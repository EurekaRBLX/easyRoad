#!/usr/bin/env python3
"""Component-faithful ordinary-junction preview, matching roundabout_preview.

This is not an idealised lane diagram. It uses the same ``preview_core``
pipeline as ``roundabout_preview.py``:

* EasyRoad component tuples (kind, width metres, traffic direction)
* ``emit_road`` rigid Part strips and marking Parts
* UK dimensions, left-hand traffic, colours, and scale
* material-colour ``*_parts.png`` plus magenta ``*_gaps.png`` output

On top of that shared road emitter it ports the ordinary junction's own walk:
stable approach ids, angular-neighbour corner ids, per-corner fillets, asphalt
pad triangulation, sidewalk corner bands, and median noses.

    python3 tools/preview/multinode_junction_preview.py --check
    python3 tools/preview/multinode_junction_preview.py uk6x4 --out out
"""
import argparse
import math
import os
import sys

from junction_pad_preview import (
    MAX_CORNER_SPAN_RAD,
    add,
    angle_delta,
    corner_kerb,
    fill_pad,
    mag,
    mul,
    segments_cross,
    self_intersects,
    sub,
    through_kerb,
)
from preview_core import (
    ASPHALT_C,
    Cubic,
    FLAT,
    GROUND,
    LANE_M,
    MEDIAN_C,
    MEDIAN_M,
    Part,
    PolyCurve,
    SCALE,
    SIDEWALK_C,
    SW_M,
    emit_road,
    is_roadway,
    offsets_m,
    point_in,
)
from raster import Canvas


DEFAULT_RADIUS_M = 6.0
PAD_MARGIN_STUDS = 6.0
APPROACH_RUN_STUDS = 150.0
SELECTED_CORNER = "A1>A2"


def uk_two_way(lanes_each_way, median=True):
    """RoadProfile.BuiltInProfiles' UK ordering and direction signs.

    Looking along the road curve, UK forward traffic is on the left. The
    four-lane form is byte-for-data equivalent to ``builtin_four_lane``.
    ``lanes_each_way=3`` is the requested custom six-lane boulevard, built from
    the same Drive/Median/Sidewalk components rather than painted rectangles.
    """
    left = [("Drive", LANE_M, 1)] * lanes_each_way
    right = [("Drive", LANE_M, -1)] * lanes_each_way
    middle = [("Median", MEDIAN_M, 0)] if median else []
    return [("Sidewalk", SW_M, 0)] + left + middle + right + [("Sidewalk", SW_M, 0)]


def case(approaches, radii=None):
    return {"approaches": approaches, "radii": radii or {}}


SIX_LANE_BOULEVARD = uk_two_way(3)
FOUR_LANE_AVENUE = uk_two_way(2)

CASES = {
    "uk6x4": case(
        [
            ("A1", 0, SIX_LANE_BOULEVARD),
            ("A2", 90, FOUR_LANE_AVENUE),
            ("A3", 180, SIX_LANE_BOULEVARD),
            ("A4", 270, FOUR_LANE_AVENUE),
        ],
        {"A4>A1": 6.0, "A1>A2": 12.0, "A2>A3": 8.0, "A3>A4": 10.0},
    ),
    "uk4x4": case(
        [(f"A{i + 1}", angle, FOUR_LANE_AVENUE) for i, angle in enumerate((0, 90, 180, 270))]
    ),
}


def straight_curve(start, finish):
    delta = sub(finish, start)
    p1 = add(start, mul(delta, 1 / 3))
    p2 = add(start, mul(delta, 2 / 3))
    return PolyCurve([Cubic(start, p1, p2, finish)])


def component_extents(components):
    offsets = offsets_m(components)
    roadway = [index for index, component in enumerate(components) if is_roadway(component)]
    if roadway:
        kerb_left = offsets[roadway[0]][0]
        kerb_right = offsets[roadway[-1]][1]
    else:
        kerb_left, kerb_right = offsets[0][0], offsets[-1][1]
    median_indices = [i for i, component in enumerate(components) if component[0] == "Median"]
    median = None
    if median_indices:
        median = offsets[median_indices[0]][0], offsets[median_indices[-1]][1]
    return {
        "outer_left": offsets[0][0],
        "outer_right": offsets[-1][1],
        "kerb_left": kerb_left,
        "kerb_right": kerb_right,
        "median": median,
        "total_m": sum(component[1] for component in components),
    }


def offset_kerb_polyline(kerb, width_start, width_end, pin_start, pin_end):
    """Port of JunctionBuilder.offsetKerbPolyline (junction centre is 0,0)."""
    if len(kerb) < 2:
        return [pin_start, pin_end]
    outer = []
    for index, point in enumerate(kerb):
        alpha = index / (len(kerb) - 1)
        width = width_start + (width_end - width_start) * alpha
        previous = kerb[max(0, index - 1)]
        following = kerb[min(len(kerb) - 1, index + 1)]
        tangent = sub(following, previous)
        length = mag(tangent)
        if length < 1e-6 or width < 1e-4:
            outer.append(point)
            continue
        n1 = -tangent[1] / length, tangent[0] / length
        n2 = -n1[0], -n1[1]
        away = point
        normal = n1 if n1[0] * away[0] + n1[1] * away[1] >= n2[0] * away[0] + n2[1] * away[1] else n2
        outer.append(add(point, mul(normal, width)))
    outer[0], outer[-1] = pin_start, pin_end
    return outer


def centroid(poly):
    return sum(point[0] for point in poly) / len(poly), sum(point[1] for point in poly) / len(poly)


def make_part(name, poly, colour, height):
    return Part(name, list(poly), colour, centroid(poly), height)


def build_scene(tag, definition, order=None):
    specs = list(definition["approaches"])
    if order is not None:
        by_id = {spec[0]: spec for spec in specs}
        specs = [by_id[approach_id] for approach_id in order]

    widest_half = max(component_extents(components)["total_m"] * SCALE / 2 for _, _, components in specs)
    trim = widest_half + PAD_MARGIN_STUDS
    road_parts = []
    approaches = []
    mouths = []
    all_kerb_points = []

    for approach_id, bearing_deg, components in specs:
        bearing = math.radians(bearing_deg)
        outward = math.cos(bearing), math.sin(bearing)
        cut = mul(outward, trim)
        far = mul(outward, trim + APPROACH_RUN_STUDS)
        curve = straight_curve(far, cut)  # junction is at this road's END
        road_parts.extend(emit_road(curve, components))

        extents = component_extents(components)
        position, right, _forward = curve.frame(curve.length)

        def world(offset_m):
            return add(position, mul(right, offset_m * SCALE))

        left = {
            "Road": approach_id,
            "ApproachId": approach_id,
            "Kerb": world(extents["kerb_left"]),
            "Outer": world(extents["outer_left"]),
            "Out": outward,
        }
        right_point = {
            "Road": approach_id,
            "ApproachId": approach_id,
            "Kerb": world(extents["kerb_right"]),
            "Outer": world(extents["outer_right"]),
            "Out": outward,
        }
        points = [left, right_point]
        all_kerb_points.extend(point["Kerb"] for point in points)
        mid = mul(add(left["Kerb"], right_point["Kerb"]), 0.5)
        angle = math.atan2(mid[1], mid[0])
        d1 = angle_delta(math.atan2(left["Kerb"][1], left["Kerb"][0]), angle)
        d2 = angle_delta(math.atan2(right_point["Kerb"][1], right_point["Kerb"][0]), angle)
        cw, ccw = (left, right_point) if d1 <= d2 else (right_point, left)
        median = None
        if extents["median"]:
            median = world(extents["median"][0]), world(extents["median"][1])
        approach = {
            "Id": approach_id,
            "Bearing": bearing_deg,
            "Angle": angle,
            "Out": outward,
            "Mid": mid,
            "Cw": cw,
            "Ccw": ccw,
            "OuterLeft": left["Outer"],
            "OuterRight": right_point["Outer"],
            "Components": components,
            "Median": median,
        }
        approaches.append(approach)
        mouths.append({"Road": approach_id, "L": left["Kerb"], "R": right_point["Kerb"]})

    approaches.sort(key=lambda approach: approach["Angle"])
    pad = []
    corners = []

    def append_unique(point):
        if not pad or mag(sub(pad[-1], point)) >= 0.05:
            pad.append(point)

    for index, approach in enumerate(approaches):
        following = approaches[(index + 1) % len(approaches)]
        span = (following["Angle"] - approach["Angle"]) % (2 * math.pi)
        turn = min(span, 2 * math.pi - span)
        a, b = approach["Ccw"], following["Cw"]
        real_corner = math.radians(20) <= turn <= MAX_CORNER_SPAN_RAD
        crosses_mouth = False
        if real_corner:
            for mouth in mouths:
                if mouth["Road"] not in (a["Road"], b["Road"]) and segments_cross(
                    a["Kerb"], b["Kerb"], mouth["L"], mouth["R"]
                ):
                    crosses_mouth = True
                    break
        corner_id = f'{approach["Id"]}>{following["Id"]}'
        radius_m = definition["radii"].get(corner_id, DEFAULT_RADIUS_M)
        if real_corner and not crosses_mouth:
            kerb, kind = corner_kerb(a, b, radius_m * SCALE, span > math.pi, "shipped")
        else:
            kerb, kind = through_kerb(a, b, "shipped")
        outer = offset_kerb_polyline(
            kerb,
            mag(sub(a["Outer"], a["Kerb"])),
            mag(sub(b["Outer"], b["Kerb"])),
            a["Outer"],
            b["Outer"],
        )
        for point in kerb:
            append_unique(point)
        corners.append({
            "Id": corner_id,
            "From": approach["Id"],
            "To": following["Id"],
            "RadiusM": radius_m,
            "Kerb": kerb,
            "Outer": outer,
            "Kind": kind,
        })

    triangles, outline, fill_path = fill_pad(pad, all_kerb_points)
    if triangles is None:
        triangles = []

    junction_parts = [make_part("JunctionSurface", triangle, ASPHALT_C, 0.0) for triangle in triangles]
    for corner in corners:
        kerb, outer = corner["Kerb"], corner["Outer"]
        for index in range(len(kerb) - 1):
            tri_a = (outer[index], kerb[index], kerb[index + 1])
            tri_b = (outer[index], kerb[index + 1], outer[index + 1])
            junction_parts.append(make_part("SidewalkCorner", tri_a, SIDEWALK_C, 0.125 * SCALE))
            junction_parts.append(make_part("SidewalkCorner", tri_b, SIDEWALK_C, 0.125 * SCALE))

    for approach in approaches:
        if not approach["Median"]:
            continue
        left, right_point = approach["Median"]
        middle = mul(add(left, right_point), 0.5)
        inward = mul(middle, -1)
        inward_length = mag(inward)
        if inward_length < 1e-6:
            continue
        nose_length = max(1.5, min(6.0, mag(sub(left, right_point)) * 0.6))
        tip = add(middle, mul(inward, nose_length / inward_length))
        junction_parts.append(make_part("MedianNose", (left, right_point, tip), MEDIAN_C, 0.125 * SCALE))

    return {
        "tag": tag,
        "parts": road_parts + junction_parts,
        "road_parts": road_parts,
        "junction_parts": junction_parts,
        "approaches": approaches,
        "corners": corners,
        "pad": pad,
        "outline": outline,
        "triangles": triangles,
        "fill_path": fill_path,
        "trim": trim,
        "drive_on_left": True,
    }


def scan_mouth_seams(scene):
    """Probe every full component-width mouth just inside/outside its cut."""
    material = [part for part in scene["parts"] if part.name != "Marking"]
    holes = []
    for approach in scene["approaches"]:
        outer_a, outer_b = approach["OuterLeft"], approach["OuterRight"]
        for along in (-0.35, 0.0, 0.35):
            shift = mul(approach["Out"], along)
            for sample in range(1, 100):
                alpha = sample / 100
                point = add(add(outer_a, mul(sub(outer_b, outer_a), alpha)), shift)
                if not any(point_in(part.poly, point) for part in material):
                    holes.append((approach["Id"], along, alpha))
    return holes


def scan_pad_fill(scene):
    holes = []
    surfaces = [part for part in scene["junction_parts"] if part.name == "JunctionSurface"]
    outline = scene["outline"]
    if not outline:
        return [(0.0, 0.0)]
    xs, ys = [point[0] for point in outline], [point[1] for point in outline]
    for xi in range(41):
        for yi in range(41):
            point = (min(xs) + (max(xs) - min(xs)) * xi / 40,
                     min(ys) + (max(ys) - min(ys)) * yi / 40)
            if point_in(outline, point) and not any(point_in(part.poly, point) for part in surfaces):
                holes.append(point)
    return holes


def scene_problems(scene, definition):
    problems = []
    if scene["fill_path"] != "corner walk":
        problems.append(f'{scene["tag"]}: pad required {scene["fill_path"]} fallback')
    if not scene["triangles"] or self_intersects(scene["outline"]):
        problems.append(f'{scene["tag"]}: pad is missing or self-intersecting')
    if len(scene["approaches"]) != len(definition["approaches"]):
        problems.append(f'{scene["tag"]}: approach count changed')
    if len(scene["corners"]) != len(definition["approaches"]):
        problems.append(f'{scene["tag"]}: angular neighbours did not yield one corner each')
    expected_radii = {
        corner["Id"]: definition["radii"].get(corner["Id"], DEFAULT_RADIUS_M)
        for corner in scene["corners"]
    }
    actual_radii = {corner["Id"]: corner["RadiusM"] for corner in scene["corners"]}
    if actual_radii != expected_radii:
        problems.append(f'{scene["tag"]}: corner radii did not resolve by stable id')
    if scan_mouth_seams(scene):
        problems.append(f'{scene["tag"]}: component-width mouth seam has uncovered samples')
    if scan_pad_fill(scene):
        problems.append(f'{scene["tag"]}: triangulated pad has uncovered samples')
    required_parts = {"Drive", "Sidewalk", "Median", "Marking", "JunctionSurface", "SidewalkCorner", "MedianNose"}
    present = {part.name for part in scene["parts"]}
    missing = required_parts - present
    if missing:
        problems.append(f'{scene["tag"]}: component renderer omitted {sorted(missing)}')
    return problems


def checks():
    problems = []
    for name, definition in CASES.items():
        scene = build_scene(name, definition)
        problems.extend(scene_problems(scene, definition))
        reversed_order = [spec[0] for spec in reversed(definition["approaches"])]
        shuffled = build_scene(name + "_shuffled", definition, reversed_order)
        if [corner["Id"] for corner in scene["corners"]] != [corner["Id"] for corner in shuffled["corners"]]:
            problems.append(f"{name}: connected-road enumeration changed stable corner ids")

    six = CASES["uk6x4"]["approaches"]
    boulevard = next(components for approach_id, _, components in six if approach_id == "A1")
    avenue = next(components for approach_id, _, components in six if approach_id == "A2")
    if sum(component[0] == "Drive" for component in boulevard) != 6:
        problems.append("uk6x4: boulevard is not six real Drive components")
    if sum(component[0] == "Drive" for component in avenue) != 4:
        problems.append("uk6x4: avenue is not four real Drive components")
    if [component[2] for component in boulevard if component[0] == "Drive"] != [1, 1, 1, -1, -1, -1]:
        problems.append("uk6x4: boulevard does not use UK left-hand direction ordering")
    if boulevard[0][:2] != ("Sidewalk", SW_M) or any(
        component[:2] == ("Median", MEDIAN_M) for component in boulevard
    ) is False:
        problems.append("uk6x4: boulevard is not built from current UK sidewalk/median dimensions")
    return problems


def render(scene, outdir):
    """Same two outputs as roundabout_preview: material parts and gap map."""
    points = [vertex for part in scene["parts"] for vertex in part.poly]
    margin = 12.0
    low = min(point[0] for point in points) - margin, min(point[1] for point in points) - margin
    high = max(point[0] for point in points) + margin, max(point[1] for point in points) + margin
    image_scale = min(3.0, 1500 / max(high[0] - low[0], high[1] - low[1]))
    width = max(1, int((high[0] - low[0]) * image_scale))
    height = max(1, int((high[1] - low[1]) * image_scale))
    transform = lambda point: ((point[0] - low[0]) * image_scale, (point[1] - low[1]) * image_scale)
    written = []
    for flat in (False, True):
        canvas = Canvas(width, height, GROUND if flat else (250, 250, 250))
        for part in sorted(scene["parts"], key=lambda item: item.y):
            canvas.fill_poly([transform(vertex) for vertex in part.poly], FLAT if flat else part.color)
        suffix = "gaps" if flat else "parts"
        name = f'junction_{scene["tag"]}_{suffix}.png'
        canvas.save(os.path.join(outdir, name))
        written.append(name)
    return written


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("cases", nargs="*", help=f'known: {" ".join(CASES)}')
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    parser.add_argument("--check", action="store_true", help="run every case without rendering")
    args = parser.parse_args()
    names = list(CASES) if args.check or not args.cases else args.cases
    problems = checks() if args.check else []
    if not args.check:
        os.makedirs(args.out, exist_ok=True)
        for name in names:
            if name not in CASES:
                raise SystemExit(f'unknown case {name!r}; known: {" ".join(CASES)}')
            scene = build_scene(name, CASES[name])
            problems.extend(scene_problems(scene, CASES[name]))
            for output in render(scene, args.out):
                print(f"wrote {os.path.join(args.out, output)}")
    if problems:
        for problem in problems:
            print("FAILED:", problem)
        return 1
    print("multinode component preview passed: UK profiles, stable corners, pad fill, and mouth seams")
    return 0


if __name__ == "__main__":
    sys.exit(main())
