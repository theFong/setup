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

export function normalizeWebsterModels(body) {
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

    const plainName =
      nonEmptyString(raw?.display_name ?? raw?.displayName ?? raw?.name) ?? humanizeModelId(id);
    const contextWindow = positiveInteger(
      raw?.max_input_tokens,
      raw?.context_window,
      raw?.contextWindow,
      raw?.context_length,
    );
    const maxOutputTokens = positiveInteger(raw?.max_output_tokens, raw?.maxOutputTokens);
    models.push({
      id,
      displayName: `${plainName.replace(/\s+\(Webster\)$/i, "")} (Webster)`,
      description:
        nonEmptyString(raw?.description) ??
        `${plainName.replace(/\s+\(Webster\)$/i, "")} served by the Brev Webster endpoint.`,
      ...(contextWindow ? { contextWindow } : {}),
      ...(maxOutputTokens ? { maxOutputTokens } : {}),
    });
  }

  models.sort((left, right) => left.id.localeCompare(right.id));
  if (models.length === 0) {
    throw new Error("Webster endpoint did not advertise any accessible models");
  }
  return models;
}

export async function discoverWebsterModels({ apiKey, baseUrl, modelsFile, timeoutMs } = {}) {
  if (modelsFile) {
    return normalizeWebsterModels(JSON.parse(readFileSync(modelsFile, "utf8")));
  }

  const response = await fetch(`${baseUrl.replace(/\/+$/, "")}/models`, {
    headers: { authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(timeoutMs ?? DEFAULT_TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error(`Webster model discovery failed with HTTP ${response.status}`);
  }
  return normalizeWebsterModels(await response.json());
}

export async function expectedConfig({ apiKey, baseUrl, modelsFile, timeoutMs } = {}) {
  if (!apiKey) throw new Error("WEBSTER_API_KEY must be set");
  if (!baseUrl) throw new Error("WEBSTER_BASE_URL must be set");
  const normalizedBaseUrl = baseUrl.replace(/\/+$/, "");
  return {
    baseUrl: normalizedBaseUrl,
    apiKey,
    models: await discoverWebsterModels({
      apiKey,
      baseUrl: normalizedBaseUrl,
      modelsFile,
      timeoutMs,
    }),
  };
}

export async function main(argv = process.argv.slice(2)) {
  const checkOnly = argv[0] === "--check";
  const outputArgument = checkOnly ? argv[1] : argv[0];
  if (!outputArgument || argv.length !== (checkOnly ? 2 : 1)) {
    throw new Error("usage: write-webster-config.mjs [--check] OUTPUT_PATH");
  }

  const outputPath = resolve(outputArgument);
  const config = await expectedConfig({
    apiKey: process.env.WEBSTER_API_KEY,
    baseUrl: process.env.WEBSTER_BASE_URL,
    modelsFile: process.env.WEBSTER_MODELS_FILE,
  });

  if (checkOnly) {
    const installed = JSON.parse(readFileSync(outputPath, "utf8"));
    if (JSON.stringify(installed) !== JSON.stringify(config)) {
      throw new Error(
        `${outputPath} does not match the models currently advertised for this Webster key`,
      );
    }
    process.stdout.write(
      `Webster endpoint advertises the ${config.models.length} configured model(s)\n`,
    );
    return;
  }

  mkdirSync(dirname(outputPath), { recursive: true });
  const temporaryPath = `${outputPath}.tmp-${process.pid}`;
  writeFileSync(temporaryPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  renameSync(temporaryPath, outputPath);
  chmodSync(outputPath, 0o600);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`write-webster-config: ${error.message}\n`);
    process.exitCode = 1;
  });
}
