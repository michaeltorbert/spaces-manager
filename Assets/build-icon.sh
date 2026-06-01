#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

python3 - <<'PY'
from __future__ import annotations

from io import BytesIO
from pathlib import Path
import struct

from PIL import Image, ImageDraw, ImageFilter

OUT_DIR = Path(__file__).resolve().parent
SVG_PATH = OUT_DIR / "AppIcon.svg"
ICNS_PATH = OUT_DIR / "AppIcon.icns"

SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc">
  <title id="title">SpacesManager app icon</title>
  <desc id="desc">A rounded macOS-style icon with overlapping Mission Control spaces and one highlighted named space.</desc>
  <defs>
    <linearGradient id="background" x1="140" y1="96" x2="884" y2="936" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#1d2632"/>
      <stop offset="0.56" stop-color="#233746"/>
      <stop offset="1" stop-color="#17545b"/>
    </linearGradient>
    <linearGradient id="active" x1="344" y1="350" x2="704" y2="630" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#5ee2b0"/>
      <stop offset="1" stop-color="#2f8fd3"/>
    </linearGradient>
    <linearGradient id="warm" x1="188" y1="570" x2="468" y2="768" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#ffd36c"/>
      <stop offset="1" stop-color="#ff8e57"/>
    </linearGradient>
    <linearGradient id="cool" x1="556" y1="214" x2="810" y2="392" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#94a3ff"/>
      <stop offset="1" stop-color="#5e6ad2"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="150%">
      <feDropShadow dx="0" dy="24" stdDeviation="22" flood-color="#071119" flood-opacity="0.45"/>
    </filter>
  </defs>
  <rect x="64" y="64" width="896" height="896" rx="206" fill="url(#background)"/>
  <path d="M170 703c128-12 202 69 331 48 154-26 207-156 360-107v145c0 48-39 87-87 87H253c-46 0-83-37-83-83Z" fill="#0f2630" opacity=".35"/>
  <g filter="url(#shadow)">
    <rect x="214" y="236" width="254" height="178" rx="36" fill="#f7fbff" opacity=".92"/>
    <rect x="250" y="272" width="93" height="106" rx="22" fill="#c9d5e3"/>
    <rect x="365" y="272" width="67" height="106" rx="22" fill="#aab8c9"/>
  </g>
  <g filter="url(#shadow)">
    <rect x="556" y="214" width="254" height="178" rx="36" fill="url(#cool)"/>
    <rect x="592" y="250" width="182" height="16" rx="8" fill="#fff" opacity=".58"/>
    <rect x="592" y="292" width="124" height="16" rx="8" fill="#fff" opacity=".42"/>
  </g>
  <g filter="url(#shadow)">
    <rect x="187" y="570" width="282" height="198" rx="40" fill="url(#warm)"/>
    <rect x="229" y="611" width="198" height="22" rx="11" fill="#fff" opacity=".58"/>
    <rect x="229" y="664" width="140" height="22" rx="11" fill="#fff" opacity=".4"/>
  </g>
  <g filter="url(#shadow)">
    <rect x="342" y="356" width="370" height="260" rx="54" fill="url(#active)"/>
    <rect x="388" y="405" width="278" height="28" rx="14" fill="#fff" opacity=".72"/>
    <rect x="388" y="466" width="183" height="28" rx="14" fill="#fff" opacity=".48"/>
    <rect x="388" y="526" width="112" height="28" rx="14" fill="#fff" opacity=".36"/>
    <path d="M617 546l91 79-56 8-21 51-43-121z" fill="#fff" opacity=".95"/>
  </g>
  <rect x="64" y="64" width="896" height="896" rx="206" fill="none" stroke="#fff" stroke-opacity=".12" stroke-width="4"/>
</svg>
"""

SCALE = 3
BASE_SIZE = 1024
CANVAS_SIZE = BASE_SIZE * SCALE


def sc(value: int | float) -> int:
    return int(round(value * SCALE))


def rgb(hex_color: str, alpha: int = 255) -> tuple[int, int, int, int]:
    value = hex_color.lstrip("#")
    return tuple(int(value[index : index + 2], 16) for index in (0, 2, 4)) + (alpha,)


def lerp(a: int, b: int, t: float) -> int:
    return int(round(a + (b - a) * t))


def gradient(size: tuple[int, int], stops: list[tuple[float, str]], start: tuple[float, float], end: tuple[float, float]) -> Image.Image:
    width, height = size
    image = Image.new("RGBA", size)
    pixels = image.load()
    sx, sy = start[0] * width, start[1] * height
    ex, ey = end[0] * width, end[1] * height
    vx, vy = ex - sx, ey - sy
    denom = vx * vx + vy * vy or 1
    colors = [(position, rgb(color)) for position, color in stops]

    for y in range(height):
        for x in range(width):
            t = ((x - sx) * vx + (y - sy) * vy) / denom
            t = min(1, max(0, t))
            for index in range(len(colors) - 1):
                p0, c0 = colors[index]
                p1, c1 = colors[index + 1]
                if t <= p1:
                    local = 0 if p0 == p1 else (t - p0) / (p1 - p0)
                    pixels[x, y] = tuple(lerp(c0[channel], c1[channel], local) for channel in range(4))
                    break
            else:
                pixels[x, y] = colors[-1][1]

    return image


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


def paste_rounded(base: Image.Image, layer: Image.Image, box: tuple[int, int, int, int], radius: int, shadow: bool = True) -> None:
    x0, y0, x1, y1 = [sc(value) for value in box]
    width, height = x1 - x0, y1 - y0
    mask = rounded_mask((width, height), sc(radius))

    if shadow:
        shadow_layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
        shadow_color = Image.new("RGBA", (width, height), (5, 15, 22, 118))
        shadow_layer.paste(shadow_color, (x0, y0), mask)
        shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(sc(18)))
        base.alpha_composite(shadow_layer, (0, sc(18)))

    if layer.size != (width, height):
        layer = layer.resize((width, height), Image.Resampling.LANCZOS)
    base.paste(layer, (x0, y0), mask)


def rounded_rect(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], radius: int, fill: tuple[int, int, int, int]) -> None:
    draw.rounded_rectangle(tuple(sc(value) for value in box), radius=sc(radius), fill=fill)


def render_icon() -> Image.Image:
    background = gradient(
        (CANVAS_SIZE, CANVAS_SIZE),
        [(0, "#1d2632"), (0.56, "#233746"), (1, "#17545b")],
        start=(0.14, 0.09),
        end=(0.86, 0.91),
    )
    icon = Image.new("RGBA", (CANVAS_SIZE, CANVAS_SIZE), (0, 0, 0, 0))
    icon.paste(
        background.crop((sc(64), sc(64), sc(960), sc(960))),
        (sc(64), sc(64)),
        rounded_mask((sc(896), sc(896)), sc(206)),
    )

    wave = Image.new("RGBA", (CANVAS_SIZE, CANVAS_SIZE), (0, 0, 0, 0))
    wave_draw = ImageDraw.Draw(wave)
    wave_draw.polygon(
        [
            (sc(170), sc(703)),
            (sc(298), sc(691)),
            (sc(372), sc(772)),
            (sc(501), sc(751)),
            (sc(655), sc(725)),
            (sc(708), sc(595)),
            (sc(861), sc(644)),
            (sc(861), sc(876)),
            (sc(170), sc(876)),
        ],
        fill=(15, 38, 48, 90),
    )
    icon.alpha_composite(wave)

    paste_rounded(icon, Image.new("RGBA", (sc(254), sc(178)), (247, 251, 255, 235)), (214, 236, 468, 414), 36)
    draw = ImageDraw.Draw(icon)
    rounded_rect(draw, (250, 272, 343, 378), 22, (201, 213, 227, 255))
    rounded_rect(draw, (365, 272, 432, 378), 22, (170, 184, 201, 255))

    cool = gradient((sc(254), sc(178)), [(0, "#94a3ff"), (1, "#5e6ad2")], start=(0.1, 0), end=(0.9, 1))
    paste_rounded(icon, cool, (556, 214, 810, 392), 36)
    draw = ImageDraw.Draw(icon)
    rounded_rect(draw, (592, 250, 774, 266), 8, (255, 255, 255, 148))
    rounded_rect(draw, (592, 292, 716, 308), 8, (255, 255, 255, 108))

    warm = gradient((sc(282), sc(198)), [(0, "#ffd36c"), (1, "#ff8e57")], start=(0.1, 0), end=(0.9, 1))
    paste_rounded(icon, warm, (187, 570, 469, 768), 40)
    draw = ImageDraw.Draw(icon)
    rounded_rect(draw, (229, 611, 427, 633), 11, (255, 255, 255, 148))
    rounded_rect(draw, (229, 664, 369, 686), 11, (255, 255, 255, 104))

    active = gradient((sc(370), sc(260)), [(0, "#5ee2b0"), (1, "#2f8fd3")], start=(0, 0), end=(1, 1))
    paste_rounded(icon, active, (342, 356, 712, 616), 54)
    draw = ImageDraw.Draw(icon)
    rounded_rect(draw, (388, 405, 666, 433), 14, (255, 255, 255, 184))
    rounded_rect(draw, (388, 466, 571, 494), 14, (255, 255, 255, 122))
    rounded_rect(draw, (388, 526, 500, 554), 14, (255, 255, 255, 92))
    draw.polygon(
        [(sc(617), sc(546)), (sc(708), sc(625)), (sc(652), sc(633)), (sc(631), sc(684)), (sc(588), sc(563))],
        fill=(255, 255, 255, 242),
    )
    draw.rounded_rectangle((sc(64), sc(64), sc(960), sc(960)), radius=sc(206), outline=(255, 255, 255, 31), width=sc(4))

    return icon.resize((BASE_SIZE, BASE_SIZE), Image.Resampling.LANCZOS)


def png_bytes(image: Image.Image, size: int) -> bytes:
    output = BytesIO()
    image.resize((size, size), Image.Resampling.LANCZOS).save(output, "PNG")
    return output.getvalue()


def write_icns(image: Image.Image, path: Path) -> None:
    entries = [
        (b"icp4", png_bytes(image, 16)),
        (b"icp5", png_bytes(image, 32)),
        (b"ic11", png_bytes(image, 32)),
        (b"ic12", png_bytes(image, 64)),
        (b"ic07", png_bytes(image, 128)),
        (b"ic13", png_bytes(image, 256)),
        (b"ic08", png_bytes(image, 256)),
        (b"ic14", png_bytes(image, 512)),
        (b"ic09", png_bytes(image, 512)),
        (b"ic10", png_bytes(image, 1024)),
    ]
    blocks = [(icon_type, struct.pack(">4sI", icon_type, 8 + len(data)) + data) for icon_type, data in entries]
    toc_payload = b"".join(struct.pack(">4sI", icon_type, len(block)) for icon_type, block in blocks)
    toc = struct.pack(">4sI", b"TOC ", 8 + len(toc_payload)) + toc_payload
    body = toc + b"".join(block for _, block in blocks)
    path.write_bytes(struct.pack(">4sI", b"icns", 8 + len(body)) + body)


SVG_PATH.write_text(SVG)
write_icns(render_icon(), ICNS_PATH)
print(f"Wrote {SVG_PATH}")
print(f"Wrote {ICNS_PATH}")
PY
