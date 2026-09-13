"""Preserve the original GLM-5.2 shared 320K token contract.

The public ``glm-5.2`` name may route to a backend with a larger context window. This
pre-call hook renders requests with the original tokenizer/template, rejects prompts
whose prompt-plus-output budget exceeds the old limit, and supplies the positive
remaining budget when no output field was requested.
All other public model names bypass the guard without initialization or mutation.
"""

from __future__ import annotations

import asyncio
import copy
import inspect
import json
import threading
from pathlib import Path
from typing import Any, Callable

try:
    from litellm.proxy._types import ProxyException
except ImportError:  # pragma: no cover - exercised by the dependency-light local suite
    class ProxyException(Exception):
        def __init__(
            self,
            message: str,
            type: str,
            param: str | None,
            code: int | str,
            openai_code: str | None = None,
        ) -> None:
            self.message = message
            self.type = type
            self.param = param
            self.code = str(code)
            self.openai_code = openai_code or str(code)
            super().__init__(message)

        def to_dict(self) -> dict[str, Any]:
            return {
                "message": self.message,
                "type": self.type,
                "param": self.param,
                "code": self.code,
            }


try:
    from litellm.integrations.custom_logger import CustomLogger
except ImportError:  # pragma: no cover - exact-image tests require the real base class
    class CustomLogger:
        pass


PUBLIC_MODEL = "glm-5.2"
LEGACY_CONTEXT_TOKENS = 320_000
DEFAULT_TOKENIZER_DIR = Path("/app/custom_callbacks/glm52-tokenizer")
VISION_CONTENT_TYPES = frozenset({"image", "image_url", "input_image"})


class GLM52ContractError(ProxyException):
    """Keep the OpenAI error code distinct from LiteLLM's HTTP status field."""

    def __init__(self, code: str, message: str, param: str | None) -> None:
        self.status_code = 400
        self.detail = {
            "error": {
                "message": message,
                "type": "invalid_request_error",
                "param": param,
                "code": code,
            }
        }
        super().__init__(
            message=message,
            type="invalid_request_error",
            param=param,
            code=self.status_code,
            openai_code=code,
        )

    def to_dict(self) -> dict[str, Any]:
        payload = super().to_dict()
        payload["code"] = self.openai_code
        return payload


def _plain(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _plain(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(item) for item in value]
    model_dump = getattr(value, "model_dump", None)
    if callable(model_dump):
        return _plain(model_dump(exclude_none=True))
    return value


class LegacyGLM52Renderer:
    """Thread-safe-after-construction tokenizer and immutable Jinja renderer."""

    REQUIRED_FILES = ("tokenizer.json", "tokenizer_config.json", "chat_template.jinja")

    def __init__(self, tokenizer_dir: Path):
        root = tokenizer_dir.resolve(strict=True)
        if not root.is_dir():
            raise RuntimeError(f"legacy tokenizer path is not a directory: {root}")
        for name in self.REQUIRED_FILES:
            path = root / name
            if not path.is_file() or path.is_symlink():
                raise RuntimeError(f"missing regular legacy tokenizer file: {name}")

        try:
            from jinja2 import ext
            from jinja2.sandbox import ImmutableSandboxedEnvironment
            from tokenizers import Tokenizer
        except ImportError as error:
            raise RuntimeError(f"legacy tokenizer dependency unavailable: {error}") from error

        self._tokenizer = Tokenizer.from_file(str(root / "tokenizer.json"))
        template_text = (root / "chat_template.jinja").read_text(encoding="utf-8")

        def tojson(
            value: Any,
            ensure_ascii: bool = False,
            indent: int | None = None,
            separators: tuple[str, str] | None = None,
            sort_keys: bool = False,
        ) -> str:
            return json.dumps(
                value,
                ensure_ascii=ensure_ascii,
                indent=indent,
                separators=separators,
                sort_keys=sort_keys,
            )

        environment = ImmutableSandboxedEnvironment(
            trim_blocks=True,
            lstrip_blocks=True,
            extensions=[ext.loopcontrols],
        )
        environment.filters["tojson"] = tojson
        self._template = environment.from_string(template_text)

    @staticmethod
    def _normalize_messages(messages: Any) -> list[dict[str, Any]]:
        if not isinstance(messages, list):
            raise RuntimeError("messages must be a list")
        normalized = _plain(copy.deepcopy(messages))
        for message in normalized:
            if not isinstance(message, dict) or not isinstance(message.get("role"), str):
                raise RuntimeError("each message must contain a role")
            for tool_call in message.get("tool_calls") or []:
                if not isinstance(tool_call, dict):
                    raise RuntimeError("tool call must be an object")
                function = tool_call.get("function", tool_call)
                if not isinstance(function, dict):
                    raise RuntimeError("tool-call function must be an object")
                arguments = function.get("arguments")
                if isinstance(arguments, str):
                    try:
                        parsed = json.loads(arguments)
                    except json.JSONDecodeError as error:
                        raise RuntimeError("tool-call arguments are not valid JSON") from error
                    if not isinstance(parsed, dict):
                        raise RuntimeError("tool-call arguments must decode to an object")
                    function["arguments"] = parsed
        return normalized

    @staticmethod
    def _template_kwargs(data: dict[str, Any]) -> dict[str, Any]:
        user_kwargs = data.get("chat_template_kwargs") or {}
        if not isinstance(user_kwargs, dict):
            raise RuntimeError("chat_template_kwargs must be an object")
        result = copy.deepcopy(user_kwargs)
        extra_kwargs = {
            "add_generation_prompt": data.get("add_generation_prompt", True),
            "continue_final_message": data.get("continue_final_message"),
            "documents": data.get("documents"),
            "reasoning_effort": data.get("reasoning_effort"),
        }
        if (
            data.get("reasoning_effort") is not None
            and "enable_thinking" not in user_kwargs
        ):
            extra_kwargs["enable_thinking"] = data["reasoning_effort"] != "none"
        for key, value in extra_kwargs.items():
            if value not in (None, "auto"):
                result[key] = value
        result["messages"] = LegacyGLM52Renderer._normalize_messages(
            data.get("messages")
        )
        tools = _plain(copy.deepcopy(data.get("tools")))
        result["tools"] = tools
        result["add_generation_prompt"] = bool(result.get("add_generation_prompt", True))
        return result

    def token_ids(self, data: dict[str, Any]) -> list[int]:
        rendered = self._template.render(**self._template_kwargs(data))
        return self._tokenizer.encode(rendered, add_special_tokens=False).ids

    def count(self, data: dict[str, Any]) -> int:
        return len(self.token_ids(data))


class GLM52ContractGuard(CustomLogger):
    def __init__(
        self,
        *,
        counter: Callable[[dict[str, Any]], int] | None = None,
        tokenizer_dir: Path = DEFAULT_TOKENIZER_DIR,
        renderer_factory: Callable[[Path], Any] = LegacyGLM52Renderer,
        responses_normalizer: Callable[[dict[str, Any]], list[Any]] | None = None,
    ) -> None:
        try:
            super().__init__()
        except TypeError:
            # Older LiteLLM CustomLogger releases did not require initialization.
            pass
        self._counter = counter
        self._tokenizer_dir = Path(tokenizer_dir)
        self._renderer_factory = renderer_factory
        self._responses_normalizer = responses_normalizer
        self._renderer: Any | None = None
        self._renderer_lock = threading.Lock()

    @staticmethod
    def _error(
        code: str, message: str, param: str | None = None
    ) -> GLM52ContractError:
        return GLM52ContractError(code, message, param)

    def _get_renderer(self) -> Any:
        if self._renderer is None:
            with self._renderer_lock:
                if self._renderer is None:
                    self._renderer = self._renderer_factory(self._tokenizer_dir)
        return self._renderer

    def _count_prompt(self, data: dict[str, Any]) -> int:
        return self._get_renderer().count(data)

    def _normalize_responses(self, data: dict[str, Any]) -> list[Any]:
        if self._responses_normalizer is not None:
            return self._responses_normalizer(data)
        try:
            from litellm.responses.litellm_completion_transformation.transformation import (
                LiteLLMCompletionResponsesConfig,
            )
        except ImportError as error:
            raise RuntimeError("LiteLLM Responses normalizer is unavailable") from error
        return LiteLLMCompletionResponsesConfig.transform_responses_api_input_to_messages(
            input=data.get("input", ""),
            responses_api_request=data,
        )

    def _count_data(self, data: dict[str, Any], call_type: str) -> dict[str, Any]:
        normalized = copy.deepcopy(data)
        if call_type in ("responses", "aresponses") or (
            "input" in normalized and "messages" not in normalized
        ):
            normalized["messages"] = _plain(self._normalize_responses(normalized))
            normalized.pop("input", None)
        return normalized

    @staticmethod
    def _contains_vision(messages: Any) -> bool:
        if not isinstance(messages, list):
            return False
        for message in messages:
            if not isinstance(message, dict):
                continue
            content = message.get("content")
            if not isinstance(content, list):
                continue
            for part in content:
                part = _plain(part)
                if not isinstance(part, dict):
                    continue
                if part.get("type") in VISION_CONTENT_TYPES:
                    return True
                if "image_url" in part:
                    return True
        return False

    @staticmethod
    def _output_field(data: dict[str, Any], call_type: str) -> str:
        if call_type in ("responses", "aresponses") or (
            "input" in data and "messages" not in data
        ):
            return "max_output_tokens"
        if "max_completion_tokens" in data:
            return "max_completion_tokens"
        return "max_tokens"

    async def async_pre_call_hook(
        self,
        user_api_key_dict: Any,
        cache: Any,
        data: dict[str, Any],
        call_type: str,
    ) -> dict[str, Any]:
        del user_api_key_dict, cache
        if data.get("model") != PUBLIC_MODEL:
            return data

        try:
            count_data = self._count_data(data, call_type)
            if self._contains_vision(count_data.get("messages")):
                raise self._error(
                    "unsupported_vision",
                    "The legacy glm-5.2 contract does not support image input.",
                    "messages" if "messages" in data else "input",
                )
            if self._counter is None:
                prompt_tokens = await asyncio.to_thread(self._count_prompt, count_data)
            else:
                prompt_tokens = self._counter(count_data)
                if inspect.isawaitable(prompt_tokens):
                    prompt_tokens = await prompt_tokens
            if isinstance(prompt_tokens, bool) or not isinstance(prompt_tokens, int):
                raise RuntimeError("prompt counter did not return an integer")
            if prompt_tokens < 0:
                raise RuntimeError("prompt counter returned a negative value")
        except GLM52ContractError:
            raise
        except Exception as error:
            raise self._error(
                "contract_tokenization_failed",
                "The legacy glm-5.2 token contract could not be evaluated.",
                "messages" if "messages" in data else "input",
            ) from error

        if prompt_tokens > LEGACY_CONTEXT_TOKENS:
            raise self._error(
                "context_length_exceeded",
                (
                    f"This model's maximum context length is {LEGACY_CONTEXT_TOKENS} "
                    f"tokens. The rendered prompt has {prompt_tokens} tokens."
                ),
                "messages" if "messages" in data else "input",
            )

        remaining = LEGACY_CONTEXT_TOKENS - prompt_tokens
        output_field = self._output_field(data, call_type)
        if output_field in data:
            requested = data[output_field]
            if isinstance(requested, bool) or not isinstance(requested, int) or requested <= 0:
                raise self._error(
                    "invalid_request_error",
                    f"{output_field} must be a positive integer.",
                    output_field,
                )
            if requested > remaining:
                raise self._error(
                    "context_length_exceeded",
                    (
                        f"This model's maximum context length is "
                        f"{LEGACY_CONTEXT_TOKENS} tokens. The rendered prompt has "
                        f"{prompt_tokens} tokens and {requested} output tokens were "
                        "requested."
                    ),
                    output_field,
                )
        else:
            if remaining <= 0:
                raise self._error(
                    "context_length_exceeded",
                    (
                        f"This model's maximum context length is "
                        f"{LEGACY_CONTEXT_TOKENS} tokens. The rendered prompt has "
                        f"{prompt_tokens} tokens, leaving no room for output."
                    ),
                    "messages" if "messages" in data else "input",
                )
            data[output_field] = remaining
        return data


glm52_contract_guard = GLM52ContractGuard()
