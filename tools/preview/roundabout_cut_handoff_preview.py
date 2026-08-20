#!/usr/bin/env python3
"""Roundabout source-road/arm cut-handoff regression fixture.

The arm profile and the pavement widths copied from its source road must use
the same mirror decision.  If the profile is mirrored but the source widths
are not, an asymmetric sidewalk/shoulder is attached to the wrong side of the
arm and the source-road cap remains visible as a rectangular stub.

This fixture covers both ends of a source road and both arm directions:

    python tools/preview/roundabout_cut_handoff_preview.py --check
    python tools/preview/roundabout_cut_handoff_preview.py --out out/roundabout-cut-handoff.png

The PNG draws the correct handoff on the left and the retired bare-global
``mirrored == nil`` behaviour on the right.  JSON beside the PNG records the
four truth-table rows and their pavement-width deltas.
"""
from __future__ import annotations

import argparse
import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path

from raster import Canvas


ROOT = Path(__file__).resolve().parents[2]
ROUNDABOUT = ROOT / "src" / "Mesh" / "RoundaboutBuilder.lua"

ASPHALT = (55, 60, 67)
PAVEMENT = (169, 171, 173)
KERB = (229, 231, 233)
ACCENT = (213, 126, 79)
FAULT = (210, 69, 73)
BACKGROUND = (28, 31, 35)


@dataclass(frozen=True)
class Case:
    name: str
    at_start: bool
    travels_inward: bool


@dataclass(frozen=True)
class Widths:
    left_m: float
    right_m: float


CASES = (
    Case("start_entry", True, True),
    Case("start_exit", True, False),
    Case("end_entry", False, True),
    Case("end_exit", False, False),
)

# Deliberately asymmetric so a missing swap cannot hide behind equal widths.
SOURCE_WIDTHS = Widths(left_m=3.0, right_m=0.75)


def mirrored(case: Case) -> bool:
    return case.travels_inward == case.at_start


def map_widths(source: Widths, should_mirror: bool) -> Widths:
    if should_mirror:
        return Widths(source.right_m, source.left_m)
    return source


def _make_arm_scope(source: str) -> str:
    start = source.find("local function makeArm(group: LaneGroup?, travelsInward: boolean): MouthArm?")
    if start < 0:
        return ""
    end = source.find("\n\tlocal entry = makeArm(inbound, true)", start)
    return source[start:end] if end >= 0 else source[start:]


def static_faults(source: str) -> list[str]:
    scope = _make_arm_scope(source)
    if not scope:
        return ["planMouth.makeArm scope is missing"]

    faults: list[str] = []
    required = (
        (
            "local mirrored = travelsInward == atStart",
            "makeArm does not retain one local mirror decision for the complete handoff",
        ),
        (
            "armProfileFor(group, solo, style, scale, mirrored, ringSidewalkWidthM(style), spokeProfile)",
            "armProfileFor does not use the same local mirror decision as the source pavement widths",
        ),
        (
            "CutPavementLeftM = if mirrored then group.RightPavementM else group.LeftPavementM",
            "left source pavement is not mirrored with the arm profile",
        ),
        (
            "CutPavementRightM = if mirrored then group.LeftPavementM else group.RightPavementM",
            "right source pavement is not mirrored with the arm profile",
        ),
    )
    compact = re.sub(r"\s+", " ", scope)
    for marker, message in required:
        if re.sub(r"\s+", " ", marker) not in compact:
            faults.append(message)
    return faults


def validate(source: str | None = None) -> dict:
    source = ROUNDABOUT.read_text(encoding="utf-8") if source is None else source
    faults = static_faults(source)
    scope = _make_arm_scope(source)
    has_shared_local = "local mirrored = travelsInward == atStart" in scope
    inverted_local = "local mirrored = travelsInward ~= atStart" in scope
    rows = []
    for case in CASES:
        expected_mirror = mirrored(case)
        if has_shared_local:
            actual_mirror = expected_mirror
        elif inverted_local:
            actual_mirror = not expected_mirror
        else:
            # Luau reads the accidentally bare global as nil in Studio.
            actual_mirror = False
        expected = map_widths(SOURCE_WIDTHS, expected_mirror)
        actual = map_widths(SOURCE_WIDTHS, actual_mirror)
        left_delta = actual.left_m - expected.left_m
        right_delta = actual.right_m - expected.right_m
        if abs(left_delta) > 1e-9 or abs(right_delta) > 1e-9:
            faults.append(
                f"{case.name}: pavement mirror mismatch leaves "
                f"left {left_delta:+.2f} m / right {right_delta:+.2f} m at the cut"
            )
        rows.append(
            {
                "case": asdict(case),
                "expected_mirrored": expected_mirror,
                "actual_mirrored": actual_mirror,
                "source": asdict(SOURCE_WIDTHS),
                "expected_arm": asdict(expected),
                "actual_arm": asdict(actual),
                "delta_m": {"left": left_delta, "right": right_delta},
            }
        )
    return {"faults": faults, "rows": rows}


def _draw_handoff(canvas: Canvas, x0: int, x1: int, seam: int, cy: int, arm: Widths, fault: bool) -> None:
    road_half = 26
    scale = 13
    source_top = cy - road_half - SOURCE_WIDTHS.left_m * scale
    source_bottom = cy + road_half + SOURCE_WIDTHS.right_m * scale
    arm_top = cy - road_half - arm.left_m * scale
    arm_bottom = cy + road_half + arm.right_m * scale

    canvas.fill_poly([(x0, cy - road_half), (x1, cy - road_half), (x1, cy + road_half), (x0, cy + road_half)], ASPHALT)
    canvas.fill_poly([(x0, source_top), (seam, source_top), (seam, cy - road_half), (x0, cy - road_half)], PAVEMENT)
    canvas.fill_poly([(x0, cy + road_half), (seam, cy + road_half), (seam, source_bottom), (x0, source_bottom)], PAVEMENT)
    canvas.fill_poly([(seam, arm_top), (x1, arm_top), (x1, cy - road_half), (seam, cy - road_half)], PAVEMENT)
    canvas.fill_poly([(seam, cy + road_half), (x1, cy + road_half), (x1, arm_bottom), (seam, arm_bottom)], PAVEMENT)
    canvas.line((x0, cy - road_half), (x1, cy - road_half), KERB, 2)
    canvas.line((x0, cy + road_half), (x1, cy + road_half), KERB, 2)
    canvas.line((seam, min(source_top, arm_top)), (seam, max(source_bottom, arm_bottom)), FAULT if fault else ACCENT, 3)

    if fault:
        # Highlight exactly the source cap area left exposed by the wrong arm-side width.
        if source_top < arm_top:
            canvas.fill_poly([(seam - 24, source_top), (seam, source_top), (seam, arm_top), (seam - 24, arm_top)], FAULT)
        if source_bottom > arm_bottom:
            canvas.fill_poly([(seam - 24, arm_bottom), (seam, arm_bottom), (seam, source_bottom), (seam - 24, source_bottom)], FAULT)


def render(path: Path) -> dict:
    report = validate()
    canvas = Canvas(1500, 860, BACKGROUND)
    for index, case in enumerate(CASES):
        cy = 115 + index * 205
        expected = map_widths(SOURCE_WIDTHS, mirrored(case))
        legacy = map_widths(SOURCE_WIDTHS, False)
        _draw_handoff(canvas, 55, 710, 360, cy, expected, False)
        _draw_handoff(canvas, 790, 1445, 1095, cy, legacy, legacy != expected)
        # Direction/end-state ticks make the four rows visually distinct even
        # without a font dependency; full labels live in the JSON companion.
        canvas.disc(78, cy, 7, ACCENT if case.at_start else KERB)
        canvas.disc(812, cy, 7, ACCENT if case.travels_inward else KERB)

    path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(path)
    path.with_suffix(".json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return report


def mutation_faults(source: str) -> list[str]:
    mutations = {
        "missing local": source.replace("\t\tlocal mirrored = travelsInward == atStart\n", "", 1),
        "inverted local": source.replace(
            "local mirrored = travelsInward == atStart", "local mirrored = travelsInward ~= atStart", 1
        ),
        "profile bypass": source.replace(
            "armProfileFor(group, solo, style, scale, mirrored, ringSidewalkWidthM(style), spokeProfile)",
            "armProfileFor(group, solo, style, scale, travelsInward == atStart, ringSidewalkWidthM(style), spokeProfile)",
            1,
        ),
        "left width bypass": source.replace(
            "CutPavementLeftM = if mirrored then group.RightPavementM else group.LeftPavementM",
            "CutPavementLeftM = group.LeftPavementM",
            1,
        ),
    }
    failures = []
    for label, mutant in mutations.items():
        if not validate(mutant)["faults"]:
            failures.append(f"injected mutation escaped: {label}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="run source, truth-table, and mutation contracts")
    parser.add_argument("--out", type=Path, help="write PNG and JSON report")
    args = parser.parse_args()

    report = render(args.out) if args.out else validate()
    faults = list(report["faults"])
    if args.check:
        faults.extend(mutation_faults(ROUNDABOUT.read_text(encoding="utf-8")))
    if faults:
        for fault in faults:
            print("FAILED:", fault)
        return 1
    print("roundabout cut handoff passed: start/end entry/exit arms share one mirror decision (4 cases, 4 injected breaks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
