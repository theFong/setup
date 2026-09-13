#!/usr/bin/env python3
"""Qualify exact DeepSeek context boundaries without retaining prompt contents."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


PADDING_UNIT = " x"
COMPLETION_TOKENS = 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--key-file", required=True, type=Path)
    parser.add_argument("--max-model-len", required=True, type=int)
    parser.add_argument(
        "--target-context", required=True, action="append", type=int
    )
    parser.add_argument("--output-json", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=1800.0)
    return parser.parse_args()


def read_secret(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise RuntimeError("key file must be a regular non-symlink file")
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise RuntimeError("key file mode must be 0600")
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        raise RuntimeError("key file is empty")
    return value


def write_private_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
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


def post_json(
    url: str,
    key: str,
    payload: dict[str, Any],
    timeout: float,
) -> tuple[int, dict[str, Any], str]:
    encoded = json.dumps(
        payload, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    request_hash = hashlib.sha256(encoded).hexdigest()
    request = urllib.request.Request(
        url,
        data=encoded,
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
            "X-Long-Context-Qualification": "1",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.loads(response.read().decode("utf-8"))
            return (
                response.status,
                body if isinstance(body, dict) else {},
                request_hash,
            )
    except urllib.error.HTTPError as error:
        try:
            body = json.loads(error.read().decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            body = {}
        return error.code, body if isinstance(body, dict) else {}, request_hash


def tokenize(
    base_url: str,
    model: str,
    key: str,
    repetitions: int,
    timeout: float,
) -> tuple[int, int | None, int | None, str]:
    status, body, request_hash = post_json(
        base_url.rstrip("/") + "/tokenize",
        key,
        {
            "model": model,
            "messages": [{"role": "user", "content": PADDING_UNIT * repetitions}],
            "add_generation_prompt": True,
            "chat_template_kwargs": {"enable_thinking": False},
        },
        timeout,
    )
    count = body.get("count")
    max_model_len = body.get("max_model_len")
    return (
        status,
        count if isinstance(count, int) and not isinstance(count, bool) else None,
        (
            max_model_len
            if isinstance(max_model_len, int) and not isinstance(max_model_len, bool)
            else None
        ),
        request_hash,
    )


def chat_payload(model: str, repetitions: int) -> dict[str, Any]:
    return {
        "model": model,
        "messages": [{"role": "user", "content": PADDING_UNIT * repetitions}],
        "temperature": 0,
        "max_tokens": COMPLETION_TOKENS,
        "reasoning_effort": "none",
    }


def validate_targets(targets: list[int], max_model_len: int) -> None:
    if max_model_len < 2:
        raise RuntimeError("max model length must be at least 2")
    if not targets:
        raise RuntimeError("at least one target context is required")
    if len(set(targets)) != len(targets):
        raise RuntimeError("target contexts must be unique")
    for target in targets:
        if target < 2 or target > max_model_len:
            raise RuntimeError(
                "target contexts must be between 2 and max model length"
            )


def usage_counts(body: dict[str, Any]) -> tuple[int | None, int | None, int | None]:
    usage = body.get("usage")
    if not isinstance(usage, dict):
        return None, None, None
    values: list[int | None] = []
    for name in ("prompt_tokens", "completion_tokens", "total_tokens"):
        value = usage.get(name)
        values.append(value if isinstance(value, int) and not isinstance(value, bool) else None)
    return values[0], values[1], values[2]


def main() -> int:
    args = parse_args()
    artifact: dict[str, Any] = {
        "schema_version": 1,
        "model": args.model,
        "max_model_len": args.max_model_len,
        "padding_unit_sha256": hashlib.sha256(PADDING_UNIT.encode()).hexdigest(),
        "accepted": [],
        "over_limit": {},
        "ok": False,
    }
    try:
        validate_targets(args.target_context, args.max_model_len)
        key = read_secret(args.key_file)
        base_url = args.base_url.rstrip("/")

        baseline_status, baseline_count, reported_max, baseline_hash = tokenize(
            base_url, args.model, key, 0, args.timeout
        )
        unit_status, unit_count, unit_max, unit_hash = tokenize(
            base_url, args.model, key, 64, args.timeout
        )
        tokenizer_ready = (
            baseline_status == 200
            and unit_status == 200
            and baseline_count is not None
            and unit_count is not None
            and unit_count - baseline_count == 64
            and reported_max == args.max_model_len
            and unit_max == args.max_model_len
        )
        artifact["tokenizer_calibration"] = {
            "baseline_status": baseline_status,
            "baseline_prompt_tokens": baseline_count,
            "baseline_request_hash": baseline_hash,
            "unit_probe_status": unit_status,
            "unit_probe_prompt_tokens": unit_count,
            "unit_probe_request_hash": unit_hash,
            "unit_probe_repetitions": 64,
            "reported_max_model_len": reported_max,
            "exact_linear_unit": tokenizer_ready,
        }
        if not tokenizer_ready or baseline_count is None:
            write_private_json(args.output_json, artifact)
            return 1

        accepted_ok = True
        for target in args.target_context:
            expected_prompt = target - COMPLETION_TOKENS
            repetitions = expected_prompt - baseline_count
            if repetitions < 0:
                raise RuntimeError("target is smaller than the chat-template overhead")
            started = time.monotonic()
            tokenize_status, tokenize_count, target_max, tokenize_hash = tokenize(
                base_url, args.model, key, repetitions, args.timeout
            )
            token_count_exact = (
                tokenize_status == 200
                and tokenize_count == expected_prompt
                and target_max == args.max_model_len
            )
            result: dict[str, Any] = {
                "target_context_tokens": target,
                "expected_prompt_tokens": expected_prompt,
                "padding_repetitions": repetitions,
                "tokenize_status": tokenize_status,
                "tokenize_request_hash": tokenize_hash,
                "token_count_exact": token_count_exact,
            }
            if token_count_exact:
                status, body, request_hash = post_json(
                    base_url + "/v1/chat/completions",
                    key,
                    chat_payload(args.model, repetitions),
                    args.timeout,
                )
                prompt_tokens, completion_tokens, total_tokens = usage_counts(body)
                result.update(
                    {
                        "status": status,
                        "request_hash": request_hash,
                        "server_prompt_tokens": prompt_tokens,
                        "server_completion_tokens": completion_tokens,
                        "server_total_tokens": total_tokens,
                        "latency_seconds": round(time.monotonic() - started, 6),
                    }
                )
                result["semantic_ok"] = (
                    status == 200
                    and prompt_tokens == expected_prompt
                    and completion_tokens == COMPLETION_TOKENS
                    and total_tokens == target
                )
            else:
                result["semantic_ok"] = False
            artifact["accepted"].append(result)
            accepted_ok = accepted_ok and bool(result["semantic_ok"])
            if not token_count_exact:
                break

        over_limit_ok = False
        if accepted_ok:
            over_limit_target = args.max_model_len + 1
            expected_prompt = args.max_model_len
            repetitions = expected_prompt - baseline_count
            started = time.monotonic()
            tokenize_status, tokenize_count, target_max, tokenize_hash = tokenize(
                base_url, args.model, key, repetitions, args.timeout
            )
            token_count_exact = (
                tokenize_status == 200
                and tokenize_count == expected_prompt
                and target_max == args.max_model_len
            )
            status: int | None = None
            request_hash: str | None = None
            if token_count_exact:
                status, _body, request_hash = post_json(
                    base_url + "/v1/chat/completions",
                    key,
                    chat_payload(args.model, repetitions),
                    args.timeout,
                )
            over_limit_ok = token_count_exact and status == 400
            artifact["over_limit"] = {
                "target_context_tokens": over_limit_target,
                "expected_prompt_tokens": expected_prompt,
                "padding_repetitions": repetitions,
                "tokenize_status": tokenize_status,
                "tokenize_request_hash": tokenize_hash,
                "token_count_exact": token_count_exact,
                "status": status,
                "request_hash": request_hash,
                "latency_seconds": round(time.monotonic() - started, 6),
                "semantic_ok": over_limit_ok,
            }

        artifact["ok"] = accepted_ok and over_limit_ok
        write_private_json(args.output_json, artifact)
        return 0 if artifact["ok"] else 1
    except (OSError, RuntimeError, UnicodeError, json.JSONDecodeError) as error:
        artifact["error_type"] = type(error).__name__
        artifact["error"] = str(error)
        try:
            write_private_json(args.output_json, artifact)
        except OSError:
            pass
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
