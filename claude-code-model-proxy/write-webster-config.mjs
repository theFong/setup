#!/usr/bin/env node

import { chmodSync, mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const outputPath = resolve(process.argv[2] ?? "");
const apiKey = process.env.WEBSTER_API_KEY;
const baseUrl = process.env.WEBSTER_BASE_URL;
const anthropicApiKey = process.env.ANTHROPIC_API_KEY;
const anthropicMode =
  process.env.ANTHROPIC_CREDENTIAL_MODE ?? (anthropicApiKey ? "api-key" : "none");

if (!process.argv[2]) throw new Error("usage: write-webster-config.mjs OUTPUT_PATH");
if (!apiKey) throw new Error("WEBSTER_API_KEY must be set");
if (!baseUrl) throw new Error("WEBSTER_BASE_URL must be set");
if (!["none", "api-key", "claude-code-oauth"].includes(anthropicMode)) {
  throw new Error(`Unsupported ANTHROPIC_CREDENTIAL_MODE: ${anthropicMode}`);
}
if (anthropicMode === "api-key" && !anthropicApiKey) {
  throw new Error("ANTHROPIC_API_KEY must be set in api-key mode");
}

mkdirSync(dirname(outputPath), { recursive: true });
const temporaryPath = `${outputPath}.tmp-${process.pid}`;
const config = {
  baseUrl: baseUrl.replace(/\/+$/, ""),
  apiKey,
  ...(anthropicMode === "none"
    ? {}
    : {
        anthropic: {
          mode: anthropicMode,
          ...(anthropicMode === "api-key" ? { apiKey: anthropicApiKey } : {}),
        },
      }),
};
writeFileSync(temporaryPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
renameSync(temporaryPath, outputPath);
chmodSync(outputPath, 0o600);
