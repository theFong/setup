#!/usr/bin/env python3
"""Verify an immutable DeepSeek V4.1 checkpoint and emit its manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath


DEFAULT_SHARDS = 48
DEFAULT_TENSOR_BYTES = 510_286_023_000
DEFAULT_SHARD_FILE_BYTES = 510_296_708_312
REQUIRED_FILES = (
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "encoding/encoding.py",
    "encoding/test_encoding.py",
    "encoding/tests/test_input_1.json",
    "encoding/tests/test_output_1.txt",
    "inference/config.json",
)


class VerificationError(RuntimeError):
    pass


def contained_file(root: Path, relative_name: str) -> Path:
    relative = PurePosixPath(relative_name)
    if relative.is_absolute() or ".." in relative.parts:
        raise VerificationError(f"unsafe checkpoint path: {relative_name}")
    candidate = root.joinpath(*relative.parts)
    try:
        resolved = candidate.resolve(strict=True)
    except FileNotFoundError as error:
        raise VerificationError(f"missing referenced shard: {relative_name}") from error
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise VerificationError(f"path escapes checkpoint: {relative_name}") from error
    if not resolved.is_file():
        raise VerificationError(f"checkpoint path is not a file: {relative_name}")
    return resolved


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def build_manifest(
    checkpoint: Path,
    expected_shards: int,
    expected_tensor_bytes: int,
    expected_shard_file_bytes: int,
) -> list[str]:
    root = checkpoint.resolve(strict=True)
    if not root.is_dir():
        raise VerificationError(f"checkpoint is not a directory: {checkpoint}")

    index_path = contained_file(root, "model.safetensors.index.json")
    try:
        index = json.loads(index_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise VerificationError(f"invalid safetensors index: {error}") from error
    weight_map = index.get("weight_map")
    if not isinstance(weight_map, dict) or not weight_map:
        raise VerificationError("safetensors index has no weight_map")

    shard_names = sorted(set(weight_map.values()))
    if not all(isinstance(name, str) and name for name in shard_names):
        raise VerificationError("safetensors index contains an invalid shard name")
    if len(shard_names) != expected_shards:
        raise VerificationError(
            f"shard count mismatch: expected {expected_shards}, got {len(shard_names)}"
        )

    shards = [contained_file(root, name) for name in shard_names]
    shard_file_bytes = sum(path.stat().st_size for path in shards)
    if shard_file_bytes != expected_shard_file_bytes:
        raise VerificationError(
            "shard file bytes mismatch: "
            f"expected {expected_shard_file_bytes}, got {shard_file_bytes}"
        )
    metadata_size = index.get("metadata", {}).get("total_size")
    if metadata_size != expected_tensor_bytes:
        raise VerificationError(
            "index total_size mismatch: "
            f"expected {expected_tensor_bytes}, got {metadata_size}"
        )

    present_safetensors = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*.safetensors")
        if path.is_file()
    }
    referenced_safetensors = {
        path.relative_to(root).as_posix() for path in shards
    }
    extras = sorted(present_safetensors - referenced_safetensors)
    if extras:
        raise VerificationError(f"unreferenced safetensors shards: {', '.join(extras)}")

    for required in REQUIRED_FILES:
        try:
            contained_file(root, required)
        except VerificationError as error:
            raise VerificationError(f"missing required checkpoint file: {required}") from error

    files: list[tuple[str, Path]] = []
    for candidate in root.rglob("*"):
        if not candidate.is_file() and not candidate.is_symlink():
            continue
        relative = candidate.relative_to(root).as_posix()
        resolved = contained_file(root, relative)
        files.append((relative, resolved))

    return sorted(
        f"{sha256_file(path)}  {path.stat().st_size}  {relative}"
        for relative, path in files
        if relative != "MANIFEST.sha256"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("--expected-shards", type=int, default=DEFAULT_SHARDS)
    parser.add_argument("--expected-tensor-bytes", type=int, default=DEFAULT_TENSOR_BYTES)
    parser.add_argument(
        "--expected-shard-file-bytes", type=int, default=DEFAULT_SHARD_FILE_BYTES
    )
    parser.add_argument("--compare-manifest", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        manifest = build_manifest(
            args.checkpoint,
            args.expected_shards,
            args.expected_tensor_bytes,
            args.expected_shard_file_bytes,
        )
        rendered = "\n".join(manifest) + "\n"
        stored_manifest_path = args.checkpoint / "MANIFEST.sha256"
        if stored_manifest_path.exists() or stored_manifest_path.is_symlink():
            stored_manifest = contained_file(
                args.checkpoint.resolve(strict=True), "MANIFEST.sha256"
            ).read_text(encoding="utf-8")
            if stored_manifest != rendered:
                raise VerificationError("stored manifest mismatch")
        if args.compare_manifest is not None:
            comparison = args.compare_manifest.read_text(encoding="utf-8")
            if comparison != rendered:
                raise VerificationError("manifest mismatch")
        sys.stdout.write(rendered)
    except (OSError, VerificationError) as error:
        print(f"checkpoint verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
