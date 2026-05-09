import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const instanceId = `pi-${process.pid}`;
const extensionDir = dirname(fileURLToPath(import.meta.url));
const packageRoot = dirname(extensionDir);
const bubbleScript = join(packageRoot, "pet-bubble.sh");
const usageFile = join(packageRoot, "tmp", "pet-bubbles", instanceId, "usage.json");
const PROVIDER_ID = "openai-codex";
const CODEX_AUTH_PATH = join(homedir(), ".codex", "auth.json");
const LIVE_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
const USAGE_CACHE_TTL_MS = 60_000;
const USAGE_ERROR_CACHE_TTL_MS = 15_000;

type JsonRecord = Record<string, unknown>;

type UsageLimit = {
  label: string;
  remainingPercent: number;
  resetAtMs?: number;
  source: string;
};

type UsageSummary = {
  planType?: string;
  accountId?: string;
  accountLabel?: string;
  limits: UsageLimit[];
  fetchedAt: number;
};

type UsageCache = {
  token?: string;
  expiresAt: number;
  summary?: UsageSummary;
  promise?: Promise<UsageSummary>;
};

let usageCache: UsageCache = { expiresAt: 0 };

function bubbleEnv(projectCwd: string) {
  return {
    ...process.env,
    PI_PET_BUBBLE_ID: instanceId,
    PI_PET_BUBBLE_DIR: projectCwd,
    PI_PET_BUBBLE_PID: String(process.pid),
  };
}

function runBubble(projectCwd: string, args: string[]) {
  if (!existsSync(bubbleScript)) return;

  try {
    const child = spawn("bash", [bubbleScript, ...args], {
      cwd: packageRoot,
      detached: true,
      stdio: "ignore",
      env: bubbleEnv(projectCwd),
    });
    child.unref();
  } catch {
    // Bubble is cosmetic; never break pi because the overlay failed.
  }
}

function runBubbleSync(projectCwd: string, args: string[]) {
  if (!existsSync(bubbleScript)) return;

  try {
    spawnSync("bash", [bubbleScript, ...args], {
      cwd: packageRoot,
      stdio: "ignore",
      timeout: 2000,
      env: bubbleEnv(projectCwd),
    });
  } catch {
    // Bubble is cosmetic; never break pi because the overlay failed.
  }
}

function parseBubbleArgs(args: string): string[] {
  const trimmed = args.trim();
  if (!trimmed) return ["start"];

  const [command, ...rest] = trimmed.split(/\s+/);
  const text = trimmed.slice(command.length).trim();

  switch (command) {
    case "start":
    case "stop":
      return [command];
    case "thinking":
    case "answering":
    case "finished":
      return text ? [command, text] : [command];
    case "set": {
      const status = rest[0] ?? "finished";
      const restText = rest.length > 1 ? trimmed.slice(command.length + 1 + status.length).trim() : "";
      return restText ? ["set", status, restText] : ["set", status];
    }
    default:
      return ["set", command, text];
  }
}

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseNumber(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value.trim().replace(/%$/, ""));
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}

function clampPercent(value: number): number {
  return Math.max(0, Math.min(100, value));
}

function firstString(record: JsonRecord, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return undefined;
}

function firstNumber(record: JsonRecord, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = parseNumber(record[key]);
    if (value !== undefined) return value;
  }
  return undefined;
}

function firstTimestampMs(record: JsonRecord, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "number" && Number.isFinite(value) && value > 0) return value < 10_000_000_000 ? value * 1000 : value;
    if (typeof value === "string" && value.trim()) {
      const numeric = Number(value.trim());
      if (Number.isFinite(numeric) && numeric > 0) return numeric < 10_000_000_000 ? numeric * 1000 : numeric;
      const parsed = Date.parse(value);
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return undefined;
}

function durationMs(value: unknown, unitMs: number): number | undefined {
  const number = parseNumber(value);
  return number !== undefined && number >= 0 ? number * unitMs : undefined;
}

function extractAccessToken(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined;
  const direct = firstString(value, ["access_token", "accessToken", "access"]);
  if (direct) return direct;

  const tokens = value.tokens;
  if (isRecord(tokens)) {
    const token = firstString(tokens, ["access_token", "accessToken", "access"]);
    if (token) return token;
  }

  const providerCredential = value[PROVIDER_ID];
  if (providerCredential && providerCredential !== value) return extractAccessToken(providerCredential);
  return undefined;
}

function accountIdFromCredential(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined;
  const direct = firstString(value, ["accountId", "account_id"]);
  if (direct) return direct;
  const tokens = value.tokens;
  if (isRecord(tokens)) return firstString(tokens, ["accountId", "account_id"]);
  const providerCredential = value[PROVIDER_ID];
  if (providerCredential && providerCredential !== value) return accountIdFromCredential(providerCredential);
  return undefined;
}

async function readJsonObject(path: string): Promise<JsonRecord> {
  try {
    const parsed = JSON.parse(await readFile(path, "utf8")) as unknown;
    return isRecord(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function currentCodexCredential(ctx: ExtensionContext): unknown {
  try {
    const authStorage = (ctx.modelRegistry as any)?.authStorage;
    return typeof authStorage?.get === "function" ? authStorage.get(PROVIDER_ID) : undefined;
  } catch {
    return undefined;
  }
}

async function resolveCodexToken(ctx: ExtensionContext): Promise<{ token: string; accountId?: string } | undefined> {
  const credential = currentCodexCredential(ctx);
  const token = extractAccessToken(credential);
  const accountId = accountIdFromCredential(credential);
  if (token) return { token, accountId };

  const auth = await readJsonObject(CODEX_AUTH_PATH);
  const fallbackToken = extractAccessToken(auth);
  return fallbackToken ? { token: fallbackToken, accountId: accountIdFromCredential(auth) } : undefined;
}

function normalizeWindowLabel(text: string): string | undefined {
  const lower = text.trim().toLowerCase().replace(/[_-]+/g, " ");
  const hour = lower.match(/(\d+)\s*(?:h|hr|hrs|hour|hours)\b/);
  if (hour) return `${hour[1]}h`;
  const day = lower.match(/(\d+)\s*(?:d|day|days)\b/);
  if (day) return `${day[1]}d`;
  if (/\bweek(?:ly)?\b/.test(lower)) return "7d";
  return undefined;
}

function inferUsageLabel(key: string, raw: unknown): string {
  if (isRecord(raw)) {
    const text = firstString(raw, ["window", "window_size", "windowSize", "period", "duration", "label", "name", "title", "type"]);
    if (text) {
      const label = normalizeWindowLabel(text);
      if (label) return label;
    }
    const windowMinutes = firstNumber(raw, ["window_minutes", "windowMinutes", "window_mins", "windowMins"]);
    if (windowMinutes !== undefined && windowMinutes > 0) {
      if (windowMinutes % 1440 === 0) return `${windowMinutes / 1440}d`;
      if (windowMinutes % 60 === 0) return `${windowMinutes / 60}h`;
      return `${windowMinutes}m`;
    }
  }

  const normalized = key.toLowerCase();
  const label = normalizeWindowLabel(normalized);
  if (label) return label;
  if (normalized.includes("secondary") || normalized.includes("weekly")) return "7d";
  if (normalized.includes("primary")) return "5h";
  return key.replace(/[_-]+/g, " ");
}

function resetAtFromUsage(raw: unknown, now = Date.now()): number | undefined {
  if (!isRecord(raw)) return undefined;
  const explicit = firstTimestampMs(raw, ["reset_at", "resetAt", "resets_at", "resetsAt", "next_reset_at", "nextResetAt", "expires_at", "expiresAt"]);
  if (explicit !== undefined) return explicit;
  const seconds = durationMs(raw.reset_after_seconds ?? raw.resetAfterSeconds ?? raw.reset_in_seconds ?? raw.resetInSeconds ?? raw.seconds_until_reset ?? raw.secondsUntilReset, 1000);
  if (seconds !== undefined) return now + seconds;
  const minutes = durationMs(raw.reset_after_minutes ?? raw.resetAfterMinutes ?? raw.reset_in_minutes ?? raw.resetInMinutes, 60_000);
  return minutes !== undefined ? now + minutes : undefined;
}

function remainingPercentFromUsage(raw: unknown): number | undefined {
  if (typeof raw === "number" || typeof raw === "string") {
    const used = parseNumber(raw);
    return used === undefined ? undefined : clampPercent(100 - used);
  }
  if (!isRecord(raw)) return undefined;

  const explicitRemaining = firstNumber(raw, ["remaining_percent", "remainingPercentage", "percentage_remaining", "percent_remaining", "remaining_pct", "pct_remaining"]);
  if (explicitRemaining !== undefined) return clampPercent(explicitRemaining);

  const explicitUsed = firstNumber(raw, ["used_percent", "usedPercentage", "usage_percent", "usagePercentage", "percentage_used", "percent_used", "used_pct", "usage_pct"]);
  if (explicitUsed !== undefined) return clampPercent(100 - explicitUsed);

  const limit = firstNumber(raw, ["limit", "max", "quota", "total"]);
  if (limit !== undefined && limit > 0) {
    const remaining = firstNumber(raw, ["remaining", "available", "left"]);
    if (remaining !== undefined) return clampPercent((remaining / limit) * 100);
    const used = firstNumber(raw, ["used", "current", "consumed", "usage", "count"]);
    if (used !== undefined) return clampPercent(100 - (used / limit) * 100);
  }

  return undefined;
}

function pushUsageLimit(limits: UsageLimit[], key: string, raw: unknown): void {
  const remainingPercent = remainingPercentFromUsage(raw);
  if (remainingPercent === undefined) return;
  const label = inferUsageLabel(key, raw);
  if (limits.some((limit) => limit.label === label)) return;
  limits.push({ label, remainingPercent, resetAtMs: resetAtFromUsage(raw), source: key });
}

function normalizeUsagePayload(payload: unknown, accountId?: string): UsageSummary {
  const root = isRecord(payload) ? payload : {};
  const rateLimit = isRecord(root.rate_limit) ? root.rate_limit : isRecord(root.rate_limits) ? root.rate_limits : isRecord(root.rateLimit) ? root.rateLimit : root;
  const limits: UsageLimit[] = [];

  pushUsageLimit(limits, "primary", rateLimit.primary ?? rateLimit.primary_window ?? rateLimit.primaryWindow);
  pushUsageLimit(limits, "secondary", rateLimit.secondary ?? rateLimit.secondary_window ?? rateLimit.secondaryWindow);

  const additional = root.additional_rate_limits ?? root.additionalRateLimits ?? rateLimit.additional_rate_limits ?? rateLimit.additionalRateLimits;
  if (Array.isArray(additional)) {
    additional.forEach((limit, index) => pushUsageLimit(limits, `additional ${index + 1}`, limit));
  } else if (isRecord(additional)) {
    for (const [key, limit] of Object.entries(additional)) pushUsageLimit(limits, key, limit);
  }

  return {
    planType: firstString(root, ["plan_type", "planType", "plan"]),
    accountId,
    accountLabel: accountId ? `account …${accountId.slice(-8)}` : undefined,
    limits,
    fetchedAt: Date.now(),
  };
}

async function fetchUsageSummary(token: string, accountId?: string): Promise<UsageSummary> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 7000);
  try {
    const response = await fetch(LIVE_USAGE_URL, {
      method: "GET",
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`usage endpoint returned HTTP ${response.status}`);
    return normalizeUsagePayload(await response.json(), accountId);
  } finally {
    clearTimeout(timeout);
  }
}

async function writeUsageFile(summary: UsageSummary): Promise<void> {
  await mkdir(dirname(usageFile), { recursive: true, mode: 0o700 });
  const tmp = `${usageFile}.${process.pid}.${Date.now()}.tmp`;
  const payload = { seq: Date.now(), source: "live", ...summary };
  await writeFile(tmp, `${JSON.stringify(payload, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
  await rename(tmp, usageFile);
}

async function refreshUsage(ctx: ExtensionContext, options?: { refresh?: boolean }): Promise<void> {
  try {
    const resolved = await resolveCodexToken(ctx);
    if (!resolved) return;

    const now = Date.now();
    if (!options?.refresh && usageCache.token === resolved.token && usageCache.summary && usageCache.expiresAt > now) {
      await writeUsageFile(usageCache.summary);
      return;
    }
    if (!options?.refresh && usageCache.token === resolved.token && usageCache.promise) {
      await writeUsageFile(await usageCache.promise);
      return;
    }

    const promise = fetchUsageSummary(resolved.token, resolved.accountId);
    usageCache = { token: resolved.token, expiresAt: now + USAGE_CACHE_TTL_MS, promise };
    const summary = await promise;
    usageCache = { token: resolved.token, expiresAt: Date.now() + USAGE_CACHE_TTL_MS, summary };
    await writeUsageFile(summary);
  } catch {
    usageCache = { token: usageCache.token, expiresAt: Date.now() + USAGE_ERROR_CACHE_TTL_MS };
    // Usage rings are cosmetic; never break pi because usage failed.
  }
}

export default function (pi: ExtensionAPI) {
  let markedAnswering = false;

  pi.on("session_start", async (_event, ctx) => {
    runBubble(ctx.cwd, ["start", "finished", "Ready"]);
    void refreshUsage(ctx, { refresh: true });
  });

  pi.on("agent_start", async (_event, ctx) => {
    markedAnswering = false;
    runBubble(ctx.cwd, ["thinking", "Thinking..."]);
  });

  pi.on("message_update", async (event, ctx) => {
    if (markedAnswering) return;
    if (event.message.role !== "assistant") return;

    markedAnswering = true;
    runBubble(ctx.cwd, ["answering", "Answering..."]);
  });

  pi.on("agent_end", async (_event, ctx) => {
    markedAnswering = false;
    runBubble(ctx.cwd, ["finished", "Finished"]);
    void refreshUsage(ctx, { refresh: true });
  });

  pi.on("session_shutdown", async (event, ctx) => {
    if (event.reason === "reload") {
      runBubble(ctx.cwd, ["finished", "Reloading..."]);
    } else {
      // Synchronous on shutdown so the stop command is written before pi exits.
      runBubbleSync(ctx.cwd, ["stop"]);
    }
  });

  pi.registerCommand("bubble", {
    description: "Control this pi instance's Windows status bubble: start, stop, thinking, answering, finished, set <status> <text>",
    handler: async (args, ctx) => {
      runBubble(ctx.cwd, parseBubbleArgs(args));
      ctx.ui.notify("pet bubble command sent", "info");
    },
  });
}
