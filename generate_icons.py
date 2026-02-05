#!/usr/bin/env python3
"""Generate Ghostly app icon and menu bar icon — Pac-Man ghost style."""

from PIL import Image, ImageDraw
import math
import os

BASE = "/Users/kbd606/Downloads/ghostly/Ghostly/Ghostly/Assets.xcassets"


def pacman_ghost_points(size, margin_pct=0.12):
    """Classic Pac-Man ghost: dome top, straight sides, zigzag bottom."""
    s = size
    m = s * margin_pct
    cx = s / 2

    left = m
    right = s - m
    width = right - left
    top = m * 1.2
    bottom = s - m * 0.8

    dome_radius = width / 2
    dome_cy = top + dome_radius

    points = []

    # Start at bottom-left, go up the left side
    points.append((left, bottom))
    points.append((left, dome_cy))

    # Dome: semicircle left to right
    steps = 40
    for i in range(steps + 1):
        angle = math.pi + (math.pi * i / steps)
        x = cx + dome_radius * math.cos(angle)
        y = dome_cy + dome_radius * math.sin(angle)
        points.append((x, y))

    # Right side down
    points.append((right, dome_cy))
    points.append((right, bottom))

    # Zigzag bottom: 3 teeth (classic pac-man ghost has 3)
    teeth = 3
    tooth_w = width / teeth
    tooth_h = s * 0.10

    for i in range(teeth):
        tx = right - i * tooth_w
        # Valley (go up)
        points.append((tx - tooth_w * 0.5, bottom - tooth_h))
        # Next peak (go down)
        points.append((tx - tooth_w, bottom))

    return points


def draw_pacman_ghost(draw, size, body_color, margin_pct=0.12):
    """Draw a Pac-Man style ghost body."""
    points = pacman_ghost_points(size, margin_pct)
    draw.polygon(points, fill=body_color)


def draw_pacman_eyes(draw, size, eye_white, pupil_color, margin_pct=0.12):
    """Classic Pac-Man ghost eyes: large white ovals with blue pupils."""
    s = size
    m = s * margin_pct
    cx = s / 2
    width = s - 2 * m
    dome_radius = width / 2
    dome_cy = m * 1.2 + dome_radius

    # Eye position
    eye_y = dome_cy + s * 0.03
    eye_sep = s * 0.155

    # White eye size (tall ovals like pac-man ghosts)
    ew = s * 0.105
    eh = s * 0.13

    for ex in [cx - eye_sep, cx + eye_sep]:
        # White
        draw.ellipse(
            [ex - ew, eye_y - eh, ex + ew, eye_y + eh],
            fill=eye_white,
        )
        # Pupil (shifted slightly to one direction for character)
        pw = ew * 0.6
        ph = eh * 0.65
        offset_x = ew * 0.2  # looking right
        offset_y = eh * 0.1   # looking slightly down
        draw.ellipse(
            [ex - pw + offset_x, eye_y - ph + offset_y,
             ex + pw + offset_x, eye_y + ph + offset_y],
            fill=pupil_color,
        )


def generate_app_icon(size, filename):
    """Generate app icon with Pac-Man ghost on dark background."""
    s = size
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    padding = max(1, int(s * 0.04))
    corner_radius = max(1, int(s * 0.22))

    # Background gradient: deep indigo
    bg = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    bg_draw = ImageDraw.Draw(bg)

    bg_draw.rounded_rectangle(
        [padding, padding, s - padding, s - padding],
        radius=corner_radius,
        fill=(25, 20, 50, 255),
    )

    # Apply vertical gradient
    for y in range(padding, s - padding):
        frac = (y - padding) / max(1, s - 2 * padding)
        r = int(35 - 15 * frac)
        g = int(28 - 12 * frac)
        b = int(65 - 20 * frac)
        for x in range(padding, s - padding):
            px = bg.getpixel((x, y))
            if px[3] > 0:
                bg.putpixel((x, y), (r, g, b, 255))

    img = Image.alpha_composite(img, bg)

    # Subtle glow behind ghost
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    glow_d = ImageDraw.Draw(glow)
    draw_pacman_ghost(glow_d, s, (160, 180, 255, 35), margin_pct=0.10)
    img = Image.alpha_composite(img, glow)

    # Ghost body — light blue/lavender (classic cyan-ish ghost)
    ghost = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    gd = ImageDraw.Draw(ghost)
    draw_pacman_ghost(gd, s, (140, 180, 255, 240), margin_pct=0.15)

    # Eyes
    draw_pacman_eyes(gd, s,
                     eye_white=(255, 255, 255, 255),
                     pupil_color=(30, 40, 120, 255),
                     margin_pct=0.15)

    img = Image.alpha_composite(img, ghost)
    img.save(filename, "PNG")


def generate_menu_bar_icon(size, filename):
    """Template menu bar icon: black Pac-Man ghost with cutout eyes."""
    s = size
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Solid black ghost
    draw_pacman_ghost(draw, s, (0, 0, 0, 200), margin_pct=0.06)

    # Cut out eyes (transparent = creates "holes")
    m = s * 0.06
    cx = s / 2
    width = s - 2 * m
    dome_radius = width / 2
    dome_cy = m * 1.2 + dome_radius

    eye_y = dome_cy + s * 0.03
    eye_sep = s * 0.155
    ew = s * 0.09
    eh = s * 0.11

    for ex in [cx - eye_sep, cx + eye_sep]:
        draw.ellipse(
            [ex - ew, eye_y - eh, ex + ew, eye_y + eh],
            fill=(0, 0, 0, 0),
        )

    img.save(filename, "PNG")


# --- Generate ---
app_icon_dir = os.path.join(BASE, "AppIcon.appiconset")
for sz in [16, 32, 64, 128, 256, 512, 1024]:
    generate_app_icon(sz, os.path.join(app_icon_dir, f"icon_{sz}x{sz}.png"))
    print(f"  AppIcon: {sz}x{sz}")

menu_icon_dir = os.path.join(BASE, "MenuBarIcon.imageset")
generate_menu_bar_icon(18, os.path.join(menu_icon_dir, "menubar_icon.png"))
generate_menu_bar_icon(36, os.path.join(menu_icon_dir, "menubar_icon@2x.png"))
generate_menu_bar_icon(54, os.path.join(menu_icon_dir, "menubar_icon@3x.png"))
print("  MenuBarIcon: 18/36/54")
print("Done!")
