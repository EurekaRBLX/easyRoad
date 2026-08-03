#!/usr/bin/env python3
"""Pre-render preview: simulate the PARTS RoadBuilder actually emits.

Everything before this modelled idealised centrelines and offset polygons.
Roblox does not get polygons - it gets rigid boxes, one per (component,
station interval), each a rotated rectangle approximating an arc. That is
where facets, sliver gaps and z-fighting live, and none of it is visible in
an idealised render.

Ported from src/Mesh/RoadBuilder.lua:
  buildStations  - adaptive stepping, incl. the offset-edge curvature term
  the deck-strip branch - Size = (width, h, nominalLength + padding),
                          CFrame = midFrame * CFrame.new(centerOffset, y, 0)
  curveMiterPad  - padding = |edgeDistance| * curvature * nominalLength + 0.08
  placeMarkingSpan - endpoints anchored to true curve positions
and src/Mesh/RoundaboutBuilder.lua for the ring / arms / sector opening.

Outputs two views per case:
  *_parts.png  - every emitted part drawn in its material colour
  *_gaps.png   - magenta ground; anything still magenta is BARE GROUND
"""
import argparse
import math
import os

from preview_core import *          # noqa: F401,F403  - shared emission core
from preview_core import (ARC_SAMPLES, ASPHALT_C, CHORD_TOLERANCE, Cubic, FLAT, GROUND,
                          ISLAND_C, KIND_C, LANE_M, MARK_C, MARKING_LIFT, MARKING_THICKNESS,
                          MARKING_W_M, MAX_SEGMENT_LENGTH,
                          MEDIAN_M, Part, PolyCurve, SCALE, SHOULDER_M, SIDEWALK_C, SW_M,
                          THICKNESS, build_stations, direction_of, emit_road, is_roadway,
                          offsets_m, point_in, rect, right_of, roadway_edges_m, unit)
from raster import Canvas


# --- RoundaboutBuilder constants ---------------------------------------------
SPLIT_ANGLE_RAD = math.radians(38)
MIN_SPLIT_RAD = math.radians(14)
SOLO_SPLIT_CLEARANCE_RAD = math.radians(3)
SOLO_SPLIT_MAX_RAD = math.radians(26)
MIN_KERB_GAP_RAD = math.radians(8)
SECTOR_MARGIN_RAD = math.radians(3)
MAX_SECTOR_HALF_RAD = math.radians(60)
SECTOR_INSET_RAD = math.radians(3)
# A paired highway mouth replaces its terminal hard shoulders with tapered
# shoulder/kerb wedges.  Their rigid outer facets sit farther inside the merge
# ray than an ordinary arm's full-width pavement, so the normal three-degree
# ownership overlap can delete ring sidewalk the taper has not reached yet.
# The strict component sweep closes the last outer-band crescent at eight
# degrees.  Keep this shoulder-specific: ordinary mouths still use the tighter
# three-degree opening, while solo mouths have their own seven-degree rule.
SHOULDER_SECTOR_INSET_RAD = math.radians(8)
# A single tangent arm has no splitter/apron blanket under its pavement edge.
# Keep a little more ring sidewalk than paired mouths so rigid arm quads overlap
# the ownership ray instead of exposing one-sample outer-band spikes. Width-fit
# solo flares can be narrower than twice seven degrees, so the actual inset is
# capped to a share of their measured sweep below.
SOLO_SECTOR_INSET_RAD = math.radians(7)
SOLO_SECTOR_OVERLAP_SHARE = 0.3
ARM_HANDLE = 0.30
ENTRY_SPLIT_SCALE = 0.8
GORE_SAMPLES = 18
APRON_SAMPLES = 24
# Two separate questions about the gore - see RoundaboutBuilder. Does the
# approach arrive with a median at all (measured at the cut), and on one that
# does not, how wide must the gore open before the splitter becomes a raised
# island instead of flat asphalt.
MEDIAN_AT_CUT_M = 0.5
ISLAND_MIN_WIDTH_M = 2.0
# Tapering nose the island grows back from there - see RoundaboutBuilder.
ISLAND_NOSE_TAPER_M = 6.0
NOSE_ARC_STEP_RAD = math.radians(2)
ARM_SINK = 0.05
ARM_RUN_FACTOR, ARM_RUN_MIN, ARM_RUN_MAX = 0.85, 28, 90

# Python can resolve equal-height overlaps by paint order; Studio cannot.  Keep
# the same plan-view pixels while recording a deterministic layer for the
# Turbo peel above the ordinary concentric divider.
ROADBUILDER_MARKING_ALT_STUDS = 0.004
MARKING_LAYER_GAP_STUDS = 0.005
TURBO_MARKING_LIFT = MARKING_LIFT + ROADBUILDER_MARKING_ALT_STUDS + MARKING_LAYER_GAP_STUDS
ARM_MARKING_CLIP_SAMPLES = 96
BAND_EXIT_SAMPLES = 96


def split_approach_lanes(components, inbound_sign, style_pav=SW_M):
    """Port of RoundaboutBuilder.splitApproachLanes.

    Collects INDICES and sorts them at the end. The undirected pass runs after
    the directional one, so appending as it goes put a shoulder at the inboard
    end of its own group however far outboard it actually sat - invisible while
    every strip came out as an identical-width Drive, and a hard shoulder down
    the middle of the mouth as soon as they did not.
    """
    offs = offsets_m(components)
    # Zero is meaningful: a motorway really has no pavement. The arm profile
    # still carries the ring-side width; emit_arm tapers only that outer strip
    # down to this source width without recentering the roadway.
    groups = {1: dict(lanes=[], idx=[], left=math.inf, right=-math.inf, pav=0.0),
              -1: dict(lanes=[], idx=[], left=math.inf, right=-math.inf, pav=0.0)}

    def add(g, i):
        g["idx"].append(i)
        g["left"] = min(g["left"], offs[i][0])
        g["right"] = max(g["right"], offs[i][1])

    for i, c in enumerate(components):
        if not is_roadway(c):
            continue
        d = direction_of(c)
        if d == inbound_sign:
            add(groups[1], i)
        elif d == -inbound_sign:
            add(groups[-1], i)
    # Grow through contiguous undirected reserve until stable. A single pass
    # misses the outer member of `[Shoulder, Shoulder, Drive]` when components
    # are visited left-to-right: only the inner shoulder is adjacent on pass 1.
    remaining = {i for i, c in enumerate(components)
                 if is_roadway(c) and direction_of(c) == 0}
    changed = True
    while changed:
        changed = False
        for i in list(remaining):
            for g in groups.values():
                if g["idx"] and (abs(offs[i][1]-g["left"]) < 1e-6
                                 or abs(offs[i][0]-g["right"]) < 1e-6):
                    add(g, i)
                    remaining.remove(i)
                    changed = True
                    break
    for g in groups.values():
        for i in sorted(g["idx"]):
            c = components[i]
            g["lanes"].append((c[0], c[1], direction_of(c) != 0))
        for i, c in enumerate(components):
            if c[0] != "Sidewalk":
                continue
            if abs(offs[i][1]-g["left"]) < 1e-6 or abs(offs[i][0]-g["right"]) < 1e-6:
                g["pav"] = c[1]
    return (groups[1] if groups[1]["lanes"] else None,
            groups[-1] if groups[-1]["lanes"] else None)


def arm_from_group(group, drive_on_left, solo=False, mirrored=False, ring_pav=SW_M):
    """`group["lanes"]` is in the APPROACH's left-to-right order.

    An arm whose own travel runs against the approach curve sees that
    cross-section mirrored, so its components list back to front - see
    RoundaboutBuilder.armProfileFor.
    """
    lanes = list(reversed(group["lanes"])) if mirrored else list(group["lanes"])
    # The hard shoulder remains in the profile at zero width so the marking
    # port sees Drive/Shoulder and emits a solid separator. Its real paved width
    # is returned separately and emit_arm tapers that surface to zero. A solo
    # one-way highway has open ground on BOTH sides rather than a sibling arm,
    # so both terminal shoulder runs taper; a paired mouth still tapers only its
    # traffic-outboard shoulder and leaves unusual internal reserve untouched.
    tapered_shoulders = set()

    def consume(indices):
        width = 0.0
        for i in indices:
            if lanes[i][0] != "Shoulder":
                break
            tapered_shoulders.add(i)
            width += lanes[i][1]
        return width

    if solo:
        cut_left = consume(range(len(lanes)))
        cut_right = consume(range(len(lanes) - 1, -1, -1))
    elif drive_on_left:
        cut_left, cut_right = consume(range(len(lanes))), 0.0
    else:
        cut_left, cut_right = 0.0, consume(range(len(lanes) - 1, -1, -1))
    comps = []
    previous_tapered = False
    for i, (kind, width, directional) in enumerate(lanes):
        tapered = i in tapered_shoulders
        # A run of hard-shoulder modules is one physical reserve and needs one
        # semantic Drive/Shoulder boundary, not a stack of zero-width markers.
        if tapered and previous_tapered:
            continue
        comps.append((kind, 0.0 if tapered else width,
                      1 if directional else 0))
        previous_tapered = tapered
    # This is the RING-side width. emit_arm replaces the physical Sidewalk
    # part while coordinating it with the shoulder taper outside the lanes.
    if solo:
        # There is no sibling arm or splitter, but the inboard side still opens
        # directly onto circulating asphalt. Keep a zero-width semantic
        # Sidewalk there so emit_arm can taper any SOURCE pavement away; only
        # the traffic-outboard pavement continues/grows to ring width.
        if drive_on_left:
            comps.insert(0, ("Sidewalk", ring_pav))
            comps.append(("Sidewalk", 0.0))
        else:
            comps.insert(0, ("Sidewalk", 0.0))
            comps.append(("Sidewalk", ring_pav))
    elif drive_on_left:
        comps.insert(0, ("Sidewalk", ring_pav))
    else:
        comps.append(("Sidewalk", ring_pav))
    lm, rm = roadway_edges_m(comps)
    outer = (-lm if drive_on_left else rm) * SCALE
    inner = (rm if drive_on_left else -lm) * SCALE
    core_shift = (cut_left - cut_right) / 2
    return comps, outer, inner, (lm + rm) / 2, (cut_left, cut_right), core_shift


def retarget_edge_line(parts, curve, cut_at_start, source_offset_m, ring_offset_m):
    """Shift only the preserved outboard line to its ring-end inset."""
    if source_offset_m is None or ring_offset_m is None:
        return
    marking_half = MARKING_W_M * SCALE / 2
    for part in parts:
        if (part.name != "Marking" or part.marking_offset_m is None
                or abs(part.marking_offset_m - source_offset_m) > 1e-6):
            continue
        a, b = part.from_station, part.to_station
        if a is None or b is None:
            continue

        def point_at(station):
            # RoadBuilder interpolates OffsetStartM -> OffsetEndM along the
            # marking span.  Entry curves end at the ring; exit curves start
            # there, so the same source/ring pair has opposite station order.
            alpha = station / curve.length if cut_at_start else 1.0 - station / curve.length
            offset_m = source_offset_m + (ring_offset_m - source_offset_m) * alpha
            position, right, _ = curve.frame(station)
            return (position[0] + right[0] * offset_m * SCALE,
                    position[1] + right[1] * offset_m * SCALE)

        p0, p1 = point_at(a), point_at(b)
        length = math.dist(p0, p1)
        if length <= 1e-6:
            continue
        forward = unit((p1[0] - p0[0], p1[1] - p0[1]))
        center = ((p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2)
        part.poly = rect(center, right_of(forward), forward, marking_half, length / 2)
        part.center = center


def emit_arm(curve, components, cut_pavement_m, cut_shoulders_m, cut_at_start,
             drive_on_left, marking_bounds=None, edge_line_offsets_m=None):
    """Emit fixed travel lanes with shoulder and pavement outside them.

    The Shoulder component is deliberately zero-width in `components`: it keeps
    the Drive/Shoulder boundary semantic (solid marking) without becoming a
    third running lane. The physical shoulder is an edge-anchored wedge from its
    full source width to zero; pavement begins at its outer edge and grows to
    the ring-side width.
    """
    sidewalk_indices = [i for i, c in enumerate(components) if c[0] == "Sidewalk"]
    cut_left_shoulder_m, cut_right_shoulder_m = cut_shoulders_m
    needs_taper = (cut_left_shoulder_m + cut_right_shoulder_m > 1e-6) or any(
        abs(components[i][1] - cut_pavement_m) > 1e-6 for i in sidewalk_indices)
    emitted = emit_road(curve, components, -ARM_SINK,
                        marking_bounds=marking_bounds)
    # Luau sinks only the arm surfaces. Markings have explicit ring ownership
    # and remain on the normal paint plane so the outboard edge line can meet
    # both the source road and ring without a vertical step.
    for part in emitted:
        if part.name == "Marking":
            part.y += ARM_SINK
    if edge_line_offsets_m is not None:
        retarget_edge_line(
            emitted,
            curve,
            cut_at_start,
            edge_line_offsets_m[0],
            edge_line_offsets_m[1],
        )
    offs = offsets_m(components)
    max_offset = sum(c[1] for c in components) / 2 * SCALE
    stations = build_stations(curve, MAX_SEGMENT_LENGTH, CHORD_TOLERANCE, max_offset)
    if not needs_taper:
        # Preserve the padded interior and ring-end overlap, but replace the
        # raised strip at the approach cut with an exact quad. That cap cannot
        # project diagonally over the adjoining carriageway.
        if sidewalk_indices and len(stations) >= 3:
            interval = 0 if cut_at_start else len(stations) - 2
            s0, s1 = stations[interval], stations[interval + 1]
            p0, r0, _ = curve.frame(s0)
            p1, r1, _ = curve.frame(s1)
            for index in sidewalk_indices:
                edge = offs[index]
                poly = [
                    (p0[0] + r0[0] * edge[0] * SCALE,
                     p0[1] + r0[1] * edge[0] * SCALE),
                    (p0[0] + r0[0] * edge[1] * SCALE,
                     p0[1] + r0[1] * edge[1] * SCALE),
                    (p1[0] + r1[0] * edge[1] * SCALE,
                     p1[1] + r1[1] * edge[1] * SCALE),
                    (p1[0] + r1[0] * edge[0] * SCALE,
                     p1[1] + r1[1] * edge[0] * SCALE),
                ]
                center = (sum(p[0] for p in poly) / 4,
                          sum(p[1] for p in poly) / 4)
                candidates = [p for p in emitted if p.name == "Sidewalk"]
                victim = min(candidates, key=lambda p: math.dist(p.center, center))
                emitted.remove(victim)
                emitted.append(Part("Sidewalk", poly, SIDEWALK_C, center,
                                    -ARM_SINK + 0.125 * SCALE))
        return emitted, {"left": [], "right": []}

    parts = [p for p in emitted if p.name != "Sidewalk"]
    shoulder_parts = {"left": [], "right": []}

    def ring_alpha(station):
        t = station / curve.length if cut_at_start else 1.0 - station / curve.length
        t = max(0.0, min(1.0, t))
        return t * t * (3.0 - 2.0 * t)

    for index in sidewalk_indices:
        edge = offs[index]
        left_side = (edge[0] + edge[1]) / 2 < 0
        outward = -1.0 if left_side else 1.0
        inner_m = edge[1] if left_side else edge[0]
        ring_pavement_m = components[index][1]
        side = "left" if left_side else "right"
        side_shoulder_m = (cut_left_shoulder_m if left_side
                           else cut_right_shoulder_m)

        def surface_points(station):
            alpha = ring_alpha(station)
            shoulder_m = side_shoulder_m * (1.0 - alpha)
            pavement_m = cut_pavement_m + (ring_pavement_m - cut_pavement_m) * alpha
            pos, right, _ = curve.frame(station)
            shoulder_outer_m = inner_m + outward * shoulder_m
            pavement_outer_m = shoulder_outer_m + outward * pavement_m
            shoulder_inner = (pos[0] + right[0] * inner_m * SCALE,
                              pos[1] + right[1] * inner_m * SCALE)
            shoulder_outer = (pos[0] + right[0] * shoulder_outer_m * SCALE,
                              pos[1] + right[1] * shoulder_outer_m * SCALE)
            pavement_inner = shoulder_outer
            pavement_outer = (pos[0] + right[0] * pavement_outer_m * SCALE,
                              pos[1] + right[1] * pavement_outer_m * SCALE)
            return (shoulder_inner, shoulder_outer, pavement_inner, pavement_outer,
                    shoulder_m, pavement_m)

        for s0, s1 in zip(stations, stations[1:]):
            sh_in0, sh_out0, pav_in0, pav_out0, sh_w0, pav_w0 = surface_points(s0)
            sh_in1, sh_out1, pav_in1, pav_out1, sh_w1, pav_w1 = surface_points(s1)
            if max(sh_w0, sh_w1) * SCALE >= 0.02:
                poly = [sh_in0, sh_out0, sh_out1, sh_in1]
                center = (sum(p[0] for p in poly) / 4, sum(p[1] for p in poly) / 4)
                part = Part("Shoulder", poly, KIND_C["Shoulder"], center, -ARM_SINK)
                parts.append(part)
                shoulder_parts[side].append(part)
            if max(pav_w0, pav_w1) * SCALE >= 0.02:
                poly = [pav_in0, pav_out0, pav_out1, pav_in1]
                center = (sum(p[0] for p in poly) / 4, sum(p[1] for p in poly) / 4)
                parts.append(Part("Sidewalk", poly, SIDEWALK_C, center,
                                  -ARM_SINK + 0.125 * SCALE))
    return parts, shoulder_parts


# --- roundabout --------------------------------------------------------------
def circle_segments(center, r, drive_on_left):
    K = 0.5522847498307936
    sign = 1 if drive_on_left else -1
    pt = lambda a: (center[0]+math.cos(a)*r, center[1]+math.sin(a)*r)
    tn = lambda a: (-math.sin(a)*sign, math.cos(a)*sign)
    segs = []
    h = r*K
    for i in range(4):
        a0 = sign*(i/4)*2*math.pi
        a1 = sign*((i+1)/4)*2*math.pi
        p0, p3 = pt(a0), pt(a1)
        t0, t1 = tn(a0), tn(a1)
        segs.append(Cubic(p0, (p0[0]+t0[0]*h, p0[1]+t0[1]*h),
                          (p3[0]-t1[0]*h, p3[1]-t1[1]*h), p3))
    return PolyCurve(segs)


def ring_components(lanes, lane_w, drive_on_left, sidewalk=True):
    comps = [("Drive", lane_w) for _ in range(lanes)]
    if not sidewalk:
        return comps
    if drive_on_left:
        comps.insert(0, ("Sidewalk", SW_M))
    else:
        comps.append(("Sidewalk", SW_M))
    return comps


def arm_components(spoke_lanes, lane_w, drive_on_left, spoke=None):
    lanes = max(1, spoke_lanes//2)
    comps = [("Drive", lane_w) for _ in range(lanes)]
    pav = SW_M
    for c in (spoke or []):
        if c[0] == "Sidewalk":
            pav = max(pav, c[1])
    if drive_on_left:
        comps.insert(0, ("Sidewalk", pav))
    else:
        comps.append(("Sidewalk", pav))
    return comps


def angle_delta(a, b):
    d = (a-b) % (2*math.pi)
    return d-2*math.pi if d > math.pi else d


def angular_half_span(part, center, center_angle):
    return max(
        abs(angle_delta(math.atan2(point[1]-center[1], point[0]-center[0]),
                        center_angle))
        for point in part.poly
    )


def clip_to_angular_side(poly, center, boundary_angle, keep_sign):
    """Clip convex `poly` to one side of a radial mouth-boundary line."""
    boundary = (math.cos(boundary_angle), math.sin(boundary_angle))

    def side(point):
        x, y = point[0]-center[0], point[1]-center[1]
        return keep_sign * (boundary[0]*y - boundary[1]*x)

    clipped = []
    previous = poly[-1]
    previous_side = side(previous)
    previous_inside = previous_side >= -1e-9
    for current in poly:
        current_side = side(current)
        current_inside = current_side >= -1e-9
        if current_inside != previous_inside:
            denominator = previous_side-current_side
            if abs(denominator) > 1e-12:
                t = previous_side/denominator
                clipped.append((previous[0]+(current[0]-previous[0])*t,
                                previous[1]+(current[1]-previous[1])*t))
        if current_inside:
            clipped.append(current)
        previous = current
        previous_side = current_side
        previous_inside = current_inside
    return clipped


def ring_boundary_intrusions(parts, center, sectors, tolerance=1e-7):
    """Return clipped-ring vertices that remain strictly inside a mouth."""
    intrusions = []
    for part in parts:
        for point in part.poly:
            angle = math.atan2(point[1]-center[1], point[0]-center[0])
            for sector_angle, ahead, behind in sectors:
                delta = angle_delta(angle, sector_angle)
                if delta < ahead-tolerance and -delta < behind-tolerance:
                    intrusions.append((part, point, sector_angle))
                    break
    return intrusions


def _signed_area(poly):
    return sum(a[0] * b[1] - b[0] * a[1]
               for a, b in zip(poly, poly[1:] + poly[:1])) / 2


def _convex_intersection(subject, clip, tolerance=1e-9):
    """Clip one convex plan-view footprint by another."""
    if len(subject) < 3 or len(clip) < 3:
        return []
    orientation = 1 if _signed_area(clip) >= 0 else -1
    out = list(subject)
    for a, b in zip(clip, clip[1:] + clip[:1]):
        if not out:
            break

        def side(point):
            return orientation * ((b[0] - a[0]) * (point[1] - a[1])
                                  - (b[1] - a[1]) * (point[0] - a[0]))

        clipped = []
        previous = out[-1]
        previous_side = side(previous)
        previous_inside = previous_side >= -tolerance
        for current in out:
            current_side = side(current)
            current_inside = current_side >= -tolerance
            if current_inside != previous_inside:
                denominator = previous_side - current_side
                if abs(denominator) > 1e-12:
                    t = previous_side / denominator
                    clipped.append((previous[0] + (current[0] - previous[0]) * t,
                                    previous[1] + (current[1] - previous[1]) * t))
            if current_inside:
                clipped.append(current)
            previous = current
            previous_side = current_side
            previous_inside = current_inside
        out = clipped
    return out


def open_angular_parts(parts, center, sectors, selected, clamp=True):
    """Delete/clip selected Part footprints inside angular ownership sectors."""
    sectors = clamp_sectors(sectors) if clamp else list(sectors)
    kept, removed, clipped = [], 0, 0
    for part in parts:
        if not selected(part):
            kept.append(part)
            continue
        angle = math.atan2(part.center[1] - center[1], part.center[0] - center[0])
        angular_half = angular_half_span(part, center, angle)
        handled = False
        for sector_angle, ahead, behind in sectors:
            delta = angle_delta(angle, sector_angle)
            fully_inside = (delta + angular_half <= ahead
                            and -delta + angular_half <= behind)
            if fully_inside:
                removed += 1
                handled = True
                break
            if delta <= ahead + angular_half and -delta <= behind + angular_half:
                # Pick the boundary the FOOTPRINT crosses, not the side its
                # centre happens to sit on.  A long tangential strip can have
                # its centre inside the sector while its ahead corner already
                # crosses the ahead ray; `delta > ahead` chose the opposite ray
                # for precisely that case and left the visible corner behind.
                ahead_overflow = delta + angular_half - ahead
                behind_overflow = -delta + angular_half - behind
                ahead_side = ahead_overflow >= behind_overflow
                boundary_angle = sector_angle + (ahead if ahead_side else -behind)
                outside = clip_to_angular_side(
                    part.poly, center, boundary_angle, 1 if ahead_side else -1)
                if len(outside) >= 3:
                    clipped_center = (sum(point[0] for point in outside) / len(outside),
                                      sum(point[1] for point in outside) / len(outside))
                    fragment = Part(part.name, outside, part.color, clipped_center, part.y)
                    fragment.marking_offset_m = part.marking_offset_m
                    fragment.from_station = part.from_station
                    fragment.to_station = part.to_station
                    kept.append(fragment)
                    clipped += 1
                else:
                    removed += 1
                handled = True
                break
        if not handled:
            kept.append(part)
    return kept, removed, clipped


def check_ring_openings(scene):
    """Raised pavement and edge paint own different mouth hand-offs."""
    faults = []
    sidewalk_intrusions = ring_boundary_intrusions(
        scene.get("outer_ring_sidewalk", []),
        scene["center"],
        scene.get("pavement_sectors", scene.get("sectors", [])),
    )
    if sidewalk_intrusions:
        faults.append(
            f"{len(sidewalk_intrusions)} sidewalk boundary vertices remain "
            "inside pavement mouth ownership"
        )
    marking_intrusions = ring_boundary_intrusions(
        scene.get("outer_ring_markings", []),
        scene["center"],
        scene.get("edge_marking_sectors", scene.get("sectors", [])),
    )
    if marking_intrusions:
        faults.append(
            f"{len(marking_intrusions)} outer edge-line vertices remain "
            "inside full-angle marking ownership"
        )
    return faults


def _overlap_area(a, b):
    overlap = _convex_intersection(a, b)
    return abs(_signed_area(overlap)) if len(overlap) >= 3 else 0.0


def check_visual_ownership(scene, area_tolerance=1e-5, height_tolerance=1e-6):
    """3D ownership invariants hidden by the Python painter.

    The raster resolves overlap by paint order, while Roblox needs distinct top
    planes. Turbo replaces the concentric divider over its peel arc; where it
    hands onto the exit arm, any remaining overlap must still have deterministic
    vertical ownership.
    """
    faults = []
    markings = [part for part in scene["parts"] if part.name == "Marking"]
    if scene.get("markings") == "Turbo":
        spiral_ids = {id(part) for part in scene["spiral"]}
        base = [part for part in markings if id(part) not in spiral_ids]
        for peel in scene["spiral"]:
            for ordinary in base:
                if _overlap_area(peel.poly, ordinary.poly) <= area_tolerance:
                    continue
                if abs(peel.y - ordinary.y) <= height_tolerance:
                    faults.append(
                        "Turbo peel and ordinary marking have coplanar top faces"
                    )
                    return faults
    return faults


def check_arm_marking_bounds(scene, station_tolerance=1e-5, radius_tolerance=0.02):
    """Arm lines stop at their own offset's ring-ownership crossing."""
    faults = []
    half_width = MARKING_W_M * SCALE / 2
    for index, record in enumerate(scene.get("arm_marking_bounds", [])):
        crossing = record["crossing"]
        if crossing is None:
            continue
        curve = record["curve"]
        position, right, _ = curve.frame(crossing)
        point = (position[0] + right[0] * record["offset_m"] * SCALE,
                 position[1] + right[1] * record["offset_m"] * SCALE)
        radius = math.dist(point, scene["center"])
        if abs(radius - record["clip_radius"]) > radius_tolerance:
            faults.append(
                f"arm line {index}: crossing radius {radius:.3f} differs from "
                f"clip radius {record['clip_radius']:.3f}"
            )
        for part in record["parts"]:
            if record["cut_at_start"] and part.to_station > crossing + station_tolerance:
                faults.append(f"arm line {index}: entry marking extends past its ToStation")
                break
            if not record["cut_at_start"] and part.from_station < crossing - station_tolerance:
                faults.append(f"arm line {index}: exit marking begins before its FromStation")
                break
            ring_kerb = record["clip_radius"] - half_width - MARKING_LAYER_GAP_STUDS
            if min(math.dist(vertex, scene["center"]) for vertex in part.poly) < ring_kerb - radius_tolerance:
                faults.append(f"arm line {index}: marking footprint intrudes into ring ownership")
                break
    return faults


def _point_segment_distance(point, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    length2 = dx * dx + dy * dy
    if length2 <= 1e-12:
        return math.dist(point, a)
    t = max(0.0, min(1.0,
                     ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / length2))
    return math.dist(point, (a[0] + dx * t, a[1] + dy * t))


def check_outboard_edge_handoffs(scene, station_tolerance=1e-5,
                                  footprint_tolerance=0.03):
    """Every arm keeps one outer line to its exact physical merge station."""
    faults = []
    records = [record for record in scene.get("arm_marking_bounds", [])
               if record.get("preserved")]
    expected = len(scene.get("arm_kinds", []))
    if len(records) != expected:
        faults.append(
            f"preserved {len(records)} outboard edge lines for {expected} arms"
        )
    marking_half = MARKING_W_M * SCALE / 2
    for index, record in enumerate(records):
        curve = record["curve"]
        terminal = curve.length if record["cut_at_start"] else 0.0
        parts = record.get("parts", [])
        if not parts:
            faults.append(f"arm edge {index}: preserved line emitted no parts")
            continue
        if record["cut_at_start"]:
            reaches = max(part.to_station for part in parts) >= terminal - station_tolerance
        else:
            reaches = min(part.from_station for part in parts) <= terminal + station_tolerance
        if not reaches:
            faults.append(f"arm edge {index}: line stops before its merge station")
            continue

        position, right, _ = curve.frame(terminal)
        ring_offset = record.get("ring_offset_m")
        if ring_offset is None:
            ring_offset = record["offset_m"]
        merge = (position[0] + right[0] * ring_offset * SCALE,
                 position[1] + right[1] * ring_offset * SCALE)
        distance = min(
            _point_segment_distance(merge, a, b)
            for part in parts
            for a, b in zip(part.poly, part.poly[1:] + part.poly[:1])
        )
        if distance > marking_half + footprint_tolerance:
            faults.append(
                f"arm edge {index}: geometry misses its ring handoff by {distance:.3f} studs"
            )
    return faults


def clamp_sectors(sectors):
    """sectors are (angle, ahead, behind)."""
    if not sectors:
        return []
    ss = sorted(sectors, key=lambda s: s[0])
    if len(ss) == 1:
        a, ah, bh = ss[0]
        return [(a, min(ah, MAX_SECTOR_HALF_RAD), min(bh, MAX_SECTOR_HALF_RAD))]
    out = []
    for i, (ang, ah, bh) in enumerate(ss):
        prev = ss[i-1][0]
        nxt = ss[(i+1) % len(ss)][0]
        gp = (ang-prev) % (2*math.pi)
        gn = (nxt-ang) % (2*math.pi)
        a2 = min(ah, MAX_SECTOR_HALF_RAD, max(0, (gn-MIN_KERB_GAP_RAD)/2))
        b2 = min(bh, MAX_SECTOR_HALF_RAD, max(0, (gp-MIN_KERB_GAP_RAD)/2))
        if a2 > 0 or b2 > 0:
            out.append((ang, a2, b2))
    return out


# RoundaboutBuilder.ISLAND_MIN_RADIUS_STUDS - buildIsland bails below 1.
ISLAND_MIN_RADIUS_STUDS = 2


def min_radius_studs(ring_lanes, lane_w, dol, sidewalk=True):
    """Port of RoundaboutBuilder.MinimumRadiusStuds - the HARD FLOOR.

    Below this the ring's inner edge has passed the centre and the annulus is a
    self-overlapping disc. Closed form: the ring's own inner half-width plus a
    minimum island.

    This name used to be attached to the function below, which computes the
    angular PACKING estimate - a different quantity, and the one the plugin
    renamed to SuggestedRadiusStuds when the two were separated. The preview
    never followed, so it carried a docstring claiming to port a function it
    did not, and check_parity.py reported the symptom as one orphan constant.
    """
    comps = ring_components(ring_lanes, lane_w, dol, sidewalk)
    o = offsets_m(comps)
    inner_half_m = o[-1][1] if dol else -o[0][0]
    return inner_half_m*SCALE + ISLAND_MIN_RADIUS_STUDS


def suggested_radius_studs(legs, lane_count, lane_w, dol):
    """Port of RoundaboutBuilder.SuggestedRadiusStuds - the ANGULAR PACKING fit.

    Every leg's two arms, its deflection split, and a strip of kerb before the
    next leg, summed against 360 degrees. A fine suggestion and a bad floor: the
    geometry holds to R=18 against packing numbers of 27 to 70 (ROUNDABOUT.md
    3.9).
    """
    total = widest = outer_off = 0.0
    for _, spoke in legs:
        inbound, outbound = split_approach_lanes(spoke, 1)
        solo = (inbound is None) != (outbound is None)
        # inbound_sign is +1 above, i.e. the junction is at the FAR end of the
        # approach, so the inward arm keeps the curve's frame and the outward
        # one is mirrored.
        for group, travels_inward in ((inbound, True), (outbound, False)):
            if not group:
                continue
            comps, outer, _inner, _centre, _shoulders, _core_shift = arm_from_group(
                group, dol, solo, not travels_inward)
            width = sum(c[1] for c in comps) * SCALE
            total += width
            widest = max(widest, width)
            outer_off = max(outer_off, outer)
    spare = 2 * math.pi - len(legs) * (2 * MIN_SPLIT_RAD + MIN_KERB_GAP_RAD)
    merge = total / spare if spare > 0.2 else total
    ring_w = max(1, lane_count) * lane_w + SW_M
    ring_half = max(ring_w * SCALE, widest) / 2
    return merge + outer_off + SW_M * SCALE - ring_half


# Angular step of one spiral span - see RoundaboutBuilder.TURBO_ARC_STEP_RAD.
TURBO_ARC_STEP_RAD = math.radians(2)
# Match the hard lower sampling bound in RoundaboutBuilder so extreme edited
# radii cannot make the exit-arm phase unbounded.
TURBO_MIN_SAMPLE_SPACING_STUDS = 0.5
# Fraction of each arc over which the boundary makes its outward move. It holds
# a constant radius for the rest - see RoundaboutBuilder.
TURBO_FLING_FRACTION = 0.35
# Deliberately tighter than the region's open-road LaneLine (1 m / 5 m), which
# puts ~5 dashes on a whole quadrant and reads as an unmarked ring. See
# RoundaboutBuilder.
# LONG mark, SHORT gap - the hazard ratio, not a permissive lane line. See
# RoundaboutBuilder.
TURBO_DASH_M, TURBO_GAP_M = 4.0, 2.0
# How far down the exit arm the peel lands, and its share of the gap back to
# the previous exit - see RoundaboutBuilder.
TURBO_PEEL_INTO_M = 9.0
TURBO_PEEL_MAX_SHARE = 0.5


def arm_drive_boundaries(arm, drive_on_left):
    """Actual Drive/Drive offsets, ordered from the arm's outside inward."""
    comps = arm["comps"]
    offs = offsets_m(comps)
    boundaries = [offs[i][1] * SCALE for i in range(len(comps) - 1)
                  if comps[i][0] == "Drive" and comps[i + 1][0] == "Drive"]
    outer_local = -arm["outer"] if drive_on_left else arm["outer"]
    return sorted(boundaries, key=lambda value: abs(value - outer_local))


def outboard_arm_edge_line_offsets_m(components, drive_on_left):
    """Source/ring offsets of the line that hands onto the ring edge.

    Ordinary arms use the inset roadway-edge line.  A highway arm carries its
    outboard hard shoulder to the ring as a zero-width semantic component;
    roundabout marking rules suppress the duplicate inset line and emit the
    Drive/Shoulder separator exactly at that zero-width boundary instead.  That
    separator starts at the true shoulder boundary but shifts to the normal
    inset at the ring, so it meets the ring edge line instead of ending one
    marking inset radially away from it.
    """
    offs = offsets_m(components)
    roadway = [i for i, component in enumerate(components) if is_roadway(component)]
    if not roadway:
        return None, None
    first, last = roadway[0], roadway[-1]
    inset = MARKING_W_M * 1.5
    if drive_on_left:
        component = components[first]
        covered = (component[0] == "Shoulder" and component[1] <= 1e-6
                   and first + 1 < len(components)
                   and components[first + 1][0] == "Drive")
        source = offs[first][1] if covered else offs[first][0] + inset
        return source, offs[first][0] + inset
    component = components[last]
    covered = (component[0] == "Shoulder" and component[1] <= 1e-6
               and last > 0 and components[last - 1][0] == "Drive")
    source = offs[last - 1][1] if covered else offs[last][1] - inset
    return source, offs[last][1] - inset


def band_exit_angle(curve, arm, from_station, away, center, outer_radius, flow):
    """Exact first crossing of an arm's outboard edge over the outer band."""
    def outer_edge(station):
        position, right, _ = curve.frame(max(0.0, min(curve.length, station)))
        return (position[0] - right[0] * arm["outer"] * flow,
                position[1] - right[1] * arm["outer"] * flow)

    def radius_at(station):
        return math.dist(outer_edge(station), center)

    station = max(0.0, min(curve.length, from_station))
    step = curve.length / BAND_EXIT_SAMPLES if curve.length > 1e-9 else 0.0
    if step > 0 and radius_at(station) <= outer_radius:
        for _ in range(BAND_EXIT_SAMPLES):
            next_station = max(0.0, min(curve.length, station + away * step))
            if abs(next_station - station) < 1e-9:
                break
            if radius_at(next_station) > outer_radius:
                inside, outside = station, next_station
                for _ in range(24):
                    mid = (inside + outside) / 2
                    if radius_at(mid) > outer_radius:
                        outside = mid
                    else:
                        inside = mid
                station = (inside + outside) / 2
                break
            station = next_station
    point = outer_edge(station)
    return math.atan2(point[1] - center[1], point[0] - center[0])


def solo_split_angle(arm, split_budget):
    """Fit a lone one-way merge to its width instead of the paired 38° fan."""
    half_width = (arm["outer"] + arm["inner"]) / 2
    ratio = max(0.0, min(0.95, half_width / max(arm["merge"], 1.0)))
    fit = math.asin(ratio)
    budget_cap = min(
        SOLO_SPLIT_MAX_RAD,
        max(MIN_SPLIT_RAD, split_budget - SECTOR_MARGIN_RAD),
    )
    return max(MIN_SPLIT_RAD, min(budget_cap, fit + SOLO_SPLIT_CLEARANCE_RAD))


def turbo_spiral(center, ring_r, island_r, lanes, lane_m, drive_on_left, exits):
    """Port of RoundaboutBuilder.buildTurboMarkings.

    One peel per exit, running from the ring's own lane divider onto the EXIT
    ARM's lane boundary a short way down the arm, so the two are one line. Five
    earlier versions tried this with ring geometry alone and every one ended on
    the ring's outer EDGE line instead - see ROUNDABOUT.md 3.8.
    """
    lanes = max(1, int(lanes))
    if lanes < 2 or not exits:
        return [], [], []
    lane_studs = lane_m * SCALE
    travel = 1 if drive_on_left else -1
    mw = MARKING_W_M * SCALE
    dash, gap = TURBO_DASH_M * SCALE, TURBO_GAP_M * SCALE
    angles = [math.atan2(c.pos(0.0)[1] - center[1], c.pos(0.0)[0] - center[0])
              for c, _ in exits]

    out, spans, replacements = [], [], []
    for i, (curve, arm) in enumerate(exits):
        room = 2 * math.pi
        for j, other in enumerate(angles):
            if j != i:
                room = min(room, ((angles[i] - other) * travel) % (2 * math.pi))
        sweep = room * TURBO_PEEL_MAX_SHARE * TURBO_FLING_FRACTION * 2
        if sweep <= 1e-6:
            continue
        into = min(TURBO_PEEL_INTO_M * SCALE, curve.length * 0.9)
        target_offsets = arm_drive_boundaries(arm, drive_on_left)
        for k in range(1, lanes):
            target_index = lanes - k
            if target_index > len(target_offsets):
                continue
            off = target_offsets[target_index - 1]
            r0 = island_r + k * lane_studs
            # A tiny requested ring can place an internal divider at or behind
            # the centre. It has no meaningful polar arc, and using that radius
            # as a spatial step denominator explodes into millions of samples.
            if r0 <= max(mw, 1e-3):
                continue
            base, base_right, _ = curve.frame(0.0)
            target = (base[0] + base_right[0] * off,
                      base[1] + base_right[1] * off)
            target_angle = math.atan2(target[1] - center[1], target[0] - center[0])
            target_radius = math.dist(target, center)
            a0 = target_angle - travel * sweep
            # Polar ease to the exit's real boundary radius, then follow that
            # boundary down the arm. This is what keeps edited ring lane widths
            # continuous with unequal/custom approach widths.
            arc_n = max(4, math.ceil(sweep / TURBO_ARC_STEP_RAD))
            pts = []
            for j in range(arc_n + 1):
                t = j / arc_n
                eased = t * t * (3 - 2 * t)
                radius = r0 + (target_radius - r0) * eased
                ang = a0 + travel * sweep * t
                pts.append((center[0] + math.cos(ang) * radius,
                            center[1] + math.sin(ang) * radius))
            arm_step = max(TURBO_MIN_SAMPLE_SPACING_STUDS,
                           TURBO_ARC_STEP_RAD * r0)
            arm_n = max(4, math.ceil(into / arm_step))
            for j in range(1, arm_n + 1):
                ap, ar, _ = curve.frame(into * j / arm_n)
                pts.append((ap[0] + ar[0] * off, ap[1] + ar[1] * off))
            cum = [0.0]
            for j in range(1, len(pts)):
                cum.append(cum[-1] + math.dist(pts[j - 1], pts[j]))
            total = cum[-1]

            def at_len(dd):
                dd = max(0.0, min(total, dd))
                for m in range(len(cum) - 1):
                    if dd <= cum[m + 1]:
                        sp = cum[m + 1] - cum[m]
                        f = (dd - cum[m]) / sp if sp > 1e-9 else 0.0
                        return (pts[m][0] + (pts[m + 1][0] - pts[m][0]) * f,
                                pts[m][1] + (pts[m + 1][1] - pts[m][1]) * f)
                return pts[-1]

            emitted = False
            d = total - dash
            while d >= 0:
                q0, q1 = at_len(d), at_len(d + dash)
                length = math.dist(q0, q1)
                if length > 1e-4:
                    fwd = unit((q1[0] - q0[0], q1[1] - q0[1]))
                    mid = ((q0[0] + q1[0]) / 2, (q0[1] + q1[1]) / 2)
                    out.append(Part("Marking", rect(mid, right_of(fwd), fwd, mw / 2, length / 2),
                                    MARK_C, mid, TURBO_MARKING_LIFT))
                    emitted = True
                    # Tagged with the exit it belongs to. check_turbo needs to
                    # ask about ONE peel's far end against ONE arm's lines;
                    # asked over the whole scene at once the question answers
                    # itself, because a peel and an arm's lane lines are both
                    # long and always cross somewhere.
                    spans.append((i, k,
                                  math.atan2(q0[1] - center[1], q0[0] - center[0]),
                                  math.hypot(q0[0] - center[0], q0[1] - center[1]),
                                  math.atan2(q1[1] - center[1], q1[0] - center[0]),
                                  math.hypot(q1[0] - center[0], q1[1] - center[1])))
                d -= dash + gap
            if emitted:
                replacements.append({
                    "divider_radius": r0,
                    "sector_angle": a0 + travel * sweep / 2,
                    "sector_half": sweep / 2,
                    "exit_index": i,
                    "divider_index": k,
                    "target_offset_m": off,
                    "target_point": target,
                    "landing_point": pts[-1],
                })
    return out, spans, replacements


def check_turbo(scene):
    """Invariants for the per-exit peel.

    Rewritten from the ones guarding the old full-ring spiral, which asserted
    "reaches the ring's outer edge at each exit" - the very property that turned
    out to BE the defect. A check inherited across a design change is worse than
    no check: it certifies the thing you just stopped wanting.

    What matters now is that the peel LEAVES the ring's own lane divider and
    ARRIVES on the exit arm's line. The second is tested against the arm's
    actual marking Parts rather than by recomputing where they ought to be, so
    it cannot agree with the emitter by construction.
    """
    faults = []
    if scene.get("markings") != "Turbo":
        return faults
    lanes, spiral = scene["ring_lanes"], scene["spiral"]
    inner = scene["island_r"]
    lane_studs = scene["lane_width_m"] * SCALE
    if lanes < 2:
        if spiral:
            faults.append(f"peel emitted on a {lanes}-lane ring; should fall back")
        return faults
    if not spiral:
        faults.append("Turbo selected but no peel emitted")
        return faults
    if not scene.get("turbo_replacements"):
        faults.append("Turbo emitted peels but did not replace their concentric divider arcs")
    cx, cy = scene["center"]
    replacements = scene.get("turbo_replacements", [])
    replacement_by_key = {
        (replacement["exit_index"], replacement["divider_index"]): replacement
        for replacement in replacements
    }

    # Every arm receives only dividers for which it has a real Drive/Drive
    # boundary, ordered outside-in.  This is deliberately independent of the
    # edited ring lane width; deriving the arm count from ringLaneWidth is the
    # bug that made Turbo disappear after changing that editor value.
    expected = {}
    for n, (_curve, arm) in enumerate(scene.get("exit_traces", [])):
        boundaries = arm_drive_boundaries(arm, scene["drive_on_left"])
        for k in range(1, lanes):
            target_index = lanes - k
            if target_index <= len(boundaries):
                expected[(n, k)] = boundaries[target_index - 1]
    missing = sorted(set(expected) - set(replacement_by_key))
    extra = sorted(set(replacement_by_key) - set(expected))
    if missing:
        faults.append(f"missing Turbo replacements for actual exit boundaries {missing}")
    if extra:
        faults.append(f"Turbo emitted replacements with no exit boundary {extra}")
    for key, offset_m in expected.items():
        replacement = replacement_by_key.get(key)
        if replacement and abs(replacement["target_offset_m"] - offset_m) > 1e-6:
            faults.append(
                f"exit {key[0]} divider {key[1]} targets {replacement['target_offset_m']:.3f} m; "
                f"actual arm boundary is {offset_m:.3f} m"
            )

    # Replacement metadata is also the base-divider ownership contract.  Each
    # peel must begin on a real ring divider even if its edited-width handoff
    # subsequently moves inward or outward.
    for replacement in replacements:
        k_at_start = (replacement["divider_radius"] - inner) / lane_studs
        if (abs(k_at_start - round(k_at_start)) > 1e-6
                or not (1 <= round(k_at_start) <= lanes - 1)):
            faults.append(
                f"peel replacement starts {k_at_start:.3f} lanes off the island, "
                "not on a ring divider"
            )

    # Landing: each peel's FAR END, against the lane lines of the exit it was
    # built for, and nothing else.
    #
    # Both halves of that had to be narrowed. The earlier form asked for the
    # nearest "Marking" of any kind, which was a real test while Turbo
    # suppressed the ring's lane lines and became a tautology the moment it
    # stopped - the peel lies exactly along a ring divider for its whole first
    # phase, so the nearest marking is ~0 always. Scoping it to the exit arms
    # was not enough either: measured over the whole peel it still passed a peel
    # rotated 40 degrees off its exit, because a 30-degree arc and an 80-stud
    # arm cross somewhere no matter how they are turned. Only the END of the
    # peel says anything about where it hands over.
    #
    # Third rule in this file invalidated by a design change it was not re-read
    # against - see ROUNDABOUT.md 3.8.
    reach = (TURBO_DASH_M + TURBO_GAP_M) * SCALE
    # Dashes are emitted from the far end back toward the ring, so the first
    # span's q1 is the physical landing even when an edited lane width makes the
    # peel move INWARD. Choosing the greatest radius silently picked the start
    # of those valid peels and is why the old validation missed the editor bug.
    ends: dict = {}
    for n, k, a0, r0, a1, r1 in scene["spiral_spans"]:
        ends.setdefault((n, k), (a1, r1))
    for (n, k), (a, r) in sorted(ends.items()):
        tip = (cx + math.cos(a) * r, cy + math.sin(a) * r)
        replacement = replacement_by_key.get((n, k))
        if replacement:
            miss = math.dist(tip, replacement["landing_point"])
            if miss > 0.05:
                faults.append(
                    f"exit {n} divider {k}: emitted peel misses its edited-width "
                    f"landing by {miss:.2f} studs"
                )
        arm_marks = scene["exit_markings"][n] if n < len(scene["exit_markings"]) else []
        if not arm_marks:
            continue
        near = min(math.dist(tip, q.center) for q in arm_marks)
        if near > reach:
            faults.append(f"exit {n} divider {k}: the peel ends {near:.1f} studs from that "
                          f"arm's own lane lines (allow {reach:.1f}) - it hands over to nothing")

    return faults


def check_arm_kinds(scene):
    """Running lanes stay lanes; a shoulder becomes a zero-width boundary.

    Earlier validation required every source roadway strip to keep full width
    at the ring, accidentally certifying a hard shoulder as a third lane. The
    correct invariant is that non-shoulder roadway components keep their kinds
    and widths, while the outboard shoulder survives only as a zero-width
    component at the merge so its Drive/Shoulder boundary remains solid.
    """
    faults = []
    for n, arm in enumerate(scene["arm_kinds"]):
        want = sorted((k, round(w, 4)) for k, w, _ in arm["source"] if k != "Shoulder")
        got = sorted((c[0], round(c[1], 4)) for c in arm["comps"]
                     if c[0] not in ("Sidewalk", "Shoulder"))
        if want != got:
            faults.append(f"arm {n} ({arm['role']}): running surface was {want}, arm built {got}")
            continue
        source_shoulder = sum(w for k, w, _ in arm["source"] if k == "Shoulder")
        cut_left, cut_right = arm["cut_shoulders"]
        roadway = [c for c in arm["comps"] if c[0] != "Sidewalk"]
        shoulders = [i for i, c in enumerate(roadway) if c[0] == "Shoulder"]
        remaining = sum(c[1] for c in roadway if c[0] == "Shoulder")
        expected_remaining = source_shoulder - cut_left - cut_right
        if abs(remaining - expected_remaining) > 1e-6:
            faults.append(
                f"arm {n} ({arm['role']}): source shoulder reserve is "
                f"{source_shoulder:.2f} m, tapers consume {cut_left:.2f}+"
                f"{cut_right:.2f} m but {remaining:.2f} m remains"
            )
        if source_shoulder <= 1e-6:
            continue
        if cut_left > 1e-6 and (not roadway or roadway[0][0] != "Shoulder"
                               or roadway[0][1] > 1e-6):
            faults.append(f"arm {n} ({arm['role']}): left shoulder is not zero-width at the ring")
        if cut_right > 1e-6 and (not roadway or roadway[-1][0] != "Shoulder"
                                or roadway[-1][1] > 1e-6):
            faults.append(f"arm {n} ({arm['role']}): right shoulder is not zero-width at the ring")
    return faults


def check_shoulder_tapers(scene):
    """Measure the emitted shoulder polygons at both ends of every highway arm."""
    faults = []
    for n, taper in enumerate(scene["shoulder_tapers"]):
        for side, expected_m in zip(("left", "right"), taper["cut_shoulders"]):
            pieces = taper["parts"][side]
            expected = expected_m * SCALE
            if expected <= 1e-6:
                if pieces:
                    faults.append(
                        f"arm {n} {side}: emitted shoulder geometry with no source shoulder"
                    )
                continue
            if not pieces:
                faults.append(
                    f"arm {n} {side}: {expected:.2f}-stud source shoulder emitted no taper"
                )
                continue
            first, last = pieces[0], pieces[-1]
            if taper["cut_at_start"]:
                cut_width = math.dist(first.poly[0], first.poly[1])
                ring_width = math.dist(last.poly[2], last.poly[3])
            else:
                ring_width = math.dist(first.poly[0], first.poly[1])
                cut_width = math.dist(last.poly[2], last.poly[3])
            if abs(cut_width - expected) > 0.05:
                faults.append(
                    f"arm {n} {side}: shoulder is {cut_width:.2f} studs at cut, "
                    f"expected {expected:.2f}"
                )
            if ring_width > 0.05:
                faults.append(
                    f"arm {n} {side}: shoulder still {ring_width:.2f} studs wide at ring merge"
                )
    return faults


def shoulder_taper_widths(taper):
    """Return emitted (cut, ring) widths for every tapered side."""
    widths = []
    for side, expected_m in zip(("left", "right"), taper["cut_shoulders"]):
        pieces = taper["parts"][side]
        if expected_m <= 1e-6 or not pieces:
            continue
        first, last = pieces[0], pieces[-1]
        if taper["cut_at_start"]:
            widths.append((math.dist(first.poly[0], first.poly[1]),
                           math.dist(last.poly[2], last.poly[3])))
        else:
            widths.append((math.dist(last.poly[2], last.poly[3]),
                           math.dist(first.poly[0], first.poly[1])))
    return widths


def arm_marking_ring_crossing(curve, offset_m, center, ring_kerb, cut_at_start):
    """Exact per-offset station where an arm marking enters ring ownership."""
    clip_radius = (ring_kerb + MARKING_W_M * SCALE / 2
                   + MARKING_LAYER_GAP_STUDS)
    outside_station = 0.0 if cut_at_start else curve.length
    ring_station = curve.length if cut_at_start else 0.0

    def radius_at(station):
        position, right, _ = curve.frame(station)
        point = (position[0] + right[0] * offset_m * SCALE,
                 position[1] + right[1] * offset_m * SCALE)
        return math.dist(point, center)

    if (radius_at(outside_station) <= clip_radius
            or radius_at(ring_station) > clip_radius):
        return None, clip_radius

    previous = outside_station
    crossing = None
    for i in range(1, ARM_MARKING_CLIP_SAMPLES + 1):
        station = outside_station + (ring_station - outside_station) * (
            i / ARM_MARKING_CLIP_SAMPLES)
        if radius_at(station) <= clip_radius:
            outside_s, inside_s = previous, station
            for _ in range(24):
                middle = (outside_s + inside_s) / 2
                if radius_at(middle) > clip_radius:
                    outside_s = middle
                else:
                    inside_s = middle
            crossing = (outside_s + inside_s) / 2
            break
        previous = station
    return crossing, clip_radius


def arm_marking_bounder(curve, center, ring_kerb, cut_at_start, records,
                        preserve_offset_m=None, preserve_ring_offset_m=None):
    """Return an emit_road callback mirroring clipArmMarkingLinesAtRing."""
    def bounds(offset_m):
        if (preserve_offset_m is not None
                and abs(offset_m - preserve_offset_m) < 1e-6):
            records.append(dict(curve=curve, offset_m=offset_m,
                                cut_at_start=cut_at_start, crossing=None,
                                clip_radius=None, lo=0.0, hi=curve.length,
                                preserved=True,
                                ring_offset_m=preserve_ring_offset_m))
            return 0.0, curve.length
        crossing, clip_radius = arm_marking_ring_crossing(
            curve, offset_m, center, ring_kerb, cut_at_start)
        lo, hi = 0.0, curve.length
        if crossing is not None:
            if cut_at_start:
                hi = crossing
            else:
                lo = crossing
        records.append(dict(curve=curve, offset_m=offset_m,
                            cut_at_start=cut_at_start, crossing=crossing,
                            clip_radius=clip_radius, lo=lo, hi=hi,
                            preserved=False, ring_offset_m=None))
        return lo, hi
    return bounds


def build(ring_r, ring_lanes, legs, drive_on_left, tag, grow=False, sidewalk=True,
          island=True, markings="Continuous", lane_width_m=LANE_M):
    """legs is a list of (degrees, approach component list).

    `grow` mirrors the plugin, and the plugin no longer grows: the requested
    radius is built as asked and `MinimumRadiusStuds` is advice shown in the
    panel. Kept as an option because the growth is still what
    `SuggestedRadiusStuds` is derived from, so it is occasionally useful to
    inspect the recommended ring alongside the requested one.
    """
    assert markings in ("Continuous", "SolidLanes", "Turbo"), markings
    if grow:
        ring_r = max(
            ring_r,
            suggested_radius_studs(legs, ring_lanes, lane_width_m, drive_on_left),
        )
    flow = 1 if drive_on_left else -1
    center = (0.0, 0.0)
    rc = ring_components(ring_lanes, lane_width_m, drive_on_left, sidewalk)
    outerR = ring_r + sum(c[1] for c in rc)/2*SCALE
    ring_kerb = outerR - (SW_M*SCALE if sidewalk else 0.0)
    ro = offsets_m(rc)
    inner_half_m = ro[-1][1] if drive_on_left else -ro[0][0]
    island_r = ring_r - inner_half_m*SCALE
    run = min(max(outerR*ARM_RUN_FACTOR, ARM_RUN_MIN), ARM_RUN_MAX)
    cutR = outerR + run

    leg_info = []
    ring_curve = circle_segments(center, ring_r, drive_on_left)
    # Build the ordinary concentric divider first. Turbo later replaces only
    # the arc owned by each peel, leaving the untouched portions concentric.
    ring_parts = emit_road(ring_curve, rc, solid_lane_lines=(markings == "SolidLanes"))
    ring_sidewalk = [p for p in ring_parts if p.name == "Sidewalk"]
    ring_markings = [p for p in ring_parts if p.name == "Marking"]

    pavement_sectors, edge_marking_sectors = [], []
    arm_parts, gore_tris, apron_tris = [], [], []
    exit_traces = []          # (curve, arm) per exit, for the turbo peel
    exit_markings = []        # per exit arm, that arm's OWN lane lines
    arm_marking_bounds = []   # exact per-offset ring ownership cuts
    arm_kinds = []            # source group vs built arm, for check_arm_kinds
    shoulder_tapers = []      # emitted polygons, measured at cut and ring
    solo_mouths = []          # source/merge rays for one-way flare diagnostics
    angles = [d for d, _ in legs]
    for deg, spoke_profile in legs:
        a = math.radians(deg)
        near = 2*math.pi
        for o in angles:
            if o == deg:
                continue
            ahead = (math.radians(o)-a) % (2*math.pi)
            near = min(near, ahead, 2*math.pi-ahead)
        budget = max(MIN_SPLIT_RAD, near/2 - MIN_KERB_GAP_RAD/2)
        split = max(MIN_SPLIT_RAD, min(SPLIT_ANGLE_RAD,
                                       max(MIN_SPLIT_RAD, budget-SECTOR_MARGIN_RAD)))
        esplit = max(MIN_SPLIT_RAD, split*ENTRY_SPLIT_SCALE)
        cut = (math.cos(a)*cutR, math.sin(a)*cutR)
        inward = (-math.cos(a), -math.sin(a))
        r = right_of(inward)
        rt = lambda ang: (-math.sin(ang)*flow, math.cos(ang)*flow)

        def arm_curve(p0, t0, p1, t1):
            h = max(2.0, math.dist(p0, p1)*ARM_HANDLE)
            return PolyCurve([Cubic(p0, (p0[0]+t0[0]*h, p0[1]+t0[1]*h),
                                    (p1[0]-t1[0]*h, p1[1]-t1[1]*h), p1)])

        # junction is at the far end of the approach here, so inbound sign is +1
        inbound, outbound = split_approach_lanes(spoke_profile, 1)

        solo = (inbound is None) != (outbound is None)

        def make(group, travels_inward):
            if not group:
                return None
            # Junction at the far end (inbound sign +1 above), so the outward
            # arm is the mirrored one - see armProfileFor.
            comps, outer, inner, road_centre, cut_shoulders, core_shift_local = arm_from_group(
                group, drive_on_left, solo, not travels_inward,
                SW_M if sidewalk else 0.0)
            merge = ring_kerb - outer
            span_centre = (group["left"] + group["right"]) / 2
            core_centre = span_centre + core_shift_local * (1 if travels_inward else -1)
            lat_m = (core_centre - road_centre) if travels_inward else (core_centre + road_centre)
            # Source group kept alongside the built arm so check_arm_kinds can
            # compare the two rather than re-deriving what the arm ought to be.
            arm_kinds.append(dict(role="entry" if travels_inward else "exit",
                                  source=list(group["lanes"]), comps=comps,
                                  cut_shoulders=cut_shoulders, solo=solo))
            return dict(comps=comps, outer=outer, inner=inner, merge=merge,
                        lat=lat_m*SCALE, cut_pav=group["pav"],
                        cut_shoulders=cut_shoulders)

        entry_arm, exit_arm = make(inbound, True), make(outbound, False)
        if solo:
            solo_split = solo_split_angle(entry_arm or exit_arm, budget)
            split = esplit = solo_split
        ea, xa = a + flow*esplit, a - flow*split
        entry = exit_ = None
        if entry_arm:
            p0 = (cut[0]+r[0]*entry_arm["lat"], cut[1]+r[1]*entry_arm["lat"])
            p1 = (math.cos(ea)*entry_arm["merge"], math.sin(ea)*entry_arm["merge"])
            entry = arm_curve(p0, inward, p1, rt(ea))
            edge_offsets = outboard_arm_edge_line_offsets_m(
                entry_arm["comps"], drive_on_left)
            first_record = len(arm_marking_bounds)
            emitted, shoulder_parts = emit_arm(
                entry, entry_arm["comps"], entry_arm["cut_pav"],
                entry_arm["cut_shoulders"], True, drive_on_left,
                arm_marking_bounder(entry, center, ring_kerb, True,
                                    arm_marking_bounds,
                                    edge_offsets[0], edge_offsets[1]),
                edge_offsets)
            for record in arm_marking_bounds[first_record:]:
                record["parts"] = [p for p in emitted
                                   if p.marking_offset_m is not None
                                   and abs(p.marking_offset_m - record["offset_m"]) < 1e-9]
            arm_parts += emitted
            shoulder_tapers.append(dict(parts=shoulder_parts,
                                         cut_shoulders=entry_arm["cut_shoulders"],
                                         cut_at_start=True))
        if exit_arm:
            p0 = (math.cos(xa)*exit_arm["merge"], math.sin(xa)*exit_arm["merge"])
            p1 = (cut[0]+r[0]*exit_arm["lat"], cut[1]+r[1]*exit_arm["lat"])
            exit_ = arm_curve(p0, rt(xa), p1, (-inward[0], -inward[1]))
            edge_offsets = outboard_arm_edge_line_offsets_m(
                exit_arm["comps"], drive_on_left)
            first_record = len(arm_marking_bounds)
            emitted, shoulder_parts = emit_arm(
                exit_, exit_arm["comps"], exit_arm["cut_pav"],
                exit_arm["cut_shoulders"], False, drive_on_left,
                arm_marking_bounder(exit_, center, ring_kerb, False,
                                    arm_marking_bounds,
                                    edge_offsets[0], edge_offsets[1]),
                edge_offsets)
            for record in arm_marking_bounds[first_record:]:
                record["parts"] = [p for p in emitted
                                   if p.marking_offset_m is not None
                                   and abs(p.marking_offset_m - record["offset_m"]) < 1e-9]
            arm_parts += emitted
            shoulder_tapers.append(dict(parts=shoulder_parts,
                                         cut_shoulders=exit_arm["cut_shoulders"],
                                         cut_at_start=False))
            exit_traces.append((exit_, exit_arm))
            # Kept by IDENTITY rather than found later by name or position.
            # check_turbo has to ask whether the peel lands on THE EXIT ARM's
            # own line, and every marking in the scene is named "Marking" - so
            # a search would happily match the ring's concentric divider, which
            # the peel lies along for its whole first phase. That is not a
            # hypothetical: the rule was written before Turbo kept the ring's
            # dividers, and once it did, "nearest other marking" became a
            # measurement of the line the peel STARTS on.
            exit_markings.append([p for p in emitted if p.name == "Marking"])

        if solo:
            only = entry_arm or exit_arm
            merge_angle = ea if entry_arm else xa
            solo_mouths.append(dict(
                source_angle=a,
                merge_angle=merge_angle,
                split=abs(angle_delta(a, merge_angle)),
                budget=budget,
                cut=cut,
                merge=(math.cos(merge_angle) * only["merge"],
                       math.sin(merge_angle) * only["merge"]),
                arm=only,
                role="entry" if entry_arm else "exit",
            ))

        if entry and exit_:
            def gore_edge(curve, sst, arm):
                p, rt_, _ = curve.frame(max(0.0, min(curve.length, sst)))
                io = arm["inner"]
                return (p[0]+rt_[0]*io*flow, p[1]+rt_[1]*io*flow)

            def kerb_crossing(curve, station, direction, arm):
                step = curve.length/128
                sc = station
                for _ in range(160):
                    nxt = sc + direction*step
                    if nxt < 0 or nxt > curve.length:
                        return max(0.0, min(curve.length, nxt))
                    if math.hypot(*gore_edge(curve, nxt, arm)) <= ring_kerb:
                        lo, hi = sc, nxt
                        for _ in range(24):
                            mid = (lo+hi)/2
                            if math.hypot(*gore_edge(curve, mid, arm)) > ring_kerb:
                                lo = mid
                            else:
                                hi = mid
                        return hi
                    sc = nxt
                return sc

            reach = min(entry.length, exit_.length)

            def gore_width(along):
                return math.dist(gore_edge(entry, along, entry_arm),
                                 gore_edge(exit_, exit_.length-along, exit_arm))
            # Where the raised island starts, and so where the flat apron in
            # front of it stops. The width test picks WHICH surface, not
            # whether there is one - the gore is never left open. Default
            # `reach`: a gore that never opens to island width is apron for its
            # whole length. See RoundaboutBuilder.
            start_along = reach
            if gore_width(0) >= MEDIAN_AT_CUT_M*SCALE:
                start_along = 0.0          # median arrives at the cut: continue it
            else:
                for i in range(65):
                    along = (i/64)*reach
                    if gore_width(along) >= ISLAND_MIN_WIDTH_M*SCALE:
                        start_along = along
                        break
            # Where the gore stops being beside the circulating carriageway
            # and starts being ON it. Nothing raised may begin past here - see
            # RoundaboutBuilder for the wedge that appeared when it could.
            # Two values: the apron stops at the first probe at/inside the
            # kerb (stopping short left a bare ring just outside it), the
            # island must start before the last probe still outside.
            kerb_in = kerb_out = reach
            for i in range(65):
                along = (i/64)*reach
                if (math.hypot(*gore_edge(entry, along, entry_arm)) <= ring_kerb
                        or math.hypot(*gore_edge(exit_, exit_.length-along, exit_arm)) <= ring_kerb):
                    # One probe PAST the crossing - see RoundaboutBuilder.
                    kerb_in = min(reach, (i+1)/64*reach)
                    kerb_out = max(0, i-1)/64*reach
                    break
            # The apron: flat asphalt from the cut to the island, or to the
            # kerb if the island never gets to start. On the arms' own inner
            # edges so it abuts both and overlaps neither.
            apron_end = min(start_along, kerb_in)
            if apron_end > 0:
                prev = None
                for i in range(APRON_SAMPLES+1):
                    along = (i/APRON_SAMPLES)*apron_end
                    pa = gore_edge(entry, along, entry_arm)
                    pb = gore_edge(exit_, exit_.length-along, exit_arm)
                    if prev:
                        apron_tris.append([prev[0], prev[1], pb])
                        apron_tris.append([prev[0], pb, pa])
                    prev = (pa, pb)
            if 0 < start_along < kerb_out:
                taper_start = max(0.0, start_along - ISLAND_NOSE_TAPER_M*SCALE)
                span = start_along - taper_start
                if span > 1e-3:
                    steps = max(2, APRON_SAMPLES//2)
                    prev = None
                    for i in range(steps+1):
                        t = i/steps
                        along = taper_start + t*span
                        pa = gore_edge(entry, along, entry_arm)
                        pb = gore_edge(exit_, exit_.length-along, exit_arm)
                        mid = ((pa[0]+pb[0])/2, (pa[1]+pb[1])/2)
                        pa = (mid[0]+(pa[0]-mid[0])*t, mid[1]+(pa[1]-mid[1])*t)
                        pb = (mid[0]+(pb[0]-mid[0])*t, mid[1]+(pb[1]-mid[1])*t)
                        if prev:
                            gore_tris.append([prev[0], prev[1], pb])
                            gore_tris.append([prev[0], pb, pa])
                        prev = (pa, pb)
            L, R, last_along = [], [], start_along
            if start_along < reach and start_along < kerb_out:
                for i in range(GORE_SAMPLES+1):
                    along = start_along + (i/GORE_SAMPLES)*(reach-start_along)
                    pa = gore_edge(entry, along, entry_arm)
                    pb = gore_edge(exit_, exit_.length-along, exit_arm)
                    if i > 0 and (math.hypot(*pa) <= ring_kerb or math.hypot(*pb) <= ring_kerb):
                        break
                    L.append(pa); R.append(pb); last_along = along
            for j in range(len(L)-1):
                gore_tris.append([L[j], R[j], R[j+1]])
                gore_tris.append([L[j], R[j+1], L[j+1]])
            if L and R:
                nose, tail = L[-1], R[-1]
                nose_end = gore_edge(entry, kerb_crossing(entry, last_along, 1, entry_arm), entry_arm)
                tail_end = gore_edge(exit_, kerb_crossing(exit_, exit_.length-last_along, -1, exit_arm), exit_arm)
                a0 = math.atan2(nose_end[1], nose_end[0])
                a1 = math.atan2(tail_end[1], tail_end[0])
                sweep = angle_delta(a1, a0)
                steps = max(1, math.ceil(abs(sweep)/NOSE_ARC_STEP_RAD))
                apex = ((nose[0]+tail[0])/2, (nose[1]+tail[1])/2)
                boundary = [nose, nose_end]
                for k in range(1, steps):
                    ang2 = a0 + sweep*(k/steps)
                    boundary.append((math.cos(ang2)*ring_kerb, math.sin(ang2)*ring_kerb))
                boundary += [tail_end, tail]
                for k in range(len(boundary)-1):
                    gore_tris.append([apex, boundary[k], boundary[k+1]])

        if not (entry and exit_):
            only = entry_arm or exit_arm
            only_curve = entry or exit_
            merge_angle = ea if entry else xa
            outer_radius = ring_kerb + (SW_M*SCALE if sidewalk else 0.0)
            st = only_curve.length if entry else 0.0
            away = -1 if entry else 1
            edge_angle = band_exit_angle(
                only_curve, only, st, away, center, outer_radius, flow)
            sweep = angle_delta(merge_angle, edge_angle)
            center_angle = edge_angle + sweep/2
            solo_inset = min(
                SOLO_SECTOR_INSET_RAD,
                abs(sweep) * SOLO_SECTOR_OVERLAP_SHARE,
            )
            pavement_half = max(0, abs(sweep)/2 - solo_inset)
            edge_half = abs(sweep)/2
            solo_mouths[-1]["pavement_half"] = pavement_half
            solo_mouths[-1]["opening_sweep"] = abs(sweep)
            pavement_sectors.append((center_angle, pavement_half, pavement_half))
            edge_marking_sectors.append((center_angle, edge_half, edge_half))
        else:
            has_tapered_shoulder = any(
                sum(arm["cut_shoulders"]) > 1e-6
                for arm in (entry_arm, exit_arm)
                if arm is not None
            )
            pavement_inset = (SHOULDER_SECTOR_INSET_RAD
                              if has_tapered_shoulder else SECTOR_INSET_RAD)
            e_half = max(0, esplit-pavement_inset)
            x_half = max(0, split-pavement_inset)
            pavement_sectors.append(
                (a, e_half if flow > 0 else x_half,
                 x_half if flow > 0 else e_half)
            )
            # These rays are the arm endpoints themselves.  Do not inset or
            # neighbour-clamp them: moving either ray breaks the exact tangent
            # handoff the preserved arm edge line was built to meet.
            edge_marking_sectors.append(
                (a, esplit if flow > 0 else split,
                 split if flow > 0 else esplit)
            )
        leg_info.append(dict(cut=cut, inward=inward))

        far = (cut[0]-inward[0]*70, cut[1]-inward[1]*70)
        stem = PolyCurve([Cubic(far, (far[0]+(cut[0]-far[0])/3, far[1]+(cut[1]-far[1])/3),
                                (far[0]+2*(cut[0]-far[0])/3, far[1]+2*(cut[1]-far[1])/3), cut)])
        arm_parts += emit_road(stem, spoke_profile)

    pavement_cl = clamp_sectors(pavement_sectors)
    edge_raw = list(edge_marking_sectors)
    min_radius = ring_kerb - MARKING_W_M*1.5*SCALE - 0.5
    kept, removed, clipped = open_angular_parts(
        ring_parts,
        center,
        pavement_cl,
        lambda part: part in ring_sidewalk,
        clamp=False,
    )
    kept, edge_removed, edge_clipped = open_angular_parts(
        kept,
        center,
        edge_raw,
        lambda part: part in ring_markings
        and math.dist(part.center, center) >= min_radius,
        clamp=False,
    )
    removed += edge_removed
    clipped += edge_clipped
    spiral, spiral_spans, turbo_replacements = (
        turbo_spiral(center, ring_r, island_r, ring_lanes, lane_width_m, drive_on_left,
                     exit_traces)
        if markings == "Turbo" else ([], [], []))
    # Replace, do not paint over, the ordinary concentric divider over each
    # peel arc. Mixed short/open-road and long/hazard dash phases are the
    # doubled "extra markings" visible in Studio.
    tolerance = max(0.5, MARKING_W_M * SCALE * 1.5)
    for replacement in turbo_replacements:
        divider_radius = replacement["divider_radius"]
        sector_angle = replacement["sector_angle"]
        sector_half = replacement["sector_half"]
        kept, turbo_removed, turbo_clipped = open_angular_parts(
            kept,
            center,
            [(sector_angle, sector_half, sector_half)],
            lambda part, radius=divider_radius: (
                part.name == "Marking"
                and abs(math.dist(part.center, center) - radius) <= tolerance
            ),
            clamp=False,
        )
        removed += turbo_removed
        clipped += turbo_clipped
    parts = kept + arm_parts
    outer_ring_sidewalk = [p for p in kept if p.name == "Sidewalk"]
    outer_ring_markings = [
        p for p in kept
        if p.name == "Marking" and math.dist(p.center, center) >= min_radius
    ]
    outer_ring_parts = outer_ring_sidewalk + outer_ring_markings
    parts += spiral
    return dict(tag=tag, parts=parts, gore=gore_tris, apron=apron_tris,
                spiral=spiral, spiral_spans=spiral_spans, markings=markings,
                turbo_replacements=turbo_replacements,
                exit_markings=exit_markings, exit_traces=exit_traces,
                arm_kinds=arm_kinds,
                arm_marking_bounds=arm_marking_bounds,
                shoulder_tapers=shoulder_tapers,
                solo_mouths=solo_mouths,
                outer_ring_parts=outer_ring_parts,
                outer_ring_sidewalk=outer_ring_sidewalk,
                outer_ring_markings=outer_ring_markings,
                ring_r=ring_r, ring_lanes=ring_lanes, lane_width_m=lane_width_m,
                drive_on_left=drive_on_left,
                island_r=island_r, island=island, legs=leg_info,
                sectors=pavement_cl,
                pavement_sectors=pavement_cl,
                edge_marking_sectors=edge_raw,
                outerR=outerR, ring_kerb=ring_kerb, cutR=cutR, center=center,
                n_ring=len(ring_parts), n_arms=len(arm_parts), removed=removed,
                clipped=clipped)


# --- rendering ---------------------------------------------------------------
def render(scene, outdir):
    """Two views: the parts as Studio would show them, and a bare-ground map."""
    cutR, center = scene["cutR"], scene["center"]
    S = 3.0
    SZ = int((cutR * 2 + 60) * S)
    tx = lambda p: (p[0] * S + SZ / 2, p[1] * S + SZ / 2)
    written = []
    for flat in (False, True):
        cv = Canvas(SZ, SZ, GROUND if flat else (250, 250, 250))
        cx, cy = tx(center)
        for p in sorted(scene["parts"], key=lambda q: q.y):
            cv.fill_poly([tx(v) for v in p.poly], FLAT if flat else p.color)
        for t in scene["apron"]:
            cv.fill_poly([tx(v) for v in t], FLAT if flat else ASPHALT_C)
        for t in scene["gore"]:
            cv.fill_poly([tx(v) for v in t], FLAT if flat else ISLAND_C)
        if scene["island_r"] > 1:
            if scene.get("island", True):
                cv.disc(cx, cy, scene["island_r"] * S, FLAT if flat else ISLAND_C)
        name = f"{scene['tag']}_{'gaps' if flat else 'parts'}.png"
        cv.save(os.path.join(outdir, name))
        written.append(name)
    if scene.get("solo_mouths"):
        cv = Canvas(SZ, SZ, (250, 250, 250))
        cx, cy = tx(center)
        for p in sorted(scene["parts"], key=lambda q: q.y):
            cv.fill_poly([tx(v) for v in p.poly], p.color)
        for t in scene["apron"]:
            cv.fill_poly([tx(v) for v in t], ASPHALT_C)
        for t in scene["gore"]:
            cv.fill_poly([tx(v) for v in t], ISLAND_C)
        if scene.get("island", True) and scene["island_r"] > 1:
            cv.disc(cx, cy, scene["island_r"] * S, ISLAND_C)
        for mouth in scene["solo_mouths"]:
            # Cyan is the source roadway axis; orange is the fitted merge ray.
            cv.line((cx, cy), tx(mouth["cut"]), (0, 185, 230), 3)
            cv.line((cx, cy), tx(mouth["merge"]), (232, 126, 71), 3)
            mx, my = tx(mouth["merge"])
            cv.disc(mx, my, 5, (232, 126, 71))
        name = f"{scene['tag']}_controls.png"
        cv.save(os.path.join(outdir, name))
        written.append(name)
    return written


def scan_gaps(scene, rings=240):
    """Sample the ring footprint and report anything no part covers.

    This is the whole point of the tool: an idealised render cannot show a
    sliver of bare ground between a deleted ring strip and the arm that was
    supposed to replace it, because idealised geometry has no strips.
    """
    island_r, outerR = scene["island_r"], scene["outerR"]
    parts, gore = scene["parts"], scene["gore"] + scene["apron"]
    pitch = (outerR - island_r) / rings
    holes = []
    for ri in range(rings):
        rad = island_r + (outerR - island_r) * (ri + 0.5) / rings
        n = max(120, int(rad * 6))
        for ai in range(n):
            ang = 2 * math.pi * ai / n
            pt = (math.cos(ang) * rad, math.sin(ang) * rad)
            if any(point_in(q.poly, pt) for q in parts):
                continue
            if any(point_in(t, pt) for t in gore):
                continue
            holes.append((rad - outerR, math.degrees(ang) % 360))
    return holes, pitch


def seam_steps(scene, probe=1.5, span=60.0, samples=1200):
    """Measure the cross-section step where each approach meets its arm pair.

    Sweeps the road's own perpendicular a little either side of the cut and
    compares how far the covered material reaches. A non-zero step here is the
    seam that reads as the pavement or kerb line jogging sideways at the mouth.
    """
    steps = []
    for leg in scene.get("legs", []):
        cut, inward = leg["cut"], leg["inward"]
        side = right_of(inward)

        def extent(at):
            origin = (cut[0] - inward[0] * at, cut[1] - inward[1] * at)
            lo = hi = None
            for i in range(samples + 1):
                d = -span + 2 * span * i / samples
                pt = (origin[0] + side[0] * d, origin[1] + side[1] * d)
                if any(point_in(q.poly, pt) for q in scene["parts"]):
                    lo = d if lo is None else min(lo, d)
                    hi = d if hi is None else max(hi, d)
            return lo, hi

        before, after = extent(probe), extent(-probe)
        if None in before or None in after:
            continue
        steps.append((abs(before[0] - after[0]), abs(before[1] - after[1])))
    return steps


def scan_mouths(scene, span=70.0, samples=420, steps=40, min_gap=0.2, max_skip=6.0):
    """Bare ground INSIDE each mouth, between the ring and the approach cut.

    `scan_gaps` only ever looks at the ring annulus (island_r -> outerR). On a
    40-stud ring that leaves outerR -> cutR entirely unexamined - 68% of the
    built radius, and every bit of the entry/exit slip: the arms, the gore, the
    splitter, the arm-to-approach seam. Everything this tool has certified
    about the mouths was certified about ground it never sampled.

    The hard part is that expected coverage out here is NOT a full annulus:
    between mouths there is legitimately open ground, so simply raising the
    annulus scan's outer bound flags acres of grass and gets ignored.

    So the envelope is SELF-DEFINING rather than modelled. Sweeping the road's
    own perpendicular at one station, the outermost covered points either side
    ARE the mouth's outer edges there - that is what got built. A gap strictly
    BETWEEN them is material missing from inside the mouth; anything past them
    is outside the road and none of this check's business. Nothing has to be
    described in advance, and the check cannot drift from the geometry because
    it is derived from it.

    Interior gaps are split by cause, because only one kind is a defect:

      * GORE - spans the mouth's own centreline, i.e. the space between a
        diverging entry and exit.
      * HOLE - does not touch the centre: a tear inside one arm's own width, or
        between an arm and the pavement that should meet it.

    BOTH are defects. Open gore used to be excused as by-design, on the
    reasoning that the splitter island only starts where the gore reaches
    MIN_GORE_WIDTH_M so the stretch before that is meant to be empty. That
    reasoning assumed the only two options were raised island or nothing.
    They are not: near the cut the wedge is the approach's own carriageway
    fanning into the mouth, and it should be flat asphalt (ROUNDABOUT.md
    5.3d). Under that design no part of the mouth is ever legitimately bare,
    so the excuse is gone and gore gaps fail like any other. The label is
    kept because it still says WHICH defect - a gore gap is the indentation,
    a hole is a tear.

    Also reports OVERHANG: raised kerb material lying over the carriageway.
    That is the opposite failure and the gap search structurally cannot see it -
    a gap search looks for material that is MISSING, and this is material that
    should not be there. It is the live "clipping" defect, a wedge of pavement
    jutting out across the asphalt at an arm end. Detected by classifying each
    swept sample as deck or raised and flagging raised material strictly inside
    the carriageway's own lateral span at that station.

    The splitter island is excluded from that by identity, not by geometry. It
    IS raised material strictly inside the mouth's lateral span - that is what a
    splitter is - so the overhang rule flags it on sight, and once the apron
    stopped the island being outrun by bare ground it flagged 60 to 75 samples a
    case of nothing but correctly built island. Testing whether a raised run
    straddles the mouth centreline does not separate them either: the entry and
    exit splits are asymmetric (ENTRY_SPLIT_SCALE), so the gore sits off-axis
    and half the island reads as off-centre. Tagging the gore triangles as
    "Island" rather than "Sidewalk" is exact, because it asks the only question
    that matters - which builder laid this - instead of inferring it.
    """
    # A gap narrower than the sweep's own sample pitch is one dark sample, not
    # a hole. With min_gap below the pitch this reported its own resolution
    # floor as geometry: a 0.33-stud "gore" at R=10, R=15 and on a 3/1
    # approach - exactly one pitch wide, every one of them gone at four times
    # the sample density.
    min_gap = max(min_gap, 2 * (2 * span / samples))

    # Bounding boxes first. A mouth sweep is tens of thousands of point tests
    # against every Part in the scene; without culling it takes minutes.
    boxed = []
    for q in scene["parts"]:
        xs = [v[0] for v in q.poly]
        ys = [v[1] for v in q.poly]
        boxed.append((min(xs), max(xs), min(ys), max(ys), q.poly, q.name))
    for t, kind in ([(t, "Island") for t in scene["gore"]]
                    + [(t, "Apron") for t in scene["apron"]]):
        xs = [v[0] for v in t]
        ys = [v[1] for v in t]
        boxed.append((min(xs), max(xs), min(ys), max(ys), t, kind))

    def hits_at(pt):
        """(anything covers it, asphalt covers it, raised kerb material does)."""
        x, y = pt
        any_hit = deck = raised = False
        for x0, x1, y0, y1, poly, name in boxed:
            if x0 <= x <= x1 and y0 <= y <= y1 and point_in(poly, pt):
                any_hit = True
                if name == "Sidewalk":
                    raised = True
                elif name != "Marking":
                    deck = True
        return any_hit, deck, raised

    def covered_at(pt):
        return hits_at(pt)[0]

    findings = []
    for index, leg in enumerate(scene.get("legs", [])):
        cut, inward = leg["cut"], leg["inward"]
        side = right_of(inward)
        reach = math.hypot(cut[0] - scene["center"][0], cut[1] - scene["center"][1]) - scene["outerR"]
        if reach <= 0:
            continue
        # The exact ring ownership ray is a shared polygon boundary. The
        # ray-based `point_in` predicate deliberately excludes some boundary
        # points, so sampling `si == steps` manufactures a one-row "hole" at
        # the mathematical handoff. scan_gaps owns the ring footprint itself;
        # this sweep owns the open interval from the cut up to that ray.
        for si in range(steps):
            at = reach * si / steps           # 0 = the cut, reach = the ring
            # `inward` points from the cut toward the centre, so stepping into
            # the mouth is PLUS inward. Subtracting it walked the other way,
            # down the plain approach road: every "no bare ground inside the
            # mouth envelope" this printed was measured over the one stretch
            # of road that was never in question. That is precisely the blind
            # spot the docstring above claims to have closed, reintroduced by
            # a sign - so it also explains why the OVERHANG check below has
            # never once reproduced the clipping defect (ROUNDABOUT.md 5.4).
            origin = (cut[0] + inward[0] * at, cut[1] + inward[1] * at)
            swept, classed = [], []
            for i in range(samples + 1):
                d = -span + 2 * span * i / samples
                pt = (origin[0] + side[0] * d, origin[1] + side[1] * d)
                any_hit, deck, raised = hits_at(pt)
                swept.append((d, any_hit))
                classed.append((d, deck, raised))
            hits = [d for d, h in swept if h]
            if len(hits) < 2:
                continue
            # Bound the envelope to THIS mouth. Taking the outermost covered
            # samples as the edges assumes the only thing the sweep can reach
            # is the mouth itself, which stops being true once a neighbouring
            # leg is closer than `span`: on a 45-stud ring with legs at 0 and
            # 65 degrees the sweep ran into the next road and reported the 44
            # studs of grass between them as a tear inside the mouth.
            #
            # So walk outward from the centreline instead and stop at the first
            # run of bare ground too wide to be a defect. The walk still starts
            # by finding material in each direction however far out it is, so a
            # gore standing wide open at the centre - the whole point of this
            # check - is still bracketed and still fails.
            def edge(direction):
                far, since = None, 0.0
                prev = 0.0
                for d, h in (swept if direction > 0 else reversed(swept)):
                    if direction * d < 0:
                        continue
                    if h:
                        far, since = d, 0.0
                    elif far is not None:
                        since += abs(d - prev)
                        if since > max_skip:
                            break
                    prev = d
                return far

            lo, hi = edge(-1), edge(1)
            if lo is None or hi is None:
                continue
            # OVERHANG: raised kerb material lying over the carriageway. The
            # gap search below can never see this - it looks for MISSING
            # material, and this is material that should not be there. It is
            # the live "clipping" defect: a wedge of pavement jutting out
            # across the asphalt at the arm end.
            deck_at = [d for d, dk, _ in classed if dk and lo <= d <= hi]
            if len(deck_at) >= 2:
                dlo, dhi = min(deck_at), max(deck_at)
                run = None
                for d, dk, rs in classed:
                    if rs and not dk and dlo < d < dhi:
                        run = d if run is None else run
                    elif run is not None:
                        if d - run >= min_gap:
                            findings.append(dict(leg=index + 1, at=at,
                                                 width=d - run, kind="overhang"))
                        run = None
            run_start = None
            for d, h in swept:
                if d < lo or d > hi:
                    continue
                if not h and run_start is None:
                    run_start = d
                elif h and run_start is not None:
                    width = d - run_start
                    if width >= min_gap:
                        findings.append(dict(leg=index + 1, at=at, width=width,
                                             kind="gore" if run_start <= 0.0 <= d else "hole"))
                    run_start = None
    return findings


def circulating_width(scene, steps=360):
    """Narrowest drivable width of the circulating carriageway, in studs.

    THE question a roundabout has to answer is whether you can drive round it.
    Bare ground cannot answer it - the way a too-small ring fails is the exact
    opposite of a hole. The splitter islands grow inward until they meet across
    the carriageway, and every square stud is covered, just covered in kerb. At
    R=10 a 4-leg 2+2 comes out as a four-pointed raised star with a hexagon of
    island in the middle and no ring at all, and scan_gaps calls it clean
    because nothing is missing.

    The overhang check cannot answer it either, and for a reason worth writing
    down: it deliberately excludes the splitter islands by identity, because a
    splitter IS raised material inside the mouth's lateral span and flagging it
    was pure noise (ROUNDABOUT.md 5.4). Correct for that question, blind to
    this one - here the splitter islands are exactly what is wrong.

    So: sweep each angle radially from the island to the kerb and total the
    DECK-only run. The minimum over all angles is how wide the ring gets at its
    tightest, and a ring narrower than a lane is not a roundabout.
    """
    center, island_r, outer = scene["center"], scene["island_r"], scene["ring_kerb"]
    deck, raised = [], []
    for q in scene["parts"]:
        xs = [v[0] for v in q.poly]
        ys = [v[1] for v in q.poly]
        box = (min(xs), max(xs), min(ys), max(ys), q.poly)
        if q.name == "Sidewalk":
            raised.append(box)
        elif q.name != "Marking":
            deck.append(box)
    for t in scene["gore"]:
        xs = [v[0] for v in t]
        ys = [v[1] for v in t]
        raised.append((min(xs), max(xs), min(ys), max(ys), t))

    def covers(boxes, pt):
        x, y = pt
        for x0, x1, y0, y1, poly in boxes:
            if x0 <= x <= x1 and y0 <= y <= y1 and point_in(poly, pt):
                return True
        return False

    # A negative island radius means the ring's inner edge has passed the
    # centre: the "annulus" is a self-overlapping disc and there is no ring at
    # all. Report it as zero drivable width rather than sweeping a band that
    # starts behind the origin, which is what made this metric pass R=8.
    if island_r <= 0:
        return 0.0, 0.0
    band = max(1.0, outer - island_r)
    rings = max(12, min(48, int(band * 3)))
    pitch = band / rings
    worst, worst_ang = band, 0.0
    for si in range(steps):
        ang = 2 * math.pi * si / steps
        run = 0.0
        for ri in range(rings):
            r = island_r + band * (ri + 0.5) / rings
            pt = (center[0] + math.cos(ang) * r, center[1] + math.sin(ang) * r)
            if covers(deck, pt) and not covers(raised, pt):
                run += pitch
        if run < worst:
            worst, worst_ang = run, math.degrees(ang)
    return worst, worst_ang


def cluster_gaps(holes, pitch, hairline):
    """Group bare-ground samples by angle and split real holes from hairlines.

    Shared by `report` and `validate.py` on purpose. A runner that re-derived
    the hairline rule would be a second implementation to disagree with the
    first, and the whole reason this rule exists is subtle: the ring's innermost
    strips are chords of the island circle, so their inner edge stands off it by
    (step/2)^2 / r - about 0.05 studs at default settings. An order of magnitude
    below anything visible, and no padding removes it without overlapping the
    island instead.

    Returns ({angle: (samples, depth)} for real clusters, count of hairlines).
    """
    by_ang = {}
    for dr, ang in holes:
        by_ang.setdefault(round(ang / 2) * 2, []).append(dr)
    real, thin = {}, 0
    for k, v in by_ang.items():
        depth = (max(v) - min(v)) + pitch
        if depth <= hairline:
            thin += 1
        else:
            real[k] = (v, depth)
    return real, thin


def check_solo_merges(scene, tolerance=1e-8):
    """Solo arms must use the width-fit flare rather than a paired mouth ray."""
    faults = []
    for index, mouth in enumerate(scene.get("solo_mouths", []), 1):
        expected = solo_split_angle(mouth["arm"], mouth["budget"])
        if abs(mouth["split"] - expected) > tolerance:
            faults.append(
                f"mouth {index} split {math.degrees(mouth['split']):.2f}° "
                f"!= width-fit {math.degrees(expected):.2f}°"
            )
        if mouth["split"] > SOLO_SPLIT_MAX_RAD + tolerance:
            faults.append(
                f"mouth {index} still uses a {math.degrees(mouth['split']):.2f}° "
                "paired-style tangent"
            )
        if mouth.get("pavement_half", 0.0) <= tolerance:
            faults.append(
                f"mouth {index} ring-sidewalk opening collapsed across the one-way road"
            )
    return faults


def report(scene, holes, pitch, hairline):
    """Clusters thinner than `hairline` studs are reported but not failed.

    The ring's innermost strips are chords of the island circle, so their inner
    edge stands off it by (step/2)^2 / r - about 0.05 studs at default settings.
    That is a hairline an order of magnitude below anything visible, and no
    amount of padding removes it without overlapping the island instead.
    """
    print(f"{scene['tag']}: {len(scene['parts'])} parts "
          f"({scene['n_ring']} ring, {scene['n_arms']} arms/stems), "
          f"{len(scene['gore'])} gore tris, {scene['removed']} ring pavement parts "
          f"removed and {scene['clipped']} boundary parts clipped in mouths")
    ok = True
    opening_faults = check_ring_openings(scene)
    if opening_faults:
        ok = False
        for fault in opening_faults:
            print(f"    RING OPENING: {fault}")
    else:
        print("    ring openings: inset pavement and full-angle edge-line handoffs are clear")
    mouth = scan_mouths(scene)
    mouth_over = [m for m in mouth if m["kind"] == "overhang"]
    if mouth_over:
        ok = False
        print(f"    MOUTH: {len(mouth_over)} OVERHANG samples - pavement over the "
              f"carriageway, worst {max(m['width'] for m in mouth_over):.2f} studs")
    bare = [(k, [m for m in mouth if m["kind"] == k]) for k in ("gore", "hole")]
    if any(g for _, g in bare):
        ok = False
        for kind, group in bare:
            if not group:
                continue
            what = "the indentation" if kind == "gore" else "a tear inside an arm"
            print(f"    MOUTH: {len(group)} bare-ground {kind.upper()} samples "
                  f"({what}), worst {max(m['width'] for m in group):.2f} studs wide")
            for m in sorted(group, key=lambda m: -m["width"])[:3]:
                print(f"        leg {m['leg']} at {m['at']:.1f} studs from the cut: "
                      f"{m['width']:.2f} studs")
    else:
        print("    MOUTH: no bare ground inside the mouth envelope")
    for fault in check_arm_kinds(scene):
        ok = False
        print(f"    ARM: {fault}")
    for fault in check_shoulder_tapers(scene):
        ok = False
        print(f"    SHOULDER: {fault}")
    for fault in check_outboard_edge_handoffs(scene):
        ok = False
        print(f"    EDGE HANDOFF: {fault}")
    solo_faults = check_solo_merges(scene)
    if solo_faults:
        ok = False
        for fault in solo_faults:
            print(f"    SOLO FLARE: {fault}")
    elif scene.get("solo_mouths"):
        angles = [math.degrees(mouth["split"]) for mouth in scene["solo_mouths"]]
        print(
            f"    solo flare: {min(angles):.2f}..{max(angles):.2f} degrees "
            f"(paired mouth {math.degrees(SPLIT_ANGLE_RAD):.0f} degrees)"
        )
    shoulder_widths = [width
                       for taper in scene["shoulder_tapers"]
                       for width in shoulder_taper_widths(taper)]
    if shoulder_widths:
        print(f"    shoulder taper: {len(shoulder_widths)} arm sides, "
              f"cut {min(w[0] for w in shoulder_widths):.2f}.."
              f"{max(w[0] for w in shoulder_widths):.2f} studs -> ring "
              f"{max(w[1] for w in shoulder_widths):.2f} studs")
    for fault in check_turbo(scene):
        ok = False
        print(f"    TURBO: {fault}")
    steps = seam_steps(scene)
    if steps:
        worst = max(max(a, b) for a, b in steps)
        print(f"    approach/arm seam: worst edge step {worst:.2f} studs "
              f"({'flush' if worst <= 0.5 else 'STEPPED'})")
    if not holes:
        print("    no bare ground inside the ring footprint")
        return ok
    real, thin = cluster_gaps(holes, pitch, hairline)
    if thin:
        print(f"    {thin} hairline clusters under {hairline:.2f} studs deep "
              f"(sample pitch {pitch:.3f}) - below visible, not failed")
    if not real:
        print("    no visible bare ground inside the ring footprint")
        return ok
    print(f"    BARE GROUND: {len(real)} clusters")
    for k in sorted(real):
        v, depth = real[k]
        print(f"      angle~{k:5.0f}deg  n={len(v):4d}  depth~{depth:.2f} studs  "
              f"r-outerR {min(v):+.1f}..{max(v):+.1f}")
    return False


def two_way(inbound, outbound, dol, lane=LANE_M, pav=SW_M):
    """Lanes tagged +1 toward the ring. Inbound keeps left for LHT."""
    inl = [("Drive", lane, 1)] * inbound
    outl = [("Drive", lane, -1)] * outbound
    middle = inl + outl if dol else outl + inl
    return [("Sidewalk", pav)] + middle + [("Sidewalk", pav)]


def one_way(lanes, into_ring, dol, lane=LANE_M, pav=SW_M):
    d = 1 if into_ring else -1
    return [("Sidewalk", pav)] + [("Drive", lane, d)] * lanes + [("Sidewalk", pav)]


def highway(lanes_each_way, dol, lane=LANE_M, shoulder=SHOULDER_M, median=MEDIAN_M):
    """Mirrors builtin_highway: a hard shoulder OUTBOARD of the lanes each way.

    No pavement - a motorway has none, which also means the arm's shoulder is
    the outermost thing in the cross-section and lands directly against the
    ring's kerb. That is the case the Direction=0 flattening got wrong.
    """
    inl = [("Drive", lane, 1)] * lanes_each_way
    outl = [("Drive", lane, -1)] * lanes_each_way
    sh = ("Shoulder", shoulder, 0)
    left = [sh] + inl if dol else [sh] + outl
    right = (outl if dol else inl) + [sh]
    return left + [("Median", median, 0)] + right


def one_way_highway(lanes, into_ring, dol, lane=LANE_M,
                     outer_shoulder=SHOULDER_M, inner_shoulder=None):
    """Mirror the built-in one-way highway, including both shoulders."""
    if inner_shoulder is None:
        inner_shoulder = max(SHOULDER_M * 0.4, 0.8)
    direction = 1 if into_ring else -1
    outer = ("Shoulder", outer_shoulder, 0)
    inner = ("Shoulder", inner_shoulder, 0)
    drives = [("Drive", lane, direction)] * lanes
    return ([outer] + drives + [inner]) if dol else ([inner] + drives + [outer])


def case(ring_r, ring_lanes, drive_on_left, legs, markings="Continuous",
         lane_width_m=LANE_M):
    return dict(ring_r=ring_r, ring_lanes=ring_lanes, drive_on_left=drive_on_left,
                legs=legs, markings=markings, lane_width_m=lane_width_m)


def CASE_TABLE(dol_default=True):
    d = dol_default
    return {
        "uk4": case(70, 2, True, [(a, two_way(2, 2, True)) for a in (90, 180, 270, 0)]),
        "uk3": case(60, 1, True, [(a, two_way(1, 1, True)) for a in (270, 30, 150)]),
        "us4": case(70, 2, False, [(a, two_way(2, 2, False)) for a in (90, 180, 270, 0)]),
        "uk5mini": case(40, 1, True, [(a, two_way(1, 1, True)) for a in (0, 72, 144, 216, 288)]),
        # Live reports: an X and a T turned into a roundabout at radius 30,
        # which is below what the approaches can fit. CreateAtJunction now grows
        # the radius; these carry the grown values.
        "liveX2": case(43, 1, True, [(a, two_way(1, 1, True)) for a in (0, 90, 180, 270)]),
        "liveX4": case(71, 2, True, [(a, two_way(2, 2, True)) for a in (0, 90, 180, 270)]),
        "liveT2": case(30, 1, True, [(90, two_way(1, 1, True)), (215, two_way(1, 1, True)),
                                     (325, two_way(1, 1, True))]),
        "liveT4": case(45, 2, True, [(90, two_way(2, 2, True)), (215, two_way(2, 2, True)),
                                     (325, two_way(2, 2, True))]),
        # Stress: every approach a different shape on one ring.
        "stress": case(70, 2, True, [
            (0, two_way(1, 1, True)),          # 2 lanes, one each way
            (90, one_way(1, True, True)),      # 1 lane, one-way INTO the ring
            (180, two_way(2, 2, True)),        # 4 lanes, 2/2
            (270, two_way(3, 1, True)),        # 4 lanes, 3 in / 1 out
        ]),
        "stress_us": case(70, 2, False, [
            (0, two_way(1, 1, False)),
            (90, one_way(1, False, False)),    # 1 lane, one-way OUT of the ring
            (180, two_way(2, 2, False)),
            (270, two_way(1, 3, False)),
        ]),
        # Turbo: the spiral has to line up with the exits, stay on the
        # carriageway, and wind WITH the traffic. Both hands, because
        # Ahead/Behind are absolute angles and travel is not.
        "turbo4": case(70, 2, True, [(a, two_way(2, 2, True)) for a in (0, 90, 180, 270)],
                       markings="Turbo"),
        "turbo3x": case(80, 3, False, [(a, two_way(2, 2, False)) for a in (270, 30, 150)],
                        markings="Turbo"),
        # Deliberately far from the approach width. The retired floor-based
        # algorithm inferred only one arm lane from 7.3 / 4.4 and emitted no
        # peel; the actual Drive/Drive boundary still gives Turbo a handoff.
        "turbo_width": case(
            95, 3, True,
            [(a, two_way(2, 2, True)) for a in (0, 90, 180, 270)],
            markings="Turbo", lane_width_m=4.4,
        ),
        # Shoulders. A hard shoulder is Direction=0 roadway and was arriving at
        # the mouth as a running lane - see check_arm_kinds. Both hands, because
        # which side the shoulder sits on flips with the hand of the road, and
        # one mixed ring because a motorway meeting ordinary streets is the
        # transition the live report was actually about.
        "hw4": case(80, 2, True, [(a, highway(2, True)) for a in (0, 90, 180, 270)]),
        "hw4us": case(80, 2, False, [(a, highway(2, False)) for a in (0, 90, 180, 270)]),
        "hwmix": case(75, 2, True, [
            (0, highway(2, True)),
            (90, two_way(2, 2, True)),
            (180, highway(3, True)),
            (270, two_way(1, 1, True)),
        ]),
        "hw_oneway": case(95, 3, True, [
            (0, one_way_highway(1, True, True)),
            (90, one_way_highway(3, False, True)),
            (180, one_way_highway(2, True, True)),
            (270, one_way_highway(3, False, True)),
        ]),
        # Focused one-way mouth geometry: one narrow entry, one wide exit and
        # one ordinary two-way leg. The controls render overlays the source
        # axes (cyan) and fitted merge rays (orange).
        "solo_flare": case(80, 2, True, [
            (90, one_way_highway(1, True, True)),
            (210, one_way_highway(3, False, True)),
            (330, two_way(2, 2, True)),
        ]),
    }


CASES = CASE_TABLE()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cases", nargs="*", default=None,
                    help=f"cases to run (default: uk4 uk3 us4). known: {' '.join(CASES)}")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"),
                    help="directory for the PNGs")
    ap.add_argument("--no-render", action="store_true", help="scan only, write no PNGs")
    ap.add_argument("--hairline", type=float, default=0.15,
                    help="bare-ground clusters shallower than this (studs) are "
                         "reported but do not fail the run")
    args = ap.parse_args()
    names = args.cases or ["uk4", "uk3", "us4"]
    os.makedirs(args.out, exist_ok=True)
    ok = True
    for name in names:
        if name not in CASES:
            raise SystemExit(f"unknown case {name!r}; known: {' '.join(CASES)}")
        scene = build(tag=name, **CASES[name])
        holes, pitch = scan_gaps(scene)
        ok &= report(scene, holes, pitch, args.hairline)
        if not args.no_render:
            for f in render(scene, args.out):
                print(f"    wrote {os.path.join(args.out, f)}")
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
