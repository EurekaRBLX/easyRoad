#!/usr/bin/env python3
"""One command that runs every headless check in this directory.

    python3 tools/preview/validate.py            # the quick set
    python3 tools/preview/validate.py --full     # every case, several minutes
    python3 tools/preview/validate.py --list     # what would run

There is no Roblox Studio in this environment and no Luau runtime, so this is
the only automated evidence the geometry works at all. It is not a substitute
for a live check - see the LIMITS section at the bottom of the output, which is
printed on every run on purpose.

KNOWN-OPEN
----------
Some checks fail on purpose, because the defect is understood, measured and not
yet fixed. Those pairs are listed in `KNOWN_OPEN` with a reason. The runner
fails if a NEW failure appears - and also if a known-open one starts PASSING,
because that means it was fixed and the entry is now a lie. An expected-failure
list nobody prunes is the same trap as an invariant nobody re-reads.
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# (suite, case, check) -> why it is expected to fail today.
KNOWN_OPEN = {}

QUICK_ROUNDABOUT = ["uk4", "uk3", "us4", "turbo4", "turbo_width", "hw4"]
FULL_ROUNDABOUT = ["uk4", "uk3", "us4", "uk5mini", "liveX2", "liveX4", "liveT2",
                   "liveT4", "stress", "stress_us", "turbo4", "turbo3x",
                   "turbo_width", "hw4", "hw4us", "hwmix", "hw_oneway", "solo_flare"]


def run_script(name, args=()):
    """Run one of the standalone checkers as a subprocess.

    A subprocess rather than an import because several of them monkeypatch the
    emitter for their break-tests, and a failed restore would silently corrupt
    every check that ran afterwards in the same interpreter.
    """
    t = time.time()
    proc = subprocess.run([sys.executable, os.path.join(HERE, name), *args],
                          capture_output=True, text=True)
    return proc.returncode == 0, proc.stdout + proc.stderr, time.time()-t


def roundabout_suite(cases):
    import roundabout_preview as rp
    results = []
    for name in cases:
        scene = rp.build(tag=name, **rp.CASES[name])
        checks = {}
        holes, pitch = rp.scan_gaps(scene)
        mouth = rp.scan_mouths(scene)
        checks["mouth"] = not [m for m in mouth if m["kind"] in ("gore", "hole", "overhang")]
        # Same clustering `report` uses, from the same function - re-deriving
        # the hairline rule here would be a second implementation to disagree
        # with the first.
        real, _thin = rp.cluster_gaps(holes, pitch, 0.15)
        checks["gaps"] = not real
        checks["arm_kinds"] = not rp.check_arm_kinds(scene)
        checks["shoulder"] = not rp.check_shoulder_tapers(scene)
        checks["turbo"] = not rp.check_turbo(scene)
        checks["ring_boundary"] = not rp.check_ring_openings(scene)
        checks["visual_ownership"] = not rp.check_visual_ownership(scene)
        checks["arm_marking_bounds"] = not rp.check_arm_marking_bounds(scene)
        checks["edge_handoff"] = not rp.check_outboard_edge_handoffs(scene)
        checks["solo_merge"] = not rp.check_solo_merges(scene)
        steps = rp.seam_steps(scene)
        checks["seam"] = not steps or max(max(a, b) for a, b in steps) <= 0.5
        results.append((name, checks))
    return results


def road_suite():
    import road_preview as rd
    results = []
    for name, (curve, comps) in rd.CASES.items():
        scene = rd.build(name, curve, comps)
        holes, _ = rd.scan_road_gaps(scene)
        _, flips, _ = rd.scan_edge_sawtooth(scene)
        results.append((name, {
            "gaps": not holes,
            "sawtooth": flips <= 2,
            "markings": not rd.scan_marking_breaks(scene),
        }))
    return results


def grade(suite, results, problems, stale):
    for case, checks in results:
        for check, passed in checks.items():
            key = (suite, case, check)
            known = key in KNOWN_OPEN
            if not passed and not known:
                problems.append(key)
            elif passed and known:
                stale.append(key)
        marks = " ".join(("." if p else ("!" if (suite, case, c) not in KNOWN_OPEN else "k"))
                         + c for c, p in sorted(checks.items()))
        print(f"  {case:16s} {marks}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--full", action="store_true", help="every roundabout case")
    ap.add_argument("--list", action="store_true", help="print what would run")
    args = ap.parse_args()

    cases = FULL_ROUNDABOUT if args.full else QUICK_ROUNDABOUT
    if args.list:
        print("roundabout:", " ".join(cases))
        import road_preview as rd
        print("road:      ", " ".join(rd.CASES))
        print("scripts:    turbo_check.py roundabout_parity_contract.py junction_lifecycle_contract.py roundabout_editor_preview.py --check roundabout_arm_height_preview.py --check roundabout_cut_handoff_preview.py --check road_break_tests.py straight_optimization_preview.py --check curved_superelevation_optimization_preview.py --check structure_preview.py --check ground_asset_preview.py --check parallel_preview.py --check transition_anchor_preview.py --check cross_section_connection_preview.py --check setup_wizard_preview.py --check multinode_junction_preview.py --check marking_boundary_preview.py --check regional_marking_preview.py --check structure_break_tests.py hardware_reference_check.py integration_contracts.py check_parity.py")
        return 0

    problems, stale = [], []
    print("legend: .check passed   !check FAILED   kcheck known-open\n")

    t = time.time()
    print("roundabout")
    grade("roundabout", roundabout_suite(cases), problems, stale)
    print("road")
    grade("road", road_suite(), problems, stale)

    print("\nbreak-tests and parity")
    for script, script_args in (
            ("turbo_check.py", ()),
            ("roundabout_parity_contract.py", ()),
            ("junction_lifecycle_contract.py", ()),
            ("roundabout_editor_preview.py", ("--check",)),
            ("roundabout_arm_height_preview.py", ("--check",)),
            ("roundabout_cut_handoff_preview.py", ("--check",)),
            ("road_break_tests.py", ()),
            ("straight_optimization_preview.py", ("--check",)),
            ("curved_superelevation_optimization_preview.py", ("--check",)),
            ("structure_preview.py", ("--check",)),
            ("ground_asset_preview.py", ("--check",)),
            ("parallel_preview.py", ("--check",)),
            ("transition_anchor_preview.py", ("--check",)),
            ("cross_section_connection_preview.py", ("--check",)),
            ("setup_wizard_preview.py", ("--check",)),
            ("multinode_junction_preview.py", ("--check",)),
            ("marking_boundary_preview.py", ("--check",)),
            ("regional_marking_preview.py", ("--check",)),
            ("structure_break_tests.py", ()),
            ("hardware_reference_check.py", ()),
            ("integration_contracts.py", ()),
            ("check_parity.py", ())):
        ok, out, secs = run_script(script, script_args)
        # check_parity reports drift on stdout but exits 0; treat any "DRIFT" as
        # a failure here so the runner is the single answer.
        if "DRIFT" in out:
            ok = False
        print(f"  {script:22s} {'ok' if ok else 'FAILED'}  ({secs:.0f}s)")
        if not ok:
            problems.append(("script", script, "run"))
            print("".join(f"      {l}\n" for l in out.strip().split("\n")[-6:]))

    print(f"\n{time.time()-t:.0f}s total")
    for key in stale:
        print(f"STALE known-open: {key} now PASSES - remove it from KNOWN_OPEN")
    for key in problems:
        print(f"FAILED: {key}")
    if KNOWN_OPEN:
        print(f"\n{len(KNOWN_OPEN)} known-open failures carried (see KNOWN_OPEN in this file)")

    print("""
LIMITS - what a green run here does NOT mean:
  * nothing is executed in Roblox. This re-implements the geometry in Python;
    it cannot catch a nil identifier, a Luau error, or the Lua diverging from
    this port. check_parity.py compares CONSTANTS, not behaviour.
  * general road/roundabout heights and render order are not modelled. The
    roundabout contract models its two explicit marking top planes and the
    structure preview models elevation, but other z-fighting and actual Roblox
    raycasts remain Studio-only.
  * transition_anchor_preview.py proves only the whole-profile Centre/LeftEdge/
    RightEdge datum math for 3->4 and 4->3, its constant-width chain join, and
    the legacy zero-offset fallback. General emitted transition strips,
    component matching, and bus bays are not ported, so it cannot certify their
    Part-level seams or topology.
  * cross_section_connection_preview.py proves the connection-mode contract and
    selected lateral datum, not Roblox mouse raycasts or live junction rebuilds.
  * imported Roblox Models are represented by their start/end socket chord;
    mesh contents, collisions and attachment orientation still need Studio.""")
    return 1 if (problems or stale) else 0


if __name__ == "__main__":
    sys.exit(main())
