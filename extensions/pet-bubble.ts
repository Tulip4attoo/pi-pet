import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const instanceId = `pi-${process.pid}`;
const extensionDir = dirname(fileURLToPath(import.meta.url));
const packageRoot = dirname(extensionDir);
const bubbleScript = join(packageRoot, "pet-bubble.sh");

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

export default function (pi: ExtensionAPI) {
  let markedAnswering = false;

  pi.on("session_start", async (_event, ctx) => {
    runBubble(ctx.cwd, ["start", "finished", "Ready"]);
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
