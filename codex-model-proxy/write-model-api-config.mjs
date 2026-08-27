#!/usr/bin/env node

import {
  chmodSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_TIMEOUT_MS = 20_000;

function nonEmptyString(value) {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
}

function positiveInteger(...values) {
  for (const value of values) {
    const parsed = typeof value === "string" && value.trim() !== "" ? Number(value) : value;
    if (Number.isSafeInteger(parsed) && parsed > 0) return parsed;
  }
  return undefined;
}

function humanizeModelId(id) {
  return id
    .split(/[-_]+/)
    .filter(Boolean)
    .map((part) => {
      if (/^(?:h\d+|v\d+|\d+(?:\.\d+)*)$/i.test(part)) return part.toUpperCase();
      if (/^(?:glm|gpt|qwen|llama|mistral|nemotron)$/i.test(part)) return part.toUpperCase();
      if (/^deepseek$/i.test(part)) return "DeepSeek";
      return `${part[0]?.toUpperCase() ?? ""}${part.slice(1)}`;
    })
    .join(" ");
}

function withoutProviderSuffix(value, providerName) {
  const suffix = ` (${providerName})`;
  return value.toLowerCase().endsWith(suffix.toLowerCase())
    ? value.slice(0, -suffix.length)
    : value;
}

export function normalizeModelApiModels(body, providerName = "Custom") {
  const advertised = Array.isArray(body?.data)
    ? body.data
    : Array.isArray(body?.models)
      ? body.models
      : [];
  const models = [];
  const seen = new Set();

  for (const advertisedModel of advertised) {
    const raw = typeof advertisedModel === "string" ? { id: advertisedModel } : advertisedModel;
    const id = nonEmptyString(raw?.id ?? raw?.slug ?? raw?.model);
    if (!id || seen.has(id)) continue;
    seen.add(id);

    const plainName = withoutProviderSuffix(
      nonEmptyString(raw?.display_name ?? raw?.displayName ?? raw?.name) ?? humanizeModelId(id),
      providerName,
    );
    const contextWindow = positiveInteger(
      raw?.max_input_tokens,
      raw?.context_window,
      raw?.contextWindow,
      raw?.context_length,
    );
    const maxOutputTokens = positiveInteger(raw?.max_output_tokens, raw?.maxOutputTokens);
    models.push({
      id,
      displayName: `${plainName} (${providerName})`,
      description:
        nonEmptyString(raw?.description) ?? `${plainName} served by the ${providerName} endpoint.`,
      ...(contextWindow ? { contextWindow } : {}),
      ...(maxOutputTokens ? { maxOutputTokens } : {}),
    });
  }

  models.sort((left, right) => left.id.localeCompare(right.id));
  if (models.length === 0) {
    throw new Error(`${providerName} endpoint did not advertise any accessible models`);
  }
  return models;
}

export async function discoverModelApiModels({
  apiKey,
  baseUrl,
  modelsFile,
  providerName = "Custom",
  timeoutMs,
} = {}) {
  if (modelsFile) {
    return normalizeModelApiModels(JSON.parse(readFileSync(modelsFile, "utf8")), providerName);
  }

  const response = await fetch(`${baseUrl.replace(/\/+$/, "")}/models`, {
    headers: { authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(timeoutMs ?? DEFAULT_TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error(`${providerName} model discovery failed with HTTP ${response.status}`);
  }
  return normalizeModelApiModels(await response.json(), providerName);
}

export async function expectedConfig({
  apiKey,
  baseUrl,
  modelsFile,
  providerName = "Custom",
  timeoutMs,
} = {}) {
  if (!apiKey) throw new Error("CODEX_MODEL_API_KEY must be set");
  if (!baseUrl) throw new Error("CODEX_MODEL_API_BASE_URL must be set");
  if (!nonEmptyString(providerName)) throw new Error("CODEX_MODEL_API_NAME must not be empty");
  const normalizedBaseUrl = baseUrl.replace(/\/+$/, "");
  return {
    name: providerName.trim(),
    baseUrl: normalizedBaseUrl,
    apiKey,
    models: await discoverModelApiModels({
      apiKey,
      baseUrl: normalizedBaseUrl,
      modelsFile,
      providerName: providerName.trim(),
      timeoutMs,
    }),
  };
}

function environment() {
  const usesGenericInputs =
    process.env.CODEX_MODEL_API_KEY !== undefined ||
    process.env.CODEX_MODEL_API_BASE_URL !== undefined ||
    process.env.CODEX_MODEL_API_NAME !== undefined;
  return {
    apiKey: process.env.CODEX_MODEL_API_KEY ?? process.env.WEBSTER_API_KEY,
    baseUrl: process.env.CODEX_MODEL_API_BASE_URL ?? process.env.WEBSTER_BASE_URL,
    modelsFile: process.env.CODEX_MODEL_API_MODELS_FILE ?? process.env.WEBSTER_MODELS_FILE,
    providerName: process.env.CODEX_MODEL_API_NAME ?? (usesGenericInputs ? "Custom" : "Webster"),
  };
}

export async function main(argv = process.argv.slice(2)) {
  const checkOnly = argv[0] === "--check";
  const outputArgument = checkOnly ? argv[1] : argv[0];
  if (!outputArgument || argv.length !== (checkOnly ? 2 : 1)) {
    throw new Error("usage: write-model-api-config.mjs [--check] OUTPUT_PATH");
  }

  const outputPath = resolve(outputArgument);
  const config = await expectedConfig(environment());

  if (checkOnly) {
    const installed = JSON.parse(readFileSync(outputPath, "utf8"));
    if (JSON.stringify(installed) !== JSON.stringify(config)) {
      throw new Error(
        `${outputPath} does not match the models currently advertised for this API key`,
      );
    }
    process.stdout.write(
      `${config.name} endpoint advertises the ${config.models.length} configured model(s)\n`,
    );
    return;
  }

  mkdirSync(dirname(outputPath), { recursive: true });
  const temporaryPath = `${outputPath}.tmp-${process.pid}`;
  writeFileSync(temporaryPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  renameSync(temporaryPath, outputPath);
  chmodSync(outputPath, 0o600);
}

// Backward-compatible exports for callers that imported the original names.
export const normalizeWebsterModels = (body) => normalizeModelApiModels(body, "Webster");
export const discoverWebsterModels = (options = {}) =>
  discoverModelApiModels({ ...options, providerName: "Webster" });

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`write-model-api-config: ${error.message}\n`);
    process.exitCode = 1;
  });
}
