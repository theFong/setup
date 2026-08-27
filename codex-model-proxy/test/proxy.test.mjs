import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";

import { createCodexModelProxy, loadModelApiProvider } from "../proxy.mjs";
import {
  discoverModelApiModels,
  normalizeModelApiModels,
} from "../write-model-api-config.mjs";

const TEST_MODEL_API_MODELS = Object.freeze([
  {
    id: "future-model-7b",
    displayName: "Future Model 7B (Example)",
    description: "Future Model 7B served by Example.",
    contextWindow: 98_304,
    maxOutputTokens: 16_384,
  },
  {
    id: "key-scoped-model",
    displayName: "Key Scoped Model (Example)",
    description: "A model available to this test key.",
    contextWindow: 131_072,
  },
]);

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
    supports_reasoning_summaries: true,
    minimal_client_version: "0.100.0",
    available_in_plans: ["plus"],
    experimental_supported_tools: [],
  };
}

async function fixture(t, { modelApiModels = TEST_MODEL_API_MODELS } = {}) {
  const seen = { chatGpt: [], modelApi: [], openAi: [] };

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
  const modelApiServer = upstream("modelApi");
  const [chatGptBaseUrl, openAiBaseUrl, modelApiBaseUrl] = await Promise.all([
    listen(chatGptServer),
    listen(openAiServer),
    listen(modelApiServer),
  ]);
  const proxy = createCodexModelProxy({
    chatGptBaseUrl,
    openAiBaseUrl,
    port: 0,
    modelApiKey: "model-api-secret",
    modelApiBaseUrl,
    modelApiModels,
  });
  const address = await proxy.start();
  const proxyBaseUrl = `http://127.0.0.1:${address.port}/v1`;

  t.after(async () => {
    await proxy.stop();
    await Promise.all([close(chatGptServer), close(openAiServer), close(modelApiServer)]);
  });
  return { proxyBaseUrl, seen };
}

test("loads the installer-owned custom model API config format", (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "codex-model-proxy-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const configPath = resolve(directory, "upstream.json");
  writeFileSync(
    configPath,
    JSON.stringify({
      name: "Example",
      baseUrl: "https://models.example/v1/",
      apiKey: "secret",
      models: TEST_MODEL_API_MODELS,
    }),
  );

  assert.deepEqual(loadModelApiProvider(configPath), {
    name: "Example",
    baseUrl: "https://models.example/v1",
    apiKey: "secret",
    models: TEST_MODEL_API_MODELS,
  });
});

test("loads a legacy Webster config with its compatibility name", (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "codex-model-proxy-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const configPath = resolve(directory, "webster.json");
  writeFileSync(
    configPath,
    JSON.stringify({
      baseUrl: "https://webster.example/v1",
      apiKey: "secret",
      models: TEST_MODEL_API_MODELS,
    }),
  );

  assert.equal(loadModelApiProvider(configPath).name, "Webster");
});

test("rejects a model API config without discovered models", (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "codex-model-proxy-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const configPath = resolve(directory, "webster.json");
  writeFileSync(
    configPath,
    JSON.stringify({ baseUrl: "https://webster.example/v1", apiKey: "secret" }),
  );

  assert.throws(() => loadModelApiProvider(configPath), /no discovered models/);
});

test("discovers and normalizes only the models advertised for the supplied key", async (t) => {
  const discoveryServer = createServer((request, response) => {
    assert.equal(request.url, "/v1/models");
    assert.equal(request.headers.authorization, "Bearer scoped-secret");
    response.writeHead(200, { "content-type": "application/json" });
    response.end(
      JSON.stringify({
        data: [
          {
            id: "new-model-h300",
            max_input_tokens: 222_000,
            max_output_tokens: 12_000,
          },
        ],
      }),
    );
  });
  const baseUrl = await listen(discoveryServer);
  t.after(() => close(discoveryServer));

  assert.deepEqual(
    await discoverModelApiModels({
      apiKey: "scoped-secret",
      baseUrl,
      providerName: "Example",
    }),
    [
      {
        id: "new-model-h300",
        displayName: "New Model H300 (Example)",
        description: "New Model H300 served by the Example endpoint.",
        contextWindow: 222_000,
        maxOutputTokens: 12_000,
      },
    ],
  );
});

test("rejects a successful discovery response with no accessible models", () => {
  assert.throws(
    () => normalizeModelApiModels({ data: [] }, "Example"),
    /did not advertise any/,
  );
});

test("routes custom API models and replaces the incoming credential", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/responses`, {
    method: "POST",
    headers: {
      authorization: "Bearer chatgpt-secret",
      "chatgpt-account-id": "account-123",
      "content-type": "application/json",
    },
    body: JSON.stringify({ model: "future-model-7b", input: "hello", stream: true }),
  });

  assert.equal(response.status, 200);
  assert.match(await response.text(), /modelApi/);
  assert.equal(seen.modelApi.length, 1);
  assert.equal(seen.modelApi[0].headers.authorization, "Bearer model-api-secret");
  assert.equal(seen.modelApi[0].headers["chatgpt-account-id"], undefined);
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
  assert.equal(seen.modelApi.length, 0);
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

test("merges custom API models into the Codex model catalog", async (t) => {
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
    ["gpt-test", "future-model-7b", "key-scoped-model"],
  );
  assert.equal(body.models[1].context_window, 98_304);
  assert.equal(body.models[1].visibility, "list");
  assert.equal(body.models[1].model_messages.instructions_template, "Test instructions");
  assert.equal(body.models[1].supports_reasoning_summaries, true);
  for (const key of Object.keys(catalogModel())) {
    assert.equal(Object.hasOwn(body.models[1], key), true, `missing cloned catalog field ${key}`);
  }
  assert.equal(seen.chatGpt[0].url, "/v1/models?client_version=0.148.0");
});

test("rejects unauthenticated and unsupported requests", async (t) => {
  const { proxyBaseUrl } = await fixture(t);
  const missingAuth = await fetch(`${proxyBaseUrl}/responses`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "future-model-7b", input: "hello" }),
  });
  const unsupported = await fetch(`${proxyBaseUrl}/chat/completions`, {
    method: "POST",
    headers: { authorization: "Bearer test" },
  });

  assert.equal(missingAuth.status, 401);
  assert.equal(unsupported.status, 404);
});
