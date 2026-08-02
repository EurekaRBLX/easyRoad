#!/usr/bin/env python3
"""Headless validation + PNG preview for road structure generation.

This ports StructureBuilder.lua's socket-chord module stepping, evenly-spaced
downward pillar projection, procedural viaduct deck, and arched tunnel. It deliberately
stays stdlib-only like the other preview tools: `raster.py` writes the PNG
without Pillow.

    python3 tools/preview/structure_preview.py --check
    python3 tools/preview/structure_preview.py --out structure_preview.png

The PNG contains, from top to bottom: custom-module plan, procedural viaduct
side elevation, and procedural tunnel cross-section. Alternating module colours make custom
module overlaps/gaps visible; yellow dots/columns are raycast pier stations and
the green profile is terrain.
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
MAX_PROCEDURAL_PARTS = 6000
TUNNEL_ARCH_SEGMENTS = 9
STRUCTURE_SURFACE_CLEARANCE_STUDS = 0.08


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
    target_count = max(1, math.floor(curve.length/spacing))
    support_drop = -viaduct_section(86.0)["slab_bottom"]
    for index in range(1, target_count+1):
        station = curve.length*index/(target_count+1)
        road = curve.pos(station)
        top = (road[0], road[1]-support_drop, road[2])
        ground = terrain_y(top)
        height = top[1]-ground
        if 0.5 < height <= max_drop:
            piers.append((station, top, ground))
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


def central_base_thickness(scale):
    return max(0.2*scale, 0.65)


def safe_interface_overlap(requested_m, scale, road_thickness, base_thickness):
    return min(requested_m*scale, base_thickness*0.9,
               max(road_thickness-STRUCTURE_SURFACE_CLEARANCE_STUDS, 0))


def viaduct_section(road_width, scale=3.571, road_thickness=1.0,
                    interface_overlap_m=0.2, parapet_gap_m=0.0):
    """Port of the thin base and downward-extended parapet/fascia."""
    edge_allowance = 0.45*scale
    base_thickness = central_base_thickness(scale)
    fascia_depth = max(0.55*scale, 1.5)
    barrier_thickness = max(0.35*scale, 0.8)
    barrier_height = max(1.2*scale, 2.5)
    barrier_center = road_width/2 + parapet_gap_m*scale + barrier_thickness/2
    deck_half = max(road_width/2+edge_allowance, barrier_center+barrier_thickness/2)
    interface_overlap = safe_interface_overlap(
        interface_overlap_m, scale, road_thickness, base_thickness)
    base_top = -road_thickness+interface_overlap
    return {
        "deck_width": deck_half*2,
        "slab_bottom": base_top-base_thickness,
        "slab_top": base_top,
        "base_thickness": base_thickness,
        "fascia_depth": fascia_depth,
        "fascia_bottom": base_top-fascia_depth,
        "barrier_thickness": barrier_thickness,
        "barrier_height": barrier_height,
        "barrier_bottom": base_top-fascia_depth,
        "barrier_inner": barrier_center-barrier_thickness/2,
    }


def tunnel_section(road_width, scale=3.571, road_thickness=1.0,
                   interface_overlap_m=0.2, wall_clearance_m=0.75):
    """Port of the thin base, bottom-extended walls, and elliptical vault."""
    side_clearance = wall_clearance_m*scale
    thickness = max(0.35*scale, 0.5)
    base_thickness = central_base_thickness(scale)
    inner_half = road_width/2 + side_clearance
    wall_height = max(6*scale, inner_half*0.72)
    roof_rise = max(2.5*scale, inner_half*0.22)
    interface_overlap = safe_interface_overlap(
        interface_overlap_m, scale, road_thickness, base_thickness)
    floor_top = -road_thickness+interface_overlap
    wall_bottom = floor_top-thickness
    wall_top = floor_top+wall_height
    panels = []
    for index in range(TUNNEL_ARCH_SEGMENTS):
        theta0 = math.pi*index/TUNNEL_ARCH_SEGMENTS
        theta1 = math.pi*(index+1)/TUNNEL_ARCH_SEGMENTS
        panels.append((
            (-inner_half*math.cos(theta0), floor_top+wall_height+roof_rise*math.sin(theta0)),
            (-inner_half*math.cos(theta1), floor_top+wall_height+roof_rise*math.sin(theta1)),
        ))
    return {
        "inner_half": inner_half,
        "thickness": thickness,
        "base_thickness": base_thickness,
        "base_bottom": floor_top-base_thickness,
        "wall_height": wall_height,
        "wall_bottom": wall_bottom,
        "wall_top": wall_top,
        "roof_rise": roof_rise,
        "floor_top": floor_top,
        "panels": panels,
    }


def procedural_errors():
    errors = []
    road_width = 86.0
    viaduct = viaduct_section(road_width)
    if viaduct["deck_width"] <= road_width:
        errors.append("viaduct slab does not extend beyond the road")
    if viaduct["barrier_height"] <= 0 or viaduct["slab_bottom"] >= viaduct["slab_top"]:
        errors.append("invalid viaduct cross-section")
    if viaduct["slab_top"] > -STRUCTURE_SURFACE_CLEARANCE_STUDS+1e-9:
        errors.append("viaduct base can cover the road surface")
    if viaduct["base_thickness"] >= viaduct["fascia_depth"]:
        errors.append("viaduct central base was not shortened")
    if viaduct["barrier_bottom"] >= viaduct["slab_bottom"]:
        errors.append("viaduct walls do not compensate below the shortened base")
    if abs(viaduct["barrier_inner"]-road_width/2) > 1e-9:
        errors.append("default viaduct parapet leaves an edge gap")
    tunnel = tunnel_section(road_width)
    panels = tunnel["panels"]
    expected_y = tunnel["wall_top"]
    if len(panels) != TUNNEL_ARCH_SEGMENTS:
        errors.append("wrong tunnel vault panel count")
    if abs(panels[0][0][0]+tunnel["inner_half"]) > 1e-9 or abs(panels[-1][1][0]-tunnel["inner_half"]) > 1e-9:
        errors.append("vault does not meet both walls")
    if abs(panels[0][0][1]-expected_y) > 1e-9 or abs(panels[-1][1][1]-expected_y) > 1e-9:
        errors.append("vault endpoints do not meet the wall tops")
    for previous, current in zip(panels, panels[1:]):
        if dist(previous[1], current[0]) > 1e-9:
            errors.append("gap between tunnel vault panels")
    crown = max(point[1] for panel in panels for point in panel)
    if crown <= expected_y:
        errors.append("tunnel vault has no crown rise")
    if tunnel["floor_top"] > -STRUCTURE_SURFACE_CLEARANCE_STUDS+1e-9:
        errors.append("tunnel base can cover the road surface")
    if tunnel["base_thickness"] >= tunnel["thickness"]:
        errors.append("tunnel central base was not shortened")
    if tunnel["wall_bottom"] >= tunnel["base_bottom"]:
        errors.append("tunnel walls do not compensate below the shortened base")
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
        "MAX_PROCEDURAL_PARTS": MAX_PROCEDURAL_PARTS,
        "TUNNEL_ARCH_SEGMENTS": TUNNEL_ARCH_SEGMENTS,
        "STRUCTURE_SURFACE_CLEARANCE_STUDS": STRUCTURE_SURFACE_CLEARANCE_STUDS,
        "ARC_SAMPLES": ARC_SAMPLES,
    }
    sources = {
        "EPSILON": builder,
        "MAX_MODULES": builder,
        "MAX_PROCEDURAL_PARTS": builder,
        "TUNNEL_ARCH_SEGMENTS": builder,
        "STRUCTURE_SURFACE_CLEARANCE_STUDS": builder,
        "ARC_SAMPLES": curve_source,
    }
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
    errors = procedural_errors()
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

    # Procedural viaduct side elevation: structural slab/parapet over columns.
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
    viaduct = viaduct_section(86.0)
    wall_top = [side(curve.length*index/180, curve.pos(curve.length*index/180)[1]+viaduct["barrier_height"])
                for index in range(181)]
    wall_bottom = [side(curve.length*index/180, curve.pos(curve.length*index/180)[1]+viaduct["barrier_bottom"])
                   for index in range(181)]
    canvas.fill_poly(wall_top+list(reversed(wall_bottom)), (139, 143, 148))
    base_bottom = [side(curve.length*index/180, curve.pos(curve.length*index/180)[1]+viaduct["slab_bottom"])
                   for index in range(181)]
    canvas.polyline(base_bottom, (92, 97, 104), 2)
    canvas.polyline(road, (225, 230, 235), 4)
    canvas.polyline(wall_top, (174, 178, 183), 3)

    # Procedural tunnel cross-section: base, tall walls, and the same nine
    # contiguous elliptical vault panels emitted by StructureBuilder.lua.
    road_width = 86.0
    tunnel = tunnel_section(road_width)
    section_scale = 4.35
    center_x = 550
    floor_y = 708

    def section_point(point):
        x, y = point
        return center_x+x*section_scale, floor_y-(y-tunnel["floor_top"])*section_scale

    outer_half = tunnel["inner_half"]+tunnel["thickness"]
    base_bottom = floor_y+tunnel["base_thickness"]*section_scale
    canvas.fill_poly([
        section_point((-outer_half, tunnel["floor_top"])),
        section_point((outer_half, tunnel["floor_top"])),
        (center_x+outer_half*section_scale, base_bottom),
        (center_x-outer_half*section_scale, base_bottom),
    ], (139, 143, 148))
    wall_top_y = tunnel["wall_top"]
    for side_sign in (-1, 1):
        inner_x = side_sign*tunnel["inner_half"]
        outer_x = side_sign*outer_half
        canvas.fill_poly([
            section_point((inner_x, tunnel["wall_bottom"])),
            section_point((outer_x, tunnel["wall_bottom"])),
            section_point((outer_x, wall_top_y)),
            section_point((inner_x, wall_top_y)),
        ], (139, 143, 148))
    for panel in tunnel["panels"]:
        canvas.line(section_point(panel[0]), section_point(panel[1]), (139, 143, 148),
                    max(3, round(tunnel["thickness"]*section_scale)))

    # Road slab and lane markings remain visibly inside the generated shell.
    road_left = center_x-road_width*section_scale/2
    road_right = center_x+road_width*section_scale/2
    canvas.fill_poly([(road_left, floor_y-5), (road_right, floor_y-5),
                      (road_right, floor_y), (road_left, floor_y)], (48, 53, 60))
    for fraction in (-0.25, 0.0, 0.25):
        x = center_x+road_width*section_scale*fraction
        canvas.line((x, floor_y-7), (x, floor_y-4), (225, 230, 235), 2)

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
        print(f"wrote {args.out}: {len(ranges)} modules, {len(piers)} terrain-projected piers, "
              f"{TUNNEL_ARCH_SEGMENTS} tunnel-vault panels, {curve.length:.1f} studs")
    else:
        curve, ranges, piers = validate_geometry()
        print(f"structure checks passed: {len(ranges)} modules cover {curve.length:.1f} studs; "
              f"{len(piers)} piers touch terrain; {TUNNEL_ARCH_SEGMENTS} tunnel-vault panels are contiguous")
    return 0


if __name__ == "__main__":
    sys.exit(main())
