#!/usr/bin/env python3
"""Verify that an installed vLLM registry exposes a required model class."""

from __future__ import annotations

import argparse
import importlib.util
import re
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-root", type=Path)
    parser.add_argument("--require-model", required=True)
    return parser.parse_args()


def discover_package_roots() -> list[Path]:
    spec = importlib.util.find_spec("vllm")
    if spec is None or spec.submodule_search_locations is None:
        raise SystemExit("installed vLLM package was not found")
    return [Path(location).resolve() for location in spec.submodule_search_locations]


def main() -> None:
    args = parse_args()
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", args.require_model):
        raise SystemExit("required model is not a Python identifier")

    roots = (
        [args.package_root.resolve()]
        if args.package_root is not None
        else discover_package_roots()
    )
    registry_paths = [
        root / "model_executor" / "models" / "registry.py" for root in roots
    ]
    registry_paths = [path for path in registry_paths if path.is_file()]
    if len(registry_paths) != 1:
        raise SystemExit(
            f"expected exactly one installed vLLM registry, found {len(registry_paths)}"
        )

    registry_path = registry_paths[0]
    registry = registry_path.read_text(encoding="utf-8")
    entry = re.compile(rf'''["']{re.escape(args.require_model)}["']\s*:''')
    if entry.search(registry) is None:
        raise SystemExit(f"vLLM registry lacks {args.require_model}")
    print(f"registry-model={args.require_model} path={registry_path}")


if __name__ == "__main__":
    main()
