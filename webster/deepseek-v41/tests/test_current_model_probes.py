#!/usr/bin/env python3
"""Behavior tests for the scoped current-model baseline probe."""

from __future__ import annotations

import importlib.util
import io
import unittest
import urllib.error
from pathlib import Path


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = PACKAGE_ROOT / "scripts" / "current-model-probes.py"


def load_module():
    spec = importlib.util.spec_from_file_location("current_model_probes", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CurrentModelProbeTests(unittest.TestCase):
    def test_bedrock_converse_omits_output_limit_while_vllm_keeps_it(self) -> None:
        module = load_module()
        calls = []

        def post(url, body, key, timeout):
            calls.append((url, body, key, timeout))
            if url.endswith("/key/generate"):
                return 200, {"key": "sk-fixture-secret"}
            if url.endswith("/key/delete"):
                return 200, {}
            return 200, {"choices": [{"message": {"content": "OK"}}], "model": body["model"]}

        module.run_scoped_probes(
            [
                ("glm-5.2", "hosted_vllm/nvidia/GLM-5.2-NVFP4"),
                ("aws/openai-gpt-5.6-sol", "bedrock/converse/us.openai.gpt-5.6-sol"),
            ],
            "20990101T000000Z",
            "master-fixture-secret",
            post=post,
        )

        completion_bodies = [
            body for url, body, _, _ in calls if url.endswith("/v1/chat/completions")
        ]
        self.assertEqual(completion_bodies[0]["max_tokens"], 8)
        self.assertNotIn("max_tokens", completion_bodies[1])

    def test_http_error_names_model_and_status_then_revokes_without_body_or_key(self) -> None:
        module = load_module()
        calls = []

        def post(url, body, key, timeout):
            calls.append((url, body, key, timeout))
            if url.endswith("/key/generate"):
                return 200, {"key": "sk-fixture-secret"}
            if url.endswith("/key/delete"):
                return 200, {}
            raise urllib.error.HTTPError(
                url,
                400,
                "Bad Request",
                {},
                io.BytesIO(b"sensitive provider response"),
            )

        with self.assertRaises(RuntimeError) as caught:
            module.run_scoped_probes(
                [("aws/xai-grok-4.6", "bedrock/converse/us.xai.grok-4.6")],
                "20990101T000000Z",
                "master-fixture-secret",
                post=post,
            )

        message = str(caught.exception)
        self.assertEqual(
            message,
            "completion probe failed model=aws/xai-grok-4.6 status=400",
        )
        self.assertNotIn("sensitive provider response", message)
        self.assertNotIn("fixture-secret", message)
        delete_calls = [call for call in calls if call[0].endswith("/key/delete")]
        self.assertEqual(len(delete_calls), 1)
        self.assertEqual(delete_calls[0][1], {"keys": ["sk-fixture-secret"]})


if __name__ == "__main__":
    unittest.main()
