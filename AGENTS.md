# AGENTS.md

## Project notes

This repo is a pi package for a WSL -> Windows pet/bubble overlay.

## Codex/Petdex pet sprite contract

`pi-pet` is moving toward a Petdex-compatible desktop pet runtime. Pet packs are expected to match Codex/Petdex custom pet format:

```text
pet.json
spritesheet.webp
```

The sprite atlas is fixed:

```text
1536 x 1872
8 columns x 9 rows
192 x 208 px per cell
```

Rows have fixed meanings and should stay stable unless the project intentionally migrates the pet format:

| Row | State | Used columns | Meaning |
| ---: | --- | ---: | --- |
| 0 | `idle` | 0-5 | calm idle / breathing / blink |
| 1 | `running-right` | 0-7 | directional movement to the right |
| 2 | `running-left` | 0-7 | directional movement to the left |
| 3 | `waving` | 0-3 | greeting / attention gesture |
| 4 | `jumping` | 0-4 | jump / excited bounce |
| 5 | `failed` | 0-7 | error / sad / failed reaction |
| 6 | `waiting` | 0-5 | patient waiting / secondary idle |
| 7 | `running` | 0-5 | active working / in-progress loop |
| 8 | `review` | 0-5 | focused reviewing / thinking loop |

Initial pi status mapping should prefer:

```text
Ready/Finished -> idle or waiting
Thinking       -> review
Answering      -> running
Error          -> failed
Manual hello   -> waving
```

## Important regression note

`pet-bubble.sh` is the critical command writer used by the pi extension. It must be extremely reliable and should always write:

```text
tmp/pet-bubbles/<id>/command.json
```

A previous change tried to capture the Windows foreground/terminal handle from `pet-bubble.sh` before writing `command.json`. When run through the extension, that path could fail/hang/exit early, leaving only files like:

```text
tmp/pet-bubbles/pi-<pid>/focus.json
```

with no `command.json`, so the PowerShell manager had nothing to render and the bubble did not show.

Rules to avoid this again:

- Keep `pet-bubble.sh` simple: write `command.json` first and never let cosmetic features block it.
- Do Windows UI/window discovery in `pet-bubble.ps1` where possible, not in the WSL command writer.
- If adding any optional shell-side feature, guard it with `|| true` and make sure `command.json` is still written.
- After changes, test both paths:
  - Manual: `./pet-bubble.sh thinking "test pet"`
  - Extension-like: `PI_PET_BUBBLE_ID=pi-test PI_PET_BUBBLE_DIR=$PWD PI_PET_BUBBLE_PID=$$ ./pet-bubble.sh thinking "test"` and verify `tmp/pet-bubbles/pi-test/command.json` exists.
- Also check PowerShell syntax with scriptblock parsing before declaring the overlay fixed.
