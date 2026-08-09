#!/usr/bin/env python3
"""Render and validate representative first-run setup states.

Welcome, Units, and Enjoy are drawn side by side from the six-step source
contract.  Colours and step names are read from the Luau files, so this image
cannot quietly advertise a different progress sequence or accent from Studio.

    python setup_wizard_preview.py --check
    python setup_wizard_preview.py --out out/setup-wizard.png
"""

import argparse
from dataclasses import dataclass, replace
import os
from pathlib import Path
import re
import sys

from raster import Canvas


ROOT = Path(__file__).resolve().parents[2]
WIZARD_SOURCE = (ROOT / "src/UI/SetupWizard.lua").read_text(encoding="utf-8")
THEME_SOURCE = (ROOT / "src/UI/Theme.lua").read_text(encoding="utf-8")


def rgb_from_source(source, expression):
    match = re.search(expression + r"\s*=\s*Color3\.fromRGB\((\d+),\s*(\d+),\s*(\d+)\)", source)
    if not match:
        raise AssertionError(f"could not read {expression} colour from source")
    return tuple(int(value) for value in match.groups())


def steps_from_source(source):
    match = re.search(r"local STEP_NAMES = \{(.*?)\n\}", source, re.S)
    if not match:
        raise AssertionError("SetupWizard.lua has no STEP_NAMES table")
    return tuple(re.findall(r'"([^"]+)"', match.group(1)))


STEPS = steps_from_source(WIZARD_SOURCE)
ACCENT = rgb_from_source(THEME_SOURCE, r"Theme\.ACCENT")
FIELD = rgb_from_source(THEME_SOURCE, r"Theme\.FIELD")
WHITE = rgb_from_source(THEME_SOURCE, r"Theme\.WHITE")
DIM = rgb_from_source(THEME_SOURCE, r"Theme\.DIM")
BACKGROUND = rgb_from_source(WIZARD_SOURCE, r"local BACKGROUND")
SECTION = rgb_from_source(WIZARD_SOURCE, r"local SECTION")
OFFWHITE = (204, 204, 204)
CANVAS_BG = (20, 24, 31)
STROKE = (73, 77, 84)


GLYPHS = {
    " ": ("00000",) * 7,
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "B": ("11110", "10001", "10001", "11110", "10001", "10001", "11110"),
    "C": ("01111", "10000", "10000", "10000", "10000", "10000", "01111"),
    "D": ("11110", "10001", "10001", "10001", "10001", "10001", "11110"),
    "E": ("11111", "10000", "10000", "11110", "10000", "10000", "11111"),
    "F": ("11111", "10000", "10000", "11110", "10000", "10000", "10000"),
    "G": ("01111", "10000", "10000", "10111", "10001", "10001", "01110"),
    "H": ("10001", "10001", "10001", "11111", "10001", "10001", "10001"),
    "I": ("11111", "00100", "00100", "00100", "00100", "00100", "11111"),
    "J": ("00111", "00010", "00010", "00010", "10010", "10010", "01100"),
    "K": ("10001", "10010", "10100", "11000", "10100", "10010", "10001"),
    "L": ("10000", "10000", "10000", "10000", "10000", "10000", "11111"),
    "M": ("10001", "11011", "10101", "10101", "10001", "10001", "10001"),
    "N": ("10001", "11001", "10101", "10011", "10001", "10001", "10001"),
    "O": ("01110", "10001", "10001", "10001", "10001", "10001", "01110"),
    "P": ("11110", "10001", "10001", "11110", "10000", "10000", "10000"),
    "Q": ("01110", "10001", "10001", "10001", "10101", "10010", "01101"),
    "R": ("11110", "10001", "10001", "11110", "10100", "10010", "10001"),
    "S": ("01111", "10000", "10000", "01110", "00001", "00001", "11110"),
    "T": ("11111", "00100", "00100", "00100", "00100", "00100", "00100"),
    "U": ("10001", "10001", "10001", "10001", "10001", "10001", "01110"),
    "V": ("10001", "10001", "10001", "10001", "10001", "01010", "00100"),
    "W": ("10001", "10001", "10001", "10101", "10101", "11011", "10001"),
    "X": ("10001", "10001", "01010", "00100", "01010", "10001", "10001"),
    "Y": ("10001", "10001", "01010", "00100", "00100", "00100", "00100"),
    "Z": ("11111", "00001", "00010", "00100", "01000", "10000", "11111"),
    "0": ("01110", "10001", "10011", "10101", "11001", "10001", "01110"),
    "1": ("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
    "2": ("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
    "3": ("11110", "00001", "00001", "01110", "00001", "00001", "11110"),
    "4": ("00010", "00110", "01010", "10010", "11111", "00010", "00010"),
    "5": ("11111", "10000", "10000", "11110", "00001", "00001", "11110"),
    "6": ("01110", "10000", "10000", "11110", "10001", "10001", "01110"),
    "7": ("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
    "8": ("01110", "10001", "10001", "01110", "10001", "10001", "01110"),
    "9": ("01110", "10001", "10001", "01111", "00001", "00001", "01110"),
    "-": ("00000", "00000", "00000", "11111", "00000", "00000", "00000"),
    "/": ("00001", "00010", "00010", "00100", "01000", "01000", "10000"),
    ":": ("00000", "00100", "00100", "00000", "00100", "00100", "00000"),
    "!": ("00100", "00100", "00100", "00100", "00100", "00000", "00100"),
    ".": ("00000", "00000", "00000", "00000", "00000", "00110", "00110"),
    ">": ("10000", "01000", "00100", "00010", "00100", "01000", "10000"),
}


def rect(canvas, left, top, right, bottom, colour):
    canvas.fill_poly([(left, top), (right, top), (right, bottom), (left, bottom)], colour)


def outline(canvas, left, top, right, bottom, colour, width=1):
    canvas.line((left, top), (right, top), colour, width)
    canvas.line((right, top), (right, bottom), colour, width)
    canvas.line((right, bottom), (left, bottom), colour, width)
    canvas.line((left, bottom), (left, top), colour, width)


def draw_text(canvas, x, y, value, colour, scale=1):
    cursor = int(x)
    for character in value.upper():
        glyph = GLYPHS.get(character, GLYPHS[" "])
        for row, bits in enumerate(glyph):
            for column, bit in enumerate(bits):
                if bit == "1":
                    rect(
                        canvas,
                        cursor + column * scale,
                        y + row * scale,
                        cursor + (column + 1) * scale,
                        y + (row + 1) * scale,
                        colour,
                    )
        cursor += 6 * scale
    return cursor


@dataclass(frozen=True)
class WizardState:
    step: int
    name: str
    progress: float
    show_skip: bool
    accent: tuple


def state_for(step, steps=STEPS, accent=ACCENT, denominator=None, force_skip=None):
    total = len(steps) if denominator is None else denominator
    show_skip = step < len(steps) if force_skip is None else force_skip
    return WizardState(step, steps[step - 1], step / total, show_skip, accent)


def wizard_faults(steps=STEPS, accent=ACCENT, denominator=None, final_skip=False):
    faults = []
    if steps != ("Welcome", "Region", "Terminology", "Traffic side", "Units", "Enjoy"):
        faults.append("setup steps no longer match the first-run contract")
        return faults
    states = [state_for(index, steps, accent, denominator) for index in range(1, len(steps) + 1)]
    if any(state.progress <= 0 or state.progress > 1 for state in states):
        faults.append("setup progress leaves the 0..1 track")
    if any(b.progress <= a.progress for a, b in zip(states, states[1:])):
        faults.append("setup progress does not advance every step")
    if abs(states[-1].progress - 1.0) > 1e-12:
        faults.append("Enjoy does not fill the progress bar")
    if accent != ACCENT:
        faults.append("setup progress does not use Theme.ACCENT")
    if final_skip or states[-1].show_skip:
        faults.append("Enjoy still offers Skip setup")
    if not all(token in WIZARD_SOURCE for token in ('Title = "Roblox"', 'Title = "Metric"', 'Title = "Imperial"')):
        faults.append("units step does not offer Roblox, metric, and imperial")
    if 'Title = "Enjoy!"' not in WIZARD_SOURCE:
        faults.append("setup has no Enjoy completion page")
    if "Size = UDim2.fromScale(1, 1)" not in WIZARD_SOURCE:
        faults.append("setup root does not fill the host viewport")
    return faults


def check():
    faults = wizard_faults()
    if faults:
        raise AssertionError("; ".join(faults))
    breaks = (
        lambda: wizard_faults(steps=STEPS[:-1] + ("Done",)),
        lambda: wizard_faults(denominator=len(STEPS) + 1),
        lambda: wizard_faults(denominator=len(STEPS) - 1),
        lambda: wizard_faults(accent=(255, 255, 255)),
        lambda: wizard_faults(final_skip=True),
    )
    for index, fault_case in enumerate(breaks, start=1):
        if not fault_case():
            raise AssertionError(f"setup wizard break-test {index} escaped")
    return len(breaks)


def button(canvas, x, y, width, label, selected=False):
    colour = ACCENT if selected else FIELD
    rect(canvas, x, y, x + width, y + 29, colour)
    outline(canvas, x, y, x + width, y + 29, ACCENT if selected else STROKE)
    draw_text(canvas, x + 10, y + 10, label, WHITE, 1)


def choice(canvas, x, y, width, title, detail, selected=False):
    rect(canvas, x, y, x + width, y + 52, FIELD)
    outline(canvas, x, y, x + width, y + 52, ACCENT if selected else STROKE, 2 if selected else 1)
    canvas.ring(x + 18, y + 26, 5, 7, ACCENT if selected else DIM)
    if selected:
        canvas.disc(x + 18, y + 26, 3, WHITE)
    draw_text(canvas, x + 34, y + 11, title, WHITE, 1)
    draw_text(canvas, x + 34, y + 31, detail, OFFWHITE, 1)


def summary_row(canvas, x, y, width, label, value):
    rect(canvas, x, y, x + width, y + 39, FIELD)
    draw_text(canvas, x + 10, y + 6, label, DIM, 1)
    draw_text(canvas, x + 10, y + 23, value, WHITE, 1)


def render_state(canvas, state, left, top, width, height):
    rect(canvas, left, top, left + width, top + height, BACKGROUND)
    outline(canvas, left, top, left + width, top + height, STROKE)
    pad = 22
    x = left + pad
    right = left + width - pad
    draw_text(canvas, x, top + 18, "EASYROAD", ACCENT, 2)
    draw_text(canvas, x, top + 39, "QUICK SETUP", DIM, 1)
    if state.show_skip:
        button(canvas, right - 91, top + 15, 91, "SKIP SETUP")

    label = f"STEP {state.step} OF {len(STEPS)} - {state.name}"
    draw_text(canvas, x, top + 72, label, OFFWHITE, 1)
    track_top = top + 91
    rect(canvas, x, track_top, right, track_top + 6, FIELD)
    rect(canvas, x, track_top, x + (right - x) * state.progress, track_top + 6, state.accent)

    content_top = top + 116
    content_bottom = top + height - 68
    rect(canvas, x, content_top, right, content_bottom, SECTION)
    outline(canvas, x, content_top, right, content_bottom, STROKE)
    cx = x + 22
    content_width = right - x - 44

    if state.name == "Welcome":
        draw_text(canvas, cx, content_top + 24, "SET UP EASYROAD", WHITE, 2)
        draw_text(canvas, cx, content_top + 66, "CHOOSE DEFAULTS THAT MATCH", OFFWHITE, 1)
        draw_text(canvas, cx, content_top + 82, "THE ROADS YOU BUILD.", OFFWHITE, 1)
        rect(canvas, cx, content_top + 118, cx + content_width, content_top + 180, FIELD)
        draw_text(canvas, cx + 14, content_top + 134, "REGION  TERMINOLOGY", DIM, 1)
        draw_text(canvas, cx + 14, content_top + 153, "TRAFFIC SIDE  UNITS", WHITE, 1)
    elif state.name == "Units":
        draw_text(canvas, cx, content_top + 22, "HOW SHOULD", WHITE, 2)
        draw_text(canvas, cx, content_top + 42, "MEASUREMENTS APPEAR?", WHITE, 2)
        choice(canvas, cx, content_top + 82, content_width, "ROBLOX", "STUDS AND STUDS/S")
        choice(canvas, cx, content_top + 142, content_width, "METRIC", "METRES AND KM/H", True)
        choice(canvas, cx, content_top + 202, content_width, "IMPERIAL", "FEET AND MPH")
    else:
        draw_text(canvas, cx, content_top + 22, "ENJOY!", ACCENT, 3)
        draw_text(canvas, cx, content_top + 57, "EASYROAD IS READY.", OFFWHITE, 1)
        summary_row(canvas, cx, content_top + 83, content_width, "REGIONAL STANDARD", "UNITED KINGDOM")
        summary_row(canvas, cx, content_top + 127, content_width, "TERMINOLOGY", "BRITISH ENGLISH")
        summary_row(canvas, cx, content_top + 171, content_width, "TRAFFIC SIDE", "FOLLOW REGION")
        summary_row(canvas, cx, content_top + 215, content_width, "DISPLAY UNITS", "METRIC")

    footer_y = top + height - 48
    if state.step > 1:
        button(canvas, right - 196, footer_y, 88, "BACK")
    button(canvas, right - 100, footer_y, 100, "FINISH" if state.name == "Enjoy" else "CONTINUE", True)


def render(path):
    breaks = check()
    canvas = Canvas(1480, 620, CANVAS_BG)
    margin = 20
    gap = 15
    width = (canvas.w - 2 * margin - 2 * gap) / 3
    height = canvas.h - 2 * margin
    for column, step in enumerate((1, 5, 6)):
        render_state(
            canvas,
            state_for(step),
            margin + column * (width + gap),
            margin,
            width,
            height,
        )
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    canvas.save(path)
    return breaks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--out")
    args = parser.parse_args()
    breaks = check()
    if args.out:
        render(args.out)
        print(f"wrote {args.out}: Welcome 1/6, Units 5/6, Enjoy 6/6")
    else:
        print(
            f"setup wizard checks passed: {len(STEPS)} source steps, "
            f"Theme.ACCENT={ACCENT}, final progress=1.0; {breaks} injected break-tests caught"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
