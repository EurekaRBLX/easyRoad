#!/usr/bin/env python3
"""Preview a two-road CORNER (an L bend), the case that currently ships a
semicircle.

A two-road node is not an intersection - CivicArc builds a corner path for any
bend over 18 degrees, and the clipping-circle paper draws its L-shaped case
with no clipping lines at all. Our JunctionBuilder instead treats anything
sharper than 32 degrees as a junction and falls through to a plain
`Enum.PartType.Cylinder` pad, whose outer boundary is the reported bulge.

Two roads whose centrelines both END at the node overlap on the INSIDE of the
bend (harmless - same asphalt) and leave a V-shaped notch on the OUTSIDE. The
corner is therefore an outside-only problem:

    miter  = fill the notch to where the two outer edges would meet
    fillet = replace that point with an arc of radius r tangent to both

Checks, both of which the current shipped behaviour fails:

  * BARE GROUND - anything inside the corner envelope no part covers
  * BULGE       - any part material outside the envelope, which is exactly
                  what a circular pad on a two-road node produces

    python3 corner_preview.py --turn 90 --fillet 8
"""
import argparse
import math

import roundabout_preview as P
from raster import Canvas

GROUND = (255, 0, 200)
FLAT = (70, 70, 70)
BULGE = (255, 220, 0)


def unit(v):
    m = math.hypot(v[0], v[1])
    return (v[0] / m, v[1] / m) if m > 1e-9 else (0.0, 0.0)


def line_intersect(p, d, q, e):
    """Intersection of p+t*d and q+s*e, or None if parallel."""
    den = d[0] * e[1] - d[1] * e[0]
    if abs(den) < 1e-9:
        return None
    t = ((q[0] - p[0]) * e[1] - (q[1] - p[1]) * e[0]) / den
    return (p[0] + d[0] * t, p[1] + d[1] * t)


def point_in(poly, pt):
    inside = False
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        if (a[1] > pt[1]) != (b[1] > pt[1]):
            x = a[0] + (pt[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
            if x > pt[0]:
                inside = not inside
    return inside


def straight(from_pt, to_pt):
    d = (to_pt[0] - from_pt[0], to_pt[1] - from_pt[1])
    c1 = (from_pt[0] + d[0] / 3, from_pt[1] + d[1] / 3)
    c2 = (from_pt[0] + 2 * d[0] / 3, from_pt[1] + 2 * d[1] / 3)
    return P.PolyCurve([P.Cubic(from_pt, c1, c2, to_pt)])


def fillet_arc(corner, edge_a_pt, dir_a, edge_b_pt, dir_b, radius, steps=24):
    """Arc of `radius` tangent to both outer edge lines, plus its tangent points.

    Returns (points, tangent_a, tangent_b). Falls back to the sharp miter point
    when the lines are parallel or the radius does not fit.
    """
    apex = line_intersect(edge_a_pt, dir_a, edge_b_pt, dir_b)
    if apex is None:
        return [], None, None
    # Unit vectors from the apex back along each edge.
    ua = unit((edge_a_pt[0] - apex[0], edge_a_pt[1] - apex[1]))
    ub = unit((edge_b_pt[0] - apex[0], edge_b_pt[1] - apex[1]))
    cosine = max(-1.0, min(1.0, ua[0] * ub[0] + ua[1] * ub[1]))
    half = math.acos(cosine) / 2
    if half < 1e-4 or half > math.pi / 2 - 1e-4:
        return [apex], apex, apex
    setback = radius / math.tan(half)
    ta = (apex[0] + ua[0] * setback, apex[1] + ua[1] * setback)
    tb = (apex[0] + ub[0] * setback, apex[1] + ub[1] * setback)
    bis = unit((ua[0] + ub[0], ua[1] + ub[1]))
    centre_dist = radius / math.sin(half)
    centre = (apex[0] + bis[0] * centre_dist, apex[1] + bis[1] * centre_dist)
    a0 = math.atan2(ta[1] - centre[1], ta[0] - centre[0])
    a1 = math.atan2(tb[1] - centre[1], tb[0] - centre[0])
    sweep = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
    pts = [(centre[0] + math.cos(a0 + sweep * i / steps) * radius,
            centre[1] + math.sin(a0 + sweep * i / steps) * radius)
           for i in range(steps + 1)]
    return pts, ta, tb


def build(turn_deg, approach_lanes, fillet_radius, drive_on_left, legacy_pad):
    """Road A comes in along +x, road B leaves rotated by `turn_deg`."""
    node = (0.0, 0.0)
    profile = P.two_way(approach_lanes, approach_lanes, drive_on_left)
    half = sum(c[1] for c in profile) / 2 * P.SCALE
    road_half = max(abs(x) for x in P.roadway_edges_m(profile)) * P.SCALE
    run = 90.0

    turn = math.radians(turn_deg)
    dir_a = (1.0, 0.0)                                  # A travels toward node
    dir_b = (math.cos(turn), math.sin(turn))            # B leaves the node
    start_a = (-dir_a[0] * run, -dir_a[1] * run)
    end_b = (dir_b[0] * run, dir_b[1] * run)

    parts = P.emit_road(straight(start_a, node), profile)
    parts += P.emit_road(straight(node, end_b), profile)

    # Outside of the bend is the side the road turns AWAY from.
    cross = dir_a[0] * dir_b[1] - dir_a[1] * dir_b[0]
    outward = -1 if cross > 0 else 1

    def edge_point(direction, offset):
        r = (-direction[1], direction[0])
        return (node[0] + r[0] * offset * outward, node[1] + r[1] * offset * outward)

    corner_polys = []
    envelope_arc = []
    if not legacy_pad:
        for offset, _name in ((road_half, "roadway"), (half, "pavement")):
            ea, eb = edge_point(dir_a, offset), edge_point(dir_b, offset)
            arc, ta, tb = fillet_arc(node, ea, dir_a, eb, dir_b, fillet_radius)
            if not arc:
                continue
            poly = [node, ea]
            if ta and ta != tb:
                poly.append(ta)
            poly += list(arc)
            if tb and ta != tb:
                poly.append(tb)
            poly.append(eb)
            corner_polys.append(poly)
            if offset == half:
                envelope_arc = poly
    else:
        # What ships today: a circular pad centred on the node.
        radius = half + 2.0
        steps = 48
        poly = [(node[0] + math.cos(2 * math.pi * i / steps) * radius,
                 node[1] + math.sin(2 * math.pi * i / steps) * radius) for i in range(steps)]
        corner_polys.append(poly)
        envelope_arc = poly

    # Envelope: either road's full-width strip, plus the corner fill itself.
    def strip(p0, p1):
        d = unit((p1[0] - p0[0], p1[1] - p0[1]))
        r = (-d[1], d[0])
        return [(p0[0] + r[0] * half, p0[1] + r[1] * half),
                (p1[0] + r[0] * half, p1[1] + r[1] * half),
                (p1[0] - r[0] * half, p1[1] - r[1] * half),
                (p0[0] - r[0] * half, p0[1] - r[1] * half)]

    envelope = [strip(start_a, node), strip(node, end_b)]
    if not legacy_pad and envelope_arc:
        envelope.append(envelope_arc)

    return dict(parts=parts, corner=corner_polys, envelope=envelope, node=node,
                half=half, run=run, turn=turn_deg, legacy=legacy_pad)


def scan(scene, samples=420):
    """Bare ground inside the envelope, and material outside it."""
    half, run = scene["half"], scene["run"]
    reach = half * 3 + 10
    bare = bulge = 0
    step = 2 * reach / samples
    for i in range(samples + 1):
        for j in range(samples + 1):
            pt = (-reach + i * step, -reach + j * step)
            inside = any(point_in(poly, pt) for poly in scene["envelope"])
            covered = any(point_in(q.poly, pt) for q in scene["parts"]) or \
                any(point_in(poly, pt) for poly in scene["corner"])
            if inside and not covered:
                bare += 1
            elif covered and not inside:
                bulge += 1
    area = step * step
    return bare * area, bulge * area


def render(scene, path):
    reach = scene["half"] * 3 + 20
    S = 4.0
    SZ = int(reach * 2 * S)
    tx = lambda p: (p[0] * S + SZ / 2, p[1] * S + SZ / 2)
    cv = Canvas(SZ, SZ, GROUND)
    for poly in scene["envelope"]:
        cv.fill_poly([tx(v) for v in poly], (235, 235, 235))
    for q in sorted(scene["parts"], key=lambda x: x.y):
        cv.fill_poly([tx(v) for v in q.poly], q.color)
    for poly in scene["corner"]:
        cv.fill_poly([tx(v) for v in poly], (90, 90, 90))
    cv.save(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--turn", type=float, default=90.0, help="bend in degrees")
    ap.add_argument("--fillet", type=float, default=8.0, help="outer fillet radius, studs")
    ap.add_argument("--lanes", type=int, default=1, help="running lanes each way")
    ap.add_argument("--right-hand", action="store_true")
    ap.add_argument("--out", default="out")
    args = ap.parse_args()

    import os
    os.makedirs(args.out, exist_ok=True)
    ok = True
    for legacy in (True, False):
        scene = build(args.turn, args.lanes, args.fillet, not args.right_hand, legacy)
        bare, bulge = scan(scene)
        label = "shipped (cylinder pad)" if legacy else f"miter+fillet r={args.fillet:g}"
        print(f"{args.turn:g} deg bend, {label}:")
        print(f"    bare ground inside envelope : {bare:8.1f} studs^2")
        print(f"    material outside envelope   : {bulge:8.1f} studs^2")
        name = f"corner_{int(args.turn)}_{'legacy' if legacy else 'fillet'}.png"
        render(scene, os.path.join(args.out, name))
        print(f"    wrote {os.path.join(args.out, name)}")
        if not legacy and (bare > 2.0 or bulge > 2.0):
            ok = False
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
