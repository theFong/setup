#!/usr/bin/env python3
"""Build the private publication manifest only after all evidence is stable."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


PROFILE_NAME = "dspark-1m-noautotune-seqs4"
MODEL = "deepseek-ai/DeepSeek-V4.1-Flash"
PUBLIC_MODEL = "deepseek-v4.1-flash"
STATION_ENDPOINT = "http://100.73.140.127:8000/v1"
KV_PATTERN = re.compile(
    r"GPU KV cache size:\s*([0-9,]+) tokens, Maximum concurrency for "
    r"1,048,576 tokens per request:\s*([0-9.]+)x"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-root", required=True, type=Path)
    parser.add_argument("--rank-0-evidence", required=True, type=Path)
    parser.add_argument("--rank-1-evidence", required=True, type=Path)
    parser.add_argument("--api-evidence", required=True, type=Path)
    parser.add_argument(
        "--seqs-8-request-throughput-gain-percent", required=True, type=float
    )
    parser.add_argument("--selection-reason", required=True)
    parser.add_argument("--pp2-reason", required=True)
    parser.add_argument("--max-age-seconds", type=float, default=21600)
    return parser.parse_args()


def fail(message: str) -> None:
    raise RuntimeError(message)


def private_file(path: Path, run_root: Path, label: str) -> Path:
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        fail(f"{label} must be an absolute regular non-symlink file")
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(run_root):
        fail(f"{label} escapes the run root")
    if stat.S_IMODE(resolved.stat().st_mode) != 0o600:
        fail(f"{label} must have mode 0600")
    if resolved.stat().st_uid != run_root.stat().st_uid:
        fail(f"{label} owner does not match the run root")
    return resolved


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeError(f"{label} is malformed") from error
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def load_env(path: Path, label: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            fail(f"{label} line {number} is malformed")
        key, value = line.split("=", 1)
        if not key or key in values:
            fail(f"{label} contains a duplicate or empty field")
        values[key] = value
    return values


def reference(path: Path) -> dict[str, str]:
    return {"path": str(path), "sha256": sha256(path)}


def write_private_json(path: Path, value: Any) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def generate(args: argparse.Namespace) -> tuple[Path, str]:
    run_root = args.run_root.resolve(strict=True)
    if not run_root.is_dir() or args.run_root.is_symlink():
        fail("run root must be a regular directory")

    profile = private_file(
        run_root / "profiles" / f"{PROFILE_NAME}.env",
        run_root,
        "selected profile",
    )
    manifest = private_file(run_root / "manifest.env", run_root, "runtime manifest")
    checkpoint_shamu = private_file(
        run_root / "baseline" / "shamu-checkpoint.manifest",
        run_root,
        "Shamu checkpoint manifest",
    )
    checkpoint_tilikum = private_file(
        run_root / "baseline" / "tilikum-checkpoint.manifest",
        run_root,
        "Tilikum checkpoint manifest",
    )
    if sha256(checkpoint_shamu) != sha256(checkpoint_tilikum):
        fail("checkpoint manifests differ between ranks")

    feature_path = private_file(
        run_root / "feature-dspark-1m-seqs4-final.json",
        run_root,
        "feature qualification",
    )
    context_path = private_file(
        run_root / "long-context-dspark-1m-seqs4-final.json",
        run_root,
        "long-context qualification",
    )
    weka_path = private_file(
        run_root / "aiperf" / "scored-summaries" / "seqs4.json",
        run_root,
        "Weka qualification",
    )
    pricing_path = private_file(
        run_root / "pricing-evidence.json",
        run_root,
        "pricing evidence",
    )
    weka_repetitions = [
        private_file(
            run_root
            / "aiperf"
            / f"{PROFILE_NAME}-c4-r{repetition}-open"
            / "provenance.json",
            run_root,
            f"Weka repetition {repetition} provenance",
        )
        for repetition in (1, 2)
    ]
    rank_0 = private_file(args.rank_0_evidence, run_root, "rank 0 evidence")
    rank_1 = private_file(args.rank_1_evidence, run_root, "rank 1 evidence")
    api = private_file(args.api_evidence, run_root, "API evidence")

    feature = load_json(feature_path, "feature qualification")
    context = load_json(context_path, "long-context qualification")
    weka = load_json(weka_path, "Weka qualification")
    pricing = load_json(pricing_path, "pricing evidence")
    manifest_values = load_env(manifest, "runtime manifest")
    profile_values = load_env(profile, "selected profile")
    rank_0_text = rank_0.read_text(encoding="utf-8")
    rank_1_text = rank_1.read_text(encoding="utf-8")
    kv = KV_PATTERN.search(rank_0_text)
    if kv is None:
        fail("rank 0 evidence is missing KV-cache capacity")
    fatal = re.search(r"fatal_error_matches=([0-9]+)", rank_1_text)
    if fatal is None:
        fail("rank 1 evidence is missing fatal-error count")
    rank_0_generation = re.search(r"^generation=(\S+)$", rank_0_text, re.MULTILINE)
    rank_1_generation = re.search(r"^generation=(\S+)$", rank_1_text, re.MULTILINE)
    if (
        rank_0_generation is None
        or rank_1_generation is None
        or rank_0_generation.group(1) != rank_1_generation.group(1)
    ):
        fail("rank evidence does not identify one serving generation")
    serving_generation = rank_0_generation.group(1)

    cases = feature.get("cases")
    accepted = context.get("accepted")
    if not isinstance(cases, list) or not isinstance(accepted, list):
        fail("qualification artifacts are incomplete")
    accepted_totals = [row.get("target_context_tokens") for row in accepted]
    over_limit = context.get("over_limit")
    if not isinstance(over_limit, dict):
        fail("long-context over-limit result is missing")
    pricing_input = pricing.get("input")
    pricing_output = pricing.get("output")
    if not isinstance(pricing_input, dict) or not isinstance(pricing_output, dict):
        fail("pricing evidence is incomplete")

    mirrored_weka = (
        "requests",
        "errors",
        "server_success_rate",
        "request_throughput",
        "output_token_throughput",
        "ttft_p90_ms",
        "request_peak_concurrency",
        "preemptions_total",
    )
    accepted_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    output = run_root / "private-acceptance.json"
    value = {
        "schema_version": 1,
        "accepted_at": accepted_at,
        "decision": "GO",
        "model": MODEL,
        "public_model_name": PUBLIC_MODEL,
        "topology": {
            "tensor_parallel_size": 2,
            "pipeline_parallel_size": 1,
            "rank_0": "shamu",
            "rank_1": "tilikum",
            "rank_1_headless_and_keyless": True,
        },
        "selected_profile": {
            "name": PROFILE_NAME,
            "path": str(profile),
            "sha256": sha256(profile),
            "max_model_len": int(profile_values["MAX_MODEL_LEN"]),
            "max_num_seqs": int(profile_values["MAX_NUM_SEQS"]),
            "speculative_method": profile_values["SPECULATIVE_METHOD"],
            "flashinfer_autotune": (
                profile_values["ENABLE_FLASHINFER_AUTOTUNE"] == "1"
            ),
        },
        "runtime": {
            "manifest_path": str(manifest),
            "manifest_sha256": sha256(manifest),
            "vllm_commit": manifest_values["VLLM_COMMIT"],
            "image_id": manifest_values["VLLM_IMAGE_ID"],
            "checkpoint_revision": manifest_values["CHECKPOINT_REVISION"],
            "checkpoint_manifest_sha256": sha256(checkpoint_shamu),
        },
        "feature_qualification": {
            **reference(feature_path),
            "passed": sum(
                1
                for case in cases
                if isinstance(case, dict) and case.get("semantic_ok") is True
            ),
            "total": len(cases),
            "ok": feature.get("ok"),
        },
        "long_context_qualification": {
            **reference(context_path),
            "accepted_context_totals": accepted_totals,
            "rejected_context_total": over_limit.get("target_context_tokens"),
            "ok": context.get("ok"),
        },
        "weka_qualification": {
            **reference(weka_path),
            **{name: weka.get(name) for name in mirrored_weka},
            "qualified": weka.get("qualified"),
            "repetitions": [reference(path) for path in weka_repetitions],
        },
        "live_state": {
            "rank_0_evidence": reference(rank_0),
            "rank_1_evidence": reference(rank_1),
            "api_evidence": reference(api),
            "kv_cache_tokens": int(kv.group(1).replace(",", "")),
            "full_context_concurrency": float(kv.group(2)),
            "restart_counts_zero": (
                "running=true" in rank_0_text
                and "restart=0" in rank_0_text
                and "running=true" in rank_1_text
                and "restart=0" in rank_1_text
            ),
            "fatal_error_matches": int(fatal.group(1)),
            "serving_generation": serving_generation,
        },
        "selection": {
            "seqs_8_request_throughput_gain_percent": (
                args.seqs_8_request_throughput_gain_percent
            ),
            "reason": args.selection_reason,
            "pp2_triggered": False,
            "pp2_reason": args.pp2_reason,
        },
        "pricing_evidence": reference(pricing_path),
        "publication": {
            "public_model_name": PUBLIC_MODEL,
            "served_model_name": MODEL,
            "max_context": int(profile_values["MAX_MODEL_LEN"]),
            "station_endpoint": STATION_ENDPOINT,
            "supports_function_calling": True,
            "supports_reasoning": True,
            "supports_response_schema": True,
            "supports_vision": any(
                isinstance(case, dict)
                and case.get("case") == "vision"
                and case.get("semantic_ok") is True
                and case.get("status") == 200
                for case in cases
            ),
            "input_cost_per_token": pricing_input.get("published_cost_per_token"),
            "output_cost_per_token": pricing_output.get("published_cost_per_token"),
        },
    }
    write_private_json(output, value)
    return output, accepted_at


def main() -> int:
    args = parse_args()
    try:
        output, accepted_at = generate(args)
        verifier = Path(__file__).with_name("verify-private-acceptance.py")
        result = subprocess.run(
            [
                sys.executable,
                str(verifier),
                "--run-root",
                str(args.run_root),
                "--acceptance",
                str(output),
                "--max-age-seconds",
                str(args.max_age_seconds),
                "--now",
                accepted_at,
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            fail(result.stderr.strip() or "generated acceptance failed validation")
    except (KeyError, OSError, RuntimeError, UnicodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"private acceptance generated and validated: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
