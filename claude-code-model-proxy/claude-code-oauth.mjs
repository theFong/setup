#!/usr/bin/env node

import { spawn } from "node:child_process";
import { userInfo } from "node:os";
import { pathToFileURL } from "node:url";

const KEYCHAIN_SERVICE = "Claude Code-credentials";
const OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const OAUTH_TOKEN_URL = "https://platform.claude.com/v1/oauth/token";
const DEFAULT_REFRESH_SKEW_MS = 5 * 60 * 1000;

function command(commandName, args, input) {
  return new Promise((resolveCommand, reject) => {
    const child = spawn(commandName, args, { stdio: ["pipe", "pipe", "pipe"] });
    const stdout = [];
    const stderr = [];
    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.once("error", reject);
    child.once("close", (code) => {
      if (code === 0) {
        resolveCommand(Buffer.concat(stdout).toString("utf8"));
        return;
      }
      reject(
        new Error(
          `${commandName} exited ${code}${stderr.length > 0 ? ": credential access failed" : ""}`,
        ),
      );
    });
    child.stdin.end(input);
  });
}

async function readMacKeychainCredential() {
  if (process.platform !== "darwin") {
    throw new Error("Claude Code OAuth reuse is supported only on macOS");
  }
  let value;
  try {
    value = JSON.parse(
      await command("security", ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"]),
    );
  } catch (error) {
    throw new Error("Unable to read the Claude Code OAuth credential from macOS Keychain", {
      cause: error,
    });
  }
  return value;
}

async function writeMacKeychainCredential(value) {
  if (process.platform !== "darwin") {
    throw new Error("Claude Code OAuth reuse is supported only on macOS");
  }
  try {
    // Keeping -w last makes security read the password from stdin instead of
    // exposing the credential in the process list.
    await command(
      "security",
      [
        "add-generic-password",
        "-U",
        "-a",
        userInfo().username,
        "-s",
        KEYCHAIN_SERVICE,
        "-w",
      ],
      `${JSON.stringify(value)}\n`,
    );
  } catch (error) {
    throw new Error("Unable to update the rotated Claude Code OAuth credential in Keychain", {
      cause: error,
    });
  }
}

function oauthRecord(container) {
  const oauth = container?.claudeAiOauth;
  if (!oauth || typeof oauth !== "object") {
    throw new Error("Claude Code Keychain credential has no claudeAiOauth record");
  }
  if (typeof oauth.accessToken !== "string" || oauth.accessToken === "") {
    throw new Error("Claude Code OAuth access token is missing");
  }
  return oauth;
}

function usableCredential(container) {
  const oauth = oauthRecord(container);
  return {
    kind: "oauth",
    secret: oauth.accessToken,
    expiresAt: Number.isFinite(oauth.expiresAt) ? oauth.expiresAt : 0,
  };
}

function positiveSeconds(value, label) {
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`Claude OAuth refresh response has invalid ${label}`);
  }
  return value;
}

export function createClaudeCodeOAuthProvider({
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
  readCredential = readMacKeychainCredential,
  refreshSkewMs = DEFAULT_REFRESH_SKEW_MS,
  writeCredential = writeMacKeychainCredential,
} = {}) {
  if (typeof fetchImpl !== "function") throw new Error("fetch is required for OAuth refresh");
  let refreshInFlight;

  const refresh = async (initialContainer) => {
    const initialOauth = oauthRecord(initialContainer);
    if (typeof initialOauth.refreshToken !== "string" || initialOauth.refreshToken === "") {
      throw new Error("Claude Code OAuth refresh token is missing; run `claude auth login`");
    }
    if (
      Number.isFinite(initialOauth.refreshTokenExpiresAt) &&
      initialOauth.refreshTokenExpiresAt <= now()
    ) {
      throw new Error("Claude Code OAuth refresh token has expired; run `claude auth login`");
    }

    const response = await fetchImpl(OAUTH_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "refresh_token",
        refresh_token: initialOauth.refreshToken,
        client_id: OAUTH_CLIENT_ID,
      }),
    });
    let payload;
    try {
      payload = await response.json();
    } catch {
      throw new Error(`Claude Code OAuth refresh returned invalid JSON (${response.status})`);
    }
    if (!response.ok) {
      throw new Error(
        `Claude Code OAuth refresh failed (${response.status}, ${payload?.error ?? "unknown error"})`,
      );
    }
    if (typeof payload.access_token !== "string" || payload.access_token === "") {
      throw new Error("Claude Code OAuth refresh response has no access_token");
    }

    // Refresh tokens rotate. Do not overwrite a credential another Claude Code
    // process refreshed while this request was in flight.
    const latestContainer = await readCredential();
    const latestOauth = oauthRecord(latestContainer);
    if (latestOauth.refreshToken !== initialOauth.refreshToken) {
      return usableCredential(latestContainer);
    }

    const refreshedAt = now();
    const nextOauth = {
      ...latestOauth,
      accessToken: payload.access_token,
      refreshToken: payload.refresh_token ?? latestOauth.refreshToken,
      expiresAt:
        refreshedAt + positiveSeconds(payload.expires_in, "expires_in") * 1000,
      ...(payload.refresh_token_expires_in === undefined
        ? {}
        : {
            refreshTokenExpiresAt:
              refreshedAt +
              positiveSeconds(
                payload.refresh_token_expires_in,
                "refresh_token_expires_in",
              ) *
                1000,
          }),
    };
    const nextContainer = { ...latestContainer, claudeAiOauth: nextOauth };
    await writeCredential(nextContainer);
    return usableCredential(nextContainer);
  };

  return {
    async getCredential({ forceRefresh = false } = {}) {
      const container = await readCredential();
      const current = usableCredential(container);
      if (!forceRefresh && current.expiresAt > now() + refreshSkewMs) return current;
      if (!refreshInFlight) {
        refreshInFlight = refresh(container).finally(() => {
          refreshInFlight = undefined;
        });
      }
      try {
        return await refreshInFlight;
      } catch (error) {
        if (!forceRefresh && current.expiresAt > now() + 30_000) return current;
        throw error;
      }
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  createClaudeCodeOAuthProvider()
    .getCredential()
    .then((credential) => {
      process.stdout.write(
        `${JSON.stringify({ kind: credential.kind, expiresAt: credential.expiresAt })}\n`,
      );
    })
    .catch((error) => {
      process.stderr.write(`claude-code-oauth: ${error.message}\n`);
      process.exitCode = 1;
    });
}
