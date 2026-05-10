import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const instanceId = `pi-${process.pid}`;
const extensionDir = dirname(fileURLToPath(import.meta.url));
const packageRoot = dirname(extensionDir);
const bubbleScript = join(packageRoot, "pet-bubble.sh");
const petInstallScript = join(packageRoot, "pet-install.sh");
const petsDir = join(packageRoot, "pets");
const activePetFile = join(petsDir, "active");
const usageFile = join(packageRoot, "tmp", "pet-bubbles", instanceId, "usage.json");
const PROVIDER_ID = "openai-codex";
const CODEX_AUTH_PATH = join(homedir(), ".codex", "auth.json");
const LIVE_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
const PETDEX_MANIFEST_URL = "https://petdex.crafter.run/api/manifest";
const PETDEX_SEARCH_URL = "https://petdex.crafter.run/api/pets/search";
const CODEX_PETS_BASE = "https://codex-pets.net";
const CODEX_PETS_SEARCH_URL = `${CODEX_PETS_BASE}/api/pets`;
const USAGE_CACHE_TTL_MS = 60_000;
const USAGE_ERROR_CACHE_TTL_MS = 15_000;
const PETDEX_SEARCH_CACHE_TTL_MS = 10 * 60_000;

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

function isCodexModel(ctx: ExtensionContext, modelOverride?: unknown): boolean {
  const model = modelOverride ?? (ctx as any)?.model;
  return isRecord(model) && model.provider === PROVIDER_ID;
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

async function writeUsagePayload(payload: JsonRecord): Promise<void> {
  await mkdir(dirname(usageFile), { recursive: true, mode: 0o700 });
  const tmp = `${usageFile}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(tmp, `${JSON.stringify(payload, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
  await rename(tmp, usageFile);
}

async function writeUsageFile(summary: UsageSummary): Promise<void> {
  await writeUsagePayload({ seq: Date.now(), source: "live", ...summary });
}

async function hideUsageRings(reason: string): Promise<void> {
  const now = Date.now();
  await writeUsagePayload({ seq: now, source: "disabled", disabled: true, reason, limits: [], fetchedAt: now });
}

async function refreshUsage(ctx: ExtensionContext, options?: { refresh?: boolean; model?: unknown }): Promise<void> {
  try {
    if (!isCodexModel(ctx, options?.model)) {
      usageCache = { expiresAt: 0 };
      await hideUsageRings("non-codex-model");
      return;
    }

    const resolved = await resolveCodexToken(ctx);
    if (!resolved) {
      usageCache = { expiresAt: Date.now() + USAGE_ERROR_CACHE_TTL_MS };
      await hideUsageRings("no-codex-token");
      return;
    }

    const now = Date.now();
    if (!options?.refresh && usageCache.token === resolved.token && usageCache.summary && usageCache.expiresAt > now) {
      await writeUsageFile(usageCache.summary);
      return;
    }
    if (!options?.refresh && usageCache.token === resolved.token && usageCache.promise) {
      const summary = await usageCache.promise;
      if (summary.limits.length === 0) await hideUsageRings("no-usage-limits");
      else await writeUsageFile(summary);
      return;
    }

    const promise = fetchUsageSummary(resolved.token, resolved.accountId);
    usageCache = { token: resolved.token, expiresAt: now + USAGE_CACHE_TTL_MS, promise };
    const summary = await promise;
    if (summary.limits.length === 0) {
      usageCache = { token: resolved.token, expiresAt: Date.now() + USAGE_ERROR_CACHE_TTL_MS };
      await hideUsageRings("no-usage-limits");
      return;
    }

    usageCache = { token: resolved.token, expiresAt: Date.now() + USAGE_CACHE_TTL_MS, summary };
    await writeUsageFile(summary);
  } catch {
    usageCache = { token: usageCache.token, expiresAt: Date.now() + USAGE_ERROR_CACHE_TTL_MS };
    try { await hideUsageRings("usage-refresh-failed"); } catch {}
    // Usage rings are cosmetic; never break pi because usage failed.
  }
}

type ProcessResult = {
  code: number | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
};

type InstalledPet = {
  slug: string;
  displayName: string;
  active: boolean;
};

type PetdexPet = {
  slug: string;
  displayName?: string;
  kind?: string;
  description?: string;
  vibes?: string[];
  colors?: string[];
  submittedBy?: string;
  zipUrl?: string;
  source?: "Petdex" | "Codex Pets";
  installTarget?: string;
};

type PetdexSearchCache = {
  expiresAt: number;
  pets?: PetdexPet[];
  promise?: Promise<PetdexPet[]>;
};

let petdexSearchCache: PetdexSearchCache = { expiresAt: 0 };

type CompletionItem = {
  value: string;
  label: string;
  description?: string;
};

const PET_SLUG_RE = /^[A-Za-z0-9._-]+$/;

const PET_GUIDE = [
  "Pi-pet agent guide: search, install, and switch desktop pets",
  "",
  "For agent-driven pet changes, use the pi_pet tool. Do not write /pet commands in bash or in assistant text expecting them to auto-run.",
  "The /pet slash command namespace is for the user/editor; the pi_pet tool is for the model. Pet sources are Petdex and Codex Pets.",
  "",
  "pi_pet tool actions:",
  "- action: list",
  "  Lists installed pets first. If the requested pet is already installed, prefer action: use.",
  "- action: use, target: <installed-slug>",
  "  Switches to an already installed pet.",
  "- action: search, target: <query>",
  "  Searches both Petdex and Codex Pets by name, character, vibe, tags, or description. Results include source and an install target/URL.",
  "- action: install, target: <petdex-slug-or-codex-pets-url>",
  "  Installs a pet and makes it active. Bare names/slugs use Petdex by default, e.g. luffy.",
  "  For Codex Pets, pass the codex-pets.net URL returned by search, e.g. https://codex-pets.net/#/pets/dario.",
  "- action: current",
  "  Shows the active pet.",
  "",
  "Examples:",
  "- User: switch to boba → first list; if boba is installed use {action: 'use', target: 'boba'}, otherwise install {action: 'install', target: 'boba'}.",
  "- User: find a goku pet → {action: 'search', target: 'goku'}, then install the best exact result or ask if several variants look plausible.",
  "- Petdex result install line says '/pet install goku-blue' → use {action: 'install', target: 'goku-blue'}.",
  "- Codex Pets result install line says '/pet install https://codex-pets.net/#/pets/son-goku' → use {action: 'install', target: 'https://codex-pets.net/#/pets/son-goku'}.",
  "- User: cozy dragon / cute cat / fierce robot → search those exact words before choosing a pet.",
  "",
  "Natural-language workflow:",
  "1. When the user asks to change pets, check the installed pet list first if it is not already fresh in the conversation. Do not call list repeatedly when a recent list is available.",
  "2. If an installed slug clearly matches the request, call pi_pet with action: use and that slug; do not reinstall it.",
  "3. If the request is descriptive, vague, or a popular character/name that may have multiple variants (e.g. goku, dragon, cozy cat), call pi_pet with action: search and the user's words before installing.",
  "4. Read search results carefully. Prefer exact name/character matches and respect the source: Petdex results can be installed by slug; Codex Pets results should be installed with the returned codex-pets.net URL.",
  "5. If there is one strong match, install it using pi_pet action: install with the exact target from the result. If multiple plausible variants exist, briefly present the options and ask the user to choose.",
  "6. If install fails with not found/404, do not keep retrying the same target. Search for close names/aliases, try a better candidate only if confident, otherwise explain the miss and ask for a slug or URL.",
  "7. If search is unavailable, avoid guessing obscure names; ask the user for the exact Petdex slug or Codex Pets URL.",
].join("\n");

const PetToolParams = {
  type: "object",
  properties: {
    action: {
      type: "string",
      enum: ["list", "current", "use", "install", "search"],
      description: "Pet action to perform. Examples: list, search with target 'goku', install with target 'boba' or 'https://codex-pets.net/#/pets/son-goku', use with target 'boba'.",
    },
    target: {
      type: "string",
      description: "Installed slug for use; Petdex slug or Codex Pets URL for install; query text for search. Examples: 'boba', 'goku', 'cozy dragon', 'https://codex-pets.net/#/pets/son-goku'.",
    },
  },
  required: ["action"],
  additionalProperties: false,
} as const;

function petCommandUsage(): string {
  return [
    "Usage:",
    "  /pet install <petdex-slug-or-url>",
    "  /pet search <query>",
    "  /pet use <installed-slug>",
    "  /pet list",
    "  /pet current",
    "  /pet agent guide",
    "",
    "Bare install names use Petdex. Use a codex-pets.net URL for Codex Pets.",
  ].join("\n");
}

function completionItems(candidates: CompletionItem[], prefix: string): CompletionItem[] | null {
  const normalizedPrefix = prefix.trimStart().toLowerCase();
  const seen = new Set<string>();
  const items = candidates.filter((candidate) => {
    const key = candidate.value.toLowerCase();
    if (seen.has(key)) return false;
    if (!key.startsWith(normalizedPrefix)) return false;
    seen.add(key);
    return true;
  });
  return items.length > 0 ? items : null;
}

function assertPetSlug(slug: string): void {
  if (!PET_SLUG_RE.test(slug) || slug === "." || slug === "..") throw new Error(`Invalid pet slug: ${slug}`);
}

function lastOutput(result: Pick<ProcessResult, "stdout" | "stderr">): string {
  const text = `${result.stderr}\n${result.stdout}`.trim();
  return text.length > 1200 ? text.slice(-1200) : text;
}

function runProcess(command: string, args: string[], options: { cwd?: string; env?: Record<string, string | undefined>; timeoutMs?: number } = {}): Promise<ProcessResult> {
  return new Promise((resolve, reject) => {
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let settled = false;

    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    child.stdout?.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr?.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    const timeout = options.timeoutMs
      ? setTimeout(() => {
          timedOut = true;
          try { child.kill("SIGTERM"); } catch {}
          setTimeout(() => {
            try { child.kill("SIGKILL"); } catch {}
          }, 1500).unref();
        }, options.timeoutMs)
      : undefined;
    timeout?.unref();

    child.on("error", (error) => {
      if (settled) return;
      settled = true;
      if (timeout) clearTimeout(timeout);
      reject(error);
    });

    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      if (timeout) clearTimeout(timeout);
      resolve({ code, stdout, stderr, timedOut });
    });
  });
}

async function readActivePet(): Promise<string | undefined> {
  try {
    const active = (await readFile(activePetFile, "utf8")).trim();
    return active || undefined;
  } catch {
    return undefined;
  }
}

async function listInstalledPets(): Promise<InstalledPet[]> {
  const active = await readActivePet();
  let entries: Array<{ isDirectory(): boolean; name: string }>;
  try {
    entries = await readdir(petsDir, { withFileTypes: true });
  } catch {
    return [];
  }

  const pets: InstalledPet[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !PET_SLUG_RE.test(entry.name)) continue;
    const manifestPath = join(petsDir, entry.name, "pet.json");
    if (!existsSync(manifestPath)) continue;

    const manifest = await readJsonObject(manifestPath);
    const displayName = firstString(manifest, ["displayName", "name", "id"]) ?? entry.name;
    pets.push({ slug: entry.name, displayName, active: active === entry.name });
  }

  return pets.sort((a, b) => a.slug.localeCompare(b.slug));
}

function formatPetList(pets: InstalledPet[]): string {
  if (pets.length === 0) return "No pets installed.";
  return pets.map((pet) => `${pet.active ? "*" : " "} ${pet.slug} — ${pet.displayName}`).join("\n");
}

function petdexPetSearchText(pet: PetdexPet): string {
  return [pet.slug, pet.displayName, pet.kind, pet.description, pet.vibes?.join(" "), pet.colors?.join(" "), pet.submittedBy].filter(Boolean).join(" ").toLowerCase();
}

function parseStringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const items = value.filter((item): item is string => typeof item === "string" && item.trim()).map((item) => item.trim());
  return items.length > 0 ? items : undefined;
}

function parsePetdexPet(raw: unknown): PetdexPet[] {
  if (!isRecord(raw) || typeof raw.slug !== "string" || !raw.slug.trim()) return [];
  let submittedBy: string | undefined;
  if (typeof raw.submittedBy === "string") submittedBy = raw.submittedBy.trim();
  else if (isRecord(raw.submittedBy) && typeof raw.submittedBy.name === "string") submittedBy = raw.submittedBy.name.trim();

  const slug = raw.slug.trim();
  return [{
    slug,
    displayName: typeof raw.displayName === "string" ? raw.displayName.trim() : undefined,
    kind: typeof raw.kind === "string" ? raw.kind.trim() : undefined,
    description: typeof raw.description === "string" ? raw.description.trim() : undefined,
    vibes: parseStringArray(raw.vibes),
    colors: parseStringArray(raw.colors),
    submittedBy,
    zipUrl: typeof raw.zipUrl === "string" ? raw.zipUrl.trim() : undefined,
    source: "Petdex",
    installTarget: slug,
  }];
}

function parseCodexPet(raw: unknown): PetdexPet[] {
  if (!isRecord(raw) || typeof raw.id !== "string" || !raw.id.trim()) return [];
  const slug = raw.id.trim();
  return [{
    slug,
    displayName: typeof raw.displayName === "string" ? raw.displayName.trim() : typeof raw.name === "string" ? raw.name.trim() : undefined,
    kind: typeof raw.kind === "string" ? raw.kind.trim() : undefined,
    description: typeof raw.description === "string" ? raw.description.trim() : undefined,
    vibes: parseStringArray(raw.tags),
    submittedBy: typeof raw.ownerName === "string" ? raw.ownerName.trim() : undefined,
    zipUrl: typeof raw.downloadUrl === "string" ? new URL(raw.downloadUrl, CODEX_PETS_BASE).toString() : undefined,
    source: "Codex Pets",
    installTarget: `${CODEX_PETS_BASE}/#/pets/${encodeURIComponent(slug)}`,
  }];
}

function getFetch(): (url: string, init?: Record<string, unknown>) => Promise<any> {
  const fetchFn = (globalThis as any).fetch as undefined | ((url: string, init?: Record<string, unknown>) => Promise<any>);
  if (!fetchFn) throw new Error("fetch is not available in this pi runtime");
  return fetchFn;
}

async function fetchPetdexPets(): Promise<PetdexPet[]> {
  const now = Date.now();
  if (petdexSearchCache.pets && petdexSearchCache.expiresAt > now) return petdexSearchCache.pets;
  if (petdexSearchCache.promise && petdexSearchCache.expiresAt > now) return petdexSearchCache.promise;

  const fetchFn = getFetch();

  const promise = (async () => {
    const response = await fetchFn(PETDEX_MANIFEST_URL, {
      headers: {
        "Accept": "application/json,*/*",
        "User-Agent": "pi-pet search",
      },
    });
    if (!response.ok) throw new Error(`Petdex manifest request failed: HTTP ${response.status}`);

    const payload = await response.json();
    const rawPets = isRecord(payload) && Array.isArray(payload.pets) ? payload.pets : [];
    const pets = rawPets.flatMap(parsePetdexPet);
    petdexSearchCache = { pets, expiresAt: Date.now() + PETDEX_SEARCH_CACHE_TTL_MS };
    return pets;
  })();

  petdexSearchCache = { promise, expiresAt: now + PETDEX_SEARCH_CACHE_TTL_MS };
  return promise;
}

async function searchPetdexPetsViaApi(query: string, limit: number): Promise<PetdexPet[]> {
  const params = new URLSearchParams({ q: query, limit: String(limit) });
  const response = await getFetch()(`${PETDEX_SEARCH_URL}?${params}`, {
    headers: {
      "Accept": "application/json,*/*",
      "Referer": "https://petdex.crafter.run/",
      "User-Agent": "pi-pet search",
    },
  });
  if (!response.ok) throw new Error(`Petdex search request failed: HTTP ${response.status}`);

  const payload = await response.json();
  const rawPets = isRecord(payload) && Array.isArray(payload.pets) ? payload.pets : [];
  return rawPets.flatMap(parsePetdexPet);
}

async function searchPetdexPetsFromManifest(query: string, limit: number): Promise<PetdexPet[]> {
  const terms = query.toLowerCase().split(/\s+/).map((term) => term.trim()).filter(Boolean);
  if (terms.length === 0) throw new Error("Search query is required.");

  const scored = (await fetchPetdexPets()).flatMap((pet, index): Array<{ pet: PetdexPet; score: number; index: number }> => {
    const slug = pet.slug.toLowerCase();
    const name = (pet.displayName ?? "").toLowerCase();
    const text = petdexPetSearchText(pet);
    if (!terms.every((term) => text.includes(term))) return [];

    let score = 0;
    const joined = terms.join(" ");
    if (slug === joined) score += 100;
    if (name === joined) score += 90;
    for (const term of terms) {
      if (slug === term) score += 50;
      else if (slug.startsWith(term)) score += 30;
      else if (slug.includes(term)) score += 15;

      if (name === term) score += 45;
      else if (name.startsWith(term)) score += 25;
      else if (name.includes(term)) score += 12;

      if ((pet.kind ?? "").toLowerCase().includes(term)) score += 5;
      if ((pet.submittedBy ?? "").toLowerCase().includes(term)) score += 2;
    }
    return [{ pet, score, index }];
  });

  return scored
    .sort((a, b) => b.score - a.score || a.index - b.index || a.pet.slug.localeCompare(b.pet.slug))
    .slice(0, limit)
    .map((entry) => entry.pet);
}

async function searchPetdexPets(query: string, limit = 8): Promise<PetdexPet[]> {
  if (!query.trim()) throw new Error("Search query is required.");
  try {
    return await searchPetdexPetsViaApi(query.trim(), limit);
  } catch {
    return searchPetdexPetsFromManifest(query, limit);
  }
}

async function searchCodexPets(query: string, limit = 8): Promise<PetdexPet[]> {
  if (!query.trim()) throw new Error("Search query is required.");
  const params = new URLSearchParams({ q: query.trim(), page: "1", pageSize: String(limit) });
  const response = await getFetch()(`${CODEX_PETS_SEARCH_URL}?${params}`, {
    headers: {
      "Accept": "application/json,*/*",
      "Referer": `${CODEX_PETS_BASE}/`,
      "User-Agent": "pi-pet search",
    },
  });
  if (!response.ok) throw new Error(`Codex Pets search request failed: HTTP ${response.status}`);

  const payload = await response.json();
  const rawPets = isRecord(payload) && Array.isArray(payload.pets) ? payload.pets : [];
  return rawPets.flatMap(parseCodexPet);
}

async function searchPets(query: string): Promise<PetdexPet[]> {
  const [petdex, codex] = await Promise.allSettled([
    searchPetdexPets(query),
    searchCodexPets(query),
  ]);

  const results = [
    ...(petdex.status === "fulfilled" ? petdex.value : []),
    ...(codex.status === "fulfilled" ? codex.value : []),
  ];
  if (results.length === 0 && petdex.status === "rejected" && codex.status === "rejected") {
    throw new Error(`Pet search failed. Petdex: ${petdex.reason}; Codex Pets: ${codex.reason}`);
  }
  return results;
}

function formatPetSearchResults(query: string, pets: PetdexPet[]): string {
  if (pets.length === 0) return `No Petdex/Codex Pets found for: ${query}`;
  return [
    `Pet search results for: ${query}`,
    ...pets.map((pet) => {
      const source = pet.source ?? "Petdex";
      const tags = pet.vibes?.length ? `#${pet.vibes.join(" #")}` : undefined;
      const details = [pet.displayName && pet.displayName !== pet.slug ? pet.displayName : undefined, pet.kind, tags, pet.submittedBy ? `by ${pet.submittedBy}` : undefined]
        .filter(Boolean)
        .join(" · ");
      const description = pet.description ? ` — ${pet.description}` : "";
      return `- [${source}] ${pet.slug}${details ? ` — ${details}` : ""}${description}\n  install: /pet install ${pet.installTarget ?? pet.slug}`;
    }),
  ].join("\n");
}

async function getPetCompletions(prefix: string): Promise<CompletionItem[] | null> {
  const installedPets = await listInstalledPets();
  const installedPetCompletions = installedPets.flatMap((pet): CompletionItem[] => {
    const description = `${pet.active ? "Active" : "Installed"}: ${pet.displayName}`;
    return [
      { value: `use ${pet.slug}`, label: `use ${pet.slug}`, description },
      { value: `set ${pet.slug}`, label: `set ${pet.slug}`, description: `Alias for use. ${description}` },
      { value: `activate ${pet.slug}`, label: `activate ${pet.slug}`, description: `Alias for use. ${description}` },
      { value: pet.slug, label: pet.slug, description: `Shortcut: activate installed pet. ${description}` },
    ];
  });

  return completionItems(
    [
      { value: "install ", label: "install", description: "Install a Petdex slug or Petdex/Codex Pets URL" },
      { value: "install luffy", label: "install luffy", description: "Example Petdex install" },
      { value: "install https://codex-pets.net/#/pets/dario", label: "install Codex Pets URL", description: "Example Codex Pets install" },
      { value: "add ", label: "add", description: "Alias for install" },
      { value: "search ", label: "search", description: "Search Petdex and Codex Pets by text/vibe/name" },
      { value: "find ", label: "find", description: "Alias for search" },
      { value: "use ", label: "use", description: "Activate an installed pet" },
      { value: "set ", label: "set", description: "Alias for use" },
      { value: "activate ", label: "activate", description: "Alias for use" },
      { value: "list", label: "list", description: "List installed pets" },
      { value: "ls", label: "ls", description: "Alias for list" },
      { value: "current", label: "current", description: "Show the active pet" },
      { value: "active", label: "active", description: "Alias for current" },
      { value: "agent guide", label: "agent guide", description: "Add pi-pet tool guidance to this conversation" },
      { value: "load guide", label: "load guide", description: "Alias for agent guide" },
      { value: "guide", label: "guide", description: "Alias for agent guide" },
      { value: "help", label: "help", description: "Show /pet usage" },
      ...installedPetCompletions,
    ],
    prefix,
  );
}

async function activatePet(slug: string): Promise<string> {
  assertPetSlug(slug);
  const manifestPath = join(petsDir, slug, "pet.json");
  if (!existsSync(manifestPath)) throw new Error(`Pet is not installed: ${slug}`);

  await mkdir(petsDir, { recursive: true });
  await writeFile(activePetFile, `${slug}\n`, "utf8");
  return slug;
}

async function installPet(target: string): Promise<string> {
  if (!target.trim()) throw new Error("Pet target is required.");
  if (!existsSync(petInstallScript)) throw new Error(`Missing installer: ${petInstallScript}`);

  const result = await runProcess("bash", [petInstallScript, target.trim()], {
    cwd: packageRoot,
    env: { ...process.env, PI_PET_PETS_DIR: petsDir },
    timeoutMs: 180_000,
  });

  if (result.timedOut) throw new Error(`Pet install timed out.\n${lastOutput(result)}`.trim());
  if (result.code !== 0) throw new Error(`Pet install failed.\n${lastOutput(result)}`.trim());

  return (await readActivePet()) ?? target.trim();
}

function requirePetTarget(target: string | undefined, action: string): string {
  const trimmed = target?.trim() ?? "";
  if (!trimmed) throw new Error(`target is required for pi_pet action: ${action}`);
  return trimmed;
}

async function runPetToolAction(action: "list" | "current" | "use" | "install" | "search", target: string | undefined, ctx: ExtensionContext) {
  switch (action) {
    case "list": {
      const pets = await listInstalledPets();
      return {
        content: [{ type: "text" as const, text: formatPetList(pets) }],
        details: { action, pets },
      };
    }

    case "current": {
      const activePet = (await readActivePet()) ?? "none";
      return {
        content: [{ type: "text" as const, text: `Active pet: ${activePet}` }],
        details: { action, activePet },
      };
    }

    case "use": {
      const slug = requirePetTarget(target, action);
      const activePet = await activatePet(slug);
      restartPetOverlay(ctx.cwd, activePet);
      return {
        content: [{ type: "text" as const, text: `Active pet: ${activePet}` }],
        details: { action, activePet },
      };
    }

    case "install": {
      const installTarget = requirePetTarget(target, action);
      runBubble(ctx.cwd, ["thinking", `Installing pet ${installTarget}...`]);
      const activePet = await installPet(installTarget);
      restartPetOverlay(ctx.cwd, activePet);
      return {
        content: [{ type: "text" as const, text: `Installed and activated pet: ${activePet}` }],
        details: { action, target: installTarget, activePet },
      };
    }

    case "search": {
      const query = requirePetTarget(target, action);
      const results = await searchPets(query);
      return {
        content: [{ type: "text" as const, text: formatPetSearchResults(query, results) }],
        details: { action, query, results },
      };
    }
  }
}

function loadPetGuide(pi: ExtensionAPI, ctx: ExtensionContext): void {
  pi.sendMessage(
    {
      customType: "pi-pet-guide",
      content: PET_GUIDE,
      display: true,
      details: { kind: "pet-management-guide" },
    },
    { triggerTurn: false },
  );
  ctx.ui.notify("pi-pet guide added to this conversation", "info");
}

function restartPetOverlay(projectCwd: string, activePet: string): void {
  try {
    spawnSync(
      "powershell.exe",
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*pet-bubble.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }",
      ],
      { stdio: "ignore", timeout: 2500 },
    );
  } catch {
    // Restarting the Windows overlay is cosmetic; the active pet file was already updated.
  }

  runBubble(projectCwd, ["finished", `Pet: ${activePet}`]);
}

async function chooseInstalledPet(ctx: ExtensionContext): Promise<string | undefined> {
  const pets = await listInstalledPets();
  if (pets.length === 0) {
    ctx.ui.notify("No pets installed. Try /pet install luffy", "warning");
    return undefined;
  }

  const options = pets.map((pet) => `${pet.active ? "✓" : " "} ${pet.slug} — ${pet.displayName}`);
  const choice = await ctx.ui.select("Choose active pet", options);
  if (!choice) return undefined;
  const index = options.indexOf(choice);
  return index >= 0 ? pets[index].slug : undefined;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    runBubble(ctx.cwd, ["start", "finished", "Ready"]);
    void refreshUsage(ctx, { refresh: true });
  });

  pi.on("model_select", async (event, ctx) => {
    void refreshUsage(ctx, { refresh: true, model: (event as any).model });
  });

  pi.on("agent_start", async (_event, ctx) => {
    runBubble(ctx.cwd, ["thinking", "Working..."]);
  });

  pi.on("agent_end", async (_event, ctx) => {
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

  pi.registerTool({
    name: "pi_pet",
    label: "Pi Pet",
    description: "Manage the desktop pet: search Petdex/Codex Pets, list installed pets, show current pet, switch pets, or install a Petdex/Codex Pets pet.",
    promptSnippet: "Manage the desktop pet with list/current/use/install/search actions.",
    promptGuidelines: [
      "Use pi_pet for agent-driven desktop pet changes instead of writing /pet slash commands or running /pet in bash.",
      "Use pi_pet with action list before installing; if the requested pet is already installed, use action use instead of reinstalling.",
      "Use pi_pet with action search for vague/descriptive requests or names with multiple variants; install the exact target returned by search, especially codex-pets.net URLs for Codex Pets results.",
      "Examples: search Goku -> { action: 'search', target: 'goku' }; install Petdex Boba -> { action: 'install', target: 'boba' }; install Codex Son Goku -> { action: 'install', target: 'https://codex-pets.net/#/pets/son-goku' }; switch installed Boba -> { action: 'use', target: 'boba' }.",
    ],
    parameters: PetToolParams,
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return runPetToolAction(params.action, params.target, ctx);
    },
  });

  pi.registerCommand("pet", {
    description: "Install, search, or switch the desktop pet: install <slug-or-url>, search <query>, use <slug>, list, current, agent guide",
    getArgumentCompletions: getPetCompletions,
    handler: async (args, ctx) => {
      const trimmed = args.trim();
      const [command = "", ...rest] = trimmed.split(/\s+/);
      const value = trimmed.slice(command.length).trim();

      try {
        if (!trimmed) {
          const action = await ctx.ui.select("pi-pet", ["Install new pet", "Search pets", "Use installed pet", "List installed pets", "Show current pet"]);
          if (!action) return;

          if (action === "Install new pet") {
            const target = await ctx.ui.input("Petdex slug or Codex Pets/Petdex URL", "luffy");
            if (!target) return;
            runBubble(ctx.cwd, ["thinking", `Installing pet ${target}...`]);
            ctx.ui.setStatus("pi-pet", `Installing ${target}...`);
            try {
              const activePet = await installPet(target);
              restartPetOverlay(ctx.cwd, activePet);
              ctx.ui.notify(`Installed and activated pet: ${activePet}`, "info");
            } finally {
              ctx.ui.setStatus("pi-pet", undefined);
            }
            return;
          }

          if (action === "Search pets") {
            const query = await ctx.ui.input("Pet search query", "cozy dragon");
            if (!query) return;
            ctx.ui.setStatus("pi-pet", `Searching ${query}...`);
            try {
              ctx.ui.notify(formatPetSearchResults(query, await searchPets(query)), "info");
            } finally {
              ctx.ui.setStatus("pi-pet", undefined);
            }
            return;
          }

          if (action === "Use installed pet") {
            const slug = await chooseInstalledPet(ctx);
            if (!slug) return;
            const activePet = await activatePet(slug);
            restartPetOverlay(ctx.cwd, activePet);
            ctx.ui.notify(`Active pet: ${activePet}`, "info");
            return;
          }

          if (action === "List installed pets") {
            ctx.ui.notify(formatPetList(await listInstalledPets()), "info");
            return;
          }

          ctx.ui.notify(`Active pet: ${(await readActivePet()) ?? "none"}`, "info");
          return;
        }

        switch (command.toLowerCase()) {
          case "help":
          case "-h":
          case "--help":
            ctx.ui.notify(petCommandUsage(), "info");
            return;

          case "list":
          case "ls":
            ctx.ui.notify(formatPetList(await listInstalledPets()), "info");
            return;

          case "current":
          case "active":
            ctx.ui.notify(`Active pet: ${(await readActivePet()) ?? "none"}`, "info");
            return;

          case "search":
          case "find": {
            const query = value;
            if (!query) {
              ctx.ui.notify("Usage: /pet search <query>", "error");
              return;
            }
            ctx.ui.setStatus("pi-pet", `Searching ${query}...`);
            try {
              ctx.ui.notify(formatPetSearchResults(query, await searchPets(query)), "info");
            } finally {
              ctx.ui.setStatus("pi-pet", undefined);
            }
            return;
          }

          case "guide":
            loadPetGuide(pi, ctx);
            return;

          case "agent":
            if ((rest[0] ?? "").toLowerCase() === "guide") {
              loadPetGuide(pi, ctx);
              return;
            }
            ctx.ui.notify("Usage: /pet agent guide", "error");
            return;

          case "load":
            if ((rest[0] ?? "").toLowerCase() === "guide") {
              loadPetGuide(pi, ctx);
              return;
            }
            ctx.ui.notify("Usage: /pet agent guide", "error");
            return;

          case "use":
          case "set":
          case "activate": {
            const slug = rest[0] ?? (await chooseInstalledPet(ctx));
            if (!slug) return;
            const activePet = await activatePet(slug);
            restartPetOverlay(ctx.cwd, activePet);
            ctx.ui.notify(`Active pet: ${activePet}`, "info");
            return;
          }

          case "install":
          case "add": {
            const target = value;
            if (!target) {
              ctx.ui.notify("Usage: /pet install <petdex-slug-or-url>", "error");
              return;
            }

            runBubble(ctx.cwd, ["thinking", `Installing pet ${target}...`]);
            ctx.ui.setStatus("pi-pet", `Installing ${target}...`);
            try {
              const activePet = await installPet(target);
              restartPetOverlay(ctx.cwd, activePet);
              ctx.ui.notify(`Installed and activated pet: ${activePet}`, "info");
            } finally {
              ctx.ui.setStatus("pi-pet", undefined);
            }
            return;
          }

          default: {
            // Convenience: /pet <slug> switches if installed, otherwise installs from Petdex by default.
            const maybeInstalled = (await listInstalledPets()).some((pet) => pet.slug === command);
            if (maybeInstalled) {
              const activePet = await activatePet(command);
              restartPetOverlay(ctx.cwd, activePet);
              ctx.ui.notify(`Active pet: ${activePet}`, "info");
              return;
            }

            runBubble(ctx.cwd, ["thinking", `Installing pet ${trimmed}...`]);
            ctx.ui.setStatus("pi-pet", `Installing ${trimmed}...`);
            try {
              const activePet = await installPet(trimmed);
              restartPetOverlay(ctx.cwd, activePet);
              ctx.ui.notify(`Installed and activated pet: ${activePet}`, "info");
            } finally {
              ctx.ui.setStatus("pi-pet", undefined);
            }
          }
        }
      } catch (error) {
        ctx.ui.setStatus("pi-pet", undefined);
        ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
      }
    },
  });
}
