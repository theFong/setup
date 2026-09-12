#!/usr/bin/env python3
"""Repository contract tests for the DeepSeek V4.1 cutover package."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
PACKAGE_ROOT = REPOSITORY_ROOT / "webster" / "deepseek-v41"


def read(relative_path: str) -> str:
    return (PACKAGE_ROOT / relative_path).read_text(encoding="utf-8")


def shell_script_paths() -> list[Path]:
    scripts = PACKAGE_ROOT / "scripts"
    return sorted(scripts.glob("*.sh")) if scripts.exists() else []


class FoundationContractTests(unittest.TestCase):
    def test_foundation_files_exist(self) -> None:
        for relative_path in (
            ".gitignore",
            "manifest.env.example",
            "README.md",
            "scripts/common.sh",
            "scripts/preflight.sh",
        ):
            with self.subTest(path=relative_path):
                self.assertTrue((PACKAGE_ROOT / relative_path).is_file())

    def test_station_topology_is_pinned(self) -> None:
        common = read("scripts/common.sh")
        for literal in (
            'SHAMU_NETBIRD="100.73.140.127"',
            'SHAMU_RAIL="10.10.1.1"',
            'TILIKUM_RAIL="10.10.1.2"',
            'NCCL_IFACE="enP1p3s0f1np1"',
            'NCCL_HCA="mlx5_1"',
        ):
            self.assertIn(literal, common)

    def test_checkpoint_and_capacity_contract_is_pinned(self) -> None:
        common = read("scripts/common.sh")
        for literal in (
            'MIN_FREE_BEFORE_STAGE_BYTES="805306368000"',
            'MIN_FREE_AFTER_STAGE_BYTES="214748364800"',
            'CHECKPOINT_REPO="deepseek-ai/DeepSeek-V4.1-Flash"',
            'CHECKPOINT_REVISION="dba1be0a40aa45a94ad051997016db3960a90277"',
            'CHECKPOINT_SHARDS="48"',
            'CHECKPOINT_TENSOR_BYTES="510286023000"',
            'CHECKPOINT_SHARD_FILE_BYTES="510296708312"',
        ):
            self.assertIn(literal, common)

    def test_manifest_requires_execution_time_pins(self) -> None:
        manifest = read("manifest.env.example")
        for field in (
            "VLLM_COMMIT",
            "VLLM_BASE_IMAGE_DIGEST",
            "VLLM_BUILD_BASE_IMAGE_DIGEST",
            "VLLM_FINAL_BASE_IMAGE_DIGEST",
            "VLLM_SOURCE_ARCHIVE_SHA256",
            "VLLM_IMAGE_ID",
            "VLLM_IMAGE_TAR_SHA256",
            "AIPERF_COMMIT",
            "WEKA_REPOSITORY",
            "WEKA_REVISION",
        ):
            self.assertRegex(manifest, rf"(?m)^{field}=\s*$")

    def test_limited_downtime_sequence_is_documented(self) -> None:
        documentation = read("README.md")
        sequence = (
            "freeze rollback -> stage additively -> route alias -> restart once -> hot soak\n"
            "-> stop both GLM ranks -> private canary/tuning -> register new name -> restart once"
        )
        self.assertIn(sequence, documentation)
        self.assertIn("60-second", documentation)
        self.assertIn("5–15 minute", documentation)

    def test_baker_route_is_never_a_mutation_target(self) -> None:
        for path in shell_script_paths():
            script = path.read_text(encoding="utf-8")
            self.assertNotIn("100.73.127.129:8888", script, path)
            self.assertNotRegex(script, r"ssh\s+baker-spark-[12]", path)

    def test_no_secret_on_command_line(self) -> None:
        scripts = "\n".join(
            path.read_text(encoding="utf-8") for path in shell_script_paths()
        )
        self.assertNotRegex(scripts, r"--api-key(?:=|\s+)[^\"'$]")
        self.assertNotRegex(scripts, r"Authorization:\s*Bearer\s+\$\{")

    def test_aiperf_fixtures_are_parseable(self) -> None:
        profile = json.loads(read("tests/fixtures/aiperf-profile.json"))
        self.assertIn("metrics", profile)
        rows = [
            json.loads(line)
            for line in read("tests/fixtures/aiperf-errors.jsonl").splitlines()
            if line.strip()
        ]
        self.assertTrue(any(row.get("error") for row in rows))

    def test_root_runner_invokes_cutover_suites(self) -> None:
        runner = (REPOSITORY_ROOT / "test.sh").read_text(encoding="utf-8")
        self.assertIn(
            "python3 -m unittest discover -s webster/deepseek-v41/tests -p 'test_*.py'",
            runner,
        )
        self.assertIn(
            "bash webster/deepseek-v41/tests/test_failure_paths.sh", runner
        )
        self.assertTrue(
            re.search(
                r"if \[ -f webster/deepseek-v41/litellm/"
                r"test_glm52_contract_guard\.py \]",
                runner,
            )
        )

    def test_staging_files_exist(self) -> None:
        for relative_path in (
            "scripts/stage-artifacts.sh",
            "scripts/verify-checkpoint.py",
        ):
            with self.subTest(path=relative_path):
                self.assertTrue((PACKAGE_ROOT / relative_path).is_file())

    def test_checkpoint_downloader_keeps_xet_enabled(self) -> None:
        staging = read("scripts/stage-artifacts.sh")
        self.assertNotIn("HF_HUB_DISABLE_XET=1", staging)

    def test_litellm_cutover_files_exist(self) -> None:
        for relative_path in (
            "scripts/render-litellm-cutover.py",
            "scripts/verify-litellm-config.py",
            "scripts/verify-litellm-container.py",
            "scripts/install-glm52-guard.sh",
            "scripts/restore-litellm-config.sh",
            "scripts/contract-probe.py",
        ):
            with self.subTest(path=relative_path):
                self.assertTrue((PACKAGE_ROOT / relative_path).is_file())

    def test_runtime_package_files_exist(self) -> None:
        for relative_path in (
            "runtime/Dockerfile",
            "runtime/constraints.txt",
            "runtime/README.md",
            "scripts/build-runtime.sh",
        ):
            with self.subTest(path=relative_path):
                self.assertTrue((PACKAGE_ROOT / relative_path).is_file())

    def test_runtime_wrapper_cannot_mutate_upstream_image(self) -> None:
        dockerfile = read("runtime/Dockerfile")
        instructions = [
            line.split(maxsplit=1)[0].upper()
            for line in dockerfile.splitlines()
            if line and not line.startswith("#")
        ]
        self.assertEqual(instructions.count("FROM"), 1)
        self.assertIn("ARG", instructions)
        self.assertIn("LABEL", instructions)
        for forbidden in ("ADD", "COPY", "RUN"):
            self.assertNotIn(forbidden, instructions)


if __name__ == "__main__":
    unittest.main()
