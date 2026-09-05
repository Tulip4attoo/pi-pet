#!/usr/bin/env node
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { getPetsDir, sendWindowsBubble } from "./lib/windows-bubble.mjs";

const args = process.argv.slice(2);
if (["help", "--help", "-h"].includes(args[0])) {
  console.log(`Native Windows usage:
  node .\\pet-bubble.mjs start [status] [text...]
  node .\\pet-bubble.mjs thinking|answering|finished [text...]
  node .\\pet-bubble.mjs set <status> [text...]
  node .\\pet-bubble.mjs move <x> <y>
  node .\\pet-bubble.mjs stop

PI_PET_BUBBLE_ID, PI_PET_BUBBLE_DIR, PI_PET_BUBBLE_PID and PI_PET_PETS_DIR
can override the session ID, project label, owner PID and pet storage.`);
} else if (process.platform !== "win32") {
  console.error("Use ./pet-bubble.sh from WSL.");
  process.exitCode = 1;
} else {
  try {
    sendWindowsBubble({
      packageRoot: dirname(fileURLToPath(import.meta.url)),
      petsDir: getPetsDir(),
      id: process.env.PI_PET_BUBBLE_ID || `pi-win-${process.ppid}`,
      cwd: process.env.PI_PET_BUBBLE_DIR || process.cwd(),
      pid: process.env.PI_PET_BUBBLE_PID || process.ppid,
    }, args);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
