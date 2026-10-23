#!/usr/bin/env python3
"""Render the README gallery from the existing Python geometry models.

Run from the repository root:
    python3 tools/preview/readme_gallery.py

These are headless Python previews, not Roblox Studio screenshots. The
geometry models and their limits are documented in tools/preview/README.md.
"""

from pathlib import Path

import parallel_preview as parallel
import preview_core as core
import road_preview as road
import roundabout_preview as roundabout
from raster import Canvas

OUTPUT = Path(__file__).resolve().parents[2] / "images"
WIDTH, HEIGHT, MARGIN = 1200, 760, 48


def parallel_scene():
    profile = roundabout.one_way_highway(2, True, True)
    offset = (sum(component[1] for component in profile) * core.SCALE + 16.0) / 2
    parts = []
    for sign, reverse in ((-1, True), (1, False)):
        fitted = parallel.offset_curve(parallel.demo_curve(), sign * offset)
        controls = [chunk.p for chunk in fitted.chunks]
        if reverse:
            controls = [tuple(reversed(points)) for points in reversed(controls)]
        curve = core.PolyCurve([
            core.Cubic(*[(point[0], point[2]) for point in points])
            for points in controls
        ])
        parts.extend(core.emit_road(curve, profile))
    return {"parts": parts}


def render(scene, output, coverage=False):
    # Preserve the canonical renderer's layer order and roundabout overlays.
    layers = [(part.poly, part.color) for part in sorted(scene["parts"], key=lambda part: part.y)]
    layers.extend((polygon, roundabout.ASPHALT_C) for polygon in scene.get("apron", []))
    layers.extend((polygon, roundabout.ISLAND_C) for polygon in scene.get("gore", []))
    points = [point for polygon, _color in layers for point in polygon]
    if not points:
        raise ValueError("The preview scene contains no geometry")

    island_radius = scene.get("island_r", 0) if scene.get("island", True) else 0
    if island_radius > 1:
        center = scene["center"]
        points.extend((center[0] + dx * island_radius, center[1] + dy * island_radius)
                      for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)))

    span_x = max(point[0] for point in points) - min(point[0] for point in points)
    span_y = max(point[1] for point in points) - min(point[1] for point in points)
    rotate = span_y > span_x

    def project(point):
        return (point[1], -point[0]) if rotate else point

    projected = [project(point) for point in points]
    low_x = min(point[0] for point in projected)
    high_x = max(point[0] for point in projected)
    low_y = min(point[1] for point in projected)
    high_y = max(point[1] for point in projected)
    scale = min((WIDTH - 2 * MARGIN) / max(high_x - low_x, 1),
                (HEIGHT - 2 * MARGIN) / max(high_y - low_y, 1))
    center_x, center_y = (low_x + high_x) / 2, (low_y + high_y) / 2

    def screen(point):
        x, y = project(point)
        return WIDTH / 2 + (x - center_x) * scale, HEIGHT / 2 + (y - center_y) * scale

    canvas = Canvas(WIDTH, HEIGHT, roundabout.GROUND if coverage else (250, 250, 250))
    for polygon, color in layers:
        canvas.fill_poly([screen(point) for point in polygon], roundabout.FLAT if coverage else color)
    if island_radius > 1:
        x, y = screen(scene["center"])
        canvas.disc(x, y, island_radius * scale, roundabout.FLAT if coverage else roundabout.ISLAND_C)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(str(output))
    print(f"Wrote {output.relative_to(OUTPUT.parent)} ({WIDTH} x {HEIGHT})")


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    scenes = [
        ("screenshot.png", road.build("gallery_avenue", *road.CASES["scurve_r80"])),
        ("highway.png", road.build("gallery_highway", *road.CASES["motorway_tight"])),
        ("parallel-roadways.png", parallel_scene()),
        ("roundabout.png", roundabout.build(tag="gallery_roundabout", **roundabout.CASES["turbo4"])),
    ]
    for filename, scene in scenes:
        render(scene, OUTPUT / filename)
    render(scenes[-1][1], OUTPUT / "preview/roundabout-coverage.png", coverage=True)


if __name__ == "__main__":
    main()
