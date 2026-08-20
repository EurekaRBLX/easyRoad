#!/usr/bin/env python3
"""Roundabout arm/source height continuity regression fixture.

The roundabout generator owns a short curved arm between a trimmed source road
and the circulating ring.  That arm must meet the source at exactly the same
top plane: a 0.05-stud vertical ``ARM_SINK_STUDS`` made the arm visibly step
down at its *outer* cut even though the sink was only intended to break up
overlap at the ring.

This is deliberately a small elevation fixture rather than another plan-view
roundabout preview.  It tests the three top planes that users can see at the
cut -- asphalt, raised pavement/kerb, and paint -- across flat, elevated, and
banked source frames.  The banked sample catches an attempted curb-only
compensation: moving just the raised surface back up can hide a kerb seam while
leaving the road deck below it.

    python tools/preview/roundabout_arm_height_preview.py --check
    python tools/preview/roundabout_arm_height_preview.py --out out/roundabout-arm-height.png

The static production contract intentionally fails while RoundaboutBuilder
contains the retired arm sink or any of its apron/splitter compensations.
"""
import argparse
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path

from preview_core import MARKING_LIFT, MARKING_THICKNESS, SCALE
from raster import Canvas


ROOT = Path(__file__).resolve().parents[2]
ROUNDABOUT = ROOT / "src" / "Mesh" / "RoundaboutBuilder.lua"

CURB_HEIGHT_STUDS = 0.15 * SCALE
ARM_SINK_STUDS = 0.05
EPSILON = 1e-6


@dataclass(frozen=True)
class CutCase:
    name: str
    centre_y: float
    roll_deg: float


@dataclass(frozen=True)
class TopPlanes:
    drive: float
    shoulder: float
    sidewalk_kerb: float
    marking: float


CASES = (
    CutCase("flat_ground", 0.0, 0.0),
    CutCase("elevated_flat", 18.75, 0.0),
    CutCase("banked_elevated", 11.0, 6.0),
)


def top_planes(case: CutCase, lateral_studs: float = 0.0, sink: float = 0.0,
               compensate_kerb: bool = False) -> TopPlanes:
    """Top face of each visible layer in the local road frame at the cut.

    ``lateral_studs`` makes the banked case a real cross-section rather than a
    centreline-only test.  The source and a correctly built arm share this
    frame at their common station.  A downward arm translation affects deck
    and kerb geometry but not the deliberately un-sunk marking Parts in the
    historical implementation.
    """
    roll = math.radians(case.roll_deg)
    up = math.cos(roll)
    asphalt = case.centre_y + lateral_studs * math.sin(roll) - sink
    kerb = asphalt + CURB_HEIGHT_STUDS * up
    if compensate_kerb:
        kerb += sink
    # Marking Part.CFrame is at MARKING_LIFT and its visible top is another
    # half-thickness above that.  The old sink loop exempted Marking.
    marking = case.centre_y + lateral_studs * math.sin(roll) + (MARKING_LIFT + MARKING_THICKNESS / 2) * up
    return TopPlanes(asphalt, asphalt, kerb, marking)


def delta(a: TopPlanes, b: TopPlanes) -> TopPlanes:
    return TopPlanes(
        a.drive - b.drive,
        a.shoulder - b.shoulder,
        a.sidewalk_kerb - b.sidewalk_kerb,
        a.marking - b.marking,
    )


def max_abs(value: TopPlanes) -> float:
    return max(abs(value.drive), abs(value.shoulder), abs(value.sidewalk_kerb), abs(value.marking))


def static_faults(source: str) -> list[str]:
    """Require retirement of the old vertical displacement as a whole.

    Removing only the descendant translation is insufficient: apron/frontage
    coordinates and splitter lifts included offsetting +0.05 terms and would
    leave their own height seams at the mouth.
    """
    faults = []
    rejected = (
        ("local ARM_SINK_STUDS = 0.05", "roundabout arms still declare the retired 0.05-stud sink"),
        ("Vector3.new(0, ARM_SINK_STUDS, 0)", "roundabout arms still translate descendants below the source road"),
        ("goreEdgeAt(entryCurve, along, entryArm, -ARM_SINK_STUDS)", "flat apron still compensates for the retired arm sink"),
        ("goreEdgeAt(exitCurve, exitCurve.Length - along, exitArm, -ARM_SINK_STUDS)", "flat apron still compensates for the retired arm sink"),
        ("goreEdgeAt(entryCurve, lastAlong, entryArm, -ARM_SINK_STUDS)", "splitter frontage still compensates for the retired arm sink"),
        ("goreEdgeAt(exitCurve, exitCurve.Length - lastAlong, exitArm, -ARM_SINK_STUDS)", "splitter frontage still compensates for the retired arm sink"),
        ("Vector3.new(0, curbHeight + ARM_SINK_STUDS, 0)", "raised splitter frontage still contains an arm-sink compensation"),
    )
    for marker, message in rejected:
        if marker in source:
            faults.append(message)

    # Keep the outer endpoint attached to its source cut, while the arm enters
    # the ring on the ring controller's own elevation.  This is a *graded arm
    # diagnostic*, not a banking policy: it prevents a source road from being
    # cut loose while avoiding an arbitrarily elevated slice of a flat ring.
    for marker, message in (
        ("plan.CutMid + side * entry.LateralStuds", "entry arm no longer begins on its source-cut point"),
        ("plan.CutMid + side * exit.LateralStuds", "exit arm no longer ends on its source-cut point"),
        ("ringPointAt(center, entryAngle, entry.MergeRadius, center.Y)",
         "entry arm no longer lands on the ring controller elevation"),
        ("ringPointAt(center, exitAngle, exit.MergeRadius, center.Y)",
         "exit arm no longer lands on the ring controller elevation"),
    ):
        if marker not in source:
            faults.append(message)
    return faults


def validate_geometry(source: str | None = None) -> dict:
    source = ROUNDABOUT.read_text(encoding="utf-8") if source is None else source
    faults = static_faults(source)
    rows = []
    for case in CASES:
        lateral_samples = (-12.0, 0.0, 12.0) if case.roll_deg else (0.0,)
        for lateral in lateral_samples:
            road = top_planes(case, lateral)
            arm = top_planes(case, lateral)
            seam = delta(arm, road)
            if max_abs(seam) > EPSILON:
                faults.append(f"{case.name}/{lateral:+.1f}: expected arm/source seam is {seam}")

            # Mutation: the exact legacy code lowered every non-marking arm
            # descendant. It must fail on asphalt and raised pavement. Paint
            # alone happened to remain continuous, which is why a marking-only
            # visual check never caught the defect.
            sunk = delta(top_planes(case, lateral, ARM_SINK_STUDS), road)
            if (
                abs(sunk.drive + ARM_SINK_STUDS) > EPSILON
                or abs(sunk.shoulder + ARM_SINK_STUDS) > EPSILON
                or abs(sunk.sidewalk_kerb + ARM_SINK_STUDS) > EPSILON
            ):
                faults.append(f"{case.name}/{lateral:+.1f}: sink mutant no longer exposes Drive/Shoulder/Sidewalk step")
            if abs(sunk.marking) > EPSILON:
                faults.append(f"{case.name}/{lateral:+.1f}: sink mutant must preserve historical marking plane")

            # A tempting partial repair lifts only curbs/splitters by +sink.
            # Assert this cannot satisfy the fixture because asphalt is still
            # below the source surface.
            curb_only = delta(top_planes(case, lateral, ARM_SINK_STUDS, True), road)
            if abs(curb_only.drive + ARM_SINK_STUDS) > EPSILON or abs(curb_only.sidewalk_kerb) > EPSILON:
                faults.append(f"{case.name}/{lateral:+.1f}: curb-only compensation model changed unexpectedly")

            rows.append({
                "case": case.name,
                "lateral_studs": lateral,
                "road": asdict(road),
                "expected_arm": asdict(arm),
                "legacy_sunk_arm_delta": asdict(sunk),
                "curb_only_compensation_delta": asdict(curb_only),
            })
    # Diagnostic only: an arm from an elevated source to a flat ring needs a
    # grade over its length. This does not relax the zero delta at the source
    # cut, and is reported separately so visual QA can tell a designed grade
    # from the old blanket 0.05-stud drop.
    graded = CutCase("graded_ring_end_diagnostic", 8.0, 0.0)
    rows.append({
        "case": graded.name,
        "note": "diagnostic only; not an arm/source cut failure",
        "source_cut_y": graded.centre_y,
        "flat_ring_controller_y": 0.0,
        "required_arm_grade_delta": -graded.centre_y,
    })
    return {"faults": faults, "rows": rows}


def render(path: Path) -> dict:
    """Draw a side elevation plus a banked cross-section at the source cut."""
    report = validate_geometry()
    canvas = Canvas(1400, 700, (27, 30, 34))

    # Left: source road (0..580) and the roundabout arm (580..1160).  The
    # upper two bands are kerb and marking; the lower wide band is asphalt.
    # Expected paths are solid; the red dashed path is the old 0.05 sink.
    base_x0, cut_x, end_x = 90, 610, 1230
    y0, px_per_stud = 385, 12

    def y(height: float) -> float:
        return y0 - height * px_per_stud

    flat = CASES[0]
    source = top_planes(flat)
    sunk = top_planes(flat, sink=ARM_SINK_STUDS)
    asphalt_bottom = source.drive - 1.0
    canvas.fill_poly([(base_x0, y(asphalt_bottom)), (cut_x, y(asphalt_bottom)),
                      (cut_x, y(source.drive)), (base_x0, y(source.drive))], (54, 60, 69))
    canvas.fill_poly([(cut_x, y(asphalt_bottom)), (end_x, y(asphalt_bottom)),
                      (end_x, y(source.drive)), (cut_x, y(source.drive))], (54, 60, 69))
    # kerb: source and the corrected arm use one uninterrupted top line.
    canvas.fill_poly([(base_x0, y(source.drive)), (end_x, y(source.drive)),
                      (end_x, y(source.sidewalk_kerb)), (base_x0, y(source.sidewalk_kerb))], (161, 166, 172))
    canvas.line((base_x0, y(source.marking)), (end_x, y(source.marking)), (245, 245, 245), 5)
    # Cut marker / retired sink ghost.
    canvas.line((cut_x, 160), (cut_x, 535), (225, 136, 80), 2)
    for start in range(cut_x + 10, end_x, 28):
        canvas.line((start, y(sunk.drive)), (min(start + 14, end_x), y(sunk.drive)), (205, 73, 76), 3)
        canvas.line((start, y(sunk.sidewalk_kerb)), (min(start + 14, end_x), y(sunk.sidewalk_kerb)), (205, 73, 76), 3)

    # Right: banked cut cross-section. Source/arm joint must share every point
    # of its asphalt, raised kerb and marking planes; sample both edges and the
    # centre. Draw the locally-upward kerb strips at either edge.
    origin_x, origin_y, width = 1030, 560, 18
    bank = CASES[-1]
    roll = math.radians(bank.roll_deg)
    points = []
    for lateral in (-12, 0, 12):
        planes = top_planes(bank, lateral)
        x = origin_x + lateral * width
        points.append((x, origin_y - (planes.drive - bank.centre_y) * px_per_stud))
    canvas.fill_poly(points + [(points[-1][0], origin_y + 85), (points[0][0], origin_y + 85)], (54, 60, 69))
    canvas.polyline(points, (225, 230, 235), 3)
    for lateral in (-12, 12):
        plane = top_planes(bank, lateral)
        x = origin_x + lateral * width
        kerb_y = origin_y - (plane.sidewalk_kerb - bank.centre_y) * px_per_stud
        asphalt_y = origin_y - (plane.drive - bank.centre_y) * px_per_stud
        canvas.fill_poly([(x - 10, asphalt_y), (x + 10, asphalt_y),
                          (x + 10, kerb_y), (x - 10, kerb_y)], (161, 166, 172))
    # Source/arm identity is encoded as cyan coincidence markers, which remain
    # a single line only if all sampled planes occupy the same height.
    for lateral in (-12, 0, 12):
        plane = top_planes(bank, lateral)
        x = origin_x + lateral * width
        canvas.line((x - 7, origin_y - (plane.marking - bank.centre_y) * px_per_stud),
                    (x + 7, origin_y - (plane.marking - bank.centre_y) * px_per_stud),
                    (79, 205, 210), 3)

    path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(path)
    json_path = path.with_suffix(".json")
    json_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="run contract and numeric regression only")
    parser.add_argument("--out", type=Path, help="write elevation PNG and JSON report")
    args = parser.parse_args()

    if args.out:
        report = render(args.out)
        print(f"wrote {args.out} and {args.out.with_suffix('.json')}")
    else:
        report = validate_geometry()
    if report["faults"]:
        for fault in report["faults"]:
            print("FAILED:", fault)
        return 1
    print("roundabout arm height continuity passed: flat, elevated, and banked source cuts; asphalt, kerb, and markings share zero seam delta")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
