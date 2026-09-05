// Opt-in live test: opens the pet and exercises the real Windows launcher/WPF UI.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { sendWindowsBubble } from "../lib/windows-bubble.mjs";

if (process.platform !== "win32") throw new Error("This smoke test requires native Windows.");
const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const scratch = join(packageRoot, "tmp", "native smoke 日本語");
process.env.PI_PET_PETS_DIR = join(scratch, "user pets");
const { default: extension } = await import("../extensions/pet-bubble.ts");
const handlers = {};
const commands = {};
extension({ on: (name, fn) => handlers[name] = fn, registerCommand: (name, value) => commands[name] = value });
const ctx = { cwd: 'C:\\project with spaces\\日本語', model: { provider: "test" }, ui: { notify() {} } };
const options = { packageRoot, petsDir: process.env.PI_PET_PETS_DIR, id: `pi-win-${process.pid}`, cwd: ctx.cwd, pid: process.pid };
const file = join(packageRoot, "tmp", "pet-bubbles", options.id, "command.json");
const readJson = (path) => JSON.parse(readFileSync(path, "utf8").replace(/^\uFEFF/, ""));
const managerPid = () => readJson(join(tmpdir(), "pi-pet-manager-owner.json")).pid;
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
async function waitFor(check, message) {
  for (let i = 0; i < 60; i++) {
    try { if (check()) return; } catch {}
    await delay(250);
  }
  throw new Error(message);
}
function assertVisible(pid) {
  // MainWindowHandle excludes tool windows. Enumerate visible HWNDs instead.
  const script = `
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PetSmokeWindows {
  public delegate bool Callback(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumWindows(Callback cb, IntPtr data);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  public static bool Visible(uint pid) {
    bool found = false;
    EnumWindows((hwnd, data) => { uint owner; GetWindowThreadProcessId(hwnd, out owner);
      if (owner == pid && IsWindowVisible(hwnd)) found = true; return true; }, IntPtr.Zero);
    return found;
  }
}
'@
if (-not [PetSmokeWindows]::Visible(${pid})) { throw 'No visible WPF pet window' }
`;
  const result = spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-EncodedCommand", Buffer.from(script, "utf16le").toString("base64")], { windowsHide: true, encoding: "utf8", timeout: 10000 });
  assert.equal(result.status, 0, result.stderr);
}

let child;
let alternate;
try {
  await handlers.session_start({}, ctx);
  assert.equal(readJson(file).action, "start");
  await waitFor(() => alive(managerPid()), "manager did not start");
  await delay(2500);
  const firstPid = managerPid();
  assertVisible(firstPid);
  await handlers.agent_start({}, ctx);
  assert.equal(readJson(file).status, "thinking");
  await delay(2000);
  assert.equal(managerPid(), firstPid, "ordinary updates must reuse the manager");
  await handlers.agent_end({}, ctx);
  assert.equal(readJson(file).status, "finished");
  await handlers.session_shutdown({ reason: "reload" }, ctx);
  assert.equal(readJson(file).text, "Reloading...");
  await handlers.session_start({}, ctx);

  // A second session disappears after its native owner dies, without sending stop.
  child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore", windowsHide: true });
  const second = { ...options, id: "pi-win-smoke-second", pid: child.pid };
  const secondFile = sendWindowsBubble(second, ["thinking", "Second session"]);
  await delay(1500);
  child.kill();
  await waitFor(() => !existsSync(secondFile), "Windows owner watchdog did not remove dead session");

  sendWindowsBubble({ ...options, restart: true }, ["finished", "Restart test"]);
  await waitFor(() => managerPid() !== firstPid && alive(managerPid()), "pet switch did not restart manager");
  await delay(2000);
  assertVisible(managerPid());

  // Exercise actual PowerShell argument passing and old-root cleanup, not just JSON,
  // with a package path containing spaces and non-ASCII characters.
  mkdirSync(scratch, { recursive: true });
  cpSync(join(packageRoot, "pet-bubble.ps1"), join(scratch, "pet-bubble.ps1"));
  cpSync(join(packageRoot, "pets", "default"), join(scratch, "pets", "default"), { recursive: true });
  alternate = { ...options, packageRoot: scratch, id: "pi-win-smoke-path" };
  const previousPid = managerPid();
  sendWindowsBubble(alternate, ["start", "finished", "Path test"]);
  await waitFor(() => managerPid() !== previousPid && alive(managerPid()), "root change did not replace manager");
  await delay(2000);
  assertVisible(managerPid());
  const finalPid = managerPid();
  sendWindowsBubble(alternate, ["stop"]);
  await waitFor(() => !alive(finalPid), "last stop did not close overlay");
  console.log("Native Windows live smoke passed: visible WPF window, lifecycle, multi-session watchdog, restart, Unicode paths, shutdown.");
} finally {
  child?.kill();
  if (alternate) sendWindowsBubble(alternate, ["stop"]);
  await handlers.session_shutdown({ reason: "quit" }, ctx);
  assert.equal(readJson(file).action, "stop", "shutdown must write synchronously");
  await delay(1000);
  rmSync(join(packageRoot, "tmp", "pet-bubbles", options.id), { recursive: true, force: true });
  rmSync(scratch, { recursive: true, force: true });
}
