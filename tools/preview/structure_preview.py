#!/usr/bin/env python3
"""Headless validation + PNG preview for rigid structure modules and piers.

This ports StructureBuilder.lua's socket-chord module stepping and downward
pillar projection. It deliberately stays stdlib-only like the other preview
tools: `raster.py` writes the PNG without Pillow.

    python3 tools/preview/structure_preview.py --check
    python3 tools/preview/structure_preview.py --out structure_preview.png

The PNG contains, from top to bottom: viaduct plan, viaduct side elevation,
and tunnel-module plan. Alternating module colours make overlaps/gaps visible;
yellow dots/columns are raycast pier stations and the green profile is terrain.
"""
import argparse
import bisect
import math
import os
import re
import sys

from raster import Canvas

ARC_SAMPLES = 64
EPSILON = 0.05
MAX_MODULES = 2000


def dist(a, b):
    return math.sqrt(sum((x-y) ** 2 for x, y in zip(a, b)))


class Cubic3:
    """Same 64-sample arc-length lookup convention as CurveSegment.lua."""
    def __init__(self, p0, p1, p2, p3):
        self.p = (p0, p1, p2, p3)
        self.arc = [0.0]
        previous = self.at(0.0)
        for index in range(1, ARC_SAMPLES):
            current = self.at(index/(ARC_SAMPLES-1))
            self.arc.append(self.arc[-1] + dist(previous, current))
            previous = current
        self.length = self.arc[-1]

    def at(self, t):
        p0, p1, p2, p3 = self.p
        u = 1-t
        return tuple(
            u**3*p0[i] + 3*u*u*t*p1[i] + 3*u*t*t*p2[i] + t**3*p3[i]
            for i in range(3)
        )

    def pos(self, station):
        station = max(0.0, min(self.length, station))
        index = bisect.bisect_left(self.arc, station)
        if index <= 0:
            return self.at(0.0)
        if index >= len(self.arc):
            return self.at(1.0)
        span = self.arc[index] - self.arc[index-1]
        fraction = 0.0 if span < 1e-9 else (station-self.arc[index-1])/span
        t = ((index-1)+fraction)/(ARC_SAMPLES-1)
        return self.at(t)


def advance_by_chord(curve, start_station, chord_length):
    if start_station >= curve.length:
        return curve.length
    start = curve.pos(start_station)
    lo = start_station
    hi = min(curve.length, start_station + chord_length*1.25 + 2)
    while hi < curve.length and dist(curve.pos(hi), start) < chord_length:
        hi = min(curve.length, start_station + (hi-start_station)*1.75)
    if dist(curve.pos(hi), start) < chord_length:
        return curve.length
    for _ in range(28):
        mid = (lo+hi)/2
        if dist(curve.pos(mid), start) < chord_length:
            lo = mid
        else:
            hi = mid
    return hi


def retreat_by_chord(curve, end_station, chord_length):
    end = curve.pos(end_station)
    lo = max(0.0, end_station-chord_length*1.75-2)
    hi = end_station
    while lo > 0 and dist(end, curve.pos(lo)) < chord_length:
        lo = max(0.0, end_station-(end_station-lo)*1.75)
    if dist(end, curve.pos(lo)) < chord_length:
        return 0.0
    for _ in range(28):
        mid = (lo+hi)/2
        if dist(end, curve.pos(mid)) > chord_length:
            lo = mid
        else:
            hi = mid
    return hi


def module_ranges(curve, module_length):
    ranges = []
    if curve.length < EPSILON:
        return ranges
    if dist(curve.pos(curve.length), curve.pos(0)) < module_length and curve.length < module_length*1.1:
        return [(0.0, curve.length)]
    station = 0.0
    while station < curve.length-EPSILON and len(ranges) < MAX_MODULES:
        next_station = advance_by_chord(curve, station, module_length)
        if next_station <= station+EPSILON:
            break
        if next_station >= curve.length-EPSILON:
            last_start = retreat_by_chord(curve, curve.length, module_length)
            previous_start = ranges[-1][0] if ranges else -math.inf
            if last_start > previous_start+EPSILON:
                ranges.append((last_start, curve.length))
            elif not ranges:
                ranges.append((0.0, curve.length))
            break
        ranges.append((station, next_station))
        station = next_station
    return ranges


def terrain_y(position):
    x, _y, z = position
    return 4.0 + 3.2*math.sin(x/38.0) + 1.7*math.cos(z/17.0)


def projected_piers(curve, spacing, max_drop):
    piers = []
    station = spacing/2
    while station < curve.length-spacing*0.15:
        top = curve.pos(station)
        ground = terrain_y(top)
        height = top[1]-ground
        if 0.5 < height <= max_drop:
            piers.append((station, top, ground))
        station += spacing
    return piers


def module_errors(curve, ranges, module_length):
    errors = []
    if not ranges:
        return ["no modules generated"]
    if abs(ranges[0][0]) > EPSILON:
        errors.append("module coverage does not start at the road start")
    if abs(ranges[-1][1]-curve.length) > EPSILON:
        errors.append("module coverage does not reach the road end")
    for previous, current in zip(ranges, ranges[1:]):
        if current[0] > previous[1]+EPSILON:
            errors.append("gap between rigid modules")
    for start, end in ranges[:-1]:
        if abs(dist(curve.pos(start), curve.pos(end))-module_length) >= 0.01:
            errors.append("socket chord drift")
    return errors


def pier_errors(piers):
    errors = []
    for _station, top, ground in piers:
        if abs(ground-terrain_y(top)) >= 1e-9:
            errors.append("pier does not terminate on terrain")
        if not 0.5 < top[1]-ground <= 100.0:
            errors.append("pier height outside raycast range")
    return errors


def validate_parity():
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    with open(os.path.join(root, "src", "StructureBuilder.lua"), encoding="utf-8") as handle:
        builder = handle.read()
    with open(os.path.join(root, "src", "Geometry", "CurveSegment.lua"), encoding="utf-8") as handle:
        curve_source = handle.read()
    expected = {
        "EPSILON": EPSILON,
        "MAX_MODULES": MAX_MODULES,
        "ARC_SAMPLES": ARC_SAMPLES,
    }
    sources = {"EPSILON": builder, "MAX_MODULES": builder, "ARC_SAMPLES": curve_source}
    for name, value in expected.items():
        match = re.search(rf"local\s+{name}\s*=\s*([0-9.]+)", sources[name])
        assert match, f"could not find Lua {name}"
        assert float(match.group(1)) == float(value), f"Lua/Python drift for {name}"


def validate_geometry():
    validate_parity()
    curve = demo_curve()
    ranges = module_ranges(curve, 30.0)
    errors = module_errors(curve, ranges, 30.0)
    assert not errors, "; ".join(errors)
    piers = projected_piers(curve, 42.0, 100.0)
    assert len(piers) >= 4, "demo should exercise several terrain projections"
    errors = pier_errors(piers)
    assert not errors, "; ".join(errors)
    return curve, ranges, piers


def demo_curve():
    return Cubic3((0, 28, 0), (65, 31, -8), (132, 49, 68), (220, 35, 92))


def map_plan(position, top):
    x, _y, z = position
    return 80+x*4.1, top+120-z*1.45


def quad_around(a, b, half_width):
    dx, dy = b[0]-a[0], b[1]-a[1]
    length = math.hypot(dx, dy) or 1.0
    nx, ny = -dy/length*half_width, dx/length*half_width
    return [(a[0]+nx, a[1]+ny), (b[0]+nx, b[1]+ny),
            (b[0]-nx, b[1]-ny), (a[0]-nx, a[1]-ny)]


def render(path):
    curve, ranges, piers = validate_geometry()
    canvas = Canvas(1100, 760, (29, 34, 43))
    # Panel separators.
    canvas.line((40, 250), (1060, 250), (72, 82, 96), 2)
    canvas.line((40, 505), (1060, 505), (72, 82, 96), 2)

    # Viaduct plan: dark procedural deck, alternating imported modules, pier dots.
    plan_points = [map_plan(curve.pos(curve.length*i/180), 20) for i in range(181)]
    canvas.polyline(plan_points, (48, 53, 60), 30)
    module_colors = ((57, 171, 160), (89, 126, 207))
    for index, (start, end) in enumerate(ranges):
        a, b = map_plan(curve.pos(start), 20), map_plan(curve.pos(end), 20)
        canvas.fill_poly(quad_around(a, b, 10), module_colors[index % 2])
        canvas.line(a, b, (215, 226, 236), 2)
    for _station, top, _ground in piers:
        x, y = map_plan(top, 20)
        canvas.disc(x, y, 5, (244, 196, 74))

    # Viaduct side elevation: green terrain and concrete raycast columns.
    def side(station, elevation):
        return 75+station*4.1, 470-elevation*5.0
    terrain = []
    road = []
    for index in range(181):
        station = curve.length*index/180
        position = curve.pos(station)
        terrain.append(side(station, terrain_y(position)))
        road.append(side(station, position[1]))
    ground_poly = terrain + [(terrain[-1][0], 490), (terrain[0][0], 490)]
    canvas.fill_poly(ground_poly, (55, 94, 64))
    canvas.polyline(terrain, (102, 166, 104), 3)
    for _station, top, ground in piers:
        a = side(_station, top[1])
        b = side(_station, ground)
        canvas.fill_poly([(a[0]-5, a[1]), (a[0]+5, a[1]), (b[0]+7, b[1]), (b[0]-7, b[1])],
                         (139, 143, 148))
        canvas.disc(b[0], b[1], 4, (244, 196, 74))
    for index, (start, end) in enumerate(ranges):
        p0, p1 = curve.pos(start), curve.pos(end)
        a, b = side(start, p0[1]), side(end, p1[1])
        canvas.fill_poly(quad_around(a, b, 7), module_colors[index % 2])
    canvas.polyline(road, (225, 230, 235), 2)

    # Tunnel plan: same socket-chord solver, no piers. A larger dark outline
    # reads as the shell while alternating inner modules expose overlap/gaps.
    tunnel_points = [map_plan(curve.pos(curve.length*i/180), 520) for i in range(181)]
    canvas.polyline(tunnel_points, (112, 118, 128), 42)
    for index, (start, end) in enumerate(ranges):
        a, b = map_plan(curve.pos(start), 520), map_plan(curve.pos(end), 520)
        color = (123, 101, 171) if index % 2 else (92, 139, 164)
        canvas.fill_poly(quad_around(a, b, 15), color)
        canvas.line(a, b, (205, 213, 222), 2)

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    canvas.save(path)
    return curve, ranges, piers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="validate only; do not write an image")
    parser.add_argument("--out", help="PNG output path")
    args = parser.parse_args()
    if args.out:
        curve, ranges, piers = render(args.out)
        print(f"wrote {args.out}: {len(ranges)} modules, {len(piers)} terrain-projected piers, {curve.length:.1f} studs")
    else:
        curve, ranges, piers = validate_geometry()
        print(f"structure checks passed: {len(ranges)} modules cover {curve.length:.1f} studs; {len(piers)} piers touch terrain")
    return 0


if __name__ == "__main__":
    sys.exit(main())
