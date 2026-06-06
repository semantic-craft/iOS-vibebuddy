#!/usr/bin/env python3
"""Generate the app icons (iOS + macOS): a code-drawn kawaii cat (ADR-0007).

The pet, the menu-bar mark and the home-screen/Dock icon all read as the *same*
black-and-white cat. The live pet is the literal pixel-cat sprite (`PetFace` /
`ActivityPixelCat`); this icon is a cleaner "hero" rendition — clear triangle
ears, two big green eyes, whiskers, a `:3` mouth — so it stays unmistakably a
cat when shrunk to a tile.

Both platforms use a flat, fully-opaque square raster (no alpha; iOS masks its
own corners, and the existing macOS set is full-bleed too). Each size is drawn
at 4x and downsampled for clean anti-aliased edges.

Run:  python3 VibeBuddyApp/Tools/make_app_icon.py
Out:  VibeBuddyApp/Sources/Assets.xcassets/AppIcon.appiconset/icon_1024.png
      VibeBuddyMacApp/Sources/Assets.xcassets/AppIcon.appiconset/icon_{16..1024}.png
"""

from pathlib import Path
from PIL import Image, ImageDraw

# Palette — the app's dark surface + status accents (see ADR-0007).
BG = (37, 41, 48)        # #252930 dark slate
WHITE = (247, 247, 248)  # the cat body
GREEN = (56, 205, 108)   # calm / "all good" accent → the eyes
PINK = (255, 138, 158)   # nose
WHISK = (120, 126, 136)  # whiskers + mouth

EYE = GREEN
SS = 4                   # supersample factor

REPO = Path(__file__).resolve().parents[2]
IOS_DIR = REPO / "VibeBuddyApp/Sources/Assets.xcassets/AppIcon.appiconset"
MAC_DIR = REPO / "VibeBuddyMacApp/Sources/Assets.xcassets/AppIcon.appiconset"


def render(px: int) -> Image.Image:
    """Draw the kawaii cat at `px` square (opaque, full-bleed)."""
    n = px * SS
    im = Image.new("RGB", (n, n), BG)
    d = ImageDraw.Draw(im)

    def s(v: float) -> int:
        return int(v * px / 1024 * SS)   # coords authored in a 1024 space

    cx = s(512)

    # Ears (behind the head): white outer triangle + accent inner.
    d.polygon([(s(250), s(360)), (s(300), s(150)), (s(430), s(300))], fill=WHITE)
    d.polygon([(s(774), s(360)), (s(724), s(150)), (s(594), s(300))], fill=WHITE)
    d.polygon([(s(300), s(345)), (s(318), s(228)), (s(388), s(305))], fill=EYE)
    d.polygon([(s(724), s(345)), (s(706), s(228)), (s(636), s(305))], fill=EYE)

    # Head.
    d.rounded_rectangle([s(232), s(300), s(792), s(820)], radius=s(180), fill=WHITE)

    # Eyes: big accent iris, dark pupil, white glint.
    for ex in (s(420), s(604)):
        d.ellipse([ex - s(56), s(470), ex + s(56), s(600)], fill=EYE)
        d.ellipse([ex - s(30), s(500), ex + s(30), s(585)], fill=BG)
        d.ellipse([ex - s(8), s(508), ex + s(20), s(540)], fill=WHITE)

    # Nose + ":3" mouth.
    d.polygon([(cx - s(26), s(628)), (cx + s(26), s(628)), (cx, s(660))], fill=PINK)
    d.arc([cx - s(60), s(648), cx, s(712)], start=20, end=160, fill=WHISK, width=max(1, s(7)))
    d.arc([cx, s(648), cx + s(60), s(712)], start=20, end=160, fill=WHISK, width=max(1, s(7)))

    # Whiskers (three per side).
    ww = max(1, s(6))
    for dy in (-s(18), s(18), s(54)):
        d.line([(s(250), s(612) + dy), (s(395), int(s(620) + dy * 0.4))], fill=WHISK, width=ww)
        d.line([(s(774), s(612) + dy), (s(629), int(s(620) + dy * 0.4))], fill=WHISK, width=ww)

    return im.resize((px, px), Image.LANCZOS)


def main() -> None:
    written = []
    # iOS: a single universal 1024.
    IOS_DIR.mkdir(parents=True, exist_ok=True)
    render(1024).save(IOS_DIR / "icon_1024.png")
    written.append("ios/icon_1024")
    # macOS: the full size ladder.
    MAC_DIR.mkdir(parents=True, exist_ok=True)
    for px in (16, 32, 64, 128, 256, 512, 1024):
        render(px).save(MAC_DIR / f"icon_{px}.png")
        written.append(f"mac/icon_{px}")
    print("wrote: " + ", ".join(written))


if __name__ == "__main__":
    main()
