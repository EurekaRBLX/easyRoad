#!/usr/bin/env python3
"""Shared core for the headless preview: everything that is not one scenario.

Split out of `roundabout_preview.py`, which was the whole tool. The emission
port is generic - a curve plus a cross-section becomes rigid boxes per
(component, station interval), exactly as RoadBuilder emits them - so the only
roundabout-specific things in it were the ring, the arms and their scans. Every
scenario module (`roundabout_preview`, `road_preview`) imports this and adds
its own geometry and its own checks.

Ported from src/Mesh/RoadBuilder.lua:
  buildStations  - adaptive stepping, incl. the offset-edge curvature term
  the deck-strip branch - Size = (width, h, nominalLength + padding),
                          CFrame = midFrame * CFrame.new(centerOffset, y, 0)
  curveMiterPad  - padding = |edgeDistance| * curvature * nominalLength + 0.08
  placeMarkingSpan - endpoints anchored to true curve positions
"""
import math

# --- RoadBuilder constants ---------------------------------------------------
CHORD_TOLERANCE = 0.05
MIN_STEP = 0.4
MAX_TURN_PER_STEP = 0.2
MARKING_THICKNESS = 0.05
MAX_SEGMENT_LENGTH = 8.0          # settings.MaxSegmentLengthStuds
ARC_SAMPLES = 64                  # CurveSegment.ARC_SAMPLES

# --- region / settings -------------------------------------------------------
SCALE = 3.571
SW_M, LANE_M = 2.0, 3.65
# RegionStyles UK: ShoulderWidthM = 3.3, and builtin_highway's MedianWidthM*1.5.
SHOULDER_M, MEDIAN_M = 3.3, 1.8 * 1.5
MARKING_W_M = 0.1
THICKNESS = 1.0

ASPHALT_C = (60, 60, 60)
SIDEWALK_C = (168, 168, 168)
SHOULDER_C = (92, 92, 92)
MEDIAN_C = (120, 130, 112)
MARK_C = (245, 245, 245)
ISLAND_C = (150, 150, 150)
GROUND = (255, 0, 200)
FLAT = (70, 70, 70)

# Per-kind colour, mirroring RoadBuilder's COMPONENT_COLOR. Shoulders were drawn
# as plain asphalt here, which is exactly why the plugin emitting them as Drive
# lanes was invisible in every render this tool has ever produced.
KIND_C = {
    "Sidewalk": SIDEWALK_C,
    "Shoulder": SHOULDER_C,
    "Median": MEDIAN_C,
}

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


# Mirrors RoadProfile.ROADWAY exactly. This used to be spelled `!= "Sidewalk"`
# at each site, which quietly counts a MEDIAN as roadway - so the undirected
# pass adopted the median into whichever arm it abutted instead of leaving it to
# become the splitter gore. A port divergence on every median profile, invisible
# because nothing compared the two implementations on this.
ROADWAY = {"Drive", "Bike", "Parking", "Shoulder", "Bay"}


def is_roadway(component):
    return component[0] in ROADWAY

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
                KIND_C.get(kind, ASPHALT_C),
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
