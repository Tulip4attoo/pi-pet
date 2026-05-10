# Pi Windows Bubble Overlay

Small WSL -> Windows overlay helper for [pi](https://pi.dev): show a draggable 2-line status bubble on Windows while pi runs in WSL.

It displays one row per pi instance:

```text
/home/tulip/project
Thinking...
```

Multiple pi instances are stacked in one Windows overlay window. Click a row to bring its terminal window back to the front; right-click a row for Show window / Close pet; drag any row to move the whole stack.

## Requirements

- Windows + WSL
- Windows PowerShell available as `powershell.exe`
- pi installed in WSL

## Files

```text
package.json                   pi package manifest
extensions/pet-bubble.ts       pi extension hooking session events
pet-bubble.ps1                 Windows WPF overlay manager
pet-bubble.sh                  WSL wrapper/command writer
pet-install.sh                 Petdex/Codex Pets pet pack installer
pets/default/                  bundled default Einstein pet
show-overlay.ps1               standalone image overlay helper
show-overlay.sh                WSL wrapper for image overlay
```

## Install/use with pi

Install as a pi package from git:

```bash
pi install git:github.com/<you>/pi-pet-bubble
# or
pi install https://github.com/<you>/pi-pet-bubble
```

For a project-local install, run from the target project:

```bash
pi install -l git:github.com/<you>/pi-pet-bubble
```

For local development from this checkout:

```bash
pi install ./
# or temporary for one run:
pi -e ./
```

If pi is already open, reload extensions:

```text
/reload
```

After that, the bubble updates automatically:

```text
session_start  -> Ready
agent_start    -> Working...
agent_end      -> Finished
quit/exit      -> remove this row
```

It also has a watchdog. If pi is suspended with `Ctrl+Z` or the process dies, the row is removed automatically after about 1 second.

## Manual bubble commands

From WSL:

```bash
./pet-bubble.sh start
./pet-bubble.sh thinking "Working..."
./pet-bubble.sh finished "Done"
./pet-bubble.sh stop
```

Inside pi:

```text
/bubble start
/bubble thinking đang làm...
/bubble finished xong rồi
/bubble stop
```

Manage pets from inside pi:

```text
/pet install luffy
/pet install https://codex-pets.net/#/pets/dario
/pet search cozy dragon
/pet use einstein
/pet list
/pet current
/pet agent guide
```

Bare `/pet install <name>` uses Petdex by default. A `codex-pets.net` URL installs from Codex Pets. `/pet search <query>` searches both Petdex and Codex Pets and returns installable slugs/URLs. `/pet agent guide` adds short guidance for agent-driven pet changes using the `pi_pet` tool.

## Multi-instance behavior

Each pi process gets a unique row based on its PID. Rows are rendered by one Windows overlay manager and stacked vertically. Clicking a row focuses the terminal window that was active when that row first wrote a bubble command.

Manual test:

```bash
PI_PET_BUBBLE_ID=a PI_PET_BUBBLE_DIR=/project/a ./pet-bubble.sh thinking "Thinking A"
PI_PET_BUBBLE_ID=b PI_PET_BUBBLE_DIR=/project/b ./pet-bubble.sh answering "Answering B"
```

## Install pets

Install a pet pack into the persistent user pet store and make it active:

```bash
./pet-install.sh luffy
./pet-install.sh https://petdex.crafter.run/pets/luffy
./pet-install.sh https://codex-pets.net/#/pets/dario
```

Bare names/slugs use Petdex by default. To install from Codex Pets, pass a `codex-pets.net` pet URL.

User-installed pets are stored outside the package checkout so they survive `pi update`:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/pi-pet/pets/<slug>/
${XDG_DATA_HOME:-$HOME/.local/share}/pi-pet/pets/active
```

The bundled `pets/default/` remains as a read-only fallback. If older installs are found under the package `pets/` directory, pi-pet copies them into the persistent store on startup.

## Image overlay helper

Standalone image overlay:

```bash
./show-overlay.sh ./image.png -Nearest
```

Useful options:

```bash
-ClickThrough
-Duration 10
-Opacity 0.9
-AlphaThreshold 4
-TransparentColor '#ff00ff' -ColorTolerance 80
```

## Packaging notes

This repo is structured as a pi package. `package.json` declares:

```json
{
  "pi": {
    "extensions": ["./extensions/pet-bubble.ts"]
  }
}
```

Runtime files under `tmp/` are ignored.
