#!/usr/bin/env python3
"""Run safe, model-scoped completion probes from the LiteLLM host."""

from __future__ import annotations

import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

import yaml


ADMIN_BASE_URL = "http://127.0.0.1:4446"
COMPLETION_URL = "http://127.0.0.1:4444/v1/chat/completions"


def post_json(url: str, body: dict, key: str, timeout: int) -> tuple[int, dict]:
    request = urllib.request.Request(
        url,
        data=json.dumps(body, separators=(",", ":")).encode(),
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status, json.load(response)


def probe_body(model_name: str, provider_model: str) -> dict:
    body = {
        "model": model_name,
        "messages": [{"role": "user", "content": "Reply OK."}],
    }
    if provider_model.startswith("hosted_vllm/"):
        body["max_tokens"] = 8
    return body


def run_scoped_probes(
    deployments: list[tuple[str, str]],
    change_id: str,
    master_key: str,
    *,
    post: Callable[[str, dict, str, int], tuple[int, dict]] = post_json,
) -> dict:
    virtual_key = None
    results = []
    try:
        _, created = post(
            ADMIN_BASE_URL + "/key/generate",
            {
                "key_alias": f"baseline-{change_id}",
                "models": [model_name for model_name, _ in deployments],
                "max_budget": 0.5,
                "budget_duration": "1d",
            },
            master_key,
            30,
        )
        virtual_key = created["key"]
        for model_name, provider_model in deployments:
            started = time.monotonic()
            try:
                status, payload = post(
                    COMPLETION_URL,
                    probe_body(model_name, provider_model),
                    virtual_key,
                    180,
                )
            except urllib.error.HTTPError as error:
                raise RuntimeError(
                    f"completion probe failed model={model_name} status={error.code}"
                ) from None
            except Exception as error:
                raise RuntimeError(
                    "completion probe failed "
                    f"model={model_name} exception={type(error).__name__}"
                ) from None

            choices = payload.get("choices")
            if status != 200 or not isinstance(choices, list) or not choices:
                raise RuntimeError(
                    f"completion probe failed model={model_name} status={status}"
                )
            results.append(
                {
                    "model": model_name,
                    "status": status,
                    "response_model": payload.get("model"),
                    "elapsed_seconds": round(time.monotonic() - started, 6),
                }
            )
    finally:
        if virtual_key is not None:
            try:
                delete_status, _ = post(
                    ADMIN_BASE_URL + "/key/delete",
                    {"keys": [virtual_key]},
                    master_key,
                    30,
                )
            except urllib.error.HTTPError as error:
                raise RuntimeError(
                    f"temporary scoped key revocation failed status={error.code}"
                ) from None
            except Exception as error:
                raise RuntimeError(
                    "temporary scoped key revocation failed "
                    f"exception={type(error).__name__}"
                ) from None
            if delete_status != 200:
                raise RuntimeError(
                    f"temporary scoped key revocation failed status={delete_status}"
                )
    return {"models": results, "key_revoked": True}


def current_master_key() -> str:
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
        line.split("=", 1)[1]
        for line in environment
        if line.startswith("LITELLM_MASTER_KEY=")
    )


def current_deployments() -> list[tuple[str, str]]:
    config = yaml.safe_load(Path("/home/nvidia/litellm/config.yaml").read_text())
    deployments = []
    seen = set()
    for item in config["model_list"]:
        model_name = item["model_name"]
        if model_name in seen:
            continue
        provider_model = item["litellm_params"]["model"]
        deployments.append((model_name, provider_model))
        seen.add(model_name)
    return deployments


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        raise SystemExit("usage: current-model-probes.py CHANGE_ID")
    result = run_scoped_probes(
        current_deployments(),
        argv[1],
        current_master_key(),
    )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
