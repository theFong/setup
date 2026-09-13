#!/usr/bin/env python3
"""Behavior tests for exact-token DeepSeek long-context qualification."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = (
    REPOSITORY_ROOT
    / "webster"
    / "deepseek-v41"
    / "scripts"
    / "long-context-qualification.py"
)


class LongContextQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.key_file = self.root / "canary.key"
        self.key_file.write_text("test-long-context-key\n", encoding="utf-8")
        os.chmod(self.key_file, 0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_runner(
        self,
        base_url: str,
        output: Path,
        *,
        expect_success: bool,
        targets: tuple[int, ...] = (64, 96),
        max_model_len: int = 128,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(SCRIPT),
            "--base-url",
            base_url,
            "--model",
            "deepseek-ai/DeepSeek-V4.1-Flash",
            "--key-file",
            str(self.key_file),
            "--max-model-len",
            str(max_model_len),
            "--output-json",
            str(output),
        ]
        for target in targets:
            command.extend(("--target-context", str(target)))
        result = subprocess.run(
            command,
            cwd=REPOSITORY_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        if expect_success and result.returncode != 0:
            self.fail(result.stderr)
        if not expect_success and result.returncode == 0:
            self.fail(result.stdout)
        self.assertNotIn("test-long-context-key", result.stdout + result.stderr)
        return result

    def test_exact_context_targets_and_over_limit_rejection_are_qualified(self) -> None:
        chat_totals: list[int] = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                return

            def send_json(self, status: int, value: object) -> None:
                encoded = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
                length = int(self.headers.get("Content-Length", "0"))
                request = json.loads(self.rfile.read(length))
                if self.headers.get("Authorization") != "Bearer test-long-context-key":
                    self.send_json(401, {"error": {"message": "unauthorized"}})
                    return
                content = request["messages"][0]["content"]
                prompt_tokens = 4 + content.count(" x")
                if self.path == "/tokenize":
                    if request.get("chat_template_kwargs") != {
                        "enable_thinking": False
                    }:
                        self.send_json(
                            400,
                            {"error": {"message": "thinking template mismatch"}},
                        )
                        return
                    self.send_json(
                        200,
                        {
                            "count": prompt_tokens,
                            "max_model_len": 128,
                            "tokens": [],
                            "token_strs": [],
                        },
                    )
                    return
                self.assert_chat_request(request)
                total = prompt_tokens + request["max_tokens"]
                chat_totals.append(total)
                if total > 128:
                    self.send_json(
                        400,
                        {"error": {"message": "maximum context length is 128 tokens"}},
                    )
                    return
                self.send_json(
                    200,
                    {
                        "choices": [
                            {
                                "message": {"role": "assistant", "content": "x"},
                                "finish_reason": "length",
                            }
                        ],
                        "usage": {
                            "prompt_tokens": prompt_tokens,
                            "completion_tokens": 1,
                            "total_tokens": total,
                        },
                    },
                )

            def assert_chat_request(self, request: dict[str, object]) -> None:
                testcase.assertEqual(self.path, "/v1/chat/completions")
                testcase.assertEqual(request["reasoning_effort"], "none")
                testcase.assertEqual(request["temperature"], 0)
                testcase.assertEqual(request["max_tokens"], 1)

        testcase = self
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        output = self.root / "long-context.json"
        try:
            self.run_runner(
                f"http://127.0.0.1:{server.server_port}",
                output,
                expect_success=True,
            )
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()

        self.assertEqual(chat_totals, [64, 96, 129])
        artifact = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertTrue(artifact["ok"])
        self.assertEqual(artifact["max_model_len"], 128)
        self.assertEqual(
            [case["target_context_tokens"] for case in artifact["accepted"]],
            [64, 96],
        )
        self.assertTrue(all(case["status"] == 200 for case in artifact["accepted"]))
        self.assertTrue(
            all(case["server_prompt_tokens"] == case["expected_prompt_tokens"] for case in artifact["accepted"])
        )
        self.assertEqual(artifact["over_limit"]["target_context_tokens"], 129)
        self.assertEqual(artifact["over_limit"]["status"], 400)
        self.assertNotIn(
            "test-long-context-key", output.read_text(encoding="utf-8")
        )

    def test_tokenizer_mismatch_fails_before_chat_and_records_evidence(self) -> None:
        chat_requests = 0

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
                nonlocal chat_requests
                length = int(self.headers.get("Content-Length", "0"))
                request = json.loads(self.rfile.read(length))
                if self.path != "/tokenize":
                    chat_requests += 1
                repetitions = request["messages"][0]["content"].count(" x")
                count = 4 + repetitions
                if repetitions == 59:
                    count -= 1
                encoded = json.dumps(
                    {
                        "count": count,
                        "max_model_len": 128,
                        "tokens": [],
                        "token_strs": [],
                    }
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        output = self.root / "mismatch.json"
        try:
            self.run_runner(
                f"http://127.0.0.1:{server.server_port}",
                output,
                expect_success=False,
                targets=(64,),
            )
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()

        self.assertEqual(chat_requests, 0)
        artifact = json.loads(output.read_text(encoding="utf-8"))
        self.assertFalse(artifact["ok"])
        self.assertEqual(artifact["accepted"][0]["tokenize_status"], 200)
        self.assertFalse(artifact["accepted"][0]["token_count_exact"])


if __name__ == "__main__":
    unittest.main()
