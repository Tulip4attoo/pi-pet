#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./show-overlay.sh IMAGE [PowerShell options]

Examples:
  ./show-overlay.sh ./picture.png -X 300 -Y 120
  ./show-overlay.sh ./picture.png -X 0 -Y 0 -Width 500 -Height 500 -Opacity 0.8 -ClickThrough
  ./show-overlay.sh ./picture.png -Duration 10 -ClickThrough
  ./show-overlay.sh ./spritesheet.webp -Nearest -TransparentColor '#ff00ff' -ColorTolerance 45 -AlphaThreshold 24

PowerShell options:
  -X <px> -Y <px>              Position on Windows desktop
  -Width <px> -Height <px>    Render size; defaults to image size
  -Opacity <0..1>             Whole overlay opacity
  -Duration <seconds>         Auto close; 0 = stay open
  -Nearest                    Pixel-art scaling, no smoothing/halo
  -AlphaThreshold <0..255>    Force pixels with alpha <= N to transparent
  -TransparentColor <color>   Chroma-key color: #RRGGBB or R,G,B
  -ColorTolerance <0..255>    Tolerance for -TransparentColor
  -ClickThrough               Mouse clicks pass through overlay
  -NoTopmost                  Do not force always-on-top

Close with Esc when not click-through. If click-through and no Duration, kill powershell.exe/Windows PowerShell from Task Manager.
EOF
}

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

image_path="$1"
shift

if [[ ! -e "$image_path" ]]; then
  echo "Image not found: $image_path" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ps_script="$(wslpath -w "$script_dir/show-overlay.ps1")"
win_image="$(wslpath -w "$image_path")"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps_script" -ImagePath "$win_image" "$@"
