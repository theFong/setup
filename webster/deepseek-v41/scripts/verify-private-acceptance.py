#!/usr/bin/env python3
"""Validate private qualification evidence before publication."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


MODEL = "deepseek-ai/DeepSeek-V4.1-Flash"
PUBLIC_MODEL = "deepseek-v4.1-flash"
PROFILE_NAME = "dspark-1m-noautotune-seqs4"
CHECKPOINT_REVISION = "dba1be0a40aa45a94ad051997016db3960a90277"
CHECKPOINT_MANIFEST_SHA256 = (
    "aad652a2b601f711599298493229f32fcc7216ca17d6bb0ccd451fd2fdd01fef"
)
VLLM_COMMIT = "e77daef89e18e08321ae7b8b24827eedd5fe8673"
VLLM_IMAGE_ID = (
    "sha256:3863bf0f59bd4df4012b7b7aed8a7d2be6ef9b42ee3a5299d014f83a1f1ba6ea"
)
AIPERF_COMMIT = "ea28b2e81c7367f8403c6f6ebe0837a508795a8d"
AIPERF_WEKA_PATCH_SHA256 = (
    "9557a46afac031b64f66ea64ebac4e8ed4d1a0e142354388c19c086a9377a36e"
)
WEKA_REPOSITORY = "semianalysisai/cc-traces-weka-062126"
WEKA_REVISION = "23f152f6f0f9399a85901b89a6458def0ef16729"
WEKA_TRACE_COUNT = 393
CLOCK_SKEW_SECONDS = 5
STATION_ENDPOINT = "http://100.73.140.127:8000/v1"
INPUT_COST_PER_TOKEN = 1.3e-8
OUTPUT_COST_PER_TOKEN = 9.6e-7
ELECTRICITY_RATE_USD_PER_KWH = 0.47
EXPECTED_PROFILE = {
    "PROFILE_NAME": PROFILE_NAME,
    "MAX_MODEL_LEN": "1048576",
    "MAX_NUM_SEQS": "4",
    "GPU_MEMORY_UTILIZATION": "0.90",
    "ENFORCE_EAGER": "0",
    "ENABLE_PREFIX_CACHING": "1",
    "MAX_NUM_BATCHED_TOKENS": "16384",
    "ENABLE_EXPERT_PARALLEL": "0",
    "SPECULATIVE_METHOD": "dspark",
    "NUM_SPECULATIVE_TOKENS": "5",
    "DRAFT_SAMPLE_METHOD": "greedy",
    "REJECTION_SAMPLE_METHOD": "standard",
    "ENABLE_FLASHINFER_AUTOTUNE": "0",
}
EXPECTED_COMMON_SERVING_ARGS = [
    "serve",
    "/model",
    "--served-model-name",
    MODEL,
    "--nnodes",
    "2",
    "--master-addr",
    "10.10.1.1",
    "--master-port",
    "29511",
    "--distributed-executor-backend",
    "mp",
    "--tensor-parallel-size",
    "2",
    "--pipeline-parallel-size",
    "1",
    "--engram-config",
    '{"cpu_offload":true,"embedding_across_dp":false}',
    "--max-model-len",
    "1048576",
    "--max-num-seqs",
    "4",
    "--gpu-memory-utilization",
    "0.90",
    "--disable-custom-all-reduce",
    "--enable-auto-tool-choice",
    "--tool-call-parser",
    "deepseek_v41",
    "--reasoning-parser",
    "deepseek_v41",
    "--enable-prefix-caching",
    "--max-num-batched-tokens",
    "16384",
    "--no-enable-flashinfer-autotune",
    "--speculative-config",
    (
        '{"method":"dspark","num_speculative_tokens":5,'
        '"draft_sample_method":"greedy",'
        '"rejection_sample_method":"standard"}'
    ),
]
FEATURE_CASES = {
    "deterministic-text",
    "utf8",
    "stop-sequence",
    "streaming",
    "usage-accounting",
    "reasoning-on",
    "tool-auto",
    "tool-named",
    "tool-required",
    "tool-parallel",
    "tool-result",
    "structured",
    "json-object",
    "vision",
    "malformed-input",
    "wrong-model",
    "disconnect-queue-drain",
}
CONTEXT_TARGETS = [320000, 600000, 990016, 996579]
SHA256 = re.compile(r"^[0-9a-f]{64}$")
IMAGE_ID = re.compile(r"^sha256:[0-9a-f]{64}$")


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-root", required=True, type=Path)
    parser.add_argument("--acceptance", required=True, type=Path)
    parser.add_argument("--max-age-seconds", required=True, type=float)
    parser.add_argument("--now")
    return parser.parse_args()


def timestamp(value: Any, label: str) -> datetime:
    require(isinstance(value, str), f"{label} timestamp must be a string")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise ValidationError(f"{label} timestamp is malformed") from error


def load_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"{label} is malformed: {error}") from error


def private_file(path: Path, run_root: Path, label: str) -> Path:
    require(path.is_absolute(), f"{label} path must be absolute")
    require(
        path.is_file() and not path.is_symlink(),
        f"{label} must be a regular non-symlink file",
    )
    resolved = path.resolve(strict=True)
    require(resolved.is_relative_to(run_root), f"{label} path escapes the run root")
    metadata = resolved.stat()
    require(stat.S_IMODE(metadata.st_mode) == 0o600, f"{label} must have mode 0600")
    require(
        metadata.st_uid == run_root.stat().st_uid,
        f"{label} owner does not match the run root",
    )
    return resolved


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def weka_record_failed(record: dict[str, Any]) -> bool:
    if record.get("error"):
        return True
    status = record.get("status_code", record.get("status"))
    if status is not None:
        return (
            not isinstance(status, int)
            or isinstance(status, bool)
            or not 200 <= status < 300
        )
    return not isinstance(record.get("metadata"), dict) or not isinstance(
        record.get("metrics"), dict
    )


def require_fresh(
    path: Path,
    label: str,
    accepted: datetime,
    now: datetime,
    max_age_seconds: float,
) -> None:
    captured = path.stat().st_mtime
    require(
        captured >= now.timestamp() - max_age_seconds,
        f"{label} evidence is stale",
    )
    require(
        captured
        <= min(accepted.timestamp(), now.timestamp()) + CLOCK_SKEW_SECONDS,
        f"{label} evidence is future-dated beyond the "
        f"{CLOCK_SKEW_SECONDS}-second clock-skew allowance",
    )


def expected_checkpoint_manifest_hash() -> str:
    if os.environ.get("WEBSTER_ACCEPTANCE_TEST_MODE") == "1":
        value = os.environ.get("TEST_CHECKPOINT_MANIFEST_SHA256", "")
        require(
            SHA256.fullmatch(value) is not None,
            "test checkpoint manifest hash is invalid",
        )
        return value
    return CHECKPOINT_MANIFEST_SHA256


def child(
    root: Any, key: str, label: str = "acceptance"
) -> dict[str, Any]:
    require(isinstance(root, dict), f"{label} must be an object")
    value = root.get(key)
    require(isinstance(value, dict), f"{label}.{key} must be an object")
    return value


def reference(
    value: dict[str, Any],
    run_root: Path,
    label: str,
    expected_path: Path,
    *,
    parse_json: bool = True,
) -> tuple[Path, Any]:
    raw_path = value.get("path")
    require(isinstance(raw_path, str), f"{label} path must be a string")
    path = private_file(Path(raw_path), run_root, label)
    require(path == expected_path, f"{label} path does not match its artifact")
    expected_hash = value.get("sha256")
    require(
        isinstance(expected_hash, str) and SHA256.fullmatch(expected_hash) is not None,
        f"{label} hash is invalid",
    )
    require(file_hash(path) == expected_hash, f"{label} hash does not match content")
    return path, load_json(path, label) if parse_json else None


def env_file(path: Path, label: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        require("=" in line, f"{label} line {number} is malformed")
        key, value = line.split("=", 1)
        require(key and key not in values, f"{label} has a duplicate field")
        values[key] = value
    return values


def validate_profile(root: dict[str, Any], run_root: Path) -> None:
    selected = child(root, "selected_profile")
    require(
        selected.get("name") == PROFILE_NAME
        and selected.get("max_model_len") == 1048576
        and selected.get("max_num_seqs") == 4
        and selected.get("speculative_method") == "dspark"
        and selected.get("flashinfer_autotune") is False,
        "selected profile does not match the qualified production profile",
    )
    expected = run_root / "profiles" / f"{PROFILE_NAME}.env"
    path, _ = reference(
        selected, run_root, "selected profile", expected, parse_json=False
    )
    require(
        env_file(path, "selected profile") == EXPECTED_PROFILE,
        "selected profile file content is wrong",
    )


def validate_runtime(root: dict[str, Any], run_root: Path) -> str:
    runtime = child(root, "runtime")
    require(
        runtime.get("checkpoint_revision") == CHECKPOINT_REVISION,
        "runtime checkpoint revision is wrong",
    )
    image = runtime.get("image_id")
    require(
        isinstance(image, str) and IMAGE_ID.fullmatch(image) is not None,
        "runtime image is invalid",
    )
    require(image == VLLM_IMAGE_ID, "runtime image is wrong")
    require(runtime.get("vllm_commit") == VLLM_COMMIT, "runtime vLLM commit is wrong")
    raw_manifest = runtime.get("manifest_path")
    require(isinstance(raw_manifest, str), "runtime manifest path must be a string")
    manifest = private_file(Path(raw_manifest), run_root, "runtime manifest")
    require(manifest == run_root / "manifest.env", "runtime manifest path is wrong")
    manifest_hash = runtime.get("manifest_sha256")
    require(
        isinstance(manifest_hash, str) and SHA256.fullmatch(manifest_hash) is not None,
        "runtime manifest hash is invalid",
    )
    require(
        file_hash(manifest) == manifest_hash,
        "runtime manifest hash does not match content",
    )
    values = env_file(manifest, "runtime manifest")
    require(values.get("CHECKPOINT_REPO") == MODEL, "runtime manifest model is wrong")
    require(
        values.get("CHECKPOINT_REVISION") == CHECKPOINT_REVISION,
        "runtime manifest checkpoint is wrong",
    )
    require(values.get("VLLM_IMAGE_ID") == image, "runtime image does not match manifest")
    require(
        values.get("VLLM_COMMIT") == runtime.get("vllm_commit"),
        "runtime vLLM commit does not match manifest",
    )
    checkpoint_hash = runtime.get("checkpoint_manifest_sha256")
    require(
        isinstance(checkpoint_hash, str)
        and SHA256.fullmatch(checkpoint_hash) is not None,
        "checkpoint manifest hash is invalid",
    )
    require(
        checkpoint_hash == expected_checkpoint_manifest_hash(),
        "checkpoint manifest hash is wrong",
    )
    for rank in ("shamu", "tilikum"):
        path = private_file(
            run_root / "baseline" / f"{rank}-checkpoint.manifest",
            run_root,
            f"{rank} checkpoint manifest",
        )
        require(
            file_hash(path) == checkpoint_hash,
            f"{rank} checkpoint manifest hash is wrong",
        )
    return image


def validate_feature(root: dict[str, Any], run_root: Path) -> None:
    item = child(root, "feature_qualification")
    _, payload = reference(
        item,
        run_root,
        "capability qualification",
        run_root / "feature-dspark-1m-seqs4-final.json",
    )
    require(
        isinstance(payload, dict) and payload.get("schema_version") == 1,
        "capability qualification schema is wrong",
    )
    require(
        payload.get("model") == MODEL and payload.get("stage") == "dspark",
        "capability qualification target is wrong",
    )
    require(
        payload.get("ok") is True and item.get("ok") is True,
        "capability qualification is not successful",
    )
    cases = payload.get("cases")
    require(isinstance(cases, list) and cases, "capability cases are missing")
    names = [case.get("case") for case in cases if isinstance(case, dict)]
    require(
        len(names) == len(cases) and len(set(names)) == len(names),
        "capability cases are malformed",
    )
    require(FEATURE_CASES.issubset(set(names)), "capability is missing required cases")
    require(
        all(case.get("semantic_ok") is True for case in cases),
        "capability contains a failed case",
    )
    by_name = {case["case"]: case for case in cases}
    require(
        all(
            by_name[name].get("status")
            == {"malformed-input": 400, "wrong-model": 404}.get(name, 200)
            for name in FEATURE_CASES
        ),
        "capability contains an unexpected response status",
    )
    deterministic = by_name["deterministic-text"]
    require(
        deterministic.get("repetitions", 0) >= 3
        and deterministic.get("distinct_normalized_outputs") == 1,
        "capability deterministic repetitions are incomplete",
    )
    disconnect = by_name["disconnect-queue-drain"]
    baseline = disconnect.get("queue_baseline")
    final = disconnect.get("queue_final")
    require(
        disconnect.get("client_disconnected") is True
        and disconnect.get("queue_drained") is True
        and isinstance(baseline, dict)
        and isinstance(final, dict)
        and all(
            isinstance(baseline.get(name), (int, float))
            and isinstance(final.get(name), (int, float))
            and final[name] <= baseline[name]
            for name in ("running", "waiting")
        ),
        "capability disconnect queue drain is incomplete",
    )
    failure_capture = payload.get("failure_log_capture")
    require(
        isinstance(failure_capture, dict)
        and failure_capture.get("requested") is True
        and failure_capture.get("captured") is False
        and failure_capture.get("ok") is True
        and failure_capture.get("nodes") == ["shamu", "tilikum"]
        and failure_capture.get("container") == "deepseek-v41-flash-tp2",
        "capability failure-log capture was not armed",
    )
    require(
        item.get("passed") == len(cases) == item.get("total"),
        "capability passed/total is wrong",
    )


def validate_context(root: dict[str, Any], run_root: Path) -> dict[str, Any]:
    item = child(root, "long_context_qualification")
    _, payload = reference(
        item,
        run_root,
        "context qualification",
        run_root / "long-context-dspark-1m-seqs4-final.json",
    )
    require(
        isinstance(payload, dict) and payload.get("schema_version") == 1,
        "context qualification schema is wrong",
    )
    require(
        payload.get("model") == MODEL and payload.get("max_model_len") == 1048576,
        "context qualification target is wrong",
    )
    require(
        payload.get("ok") is True and item.get("ok") is True,
        "context qualification is not successful",
    )
    require(
        item.get("accepted_context_totals") == CONTEXT_TARGETS,
        "context acceptance totals are wrong",
    )
    require(
        item.get("rejected_context_total") == 1048577,
        "context rejection boundary is wrong",
    )
    accepted = payload.get("accepted")
    require(isinstance(accepted, list), "context accepted cases are missing")
    require(
        [row.get("target_context_tokens") for row in accepted] == CONTEXT_TARGETS,
        "context accepted cases target the wrong totals",
    )
    for row, target in zip(accepted, CONTEXT_TARGETS):
        require(
            row.get("status") == 200
            and row.get("semantic_ok") is True
            and row.get("token_count_exact") is True
            and row.get("server_total_tokens") == target,
            "context accepted case is not qualified",
        )
    over = payload.get("over_limit")
    require(
        isinstance(over, dict)
        and over.get("target_context_tokens") == 1048577
        and over.get("status") == 400
        and over.get("semantic_ok") is True
        and over.get("token_count_exact") is True,
        "context over-limit rejection is not qualified",
    )
    calibration = payload.get("tokenizer_calibration")
    require(
        isinstance(calibration, dict)
        and calibration.get("reported_max_model_len") == 1048576
        and calibration.get("exact_linear_unit") is True,
        "context tokenizer calibration is wrong",
    )
    return payload


def validate_weka(
    root: dict[str, Any], run_root: Path, serving_generation: str
) -> dict[str, Any]:
    item = child(root, "weka_qualification")
    _, payload = reference(
        item,
        run_root,
        "Weka qualification",
        run_root / "aiperf" / "scored-summaries" / "seqs4.json",
    )
    require(
        isinstance(payload, dict)
        and payload.get("schema_version") == 1
        and payload.get("qualified") is True
        and item.get("qualified") is True,
        "Weka qualification is not successful",
    )
    mirrored = (
        "requests",
        "errors",
        "server_success_rate",
        "request_throughput",
        "output_token_throughput",
        "ttft_p90_ms",
        "request_peak_concurrency",
        "preemptions_total",
    )
    require(
        all(item.get(name) == payload.get(name) for name in mirrored),
        "Weka qualification summary does not match its artifact",
    )
    required = (
        "kv_cache_usage_max",
        "prefix_cache_hits",
        "prefix_cache_queries",
        "prefix_cache_hit_ratio",
        "running_requests_max",
        "waiting_requests_max",
        "wall_power_avg_watts",
        "facility_power_avg_watts",
        "facility_energy_kwh",
        "facility_cost_dollars",
        "completed_root_workflows",
        "cancelled_root_workflows",
        "root_workflow_elapsed_seconds",
        "completed_root_workflows_per_second",
    )
    require(
        all(payload.get(name) is not None for name in required),
        "Weka qualification is missing required metrics",
    )
    require(
        payload.get("requests", 0) > 0
        and payload.get("errors") == 0
        and payload.get("server_success_rate", 0) >= 0.99
        and payload.get("preemptions_total") == 0
        and payload.get("cancelled_root_workflows") == 0
        and payload.get("completed_root_workflows", 0) > 0,
        "Weka qualification contains disqualifying results",
    )
    repetitions = item.get("repetitions")
    require(
        isinstance(repetitions, list) and len(repetitions) == 2,
        "Weka qualification requires both repetitions",
    )
    selected_rederived: dict[str, Any] | None = None
    warmup_provenance_hash: str | None = None
    warmup_rank_states: list[dict[str, Any]] | None = None
    for expected_repetition, repetition in enumerate(repetitions, 1):
        require(isinstance(repetition, dict), "Weka repetition reference is malformed")
        raw_path = repetition.get("path")
        require(isinstance(raw_path, str), "Weka repetition path must be a string")
        expected = (
            run_root
            / "aiperf"
            / f"{PROFILE_NAME}-c4-r{expected_repetition}-open"
            / "provenance.json"
        )
        provenance_path, provenance = reference(
            repetition,
            run_root,
            f"Weka repetition {expected_repetition}",
            expected,
        )
        require(
            isinstance(provenance, dict) and provenance.get("schema_version") == 1,
            f"Weka repetition {expected_repetition} provenance is malformed",
        )
        require(
            provenance.get("profile_name") == PROFILE_NAME
            and provenance.get("concurrency") == 4
            and provenance.get("repetition") == expected_repetition,
            f"Weka repetition {expected_repetition} selected point is wrong",
        )
        require(
            provenance.get("aiperf_commit") == AIPERF_COMMIT
            and provenance.get("weka_repository") == WEKA_REPOSITORY
            and provenance.get("weka_revision") == WEKA_REVISION,
            f"Weka repetition {expected_repetition} client or dataset pin is wrong",
        )
        require(
            provenance.get("aiperf_weka_patch_sha256")
            == AIPERF_WEKA_PATCH_SHA256,
            f"Weka repetition {expected_repetition} AIPerf runtime patch is wrong",
        )
        require(
            provenance.get("trace_count") == WEKA_TRACE_COUNT
            and provenance.get("full_subagents") is True,
            f"Weka repetition {expected_repetition} does not prove the exact "
            "393-trace full-subagent corpus",
        )
        if expected_repetition == 1:
            require(
                provenance.get("cache_state") == "warmup"
                and provenance.get("warmup_and_scored_comparable") is False
                and provenance.get("warmup_provenance_sha256") is None,
                "Weka repetition 1 is not identified as the warmup",
            )
            warmup_provenance_hash = file_hash(provenance_path)
        else:
            require(
                provenance.get("cache_state") == "warm"
                and provenance.get("warmup_and_scored_comparable") is True
                and provenance.get("warmup_provenance_sha256")
                == warmup_provenance_hash,
                "Weka scored repetition is not bound to the warmup provenance",
            )
        require(
            provenance.get("serving_generation") == serving_generation,
            f"Weka repetition {expected_repetition} serving generation does not match",
        )
        require(
            provenance.get("engine_deaths") == 0
            and provenance.get("nccl_timeouts") == 0
            and provenance.get("corruption_flags") == 0
            and provenance.get("rank_fatal_error_matches") == 0,
            f"Weka repetition {expected_repetition} contains engine, NCCL, or corruption failures",
        )
        artifacts = provenance.get("artifacts")
        require(isinstance(artifacts, dict), "Weka raw artifact manifest is missing")
        required_artifacts = (
            "EXIT",
            ".aiperf_results_ready.json",
            "profile_export.jsonl",
            "profile_export_aiperf.json",
            "server_metrics_export.json",
            "aiperf.stdout.log",
            "aiperf.stderr.log",
            "rendered-command.txt",
            "summary.json",
            "benchmark-window.json",
            "rank0-before.json",
            "rank1-before.json",
            "rank0-after.json",
            "rank1-after.json",
            "rank0-container.log",
            "rank1-container.log",
        )
        directory = provenance_path.parent
        for name in required_artifacts:
            kind = "rank log" if name.endswith("-container.log") else "raw artifact"
            artifact = private_file(directory / name, run_root, f"Weka {kind} {name}")
            digest = artifacts.get(name)
            require(
                isinstance(digest, str)
                and SHA256.fullmatch(digest) is not None
                and file_hash(artifact) == digest,
                f"Weka raw artifact {name} is missing or has the wrong identity",
            )
        require(
            (directory / "EXIT").read_text(encoding="utf-8") == "EXIT=0\n",
            f"Weka repetition {expected_repetition} does not have exact EXIT=0 readiness",
        )
        readiness = load_json(
            directory / ".aiperf_results_ready.json", "Weka readiness"
        )
        require(
            isinstance(readiness, dict)
            and readiness.get("ready") is True
            and readiness.get("was_cancelled") is False
            and readiness.get("partial") is False
            and readiness.get("failed_exporters", []) == [],
            f"Weka repetition {expected_repetition} readiness is incomplete",
        )
        raw_lines = [
            line
            for line in (directory / "profile_export.jsonl")
            .read_text(encoding="utf-8")
            .splitlines()
            if line.strip()
        ]
        require(raw_lines, f"Weka repetition {expected_repetition} raw records are empty")
        try:
            raw_records = [json.loads(line) for line in raw_lines]
        except json.JSONDecodeError as error:
            raise ValidationError("Weka raw records are malformed") from error
        require(
            all(isinstance(row, dict) for row in raw_records),
            "Weka raw records must be objects",
        )
        require(
            not any(weka_record_failed(row) for row in raw_records),
            f"Weka repetition {expected_repetition} raw records contain failed requests",
        )
        require(
            '"corruption":true'
            not in (directory / "profile_export.jsonl")
            .read_text(encoding="utf-8")
            .lower(),
            f"Weka repetition {expected_repetition} raw records contain corruption flags",
        )
        fatal_pattern = re.compile(
            r"EngineDeadError|NCCL.*(?:timeout|error)|RPC call.*timed out",
            re.IGNORECASE,
        )
        require(
            all(
                fatal_pattern.search(
                    (directory / name).read_text(
                        encoding="utf-8", errors="replace"
                    )
                )
                is None
                for name in ("rank0-container.log", "rank1-container.log")
            ),
            f"Weka repetition {expected_repetition} rank logs contain fatal errors",
        )
        rank_states: list[dict[str, Any]] = []
        for rank in (0, 1):
            before = load_json(
                directory / f"rank{rank}-before.json",
                f"Weka rank {rank} pre-run state",
            )
            after = load_json(
                directory / f"rank{rank}-after.json",
                f"Weka rank {rank} post-run state",
            )
            require(
                isinstance(before, dict) and before == after,
                f"Weka repetition {expected_repetition} rank {rank} changed during the run",
            )
            require(
                before.get("image") == VLLM_IMAGE_ID
                and before.get("restart_count") == 0
                and isinstance(before.get("container_id"), str)
                and SHA256.fullmatch(before["container_id"]) is not None,
                f"Weka repetition {expected_repetition} rank {rank} state is not generation-bound",
            )
            rank_states.append(after)
        generation_result = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("verify-serving-pair.py")),
                "--rank0-state-json",
                json.dumps(rank_states[0], separators=(",", ":")),
                "--rank1-state-json",
                json.dumps(rank_states[1], separators=(",", ":")),
                "--max-start-skew-seconds",
                "120",
                "--require-matching-image",
                "--print-generation",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        require(
            generation_result.returncode == 0
            and generation_result.stdout.strip() == serving_generation,
            f"Weka repetition {expected_repetition} rank state is not generation-bound",
        )
        if expected_repetition == 1:
            warmup_rank_states = rank_states
        else:
            require(
                warmup_rank_states == rank_states,
                "Weka scored repetition did not continue on the warmup serving ranks",
            )
        window = load_json(
            directory / "benchmark-window.json", "Weka benchmark window"
        )
        require(
            isinstance(window, dict)
            and timestamp(window.get("started_at"), "Weka benchmark start")
            <= timestamp(window.get("ended_at"), "Weka benchmark end"),
            f"Weka repetition {expected_repetition} benchmark window is invalid",
        )
        with tempfile.TemporaryDirectory(prefix="webster-weka-verify-") as temporary:
            derived_path = Path(temporary) / "summary.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("summarize-aiperf.py")),
                    "--profile",
                    str(directory / "profile_export_aiperf.json"),
                    "--records",
                    str(directory / "profile_export.jsonl"),
                    "--server-metrics",
                    str(directory / "server_metrics_export.json"),
                    "--timing-log",
                    str(directory / "aiperf.stdout.log"),
                    "--output-json",
                    str(derived_path),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            require(
                result.returncode == 0,
                f"Weka repetition {expected_repetition} raw artifacts are not qualified: "
                f"{result.stderr.strip()}",
            )
            derived = load_json(
                derived_path, f"Weka repetition {expected_repetition} rederived summary"
            )
        stored_summary = load_json(
            directory / "summary.json",
            f"Weka repetition {expected_repetition} stored summary",
        )
        require(
            stored_summary == derived,
            f"Weka repetition {expected_repetition} stored summary differs from raw artifacts",
        )
        if expected_repetition == 2:
            selected_rederived = derived
    require(selected_rederived is not None, "Weka repetition 2 was not rederived")
    selected_fields = mirrored + required + (
        "completed",
        "qualified",
    )
    require(
        all(payload.get(name) == selected_rederived.get(name) for name in selected_fields),
        "Weka selected score differs from rederived repetition 2",
    )
    return payload


def validate_pricing(
    root: dict[str, Any],
    run_root: Path,
    serving_generation: str,
    context: dict[str, Any],
    weka: dict[str, Any],
) -> tuple[float, float]:
    item = child(root, "pricing_evidence")
    expected_path = run_root / "pricing-evidence.json"
    require(expected_path.is_file(), "pricing evidence is absent")
    _, pricing = reference(
        item,
        run_root,
        "pricing evidence",
        expected_path,
    )
    require(isinstance(pricing, dict), "pricing evidence must be an object")
    require(
        set(pricing)
        == {
            "schema_version",
            "model",
            "serving_generation",
            "electricity_rate_usd_per_kwh",
            "facility_power_watts",
            "input",
            "output",
        },
        "pricing evidence schema is wrong",
    )
    require(
        pricing.get("schema_version") == 1 and pricing.get("model") == MODEL,
        "pricing evidence identity is wrong",
    )
    require(
        pricing.get("serving_generation") == serving_generation,
        "pricing evidence references a different serving generation",
    )
    rate = pricing.get("electricity_rate_usd_per_kwh")
    power = pricing.get("facility_power_watts")
    require(
        isinstance(rate, (int, float))
        and not isinstance(rate, bool)
        and rate == ELECTRICITY_RATE_USD_PER_KWH
        and isinstance(power, (int, float))
        and not isinstance(power, bool)
        and power == weka.get("facility_power_avg_watts"),
        "pricing evidence power or electricity rate is wrong",
    )
    input_basis = pricing.get("input")
    output_basis = pricing.get("output")
    require(
        isinstance(input_basis, dict)
        and set(input_basis)
        == {
            "basis",
            "prompt_tokens",
            "elapsed_seconds",
            "throughput_tokens_per_second",
            "direct_energy_cost_per_token",
            "published_cost_per_token",
        },
        "pricing input evidence schema is wrong",
    )
    require(
        isinstance(output_basis, dict)
        and set(output_basis)
        == {
            "basis",
            "throughput_tokens_per_second",
            "direct_energy_cost_per_token",
            "published_cost_per_token",
        },
        "pricing output evidence schema is wrong",
    )
    accepted = context.get("accepted")
    require(
        isinstance(accepted, list) and accepted and isinstance(accepted[0], dict),
        "pricing cold-prefill source is missing",
    )
    cold = accepted[0]
    prompt_tokens = input_basis.get("prompt_tokens")
    elapsed = input_basis.get("elapsed_seconds")
    input_throughput = input_basis.get("throughput_tokens_per_second")
    output_throughput = output_basis.get("throughput_tokens_per_second")
    numeric = (int, float)
    require(
        input_basis.get("basis") == "cold-prefill"
        and prompt_tokens == cold.get("expected_prompt_tokens") == 319999
        and prompt_tokens == cold.get("server_prompt_tokens")
        and elapsed == cold.get("latency_seconds")
        and isinstance(elapsed, numeric)
        and not isinstance(elapsed, bool)
        and elapsed > 0
        and isinstance(input_throughput, numeric)
        and not isinstance(input_throughput, bool)
        and math.isclose(
            input_throughput,
            prompt_tokens / elapsed,
            rel_tol=1e-12,
            abs_tol=0.0,
        ),
        "pricing input value does not prove the measured cold-prefill throughput",
    )
    require(
        output_basis.get("basis") == "selected-weka-profile"
        and isinstance(output_throughput, numeric)
        and not isinstance(output_throughput, bool)
        and output_throughput == weka.get("output_token_throughput")
        and output_throughput > 0,
        "pricing output value does not match measured Weka throughput",
    )
    energy_per_second = power / 1000 * rate / 3600
    expected_input_direct = energy_per_second / input_throughput
    expected_output_direct = energy_per_second / output_throughput
    input_direct = input_basis.get("direct_energy_cost_per_token")
    output_direct = output_basis.get("direct_energy_cost_per_token")
    input_published = input_basis.get("published_cost_per_token")
    output_published = output_basis.get("published_cost_per_token")
    require(
        isinstance(input_direct, numeric)
        and not isinstance(input_direct, bool)
        and math.isclose(
            input_direct, expected_input_direct, rel_tol=1e-12, abs_tol=0.0
        )
        and input_published == INPUT_COST_PER_TOKEN,
        "pricing input value is wrong",
    )
    require(
        isinstance(output_direct, numeric)
        and not isinstance(output_direct, bool)
        and math.isclose(
            output_direct, expected_output_direct, rel_tol=1e-12, abs_tol=0.0
        )
        and output_published == OUTPUT_COST_PER_TOKEN,
        "pricing output value is wrong",
    )
    return input_published, output_published


def validate_rank_evidence(
    root: dict[str, Any],
    run_root: Path,
    image: str,
    accepted: datetime,
) -> None:
    live = child(root, "live_state")
    serving_generation = live.get("serving_generation")
    require(
        isinstance(serving_generation, str) and serving_generation,
        "live serving generation is missing",
    )
    require(
        live.get("restart_counts_zero") is True
        and live.get("fatal_error_matches") == 0
        and isinstance(live.get("kv_cache_tokens"), int)
        and live["kv_cache_tokens"] > 0
        and isinstance(live.get("full_context_concurrency"), (int, float))
        and live["full_context_concurrency"] > 0,
        "live state is not qualified",
    )
    texts: dict[str, str] = {}
    for key, label in (
        ("rank_0_evidence", "rank 0 evidence"),
        ("rank_1_evidence", "rank 1 evidence"),
        ("api_evidence", "API evidence"),
    ):
        item = child(live, key, "acceptance.live_state")
        raw_path = item.get("path")
        require(isinstance(raw_path, str), f"{label} path must be a string")
        path = private_file(Path(raw_path), run_root, label)
        require(path.parent == run_root / "logs", f"{label} path is wrong")
        digest = item.get("sha256")
        require(
            isinstance(digest, str)
            and SHA256.fullmatch(digest) is not None
            and file_hash(path) == digest,
            f"{label} hash does not match content",
        )
        require(
            path.stat().st_mtime <= accepted.timestamp() + 5,
            f"{label} was captured after acceptance",
        )
        texts[key] = path.read_text(encoding="utf-8")
    rank0 = texts["rank_0_evidence"]
    rank1 = texts["rank_1_evidence"]

    def serving_args(text: str, label: str) -> list[str]:
        rows = [line.split(" args=", 1)[1] for line in text.splitlines() if " args=" in line]
        require(len(rows) == 1, f"{label} serving arguments are missing or duplicated")
        try:
            value = json.loads(rows[0])
        except json.JSONDecodeError as error:
            raise ValidationError(f"{label} serving arguments are malformed") from error
        require(
            isinstance(value, list) and all(isinstance(arg, str) for arg in value),
            f"{label} serving arguments must be a string array",
        )
        return value

    rank0_args = EXPECTED_COMMON_SERVING_ARGS + [
        "--node-rank",
        "0",
        "--host",
        "100.73.140.127",
        "--port",
        "8000",
    ]
    rank1_args = EXPECTED_COMMON_SERVING_ARGS + ["--node-rank", "1", "--headless"]
    require(
        serving_args(rank0, "rank 0") == rank0_args
        and f"image={image}" in rank0
        and "running=true" in rank0
        and "restart=0" in rank0
        and "serving_key_vars=1" in rank0
        and "health=pass" in rank0
        and "100.73.140.127:8000" in rank0,
        "rank 0 serving arguments or identity for shamu are wrong",
    )
    require(
        serving_args(rank1, "rank 1") == rank1_args
        and f"image={image}" in rank1
        and "running=true" in rank1
        and "restart=0" in rank1
        and "serving_key_vars=0" in rank1
        and "listener=none" in rank1
        and "fatal_error_matches=0" in rank1,
        "rank 1 serving arguments or identity for tilikum are wrong",
    )
    require(
        f"generation={serving_generation}" in rank0
        and f"generation={serving_generation}" in rank1,
        "rank evidence does not match the accepted serving generation",
    )
    api_rows = [
        json.loads(line)
        for line in texts["api_evidence"].splitlines()
        if line.strip().startswith("{")
    ]
    require(
        len(api_rows) == 1
        and api_rows[0].get("missing_key_status") == 401
        and api_rows[0].get("wrong_key_status") == 401
        and api_rows[0].get("correct_key_status") == 200
        and api_rows[0].get("status") == 200
        and api_rows[0].get("model") == MODEL
        and api_rows[0].get("has_content") is True,
        "API auth evidence must prove missing/wrong 401 and correct-key 200",
    )
    require(
        api_rows[0].get("serving_generation") == serving_generation,
        "API auth evidence references a different serving generation",
    )


def validate() -> None:
    args = parse_args()
    require(args.max_age_seconds > 0, "maximum age must be positive")
    run_root = args.run_root.resolve(strict=True)
    require(
        run_root.is_dir() and not args.run_root.is_symlink(),
        "run root must be a regular directory",
    )
    acceptance = private_file(args.acceptance, run_root, "private acceptance")
    require(
        acceptance == run_root / "private-acceptance.json",
        "private acceptance path is wrong",
    )
    root = load_json(acceptance, "private acceptance")
    require(isinstance(root, dict), "private acceptance must be an object")
    require(root.get("schema_version") == 1, "private acceptance schema is wrong")
    require(root.get("decision") == "GO", "private acceptance decision is not GO")
    require(
        root.get("model") == MODEL
        and root.get("public_model_name") == PUBLIC_MODEL,
        "private acceptance model identity is wrong",
    )
    accepted = timestamp(root.get("accepted_at"), "accepted_at")
    now = timestamp(args.now, "now") if args.now else datetime.now(timezone.utc)
    age = (now - accepted).total_seconds()
    require(
        age >= -CLOCK_SKEW_SECONDS,
        "private acceptance timestamp is beyond the documented clock-skew allowance",
    )
    require(age <= args.max_age_seconds, "private acceptance is stale")
    topology = child(root, "topology")
    require(
        topology
        == {
            "tensor_parallel_size": 2,
            "pipeline_parallel_size": 1,
            "rank_0": "shamu",
            "rank_1": "tilikum",
            "rank_1_headless_and_keyless": True,
        },
        "rank identity or topology is wrong",
    )
    require(
        (run_root / "pricing-evidence.json").is_file(),
        "pricing evidence is absent",
    )
    for section, label in (
        (child(root, "feature_qualification"), "feature qualification"),
        (child(root, "long_context_qualification"), "context qualification"),
        (child(root, "weka_qualification"), "Weka qualification"),
        (child(root, "pricing_evidence"), "pricing evidence"),
        (child(child(root, "live_state"), "rank_0_evidence", "acceptance.live_state"), "Shamu rank"),
        (child(child(root, "live_state"), "rank_1_evidence", "acceptance.live_state"), "Tilikum rank"),
        (child(child(root, "live_state"), "api_evidence", "acceptance.live_state"), "station API auth"),
    ):
        raw_path = section.get("path")
        require(isinstance(raw_path, str), f"{label} path must be a string")
        evidence_path = private_file(Path(raw_path), run_root, label)
        require_fresh(evidence_path, label, accepted, now, args.max_age_seconds)
    validate_profile(root, run_root)
    image = validate_runtime(root, run_root)
    validate_feature(root, run_root)
    context = validate_context(root, run_root)
    serving_generation = child(root, "live_state").get("serving_generation")
    require(isinstance(serving_generation, str), "live serving generation is missing")
    weka = validate_weka(root, run_root, serving_generation)
    input_cost, output_cost = validate_pricing(
        root,
        run_root,
        serving_generation,
        context,
        weka,
    )
    validate_rank_evidence(root, run_root, image, accepted)
    publication = child(root, "publication")
    require(
        publication
        == {
            "public_model_name": PUBLIC_MODEL,
            "served_model_name": MODEL,
            "max_context": 1048576,
            "station_endpoint": STATION_ENDPOINT,
            "supports_function_calling": True,
            "supports_reasoning": True,
            "supports_response_schema": True,
            "supports_vision": True,
            "input_cost_per_token": input_cost,
            "output_cost_per_token": output_cost,
        },
        "publication parameters do not match the accepted record",
    )
    selection = child(root, "selection")
    require(
        selection.get("pp2_triggered") is False
        and isinstance(selection.get("pp2_reason"), str)
        and selection["pp2_reason"]
        and isinstance(selection.get("reason"), str)
        and selection["reason"],
        "selection rationale is incomplete",
    )
    gain = selection.get("seqs_8_request_throughput_gain_percent")
    require(
        isinstance(gain, (int, float))
        and not isinstance(gain, bool)
        and gain == 0.89,
        "selection measurement is wrong",
    )


def main() -> int:
    try:
        validate()
    except (ValidationError, OSError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("private acceptance validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
