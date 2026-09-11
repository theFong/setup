#!/usr/bin/env python3
"""Render the GLM-5.2 compatibility alias without exposing backend credentials."""

from __future__ import annotations

import argparse
import importlib.util
import os
import sys
import tempfile
from pathlib import Path

import yaml


HERE = Path(__file__).resolve().parent
VERIFIER_PATH = HERE / "verify-litellm-config.py"


def load_verifier():
    spec = importlib.util.spec_from_file_location("verify_litellm_config", VERIFIER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load LiteLLM configuration verifier")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("before", type=Path)
    parser.add_argument("output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    verifier = load_verifier()
    temporary_path: Path | None = None
    try:
        before_resolved = args.before.resolve(strict=True)
        output_resolved = args.output.resolve(strict=False)
        if before_resolved == output_resolved:
            raise verifier.ValidationError("refusing to overwrite the source configuration")
        before = verifier.load_config(before_resolved)
        candidate = verifier.expected_alias_config(before)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(
            prefix=f".{args.output.name}.", dir=args.output.parent
        )
        temporary_path = Path(temporary)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            yaml.safe_dump(candidate, handle, sort_keys=False)
        os.chmod(temporary_path, 0o600)
        rendered = verifier.load_config(temporary_path)
        verifier.validate_alias(before, rendered)
        os.replace(temporary_path, args.output)
        temporary_path = None
        os.chmod(args.output, 0o600)
    except (OSError, RuntimeError, yaml.YAMLError) as error:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"rendered validated LiteLLM alias candidate at {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
