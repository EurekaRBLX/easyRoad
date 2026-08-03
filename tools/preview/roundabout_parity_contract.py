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

    def reject(text, needle, message):
        if needle in text:
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
    reject(source, "SOLO_SECTOR_INSET_RAD",
           "solo pavement still uses the obsolete angular inset")
    reject(source, "SOLO_SECTOR_OVERLAP_SHARE",
           "solo pavement still uses the obsolete overlap share")
    reject(source, "local function bandExitAngle(",
           "solo pavement still uses the obsolete outboard-only crossing")
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
    require(build_arm, "collectRoadwayFootprints: boolean",
            "buildArm cannot collect solo roadway cutters")
    require(build_arm, "local stations = RoadBuilder.StationsFor(options)",
            "solo cutters do not share RoadBuilder's station grid")
    require(build_arm, "local roadwayPartNames: { [string]: boolean }",
            "solo cutters have no generated-part roadway filter")
    require(build_arm, "Bay = true",
            "solo cutters omit generated Bay blocks")
    require(build_arm, "table.insert(roadwayFootprints, partTopPolygon(descendant))",
            "solo cutters do not use exact generated core block footprints")
    require(build_arm,
            "{ shoulderInner0, shoulderOuter0, shoulderOuter1, shoulderInner1 }",
            "solo cutters omit the exact shoulder-taper quad")
    require(build_arm, "return model, roadwayFootprints",
            "buildArm drops its captured roadway cutters")

    footprint_open = function_scope(
        source, "local function openRingSidewalkByFootprints("
    )
    require(footprint_open, "subtractConvexFootprint(fragment, cutter.Polygon)",
            "solo sidewalk opening does not subtract exact cutter polygons")
    require(footprint_open, "replaceWithClippedPolygons(part, fragments)",
            "solo sidewalk opening does not retain exact surviving fragments")

    crossing = function_scope(source, "local function bandEdgeExitAngle(")
    require(crossing, "signedOffsetStuds: number",
            "solo band crossing is still specialized to one roadway edge")
    require(crossing, "rightOf(tangent) * signedOffsetStuds",
            "solo band crossing ignores its signed lateral edge offset")
    require(crossing, "radiusAt(station) <= targetRadiusStuds",
            "edge-paint crossing no longer preserves the merge-terminal cap")
    require(crossing, "local edge = edgeAt(station)",
            "edge crossing does not return the first edge/cap point")

    mouth = function_scope(source, "local function buildMouth(")
    require(mouth, "local hasTaperedShoulder =",
            "buildMouth does not distinguish shoulder-taper pavement ownership")
    require(mouth, "then SHOULDER_SECTOR_INSET_RAD else SECTOR_INSET_RAD",
            "paired highway mouths still use the ordinary pavement opening")
    require(mouth, "local outboardOffsetStuds = -only.Profile.OuterOffsetStuds * flow",
            "solo mouth does not cross its signed traffic-outboard edge")
    require(mouth, "local inboardOffsetStuds = only.Profile.InnerOffsetStuds * flow",
            "solo mouth does not cross its signed traffic-inboard edge")
    require(mouth, "bandEdgeExitAngle(onlyCurve, outboardOffsetStuds",
            "solo mouth never applies the generalized crossing to its outboard edge")
    require(mouth, "bandEdgeExitAngle(onlyCurve, inboardOffsetStuds",
            "solo mouth never applies the generalized crossing to its inboard edge")
    require(mouth, "local function sectorAtRadius(targetRadiusStuds: number): MouthSector",
            "solo edge paint has no two-edge sector construction")
    require(mouth, "local sweep = angleDelta(inboardAngle, outboardAngle)",
            "solo edge-paint sector is not bounded by both roadway edges")
    require(mouth, "return { Angle = outboardAngle + sweep / 2, Ahead = half, Behind = half }",
            "solo edge paint does not open the full edge-to-edge sector")
    reject(mouth, "local outerBandRadius =",
           "solo pavement has regressed to a radial outer-band sector")
    reject(mouth, "sectorAtRadius(outerBandRadius)",
           "solo pavement is still deleted by an angular sector")
    require(mouth, "local edgeLineRadius = ringKerbRadius - style.MarkingWidthM * 1.5 * settings.MetersToStuds",
            "solo paint sector is not measured at the ring outer edge-line centre")
    require(mouth, "return nil, sectorAtRadius(edgeLineRadius), soloTrace, soloRoadwayCutters",
            "solo mouths do not return footprint-owned pavement and edge-line paint")
    require(mouth, "): (MouthSector?, MouthSector, ExitTrace?, { ConvexFootprint })",
            "buildMouth cannot return nil solo pavement plus roadway cutters")
    require(mouth, "local soloMouth = not (plan.Entry and plan.Exit)",
            "roadway cutter capture is not restricted to solo mouths")
    require(mouth,
            "local collectSoloRoadway = soloMouth and ringSidewalkWidthM(style) > 1e-6",
            "roadway cutters are collected when no solo ring sidewalk exists")
    require(mouth, "return pavementSector,",
            "paired mouths no longer preserve their pavement sector")

    require(source, "if sector then",
            "nil solo pavement sectors cannot be excluded from mouthSectors")
    require(source, "table.insert(mouthSectors, sector)",
            "paired pavement sectors are no longer collected")
    footprint_call = source.find(
        "openRingSidewalkByFootprints(ringSidewalk, soloRoadwayCutters)"
    )
    paired_call = source.find(
        "openRingPavement(ringSidewalk, center, mouthSectors, 0)"
    )
    if footprint_call < 0:
        faults.append("solo roadway cutters are never applied to ring sidewalk")
    if paired_call < 0:
        faults.append("paired angular sidewalk sectors are never applied")
    if footprint_call >= 0 and paired_call >= 0 and footprint_call > paired_call:
        faults.append("solo footprint subtraction must precede paired sector opening")

    splits = function_scope(source, "local function resolveSplits(")
    require(splits, "local fitAngle = math.asin",
            "solo one-way merge deflection is not fitted to actual arm width")
    require(splits, "return soloSplit, soloSplit",
            "solo one-way entry/exit rays still use paired-mouth split logic")

    turbo = function_scope(source, "local function buildTurboMarkings(")
    require(turbo, "local y = center.Y + TURBO_MARKING_LIFT_STUDS",
            "Turbo markings still share the ordinary marking top plane")
    return faults


def solo_ownership_faults(scene, tolerance=1e-7):
    """Solo pavement is exact roadway subtraction; only paint stays angular."""
    faults = []
    center = scene["center"]
    edge_line_radius = (
        scene["ring_kerb"] - rp.MARKING_W_M * 1.5 * rp.SCALE
    )
    solo_mouths = scene.get("solo_mouths", [])
    paired_count = len(scene.get("legs", [])) - len(solo_mouths)
    if len(scene.get("pavement_sectors", [])) != paired_count:
        faults.append(
            "solo pavement leaked into mouthSectors or a paired sector was dropped"
        )

    ring_sidewalk = scene.get("outer_ring_sidewalk", [])
    for index, mouth in enumerate(solo_mouths, 1):
        roadway_parts = mouth.get("roadway_parts", [])
        if not roadway_parts:
            faults.append(f"mouth {index} has no roadway footprint cutters")
        elif not any(part.name == "Drive" for part in roadway_parts):
            faults.append(f"mouth {index} cutters omit the core Drive surface")
        cut_shoulders = mouth.get("arm", {}).get("cut_shoulders", (0.0, 0.0))
        if sum(cut_shoulders) > tolerance and not any(
                part.name == "Shoulder" for part in roadway_parts):
            faults.append(f"mouth {index} cutters omit its shoulder taper")
        component_kinds = {
            component[0] for component in mouth.get("arm", {}).get("comps", [])
            if component[1] > tolerance
        }
        for roadway_kind in ("Bike", "Parking", "Bay"):
            if (roadway_kind in component_kinds
                    and not any(part.name == roadway_kind
                                for part in roadway_parts)):
                faults.append(
                    f"mouth {index} cutters omit its {roadway_kind} surface"
                )

        overlap_found = False
        for roadway in roadway_parts:
            for sidewalk in ring_sidewalk:
                if rp._overlap_area(roadway.poly, sidewalk.poly) > 1e-5:
                    faults.append(
                        f"mouth {index} retains ring Sidewalk over an exact "
                        f"{roadway.name} footprint"
                    )
                    overlap_found = True
                    break
            if overlap_found:
                break

        if abs(mouth.get("marking_ownership_radius", math.inf)
               - edge_line_radius) > tolerance:
            faults.append(
                f"mouth {index} paint ownership is not at the outer edge-line centre"
            )
        crossings = mouth.get("marking_crossings", {})
        marking_sector = mouth.get("marking_sector")
        outer = crossings.get("outer")
        inner = crossings.get("inner")
        if not outer or not inner or not marking_sector:
            faults.append(f"mouth {index} has no complete edge-paint sector")
        else:
            for edge_name, crossing in (("outboard", outer), ("inboard", inner)):
                delta = rp.angle_delta(crossing["angle"], marking_sector[0])
                if (delta > marking_sector[1] + tolerance
                        or -delta > marking_sector[2] + tolerance):
                    faults.append(
                        f"mouth {index} edge-paint sector contracts before its "
                        f"{edge_name} boundary"
                    )
                radius = math.dist(crossing["point"], center)
                if abs(radius - edge_line_radius) > 1e-5:
                    faults.append(
                        f"mouth {index} edge-paint {edge_name} boundary is at "
                        f"{radius:.5f}, expected {edge_line_radius:.5f}"
                    )

        marking_cap = crossings.get("outer")
        if marking_cap:
            if abs(rp.angle_delta(
                    marking_cap["angle"], mouth["merge_angle"])) > tolerance:
                faults.append(
                    f"mouth {index} edge-paint outboard boundary is not the merge cap"
                )
            if abs(marking_cap["station"] - mouth["ring_station"]) > tolerance:
                faults.append(
                    f"mouth {index} edge-paint cap moved away from the ring terminal"
                )
    return faults


def geometry_faults(name):
    scene = rp.build(tag=name, **rp.CASES[name])
    faults = []
    faults += rp.check_arm_marking_bounds(scene)
    faults += rp.check_outboard_edge_handoffs(scene)
    faults += rp.check_visual_ownership(scene)
    faults += rp.check_ring_openings(scene)
    faults += rp.check_solo_merges(scene)
    faults += solo_ownership_faults(scene)
    records = [record for record in scene["arm_marking_bounds"]
               if record["crossing"] is not None]
    if not records:
        faults.append("case exercises no per-offset arm marking crossing")
    elif not ({record["cut_at_start"] for record in records} >= {True, False}):
        faults.append("case does not exercise both entry ToStation and exit FromStation")
    return scene, faults


def visible_ring_gap_faults(scene, hairline=0.15, rings=96):
    """Reject bare curb-return gaps without making every parity run a full CLI scan.

    The regressions here are 3--5-stud crescents, so 96 radial probes retain a
    wide detection margin. The established paired-shoulder guard below still
    requests the preview's full 240-ring scan explicitly.
    """
    holes, pitch = rp.scan_gaps(scene, rings=rings)
    real, _thin = rp.cluster_gaps(holes, pitch, hairline)
    if not real:
        return []
    worst_depth = max(depth for _samples, depth in real.values())
    return [
        f"{len(real)} visible ring-sidewalk gap clusters "
        f"(worst depth {worst_depth:.3f} studs)"
    ]


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

    one_edge = source.replace(
        "bandEdgeExitAngle(onlyCurve, inboardOffsetStuds",
        "bandEdgeExitAngle(onlyCurve, outboardOffsetStuds",
        1,
    )
    results.append(("reused outboard crossing for both edges",
                    bool(static_faults(one_edge))))

    angular_solo = source.replace(
        "return nil, sectorAtRadius(edgeLineRadius), soloTrace, soloRoadwayCutters",
        "return sectorAtRadius(edgeLineRadius), sectorAtRadius(edgeLineRadius), soloTrace, soloRoadwayCutters",
        1,
    )
    results.append(("returned angular solo pavement sector",
                    bool(static_faults(angular_solo))))

    without_footprint_open = source.replace(
        "\topenRingSidewalkByFootprints(ringSidewalk, soloRoadwayCutters)",
        "\t-- removed by break-test",
        1,
    )
    results.append(("skipped solo footprint subtraction",
                    bool(static_faults(without_footprint_open))))

    without_core_cutters = source.replace(
        "table.insert(roadwayFootprints, partTopPolygon(descendant))",
        "-- core cutter removed by break-test",
        1,
    )
    results.append(("omitted generated core cutters",
                    bool(static_faults(without_core_cutters))))

    without_shoulder_cutters = source.replace(
        "{ shoulderInner0, shoulderOuter0, shoulderOuter1, shoulderInner1 }",
        "{} -- shoulder cutter removed by break-test",
        1,
    )
    results.append(("omitted shoulder taper cutters",
                    bool(static_faults(without_shoulder_cutters))))

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

    solo, _ = geometry_faults("solo_flare")
    solo["pavement_sectors"].append(solo["solo_pavement_sectors"][0])
    results.append(("leaked solo sector into paired openings",
                    bool(solo_ownership_faults(solo))))

    shoulders, _ = geometry_faults("solo_flare")
    shoulder_mouth = next(
        mouth for mouth in shoulders["solo_mouths"]
        if sum(mouth["arm"]["cut_shoulders"]) > 1e-7
    )
    shoulder_mouth["roadway_parts"] = [
        part for part in shoulder_mouth["roadway_parts"]
        if part.name != "Shoulder"
    ]
    results.append(("removed Python shoulder cutters",
                    bool(solo_ownership_faults(shoulders))))

    bay, _ = geometry_faults("solo_bay")
    bay_mouth = next(
        mouth for mouth in bay["solo_mouths"]
        if any(component[0] == "Bay" for component in mouth["arm"]["comps"])
    )
    bay_mouth["roadway_parts"] = [
        part for part in bay_mouth["roadway_parts"] if part.name != "Bay"
    ]
    results.append(("removed Python Bay cutters",
                    bool(solo_ownership_faults(bay))))

    over_opened, _ = geometry_faults("solo_flare")
    sidewalk_ids = {
        id(part) for part in over_opened.get("outer_ring_sidewalk", [])
    }
    over_opened["parts"] = [
        part for part in over_opened["parts"] if id(part) not in sidewalk_ids
    ]
    over_opened["outer_ring_parts"] = [
        part for part in over_opened.get("outer_ring_parts", [])
        if id(part) not in sidewalk_ids
    ]
    over_opened["outer_ring_sidewalk"] = []
    results.append(("deleted solo curb-return sidewalk",
                    bool(visible_ring_gap_faults(over_opened))))
    return results


def main():
    source = ROUNDABOUT.read_text(encoding="utf-8")
    faults = static_faults(source)
    scenes = {}
    for name in ("uk4", "us4", "turbo4", "turbo3x", "turbo_width",
                 "hw4", "hw4us", "hw_oneway", "solo_flare", "stress",
                 "stress_us", "solo_bay", "solo_bay_us"):
        scene, case_faults = geometry_faults(name)
        scenes[name] = scene
        for fault in case_faults:
            faults.append(f"{name}: {fault}")
    # The shoulder-specific sector ownership exists for one concrete reason:
    # rigid shoulder/kerb taper facets otherwise leave outer-band crescents in
    # the ring sidewalk. Exercise both traffic hands with the strict annulus
    # scan so the eight-degree constant cannot silently regress to three.
    for name in ("hw4", "hw4us"):
        for fault in visible_ring_gap_faults(scenes[name], rings=240):
            faults.append(f"{name}: {fault}")

    # Exact subtraction has a second failure mode that overlap checks cannot
    # see: deleting too much concrete leaves bare curb-return crescents. Cover
    # a plain solo flare, tapered one-way highway shoulders, Bay roadway in
    # both traffic hands, and the mixed stress layouts. A bounded probe count
    # keeps this dynamic parity guard materially cheaper than the full CLI scan.
    for name in ("solo_flare", "hw_oneway", "solo_bay", "solo_bay_us",
                 "stress", "stress_us"):
        for fault in visible_ring_gap_faults(scenes[name]):
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
    print("roundabout 3D parity passed: exact solo footprint openings, edge handoffs, split mouth ownership, and width-safe Turbo")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
