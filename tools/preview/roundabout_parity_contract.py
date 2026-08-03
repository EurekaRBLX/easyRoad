#!/usr/bin/env python3
"""Behaviour/static contract for Python-looking roundabouts in 3D Studio.

The Python raster has deterministic paint order; Roblox Parts do not.  These
checks lock the explicit ownership rules that make the Luau result show the
same pixels without relying on coplanar or slightly protruding geometry.
"""
import math
from pathlib import Path

import roundabout_preview as rp


ROOT = Path(__file__).resolve().parents[2]
ROUNDABOUT = ROOT / "src" / "Mesh" / "RoundaboutBuilder.lua"


def function_scope(source, declaration, next_declaration="\nlocal function "):
    start = source.find(declaration)
    if start < 0:
        return ""
    end = source.find(next_declaration, start + len(declaration))
    return source[start:] if end < 0 else source[start:end]


def static_faults(source):
    faults = []

    def require(text, needle, message):
        if needle not in text:
            faults.append(message)

    require(source, "local ARM_MARKING_CLIP_SAMPLES = 96",
            "Luau arm-marking crossing resolution differs from the Python port")
    require(source, "local MARKING_LAYER_GAP_STUDS = 0.005",
            "Luau marking ownership gap differs from the Python port")
    require(source, "local ROADBUILDER_MARKING_ALT_STUDS = 0.004",
            "Luau Turbo layer does not account for RoadBuilder's alternate lift")
    require(
        source,
        "local TURBO_MARKING_LIFT_STUDS = RoadBuilder.MarkingLiftStuds + ROADBUILDER_MARKING_ALT_STUDS + MARKING_LAYER_GAP_STUDS",
        "Turbo is not assigned a deterministic top plane above ordinary markings",
    )

    clip = function_scope(source, "local function clipArmMarkingLinesAtRing(")
    require(clip, "ringKerbRadiusStuds + markingWidthStuds / 2 + MARKING_LAYER_GAP_STUDS",
            "arm marking clipping ignores the marking footprint or ownership gap")
    require(clip, "line.OffsetStartM + (line.OffsetEndM - line.OffsetStartM) * alpha",
            "arm marking clipping is not evaluated at each line's interpolated offset")
    require(clip, "line.ToStationStuds = crossing",
            "entry-arm markings are not bounded at their ring crossing")
    require(clip, "line.FromStationStuds = crossing",
            "exit-arm markings are not bounded at their ring crossing")

    build_arm = function_scope(source, "local function buildArm(")
    require(build_arm, "clipArmMarkingLinesAtRing(",
            "buildArm does not apply the per-offset marking ownership clip")
    require(build_arm, "MarkingLines = markingLines",
            "RoadBuilder does not receive the clipped arm marking plan")

    turbo = function_scope(source, "local function buildTurboMarkings(")
    require(turbo, "local y = center.Y + TURBO_MARKING_LIFT_STUDS",
            "Turbo markings still share the ordinary marking top plane")
    return faults


def geometry_faults(name):
    scene = rp.build(tag=name, **rp.CASES[name])
    faults = []
    faults += rp.check_arm_marking_bounds(scene)
    faults += rp.check_visual_ownership(scene)
    intrusions = rp.ring_boundary_intrusions(
        scene["outer_ring_parts"], scene["center"], scene["sectors"])
    if intrusions:
        faults.append(f"{len(intrusions)} ring boundary vertices remain in mouth ownership")
    records = [record for record in scene["arm_marking_bounds"]
               if record["crossing"] is not None]
    if not records:
        faults.append("case exercises no per-offset arm marking crossing")
    elif not ({record["cut_at_start"] for record in records} >= {True, False}):
        faults.append("case does not exercise both entry ToStation and exit FromStation")
    return scene, faults


def break_tests(source):
    results = []

    without_clip = source.replace("\tclipArmMarkingLinesAtRing(\n", "\t-- removed by break-test\n", 1)
    results.append(("removed buildArm clip call", bool(static_faults(without_clip))))

    flat_turbo = source.replace(
        "local y = center.Y + TURBO_MARKING_LIFT_STUDS",
        "local y = center.Y + RoadBuilder.MarkingLiftStuds",
        1,
    )
    results.append(("flattened Turbo layer", bool(static_faults(flat_turbo))))

    bounded, _ = geometry_faults("uk4")
    record = next(record for record in bounded["arm_marking_bounds"]
                  if record["crossing"] is not None and record["parts"])
    part = record["parts"][-1 if record["cut_at_start"] else 0]
    if record["cut_at_start"]:
        part.to_station = record["curve"].length
    else:
        part.from_station = 0.0
    results.append(("extended arm line through ring",
                    bool(rp.check_arm_marking_bounds(bounded))))

    turbo, _ = geometry_faults("turbo4")
    for part in turbo["spiral"]:
        part.y = rp.MARKING_LIFT
    results.append(("coplanar Turbo overlay",
                    bool(rp.check_visual_ownership(turbo))))

    boundary, _ = geometry_faults("uk4")
    angle, _ahead, _behind = boundary["sectors"][0]
    radius = boundary["ring_kerb"]
    center = boundary["center"]
    point = (center[0] + math.cos(angle) * radius,
             center[1] + math.sin(angle) * radius)
    fake = rp.Part("Marking", [
        (point[0] - 0.05, point[1] - 0.05),
        (point[0] + 0.05, point[1] - 0.05),
        (point[0], point[1] + 0.05),
    ], rp.MARK_C, point, rp.MARKING_LIFT)
    results.append(("ring fragment inside mouth", bool(rp.ring_boundary_intrusions(
        [fake], center, boundary["sectors"]))))
    return results


def main():
    source = ROUNDABOUT.read_text(encoding="utf-8")
    faults = static_faults(source)
    for name in ("uk4", "us4", "turbo4", "turbo3x", "hw4", "hw4us"):
        _scene, case_faults = geometry_faults(name)
        for fault in case_faults:
            faults.append(f"{name}: {fault}")

    print("break-tests (each MUST be caught):")
    for name, caught in break_tests(source):
        print(f"  {name:36s} {'caught' if caught else 'NOT CAUGHT'}")
        if not caught:
            faults.append(f"break-test escaped: {name}")

    if faults:
        for fault in faults:
            print("FAILED:", fault)
        return 1
    print("roundabout 3D parity passed: per-offset arm clips, mouth bounds, Turbo layer ownership")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
