#!/usr/bin/env python3
"""Visual and semantic check for editable lane/centre marking boundaries.

The scene is a UK-style 3+3 bidirectional road using preview_core's ordinary
EasyRoad component emitter. The amber overlay is the marking-stretch selection
ghost: it must sit on the one boundary where Drive direction changes.

    python marking_boundary_preview.py --out out
    python marking_boundary_preview.py --check

This does not execute Luau. integration_contracts.py separately guards that
RoadEditSession and Markings.Compute call the shared editable-boundary API.
"""
import argparse
import os

from preview_core import SCALE
from raster import Canvas
from road_preview import build, straight, street


AMBER = (255, 176, 64)


def editable_boundaries(components):
    """Zero-based equivalent of Markings.IsEditableLaneBoundary."""
    return [i for i, (a, b) in enumerate(zip(components, components[1:]))
            if a[0] == "Drive" and b[0] == "Drive"]


def same_direction_boundary(components, index):
    a, b = components[index], components[index + 1]
    return (a[0] == "Drive" and b[0] == "Drive"
            and not (a[2] and b[2] and a[2] != b[2]))


def sibling_boundaries(components, index):
    """Port of the All-mode grouping rule, including a centre singleton."""
    editable = editable_boundaries(components)
    if index not in editable:
        return []
    if not same_direction_boundary(components, index):
        return [index]
    lo = hi = index
    while lo - 1 >= 0 and same_direction_boundary(components, lo - 1):
        lo -= 1
    while hi + 1 < len(components) - 1 and same_direction_boundary(components, hi + 1):
        hi += 1
    return list(range(lo, hi + 1))


def selected_centre_boundary(components):
    opposing = [i for i in editable_boundaries(components)
                if components[i][2] != components[i + 1][2]]
    if len(opposing) != 1:
        raise AssertionError(f"expected one opposing centre boundary, got {opposing}")
    return opposing[0]


def boundary_offset_m(components, index):
    total = sum(component[1] for component in components)
    return -total / 2 + sum(component[1] for component in components[:index + 1])


def check():
    components = street(3)
    editable = editable_boundaries(components)
    centre = selected_centre_boundary(components)
    assert editable == [1, 2, 3, 4, 5], editable
    assert sibling_boundaries(components, 1) == [1, 2]
    assert sibling_boundaries(components, centre) == [centre]
    assert sibling_boundaries(components, 5) == [4, 5]
    assert abs(boundary_offset_m(components, centre)) < 1e-9
    return components, centre


def render(outdir):
    components, centre = check()
    scene = build("marking_boundary_3x3", straight(360), components)
    curve = scene["curve"]
    half_width = sum(component[1] for component in components) / 2 * SCALE + 10
    lo = (-10.0, -half_width)
    hi = (curve.length + 10.0, half_width)
    scale = min(4.0, 1400 / (hi[0] - lo[0]))
    width = int((hi[0] - lo[0]) * scale)
    height = int((hi[1] - lo[1]) * scale)
    transform = lambda point: ((point[0] - lo[0]) * scale, (point[1] - lo[1]) * scale)

    canvas = Canvas(width, height, (232, 238, 244))
    for part in sorted(scene["parts"], key=lambda item: item.y):
        canvas.fill_poly([transform(vertex) for vertex in part.poly], part.color)

    offset = boundary_offset_m(components, centre) * SCALE
    start, finish = curve.length * 0.25, curve.length * 0.75
    p0, right0, _ = curve.frame(start)
    p1, right1, _ = curve.frame(finish)
    a = transform((p0[0] + right0[0] * offset, p0[1] + right0[1] * offset))
    b = transform((p1[0] + right1[0] * offset, p1[1] + right1[1] * offset))
    canvas.line(a, b, AMBER, width=5)
    canvas.disc(a[0], a[1], 7, AMBER)
    canvas.disc(b[0], b[1], 7, AMBER)

    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, "marking_boundary_3x3_selected.png")
    canvas.save(path)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="semantic checks only; do not render")
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    args = parser.parse_args()
    components, centre = check()
    print(f"marking boundaries passed: editable={editable_boundaries(components)}, centre={centre}, All={sibling_boundaries(components, centre)}")
    if not args.check:
        print(f"wrote {render(args.out)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
