#!/usr/bin/env python3
"""Bird's-eye contract for automatic versus cross-section road snapping.

The top row shows the ordinary network workflow: a snap creates a junction and
splits the target road.  The bottom row shows the advanced alignment workflow:
the new road meets the selected cross-section with a tangential lead-in, while
the target stays intact. Columns exercise the existing left / centre / right
roadway references.

This is a Python model, not Luau execution.  Source-linked checks below keep the
model tied to Settings, BuildBar, and createRoadSession.

    python cross_section_connection_preview.py --check
    python cross_section_connection_preview.py --out out/cross-section-connections.png
"""

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import sys

from raster import Canvas
from setup_wizard_preview import draw_text


ROOT = Path(__file__).resolve().parents[2]
SETTINGS_SOURCE = (ROOT / "src/Settings.lua").read_text(encoding="utf-8")
BUILD_BAR_SOURCE = (ROOT / "src/UI/BuildBar.lua").read_text(encoding="utf-8")
SESSION_SOURCE = (ROOT / "src/createRoadSession.lua").read_text(encoding="utf-8")
MAIN_SOURCE = (ROOT / "src/main.lua").read_text(encoding="utf-8")
FITTING_SOURCE = (ROOT / "src/Geometry/Fitting.lua").read_text(encoding="utf-8")

REFERENCES = ("LeftRoadwayEdge", "Centre", "RightRoadwayEdge")
MODES = ("AutomaticJunction", "CrossSection")

BACKGROUND = (25, 29, 36)
PANEL = (38, 44, 54)
PANEL_STROKE = (74, 83, 96)
ASPHALT = (68, 75, 88)
SHOULDER = (92, 99, 110)
MARKING = (225, 229, 234)
ACCENT = (217, 132, 85)
ALIGN = (69, 190, 199)
TEXT = (238, 239, 241)
DIM = (163, 171, 183)


@dataclass(frozen=True)
class ConnectionResult:
    mode: str
    reference: str
    lateral: float
    target_split: bool
    junction_generated: bool
    allows_start_midspan: bool


def selected_lateral(reference, half_width=1.0):
    if reference == "LeftRoadwayEdge":
        return -half_width
    if reference == "Centre":
        return 0.0
    if reference == "RightRoadwayEdge":
        return half_width
    raise ValueError(f"unsupported snap reference {reference}")


def connect(mode, reference, lateral_fn=selected_lateral):
    automatic = mode == "AutomaticJunction"
    return ConnectionResult(
        mode=mode,
        reference=reference,
        lateral=lateral_fn(reference),
        target_split=automatic,
        junction_generated=automatic,
        allows_start_midspan=not automatic,
    )


def choose_station_candidate(mode, endpoint_distance, midspan_distance):
    if mode == "AutomaticJunction":
        return "endpoint"
    return "midspan" if midspan_distance + 1e-4 < endpoint_distance else "endpoint"


def anchored_parallel_offsets(count, primary_index, spacing=1.0):
    raw = tuple((index - (count - 1) / 2) * spacing for index in range(count))
    origin = raw[primary_index]
    return tuple(value - origin for value in raw)


def _sub(a, b):
    return a[0] - b[0], a[1] - b[1]


def _add(a, b):
    return a[0] + b[0], a[1] + b[1]


def _scale(a, scalar):
    return a[0] * scalar, a[1] * scalar


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1]


def _length(a):
    return (_dot(a, a)) ** 0.5


def oriented_axis(axis, chord):
    chord_length = _length(chord)
    chord_direction = _scale(chord, 1 / chord_length) if chord_length > 1e-6 else (0.0, 1.0)
    axis_length = _length(axis)
    direction = _scale(axis, 1 / axis_length) if axis_length > 1e-6 else chord_direction
    return _scale(direction, -1) if _dot(direction, chord_direction) < 0 else direction


def tangent_right(tangent):
    direction = oriented_axis(tangent, tangent)
    return -direction[1], direction[0]


def solve_profile_endpoint(target, tangent_axis, chord, profile_offset):
    direction = oriented_axis(tangent_axis, chord)
    return _sub(target, _scale(tangent_right(direction), profile_offset))


def constrain_endpoint_tangents(p0, p1, p2, p3, start_axis=None, end_axis=None):
    """2-D port of Fitting.ConstrainEndpointTangents's cubic handle rule."""
    chord = _sub(p3, p0)
    chord_length = _length(chord)
    if chord_length < 1e-6:
        return p0, p1, p2, p3
    maximum_handle = chord_length / 3

    if start_axis is not None:
        handle = min(_length(_sub(p1, p0)), maximum_handle)
        if handle < 1e-4:
            handle = maximum_handle
        p1 = _add(p0, _scale(oriented_axis(start_axis, chord), handle))
    if end_axis is not None:
        handle = min(_length(_sub(p3, p2)), maximum_handle)
        if handle < 1e-4:
            handle = maximum_handle
        p2 = _sub(p3, _scale(oriented_axis(end_axis, chord), handle))
    return p0, p1, p2, p3


def tangency_faults(constrain_fn=constrain_endpoint_tangents):
    faults = []
    base = ((0.0, 70.0), (22.0, 38.0), (72.0, 38.0), (100.0, 0.0))
    horizontal = (1.0, 0.0)
    reversed_horizontal = (-1.0, 0.0)

    end_only = constrain_fn(*base, end_axis=horizontal)
    if end_only[0] != base[0] or end_only[3] != base[3]:
        faults.append("end lead-in moved a snapped endpoint")
    if end_only[1] != base[1]:
        faults.append("end lead-in changed the unconstrained start handle")
    end_derivative = _sub(end_only[3], end_only[2])
    if abs(end_derivative[1]) > 1e-7 or end_derivative[0] <= 0:
        faults.append("end lead-in is not tangent to the target cross-section")

    start_only = constrain_fn(*base, start_axis=reversed_horizontal)
    if start_only[0] != base[0] or start_only[3] != base[3]:
        faults.append("start lead-in moved a snapped endpoint")
    if start_only[2] != base[2]:
        faults.append("start lead-in changed the unconstrained end handle")
    start_derivative = _sub(start_only[1], start_only[0])
    if abs(start_derivative[1]) > 1e-7 or start_derivative[0] <= 0:
        faults.append("start lead-in did not orient the target tangent toward the road")

    both = constrain_fn(*base, start_axis=horizontal, end_axis=reversed_horizontal)
    if abs(_sub(both[1], both[0])[1]) > 1e-7 or abs(_sub(both[3], both[2])[1]) > 1e-7:
        faults.append("two-ended cross-section placement loses one terminal tangent")
    maximum_handle = _length(_sub(base[3], base[0])) / 3
    if _length(_sub(both[1], both[0])) > maximum_handle + 1e-7:
        faults.append("constrained tangent handle can loop beyond one-third chord")
    return faults


def profile_alignment_faults(solve_fn=solve_profile_endpoint):
    faults = []
    start_target = (12.0, 18.0)
    end_target = (112.0, 8.0)
    chord = _sub(end_target, start_target)
    tangent = (1.0, 0.0)
    # End offset includes a carried 2.0 m datum plus a 3.0 m LeftEdge
    # TransitionAnchor delta from a 12 m -> 18 m widening.
    for label, target, axis, offset in (
            ("start", start_target, (-1.0, 0.0), -3.5),
            ("end", end_target, tangent, 2.0 + (18.0 - 12.0) / 2),
    ):
        authored = solve_fn(target, axis, chord, offset)
        direction = oriented_axis(axis, chord)
        rendered = _add(authored, _scale(tangent_right(direction), offset))
        if _length(_sub(rendered, target)) > 1e-7:
            faults.append(f"{label} profile offset moves the visible carriageway off its snap target")
    return faults


def semantic_faults(
        connect_fn=connect,
        constrain_fn=constrain_endpoint_tangents,
        profile_solver=solve_profile_endpoint):
    faults = []
    for mode in MODES:
        for reference in REFERENCES:
            result = connect_fn(mode, reference)
            expected_lateral = selected_lateral(reference)
            if abs(result.lateral - expected_lateral) > 1e-9:
                faults.append(f"{mode}/{reference}: snap moved off the selected cross-section datum")
            if mode == "AutomaticJunction":
                if not result.target_split or not result.junction_generated:
                    faults.append(f"{mode}/{reference}: ordinary network snap stopped building a junction")
                if result.allows_start_midspan:
                    faults.append(f"{mode}/{reference}: default first-click behavior changed unexpectedly")
            else:
                if result.target_split or result.junction_generated:
                    faults.append(f"{mode}/{reference}: alignment-only snap mutated target topology")
                if not result.allows_start_midspan:
                    faults.append(f"{mode}/{reference}: alignment-only mode cannot start along a road")
    if choose_station_candidate("CrossSection", 6.0, 0.0) != "midspan":
        faults.append("CrossSection drags a nearby station back to the road endpoint")
    if choose_station_candidate("CrossSection", 0.0, 0.0) != "endpoint":
        faults.append("CrossSection loses exact endpoint tangent on a distance tie")
    if choose_station_candidate("AutomaticJunction", 6.0, 0.0) != "endpoint":
        faults.append("AutomaticJunction no longer preserves endpoint-first behavior")
    for count, primary_index in ((2, 0), (2, 1), (4, 2)):
        offsets = anchored_parallel_offsets(count, primary_index)
        if abs(offsets[primary_index]) > 1e-9:
            faults.append("parallel CrossSection has no generated carriageway on the snapped datum")
    faults.extend(tangency_faults(constrain_fn))
    faults.extend(profile_alignment_faults(profile_solver))
    return faults


def source_faults(
        settings_source=SETTINGS_SOURCE,
        build_bar_source=BUILD_BAR_SOURCE,
        session_source=SESSION_SOURCE,
        main_source=MAIN_SOURCE,
        fitting_source=FITTING_SOURCE):
    required = (
        (
            settings_source,
            'export type SnapConnectionMode = "AutomaticJunction" | "CrossSection"',
            "Settings has no persisted connection-mode union",
        ),
        (
            settings_source,
            'SnapConnectionMode = enumOr(\n\t\t\traw,\n\t\t\t"SnapConnectionMode",\n\t\t\t{ "AutomaticJunction", "CrossSection" },\n\t\t\t"AutomaticJunction"',
            "legacy settings do not default to automatic junctions",
        ),
        (
            build_bar_source,
            '{ Id = "AutomaticJunction", Text = "Build junction" }',
            "Road Tools does not expose ordinary junction mode",
        ),
        (
            build_bar_source,
            '{ Id = "CrossSection", Text = "Cross-section only" }',
            "Road Tools does not expose cross-section mode",
        ),
        (
            session_source,
            'return placementConnectionMode == "AutomaticJunction"',
            "placement has no canonical automatic-junction predicate",
        ),
        (
            session_source,
            "local snapSemanticsChanged = requestedMode ~= placementConnectionMode",
            "connection mode is not latched across an active placement chain",
        ),
        (
            session_source,
            "or requestedSnapToRoad ~= placementSnapToRoad",
            "Snap to road is not latched across an active placement chain",
        ),
        (
            session_source,
            "or requestedSnapReference ~= placementSnapReference",
            "snap reference is not latched across an active placement chain",
        ),
        (
            session_source,
            "if #points > 0 then\n\t\t\t\tcancelPlacement()",
            "switching connection mode can reinterpret captured snap matches",
        ),
        (
            session_source,
            "profileOffsetM = 0\n\t\thoverSnapPos = nil",
            "cancelling an edge-anchored chain leaks its lateral datum into the next road",
        ),
        (
            session_source,
            "if isStart or isEnd then",
            "cross-section mode cannot snap its first click mid-span",
        ),
        (
            session_source,
            "if midDistance + 1e-4 < endpointDistance then",
            "cross-section mode always drags nearby stations back to an endpoint",
        ),
        (
            session_source,
            "if automaticJunctionsEnabled() and not RoadSplit.CanSplit(child) then",
            "alignment-only mode still rejects feature-bearing target roads",
        ),
        (
            session_source,
            "alignmentOriginOffsetM = (anchorIndex - (count + 1) / 2) * spacingM",
            "parallel cross-section snaps still align an empty corridor median",
        ),
        (
            session_source,
            "then RoadProfile.TotalWidthM(data.ProfileStart) / 2 * settings.MetersToStuds + settings.SnapRadiusStuds",
            "automatic junctions lost the established full-profile click tolerance",
        ),
        (
            session_source,
            "if not settings.SnapToRoad or not automaticJunctionsEnabled() then\n\t\t\treturn {}",
            "alignment-only crossings can still create automatic X junctions",
        ),
        (
            session_source,
            "if not automaticJunctionsEnabled() then\n\t\t\t\treturn\n\t\t\tend",
            "alignment-only endpoints still mutate target topology",
        ),
        (
            main_source,
            "currentSession.RefreshPlacementSettings()",
            "changing snap settings leaves the stationary hover preview stale",
        ),
        (
            fitting_source,
            "function Fitting.ConstrainEndpointTangents(",
            "curve fitting has no persistent endpoint-tangent constraint",
        ),
        (
            fitting_source,
            "function Fitting.OrientedTangentAxis(axis: Vector3, chord: Vector3): Vector3",
            "endpoint fitting and profile-offset solving do not share a tangent-axis convention",
        ),
        (
            fitting_source,
            "function Fitting.TangentRightVector(tangent: Vector3): Vector3",
            "placement cannot solve the rendered profile centre from its authored curve datum",
        ),
        (
            fitting_source,
            "p1 = p0 + (segment.P1 - p0) * (2 / 3)",
            "quadratic lead-ins are not exactly degree-elevated before constraining",
        ),
        (
            session_source,
            "local function roadSnapTangent(data: RoadInstance.RoadData, station: number): Vector3",
            "lead-ins use the authored centreline tangent instead of the visible selected reference",
        ),
        (
            session_source,
            "Tangent = if automaticJunctionsEnabled() then nil else roadSnapTangent(data, station)",
            "mid-span cross-section snaps discard their target tangent",
        ),
        (
            session_source,
            "local hoverSnapMatch: SnapMatch? = nil",
            "hover state cannot retain the exact tangent-producing target",
        ),
        (
            session_source,
            "local position, _, snapped, snapMatch = placementPointFromGround(ground)",
            "hover refresh still discards the pending snap match",
        ),
        (
            session_source,
            "local segment = buildSegment(hoverPos, hoverSnapMatch)",
            "preview does not use the same tangential lead-in as commit",
        ),
        (
            session_source,
            "return Fitting.ConstrainEndpointTangents(segment, startTangentAxis, endTangentAxis)",
            "committed cross-section curves never apply their terminal tangents",
        ),
        (
            session_source,
            "local startOffsetM, endOffsetM = corridorProfileOffsetsM()",
            "cross-section endpoints ignore carried and transition-anchor profile offsets",
        ),
        (
            session_source,
            "Fitting.TangentRightVector(endDirection) * (endOffsetM * settings.MetersToStuds)",
            "the authored endpoint is not solved backward from the visible snap target",
        ),
        (
            session_source,
            "else Fitting.Straight(pts[1], pts[#pts])",
            "Straight mode can project away from its snapped cross-section endpoint",
        ),
    )
    return [message for source, marker, message in required if marker not in source]


def break_test_faults():
    failures = []

    def force_alignment_split(mode, reference):
        result = connect(mode, reference)
        if mode == "CrossSection":
            return ConnectionResult(mode, reference, result.lateral, True, True, True)
        return result

    def centre_every_reference(mode, reference):
        return connect(mode, reference, lateral_fn=lambda _reference: 0.0)

    def block_alignment_start(mode, reference):
        result = connect(mode, reference)
        if mode == "CrossSection":
            return ConnectionResult(mode, reference, result.lateral, False, False, False)
        return result

    def leave_abrupt(p0, p1, p2, p3, start_axis=None, end_axis=None):
        del start_axis, end_axis
        return p0, p1, p2, p3

    def move_terminal(p0, p1, p2, p3, start_axis=None, end_axis=None):
        result = constrain_endpoint_tangents(p0, p1, p2, p3, start_axis, end_axis)
        return result[0], result[1], result[2], (result[3][0] + 1, result[3][1])

    def leave_profile_datum_on_target(target, tangent_axis, chord, profile_offset):
        del tangent_axis, chord, profile_offset
        return target

    injected = (
        (lambda: semantic_faults(force_alignment_split), "alignment topology mutation"),
        (lambda: semantic_faults(centre_every_reference), "lost left/right datum"),
        (lambda: semantic_faults(block_alignment_start), "blocked first-click midspan"),
        (
            lambda: source_faults(SETTINGS_SOURCE.replace(' | "CrossSection"', "")),
            "missing settings mode",
        ),
        (
            lambda: source_faults(build_bar_source=BUILD_BAR_SOURCE.replace("Cross-section only", "Alignment")),
            "missing UI option",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("if isStart or isEnd then", "if isEnd then")),
            "missing start snap reachability",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("if midDistance + 1e-4 < endpointDistance then", "if false then")),
            "endpoint-near station ranking",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("if automaticJunctionsEnabled() and not RoadSplit.CanSplit(child) then", "if not RoadSplit.CanSplit(child) then")),
            "feature-bearing target rejection",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("if not settings.SnapToRoad or not automaticJunctionsEnabled() then", "if not settings.SnapToRoad then")),
            "automatic crossing leak",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("alignmentOriginOffsetM = (anchorIndex - (count + 1) / 2) * spacingM", "alignmentOriginOffsetM = 0")),
            "parallel anchor drift",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("then RoadProfile.TotalWidthM(data.ProfileStart) / 2 * settings.MetersToStuds + settings.SnapRadiusStuds", "then settings.SnapRadiusStuds")),
            "automatic tolerance regression",
        ),
        (
            lambda: source_faults(main_source=MAIN_SOURCE.replace("currentSession.RefreshPlacementSettings()", "")),
            "stale stationary hover",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("if #points > 0 then\n\t\t\t\tcancelPlacement()", "if false then")),
            "mid-placement connection mode flip",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("or requestedSnapToRoad ~= placementSnapToRoad", "or false")),
            "mid-placement Snap to road flip",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("or requestedSnapReference ~= placementSnapReference", "or false")),
            "mid-placement snap-reference flip",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("profileOffsetM = 0\n\t\thoverSnapPos = nil", "hoverSnapPos = nil")),
            "cancelled chain profile-offset leak",
        ),
        (lambda: semantic_faults(constrain_fn=leave_abrupt), "abrupt cross-section butt joint"),
        (lambda: semantic_faults(constrain_fn=move_terminal), "lead-in endpoint drift"),
        (
            lambda: semantic_faults(profile_solver=leave_profile_datum_on_target),
            "profile-offset endpoint drift",
        ),
        (
            lambda: source_faults(fitting_source=FITTING_SOURCE.replace("function Fitting.ConstrainEndpointTangents(", "function Fitting.Missing(")),
            "missing tangent fitter",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("local hoverSnapMatch: SnapMatch? = nil", "")),
            "missing hover target state",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("local segment = buildSegment(hoverPos, hoverSnapMatch)", "local segment = buildSegment(hoverPos, nil)")),
            "preview/commit tangent mismatch",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("return Fitting.ConstrainEndpointTangents(segment, startTangentAxis, endTangentAxis)", "return segment")),
            "missing committed tangent constraint",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("then nil else roadSnapTangent(data, station)", "then nil else nil")),
            "discarded mid-span tangent",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("else Fitting.Straight(pts[1], pts[#pts])", "else Fitting.StraightFromTangent(pts[1], tangent, pts[#pts])")),
            "Straight endpoint projection",
        ),
        (
            lambda: source_faults(session_source=SESSION_SOURCE.replace("local startOffsetM, endOffsetM = corridorProfileOffsetsM()", "local startOffsetM, endOffsetM = 0, 0")),
            "missing profile-centre endpoint solve",
        ),
    )
    for run, name in injected:
        if not run():
            failures.append(f"break-test did not catch {name}")
    return failures


def rect(canvas, left, top, right, bottom, color):
    canvas.fill_poly([(left, top), (right, top), (right, bottom), (left, bottom)], color)


def outline(canvas, left, top, right, bottom, color):
    canvas.line((left, top), (right, top), color)
    canvas.line((right, top), (right, bottom), color)
    canvas.line((right, bottom), (left, bottom), color)
    canvas.line((left, bottom), (left, top), color)


def dashed_line(canvas, a, b, color, width=2, dash=12, gap=9):
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    length = max((dx * dx + dy * dy) ** 0.5, 1e-9)
    distance = 0.0
    while distance < length:
        end = min(distance + dash, length)
        p0 = (a[0] + dx * distance / length, a[1] + dy * distance / length)
        p1 = (a[0] + dx * end / length, a[1] + dy * end / length)
        canvas.line(p0, p1, color, width)
        distance += dash + gap


def cubic_polyline(p0, p1, p2, p3, steps=28):
    points = []
    for index in range(steps + 1):
        t = index / steps
        u = 1 - t
        points.append((
            p0[0] * u ** 3 + p1[0] * 3 * u * u * t + p2[0] * 3 * u * t * t + p3[0] * t ** 3,
            p0[1] * u ** 3 + p1[1] * 3 * u * u * t + p2[1] * 3 * u * t * t + p3[1] * t ** 3,
        ))
    return points


def draw_panel(canvas, left, top, width, height, mode, reference):
    rect(canvas, left, top, left + width, top + height, PANEL)
    outline(canvas, left, top, left + width, top + height, PANEL_STROKE)
    title = reference.replace("RoadwayEdge", " edge").replace("Centre", "Centre")
    draw_text(canvas, left + 18, top + 16, title, TEXT, 2)

    road_y = top + 118
    road_left = left + 22
    road_right = left + width - 22
    rect(canvas, road_left, road_y - 30, road_right, road_y + 30, SHOULDER)
    rect(canvas, road_left, road_y - 24, road_right, road_y + 24, ASPHALT)
    dashed_line(canvas, (road_left, road_y), (road_right, road_y), MARKING, 2)
    canvas.line((road_left, road_y - 22), (road_right, road_y - 22), MARKING)
    canvas.line((road_left, road_y + 22), (road_right, road_y + 22), MARKING)

    lateral = selected_lateral(reference)
    snap_y = road_y + lateral * 21
    snap_x = left + width * 0.66
    ramp = cubic_polyline(
        (left + 42, top + height - 35),
        (left + 112, top + height - 70),
        (snap_x - 62, snap_y),
        (snap_x, snap_y),
    )
    canvas.polyline(ramp, SHOULDER, 20)
    canvas.polyline(ramp, ASPHALT, 14)
    canvas.polyline(ramp, MARKING, 2)

    if mode == "AutomaticJunction":
        canvas.disc(snap_x, snap_y, 18, ASPHALT)
        canvas.disc(snap_x, snap_y, 6, ACCENT)
        canvas.line((snap_x, road_y - 32), (snap_x, road_y + 32), ACCENT, 3)
        draw_text(canvas, left + 18, top + height - 24, "TARGET SPLIT + JUNCTION", ACCENT, 1)
    else:
        canvas.line((snap_x, road_y - 31), (snap_x, road_y + 31), ALIGN, 3)
        canvas.disc(snap_x, snap_y, 5, ALIGN)
        draw_text(canvas, left + 18, top + height - 24, "TARGET INTACT / TANGENT LEAD-IN", ALIGN, 1)


def render(path):
    canvas = Canvas(1410, 760, BACKGROUND)
    draw_text(canvas, 34, 24, "ROAD CROSS-SECTION CONNECTIONS", TEXT, 3)
    draw_text(canvas, 34, 60, "DEFAULT NETWORK BUILD ABOVE / CUSTOM ALIGNMENT BELOW", DIM, 1)
    panel_width = 440
    panel_height = 300
    x_positions = (24, 485, 946)
    for row, mode in enumerate(MODES):
        y = 92 + row * 326
        row_label = "BUILD JUNCTION" if mode == "AutomaticJunction" else "CROSS-SECTION ONLY"
        draw_text(canvas, 34, y - 16, row_label, ACCENT if row == 0 else ALIGN, 1)
        for x, reference in zip(x_positions, REFERENCES):
            draw_panel(canvas, x, y, panel_width, panel_height, mode, reference)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    canvas.save(path)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--out", default=str(Path(__file__).with_name("out") / "cross-section-connections.png"))
    args = parser.parse_args()

    faults = semantic_faults() + source_faults() + break_test_faults()
    if faults:
        for fault in faults:
            print("FAILED:", fault)
        return 1
    print("cross-section connection contract: PASS (6 scenarios, 26 injected breaks)")
    if not args.check:
        print(render(args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
