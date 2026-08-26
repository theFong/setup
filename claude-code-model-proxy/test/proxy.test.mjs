import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  anthropicToChatRequest,
  chatToAnthropicResponse,
  createClaudeCodeModelProxy,
  DEFAULT_WEBSTER_MODELS,
  loadProxyConfig,
  loadWebsterProvider,
} from "../proxy.mjs";
import { createClaudeCodeOAuthProvider } from "../claude-code-oauth.mjs";
import { writeClaudeDesktopConfig } from "../write-claude-desktop-config.mjs";

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

async function fixture(
  t,
  { anthropicCredential, anthropicCredentialProvider, rejectOAuthOnce = false } = {},
) {
  const seen = { anthropic: [], webster: [] };
  let oauthRejected = false;
  const anthropicServer = createServer(async (request, response) => {
    const body = await readBody(request);
    seen.anthropic.push({ body, headers: request.headers, method: request.method, url: request.url });
    if (
      rejectOAuthOnce &&
      !oauthRejected &&
      request.method === "POST" &&
      request.headers.authorization === "Bearer oauth-stale"
    ) {
      oauthRejected = true;
      response.writeHead(401, { "content-type": "application/json" });
      response.end(JSON.stringify({ type: "error", error: { type: "authentication_error" } }));
      return;
    }
    response.writeHead(200, { "content-type": "application/json" });
    if (request.method === "GET" && request.url?.startsWith("/v1/models")) {
      response.end(
        JSON.stringify({
          data: [
            {
              id: "claude-opus-test",
              type: "model",
              display_name: "Claude Opus Test",
              created_at: "2026-08-21T00:00:00Z",
            },
            {
              id: "claude-sonnet-test",
              type: "model",
              display_name: "Claude Sonnet Test",
              created_at: "2026-08-21T00:00:00Z",
            },
          ],
          has_more: false,
        }),
      );
      return;
    }
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
    anthropicCredential,
    anthropicCredentialProvider,
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

test("loads API-key and Claude Code OAuth Anthropic config modes", (t) => {
  const directory = mkdtempSync(resolve(tmpdir(), "claude-code-model-proxy-auth-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const configPath = resolve(directory, "webster.json");
  writeFileSync(
    configPath,
    JSON.stringify({
      baseUrl: "https://webster.example/v1",
      apiKey: "webster-secret",
      anthropic: { mode: "api-key", apiKey: "anthropic-secret" },
    }),
  );
  assert.deepEqual(loadProxyConfig(configPath).anthropic, {
    mode: "api-key",
    apiKey: "anthropic-secret",
  });
  writeFileSync(
    configPath,
    JSON.stringify({
      baseUrl: "https://webster.example/v1",
      apiKey: "webster-secret",
      anthropic: { mode: "claude-code-oauth" },
    }),
  );
  assert.deepEqual(loadProxyConfig(configPath).anthropic, {
    mode: "claude-code-oauth",
  });
});

test("writes an idempotent private Claude Desktop Gateway profile", (t) => {
  const support = mkdtempSync(resolve(tmpdir(), "claude-desktop-config-"));
  t.after(() => rmSync(support, { recursive: true, force: true }));
  const library = join(support, "configLibrary");
  const profileId = "d7635c38-7e14-4626-a045-8afbcc66c2c2";
  const desktopPath = join(support, "claude_desktop_config.json");
  const metaPath = join(library, "_meta.json");
  const profilePath = join(library, `${profileId}.json`);
  mkdirSync(library, { recursive: true });
  writeFileSync(desktopPath, '{"enterpriseConfig":{"banner":"keep"}}\n');
  writeFileSync(
    metaPath,
    `${JSON.stringify({ appliedId: profileId, entries: [{ id: profileId, name: "Default" }] })}\n`,
  );
  writeFileSync(
    profilePath,
    `${JSON.stringify({
      inferenceProvider: "gateway",
      inferenceGatewayBaseUrl: "http://127.0.0.1:4816",
      customInferenceHeaders: { "x-tenant": "keep" },
    })}\n`,
  );

  const first = writeClaudeDesktopConfig(support, "http://127.0.0.1:4816/");
  assert.equal(first.changed, true);
  assert.equal(first.profileId, profileId);
  const desktop = JSON.parse(readFileSync(desktopPath, "utf8"));
  const meta = JSON.parse(readFileSync(metaPath, "utf8"));
  const profile = JSON.parse(readFileSync(profilePath, "utf8"));
  assert.equal(desktop.deploymentMode, "3p");
  assert.equal(desktop.enterpriseConfig.banner, "keep");
  assert.equal(meta.appliedId, profileId);
  assert.equal(profile.inferenceProvider, "gateway");
  assert.equal(profile.inferenceCredentialKind, "static");
  assert.equal(profile.inferenceGatewayBaseUrl, "http://127.0.0.1:4816");
  assert.equal(profile.inferenceGatewayApiKey, "claude-desktop-local");
  assert.equal(profile.inferenceGatewayAuthScheme, "bearer");
  assert.equal(profile.modelDiscoveryEnabled, true);
  assert.equal(profile.customInferenceHeaders["x-tenant"], "keep");
  for (const path of [desktopPath, metaPath, profilePath]) {
    assert.equal(statSync(path).mode & 0o777, 0o600);
    assert.ok(readFileSync(`${path}.bak-claude-desktop-setup`, "utf8").length > 0);
  }

  const snapshot = [desktopPath, metaPath, profilePath].map((path) => readFileSync(path, "utf8"));
  const second = writeClaudeDesktopConfig(support, "http://127.0.0.1:4816");
  assert.equal(second.changed, false);
  assert.deepEqual(
    [desktopPath, metaPath, profilePath].map((path) => readFileSync(path, "utf8")),
    snapshot,
  );
});

test("refuses malformed Claude Desktop config without clobbering it", (t) => {
  const support = mkdtempSync(resolve(tmpdir(), "claude-desktop-invalid-"));
  t.after(() => rmSync(support, { recursive: true, force: true }));
  const desktopPath = join(support, "claude_desktop_config.json");
  writeFileSync(desktopPath, "not json\n");
  assert.throws(
    () => writeClaudeDesktopConfig(support, "http://127.0.0.1:4816"),
    /Unable to parse/,
  );
  assert.equal(readFileSync(desktopPath, "utf8"), "not json\n");
  assert.throws(() => writeClaudeDesktopConfig(support, "not a url"), /Invalid URL/);
});

test("discovers all Webster models without replacing Claude's built-ins", async (t) => {
  const { proxyBaseUrl } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/v1/models`);
  assert.equal(response.status, 200);
  const catalog = await response.json();
  assert.deepEqual(
    catalog.data.map((model) => model.id),
    DEFAULT_WEBSTER_MODELS.map((model) => model.desktopId),
  );
  assert.ok(catalog.data.every((model) => model.id.startsWith("claude")));
  assert.ok(catalog.data.every((model) => !/(?:deepseek|glm)/i.test(model.id)));
  assert.ok(catalog.data.every((model) => model.display_name.endsWith("(Webster)")));
  assert.ok(catalog.data.every((model) => model.anthropic_family_tier === "sonnet"));
  assert.equal(catalog.data.filter((model) => model.is_family_default).length, 1);
  assert.deepEqual(
    catalog.data.map((model) => model.max_input_tokens),
    DEFAULT_WEBSTER_MODELS.map((model) => model.contextWindow),
  );
});

test("merges Anthropic models and injects a configured API key for Desktop", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t, {
    anthropicCredential: { mode: "api-key", apiKey: "anthropic-secret" },
  });
  const catalogResponse = await fetch(`${proxyBaseUrl}/v1/models`);
  assert.equal(catalogResponse.status, 200);
  const catalog = await catalogResponse.json();
  assert.deepEqual(catalog.data.slice(0, 2).map((model) => model.id), [
    "claude-opus-test",
    "claude-sonnet-test",
  ]);
  assert.deepEqual(
    catalog.data.slice(2).map((model) => model.id),
    DEFAULT_WEBSTER_MODELS.map((model) => model.desktopId),
  );
  assert.equal(seen.anthropic[0].headers["x-api-key"], "anthropic-secret");
  assert.equal(seen.anthropic[0].headers.authorization, undefined);

  const response = await fetch(`${proxyBaseUrl}/v1/messages`, {
    method: "POST",
    headers: {
      authorization: "Bearer claude-desktop-local",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-sonnet-test",
      max_tokens: 16,
      messages: [{ role: "user", content: "hello" }],
    }),
  });
  assert.equal(response.status, 200);
  const messageRequest = seen.anthropic.at(-1);
  assert.equal(messageRequest.headers["x-api-key"], "anthropic-secret");
  assert.equal(messageRequest.headers.authorization, undefined);
  assert.equal(messageRequest.headers["anthropic-version"], "2023-06-01");
});

test("merges Anthropic models and injects Claude Code OAuth only for Desktop", async (t) => {
  const credentialRequests = [];
  const { proxyBaseUrl, seen } = await fixture(t, {
    anthropicCredentialProvider: {
      async getCredential(options) {
        credentialRequests.push(options);
        return { kind: "oauth", secret: "oauth-secret", expiresAt: Date.now() + 60_000 };
      },
    },
  });
  const catalogResponse = await fetch(`${proxyBaseUrl}/v1/models`);
  assert.equal(catalogResponse.status, 200);
  const catalog = await catalogResponse.json();
  assert.ok(catalog.data.some((model) => model.id === "claude-opus-test"));
  assert.ok(catalog.data.some((model) => model.display_name.endsWith("(Webster)")));
  assert.equal(seen.anthropic[0].headers.authorization, "Bearer oauth-secret");
  assert.equal(seen.anthropic[0].headers["anthropic-beta"], "oauth-2025-04-20");

  const response = await fetch(`${proxyBaseUrl}/v1/messages`, {
    method: "POST",
    headers: {
      authorization: "Bearer claude-desktop-local",
      "anthropic-beta": "files-api-2025-04-14",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-opus-test",
      max_tokens: 16,
      messages: [{ role: "user", content: "hello" }],
    }),
  });
  assert.equal(response.status, 200);
  const messageRequest = seen.anthropic.at(-1);
  assert.equal(messageRequest.headers.authorization, "Bearer oauth-secret");
  assert.equal(messageRequest.headers["x-api-key"], undefined);
  assert.equal(
    messageRequest.headers["anthropic-beta"],
    "files-api-2025-04-14,oauth-2025-04-20",
  );
  assert.ok(credentialRequests.every((request) => request.forceRefresh === false));
});

test("refreshes injected OAuth once when Anthropic rejects it", async (t) => {
  const credentialRequests = [];
  const { proxyBaseUrl, seen } = await fixture(t, {
    rejectOAuthOnce: true,
    anthropicCredentialProvider: {
      async getCredential({ forceRefresh }) {
        credentialRequests.push(forceRefresh);
        return {
          kind: "oauth",
          secret: forceRefresh ? "oauth-fresh" : "oauth-stale",
          expiresAt: Date.now() + 60_000,
        };
      },
    },
  });
  const response = await fetch(`${proxyBaseUrl}/v1/messages`, {
    method: "POST",
    headers: {
      authorization: "Bearer claude-desktop-local",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-sonnet-test",
      max_tokens: 16,
      messages: [{ role: "user", content: "hello" }],
    }),
  });
  assert.equal(response.status, 200);
  assert.deepEqual(credentialRequests, [false, true]);
  assert.deepEqual(
    seen.anthropic.map((request) => request.headers.authorization),
    ["Bearer oauth-stale", "Bearer oauth-fresh"],
  );
});

test("refreshes and persists a rotated Claude Code OAuth credential", async () => {
  const clock = 1_000_000;
  let stored = {
    claudeAiOauth: {
      accessToken: "expired-access",
      refreshToken: "old-refresh",
      expiresAt: clock - 1,
      refreshTokenExpiresAt: clock + 86_400_000,
      scopes: ["user:inference"],
    },
    mcpOAuth: { keep: true },
  };
  let refreshCalls = 0;
  let writes = 0;
  const provider = createClaudeCodeOAuthProvider({
    now: () => clock,
    readCredential: async () => structuredClone(stored),
    writeCredential: async (next) => {
      writes += 1;
      stored = structuredClone(next);
    },
    fetchImpl: async (url, options) => {
      refreshCalls += 1;
      assert.equal(url, "https://platform.claude.com/v1/oauth/token");
      assert.equal(options.method, "POST");
      assert.equal(options.body.get("grant_type"), "refresh_token");
      assert.equal(options.body.get("refresh_token"), "old-refresh");
      assert.equal(options.body.get("client_id"), "9d1c250a-e61b-44d9-88ed-5944d1962f5e");
      return new Response(
        JSON.stringify({
          access_token: "fresh-access",
          refresh_token: "new-refresh",
          expires_in: 28_800,
          refresh_token_expires_in: 2_592_000,
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    },
  });

  const [first, second] = await Promise.all([
    provider.getCredential(),
    provider.getCredential(),
  ]);
  assert.equal(first.secret, "fresh-access");
  assert.equal(second.secret, "fresh-access");
  assert.equal(refreshCalls, 1);
  assert.equal(writes, 1);
  assert.equal(stored.claudeAiOauth.refreshToken, "new-refresh");
  assert.equal(stored.claudeAiOauth.expiresAt, clock + 28_800_000);
  assert.equal(stored.claudeAiOauth.refreshTokenExpiresAt, clock + 2_592_000_000);
  assert.deepEqual(stored.mcpOAuth, { keep: true });
});

test("still requires a Claude credential for inference", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/v1/messages`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: DEFAULT_WEBSTER_MODELS[0].desktopId,
      max_tokens: 16,
      messages: [{ role: "user", content: "hello" }],
    }),
  });

  assert.equal(response.status, 401);
  assert.equal((await response.json()).error.type, "authentication_error");
  assert.equal(seen.anthropic.length, 0);
  assert.equal(seen.webster.length, 0);
});

test("does not leak the Desktop sentinel to Anthropic without configured auth", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/v1/messages`, {
    method: "POST",
    headers: {
      authorization: "Bearer claude-desktop-local",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-sonnet-test",
      max_tokens: 16,
      messages: [{ role: "user", content: "hello" }],
    }),
  });
  assert.equal(response.status, 401);
  assert.match((await response.json()).error.message, /not configured/);
  assert.equal(seen.anthropic.length, 0);
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

test("translates desktop-safe Webster aliases and isolates credentials", async (t) => {
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
      model: DEFAULT_WEBSTER_MODELS[0].desktopId,
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
  assert.equal(body.model, DEFAULT_WEBSTER_MODELS[0].desktopId);
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

test("keeps legacy Claude Code model IDs routable", async (t) => {
  const { proxyBaseUrl, seen } = await fixture(t);
  const response = await fetch(`${proxyBaseUrl}/v1/messages`, {
    method: "POST",
    headers: {
      authorization: "Bearer claude-login",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: DEFAULT_WEBSTER_MODELS[0].id,
      max_tokens: 16,
      messages: [{ role: "user", content: "hello" }],
    }),
  });

  assert.equal(response.status, 200);
  assert.equal((await response.json()).model, DEFAULT_WEBSTER_MODELS[0].id);
  assert.equal(seen.anthropic.length, 0);
  assert.equal(seen.webster.length, 1);
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
