#!/usr/bin/env python3
"""Headless checks for ordinary road geometry in the Python preview model.

    python3 tools/preview/road_preview.py            # scan, no images
    python3 tools/preview/road_preview.py --render    # + PNGs

This model emits rigid boxes for each component and station interval. The
current Luau builder uses exact station-corner quads on curves, so this render
does not prove runtime surface parity. See tools/preview/README.md for limits.

This suite does not model lane-width transitions or bus bays. Separate
contracts cover some related source rules. Validate the plugin in Studio.
"""
import argparse
import math
import os

from preview_core import (ASPHALT_C, Cubic, GROUND, LANE_M, MEDIAN_M, PolyCurve, SCALE,
                          SHOULDER_M, SW_M, emit_road, point_in, right_of, roadway_edges_m,
                          unit)
from raster import Canvas


# --- curves ------------------------------------------------------------------
def straight(length):
    p0, p1 = (0.0, 0.0), (length, 0.0)
    third = ((p1[0]-p0[0])/3, 0.0)
    return PolyCurve([Cubic(p0, (p0[0]+third[0], 0.0), (p1[0]-third[0], 0.0), p1)])


def arc(radius, sweep_deg, start=(0.0, 0.0)):
    """A circular arc as Bezier quarters or less, so curvature is honest.

    Split at 90 degrees maximum: a single cubic over a wider sweep is a poor
    circle, and the point of this tool is to measure the emitter, not to give
    it a curve that was already wrong.
    """
    K = 0.5522847498307936
    sweep = math.radians(sweep_deg)
    n = max(1, math.ceil(abs(sweep_deg)/90.0))
    step = sweep/n
    h = radius*K*(abs(step)/(math.pi/2))
    centre = (start[0], start[1]+radius)
    segs = []
    for i in range(n):
        a0 = -math.pi/2 + step*i
        a1 = -math.pi/2 + step*(i+1)
        p0 = (centre[0]+math.cos(a0)*radius, centre[1]+math.sin(a0)*radius)
        p1 = (centre[0]+math.cos(a1)*radius, centre[1]+math.sin(a1)*radius)
        sgn = 1 if step > 0 else -1
        t0 = (-math.sin(a0)*sgn, math.cos(a0)*sgn)
        t1 = (-math.sin(a1)*sgn, math.cos(a1)*sgn)
        segs.append(Cubic(p0, (p0[0]+t0[0]*h, p0[1]+t0[1]*h),
                          (p1[0]-t1[0]*h, p1[1]-t1[1]*h), p1))
    return PolyCurve(segs)


def s_curve(radius, sweep_deg):
    """Two arcs of opposite hand. Curvature changes SIGN at the join, which is
    where a miter term that forgot to take an absolute value shows up."""
    first = arc(radius, sweep_deg)
    end, tan = first.pos(first.length), first.frame(first.length)[2]
    K = 0.5522847498307936
    sweep = math.radians(sweep_deg)
    n = max(1, math.ceil(abs(sweep_deg)/90.0))
    step = -sweep/n
    h = radius*K*(abs(step)/(math.pi/2))
    # Centre on the other side of the tangent.
    normal = right_of(tan)
    centre = (end[0]+normal[0]*radius, end[1]+normal[1]*radius)
    base = math.atan2(end[1]-centre[1], end[0]-centre[0])
    segs = list(first.segs)
    for i in range(n):
        a0 = base - step*i
        a1 = base - step*(i+1)
        p0 = (centre[0]+math.cos(a0)*radius, centre[1]+math.sin(a0)*radius)
        p1 = (centre[0]+math.cos(a1)*radius, centre[1]+math.sin(a1)*radius)
        sgn = -1 if step > 0 else 1
        t0 = (-math.sin(a0)*sgn, math.cos(a0)*sgn)
        t1 = (-math.sin(a1)*sgn, math.cos(a1)*sgn)
        segs.append(Cubic(p0, (p0[0]+t0[0]*h, p0[1]+t0[1]*h),
                          (p1[0]-t1[0]*h, p1[1]-t1[1]*h), p1))
    return PolyCurve(segs)


# --- profiles ----------------------------------------------------------------
def street(lanes_each_way=1):
    lane = [("Drive", LANE_M, 1)]*lanes_each_way + [("Drive", LANE_M, -1)]*lanes_each_way
    return [("Sidewalk", SW_M)] + lane + [("Sidewalk", SW_M)]


def avenue():
    return ([("Sidewalk", SW_M)] + [("Drive", LANE_M, 1)]*2 + [("Median", MEDIAN_M, 0)]
            + [("Drive", LANE_M, -1)]*2 + [("Sidewalk", SW_M)])


def motorway(lanes_each_way=2):
    sh = ("Shoulder", SHOULDER_M, 0)
    return ([sh] + [("Drive", LANE_M, 1)]*lanes_each_way + [("Median", MEDIAN_M, 0)]
            + [("Drive", LANE_M, -1)]*lanes_each_way + [sh])


# --- scans -------------------------------------------------------------------
def cross_section(scene, s, half_span, samples):
    """Covered lateral extent at station `s`, as a list of (lo, hi) runs.

    Runs, not a single min/max: a hole in the middle of the carriageway is the
    thing being looked for, and an extent would swallow it.
    """
    pos, right, _ = scene["curve"].frame(s)
    runs, open_at = [], None
    for i in range(samples+1):
        d = -half_span + 2*half_span*i/samples
        pt = (pos[0]+right[0]*d, pos[1]+right[1]*d)
        hit = any(point_in(p.poly, pt) for p in scene["parts"])
        if hit and open_at is None:
            open_at = d
        elif not hit and open_at is not None:
            runs.append((open_at, d))
            open_at = None
    if open_at is not None:
        runs.append((open_at, half_span))
    return runs


def scan_road_gaps(scene, steps=200, samples=400, min_gap=None):
    """Bare ground strictly INSIDE the road, at stations between the strips.

    Sampled off the station boundaries on purpose. A strip is padded past its
    own interval (`curveMiterPad`), so sampling AT a boundary lands inside the
    overlap and can never see the sliver the padding exists to close - which is
    exactly how a gap ships. This walks a fine station sweep instead, and the
    default gap floor is two sample pitches so a single dark sample between two
    abutting strips is not reported as a hole.
    """
    curve, comps = scene["curve"], scene["components"]
    total_m = sum(c[1] for c in comps)
    half = total_m/2*SCALE + 4.0
    pitch = 2*half/samples
    floor = min_gap if min_gap is not None else pitch*2
    holes = []
    for i in range(steps+1):
        s = curve.length*i/steps
        runs = cross_section(scene, s, half, samples)
        for a, b in zip(runs, runs[1:]):
            width = b[0]-a[1]
            if width > floor:
                holes.append(dict(station=s, at=a[1], width=width))
    return holes, pitch


def scan_edge_sawtooth(scene, steps=400):
    """How much the road's covered WIDTH jitters from station to station.

    The sawtooth bug family (farEdgePad, the anchored-edge scheme, the diagonal
    taper seams) all showed up as the outer edge stepping in and out along an
    otherwise smooth curve. Measured as the change in total covered width
    between adjacent samples, so a genuine taper reads as a steady ramp and a
    sawtooth as alternating signs.
    """
    curve, comps = scene["curve"], scene["components"]
    total_m = sum(c[1] for c in comps)
    half = total_m/2*SCALE + 4.0
    widths = []
    for i in range(steps+1):
        s = curve.length*i/steps
        runs = cross_section(scene, s, half, 400)
        widths.append(runs[-1][1]-runs[0][0] if runs else 0.0)
    # Sign changes in the sequence of SIGNIFICANT deltas, not between adjacent
    # samples. A strip boundary is a single-sample jump with flat runs either
    # side, so comparing neighbours measures every jump against a zero and sees
    # no sign change at all - the first version counted 2 flips on a road built
    # to alternate at every station.
    #
    # "Significant" is 1% of the road's own width, not a fixed number of studs.
    # The legitimate jitter is the strips rotating against each other on a
    # curve, and it scales with the road: measured across every case here it
    # runs 0.121 studs on a 40-stud road and 0.233 on an 85-stud one - 0.30%
    # and 0.27%. A fixed threshold picked off one case would either pass a
    # sawtooth on a wide road or fail a clean narrow one.
    span = max(widths) if widths else 0.0
    floor = max(0.05, span*0.01)
    worst = 0.0
    moves = []
    for a, b in zip(widths, widths[1:]):
        delta = b-a
        worst = max(worst, abs(delta))
        if abs(delta) > floor:
            moves.append(1 if delta > 0 else -1)
    flips = sum(1 for x, y in zip(moves, moves[1:]) if x != y)
    return worst, flips, widths


def scan_marking_breaks(scene, max_gap=None):
    """Longest gap between consecutive SOLID edge-line parts.

    Only the two edge lines are solid; lane lines are dashed by design, so a
    gap there means nothing. Identified by position rather than by name because
    every marking is called "Marking" - the same lesson check_turbo learnt.
    """
    curve, comps = scene["curve"], scene["components"]
    left_m, right_m = roadway_edges_m(comps)
    inset = 0.1*1.5
    limit = max_gap if max_gap is not None else 1.0
    breaks = []
    for off_m, side in ((left_m+inset, "left"), (right_m-inset, "right")):
        off = off_m*SCALE
        want = []
        for i in range(400):
            s = curve.length*i/399
            pos, right, _ = curve.frame(s)
            want.append((s, (pos[0]+right[0]*off, pos[1]+right[1]*off)))
        marks = [p for p in scene["parts"] if p.name == "Marking"]
        run_start = None
        for s, pt in want:
            covered = any(point_in(p.poly, pt) for p in marks)
            if not covered and run_start is None:
                run_start = s
            elif covered and run_start is not None:
                if s-run_start > limit:
                    breaks.append(dict(side=side, frm=run_start, to=s))
                run_start = None
        if run_start is not None and curve.length-run_start > limit:
            breaks.append(dict(side=side, frm=run_start, to=curve.length))
    return breaks


# --- scenes ------------------------------------------------------------------
def build(tag, curve, components):
    return dict(tag=tag, curve=curve, components=components,
                parts=emit_road(curve, components))


def render(scene, outdir):
    curve, comps = scene["curve"], scene["components"]
    half = sum(c[1] for c in comps)/2*SCALE + 10
    xs, ys = [], []
    for i in range(200):
        p = curve.pos(curve.length*i/199)
        xs.append(p[0]); ys.append(p[1])
    lo = (min(xs)-half, min(ys)-half)
    hi = (max(xs)+half, max(ys)+half)
    s = min(6.0, 1400/max(hi[0]-lo[0], hi[1]-lo[1]))
    w, h = int((hi[0]-lo[0])*s), int((hi[1]-lo[1])*s)
    tx = lambda p: ((p[0]-lo[0])*s, (p[1]-lo[1])*s)
    written = []
    for flat in (False, True):
        cv = Canvas(w, h, GROUND if flat else (250, 250, 250))
        for p in sorted(scene["parts"], key=lambda q: q.y):
            cv.fill_poly([tx(v) for v in p.poly], (70, 70, 70) if flat else p.color)
        name = f"road_{scene['tag']}_{'gaps' if flat else 'parts'}.png"
        cv.save(os.path.join(outdir, name))
        written.append(name)
    return written


def CASE_TABLE():
    return {
        "straight": (straight(400), street(1)),
        "gentle_r300": (arc(300, 60), street(1)),
        "medium_r120": (arc(120, 90), street(2)),
        "tight_r60": (arc(60, 120), street(1)),
        # Below RoadBuilder's own chord tolerance a 30-stud radius is where
        # faceting used to be visible; kept as the hard case.
        "hairpin_r30": (arc(30, 150), street(1)),
        "scurve_r80": (s_curve(80, 70), avenue()),
        "avenue_r150": (arc(150, 80), avenue()),
        "motorway_r250": (arc(250, 45), motorway(2)),
        "motorway_tight": (arc(70, 90), motorway(3)),
    }


CASES = CASE_TABLE()


def report(scene):
    ok = True
    holes, pitch = scan_road_gaps(scene)
    worst, flips, _ = scan_edge_sawtooth(scene)
    breaks = scan_marking_breaks(scene)
    print(f"{scene['tag']:16s} {len(scene['parts']):5d} parts", end="")
    if holes:
        ok = False
        widest = max(h["width"] for h in holes)
        print(f"\n    BARE GROUND inside the road: {len(holes)} samples, "
              f"worst {widest:.2f} studs (pitch {pitch:.3f})")
        for h in sorted(holes, key=lambda h: -h["width"])[:3]:
            print(f"        station {h['station']:.1f}, {h['width']:.2f} studs "
                  f"at lateral {h['at']:.1f}")
    if flips > 2:
        ok = False
        print(f"\n    SAWTOOTH: covered width reverses {flips} times, "
              f"worst step {worst:.2f} studs")
    if breaks:
        ok = False
        print(f"\n    EDGE LINE broken in {len(breaks)} places, "
              f"longest {max(b['to']-b['frm'] for b in breaks):.1f} studs")
    if ok:
        print("   clean")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cases", nargs="*", help=f"known: {' '.join(CASES)}")
    ap.add_argument("--render", action="store_true", help="also write PNGs")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    args = ap.parse_args()
    names = args.cases or list(CASES)
    os.makedirs(args.out, exist_ok=True)
    ok = True
    for name in names:
        if name not in CASES:
            raise SystemExit(f"unknown case {name!r}; known: {' '.join(CASES)}")
        curve, comps = CASES[name]
        scene = build(name, curve, comps)
        ok &= report(scene)
        if args.render:
            for f in render(scene, args.out):
                print(f"    wrote {os.path.join(args.out, f)}")
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
