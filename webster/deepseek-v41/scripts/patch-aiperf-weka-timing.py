#!/usr/bin/env python3
"""Apply the pinned AIPerf Weka fixed-schedule timing fix safely."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


RELATIVE_RESOLVER = Path("src/aiperf/config/dataset/resolver.py")
UNPATCHED = (
    "            CustomDatasetType.BURST_GPT_TRACE,\n"
    "            CustomDatasetType.BASETEN_TRACE,\n"
    "            CustomDatasetType.TRACELAB,\n"
)
PATCHED = UNPATCHED + "            CustomDatasetType.WEKA_TRACE,\n"


def apply_patch(source: Path) -> None:
    source = source.resolve(strict=True)
    resolver = source / RELATIVE_RESOLVER
    if resolver.is_symlink() or not resolver.is_file():
        raise ValueError(f"AIPerf resolver is not a regular file: {resolver}")
    if not resolver.resolve(strict=True).is_relative_to(source):
        raise ValueError(f"AIPerf resolver escapes source root: {resolver}")

    original = resolver.read_text(encoding="utf-8")
    if original.count(PATCHED) == 1:
        print(f"GO AIPerf Weka timing patch already active: {resolver}")
        return
    if original.count(UNPATCHED) != 1:
        raise ValueError(
            "unsupported AIPerf resolver source; refusing an ambiguous patch"
        )

    updated = original.replace(UNPATCHED, PATCHED, 1)
    temporary = resolver.with_name(f".{resolver.name}.tmp.{os.getpid()}")
    try:
        temporary.write_text(updated, encoding="utf-8")
        temporary.chmod(resolver.stat().st_mode & 0o777)
        os.replace(temporary, resolver)
    finally:
        temporary.unlink(missing_ok=True)

    verified = resolver.read_text(encoding="utf-8")
    if verified.count(PATCHED) != 1:
        raise RuntimeError("AIPerf Weka timing patch verification failed")
    print(f"GO applied AIPerf Weka timing patch: {resolver}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    args = parser.parse_args()
    try:
        apply_patch(args.source)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
