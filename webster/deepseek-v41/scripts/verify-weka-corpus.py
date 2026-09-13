#!/usr/bin/env python3
"""Bind split Weka traces to one immutable source JSONL identity."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import BinaryIO


SHA256 = re.compile(r"^[0-9a-f]{64}$")
REVISION = re.compile(r"^[0-9a-f]{40}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--source-size", required=True, type=int)
    parser.add_argument("--trace-count", required=True, type=int)
    return parser.parse_args()


def sha256_stream(handle: BinaryIO) -> str:
    digest = hashlib.sha256()
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def fail(message: str) -> None:
    raise RuntimeError(message)


def verify(args: argparse.Namespace) -> None:
    if not args.repository or REVISION.fullmatch(args.revision) is None:
        fail("expected Weka repository or revision is malformed")
    if SHA256.fullmatch(args.source_sha256) is None:
        fail("expected Weka source hash is malformed")
    if args.source_size <= 0 or args.trace_count <= 0:
        fail("expected Weka source size or trace count is invalid")

    if not args.dataset.is_dir() or args.dataset.is_symlink():
        fail("Weka dataset must be a regular non-symlink directory")
    dataset = args.dataset.resolve(strict=True)
    source = dataset.parent / "traces.jsonl"
    if not source.is_file() or source.is_symlink():
        fail("pinned Weka source JSONL is missing")
    if source.stat().st_size != args.source_size:
        fail("pinned Weka source size differs")
    with source.open("rb") as handle:
        if sha256_stream(handle) != args.source_sha256:
            fail("pinned Weka source hash differs")

    if not args.manifest.is_file() or args.manifest.is_symlink():
        fail("Weka corpus manifest must be a regular non-symlink file")
    manifest_path = args.manifest.resolve(strict=True)
    if manifest_path.parent != dataset.parent:
        fail("Weka corpus manifest must be beside the trace directory")
    if stat.S_IMODE(manifest_path.stat().st_mode) != 0o600:
        fail("Weka corpus manifest must have mode 0600")
    value = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        fail("Weka corpus manifest is malformed")
    if (
        value.get("repository") != args.repository
        or value.get("revision") != args.revision
        or value.get("trace_count") != args.trace_count
        or value.get("full_subagents") is not True
        or value.get("source_sha256") != args.source_sha256
        or value.get("source_size") != args.source_size
    ):
        fail("Weka corpus manifest does not identify the pinned source")
    files = value.get("files")
    if not isinstance(files, dict):
        fail("Weka corpus manifest has no file identities")
    expected_names = {
        f"trace-{index:03d}.json" for index in range(args.trace_count)
    }
    if set(files) != expected_names:
        fail("Weka corpus manifest does not list the exact trace set")
    actual_names = {path.name for path in dataset.glob("*.json")}
    if actual_names != expected_names:
        fail("Weka dataset does not contain the exact JSON trace set")

    with source.open("rb") as source_handle:
        for index in range(args.trace_count):
            source_line = source_handle.readline()
            if not source_line:
                fail("pinned Weka source has fewer traces than expected")
            name = f"trace-{index:03d}.json"
            expected_hash = files[name]
            if not isinstance(expected_hash, str) or SHA256.fullmatch(expected_hash) is None:
                fail(f"Weka corpus file identity is malformed: {name}")
            path = dataset / name
            if not path.is_file() or path.is_symlink():
                fail(f"Weka corpus trace is missing or unsafe: {name}")
            resolved = path.resolve(strict=True)
            if not resolved.is_relative_to(dataset):
                fail(f"Weka corpus trace escapes the dataset: {name}")
            with resolved.open("rb") as trace_handle:
                actual_hash = sha256_stream(trace_handle)
            if actual_hash != expected_hash:
                fail(f"Weka corpus file hash differs: {name}")
            if hashlib.sha256(source_line).hexdigest() != actual_hash:
                fail(f"Weka corpus trace does not match pinned source: {name}")
        if source_handle.readline():
            fail("pinned Weka source has more traces than expected")


def main() -> int:
    args = parse_args()
    try:
        verify(args)
    except (OSError, RuntimeError, UnicodeError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "repository": args.repository,
                "revision": args.revision,
                "source_sha256": args.source_sha256,
                "source_size": args.source_size,
                "trace_count": args.trace_count,
                "full_subagents": True,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
