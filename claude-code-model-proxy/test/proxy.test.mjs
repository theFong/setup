import assert from "node:assert/strict";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  anthropicToChatRequest,
  chatToAnthropicResponse,
  createClaudeCodeModelProxy,
  DEFAULT_WEBSTER_MODELS,
  loadWebsterProvider,
} from "../proxy.mjs";

const testDirectory = dirname(fileURLToPath(import.meta.url));

function listen(server) {
  return new Promise((resolveListen, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      const address = server.address();
      resolveListen(`http://127.0.0.1:${address.port}`);
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

function chatStream(response) {
  response.writeHead(200, { "content-type": "text/event-stream" });
  const events = [
    {
      id: "chatcmpl_test",
      choices: [{ index: 0, delta: { role: "assistant", content: "checking " }, finish_reason: null }],
    },
    {
      id: "chatcmpl_test",
      choices: [
        {
          index: 0,
          delta: {
            tool_calls: [
              {
                index: 0,
                id: "call_read",
                type: "function",
                function: { name: "Read", arguments: "{\"path\":" },
              },
            ],
          },
          finish_reason: null,
        },
      ],
    },
    {
      id: "chatcmpl_test",
      choices: [
        {
          index: 0,
          delta: { tool_calls: [{ index: 0, function: { arguments: "\"/tmp/a\"}" } }] },
          finish_reason: "tool_calls",
        },
      ],
    },
    {
      id: "chatcmpl_test",
      choices: [],
      usage: { prompt_tokens: 17, completion_tokens: 9 },
    },
  ];
  for (const event of events) response.write(`data: ${JSON.stringify(event)}\n\n`);
  response.end("data: [DONE]\n\n");
}

async function fixture(t) {
  const seen = { anthropic: [], webster: [] };
  const anthropicServer = createServer(async (request, response) => {
    const body = await readBody(request);
    seen.anthropic.push({ body, headers: request.headers, method: request.method, url: request.url });
    response.writeHead(200, { "content-type": "application/json" });
    response.end(
      JSON.stringify({
        id: "msg_anthropic",
        type: "message",
        role: "assistant",
        content: [{ type: "text", text: "from anthropic" }],
        model: "claude-sonnet-test",
        stop_reason: "end_turn",
        stop_sequence: null,
        usage: { input_tokens: 1, output_tokens: 2 },
      }),
    );
  });
  const websterServer = createServer(async (request, response) => {
    const body = await readBody(request);
    seen.webster.push({ body, headers: request.headers, method: request.method, url: request.url });
    const payload = JSON.parse(body);
    if (payload.stream) {
      chatStream(response);
      return;
    }
    response.writeHead(200, { "content-type": "application/json" });
    response.end(
      JSON.stringify({
        id: "chatcmpl_webster",
        model: payload.model,
        choices: [
          {
            index: 0,
            message: { role: "assistant", content: "from webster" },
            finish_reason: "stop",
          },
        ],
        usage: { prompt_tokens: 11, completion_tokens: 4 },
      }),
    );
  });

  const [anthropicBaseUrl, websterRootUrl] = await Promise.all([
    listen(anthropicServer),
    listen(websterServer),
  ]);
  const proxy = createClaudeCodeModelProxy({
    anthropicBaseUrl,
    port: 0,
    websterApiKey: "webster-secret",
    websterBaseUrl: `${websterRootUrl}/v1`,
  });
  const address = await proxy.start();
  const proxyBaseUrl = `http://127.0.0.1:${address.port}`;

  t.after(async () => {
    await proxy.stop();
    await Promise.all([close(anthropicServer), close(websterServer)]);
  });
  return { proxyBaseUrl, seen };
}

test("loads the installer-owned Webster config format", (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "claude-code-model-proxy-"));
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

test("discovers all Webster models without replacing Claude's built-ins", async (t) => {
  const { proxyBaseUrl } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/v1/models`);
  assert.equal(response.status, 200);
  const catalog = await response.json();
  assert.deepEqual(
    catalog.data.map((model) => model.id),
    DEFAULT_WEBSTER_MODELS.map((model) => model.id),
  );
  assert.ok(catalog.data.every((model) => model.id.startsWith("claude")));
  assert.ok(catalog.data.every((model) => model.display_name.endsWith("(Webster)")));
});

test("still requires a Claude credential for inference", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/v1/messages`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: "claude-webster-glm-5-2",
      max_tokens: 16,
      messages: [{ role: "user", content: "hello" }],
    }),
  });

  assert.equal(response.status, 401);
  assert.equal((await response.json()).error.type, "authentication_error");
  assert.equal(seen.anthropic.length, 0);
  assert.equal(seen.webster.length, 0);
});

test("passes normal Claude models and credentials through unchanged", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t);
  const payload = {
    model: "claude-sonnet-test",
    max_tokens: 64,
    messages: [{ role: "user", content: "hello" }],
  };
  const response = await fetch(`${proxyBaseUrl}/v1/messages?beta=true`, {
    method: "POST",
    headers: {
      authorization: "Bearer claude-login",
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  assert.equal(response.status, 200);
  assert.equal((await response.json()).content[0].text, "from anthropic");
  assert.equal(seen.anthropic.length, 1);
  assert.equal(seen.anthropic[0].url, "/v1/messages?beta=true");
  assert.equal(seen.anthropic[0].headers.authorization, "Bearer claude-login");
  assert.equal(seen.anthropic[0].headers["anthropic-version"], "2023-06-01");
  assert.deepEqual(JSON.parse(seen.anthropic[0].body), payload);
  assert.equal(seen.webster.length, 0);
});

test("translates Webster Messages requests and isolates credentials", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/v1/messages`, {
    method: "POST",
    headers: {
      authorization: "Bearer claude-login",
      "x-api-key": "claude-api-key",
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-webster-glm-5-2",
      max_tokens: 256,
      system: [{ type: "text", text: "You are a coding agent", cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: [{ type: "text", text: "read a file" }] }],
      tools: [
        {
          name: "Read",
          description: "Read a file",
          input_schema: {
            type: "object",
            properties: { path: { type: "string" } },
            required: ["path"],
          },
        },
      ],
      tool_choice: { type: "auto" },
      output_config: { effort: "high" },
    }),
  });

  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.type, "message");
  assert.equal(body.model, "claude-webster-glm-5-2");
  assert.equal(body.content[0].text, "from webster");
  assert.equal(body.usage.input_tokens, 11);
  assert.equal(seen.anthropic.length, 0);
  assert.equal(seen.webster.length, 1);
  assert.equal(seen.webster[0].url, "/v1/chat/completions");
  assert.equal(seen.webster[0].headers.authorization, "Bearer webster-secret");
  assert.equal(seen.webster[0].headers["x-api-key"], undefined);
  assert.equal(seen.webster[0].headers["anthropic-version"], undefined);
  const sent = JSON.parse(seen.webster[0].body);
  assert.equal(sent.model, "glm-5.2");
  assert.deepEqual(sent.messages.slice(0, 2), [
    { role: "system", content: "You are a coding agent" },
    { role: "user", content: "read a file" },
  ]);
  assert.equal(sent.tools[0].function.name, "Read");
  assert.equal(sent.reasoning_effort, "high");
});

test("translates tool history and tool responses in both directions", () => {
  const converted = anthropicToChatRequest(
    {
      messages: [
        {
          role: "assistant",
          content: [
            { type: "text", text: "I will read it" },
            { type: "tool_use", id: "toolu_1", name: "Read", input: { path: "/tmp/a" } },
          ],
        },
        {
          role: "user",
          content: [
            { type: "tool_result", tool_use_id: "toolu_1", content: "file body" },
            { type: "text", text: "continue" },
          ],
        },
      ],
      tools: [],
    },
    "glm-5.2",
  );
  assert.equal(converted.messages[0].tool_calls[0].function.arguments, '{"path":"/tmp/a"}');
  assert.deepEqual(converted.messages.slice(1), [
    { role: "tool", tool_call_id: "toolu_1", content: "file body" },
    { role: "user", content: "continue" },
  ]);

  const response = chatToAnthropicResponse(
    {
      id: "chat_1",
      choices: [
        {
          message: {
            content: null,
            tool_calls: [
              { id: "call_1", type: "function", function: { name: "Read", arguments: '{"path":"/tmp/a"}' } },
            ],
          },
          finish_reason: "tool_calls",
        },
      ],
      usage: { prompt_tokens: 3, completion_tokens: 5 },
    },
    "claude-webster-glm-5-2",
  );
  assert.deepEqual(response.content, [
    { type: "tool_use", id: "call_1", name: "Read", input: { path: "/tmp/a" } },
  ]);
  assert.equal(response.stop_reason, "tool_use");
});

test("translates streamed text, tool calls, finish reason, and usage", async (t) => {
  const { proxyBaseUrl } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/v1/messages`, {
    method: "POST",
    headers: { authorization: "Bearer claude-login", "content-type": "application/json" },
    body: JSON.stringify({
      model: "claude-webster-deepseek-v4-flash",
      max_tokens: 128,
      stream: true,
      messages: [{ role: "user", content: "use a tool" }],
      tools: [{ name: "Read", description: "Read", input_schema: { type: "object" } }],
    }),
  });
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /^text\/event-stream/);
  const body = await response.text();
  assert.match(body, /event: message_start/);
  assert.match(body, /"type":"text_delta","text":"checking "/);
  assert.match(body, /"type":"tool_use","id":"call_read","name":"Read"/);
  assert.match(body, /"type":"input_json_delta","partial_json":"\{\\"path\\":\\"\/tmp\/a\\"\}"/);
  assert.match(body, /"stop_reason":"tool_use"/);
  assert.match(body, /"output_tokens":9/);
  assert.match(body, /event: message_stop/);
});

test("rejects unsupported input and unknown routes", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t);
  const image = await fetch(`${proxyBaseUrl}/v1/messages`, {
    method: "POST",
    headers: { authorization: "Bearer claude-login", "content-type": "application/json" },
    body: JSON.stringify({
      model: "claude-webster-glm-5-2",
      messages: [{ role: "user", content: [{ type: "image", source: {} }] }],
    }),
  });
  const unknown = await fetch(`${proxyBaseUrl}/v1/complete`, {
    headers: { authorization: "Bearer claude-login" },
  });
  const hello = await fetch(`${proxyBaseUrl}/api/hello`, { method: "HEAD" });

  assert.equal(image.status, 400);
  assert.match((await image.json()).error.message, /text input only/);
  assert.equal(unknown.status, 404);
  assert.equal(hello.status, 200);
  assert.equal(seen.webster.length, 0);
});

test("settings writer preserves unrelated settings and is idempotent", (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "claude-settings-writer-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const inputPath = resolve(directory, "settings.json");
  const firstOutput = resolve(directory, "settings.first.json");
  const secondOutput = resolve(directory, "settings.second.json");
  writeFileSync(
    inputPath,
    JSON.stringify({ permissions: { defaultMode: "auto" }, env: { KEEP_ME: "yes" } }),
  );
  const script = resolve(testDirectory, "../write-claude-settings.mjs");
  const env = { ...process.env, CLAUDE_CODE_MODEL_PROXY_URL: "http://127.0.0.1:4816/" };
  const first = spawnSync(process.execPath, [script, inputPath, firstOutput], { env });
  assert.equal(first.status, 0, first.stderr.toString());
  const second = spawnSync(process.execPath, [script, firstOutput, secondOutput], { env });
  assert.equal(second.status, 0, second.stderr.toString());
  const settings = JSON.parse(readFileSync(firstOutput, "utf8"));
  assert.equal(settings.permissions.defaultMode, "auto");
  assert.equal(settings.env.KEEP_ME, "yes");
  assert.equal(settings.env.ANTHROPIC_BASE_URL, "http://127.0.0.1:4816");
  assert.equal(settings.env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY, "1");
  assert.equal(settings.env.ENABLE_TOOL_SEARCH, "true");
  assert.equal(readFileSync(firstOutput, "utf8"), readFileSync(secondOutput, "utf8"));
  assert.equal(statSync(firstOutput).mode & 0o777, 0o600);
});

test("settings writer refuses malformed settings without clobbering them", (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "claude-settings-invalid-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const inputPath = resolve(directory, "settings.json");
  const outputPath = resolve(directory, "settings.next.json");
  writeFileSync(inputPath, "not json\n");
  const script = resolve(testDirectory, "../write-claude-settings.mjs");
  const result = spawnSync(process.execPath, [script, inputPath, outputPath], {
    env: { ...process.env, CLAUDE_CODE_MODEL_PROXY_URL: "http://127.0.0.1:4816" },
  });
  assert.notEqual(result.status, 0);
  assert.equal(readFileSync(inputPath, "utf8"), "not json\n");
});

test("gateway cache writer seeds all models and is idempotent", (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "claude-gateway-cache-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const inputPath = resolve(directory, "gateway-models.json");
  const firstOutput = resolve(directory, "gateway-models.first.json");
  const secondOutput = resolve(directory, "gateway-models.second.json");
  const script = resolve(testDirectory, "../write-gateway-cache.mjs");
  const env = { ...process.env, CLAUDE_CODE_MODEL_PROXY_URL: "http://127.0.0.1:4816/" };
  const first = spawnSync(process.execPath, [script, inputPath, firstOutput], { env });
  assert.equal(first.status, 0, first.stderr.toString());
  const second = spawnSync(process.execPath, [script, firstOutput, secondOutput], { env });
  assert.equal(second.status, 0, second.stderr.toString());
  const cache = JSON.parse(readFileSync(firstOutput, "utf8"));
  assert.equal(cache.baseUrl, "http://127.0.0.1:4816");
  assert.deepEqual(
    cache.models.map((model) => model.id),
    DEFAULT_WEBSTER_MODELS.map((model) => model.id),
  );
  assert.ok(cache.models.every((model) => model.display_name.endsWith("(Webster)")));
  assert.equal(readFileSync(firstOutput, "utf8"), readFileSync(secondOutput, "utf8"));
  assert.equal(statSync(firstOutput).mode & 0o777, 0o600);
});

test("gateway cache writer refuses malformed cache without clobbering it", (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "claude-gateway-invalid-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const inputPath = resolve(directory, "gateway-models.json");
  const outputPath = resolve(directory, "gateway-models.next.json");
  writeFileSync(inputPath, "not json\n");
  const script = resolve(testDirectory, "../write-gateway-cache.mjs");
  const result = spawnSync(process.execPath, [script, inputPath, outputPath], {
    env: { ...process.env, CLAUDE_CODE_MODEL_PROXY_URL: "http://127.0.0.1:4816" },
  });
  assert.notEqual(result.status, 0);
  assert.equal(readFileSync(inputPath, "utf8"), "not json\n");
});
