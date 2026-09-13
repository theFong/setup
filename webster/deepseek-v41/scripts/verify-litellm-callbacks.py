#!/usr/bin/env python3
"""Validate LiteLLM callback ordering and exact-image importability."""

from __future__ import annotations

import argparse
import importlib
import sys
from pathlib import Path
from typing import Any

import yaml


GUARD_CALLBACK = "custom_callbacks.glm52_contract_guard.glm52_contract_guard"
RESPONSES_SANITIZER_CALLBACK = (
    "custom_callbacks.responses_sanitizer.responses_encrypted_content_sanitizer"
)


class ValidationError(RuntimeError):
    """An intentionally non-secret callback validation failure."""


def load_config(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise ValidationError(f"configuration is not a regular file: {path}")
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, yaml.YAMLError) as error:
        raise ValidationError(f"cannot parse configuration: {path}") from error
    if not isinstance(value, dict):
        raise ValidationError("configuration root must be a mapping")
    return value


def validate_guard_order(config: dict[str, Any]) -> list[str]:
    settings = config.get("litellm_settings")
    if not isinstance(settings, dict):
        raise ValidationError("litellm_settings must be a mapping")
    callbacks = settings.get("callbacks")
    if not isinstance(callbacks, list) or any(
        not isinstance(callback, str) for callback in callbacks
    ):
        raise ValidationError("litellm_settings.callbacks must be a list of strings")
    if callbacks.count(GUARD_CALLBACK) != 1:
        raise ValidationError("guard callback must appear exactly once")

    guard_index = callbacks.index(GUARD_CALLBACK)
    prefix = callbacks[:guard_index]
    if prefix not in ([], [RESPONSES_SANITIZER_CALLBACK]):
        raise ValidationError("only the responses sanitizer may precede the guard")
    return callbacks


def validate_custom_callbacks(config: dict[str, Any]) -> None:
    callbacks = validate_guard_order(config)
    working_directory = str(Path.cwd())
    if not sys.path or sys.path[0] != working_directory:
        sys.path.insert(0, working_directory)

    try:
        from litellm.integrations.custom_logger import CustomLogger
    except Exception as error:
        raise ValidationError("cannot import LiteLLM CustomLogger") from error

    for callback in callbacks:
        if not callback.startswith("custom_callbacks."):
            continue
        module_name, attribute_name = callback.rsplit(".", 1)
        try:
            module = importlib.import_module(module_name)
            instance = getattr(module, attribute_name)
        except Exception as error:
            raise ValidationError(f"cannot import custom callback: {callback}") from error
        if not isinstance(instance, CustomLogger):
            raise ValidationError(f"custom callback is not a CustomLogger: {callback}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        config = load_config(args.config)
        validate_custom_callbacks(config)
    except ValidationError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("LiteLLM callback order and imports are valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
