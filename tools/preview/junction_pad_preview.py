#!/usr/bin/env python3
"""Regression test for the junction PAD outline - the live zigzag bug.

`corner_preview.py` models an idealised corner. This one is different: it is a
line-by-line port of what `JunctionBuilder.Rebuild` actually walks -
`edgePointsForRoad` -> approach sort by angle -> per-gap `cornerBoundaries`
-> `padPoly` -> clean -> ear clip, with the convex-hull fallback behind it -
so a defect in that walk shows up here instead of only in Studio.

Two numbers decide it, and neither is a judgement call:

  * SELF-CROSS - does the pad outline cross itself? A closed boundary that
    crosses itself has no well-defined interior, so every triangle drawn from
    it is guesswork. This is the reported "jagged outline".
  * OVERDRAW - sum of |triangle area| divided by |polygon area|. A correct
    triangulation is exactly 1.000: the pieces tile the polygon once. Values
    above 1 mean triangles double-cover part of the pad and hang off the rest
    - the reported "spikes".

What it caught, and what the fix was: `cornerBoundaries` used to aim its edge
directions along +outward on any span wider than 180 degrees. The corner
vertex is toward -outward on BOTH sides of a bend, so `Fillet.Compute`
correctly rejected every one of those spans and the Hermite fallback - handed
mismatched directions - looped the outer boundary back across the pad. Every
bend from 45 to 150 degrees produced a self-crossing outline, with fan
overdraw up to 800x. Spans over 180 degrees are not exclusive to two-road
bends: any junction whose legs bunch to one side has one too, which is why
the T/X/5-leg cases below are part of the sweep.

    python3 junction_pad_preview.py             # full sweep, exits non-zero on any failure
    python3 junction_pad_preview.py --legacy    # show the pre-fix behaviour alongside
    python3 junction_pad_preview.py --bend 90   # one two-road bend
"""
import argparse
import math

MAX_CORNER_SPAN_RAD = math.radians(135)
PASS_THROUGH_DOT_THRESHOLD = -0.85
MAX_VERTEX_CHORD_RATIO = 4
FILLET_ARC_SAMPLES = 4
HERMITE_SAMPLES = 5


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1])


def add(a, b):
    return (a[0] + b[0], a[1] + b[1])


def mul(a, s):
    return (a[0] * s, a[1] * s)


def mag(a):
    return math.hypot(a[0], a[1])


def unit(a):
    m = mag(a)
    return (a[0] / m, a[1] / m) if m > 1e-9 else (0.0, 0.0)


def cross2d(o, a, b):
    """Port of JunctionBuilder.cross2D (X,Z treated as x,y)."""
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])


def angle_delta(a, b):
    return (a - b + math.pi) % (2 * math.pi) - math.pi


# ---------------------------------------------------------------- Fillet.lua


def fillet_compute(a_kerb, inward_a, b_kerb, inward_b, radius):
    """Port of Fillet.Compute. Returns (p1, centre, p2, radius) or all None."""
    ax, az = inward_a
    bx, bz = inward_b
    det = ax * -bz - az * -bx
    if abs(det) < 1e-6:
        return None, None, None, None
    dx, dz = b_kerb[0] - a_kerb[0], b_kerb[1] - a_kerb[1]
    t1 = (dx * -bz - dz * -bx) / det
    t2 = (ax * dz - dx * az) / det
    if t1 <= 1e-3 or t2 <= 1e-3:
        return None, None, None, None
    chord = mag(sub(b_kerb, a_kerb))
    if chord < 1e-3 or t1 > chord * MAX_VERTEX_CHORD_RATIO or t2 > chord * MAX_VERTEX_CHORD_RATIO:
        return None, None, None, None
    vertex = add(a_kerb, mul(inward_a, t1))
    dir_a = unit(mul(inward_a, -1))
    dir_b = unit(mul(inward_b, -1))
    cos_theta = max(-1.0, min(1.0, dir_a[0] * dir_b[0] + dir_a[1] * dir_b[1]))
    theta = math.acos(cos_theta)
    if theta < 1e-3:
        return None, None, None, None
    tangent = min(radius / math.tan(theta / 2), t1, t2)
    if tangent < 1e-3:
        return None, None, None, None
    effective = tangent * math.tan(theta / 2)
    bis = add(dir_a, dir_b)
    if mag(bis) < 1e-6:
        return None, None, None, None
    bis = unit(bis)
    centre = add(vertex, mul(bis, tangent / math.cos(theta / 2)))
    return add(vertex, mul(dir_a, tangent)), centre, add(vertex, mul(dir_b, tangent)), effective


def fillet_sample_arc(centre, radius, p1, p2, samples):
    a1 = math.atan2(p1[1] - centre[1], p1[0] - centre[0])
    a2 = math.atan2(p2[1] - centre[1], p2[0] - centre[0])
    delta = a2 - a1
    while delta > math.pi:
        delta -= 2 * math.pi
    while delta <= -math.pi:
        delta += 2 * math.pi
    return [(centre[0] + math.cos(a1 + delta * i / (samples + 1)) * radius,
             centre[1] + math.sin(a1 + delta * i / (samples + 1)) * radius)
            for i in range(1, samples + 1)]


def hermite_boundary(p0, d0, p1, d1, samples):
    """Port of JunctionBuilder.hermiteBoundary."""
    chord = mag(sub(p1, p0))
    m0, m1 = mul(unit(d0), chord), mul(unit(d1), chord)
    pts = [p0]
    for i in range(1, samples + 1):
        t = i / (samples + 1)
        t2, t3 = t * t, t * t * t
        h00, h10 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t
        h01, h11 = -2 * t3 + 3 * t2, t3 - t2
        pts.append((p0[0] * h00 + m0[0] * h10 + p1[0] * h01 + m1[0] * h11,
                    p0[1] * h00 + m0[1] * h10 + p1[1] * h01 + m1[1] * h11))
    pts.append(p1)
    return pts


# ------------------------------------------------------- cornerBoundaries


MAX_HERMITE_EXCURSION = 0.6  # multiples of the chord


def excursion(poly):
    """Furthest a polyline strays from its own chord, in chord multiples."""
    p0, p1 = poly[0], poly[-1]
    chord = mag(sub(p1, p0))
    if chord < 1e-6:
        return float("inf")
    d = unit(sub(p1, p0))
    n = (-d[1], d[0])
    worst = 0.0
    for p in poly:
        v = sub(p, p0)
        along = v[0] * d[0] + v[1] * d[1]
        worst = max(worst, abs(v[0] * n[0] + v[1] * n[1]))
        if along < -1e-6 or along > chord + 1e-6:
            worst = max(worst, min(abs(along), abs(along - chord)))
    return worst / chord


def corner_kerb(a, b, radius, exterior, mode):
    """Port of cornerBoundaries' KERB polyline (the pad outline contribution).

    `mode` selects the convention under test:
      legacy  - what shipped before this was fixed: `exterior` flipped both
                the fillet and the Hermite directions on the long way round
      shipped - the corner vertex is toward -outward on BOTH sides, and a
                Hermite that strays too far from its own chord is discarded
                for the straight chord
    """
    out_a, out_b = a["Out"], b["Out"]
    if mode == "legacy" and exterior:
        dir_a, dir_b = out_a, out_b
    else:
        dir_a, dir_b = mul(out_a, -1), mul(out_b, -1)
    chord = mag(sub(b["Kerb"], a["Kerb"]))
    capped = min(radius, chord * 0.45)
    p1, centre, p2, eff = fillet_compute(a["Kerb"], dir_a, b["Kerb"], dir_b, capped)
    if p1 is None:
        if mode == "legacy" and exterior:
            h_a, h_b = out_a, mul(out_b, -1)
        else:
            h_a, h_b = mul(out_a, -1), out_b
        kerb = hermite_boundary(a["Kerb"], h_a, b["Kerb"], h_b, HERMITE_SAMPLES)
        if mode == "shipped" and excursion(kerb) > MAX_HERMITE_EXCURSION:
            return [a["Kerb"], b["Kerb"]], "chord"
        return kerb, "hermite"
    kerb = [a["Kerb"], p1] + fillet_sample_arc(centre, eff, p1, p2, FILLET_ARC_SAMPLES)
    kerb += [p2, b["Kerb"]]
    return kerb, "fillet"


# -------------------------------------------------------------- the walk


def outward_dirs(bearings_deg):
    return [(math.cos(math.radians(b)), math.sin(math.radians(b))) for b in bearings_deg]


def kerb_points(bearings_deg, kerb_half, trim):
    """Every road's two kerb points - the convex hull fallback's input."""
    pts = []
    for out in outward_dirs(bearings_deg):
        end, n = mul(out, trim), (-out[1], out[0])
        pts += [add(end, mul(n, kerb_half)), sub(end, mul(n, kerb_half))]
    return pts


def build_pad(bearings_deg, kerb_half, trim, radius, mode):
    """Roads leaving the node along each of `bearings_deg`."""
    centre = (0.0, 0.0)
    outs = outward_dirs(bearings_deg)

    approaches = []
    for road, out in enumerate(outs):
        end = mul(out, trim)
        n = (-out[1], out[0])
        pts = [{"Road": road, "Kerb": add(end, mul(n, kerb_half)), "Out": out},
               {"Road": road, "Kerb": sub(end, mul(n, kerb_half)), "Out": out}]
        mid = mul(add(pts[0]["Kerb"], pts[1]["Kerb"]), 0.5)
        ang = math.atan2(mid[1] - centre[1], mid[0] - centre[0])
        d1 = angle_delta(math.atan2(pts[0]["Kerb"][1], pts[0]["Kerb"][0]), ang)
        d2 = angle_delta(math.atan2(pts[1]["Kerb"][1], pts[1]["Kerb"][0]), ang)
        cw, ccw = (pts[0], pts[1]) if d1 <= d2 else (pts[1], pts[0])
        approaches.append({"Road": road, "Angle": ang, "Cw": cw, "Ccw": ccw})
    approaches.sort(key=lambda x: x["Angle"])

    pad = []

    def append_unique(p):
        if pad and mag(sub(pad[-1], p)) < 0.05:
            return
        pad.append(p)

    spans = []
    for i in range(len(approaches)):
        nxt = (i + 1) % len(approaches)
        span = approaches[nxt]["Angle"] - approaches[i]["Angle"]
        if span < 0:
            span += 2 * math.pi
        turn = min(span, 2 * math.pi - span)
        exterior = span > math.pi
        a, b = approaches[i]["Ccw"], approaches[nxt]["Cw"]
        if a["Road"] == b["Road"]:
            append_unique(a["Kerb"])
            continue
        real = MAX_CORNER_SPAN_RAD >= turn >= math.radians(20)
        if real:
            kerb, kind = corner_kerb(a, b, radius, exterior, mode)
            for p in kerb:
                append_unique(p)
        else:
            kind = "chord"
            append_unique(a["Kerb"])
            append_unique(b["Kerb"])
        spans.append((math.degrees(span), math.degrees(turn), exterior, kind))
    return pad, spans


# ---------------------------------------------------------------- checks


def poly_area2(poly):
    s = 0.0
    for i, p in enumerate(poly):
        q = poly[(i + 1) % len(poly)]
        s += p[0] * q[1] - q[0] * p[1]
    return s


def segments_cross(a1, a2, b1, b2):
    o1, o2 = cross2d(a1, a2, b1), cross2d(a1, a2, b2)
    o3, o4 = cross2d(b1, b2, a1), cross2d(b1, b2, a2)
    return o1 * o2 < 0 and o3 * o4 < 0


def self_intersects(poly):
    n = len(poly)
    for i in range(n):
        for j in range(i + 1, n):
            if i == j or (i + 1) % n == j or (j + 1) % n == i:
                continue
            if segments_cross(poly[i], poly[(i + 1) % n], poly[j], poly[(j + 1) % n]):
                return True
    return False


def fan_overdraw(poly):
    """Sum of |centroid-fan triangle| / |polygon|. 1.00 iff the fan is valid."""
    area = abs(poly_area2(poly)) / 2
    if area < 1e-9:
        return float("inf")
    cx = sum(p[0] for p in poly) / len(poly)
    cy = sum(p[1] for p in poly) / len(poly)
    total = 0.0
    for i, p in enumerate(poly):
        q = poly[(i + 1) % len(poly)]
        total += abs(cross2d((cx, cy), p, q)) / 2
    return total / area


def ear_clip(poly):
    """Port of the fix: CivicArc JunctionTool's ear-clipping triangulation."""
    area2 = poly_area2(poly)
    if abs(area2) < 1e-4:
        return None
    orient = 1 if area2 >= 0 else -1
    idx = list(range(len(poly)))
    tris = []
    guard = 0
    while len(idx) > 3 and guard < 256:
        guard += 1
        found = False
        for i in range(len(idx)):
            pi, ci, ni = idx[i - 1], idx[i], idx[(i + 1) % len(idx)]
            a, b, c = poly[pi], poly[ci], poly[ni]
            if cross2d(a, b, c) * orient <= 1e-5:
                continue
            blocked = False
            for t in idx:
                if t in (pi, ci, ni):
                    continue
                p = poly[t]
                if (cross2d(a, b, p) * orient >= -1e-5 and cross2d(b, c, p) * orient >= -1e-5
                        and cross2d(c, a, p) * orient >= -1e-5):
                    blocked = True
                    break
            if not blocked:
                tris.append((a, b, c))
                idx.pop(i)
                found = True
                break
        if not found:
            return None
    if len(idx) == 3:
        tris.append((poly[idx[0]], poly[idx[1]], poly[idx[2]]))
    return tris


def ear_overdraw(poly):
    tris = ear_clip(poly)
    if tris is None:
        return float("inf")
    area = abs(poly_area2(poly)) / 2
    total = sum(abs(cross2d(a, b, c)) / 2 for a, b, c in tris)
    return total / area if area > 1e-9 else float("inf")


POLY_MERGE = 0.05
POLY_COLLINEAR = 0.02


def clean_polygon(poly):
    """Port of JunctionBuilder.cleanPolygon."""
    out = []
    for p in poly:
        if not out or mag(sub(out[-1], p)) > POLY_MERGE:
            out.append(p)
    while len(out) >= 2 and mag(sub(out[0], out[-1])) <= POLY_MERGE:
        out.pop()
    changed = True
    while changed and len(out) > 3:
        changed = False
        for i in range(len(out)):
            prev, nxt = out[i - 1], out[(i + 1) % len(out)]
            base = mag(sub(prev, nxt))
            if base > 1e-6 and abs(cross2d(prev, nxt, out[i])) / base <= POLY_COLLINEAR:
                out.pop(i)
                changed = True
                break
    return out


def convex_hull(points):
    """Port of JunctionBuilder.convexHull, monotone chain over raw points."""
    pts = sorted(set(points))
    if len(pts) < 3:
        return pts

    def chain(seq):
        out = []
        for q in seq:
            while len(out) >= 2 and cross2d(out[-2], out[-1], q) <= 0:
                out.pop()
            out.append(q)
        return out

    lower, upper = chain(pts), chain(reversed(pts))
    if len(lower) >= 2 and len(upper) >= 2:
        lower, upper = lower[:-1], upper[:-1]
    hull = lower + upper
    if len(hull) < 3:
        cx = sum(p[0] for p in points) / len(points)
        cy = sum(p[1] for p in points) / len(points)
        return sorted(points, key=lambda p: math.atan2(p[1] - cy, p[0] - cx))
    return hull


def fill_pad(pad, kerbs):
    """Port of the shipped fill: clean -> reject self-crossing -> ear clip,
    falling back to the convex hull of the kerb points. Returns
    (triangles, which_path)."""
    outline = clean_polygon(pad)
    if len(outline) >= 3 and not self_intersects(outline):
        tris = ear_clip(outline)
        if tris is not None:
            return tris, outline, "corner walk"
    hull = clean_polygon(convex_hull(kerbs))
    return (ear_clip(hull) if len(hull) >= 3 else None), hull, "convex hull"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bend", type=float, help="single two-road bend, degrees from dead straight")
    ap.add_argument("--radius", type=float, default=12.0)
    ap.add_argument("--legacy", action="store_true",
                    help="also show the pre-fix behaviour, for comparison")
    args = ap.parse_args()

    if args.bend:
        cases = [(f"bend {args.bend:g}", [180.0, args.bend])]
    else:
        cases = [(f"bend {b:g}", [180.0, float(b)]) for b in
                 (35, 40, 45, 55, 60, 75, 90, 100, 110, 120, 130, 140, 150, 160, 170)]
        # 3+ legs: a span can exceed 180 degrees whenever the legs bunch to
        # one side, so these hit the same exterior path a two-road bend does.
        cases += [
            ("T square", [0.0, 90.0, 180.0]),
            ("T skewed", [0.0, 70.0, 200.0]),
            ("T bunched", [0.0, 45.0, 90.0]),
            ("X square", [0.0, 90.0, 180.0, 270.0]),
            ("X skewed", [0.0, 75.0, 185.0, 250.0]),
            ("X bunched", [0.0, 40.0, 80.0, 120.0]),
            ("5 legs", [0.0, 60.0, 130.0, 200.0, 290.0]),
        ]
    shapes = [(9.0, 15.0), (14.0, 25.0), (6.0, 40.0)]
    modes = ("legacy", "shipped") if args.legacy else ("shipped",)
    print(f"fillet radius {args.radius:g}; road shapes (kerb half-width, trim): "
          + ", ".join(f"({w:g},{t:g})" for w, t in shapes))
    print()
    print(f"{'case':>10} {'mode':>7} {'w':>4} {'t':>4}  {'walk cross?':>11} {'walk over':>9}  {'used':<12} {'final':>10}  spans")
    bad = 0
    for label, bearings in cases:
        if len(bearings) == 2:
            dot = math.cos(math.radians(bearings[1] - bearings[0]))
            if dot < PASS_THROUGH_DOT_THRESHOLD:
                print(f"{label:>10}  skipped by isSmoothPassThrough (gentle through-curve, no pad)")
                continue
        for mode in modes:
            for kerb_half, trim in shapes:
                pad, spans = build_pad(bearings, kerb_half, trim, args.radius, mode)
                crossed = len(pad) < 3 or self_intersects(pad)
                walk_over = ear_overdraw(pad) if len(pad) >= 3 else float("inf")
                tris, used_poly, path = fill_pad(pad, kerb_points(bearings, kerb_half, trim))
                if tris is None:
                    final, ok = float("inf"), False
                else:
                    area = abs(poly_area2(used_poly)) / 2
                    total = sum(abs(cross2d(a, b, c)) / 2 for a, b, c in tris)
                    final = total / area if area > 1e-9 else float("inf")
                    ok = not self_intersects(used_poly) and final <= 1.001
                kinds = ",".join(f"{'ext' if e else 'int'}:{k}" for _, _, e, k in spans)
                if mode == "shipped" and not ok:
                    bad += 1
                flag = "" if ok or mode == "legacy" else "  <-- BROKEN"
                print(f"{label:>10} {mode:>7} {kerb_half:4g} {trim:4g}  {str(crossed):>11} {walk_over:9.3f}"
                      f"  {path:<12} {final:10.3f}  {kinds}{flag}")
        print()
    print("'walk over' is the corner walk's own ear-clip overdraw (inf = outline unusable);")
    print("'final' is the overdraw of what actually gets filled. 1.000 means the triangles")
    print("tile the pad exactly once - no double-cover, no overhang, no spikes.")
    print()
    if bad:
        print(f"{bad} case(s) BROKEN")
    else:
        print(f"all {len(cases) * len(shapes)} cases fill exactly once over")
    raise SystemExit(1 if bad else 0)


if __name__ == "__main__":
    main()
