#!/usr/bin/env python3
"""Render the GLM-5.2 compatibility alias without exposing backend credentials."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import stat
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
    parser.add_argument("--phase", choices=("alias", "publish"), default="alias")
    parser.add_argument("--api-key-file", type=Path)
    parser.add_argument("--private-acceptance", type=Path)
    parser.add_argument("--served-model-name")
    parser.add_argument("--max-context", type=int)
    parser.add_argument("--input-cost-per-token", type=float)
    parser.add_argument("--output-cost-per-token", type=float)
    parser.add_argument("--supports-vision", action="store_true")
    return parser.parse_args()


def read_private_key(path: Path | None, verifier) -> str:
    if path is None:
        raise verifier.ValidationError("--api-key-file is required for publish")
    if not path.is_file() or path.is_symlink():
        raise verifier.ValidationError("backend key must be a regular non-symlink file")
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise verifier.ValidationError("backend key file mode must be 0600")
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        raise verifier.ValidationError("backend key file is empty")
    return value


def read_accepted_publication(path: Path | None, verifier) -> dict[str, object]:
    if path is None:
        raise verifier.ValidationError("--private-acceptance is required for publish")
    if not path.is_file() or path.is_symlink():
        raise verifier.ValidationError(
            "private acceptance must be a regular non-symlink file"
        )
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise verifier.ValidationError("private acceptance file mode must be 0600")
    try:
        root = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise verifier.ValidationError("private acceptance is malformed") from error
    if not isinstance(root, dict) or root.get("decision") != "GO":
        raise verifier.ValidationError("private acceptance decision is not GO")
    publication = root.get("publication")
    expected_keys = {
        "public_model_name",
        "served_model_name",
        "max_context",
        "station_endpoint",
        "supports_function_calling",
        "supports_reasoning",
        "supports_response_schema",
        "supports_vision",
        "input_cost_per_token",
        "output_cost_per_token",
    }
    if not isinstance(publication, dict) or set(publication) != expected_keys:
        raise verifier.ValidationError("accepted publication record is incomplete")
    if (
        publication.get("public_model_name") != verifier.PUBLISHED_MODEL
        or publication.get("station_endpoint") != verifier.PUBLISHED_API_BASE
        or publication.get("served_model_name")
        != "deepseek-ai/DeepSeek-V4.1-Flash"
        or publication.get("max_context") != 1_048_576
        or publication.get("supports_function_calling") is not True
        or publication.get("supports_reasoning") is not True
        or publication.get("supports_response_schema") is not True
        or publication.get("supports_vision") is not True
        or publication.get("input_cost_per_token") != 1.3e-8
        or publication.get("output_cost_per_token") != 9.6e-7
    ):
        raise verifier.ValidationError(
            "accepted publication record does not match the qualified profile"
        )
    return publication


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
        if args.phase == "alias":
            candidate = verifier.expected_alias_config(before)
        else:
            publication = read_accepted_publication(args.private_acceptance, verifier)
            supplied = {
                "served_model_name": args.served_model_name,
                "max_context": args.max_context,
                "input_cost_per_token": args.input_cost_per_token,
                "output_cost_per_token": args.output_cost_per_token,
            }
            for name, value in supplied.items():
                if value is not None and value != publication[name]:
                    raise verifier.ValidationError(
                        f"caller {name} differs from the accepted publication record"
                    )
            if args.supports_vision and publication["supports_vision"] is not True:
                raise verifier.ValidationError(
                    "caller vision flag differs from the accepted publication record"
                )
            candidate = verifier.expected_publish_config(
                before,
                api_key=read_private_key(args.api_key_file, verifier),
                served_model_name=str(publication["served_model_name"]),
                max_context=int(publication["max_context"]),
                input_cost_per_token=float(publication["input_cost_per_token"]),
                output_cost_per_token=float(publication["output_cost_per_token"]),
                supports_vision=bool(publication["supports_vision"]),
            )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(
            prefix=f".{args.output.name}.", dir=args.output.parent
        )
        temporary_path = Path(temporary)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            yaml.safe_dump(candidate, handle, sort_keys=False)
        os.chmod(temporary_path, 0o600)
        rendered = verifier.load_config(temporary_path)
        if args.phase == "alias":
            verifier.validate_alias(before, rendered)
        else:
            verifier.validate_publish(before, rendered)
        os.replace(temporary_path, args.output)
        temporary_path = None
        os.chmod(args.output, 0o600)
    except (OSError, RuntimeError, yaml.YAMLError) as error:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"rendered validated LiteLLM {args.phase} candidate at {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
