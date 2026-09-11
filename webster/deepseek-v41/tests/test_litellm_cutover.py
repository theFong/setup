#!/usr/bin/env python3
"""Behavior tests for semantic LiteLLM alias rendering and shape checks."""

from __future__ import annotations

import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import yaml


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
PACKAGE_ROOT = REPOSITORY_ROOT / "webster" / "deepseek-v41"
SCRIPTS = PACKAGE_ROOT / "scripts"
RENDER = SCRIPTS / "render-litellm-cutover.py"
VERIFY_CONFIG = SCRIPTS / "verify-litellm-config.py"
VERIFY_CONTAINER = SCRIPTS / "verify-litellm-container.py"
CONTRACT_PROBE = SCRIPTS / "contract-probe.py"
GUARD_CALLBACK = "custom_callbacks.glm52_contract_guard.glm52_contract_guard"
SECRET_VALUES = ("os.environ/OLD_BACKEND_KEY", "os.environ/NEW_BACKEND_KEY")


def before_config() -> dict:
    return {
        "model_list": [
            {
                "model_name": "glm-5.2",
                "litellm_params": {
                    "model": "hosted_vllm/nvidia/GLM-5.2-NVFP4",
                    "api_base": "http://100.73.140.127:8000/v1",
                    "api_key": SECRET_VALUES[0],
                },
                "model_info": {
                    "mode": "chat",
                    "max_input_tokens": 320000,
                    "max_output_tokens": 320000,
                    "supports_function_calling": True,
                    "supports_reasoning": True,
                    "input_cost_per_token": 5.8e-08,
                    "output_cost_per_token": 3.8e-06,
                    "description": "Station GLM-5.2",
                    "compatibility_note": "preserve-me",
                },
            },
            {
                "model_name": "glm-5.3-flash",
                "litellm_params": {
                    "model": "hosted_vllm/zai-org/GLM-5.3-Flash",
                    "api_base": "http://100.73.165.55:8000/v1",
                    "api_key": SECRET_VALUES[1],
                },
                "model_info": {
                    "mode": "chat",
                    "max_input_tokens": 1048576,
                    "max_output_tokens": 1048576,
                    "supports_function_calling": True,
                    "supports_reasoning": True,
                    "supports_vision": True,
                    "input_cost_per_token": 6.0e-08,
                    "output_cost_per_token": 1.7e-06,
                    "description": "Native GLM-5.3",
                },
            },
            {
                "model_name": "unrelated-model",
                "litellm_params": {
                    "model": "openai/unrelated",
                    "api_key": "os.environ/UNRELATED_KEY",
                },
                "model_info": {"mode": "chat", "description": "untouched"},
            },
        ],
        "general_settings": {"store_prompts_in_spend_logs": True},
        "litellm_settings": {
            "callbacks": [
                "custom_callbacks.session_mapper.session_mapper",
                "langfuse_otel",
                "custom_callbacks.cost_in_body_logger.logger",
            ]
        },
        "router_settings": {"plugins": ["custom_callbacks.kv_router.plugin"]},
        "key_management_settings": {
            "default_team_settings": [{"models": ["glm-5.2"]}]
        },
    }


def valid_inspect() -> list[dict]:
    return [
        {
            "Id": "container-id",
            "Image": "sha256:" + "0" * 64,
            "Config": {
                "Image": "ghcr.io/berriai/litellm:main-latest",
                "Entrypoint": ["docker/prod_entrypoint.sh"],
                "Cmd": [
                    "--config",
                    "/app/config.yaml",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    "4446",
                ],
                "Env": ["LITELLM_MASTER_KEY=never-print-this"],
                "User": "",
            },
            "HostConfig": {
                "NetworkMode": "host",
                "RestartPolicy": {"Name": "unless-stopped", "MaximumRetryCount": 0},
                "PortBindings": {},
                "CapAdd": None,
                "Ulimits": [],
            },
            "Mounts": [
                {
                    "Type": "bind",
                    "Source": "/home/nvidia/litellm/config.yaml",
                    "Destination": "/app/config.yaml",
                    "Mode": "ro",
                    "RW": False,
                }
            ],
        }
    ]


class LiteLLMCutoverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.before = self.root / "before.yaml"
        self.candidate = self.root / "candidate.yaml"
        self.before.write_text(
            yaml.safe_dump(before_config(), sort_keys=False), encoding="utf-8"
        )
        os.chmod(self.before, 0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_script(
        self, script: Path, *arguments: str, expect_success: bool
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [sys.executable, str(script), *arguments],
            cwd=REPOSITORY_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        if expect_success and result.returncode != 0:
            self.fail(f"{script.name} failed: {result.stderr}")
        if not expect_success and result.returncode == 0:
            self.fail(f"{script.name} unexpectedly succeeded: {result.stdout}")
        for secret in SECRET_VALUES:
            self.assertNotIn(secret, result.stdout + result.stderr)
        return result

    def render_candidate(self) -> dict:
        self.run_script(
            RENDER,
            str(self.before),
            str(self.candidate),
            expect_success=True,
        )
        return yaml.safe_load(self.candidate.read_text(encoding="utf-8"))

    def test_renderer_changes_only_the_legacy_alias_contract(self) -> None:
        original = self.before.read_bytes()
        candidate = self.render_candidate()
        self.assertEqual(self.before.read_bytes(), original)
        self.assertEqual(self.candidate.stat().st_mode & 0o777, 0o600)

        models = {item["model_name"]: item for item in candidate["model_list"]}
        alias = models["glm-5.2"]
        native = models["glm-5.3-flash"]
        self.assertEqual(alias["litellm_params"], native["litellm_params"])
        self.assertEqual(
            alias["model_info"],
            {
                "mode": "chat",
                "max_input_tokens": 320000,
                "max_output_tokens": 320000,
                "supports_function_calling": True,
                "supports_reasoning": True,
                "input_cost_per_token": 6.0e-08,
                "output_cost_per_token": 1.7e-06,
                "description": (
                    "Deprecated GLM-5.2 compatibility alias served by "
                    "GLM-5.3-Flash; legacy 320000-token shared window, reasoning, "
                    "and function-calling contract retained; no advertised vision "
                    "capability."
                ),
                "compatibility_note": "preserve-me",
            },
        )
        self.assertEqual(models["unrelated-model"], before_config()["model_list"][2])
        self.assertEqual(
            candidate["litellm_settings"]["callbacks"],
            [GUARD_CALLBACK, *before_config()["litellm_settings"]["callbacks"]],
        )
        self.assertEqual(
            candidate["router_settings"], before_config()["router_settings"]
        )
        self.assertEqual(
            candidate["key_management_settings"],
            before_config()["key_management_settings"],
        )

    def test_renderer_is_idempotent(self) -> None:
        self.render_candidate()
        second = self.root / "second.yaml"
        self.run_script(
            RENDER,
            str(self.candidate),
            str(second),
            expect_success=True,
        )
        self.assertEqual(
            yaml.safe_load(second.read_text(encoding="utf-8")),
            yaml.safe_load(self.candidate.read_text(encoding="utf-8")),
        )

    def test_allowed_diff_verifier_accepts_the_rendered_candidate(self) -> None:
        self.render_candidate()
        result = self.run_script(
            VERIFY_CONFIG,
            str(self.before),
            str(self.candidate),
            "--phase",
            "alias",
            expect_success=True,
        )
        self.assertIn("allowed semantic diff", result.stdout)

    def test_allowed_diff_verifier_rejects_unrelated_model_mutation(self) -> None:
        candidate = self.render_candidate()
        candidate["model_list"][2]["model_info"]["description"] = "changed"
        self.candidate.write_text(
            yaml.safe_dump(candidate, sort_keys=False), encoding="utf-8"
        )
        self.run_script(
            VERIFY_CONFIG,
            str(self.before),
            str(self.candidate),
            "--phase",
            "alias",
            expect_success=False,
        )

    def test_allowed_diff_verifier_rejects_missing_kv_router(self) -> None:
        candidate = self.render_candidate()
        candidate["router_settings"]["plugins"] = []
        self.candidate.write_text(
            yaml.safe_dump(candidate, sort_keys=False), encoding="utf-8"
        )
        self.run_script(
            VERIFY_CONFIG,
            str(self.before),
            str(self.candidate),
            "--phase",
            "alias",
            expect_success=False,
        )

    def test_allowed_diff_verifier_rejects_global_pre_call_checks(self) -> None:
        candidate = self.render_candidate()
        candidate["router_settings"]["enable_pre_call_checks"] = True
        self.candidate.write_text(
            yaml.safe_dump(candidate, sort_keys=False), encoding="utf-8"
        )
        self.run_script(
            VERIFY_CONFIG,
            str(self.before),
            str(self.candidate),
            "--phase",
            "alias",
            expect_success=False,
        )

    def test_allowed_diff_verifier_rejects_duplicate_public_name(self) -> None:
        candidate = self.render_candidate()
        candidate["model_list"].append(copy.deepcopy(candidate["model_list"][0]))
        self.candidate.write_text(
            yaml.safe_dump(candidate, sort_keys=False), encoding="utf-8"
        )
        self.run_script(
            VERIFY_CONFIG,
            str(self.before),
            str(self.candidate),
            "--phase",
            "alias",
            expect_success=False,
        )

    def test_container_shape_accepts_the_exact_live_command_contract(self) -> None:
        inspect_path = self.root / "inspect.json"
        inspect_path.write_text(json.dumps(valid_inspect()), encoding="utf-8")
        result = self.run_script(
            VERIFY_CONTAINER, str(inspect_path), expect_success=True
        )
        self.assertIn("container shape valid", result.stdout)
        self.assertNotIn("never-print-this", result.stdout)

    def test_container_shape_rejects_duplicate_entrypoint_in_cmd(self) -> None:
        inspect = valid_inspect()
        inspect[0]["Config"]["Cmd"] = [
            "docker/prod_entrypoint.sh",
            *inspect[0]["Config"]["Cmd"],
        ]
        inspect_path = self.root / "inspect.json"
        inspect_path.write_text(json.dumps(inspect), encoding="utf-8")
        self.run_script(VERIFY_CONTAINER, str(inspect_path), expect_success=False)

    def test_container_shape_rejects_wrong_bind_or_port(self) -> None:
        for token, replacement in (("127.0.0.1", "0.0.0.0"), ("4446", "4444")):
            with self.subTest(token=token):
                inspect = valid_inspect()
                command = inspect[0]["Config"]["Cmd"]
                command[command.index(token)] = replacement
                inspect_path = self.root / f"inspect-{token.replace('.', '-')}.json"
                inspect_path.write_text(json.dumps(inspect), encoding="utf-8")
                self.run_script(
                    VERIFY_CONTAINER, str(inspect_path), expect_success=False
                )

    def test_container_recreation_must_match_the_baseline_shape(self) -> None:
        baseline = self.root / "baseline.json"
        candidate = self.root / "recreation.json"
        baseline.write_text(json.dumps(valid_inspect()), encoding="utf-8")
        changed = valid_inspect()
        changed[0]["HostConfig"]["NetworkMode"] = "bridge"
        candidate.write_text(json.dumps(changed), encoding="utf-8")
        self.run_script(
            VERIFY_CONTAINER,
            str(candidate),
            "--baseline",
            str(baseline),
            expect_success=False,
        )

    def test_contract_probe_exercises_real_chat_shapes_without_leaking_key(self) -> None:
        seen_cases: list[str] = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length))
                if self.headers.get("Authorization") != "Bearer test-contract-key":
                    self.send_error(401)
                    return
                case = self.headers.get("X-Contract-Probe-Case", "missing")
                seen_cases.append(case)
                if body.get("stream"):
                    chunks = [
                        {
                            "model": "legacy-response-model",
                            "choices": [
                                {"delta": {"content": "ok"}, "finish_reason": None}
                            ],
                        },
                        {
                            "model": "legacy-response-model",
                            "choices": [{"delta": {}, "finish_reason": "stop"}],
                        },
                    ]
                    payload = "".join(
                        f"data: {json.dumps(chunk)}\n\n" for chunk in chunks
                    ) + "data: [DONE]\n\n"
                    encoded = payload.encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                    return

                message: dict = {"role": "assistant", "content": "ok"}
                if case == "tool-auto":
                    message = {
                        "role": "assistant",
                        "content": None,
                        "tool_calls": [
                            {
                                "id": "call_1",
                                "type": "function",
                                "function": {
                                    "name": "get_weather",
                                    "arguments": '{"city":"San Francisco"}',
                                },
                            }
                        ],
                    }
                elif case == "structured":
                    message["content"] = '{"city":"San Francisco","temperature_c":15}'
                response = {
                    "model": "legacy-response-model",
                    "choices": [{"message": message, "finish_reason": "stop"}],
                    "usage": {
                        "prompt_tokens": 10,
                        "completion_tokens": 2,
                        "total_tokens": 12,
                    },
                }
                encoded = json.dumps(response).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            key_file = self.root / "probe.key"
            key_file.write_text("test-contract-key\n", encoding="utf-8")
            os.chmod(key_file, 0o600)
            output = self.root / "probe.json"
            environment = os.environ.copy()
            environment["WEBSTER_CONTRACT_PROBE_TEST_MODE"] = "1"
            result = subprocess.run(
                [
                    sys.executable,
                    str(CONTRACT_PROBE),
                    "--base-url",
                    f"http://127.0.0.1:{server.server_port}/v1",
                    "--models",
                    "glm-5.2",
                    "--key-file",
                    str(key_file),
                    "--expected-response-model",
                    "glm-5.2=legacy-response-model",
                    "--output-json",
                    str(output),
                    "--skip-boundary",
                ],
                cwd=REPOSITORY_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            set(seen_cases),
            {
                "plain",
                "stream",
                "reasoning-none",
                "reasoning-on",
                "tool-auto",
                "tool-result",
                "structured",
            },
        )
        artifact = json.loads(output.read_text(encoding="utf-8"))
        self.assertTrue(artifact["ok"])
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("test-contract-key", output.read_text(encoding="utf-8"))

    def test_contract_probe_rejects_a_group_readable_key(self) -> None:
        key_file = self.root / "probe.key"
        key_file.write_text("test-contract-key\n", encoding="utf-8")
        os.chmod(key_file, 0o640)
        result = subprocess.run(
            [
                sys.executable,
                str(CONTRACT_PROBE),
                "--base-url",
                "http://127.0.0.1:1/v1",
                "--models",
                "glm-5.2",
                "--key-file",
                str(key_file),
                "--expected-response-model",
                "glm-5.2=legacy-response-model",
                "--output-json",
                str(self.root / "probe.json"),
                "--skip-boundary",
            ],
            cwd=REPOSITORY_ROOT,
            env={**os.environ, "WEBSTER_CONTRACT_PROBE_TEST_MODE": "1"},
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("0600", result.stderr)

    def test_backend_counter_includes_rejected_chat_requests(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                return

            def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
                payload = b"""\
http_requests_total{handler=\"/v1/chat/completions\",method=\"POST\",status=\"2xx\"} 7
http_requests_total{handler=\"/v1/chat/completions\",method=\"POST\",status=\"4xx\"} 3
http_requests_total{handler=\"/v1/models\",method=\"GET\",status=\"2xx\"} 100
vllm:request_success_total{finished_reason=\"stop\"} 1000
"""
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            spec = importlib.util.spec_from_file_location("contract_probe", CONTRACT_PROBE)
            assert spec is not None and spec.loader is not None
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            total = module.backend_chat_request_total(
                f"http://127.0.0.1:{server.server_port}/metrics"
            )
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()
        self.assertEqual(total, 10.0)

    def test_boundary_snapshot_covers_unchanged_and_increasing_backends(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                return

            def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
                count = 11 if self.path == "/old" else 22
                payload = (
                    "http_requests_total{handler=\"/v1/chat/completions\","
                    f"method=\"POST\",status=\"2xx\"}} {count}\n"
                ).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            spec = importlib.util.spec_from_file_location("contract_probe", CONTRACT_PROBE)
            assert spec is not None and spec.loader is not None
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            base = f"http://127.0.0.1:{server.server_port}"
            totals = module.snapshot_backend_chat_requests(
                {
                    "backends": {
                        "old": {"url": base + "/old", "expect": "unchanged"},
                        "new": {"url": base + "/new", "expect": "increase"},
                    }
                }
            )
        finally:
            server.shutdown()
            thread.join(timeout=5)
            server.server_close()
        self.assertEqual(totals, {"old": 11.0, "new": 22.0})


if __name__ == "__main__":
    unittest.main()
