# Pi Pet

A Codex-inspired desktop pet and status bubble for [pi](https://pi.dev) on Windows/WSL. It shows working status and Codex subscription usage, so you do not miss when a session is done.

<p align="center">
  <img src="https://raw.githubusercontent.com/Tulip4attoo/media_for_projects/master/pi-pet-0.3.gif" width="720" alt="Pi Pet demo" />
</p>

## Features

- Animated desktop pet for pi sessions
- Ready / Working / Finished status bubble
- Codex subscription usage rings when using a Codex model
- [Petdex](https://petdex.crafter.run/) and [Codex Pets](https://codex-pets.net/) support - you could use pet from both.
- Multiple pi sessions in one overlay
- Click to focus the terminal, drag to move, right-click for actions
- Ask pi in chat to install or switch to the pet you want

## Requirements

- Windows + WSL
- Windows PowerShell available as `powershell.exe`
- pi installed in WSL

## Install

```bash
pi install https://github.com/Tulip4attoo/pi-pet
```

If pi is already open, reload extensions:

```text
/reload
```

After that, Pi Pet starts automatically with pi.

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

## Updates and pet storage

Update package code with:

```bash
pi update
```

User-installed pets are stored outside the package checkout:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/pi-pet/pets
```

So `pi update` can reset the package without deleting installed pets. The bundled fallback pet remains in `pets/default/`.

## Local development

Run from this checkout:

```bash
pi install ./
# or temporary for one run:
pi -e ./
```

Manual overlay test:

```bash
./pet-bubble.sh thinking "test pet"
./pet-bubble.sh stop
```

File map:

```text
package.json                   pi package manifest
extensions/pet-bubble.ts       pi extension, /pet commands, pi_pet tool
pet-bubble.sh                  WSL command writer
pet-bubble.ps1                 Windows WPF overlay manager
pet-install.sh                 Petdex/Codex Pets installer
pets/default/                  bundled fallback pet
show-overlay.sh/.ps1           standalone image overlay helper
```
