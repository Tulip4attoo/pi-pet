import { spawn } from "node:child_process";
import { appendFileSync, closeSync, mkdirSync, openSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const MANAGER_VERSION = "0.4.1";

export function getPetsDir(env = process.env, platform = process.platform, home = homedir()) {
  if (env.PI_PET_PETS_DIR?.trim()) return env.PI_PET_PETS_DIR.trim();
  const dataRoot = env.XDG_DATA_HOME?.trim() || (platform === "win32"
    ? env.LOCALAPPDATA?.trim() || join(home, "AppData", "Local")
    : join(home, ".local", "share"));
  return join(dataRoot, "pi-pet", "pets");
}

export function createCommand(args, { cwd, pid }) {
  const [command = "start", ...rest] = args;
  const payload = { seq: randomUUID(), action: "set", dir: cwd, pid: String(pid), platform: "win32" };
  switch (command) {
    case "start":
      return { ...payload, action: "start", status: rest[0] || "finished", text: rest.slice(1).join(" ") || "Ready" };
    case "stop":
      return { ...payload, action: "stop" };
    case "thinking":
    case "answering":
    case "finished":
      return { ...payload, status: command, text: rest.join(" ") || (command === "finished" ? "Finished" : "Working...") };
    case "set":
      return { ...payload, status: rest[0] || "finished", text: rest.slice(1).join(" ") };
    case "move": {
      if (rest.length !== 2 || rest.some((value) => !value.trim() || !Number.isFinite(Number(value)))) {
        throw new Error("move requires two numeric coordinates");
      }
      return { ...payload, action: "move", x: Number(rest[0]), y: Number(rest[1]) };
    }
    default:
      throw new Error(`Unknown bubble command: ${command}`);
  }
}

export function writeWindowsCommand(root, id, payload) {
  const safeId = id.replace(/[^a-zA-Z0-9_.-]/g, "_");
  if (!safeId || safeId === "." || safeId === "..") throw new Error("Invalid bubble ID");
  const file = join(root, safeId, "command.json");
  mkdirSync(dirname(file), { recursive: true });
  const tmp = `${file}.${randomUUID()}.tmp`;
  try {
    writeFileSync(tmp, `${JSON.stringify(payload)}\n`, "utf8");
    renameSync(tmp, file);
  } finally {
    rmSync(tmp, { force: true });
  }
  return file;
}

export function launchWindowsManager({ packageRoot, petsDir, restart = false }) {
  const root = join(packageRoot, "tmp", "pet-bubbles");
  const log = join(root, "manager-powershell.log");
  const reportError = (error) => {
    try { appendFileSync(log, `\nCould not launch pet overlay: ${error.message}\n`); } catch {}
  };
  let fd;
  try {
    fd = openSync(log, "a");
    // Do not pass -WindowStyle Hidden: PowerShell can hide pi's shared console.
    // windowsHide suppresses a new console without changing the parent's window.
    const child = spawn("powershell.exe", [
      "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-STA",
      "-File", join(packageRoot, "pet-bubble.ps1"),
      "-RootPath", root, "-StatePath", join(root, "manager-state.json"),
      "-UserPetsPath", petsDir, "-ManagerVersion", MANAGER_VERSION, "-Bootstrap",
      ...(restart ? ["-Restart"] : []),
    ], { cwd: packageRoot, windowsHide: true, stdio: ["ignore", fd, fd] });
    // spawn errors are asynchronous and must never become uncaught extension errors.
    child.on("error", reportError);
    // On Windows, detached + a hidden console can make Windows PowerShell exit
    // before executing -File. Redirected stdio + unref is enough to release pi.
    child.unref();
  } catch (error) {
    reportError(error);
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

export function sendWindowsBubble(options, args, launch = launchWindowsManager) {
  const payload = createCommand(args, options);
  // This is deliberately synchronous, including during pi shutdown. Do not put
  // process discovery, optional assets, or PowerShell startup before this write.
  const file = writeWindowsCommand(join(options.packageRoot, "tmp", "pet-bubbles"), options.id, payload);
  if (payload.action !== "stop") {
    try { launch(options); } catch { /* The command is already safely published. */ }
  }
  return file;
}
