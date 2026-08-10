#!/usr/bin/env python3
"""Bird's-eye roundabout-editor showcase using the canonical preview port.

This is intentionally a thin scenario layer over ``roundabout_preview``.  It
does not redraw an idealised ring or maintain a second editor-only geometry
implementation: both states go through the same component emission, mouth
clipping, arm-marking ownership, Turbo, and raster pipeline used by the normal
roundabout validation.

    python3 roundabout_editor_preview.py
    python3 roundabout_editor_preview.py --out out/roundabout-editor
    python3 roundabout_editor_preview.py --check
"""

import argparse
from pathlib import Path

import roundabout_preview as rp


def editor_scenes():
    """Return a connected UK four-arm ring before and after an editor change."""
    approaches = [(angle, rp.two_way(2, 2, True)) for angle in (0, 90, 180, 270)]
    before = rp.build(
        tag="roundabout_editor_before",
        ring_r=70,
        ring_lanes=2,
        lane_width_m=3.2,
        drive_on_left=True,
        legs=approaches,
        markings="Continuous",
        sidewalk=True,
        island=True,
    )
    after = rp.build(
        tag="roundabout_editor_after",
        ring_r=90,
        ring_lanes=3,
        # 4.4 m is intentionally far from the 3.65 m approaches. The retired
        # floor-based Turbo mapping inferred one lane from a 7.3 m exit and
        # emitted no peel; actual Drive/Drive boundaries still map correctly.
        lane_width_m=4.4,
        drive_on_left=True,
        legs=approaches,
        markings="Turbo",
        sidewalk=False,
        island=False,
    )
    return before, after


def compatibility_scene():
    """One-way highway mouths exercise solo arms and zero-width shoulders."""
    return rp.build(
        tag="roundabout_editor_one_way_highway",
        **rp.CASES["hw_oneway"],
    )


def custom_shoulder_faults():
    """Contiguous terminal reserve must be adopted and collapsed per side."""
    profile = [
        ("Shoulder", 1.0, 0),
        ("Shoulder", 0.5, 0),
        ("Drive", 3.65, 1),
        ("Drive", 3.65, 1),
        ("Shoulder", 0.4, 0),
        ("Shoulder", 0.8, 0),
    ]
    inbound, outbound = rp.split_approach_lanes(profile, 1)
    faults = []
    if inbound is None or outbound is not None or len(inbound["lanes"]) != 6:
        faults.append("undirected adjacency did not grow through both shoulder runs")
        return faults
    components, _outer, _inner, _centre, cuts, _shift, _pavements = rp.arm_from_group(
        inbound, True, solo=True
    )
    if any(abs(actual - expected) > 1e-6
           for actual, expected in zip(cuts, (1.5, 1.2))):
        faults.append(f"terminal shoulder widths were {cuts!r}, expected (1.5, 1.2)")
    zero_shoulders = [component for component in components
                      if component[0] == "Shoulder" and component[1] <= 1e-6]
    if len(zero_shoulders) != 2:
        faults.append(
            f"terminal shoulder runs emitted {len(zero_shoulders)} semantic markers, expected 2"
        )
    return faults


def scene_faults(scene):
    faults = []
    holes, pitch = rp.scan_gaps(scene)
    real_holes, _thin = rp.cluster_gaps(holes, pitch, 0.15)
    if real_holes:
        faults.append(f"{len(real_holes)} visible bare-ground clusters")

    mouth_faults = [
        item
        for item in rp.scan_mouths(scene)
        if item["kind"] in ("gore", "hole", "overhang")
    ]
    if mouth_faults:
        faults.append(f"{len(mouth_faults)} mouth ownership faults")

    faults.extend(rp.check_arm_kinds(scene))
    faults.extend(rp.check_shoulder_tapers(scene))
    faults.extend(rp.check_turbo(scene))
    faults.extend(rp.check_visual_ownership(scene))
    faults.extend(rp.check_arm_marking_bounds(scene))
    faults.extend(rp.check_outboard_edge_handoffs(scene))
    faults.extend(rp.check_ring_openings(scene))

    seam_steps = rp.seam_steps(scene)
    if seam_steps:
        worst = max(max(left, right) for left, right in seam_steps)
        if worst > 0.5:
            faults.append(f"approach seam steps by {worst:.2f} studs")
    return faults


def contract_faults(before, after):
    faults = []
    expected = {
        "before": (70, 2, 3.2, "Continuous", True),
        "after": (90, 3, 4.4, "Turbo", False),
    }
    for label, scene in (("before", before), ("after", after)):
        actual = (
            scene["ring_r"],
            scene["ring_lanes"],
            scene["lane_width_m"],
            scene["markings"],
            scene["island"],
        )
        if actual != expected[label]:
            faults.append(f"{label} editor state drifted: {actual!r}")
        faults.extend(f"{label}: {fault}" for fault in scene_faults(scene))

    if after["outerR"] <= before["outerR"]:
        faults.append("radius/lane-width edit did not enlarge the emitted ring")
    if not after["spiral"]:
        faults.append("Turbo edit emitted no spiral marking parts")
    if before["spiral"]:
        faults.append("Continuous state unexpectedly contains Turbo parts")
    return faults


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        type=Path,
        help="write the before/after parts and gap PNGs to this directory",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="check geometry only; write nothing unless --out is also supplied",
    )
    args = parser.parse_args()

    before, after = editor_scenes()
    faults = contract_faults(before, after)
    compatibility = compatibility_scene()
    faults.extend(
        f"one-way highway: {fault}" for fault in scene_faults(compatibility)
    )
    faults.extend(f"custom shoulders: {fault}" for fault in custom_shoulder_faults())
    if len(compatibility["arm_kinds"]) != 4:
        faults.append(
            "one-way highway scenario did not build one solo arm per approach"
        )
    if faults:
        for fault in faults:
            print("FAILED:", fault)
        return 1

    out = args.out
    if out is None and not args.check:
        out = Path(__file__).resolve().parent / "out" / "roundabout-editor"
    if out is not None:
        out.mkdir(parents=True, exist_ok=True)
        for scene in (before, after, compatibility):
            for filename in rp.render(scene, str(out)):
                print("wrote", out / filename)

    print(
        "roundabout editor preview passed: canonical component pipeline, "
        "4.4 m Turbo width, full-angle edge handoffs, and one-way highway mouths"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
