#!/usr/bin/env python3
"""Validate LiteLLM's immutable image and non-duplicated entrypoint command shape."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


EXPECTED_ENTRYPOINT = "docker/prod_entrypoint.sh"
EXPECTED_COMMAND = [
    "--config",
    "/app/config.yaml",
    "--host",
    "127.0.0.1",
    "--port",
    "4446",
]
IMAGE_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")


class ValidationError(RuntimeError):
    """A non-secret inspect validation failure."""


def load_inspect(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise ValidationError(f"inspect input is not a regular file: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"cannot parse inspect JSON: {path}") from error
    if not isinstance(payload, list) or len(payload) != 1 or not isinstance(payload[0], dict):
        raise ValidationError("inspect JSON must contain exactly one container object")
    return payload[0]


def require_mapping(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValidationError(f"{name} must be an object")
    return value


def validate_shape(inspect: dict[str, Any], expected_image: str | None = None) -> None:
    image = inspect.get("Image")
    if not isinstance(image, str) or not IMAGE_PATTERN.fullmatch(image):
        raise ValidationError("container Image must be an immutable sha256 ID")
    if expected_image is not None and image != expected_image:
        raise ValidationError("container image ID does not match the approved image")

    config = require_mapping(inspect.get("Config"), "Config")
    entrypoint = config.get("Entrypoint")
    if not isinstance(entrypoint, list) or any(
        not isinstance(token, str) for token in entrypoint
    ):
        raise ValidationError("Config.Entrypoint must be a string list")
    if entrypoint.count(EXPECTED_ENTRYPOINT) != 1:
        raise ValidationError("Config.Entrypoint must contain prod_entrypoint exactly once")
    command = config.get("Cmd")
    if command != EXPECTED_COMMAND:
        raise ValidationError("Config.Cmd does not match the loopback-only LiteLLM contract")
    if any("prod_entrypoint.sh" in token for token in command):
        raise ValidationError("Config.Cmd must not repeat the image entrypoint")


def recreation_shape(inspect: dict[str, Any]) -> dict[str, Any]:
    config = require_mapping(inspect.get("Config"), "Config")
    host = require_mapping(inspect.get("HostConfig"), "HostConfig")
    return {
        "Image": inspect.get("Image"),
        "Entrypoint": config.get("Entrypoint"),
        "Cmd": config.get("Cmd"),
        "Mounts": inspect.get("Mounts"),
        "NetworkMode": host.get("NetworkMode"),
        "RestartPolicy": host.get("RestartPolicy"),
        "PortBindings": host.get("PortBindings"),
        "User": config.get("User"),
        "Capabilities": {
            "CapAdd": host.get("CapAdd"),
            "CapDrop": host.get("CapDrop"),
            "Privileged": host.get("Privileged"),
            "ReadonlyRootfs": host.get("ReadonlyRootfs"),
            "SecurityOpt": host.get("SecurityOpt"),
        },
        "Ulimits": host.get("Ulimits"),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("inspect_json", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--expected-image")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        candidate = load_inspect(args.inspect_json)
        validate_shape(candidate, args.expected_image)
        if args.baseline is not None:
            baseline = load_inspect(args.baseline)
            validate_shape(baseline, args.expected_image)
            if recreation_shape(candidate) != recreation_shape(baseline):
                raise ValidationError("recreation shape differs from captured baseline")
    except ValidationError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("container shape valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
