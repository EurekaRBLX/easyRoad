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
    require(source, "local SHOULDER_SECTOR_INSET_RAD = math.rad(8)",
            "paired shoulder-taper mouths do not retain the measured ring-sidewalk overlap")
    require(source, "local SOLO_SPLIT_CLEARANCE_RAD = math.rad(3)",
            "solo one-way mouths do not retain the width-fit merge clearance")
    require(source, "local SOLO_SPLIT_MAX_RAD = math.rad(26)",
            "solo one-way mouths can fall back to the paired 38-degree tangent")
    require(source, "local SOLO_SECTOR_OVERLAP_SHARE = 0.3",
            "width-fit solo mouths can leave the ring sidewalk across the road")
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

    mouth = function_scope(source, "local function buildMouth(")
    require(mouth, "local hasTaperedShoulder =",
            "buildMouth does not distinguish shoulder-taper pavement ownership")
    require(mouth, "then SHOULDER_SECTOR_INSET_RAD else SECTOR_INSET_RAD",
            "paired highway mouths still use the ordinary pavement opening")
    require(mouth, "math.abs(sweep) * SOLO_SECTOR_OVERLAP_SHARE",
            "solo sidewalk ownership does not scale with its fitted merge sweep")

    splits = function_scope(source, "local function resolveSplits(")
    require(splits, "local fitAngle = math.asin",
            "solo one-way merge deflection is not fitted to actual arm width")
    require(splits, "return soloSplit, soloSplit",
            "solo one-way entry/exit rays still use paired-mouth split logic")

    turbo = function_scope(source, "local function buildTurboMarkings(")
    require(turbo, "local y = center.Y + TURBO_MARKING_LIFT_STUDS",
            "Turbo markings still share the ordinary marking top plane")
    return faults


def geometry_faults(name):
    scene = rp.build(tag=name, **rp.CASES[name])
    faults = []
    faults += rp.check_arm_marking_bounds(scene)
    faults += rp.check_outboard_edge_handoffs(scene)
    faults += rp.check_visual_ownership(scene)
    faults += rp.check_ring_openings(scene)
    faults += rp.check_solo_merges(scene)
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

    handoff, _ = geometry_faults("uk4")
    edge = next(record for record in handoff["arm_marking_bounds"]
                if record.get("preserved") and record["parts"])
    terminal_part = edge["parts"][-1 if edge["cut_at_start"] else 0]
    if edge["cut_at_start"]:
        terminal_part.to_station = edge["curve"].length - 1.0
    else:
        terminal_part.from_station = 1.0
    results.append(("clipped outboard handoff early",
                    bool(rp.check_outboard_edge_handoffs(handoff))))

    boundary, _ = geometry_faults("uk4")
    angle, _ahead, _behind = boundary["edge_marking_sectors"][0]
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
        [fake], center, boundary["edge_marking_sectors"]))))

    # Centre remains inside the sector, but the ahead corner crosses its ray.
    # The retired selector (`delta > ahead`) clipped this against the BEHIND
    # ray and left the visible ahead corner untouched.
    sector = (0.0, 0.25, 0.25)
    polar = lambda radius, angle: (math.cos(angle) * radius,
                                   math.sin(angle) * radius)
    polygon = [polar(10, 0.10), polar(11, 0.10),
               polar(11, 0.30), polar(10, 0.30)]
    centre = (sum(point[0] for point in polygon) / 4,
              sum(point[1] for point in polygon) / 4)
    straddler = rp.Part("Sidewalk", polygon, rp.SIDEWALK_C, centre, 0.0)
    kept, _removed, _clipped = rp.open_angular_parts(
        [straddler], (0.0, 0.0), [sector], lambda _part: True, clamp=False
    )
    results.append(("inside-centre part clipped at crossed ray",
                    not rp.ring_boundary_intrusions(
                        kept, (0.0, 0.0), [sector]
                    )))
    return results


def main():
    source = ROUNDABOUT.read_text(encoding="utf-8")
    faults = static_faults(source)
    for name in ("uk4", "us4", "turbo4", "turbo3x", "turbo_width",
                 "hw4", "hw4us", "hw_oneway"):
        _scene, case_faults = geometry_faults(name)
        for fault in case_faults:
            faults.append(f"{name}: {fault}")
    # The shoulder-specific sector ownership exists for one concrete reason:
    # rigid shoulder/kerb taper facets otherwise leave outer-band crescents in
    # the ring sidewalk. Exercise both traffic hands with the strict annulus
    # scan so the eight-degree constant cannot silently regress to three.
    for name in ("hw4", "hw4us"):
        scene = rp.build(tag=name, **rp.CASES[name])
        holes, pitch = rp.scan_gaps(scene)
        real, _thin = rp.cluster_gaps(holes, pitch, 0.15)
        if real:
            faults.append(f"{name}: visible ring-sidewalk gaps {real}")

    print("break-tests (each MUST be caught):")
    for name, caught in break_tests(source):
        print(f"  {name:36s} {'caught' if caught else 'NOT CAUGHT'}")
        if not caught:
            faults.append(f"break-test escaped: {name}")

    if faults:
        for fault in faults:
            print("FAILED:", fault)
        return 1
    print("roundabout 3D parity passed: edge handoffs, split mouth ownership, and width-safe Turbo")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
