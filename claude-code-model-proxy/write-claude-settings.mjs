#!/usr/bin/env node

import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const inputPath = resolve(process.argv[2] ?? "");
const outputPath = resolve(process.argv[3] ?? "");
const proxyUrl = process.env.CLAUDE_CODE_MODEL_PROXY_URL;

if (!process.argv[2] || !process.argv[3]) {
  throw new Error("usage: write-claude-settings.mjs INPUT_PATH OUTPUT_PATH");
}
if (!proxyUrl) throw new Error("CLAUDE_CODE_MODEL_PROXY_URL must be set");

let settings = {};
try {
  settings = JSON.parse(readFileSync(inputPath, "utf8"));
} catch (error) {
  if (error.code !== "ENOENT") {
    throw new Error(`Unable to parse existing Claude settings: ${error.message}`);
  }
}
if (!settings || typeof settings !== "object" || Array.isArray(settings)) {
  throw new Error("Existing Claude settings must contain a JSON object");
}
if (settings.env !== undefined && (!settings.env || typeof settings.env !== "object" || Array.isArray(settings.env))) {
  throw new Error("Existing Claude settings env must contain a JSON object");
}

settings.env = {
  ...(settings.env ?? {}),
  ANTHROPIC_BASE_URL: proxyUrl.replace(/\/+$/, ""),
  CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY: "1",
  ENABLE_TOOL_SEARCH: "true",
};

mkdirSync(dirname(outputPath), { recursive: true });
const temporaryPath = `${outputPath}.tmp-${process.pid}`;
writeFileSync(temporaryPath, `${JSON.stringify(settings, null, 2)}\n`, { mode: 0o600 });
renameSync(temporaryPath, outputPath);
chmodSync(outputPath, 0o600);
