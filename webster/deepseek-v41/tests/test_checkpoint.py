#!/usr/bin/env python3
"""Behavior tests for immutable checkpoint verification."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
VERIFIER = (
    REPOSITORY_ROOT
    / "webster"
    / "deepseek-v41"
    / "scripts"
    / "verify-checkpoint.py"
)


class CheckpointVerifierTests(unittest.TestCase):
    def make_checkpoint(self, root: Path, sizes: tuple[int, ...] = (5, 7)) -> Path:
        checkpoint = root / "checkpoint"
        checkpoint.mkdir()
        weight_map: dict[str, str] = {}
        for index, size in enumerate(sizes, start=1):
            name = f"model-{index:05d}-of-{len(sizes):05d}.safetensors"
            (checkpoint / name).write_bytes(bytes([index]) * size)
            weight_map[f"layer.{index}.weight"] = name
        (checkpoint / "model.safetensors.index.json").write_text(
            json.dumps({"metadata": {"total_size": sum(sizes)}, "weight_map": weight_map}),
            encoding="utf-8",
        )
        for name in (
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "encoding/encoding.py",
            "encoding/test_encoding.py",
            "encoding/tests/test_input_1.json",
            "encoding/tests/test_output_1.txt",
            "inference/config.json",
        ):
            path = checkpoint / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"fixture:{name}\n", encoding="utf-8")
        return checkpoint

    def run_verifier(self, checkpoint: Path, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(VERIFIER),
                str(checkpoint),
                "--expected-shards",
                "2",
                "--expected-shard-file-bytes",
                "12",
                "--expected-tensor-bytes",
                "12",
                *extra,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_valid_checkpoint_emits_sorted_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = self.make_checkpoint(Path(temporary))
            result = self.run_verifier(checkpoint)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = result.stdout.splitlines()
        self.assertEqual(rows, sorted(rows))
        self.assertTrue(any(row.endswith("model-00001-of-00002.safetensors") for row in rows))
        self.assertTrue(any("  5  model-00001-of-00002.safetensors" in row for row in rows))

    def test_missing_referenced_shard_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = self.make_checkpoint(Path(temporary))
            (checkpoint / "model-00002-of-00002.safetensors").unlink()
            result = self.run_verifier(checkpoint)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing referenced shard", result.stderr)

    def test_weight_byte_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = self.make_checkpoint(Path(temporary), sizes=(5, 6))
            result = self.run_verifier(checkpoint)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("shard file bytes mismatch", result.stderr)

    def test_index_tensor_byte_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = self.make_checkpoint(Path(temporary))
            index_path = checkpoint / "model.safetensors.index.json"
            index = json.loads(index_path.read_text(encoding="utf-8"))
            index["metadata"]["total_size"] = 11
            index_path.write_text(json.dumps(index), encoding="utf-8")
            result = self.run_verifier(checkpoint)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("index total_size mismatch", result.stderr)

    def test_duplicate_index_shard_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = self.make_checkpoint(Path(temporary))
            index_path = checkpoint / "model.safetensors.index.json"
            index = json.loads(index_path.read_text(encoding="utf-8"))
            index["weight_map"]["layer.2.weight"] = "model-00001-of-00002.safetensors"
            index_path.write_text(json.dumps(index), encoding="utf-8")
            result = self.run_verifier(checkpoint)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("shard count mismatch", result.stderr)

    def test_unreferenced_extra_shard_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = self.make_checkpoint(Path(temporary))
            (checkpoint / "unreferenced.safetensors").write_bytes(b"extra")
            result = self.run_verifier(checkpoint)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unreferenced safetensors", result.stderr)

    def test_parent_traversal_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkpoint = self.make_checkpoint(root)
            outside = root / "outside.safetensors"
            outside.write_bytes(b"1234567")
            index_path = checkpoint / "model.safetensors.index.json"
            index = json.loads(index_path.read_text(encoding="utf-8"))
            index["weight_map"]["layer.2.weight"] = "../outside.safetensors"
            index_path.write_text(json.dumps(index), encoding="utf-8")
            result = self.run_verifier(checkpoint)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe checkpoint path", result.stderr)

    def test_symlink_that_escapes_checkpoint_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkpoint = self.make_checkpoint(root)
            outside = root / "outside.safetensors"
            outside.write_bytes(b"1234567")
            shard = checkpoint / "model-00002-of-00002.safetensors"
            shard.unlink()
            shard.symlink_to(outside)
            result = self.run_verifier(checkpoint)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("escapes checkpoint", result.stderr)

    def test_compare_manifest_rejects_cross_node_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkpoint = self.make_checkpoint(root)
            comparison = root / "other.manifest"
            comparison.write_text("different\n", encoding="utf-8")
            result = self.run_verifier(
                checkpoint, "--compare-manifest", str(comparison)
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest mismatch", result.stderr)

    def test_stored_manifest_detects_post_promotion_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = self.make_checkpoint(Path(temporary))
            initial = self.run_verifier(checkpoint)
            self.assertEqual(initial.returncode, 0, initial.stderr)
            (checkpoint / "MANIFEST.sha256").write_text(
                initial.stdout, encoding="utf-8"
            )
            verified = self.run_verifier(checkpoint)
            self.assertEqual(verified.returncode, 0, verified.stderr)

            (checkpoint / "config.json").write_text(
                "tampered\n", encoding="utf-8"
            )
            result = self.run_verifier(checkpoint)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stored manifest mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
