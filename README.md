<p align="center">
  <img src="https://raw.githubusercontent.com/Tulip4attoo/media_for_projects/master/pi-pet-image-261307.gif" width="200" alt="Pi Pet demo" />
</p>

# Pi Pet

A Codex-inspired desktop pet and status bubble for [pi](https://pi.dev) on native Windows (PowerShell) or WSL. It shows working status and Codex subscription usage, so you do not miss when a session is done.

<p align="center">
  <img src="https://raw.githubusercontent.com/Tulip4attoo/media_for_projects/master/pi-pet-261307.gif" width="720" alt="Pi Pet demo" />
</p>

## Features

- Animated desktop pet for pi sessions
- Ready / Working / Finished status bubble
- Weekly Codex usage and reset progress rings when using a Codex model
- [Petdex](https://petdex.crafter.run/) and [Codex Pets](https://codex-pets.net/) support
- Multiple pi sessions in one overlay
- Click to focus the terminal, drag to move, right-click for actions
- Opt in with `/pet agent guide` to let pi install or switch pets from chat

## Requirements

- Windows with Windows PowerShell (`powershell.exe`, included with Windows)
- pi installed **on Windows or in WSL**
- Native Windows needs no Bash, Python, or WSL for Pi Pet. Run pi from Windows PowerShell or PowerShell 7; the overlay uses Windows PowerShell/WPF.
- WSL users also need `python3` and working Windows-executable interop.

The bundled pet works out of the box. Installing community WebP pets on native Windows requires a Windows WebP image codec or [FFmpeg](https://ffmpeg.org/) on `PATH` if Windows cannot decode the image.

## Install

```bash
pi install https://github.com/Tulip4attoo/pi-pet
```

If pi is already open, reload extensions:

```text
/reload
```

After that, Pi Pet starts automatically with pi. The extension detects whether pi is running natively on Windows or inside WSL.

### Use this checkout on Windows

From PowerShell:

```powershell
cd C:\LxSpace\pi-pet
pi install .
pi
```

If you already installed a different copy of Pi Pet, use `pi list` / `pi remove <old-source>` to avoid loading it twice. In an existing pi session, run `/reload` after installing this checkout.

## Usage

Pi Pet follows pi session events automatically. You can manage pets with:

```text
/pet search goku
/pet install luffy
/pet install https://codex-pets.net/#/pets/dario
/pet list
/pet use luffy
/pet current
```

### Codex usage rings

When the selected model uses the Codex provider, two rings appear around the pet:

- The outer ring shows the weekly allowance remaining.
- The inner ring has seven day-sized segments and counts down to the weekly reset. The current segment drains gradually through the day.

The exact reset countdown is hidden by default because the rings are usually enough. Right-click the pet and toggle **Show reset time** to display it; the choice is remembered. Usage rings are hidden for non-Codex models or when usage data is unavailable.

### Desktop controls

- Click a session bubble to focus its terminal.
- Click the pet to wave and focus the latest session.
- Drag left or right to move the overlay with directional running animations.
- Right-click the pet to show the reset countdown, focus the terminal, or close the pet.

## LLM pet tool is opt-in

By default, Pi Pet only starts the overlay and `/pet` slash command. It does not register the `pi_pet` LLM tool, so no pet tool metadata/guidance is added to the model context.

When you want the model to manage pets, run:

```text
/pet agent guide
```

That registers/enables the `pi_pet` tool for the session and adds the pet-management guide to the conversation. To auto-register the tool at startup, set `PI_PET_TOOL=1`. To hard-disable it even for `/pet agent guide`, set `PI_PET_DISABLE_TOOL=1`.

PowerShell: `$env:PI_PET_TOOL = '1'; pi`. WSL: `PI_PET_TOOL=1 pi`.

## Updates and pet storage

Update package code with:

```text
pi update --extensions
```

User-installed pets are stored outside the package checkout:

```text
Windows: %LOCALAPPDATA%\pi-pet\pets
WSL:     ${XDG_DATA_HOME:-$HOME/.local/share}/pi-pet/pets
```

`PI_PET_PETS_DIR` overrides the pet directory on either platform; `XDG_DATA_HOME` overrides the data root. Windows and WSL use separate pet libraries by default.

So package updates can reset the package without deleting installed pets. Local checkout installs use your working files directly; update those with Git. The bundled fallback pet remains in `pets/default/`.

## Local development

Run from this checkout:

```bash
pi install ./
# or temporary for one run:
pi -e ./
```

Manual overlay test on **Windows** (Node.js on `PATH`):

```powershell
node .\pet-bubble.mjs thinking "test pet"
node .\pet-bubble.mjs finished "Finished"
node .\pet-bubble.mjs stop
```

Manual install without pi:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\pet-install.ps1 luffy
```

Manual overlay test on **WSL**:

```bash
./pet-bubble.sh thinking "test pet"
./pet-bubble.sh stop
```

Run offline tests with `npm test` (Windows additionally tests PowerShell parsing, process checks, and installing a generated local pack). Logs are in `tmp/pet-bubbles/manager-powershell.log`; per-session commands are in `tmp/pet-bubbles/<id>/command.json`.

File map:

```text
package.json                   pi package manifest
extensions/pet-bubble.ts       pi extension, /pet commands, pi_pet tool
pet-bubble.sh                  WSL command writer
pet-bubble.mjs                 native Windows command-line entry point
lib/windows-bubble.mjs         native command writer/launcher, pet storage paths
pet-bubble.ps1                 shared Windows WPF overlay manager
pet-install.sh                 WSL Petdex/Codex Pets installer
pet-install.ps1                native Windows installer (no Bash/Python)
tests/                         offline regression tests
pets/default/                  bundled fallback pet
show-overlay.sh/.ps1           standalone image overlay helper
```
