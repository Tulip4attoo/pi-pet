#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pet_root="${PI_PET_PETS_DIR:-$script_dir/pets}"

usage() {
  cat <<'EOF'
Usage:
  ./pet-install.sh <petdex-url-or-slug>

Examples:
  ./pet-install.sh https://petdex.crafter.run/pets/luffy
  ./pet-install.sh luffy

Downloads a Petdex/Codex-compatible pet pack and installs it into:
  ./pets/<slug>/pet.json
  ./pets/<slug>/spritesheet.webp

Override install root with PI_PET_PETS_DIR=/path/to/pets.
EOF
}

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

python3 - "$1" "$pet_root" <<'PY'
import html
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile
import zlib
from pathlib import Path

raw_target = sys.argv[1].strip()
pet_root = Path(sys.argv[2]).expanduser().resolve()

if not raw_target:
    raise SystemExit("pet target is required")


def sanitize_slug(value: str) -> str:
    slug = value.strip().strip("/")
    if not slug or slug in {".", ".."} or not re.fullmatch(r"[A-Za-z0-9._-]+", slug):
        raise SystemExit(f"invalid pet slug: {value!r}")
    return slug


def slug_from_target(target: str) -> str:
    parsed = urllib.parse.urlparse(target)
    if parsed.scheme and parsed.netloc:
        parts = [urllib.parse.unquote(p) for p in parsed.path.split("/") if p]
        if "pets" in parts:
            idx = parts.index("pets")
            if idx + 1 < len(parts):
                return sanitize_slug(parts[idx + 1])
        if parts:
            return sanitize_slug(parts[-1])
        raise SystemExit(f"could not infer pet slug from URL: {target}")
    return sanitize_slug(target)


def fetch(url: str) -> bytes:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (pi-pet installer)",
            "Accept": "text/html,application/xhtml+xml,application/xml,application/zip,image/webp,*/*",
            "Referer": "https://petdex.crafter.run/",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read()


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def write_png_rgba(path: Path, width: int, height: int, rgba: bytes) -> None:
    rows = []
    stride = width * 4
    for y in range(height):
        rows.append(b"\x00" + rgba[y * stride : (y + 1) * stride])
    payload = b"".join(rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += png_chunk(b"IDAT", zlib.compress(payload, 9))
    png += png_chunk(b"IEND", b"")
    path.write_bytes(png)


def is_chroma_artifact(r: int, g: int, b: int, a: int) -> bool:
    # Petdex/Codex generated sheets often carry magenta/purple chroma garbage in
    # transparent areas. WPF's WebP/WIC path can show those pixels, so remove the
    # chroma family at install time. Keep the rule alpha-aware to avoid deleting
    # intentionally purple opaque pet details where possible.
    magenta_like = r > 85 and b > 70 and g < 90 and (r + b - 2 * g) > 115 and abs(r - b) < 125
    hot_pink = r > 180 and b > 140 and g < 110
    return (magenta_like or hot_pink) and a < 245


def clean_spritesheet_to_png(source: Path, output: Path) -> None:
    width = 1536
    height = 1872
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg not found; cannot decode WebP for clean PNG generation")

    raw = subprocess.check_output([
        ffmpeg,
        "-v", "error",
        "-i", str(source),
        "-f", "rawvideo",
        "-pix_fmt", "rgba",
        "-",
    ])
    expected = width * height * 4
    if len(raw) != expected:
        raise RuntimeError(f"decoded spritesheet has unexpected size: {len(raw)} bytes, expected {expected}")

    pixels = bytearray(raw)
    alpha_threshold = 96
    for index in range(0, len(pixels), 4):
        r, g, b, a = pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3]
        if a <= alpha_threshold or is_chroma_artifact(r, g, b, a):
            pixels[index] = 0
            pixels[index + 1] = 0
            pixels[index + 2] = 0
            pixels[index + 3] = 0

    write_png_rgba(output, width, height, bytes(pixels))


slug = slug_from_target(raw_target)
page_url = raw_target if urllib.parse.urlparse(raw_target).scheme else f"https://petdex.crafter.run/pets/{slug}"
page_text = fetch(page_url).decode("utf-8", "ignore")
page_text = html.unescape(page_text)

zip_patterns = [
    rf'https://[^"\\\s<>)]*/pets/{re.escape(slug)}-[^"\\\s<>)]*/zip\.zip',
    r'"zipUrl"\s*:\s*"(https://[^"\\]+/zip\.zip)"',
]
zip_url = None
for pattern in zip_patterns:
    match = re.search(pattern, page_text, re.IGNORECASE)
    if match:
        zip_url = match.group(1) if match.lastindex else match.group(0)
        break

if not zip_url:
    raise SystemExit(f"could not find Petdex zip URL on {page_url}")

zip_url = zip_url.replace("\\/", "/")
print(f"pi-pet: resolved {slug} -> {zip_url}")

zip_bytes = fetch(zip_url)
if len(zip_bytes) < 100:
    raise SystemExit("downloaded zip is unexpectedly small")

pet_root.mkdir(parents=True, exist_ok=True)
dest = pet_root / slug
with tempfile.TemporaryDirectory(prefix=f".{slug}-", dir=str(pet_root)) as tmp_name:
    tmp_dir = Path(tmp_name)
    zip_path = tmp_dir / "pack.zip"
    zip_path.write_bytes(zip_bytes)

    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
        if "pet.json" not in names:
            raise SystemExit("pet pack does not contain pet.json")
        pet_json = json.loads(zf.read("pet.json").decode("utf-8"))
        sprite_name = pet_json.get("spritesheetPath") or "spritesheet.webp"
        if sprite_name not in names:
            # Some community packs use sprite.webp but still render on Petdex.
            webp_names = [name for name in names if name.lower().endswith((".webp", ".png"))]
            if not webp_names:
                raise SystemExit("pet pack does not contain a spritesheet image")
            sprite_name = webp_names[0]
            pet_json["spritesheetPath"] = Path(sprite_name).name

        install_dir = tmp_dir / slug
        install_dir.mkdir(parents=True, exist_ok=True)
        source_sprite_name = Path(sprite_name).name
        source_sprite_path = install_dir / source_sprite_name
        source_sprite_path.write_bytes(zf.read(sprite_name))

        clean_sprite_name = "spritesheet.clean.png"
        try:
            clean_spritesheet_to_png(source_sprite_path, install_dir / clean_sprite_name)
            pet_json["sourceSpritesheetPath"] = source_sprite_name
            pet_json["spritesheetPath"] = clean_sprite_name
            print(f"pi-pet: wrote clean PNG {clean_sprite_name}")
        except Exception as error:
            print(f"pi-pet: warning: could not create clean PNG: {error}", file=sys.stderr)
            pet_json["spritesheetPath"] = source_sprite_name

        (install_dir / "pet.json").write_text(json.dumps(pet_json, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if dest.exists():
        shutil.rmtree(dest)
    shutil.move(str(tmp_dir / slug), str(dest))

active_path = pet_root / "active"
active_path.write_text(slug + "\n", encoding="utf-8")

print(f"pi-pet: installed {slug} into {dest}")
print(f"pi-pet: active pet set to {slug}")
print(dest / "pet.json")
print(dest / (json.loads((dest / "pet.json").read_text(encoding="utf-8")).get("spritesheetPath") or "spritesheet.webp"))
PY
