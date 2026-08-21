#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 4815;
const DEFAULT_CODEX_DIR = resolve(homedir(), ".codex");
const DEFAULT_WEBSTER_CONFIG = resolve(DEFAULT_CODEX_DIR, "model-proxy/webster.json");
const DEFAULT_CHATGPT_BASE_URL = "https://chatgpt.com/backend-api/codex";
const DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1";
const DEFAULT_BODY_LIMIT_BYTES = 64 * 1024 * 1024;
const DEFAULT_REQUEST_TIMEOUT_MS = 5 * 60 * 1000;

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
  "keep-alive",
  "transfer-encoding",
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
  if (!Array.isArray(provider?.models) || provider.models.length === 0) {
    throw new Error(
      `Webster config at ${configPath} has no discovered models; re-run codex-setup.sh`,
    );
  }
  return {
    baseUrl: normalizeBaseUrl(
      requireNonEmptyString(provider?.baseUrl, "Webster config baseUrl"),
    ),
    apiKey: requireNonEmptyString(provider?.apiKey, "Webster config apiKey"),
    models: provider.models.map((model, index) => ({
      ...model,
      id: requireNonEmptyString(model?.id, `Webster config models[${index}].id`),
      displayName: requireNonEmptyString(
        model?.displayName,
        `Webster config models[${index}].displayName`,
      ),
      description: requireNonEmptyString(
        model?.description,
        `Webster config models[${index}].description`,
      ),
    })),
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

function hasChatGptAccount(request) {
  return typeof request.headers["chatgpt-account-id"] === "string";
}

function copyRequestHeaders(request, { websterApiKey, route }) {
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
      (lowerName === "authorization" || lowerName === "chatgpt-account-id")
    ) {
      continue;
    }
    headers[name] = value;
  }

  headers["accept-encoding"] = "identity";
  if (route === "webster") {
    headers.authorization = `Bearer ${websterApiKey}`;
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
    if (body) {
      upstreamRequest.end(body);
    } else {
      upstreamRequest.end();
    }
  });
}

function collectResponse(upstreamResponse, limitBytes = 16 * 1024 * 1024) {
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

function modelTemplate(catalog) {
  return (
    catalog.models.find((model) => model.slug === "gpt-5.6-terra") ??
    catalog.models.find((model) => model.visibility === "list") ??
    catalog.models[0]
  );
}

function websterCatalogEntry(definition, template, priority) {
  const entry = structuredClone(template);
  const contextWindow = definition.contextWindow ?? template.context_window;
  Object.assign(entry, {
    slug: definition.id,
    display_name: definition.displayName,
    description: definition.description,
    default_reasoning_level: "medium",
    supported_reasoning_levels: [
      { effort: "low", description: "Fast responses with lighter reasoning" },
      { effort: "medium", description: "Balanced reasoning depth" },
      { effort: "high", description: "Greater reasoning depth for complex tasks" },
    ],
    shell_type: "default",
    visibility: "list",
    supported_in_api: true,
    priority,
    additional_speed_tiers: [],
    service_tiers: [],
    default_service_tier: null,
    availability_nux: null,
    upgrade: null,
    include_skills_usage_instructions: false,
    include_plugin_usage_instructions: false,
    include_apps_usage_instructions: false,
    supports_reasoning_summaries:
      typeof template.supports_reasoning_summaries === "boolean"
        ? template.supports_reasoning_summaries
        : false,
    supports_reasoning_summary_parameter: true,
    default_reasoning_summary: "auto",
    support_verbosity: false,
    default_verbosity: null,
    apply_patch_tool_type: null,
    web_search_tool_type: "text",
    truncation_policy: { mode: "bytes", limit: 10_000 },
    supports_parallel_tool_calls: false,
    supports_image_detail_original: false,
    context_window: contextWindow,
    max_context_window: contextWindow,
    auto_compact_token_limit: null,
    comp_hash: null,
    effective_context_window_percent: 95,
    experimental_supported_tools: [],
    input_modalities: ["text"],
    supports_search_tool: false,
    use_responses_lite: false,
    auto_review_model_override: null,
    model_specialty: null,
    tool_mode: null,
    multi_agent_version: null,
    prefer_websockets: false,
  });
  return entry;
}

export function mergeWebsterModels(catalog, definitions) {
  if (!catalog || !Array.isArray(catalog.models) || catalog.models.length === 0) {
    throw new Error("OpenAI model catalog did not contain a non-empty models array");
  }
  if (!Array.isArray(definitions) || definitions.length === 0) {
    throw new Error("Webster config did not contain any discovered models");
  }

  const template = modelTemplate(catalog);
  const websterIds = new Set(definitions.map((model) => model.id));
  const models = catalog.models.filter((model) => !websterIds.has(model.slug));
  const highestPriority = models.reduce(
    (current, model) => Math.max(current, Number(model.priority) || 0),
    0,
  );

  definitions.forEach((definition, index) => {
    models.push(websterCatalogEntry(definition, template, highestPriority + index + 1));
  });
  return { ...catalog, models };
}

function upstreamBaseForOpenAi(request, options) {
  return hasChatGptAccount(request) ? options.chatGptBaseUrl : options.openAiBaseUrl;
}

function upstreamUrl(baseUrl, pathAndSearch) {
  return `${normalizeBaseUrl(baseUrl)}${pathAndSearch.replace(/^\/v1/, "")}`;
}

async function handleModels(request, response, options) {
  const baseUrl = upstreamBaseForOpenAi(request, options);
  const url = upstreamUrl(baseUrl, request.url);
  const upstreamResponse = await requestUpstream({
    headers: copyRequestHeaders(request, {
      route: "openai",
      websterApiKey: options.websterApiKey,
    }),
    method: "GET",
    timeoutMs: options.timeoutMs,
    url,
  });
  const body = await collectResponse(upstreamResponse);

  if (upstreamResponse.statusCode < 200 || upstreamResponse.statusCode >= 300) {
    response.writeHead(
      upstreamResponse.statusCode,
      copyResponseHeaders(upstreamResponse.headers),
    );
    response.end(body);
    return;
  }

  let catalog;
  try {
    catalog = mergeWebsterModels(JSON.parse(body.toString("utf8")), options.websterModels);
  } catch (error) {
    jsonResponse(response, 502, {
      error: { message: `Unable to merge the OpenAI model catalog: ${error.message}` },
    });
    return;
  }

  const payload = Buffer.from(JSON.stringify(catalog));
  response.writeHead(200, {
    "content-type": "application/json",
    "content-length": payload.length,
    "cache-control": "no-store",
  });
  response.end(payload);
}

async function handleResponses(request, response, options) {
  const body = await readBody(request, options.bodyLimitBytes);
  let payload;
  try {
    payload = JSON.parse(body.toString("utf8"));
  } catch {
    jsonResponse(response, 400, { error: { message: "Request body must be valid JSON" } });
    return;
  }

  const model = payload?.model;
  if (typeof model !== "string" || model === "") {
    jsonResponse(response, 400, { error: { message: "Request body must include model" } });
    return;
  }

  const isWebster = options.websterModelIds.has(model);
  const route = isWebster ? "webster" : "openai";
  const baseUrl = isWebster ? options.websterBaseUrl : upstreamBaseForOpenAi(request, options);
  const url = upstreamUrl(baseUrl, request.url);
  const upstreamResponse = await requestUpstream({
    body,
    headers: copyRequestHeaders(request, {
      route,
      websterApiKey: options.websterApiKey,
    }),
    method: "POST",
    timeoutMs: options.timeoutMs,
    url,
  });

  response.writeHead(upstreamResponse.statusCode, copyResponseHeaders(upstreamResponse.headers));
  upstreamResponse.pipe(response);
}

export function createCodexModelProxy({
  bodyLimitBytes = DEFAULT_BODY_LIMIT_BYTES,
  chatGptBaseUrl = DEFAULT_CHATGPT_BASE_URL,
  host = DEFAULT_HOST,
  openAiBaseUrl = DEFAULT_OPENAI_BASE_URL,
  port = DEFAULT_PORT,
  timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
  websterApiKey,
  websterBaseUrl,
  websterModels,
}) {
  requireNonEmptyString(websterApiKey, "websterApiKey");
  requireNonEmptyString(websterBaseUrl, "websterBaseUrl");
  if (!Array.isArray(websterModels) || websterModels.length === 0) {
    throw new Error("websterModels must contain at least one discovered model");
  }
  const options = {
    bodyLimitBytes,
    chatGptBaseUrl: normalizeBaseUrl(chatGptBaseUrl),
    openAiBaseUrl: normalizeBaseUrl(openAiBaseUrl),
    timeoutMs,
    websterApiKey,
    websterBaseUrl: normalizeBaseUrl(websterBaseUrl),
    websterModelIds: new Set(websterModels.map((model) => model.id)),
    websterModels,
  };

  const server = createServer(async (request, response) => {
    try {
      if (request.method === "GET" && request.url === "/healthz") {
        jsonResponse(response, 200, { status: "ok" });
        return;
      }

      if (typeof request.headers.authorization !== "string") {
        jsonResponse(response, 401, { error: { message: "Authorization header required" } });
        return;
      }

      const url = new URL(request.url, "http://localhost");
      if (request.method === "GET" && url.pathname === "/v1/models") {
        await handleModels(request, response, options);
        return;
      }
      if (
        request.method === "POST" &&
        (url.pathname === "/v1/responses" || url.pathname === "/v1/responses/compact")
      ) {
        await handleResponses(request, response, options);
        return;
      }

      jsonResponse(response, 404, { error: { message: "Route not found" } });
    } catch (error) {
      if (!response.headersSent) {
        jsonResponse(response, error.statusCode ?? 502, {
          error: { message: error.message },
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
  if (value === undefined) {
    return fallback;
  }
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  return parsed;
}

export async function main() {
  const configPath = process.env.WEBSTER_MODELS_CONFIG ?? DEFAULT_WEBSTER_CONFIG;
  const configProvider = loadWebsterProvider(configPath);
  const proxy = createCodexModelProxy({
    bodyLimitBytes: integerFromEnv("CODEX_MODEL_PROXY_BODY_LIMIT_BYTES", DEFAULT_BODY_LIMIT_BYTES),
    chatGptBaseUrl: process.env.CHATGPT_UPSTREAM_BASE_URL ?? DEFAULT_CHATGPT_BASE_URL,
    host: process.env.CODEX_MODEL_PROXY_HOST ?? DEFAULT_HOST,
    openAiBaseUrl: process.env.OPENAI_UPSTREAM_BASE_URL ?? DEFAULT_OPENAI_BASE_URL,
    port: integerFromEnv("CODEX_MODEL_PROXY_PORT", DEFAULT_PORT),
    timeoutMs: integerFromEnv("CODEX_MODEL_PROXY_TIMEOUT_MS", DEFAULT_REQUEST_TIMEOUT_MS),
    websterApiKey: process.env.WEBSTER_API_KEY ?? configProvider.apiKey,
    websterBaseUrl: process.env.WEBSTER_BASE_URL ?? configProvider.baseUrl,
    websterModels: configProvider.models,
  });
  const address = await proxy.start();
  process.stdout.write(
    `codex-model-proxy listening on http://${address.address}:${address.port}/v1\n`,
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
    process.stderr.write(`codex-model-proxy: ${error.message}\n`);
    process.exitCode = 1;
  });
}
