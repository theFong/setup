#!/usr/bin/env python3
"""Behavior tests for the publication private-acceptance gate."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
VERIFIER = (
    REPOSITORY_ROOT
    / "webster"
    / "deepseek-v41"
    / "scripts"
    / "verify-private-acceptance.py"
)
GENERATOR = (
    REPOSITORY_ROOT
    / "webster"
    / "deepseek-v41"
    / "scripts"
    / "generate-private-acceptance.py"
)
NOW = "2099-01-01T12:00:00Z"
ACCEPTED_AT = "2099-01-01T11:55:00Z"
MODEL = "deepseek-ai/DeepSeek-V4.1-Flash"
IMAGE = "sha256:3863bf0f59bd4df4012b7b7aed8a7d2be6ef9b42ee3a5299d014f83a1f1ba6ea"
CHECKPOINT_REVISION = "dba1be0a40aa45a94ad051997016db3960a90277"
VLLM_COMMIT = "e77daef89e18e08321ae7b8b24827eedd5fe8673"
AIPERF_COMMIT = "ea28b2e81c7367f8403c6f6ebe0837a508795a8d"
AIPERF_WEKA_PATCH_SHA256 = (
    "9557a46afac031b64f66ea64ebac4e8ed4d1a0e142354388c19c086a9377a36e"
)
WEKA_REPOSITORY = "semianalysisai/cc-traces-weka-062126"
WEKA_REVISION = "23f152f6f0f9399a85901b89a6458def0ef16729"
SERVING_GENERATION = "deepseek-v41-accepted-generation"
LEGACY_SERVING_GENERATION = (
    "legacy-e11a1b895929ef85ea53d5014becaeeb7dee3099dbb578325cfc94aaf78d2cd1"
)
FIXTURE_CHECKPOINT_SHA256 = hashlib.sha256(b"checkpoint fixture\n").hexdigest()
EVIDENCE_EPOCH = time.mktime(
    time.strptime("2099-01-01T11:54:00Z", "%Y-%m-%dT%H:%M:%SZ")
)
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


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_private(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)


def mark_evidence_time(path: Path) -> None:
    os.utime(path, (EVIDENCE_EPOCH, EVIDENCE_EPOCH))


def build_fixture(base: Path) -> tuple[Path, Path]:
    run_root = base / "runs" / "20990101T000000Z"
    (run_root / "profiles").mkdir(parents=True)
    (run_root / "baseline").mkdir()
    (run_root / "aiperf" / "scored-summaries").mkdir(parents=True)
    (run_root / "logs").mkdir()

    manifest = run_root / "manifest.env"
    manifest.write_text(
        f"CHECKPOINT_REPO={MODEL}\n"
        f"CHECKPOINT_REVISION={CHECKPOINT_REVISION}\n"
        "CHECKPOINT_SHARDS=48\n"
        f"VLLM_COMMIT={VLLM_COMMIT}\n"
        f"VLLM_IMAGE_ID={IMAGE}\n"
        f"AIPERF_COMMIT={AIPERF_COMMIT}\n"
        f"WEKA_REPOSITORY={WEKA_REPOSITORY}\n"
        f"WEKA_REVISION={WEKA_REVISION}\n",
        encoding="utf-8",
    )
    os.chmod(manifest, 0o600)

    profile = run_root / "profiles" / "dspark-1m-noautotune-seqs4.env"
    profile.write_text(
        "PROFILE_NAME=dspark-1m-noautotune-seqs4\n"
        "MAX_MODEL_LEN=1048576\n"
        "MAX_NUM_SEQS=4\n"
        "GPU_MEMORY_UTILIZATION=0.90\n"
        "ENFORCE_EAGER=0\n"
        "ENABLE_PREFIX_CACHING=1\n"
        "MAX_NUM_BATCHED_TOKENS=16384\n"
        "ENABLE_EXPERT_PARALLEL=0\n"
        "SPECULATIVE_METHOD=dspark\n"
        "NUM_SPECULATIVE_TOKENS=5\n"
        "DRAFT_SAMPLE_METHOD=greedy\n"
        "REJECTION_SAMPLE_METHOD=standard\n"
        "ENABLE_FLASHINFER_AUTOTUNE=0\n",
        encoding="utf-8",
    )
    os.chmod(profile, 0o600)

    checkpoint = run_root / "baseline" / "shamu-checkpoint.manifest"
    checkpoint.write_text("checkpoint fixture\n", encoding="utf-8")
    os.chmod(checkpoint, 0o600)
    checkpoint_peer = run_root / "baseline" / "tilikum-checkpoint.manifest"
    checkpoint_peer.write_bytes(checkpoint.read_bytes())
    os.chmod(checkpoint_peer, 0o600)

    feature = run_root / "feature-dspark-1m-seqs4-final.json"
    feature_payload = {
        "schema_version": 1,
        "model": MODEL,
        "stage": "dspark",
        "ok": True,
        "failure_log_capture": {
            "requested": True,
            "captured": False,
            "ok": True,
            "path": str(run_root / "logs" / "feature-failure-server.log"),
            "nodes": ["shamu", "tilikum"],
            "container": "deepseek-v41-flash-tp2",
        },
        "cases": [
            {
                "case": name,
                "status": {
                    "malformed-input": 400,
                    "wrong-model": 404,
                }.get(name, 200),
                "semantic_ok": True,
                "error": None,
                "repetitions": 3 if name == "deterministic-text" else 1,
                "distinct_normalized_outputs": 1,
                **(
                    {
                        "client_disconnected": True,
                        "queue_drained": True,
                        "queue_baseline": {"running": 0.0, "waiting": 0.0},
                        "queue_final": {"running": 0.0, "waiting": 0.0},
                    }
                    if name == "disconnect-queue-drain"
                    else {}
                ),
            }
            for name in sorted(FEATURE_CASES)
        ],
    }
    write_private(feature, feature_payload)

    long_context = run_root / "long-context-dspark-1m-seqs4-final.json"
    targets = [320000, 600000, 990016, 996579]
    write_private(
        long_context,
        {
            "schema_version": 1,
            "model": MODEL,
            "max_model_len": 1048576,
            "ok": True,
            "accepted": [
                {
                    "target_context_tokens": target,
                    "server_total_tokens": target,
                    "status": 200,
                    "semantic_ok": True,
                    "token_count_exact": True,
                    **(
                        {
                            "expected_prompt_tokens": 319999,
                            "server_prompt_tokens": 319999,
                            "server_completion_tokens": 1,
                            "latency_seconds": 21.266248,
                        }
                        if target == 320000
                        else {}
                    ),
                }
                for target in targets
            ],
            "over_limit": {
                "target_context_tokens": 1048577,
                "status": 400,
                "semantic_ok": True,
                "token_count_exact": True,
            },
            "tokenizer_calibration": {
                "reported_max_model_len": 1048576,
                "exact_linear_unit": True,
            },
        },
    )

    weka = run_root / "aiperf" / "scored-summaries" / "seqs4.json"
    weka_payload = {
        "schema_version": 1,
        "qualified": True,
        "requests": 396,
        "completed": 396,
        "errors": 0,
        "server_success_rate": 1.0,
        "request_throughput": 0.44,
        "output_token_throughput": 202.0287585576069,
        "ttft_p90_ms": 1067.0,
        "request_peak_concurrency": 3,
        "preemptions_total": 0.0,
        "waiting_requests_max": 0.0,
        "kv_cache_usage_max": 0.02,
        "prefix_cache_hits": 100.0,
        "prefix_cache_queries": 110.0,
        "prefix_cache_hit_ratio": 100.0 / 110.0,
        "running_requests_max": 3.0,
        "wall_power_avg_watts": 1477.4115518641565,
        "facility_power_avg_watts": 1477.4115518641565,
        "facility_energy_kwh": 0.37,
        "facility_cost_dollars": 0.17,
        "completed_root_workflows": 3,
        "cancelled_root_workflows": 0,
        "root_workflow_elapsed_seconds": 900.0,
        "completed_root_workflows_per_second": 3.0 / 900.0,
        "input_cost_per_token": 1.3e-8,
        "output_cost_per_token": 9.6e-7,
        "engine_deaths": 0,
        "nccl_timeouts": 0,
        "corruption_flags": 0,
    }
    write_private(weka, weka_payload)

    pricing = run_root / "pricing-evidence.json"
    pricing_payload = {
        "schema_version": 1,
        "model": MODEL,
        "serving_generation": SERVING_GENERATION,
        "electricity_rate_usd_per_kwh": 0.47,
        "facility_power_watts": 1477.4115518641565,
        "input": {
            "basis": "cold-prefill",
            "prompt_tokens": 319999,
            "elapsed_seconds": 21.266248,
            "throughput_tokens_per_second": 15047.271150040195,
            "direct_energy_cost_per_token": 1.2818555870663976e-8,
            "published_cost_per_token": 1.3e-8,
        },
        "output": {
            "basis": "selected-weka-profile",
            "throughput_tokens_per_second": 202.0287585576069,
            "direct_energy_cost_per_token": 9.547367776495098e-7,
            "published_cost_per_token": 9.6e-7,
        },
    }
    write_private(pricing, pricing_payload)

    rederived_weka = {
        key: value
        for key, value in weka_payload.items()
        if key
        not in {
            "input_cost_per_token",
            "output_cost_per_token",
            "engine_deaths",
            "nccl_timeouts",
            "corruption_flags",
        }
    }
    rederived_weka.update(
        {
            "error_types": {},
            "root_session_trees": 3,
            "request_count_by_agent_depth": {"0": 396},
        }
    )

    def metric_series(
        metric_type: str,
        stat: str,
        value: float,
        *,
        labels: dict[str, str] | None = None,
    ) -> dict[str, object]:
        return {
            "type": metric_type,
            "series": [
                {
                    "endpoint_url": "http://fixture/metrics",
                    "labels": labels or {},
                    "stats": {stat: value},
                }
            ],
        }

    server_metrics = {
        "metrics": {
            "vllm:prefix_cache_hits": metric_series("counter", "total", 100.0),
            "vllm:prefix_cache_queries": metric_series("counter", "total", 110.0),
            "vllm:kv_cache_usage_perc": metric_series("gauge", "max", 0.02),
            "vllm:num_preemptions": metric_series("counter", "total", 0.0),
            "vllm:num_requests_running": metric_series("gauge", "max", 3.0),
            "vllm:num_requests_waiting": metric_series("gauge", "max", 0.0),
            "power_total_watts": {
                "type": "gauge",
                "series": [
                    {
                        "endpoint_url": "http://fixture/metrics",
                        "labels": {"scope": scope},
                        "stats": {"avg": 1477.4115518641565},
                    }
                    for scope in ("wall", "facility")
                ],
            },
            "power_energy_kwh": metric_series(
                "counter", "total", 0.37, labels={"scope": "facility"}
            ),
            "power_cost_dollars": metric_series("counter", "total", 0.17),
        }
    }

    weka_repetitions = []
    warmup_provenance_sha256: str | None = None
    for repetition in (1, 2):
        repetition_dir = (
            run_root
            / "aiperf"
            / f"dspark-1m-noautotune-seqs4-c4-r{repetition}-open"
        )
        repetition_dir.mkdir()
        artifacts = {
            "EXIT": "EXIT=0\n",
            ".aiperf_results_ready.json": json.dumps(
                {
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                    "failed_exporters": [],
                },
                sort_keys=True,
            )
            + "\n",
            "profile_export.jsonl": "".join(
                json.dumps(
                    {
                        "status": 200,
                        "error": None,
                        "output": "OK",
                        "metadata": {
                            "request_start_ns": index,
                            "request_end_ns": index + 3,
                            "agent_depth": 0,
                            "root_correlation_id": f"root-{index % 3}",
                        },
                        "metrics": {},
                    },
                    sort_keys=True,
                )
                + "\n"
                for index in range(396)
            ),
            "profile_export_aiperf.json": json.dumps(
                {
                    "request_throughput": {"avg": 0.44},
                    "time_to_first_token": {"p90": 1067.0},
                    "output_token_throughput": {"avg": 202.0287585576069},
                },
                sort_keys=True,
            )
            + "\n",
            "server_metrics_export.json": json.dumps(server_metrics, sort_keys=True)
            + "\n",
            "aiperf.stdout.log": (
                "05:31:54.473 NOTICE Phase profiling (profiling) complete | "
                "completed=396, cancelled=0, errors=0 | sessions: completed=3, "
                "cancelled=0 | elapsed=900.00s (runner.py:1227)\n"
            ),
            "aiperf.stderr.log": "",
            "rendered-command.txt": "aiperf profile --config aiperf-config.yaml\n",
            "summary.json": json.dumps(rederived_weka, sort_keys=True) + "\n",
            "benchmark-window.json": json.dumps(
                {
                    "started_at": "2099-01-01T11:30:00Z",
                    "ended_at": "2099-01-01T11:45:00Z",
                },
                sort_keys=True,
            )
            + "\n",
            "rank0-before.json": json.dumps(
                {
                    "container_id": "0" * 64,
                    "generation": SERVING_GENERATION,
                    "image": IMAGE,
                    "restart_count": 0,
                    "started_at": "2099-01-01T00:00:00Z",
                },
                sort_keys=True,
            )
            + "\n",
            "rank1-before.json": json.dumps(
                {
                    "container_id": "1" * 64,
                    "generation": SERVING_GENERATION,
                    "image": IMAGE,
                    "restart_count": 0,
                    "started_at": "2099-01-01T00:00:01Z",
                },
                sort_keys=True,
            )
            + "\n",
            "rank0-after.json": json.dumps(
                {
                    "container_id": "0" * 64,
                    "generation": SERVING_GENERATION,
                    "image": IMAGE,
                    "restart_count": 0,
                    "started_at": "2099-01-01T00:00:00Z",
                },
                sort_keys=True,
            )
            + "\n",
            "rank1-after.json": json.dumps(
                {
                    "container_id": "1" * 64,
                    "generation": SERVING_GENERATION,
                    "image": IMAGE,
                    "restart_count": 0,
                    "started_at": "2099-01-01T00:00:01Z",
                },
                sort_keys=True,
            )
            + "\n",
            "rank0-container.log": "healthy rank 0\n",
            "rank1-container.log": "healthy rank 1\n",
        }
        for name, content in artifacts.items():
            path = repetition_dir / name
            path.write_text(content, encoding="utf-8")
            os.chmod(path, 0o600)
        provenance = repetition_dir / "provenance.json"
        write_private(
            provenance,
            {
                "schema_version": 1,
                "profile_name": "dspark-1m-noautotune-seqs4",
                "concurrency": 4,
                "repetition": repetition,
                "cache_state": "warmup" if repetition == 1 else "warm",
                "warmup_and_scored_comparable": repetition == 2,
                "warmup_provenance_sha256": (
                    warmup_provenance_sha256 if repetition == 2 else None
                ),
                "aiperf_commit": AIPERF_COMMIT,
                "aiperf_weka_patch_sha256": AIPERF_WEKA_PATCH_SHA256,
                "weka_repository": WEKA_REPOSITORY,
                "weka_revision": WEKA_REVISION,
                "trace_count": 393,
                "full_subagents": True,
                "serving_generation": SERVING_GENERATION,
                "engine_deaths": 0,
                "nccl_timeouts": 0,
                "corruption_flags": 0,
                "rank_fatal_error_matches": 0,
                "artifacts": {
                    name: sha256(repetition_dir / name) for name in artifacts
                },
            },
        )
        weka_repetitions.append(
            {"path": str(provenance), "sha256": sha256(provenance)}
        )
        if repetition == 1:
            warmup_provenance_sha256 = sha256(provenance)

    serving_args = [
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
    rank0 = run_root / "logs" / "private-acceptance-shamu.log"
    rank0.write_text(
        f"running=true restart=0 image={IMAGE} args="
        + json.dumps(
            serving_args
            + [
                "--node-rank",
                "0",
                "--host",
                "100.73.140.127",
                "--port",
                "8000",
            ],
            separators=(",", ":"),
        )
        + "\n"
        f"generation={SERVING_GENERATION}\n"
        "serving_key_vars=1\nhealth=pass\n"
        "LISTEN 0 2048 100.73.140.127:8000 0.0.0.0:*\n"
        "GPU KV cache size: 26,028,861 tokens, Maximum concurrency for "
        "1,048,576 tokens per request: 24.82x\n",
        encoding="utf-8",
    )
    os.chmod(rank0, 0o600)
    rank1 = run_root / "logs" / "private-acceptance-tilikum.log"
    rank1.write_text(
        f"running=true restart=0 image={IMAGE} args="
        + json.dumps(
            serving_args + ["--node-rank", "1", "--headless"],
            separators=(",", ":"),
        )
        + "\n"
        f"generation={SERVING_GENERATION}\n"
        "serving_key_vars=0\nlistener=none\nfatal_error_matches=0\n",
        encoding="utf-8",
    )
    os.chmod(rank1, 0o600)
    api = run_root / "logs" / "private-acceptance-api.log"
    api.write_text(
        json.dumps(
            {
                "status": 200,
                "missing_key_status": 401,
                "wrong_key_status": 401,
                "correct_key_status": 200,
                "model": MODEL,
                "has_content": True,
                "finish_reason": "stop",
                "serving_generation": SERVING_GENERATION,
            }
        )
        + "\n",
        encoding="utf-8",
    )
    os.chmod(api, 0o600)
    for evidence in (
        feature,
        long_context,
        weka,
        rank0,
        rank1,
        api,
        pricing,
        *(Path(item["path"]) for item in weka_repetitions),
    ):
        mark_evidence_time(evidence)

    acceptance = run_root / "private-acceptance.json"
    write_private(
        acceptance,
        {
            "schema_version": 1,
            "accepted_at": ACCEPTED_AT,
            "decision": "GO",
            "model": MODEL,
            "public_model_name": "deepseek-v4.1-flash",
            "selected_profile": {
                "name": "dspark-1m-noautotune-seqs4",
                "path": str(profile),
                "sha256": sha256(profile),
                "max_model_len": 1048576,
                "max_num_seqs": 4,
                "speculative_method": "dspark",
                "flashinfer_autotune": False,
            },
            "runtime": {
                "checkpoint_revision": CHECKPOINT_REVISION,
                "checkpoint_manifest_sha256": sha256(checkpoint),
                "vllm_commit": VLLM_COMMIT,
                "image_id": IMAGE,
                "manifest_path": str(manifest),
                "manifest_sha256": sha256(manifest),
            },
            "topology": {
                "tensor_parallel_size": 2,
                "pipeline_parallel_size": 1,
                "rank_0": "shamu",
                "rank_1": "tilikum",
                "rank_1_headless_and_keyless": True,
            },
            "feature_qualification": {
                "path": str(feature),
                "sha256": sha256(feature),
                "ok": True,
                "passed": len(FEATURE_CASES),
                "total": len(FEATURE_CASES),
            },
            "long_context_qualification": {
                "path": str(long_context),
                "sha256": sha256(long_context),
                "ok": True,
                "accepted_context_totals": targets,
                "rejected_context_total": 1048577,
            },
            "weka_qualification": {
                "path": str(weka),
                "sha256": sha256(weka),
                "qualified": True,
                "repetitions": weka_repetitions,
                **{
                    name: weka_payload[name]
                    for name in (
                        "requests",
                        "errors",
                        "server_success_rate",
                        "request_throughput",
                        "output_token_throughput",
                        "ttft_p90_ms",
                        "request_peak_concurrency",
                        "preemptions_total",
                    )
                },
            },
            "live_state": {
                "restart_counts_zero": True,
                "fatal_error_matches": 0,
                "kv_cache_tokens": 26028861,
                "full_context_concurrency": 24.82,
                "rank_0_evidence": {"path": str(rank0), "sha256": sha256(rank0)},
                "rank_1_evidence": {"path": str(rank1), "sha256": sha256(rank1)},
                "api_evidence": {"path": str(api), "sha256": sha256(api)},
                "serving_generation": SERVING_GENERATION,
            },
            "selection": {
                "pp2_triggered": False,
                "pp2_reason": "TP2/PP1 passed the qualification gates",
                "seqs_8_request_throughput_gain_percent": 0.89,
                "reason": "seqs=4 retains KV headroom within the throughput tolerance",
            },
            "pricing_evidence": {
                "path": str(pricing),
                "sha256": sha256(pricing),
            },
            "publication": {
                "public_model_name": "deepseek-v4.1-flash",
                "served_model_name": MODEL,
                "max_context": 1048576,
                "station_endpoint": "http://100.73.140.127:8000/v1",
                "supports_function_calling": True,
                "supports_reasoning": True,
                "supports_response_schema": True,
                "supports_vision": True,
                "input_cost_per_token": 1.3e-8,
                "output_cost_per_token": 9.6e-7,
            },
        },
    )
    return run_root, acceptance


def verify(run_root: Path, acceptance: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(VERIFIER),
            "--run-root",
            str(run_root),
            "--acceptance",
            str(acceptance),
            "--now",
            NOW,
            "--max-age-seconds",
            "21600",
        ],
        cwd=REPOSITORY_ROOT,
        text=True,
        capture_output=True,
        check=False,
        env={
            **os.environ,
            "WEBSTER_ACCEPTANCE_TEST_MODE": "1",
            "TEST_CHECKPOINT_MANIFEST_SHA256": FIXTURE_CHECKPOINT_SHA256,
        },
    )


class PrivateAcceptanceTests(unittest.TestCase):
    def test_generator_builds_a_validator_accepted_manifest_last(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            original = json.loads(acceptance.read_text(encoding="utf-8"))
            acceptance.unlink()
            evidence = original["live_state"]
            current_epoch = time.time()
            for item in evidence.values():
                if isinstance(item, dict) and "path" in item:
                    os.utime(item["path"], (current_epoch, current_epoch))
            for section in (
                "feature_qualification",
                "long_context_qualification",
                "weka_qualification",
            ):
                os.utime(
                    original[section]["path"], (current_epoch, current_epoch)
                )
            for item in original["weka_qualification"]["repetitions"]:
                os.utime(item["path"], (current_epoch, current_epoch))
            os.utime(
                original["pricing_evidence"]["path"],
                (current_epoch, current_epoch),
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(GENERATOR),
                    "--run-root",
                    str(run_root),
                    "--rank-0-evidence",
                    evidence["rank_0_evidence"]["path"],
                    "--rank-1-evidence",
                    evidence["rank_1_evidence"]["path"],
                    "--api-evidence",
                    evidence["api_evidence"]["path"],
                    "--seqs-8-request-throughput-gain-percent",
                    "0.89",
                    "--selection-reason",
                    original["selection"]["reason"],
                    "--pp2-reason",
                    original["selection"]["pp2_reason"],
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
                env={
                    **os.environ,
                    "WEBSTER_ACCEPTANCE_TEST_MODE": "1",
                    "TEST_CHECKPOINT_MANIFEST_SHA256": FIXTURE_CHECKPOINT_SHA256,
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            generated = json.loads(acceptance.read_text(encoding="utf-8"))
            self.assertEqual(acceptance.stat().st_mode & 0o777, 0o600)
            self.assertEqual(generated["feature_qualification"]["total"], 17)
            self.assertEqual(generated["live_state"]["kv_cache_tokens"], 26028861)
            self.assertEqual(generated["live_state"]["full_context_concurrency"], 24.82)
            accepted_at = time.mktime(
                time.strptime(generated["accepted_at"], "%Y-%m-%dT%H:%M:%SZ")
            )
            self.assertGreaterEqual(accepted_at + 5, max(
                Path(item["path"]).stat().st_mtime
                for item in evidence.values()
                if isinstance(item, dict) and "path" in item
            ))

    def test_complete_private_acceptance_is_valid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            result = verify(run_root, acceptance)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_unlabeled_legacy_weka_rank_states_use_the_derived_pair_generation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))

            warmup_hash = None
            for repetition in payload["weka_qualification"]["repetitions"]:
                provenance_path = Path(repetition["path"])
                provenance = json.loads(
                    provenance_path.read_text(encoding="utf-8")
                )
                for rank in (0, 1):
                    for phase in ("before", "after"):
                        name = f"rank{rank}-{phase}.json"
                        state_path = provenance_path.parent / name
                        state = json.loads(state_path.read_text(encoding="utf-8"))
                        self.assertEqual(state["generation"], SERVING_GENERATION)
                        state["generation"] = None
                        write_private(state_path, state)
                        provenance["artifacts"][name] = sha256(state_path)
                provenance["serving_generation"] = LEGACY_SERVING_GENERATION
                if provenance["repetition"] == 2:
                    provenance["warmup_provenance_sha256"] = warmup_hash
                write_private(provenance_path, provenance)
                mark_evidence_time(provenance_path)
                repetition["sha256"] = sha256(provenance_path)
                if provenance["repetition"] == 1:
                    warmup_hash = repetition["sha256"]

            live = payload["live_state"]
            live["serving_generation"] = LEGACY_SERVING_GENERATION
            for key in ("rank_0_evidence", "rank_1_evidence"):
                item = live[key]
                path = Path(item["path"])
                text = path.read_text(encoding="utf-8").replace(
                    f"generation={SERVING_GENERATION}",
                    f"generation={LEGACY_SERVING_GENERATION}",
                )
                path.write_text(text, encoding="utf-8")
                os.chmod(path, 0o600)
                mark_evidence_time(path)
                item["sha256"] = sha256(path)

            api_item = live["api_evidence"]
            api_path = Path(api_item["path"])
            api = json.loads(api_path.read_text(encoding="utf-8"))
            api["serving_generation"] = LEGACY_SERVING_GENERATION
            write_private(api_path, api)
            mark_evidence_time(api_path)
            api_item["sha256"] = sha256(api_path)

            pricing_item = payload["pricing_evidence"]
            pricing_path = Path(pricing_item["path"])
            pricing = json.loads(pricing_path.read_text(encoding="utf-8"))
            pricing["serving_generation"] = LEGACY_SERVING_GENERATION
            write_private(pricing_path, pricing)
            mark_evidence_time(pricing_path)
            pricing_item["sha256"] = sha256(pricing_path)
            write_private(acceptance, payload)

            result = verify(run_root, acceptance)

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_pricing_does_not_require_cost_fields_in_weka_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))
            item = payload["weka_qualification"]
            path = Path(item["path"])
            weka = json.loads(path.read_text(encoding="utf-8"))
            weka.pop("input_cost_per_token")
            weka.pop("output_cost_per_token")
            write_private(path, weka)
            mark_evidence_time(path)
            item["sha256"] = sha256(path)
            write_private(acceptance, payload)

            result = verify(run_root, acceptance)

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_pricing_accepts_a_fresh_remeasured_cold_prefill(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))

            context_item = payload["long_context_qualification"]
            context_path = Path(context_item["path"])
            context = json.loads(context_path.read_text(encoding="utf-8"))
            context["accepted"][0]["latency_seconds"] = 20.907312
            write_private(context_path, context)
            mark_evidence_time(context_path)
            context_item["sha256"] = sha256(context_path)

            pricing_item = payload["pricing_evidence"]
            pricing_path = Path(pricing_item["path"])
            pricing = json.loads(pricing_path.read_text(encoding="utf-8"))
            pricing["input"]["elapsed_seconds"] = 20.907312
            pricing["input"]["throughput_tokens_per_second"] = 15305.602174014526
            pricing["input"]["direct_energy_cost_per_token"] = (
                1.2602201713127931e-8
            )
            write_private(pricing_path, pricing)
            mark_evidence_time(pricing_path)
            pricing_item["sha256"] = sha256(pricing_path)
            write_private(acceptance, payload)

            result = verify(run_root, acceptance)

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_live_rank_arguments_must_match_the_selected_profile_exactly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))
            item = payload["live_state"]["rank_0_evidence"]
            path = Path(item["path"])
            evidence = path.read_text(encoding="utf-8").replace(
                '"--max-num-batched-tokens","16384"',
                '"--max-num-batched-tokens","8192"',
            )
            self.assertNotEqual(evidence, path.read_text(encoding="utf-8"))
            path.write_text(evidence, encoding="utf-8")
            os.chmod(path, 0o600)
            mark_evidence_time(path)
            item["sha256"] = sha256(path)
            write_private(acceptance, payload)

            result = verify(run_root, acceptance)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("serving arguments", result.stderr)

    def test_malformed_private_acceptance_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            acceptance.write_text("{not-json\n", encoding="utf-8")
            result = verify(run_root, acceptance)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("malformed", result.stderr)

    def test_private_acceptance_must_be_mode_0600(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            os.chmod(acceptance, 0o644)
            result = verify(run_root, acceptance)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mode 0600", result.stderr)

    def test_stale_private_acceptance_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))
            payload["accepted_at"] = "2099-01-01T00:00:00Z"
            write_private(acceptance, payload)
            result = verify(run_root, acceptance)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stale", result.stderr)

    def test_every_decision_artifact_requires_both_freshness_bounds(self) -> None:
        for relation, epoch, expected in (
            ("too old", "2099-01-01T05:54:59Z", "stale"),
            ("future", "2099-01-01T11:55:06Z", "future"),
        ):
            for section in (
                "feature_qualification",
                "long_context_qualification",
                "weka_qualification",
            ):
                with self.subTest(relation=relation, section=section), tempfile.TemporaryDirectory() as temporary:
                    run_root, acceptance = build_fixture(Path(temporary))
                    payload = json.loads(acceptance.read_text(encoding="utf-8"))
                    path = Path(payload[section]["path"])
                    timestamp = time.mktime(time.strptime(epoch, "%Y-%m-%dT%H:%M:%SZ"))
                    os.utime(path, (timestamp, timestamp))
                    result = verify(run_root, acceptance)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, result.stderr)

    def test_future_acceptance_cannot_extend_evidence_clock_skew(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))
            payload["accepted_at"] = "2099-01-01T12:00:05Z"
            feature = Path(payload["feature_qualification"]["path"])
            future = time.mktime(
                time.strptime("2099-01-01T12:00:10Z", "%Y-%m-%dT%H:%M:%SZ")
            )
            os.utime(feature, (future, future))
            write_private(acceptance, payload)

            result = verify(run_root, acceptance)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("future", result.stderr)

    def test_weka_publication_requires_two_complete_pinned_raw_repetitions(self) -> None:
        mutations = (
            ("both repetitions", lambda root, value: value["weka_qualification"].pop("repetitions")),
            (
                "393-trace",
                lambda root, value: self._mutate_weka_provenance(
                    value, 0, "trace_count", 392
                ),
            ),
            (
                "raw artifact",
                lambda root, value: (
                    Path(value["weka_qualification"]["repetitions"][0]["path"]).parent
                    / "profile_export.jsonl"
                ).unlink(),
            ),
            (
                "serving generation",
                lambda root, value: self._mutate_weka_provenance(
                    value, 1, "serving_generation", "other-generation"
                ),
            ),
        )
        for expected, mutate in mutations:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as temporary:
                run_root, acceptance = build_fixture(Path(temporary))
                payload = json.loads(acceptance.read_text(encoding="utf-8"))
                mutate(run_root, payload)
                write_private(acceptance, payload)
                result = verify(run_root, acceptance)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_weka_publication_requires_exact_aiperf_runtime_patch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))
            self._mutate_weka_provenance(
                payload,
                1,
                "aiperf_weka_patch_sha256",
                "0" * 64,
            )
            write_private(acceptance, payload)

            result = verify(run_root, acceptance)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("runtime patch", result.stderr)

    def test_weka_publication_rederives_request_success_from_raw_records(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))
            item = payload["weka_qualification"]["repetitions"][0]
            provenance_path = Path(item["path"])
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            records = provenance_path.parent / "profile_export.jsonl"
            write_private(
                records,
                {"status": 500, "error": "server failed", "corruption": False},
            )
            provenance["artifacts"]["profile_export.jsonl"] = sha256(records)
            write_private(provenance_path, provenance)
            mark_evidence_time(provenance_path)
            item["sha256"] = sha256(provenance_path)
            write_private(acceptance, payload)

            result = verify(run_root, acceptance)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("raw records contain failed requests", result.stderr)

    def test_weka_publication_requires_hashed_paired_rank_logs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))
            provenance_path = Path(
                payload["weka_qualification"]["repetitions"][0]["path"]
            )
            (provenance_path.parent / "rank1-container.log").unlink()

            result = verify(run_root, acceptance)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("rank log", result.stderr)

    def test_weka_publication_matches_selected_score_to_rederived_repetition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))
            item = payload["weka_qualification"]
            scored_path = Path(item["path"])
            scored = json.loads(scored_path.read_text(encoding="utf-8"))
            scored["request_throughput"] = 99.0
            write_private(scored_path, scored)
            mark_evidence_time(scored_path)
            item["request_throughput"] = 99.0
            item["sha256"] = sha256(scored_path)
            write_private(acceptance, payload)

            result = verify(run_root, acceptance)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("rederived repetition 2", result.stderr)

    def test_weka_scored_repetition_is_bound_to_warmup_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))
            item = payload["weka_qualification"]["repetitions"][1]
            provenance_path = Path(item["path"])
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["warmup_provenance_sha256"] = "0" * 64
            write_private(provenance_path, provenance)
            mark_evidence_time(provenance_path)
            item["sha256"] = sha256(provenance_path)
            write_private(acceptance, payload)

            result = verify(run_root, acceptance)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("warmup provenance", result.stderr)

    def test_station_auth_evidence_requires_missing_wrong_and_correct_key_proofs(self) -> None:
        for field, value in (
            ("missing_key_status", None),
            ("wrong_key_status", 200),
            ("correct_key_status", 401),
            ("serving_generation", "other-generation"),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                run_root, acceptance = build_fixture(Path(temporary))
                payload = json.loads(acceptance.read_text(encoding="utf-8"))
                item = payload["live_state"]["api_evidence"]
                path = Path(item["path"])
                api = json.loads(path.read_text(encoding="utf-8"))
                if value is None:
                    api.pop(field)
                else:
                    api[field] = value
                write_private(path, api)
                mark_evidence_time(path)
                item["sha256"] = sha256(path)
                write_private(acceptance, payload)
                result = verify(run_root, acceptance)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("auth", result.stderr.lower())

    def test_pricing_publication_requires_fresh_hashed_generation_bound_evidence(self) -> None:
        def mutate_hash(root: Path, payload: dict[str, object]) -> None:
            payload["pricing_evidence"]["sha256"] = "0" * 64

        def mutate_value(root: Path, payload: dict[str, object]) -> None:
            item = payload["pricing_evidence"]
            path = Path(item["path"])
            pricing = json.loads(path.read_text(encoding="utf-8"))
            pricing["input"]["published_cost_per_token"] = 1.4e-8
            write_private(path, pricing)
            mark_evidence_time(path)
            item["sha256"] = sha256(path)

        def mutate_stale(root: Path, payload: dict[str, object]) -> None:
            path = Path(payload["pricing_evidence"]["path"])
            stale = time.mktime(
                time.strptime("2099-01-01T05:54:59Z", "%Y-%m-%dT%H:%M:%SZ")
            )
            os.utime(path, (stale, stale))

        def mutate_generation(root: Path, payload: dict[str, object]) -> None:
            item = payload["pricing_evidence"]
            path = Path(item["path"])
            pricing = json.loads(path.read_text(encoding="utf-8"))
            pricing["serving_generation"] = "other-generation"
            write_private(path, pricing)
            mark_evidence_time(path)
            item["sha256"] = sha256(path)

        mutations = (
            ("absent", lambda root, payload: (root / "pricing-evidence.json").unlink()),
            ("hash", mutate_hash),
            ("value", mutate_value),
            ("stale", mutate_stale),
            ("generation", mutate_generation),
        )
        for expected, mutate in mutations:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as temporary:
                run_root, acceptance = build_fixture(Path(temporary))
                payload = json.loads(acceptance.read_text(encoding="utf-8"))
                mutate(run_root, payload)
                write_private(acceptance, payload)

                result = verify(run_root, acceptance)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr.lower())

    @staticmethod
    def _mutate_weka_provenance(
        acceptance: dict[str, object], repetition: int, field: str, value: object
    ) -> None:
        item = acceptance["weka_qualification"]["repetitions"][repetition]
        path = Path(item["path"])
        provenance = json.loads(path.read_text(encoding="utf-8"))
        provenance[field] = value
        write_private(path, provenance)
        mark_evidence_time(path)
        item["sha256"] = sha256(path)

    def test_wrong_profile_and_image_are_rejected(self) -> None:
        for field, value, expected in (
            (("selected_profile", "max_num_seqs"), 8, "selected profile"),
            (("runtime", "image_id"), "sha256:" + "b" * 64, "image"),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                run_root, acceptance = build_fixture(Path(temporary))
                payload = json.loads(acceptance.read_text(encoding="utf-8"))
                payload[field[0]][field[1]] = value
                write_private(acceptance, payload)
                result = verify(run_root, acceptance)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_wrong_context_capability_hash_and_rank_identity_are_rejected(self) -> None:
        mutations = (
            ("context", lambda payload: payload["long_context_qualification"].update(accepted_context_totals=[320000])),
            ("capability", lambda payload: payload["feature_qualification"].update(passed=9)),
            ("hash", lambda payload: payload["weka_qualification"].update(sha256="0" * 64)),
            (
                "rank identity",
                lambda payload: payload["topology"].update(rank_0="tilikum"),
            ),
        )
        for expected, mutate in mutations:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as temporary:
                run_root, acceptance = build_fixture(Path(temporary))
                payload = json.loads(acceptance.read_text(encoding="utf-8"))
                mutate(payload)
                write_private(acceptance, payload)
                result = verify(run_root, acceptance)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_missing_expanded_capability_case_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))
            feature_path = Path(payload["feature_qualification"]["path"])
            feature = json.loads(feature_path.read_text(encoding="utf-8"))
            feature["cases"] = [
                case
                for case in feature["cases"]
                if case["case"] != "tool-parallel"
            ]
            write_private(feature_path, feature)
            mark_evidence_time(feature_path)
            payload["feature_qualification"].update(
                sha256=sha256(feature_path),
                passed=len(feature["cases"]),
                total=len(feature["cases"]),
            )
            write_private(acceptance, payload)
            result = verify(run_root, acceptance)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing required cases", result.stderr)

    def test_runtime_evidence_cannot_repin_known_immutable_artifacts(self) -> None:
        mutations = ("image", "vLLM commit", "checkpoint manifest")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                run_root, acceptance = build_fixture(Path(temporary))
                payload = json.loads(acceptance.read_text(encoding="utf-8"))
                manifest_path = Path(payload["runtime"]["manifest_path"])
                manifest = manifest_path.read_text(encoding="utf-8")
                if mutation == "image":
                    replacement = "sha256:" + "b" * 64
                    payload["runtime"]["image_id"] = replacement
                    manifest = manifest.replace(IMAGE, replacement)
                    for key in ("rank_0_evidence", "rank_1_evidence"):
                        item = payload["live_state"][key]
                        path = Path(item["path"])
                        path.write_text(
                            path.read_text(encoding="utf-8").replace(IMAGE, replacement),
                            encoding="utf-8",
                        )
                        os.chmod(path, 0o600)
                        mark_evidence_time(path)
                        item["sha256"] = sha256(path)
                elif mutation == "vLLM commit":
                    replacement = "f" * 40
                    payload["runtime"]["vllm_commit"] = replacement
                    manifest = manifest.replace(VLLM_COMMIT, replacement)
                else:
                    checkpoint = run_root / "baseline" / "shamu-checkpoint.manifest"
                    peer = run_root / "baseline" / "tilikum-checkpoint.manifest"
                    checkpoint.write_text("different checkpoint fixture\n", encoding="utf-8")
                    peer.write_bytes(checkpoint.read_bytes())
                    os.chmod(checkpoint, 0o600)
                    os.chmod(peer, 0o600)
                    payload["runtime"]["checkpoint_manifest_sha256"] = sha256(checkpoint)
                manifest_path.write_text(manifest, encoding="utf-8")
                os.chmod(manifest_path, 0o600)
                payload["runtime"]["manifest_sha256"] = sha256(manifest_path)
                write_private(acceptance, payload)
                result = verify(run_root, acceptance)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(mutation, result.stderr)

    def test_profile_selection_measurement_is_pinned(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_root, acceptance = build_fixture(Path(temporary))
            payload = json.loads(acceptance.read_text(encoding="utf-8"))
            payload["selection"]["seqs_8_request_throughput_gain_percent"] = 42.0
            write_private(acceptance, payload)
            result = verify(run_root, acceptance)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("selection", result.stderr)


if __name__ == "__main__":
    unittest.main()
