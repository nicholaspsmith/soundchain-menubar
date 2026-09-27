#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Nicholas Smith

"""Generate SoundChain's app icon with Gemini, then cut it to macOS's shape.

The model paints the artwork; the geometry is done here, because that half is
not a matter of taste: macOS expects a superellipse tile of a particular size
inside a 1024px canvas, with clear space around it and no baked drop shadow.
Asking a model for "a rounded square" gets you a rounded square of its own
choosing, which reads wrong beside every other icon in the Dock.

Usage:
  python3 art/gen_app_icon.py              # generate, then build the .icns
  python3 art/gen_app_icon.py --reprocess  # rebuild from art/raw/app-icon.png

The API key is the same one the Menubarn site's mascot pipeline uses:
GOOGLE_GENERATIVE_AI_API_KEY in the environment, or the untracked .env in
../widgets.nicksmith.software. It is never printed.
"""
from __future__ import annotations

import base64
import json
import math
import subprocess
import sys
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "art" / "raw" / "app-icon.png"
ICONSET = ROOT / "art" / "SoundChain.iconset"
ICNS = ROOT / "Resources" / "bundle" / "AppIcon.icns"
PREVIEW = ROOT / "docs" / "app-icon.png"
API = "https://generativelanguage.googleapis.com/v1beta"
MODEL = "gemini-2.5-flash-image"

PROMPT = (
    "A macOS app icon illustration, square, filling the entire frame edge to edge with no "
    "border and no rounded corners — a full-bleed square painting.\n\n"
    "Subject: a cheerful plump green caterpillar with a long body of round glossy segments on "
    "tiny legs, a big round head with a friendly eye and rosy cheek, wearing chunky glossy black "
    "over-ear headphones with the band arching over its head, happily bobbing to music. A few "
    "soft glowing musical notes float in the air beside it. Behind it, a deep plum-to-magenta "
    "gradient sky, lighter at the top, with a soft warm halo around the caterpillar.\n\n"
    "Style: modern Apple-like app icon art — clean vector-smooth shapes, generous soft gradients, "
    "gentle rim light, subtle depth, no harsh outlines, no texture noise, no photographic detail. "
    "The caterpillar is centred and large in frame — it should occupy about two thirds of the "
    "width and height, so it stays readable when the icon is shown at 32 pixels.\n\n"
    "No text, no letters, no logos, no watermark, no border, no frame, no drop shadow around the "
    "artwork itself, and nothing resembling a rounded-rectangle tile inside the image."
)


def key() -> str:
    import os
    found = os.environ.get("GOOGLE_GENERATIVE_AI_API_KEY")
    if not found:
        env = ROOT.parent / "widgets.nicksmith.software" / ".env"
        if env.exists():
            for line in env.read_text().splitlines():
                if line.startswith("GOOGLE_GENERATIVE_AI_API_KEY="):
                    found = line.split("=", 1)[1].strip().strip("'\"")
    if not found:
        sys.exit("GOOGLE_GENERATIVE_AI_API_KEY is not set, and ../widgets.nicksmith.software/.env has no key.")
    return found.strip()


def generate() -> bytes:
    body = {"contents": [{"parts": [{"text": PROMPT}]}],
            "generationConfig": {"responseModalities": ["IMAGE"]}}
    request = urllib.request.Request(
        f"{API}/models/{MODEL}:generateContent?key={key()}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        payload = json.load(response)
    for candidate in payload.get("candidates", []):
        for part in candidate.get("content", {}).get("parts", []):
            data = part.get("inlineData", {}).get("data")
            if data:
                return base64.b64decode(data)
    sys.exit(f"no image in the response: {json.dumps(payload)[:400]}")


def squircle_mask(size: int, exponent: float = 5.6) -> Image.Image:
    """The tile's silhouette: a superellipse, drawn at 4x and downsampled so the
    curve has no stair-stepping. A plain rounded rectangle reads pinched at the
    corners next to the rest of the Dock."""
    scale = 4
    mask = Image.new("L", (size * scale, size * scale), 0)
    draw = ImageDraw.Draw(mask)
    a = b = size * scale / 2
    points = []
    for step in range(1441):
        t = step / 1440 * 2 * math.pi
        cos_t, sin_t = math.cos(t), math.sin(t)
        x = a + a * abs(cos_t) ** (2 / exponent) * (1 if cos_t >= 0 else -1)
        y = b + b * abs(sin_t) ** (2 / exponent) * (1 if sin_t >= 0 else -1)
        points.append((x, y))
    draw.polygon(points, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def compose(raw: bytes, size: int = 1024) -> Image.Image:
    """Crop the painting to the tile, mask it, and add the rim light macOS icons
    carry. Clear space is Apple's: the tile is 824/1024 of the canvas."""
    art = Image.open(__import__("io").BytesIO(raw)).convert("RGBA")
    side = min(art.size)
    art = art.crop(((art.width - side) // 2, (art.height - side) // 2,
                    (art.width + side) // 2, (art.height + side) // 2))

    tile_size = round(size * 824 / 1024)
    art = art.resize((tile_size, tile_size), Image.LANCZOS)

    mask = squircle_mask(tile_size)
    tile = Image.new("RGBA", (tile_size, tile_size), (0, 0, 0, 0))
    tile.paste(art, (0, 0), mask)

    # Rim light: the mask minus an inset copy of itself, so it follows the
    # squircle exactly rather than approximating it with a stroke.
    inset = 3 if size >= 512 else 2
    inner = squircle_mask(tile_size - inset * 2)
    ring = Image.new("L", (tile_size, tile_size), 0)
    ring.paste(mask, (0, 0))
    cut = Image.new("L", (tile_size, tile_size), 0)
    cut.paste(inner, (inset, inset))
    ring = Image.composite(Image.new("L", ring.size, 0), ring, cut)
    rim = Image.new("RGBA", (tile_size, tile_size), (255, 255, 255, 46))
    tile = Image.alpha_composite(tile, Image.composite(
        rim, Image.new("RGBA", tile.size, (0, 0, 0, 0)), ring.filter(ImageFilter.GaussianBlur(0.4))))

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(tile, ((size - tile_size) // 2, (size - tile_size) // 2), tile)
    return canvas


def main(argv: list[str]) -> None:
    RAW.parent.mkdir(parents=True, exist_ok=True)
    if "--reprocess" in argv:
        raw = RAW.read_bytes()
    else:
        print("generating with", MODEL, "...")
        raw = generate()
        RAW.write_bytes(raw)
        print("wrote", RAW.relative_to(ROOT))

    ICONSET.mkdir(parents=True, exist_ok=True)
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            suffix = "" if scale == 1 else "@2x"
            compose(raw, pixels).save(ICONSET / f"icon_{points}x{points}{suffix}.png")
    compose(raw, 1024).save(PREVIEW)

    ICNS.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)
    print("wrote", ICNS.relative_to(ROOT), "and", PREVIEW.relative_to(ROOT))


if __name__ == "__main__":
    main(sys.argv[1:])
