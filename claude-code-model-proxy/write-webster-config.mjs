#!/usr/bin/env node

import { chmodSync, mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const outputPath = resolve(process.argv[2] ?? "");
const apiKey = process.env.WEBSTER_API_KEY;
const baseUrl = process.env.WEBSTER_BASE_URL;

if (!process.argv[2]) throw new Error("usage: write-webster-config.mjs OUTPUT_PATH");
if (!apiKey) throw new Error("WEBSTER_API_KEY must be set");
if (!baseUrl) throw new Error("WEBSTER_BASE_URL must be set");

mkdirSync(dirname(outputPath), { recursive: true });
const temporaryPath = `${outputPath}.tmp-${process.pid}`;
const config = { baseUrl: baseUrl.replace(/\/+$/, ""), apiKey };
writeFileSync(temporaryPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
renameSync(temporaryPath, outputPath);
chmodSync(outputPath, 0o600);
