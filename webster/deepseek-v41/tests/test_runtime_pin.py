#!/usr/bin/env python3
"""Behavior tests for the fail-closed vLLM runtime pin decision."""

from __future__ import annotations

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = PACKAGE_ROOT / "scripts" / "pin-runtime.py"
HEAD_SHA = "7d81d62702b41885e2ff3ebc7ad9dfb638cc429c"
MERGE_SHA = "41fef9e0ed8b61342b232a3cf776a9cb695dadfe"
RELEASE_SHA = "a" * 40


def load_module():
    spec = importlib.util.spec_from_file_location("pin_runtime", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def passing_evidence() -> tuple[dict, list[dict], dict, dict]:
    pr = {
        "state": "open",
        "draft": False,
        "merged": False,
        "mergeable_state": "clean",
        "head": {"sha": HEAD_SHA},
        "merge_commit_sha": MERGE_SHA,
    }
    reviews = [
        {"state": "APPROVED", "user": {"login": "reviewer"}, "commit_id": HEAD_SHA}
    ]
    status = {
        "state": "success",
        "total_count": 1,
        "statuses": [{"context": "ci/test", "state": "success"}],
    }
    checks = {
        "total_count": 1,
        "check_runs": [
            {"name": "unit", "status": "completed", "conclusion": "success"}
        ],
    }
    return pr, reviews, status, checks


class RuntimePinDecisionTests(unittest.TestCase):
    def test_operational_script_is_directly_executable(self) -> None:
        self.assertTrue(os.access(MODULE_PATH, os.X_OK))

    def test_open_blocked_pr_is_rejected(self) -> None:
        module = load_module()
        pr, reviews, status, checks = passing_evidence()
        pr["mergeable_state"] = "blocked"

        with self.assertRaisesRegex(module.PinRejected, "mergeable_state=blocked"):
            module.select_runtime_pin(pr, reviews, status, checks, [])

    def test_pending_ci_is_rejected(self) -> None:
        module = load_module()
        pr, reviews, status, checks = passing_evidence()
        status["state"] = "pending"
        status["statuses"][0]["state"] = "pending"

        with self.assertRaisesRegex(module.PinRejected, "commit status is pending"):
            module.select_runtime_pin(pr, reviews, status, checks, [])

    def test_only_latest_status_per_context_is_evaluated(self) -> None:
        module = load_module()
        history = [
            {
                "context": "ci/test",
                "state": "success",
                "created_at": "2026-09-11T08:00:00Z",
            },
            {
                "context": "ci/test",
                "state": "pending",
                "created_at": "2026-09-11T07:00:00Z",
            },
            {
                "context": "ci/lint",
                "state": "success",
                "created_at": "2026-09-11T07:30:00Z",
            },
        ]

        current = module.latest_statuses_by_context(history)

        self.assertEqual(
            [(item["context"], item["state"]) for item in current],
            [("ci/lint", "success"), ("ci/test", "success")],
        )

    def test_clean_reviewed_open_pr_selects_exact_head(self) -> None:
        module = load_module()
        pr, reviews, status, checks = passing_evidence()

        selected = module.select_runtime_pin(pr, reviews, status, checks, [])

        self.assertEqual(selected, {"commit": HEAD_SHA, "source": "pr-head"})

    def test_release_containing_merged_change_is_preferred(self) -> None:
        module = load_module()
        pr, reviews, status, checks = passing_evidence()
        pr.update({"state": "closed", "merged": True})
        releases = [
            {
                "tag_name": "v0.99.0",
                "target_commit": RELEASE_SHA,
                "contains_merge_commit": True,
                "draft": False,
                "prerelease": False,
            }
        ]

        selected = module.select_runtime_pin(pr, reviews, status, checks, releases)

        self.assertEqual(
            selected,
            {"commit": RELEASE_SHA, "source": "release:v0.99.0"},
        )

    def test_existing_different_manifest_pin_is_never_overwritten(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "manifest.env"
            manifest.write_text("VLLM_COMMIT=" + ("b" * 40) + "\nOTHER=value\n")
            os.chmod(manifest, 0o600)

            with self.assertRaisesRegex(module.PinRejected, "already pins a different"):
                module.update_manifest(manifest, HEAD_SHA)

            self.assertEqual(
                manifest.read_text(),
                "VLLM_COMMIT=" + ("b" * 40) + "\nOTHER=value\n",
            )

    def test_pr_change_during_evidence_collection_is_rejected(self) -> None:
        module = load_module()
        before = {
            "state": "open",
            "draft": False,
            "merged": False,
            "mergeable_state": "clean",
            "updated_at": "2026-09-11T08:00:00Z",
            "head": {"sha": HEAD_SHA},
        }
        after = {
            **before,
            "updated_at": "2026-09-11T08:01:00Z",
            "head": {"sha": "c" * 40},
        }

        with self.assertRaisesRegex(module.PinRejected, "changed during evidence collection"):
            module.require_stable_pr(before, after)


if __name__ == "__main__":
    unittest.main()
