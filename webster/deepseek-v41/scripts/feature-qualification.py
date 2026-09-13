#!/usr/bin/env python3
"""Run deterministic, redacted API qualification cases against the private canary."""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
import re
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.request
import zlib
from pathlib import Path
from typing import Any, Callable


Validator = Callable[[dict[str, Any], dict[str, Any]], bool]
Payload = dict[str, Any] | bytes

EXPECTED_STATUSES = {
    "malformed-input": 400,
    "wrong-model": 404,
}
REPETITIONS = {"deterministic-text": 3}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--key-file", required=True, type=Path)
    parser.add_argument(
        "--stage", required=True, choices=("eager", "graphs", "dspark")
    )
    parser.add_argument("--output-json", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=900.0)
    parser.add_argument("--metrics-url")
    parser.add_argument("--failure-log-output", type=Path)
    parser.add_argument(
        "--server-log-node",
        action="append",
        choices=("shamu", "tilikum"),
        default=[],
    )
    parser.add_argument(
        "--server-container", default="deepseek-v41-flash-tp2"
    )
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


def canonical_hash(value: Any) -> str:
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def request_hash(value: Payload) -> str:
    if isinstance(value, bytes):
        return hashlib.sha256(value).hexdigest()
    return canonical_hash(value)


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_output(value: str) -> str:
    return unicodedata.normalize("NFC", value).replace("\r\n", "\n").strip()


def request_json(
    url: str,
    key: str,
    case: str,
    payload: Payload,
    timeout: float,
) -> tuple[int, dict[str, Any], str | None, dict[str, Any]]:
    request = urllib.request.Request(
        url,
        data=(
            payload
            if isinstance(payload, bytes)
            else json.dumps(payload, ensure_ascii=False).encode("utf-8")
        ),
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
            "X-Feature-Qualification-Case": case,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.status
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        return error.code, {}, None, {}

    if isinstance(payload, dict) and payload.get("stream"):
        content: list[str] = []
        reasoning: list[str] = []
        finish_reason: str | None = None
        usage: dict[str, Any] = {}
        for line in body.splitlines():
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            chunk = json.loads(line[6:])
            if isinstance(chunk.get("usage"), dict):
                usage = chunk["usage"]
            choices = chunk.get("choices") or []
            if not choices:
                continue
            choice = choices[0]
            delta = choice.get("delta") or {}
            if isinstance(delta.get("content"), str):
                content.append(delta["content"])
            delta_reasoning = delta.get("reasoning") or delta.get(
                "reasoning_content"
            )
            if isinstance(delta_reasoning, str):
                reasoning.append(delta_reasoning)
            if choice.get("finish_reason") is not None:
                finish_reason = choice["finish_reason"]
        return (
            status,
            {"content": "".join(content), "reasoning": "".join(reasoning)},
            finish_reason,
            usage,
        )

    parsed = json.loads(body)
    choices = parsed.get("choices") or []
    if not choices:
        return status, {}, None, parsed.get("usage") or {}
    choice = choices[0]
    message = choice.get("message") or {}
    return (
        status,
        message if isinstance(message, dict) else {},
        choice.get("finish_reason"),
        parsed.get("usage") or {},
    )


def content_of(message: dict[str, Any]) -> str:
    content = message.get("content")
    return content if isinstance(content, str) else ""


def reasoning_of(message: dict[str, Any]) -> str:
    reasoning = message.get("reasoning") or message.get("reasoning_content")
    return reasoning if isinstance(reasoning, str) else ""


def reasoning_tokens(usage: dict[str, Any]) -> int:
    details = usage.get("completion_tokens_details")
    if not isinstance(details, dict):
        return 0
    value = details.get("reasoning_tokens")
    return value if isinstance(value, int) else 0


def add_tool() -> dict[str, Any]:
    return {
        "type": "function",
        "function": {
            "name": "add",
            "description": "Add two integers.",
            "parameters": {
                "type": "object",
                "properties": {
                    "a": {"type": "integer"},
                    "b": {"type": "integer"},
                },
                "required": ["a", "b"],
                "additionalProperties": False,
            },
        },
    }


def multiply_tool() -> dict[str, Any]:
    return {
        "type": "function",
        "function": {
            "name": "multiply",
            "description": "Multiply two integers.",
            "parameters": {
                "type": "object",
                "properties": {
                    "a": {"type": "integer"},
                    "b": {"type": "integer"},
                },
                "required": ["a", "b"],
                "additionalProperties": False,
            },
        },
    }


def valid_add_call(message: dict[str, Any], _usage: dict[str, Any]) -> bool:
    calls = message.get("tool_calls")
    if not isinstance(calls, list) or len(calls) != 1:
        return False
    function = calls[0].get("function") if isinstance(calls[0], dict) else None
    if not isinstance(function, dict) or function.get("name") != "add":
        return False
    try:
        arguments = json.loads(function.get("arguments", ""))
    except (TypeError, json.JSONDecodeError):
        return False
    return arguments == {"a": 17, "b": 25}


def valid_parallel_add_calls(
    message: dict[str, Any], _usage: dict[str, Any]
) -> bool:
    calls = message.get("tool_calls")
    if not isinstance(calls, list) or len(calls) != 2:
        return False
    parsed: set[tuple[int, int]] = set()
    for call in calls:
        function = call.get("function") if isinstance(call, dict) else None
        if not isinstance(function, dict) or function.get("name") != "add":
            return False
        try:
            arguments = json.loads(function.get("arguments", ""))
        except (TypeError, json.JSONDecodeError):
            return False
        if not isinstance(arguments, dict):
            return False
        a, b = arguments.get("a"), arguments.get("b")
        if not isinstance(a, int) or not isinstance(b, int):
            return False
        parsed.add((a, b))
    return parsed == {(17, 25), (9, 11)}


def valid_place(message: dict[str, Any], _usage: dict[str, Any]) -> bool:
    try:
        value = json.loads(content_of(message))
    except json.JSONDecodeError:
        return False
    return value == {"city": "Paris", "country": "France"}


def png_chunk(kind: bytes, data: bytes) -> bytes:
    checksum = zlib.crc32(kind + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", checksum)


def red_png_data_url() -> str:
    width = height = 560
    raw = b"".join(b"\x00" + b"\xff\x00\x00" * width for _ in range(height))
    png = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(raw, 9))
        + png_chunk(b"IEND", b"")
    )
    return "data:image/png;base64," + base64.b64encode(png).decode("ascii")


def eager_cases(model: str) -> list[tuple[str, Payload, Validator]]:
    common = {
        "model": model,
        "temperature": 0,
        "max_tokens": 32,
        "reasoning_effort": "none",
    }
    return [
        (
            "deterministic-text",
            {
                **common,
                "messages": [
                    {
                        "role": "user",
                        "content": "Reply with exactly QUALIFICATION_OK.",
                    }
                ],
            },
            lambda message, _usage: normalize_output(content_of(message))
            == "QUALIFICATION_OK",
        ),
        (
            "utf8",
            {
                **common,
                "messages": [
                    {"role": "user", "content": "Reply with exactly: café 東京 🚀"}
                ],
            },
            lambda message, _usage: normalize_output(content_of(message))
            == "café 東京 🚀",
        ),
        (
            "stop-sequence",
            {
                **common,
                "messages": [
                    {
                        "role": "user",
                        "content": "Write 'before<END>after' exactly.",
                    }
                ],
                "stop": ["<END>"],
            },
            lambda message, _usage: "before" in content_of(message)
            and "<END>" not in content_of(message),
        ),
        (
            "streaming",
            {
                **common,
                "messages": [
                    {"role": "user", "content": "Reply with exactly: stream ok"}
                ],
                "stream": True,
                "stream_options": {"include_usage": True},
            },
            lambda message, usage: normalize_output(content_of(message))
            == "stream ok"
            and valid_usage(usage),
        ),
        (
            "usage-accounting",
            {
                **common,
                "messages": [
                    {"role": "user", "content": "Reply with exactly: usage ok"}
                ],
            },
            lambda message, usage: normalize_output(content_of(message))
            == "usage ok"
            and valid_usage(usage),
        ),
        (
            "reasoning-on",
            {
                **common,
                "messages": [
                    {
                        "role": "user",
                        "content": "What is 17 + 25? Answer with the number.",
                    }
                ],
                "reasoning_effort": "low",
                "max_tokens": 256,
            },
            lambda message, usage: normalize_output(content_of(message)) == "42"
            and bool(reasoning_of(message))
            and reasoning_tokens(usage) > 0,
        ),
        (
            "tool-auto",
            {
                **common,
                "messages": [
                    {
                        "role": "user",
                        "content": "Use the add tool to add 17 and 25.",
                    }
                ],
                "tools": [add_tool()],
                "tool_choice": "auto",
                "max_tokens": 128,
            },
            valid_add_call,
        ),
        (
            "tool-named",
            {
                **common,
                "messages": [
                    {
                        "role": "user",
                        "content": "Use the add tool to add 17 and 25.",
                    }
                ],
                "tools": [add_tool(), multiply_tool()],
                "tool_choice": {
                    "type": "function",
                    "function": {"name": "add"},
                },
                "max_tokens": 128,
            },
            valid_add_call,
        ),
        (
            "tool-required",
            {
                **common,
                "messages": [
                    {
                        "role": "user",
                        "content": "Use a tool to add 17 and 25.",
                    }
                ],
                "tools": [add_tool()],
                "tool_choice": "required",
                "max_tokens": 128,
            },
            valid_add_call,
        ),
        (
            "tool-parallel",
            {
                **common,
                "messages": [
                    {
                        "role": "user",
                        "content": (
                            "Use the add tool twice in parallel: add 17 and 25, "
                            "and separately add 9 and 11."
                        ),
                    }
                ],
                "tools": [add_tool()],
                "tool_choice": "required",
                "parallel_tool_calls": True,
                "max_tokens": 256,
            },
            valid_parallel_add_calls,
        ),
        (
            "tool-result",
            {
                **common,
                "messages": [
                    {
                        "role": "user",
                        "content": "Use the add tool to add 17 and 25.",
                    },
                    {
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [
                            {
                                "id": "call_1",
                                "type": "function",
                                "function": {
                                    "name": "add",
                                    "arguments": '{"a":17,"b":25}',
                                },
                            }
                        ],
                    },
                    {"role": "tool", "tool_call_id": "call_1", "content": "42"},
                ],
                "tools": [add_tool()],
                "max_tokens": 128,
            },
            lambda message, _usage: "42" in content_of(message),
        ),
        (
            "structured",
            {
                **common,
                "messages": [
                    {
                        "role": "user",
                        "content": "Return the city Paris and country France.",
                    }
                ],
                "response_format": {
                    "type": "json_schema",
                    "json_schema": {
                        "name": "place",
                        "strict": True,
                        "schema": {
                            "type": "object",
                            "properties": {
                                "city": {"type": "string"},
                                "country": {"type": "string"},
                            },
                            "required": ["city", "country"],
                            "additionalProperties": False,
                        },
                    },
                },
                "max_tokens": 128,
            },
            valid_place,
        ),
        (
            "json-object",
            {
                **common,
                "messages": [
                    {
                        "role": "user",
                        "content": (
                            "Return a JSON object with city Paris and country France."
                        ),
                    }
                ],
                "response_format": {"type": "json_object"},
                "max_tokens": 128,
            },
            valid_place,
        ),
        (
            "vision",
            {
                **common,
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "text",
                                "text": (
                                    "What is the dominant color? Reply one lowercase word."
                                ),
                            },
                            {
                                "type": "image_url",
                                "image_url": {"url": red_png_data_url()},
                            },
                        ],
                    }
                ],
            },
            lambda message, _usage: normalize_output(content_of(message)) == "red",
        ),
        (
            "malformed-input",
            b'{"model":',
            lambda _message, _usage: True,
        ),
        (
            "wrong-model",
            {
                **common,
                "model": "qualification-wrong-model",
                "messages": [{"role": "user", "content": "Reply with ok."}],
            },
            lambda _message, _usage: True,
        ),
        (
            "disconnect-queue-drain",
            {
                **common,
                "messages": [
                    {
                        "role": "user",
                        "content": "Count upward, one integer per line.",
                    }
                ],
                "stream": True,
                "max_tokens": 2048,
                "min_tokens": 512,
            },
            lambda _message, _usage: True,
        ),
    ]


def valid_usage(usage: dict[str, Any]) -> bool:
    values = [
        usage.get("prompt_tokens"),
        usage.get("completion_tokens"),
        usage.get("total_tokens"),
    ]
    return all(isinstance(value, int) and value >= 0 for value in values) and (
        values[0] + values[1] == values[2]
    )


def read_queue_metrics(url: str, timeout: float) -> dict[str, float]:
    request = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read().decode("utf-8")
    names = {
        "running": "vllm:num_requests_running",
        "waiting": "vllm:num_requests_waiting",
    }
    values: dict[str, float] = {}
    for label, metric in names.items():
        samples: list[float] = []
        for line in body.splitlines():
            if not (line.startswith(metric + " ") or line.startswith(metric + "{")):
                continue
            try:
                samples.append(float(line.rsplit(None, 1)[1]))
            except (IndexError, ValueError) as error:
                raise RuntimeError(f"malformed queue metric {metric}") from error
        if not samples:
            raise RuntimeError(f"missing queue metric {metric}")
        values[label] = sum(samples)
    return values


def disconnect_and_wait_for_drain(
    endpoint: str,
    metrics_url: str,
    key: str,
    case: str,
    payload: dict[str, Any],
    timeout: float,
) -> tuple[int, dict[str, Any]]:
    metric_timeout = max(1.0, min(timeout, 10.0))
    baseline = read_queue_metrics(metrics_url, metric_timeout)
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
            "X-Feature-Qualification-Case": case,
        },
        method="POST",
    )
    observed_chunk = False
    with urllib.request.urlopen(request, timeout=timeout) as response:
        status = response.status
        while True:
            raw_line = response.readline()
            if not raw_line:
                break
            line = raw_line.decode("utf-8").strip()
            if line.startswith("data: ") and line != "data: [DONE]":
                observed_chunk = True
                break

    started = time.monotonic()
    deadline = started + min(timeout, 30.0)
    final = read_queue_metrics(metrics_url, metric_timeout)
    while (
        final["running"] > baseline["running"]
        or final["waiting"] > baseline["waiting"]
    ) and time.monotonic() < deadline:
        time.sleep(0.1)
        final = read_queue_metrics(metrics_url, metric_timeout)
    queue_drained = (
        final["running"] <= baseline["running"]
        and final["waiting"] <= baseline["waiting"]
    )
    return status, {
        "client_disconnected": observed_chunk,
        "queue_drained": queue_drained,
        "queue_baseline": baseline,
        "queue_final": final,
        "queue_drain_seconds": round(time.monotonic() - started, 6),
    }


def write_private_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def write_private_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(value)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def redact_log(value: str) -> str:
    value = re.sub(
        r"(?i)(Authorization:\s*Bearer)\s+\S+",
        r"\1 [REDACTED]",
        value,
    )
    value = re.sub(
        r"(?i)((?:api[_-]?keys?|master[_-]?key|password|secret)"
        r"[\"']?\s*[:=]\s*)[^,\s\"']+",
        r"\1[REDACTED]",
        value,
    )
    value = re.sub(r"sk-[A-Za-z0-9._-]{8,}", "[REDACTED-KEY]", value)
    return value


def capture_failure_logs(
    path: Path,
    nodes: list[str],
    container: str,
    since: str,
) -> dict[str, Any]:
    environment = os.environ.copy()
    environment.pop("SSH_AUTH_SOCK", None)
    sections: list[str] = []
    ok = True
    for node in nodes:
        docker = ["sudo", "-n", "docker"] if node == "tilikum" else ["docker"]
        command = [
            "ssh",
            node,
            *docker,
            "logs",
            "--since",
            since,
            "--timestamps",
            "--tail",
            "5000",
            container,
        ]
        try:
            result = subprocess.run(
                command,
                text=True,
                capture_output=True,
                check=False,
                timeout=60,
                env=environment,
            )
            ok = ok and result.returncode == 0
            sections.append(
                f"===== {node} exit={result.returncode} =====\n"
                + result.stdout
                + result.stderr
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            ok = False
            sections.append(
                f"===== {node} capture_error={type(error).__name__} =====\n"
            )
    write_private_text(path, redact_log("".join(sections)))
    return {
        "requested": True,
        "captured": True,
        "ok": ok,
        "path": str(path.resolve()),
        "sha256": file_hash(path),
        "nodes": nodes,
        "container": container,
        "since": since,
    }


def main() -> int:
    args = parse_args()
    if bool(args.failure_log_output) != bool(args.server_log_node):
        print(
            "ERROR: failure-log-output and server-log-node must be used together",
            file=sys.stderr,
        )
        return 1
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", args.server_container) is None:
        print("ERROR: unsafe server container name", file=sys.stderr)
        return 1
    qualification_started = datetime.now(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    try:
        key = read_secret(args.key_file)
    except (OSError, RuntimeError, UnicodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    normalized_base = args.base_url.rstrip("/")
    endpoint = normalized_base + "/chat/completions"
    metrics_url = args.metrics_url
    if not metrics_url:
        metrics_base = normalized_base[:-3] if normalized_base.endswith("/v1") else normalized_base
        metrics_url = metrics_base + "/metrics"
    results: list[dict[str, Any]] = []
    for case, payload, validator in eager_cases(args.model):
        started = time.monotonic()
        repetitions = REPETITIONS.get(case, 1)
        attempts: list[dict[str, Any]] = []
        disconnect_details: dict[str, Any] = {}
        for _ in range(repetitions):
            try:
                if case == "disconnect-queue-drain":
                    require_payload = payload if isinstance(payload, dict) else {}
                    status, disconnect_details = disconnect_and_wait_for_drain(
                        endpoint,
                        metrics_url,
                        key,
                        case,
                        require_payload,
                        args.timeout,
                    )
                    message: dict[str, Any] = {}
                    finish_reason = "client_disconnect"
                    usage: dict[str, Any] = {}
                    semantic_ok = (
                        status == 200
                        and disconnect_details["client_disconnected"] is True
                        and disconnect_details["queue_drained"] is True
                    )
                else:
                    status, message, finish_reason, usage = request_json(
                        endpoint, key, case, payload, args.timeout
                    )
                    semantic_ok = (
                        status == EXPECTED_STATUSES.get(case, 200)
                        and validator(message, usage)
                    )
                error = None
            except (
                OSError,
                RuntimeError,
                UnicodeError,
                ValueError,
                json.JSONDecodeError,
            ) as exc:
                status = 0
                message = {}
                finish_reason = None
                usage = {}
                semantic_ok = False
                error = type(exc).__name__
            normalized = normalize_output(content_of(message))
            attempts.append(
                {
                    "status": status,
                    "finish_reason": finish_reason,
                    "token_usage": usage,
                    "normalized_output_hash": canonical_hash(normalized),
                    "reasoning_present": bool(reasoning_of(message)),
                    "tool_call_count": (
                        len(message.get("tool_calls"))
                        if isinstance(message.get("tool_calls"), list)
                        else 0
                    ),
                    "semantic_ok": semantic_ok,
                    "error": error,
                }
            )
        hashes = {attempt["normalized_output_hash"] for attempt in attempts}
        semantic_ok = all(attempt["semantic_ok"] for attempt in attempts)
        if repetitions > 1:
            semantic_ok = semantic_ok and len(hashes) == 1
        first = attempts[0]
        result = {
            "case": case,
            "request_hash": request_hash(payload),
            "status": first["status"],
            "finish_reason": first["finish_reason"],
            "token_usage": first["token_usage"],
            "latency_seconds": round(time.monotonic() - started, 6),
            "normalized_output_hash": first["normalized_output_hash"],
            "reasoning_present": first["reasoning_present"],
            "tool_call_count": first["tool_call_count"],
            "semantic_ok": semantic_ok,
            "error": next(
                (attempt["error"] for attempt in attempts if attempt["error"]),
                None,
            ),
            "repetitions": repetitions,
            "distinct_normalized_outputs": len(hashes),
        }
        if repetitions > 1:
            result["attempts"] = attempts
        result.update(disconnect_details)
        results.append(result)

    artifact = {
        "schema_version": 1,
        "stage": args.stage,
        "model": args.model,
        "ok": all(result["semantic_ok"] for result in results),
        "cases": results,
        "failure_log_capture": {
            "requested": bool(args.failure_log_output),
            "captured": False,
            "ok": True,
            "path": (
                str(args.failure_log_output.resolve())
                if args.failure_log_output
                else None
            ),
            "nodes": args.server_log_node,
            "container": args.server_container,
        },
    }
    if not artifact["ok"] and args.failure_log_output:
        artifact["failure_log_capture"] = capture_failure_logs(
            args.failure_log_output,
            args.server_log_node,
            args.server_container,
            qualification_started,
        )
    try:
        write_private_json(args.output_json, artifact)
    except OSError as error:
        print(f"ERROR: cannot write result: {type(error).__name__}", file=sys.stderr)
        return 1
    if not artifact["ok"]:
        failed = ",".join(
            result["case"] for result in results if not result["semantic_ok"]
        )
        print(f"NO-GO feature qualification failed cases={failed}", file=sys.stderr)
        return 1
    print(f"GO feature qualification stage={args.stage} cases={len(results)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
