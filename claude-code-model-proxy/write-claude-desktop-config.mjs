#!/usr/bin/env node

import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { randomUUID } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const PROFILE_NAME = "Webster Gateway";
const LOCAL_GATEWAY_TOKEN = "claude-desktop-local";
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function readJson(path, fallback) {
  try {
    const value = JSON.parse(readFileSync(path, "utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw new Error("expected a JSON object");
    }
    return value;
  } catch (error) {
    if (error.code === "ENOENT") return fallback;
    throw new Error(`Unable to parse ${path}: ${error.message}`, { cause: error });
  }
}

function normalizedBaseUrl(value) {
  return typeof value === "string" ? value.replace(/\/+$/, "") : "";
}

function serialized(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function writeJsonAtomic(path, value) {
  const body = serialized(value);
  try {
    if (readFileSync(path, "utf8") === body) {
      chmodSync(path, 0o600);
      return false;
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  mkdirSync(dirname(path), { recursive: true });
  if (existsSync(path)) {
    const backupPath = `${path}.bak-claude-desktop-setup`;
    if (!existsSync(backupPath)) {
      copyFileSync(path, backupPath);
      chmodSync(backupPath, 0o600);
    }
  }
  const temporaryPath = `${path}.tmp-${process.pid}`;
  writeFileSync(temporaryPath, body, { mode: 0o600 });
  renameSync(temporaryPath, path);
  chmodSync(path, 0o600);
  return true;
}

export function writeClaudeDesktopConfig(supportDirectory, proxyUrl) {
  const supportDir = resolve(supportDirectory);
  const baseUrl = normalizedBaseUrl(new URL(proxyUrl).toString());
  const configLibrary = join(supportDir, "configLibrary");
  const metaPath = join(configLibrary, "_meta.json");
  const desktopConfigPath = join(supportDir, "claude_desktop_config.json");
  const meta = readJson(metaPath, { entries: [] });
  if (!Array.isArray(meta.entries)) {
    throw new Error(`${metaPath} entries must be an array`);
  }

  let entry = meta.entries.find((candidate) => candidate?.name === PROFILE_NAME);
  if (entry && !UUID_PATTERN.test(entry.id ?? "")) {
    throw new Error(`${metaPath} contains an invalid ${PROFILE_NAME} profile id`);
  }
  if (!entry) {
    for (const candidate of meta.entries) {
      if (!UUID_PATTERN.test(candidate?.id ?? "")) continue;
      const candidatePath = join(configLibrary, `${candidate.id}.json`);
      let profile;
      try {
        profile = readJson(candidatePath, {});
      } catch {
        continue;
      }
      if (
        profile.inferenceProvider === "gateway" &&
        normalizedBaseUrl(profile.inferenceGatewayBaseUrl) === baseUrl
      ) {
        entry = candidate;
        break;
      }
    }
  }
  if (!entry) entry = { id: randomUUID(), name: PROFILE_NAME };

  const profilePath = join(configLibrary, `${entry.id}.json`);
  const existingProfile = readJson(profilePath, {});
  const profile = {
    ...existingProfile,
    inferenceProvider: "gateway",
    inferenceCredentialKind: "static",
    inferenceGatewayBaseUrl: baseUrl,
    inferenceGatewayApiKey: LOCAL_GATEWAY_TOKEN,
    inferenceGatewayAuthScheme: "bearer",
    modelDiscoveryEnabled: true,
  };
  const entries = meta.entries.some((candidate) => candidate?.id === entry.id)
    ? meta.entries
    : [...meta.entries, entry];
  const nextMeta = { ...meta, appliedId: entry.id, entries };
  const desktopConfig = {
    ...readJson(desktopConfigPath, {}),
    deploymentMode: "3p",
  };

  const changed = [
    writeJsonAtomic(profilePath, profile),
    writeJsonAtomic(metaPath, nextMeta),
    writeJsonAtomic(desktopConfigPath, desktopConfig),
  ].some(Boolean);
  return { changed, profileId: entry.id };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (!process.argv[2] || !process.argv[3]) {
    throw new Error("usage: write-claude-desktop-config.mjs SUPPORT_DIRECTORY PROXY_URL");
  }
  process.stdout.write(`${JSON.stringify(writeClaudeDesktopConfig(process.argv[2], process.argv[3]))}\n`);
}
