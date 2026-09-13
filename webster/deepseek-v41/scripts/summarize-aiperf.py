#!/usr/bin/env python3
"""Summarize AIPerf records before trusting aggregate profile metrics."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any


PROFILING_COMPLETE_MARKER = "Phase profiling (profiling) complete"
DISPLAYED_COUNT = r"(?:\d+|\d{1,3}(?:,\d{3})+)"
PROFILING_COMPLETE_PATTERN = re.compile(
    r"(?:^|\s)Phase profiling \(profiling\) complete \| "
    rf"completed={DISPLAYED_COUNT}, cancelled={DISPLAYED_COUNT}, "
    rf"errors={DISPLAYED_COUNT} \| "
    r"sessions: completed=(?P<completed>\d+), "
    r"cancelled=(?P<cancelled>\d+) \| "
    r"elapsed=(?P<elapsed>\d+(?:\.\d+)?)s(?: \(runner\.py:\d+\))?$"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--records", required=True, type=Path)
    parser.add_argument("--server-metrics", type=Path)
    parser.add_argument("--timing-log", type=Path)
    parser.add_argument("--output-json", required=True, type=Path)
    return parser.parse_args()


def load_json(path: Path) -> Any:
    if not path.is_file() or path.is_symlink():
        raise RuntimeError(f"input must be a regular non-symlink file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def load_records(path: Path) -> list[dict[str, Any]]:
    if not path.is_file() or path.is_symlink():
        raise RuntimeError(f"records must be a regular non-symlink file: {path}")
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise RuntimeError(f"record line {line_number} is not an object")
        records.append(value)
    return records


def metric_stat(
    profile: dict[str, Any], name: str, stat: str, legacy_name: str
) -> float | None:
    current = profile.get(name)
    if isinstance(current, dict):
        value = current.get(stat)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return float(value)
    metrics = profile.get("metrics")
    if not isinstance(metrics, dict):
        return None
    value = metrics.get(legacy_name)
    if isinstance(value, dict):
        value = value.get("mean")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


def error_type(value: Any) -> str:
    if isinstance(value, dict):
        value = value.get("type") or value.get("message") or "unknown"
    text = str(value or "unknown").strip()
    match = re.search(r"([A-Za-z_][A-Za-z0-9_]*(?:Error|Exception|Timeout))", text)
    return match.group(1) if match else text[:160]


def record_failed(record: dict[str, Any]) -> bool:
    if record.get("error"):
        return True
    status = record.get("status_code", record.get("status"))
    if status is not None:
        return not isinstance(status, int) or not 200 <= status < 300
    return not isinstance(record.get("metadata"), dict) or not isinstance(
        record.get("metrics"), dict
    )


def peak_concurrency(records: list[dict[str, Any]]) -> int | None:
    events: list[tuple[int, int]] = []
    for record in records:
        metadata = record.get("metadata")
        if not isinstance(metadata, dict):
            continue
        start = metadata.get("request_start_ns")
        end = metadata.get("request_end_ns")
        if (
            isinstance(start, int)
            and not isinstance(start, bool)
            and isinstance(end, int)
            and not isinstance(end, bool)
            and end >= start
        ):
            events.extend(((start, 1), (end, -1)))
    if not events:
        return None
    active = maximum = 0
    for _, change in sorted(events, key=lambda item: (item[0], item[1])):
        active += change
        maximum = max(maximum, active)
    return maximum


def finite_number(value: Any, context: str) -> float:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(value)
    ):
        raise RuntimeError(f"{context} must be a finite number")
    return float(value)


def metric_series(
    metrics: dict[str, Any], name: str, expected_type: str
) -> list[dict[str, Any]] | None:
    if name not in metrics:
        return None
    metric = metrics[name]
    if not isinstance(metric, dict):
        raise RuntimeError(f"server metric {name} must be an object")
    if metric.get("type") != expected_type:
        raise RuntimeError(
            f"server metric {name} must have type {expected_type}"
        )
    series = metric.get("series")
    if not isinstance(series, list):
        raise RuntimeError(f"server metric {name} series must be a list")
    for index, item in enumerate(series):
        if not isinstance(item, dict):
            raise RuntimeError(f"server metric {name} series {index} must be an object")
        endpoint = item.get("endpoint_url")
        if not isinstance(endpoint, str) or not endpoint:
            raise RuntimeError(
                f"server metric {name} series {index} endpoint_url must be a string"
            )
        labels = item.get("labels")
        if labels is not None and (
            not isinstance(labels, dict)
            or any(
                not isinstance(key, str) or not isinstance(value, str)
                for key, value in labels.items()
            )
        ):
            raise RuntimeError(
                f"server metric {name} series {index} labels must be a string map"
            )
        stats = item.get("stats")
        if stats is not None and not isinstance(stats, dict):
            raise RuntimeError(
                f"server metric {name} series {index} stats must be an object"
            )
    return series


def series_stat(item: dict[str, Any], name: str, stat: str) -> float | None:
    stats = item.get("stats")
    if stats is None or stats.get(stat) is None:
        return None
    return finite_number(stats[stat], f"server metric {name} {stat}")


def sum_counter_totals(
    metrics: dict[str, Any], name: str, scope: str | None = None
) -> float | None:
    series = metric_series(metrics, name, "counter")
    if series is None:
        return None
    values: list[float] = []
    seen: set[tuple[str, tuple[tuple[str, str], ...]]] = set()
    for item in series:
        labels = item.get("labels") or {}
        if scope is not None and labels.get("scope") != scope:
            continue
        identity = (item["endpoint_url"], tuple(sorted(labels.items())))
        if identity in seen:
            raise RuntimeError(f"server metric {name} contains duplicate series")
        seen.add(identity)
        value = series_stat(item, name, "total")
        if value is None:
            return None
        values.append(value)
    return sum(values) if values else None


def gauge_stat(
    metrics: dict[str, Any], name: str, stat: str, scope: str | None = None
) -> float | None:
    series = metric_series(metrics, name, "gauge")
    if series is None:
        return None
    values: list[float] = []
    seen: set[tuple[str, tuple[tuple[str, str], ...]]] = set()
    for item in series:
        labels = item.get("labels") or {}
        if scope is not None and labels.get("scope") != scope:
            continue
        identity = (item["endpoint_url"], tuple(sorted(labels.items())))
        if identity in seen:
            raise RuntimeError(f"server metric {name} contains duplicate series")
        seen.add(identity)
        value = series_stat(item, name, stat)
        if value is None:
            return None
        values.append(value)
    if not values:
        return None
    return sum(values) if stat == "avg" else max(values)


def summarize_server_metrics(value: Any) -> dict[str, float | None]:
    if not isinstance(value, dict):
        raise RuntimeError("server metrics root must be an object")
    metrics = value.get("metrics")
    if not isinstance(metrics, dict):
        raise RuntimeError("server metrics metrics must be an object")
    hits = sum_counter_totals(metrics, "vllm:prefix_cache_hits")
    queries = sum_counter_totals(metrics, "vllm:prefix_cache_queries")
    hit_ratio = (
        hits / queries if hits is not None and queries not in (None, 0.0) else None
    )
    return {
        "prefix_cache_hits": hits,
        "prefix_cache_queries": queries,
        "prefix_cache_hit_ratio": hit_ratio,
        "kv_cache_usage_max": gauge_stat(
            metrics, "vllm:kv_cache_usage_perc", "max"
        ),
        "preemptions_total": sum_counter_totals(
            metrics, "vllm:num_preemptions"
        ),
        "running_requests_max": gauge_stat(
            metrics, "vllm:num_requests_running", "max"
        ),
        "waiting_requests_max": gauge_stat(
            metrics, "vllm:num_requests_waiting", "max"
        ),
        "wall_power_avg_watts": gauge_stat(
            metrics, "power_total_watts", "avg", "wall"
        ),
        "facility_power_avg_watts": gauge_stat(
            metrics, "power_total_watts", "avg", "facility"
        ),
        "facility_energy_kwh": sum_counter_totals(
            metrics, "power_energy_kwh", "facility"
        ),
        "facility_cost_dollars": sum_counter_totals(metrics, "power_cost_dollars"),
    }


def summarize_timing_log(path: Path) -> dict[str, float | int]:
    if not path.is_file() or path.is_symlink():
        raise RuntimeError(f"timing log must be a regular non-symlink file: {path}")
    candidates = [
        line
        for line in path.read_text(encoding="utf-8").splitlines()
        if PROFILING_COMPLETE_MARKER in line
    ]
    if len(candidates) != 1:
        raise RuntimeError(
            "timing log must contain exactly one profiling-complete line"
        )
    match = PROFILING_COMPLETE_PATTERN.search(candidates[0])
    if match is None:
        raise RuntimeError("profiling-complete timing log line is malformed")
    completed = int(match.group("completed"))
    cancelled = int(match.group("cancelled"))
    elapsed = finite_number(
        float(match.group("elapsed")), "root workflow elapsed seconds"
    )
    if elapsed <= 0.0:
        raise RuntimeError(
            "root workflow elapsed seconds must be greater than zero"
        )
    return {
        "completed_root_workflows": completed,
        "cancelled_root_workflows": cancelled,
        "root_workflow_elapsed_seconds": elapsed,
        "completed_root_workflows_per_second": completed / elapsed,
    }


def write_private_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    try:
        profile = load_json(args.profile)
        records = load_records(args.records)
        if not isinstance(profile, dict):
            raise RuntimeError("profile root must be an object")
        failures = [record for record in records if record_failed(record)]
        counts = Counter(error_type(record.get("error")) for record in failures)
        depths = Counter(
            str(metadata["agent_depth"])
            for record in records
            if isinstance((metadata := record.get("metadata")), dict)
            and isinstance(metadata.get("agent_depth"), int)
            and not isinstance(metadata["agent_depth"], bool)
        )
        root_trees = {
            metadata["root_correlation_id"]
            for record in records
            if isinstance((metadata := record.get("metadata")), dict)
            and isinstance(metadata.get("root_correlation_id"), str)
            and metadata["root_correlation_id"]
        }
        completed = len(records) - len(failures)
        success_rate = completed / len(records) if records else 0.0
        summary = {
            "schema_version": 1,
            "requests": len(records),
            "completed": completed,
            "errors": len(failures),
            "server_success_rate": success_rate,
            "error_types": dict(sorted(counts.items())),
            "request_throughput": metric_stat(
                profile, "request_throughput", "avg", "request_throughput_avg"
            ),
            "ttft_p90_ms": metric_stat(
                profile, "time_to_first_token", "p90", "time_to_first_token_p90"
            ),
            "output_token_throughput": metric_stat(
                profile,
                "output_token_throughput",
                "avg",
                "output_token_throughput_avg",
            ),
            "request_peak_concurrency": peak_concurrency(records),
            "root_session_trees": len(root_trees),
            "request_count_by_agent_depth": dict(sorted(depths.items())),
            "qualified": bool(records) and success_rate >= 0.99 and not failures,
        }
        if args.server_metrics is not None:
            summary.update(summarize_server_metrics(load_json(args.server_metrics)))
        if args.timing_log is not None:
            summary.update(summarize_timing_log(args.timing_log))
        write_private_json(args.output_json, summary)
    except (OSError, RuntimeError, UnicodeError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(
        "AIPerf summary "
        f"requests={summary['requests']} errors={summary['errors']} "
        f"qualified={str(summary['qualified']).lower()}"
    )
    return 0 if summary["qualified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
