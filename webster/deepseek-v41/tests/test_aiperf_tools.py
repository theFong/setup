#!/usr/bin/env python3
"""Behavior tests for cache-controlled Weka result summarization."""

from __future__ import annotations

import json
import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
PACKAGE_ROOT = REPOSITORY_ROOT / "webster" / "deepseek-v41"
SUMMARIZER = PACKAGE_ROOT / "scripts" / "summarize-aiperf.py"
RUNNER = PACKAGE_ROOT / "scripts" / "run-weka.sh"
PATCHER = PACKAGE_ROOT / "scripts" / "patch-aiperf-weka-timing.py"
CORPUS_VERIFIER = PACKAGE_ROOT / "scripts" / "verify-weka-corpus.py"
CORPUS_BUILDER = PACKAGE_ROOT / "scripts" / "build-weka-corpus-manifest.py"
FIXTURES = PACKAGE_ROOT / "tests" / "fixtures"


def write_valid_runner_exports(
    directory: Path,
    *,
    readiness: object | None = None,
    readiness_raw: str | None = None,
    record_error: bool = False,
    missing_server_metric: str | None = None,
) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    if readiness_raw is not None:
        (directory / ".aiperf_results_ready.json").write_text(
            readiness_raw, encoding="utf-8"
        )
    elif readiness is not None:
        (directory / ".aiperf_results_ready.json").write_text(
            json.dumps(readiness) + "\n", encoding="utf-8"
        )

    (directory / "profile_export_aiperf.json").write_text(
        json.dumps(
            {
                "request_throughput": {"unit": "requests/sec", "avg": 1.0},
                "time_to_first_token": {"unit": "ms", "p90": 25.0},
                "output_token_throughput": {"unit": "tokens/sec", "avg": 8.0},
            }
        )
        + "\n",
        encoding="utf-8",
    )
    record: dict[str, object] = {
        "metadata": {
            "request_start_ns": 100,
            "request_end_ns": 200,
            "agent_depth": 0,
            "root_correlation_id": "root-1",
        },
        "metrics": {},
    }
    if record_error:
        record["error"] = {"type": "EngineDeadError"}
    (directory / "profile_export.jsonl").write_text(
        json.dumps(record) + "\n", encoding="utf-8"
    )

    def series(
        metric_type: str,
        value_name: str,
        value: float,
        *,
        endpoint: str = "http://100.73.140.127:8000/metrics",
        labels: dict[str, str] | None = None,
    ) -> dict[str, object]:
        return {
            "type": metric_type,
            "series": [
                {
                    "endpoint_url": endpoint,
                    "labels": labels or {},
                    "stats": {value_name: value},
                }
            ],
        }

    metrics = {
        "vllm:prefix_cache_hits": series("counter", "total", 8.0),
        "vllm:prefix_cache_queries": series("counter", "total", 10.0),
        "vllm:kv_cache_usage_perc": series("gauge", "max", 0.5),
        "vllm:num_preemptions": series("counter", "total", 0.0),
        "vllm:num_requests_running": series("gauge", "max", 1.0),
        "vllm:num_requests_waiting": series("gauge", "max", 0.0),
        "power_total_watts": {
            "type": "gauge",
            "series": [
                {
                    "endpoint_url": "http://100.73.140.127:9877/metrics",
                    "labels": {"scope": "wall"},
                    "stats": {"avg": 900.0},
                },
                {
                    "endpoint_url": "http://100.73.89.150:9877/metrics",
                    "labels": {"scope": "facility"},
                    "stats": {"avg": 1000.0},
                },
            ],
        },
        "power_energy_kwh": series(
            "counter", "total", 0.25, labels={"scope": "facility"}
        ),
        "power_cost_dollars": series(
            "counter", "total", 0.12, labels={"scope": "facility"}
        ),
    }
    if missing_server_metric is not None:
        del metrics[missing_server_metric]
    (directory / "server_metrics_export.json").write_text(
        json.dumps({"metrics": metrics}) + "\n", encoding="utf-8"
    )


def run_weka_fixture(
    root: Path,
    fixture: Path,
    *,
    profile_name: str,
    environment_overrides: dict[str, str] | None = None,
    verify_corpus: bool = False,
    corrupt_corpus: bool = False,
    repetition: int = 1,
    concurrency: int | None = None,
) -> tuple[subprocess.CompletedProcess[str], Path]:
    runs_root = root / "runs"
    run_root = runs_root / "20990101T000000Z"
    run_root.mkdir(parents=True, exist_ok=True)
    manifest = run_root / "manifest.env"
    manifest.write_text(
        "AIPERF_COMMIT=ea28b2e81c7367f8403c6f6ebe0837a508795a8d\n"
        "WEKA_REPOSITORY=semianalysisai/cc-traces-weka-062126\n"
        "WEKA_REVISION=23f152f6f0f9399a85901b89a6458def0ef16729\n",
        encoding="utf-8",
    )
    os.chmod(manifest, 0o600)
    dataset = root / "traces"
    dataset.mkdir(exist_ok=True)
    (dataset / "trace.json").write_text(
        '{"id":"fixture","requests":[]}\n', encoding="utf-8"
    )
    corpus_environment: dict[str, str] = {}
    if verify_corpus:
        (dataset / "trace.json").unlink()
        source = dataset.parent / "traces.jsonl"
        source_line = b'{"id":"fixture","requests":[]}\n'
        source.write_bytes(source_line)
        split = dataset / "trace-000.json"
        split.write_bytes(
            b'{"id":"forged","requests":[]}\n' if corrupt_corpus else source_line
        )
        source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        corpus_manifest = dataset.parent / "corpus-manifest.json"
        corpus_manifest.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "repository": "semianalysisai/cc-traces-weka-062126",
                    "revision": "23f152f6f0f9399a85901b89a6458def0ef16729",
                    "trace_count": 1,
                    "full_subagents": True,
                    "source_sha256": source_hash,
                    "source_size": source.stat().st_size,
                    "files": {
                        split.name: hashlib.sha256(split.read_bytes()).hexdigest()
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        os.chmod(corpus_manifest, 0o600)
        corpus_environment = {
            "TEST_WEKA_VERIFY_CORPUS": "1",
            "TEST_WEKA_SOURCE_SHA256": source_hash,
            "TEST_WEKA_SOURCE_SIZE": str(source.stat().st_size),
            "TEST_WEKA_SOURCE_TRACE_COUNT": "1",
        }
    tokenizer = root / "tokenizer"
    tokenizer.mkdir(exist_ok=True)
    key_file = root / "benchmark.key"
    key_file.write_text("test-weka-secret\n", encoding="utf-8")
    os.chmod(key_file, 0o600)
    fake = root / "aiperf"
    fake.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [[ -n \"${TEST_AIPERF_ENV_CAPTURE:-}\" ]]; then\n"
        "  printf '%s\\n' \"${AIPERF_DATASET_CONFIGURATION_TIMEOUT:-unset}\" "
        "\"${AIPERF_SERVICE_PROFILE_CONFIGURE_TIMEOUT:-unset}\" "
        ">\"$TEST_AIPERF_ENV_CAPTURE\"\n"
        "fi\n"
        "config=\n"
        "while (($#)); do\n"
        "  if [[ $1 == --config ]]; then config=$2; shift 2; else shift; fi\n"
        "done\n"
        "cp -a \"$AIPERF_OUTPUT_FIXTURE_ROOT/.\" \"$(dirname \"$config\")/\"\n"
        "printf '%s\\n' '05:31:54.473 NOTICE Phase profiling (profiling) complete | completed=1, cancelled=0, errors=0 | sessions: completed=1, cancelled=0 | elapsed=1.00s (runner.py:1227)'\n"
        "exit \"${TEST_AIPERF_EXIT_CODE:-0}\"\n",
        encoding="utf-8",
    )
    os.chmod(fake, 0o700)
    command = [
            "bash",
            str(RUNNER),
            "--run-root",
            str(run_root),
            "--profile-name",
            profile_name,
            "--repetition",
            str(repetition),
            "--key-file",
            str(key_file),
        ]
    if concurrency is None:
        command.append("--fixed-schedule")
        run_name = f"{profile_name}-r{repetition}-fixed"
    else:
        command.extend(["--concurrency", str(concurrency), "--no-fixed-schedule"])
        run_name = f"{profile_name}-c{concurrency}-r{repetition}-open"
    command.append("--internal")
    result = subprocess.run(
        command,
        cwd=REPOSITORY_ROOT,
        env={
            **os.environ,
            "WEBSTER_WEKA_RUNS_ROOT": str(runs_root),
            "WEBSTER_WEKA_TEST_MODE": "1",
            "WEBSTER_WEKA_AIPERF_BIN": str(fake),
            "WEBSTER_WEKA_DATASET": str(dataset),
            "WEBSTER_WEKA_TOKENIZER": str(tokenizer),
            "AIPERF_OUTPUT_FIXTURE_ROOT": str(fixture),
            **corpus_environment,
            **(environment_overrides or {}),
        },
        text=True,
        capture_output=True,
        check=False,
    )
    return result, run_root / "aiperf" / run_name


class AIPerfToolTests(unittest.TestCase):
    def test_weka_runner_rejects_memory_limited_controller_before_aiperf(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            aiperf_invocation = root / "aiperf-environment.log"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )

            result, destination = run_weka_fixture(
                root,
                fixture,
                profile_name="memory-limited-controller",
                environment_overrides={
                    "TEST_WEKA_CONTROLLER_MEMORY_BYTES": str(8 * 1024**3),
                    "TEST_AIPERF_ENV_CAPTURE": str(aiperf_invocation),
                },
            )

            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn("controller physical memory", result.stderr)
            self.assertFalse(aiperf_invocation.exists())
            self.assertFalse(destination.exists())

    def test_weka_runner_pins_timeouts_for_cold_corpus_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            environment_capture = root / "aiperf-environment.log"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )

            result, _ = run_weka_fixture(
                root,
                fixture,
                profile_name="cold-corpus-timeout",
                environment_overrides={
                    "TEST_AIPERF_ENV_CAPTURE": str(environment_capture)
                },
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                environment_capture.read_text(encoding="utf-8").splitlines(),
                ["1200", "1200"],
            )

    def test_corpus_builder_writes_private_manifest_bound_to_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dataset = root / "traces"
            dataset.mkdir()
            source = root / "traces.jsonl"
            lines = [b'{"id":"one","requests":[]}\n', b'{"id":"two","requests":[]}\n']
            source.write_bytes(b"".join(lines))
            for index, line in enumerate(lines):
                (dataset / f"trace-{index:03d}.json").write_bytes(line)
            source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
            manifest = dataset.parent / "corpus-manifest.json"

            result = subprocess.run(
                [
                    sys.executable,
                    str(CORPUS_BUILDER),
                    "--dataset",
                    str(dataset),
                    "--output",
                    str(manifest),
                    "--repository",
                    "fixture/repository",
                    "--revision",
                    "a" * 40,
                    "--source-sha256",
                    source_hash,
                    "--source-size",
                    str(source.stat().st_size),
                    "--trace-count",
                    "2",
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(os.stat(manifest).st_mode & 0o777, 0o600)
            value = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(value["source_sha256"], source_hash)
            self.assertEqual(set(value["files"]), {"trace-000.json", "trace-001.json"})
            verify = subprocess.run(
                [
                    sys.executable,
                    str(CORPUS_VERIFIER),
                    "--dataset",
                    str(dataset),
                    "--manifest",
                    str(manifest),
                    "--repository",
                    "fixture/repository",
                    "--revision",
                    "a" * 40,
                    "--source-sha256",
                    source_hash,
                    "--source-size",
                    str(source.stat().st_size),
                    "--trace-count",
                    "2",
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_corpus_builder_rejects_unmanifested_json_loader_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dataset = root / "traces"
            dataset.mkdir()
            source = root / "traces.jsonl"
            source_line = b'{"id":"one","requests":[]}\n'
            source.write_bytes(source_line)
            (dataset / "trace-000.json").write_bytes(source_line)
            (dataset / "unexpected.json").write_text(
                '{"id":"injected","requests":[]}\n', encoding="utf-8"
            )
            source_hash = hashlib.sha256(source.read_bytes()).hexdigest()

            result = subprocess.run(
                [
                    sys.executable,
                    str(CORPUS_BUILDER),
                    "--dataset",
                    str(dataset),
                    "--output",
                    str(root / "corpus-manifest.json"),
                    "--repository",
                    "fixture/repository",
                    "--revision",
                    "a" * 40,
                    "--source-sha256",
                    source_hash,
                    "--source-size",
                    str(source.stat().st_size),
                    "--trace-count",
                    "1",
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exact JSON trace set", result.stderr)

    def test_corpus_verifier_rejects_rehashed_split_not_from_pinned_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dataset = root / "traces"
            dataset.mkdir()
            source = root / "traces.jsonl"
            source_lines = [b'{"id":"one","requests":[]}\n', b'{"id":"two","requests":[]}\n']
            source.write_bytes(b"".join(source_lines))
            for index, line in enumerate(source_lines):
                (dataset / f"trace-{index:03d}.json").write_bytes(line)
            tampered = dataset / "trace-001.json"
            tampered.write_bytes(b'{"id":"forged","requests":[]}\n')
            source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
            manifest = dataset.parent / "corpus-manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "repository": "fixture/repository",
                        "revision": "a" * 40,
                        "trace_count": 2,
                        "full_subagents": True,
                        "source_sha256": source_hash,
                        "source_size": source.stat().st_size,
                        "files": {
                            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in sorted(dataset.glob("trace-*.json"))
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            os.chmod(manifest, 0o600)

            result = subprocess.run(
                [
                    sys.executable,
                    str(CORPUS_VERIFIER),
                    "--dataset",
                    str(dataset),
                    "--manifest",
                    str(manifest),
                    "--repository",
                    "fixture/repository",
                    "--revision",
                    "a" * 40,
                    "--source-sha256",
                    source_hash,
                    "--source-size",
                    str(source.stat().st_size),
                    "--trace-count",
                    "2",
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("pinned source", result.stderr)

    def test_corpus_verifier_rejects_json_added_after_manifest_creation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dataset = root / "traces"
            dataset.mkdir()
            source = root / "traces.jsonl"
            source_line = b'{"id":"one","requests":[]}\n'
            source.write_bytes(source_line)
            split = dataset / "trace-000.json"
            split.write_bytes(source_line)
            source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
            manifest = root / "corpus-manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "repository": "fixture/repository",
                        "revision": "a" * 40,
                        "trace_count": 1,
                        "full_subagents": True,
                        "source_sha256": source_hash,
                        "source_size": source.stat().st_size,
                        "files": {
                            split.name: hashlib.sha256(split.read_bytes()).hexdigest()
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            os.chmod(manifest, 0o600)
            (dataset / "unexpected.json").write_text(
                '{"id":"injected","requests":[]}\n', encoding="utf-8"
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(CORPUS_VERIFIER),
                    "--dataset",
                    str(dataset),
                    "--manifest",
                    str(manifest),
                    "--repository",
                    "fixture/repository",
                    "--revision",
                    "a" * 40,
                    "--source-sha256",
                    source_hash,
                    "--source-size",
                    str(source.stat().st_size),
                    "--trace-count",
                    "1",
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exact JSON trace set", result.stderr)

    def test_weka_runner_invokes_immutable_corpus_verification(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )

            result, destination = run_weka_fixture(
                root,
                fixture,
                profile_name="forged-corpus",
                verify_corpus=True,
                corrupt_corpus=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("pinned source", result.stderr)
            self.assertFalse(destination.exists())

    def test_weka_runner_rejects_fatal_worker_rank_log(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )

            result, destination = run_weka_fixture(
                root,
                fixture,
                profile_name="worker-engine-death",
                environment_overrides={
                    "TEST_WEKA_RANK1_LOG": "EngineDeadError: worker failed"
                },
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((destination / "EXIT").read_text(), "EXIT=1\n")
            self.assertIn("fatal serving-rank log", result.stderr)
            self.assertFalse((destination / "provenance.json").exists())

    def test_weka_runner_preserves_direct_aiperf_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )

            result, destination = run_weka_fixture(
                root,
                fixture,
                profile_name="aiperf-exit-failure",
                environment_overrides={"TEST_AIPERF_EXIT_CODE": "7"},
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((destination / "EXIT").read_text(), "EXIT=7\n")
            self.assertIn("AIPerf exited with status 7", result.stderr)
            self.assertNotIn("unbound variable", result.stderr)
            self.assertFalse((destination / "provenance.json").exists())

    def test_weka_scored_repetition_requires_same_generation_warmup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )

            result, destination = run_weka_fixture(
                root,
                fixture,
                profile_name="scored-without-warmup",
                repetition=2,
                concurrency=4,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("warmup repetition", result.stderr)
            self.assertFalse(destination.exists())

    def test_weka_scored_repetition_binds_exact_warmup_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )
            warmup, warmup_destination = run_weka_fixture(
                root,
                fixture,
                profile_name="sequential",
                repetition=1,
                concurrency=4,
            )
            self.assertEqual(warmup.returncode, 0, warmup.stderr)

            scored, scored_destination = run_weka_fixture(
                root,
                fixture,
                profile_name="sequential",
                repetition=2,
                concurrency=4,
            )

            self.assertEqual(scored.returncode, 0, scored.stderr)
            warmup_provenance = warmup_destination / "provenance.json"
            scored_provenance = json.loads(
                (scored_destination / "provenance.json").read_text(encoding="utf-8")
            )
            self.assertEqual(scored_provenance["cache_state"], "warm")
            self.assertTrue(scored_provenance["warmup_and_scored_comparable"])
            self.assertEqual(
                scored_provenance["warmup_provenance_sha256"],
                hashlib.sha256(warmup_provenance.read_bytes()).hexdigest(),
            )

    def test_weka_scored_repetition_rejects_different_warmup_runtime_patch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )
            warmup, warmup_destination = run_weka_fixture(
                root,
                fixture,
                profile_name="runtime-patch-continuity",
                repetition=1,
                concurrency=4,
            )
            self.assertEqual(warmup.returncode, 0, warmup.stderr)
            warmup_provenance = warmup_destination / "provenance.json"
            payload = json.loads(warmup_provenance.read_text(encoding="utf-8"))
            payload["aiperf_weka_patch_sha256"] = "0" * 64
            warmup_provenance.write_text(
                json.dumps(payload, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            scored, scored_destination = run_weka_fixture(
                root,
                fixture,
                profile_name="runtime-patch-continuity",
                repetition=2,
                concurrency=4,
            )

            self.assertNotEqual(scored.returncode, 0)
            self.assertIn("runtime patch", scored.stderr)
            self.assertFalse(scored_destination.exists())

    def test_weka_timing_patcher_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "aiperf"
            resolver = source / "src" / "aiperf" / "config" / "dataset" / "resolver.py"
            resolver.parent.mkdir(parents=True)
            resolver.write_text(
                "            CustomDatasetType.BURST_GPT_TRACE,\n"
                "            CustomDatasetType.BASETEN_TRACE,\n"
                "            CustomDatasetType.TRACELAB,\n",
                encoding="utf-8",
            )

            first = subprocess.run(
                [sys.executable, str(PATCHER), "--source", str(source)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            after_first = resolver.read_text(encoding="utf-8")
            self.assertEqual(after_first.count("CustomDatasetType.WEKA_TRACE"), 1)

            second = subprocess.run(
                [sys.executable, str(PATCHER), "--source", str(source)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(resolver.read_text(encoding="utf-8"), after_first)

    def test_weka_timing_patcher_rejects_divergent_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "aiperf"
            resolver = source / "src" / "aiperf" / "config" / "dataset" / "resolver.py"
            resolver.parent.mkdir(parents=True)
            resolver.write_text("unexpected upstream source\n", encoding="utf-8")

            result = subprocess.run(
                [sys.executable, str(PATCHER), "--source", str(source)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsupported AIPerf resolver source", result.stderr)
            self.assertEqual(
                resolver.read_text(encoding="utf-8"), "unexpected upstream source\n"
            )

    def test_summarizer_counts_request_errors_before_accepting_aggregates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "summary.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    "--profile",
                    str(FIXTURES / "aiperf-profile.json"),
                    "--records",
                    str(FIXTURES / "aiperf-errors.jsonl"),
                    "--output-json",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0, result.stderr)
            summary = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(summary["requests"], 2)
            self.assertEqual(summary["completed"], 1)
            self.assertEqual(summary["errors"], 1)
            self.assertEqual(summary["server_success_rate"], 0.5)
            self.assertEqual(summary["request_throughput"], 0.25)
            self.assertEqual(summary["ttft_p90_ms"], 1200.0)
            self.assertEqual(summary["output_token_throughput"], 42.5)
            self.assertEqual(summary["error_types"], {"EngineDeadError": 1})
            self.assertFalse(summary["qualified"])

    def test_summarizer_reads_current_aiperf_schema_and_request_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            profile = root / "profile.json"
            records = root / "records.jsonl"
            output = root / "summary.json"
            profile.write_text(
                json.dumps(
                    {
                        "request_throughput": {"unit": "requests/sec", "avg": 1.5},
                        "time_to_first_token": {"unit": "ms", "p90": 900.0},
                        "output_token_throughput": {"unit": "tokens/sec", "avg": 88.0},
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            rows = [
                {
                    "metadata": {
                        "request_start_ns": 100,
                        "request_end_ns": 300,
                        "agent_depth": 0,
                        "root_correlation_id": "root-1",
                    },
                    "metrics": {},
                },
                {
                    "metadata": {
                        "request_start_ns": 200,
                        "request_end_ns": 400,
                        "agent_depth": 1,
                        "root_correlation_id": "root-1",
                    },
                    "metrics": {},
                },
            ]
            records.write_text(
                "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    "--profile",
                    str(profile),
                    "--records",
                    str(records),
                    "--output-json",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(summary["requests"], 2)
            self.assertEqual(summary["errors"], 0)
            self.assertEqual(summary["request_throughput"], 1.5)
            self.assertEqual(summary["ttft_p90_ms"], 900.0)
            self.assertEqual(summary["output_token_throughput"], 88.0)
            self.assertEqual(summary["request_peak_concurrency"], 2)
            self.assertEqual(summary["root_session_trees"], 1)
            self.assertEqual(summary["request_count_by_agent_depth"], {"0": 1, "1": 1})
            self.assertNotIn("prefix_cache_hits", summary)
            self.assertNotIn("completed_root_workflows", summary)
            self.assertNotIn("cancelled_root_workflows", summary)
            self.assertNotIn("root_workflow_elapsed_seconds", summary)
            self.assertNotIn("completed_root_workflows_per_second", summary)
            self.assertTrue(summary["qualified"])

    def test_summarizer_reads_completed_root_workflows_from_timing_log(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            timing_log = root / "aiperf.stdout.log"
            output = root / "summary.json"
            timing_log.write_text(
                "05:31:00.000 INFO     profiling in progress\n"
                "05:31:54.473 NOTICE   Phase profiling (profiling) complete | "
                "completed=354, cancelled=0, errors=0 | sessions: completed=3, "
                "cancelled=1 | elapsed=60.00s (runner.py:1227)\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    "--profile",
                    str(FIXTURES / "aiperf-profile.json"),
                    "--records",
                    str(FIXTURES / "aiperf-errors.jsonl"),
                    "--timing-log",
                    str(timing_log),
                    "--output-json",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0, result.stderr)
            summary = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(summary["completed_root_workflows"], 3)
            self.assertEqual(summary["cancelled_root_workflows"], 1)
            self.assertEqual(summary["root_workflow_elapsed_seconds"], 60.0)
            self.assertEqual(summary["completed_root_workflows_per_second"], 0.05)
            self.assertFalse(summary["qualified"])

    def test_summarizer_accepts_grouped_aiperf_request_counts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            timing_log = root / "aiperf.log"
            output = root / "summary.json"
            timing_log.write_text(
                "2026-09-12 15:16:53.471 - PhaseRunner - NOTICE - "
                "Phase profiling (profiling) complete | completed=1,036, "
                "cancelled=0, errors=0 | sessions: completed=6, cancelled=0 | "
                "elapsed=916.22s\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    "--profile",
                    str(FIXTURES / "aiperf-profile.json"),
                    "--records",
                    str(FIXTURES / "aiperf-errors.jsonl"),
                    "--timing-log",
                    str(timing_log),
                    "--output-json",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0, result.stderr)
            summary = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(summary["completed_root_workflows"], 6)
            self.assertEqual(summary["cancelled_root_workflows"], 0)
            self.assertEqual(summary["root_workflow_elapsed_seconds"], 916.22)

    def test_summarizer_rejects_timing_log_without_profiling_completion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            timing_log = root / "aiperf.stdout.log"
            output = root / "summary.json"
            timing_log.write_text(
                "05:31:00.000 INFO     profiling in progress\n", encoding="utf-8"
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    "--profile",
                    str(FIXTURES / "aiperf-profile.json"),
                    "--records",
                    str(FIXTURES / "aiperf-errors.jsonl"),
                    "--timing-log",
                    str(timing_log),
                    "--output-json",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "timing log must contain exactly one profiling-complete line",
                result.stderr,
            )
            self.assertFalse(output.exists())

    def test_summarizer_rejects_multiple_profiling_completion_lines(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            timing_log = root / "aiperf.log"
            output = root / "summary.json"
            completion = (
                "Phase profiling (profiling) complete | completed=354, cancelled=0, "
                "errors=0 | sessions: completed=3, cancelled=0 | elapsed=900.03s\n"
            )
            timing_log.write_text(
                "05:31:54.473 NOTICE   " + completion
                + "2099-01-01 05:31:54.473 | aiperf | NOTICE | "
                + completion,
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    "--profile",
                    str(FIXTURES / "aiperf-profile.json"),
                    "--records",
                    str(FIXTURES / "aiperf-errors.jsonl"),
                    "--timing-log",
                    str(timing_log),
                    "--output-json",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "timing log must contain exactly one profiling-complete line",
                result.stderr,
            )
            self.assertFalse(output.exists())

    def test_summarizer_rejects_malformed_profiling_completion_line(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            timing_log = root / "aiperf.stdout.log"
            output = root / "summary.json"
            timing_log.write_text(
                "05:31:54.473 NOTICE   NOTPhase profiling (profiling) complete | "
                "completed=354, cancelled=0, errors=0 | sessions: completed=3, "
                "cancelled=0 | elapsed=900.03s\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    "--profile",
                    str(FIXTURES / "aiperf-profile.json"),
                    "--records",
                    str(FIXTURES / "aiperf-errors.jsonl"),
                    "--timing-log",
                    str(timing_log),
                    "--output-json",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "profiling-complete timing log line is malformed", result.stderr
            )
            self.assertFalse(output.exists())

    def test_summarizer_rejects_zero_root_workflow_elapsed_time(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            timing_log = root / "aiperf.stdout.log"
            output = root / "summary.json"
            timing_log.write_text(
                "05:31:54.473 NOTICE   Phase profiling (profiling) complete | "
                "completed=0, cancelled=0, errors=0 | sessions: completed=0, "
                "cancelled=0 | elapsed=0.00s\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    "--profile",
                    str(FIXTURES / "aiperf-profile.json"),
                    "--records",
                    str(FIXTURES / "aiperf-errors.jsonl"),
                    "--timing-log",
                    str(timing_log),
                    "--output-json",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "root workflow elapsed seconds must be greater than zero",
                result.stderr,
            )
            self.assertFalse(output.exists())

    def test_summarizer_rejects_nonfinite_root_workflow_elapsed_time(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            timing_log = root / "aiperf.stdout.log"
            output = root / "summary.json"
            timing_log.write_text(
                "05:31:54.473 NOTICE   Phase profiling (profiling) complete | "
                "completed=1, cancelled=0, errors=0 | sessions: completed=1, "
                f"cancelled=0 | elapsed={'9' * 400}.00s\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    "--profile",
                    str(FIXTURES / "aiperf-profile.json"),
                    "--records",
                    str(FIXTURES / "aiperf-errors.jsonl"),
                    "--timing-log",
                    str(timing_log),
                    "--output-json",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "root workflow elapsed seconds must be a finite number",
                result.stderr,
            )
            self.assertFalse(output.exists())

    def test_summarizer_reads_server_metrics_for_profile_comparison(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            profile = root / "profile.json"
            records = root / "records.jsonl"
            server_metrics = root / "server_metrics_export.json"
            output = root / "summary.json"
            profile.write_text(
                json.dumps(
                    {
                        "request_throughput": {"unit": "requests/sec", "avg": 0.5},
                        "time_to_first_token": {"unit": "ms", "p90": 1200.0},
                        "output_token_throughput": {
                            "unit": "tokens/sec",
                            "avg": 40.0,
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            records.write_text(
                json.dumps(
                    {
                        "metadata": {
                            "request_start_ns": 100,
                            "request_end_ns": 200,
                            "agent_depth": 0,
                            "root_correlation_id": "root-1",
                        },
                        "metrics": {},
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            server_metrics.write_text(
                json.dumps(
                    {
                        "schema_version": "1.1",
                        "aiperf_version": "0.13.0",
                        "benchmark_id": "benchmark-fixture",
                        "summary": {
                            "endpoints_configured": [
                                "http://head:8000/metrics",
                                "http://shamu:9877/metrics",
                                "http://tilikum:9877/metrics",
                            ],
                            "endpoints_successful": [
                                "http://head:8000/metrics",
                                "http://shamu:9877/metrics",
                                "http://tilikum:9877/metrics",
                            ],
                            "start_time": "2099-01-01T00:00:00Z",
                            "end_time": "2099-01-01T00:10:00Z",
                        },
                        "metrics_phase": "profiling",
                        "metrics": {
                            "vllm:prefix_cache_hits": {
                                "type": "counter",
                                "description": "Prefix cache hits",
                                "series": [
                                    {
                                        "endpoint_url": "http://head:8000/metrics",
                                        "labels": {"model_name": "deepseek-v4.1-flash"},
                                        "stats": {"total": 720.0, "rate": 1.2},
                                    }
                                ],
                            },
                            "vllm:prefix_cache_queries": {
                                "type": "counter",
                                "description": "Prefix cache queries",
                                "series": [
                                    {
                                        "endpoint_url": "http://head:8000/metrics",
                                        "labels": {"model_name": "deepseek-v4.1-flash"},
                                        "stats": {"total": 800.0, "rate": 1.333},
                                    }
                                ],
                            },
                            "vllm:kv_cache_usage_perc": {
                                "type": "gauge",
                                "description": "KV-cache usage",
                                "series": [
                                    {
                                        "endpoint_url": "http://head:8000/metrics",
                                        "labels": {"model_name": "deepseek-v4.1-flash"},
                                        "stats": {
                                            "avg": 0.55,
                                            "min": 0.1,
                                            "max": 0.875,
                                        },
                                    }
                                ],
                            },
                            "vllm:num_preemptions": {
                                "type": "counter",
                                "description": "Request preemptions",
                                "series": [
                                    {
                                        "endpoint_url": "http://head:8000/metrics",
                                        "labels": {"model_name": "deepseek-v4.1-flash"},
                                        "stats": {"total": 3.0, "rate": 0.005},
                                    }
                                ],
                            },
                            "vllm:num_requests_running": {
                                "type": "gauge",
                                "description": "Running requests",
                                "series": [
                                    {
                                        "endpoint_url": "http://head:8000/metrics",
                                        "labels": {"model_name": "deepseek-v4.1-flash"},
                                        "stats": {"avg": 0.8, "min": 0.0, "max": 1.0},
                                    }
                                ],
                            },
                            "vllm:num_requests_waiting": {
                                "type": "gauge",
                                "description": "Waiting requests",
                                "series": [
                                    {
                                        "endpoint_url": "http://head:8000/metrics",
                                        "labels": {"model_name": "deepseek-v4.1-flash"},
                                        "stats": {"avg": 4.0, "min": 0.0, "max": 11.0},
                                    }
                                ],
                            },
                            "power_total_watts": {
                                "type": "gauge",
                                "description": "Total power by scope",
                                "unit": "watts",
                                "series": [
                                    {
                                        "endpoint_url": "http://shamu:9877/metrics",
                                        "labels": {"scope": "measured"},
                                        "stats": {"avg": 425.0, "min": 400.0, "max": 450.0},
                                    },
                                    {
                                        "endpoint_url": "http://shamu:9877/metrics",
                                        "labels": {"scope": "wall"},
                                        "stats": {"avg": 510.0, "min": 490.0, "max": 530.0},
                                    },
                                    {
                                        "endpoint_url": "http://shamu:9877/metrics",
                                        "labels": {"scope": "facility"},
                                        "stats": {"avg": 550.0, "min": 525.0, "max": 575.0},
                                    },
                                    {
                                        "endpoint_url": "http://tilikum:9877/metrics",
                                        "labels": {"scope": "measured"},
                                        "stats": {"avg": 440.0, "min": 410.0, "max": 470.0},
                                    },
                                    {
                                        "endpoint_url": "http://tilikum:9877/metrics",
                                        "labels": {"scope": "wall"},
                                        "stats": {"avg": 530.0, "min": 500.0, "max": 560.0},
                                    },
                                    {
                                        "endpoint_url": "http://tilikum:9877/metrics",
                                        "labels": {"scope": "facility"},
                                        "stats": {"avg": 572.0, "min": 540.0, "max": 604.0},
                                    },
                                ],
                            },
                            "power_energy_kwh": {
                                "type": "counter",
                                "description": "Accumulated energy by scope",
                                "unit": "kilowatt-hours",
                                "series": [
                                    {
                                        "endpoint_url": "http://shamu:9877/metrics",
                                        "labels": {"scope": "measured"},
                                        "stats": {"total": 0.5, "rate": 0.0008},
                                    },
                                    {
                                        "endpoint_url": "http://shamu:9877/metrics",
                                        "labels": {"scope": "wall"},
                                        "stats": {"total": 0.7, "rate": 0.0011},
                                    },
                                    {
                                        "endpoint_url": "http://shamu:9877/metrics",
                                        "labels": {"scope": "facility"},
                                        "stats": {"total": 0.75, "rate": 0.0012},
                                    },
                                    {
                                        "endpoint_url": "http://tilikum:9877/metrics",
                                        "labels": {"scope": "measured"},
                                        "stats": {"total": 0.55, "rate": 0.0009},
                                    },
                                    {
                                        "endpoint_url": "http://tilikum:9877/metrics",
                                        "labels": {"scope": "wall"},
                                        "stats": {"total": 0.74, "rate": 0.0012},
                                    },
                                    {
                                        "endpoint_url": "http://tilikum:9877/metrics",
                                        "labels": {"scope": "facility"},
                                        "stats": {"total": 0.8, "rate": 0.0013},
                                    },
                                ],
                            },
                            "power_cost_dollars": {
                                "type": "counter",
                                "description": "Accumulated facility energy cost",
                                "unit": "dollars",
                                "series": [
                                    {
                                        "endpoint_url": "http://shamu:9877/metrics",
                                        "stats": {"total": 0.3525, "rate": 0.0006},
                                    },
                                    {
                                        "endpoint_url": "http://tilikum:9877/metrics",
                                        "stats": {"total": 0.376, "rate": 0.0006},
                                    },
                                ],
                            },
                        },
                        "input_config": {"benchmark": {"model": "deepseek-v4.1-flash"}},
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    "--profile",
                    str(profile),
                    "--records",
                    str(records),
                    "--server-metrics",
                    str(server_metrics),
                    "--output-json",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(summary["prefix_cache_hits"], 720.0)
            self.assertEqual(summary["prefix_cache_queries"], 800.0)
            self.assertEqual(summary["prefix_cache_hit_ratio"], 0.9)
            self.assertEqual(summary["kv_cache_usage_max"], 0.875)
            self.assertEqual(summary["preemptions_total"], 3.0)
            self.assertEqual(summary["running_requests_max"], 1.0)
            self.assertEqual(summary["waiting_requests_max"], 11.0)
            self.assertEqual(summary["wall_power_avg_watts"], 1040.0)
            self.assertEqual(summary["facility_power_avg_watts"], 1122.0)
            self.assertEqual(summary["facility_energy_kwh"], 1.55)
            self.assertAlmostEqual(summary["facility_cost_dollars"], 0.7285)

    def test_summarizer_returns_null_for_unexported_server_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            server_metrics = root / "server_metrics_export.json"
            output = root / "summary.json"
            server_metrics.write_text(
                json.dumps(
                    {
                        "schema_version": "1.1",
                        "aiperf_version": "0.13.0",
                        "benchmark_id": "benchmark-fixture",
                        "summary": {
                            "endpoints_configured": ["http://head:8000/metrics"],
                            "endpoints_successful": ["http://head:8000/metrics"],
                            "start_time": "2099-01-01T00:00:00Z",
                            "end_time": "2099-01-01T00:10:00Z",
                        },
                        "metrics_phase": "profiling",
                        "metrics": {
                            "vllm:num_preemptions": {
                                "type": "counter",
                                "description": "Request preemptions",
                                "series": [
                                    {
                                        "endpoint_url": "http://head:8000/metrics",
                                        "labels": {"model_name": "deepseek-v4.1-flash"},
                                        "stats": {"total": 2.0, "rate": 0.003},
                                    }
                                ],
                            }
                        },
                        "input_config": {},
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    "--profile",
                    str(FIXTURES / "aiperf-profile.json"),
                    "--records",
                    str(FIXTURES / "aiperf-errors.jsonl"),
                    "--server-metrics",
                    str(server_metrics),
                    "--output-json",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0, result.stderr)
            summary = json.loads(output.read_text(encoding="utf-8"))
            self.assertIsNone(summary["prefix_cache_hits"])
            self.assertIsNone(summary["prefix_cache_queries"])
            self.assertIsNone(summary["prefix_cache_hit_ratio"])
            self.assertIsNone(summary["kv_cache_usage_max"])
            self.assertEqual(summary["preemptions_total"], 2.0)
            self.assertIsNone(summary["running_requests_max"])
            self.assertIsNone(summary["waiting_requests_max"])
            self.assertIsNone(summary["wall_power_avg_watts"])
            self.assertIsNone(summary["facility_power_avg_watts"])
            self.assertIsNone(summary["facility_energy_kwh"])
            self.assertIsNone(summary["facility_cost_dollars"])
            self.assertFalse(summary["qualified"])

    def test_summarizer_rejects_malformed_exported_server_metric(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            profile = root / "profile.json"
            records = root / "records.jsonl"
            server_metrics = root / "server_metrics_export.json"
            output = root / "summary.json"
            profile.write_text("{}\n", encoding="utf-8")
            records.write_text(
                '{"metadata":{"request_start_ns":100,"request_end_ns":200},'
                '"metrics":{}}\n',
                encoding="utf-8",
            )
            server_metrics.write_text(
                json.dumps(
                    {
                        "schema_version": "1.1",
                        "aiperf_version": "0.13.0",
                        "benchmark_id": "benchmark-fixture",
                        "summary": {
                            "endpoints_configured": ["http://head:8000/metrics"],
                            "endpoints_successful": ["http://head:8000/metrics"],
                            "start_time": "2099-01-01T00:00:00Z",
                            "end_time": "2099-01-01T00:10:00Z",
                        },
                        "metrics_phase": "profiling",
                        "metrics": {"vllm:num_preemptions": None},
                        "input_config": {},
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SUMMARIZER),
                    "--profile",
                    str(profile),
                    "--records",
                    str(records),
                    "--server-metrics",
                    str(server_metrics),
                    "--output-json",
                    str(output),
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "server metric vllm:num_preemptions must be an object",
                result.stderr,
            )
            self.assertFalse(output.exists())

    def test_weka_runner_keeps_the_key_out_of_argv_and_cleans_exact_temp(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runs_root = root / "runs"
            run_root = runs_root / "20990101T000000Z"
            run_root.mkdir(parents=True)
            manifest = run_root / "manifest.env"
            manifest.write_text(
                "AIPERF_COMMIT=ea28b2e81c7367f8403c6f6ebe0837a508795a8d\n"
                "WEKA_REPOSITORY=semianalysisai/cc-traces-weka-062126\n"
                "WEKA_REVISION=23f152f6f0f9399a85901b89a6458def0ef16729\n",
                encoding="utf-8",
            )
            os.chmod(manifest, 0o600)
            dataset = root / "traces"
            dataset.mkdir()
            (dataset / "trace.json").write_text(
                '{"id":"fixture","requests":[]}\n', encoding="utf-8"
            )
            key_file = root / "benchmark.key"
            key_file.write_text("test-weka-secret\n", encoding="utf-8")
            os.chmod(key_file, 0o600)
            tokenizer = root / "tokenizer"
            tokenizer.mkdir()
            temp_root = run_root / "tmp"
            fake = root / "aiperf"
            config_capture = root / "aiperf-config.json"
            output_fixture = root / "aiperf-output-fixture"
            write_valid_runner_exports(
                output_fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )
            fake.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' \"$@\" >\"$AIPERF_TEST_ARGV\"\n"
                "test \"${OPENAI_API_KEY:-}\" = test-weka-secret\n"
                "config=\n"
                "while (($#)); do\n"
                "  if [[ $1 == --config ]]; then config=$2; shift 2; else shift; fi\n"
                "done\n"
                "test -n \"$config\"\n"
                "test \"$(stat -c %a \"$config\")\" = 600\n"
                "cp \"$config\" \"$AIPERF_TEST_CONFIG\"\n"
                "cp -a \"$AIPERF_OUTPUT_FIXTURE_ROOT/.\" \"$(dirname \"$config\")/\"\n"
                "printf '%s\\n' '05:31:54.473 NOTICE Phase profiling (profiling) complete | completed=1, cancelled=0, errors=0 | sessions: completed=1, cancelled=0 | elapsed=1.00s (runner.py:1227)'\n",
                encoding="utf-8",
            )
            os.chmod(fake, 0o700)
            argv_log = root / "argv.log"
            environment = {
                **os.environ,
                "WEBSTER_WEKA_RUNS_ROOT": str(runs_root),
                "WEBSTER_WEKA_TEST_MODE": "1",
                "WEBSTER_WEKA_AIPERF_BIN": str(fake),
                "WEBSTER_WEKA_DATASET": str(dataset),
                "WEBSTER_WEKA_TOKENIZER": str(tokenizer),
                "AIPERF_TEST_ARGV": str(argv_log),
                "AIPERF_TEST_CONFIG": str(config_capture),
                "AIPERF_OUTPUT_FIXTURE_ROOT": str(output_fixture),
            }
            result = subprocess.run(
                [
                    "bash",
                    str(RUNNER),
                    "--run-root",
                    str(run_root),
                    "--profile-name",
                    "baseline",
                    "--repetition",
                    "1",
                    "--key-file",
                    str(key_file),
                    "--fixed-schedule",
                    "--internal",
                ],
                cwd=REPOSITORY_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            argv = argv_log.read_text(encoding="utf-8")
            self.assertNotIn("test-weka-secret", argv)
            self.assertNotIn("--api-key", argv)
            self.assertEqual(argv.splitlines()[0], "profile")
            self.assertEqual(argv.splitlines()[1], "--config")
            self.assertEqual(len(argv.splitlines()), 3)
            config = json.loads(config_capture.read_text(encoding="utf-8"))
            benchmark = config["benchmark"]
            self.assertEqual(benchmark["endpoint"]["api_key"], "${OPENAI_API_KEY}")
            self.assertEqual(benchmark["datasets"][0]["format"], "weka_trace")
            self.assertEqual(benchmark["phases"][0]["type"], "fixed_schedule")
            self.assertNotIn("concurrency", benchmark["phases"][0])
            self.assertTrue(benchmark["phases"][0]["auto_offset"])
            self.assertEqual(
                benchmark["server_metrics"]["urls"],
                [
                    "http://100.73.140.127:8000/metrics",
                    "http://100.73.140.127:9877/metrics",
                    "http://100.73.89.150:9877/metrics",
                ],
            )
            destination = run_root / "aiperf" / "baseline-r1-fixed"
            self.assertEqual((destination / "EXIT").read_text(), "EXIT=0\n")
            self.assertTrue(
                json.loads((destination / "summary.json").read_text())["qualified"]
            )
            provenance = json.loads(
                (destination / "provenance.json").read_text(encoding="utf-8")
            )
            for name in (
                "aiperf.stderr.log",
                "summary.json",
                "benchmark-window.json",
                "rank0-before.json",
                "rank1-before.json",
                "rank0-after.json",
                "rank1-after.json",
                "rank0-container.log",
                "rank1-container.log",
            ):
                self.assertEqual(
                    provenance["artifacts"][name],
                    hashlib.sha256((destination / name).read_bytes()).hexdigest(),
                )
            self.assertEqual(
                json.loads((destination / "rank0-before.json").read_text()),
                json.loads((destination / "rank0-after.json").read_text()),
            )
            self.assertEqual(
                json.loads((destination / "rank1-before.json").read_text()),
                json.loads((destination / "rank1-after.json").read_text()),
            )
            self.assertEqual(
                os.stat(destination / "aiperf-config.yaml").st_mode & 0o777, 0o600
            )
            rendered = (destination / "rendered-command.txt").read_text()
            self.assertNotIn("test-weka-secret", rendered)
            self.assertNotIn("--api-key", rendered)
            self.assertIn("--config", rendered)
            self.assertTrue(temp_root.is_dir())
            self.assertEqual(list(temp_root.iterdir()), [])

    def test_weka_runner_carries_path_overrides_into_detached_tmux_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            injection_canary = root / "tmux-injection-canary"
            runs_root = (
                root
                / 'runs with spaces $(touch "$AIPERF_INJECTION_CANARY") [fixture]'
            )
            run_root = runs_root / "20990101T000000Z"
            run_root.mkdir(parents=True)
            manifest = run_root / "manifest.env"
            manifest.write_text(
                "AIPERF_COMMIT=ea28b2e81c7367f8403c6f6ebe0837a508795a8d\n"
                "WEKA_REPOSITORY=semianalysisai/cc-traces-weka-062126\n"
                "WEKA_REVISION=23f152f6f0f9399a85901b89a6458def0ef16729\n",
                encoding="utf-8",
            )
            os.chmod(manifest, 0o600)
            dataset = root / "traces"
            dataset.mkdir()
            (dataset / "trace.json").write_text(
                '{"id":"fixture","requests":[]}\n', encoding="utf-8"
            )
            tokenizer = root / "tokenizer"
            tokenizer.mkdir()
            key_file = root / "benchmark.key"
            key_file.write_text("test-weka-secret\n", encoding="utf-8")
            os.chmod(key_file, 0o600)

            fake_aiperf = root / "aiperf"
            environment_capture = root / "aiperf-environment.log"
            output_fixture = root / "aiperf-output-fixture"
            write_valid_runner_exports(
                output_fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )
            fake_aiperf.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' \"$WEBSTER_WEKA_RUNS_ROOT\" "
                "\"$WEBSTER_WEKA_AIPERF_BIN\" \"$WEBSTER_WEKA_DATASET\" "
                "\"$WEBSTER_WEKA_TOKENIZER\" \"${WEBSTER_LOCAL_SHAMU:-}\" "
                "\"${WEBSTER_WEKA_AIPERF_SOURCE:-}\" "
                ">\"$AIPERF_ENV_CAPTURE\"\n"
                "cp -a \"$AIPERF_OUTPUT_FIXTURE_ROOT/.\" \"$(dirname \"${!#}\")/\"\n"
                "printf '%s\\n' '05:31:54.473 NOTICE Phase profiling (profiling) complete | completed=1, cancelled=0, errors=0 | sessions: completed=1, cancelled=0 | elapsed=1.00s (runner.py:1227)'\n",
                encoding="utf-8",
            )
            os.chmod(fake_aiperf, 0o700)

            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_tmux = fake_bin / "tmux"
            tmux_argv_capture = root / "tmux-argv.log"
            fake_tmux.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "case ${1:-} in\n"
                "  new-session)\n"
                "    printf '%s\\n' \"$@\" >\"$TMUX_TEST_ARGV\"\n"
                "    command=${!#}\n"
                "    umask 002\n"
                "    env -u WEBSTER_WEKA_RUNS_ROOT "
                "-u WEBSTER_WEKA_AIPERF_BIN "
                "-u WEBSTER_WEKA_DATASET "
                "-u WEBSTER_WEKA_TOKENIZER "
                "-u WEBSTER_LOCAL_SHAMU "
                "-u WEBSTER_WEKA_AIPERF_SOURCE "
                "TMUX=fake bash -c \"$command\" || true\n"
                "    ;;\n"
                "  has-session) exit 1 ;;\n"
                "  *) exit 2 ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            os.chmod(fake_tmux, 0o700)

            environment = {
                **os.environ,
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "WEBSTER_WEKA_RUNS_ROOT": str(runs_root),
                "WEBSTER_WEKA_TEST_MODE": "1",
                "TEST_WEKA_ENABLE_TMUX": "1",
                "WEBSTER_WEKA_AIPERF_BIN": str(fake_aiperf),
                "WEBSTER_WEKA_DATASET": str(dataset),
                "WEBSTER_WEKA_TOKENIZER": str(tokenizer),
                "WEBSTER_LOCAL_SHAMU": "1",
                "WEBSTER_WEKA_AIPERF_SOURCE": str(root / "aiperf-source"),
                "AIPERF_ENV_CAPTURE": str(environment_capture),
                "AIPERF_INJECTION_CANARY": str(injection_canary),
                "AIPERF_OUTPUT_FIXTURE_ROOT": str(output_fixture),
                "TMUX_TEST_ARGV": str(tmux_argv_capture),
            }
            environment.pop("TMUX", None)
            result = subprocess.run(
                [
                    "bash",
                    str(RUNNER),
                    "--run-root",
                    str(run_root),
                    "--profile-name",
                    "detached",
                    "--repetition",
                    "1",
                    "--key-file",
                    str(key_file),
                    "--fixed-schedule",
                ],
                cwd=REPOSITORY_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            tmux_log = run_root / "logs" / "detached-r1-fixed.tmux.log"
            tmux_output = (
                tmux_log.read_text(encoding="utf-8") if tmux_log.exists() else ""
            )
            self.assertEqual(os.stat(tmux_log).st_mode & 0o777, 0o600)
            self.assertFalse(injection_canary.exists(), "tmux command injection ran")
            self.assertEqual(result.returncode, 0, result.stderr + tmux_output)
            self.assertEqual(
                environment_capture.read_text(encoding="utf-8").splitlines(),
                [
                    str(runs_root),
                    str(fake_aiperf),
                    str(dataset),
                    str(tokenizer),
                    "1",
                    str(root / "aiperf-source"),
                ],
            )
            tmux_argv = tmux_argv_capture.read_text(encoding="utf-8")
            self.assertNotIn("test-weka-secret", tmux_argv)
            self.assertNotIn("--api-key", tmux_argv)
            rendered = (
                run_root
                / "aiperf"
                / "detached-r1-fixed"
                / "rendered-command.txt"
            ).read_text(encoding="utf-8")
            self.assertNotIn("test-weka-secret", rendered)
            self.assertNotIn("--api-key", rendered)

    def test_weka_runner_rejects_incomplete_result_publication(self) -> None:
        cases: list[tuple[str, dict[str, object]]] = [
            ("missing-ready", {}),
            ("malformed-ready", {"readiness_raw": "{not-json\n"}),
            (
                "not-ready",
                {
                    "readiness": {
                        "ready": False,
                        "was_cancelled": False,
                        "partial": False,
                    }
                },
            ),
            (
                "partial",
                {
                    "readiness": {
                        "ready": True,
                        "was_cancelled": False,
                        "partial": True,
                    }
                },
            ),
            (
                "failed-exporter",
                {
                    "readiness": {
                        "ready": True,
                        "was_cancelled": False,
                        "partial": True,
                        "failed_exporters": ["ServerMetricsJsonExporter"],
                    }
                },
            ),
        ]
        for profile_name, fixture_options in cases:
            with self.subTest(profile_name=profile_name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                fixture = root / "fixture"
                write_valid_runner_exports(fixture, **fixture_options)
                result, destination = run_weka_fixture(
                    root, fixture, profile_name=profile_name
                )
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("AIPerf results readiness", result.stderr)
                self.assertNotEqual(
                    (destination / "EXIT").read_text(encoding="utf-8"),
                    "EXIT=0\n",
                )

    def test_weka_runner_rejects_unqualified_request_results(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
                record_error=True,
            )
            result, destination = run_weka_fixture(
                root, fixture, profile_name="unqualified"
            )
            self.assertNotEqual(result.returncode, 0, result.stderr)
            summary = json.loads(
                (destination / "summary.json").read_text(encoding="utf-8")
            )
            self.assertFalse(summary["qualified"])
            self.assertIn("request results are not qualified", result.stderr)

    def test_weka_runner_verifies_exact_client_revision_and_full_corpus(self) -> None:
        cases = (
            ("AIPERF_COMMIT", {"TEST_WEKA_AIPERF_COMMIT": "f" * 40}),
            (
                "AIPerf Weka timing patch",
                {"TEST_WEKA_AIPERF_PATCH_SHA256": "f" * 64},
            ),
            ("WEKA_REVISION", {"TEST_WEKA_REVISION": "e" * 40}),
            ("393 traces", {"TEST_WEKA_TRACE_COUNT": "392"}),
            ("full subagents", {"TEST_WEKA_FULL_SUBAGENTS": "0"}),
        )
        for expected, overrides in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                fixture = root / "fixture"
                write_valid_runner_exports(
                    fixture,
                    readiness={
                        "ready": True,
                        "was_cancelled": False,
                        "partial": False,
                    },
                )
                result, _ = run_weka_fixture(
                    root,
                    fixture,
                    profile_name="pin-check",
                    environment_overrides=overrides,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_weka_runner_revalidates_pins_before_reusing_completed_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )
            first, destination = run_weka_fixture(
                root,
                fixture,
                profile_name="resume-pin-check",
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(
                (destination / "EXIT").read_text(encoding="utf-8"), "EXIT=0\n"
            )

            resumed, _ = run_weka_fixture(
                root,
                fixture,
                profile_name="resume-pin-check",
                environment_overrides={"TEST_WEKA_AIPERF_COMMIT": "f" * 40},
            )

            self.assertNotEqual(resumed.returncode, 0)
            self.assertIn("checked-out AIPERF_COMMIT", resumed.stderr)

    def test_weka_runner_rejects_tampered_completed_run_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )
            first, destination = run_weka_fixture(
                root,
                fixture,
                profile_name="resume-provenance-check",
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            provenance_path = destination / "provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["aiperf_commit"] = "f" * 40
            provenance_path.write_text(
                json.dumps(provenance, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            resumed, _ = run_weka_fixture(
                root,
                fixture,
                profile_name="resume-provenance-check",
            )

            self.assertNotEqual(resumed.returncode, 0)
            self.assertIn("recorded AIPerf commit", resumed.stderr)

    def test_weka_runner_rejects_type_confused_provenance_scalars(self) -> None:
        cases: tuple[tuple[str, object], ...] = (
            ("schema_version", True),
            ("concurrency", False),
            ("repetition", True),
            ("trace_count", 393.0),
            ("full_subagents", 1),
        )
        for field, forged in cases:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                fixture = root / "fixture"
                write_valid_runner_exports(
                    fixture,
                    readiness={
                        "ready": True,
                        "was_cancelled": False,
                        "partial": False,
                    },
                )
                first, destination = run_weka_fixture(
                    root,
                    fixture,
                    profile_name="resume-provenance-types",
                )
                self.assertEqual(first.returncode, 0, first.stderr)
                provenance_path = destination / "provenance.json"
                provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
                provenance[field] = forged
                provenance_path.write_text(
                    json.dumps(provenance, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )

                resumed, _ = run_weka_fixture(
                    root,
                    fixture,
                    profile_name="resume-provenance-types",
                )

                self.assertNotEqual(resumed.returncode, 0, field)
                self.assertIn("recorded", resumed.stderr)

    def test_weka_runner_rederives_summary_without_rewriting_recorded_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )
            first, destination = run_weka_fixture(
                root,
                fixture,
                profile_name="resume-summary-immutability",
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            summary_path = destination / "summary.json"
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            summary["forged"] = True
            forged_summary = json.dumps(summary, indent=2, sort_keys=True) + "\n"
            summary_path.write_text(forged_summary, encoding="utf-8")
            provenance_path = destination / "provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["artifacts"]["summary.json"] = hashlib.sha256(
                summary_path.read_bytes()
            ).hexdigest()
            provenance_path.write_text(
                json.dumps(provenance, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            resumed, _ = run_weka_fixture(
                root,
                fixture,
                profile_name="resume-summary-immutability",
            )

            self.assertNotEqual(resumed.returncode, 0)
            self.assertIn("rederived summary differs", resumed.stderr)
            self.assertEqual(summary_path.read_text(encoding="utf-8"), forged_summary)

    def test_weka_runner_requires_exported_engine_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
                missing_server_metric="vllm:num_requests_waiting",
            )
            result, destination = run_weka_fixture(
                root, fixture, profile_name="missing-metric"
            )
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertTrue((destination / "summary.json").is_file())
            self.assertIn("waiting_requests_max", result.stderr)

    def test_weka_runner_revalidates_an_existing_success_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture"
            write_valid_runner_exports(
                fixture,
                readiness={
                    "ready": True,
                    "was_cancelled": False,
                    "partial": False,
                },
            )
            first, destination = run_weka_fixture(
                root, fixture, profile_name="existing"
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            (destination / ".aiperf_results_ready.json").unlink()
            second, _ = run_weka_fixture(root, fixture, profile_name="existing")
            self.assertNotEqual(second.returncode, 0, second.stderr)
            self.assertIn(
                "recorded artifact is missing or unsafe: .aiperf_results_ready.json",
                second.stderr,
            )

    def test_weka_runner_rejects_aiperf_cancelled_success(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runs_root = root / "runs"
            run_root = runs_root / "20990101T000000Z"
            run_root.mkdir(parents=True)
            manifest = run_root / "manifest.env"
            manifest.write_text(
                "AIPERF_COMMIT=ea28b2e81c7367f8403c6f6ebe0837a508795a8d\n"
                "WEKA_REPOSITORY=semianalysisai/cc-traces-weka-062126\n"
                "WEKA_REVISION=23f152f6f0f9399a85901b89a6458def0ef16729\n",
                encoding="utf-8",
            )
            os.chmod(manifest, 0o600)
            dataset = root / "traces"
            dataset.mkdir()
            (dataset / "trace.json").write_text(
                '{"id":"fixture","requests":[]}\n', encoding="utf-8"
            )
            tokenizer = root / "tokenizer"
            tokenizer.mkdir()
            key_file = root / "benchmark.key"
            key_file.write_text("test-weka-secret\n", encoding="utf-8")
            os.chmod(key_file, 0o600)
            fake = root / "aiperf"
            fake.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "config=\n"
                "while (($#)); do\n"
                "  if [[ $1 == --config ]]; then config=$2; shift 2; else shift; fi\n"
                "done\n"
                "printf '%s\\n' '{\"ready\":true,\"was_cancelled\":true,\"partial\":false}' "
                ">\"$(dirname \"$config\")/.aiperf_results_ready.json\"\n",
                encoding="utf-8",
            )
            os.chmod(fake, 0o700)
            result = subprocess.run(
                [
                    "bash",
                    str(RUNNER),
                    "--run-root",
                    str(run_root),
                    "--profile-name",
                    "cancelled",
                    "--repetition",
                    "1",
                    "--key-file",
                    str(key_file),
                    "--fixed-schedule",
                    "--internal",
                ],
                cwd=REPOSITORY_ROOT,
                env={
                    **os.environ,
                    "WEBSTER_WEKA_RUNS_ROOT": str(runs_root),
                    "WEBSTER_WEKA_TEST_MODE": "1",
                    "WEBSTER_WEKA_AIPERF_BIN": str(fake),
                    "WEBSTER_WEKA_DATASET": str(dataset),
                    "WEBSTER_WEKA_TOKENIZER": str(tokenizer),
                },
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            destination = run_root / "aiperf" / "cancelled-r1-fixed"
            self.assertEqual((destination / "EXIT").read_text(), "EXIT=130\n")
            self.assertIn("AIPerf run was cancelled", result.stderr)


if __name__ == "__main__":
    unittest.main()
