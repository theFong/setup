#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";

const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 4816;
const DEFAULT_CLAUDE_DIR = resolve(homedir(), ".claude");
const DEFAULT_WEBSTER_CONFIG = resolve(DEFAULT_CLAUDE_DIR, "model-proxy/webster.json");
const DEFAULT_ANTHROPIC_BASE_URL = "https://api.anthropic.com";
const DEFAULT_BODY_LIMIT_BYTES = 64 * 1024 * 1024;
const DEFAULT_REQUEST_TIMEOUT_MS = 10 * 60 * 1000;

const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "content-length",
  "host",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

const RESPONSE_HEADERS_TO_DROP = new Set([
  "connection",
  "content-length",
  "content-encoding",
  "keep-alive",
  "transfer-encoding",
]);

export const DEFAULT_WEBSTER_MODELS = Object.freeze([
  {
    id: "claude-webster-glm-5-2",
    desktopId: "claude-sonnet-4-5-webster",
    upstreamId: "glm-5.2",
    displayName: "GLM 5.2 (Webster)",
    contextWindow: 320_000,
  },
  {
    id: "claude-webster-deepseek-v4-flash",
    desktopId: "claude-sonnet-4-5-webster-flash",
    upstreamId: "deepseek-v4-flash",
    displayName: "DeepSeek V4 Flash (Webster)",
    contextWindow: 600_000,
  },
  {
    id: "claude-webster-glm-5-2-h200",
    desktopId: "claude-sonnet-4-5-webster-h200",
    upstreamId: "glm-5.2-h200",
    displayName: "GLM 5.2 H200 (Webster)",
    contextWindow: 131_072,
  },
  {
    id: "claude-webster-deepseek-v4-flash-h100",
    desktopId: "claude-sonnet-4-5-webster-flash-h100",
    upstreamId: "deepseek-v4-flash-h100",
    displayName: "DeepSeek V4 Flash H100 (Webster)",
    contextWindow: 262_144,
  },
]);

function normalizeBaseUrl(value) {
  return value.replace(/\/+$/, "");
}

function requireNonEmptyString(value, label) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${label} must be a non-empty string`);
  }
  return value;
}

export function loadWebsterProvider(configPath = DEFAULT_WEBSTER_CONFIG) {
  let config;
  try {
    config = JSON.parse(readFileSync(configPath, "utf8"));
  } catch (error) {
    throw new Error(`Unable to read Webster config at ${configPath}: ${error.message}`, {
      cause: error,
    });
  }

  const provider = config?.providers?.webster ?? config;
  return {
    baseUrl: normalizeBaseUrl(
      requireNonEmptyString(provider?.baseUrl, "Webster config baseUrl"),
    ),
    apiKey: requireNonEmptyString(provider?.apiKey, "Webster config apiKey"),
  };
}

function readBody(request, limitBytes) {
  return new Promise((resolveBody, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > limitBytes) {
        reject(Object.assign(new Error("request body too large"), { statusCode: 413 }));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolveBody(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}

function jsonResponse(response, statusCode, body) {
  const payload = Buffer.from(JSON.stringify(body));
  response.writeHead(statusCode, {
    "content-type": "application/json",
    "content-length": payload.length,
    "cache-control": "no-store",
  });
  response.end(payload);
}

function hasIncomingCredential(request) {
  return (
    typeof request.headers.authorization === "string" ||
    typeof request.headers["x-api-key"] === "string"
  );
}

function copyRequestHeaders(request, route, websterApiKey) {
  const headers = {};
  for (const [name, value] of Object.entries(request.headers)) {
    const lowerName = name.toLowerCase();
    if (
      value === undefined ||
      HOP_BY_HOP_HEADERS.has(lowerName) ||
      lowerName === "accept-encoding" ||
      lowerName === "cookie"
    ) {
      continue;
    }
    if (
      route === "webster" &&
      (lowerName === "authorization" ||
        lowerName === "x-api-key" ||
        lowerName.startsWith("anthropic-"))
    ) {
      continue;
    }
    headers[name] = value;
  }

  headers["accept-encoding"] = "identity";
  if (route === "webster") {
    headers.authorization = `Bearer ${websterApiKey}`;
    headers["content-type"] = "application/json";
  }
  return headers;
}

function copyResponseHeaders(headers) {
  const copied = {};
  for (const [name, value] of Object.entries(headers)) {
    if (value !== undefined && !RESPONSE_HEADERS_TO_DROP.has(name.toLowerCase())) {
      copied[name] = value;
    }
  }
  return copied;
}

function requestUpstream({ body, headers, method, timeoutMs, url }) {
  return new Promise((resolveRequest, reject) => {
    const upstreamUrl = new URL(url);
    const requestImpl = upstreamUrl.protocol === "http:" ? httpRequest : httpsRequest;
    const upstreamRequest = requestImpl(
      upstreamUrl,
      {
        method,
        headers: {
          ...headers,
          ...(body ? { "content-length": body.length } : {}),
        },
      },
      resolveRequest,
    );

    upstreamRequest.setTimeout(timeoutMs, () => {
      upstreamRequest.destroy(new Error("upstream request timed out"));
    });
    upstreamRequest.on("error", reject);
    upstreamRequest.end(body);
  });
}

function collectResponse(upstreamResponse, limitBytes = 64 * 1024 * 1024) {
  return new Promise((resolveBody, reject) => {
    const chunks = [];
    let size = 0;
    upstreamResponse.on("data", (chunk) => {
      size += chunk.length;
      if (size > limitBytes) {
        reject(new Error("upstream response body too large"));
        upstreamResponse.destroy();
        return;
      }
      chunks.push(chunk);
    });
    upstreamResponse.on("end", () => resolveBody(Buffer.concat(chunks)));
    upstreamResponse.on("error", reject);
  });
}

function anthropicError(message, statusCode = 400) {
  return Object.assign(new Error(message), { statusCode });
}

function blockText(content) {
  if (typeof content === "string") {
    return content;
  }
  if (!Array.isArray(content)) {
    return content == null ? "" : JSON.stringify(content);
  }
  return content
    .filter((block) => block?.type === "text")
    .map((block) => block.text ?? "")
    .join("\n");
}

function toolResultText(block) {
  const text = blockText(block.content);
  return block.is_error ? `[tool error]\n${text}` : text;
}

function pushUserContent(messages, content) {
  if (typeof content === "string") {
    messages.push({ role: "user", content });
    return;
  }
  if (!Array.isArray(content)) {
    messages.push({ role: "user", content: blockText(content) });
    return;
  }

  let pendingText = [];
  const flushText = () => {
    if (pendingText.length > 0) {
      messages.push({ role: "user", content: pendingText.join("\n") });
      pendingText = [];
    }
  };

  for (const block of content) {
    if (block?.type === "text") {
      pendingText.push(block.text ?? "");
      continue;
    }
    if (block?.type === "tool_result") {
      flushText();
      messages.push({
        role: "tool",
        tool_call_id: requireNonEmptyString(block.tool_use_id, "tool_result tool_use_id"),
        content: toolResultText(block),
      });
      continue;
    }
    if (block?.type === "image" || block?.type === "document") {
      throw anthropicError("Webster models currently support text input only");
    }
  }
  flushText();
}

function pushAssistantContent(messages, content) {
  if (typeof content === "string") {
    messages.push({ role: "assistant", content });
    return;
  }
  if (!Array.isArray(content)) {
    messages.push({ role: "assistant", content: blockText(content) });
    return;
  }

  const text = content
    .filter((block) => block?.type === "text")
    .map((block) => block.text ?? "")
    .join("\n");
  const toolCalls = content
    .filter((block) => block?.type === "tool_use")
    .map((block) => ({
      id: requireNonEmptyString(block.id, "tool_use id"),
      type: "function",
      function: {
        name: requireNonEmptyString(block.name, "tool_use name"),
        arguments: JSON.stringify(block.input ?? {}),
      },
    }));

  messages.push({
    role: "assistant",
    content: text || null,
    ...(toolCalls.length > 0 ? { tool_calls: toolCalls } : {}),
  });
}

function mapToolChoice(choice) {
  if (!choice || choice.type === "auto") return "auto";
  if (choice.type === "none") return "none";
  if (choice.type === "any") return "required";
  if (choice.type === "tool") {
    return { type: "function", function: { name: choice.name } };
  }
  return "auto";
}

export function anthropicToChatRequest(payload, upstreamModel) {
  if (!Array.isArray(payload.messages)) {
    throw anthropicError("Request body must include messages");
  }

  const messages = [];
  const system = blockText(payload.system);
  if (system) {
    messages.push({ role: "system", content: system });
  }
  for (const message of payload.messages) {
    if (message?.role === "user") {
      pushUserContent(messages, message.content);
    } else if (message?.role === "assistant") {
      pushAssistantContent(messages, message.content);
    }
  }

  const tools = Array.isArray(payload.tools)
    ? payload.tools
        .filter((tool) => typeof tool?.name === "string")
        .map((tool) => ({
          type: "function",
          function: {
            name: tool.name,
            description: tool.description ?? "",
            parameters: tool.input_schema ?? { type: "object", properties: {} },
          },
        }))
    : [];

  const effort = payload?.output_config?.effort ?? payload?.reasoning_effort;
  return {
    model: upstreamModel,
    messages,
    stream: payload.stream === true,
    ...(payload.stream === true ? { stream_options: { include_usage: true } } : {}),
    ...(Number.isFinite(payload.max_tokens) ? { max_tokens: payload.max_tokens } : {}),
    ...(Number.isFinite(payload.temperature) ? { temperature: payload.temperature } : {}),
    ...(Number.isFinite(payload.top_p) ? { top_p: payload.top_p } : {}),
    ...(Array.isArray(payload.stop_sequences) && payload.stop_sequences.length > 0
      ? { stop: payload.stop_sequences }
      : {}),
    ...(tools.length > 0 ? { tools, tool_choice: mapToolChoice(payload.tool_choice) } : {}),
    ...(payload?.tool_choice?.disable_parallel_tool_use === true
      ? { parallel_tool_calls: false }
      : {}),
    ...(["low", "medium", "high"].includes(effort) ? { reasoning_effort: effort } : {}),
  };
}

function parseToolInput(value) {
  try {
    const parsed = JSON.parse(value || "{}");
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function mapFinishReason(reason, hasTools = false) {
  if (hasTools || reason === "tool_calls" || reason === "function_call") return "tool_use";
  if (reason === "length") return "max_tokens";
  if (reason === "stop") return "end_turn";
  return reason ? "end_turn" : null;
}

function anthropicUsage(usage = {}) {
  return {
    input_tokens: usage.prompt_tokens ?? usage.input_tokens ?? 0,
    output_tokens: usage.completion_tokens ?? usage.output_tokens ?? 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: usage.prompt_tokens_details?.cached_tokens ?? 0,
  };
}

export function chatToAnthropicResponse(payload, requestedModel) {
  const choice = payload?.choices?.[0] ?? {};
  const message = choice.message ?? {};
  const content = [];
  if (typeof message.content === "string" && message.content !== "") {
    content.push({ type: "text", text: message.content });
  }
  const toolCalls = Array.isArray(message.tool_calls) ? message.tool_calls : [];
  for (const call of toolCalls) {
    if (call?.type !== "function" && !call?.function) continue;
    content.push({
      type: "tool_use",
      id: call.id ?? `toolu_${randomUUID().replaceAll("-", "")}`,
      name: call.function?.name ?? "unknown_tool",
      input: parseToolInput(call.function?.arguments),
    });
  }

  return {
    id: payload.id ?? `msg_${randomUUID().replaceAll("-", "")}`,
    type: "message",
    role: "assistant",
    content,
    model: requestedModel,
    stop_reason: mapFinishReason(choice.finish_reason, toolCalls.length > 0),
    stop_sequence: null,
    usage: anthropicUsage(payload.usage),
  };
}

function writeSse(response, type, data) {
  response.write(`event: ${type}\ndata: ${JSON.stringify(data)}\n\n`);
}

function dataFromSseEvent(event) {
  return event
    .split(/\r?\n/)
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trimStart())
    .join("\n");
}

async function pipeChatStreamAsAnthropic(upstreamResponse, response, requestedModel) {
  response.writeHead(200, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-cache, no-store",
    connection: "keep-alive",
    "x-accel-buffering": "no",
  });

  const messageId = `msg_${randomUUID().replaceAll("-", "")}`;
  writeSse(response, "message_start", {
    type: "message_start",
    message: {
      id: messageId,
      type: "message",
      role: "assistant",
      content: [],
      model: requestedModel,
      stop_reason: null,
      stop_sequence: null,
      usage: anthropicUsage(),
    },
  });

  let buffer = "";
  let textIndex = null;
  let nextIndex = 0;
  let finishReason = null;
  let usage = {};
  let finalized = false;
  const toolCalls = new Map();

  const ensureTextBlock = () => {
    if (textIndex !== null) return textIndex;
    textIndex = nextIndex++;
    writeSse(response, "content_block_start", {
      type: "content_block_start",
      index: textIndex,
      content_block: { type: "text", text: "" },
    });
    return textIndex;
  };

  const consumePayload = (chunk) => {
    if (chunk?.usage) usage = chunk.usage;
    const choice = chunk?.choices?.[0];
    if (!choice) return;
    if (choice.finish_reason) finishReason = choice.finish_reason;
    const delta = choice.delta ?? {};
    if (typeof delta.content === "string" && delta.content !== "") {
      const index = ensureTextBlock();
      writeSse(response, "content_block_delta", {
        type: "content_block_delta",
        index,
        delta: { type: "text_delta", text: delta.content },
      });
    }
    for (const toolDelta of delta.tool_calls ?? []) {
      const chatIndex = toolDelta.index ?? 0;
      const current = toolCalls.get(chatIndex) ?? { id: "", name: "", arguments: "" };
      if (toolDelta.id) current.id = toolDelta.id;
      if (toolDelta.function?.name) current.name += toolDelta.function.name;
      if (toolDelta.function?.arguments) current.arguments += toolDelta.function.arguments;
      toolCalls.set(chatIndex, current);
    }
  };

  const finalize = () => {
    if (finalized) return;
    finalized = true;
    if (textIndex !== null) {
      writeSse(response, "content_block_stop", {
        type: "content_block_stop",
        index: textIndex,
      });
    }
    for (const [, call] of [...toolCalls.entries()].sort(([a], [b]) => a - b)) {
      const index = nextIndex++;
      writeSse(response, "content_block_start", {
        type: "content_block_start",
        index,
        content_block: {
          type: "tool_use",
          id: call.id || `toolu_${randomUUID().replaceAll("-", "")}`,
          name: call.name || "unknown_tool",
          input: {},
        },
      });
      if (call.arguments) {
        writeSse(response, "content_block_delta", {
          type: "content_block_delta",
          index,
          delta: { type: "input_json_delta", partial_json: call.arguments },
        });
      }
      writeSse(response, "content_block_stop", {
        type: "content_block_stop",
        index,
      });
    }
    writeSse(response, "message_delta", {
      type: "message_delta",
      delta: {
        stop_reason: mapFinishReason(finishReason, toolCalls.size > 0) ?? "end_turn",
        stop_sequence: null,
      },
      usage: { output_tokens: anthropicUsage(usage).output_tokens },
    });
    writeSse(response, "message_stop", { type: "message_stop" });
    response.end();
  };

  for await (const chunk of upstreamResponse) {
    buffer += chunk.toString("utf8");
    let boundary;
    while ((boundary = buffer.search(/\r?\n\r?\n/)) >= 0) {
      const event = buffer.slice(0, boundary);
      const separator = buffer.slice(boundary).match(/^\r?\n\r?\n/)?.[0] ?? "\n\n";
      buffer = buffer.slice(boundary + separator.length);
      const data = dataFromSseEvent(event);
      if (!data) continue;
      if (data === "[DONE]") {
        finalize();
        continue;
      }
      try {
        consumePayload(JSON.parse(data));
      } catch {
        writeSse(response, "error", {
          type: "error",
          error: { type: "api_error", message: "Webster returned an invalid stream event" },
        });
      }
    }
  }
  finalize();
}

function modelCatalog(models) {
  const data = models.map((model, index) => ({
    id: model.desktopId ?? model.id,
    type: "model",
    display_name: model.displayName,
    created_at: "2026-08-20T00:00:00Z",
    anthropic_family_tier: "sonnet",
    is_family_default: index === 0,
    max_input_tokens: model.contextWindow,
  }));
  return {
    data,
    has_more: false,
    first_id: data[0]?.id ?? null,
    last_id: data.at(-1)?.id ?? null,
  };
}

async function handleWebsterMessage(request, response, options, payload, model) {
  const chatPayload = anthropicToChatRequest(payload, model.upstreamId);
  const body = Buffer.from(JSON.stringify(chatPayload));
  const upstreamResponse = await requestUpstream({
    body,
    headers: copyRequestHeaders(request, "webster", options.websterApiKey),
    method: "POST",
    timeoutMs: options.timeoutMs,
    url: `${options.websterBaseUrl}/chat/completions`,
  });

  if (upstreamResponse.statusCode < 200 || upstreamResponse.statusCode >= 300) {
    const errorBody = await collectResponse(upstreamResponse);
    response.writeHead(
      upstreamResponse.statusCode,
      copyResponseHeaders(upstreamResponse.headers),
    );
    response.end(errorBody);
    return;
  }

  if (payload.stream === true) {
    await pipeChatStreamAsAnthropic(upstreamResponse, response, payload.model);
    return;
  }

  const upstreamBody = await collectResponse(upstreamResponse);
  let chatResponse;
  try {
    chatResponse = JSON.parse(upstreamBody.toString("utf8"));
  } catch {
    throw new Error("Webster returned invalid JSON");
  }
  jsonResponse(response, 200, chatToAnthropicResponse(chatResponse, payload.model));
}

async function handleAnthropicMessage(request, response, options, body) {
  const url = new URL(request.url, "http://localhost");
  const upstreamResponse = await requestUpstream({
    body,
    headers: copyRequestHeaders(request, "anthropic", options.websterApiKey),
    method: "POST",
    timeoutMs: options.timeoutMs,
    url: `${options.anthropicBaseUrl}${url.pathname}${url.search}`,
  });
  response.writeHead(upstreamResponse.statusCode, copyResponseHeaders(upstreamResponse.headers));
  upstreamResponse.pipe(response);
}

export function createClaudeCodeModelProxy({
  anthropicBaseUrl = DEFAULT_ANTHROPIC_BASE_URL,
  bodyLimitBytes = DEFAULT_BODY_LIMIT_BYTES,
  host = DEFAULT_HOST,
  port = DEFAULT_PORT,
  timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
  websterApiKey,
  websterBaseUrl,
  websterModels = DEFAULT_WEBSTER_MODELS,
}) {
  requireNonEmptyString(websterApiKey, "websterApiKey");
  requireNonEmptyString(websterBaseUrl, "websterBaseUrl");
  const options = {
    anthropicBaseUrl: normalizeBaseUrl(anthropicBaseUrl),
    bodyLimitBytes,
    timeoutMs,
    websterApiKey,
    websterBaseUrl: normalizeBaseUrl(websterBaseUrl),
    websterModels,
    websterModelsById: new Map(
      websterModels.flatMap((model) => [
        [model.id, model],
        ...(model.desktopId ? [[model.desktopId, model]] : []),
      ]),
    ),
  };

  const server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url, "http://localhost");
      if (request.method === "GET" && url.pathname === "/healthz") {
        jsonResponse(response, 200, { status: "ok" });
        return;
      }
      if (request.method === "HEAD" && url.pathname === "/api/hello") {
        response.writeHead(200, { "cache-control": "no-store" });
        response.end();
        return;
      }
      // Claude.ai subscription auth is internal to Claude Code and is not
      // attached to gateway discovery requests. The proxy is bound to loopback
      // and this catalog contains only public model metadata, so serve it
      // before enforcing credentials on inference routes.
      if (request.method === "GET" && url.pathname === "/v1/models") {
        jsonResponse(response, 200, modelCatalog(options.websterModels));
        return;
      }
      if (!hasIncomingCredential(request)) {
        jsonResponse(response, 401, {
          type: "error",
          error: { type: "authentication_error", message: "Claude credential required" },
        });
        return;
      }
      if (request.method === "POST" && url.pathname === "/v1/messages") {
        const body = await readBody(request, options.bodyLimitBytes);
        let payload;
        try {
          payload = JSON.parse(body.toString("utf8"));
        } catch {
          throw anthropicError("Request body must be valid JSON");
        }
        const model = options.websterModelsById.get(payload?.model);
        if (model) {
          await handleWebsterMessage(request, response, options, payload, model);
        } else {
          await handleAnthropicMessage(request, response, options, body);
        }
        return;
      }
      jsonResponse(response, 404, {
        type: "error",
        error: { type: "not_found_error", message: "Route not found" },
      });
    } catch (error) {
      if (!response.headersSent) {
        jsonResponse(response, error.statusCode ?? 502, {
          type: "error",
          error: { type: "api_error", message: error.message },
        });
      } else {
        response.destroy(error);
      }
    }
  });

  return {
    host,
    port,
    server,
    start() {
      return new Promise((resolveStart, reject) => {
        server.once("error", reject);
        server.listen(port, host, () => {
          server.off("error", reject);
          resolveStart(server.address());
        });
      });
    },
    stop() {
      return new Promise((resolveStop, reject) => {
        server.close((error) => (error ? reject(error) : resolveStop()));
      });
    },
  };
}

function integerFromEnv(name, fallback) {
  const value = process.env[name];
  if (value === undefined) return fallback;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  return parsed;
}

export async function main() {
  const configPath = process.env.WEBSTER_MODELS_CONFIG ?? DEFAULT_WEBSTER_CONFIG;
  const configProvider = loadWebsterProvider(configPath);
  const proxy = createClaudeCodeModelProxy({
    anthropicBaseUrl:
      process.env.ANTHROPIC_UPSTREAM_BASE_URL ?? DEFAULT_ANTHROPIC_BASE_URL,
    bodyLimitBytes: integerFromEnv(
      "CLAUDE_CODE_MODEL_PROXY_BODY_LIMIT_BYTES",
      DEFAULT_BODY_LIMIT_BYTES,
    ),
    host: process.env.CLAUDE_CODE_MODEL_PROXY_HOST ?? DEFAULT_HOST,
    port: integerFromEnv("CLAUDE_CODE_MODEL_PROXY_PORT", DEFAULT_PORT),
    timeoutMs: integerFromEnv(
      "CLAUDE_CODE_MODEL_PROXY_TIMEOUT_MS",
      DEFAULT_REQUEST_TIMEOUT_MS,
    ),
    websterApiKey: process.env.WEBSTER_API_KEY ?? configProvider.apiKey,
    websterBaseUrl: process.env.WEBSTER_BASE_URL ?? configProvider.baseUrl,
  });
  const address = await proxy.start();
  process.stdout.write(
    `claude-code-model-proxy listening on http://${address.address}:${address.port}\n`,
  );

  const shutdown = async () => {
    await proxy.stop();
    process.exit(0);
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`claude-code-model-proxy: ${error.message}\n`);
    process.exitCode = 1;
  });
}
