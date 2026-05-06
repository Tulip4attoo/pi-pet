# Pi Windows Bubble Overlay

Small WSL -> Windows overlay helper for [pi](https://pi.dev): show a draggable 2-line status bubble on Windows while pi runs in WSL.

It displays one row per pi instance:

```text
/home/tulip/project
Thinking...
```

Multiple pi instances are stacked in one Windows overlay window. Drag any row to move the whole stack.

## Requirements

- Windows + WSL
- Windows PowerShell available as `powershell.exe`
- pi running from this repo/project directory

## Files

```text
pet-bubble.ps1                 Windows WPF overlay manager
pet-bubble.sh                  WSL wrapper/command writer
.pi/extensions/pet-bubble.ts   pi extension hooking session events
show-overlay.ps1               standalone image overlay helper
show-overlay.sh                WSL wrapper for image overlay
```

## Install/use with pi

This repo contains a project-local pi extension at:

```text
.pi/extensions/pet-bubble.ts
```

So from this project directory, start pi normally:

```bash
pi
```

If pi is already open, reload extensions:

```text
/reload
```

After that, the bubble updates automatically:

```text
session_start  -> Ready
agent_start    -> Thinking...
message_update -> Answering...
agent_end      -> Finished
quit/exit      -> remove this row
```

It also has a watchdog. If pi is suspended with `Ctrl+Z` or the process dies, the row is removed automatically after about 1 second.

## Manual bubble commands

From WSL:

```bash
./pet-bubble.sh start
./pet-bubble.sh thinking "Thinking..."
./pet-bubble.sh answering "Answering..."
./pet-bubble.sh finished "Done"
./pet-bubble.sh stop
```

Inside pi:

```text
/bubble start
/bubble thinking đang nghĩ...
/bubble answering đang trả lời...
/bubble finished xong rồi
/bubble stop
```

## Multi-instance behavior

Each pi process gets a unique row based on its PID. Rows are rendered by one Windows overlay manager and stacked vertically.

Manual test:

```bash
PI_PET_BUBBLE_ID=a PI_PET_BUBBLE_DIR=/project/a ./pet-bubble.sh thinking "Thinking A"
PI_PET_BUBBLE_ID=b PI_PET_BUBBLE_DIR=/project/b ./pet-bubble.sh answering "Answering B"
```

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

## Create a git repo

```bash
git init
git add .gitignore README.md pet-bubble.ps1 pet-bubble.sh show-overlay.ps1 show-overlay.sh .pi/extensions/pet-bubble.ts
git commit -m "Initial pi Windows bubble overlay"
```

Optional: include sample assets only if you want them in the repo:

```bash
git add spritesheet.webp
git commit -m "Add sample sprite asset"
```

Add remote and push:

```bash
git branch -M main
git remote add origin git@github.com:<you>/<repo>.git
git push -u origin main
```

Runtime files under `tmp/` are ignored.
