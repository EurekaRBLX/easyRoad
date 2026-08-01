#!/usr/bin/env python3
"""Check and render the v2 multinode intersection controller from above.

The geometry is the same angular-neighbour walk as JunctionBuilder: roads own
stable approach ids, each adjacent approach pair owns a stable corner id, and
the corner chooses either the linked default radius or its own override.

    python3 tools/preview/multinode_junction_preview.py --check
    python3 tools/preview/multinode_junction_preview.py --out multinode.png
"""
import argparse
import math
import os
import sys

from junction_pad_preview import (MAX_CORNER_SPAN_RAD, add, angle_delta,
                                  corner_kerb, mag, mul, self_intersects, sub)
from raster import Canvas


DEFAULT_RADIUS = 14.0
BEARINGS = {"A1": 0.0, "A2": 90.0, "A3": 180.0, "A4": 270.0}
OVERRIDES = {"A1>A2": 8.0, "A2>A3": 20.0, "A3>A4": 30.0, "A4>A1": 12.0}


def build_multinode(order, linked, overrides=None, trim=72.0, kerb_half=17.0):
    """Return approach ports, corner nodes/boundaries, and the pad outline."""
    overrides = overrides or {}
    approaches = []
    for approach_id in order:
        bearing = math.radians(BEARINGS[approach_id])
        out = math.cos(bearing), math.sin(bearing)
        mid = mul(out, trim)
        normal = -out[1], out[0]
        points = [
            {"Road": approach_id, "Kerb": add(mid, mul(normal, kerb_half)), "Out": out},
            {"Road": approach_id, "Kerb": sub(mid, mul(normal, kerb_half)), "Out": out},
        ]
        angle = math.atan2(mid[1], mid[0])
        d1 = angle_delta(math.atan2(points[0]["Kerb"][1], points[0]["Kerb"][0]), angle)
        d2 = angle_delta(math.atan2(points[1]["Kerb"][1], points[1]["Kerb"][0]), angle)
        cw, ccw = (points[0], points[1]) if d1 <= d2 else (points[1], points[0])
        approaches.append({"Id": approach_id, "Angle": angle, "Mid": mid,
                           "Left": points[0]["Kerb"], "Right": points[1]["Kerb"],
                           "Cw": cw, "Ccw": ccw, "Out": out})
    approaches.sort(key=lambda approach: approach["Angle"])

    corners, pad = [], []
    for index, approach in enumerate(approaches):
        following = approaches[(index + 1) % len(approaches)]
        span = (following["Angle"] - approach["Angle"]) % (2 * math.pi)
        turn = min(span, 2 * math.pi - span)
        if not math.radians(20) <= turn <= MAX_CORNER_SPAN_RAD:
            continue
        corner_id = f'{approach["Id"]}>{following["Id"]}'
        radius = DEFAULT_RADIUS if linked else overrides.get(corner_id, DEFAULT_RADIUS)
        boundary, kind = corner_kerb(approach["Ccw"], following["Cw"], radius,
                                     span > math.pi, "shipped")
        for point in boundary:
            if not pad or mag(sub(point, pad[-1])) >= 0.05:
                pad.append(point)
        corners.append({"Id": corner_id, "Index": index + 1, "Radius": radius,
                        "Mid": boundary[len(boundary) // 2], "Boundary": boundary,
                        "Kind": kind})
    return approaches, corners, pad


def polygon_area(poly):
    return abs(sum(poly[i][0] * poly[(i + 1) % len(poly)][1]
                   - poly[(i + 1) % len(poly)][0] * poly[i][1]
                   for i in range(len(poly)))) * 0.5


def checks():
    problems = []
    approaches, corners, pad = build_multinode(list(BEARINGS), False, OVERRIDES)
    shuffled = build_multinode(["A3", "A1", "A4", "A2"], False, OVERRIDES)
    if [corner["Id"] for corner in corners] != [corner["Id"] for corner in shuffled[1]]:
        problems.append("corner ids changed when connected-road enumeration changed")
    if {corner["Id"]: corner["Radius"] for corner in corners} != OVERRIDES:
        problems.append("per-corner overrides did not resolve by stable corner id")
    linked = build_multinode(list(BEARINGS), True, OVERRIDES)[1]
    if any(corner["Radius"] != DEFAULT_RADIUS for corner in linked):
        problems.append("linked mode did not force the shared default radius")
    if len(approaches) != 4 or len(corners) != 4:
        problems.append("four approaches did not yield four corner nodes")
    if len(pad) < 16 or polygon_area(pad) <= 1 or self_intersects(pad):
        problems.append("multinode pad is degenerate or self-intersecting")
    return problems


FONT = {
    "0":("111","101","101","101","111"), "1":("010","110","010","010","111"),
    "2":("111","001","111","100","111"), "3":("111","001","111","001","111"),
    "4":("101","101","111","001","001"), "5":("111","100","111","001","111"),
    "6":("111","100","111","101","111"), "7":("111","001","010","010","010"),
    "8":("111","101","111","101","111"), "9":("111","101","111","001","111"),
    "A":("010","101","111","101","101"), "C":("111","100","100","100","111"),
    "D":("110","101","101","101","110"), "E":("111","100","110","100","111"),
    "I":("111","010","010","010","111"), "J":("001","001","001","101","111"),
    "K":("101","101","110","101","101"), "L":("100","100","100","100","111"),
    "M":("10001","11011","10101","10101","10101"), "N":("1001","1101","1011","1001","1001"),
    "O":("111","101","101","101","111"), "P":("110","101","110","100","100"),
    "R":("110","101","110","101","101"), "S":("111","100","111","001","111"),
    "T":("111","010","010","010","010"), "U":("101","101","101","101","111"),
    "V":("101","101","101","101","010"), "W":("10101","10101","10101","11011","10001"),
    "Y":("101","101","010","010","010"), "-":("000","000","111","000","000"),
    ">":("100","010","001","010","100"), ":":("0","1","0","1","0"),
    ".":("0","0","0","0","1"), " ":("0","0","0","0","0"),
}


def text_draw(canvas, xy, value, color, scale=3):
    x, y = xy
    cursor = x
    for char in value.upper():
        glyph = FONT.get(char, FONT[" "])
        width = max(len(row) for row in glyph)
        for row_index, row in enumerate(glyph):
            for column, on in enumerate(row):
                if on == "1":
                    canvas.fill_poly([(cursor + column*scale, y + row_index*scale),
                                      (cursor + (column+1)*scale-1, y + row_index*scale),
                                      (cursor + (column+1)*scale-1, y + (row_index+1)*scale-1),
                                      (cursor + column*scale, y + (row_index+1)*scale-1)], color)
        cursor += (width + 1) * scale


def world(point):
    return 600 + point[0] * 3.0, 400 - point[1] * 3.0


def dashed(canvas, a, b, color, width=2, pieces=16):
    for index in range(0, pieces, 2):
        t0, t1 = index / pieces, (index + 1) / pieces
        canvas.line((a[0] + (b[0]-a[0])*t0, a[1] + (b[1]-a[1])*t0),
                    (a[0] + (b[0]-a[0])*t1, a[1] + (b[1]-a[1])*t1), color, width)


def render(path):
    problems = checks()
    if problems:
        raise AssertionError("; ".join(problems))
    approaches, corners, pad = build_multinode(list(BEARINGS), False, OVERRIDES)
    canvas = Canvas(1200, 800, (38, 65, 50))
    for x in range(0, 1200, 40):
        canvas.line((x, 0), (x, 800), (44, 73, 57), 1)
    for y in range(0, 800, 40):
        canvas.line((0, y), (1200, y), (44, 73, 57), 1)

    # Carriageways behind the junction pad.
    for approach in approaches:
        out = approach["Out"]
        normal = -out[1], out[0]
        near, far = mul(out, 35), mul(out, 145)
        road = [add(near, mul(normal, 17)), add(far, mul(normal, 17)),
                sub(far, mul(normal, 17)), sub(near, mul(normal, 17))]
        canvas.fill_poly([world(point) for point in road], (55, 59, 64))
        for dash in range(45, 145, 24):
            p0, p1 = world(mul(out, dash)), world(mul(out, dash + 12))
            canvas.line(p0, p1, (220, 220, 210), 3)

    canvas.fill_poly([world(point) for point in pad], (55, 59, 64))
    canvas.polyline([world(point) for point in pad + [pad[0]]], (224, 224, 215), 3)

    centre_px = world((0, 0))
    for approach in approaches:
        left, right, mid = world(approach["Left"]), world(approach["Right"]), world(approach["Mid"])
        canvas.line(left, right, (239, 83, 80), 5)
        canvas.disc(mid[0], mid[1], 7, (239, 83, 80))
        dashed(canvas, centre_px, mid, (142, 151, 162), 2)
        label = approach["Id"]
        text_draw(canvas, (mid[0] + 10, mid[1] - 20), label, (245, 245, 238), 3)

    selected = "A2>A3"
    for corner in corners:
        mid = world(corner["Mid"])
        color = (255, 166, 64) if corner["Id"] == selected else (71, 199, 226)
        canvas.polyline([world(point) for point in corner["Boundary"]], color, 5 if corner["Id"] == selected else 3)
        dashed(canvas, centre_px, mid, (142, 151, 162), 2)
        canvas.disc(mid[0], mid[1], 9 if corner["Id"] == selected else 7, color)
        text_draw(canvas, (mid[0] + 12, mid[1] - 8), f'{corner["Index"]}:{corner["Radius"]:.0f}M',
                  (245, 245, 238), 3)

    canvas.disc(centre_px[0], centre_px[1], 11, (247, 198, 45))
    text_draw(canvas, (centre_px[0] + 16, centre_px[1] - 8), "OWNER", (245, 245, 238), 3)
    text_draw(canvas, (40, 36), "MULTINODE JUNCTION - BIRD EYE", (245, 245, 238), 4)
    text_draw(canvas, (40, 710), "RED PORT   CYAN CORNER   ORANGE SELECTED   YELLOW OWNER", (245, 245, 238), 3)
    text_draw(canvas, (40, 744), "PER CORNER RADII: 8M  20M  30M  12M", (245, 245, 238), 3)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    canvas.save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--out")
    args = parser.parse_args()
    problems = checks()
    if problems:
        for problem in problems:
            print("FAILED:", problem)
        return 1
    if args.out:
        render(args.out)
        print(f"wrote {args.out}: four stable approach ports and four independently radiused corner nodes")
    else:
        print("multinode junction checks passed: stable ids, linked radii, overrides, and simple pad")
    return 0


if __name__ == "__main__":
    sys.exit(main())
