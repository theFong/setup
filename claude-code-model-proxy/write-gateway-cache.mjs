#!/usr/bin/env node

import {
  chmodSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";

import { DEFAULT_WEBSTER_MODELS } from "./proxy.mjs";

const inputPath = resolve(process.argv[2] ?? "");
const outputPath = resolve(process.argv[3] ?? "");
const proxyUrl = process.env.CLAUDE_CODE_MODEL_PROXY_URL;

if (!process.argv[2] || !process.argv[3]) {
  throw new Error("usage: write-gateway-cache.mjs INPUT_PATH OUTPUT_PATH");
}
if (!proxyUrl) throw new Error("CLAUDE_CODE_MODEL_PROXY_URL must be set");

let existing;
try {
  existing = JSON.parse(readFileSync(inputPath, "utf8"));
} catch (error) {
  if (error.code !== "ENOENT") {
    throw new Error(`Unable to parse existing gateway model cache: ${error.message}`);
  }
}

const baseUrl = proxyUrl.replace(/\/+$/, "");
const models = DEFAULT_WEBSTER_MODELS.map((model) => ({
  id: model.id,
  display_name: model.displayName,
}));
const sameCatalog =
  existing?.baseUrl === baseUrl &&
  JSON.stringify(existing?.models) === JSON.stringify(models);
const cache = {
  baseUrl,
  fetchedAt:
    sameCatalog && Number.isSafeInteger(existing?.fetchedAt)
      ? existing.fetchedAt
      : Date.now(),
  models,
};

mkdirSync(dirname(outputPath), { recursive: true });
const temporaryPath = `${outputPath}.tmp-${process.pid}`;
writeFileSync(temporaryPath, `${JSON.stringify(cache, null, 2)}\n`, { mode: 0o600 });
renameSync(temporaryPath, outputPath);
chmodSync(outputPath, 0o600);
