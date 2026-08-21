#!/usr/bin/env node

import { chmodSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const codexDir = process.env.CODEX_MODEL_PROXY_CODEX_DIR ?? resolve(homedir(), ".codex");
const authPath = process.env.CODEX_AUTH_FILE ?? resolve(codexDir, "auth.json");
const catalogPath =
  process.env.CODEX_MODEL_CATALOG_FILE ?? resolve(codexDir, "openai-webster-models.json");
const proxyBaseUrl = (process.env.CODEX_MODEL_PROXY_URL ?? "http://127.0.0.1:4815/v1").replace(
  /\/+$/,
  "",
);

function nonEmptyString(value) {
  return typeof value === "string" && value.trim() !== "" ? value : undefined;
}

function authHeaders(auth) {
  const oauthToken = nonEmptyString(auth?.tokens?.access_token);
  const apiKey = nonEmptyString(auth?.OPENAI_API_KEY);
  const useApiKey = auth?.auth_mode === "apikey" && apiKey;
  const token = useApiKey ? apiKey : (oauthToken ?? apiKey);
  if (!token) {
    throw new Error(`No OpenAI credential found in ${authPath}; run 'codex login' first`);
  }

  const headers = { authorization: `Bearer ${token}` };
  const accountId = nonEmptyString(auth?.tokens?.account_id);
  if (!useApiKey && oauthToken && accountId) {
    headers["chatgpt-account-id"] = accountId;
  }
  return headers;
}

function clientVersion() {
  if (nonEmptyString(process.env.CODEX_CLIENT_VERSION)) {
    return process.env.CODEX_CLIENT_VERSION;
  }
  const candidates = ["codex"];
  if (process.platform === "darwin") {
    candidates.push("/Applications/ChatGPT.app/Contents/Resources/codex");
  }
  for (const candidate of candidates) {
    const result = spawnSync(candidate, ["--version"], { encoding: "utf8" });
    const match = result.stdout?.match(/\b(\d+\.\d+\.\d+(?:-[\w.]+)?)\b/);
    if (match) {
      return match[1];
    }
  }
  return "0.0.0";
}

const auth = JSON.parse(readFileSync(authPath, "utf8"));
const response = await fetch(
  `${proxyBaseUrl}/models?client_version=${encodeURIComponent(clientVersion())}`,
  { headers: authHeaders(auth) },
);

if (!response.ok) {
  throw new Error(`Proxy catalog request failed (${response.status}): ${await response.text()}`);
}

const catalog = await response.json();
if (!Array.isArray(catalog?.models) || catalog.models.length === 0) {
  throw new Error("Proxy returned an invalid or empty model catalog");
}

const temporaryPath = `${catalogPath}.tmp-${process.pid}`;
writeFileSync(temporaryPath, `${JSON.stringify(catalog, null, 2)}\n`, { mode: 0o600 });
renameSync(temporaryPath, catalogPath);
chmodSync(catalogPath, 0o600);

const visible = catalog.models.filter((model) => model.visibility === "list");
process.stdout.write(
  `Wrote ${catalog.models.length} models (${visible.length} visible) to ${catalogPath}\n`,
);
