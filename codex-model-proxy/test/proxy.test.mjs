import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";

import { createCodexModelProxy, loadWebsterProvider } from "../proxy.mjs";

function listen(server) {
  return new Promise((resolveListen, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      const address = server.address();
      resolveListen(`http://127.0.0.1:${address.port}/v1`);
    });
  });
}

function close(server) {
  return new Promise((resolveClose, reject) => {
    server.close((error) => (error ? reject(error) : resolveClose()));
  });
}

function readBody(request) {
  return new Promise((resolveBody) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => resolveBody(Buffer.concat(chunks).toString("utf8")));
  });
}

function catalogModel() {
  return {
    slug: "gpt-test",
    display_name: "GPT Test",
    description: "Test model",
    default_reasoning_level: "medium",
    supported_reasoning_levels: [{ effort: "medium", description: "Balanced" }],
    shell_type: "shell_command",
    visibility: "list",
    supported_in_api: true,
    priority: 1,
    availability_nux: null,
    upgrade: null,
    model_messages: { instructions_template: "Test instructions" },
    support_verbosity: true,
    default_verbosity: "medium",
    apply_patch_tool_type: "freeform",
    truncation_policy: { mode: "tokens", limit: 10_000 },
    supports_parallel_tool_calls: true,
    experimental_supported_tools: [],
  };
}

async function fixture(t) {
  const seen = { chatGpt: [], openAi: [], webster: [] };

  const upstream = (bucket, models = false) =>
    createServer(async (request, response) => {
      const body = await readBody(request);
      seen[bucket].push({ body, headers: request.headers, method: request.method, url: request.url });
      if (models && request.url.startsWith("/v1/models")) {
        const payload = JSON.stringify({ models: [catalogModel()] });
        response.writeHead(200, { "content-type": "application/json" });
        response.end(payload);
        return;
      }
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(`data: ${JSON.stringify({ route: bucket })}\n\n`);
    });

  const chatGptServer = upstream("chatGpt", true);
  const openAiServer = upstream("openAi");
  const websterServer = upstream("webster");
  const [chatGptBaseUrl, openAiBaseUrl, websterBaseUrl] = await Promise.all([
    listen(chatGptServer),
    listen(openAiServer),
    listen(websterServer),
  ]);
  const proxy = createCodexModelProxy({
    chatGptBaseUrl,
    openAiBaseUrl,
    port: 0,
    websterApiKey: "webster-secret",
    websterBaseUrl,
  });
  const address = await proxy.start();
  const proxyBaseUrl = `http://127.0.0.1:${address.port}/v1`;

  t.after(async () => {
    await proxy.stop();
    await Promise.all([close(chatGptServer), close(openAiServer), close(websterServer)]);
  });
  return { proxyBaseUrl, seen };
}

test("loads the installer-owned Webster config format", (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "codex-model-proxy-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const configPath = resolve(directory, "webster.json");
  writeFileSync(
    configPath,
    JSON.stringify({ baseUrl: "https://webster.example/v1/", apiKey: "secret" }),
  );

  assert.deepEqual(loadWebsterProvider(configPath), {
    baseUrl: "https://webster.example/v1",
    apiKey: "secret",
  });
});

test("routes Webster models and replaces the incoming credential", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/responses`, {
    method: "POST",
    headers: {
      authorization: "Bearer chatgpt-secret",
      "chatgpt-account-id": "account-123",
      "content-type": "application/json",
    },
    body: JSON.stringify({ model: "glm-5.2", input: "hello", stream: true }),
  });

  assert.equal(response.status, 200);
  assert.match(await response.text(), /webster/);
  assert.equal(seen.webster.length, 1);
  assert.equal(seen.webster[0].headers.authorization, "Bearer webster-secret");
  assert.equal(seen.webster[0].headers["chatgpt-account-id"], undefined);
  assert.equal(seen.chatGpt.length, 0);
});

test("routes OpenAI models to the ChatGPT backend with the incoming login", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/responses`, {
    method: "POST",
    headers: {
      authorization: "Bearer chatgpt-secret",
      "chatgpt-account-id": "account-123",
      "content-type": "application/json",
    },
    body: JSON.stringify({ model: "gpt-test", input: "hello", stream: true }),
  });

  assert.equal(response.status, 200);
  assert.match(await response.text(), /chatGpt/);
  assert.equal(seen.chatGpt[0].headers.authorization, "Bearer chatgpt-secret");
  assert.equal(seen.chatGpt[0].headers["chatgpt-account-id"], "account-123");
  assert.equal(seen.webster.length, 0);
});

test("routes API-key requests without an account header to api.openai.com", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/responses`, {
    method: "POST",
    headers: {
      authorization: "Bearer api-key",
      "content-type": "application/json",
    },
    body: JSON.stringify({ model: "gpt-test", input: "hello", stream: true }),
  });

  assert.equal(response.status, 200);
  assert.match(await response.text(), /openAi/);
  assert.equal(seen.openAi[0].headers.authorization, "Bearer api-key");
  assert.equal(seen.chatGpt.length, 0);
});

test("merges Webster models into the Codex model catalog", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/models?client_version=0.148.0`, {
    headers: {
      authorization: "Bearer chatgpt-secret",
      "chatgpt-account-id": "account-123",
    },
  });

  assert.equal(response.status, 200);
  const body = await response.json();
  assert.deepEqual(
    body.models.map((model) => model.slug),
    [
      "gpt-test",
      "glm-5.2",
      "deepseek-v4-flash",
      "glm-5.2-h200",
      "deepseek-v4-flash-h100",
    ],
  );
  assert.equal(body.models[1].context_window, 320_000);
  assert.equal(body.models[1].visibility, "list");
  assert.equal(body.models[1].model_messages.instructions_template, "Test instructions");
  assert.equal(seen.chatGpt[0].url, "/v1/models?client_version=0.148.0");
});

test("rejects unauthenticated and unsupported requests", async (t) => {
  const { proxyBaseUrl } = await fixture(t);
  const missingAuth = await fetch(`${proxyBaseUrl}/responses`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "glm-5.2", input: "hello" }),
  });
  const unsupported = await fetch(`${proxyBaseUrl}/chat/completions`, {
    method: "POST",
    headers: { authorization: "Bearer test" },
  });

  assert.equal(missingAuth.status, 401);
  assert.equal(unsupported.status, 404);
});
