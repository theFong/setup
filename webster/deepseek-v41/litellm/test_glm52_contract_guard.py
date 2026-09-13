#!/usr/bin/env python3
"""Behavior tests for the GLM-5.2 compatibility contract guard."""

from __future__ import annotations

import asyncio
import copy
import importlib.util
import json
import os
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


HERE = Path(__file__).resolve().parent
MODULE_PATH = HERE / "glm52_contract_guard.py"
spec = importlib.util.spec_from_file_location("glm52_contract_guard", MODULE_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load GLM-5.2 guard module")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
GLM52ContractGuard = module.GLM52ContractGuard
GLM52ContractError = module.GLM52ContractError
LegacyGLM52Renderer = module.LegacyGLM52Renderer


def run_guard(data: dict, *, count: int = 10, call_type: str = "completion") -> dict:
    guard = GLM52ContractGuard(counter=lambda _: count)
    return asyncio.run(guard.async_pre_call_hook(None, None, data, call_type))


class GLM52ContractGuardTests(unittest.TestCase):
    def assert_error_code(self, error: GLM52ContractError, code: str) -> None:
        self.assertEqual(error.status_code, 400)
        self.assertEqual(error.detail["error"]["code"], code)

    def test_prompt_over_limit_is_rejected_before_routing(self) -> None:
        guard = GLM52ContractGuard(counter=lambda _: 320_001)
        with self.assertRaises(GLM52ContractError) as caught:
            asyncio.run(
                guard.async_pre_call_hook(
                    None,
                    None,
                    {"model": "glm-5.2", "messages": []},
                    "completion",
                )
            )
        self.assert_error_code(caught.exception, "context_length_exceeded")

    def test_legacy_alias_rejects_image_content_before_routing(self) -> None:
        data = {
            "model": "glm-5.2",
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "Describe this image."},
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": "data:image/png;base64,iVBORw0KGgo="
                            },
                        },
                    ],
                }
            ],
            "max_tokens": 16,
        }
        with self.assertRaises(GLM52ContractError) as caught:
            run_guard(data)
        self.assert_error_code(caught.exception, "unsupported_vision")
        self.assertEqual(caught.exception.detail["error"]["param"], "messages")

    def test_contract_error_serializes_public_code_separately_from_http_status(self) -> None:
        error = GLM52ContractGuard._error(
            "unsupported_vision",
            "The legacy glm-5.2 contract does not support image input.",
            "messages",
        )

        self.assertEqual(error.status_code, 400)
        self.assertEqual(getattr(error, "code", None), "400")
        self.assertEqual(error.to_dict()["code"], "unsupported_vision")

    def test_explicit_output_over_remaining_budget_is_rejected_like_old_vllm(self) -> None:
        data = {"model": "glm-5.2", "messages": [], "max_tokens": 500}
        with self.assertRaises(GLM52ContractError) as caught:
            run_guard(data, count=319_900)
        self.assert_error_code(caught.exception, "context_length_exceeded")
        self.assertEqual(data["max_tokens"], 500)

    def test_explicit_output_at_remaining_budget_is_preserved(self) -> None:
        data = {"model": "glm-5.2", "messages": [], "max_tokens": 100}
        result = run_guard(data, count=319_900)
        self.assertEqual(result["max_tokens"], 100)

    def test_max_completion_tokens_takes_precedence(self) -> None:
        data = {
            "model": "glm-5.2",
            "messages": [],
            "max_tokens": 75,
            "max_completion_tokens": 100,
        }
        result = run_guard(data, count=319_900)
        self.assertEqual(result["max_completion_tokens"], 100)
        self.assertEqual(result["max_tokens"], 75)

    def test_responses_output_over_remaining_budget_is_rejected(self) -> None:
        normalized = [{"role": "user", "content": "hello"}]
        guard = GLM52ContractGuard(
            counter=lambda data: 319_900,
            responses_normalizer=lambda data: normalized,
        )
        data = {"model": "glm-5.2", "input": "hello", "max_output_tokens": 500}
        with self.assertRaises(GLM52ContractError) as caught:
            asyncio.run(guard.async_pre_call_hook(None, None, data, "responses"))
        self.assert_error_code(caught.exception, "context_length_exceeded")

    def test_absent_output_limit_uses_remaining_budget(self) -> None:
        result = run_guard({"model": "glm-5.2", "messages": []}, count=319_900)
        self.assertEqual(result["max_tokens"], 100)

    def test_exact_limit_prompt_is_rejected_when_no_output_token_remains(self) -> None:
        with self.assertRaises(GLM52ContractError) as caught:
            run_guard({"model": "glm-5.2", "messages": []}, count=320_000)
        self.assert_error_code(caught.exception, "context_length_exceeded")

    def test_native_glm53_is_untouched_and_not_counted(self) -> None:
        calls = []
        guard = GLM52ContractGuard(counter=lambda data: calls.append(data) or 1)
        data = {"model": "glm-5.3-flash", "messages": [], "max_tokens": 500_000}
        original = copy.deepcopy(data)
        result = asyncio.run(
            guard.async_pre_call_hook(None, None, data, "completion")
        )
        self.assertEqual(result, original)
        self.assertIs(result, data)
        self.assertEqual(calls, [])

    def test_exported_guard_is_a_custom_logger(self) -> None:
        self.assertIsInstance(module.glm52_contract_guard, module.CustomLogger)

    def test_other_models_are_untouched(self) -> None:
        data = {"model": "inkling-small-nvfp4", "messages": [{"role": "user", "content": "hi"}]}
        original = copy.deepcopy(data)
        self.assertEqual(run_guard(data), original)

    def test_invalid_output_limits_are_rejected(self) -> None:
        for value in (True, False, 0, -1, 1.5, "100", None):
            with self.subTest(value=value):
                data = {"model": "glm-5.2", "messages": [], "max_tokens": value}
                with self.assertRaises(GLM52ContractError) as caught:
                    run_guard(data)
                self.assert_error_code(caught.exception, "invalid_request_error")

    def test_counter_failure_fails_closed_only_for_alias(self) -> None:
        def fail(_: dict) -> int:
            raise RuntimeError("renderer unavailable")

        guard = GLM52ContractGuard(counter=fail)
        with self.assertRaises(GLM52ContractError) as caught:
            asyncio.run(
                guard.async_pre_call_hook(
                    None,
                    None,
                    {"model": "glm-5.2", "messages": []},
                    "completion",
                )
            )
        self.assert_error_code(caught.exception, "contract_tokenization_failed")
        control = {"model": "glm-5.3-flash", "messages": []}
        self.assertIs(
            asyncio.run(guard.async_pre_call_hook(None, None, control, "completion")),
            control,
        )

    def test_responses_input_is_normalized_before_counting(self) -> None:
        observed = []
        normalized = [{"role": "user", "content": "hello"}]
        guard = GLM52ContractGuard(
            counter=lambda data: observed.append(copy.deepcopy(data)) or 10,
            responses_normalizer=lambda data: normalized,
        )
        data = {"model": "glm-5.2", "input": "hello"}
        asyncio.run(guard.async_pre_call_hook(None, None, data, "aresponses"))
        self.assertEqual(observed[0]["messages"], normalized)
        self.assertNotIn("input", observed[0])
        self.assertEqual(data["input"], "hello")

    @unittest.skipUnless(
        module.CustomLogger.__module__.startswith("litellm."),
        "requires the installed LiteLLM Responses converter",
    )
    def test_installed_litellm_responses_converter_produces_chat_messages(self) -> None:
        data = {"model": "glm-5.2", "input": "hello", "max_output_tokens": 32}
        normalized = module.glm52_contract_guard._count_data(data, "responses")
        self.assertEqual(
            normalized["messages"],
            [{"role": "user", "content": "hello"}],
        )
        self.assertNotIn("input", normalized)

    def test_lazy_renderer_initializes_once_under_threads(self) -> None:
        created = 0
        created_lock = threading.Lock()

        class FakeRenderer:
            def count(self, _: dict) -> int:
                return 1

        def factory(_: Path) -> FakeRenderer:
            nonlocal created
            with created_lock:
                created += 1
            return FakeRenderer()

        guard = GLM52ContractGuard(renderer_factory=factory)
        with ThreadPoolExecutor(max_workers=8) as executor:
            counts = list(executor.map(lambda _: guard._count_prompt({}), range(32)))
        self.assertEqual(counts, [1] * 32)
        self.assertEqual(created, 1)

    def test_missing_tokenizer_files_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            guard = GLM52ContractGuard(tokenizer_dir=Path(temporary))
            with self.assertRaises(GLM52ContractError) as caught:
                asyncio.run(
                    guard.async_pre_call_hook(
                        None,
                        None,
                        {"model": "glm-5.2", "messages": []},
                        "completion",
                    )
                )
        self.assert_error_code(caught.exception, "contract_tokenization_failed")

    def test_fixture_shapes_reach_the_counter_unchanged(self) -> None:
        fixtures = Path(__file__).resolve().parents[1] / "tests" / "fixtures"
        for name in (
            "chat.json",
            "reasoning-none.json",
            "tools.json",
            "tool-result.json",
            "structured.json",
        ):
            with self.subTest(name=name):
                payload = json.loads((fixtures / name).read_text(encoding="utf-8"))
                observed = []
                guard = GLM52ContractGuard(
                    counter=lambda data: observed.append(copy.deepcopy(data)) or 10
                )
                asyncio.run(
                    guard.async_pre_call_hook(None, None, payload, "completion")
                )
                self.assertEqual(observed[0]["messages"], payload["messages"])
                self.assertEqual(observed[0].get("tools"), payload.get("tools"))
                self.assertEqual(
                    observed[0].get("chat_template_kwargs"),
                    payload.get("chat_template_kwargs"),
                )

    @unittest.skipUnless(
        os.environ.get("GLM52_TOKENIZER_DIR"),
        "set GLM52_TOKENIZER_DIR to run the legacy tokenizer golden test",
    )
    def test_renderer_matches_old_vllm_tokenize_for_short_fixtures(self) -> None:
        fixtures = Path(__file__).resolve().parents[1] / "tests" / "fixtures"
        goldens = json.loads(
            (fixtures / "tokenize-golden.json").read_text(encoding="utf-8")
        )
        renderer = LegacyGLM52Renderer(Path(os.environ["GLM52_TOKENIZER_DIR"]))
        for name, expected in goldens.items():
            with self.subTest(name=name):
                payload = json.loads((fixtures / name).read_text(encoding="utf-8"))
                actual = renderer.token_ids(payload)
                self.assertEqual(actual, expected["token_ids"])
                self.assertEqual(len(actual), expected["count"])


if __name__ == "__main__":
    unittest.main()
