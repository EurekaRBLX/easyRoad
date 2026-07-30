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

from raster import Canvas

# --- RoadBuilder constants ---------------------------------------------------
CHORD_TOLERANCE = 0.05
MIN_STEP = 0.4
MAX_TURN_PER_STEP = 0.2
MARKING_THICKNESS = 0.05
MAX_SEGMENT_LENGTH = 8.0          # settings.MaxSegmentLengthStuds
ARC_SAMPLES = 64                  # CurveSegment.ARC_SAMPLES

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

# --- region / settings -------------------------------------------------------
SCALE = 3.571
SW_M, LANE_M = 2.0, 3.65
MARKING_W_M = 0.1
THICKNESS = 1.0

ASPHALT_C = (60, 60, 60)
SIDEWALK_C = (168, 168, 168)
MARK_C = (245, 245, 245)
ISLAND_C = (150, 150, 150)
GROUND = (255, 0, 200)
FLAT = (70, 70, 70)


# --- geometry ----------------------------------------------------------------
def unit(v):
    m = math.hypot(v[0], v[1])
    return (v[0]/m, v[1]/m) if m > 1e-9 else (0.0, 0.0)


def right_of(t):
    return (-t[1], t[0])


class Cubic:
    def __init__(self, p0, p1, p2, p3):
        self.p = (p0, p1, p2, p3)
        self.arc = [0.0]
        prev = self.at(0.0)
        for i in range(1, ARC_SAMPLES):
            cur = self.at(i/(ARC_SAMPLES-1))
            self.arc.append(self.arc[-1] + math.dist(prev, cur))
            prev = cur
        self.length = self.arc[-1]

    def at(self, t):
        p0, p1, p2, p3 = self.p
        u = 1-t
        return (u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0],
                u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1])

    def d1(self, t):
        p0, p1, p2, p3 = self.p
        u = 1-t
        return (3*u*u*(p1[0]-p0[0]) + 6*u*t*(p2[0]-p1[0]) + 3*t*t*(p3[0]-p2[0]),
                3*u*u*(p1[1]-p0[1]) + 6*u*t*(p2[1]-p1[1]) + 3*t*t*(p3[1]-p2[1]))

    def d2(self, t):
        p0, p1, p2, p3 = self.p
        u = 1-t
        return (6*u*(p2[0]-2*p1[0]+p0[0]) + 6*t*(p3[0]-2*p2[0]+p1[0]),
                6*u*(p2[1]-2*p1[1]+p0[1]) + 6*t*(p3[1]-2*p2[1]+p1[1]))

    def t_at_s(self, s):
        s = max(0.0, min(self.length, s))
        for i in range(1, len(self.arc)):
            if self.arc[i] >= s:
                span = self.arc[i]-self.arc[i-1]
                f = 0.0 if span < 1e-9 else (s-self.arc[i-1])/span
                return ((i-1)+f)/(ARC_SAMPLES-1)
        return 1.0


class PolyCurve:
    def __init__(self, segs):
        self.segs = segs
        self.length = sum(s.length for s in segs)

    def _local(self, s):
        s = max(0.0, min(self.length, s))
        for seg in self.segs:
            if s <= seg.length or seg is self.segs[-1]:
                return seg, s
            s -= seg.length
        return self.segs[-1], s

    def pos(self, s):
        seg, ls = self._local(s)
        return seg.at(seg.t_at_s(ls))

    def tan(self, s):
        seg, ls = self._local(s)
        return unit(seg.d1(seg.t_at_s(ls)))

    def curvature(self, s):
        seg, ls = self._local(s)
        t = seg.t_at_s(ls)
        d1, d2 = seg.d1(t), seg.d2(t)
        n = abs(d1[0]*d2[1] - d1[1]*d2[0])
        d = math.hypot(*d1)**3
        return 0.0 if d < 1e-9 else n/d

    def frame(self, s):
        """Returns (position, right, forward) - matches CFrame local X / -Z."""
        p = self.pos(s)
        t = self.tan(s)
        return p, right_of(t), t


def build_stations(curve, max_step, tol, max_offset):
    """Faithful port of RoadBuilder.buildStations."""
    stations = [0.0]
    s = 0.0
    while s < curve.length:
        k = curve.curvature(s)
        step = max_step
        if k > 1e-6:
            k_eff = k / max(0.05, 1 - max_offset*k)
            step = min(max_step, math.sqrt(8*tol/k_eff))
            step = min(step, MAX_TURN_PER_STEP/k_eff)
        step = max(step, MIN_STEP)
        s = min(s+step, curve.length)
        stations.append(s)
    n = len(stations)
    if n > 2 and (stations[-1]-stations[-2]) < MIN_STEP*0.5:
        del stations[-2]
    return stations


# --- profile -----------------------------------------------------------------
def offsets_m(components):
    total = sum(c[1] for c in components)
    x = -total/2
    out = []
    for c in components:
        out.append((x, x+c[1]))
        x += c[1]
    return out


def roadway_edges_m(components):
    o = offsets_m(components)
    idx = [i for i, c in enumerate(components) if c[0] != "Sidewalk"]
    if not idx:
        return o[0][0], o[-1][1]
    return o[idx[0]][0], o[idx[-1]][1]


def direction_of(component):
    return component[2] if len(component) > 2 else 0


def split_approach_lanes(components, inbound_sign, style_pav=SW_M):
    """Port of RoundaboutBuilder.splitApproachLanes."""
    offs = offsets_m(components)
    groups = {1: dict(widths=[], left=math.inf, right=-math.inf, pav=style_pav),
              -1: dict(widths=[], left=math.inf, right=-math.inf, pav=style_pav)}

    def add(g, i):
        g["widths"].append(components[i][1])
        g["left"] = min(g["left"], offs[i][0])
        g["right"] = max(g["right"], offs[i][1])

    for i, c in enumerate(components):
        if c[0] == "Sidewalk":
            continue
        d = direction_of(c)
        if d == inbound_sign:
            add(groups[1], i)
        elif d == -inbound_sign:
            add(groups[-1], i)
    for i, c in enumerate(components):
        if c[0] == "Sidewalk" or direction_of(c) != 0:
            continue
        for g in groups.values():
            if g["widths"] and (abs(offs[i][1]-g["left"]) < 1e-6 or abs(offs[i][0]-g["right"]) < 1e-6):
                add(g, i)
                break
    for g in groups.values():
        for i, c in enumerate(components):
            if c[0] != "Sidewalk":
                continue
            if abs(offs[i][1]-g["left"]) < 1e-6 or abs(offs[i][0]-g["right"]) < 1e-6:
                g["pav"] = c[1]
    return (groups[1] if groups[1]["widths"] else None,
            groups[-1] if groups[-1]["widths"] else None)


def arm_from_group(group, drive_on_left, solo=False):
    comps = [("Drive", w) for w in group["widths"]]
    if solo:
        comps.insert(0, ("Sidewalk", group["pav"]))
        comps.append(("Sidewalk", group["pav"]))
    elif drive_on_left:
        comps.insert(0, ("Sidewalk", group["pav"]))
    else:
        comps.append(("Sidewalk", group["pav"]))
    lm, rm = roadway_edges_m(comps)
    outer = (-lm if drive_on_left else rm) * SCALE
    inner = (rm if drive_on_left else -lm) * SCALE
    return comps, outer, inner, (lm + rm) / 2


# --- part emission -----------------------------------------------------------
class Part:
    __slots__ = ("name", "poly", "color", "center", "y")

    def __init__(self, name, poly, color, center, y):
        self.name, self.poly, self.color, self.center, self.y = name, poly, color, center, y


def rect(center, right, forward, half_w, half_l):
    a = (right[0]*half_w, right[1]*half_w)
    b = (forward[0]*half_l, forward[1]*half_l)
    return [(center[0]-a[0]-b[0], center[1]-a[1]-b[1]),
            (center[0]+a[0]-b[0], center[1]+a[1]-b[1]),
            (center[0]+a[0]+b[0], center[1]+a[1]+b[1]),
            (center[0]-a[0]+b[0], center[1]-a[1]+b[1])]


def emit_road(curve, components, y_base=0.0, solid_lane_lines=False, lane_lines=True):
    """Port of the deck-strip + marking emission for a flat (unbanked) road."""
    parts = []
    total_m = sum(c[1] for c in components)
    max_offset = total_m/2*SCALE
    stations = build_stations(curve, MAX_SEGMENT_LENGTH, CHORD_TOLERANCE, max_offset)
    offs = offsets_m(components)

    for i in range(len(stations)-1):
        s0, s1 = stations[i], stations[i+1]
        nominal = s1-s0
        s_mid = (s0+s1)/2
        pos, right, fwd = curve.frame(s_mid)
        k = curve.curvature(s_mid)
        for c, comp in enumerate(components):
            kind, w_m = comp[0], comp[1]
            width = w_m*SCALE
            if width <= 1e-4:
                continue
            center_off = (offs[c][0]+w_m/2)*SCALE
            raised = kind == "Sidewalk"
            edge_dist = max(abs(center_off-width/2), abs(center_off+width/2))
            miter = edge_dist*k*nominal
            padding = miter + 0.08
            cen = (pos[0]+right[0]*center_off, pos[1]+right[1]*center_off)
            parts.append(Part(
                kind,
                rect(cen, right, fwd, width/2, (nominal+padding)/2),
                SIDEWALK_C if raised else ASPHALT_C,
                cen,
                y_base + (0.125*SCALE if raised else 0.0),
            ))

    # markings: solid edge lines at the roadway edges, dashed between lanes
    mw = MARKING_W_M*SCALE
    inset = MARKING_W_M*1.5
    left_m, right_m = roadway_edges_m(components)
    lines = [(left_m+inset, True), (right_m-inset, True)]
    for c in range(len(components)-1):
        if components[c][0] != "Sidewalk" and components[c+1][0] != "Sidewalk":
            # `solid_lane_lines` stands in for RoadProfile's
            # RightBoundary = "Solid" (the SolidLanes ring); `lane_lines=False`
            # for its "None" (the Turbo ring, which suppresses the straight
            # boundary and spirals its own). Neither is a port of Markings.lua
            # - see ROUNDABOUT.md 5.3 - just enough for the three-way choice to
            # be visible here at all.
            if lane_lines:
                lines.append((offs[c][1], solid_lane_lines))

    for off_m, solid in lines:
        off = off_m*SCALE
        if solid:
            spans = [(stations[i], stations[i+1]) for i in range(len(stations)-1)]
        else:
            dash, gap = 3.0*SCALE, 3.0*SCALE
            spans, s = [], 0.0
            while s < curve.length:
                spans.append((s, min(s+dash, curve.length)))
                s += dash+gap
        for j, (a, b) in enumerate(spans):
            p0c, r0, _ = curve.frame(a)
            p1c, r1, _ = curve.frame(b)
            p0 = (p0c[0]+r0[0]*off, p0c[1]+r0[1]*off)
            p1 = (p1c[0]+r1[0]*off, p1c[1]+r1[1]*off)
            seg_len = math.dist(p0, p1)
            if seg_len < 1e-4:
                continue
            fwd = unit((p1[0]-p0[0], p1[1]-p0[1]))
            mid = ((p0[0]+p1[0])/2, (p0[1]+p1[1])/2)
            extra = 0.0 if not solid else 0.0
            parts.append(Part("Marking", rect(mid, right_of(fwd), fwd, mw/2,
                                              (seg_len+extra)/2),
                              MARK_C, mid, y_base+0.02))
    return parts


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


def min_radius_studs(legs, lane_count, lane_w, dol):
    """Port of RoundaboutBuilder.MinimumRadiusStuds.

    Lives here rather than in dump_compare.py so `build` can apply the same
    growth the plugin applies - see the note in `build`.
    """
    total = widest = outer_off = 0.0
    for _, spoke in legs:
        inbound, outbound = split_approach_lanes(spoke, 1)
        solo = (inbound is None) != (outbound is None)
        for group in (inbound, outbound):
            if not group:
                continue
            comps, outer, _inner, _centre = arm_from_group(group, dol, solo)
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
TURBO_DASH_M, TURBO_GAP_M = 1.0, 5.0     # style.LaneLine dash geometry


def turbo_spiral(center, ring_r, island_r, lanes, lane_m, drive_on_left, sectors):
    """Port of RoundaboutBuilder.buildTurboMarkings.

    Across each arc between two mouths, boundary k migrates outward from
    island_r + k*w to island_r + (k+1)*w, so the lane a driver is in is carried
    to an exit instead of needing a lane change on the ring.
    """
    lanes = max(1, int(lanes))
    if lanes < 2 or len(sectors) < 2:
        return [], []
    lane_studs = lane_m * SCALE
    travel = 1 if drive_on_left else -1
    mw = MARKING_W_M * SCALE
    ordered = sorted(sectors, key=lambda m: m[0])          # (angle, ahead, behind)

    def at(a, r):
        return (center[0] + math.cos(a) * r, center[1] + math.sin(a) * r)

    def flung(t):
        hold = 1 - TURBO_FLING_FRACTION
        if t <= hold:
            return 0.0
        u = max(0.0, min(1.0, (t - hold) / TURBO_FLING_FRACTION))
        return u * u * (3 - 2 * u)

    dash, gap = TURBO_DASH_M * SCALE, TURBO_GAP_M * SCALE
    out, spans = [], []
    for i, mouth in enumerate(ordered):
        nxt = ordered[(i + 1) % len(ordered)] if travel > 0 else ordered[i - 1]
        # ENTRY EDGE to EXIT EDGE - see RoundaboutBuilder. The exit is not at
        # the mouth centre, so aiming at the centre leaves the boundary still
        # drifting well past the traffic it is meant to deliver.
        frm = mouth[0] + (mouth[1] if travel > 0 else -mouth[2])
        arrive = nxt[0] + (-nxt[2] if travel > 0 else nxt[1])
        sweep = ((arrive - frm) * travel) % (2 * math.pi)
        if sweep <= 1e-6:
            continue
        steps = max(8, math.ceil(sweep / TURBO_ARC_STEP_RAD))
        for k in range(1, lanes):
            pts, cum, polar = [], [0.0], []
            for j in range(steps + 1):
                t = j / steps
                r = island_r + (k + flung(t)) * lane_studs
                a = frm + travel * sweep * t
                pts.append(at(a, r))
                polar.append((a, r))
                if j:
                    cum.append(cum[-1] + math.dist(pts[j - 1], pts[j]))
            total = cum[-1]

            def sample(d):
                d = max(0.0, min(total, d))
                for j in range(len(cum) - 1):
                    if d <= cum[j + 1]:
                        span_ = cum[j + 1] - cum[j]
                        f = (d - cum[j]) / span_ if span_ > 1e-9 else 0.0
                        return ((pts[j][0] + (pts[j + 1][0] - pts[j][0]) * f,
                                 pts[j][1] + (pts[j + 1][1] - pts[j][1]) * f),
                                (polar[j][0] + (polar[j + 1][0] - polar[j][0]) * f,
                                 polar[j][1] + (polar[j + 1][1] - polar[j][1]) * f))
                return pts[-1], polar[-1]

            # Backwards from the exit so a dash lands flush on it - see
            # RoundaboutBuilder.
            d = total - dash
            while d >= 0:
                (p0, q0), (p1, q1) = sample(d), sample(d + dash)
                length = math.dist(p0, p1)
                if length > 1e-4:
                    fwd = unit((p1[0] - p0[0], p1[1] - p0[1]))
                    mid = ((p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2)
                    out.append(Part("Marking", rect(mid, right_of(fwd), fwd, mw / 2, length / 2),
                                    MARK_C, mid, 0.03))
                    spans.append((q0[0], q0[1], q1[0], q1[1]))
                d -= dash + gap
    return out, spans


def check_turbo(scene, tol=0.05):
    """Invariants the spiral must satisfy, checked against the built parts.

    Deliberately NOT a re-derivation of the same formula - that would pass by
    construction. These test the bookkeeping that is actually easy to get
    wrong: which end of a mouth the arc leaves from, which way round travel
    goes, and whether the result stays on the carriageway.
    """
    faults = []
    if scene.get("markings") != "Turbo":
        return faults
    lanes, spiral = scene["ring_lanes"], scene["spiral"]
    inner, outer = scene["island_r"], scene["ring_kerb"]
    if lanes < 2 or len(scene["sectors"]) < 2:
        if spiral:
            faults.append(f"spiral emitted with {lanes} lane(s) / "
                          f"{len(scene['sectors'])} mouth(s); should fall back")
        return faults
    if not spiral:
        faults.append("Turbo selected but no spiral emitted")
        return faults
    radii = [math.hypot(p.center[0] - scene["center"][0],
                        p.center[1] - scene["center"][1]) for p in spiral]
    if min(radii) < inner - tol:
        faults.append(f"spiral crosses the island: min r {min(radii):.2f} < {inner:.2f}")
    if max(radii) > outer + tol:
        faults.append(f"spiral crosses the kerb: max r {max(radii):.2f} > {outer:.2f}")
    # DELIVERED TO THE EXIT. Each boundary must reach the ring's outer edge
    # exactly at a mouth centre, because that is the whole point - the lane it
    # was holding leaves there. This replaces an earlier "no spiral inside a
    # mouth sector" rule, which was written when the arcs ran between sector
    # EDGES and became wrong when they were changed to run centre to centre.
    # Stopping at the edges completed the migration a few degrees early, left
    # the line hanging in mid-carriageway and blanked every mouth of markings;
    # crossing the mouth is now correct, so the old rule had to be replaced
    # rather than merely relaxed, or nothing would check the mouths at all.
    lane_studs_ = LANE_M * SCALE
    outer_want = inner + lanes * lane_studs_
    travel_ = 1 if scene["drive_on_left"] else -1
    # The window has to be wider than the dash pitch or it lands in a gap and
    # reports "no spiral" on a perfectly good ring. 12 degrees is inside the
    # fling on any arc a real ring has, so the radius there is already most of
    # the way out and the tolerance below still separates flung from held.
    for sa, ah, bh in scene["sectors"]:
        # The EXIT edge, not the mouth centre - that is where the hand-off is.
        exit_a = sa + (-bh if travel_ > 0 else ah)
        near = [r for p, r in zip(spiral, radii)
                if abs(angle_delta(math.atan2(p.center[1] - scene["center"][1],
                                              p.center[0] - scene["center"][0]), exit_a)) < math.radians(12)]
        if not near:
            faults.append(f"no spiral at the exit at {math.degrees(exit_a):.0f}deg")
        elif abs(max(near) - outer_want) > lane_studs_ * 0.35:
            faults.append(f"boundary reaches r={max(near):.1f} at the exit at "
                          f"{math.degrees(exit_a):.0f}deg, want ~{outer_want:.1f} - "
                          f"the lane is not delivered to the exit")
    # Every boundary must both start one lane width off the island and finish
    # one lane width further out, or it is not delivering anything to an exit.
    lane_studs = LANE_M * SCALE
    want_lo, want_hi = inner + lane_studs, inner + lanes * lane_studs
    if abs(min(radii) - want_lo) > lane_studs * 0.25:
        faults.append(f"innermost boundary starts at {min(radii):.2f}, want ~{want_lo:.2f}")
    if abs(max(radii) - want_hi) > lane_studs * 0.25:
        faults.append(f"outermost boundary ends at {max(radii):.2f}, want ~{want_hi:.2f}")
    # THE defining property, and the one the radius bounds above cannot see: in
    # the DIRECTION OF TRAVEL the boundary must move outward. A spiral wound
    # the wrong way round is geometrically indistinguishable on a symmetric
    # ring - right radii, right sectors, every other check green - and means
    # the exact opposite thing, flinging the outer lane inward. Reversing
    # `travel` in turbo_spiral is caught here and nowhere else.
    travel = 1 if scene["drive_on_left"] else -1
    for a0, r0, a1, r1 in scene["spiral_spans"]:
        step = ((a1 - a0) * travel) % (2 * math.pi)
        if not (0 < step < math.pi):
            faults.append("spiral runs against the direction of travel")
            break
        if r1 < r0 - 1e-9:
            faults.append("spiral moves inward along travel; turbo delivers lanes outward")
            break
    return faults


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
        ring_r = max(ring_r, min_radius_studs(legs, ring_lanes, LANE_M, drive_on_left))
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
    # Turbo suppresses the straight lane lines entirely (RightBoundary="None"
    # in ringComponents) and lays spiralling ones below instead.
    ring_parts = emit_road(ring_curve, rc, solid_lane_lines=(markings == "SolidLanes"),
                           lane_lines=(markings != "Turbo"))
    parts_ring_pavement = [p for p in ring_parts if p.name in ("Sidewalk", "Marking")]

    sectors, arm_parts, gore_tris, apron_tris = [], [], [], []
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
            comps, outer, inner, road_centre = arm_from_group(group, drive_on_left, solo)
            merge = ring_kerb - outer
            span_centre = (group["left"] + group["right"]) / 2
            lat_m = (span_centre - road_centre) if travels_inward else (span_centre + road_centre)
            return dict(comps=comps, outer=outer, inner=inner, merge=merge,
                        lat=lat_m*SCALE)

        entry_arm, exit_arm = make(inbound, True), make(outbound, False)
        entry = exit_ = None
        if entry_arm:
            p0 = (cut[0]+r[0]*entry_arm["lat"], cut[1]+r[1]*entry_arm["lat"])
            p1 = (math.cos(ea)*entry_arm["merge"], math.sin(ea)*entry_arm["merge"])
            entry = arm_curve(p0, inward, p1, rt(ea))
            arm_parts += emit_road(entry, entry_arm["comps"], -ARM_SINK)
        if exit_arm:
            p0 = (math.cos(xa)*exit_arm["merge"], math.sin(xa)*exit_arm["merge"])
            p1 = (cut[0]+r[0]*exit_arm["lat"], cut[1]+r[1]*exit_arm["lat"])
            exit_ = arm_curve(p0, rt(xa), p1, (-inward[0], -inward[1]))
            arm_parts += emit_road(exit_, exit_arm["comps"], -ARM_SINK)

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
            outer_radius = ring_kerb + SW_M*SCALE

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
        turbo_spiral(center, ring_r, island_r, ring_lanes, LANE_M, drive_on_left, cl)
        if markings == "Turbo" else ([], []))
    parts += spiral
    return dict(tag=tag, parts=parts, gore=gore_tris, apron=apron_tris,
                spiral=spiral, spiral_spans=spiral_spans, markings=markings,
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


# --- bare-ground scan --------------------------------------------------------
def point_in(poly, p):
    inside = False
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        if (a[1] > p[1]) != (b[1] > p[1]):
            x = a[0] + (p[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
            if x > p[0]:
                inside = not inside
    return inside


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
