#!/usr/bin/env python3
"""Catch drift between RoundaboutBuilder.lua and the preview's port of it.

`roundabout_preview.py` is a hand-written Python re-implementation of the Lua,
not an execution of it. Nothing keeps the two in sync, so a constant tuned on
one side and forgotten on the other makes the preview quietly certify geometry
the plugin does not build. That has already nearly happened: a Lua edit was
silently reflowed away by stylua while the matching Python edit landed, and the
scan reported on code that was never shipped.

What this checks:
  * every constant present on BOTH sides has the same value
  * constants that exist on one side only, so a rename or deletion is visible

What this does NOT check: the algorithm. Two implementations can agree on every
number and still differ in what they do with them. Only Studio settles that.

    python3 check_parity.py        # exits non-zero on drift
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LUA = os.path.join(HERE, "..", "..", "src", "Mesh", "RoundaboutBuilder.lua")
PY = os.path.join(HERE, "roundabout_preview.py")

# Names that are deliberately spelled differently on the two sides.
ALIASES = {
    "ARM_SINK_STUDS": "ARM_SINK",
    "ARM_RUN_MIN_STUDS": "ARM_RUN_MIN",
    "ARM_RUN_MAX_STUDS": "ARM_RUN_MAX",
}
# Names that legitimately exist on one side only.
# The preview inlines this as a one-letter local inside circle_segments,
# which the scanner skips on purpose (single letters are loop noise).
LUA_ONLY = {"BEZIER_CIRCLE_K"}
PY_ONLY = {"CHORD_TOLERANCE", "MIN_STEP", "MAX_TURN_PER_STEP", "MARKING_THICKNESS",
           "MAX_SEGMENT_LENGTH", "ARC_SAMPLES", "SCALE", "SW_M", "LANE_M",
           "MARKING_W_M", "THICKNESS",
           "GROUND", "FLAT", "ASPHALT_C", "SIDEWALK_C", "MARK_C", "ISLAND_C"}


def scalars(text, rad):
    """Constants assigned a plain number or an angle, including tuple lines."""
    out = {}
    for line in text.splitlines():
        line = line.strip().removeprefix("local ")
        m = re.match(r"^([A-Z][A-Z0-9_]+[A-Z0-9_,\s]*)=\s*(.+?)\s*$", line)
        if not m:
            continue
        names = [n.strip() for n in m.group(1).split(",") if n.strip()]
        values = [v.strip() for v in m.group(2).split(",")] if len(names) > 1 else [m.group(2)]
        if len(names) != len(values):
            continue
        for name, value in zip(names, values):
            angle = re.match(rad + r"\(([\d.]+)\)$", value)
            if angle:
                out[name] = round(float(angle.group(1)), 9)
            elif re.match(r"^-?[\d.]+$", value):
                out[name] = round(float(value), 9)
    return out


def main():
    lua = scalars(open(LUA).read(), r"math\.rad")
    py = scalars(open(PY).read(), r"math\.radians")
    for lua_name, py_name in ALIASES.items():
        if py_name in py:
            py[lua_name] = py.pop(py_name)

    problems = []
    for name in sorted(set(lua) & set(py)):
        if abs(lua[name] - py[name]) > 1e-9:
            problems.append(f"value differs: {name}  lua={lua[name]}  preview={py[name]}")
    for name in sorted(set(lua) - set(py) - LUA_ONLY):
        problems.append(f"in Lua, missing from preview: {name}")
    for name in sorted(set(py) - set(lua) - PY_ONLY):
        problems.append(f"in preview, missing from Lua (stale?): {name}")

    shared = len(set(lua) & set(py))
    if problems:
        print(f"PARITY DRIFT ({shared} constants shared):")
        for problem in problems:
            print("  " + problem)
        return 1
    print(f"parity OK: {shared} shared constants agree, no orphans")
    print("note: constants only - the algorithm itself is not compared")
    return 0


if __name__ == "__main__":
    sys.exit(main())
