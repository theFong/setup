#!/usr/bin/env python3
"""Behavior tests for matching two-rank serving generations."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
VERIFIER = (
    REPOSITORY_ROOT
    / "webster"
    / "deepseek-v41"
    / "scripts"
    / "verify-serving-pair.py"
)


def verify(
    rank0: dict[str, object],
    rank1: dict[str, object],
    *,
    require_matching_image: bool = False,
    print_generation: bool = False,
) -> subprocess.CompletedProcess[str]:
    command = [
        sys.executable,
        str(VERIFIER),
        "--rank0-state-json",
        json.dumps(rank0, separators=(",", ":")),
        "--rank1-state-json",
        json.dumps(rank1, separators=(",", ":")),
        "--max-start-skew-seconds",
        "120",
    ]
    if require_matching_image:
        command.append("--require-matching-image")
    if print_generation:
        command.append("--print-generation")
    return subprocess.run(
        command,
        cwd=REPOSITORY_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


class ServingPairTests(unittest.TestCase):
    def test_legacy_pair_emits_a_stable_derived_generation(self) -> None:
        rank0 = {
            "container_id": "a" * 64,
            "generation": None,
            "started_at": "2026-09-12T16:41:07.263876192Z",
        }
        rank1 = {
            "container_id": "b" * 64,
            "generation": None,
            "started_at": "2026-09-12T16:41:08.329565990Z",
        }
        first = verify(rank0, rank1, print_generation=True)
        second = verify(rank0, rank1, print_generation=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertRegex(first.stdout.strip(), r"^legacy-[0-9a-f]{64}$")
        self.assertEqual(first.stdout, second.stdout)

    def test_legacy_pair_accepts_docker_nanosecond_timestamps(self) -> None:
        result = verify(
            {
                "generation": None,
                "started_at": "2026-09-12T16:41:07.263876192Z",
            },
            {
                "generation": None,
                "started_at": "2026-09-12T16:41:08.329565990Z",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_labeled_pair_requires_the_same_nonempty_generation(self) -> None:
        result = verify(
            {
                "generation": "generation-a",
                "started_at": "2026-09-12T16:41:07Z",
            },
            {
                "generation": "generation-b",
                "started_at": "2026-09-12T16:41:08Z",
            },
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different generations", result.stderr)

    def test_unlabeled_pair_rejects_excessive_start_skew(self) -> None:
        result = verify(
            {"generation": None, "started_at": "2026-09-12T16:40:00Z"},
            {"generation": None, "started_at": "2026-09-12T16:43:00Z"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not started as one generation", result.stderr)

    def test_glm_pair_requires_matching_nonempty_image_ids(self) -> None:
        result = verify(
            {
                "image": "sha256:" + "a" * 64,
                "started_at": "2026-09-12T16:41:07Z",
            },
            {
                "image": "sha256:" + "b" * 64,
                "started_at": "2026-09-12T16:41:08Z",
            },
            require_matching_image=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different image generations", result.stderr)


if __name__ == "__main__":
    unittest.main()
