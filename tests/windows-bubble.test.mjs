import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import childProcess, { spawnSync } from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { createCommand, getPetsDir, sendWindowsBubble, writeWindowsCommand } from "../lib/windows-bubble.mjs";

const owner = { cwd: 'C:\\a path\\日本語\\"quoted"', pid: 123 };

test("command contract and status defaults", () => {
  assert.equal(createCommand([], owner).action, "start");
  assert.equal(createCommand([], owner).text, "Ready");
  for (const status of ["thinking", "answering", "finished"]) {
    const command = createCommand([status], owner);
    assert.equal(command.action, "set");
    assert.equal(command.platform, "win32");
    assert.equal(command.pid, "123");
    assert.equal(command.status, status);
    assert.equal(command.text, status === "finished" ? "Finished" : "Working...");
  }
  assert.equal(createCommand(["set", "hello", "hi", "there"], owner).text, "hi there");
  assert.equal(createCommand(["stop"], owner).action, "stop");
  assert.equal(createCommand(["move", "-123.5", "0"], owner).x, -123.5);
  for (const args of [["move"], ["move", "no", "0"], ["move", "", "0"], ["move", "Infinity", "0"], ["unknown"]]) {
    assert.throws(() => createCommand(args, owner));
  }
});

test("platform storage defaults and overrides", () => {
  assert.equal(getPetsDir({}, "win32", "home"), join("home", "AppData", "Local", "pi-pet", "pets"));
  assert.equal(getPetsDir({ LOCALAPPDATA: "local" }, "win32", "home"), join("local", "pi-pet", "pets"));
  assert.equal(getPetsDir({}, "linux", "home"), join("home", ".local", "share", "pi-pet", "pets"));
  assert.equal(getPetsDir({ XDG_DATA_HOME: "xdg", LOCALAPPDATA: "local" }, "win32"), join("xdg", "pi-pet", "pets"));
  assert.equal(getPetsDir({ PI_PET_PETS_DIR: " custom " }, "win32"), "custom");
});

test("atomic command write precedes launch, survives launch failures, and stop never launches", () => {
  const packageRoot = mkdtempSync(join(tmpdir(), "pi-pet test 日本語 "));
  const options = { ...owner, packageRoot, petsDir: join(packageRoot, "user pets"), id: "pi-win-test" };
  const read = (file) => JSON.parse(readFileSync(file, "utf8"));
  try {
    const expected = join(packageRoot, "tmp", "pet-bubbles", options.id, "command.json");
    const text = 'quote " newline\n日本語 & $HOME; `no shell`';
    let launches = 0;
    const file = sendWindowsBubble(options, ["thinking", text], () => {
      launches++;
      assert.equal(read(expected).text, text);
      throw new Error("PowerShell unavailable");
    });
    assert.equal(file, expected);
    assert.equal(launches, 1);
    assert.equal(read(file).dir, owner.cwd);
    const seq = read(file).seq;
    sendWindowsBubble(options, ["finished"], () => {});
    assert.notEqual(read(file).seq, seq);
    sendWindowsBubble(options, ["stop"], () => { launches++; });
    assert.equal(read(file).action, "stop");
    assert.equal(launches, 1);
    assert.deepEqual(readdirSync(join(packageRoot, "tmp", "pet-bubbles", options.id)), ["command.json"]);
    for (const id of ["", ".", ".."]) assert.throws(() => writeWindowsCommand(packageRoot, id, {}));
  } finally { rmSync(packageRoot, { recursive: true, force: true }); }
});

test("native launcher never hides the shared terminal window", () => {
  const packageRoot = mkdtempSync(join(tmpdir(), "pi-pet launcher "));
  const originalSpawn = childProcess.spawn;
  let invocation;
  let unreferenced = false;
  try {
    childProcess.spawn = (command, args, options) => {
      invocation = { command, args, options };
      return { on() {}, unref() { unreferenced = true; } };
    };
    syncBuiltinESMExports();
    sendWindowsBubble({ ...owner, packageRoot, petsDir: packageRoot, id: "test" }, ["start"]);
    assert.equal(invocation.command, "powershell.exe");
    assert.equal(invocation.args.includes("-WindowStyle"), false);
    assert.equal(invocation.options.windowsHide, true);
    assert.notEqual(invocation.options.detached, true);
    assert.equal(unreferenced, true);
  } finally {
    childProcess.spawn = originalSpawn;
    syncBuiltinESMExports();
    rmSync(packageRoot, { recursive: true, force: true });
  }
});

test("Windows PowerShell syntax, watchdog, sprite conversion and offline installer", { skip: process.platform !== "win32" }, () => {
  const result = spawnSync("powershell.exe", [
    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-STA", "-File",
    fileURLToPath(new URL("./windows.test.ps1", import.meta.url)),
  ], { encoding: "utf8", timeout: 60_000, windowsHide: true });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}\n${result.error || ""}`);
});
