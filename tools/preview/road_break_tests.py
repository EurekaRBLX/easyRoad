#!/usr/bin/env python3
"""Reintroduce road defects that actually shipped, and check the scans catch them.

    python3 tools/preview/road_break_tests.py

Every scan in `road_preview.py` passed every case the first time it was run.
That is not evidence - three rules in `check_turbo` did the same and were
measuring nothing (ROUNDABOUT.md 6). Each defect below is one that reached a
user in Studio, so a scan that cannot see it is not worth keeping.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import preview_core as core
import road_preview as rp

real_emit = core.emit_road


def no_miter(curve, components, *a, **k):
    """RoadBuilder before `curveMiterPad`: strips butt end to end with no
    padding, so every station boundary on a curve opens a sliver."""
    parts = real_emit(curve, components, *a, **k)
    out = []
    for p in parts:
        if p.name == "Marking":
            out.append(p)
            continue
        # Shrink each strip along its own length, which is what removing the
        # padding does.
        cx, cy = p.center
        out.append(core.Part(p.name, [(cx+(x-cx)*0.90, cy+(y-cy)*0.90) for x, y in p.poly],
                             p.color, p.center, p.y))
    return out


def far_edge_pad(curve, components, *a, **k):
    """The removed `farEdgePad`: widen alternate STATIONS, which read as a
    sawtooth down the outer edge.

    Alternating by station, not by part. Parts come out station-major, so
    `n % 2` picks the same two components at every station - a constant
    widening with no alternation along the road at all, which is a defect the
    scan is right not to call a sawtooth. Cost one wrong "NOT CAUGHT".
    """
    parts = real_emit(curve, components, *a, **k)
    per_station = sum(1 for c in components if c[1]*core.SCALE > 1e-4)
    out, n = [], 0
    for p in parts:
        if p.name == "Marking":
            out.append(p)
            continue
        station = n // per_station
        n += 1
        if station % 2 == 0:
            out.append(p)
            continue
        cx, cy = p.center
        out.append(core.Part(p.name, [(cx+(x-cx)*1.20, cy+(y-cy)*1.20) for x, y in p.poly],
                             p.color, p.center, p.y))
    return out


def drop_edge_line(curve, components, *a, **k):
    """A solid edge line with a chunk missing."""
    parts = real_emit(curve, components, *a, **k)
    marks = [p for p in parts if p.name == "Marking"]
    drop = {id(p) for p in marks[len(marks)//3:len(marks)//3+14]}
    return [p for p in parts if id(p) not in drop]


def run(name, patch, expect):
    core.emit_road = patch
    rp.emit_road = patch
    try:
        curve, comps = rp.CASES["tight_r60"]
        scene = rp.build("brk", curve, comps)
        holes, _ = rp.scan_road_gaps(scene)
        worst, flips, _ = rp.scan_edge_sawtooth(scene)
        breaks = rp.scan_marking_breaks(scene)
    finally:
        core.emit_road = real_emit
        rp.emit_road = real_emit
    got = {"gaps": bool(holes), "sawtooth": flips > 2, "marking": bool(breaks)}
    hit = got[expect]
    detail = (f"holes={len(holes)} flips={flips} worst={worst:.2f} "
              f"breaks={len(breaks)}")
    print(f"  {name:34s} {'caught' if hit else 'NOT CAUGHT'}  ({detail})")
    return hit


ok = True
ok &= run("no miter padding -> slivers", no_miter, "gaps")
ok &= run("farEdgePad -> sawtooth", far_edge_pad, "sawtooth")
ok &= run("edge line chunk missing", drop_edge_line, "marking")

curve, comps = rp.CASES["tight_r60"]
scene = rp.build("tight_r60", curve, comps)
clean = (not rp.scan_road_gaps(scene)[0]
         and rp.scan_edge_sawtooth(scene)[1] <= 2
         and not rp.scan_marking_breaks(scene))
print(f"  {'unmodified tight_r60':34s} {'clean' if clean else 'FAILS - scans disagree'}")
ok &= clean

print("ALL OK" if ok else "FAILURES")
sys.exit(0 if ok else 1)
