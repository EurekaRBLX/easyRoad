#!/usr/bin/env python3
"""Validate the local rbxmx structure references used for procedural proportions.

This does not import the assets into Roblox. It proves the checked-in references
still contain the construction cues that StructureBuilder mirrors: wide deck
slabs and parapets for viaducts; a base, tall walls, and a segmented high crown
for tunnels.
"""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
HARDWARE = ROOT / "hardware"
EXPECTED = {
    "1L_EXPRESSWAY_VIADUCT.rbxmx",
    "RDL_30S_3LANE_EXPRESSWAY_TUNNEL.rbxmx",
    "RDL_30S_3LANE_EXPRESSWAY_VIADUCT.rbxmx",
    "RDR_30S_3LANE_EXPRESSWAY_TUNNEL.rbxmx",
    "RDR_30S_3LANE_EXPRESSWAY_VIADUCT.rbxmx",
}


def vector(properties, tag, name):
    node = properties.find(f"{tag}[@name='{name}']")
    if node is None:
        return None
    try:
        return tuple(float(node.findtext(axis)) for axis in ("X", "Y", "Z"))
    except (TypeError, ValueError):
        return None


def parts(path):
    root = ET.parse(path).getroot()
    result = []
    for item in root.findall(".//Item[@class='Part']"):
        properties = item.find("Properties")
        if properties is None:
            continue
        size = vector(properties, "Vector3", "size") or vector(properties, "Vector3", "Size")
        position = vector(properties, "CoordinateFrame", "CFrame")
        if size and position:
            result.append((size, position))
    return result


def main():
    problems = []
    present = {path.name for path in HARDWARE.glob("*.rbxmx")} if HARDWARE.exists() else set()
    missing = EXPECTED-present
    if missing:
        problems.append("missing references: " + ", ".join(sorted(missing)))

    summaries = []
    for name in sorted(EXPECTED & present):
        geometry = parts(HARDWARE / name)
        if not geometry:
            problems.append(f"{name}: no Part geometry parsed")
            continue
        sizes = [size for size, _position in geometry]
        positions = [position for _size, position in geometry]
        max_height = max(size[1] for size in sizes)
        vertical_extent = max(position[1] for position in positions)-min(position[1] for position in positions)
        wide_thin_slabs = [size for size in sizes
                           if size[1] <= 2.1 and max(size[0], size[2]) >= 35
                           and min(size[0], size[2]) >= 20]
        if not wide_thin_slabs:
            problems.append(f"{name}: missing wide structural slab/base")

        if "TUNNEL" in name:
            high_thin_parts = [(size, position) for size, position in geometry
                               if size[1] <= 2.1
                               and position[1] >= min(p[1] for p in positions)+30]
            if len(geometry) < 30:
                problems.append(f"{name}: expected a segmented tunnel assembly")
            if max_height < 35:
                problems.append(f"{name}: missing reference-height sidewall")
            if vertical_extent < 40:
                problems.append(f"{name}: tunnel crown does not rise above its base")
            if len(high_thin_parts) < 8:
                problems.append(f"{name}: missing segmented crown/roof pieces")
        else:
            if max_height < 5:
                problems.append(f"{name}: missing parapet-height parts")
        summaries.append(f"{name}: {len(geometry)} Parts, {vertical_extent:.1f}-stud vertical extent")

    if problems:
        for problem in problems:
            print("FAILED:", problem)
        return 1
    print("hardware references passed:")
    for summary in summaries:
        print("  " + summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
