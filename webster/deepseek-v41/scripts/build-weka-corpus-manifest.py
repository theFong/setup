#!/usr/bin/env python3
"""Create a private split-trace manifest from one pinned Weka source JSONL."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import BinaryIO


SHA256 = re.compile(r"^[0-9a-f]{64}$")
REVISION = re.compile(r"^[0-9a-f]{40}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
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


def build(args: argparse.Namespace) -> dict[str, object]:
    if not args.repository or REVISION.fullmatch(args.revision) is None:
        fail("Weka repository or revision is malformed")
    if SHA256.fullmatch(args.source_sha256) is None:
        fail("Weka source hash is malformed")
    if args.source_size <= 0 or args.trace_count <= 0:
        fail("Weka source size or trace count is invalid")
    if not args.dataset.is_dir() or args.dataset.is_symlink():
        fail("Weka dataset must be a regular non-symlink directory")
    dataset = args.dataset.resolve(strict=True)
    output = args.output.absolute()
    if output.parent.resolve(strict=True) != dataset.parent or output.is_symlink():
        fail("Weka corpus manifest output must be beside the trace directory")
    source = dataset.parent / "traces.jsonl"
    if not source.is_file() or source.is_symlink():
        fail("pinned Weka source JSONL is missing")
    if source.stat().st_size != args.source_size:
        fail("pinned Weka source size differs")
    with source.open("rb") as handle:
        if sha256_stream(handle) != args.source_sha256:
            fail("pinned Weka source hash differs")

    expected_names = [f"trace-{index:03d}.json" for index in range(args.trace_count)]
    actual_names = sorted(path.name for path in dataset.glob("*.json"))
    if actual_names != expected_names:
        fail("Weka dataset does not contain the exact JSON trace set")
    files: dict[str, str] = {}
    with source.open("rb") as source_handle:
        for name in expected_names:
            source_line = source_handle.readline()
            if not source_line:
                fail("pinned Weka source has fewer traces than expected")
            path = dataset / name
            if not path.is_file() or path.is_symlink():
                fail(f"Weka split trace is missing or unsafe: {name}")
            with path.open("rb") as trace_handle:
                digest = sha256_stream(trace_handle)
            if hashlib.sha256(source_line).hexdigest() != digest:
                fail(f"Weka split trace does not match pinned source: {name}")
            files[name] = digest
        if source_handle.readline():
            fail("pinned Weka source has more traces than expected")

    return {
        "schema_version": 1,
        "repository": args.repository,
        "revision": args.revision,
        "source_sha256": args.source_sha256,
        "source_size": args.source_size,
        "trace_count": args.trace_count,
        "full_subagents": True,
        "files": files,
    }


def write_private_json(path: Path, value: object) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    try:
        value = build(args)
        write_private_json(args.output, value)
    except (OSError, RuntimeError, UnicodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Weka corpus manifest written: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
