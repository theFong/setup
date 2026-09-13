#!/usr/bin/env python3
"""Repository contract tests for the DeepSeek V4.1 cutover package."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
PACKAGE_ROOT = REPOSITORY_ROOT / "webster" / "deepseek-v41"
MIGRATION_SKILL_ROOT = REPOSITORY_ROOT / ".agent" / "skills" / "migrating-webster-models"


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
        self.assertNotRegex(scripts, r"Authorization:\s*Bearer\s+[A-Za-z0-9]")

    def test_safety_critical_embedded_python_does_not_depend_on_assert(self) -> None:
        for relative_path in (
            "scripts/acceptance.sh",
            "scripts/install-glm52-guard.sh",
        ):
            with self.subTest(path=relative_path):
                self.assertNotRegex(read(relative_path), r"\bassert\s")

    def test_cluster_command_wrapper_scrubs_ssh_agent_and_disables_forwarding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake = root / "ssh"
            fake.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "test -z \"${SSH_AUTH_SOCK:-}\"\n"
                "test \"$1\" = -o\n"
                "test \"$2\" = ForwardAgent=no\n"
                "printf '%s\\n' \"$@\"\n",
                encoding="utf-8",
            )
            os.chmod(fake, 0o700)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; SSH_AUTH_SOCK=/tmp/inherited-agent; export SSH_AUTH_SOCK; ssh shamu true',
                    "bash",
                    str(PACKAGE_ROOT / "scripts" / "common.sh"),
                ],
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}"},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.splitlines(),
                ["-o", "ForwardAgent=no", "shamu", "true"],
            )
        start = read("scripts/start-deepseek-v41-tp2.sh")
        self.assertIn(
            "env -u SSH_AUTH_SOCK ssh -o ForwardAgent=no",
            start,
            "the Shamu-to-Tilikum composed path must scrub the remote shell too",
        )

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
            "scripts/acceptance.sh",
            "scripts/render-litellm-cutover.py",
            "scripts/verify-litellm-config.py",
            "scripts/verify-litellm-container.py",
            "scripts/install-glm52-guard.sh",
            "scripts/restore-litellm-config.sh",
            "scripts/sync-runbook.sh",
            "scripts/contract-probe.py",
        ):
            with self.subTest(path=relative_path):
                self.assertTrue((PACKAGE_ROOT / relative_path).is_file())

    def test_closeout_scripts_encode_publication_and_skill_sync_contracts(self) -> None:
        acceptance = read("scripts/acceptance.sh")
        publication_probes = read("scripts/publication-model-probes.py")
        publication_entrypoint = acceptance + "\n" + publication_probes
        for literal in (
            "deepseek-v4.1-flash",
            "glm-5.2",
            "glm-5.3-flash",
            "deepseek-v4-flash",
            "deepseek-v41-watchdog.timer",
            "PUBLISH_CONFIG_BACKUP",
        ):
            self.assertIn(literal, publication_entrypoint)
        sync = read("scripts/sync-runbook.sh")
        for literal in (
            "migrating-webster-models",
            "WEBSTER_CLUSTER_SOURCE",
            "WEBSTER_MIGRATION_SOURCE",
            ".claude/skills",
            ".codex/skills",
            ".hermes/skills/devops",
            "check-skill-drift.sh",
            "COLUMNS=240",
            "skills list --source local",
        ):
            self.assertIn(literal, sync)

    def test_migration_skill_retains_observed_closeout_lessons(self) -> None:
        playbook = (MIGRATION_SKILL_ROOT / "references" / "playbook.md").read_text(
            encoding="utf-8"
        )
        for lesson in (
            "phase-specific owner",
            "hostname resolution",
            "FlashInfer autotune",
            "cold-prefill",
            "recent-log matcher",
            "acceptance entry point",
            "legacy pair identity",
            "runtime patch",
            "executable bits",
            "dependency closure",
            "AIPERF_DATASET_CONFIGURATION_TIMEOUT",
            "Never rewrite a failed `EXIT`",
            "freshness budget",
            "dynamic pricing",
            "`brev refresh`",
            "grouped request counts",
            "stale recovery controller",
            "migration-critical aliases",
            "client-visible top-level error",
            "retired model",
        ):
            self.assertIn(lesson, playbook)

    def test_readme_records_final_reconciliation(self) -> None:
        documentation = read("README.md")
        for fact in (
            "9.122 seconds",
            "inkling-watchdog.timer",
            "10/10 Prometheus targets",
            "openwebui-shamu-5",
        ):
            self.assertIn(fact, documentation)

    def test_migration_skill_requires_fresh_cryptographic_publication_evidence(self) -> None:
        skill = (MIGRATION_SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        playbook = (MIGRATION_SKILL_ROOT / "references" / "playbook.md").read_text(
            encoding="utf-8"
        )
        combined = skill + "\n" + playbook
        for requirement in (
            "17-case",
            "failure-log-output",
            "generate-private-acceptance.py",
            "verify-private-acceptance.py",
            "accepted_at",
            "exact rendered Hermes",
            "--force",
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, combined)

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

    def test_preflight_captures_the_phase_owner_without_requiring_stopped_glm(self) -> None:
        preflight = read("scripts/preflight.sh")
        self.assertIn('station_inspect_shamu="docker inspect \'$GLM_CONTAINER\'"', preflight)
        self.assertIn('station_inspect_tilikum="sudo -n docker inspect \'$GLM_CONTAINER\'"', preflight)
        self.assertIn('if [[ "$phase" == "publish" ]]; then', preflight)
        self.assertIn('station_inspect_shamu="docker inspect \'$DEEPSEEK_CONTAINER\'"', preflight)
        self.assertIn('station_inspect_tilikum="sudo -n docker inspect \'$DEEPSEEK_CONTAINER\'"', preflight)
        capture_block = preflight.split("station_inspect_format=", 1)[1].split(
            'shamu_free="', 1
        )[0]
        self.assertNotIn(
            "docker inspect glm52-full-mtp --format",
            capture_block,
            "publication host capture must not unconditionally inspect stopped GLM",
        )

    def test_glm_fast_path_validates_the_complete_rollback_runtime_shape(self) -> None:
        start = read("scripts/start-glm52-tp2.sh")
        for requirement in (
            'config.get("WorkingDir") == "/vllm-workspace"',
            'host.get("ShmSize") == 34359738368',
            '"label=disable" in (host.get("SecurityOpt") or [])',
            '(ulimits.get("memlock") or {}).get("Soft") == -1',
            '(ulimits.get("stack") or {}).get("Soft") == 67108864',
            'item.get("PathOnHost") == "/dev/infiniband"',
            'bool(host.get("DeviceRequests"))',
            'mounts.get("/model") or {}',
            'mounts.get("/root/.cache") or {}',
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, start)

    def test_deepseek_live_evidence_supports_the_exact_unlabeled_legacy_pair(self) -> None:
        start = read("scripts/start-deepseek-v41-tp2.sh")
        for requirement in (
            'require(all(labels_present), "has partial serving labels")',
            '"container_id": data.get("Id")',
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, start)
        self.assertNotIn(
            'require(isinstance(generation, str) and generation, "has no serving generation")',
            start,
        )
        runner = read("scripts/run-weka.sh")
        self.assertIn('"--print-generation"', runner)
        self.assertIn('"container_id": value.get("Id")', runner)


if __name__ == "__main__":
    unittest.main()
