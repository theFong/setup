#!/usr/bin/env python3
"""Verify that two validated serving ranks belong to one generation."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import re
import sys
from typing import Any


DOCKER_TIMESTAMP = re.compile(
    r"^(?P<whole>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})"
    r"(?:\.(?P<fraction>\d{1,9}))?Z$"
)
IMAGE_ID = re.compile(r"^sha256:[0-9a-f]{64}$")
CONTAINER_ID = re.compile(r"^[0-9a-f]{64}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rank0-state-json", required=True)
    parser.add_argument("--rank1-state-json", required=True)
    parser.add_argument("--max-start-skew-seconds", required=True, type=float)
    parser.add_argument("--require-matching-image", action="store_true")
    parser.add_argument("--print-generation", action="store_true")
    return parser.parse_args()


def load_state(raw: str, rank: int) -> dict[str, Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"rank {rank} state is malformed JSON: {error}") from error
    if not isinstance(value, dict):
        raise RuntimeError(f"rank {rank} state must be an object")
    return value


def parse_docker_timestamp(value: Any, rank: int) -> datetime:
    if not isinstance(value, str):
        raise RuntimeError(f"rank {rank} start timestamp must be a string")
    match = DOCKER_TIMESTAMP.fullmatch(value)
    if match is None:
        raise RuntimeError(f"rank {rank} start timestamp is invalid")
    fraction = (match.group("fraction") or "")[:6].ljust(6, "0")
    normalized = f"{match.group('whole')}.{fraction}+00:00"
    try:
        return datetime.fromisoformat(normalized).astimezone(timezone.utc)
    except ValueError as error:
        raise RuntimeError(f"rank {rank} start timestamp is invalid") from error


def main() -> int:
    args = parse_args()
    try:
        if args.max_start_skew_seconds < 0:
            raise RuntimeError("maximum start skew must not be negative")
        states = [
            load_state(args.rank0_state_json, 0),
            load_state(args.rank1_state_json, 1),
        ]
        if args.require_matching_image:
            images = [state.get("image") for state in states]
            if (
                not all(isinstance(image, str) and IMAGE_ID.fullmatch(image) for image in images)
                or images[0] != images[1]
            ):
                raise RuntimeError("serving ranks use different image generations")

        generations = [state.get("generation") for state in states]
        generation_id = ""
        if any(generation not in (None, "") for generation in generations):
            if (
                not all(isinstance(generation, str) and generation for generation in generations)
                or generations[0] != generations[1]
            ):
                raise RuntimeError("serving ranks are from different generations")
            generation_id = generations[0]
        else:
            started = [
                parse_docker_timestamp(state.get("started_at"), rank)
                for rank, state in enumerate(states)
            ]
            if abs((started[0] - started[1]).total_seconds()) > args.max_start_skew_seconds:
                raise RuntimeError("legacy serving ranks were not started as one generation")
            if args.print_generation:
                container_ids = [state.get("container_id") for state in states]
                if not all(
                    isinstance(container_id, str)
                    and CONTAINER_ID.fullmatch(container_id)
                    for container_id in container_ids
                ):
                    raise RuntimeError("legacy serving ranks lack container identities")
                identity = json.dumps(
                    [
                        {
                            "container_id": container_ids[rank],
                            "started_at": states[rank].get("started_at"),
                        }
                        for rank in range(2)
                    ],
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode("utf-8")
                generation_id = "legacy-" + hashlib.sha256(identity).hexdigest()
    except RuntimeError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    if args.print_generation:
        print(generation_id)
    else:
        print("serving pair generation validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
