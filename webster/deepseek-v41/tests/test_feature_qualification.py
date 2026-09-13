#!/usr/bin/env python3
"""Behavior tests for the private DeepSeek feature qualification runner."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = (
    REPOSITORY_ROOT
    / "webster"
    / "deepseek-v41"
    / "scripts"
    / "feature-qualification.py"
)


class FeatureQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.key_file = self.root / "canary.key"
        self.key_file.write_text("test-deepseek-key\n", encoding="utf-8")
        os.chmod(self.key_file, 0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_runner(
        self,
        base_url: str,
        output: Path,
        *,
        expect_success: bool,
        stage: str = "eager",
        extra_args: list[str] | None = None,
        environment: dict[str, str] | None = None,
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
            "--stage",
            stage,
            "--output-json",
            str(output),
        ]
        command.extend(extra_args or [])
        result = subprocess.run(
            command,
            cwd=REPOSITORY_ROOT,
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )
        if expect_success and result.returncode != 0:
            self.fail(result.stderr)
        if not expect_success and result.returncode == 0:
            self.fail(result.stdout)
        self.assertNotIn("test-deepseek-key", result.stdout + result.stderr)
        return result

    def test_eager_stage_records_the_full_required_capability_contract(self) -> None:
        seen_cases: list[str] = []
        seen_requests: dict[str, dict[str, object]] = {}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length)
                if self.headers.get("Authorization") != "Bearer test-deepseek-key":
                    self.send_error(401)
                    return
                case = self.headers["X-Feature-Qualification-Case"]
                seen_cases.append(case)
                if case == "malformed-input":
                    if raw != b'{"model":':
                        self.send_error(422)
                        return
                    self.send_error(400)
                    return
                request = json.loads(raw)
                seen_requests[case] = request
                if case == "wrong-model":
                    self.send_error(404)
                    return
                expected_effort = "low" if case == "reasoning-on" else "none"
                if request.get("reasoning_effort") != expected_effort:
                    response = {
                        "model": "deepseek-ai/DeepSeek-V4.1-Flash",
                        "choices": [
                            {
                                "message": {
                                    "role": "assistant",
                                    "content": None,
                                    "reasoning": "default reasoning consumed the budget",
                                },
                                "finish_reason": "length",
                            }
                        ],
                        "usage": {
                            "prompt_tokens": 7,
                            "completion_tokens": 32,
                            "total_tokens": 39,
                            "completion_tokens_details": {
                                "reasoning_tokens": 32
                            },
                        },
                    }
                    encoded = json.dumps(response).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                    return
                if request.get("stream"):
                    chunks = (
                        {"choices": [{"delta": {"content": "stream "}}]},
                        {
                            "choices": [
                                {
                                    "delta": {"content": "ok"},
                                    "finish_reason": "stop",
                                }
                            ],
                            "usage": {
                                "prompt_tokens": 7,
                                "completion_tokens": 2,
                                "total_tokens": 9,
                            },
                        },
                    )
                    body = "".join(
                        f"data: {json.dumps(chunk)}\n\n" for chunk in chunks
                    ) + "data: [DONE]\n\n"
                    encoded = body.encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                    return
                if case == "disconnect-queue-drain":
                    chunk = {
                        "choices": [{"delta": {"content": "started"}}]
                    }
                    encoded = f"data: {json.dumps(chunk)}\n\n".encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                    return

                content = {
                    "deterministic-text": "QUALIFICATION_OK",
                    "utf8": "café 東京 🚀",
                    "stop-sequence": "before",
                    "usage-accounting": "usage ok",
                    "reasoning-on": "42",
                    "tool-auto": "",
                    "tool-named": "",
                    "tool-required": "",
                    "tool-parallel": "",
                    "tool-result": "17 + 25 = 42",
                    "structured": '{"city":"Paris","country":"France"}',
                    "json-object": '{"city":"Paris","country":"France"}',
                    "vision": "red",
                }[case]
                message = {"role": "assistant", "content": content}
                if case == "reasoning-on":
                    message["reasoning"] = "17 + 25 equals 42."
                if case in {"tool-auto", "tool-named", "tool-required"}:
                    message["tool_calls"] = [
                        {
                            "id": "call_1",
                            "type": "function",
                            "function": {
                                "name": "add",
                                "arguments": '{"a":17,"b":25}',
                            },
                        }
                    ]
                if case == "tool-parallel":
                    message["tool_calls"] = [
                        {
                            "id": "call_1",
                            "type": "function",
                            "function": {
                                "name": "add",
                                "arguments": '{"a":17,"b":25}',
                            },
                        },
                        {
                            "id": "call_2",
                            "type": "function",
                            "function": {
                                "name": "add",
                                "arguments": '{"a":9,"b":11}',
                            },
                        },
                    ]
                response = {
                    "model": "deepseek-ai/DeepSeek-V4.1-Flash",
                    "choices": [
                        {
                            "message": message,
                            "finish_reason": (
                                "tool_calls"
                                if case.startswith("tool-")
                                and case != "tool-result"
                                else "stop"
                            ),
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 7,
                        "completion_tokens": 2,
                        "total_tokens": 9,
                        "completion_tokens_details": {
                            "reasoning_tokens": 1 if case == "reasoning-on" else 0
                        },
                    },
                }
                encoded = json.dumps(response).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
                if self.path != "/metrics":
                    self.send_error(404)
                    return
                encoded = (
                    "vllm:num_requests_running 0\n"
                    "vllm:num_requests_waiting 0\n"
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        output = self.root / "eager.json"
        failure_log = self.root / "eager-failure-server.log"
        try:
            self.run_runner(
                f"http://127.0.0.1:{server.server_port}/v1",
                output,
                expect_success=True,
                extra_args=[
                    "--failure-log-output",
                    str(failure_log),
                    "--server-log-node",
                    "shamu",
                    "--server-log-node",
                    "tilikum",
                ],
            )
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()

        self.assertEqual(
            set(seen_cases),
            {
                "deterministic-text",
                "utf8",
                "stop-sequence",
                "streaming",
                "usage-accounting",
                "reasoning-on",
                "tool-auto",
                "tool-named",
                "tool-required",
                "tool-parallel",
                "tool-result",
                "structured",
                "json-object",
                "vision",
                "malformed-input",
                "wrong-model",
                "disconnect-queue-drain",
            },
        )
        counts = Counter(seen_cases)
        self.assertEqual(counts["deterministic-text"], 3)
        self.assertTrue(all(count == 1 for case, count in counts.items() if case != "deterministic-text"))
        self.assertEqual(
            seen_requests["tool-named"]["tool_choice"],
            {"type": "function", "function": {"name": "add"}},
        )
        self.assertEqual(seen_requests["tool-required"]["tool_choice"], "required")
        self.assertIs(seen_requests["tool-parallel"]["parallel_tool_calls"], True)
        self.assertEqual(
            seen_requests["json-object"]["response_format"],
            {"type": "json_object"},
        )
        self.assertEqual(seen_requests["wrong-model"]["model"], "qualification-wrong-model")
        artifact = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertTrue(artifact["ok"])
        self.assertFalse(failure_log.exists())
        self.assertEqual(
            artifact["failure_log_capture"],
            {
                "requested": True,
                "captured": False,
                "ok": True,
                "path": str(failure_log.resolve()),
                "nodes": ["shamu", "tilikum"],
                "container": "deepseek-v41-flash-tp2",
            },
        )
        self.assertEqual(artifact["stage"], "eager")
        self.assertEqual(len(artifact["cases"]), 17)
        for result in artifact["cases"]:
            self.assertTrue(result["semantic_ok"], result)
            expected_status = {
                "malformed-input": 400,
                "wrong-model": 404,
            }.get(result["case"], 200)
            self.assertEqual(result["status"], expected_status)
            self.assertRegex(result["request_hash"], r"^[0-9a-f]{64}$")
            self.assertRegex(result["normalized_output_hash"], r"^[0-9a-f]{64}$")
            self.assertGreaterEqual(result["latency_seconds"], 0)
            if expected_status == 200 and result["case"] != "disconnect-queue-drain":
                self.assertEqual(result["token_usage"]["total_tokens"], 9)
        deterministic = next(
            result
            for result in artifact["cases"]
            if result["case"] == "deterministic-text"
        )
        self.assertEqual(deterministic["repetitions"], 3)
        self.assertEqual(deterministic["distinct_normalized_outputs"], 1)
        disconnect = next(
            result
            for result in artifact["cases"]
            if result["case"] == "disconnect-queue-drain"
        )
        self.assertTrue(disconnect["client_disconnected"])
        self.assertTrue(disconnect["queue_drained"])
        self.assertNotIn("test-deepseek-key", output.read_text(encoding="utf-8"))

    def test_group_readable_key_is_rejected_before_network_access(self) -> None:
        os.chmod(self.key_file, 0o640)
        result = self.run_runner(
            "http://127.0.0.1:1/v1",
            self.root / "unsafe.json",
            expect_success=False,
        )
        self.assertIn("0600", result.stderr)

    def test_graph_stage_is_recorded_for_a_failed_network_qualification(self) -> None:
        output = self.root / "graphs.json"
        self.run_runner(
            "http://127.0.0.1:1/v1",
            output,
            expect_success=False,
            stage="graphs",
        )
        artifact = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(artifact["stage"], "graphs")
        self.assertEqual(len(artifact["cases"]), 17)

    def test_http_error_is_recorded_instead_of_crashing_on_message_access(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
                self.send_error(429)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        output = self.root / "http-error.json"
        try:
            self.run_runner(
                f"http://127.0.0.1:{server.server_port}/v1",
                output,
                expect_success=False,
            )
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()

        artifact = json.loads(output.read_text(encoding="utf-8"))
        self.assertFalse(artifact["ok"])
        self.assertEqual(len(artifact["cases"]), 17)
        regular = [
            result
            for result in artifact["cases"]
            if result["case"] != "disconnect-queue-drain"
        ]
        self.assertTrue(all(result["status"] == 429 for result in regular))
        disconnect = next(
            result
            for result in artifact["cases"]
            if result["case"] == "disconnect-queue-drain"
        )
        self.assertEqual(disconnect["status"], 0)
        self.assertEqual(disconnect["error"], "HTTPError")
        self.assertTrue(
            all(not result["semantic_ok"] for result in artifact["cases"])
        )

    def test_failure_captures_both_rank_logs_without_credentials(self) -> None:
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        invocation_log = self.root / "ssh-invocations.log"
        fake_ssh = fake_bin / "ssh"
        fake_ssh.write_text(
            "#!/usr/bin/env bash\n"
            'printf "%s auth_sock=%s\\n" "$*" "${SSH_AUTH_SOCK-unset}" '
            '>>"$TEST_SSH_INVOCATIONS"\n'
            'printf "Authorization: Bearer sk-should-never-survive\\n"\n'
            'printf "VLLM_API_KEY=raw-hex-secret-should-not-survive\\n"\n'
            'printf "rank diagnostic for %s\\n" "$1"\n',
            encoding="utf-8",
        )
        os.chmod(fake_ssh, 0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
        environment["TEST_SSH_INVOCATIONS"] = str(invocation_log)
        environment["SSH_AUTH_SOCK"] = "/tmp/agent.sock"
        output = self.root / "failed.json"
        failure_log = self.root / "failure-server.log"
        self.run_runner(
            "http://127.0.0.1:1/v1",
            output,
            expect_success=False,
            extra_args=[
                "--failure-log-output",
                str(failure_log),
                "--server-log-node",
                "shamu",
                "--server-log-node",
                "tilikum",
                "--server-container",
                "deepseek-v41-flash-tp2",
            ],
            environment=environment,
        )
        captured = failure_log.read_text(encoding="utf-8")
        self.assertEqual(failure_log.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("sk-should-never-survive", captured)
        self.assertNotIn("raw-hex-secret-should-not-survive", captured)
        self.assertIn("Authorization: Bearer [REDACTED]", captured)
        invocations = invocation_log.read_text(encoding="utf-8")
        self.assertIn(
            "shamu docker logs --since", invocations
        )
        self.assertIn(
            "tilikum sudo -n docker logs --since", invocations
        )
        self.assertNotIn("/tmp/agent.sock", invocations)
        artifact = json.loads(output.read_text(encoding="utf-8"))
        capture = artifact["failure_log_capture"]
        self.assertTrue(capture["ok"])
        self.assertEqual(capture["path"], str(failure_log.resolve()))
        self.assertRegex(capture["sha256"], r"^[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main()
