#!/usr/bin/env python3
"""Behavior tests for the public publication model probes."""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import threading
import unittest
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
PROBE_PATH = PACKAGE_ROOT / "scripts" / "publication-model-probes.py"
spec = importlib.util.spec_from_file_location("publication_model_probes", PROBE_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load publication model probes")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VisionErrorHandler(BaseHTTPRequestHandler):
    error_code = "unsupported_vision"
    request_body: dict[str, object] | None = None

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers["Content-Length"])
        type(self).request_body = json.loads(self.rfile.read(length))
        body = json.dumps(
            {"error": {"code": type(self).error_code, "message": "fixture"}}
        ).encode("utf-8")
        self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        return


class PublicationHandler(BaseHTTPRequestHandler):
    registry = (
        "deepseek-v4.1-flash",
        "glm-5.2",
        "glm-5.3-flash",
        "deepseek-v4-flash",
        "aws/openai-gpt-5.6-sol",
    )
    created_models: list[str] = []
    probed_models: list[str] = []
    deleted_keys: list[str] = []

    def send_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self) -> dict[str, object]:
        length = int(self.headers["Content-Length"])
        return json.loads(self.rfile.read(length))

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/model/info":
            rows = []
            for model in self.registry:
                model_info: dict[str, object] = {}
                if model == "deepseek-v4.1-flash":
                    model_info = {
                        "max_input_tokens": 1048576,
                        "max_output_tokens": 1048576,
                        "supports_vision": True,
                        "supports_function_calling": True,
                        "supports_reasoning": True,
                        "supports_response_schema": True,
                    }
                elif model == "glm-5.2":
                    model_info = {
                        "max_input_tokens": 320000,
                        "max_output_tokens": 320000,
                        "supports_vision": False,
                    }
                rows.append({"model_name": model, "model_info": model_info})
            self.send_json(200, {"data": rows})
            return
        if self.path == "/":
            self.send_json(403, {"error": "denied"})
            return
        if self.path == "/v1/models":
            self.send_json(401, {"error": "unauthorized"})
            return
        if self.path == "/key/info":
            self.send_json(403, {"error": "denied"})
            return
        self.send_json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        body = self.read_body()
        if self.path == "/key/generate":
            type(self).created_models = list(body["models"])
            self.send_json(200, {"key": "sk-publication-fixture"})
            return
        if self.path == "/key/delete":
            type(self).deleted_keys = list(body["keys"])
            self.send_json(200, {"deleted_keys": body["keys"]})
            return
        if self.path == "/v1/chat/completions":
            model = str(body["model"])
            type(self).probed_models.append(model)
            if model not in self.registry:
                self.send_json(404, {"error": {"code": "model_not_found"}})
                return
            content = body["messages"][0]["content"]
            if model == "glm-5.2" and isinstance(content, list):
                self.send_json(
                    400,
                    {"error": {"code": "unsupported_vision", "message": "fixture"}},
                )
                return
            self.send_json(
                200,
                {
                    "model": model,
                    "choices": [{"message": {"role": "assistant", "content": "OK"}}],
                },
            )
            return
        self.send_json(404, {"error": "not found"})

    def log_message(self, _format: str, *_args: object) -> None:
        return


class PublicationModelProbeTests(unittest.TestCase):
    def setUp(self) -> None:
        VisionErrorHandler.error_code = "unsupported_vision"
        VisionErrorHandler.request_body = None
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), VisionErrorHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def test_vision_probe_requires_the_guard_specific_error(self) -> None:
        VisionErrorHandler.error_code = "invalid_image"

        with self.assertRaisesRegex(RuntimeError, "unsupported_vision"):
            module.probe_legacy_vision_rejection(self.base, "fixture-key")

    def test_vision_probe_sends_a_valid_png_and_accepts_only_the_guard_error(self) -> None:
        status = module.probe_legacy_vision_rejection(self.base, "fixture-key")

        self.assertEqual(status, 400)
        request = VisionErrorHandler.request_body
        self.assertIsInstance(request, dict)
        content = request["messages"][0]["content"]
        encoded = content[1]["image_url"]["url"].split(",", 1)[1]
        png = base64.b64decode(encoded, validate=True)
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(png[12:16], b"IHDR")
        idat_offset = png.index(b"IDAT")
        idat_length = int.from_bytes(png[idat_offset - 4 : idat_offset], "big")
        pixels = zlib.decompress(png[idat_offset + 4 : idat_offset + 4 + idat_length])
        self.assertEqual(len(pixels), 560 * (1 + 560 * 3))
        self.assertIn(b"IEND", png)

    def test_run_probes_only_current_migration_critical_models(self) -> None:
        PublicationHandler.created_models = []
        PublicationHandler.probed_models = []
        PublicationHandler.deleted_keys = []
        server = ThreadingHTTPServer(("127.0.0.1", 0), PublicationHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        critical = [
            "deepseek-v4.1-flash",
            "glm-5.2",
            "glm-5.3-flash",
            "deepseek-v4-flash",
        ]
        environment = {
            "WEBSTER_PUBLICATION_MASTER_KEY": "fixture-master-key",
            "WEBSTER_PUBLICATION_PUBLIC_API": base,
            "WEBSTER_PUBLICATION_ADMIN_API": base,
            "WEBSTER_PUBLICATION_PRIVATE_API": base,
        }
        try:
            with patch.dict(os.environ, environment, clear=False):
                result = module.run("fixture-probe-id")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

        self.assertEqual(PublicationHandler.created_models, critical)
        self.assertEqual(PublicationHandler.probed_models[:-1], critical)
        self.assertEqual(PublicationHandler.probed_models[-1], "glm-5.2")
        self.assertNotIn("inkling-small-nvfp4", result)
        self.assertNotIn("aws/openai-gpt-5.6-sol", result)
        self.assertEqual(
            PublicationHandler.deleted_keys,
            ["sk-publication-fixture"],
        )
        self.assertEqual(result["revoked_key_status"], 401)


if __name__ == "__main__":
    unittest.main()
