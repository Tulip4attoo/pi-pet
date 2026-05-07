# AGENTS.md

## Project notes

This repo is a pi package for a WSL -> Windows pet/bubble overlay.

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
