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


def emit_road(curve, components, y_base=0.0):
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
            lines.append((offs[c][1], False))

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


def ring_components(lanes, lane_w, drive_on_left):
    comps = [("Drive", lane_w) for _ in range(lanes)]
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


def build(ring_r, ring_lanes, legs, drive_on_left, tag):
    """legs is a list of (degrees, approach component list)."""
    flow = 1 if drive_on_left else -1
    center = (0.0, 0.0)
    rc = ring_components(ring_lanes, LANE_M, drive_on_left)
    outerR = ring_r + sum(c[1] for c in rc)/2*SCALE
    ring_kerb = outerR - SW_M*SCALE
    ro = offsets_m(rc)
    inner_half_m = ro[-1][1] if drive_on_left else -ro[0][0]
    island_r = ring_r - inner_half_m*SCALE
    run = min(max(outerR*ARM_RUN_FACTOR, ARM_RUN_MIN), ARM_RUN_MAX)
    cutR = outerR + run

    leg_info = []
    ring_curve = circle_segments(center, ring_r, drive_on_left)
    ring_parts = emit_road(ring_curve, rc)
    parts_ring_pavement = [p for p in ring_parts if p.name in ("Sidewalk", "Marking")]

    sectors, arm_parts, gore_tris = [], [], []
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
            L, R, last_along = [], [], 0.0
            for i in range(GORE_SAMPLES+1):
                along = (i/GORE_SAMPLES)*reach
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
    return dict(tag=tag, parts=parts, gore=gore_tris, island_r=island_r, legs=leg_info,
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
        for t in scene["gore"]:
            cv.fill_poly([tx(v) for v in t], FLAT if flat else ISLAND_C)
        if scene["island_r"] > 1:
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
    parts, gore = scene["parts"], scene["gore"]
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
    steps = seam_steps(scene)
    if steps:
        worst = max(max(a, b) for a, b in steps)
        print(f"    approach/arm seam: worst edge step {worst:.2f} studs "
              f"({'flush' if worst <= 0.5 else 'STEPPED'})")
    if not holes:
        print("    no bare ground inside the ring footprint")
        return True
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
        return True
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


def case(ring_r, ring_lanes, drive_on_left, legs):
    return dict(ring_r=ring_r, ring_lanes=ring_lanes, drive_on_left=drive_on_left,
                legs=legs)


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
