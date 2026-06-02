#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from shutil import copyfile

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs" / "screenshots"
PUBLIC_REMOTION = ROOT / "public" / "remotion"
CAT_MENU = ROOT / "src-tauri" / "icons" / "anim-cat2"
CAT_TRAY = ROOT / "src-tauri" / "icons" / "anim-cat2-light"


def font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
    ]
    for candidate in candidates:
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            continue
    return ImageFont.load_default()


def load_frames(src: Path, size: tuple[int, int]) -> list[Image.Image]:
    frames: list[Image.Image] = []
    for path in sorted(src.glob("frame-*.png")):
        frame = Image.open(path).convert("RGBA")
        frame = frame.resize(size, Image.Resampling.LANCZOS)
        frames.append(frame)
    if not frames:
        raise RuntimeError(f"No frame-*.png files in {src}")
    return frames


def save_gif(frames: list[Image.Image], out: Path, duration_ms: int) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        out,
        save_all=True,
        append_images=frames[1:],
        duration=duration_ms,
        loop=0,
        disposal=2,
        optimize=False,
    )


def render_tray_cat() -> None:
    source = load_frames(CAT_TRAY, (96, 96))
    frames: list[Image.Image] = []
    for cat in source:
        canvas = Image.new("RGBA", (128, 96), (255, 255, 255, 255))
        canvas.alpha_composite(cat, ((canvas.width - cat.width) // 2, 0))
        frames.append(canvas.convert("P", palette=Image.Palette.ADAPTIVE, colors=64))
    save_gif(frames, DOCS / "tray-anim-cat2.gif", 90)


def render_menubar_cat() -> None:
    source = load_frames(CAT_MENU, (54, 54))
    text_font = font(31)
    label = "$425.82"
    frames: list[Image.Image] = []
    for cat in source:
        canvas = Image.new("RGBA", (260, 72), (31, 31, 34, 255))
        canvas.alpha_composite(cat, (13, 9))
        draw = ImageDraw.Draw(canvas)
        draw.text((82, 15), label, fill=(246, 246, 248, 255), font=text_font)
        frames.append(canvas.convert("P", palette=Image.Palette.ADAPTIVE, colors=96))
    save_gif(frames, DOCS / "menubar-cat2.gif", 90)
    PUBLIC_REMOTION.mkdir(parents=True, exist_ok=True)
    copyfile(DOCS / "menubar-cat2.gif", PUBLIC_REMOTION / "menubar-cat2.gif")


def main() -> None:
    render_tray_cat()
    render_menubar_cat()


if __name__ == "__main__":
    main()
