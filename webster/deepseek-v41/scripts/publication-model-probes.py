#!/usr/bin/env python3
"""Run the authenticated public model and ingress publication probes."""

from __future__ import annotations

import base64
import json
import os
import struct
import subprocess
import sys
import urllib.error
import urllib.request
import zlib
from typing import Any


PUBLIC_API = (
    "https://webster-models-extnode-3gdrajbr0hiykknxzitck9yaiwo.apps.run.brev.nvidia.com"
)
ADMIN_API = "http://127.0.0.1:4446"
PRIVATE_API = "http://127.0.0.1:4444"
MIGRATION_CRITICAL_MODELS = (
    "deepseek-v4.1-flash",
    "glm-5.2",
    "glm-5.3-flash",
    "deepseek-v4-flash",
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def read_json_payload(response: Any) -> Any:
    raw = response.read()
    if not raw:
        return None
    try:
        return json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None


def request(
    base: str,
    path: str,
    body: dict[str, Any] | None = None,
    key: str | None = None,
    timeout: int = 180,
) -> tuple[int, Any]:
    headers = {}
    data = None
    if key is not None:
        headers["Authorization"] = "Bearer " + key
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body, separators=(",", ":")).encode()
    value = urllib.request.Request(
        base + path,
        data=data,
        headers=headers,
        method="POST" if body is not None else "GET",
    )
    try:
        with urllib.request.urlopen(value, timeout=timeout) as response:
            return response.status, read_json_payload(response)
    except urllib.error.HTTPError as error:
        return error.code, read_json_payload(error)


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


def probe_legacy_vision_rejection(public_api: str, key: str) -> int:
    status, payload = request(
        public_api,
        "/v1/chat/completions",
        {
            "model": "glm-5.2",
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "Describe this image."},
                        {
                            "type": "image_url",
                            "image_url": {"url": red_png_data_url()},
                        },
                    ],
                }
            ],
            "max_tokens": 16,
            "reasoning_effort": "none",
        },
        key,
    )
    require(status == 400, "legacy alias accepted image input")
    error = payload.get("error") if isinstance(payload, dict) else None
    code = error.get("code") if isinstance(error, dict) else None
    require(
        code == "unsupported_vision",
        "legacy alias image rejection did not come from the compatibility guard "
        f"(expected unsupported_vision, got {code!r})",
    )
    return status


def master_key() -> str:
    override = os.environ.get("WEBSTER_PUBLICATION_MASTER_KEY")
    if override:
        return override
    environment = subprocess.check_output(
        [
            "docker",
            "inspect",
            "litellm",
            "--format",
            "{{range .Config.Env}}{{println .}}{{end}}",
        ],
        text=True,
    ).splitlines()
    return next(
        item.split("=", 1)[1]
        for item in environment
        if item.startswith("LITELLM_MASTER_KEY=")
    )


def run(probe_id: str) -> dict[str, Any]:
    public_api = os.environ.get("WEBSTER_PUBLICATION_PUBLIC_API", PUBLIC_API).rstrip("/")
    admin_api = os.environ.get("WEBSTER_PUBLICATION_ADMIN_API", ADMIN_API).rstrip("/")
    private_api = os.environ.get("WEBSTER_PUBLICATION_PRIVATE_API", PRIVATE_API).rstrip("/")
    master = master_key()

    def admin(path: str, body: dict[str, Any]) -> tuple[int, Any]:
        return request(admin_api, path, body, master, 30)

    key = None
    results: dict[str, Any] = {}
    try:
        info_status, info = request(admin_api, "/model/info", key=master)
        require(
            info_status == 200 and isinstance(info, dict),
            "model info request failed",
        )
        rows = info.get("data", info)
        require(isinstance(rows, list), "model info response is malformed")
        by_name = {
            row.get("model_name"): row
            for row in rows
            if isinstance(row, dict)
        }
        missing_models = [
            model for model in MIGRATION_CRITICAL_MODELS if model not in by_name
        ]
        require(
            not missing_models,
            "migration-critical models are absent from the current registry: "
            + ", ".join(missing_models),
        )
        models = list(MIGRATION_CRITICAL_MODELS)
        status, created = admin(
            "/key/generate",
            {
                "key_alias": "deepseek-v41-publication-acceptance",
                "models": models,
                "max_budget": 1.0,
                "budget_duration": "1d",
            },
        )
        require(status == 200, "temporary publication key creation failed")
        require(isinstance(created, dict) and created.get("key"), "temporary publication key response is malformed")
        key = created["key"]
        for model in models:
            body: dict[str, Any] = {
                "model": model,
                "messages": [{"role": "user", "content": "Reply with exactly OK."}],
                "max_tokens": 16,
                "temperature": 0,
                "reasoning_effort": "none",
            }
            if model == "deepseek-v4.1-flash":
                body["user"] = probe_id
                body["metadata"] = {"acceptance_probe_id": probe_id}
            response_status, payload = request(
                public_api, "/v1/chat/completions", body, key
            )
            require(
                response_status == 200
                and isinstance(payload, dict)
                and payload.get("choices"),
                f"public probe failed for {model}",
            )
            require(payload.get("model") == model, f"public response model differs for {model}")
            results[model] = response_status
            if model == "deepseek-v4.1-flash":
                results["acceptance_probe_id"] = probe_id
        results["glm-5.2-vision-rejection"] = probe_legacy_vision_rejection(
            public_api, key
        )
        root, _ = request(public_api, "/")
        unauthenticated, _ = request(public_api, "/v1/models")
        admin_denied, _ = request(public_api, "/key/info")
        require(
            (root, unauthenticated, admin_denied) == (403, 401, 403),
            "ingress security responses are wrong",
        )
        deepseek = by_name["deepseek-v4.1-flash"]["model_info"]
        require(
            deepseek["max_input_tokens"]
            == deepseek["max_output_tokens"]
            == 1048576,
            "DeepSeek context metadata is wrong",
        )
        require(deepseek["supports_vision"] is True, "DeepSeek vision metadata is wrong")
        require(
            deepseek["supports_function_calling"] is True,
            "DeepSeek tool metadata is wrong",
        )
        require(
            deepseek["supports_reasoning"] is True,
            "DeepSeek reasoning metadata is wrong",
        )
        require(
            deepseek["supports_response_schema"] is True,
            "DeepSeek schema metadata is wrong",
        )
        legacy = by_name["glm-5.2"]["model_info"]
        require(
            legacy["max_input_tokens"]
            == legacy["max_output_tokens"]
            == 320000,
            "legacy context metadata is wrong",
        )
        require(legacy["supports_vision"] is False, "legacy vision metadata is wrong")
        results["ingress"] = {
            "root": root,
            "unauthenticated_models": unauthenticated,
            "admin": admin_denied,
        }
    finally:
        if key is not None:
            delete_status, _ = admin("/key/delete", {"keys": [key]})
            require(delete_status == 200, "temporary publication key revocation failed")
            revoked, _ = request(private_api, "/v1/models", key=key)
            require(revoked == 401, "revoked publication key is still accepted")
            results["revoked_key_status"] = revoked
    return results


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: publication-model-probes.py PROBE_ID")
    print(json.dumps(run(sys.argv[1]), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
