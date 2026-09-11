#!/usr/bin/env python3
"""Exercise the GLM compatibility contract without placing credentials in argv."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
PACKAGE_ROOT = HERE.parent
GUARD_MODULE = PACKAGE_ROOT / "litellm" / "glm52_contract_guard.py"


class ProbeError(RuntimeError):
    """A probe failure safe to record without request credentials."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--models", nargs="+", required=True)
    parser.add_argument("--key-file", type=Path, required=True)
    parser.add_argument("--expected-response-model", action="append", default=[])
    parser.add_argument("--backend-metrics-before", type=Path)
    parser.add_argument("--output-json", type=Path, required=True)
    parser.add_argument("--tokenizer-dir", type=Path)
    parser.add_argument("--skip-boundary", action="store_true")
    return parser.parse_args()


def read_key(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise ProbeError("key file must be a regular file")
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise ProbeError("key file mode must be 0600")
    key = path.read_text(encoding="utf-8").strip()
    if not key:
        raise ProbeError("key file is empty")
    return key


def expected_models(values: list[str], models: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in values:
        public, separator, response = value.partition("=")
        if not separator or not public or not response or public in result:
            raise ProbeError("expected response models must use unique PUBLIC=RESPONSE pairs")
        result[public] = response
    missing = [model for model in models if model not in result]
    if missing:
        raise ProbeError("every probed model needs an expected response-model mapping")
    return result


def request_json(
    url: str,
    key: str,
    case: str,
    body: dict[str, Any],
    *,
    expected_status: int = 200,
) -> tuple[int, Any, float]:
    request = urllib.request.Request(
        url,
        data=json.dumps(body, separators=(",", ":")).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "X-Contract-Probe-Case": case,
        },
        method="POST",
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            raw = response.read()
            status = response.status
            content_type = response.headers.get("Content-Type", "")
    except urllib.error.HTTPError as error:
        raw = error.read()
        status = error.code
        content_type = error.headers.get("Content-Type", "")
    elapsed = time.monotonic() - started
    if status != expected_status:
        raise ProbeError(f"{case} returned HTTP {status}, expected {expected_status}")
    if "text/event-stream" in content_type:
        return status, raw.decode("utf-8", errors="replace"), elapsed
    try:
        return status, json.loads(raw), elapsed
    except json.JSONDecodeError as error:
        raise ProbeError(f"{case} did not return JSON") from error


def response_record(case: str, payload: dict[str, Any], elapsed: float) -> dict[str, Any]:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        raise ProbeError(f"{case} response has no choice")
    return {
        "case": case,
        "status": 200,
        "elapsed_seconds": round(elapsed, 6),
        "response_model": payload.get("model"),
        "finish_reason": choices[0].get("finish_reason"),
    }


def check_stream(case: str, payload: str, expected_model: str) -> dict[str, Any]:
    done = False
    models: set[str] = set()
    finish_reasons: list[str] = []
    for line in payload.splitlines():
        if not line.startswith("data: "):
            continue
        data = line.removeprefix("data: ")
        if data == "[DONE]":
            done = True
            continue
        try:
            chunk = json.loads(data)
        except json.JSONDecodeError as error:
            raise ProbeError("stream returned malformed JSON data") from error
        if isinstance(chunk.get("model"), str):
            models.add(chunk["model"])
        for choice in chunk.get("choices") or []:
            if choice.get("finish_reason"):
                finish_reasons.append(choice["finish_reason"])
    if not done or models != {expected_model}:
        raise ProbeError("stream did not preserve the expected response model and DONE marker")
    return {
        "case": case,
        "status": 200,
        "response_model": expected_model,
        "finish_reason": finish_reasons[-1] if finish_reasons else None,
    }


def tool() -> dict[str, Any]:
    return {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get current weather.",
            "parameters": {
                "type": "object",
                "properties": {"city": {"type": "string"}},
                "required": ["city"],
            },
        },
    }


def run_model(base_url: str, key: str, model: str, expected_model: str) -> list[dict[str, Any]]:
    endpoint = base_url.rstrip("/") + "/chat/completions"
    cases: list[tuple[str, dict[str, Any]]] = [
        (
            "plain",
            {"model": model, "messages": [{"role": "user", "content": "Reply OK."}], "max_tokens": 8, "temperature": 0},
        ),
        (
            "reasoning-none",
            {"model": model, "messages": [{"role": "user", "content": "Reply OK."}], "max_completion_tokens": 16, "reasoning_effort": "none", "temperature": 0},
        ),
        (
            "reasoning-on",
            {"model": model, "messages": [{"role": "user", "content": "What is 2+2?"}], "max_completion_tokens": 32, "reasoning_effort": "medium", "temperature": 0},
        ),
        (
            "tool-auto",
            {"model": model, "messages": [{"role": "user", "content": "Weather in San Francisco?"}], "tools": [tool()], "tool_choice": "auto", "max_tokens": 64, "temperature": 0},
        ),
        (
            "tool-result",
            {
                "model": model,
                "messages": [
                    {"role": "user", "content": "Weather in San Francisco?"},
                    {"role": "assistant", "content": "", "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": '{"city":"San Francisco"}'}}]},
                    {"role": "tool", "tool_call_id": "call_1", "content": "15 C and foggy"},
                ],
                "tools": [tool()],
                "max_tokens": 64,
                "temperature": 0,
            },
        ),
        (
            "structured",
            {
                "model": model,
                "messages": [{"role": "user", "content": "Return city and temperature JSON."}],
                "response_format": {
                    "type": "json_schema",
                    "json_schema": {
                        "name": "weather",
                        "strict": True,
                        "schema": {
                            "type": "object",
                            "properties": {"city": {"type": "string"}, "temperature_c": {"type": "number"}},
                            "required": ["city", "temperature_c"],
                            "additionalProperties": False,
                        },
                    },
                },
                "chat_template_kwargs": {"enable_thinking": False},
                "max_tokens": 64,
                "temperature": 0,
            },
        ),
    ]
    records: list[dict[str, Any]] = []
    plain = cases.pop(0)
    status, payload, elapsed = request_json(endpoint, key, plain[0], plain[1])
    del status
    if not isinstance(payload, dict) or payload.get("model") != expected_model:
        raise ProbeError(f"{model} plain response model drifted")
    records.append(response_record(plain[0], payload, elapsed))

    stream_body = dict(plain[1], stream=True)
    _, stream_payload, elapsed = request_json(endpoint, key, "stream", stream_body)
    if not isinstance(stream_payload, str):
        raise ProbeError("stream did not return an event stream")
    stream_record = check_stream("stream", stream_payload, expected_model)
    stream_record["elapsed_seconds"] = round(elapsed, 6)
    records.append(stream_record)

    for case, body in cases:
        _, payload, elapsed = request_json(endpoint, key, case, body)
        if not isinstance(payload, dict) or payload.get("model") != expected_model:
            raise ProbeError(f"{model} {case} response model drifted")
        choice = (payload.get("choices") or [{}])[0]
        message = choice.get("message") or {}
        if case == "tool-auto" and not message.get("tool_calls"):
            raise ProbeError("tool-auto response did not contain a tool call")
        if case == "structured":
            try:
                structured = json.loads(message.get("content", ""))
            except json.JSONDecodeError as error:
                raise ProbeError("structured response was not JSON") from error
            if not {"city", "temperature_c"} <= set(structured):
                raise ProbeError("structured response omitted required fields")
        records.append(response_record(case, payload, elapsed))
    return records


def load_guard_module():
    spec = importlib.util.spec_from_file_location("glm52_contract_guard_probe", GUARD_MODULE)
    if spec is None or spec.loader is None:
        raise ProbeError("cannot load legacy renderer")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def boundary_repeats(renderer: Any, target: int) -> int:
    data = {"model": "glm-5.2", "messages": [{"role": "user", "content": ""}]}
    low, high = 0, target + 1024
    while low <= high:
        middle = (low + high) // 2
        data["messages"][0]["content"] = "x " * middle
        count = renderer.count(data)
        if count < target:
            low = middle + 1
        elif count > target:
            high = middle - 1
        else:
            return middle
    raise ProbeError(f"could not construct a {target}-token legacy prompt")


def backend_chat_request_total(url: str) -> float:
    with urllib.request.urlopen(url, timeout=15) as response:
        text = response.read().decode("utf-8", errors="replace")
    total = 0.0
    matched = False
    for line in text.splitlines():
        if (
            line.startswith("http_requests_total{")
            and 'handler="/v1/chat/completions"' in line
            and 'method="POST"' in line
        ):
            matched = True
            total += float(line.rsplit(" ", 1)[1])
    if not matched:
        raise ProbeError("backend metrics contained no chat-completions request counter")
    return total


def snapshot_backend_chat_requests(data: dict[str, Any]) -> dict[str, float]:
    backends = data.get("backends")
    if not isinstance(backends, dict):
        raise ProbeError("backend metrics input must contain a backends mapping")
    totals: dict[str, float] = {}
    for name, record in backends.items():
        if not isinstance(name, str) or not isinstance(record, dict):
            raise ProbeError("backend metrics record is invalid")
        url = record.get("url")
        if not isinstance(url, str) or not url:
            raise ProbeError("backend metrics URL is invalid")
        totals[name] = backend_chat_request_total(url)
    return totals


def check_backend_metrics(path: Path | None) -> tuple[dict[str, Any], dict[str, float]]:
    if path is None:
        return {}, {}
    data = json.loads(path.read_text(encoding="utf-8"))
    backends = data.get("backends")
    if not isinstance(backends, dict):
        raise ProbeError("backend metrics input must contain a backends mapping")
    after: dict[str, float] = {}
    for name, record in backends.items():
        if not isinstance(record, dict) or record.get("expect") not in ("unchanged", "increase"):
            raise ProbeError("backend metrics expectation is invalid")
        if "chat_request_total" not in record:
            raise ProbeError("backend metrics record is missing chat_request_total")
        after[name] = backend_chat_request_total(record["url"])
        before = float(record["chat_request_total"])
        if record["expect"] == "unchanged" and after[name] != before:
            raise ProbeError(f"backend {name} changed unexpectedly")
        if record["expect"] == "increase" and after[name] <= before:
            raise ProbeError(f"backend {name} did not receive probe traffic")
    return data, after


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
        os.chmod(path, 0o600)
    finally:
        temporary_path.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    artifact: dict[str, Any] = {"ok": False, "models": {}}
    try:
        if args.skip_boundary and os.environ.get("WEBSTER_CONTRACT_PROBE_TEST_MODE") != "1":
            raise ProbeError("--skip-boundary is test-only")
        key = read_key(args.key_file)
        mappings = expected_models(args.expected_response_model, args.models)
        for model in args.models:
            artifact["models"][model] = run_model(
                args.base_url, key, model, mappings[model]
            )

        before_metrics, after_metrics = check_backend_metrics(args.backend_metrics_before)
        artifact["backend_metrics_after"] = after_metrics

        if not args.skip_boundary:
            if args.tokenizer_dir is None:
                raise ProbeError("--tokenizer-dir is required for the legacy boundary probe")
            module = load_guard_module()
            renderer = module.LegacyGLM52Renderer(args.tokenizer_dir)
            repeats = boundary_repeats(renderer, 320001)
            boundary_body = {
                "model": "glm-5.2",
                "messages": [{"role": "user", "content": "x " * repeats}],
                "max_tokens": 1,
                "temperature": 0,
            }
            boundary_before = snapshot_backend_chat_requests(before_metrics)
            status, _, elapsed = request_json(
                args.base_url.rstrip("/") + "/chat/completions",
                key,
                "boundary-320001",
                boundary_body,
                expected_status=400,
            )
            boundary_after = snapshot_backend_chat_requests(before_metrics)
            if boundary_before != boundary_after:
                raise ProbeError("320001-token rejection reached a serving backend")
            artifact["boundary"] = {
                "prompt_tokens": 320001,
                "status": status,
                "elapsed_seconds": round(elapsed, 6),
                "backend_counters_unchanged": True,
            }
        artifact["ok"] = True
        atomic_json(args.output_json, artifact)
        print(f"contract probe passed; artifact={args.output_json}")
        return 0
    except (OSError, ValueError, json.JSONDecodeError, ProbeError) as error:
        artifact["error"] = str(error)
        atomic_json(args.output_json, artifact)
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
