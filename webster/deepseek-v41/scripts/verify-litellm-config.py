#!/usr/bin/env python3
"""Fail closed unless a LiteLLM candidate contains only the approved alias change."""

from __future__ import annotations

import argparse
import copy
import math
import stat
import sys
from collections import Counter
from pathlib import Path
from typing import Any

import yaml


ALIAS = "glm-5.2"
NATIVE = "glm-5.3-flash"
GUARD_CALLBACK = "custom_callbacks.glm52_contract_guard.glm52_contract_guard"
KV_ROUTER_PLUGINS = ["custom_callbacks.kv_router.plugin"]
DESCRIPTION = (
    "Deprecated GLM-5.2 compatibility alias served by GLM-5.3-Flash; legacy "
    "320000-token shared window, reasoning, and function-calling contract retained; "
    "no advertised vision capability."
)
PUBLISHED_MODEL = "deepseek-v4.1-flash"
PUBLISHED_API_BASE = "http://100.73.140.127:8000/v1"
PUBLISHED_DESCRIPTION = (
    "DeepSeek V4.1 Flash on the Shamu/Tilikum station pair; "
    "qualified private TP2 profile."
)


class ValidationError(RuntimeError):
    """An intentionally non-secret configuration validation failure."""


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


def model_map(config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    models = config.get("model_list")
    if not isinstance(models, list):
        raise ValidationError("model_list must be a list")
    names = [item.get("model_name") if isinstance(item, dict) else None for item in models]
    if any(not isinstance(name, str) or not name for name in names):
        raise ValidationError("every model deployment must have a nonempty public name")
    duplicates = [name for name, count in Counter(names).items() if count != 1]
    if duplicates:
        raise ValidationError("every existing public model name must have one deployment")
    return {item["model_name"]: item for item in models}


def expected_alias_config(before: dict[str, Any]) -> dict[str, Any]:
    expected = copy.deepcopy(before)
    models = model_map(expected)
    if ALIAS not in models or NATIVE not in models:
        raise ValidationError("configuration must contain one GLM-5.2 alias and one native GLM-5.3")

    alias = models[ALIAS]
    native = models[NATIVE]
    alias_params = alias.get("litellm_params")
    native_params = native.get("litellm_params")
    if not isinstance(alias_params, dict) or not isinstance(native_params, dict):
        raise ValidationError("GLM deployments must contain litellm_params mappings")
    for key in ("model", "api_base", "api_key"):
        if key not in native_params:
            raise ValidationError(f"native GLM-5.3 deployment is missing {key}")
        alias_params[key] = copy.deepcopy(native_params[key])

    model_info = alias.get("model_info")
    if not isinstance(model_info, dict):
        raise ValidationError("GLM-5.2 model_info must be a mapping")
    model_info.update(
        {
            "max_input_tokens": 320000,
            "max_output_tokens": 320000,
            "supports_function_calling": True,
            "supports_reasoning": True,
            "supports_vision": False,
            "input_cost_per_token": 6.0e-08,
            "output_cost_per_token": 1.7e-06,
            "description": DESCRIPTION,
        }
    )
    settings = expected.get("litellm_settings")
    if not isinstance(settings, dict):
        raise ValidationError("litellm_settings must be a mapping")
    callbacks = settings.get("callbacks")
    if not isinstance(callbacks, list) or any(
        not isinstance(callback, str) for callback in callbacks
    ):
        raise ValidationError("litellm_settings.callbacks must be a list of strings")
    settings["callbacks"] = [
        GUARD_CALLBACK,
        *(callback for callback in callbacks if callback != GUARD_CALLBACK),
    ]
    return expected


def diff_paths(expected: Any, actual: Any, prefix: str = "root") -> list[str]:
    if type(expected) is not type(actual):
        return [prefix]
    if isinstance(expected, dict):
        paths: list[str] = []
        for key in sorted(set(expected) | set(actual), key=str):
            child = f"{prefix}.{key}"
            if key not in expected or key not in actual:
                paths.append(child)
            else:
                paths.extend(diff_paths(expected[key], actual[key], child))
        return paths
    if isinstance(expected, list):
        if len(expected) != len(actual):
            return [prefix]
        paths = []
        for index, (expected_item, actual_item) in enumerate(zip(expected, actual)):
            paths.extend(diff_paths(expected_item, actual_item, f"{prefix}[{index}]"))
        return paths
    return [] if expected == actual else [prefix]


def validate_alias(before: dict[str, Any], after: dict[str, Any]) -> None:
    before_models = model_map(before)
    after_models = model_map(after)
    if list(before_models) != list(after_models):
        raise ValidationError("public model names or deployment order changed")

    for config in (before, after):
        router = config.get("router_settings")
        if not isinstance(router, dict):
            raise ValidationError("router_settings must be a mapping")
        if router.get("plugins") != KV_ROUTER_PLUGINS:
            raise ValidationError("KV router plugin contract changed")
        if router.get("enable_pre_call_checks") is True:
            raise ValidationError("global enable_pre_call_checks is forbidden")

    expected = expected_alias_config(before)
    differences = diff_paths(expected, after)
    if differences:
        preview = ", ".join(differences[:8])
        suffix = "" if len(differences) <= 8 else ", ..."
        raise ValidationError(f"candidate contains disallowed semantic changes at {preview}{suffix}")


def expected_publish_config(
    before: dict[str, Any],
    *,
    api_key: str,
    served_model_name: str,
    max_context: int,
    input_cost_per_token: float,
    output_cost_per_token: float,
    supports_vision: bool,
) -> dict[str, Any]:
    if not api_key:
        raise ValidationError("published backend API key is empty")
    if not served_model_name or served_model_name.startswith("hosted_vllm/"):
        raise ValidationError("served model name must be the backend model identifier")
    if not 1 <= max_context <= 1_048_576:
        raise ValidationError("published context must be between 1 and 1048576")
    for label, value in (
        ("input cost", input_cost_per_token),
        ("output cost", output_cost_per_token),
    ):
        if not math.isfinite(value) or value <= 0:
            raise ValidationError(f"published {label} must be positive and finite")

    expected = copy.deepcopy(before)
    models = model_map(expected)
    if PUBLISHED_MODEL in models:
        raise ValidationError(f"{PUBLISHED_MODEL} already exists")
    expected["model_list"].append(
        {
            "model_name": PUBLISHED_MODEL,
            "litellm_params": {
                "model": "hosted_vllm/" + served_model_name,
                "api_base": PUBLISHED_API_BASE,
                "api_key": api_key,
            },
            "model_info": {
                "mode": "chat",
                "max_input_tokens": max_context,
                "max_output_tokens": max_context,
                "supports_function_calling": True,
                "supports_reasoning": True,
                "supports_response_schema": True,
                **({"supports_vision": True} if supports_vision else {}),
                "input_cost_per_token": input_cost_per_token,
                "output_cost_per_token": output_cost_per_token,
                "description": PUBLISHED_DESCRIPTION,
            },
        }
    )
    return expected


def validate_publish(before: dict[str, Any], after: dict[str, Any]) -> None:
    before_models = model_map(before)
    after_models = model_map(after)
    if PUBLISHED_MODEL in before_models:
        raise ValidationError(f"{PUBLISHED_MODEL} already exists before publication")
    if list(after_models) != [*before_models, PUBLISHED_MODEL]:
        raise ValidationError("publish phase must append exactly one approved public model")
    for name, deployment in before_models.items():
        if after_models[name] != deployment:
            raise ValidationError(f"existing model changed during publication: {name}")
    for top_level_key in set(before) | set(after):
        if top_level_key == "model_list":
            continue
        if before.get(top_level_key) != after.get(top_level_key):
            raise ValidationError(
                f"non-model configuration changed during publication: {top_level_key}"
            )

    published = after_models[PUBLISHED_MODEL]
    params = published.get("litellm_params")
    info = published.get("model_info")
    if not isinstance(params, dict) or set(params) != {"model", "api_base", "api_key"}:
        raise ValidationError("published litellm_params shape is invalid")
    if params.get("api_base") != PUBLISHED_API_BASE:
        raise ValidationError("published model must use the Shamu NetBird canary")
    if not isinstance(params.get("model"), str) or not params["model"].startswith(
        "hosted_vllm/"
    ):
        raise ValidationError("published backend model identifier is invalid")
    if not isinstance(params.get("api_key"), str) or not params["api_key"]:
        raise ValidationError("published backend key is absent")
    required_info = {
        "mode",
        "max_input_tokens",
        "max_output_tokens",
        "supports_function_calling",
        "supports_reasoning",
        "supports_response_schema",
        "input_cost_per_token",
        "output_cost_per_token",
        "description",
    }
    if not isinstance(info, dict) or set(info) not in (
        required_info,
        required_info | {"supports_vision"},
    ):
        raise ValidationError("published model_info shape is invalid")
    if info.get("mode") != "chat" or info.get("description") != PUBLISHED_DESCRIPTION:
        raise ValidationError("published mode or description is invalid")
    if info.get("max_input_tokens") != info.get("max_output_tokens") or not isinstance(
        info.get("max_input_tokens"), int
    ):
        raise ValidationError("published context fields must match")
    if not 1 <= info["max_input_tokens"] <= 1_048_576:
        raise ValidationError("published context is outside the qualified range")
    for capability in (
        "supports_function_calling",
        "supports_reasoning",
        "supports_response_schema",
    ):
        if info.get(capability) is not True:
            raise ValidationError(f"published capability is invalid: {capability}")
    if "supports_vision" in info and info["supports_vision"] is not True:
        raise ValidationError("supports_vision may only be advertised when true")
    for cost_key in ("input_cost_per_token", "output_cost_per_token"):
        value = info.get(cost_key)
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            raise ValidationError(f"published {cost_key} is invalid")
        if not math.isfinite(float(value)) or float(value) <= 0:
            raise ValidationError(f"published {cost_key} must be positive and finite")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--phase", required=True, choices=("alias", "publish"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        before = load_config(args.before)
        after = load_config(args.after)
        mode = stat.S_IMODE(args.after.stat().st_mode)
        if mode != 0o600:
            raise ValidationError("candidate configuration mode must be 0600")
        if args.phase == "alias":
            validate_alias(before, after)
        else:
            validate_publish(before, after)
    except ValidationError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"allowed semantic diff validated for {args.phase} phase")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
