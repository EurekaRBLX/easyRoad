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
                          ISLAND_C, KIND_C, LANE_M, MARK_C, MARKING_W_M, MAX_SEGMENT_LENGTH,
                          MEDIAN_M, Part, PolyCurve, SCALE, SHOULDER_M, SIDEWALK_C, SW_M,
                          THICKNESS, build_stations, direction_of, emit_road, is_roadway,
                          offsets_m, point_in, rect, right_of, roadway_edges_m, unit)
from raster import Canvas


# --- RoundaboutBuilder constants ---------------------------------------------
SPLIT_ANGLE_RAD = math.radians(38)
MIN_SPLIT_RAD = math.radians(14)
MIN_KERB_GAP_RAD = math.radians(8)
SECTOR_MARGIN_RAD = math.radians(3)
MAX_SECTOR_HALF_RAD = math.radians(60)
SECTOR_INSET_RAD = math.radians(3)
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
    for i, c in enumerate(components):
        if not is_roadway(c) or direction_of(c) != 0:
            continue
        for g in groups.values():
            if g["idx"] and (abs(offs[i][1]-g["left"]) < 1e-6 or abs(offs[i][0]-g["right"]) < 1e-6):
                add(g, i)
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
    # is returned separately and emit_arm tapers that surface to zero.
    outboard_shoulder = set()
    cut_shoulder = 0.0
    indices = range(len(lanes)) if drive_on_left else range(len(lanes) - 1, -1, -1)
    for i in indices:
        if lanes[i][0] != "Shoulder":
            break
        outboard_shoulder.add(i)
        cut_shoulder += lanes[i][1]
    comps = [(kind, 0.0 if i in outboard_shoulder else w, 1 if directional else 0)
             for i, (kind, w, directional) in enumerate(lanes)]
    # This is the RING-side width. emit_arm replaces the physical Sidewalk
    # part while coordinating it with the shoulder taper outside the lanes.
    if solo:
        comps.insert(0, ("Sidewalk", ring_pav))
        comps.append(("Sidewalk", ring_pav))
    elif drive_on_left:
        comps.insert(0, ("Sidewalk", ring_pav))
    else:
        comps.append(("Sidewalk", ring_pav))
    lm, rm = roadway_edges_m(comps)
    outer = (-lm if drive_on_left else rm) * SCALE
    inner = (rm if drive_on_left else -lm) * SCALE
    return comps, outer, inner, (lm + rm) / 2, cut_shoulder


def emit_arm(curve, components, cut_pavement_m, cut_shoulder_m, cut_at_start,
             drive_on_left):
    """Emit fixed travel lanes with shoulder and pavement outside them.

    The Shoulder component is deliberately zero-width in `components`: it keeps
    the Drive/Shoulder boundary semantic (solid marking) without becoming a
    third running lane. The physical shoulder is an edge-anchored wedge from its
    full source width to zero; pavement begins at its outer edge and grows to
    the ring-side width.
    """
    sidewalk_indices = [i for i, c in enumerate(components) if c[0] == "Sidewalk"]
    needs_taper = cut_shoulder_m > 1e-6 or any(
        abs(components[i][1] - cut_pavement_m) > 1e-6 for i in sidewalk_indices)
    emitted = emit_road(curve, components, -ARM_SINK)
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
        return emitted, []

    parts = [p for p in emitted if p.name != "Sidewalk"]
    shoulder_parts = []

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
        arm_outward = -1.0 if drive_on_left else 1.0
        side_shoulder_m = cut_shoulder_m if outward == arm_outward else 0.0

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
                shoulder_parts.append(part)
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
            comps, outer, _inner, _centre, _shoulder = arm_from_group(
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


def turbo_spiral(center, ring_r, island_r, lanes, lane_m, drive_on_left, exits):
    """Port of RoundaboutBuilder.buildTurboMarkings.

    One peel per exit, running from the ring's own lane divider onto the EXIT
    ARM's lane boundary a short way down the arm, so the two are one line. Five
    earlier versions tried this with ring geometry alone and every one ended on
    the ring's outer EDGE line instead - see ROUNDABOUT.md 3.8.
    """
    lanes = max(1, int(lanes))
    if lanes < 2 or not exits:
        return [], []
    lane_studs = lane_m * SCALE
    travel = 1 if drive_on_left else -1
    mw = MARKING_W_M * SCALE
    dash, gap = TURBO_DASH_M * SCALE, TURBO_GAP_M * SCALE
    angles = [math.atan2(c.pos(0.0)[1] - center[1], c.pos(0.0)[0] - center[0])
              for c, _ in exits]

    out, spans = [], []
    for i, (curve, arm) in enumerate(exits):
        room = 2 * math.pi
        for j, other in enumerate(angles):
            if j != i:
                room = min(room, ((angles[i] - other) * travel) % (2 * math.pi))
        sweep = room * TURBO_PEEL_MAX_SHARE * TURBO_FLING_FRACTION * 2
        if sweep <= 1e-6:
            continue
        into = min(TURBO_PEEL_INTO_M * SCALE, curve.length * 0.9)
        # Which sign points outward is MEASURED, not assumed - see
        # RoundaboutBuilder; this has been got wrong twice by reasoning.
        b, br, _ = curve.frame(0.0)
        plus = math.hypot(b[0] + br[0]*arm["outer"] - center[0], b[1] + br[1]*arm["outer"] - center[1])
        minus = math.hypot(b[0] - br[0]*arm["outer"] - center[0], b[1] - br[1]*arm["outer"] - center[1])
        outer_sign = 1 if plus >= minus else -1
        # The exit arm may be narrower than the ring - see RoundaboutBuilder.
        arm_lanes = max(1, int((arm["outer"] + arm["inner"]) / lane_studs + 0.5))
        for k in range(1, lanes):
            if lanes - k > arm_lanes - 1:
                continue
            a0 = angles[i] - travel * sweep
            r0 = island_r + k * lane_studs
            off = outer_sign * (arm["outer"] - (lanes - k) * lane_studs)
            # TWO PHASES, not one blended curve - see RoundaboutBuilder.
            arc_n = max(4, math.ceil(sweep / TURBO_ARC_STEP_RAD))
            pts = []
            for j in range(arc_n + 1):
                ang = a0 + travel * sweep * (j / arc_n)
                pts.append((center[0] + math.cos(ang) * r0, center[1] + math.sin(ang) * r0))
            arm_n = max(4, math.ceil(into / max(1e-6, TURBO_ARC_STEP_RAD * r0)))
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

            d = total - dash
            while d >= 0:
                q0, q1 = at_len(d), at_len(d + dash)
                length = math.dist(q0, q1)
                if length > 1e-4:
                    fwd = unit((q1[0] - q0[0], q1[1] - q0[1]))
                    mid = ((q0[0] + q1[0]) / 2, (q0[1] + q1[1]) / 2)
                    out.append(Part("Marking", rect(mid, right_of(fwd), fwd, mw / 2, length / 2),
                                    MARK_C, mid, 0.03))
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
    return out, spans


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
    lane_studs = LANE_M * SCALE
    if lanes < 2:
        if spiral:
            faults.append(f"peel emitted on a {lanes}-lane ring; should fall back")
        return faults
    if not spiral:
        faults.append("Turbo selected but no peel emitted")
        return faults
    cx, cy = scene["center"]
    radii = [math.hypot(p.center[0] - cx, p.center[1] - cy) for p in spiral]

    # On SOME ring divider - not necessarily the innermost. A ring wider than
    # its exits emits no peel for the boundaries the arms cannot receive, so
    # pinning this to inner + one lane failed a correctly-built 3-lane ring.
    k_at_start = (min(radii) - inner) / lane_studs
    if abs(k_at_start - round(k_at_start)) > 0.35 or not (1 <= round(k_at_start) <= lanes - 1):
        faults.append(f"peel starts at r={min(radii):.1f}, which is {k_at_start:.2f} "
                      f"lanes off the island - not on any ring divider")

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
    # Greatest radius is the far end: the peel's radius is monotonic by
    # construction (ring arc at constant radius, then out along the arm), and
    # the rule below this one fails the case where it is not. Keyed per
    # (exit, divider) so a ring handing three of its four boundaries over
    # correctly cannot cover for the fourth.
    ends: dict = {}
    for n, k, a0, r0, a1, r1 in scene["spiral_spans"]:
        for a, r in ((a0, r0), (a1, r1)):
            if (n, k) not in ends or r > ends[(n, k)][1]:
                ends[(n, k)] = (a, r)
    for (n, k), (a, r) in sorted(ends.items()):
        arm_marks = scene["exit_markings"][n] if n < len(scene["exit_markings"]) else []
        if not arm_marks:
            continue
        tip = (cx + math.cos(a) * r, cy + math.sin(a) * r)
        near = min(math.dist(tip, q.center) for q in arm_marks)
        if near > reach:
            faults.append(f"exit {n} divider {k}: the peel ends {near:.1f} studs from that "
                          f"arm's own lane lines (allow {reach:.1f}) - it hands over to nothing")

    for _, _, _, r0, _, r1 in scene["spiral_spans"]:
        if r1 < r0 - 0.5:
            faults.append("peel moves inward along its own length")
            break
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
                     if c[0] != "Sidewalk" and (c[0] != "Shoulder" or c[1] > 1e-6))
        if want != got:
            faults.append(f"arm {n} ({arm['role']}): running surface was {want}, arm built {got}")
            continue
        source_shoulder = sum(w for k, w, _ in arm["source"] if k == "Shoulder")
        if abs(source_shoulder - arm["cut_shoulder"]) > 1e-6:
            faults.append(f"arm {n} ({arm['role']}): source shoulder is {source_shoulder:.2f} m, "
                          f"taper received {arm['cut_shoulder']:.2f} m")
        roadway = [c for c in arm["comps"] if c[0] != "Sidewalk"]
        shoulders = [i for i, c in enumerate(roadway) if c[0] == "Shoulder"]
        if source_shoulder <= 1e-6:
            continue
        if not shoulders or any(roadway[i][1] > 1e-6 for i in shoulders):
            faults.append(f"arm {n} ({arm['role']}): shoulder is not zero-width at the ring")
            continue
        # Outboard = the side the pavement/kerb is on, which armProfileFor puts
        # at index 0 for left-hand drive and last for right-hand.
        outboard_end = 0 if scene["drive_on_left"] else len(roadway) - 1
        if outboard_end not in shoulders:
            faults.append(f"arm {n} ({arm['role']}): shoulder sits at index {shoulders} of "
                          f"{len(roadway)} roadway strips, not at the outboard end "
                          f"({outboard_end}) - it is on the gore side, against the splitter")
    return faults


def check_shoulder_tapers(scene):
    """Measure the emitted shoulder polygons at both ends of every highway arm."""
    faults = []
    for n, taper in enumerate(scene["shoulder_tapers"]):
        pieces = taper["parts"]
        expected = taper["cut_shoulder"] * SCALE
        if expected <= 1e-6:
            if pieces:
                faults.append(f"arm {n}: emitted shoulder geometry with no source shoulder")
            continue
        if not pieces:
            faults.append(f"arm {n}: {expected:.2f}-stud source shoulder emitted no taper")
            continue
        first, last = pieces[0], pieces[-1]
        if taper["cut_at_start"]:
            cut_width = math.dist(first.poly[0], first.poly[1])
            ring_width = math.dist(last.poly[2], last.poly[3])
        else:
            ring_width = math.dist(first.poly[0], first.poly[1])
            cut_width = math.dist(last.poly[2], last.poly[3])
        if abs(cut_width - expected) > 0.05:
            faults.append(f"arm {n}: shoulder is {cut_width:.2f} studs at cut, expected {expected:.2f}")
        if ring_width > 0.05:
            faults.append(f"arm {n}: shoulder still {ring_width:.2f} studs wide at ring merge")
    return faults


def shoulder_taper_widths(taper):
    """Return emitted (cut, ring) widths in studs, or None without geometry."""
    pieces = taper["parts"]
    if not pieces:
        return None
    first, last = pieces[0], pieces[-1]
    if taper["cut_at_start"]:
        return (math.dist(first.poly[0], first.poly[1]),
                math.dist(last.poly[2], last.poly[3]))
    return (math.dist(last.poly[2], last.poly[3]),
            math.dist(first.poly[0], first.poly[1]))


def build(ring_r, ring_lanes, legs, drive_on_left, tag, grow=False, sidewalk=True,
          island=True, markings="Continuous"):
    """legs is a list of (degrees, approach component list).

    `grow` mirrors the plugin, and the plugin no longer grows: the requested
    radius is built as asked and `MinimumRadiusStuds` is advice shown in the
    panel. Kept as an option because the growth is still what
    `SuggestedRadiusStuds` is derived from, so it is occasionally useful to
    inspect the recommended ring alongside the requested one.
    """
    assert markings in ("Continuous", "SolidLanes", "Turbo"), markings
    if grow:
        ring_r = max(ring_r, suggested_radius_studs(legs, ring_lanes, LANE_M, drive_on_left))
    flow = 1 if drive_on_left else -1
    center = (0.0, 0.0)
    rc = ring_components(ring_lanes, LANE_M, drive_on_left, sidewalk)
    outerR = ring_r + sum(c[1] for c in rc)/2*SCALE
    ring_kerb = outerR - (SW_M*SCALE if sidewalk else 0.0)
    ro = offsets_m(rc)
    inner_half_m = ro[-1][1] if drive_on_left else -ro[0][0]
    island_r = ring_r - inner_half_m*SCALE
    run = min(max(outerR*ARM_RUN_FACTOR, ARM_RUN_MIN), ARM_RUN_MAX)
    cutR = outerR + run

    leg_info = []
    ring_curve = circle_segments(center, ring_r, drive_on_left)
    # Every mode keeps the ring's own concentric divider. Turbo ADDS a peel-off
    # at each exit on top of it - see RoundaboutBuilder.
    ring_parts = emit_road(ring_curve, rc, solid_lane_lines=(markings == "SolidLanes"))
    parts_ring_pavement = [p for p in ring_parts if p.name in ("Sidewalk", "Marking")]

    sectors, arm_parts, gore_tris, apron_tris = [], [], [], []
    exit_traces = []          # (curve, arm) per exit, for the turbo peel
    exit_markings = []        # per exit arm, that arm's OWN lane lines
    arm_kinds = []            # source group vs built arm, for check_arm_kinds
    shoulder_tapers = []      # emitted polygons, measured at cut and ring
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
        ea, xa = a + flow*esplit, a - flow*split
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
            comps, outer, inner, road_centre, cut_shoulder = arm_from_group(
                group, drive_on_left, solo, not travels_inward,
                SW_M if sidewalk else 0.0)
            merge = ring_kerb - outer
            span_centre = (group["left"] + group["right"]) / 2
            arm_outer_sign = -1.0 if drive_on_left else 1.0
            core_shift_local = -arm_outer_sign * cut_shoulder / 2
            core_centre = span_centre + core_shift_local * (1 if travels_inward else -1)
            lat_m = (core_centre - road_centre) if travels_inward else (core_centre + road_centre)
            # Source group kept alongside the built arm so check_arm_kinds can
            # compare the two rather than re-deriving what the arm ought to be.
            arm_kinds.append(dict(role="entry" if travels_inward else "exit",
                                  source=list(group["lanes"]), comps=comps,
                                  cut_shoulder=cut_shoulder))
            return dict(comps=comps, outer=outer, inner=inner, merge=merge,
                        lat=lat_m*SCALE, cut_pav=group["pav"],
                        cut_shoulder=cut_shoulder)

        entry_arm, exit_arm = make(inbound, True), make(outbound, False)
        entry = exit_ = None
        if entry_arm:
            p0 = (cut[0]+r[0]*entry_arm["lat"], cut[1]+r[1]*entry_arm["lat"])
            p1 = (math.cos(ea)*entry_arm["merge"], math.sin(ea)*entry_arm["merge"])
            entry = arm_curve(p0, inward, p1, rt(ea))
            emitted, shoulder_parts = emit_arm(
                entry, entry_arm["comps"], entry_arm["cut_pav"],
                entry_arm["cut_shoulder"], True, drive_on_left)
            arm_parts += emitted
            shoulder_tapers.append(dict(parts=shoulder_parts,
                                         cut_shoulder=entry_arm["cut_shoulder"],
                                         cut_at_start=True))
        if exit_arm:
            p0 = (math.cos(xa)*exit_arm["merge"], math.sin(xa)*exit_arm["merge"])
            p1 = (cut[0]+r[0]*exit_arm["lat"], cut[1]+r[1]*exit_arm["lat"])
            exit_ = arm_curve(p0, rt(xa), p1, (-inward[0], -inward[1]))
            emitted, shoulder_parts = emit_arm(
                exit_, exit_arm["comps"], exit_arm["cut_pav"],
                exit_arm["cut_shoulder"], False, drive_on_left)
            arm_parts += emitted
            shoulder_tapers.append(dict(parts=shoulder_parts,
                                         cut_shoulder=exit_arm["cut_shoulder"],
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

            def outer_edge(st):
                pp, rr, _ = only_curve.frame(max(0.0, min(only_curve.length, st)))
                return (pp[0]-rr[0]*only["outer"]*flow, pp[1]-rr[1]*only["outer"]*flow)

            st = only_curve.length if entry else 0.0
            away = -1 if entry else 1
            step = only_curve.length/96
            for _ in range(120):
                nxt = st + away*step
                if nxt < 0 or nxt > only_curve.length:
                    break
                st = nxt
                if math.hypot(*outer_edge(st)) > outer_radius:
                    break
            pe = outer_edge(st)
            edge_angle = math.atan2(pe[1], pe[0])
            sweep = angle_delta(merge_angle, edge_angle)
            half = max(0, abs(sweep)/2 - SECTOR_INSET_RAD)
            sectors.append((edge_angle + sweep/2, half, half))
        else:
            e_half = max(0, esplit-SECTOR_INSET_RAD)
            x_half = max(0, split-SECTOR_INSET_RAD)
            sectors.append((a, e_half if flow > 0 else x_half, x_half if flow > 0 else e_half))
        leg_info.append(dict(cut=cut, inward=inward))

        far = (cut[0]-inward[0]*70, cut[1]-inward[1]*70)
        stem = PolyCurve([Cubic(far, (far[0]+(cut[0]-far[0])/3, far[1]+(cut[1]-far[1])/3),
                                (far[0]+2*(cut[0]-far[0])/3, far[1]+2*(cut[1]-far[1])/3), cut)])
        arm_parts += emit_road(stem, spoke_profile)

    cl = clamp_sectors(sectors)
    min_radius = ring_kerb - MARKING_W_M*1.5*SCALE - 0.5
    kept, removed = [], 0
    for p in ring_parts:
        if p in parts_ring_pavement:
            rad = math.hypot(*p.center)
            if rad >= min_radius:
                ang = math.atan2(p.center[1], p.center[0])
                if any(angle_delta(ang, sa) <= ah and -angle_delta(ang, sa) <= bh
                       for sa, ah, bh in cl):
                    removed += 1
                    continue
        kept.append(p)
    parts = kept + arm_parts
    spiral, spiral_spans = (
        turbo_spiral(center, ring_r, island_r, ring_lanes, LANE_M, drive_on_left,
                     exit_traces)
        if markings == "Turbo" else ([], []))
    parts += spiral
    return dict(tag=tag, parts=parts, gore=gore_tris, apron=apron_tris,
                spiral=spiral, spiral_spans=spiral_spans, markings=markings,
                exit_markings=exit_markings, arm_kinds=arm_kinds,
                shoulder_tapers=shoulder_tapers,
                ring_r=ring_r, ring_lanes=ring_lanes, drive_on_left=drive_on_left,
                island_r=island_r, island=island, legs=leg_info,
                sectors=cl,
                outerR=outerR, ring_kerb=ring_kerb, cutR=cutR, center=center,
                n_ring=len(ring_parts), n_arms=len(arm_parts), removed=removed)


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
        for si in range(steps + 1):
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
          f"removed in mouths")
    ok = True
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
    shoulder_widths = [shoulder_taper_widths(t) for t in scene["shoulder_tapers"]
                       if t["cut_shoulder"] > 1e-6]
    shoulder_widths = [w for w in shoulder_widths if w is not None]
    if shoulder_widths:
        print(f"    shoulder taper: {len(shoulder_widths)} arms, "
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


def case(ring_r, ring_lanes, drive_on_left, legs, markings="Continuous"):
    return dict(ring_r=ring_r, ring_lanes=ring_lanes, drive_on_left=drive_on_left,
                legs=legs, markings=markings)


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
