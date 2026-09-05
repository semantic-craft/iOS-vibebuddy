#!/usr/bin/env python3
"""Derive every app-icon asset from the one 1024 px master.

The master is the iOS icon itself:
    VibeBuddyApp/Sources/Assets.xcassets/AppIcon.appiconset/icon_1024.png
It is the white cat from the icon redesign (ip-as-logo skill, Nano Banana Pro,
candidate A1). Replace that file to change the brand, then run this script so
macOS, watchOS and the README renders follow.

Out:  VibeBuddyMacApp/Sources/Assets.xcassets/AppIcon.appiconset/icon_{16..1024}.png
      VibeBuddyApp/Watch/Assets.xcassets/AppIcon.appiconset/icon_1024.png
      docs/screenshots/app-icon-256.png   (macOS-rounded, transparent; README header)
      docs/screenshots/app-icon.png       (macOS / iPhone / Watch lineup; README)

Every catalog file is written as a genuine, fully opaque PNG: App Store Connect
rejects a mislabeled JPEG or an alpha channel in the marketing icon.

Run:  python3 VibeBuddyApp/Tools/make_app_icon.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = Path(__file__).resolve().parents[2]
MASTER = REPO / "VibeBuddyApp/Sources/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
MAC_DIR = REPO / "VibeBuddyMacApp/Sources/Assets.xcassets/AppIcon.appiconset"
WATCH_DIR = REPO / "VibeBuddyApp/Watch/Assets.xcassets/AppIcon.appiconset"
DOCS_DIR = REPO / "docs/screenshots"

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def load_master() -> Image.Image:
    data = MASTER.read_bytes()
    if not data.startswith(PNG_MAGIC):
        raise SystemExit(f"{MASTER} is not a PNG (re-encode it first)")
    im = Image.open(MASTER)
    if im.size != (1024, 1024):
        raise SystemExit(f"{MASTER} is {im.size}, expected 1024x1024")
    if im.mode not in ("RGB", "L", "P") and "A" in im.getbands():
        raise SystemExit(f"{MASTER} has an alpha channel; the marketing icon must be opaque")
    return im.convert("RGB")


def save_opaque_png(im: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    im.convert("RGB").save(path, format="PNG", optimize=True)


# --- README renders -----------------------------------------------------------

def squircle_mask(size: int, n: float = 5.0) -> Image.Image:
    """Superellipse |x|^n + |y|^n = 1, close to macOS's continuous-corner tile."""
    mask = Image.new("L", (size, size), 0)
    px = mask.load()
    r = size / 2
    for y in range(size):
        for x in range(size):
            v = abs((x + 0.5) / r - 1) ** n + abs((y + 0.5) / r - 1) ** n
            px[x, y] = 255 if v <= 1 else (int(255 * max(0.0, 1 - (v - 1) * 40)) if v < 1.03 else 0)
    return mask


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1], radius=radius * 4, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def circle_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, size * 4 - 1, size * 4 - 1], fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def masked_tile(master: Image.Image, size: int, mask: Image.Image) -> Image.Image:
    tile = master.resize((size, size), Image.LANCZOS).convert("RGBA")
    tile.putalpha(mask)
    return tile


def lineup(master: Image.Image) -> Image.Image:
    size, pad, gap, label_h = 256, 48, 72, 48
    tiles = [
        ("macOS", squircle_mask(size)),
        ("iPhone", rounded_mask(size, int(size * 0.2237))),
        ("Apple Watch", circle_mask(size)),
    ]
    width = pad * 2 + size * 3 + gap * 2
    height = pad * 2 + size + label_h
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 26)
    except OSError:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 26)
    x = pad
    for name, mask in tiles:
        shadow = Image.new("RGBA", (size + 40, size + 40), (0, 0, 0, 0))
        shadow_mask = Image.new("L", (size + 40, size + 40), 0)
        shadow_mask.paste(mask, (20, 28))
        shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(14))
        shadow.putalpha(shadow_mask.point(lambda v: int(v * 0.35)))
        canvas.alpha_composite(shadow, (x - 20, pad - 20))
        canvas.alpha_composite(masked_tile(master, size, mask), (x, pad))
        text_w = draw.textlength(name, font=font)
        draw.text((x + (size - text_w) / 2, pad + size + 14), name, fill=(110, 110, 110, 255), font=font)
        x += size + gap
    return canvas


def main() -> None:
    master = load_master()
    written = []

    for px in (16, 32, 64, 128, 256, 512, 1024):
        save_opaque_png(master.resize((px, px), Image.LANCZOS), MAC_DIR / f"icon_{px}.png")
        written.append(f"mac/icon_{px}")

    save_opaque_png(master, WATCH_DIR / "icon_1024.png")
    written.append("watch/icon_1024")

    DOCS_DIR.mkdir(parents=True, exist_ok=True)
    masked_tile(master, 256, squircle_mask(256)).save(DOCS_DIR / "app-icon-256.png", format="PNG", optimize=True)
    lineup(master).save(DOCS_DIR / "app-icon.png", format="PNG", optimize=True)
    written += ["docs/app-icon-256", "docs/app-icon"]

    print("wrote: " + ", ".join(written))


if __name__ == "__main__":
    main()
