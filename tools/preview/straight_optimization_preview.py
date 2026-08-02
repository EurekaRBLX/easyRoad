#!/usr/bin/env python3
"""Semantic and visual QA for RoadBuilder's exact-straight fast path.

This is a headless port, not a Luau runtime. It checks the 2048-stud split
rule, explicit stretch boundaries, conservative Drive-only lateral merging,
and the source-metadata/static wiring that keeps editing independent of the
generated Part count.

    python straight_optimization_preview.py --check
    python straight_optimization_preview.py --out out/straight_optimization.png
"""
import argparse
import math
import os
from pathlib import Path

from raster import Canvas


ROOT = Path(__file__).resolve().parents[2]
MAX_PART_AXIS_STUDS = 2048.0
LEGACY_MAX_SEGMENT_STUDS = 8.0


def straight_stations(length, forced_breaks=()):
    """Port of RoadBuilder.straightStations."""
    boundaries = sorted([0.0, float(length), *(
        max(0.0, min(float(length), float(value))) for value in forced_breaks
    )])
    stations = [0.0]
    for boundary in boundaries:
        last = stations[-1]
        if boundary <= last + 1e-4:
            continue
        while boundary - last > MAX_PART_AXIS_STUDS:
            last += MAX_PART_AXIS_STUDS
            stations.append(last)
        if boundary - stations[-1] > 1e-4:
            stations.append(boundary)
    return stations


def surface_bands(components):
    """Merge only adjacent Drive bands with an identical surface signature."""
    bands = []
    index = 0
    while index < len(components):
        component = components[index]
        end = index
        if component[0] == "Drive":
            signature = component[2:5]
            while (end + 1 < len(components)
                   and components[end + 1][0] == "Drive"
                   and components[end + 1][2:5] == signature):
                end += 1
        bands.append({
            "start": index,
            "end": end,
            "kind": component[0],
            "width": sum(item[1] for item in components[index:end + 1]),
        })
        index = end + 1
    return bands


def road_builder_contracts():
    source = (ROOT / "src" / "Mesh" / "RoadBuilder.lua").read_text(encoding="utf-8")
    required = {
        "2048-stud axis guard": "local MAX_PART_AXIS_STUDS = 2048",
        "control-point straight proof": "local function isExactStraightCurve",
        "longitudinal planner": "local function straightStations",
        "transition fallback": "local optimizedStraight = not isTransition",
        "component range start": 'part:SetAttribute("RW_ComponentStartIndex", c)',
        "component range end": 'part:SetAttribute("RW_ComponentEndIndex", componentEnd)',
        "station range start": 'part:SetAttribute("RW_StationStartStuds", s0)',
        "station range end": 'part:SetAttribute("RW_StationEndStuds", s1)',
        "raw road metadata": "RoadInstance.StampModel(model, curve, options.ProfileStart, options.ProfileEnd)",
        "markings use raw components": "Markings.Compute(componentsStart, componentsEnd, style",
    }
    missing = [label for label, needle in required.items() if needle not in source]
    if missing:
        raise AssertionError("RoadBuilder contracts missing: " + ", ".join(missing))


def check():
    cases = {
        "below": (2047.999, 1),
        "at": (2048.0, 1),
        "above": (2048.001, 2),
        "two_limits": (4096.0, 2),
        "above_two_limits": (4096.001, 3),
        "long": (5000.0, 3),
    }
    for name, (length, expected_parts) in cases.items():
        stations = straight_stations(length)
        spans = [finish - start for start, finish in zip(stations, stations[1:])]
        assert len(spans) == expected_parts, (name, stations)
        assert max(spans) <= MAX_PART_AXIS_STUDS + 1e-9, (name, spans)
        assert abs(sum(spans) - length) <= 1e-9, (name, spans)

    split = straight_stations(5000, (1000, 3000, 3000))
    assert split == [0.0, 1000.0, 3000.0, 5000.0], split

    asphalt = ("Asphalt", "#3C3C3C", 0.0)
    concrete = ("Concrete", "#A8A8A8", 0.35)
    grass = ("Grass", "#788270", 0.35)
    profile = [
        ("Sidewalk", 2.0, *concrete),
        ("Drive", 3.65, *asphalt),
        ("Drive", 3.65, *asphalt),
        ("Drive", 3.65, *asphalt),
        ("Median", 2.7, *grass),
        ("Drive", 3.65, *asphalt),
        ("Drive", 3.65, *asphalt),
        ("Drive", 3.65, *asphalt),
        ("Sidewalk", 2.0, *concrete),
    ]
    bands = surface_bands(profile)
    assert [(b["start"], b["end"]) for b in bands] == [
        (0, 0), (1, 3), (4, 4), (5, 7), (8, 8)
    ], bands

    different_colour = list(profile)
    different_colour[2] = ("Drive", 3.65, "Asphalt", "#454545", 0.0)
    assert [(b["start"], b["end"]) for b in surface_bands(different_colour)][1:4] == [
        (1, 1), (2, 2), (3, 3)
    ]
    different_material = list(profile)
    different_material[2] = ("Drive", 3.65, "Concrete", "#3C3C3C", 0.0)
    assert [(b["start"], b["end"]) for b in surface_bands(different_material)][1:4] == [
        (1, 1), (2, 2), (3, 3)
    ]
    road_builder_contracts()

    old_surface_parts = math.ceil(5000 / LEGACY_MAX_SEGMENT_STUDS) * len(profile)
    new_surface_parts = (len(straight_stations(5000)) - 1) * len(bands)
    return old_surface_parts, new_surface_parts, profile, bands


def _rect(canvas, x0, y0, x1, y1, colour):
    canvas.fill_poly([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], colour)


def render(path):
    old_count, new_count, profile, bands = check()
    canvas = Canvas(1400, 520, (232, 238, 244))
    left, right = 50, 1350
    road_top, road_height = 45, 170
    colours = {
        "Drive": (60, 60, 60),
        "Sidewalk": (168, 168, 168),
        "Median": (120, 130, 112),
    }
    total_width = sum(component[1] for component in profile)

    def draw_profile(y, optimized):
        items = bands if optimized else [
            {"start": i, "end": i, "kind": item[0], "width": item[1]}
            for i, item in enumerate(profile)
        ]
        cursor = y
        lane_boundaries = []
        for band in items:
            height = road_height * band["width"] / total_width
            _rect(canvas, left, cursor, right, cursor + height, colours[band["kind"]])
            cursor += height
        raw_cursor = y
        for index, component in enumerate(profile[:-1]):
            raw_cursor += road_height * component[1] / total_width
            if component[0] == "Drive" and profile[index + 1][0] == "Drive":
                lane_boundaries.append(raw_cursor)
        for boundary in lane_boundaries:
            for x in range(left + 12, right - 12, 34):
                canvas.line((x, boundary), (min(x + 17, right - 12), boundary), (245, 245, 245), 2)

    # Legacy: the dense station grid is visible as hundreds of seams.
    draw_profile(road_top, False)
    legacy_intervals = math.ceil(5000 / LEGACY_MAX_SEGMENT_STUDS)
    for interval in range(1, legacy_intervals):
        x = left + (right - left) * interval / legacy_intervals
        canvas.line((x, road_top), (x, road_top + road_height), (92, 92, 92), 1)

    optimized_top = 300
    draw_profile(optimized_top, True)
    for station in straight_stations(5000)[1:-1]:
        x = left + (right - left) * station / 5000
        canvas.line((x, optimized_top), (x, optimized_top + road_height), (255, 176, 64), 3)

    # Count bars: red is legacy surface Parts, green is optimized surface Parts.
    legacy_fraction = 1.0
    optimized_fraction = max(new_count / old_count, 0.006)
    _rect(canvas, left, 236, left + (right - left) * legacy_fraction, 254, (203, 76, 76))
    _rect(canvas, left, 480, left + (right - left) * optimized_fraction, 498, (63, 161, 92))

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    canvas.save(path)
    return old_count, new_count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="semantic/static checks only")
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out", "straight_optimization.png"))
    args = parser.parse_args()
    old_count, new_count, _profile, _bands = check()
    reduction = (1 - new_count / old_count) * 100
    print(f"straight optimization passed: 5000-stud 3+3 surface {old_count} -> {new_count} Parts ({reduction:.2f}% fewer)")
    if not args.check:
        render(args.out)
        print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
