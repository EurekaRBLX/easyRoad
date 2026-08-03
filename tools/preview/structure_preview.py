#!/usr/bin/env python3
"""Headless validation + PNG preview for road structure generation.

This ports StructureBuilder.lua's socket-chord module stepping, evenly-spaced
downward pillar projection, procedural viaduct deck, and arched tunnel. It deliberately
stays stdlib-only like the other preview tools: `raster.py` writes the PNG
without Pillow.

    python3 tools/preview/structure_preview.py --check
    python3 tools/preview/structure_preview.py --out structure_preview.png

The PNG contains a custom-module plan, procedural viaduct side elevation,
twin-pillar/cap-beam cross-section, and procedural tunnel cross-section.
Distinct finish colours verify that bases, edge/side walls, and tunnel roofs
remain independently styleable. Alternating module colours make custom module
overlaps/gaps visible; yellow dots/columns are raycast stations and the green
profile is terrain.
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
PROCEDURAL_AXIAL_OVERLAP_STUDS = 0.16
STRUCTURE_EDGE_CLEARANCE_STUDS = 0.08

BASE_FINISH = (101, 126, 153)
VIADUCT_WALL_FINISH = (178, 145, 99)
TUNNEL_WALL_FINISH = (111, 148, 126)
TUNNEL_ROOF_FINISH = (145, 122, 169)


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
                    interface_overlap_m=0.2, parapet_gap_m=0.0,
                    parapet_height_m=1.2):
    """Port of the visibly exposed deck and downward parapet/fascia."""
    exposed_base_depth = central_base_thickness(scale)
    fascia_depth = max(0.55*scale, 1.5)
    barrier_thickness = max(0.35*scale, 0.8)
    barrier_height = max(parapet_height_m*scale, 0.2*scale)
    barrier_center = (road_width/2 + parapet_gap_m*scale
                      + STRUCTURE_EDGE_CLEARANCE_STUDS + barrier_thickness/2)
    deck_half = barrier_center-barrier_thickness/2
    interface_overlap = safe_interface_overlap(
        interface_overlap_m, scale, road_thickness, exposed_base_depth)
    base_thickness = exposed_base_depth+interface_overlap
    base_top = -road_thickness+interface_overlap
    return {
        "deck_width": deck_half*2,
        "slab_bottom": base_top-base_thickness,
        "slab_top": base_top,
        "base_thickness": base_thickness,
        "exposed_base_depth": exposed_base_depth,
        "fascia_depth": fascia_depth,
        "fascia_bottom": base_top-fascia_depth,
        "barrier_thickness": barrier_thickness,
        "barrier_height": barrier_height,
        "barrier_bottom": base_top-fascia_depth,
        "barrier_inner": barrier_center-barrier_thickness/2,
        "barrier_outer": barrier_center+barrier_thickness/2,
    }


def twin_support_section(scale=3.571, pillar_width_m=1.8,
                         pillar_separation_m=6.0, cap_width_m=9.0,
                         cap_height_m=1.0, cap_depth_m=2.2):
    """Port of the clamped twin-column and transverse cap-beam dimensions."""
    pillar_width = max(pillar_width_m*scale, 0.2)
    separation = max(pillar_separation_m*scale, pillar_width)
    cap_width = max(cap_width_m*scale, separation+pillar_width)
    return {
        "pillar_width": pillar_width,
        "pillar_centres": (-separation/2, separation/2),
        "separation": separation,
        "cap_width": cap_width,
        "cap_height": max(cap_height_m*scale, 0.2),
        "cap_depth": max(cap_depth_m*scale, pillar_width),
    }


def tunnel_section(road_width, scale=3.571, road_thickness=1.0,
                   interface_overlap_m=0.2, wall_clearance_m=0.75,
                   vertical_clearance_m=6.0):
    """Port of the thin base, bottom-extended walls, and elliptical vault."""
    side_clearance = wall_clearance_m*scale
    thickness = max(0.35*scale, 0.5)
    base_thickness = central_base_thickness(scale)
    inner_half = road_width/2 + side_clearance
    roof_rise = max(2.5*scale, inner_half*0.22)
    interface_overlap = safe_interface_overlap(
        interface_overlap_m, scale, road_thickness, base_thickness)
    floor_top = -road_thickness+interface_overlap
    wall_bottom = floor_top-thickness
    wall_top = max(vertical_clearance_m*scale, 2*scale)
    wall_height = wall_top-wall_bottom
    panels = []
    for index in range(TUNNEL_ARCH_SEGMENTS):
        theta0 = math.pi*index/TUNNEL_ARCH_SEGMENTS
        theta1 = math.pi*(index+1)/TUNNEL_ARCH_SEGMENTS
        panels.append((
            (-inner_half*math.cos(theta0), wall_top+roof_rise*math.sin(theta0)),
            (-inner_half*math.cos(theta1), wall_top+roof_rise*math.sin(theta1)),
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


def curved_edge_rectangle(centerline_radius, road_half_width, clearance,
                          thickness, segment_arc, side):
    """Plan footprint of one viaduct parapet using its own offset chord.

    ``side`` is -1 for the inside of the bend and +1 for the outside. This is
    the geometry contract for StructureBuilder.offsetSegmentFrame, distinct
    from the retired centreline box with a curvature-expanded depth.
    """
    wall_radius = centerline_radius+side*(road_half_width+clearance+thickness/2)
    delta = segment_arc/centerline_radius
    q0 = (wall_radius*math.cos(-delta/2), wall_radius*math.sin(-delta/2))
    q1 = (wall_radius*math.cos(delta/2), wall_radius*math.sin(delta/2))
    midpoint = ((q0[0]+q1[0])/2, (q0[1]+q1[1])/2)
    tangent = (q1[0]-q0[0], q1[1]-q0[1])
    tangent_length = math.hypot(*tangent)
    tangent = (tangent[0]/tangent_length, tangent[1]/tangent_length)
    radial = (tangent[1], -tangent[0])
    if radial[0] < 0:
        radial = (-radial[0], -radial[1])
    half_depth = (tangent_length+PROCEDURAL_AXIAL_OVERLAP_STUDS)/2
    return [
        (midpoint[0]+tangent[0]*along+radial[0]*across,
         midpoint[1]+tangent[1]*along+radial[1]*across)
        for along, across in ((-half_depth, -thickness/2),
                              (-half_depth, thickness/2),
                              (half_depth, thickness/2),
                              (half_depth, -thickness/2))
    ]


def curved_viaduct_errors(centerline_radius=20.0, road_half_width=8.0,
                          clearance=STRUCTURE_EDGE_CLEARANCE_STUDS,
                          thickness=1.25, segment_arc=8.0):
    errors = []
    inner = curved_edge_rectangle(centerline_radius, road_half_width, clearance,
                                  thickness, segment_arc, -1)
    outer = curved_edge_rectangle(centerline_radius, road_half_width, clearance,
                                  thickness, segment_arc, 1)
    road_inner = centerline_radius-road_half_width
    road_outer = centerline_radius+road_half_width
    if max(math.hypot(*point) for point in inner) >= road_inner-1e-6:
        errors.append("inside viaduct parapet clips the curved road envelope")
    if min(math.hypot(*point) for point in outer) <= road_outer+1e-6:
        errors.append("outside viaduct parapet clips the curved road envelope")
    return errors


def banked_structure_errors(road_roll_deg=6.0, structure_roll_deg=6.0,
                            road_half_width=43.0):
    """Cross-section parity for a road and its generated shell.

    A midpoint structure frame that ignores road roll diverges by several
    studs at a wide carriageway edge. Viaduct and tunnel parts must use the
    same banked frame so their local clearances remain unchanged.
    """
    mismatch = math.radians(structure_roll_deg-road_roll_deg)
    edge_divergence = abs(road_half_width*math.sin(mismatch))
    if edge_divergence > 1e-6:
        return [f"structure bank diverges from road by {edge_divergence:.3f} studs"]
    return []


def procedural_errors():
    errors = []
    road_width = 86.0
    viaduct = viaduct_section(road_width)
    if viaduct["deck_width"] <= road_width:
        errors.append("viaduct slab does not extend beyond the road")
    if viaduct["deck_width"]/2 > viaduct["barrier_inner"]+1e-9:
        errors.append("viaduct slab overshoots and blocks the sidewall")
    if viaduct["barrier_height"] <= 0 or viaduct["slab_bottom"] >= viaduct["slab_top"]:
        errors.append("invalid viaduct cross-section")
    if viaduct["slab_top"] > -STRUCTURE_SURFACE_CLEARANCE_STUDS+1e-9:
        errors.append("viaduct base can cover the road surface")
    if viaduct["slab_bottom"] > -1.0-viaduct["exposed_base_depth"]+1e-9:
        errors.append("viaduct slab is buried inside the road body")
    if viaduct["base_thickness"] >= viaduct["fascia_depth"]:
        errors.append("viaduct central base was not shortened")
    if viaduct["barrier_bottom"] >= viaduct["slab_bottom"]:
        errors.append("viaduct walls do not compensate below the shortened base")
    if abs(viaduct["barrier_inner"]-(road_width/2+STRUCTURE_EDGE_CLEARANCE_STUDS)) > 1e-9:
        errors.append("default viaduct parapet lacks the structural edge clearance")
    errors.extend(curved_viaduct_errors())
    errors.extend(banked_structure_errors())
    twin = twin_support_section()
    left, right = twin["pillar_centres"]
    if abs((right-left)-twin["separation"]) > 1e-9:
        errors.append("twin pillar centres do not match configured separation")
    if twin["cap_width"]+1e-9 < twin["separation"]+twin["pillar_width"]:
        errors.append("cap beam does not cover both pillar widths")
    if twin["cap_height"] <= 0 or twin["cap_depth"] <= 0:
        errors.append("invalid cap beam dimensions")
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
    if abs(tunnel["wall_top"]-6.0*3.571) > 1e-9:
        errors.append("tunnel vertical clearance is not applied above the road datum")
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
        "PROCEDURAL_AXIAL_OVERLAP_STUDS": PROCEDURAL_AXIAL_OVERLAP_STUDS,
        "STRUCTURE_EDGE_CLEARANCE_STUDS": STRUCTURE_EDGE_CLEARANCE_STUDS,
        "ARC_SAMPLES": ARC_SAMPLES,
    }
    sources = {
        "EPSILON": builder,
        "MAX_MODULES": builder,
        "MAX_PROCEDURAL_PARTS": builder,
        "TUNNEL_ARCH_SEGMENTS": builder,
        "STRUCTURE_SURFACE_CLEARANCE_STUDS": builder,
        "PROCEDURAL_AXIAL_OVERLAP_STUDS": builder,
        "STRUCTURE_EDGE_CLEARANCE_STUDS": builder,
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
    canvas = Canvas(1200, 760, (29, 34, 43))
    # Panel separators.
    canvas.line((40, 250), (1160, 250), (72, 82, 96), 2)
    canvas.line((40, 505), (1160, 505), (72, 82, 96), 2)

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

    # Tight curved viaduct plan inset. These are the actual offset-chord
    # parapet rectangles used by the clearance regression, not decorative
    # centreline strokes: neither parapet may enter the dark road annulus.
    inset_center = (1050, 135)
    inset_scale = 3.0
    inset_radius = 20.0
    inset_road_half = 8.0
    inset_clearance = STRUCTURE_EDGE_CLEARANCE_STUDS
    inset_thickness = 1.25
    inset_angles = [(-1.0+2.0*i/60) for i in range(61)]

    def inset_point(radius, angle):
        return (inset_center[0]+math.cos(angle)*radius*inset_scale,
                inset_center[1]+math.sin(angle)*radius*inset_scale)

    road_band = [inset_point(inset_radius+inset_road_half, angle)
                 for angle in inset_angles]
    road_band += [inset_point(inset_radius-inset_road_half, angle)
                  for angle in reversed(inset_angles)]
    canvas.fill_poly(road_band, (48, 53, 60))

    def rotate_point(point, angle):
        x, y = point
        return (x*math.cos(angle)-y*math.sin(angle),
                x*math.sin(angle)+y*math.cos(angle))

    for angle in (-0.8, -0.4, 0.0, 0.4, 0.8):
        for side in (-1, 1):
            rectangle = curved_edge_rectangle(
                inset_radius, inset_road_half, inset_clearance,
                inset_thickness, 8.0, side)
            transformed = []
            for point in rectangle:
                x, y = rotate_point(point, angle)
                transformed.append((inset_center[0]+x*inset_scale,
                                    inset_center[1]+y*inset_scale))
            canvas.fill_poly(transformed, VIADUCT_WALL_FINISH)

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
                         BASE_FINISH)
        canvas.disc(b[0], b[1], 4, (244, 196, 74))
    viaduct = viaduct_section(86.0)
    wall_top = [side(curve.length*index/180, curve.pos(curve.length*index/180)[1]+viaduct["barrier_height"])
                for index in range(181)]
    wall_bottom = [side(curve.length*index/180, curve.pos(curve.length*index/180)[1]+viaduct["barrier_bottom"])
                   for index in range(181)]
    canvas.fill_poly(wall_top+list(reversed(wall_bottom)), VIADUCT_WALL_FINISH)
    base_bottom = [side(curve.length*index/180, curve.pos(curve.length*index/180)[1]+viaduct["slab_bottom"])
                   for index in range(181)]
    canvas.polyline(base_bottom, BASE_FINISH, 3)
    canvas.polyline(road, (225, 230, 235), 4)
    canvas.polyline(wall_top, (174, 178, 183), 3)

    # Twin-pillar viaduct cross-section. Each column is independently
    # projected, and both terminate at the underside of the transverse cap.
    twin = twin_support_section()
    viaduct_cross = viaduct_section(86.0)
    twin_center_x = 285
    support_scale = 4.0
    slab_top_y = 555
    road_half_px = 86.0*support_scale/2
    deck_half_px = viaduct_cross["deck_width"]*support_scale/2
    base_height_px = viaduct_cross["base_thickness"]*support_scale
    road_surface_y = slab_top_y+viaduct_cross["slab_top"]*support_scale
    road_bottom_y = road_surface_y+1.0*support_scale
    bank_angle = math.radians(-6.0)

    def bank_viaduct(points):
        transformed = []
        for x, y in points:
            dx, dy = x-twin_center_x, y-road_surface_y
            transformed.append((
                twin_center_x+dx*math.cos(bank_angle)-dy*math.sin(bank_angle),
                road_surface_y+dx*math.sin(bank_angle)+dy*math.cos(bank_angle),
            ))
        return transformed

    canvas.fill_poly(bank_viaduct([
        (twin_center_x-deck_half_px, slab_top_y),
        (twin_center_x+deck_half_px, slab_top_y),
        (twin_center_x+deck_half_px, slab_top_y+base_height_px),
        (twin_center_x-deck_half_px, slab_top_y+base_height_px),
    ]), BASE_FINISH)
    canvas.fill_poly(bank_viaduct([
        (twin_center_x-road_half_px, road_surface_y),
        (twin_center_x+road_half_px, road_surface_y),
        (twin_center_x+road_half_px, road_bottom_y),
        (twin_center_x-road_half_px, road_bottom_y),
    ]), (48, 53, 60))
    barrier_width_px = viaduct_cross["barrier_thickness"]*support_scale
    barrier_top_y = road_surface_y-viaduct_cross["barrier_height"]*support_scale
    barrier_bottom_y = road_surface_y-viaduct_cross["barrier_bottom"]*support_scale
    for sign in (-1, 1):
        inner_x = twin_center_x+sign*(road_half_px+STRUCTURE_EDGE_CLEARANCE_STUDS*support_scale)
        x0 = inner_x-barrier_width_px if sign < 0 else inner_x
        canvas.fill_poly(bank_viaduct([
            (x0, barrier_top_y), (x0+barrier_width_px, barrier_top_y),
            (x0+barrier_width_px, barrier_bottom_y), (x0, barrier_bottom_y),
        ]), VIADUCT_WALL_FINISH)
    cap_width_px = twin["cap_width"]*support_scale
    cap_height_px = twin["cap_height"]*support_scale
    cap_top = slab_top_y+base_height_px
    canvas.fill_poly(bank_viaduct([
        (twin_center_x-cap_width_px/2, cap_top),
        (twin_center_x+cap_width_px/2, cap_top),
        (twin_center_x+cap_width_px/2, cap_top+cap_height_px),
        (twin_center_x-cap_width_px/2, cap_top+cap_height_px),
    ]), BASE_FINISH)
    ground_y = 730
    pillar_width_px = twin["pillar_width"]*support_scale
    for centre in twin["pillar_centres"]:
        x, column_top = bank_viaduct([(
            twin_center_x+centre*support_scale,
            cap_top+cap_height_px,
        )])[0]
        canvas.fill_poly([
            (x-pillar_width_px/2, column_top),
            (x+pillar_width_px/2, column_top),
            (x+pillar_width_px/2, ground_y),
            (x-pillar_width_px/2, ground_y),
        ], BASE_FINISH)
        canvas.disc(x, ground_y, 4, (244, 196, 74))
    canvas.fill_poly([(70, ground_y), (500, ground_y), (500, 750), (70, 750)], (55, 94, 64))

    # Procedural tunnel cross-section: base, tall walls, and the same nine
    # contiguous elliptical vault panels emitted by StructureBuilder.lua.
    road_width = 86.0
    tunnel = tunnel_section(road_width)
    section_scale = 4.35
    center_x = 865
    floor_y = 708
    tunnel_bank_angle = math.radians(-6.0)

    def bank_tunnel(points):
        transformed = []
        pivot_y = floor_y-5
        for x, y in points:
            dx, dy = x-center_x, y-pivot_y
            transformed.append((
                center_x+dx*math.cos(tunnel_bank_angle)-dy*math.sin(tunnel_bank_angle),
                pivot_y+dx*math.sin(tunnel_bank_angle)+dy*math.cos(tunnel_bank_angle),
            ))
        return transformed

    def section_point(point):
        x, y = point
        return center_x+x*section_scale, floor_y-(y-tunnel["floor_top"])*section_scale

    outer_half = tunnel["inner_half"]+tunnel["thickness"]
    base_bottom = floor_y+tunnel["base_thickness"]*section_scale
    canvas.fill_poly(bank_tunnel([
        section_point((-outer_half, tunnel["floor_top"])),
        section_point((outer_half, tunnel["floor_top"])),
        (center_x+outer_half*section_scale, base_bottom),
        (center_x-outer_half*section_scale, base_bottom),
    ]), BASE_FINISH)
    wall_top_y = tunnel["wall_top"]
    for side_sign in (-1, 1):
        inner_x = side_sign*tunnel["inner_half"]
        outer_x = side_sign*outer_half
        canvas.fill_poly(bank_tunnel([
            section_point((inner_x, tunnel["wall_bottom"])),
            section_point((outer_x, tunnel["wall_bottom"])),
            section_point((outer_x, wall_top_y)),
            section_point((inner_x, wall_top_y)),
        ]), TUNNEL_WALL_FINISH)
    for panel in tunnel["panels"]:
        segment = bank_tunnel([section_point(panel[0]), section_point(panel[1])])
        canvas.line(segment[0], segment[1], TUNNEL_ROOF_FINISH,
                    max(3, round(tunnel["thickness"]*section_scale)))

    # Road slab and lane markings remain visibly inside the generated shell.
    road_left = center_x-road_width*section_scale/2
    road_right = center_x+road_width*section_scale/2
    canvas.fill_poly(bank_tunnel([(road_left, floor_y-5), (road_right, floor_y-5),
                                  (road_right, floor_y), (road_left, floor_y)]),
                     (48, 53, 60))
    for fraction in (-0.25, 0.0, 0.25):
        x = center_x+road_width*section_scale*fraction
        marking = bank_tunnel([(x, floor_y-7), (x, floor_y-4)])
        canvas.line(marking[0], marking[1], (225, 230, 235), 2)

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
