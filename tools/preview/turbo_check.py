"""Turbo peel checks: the cases that broke each of the earlier designs.

    python3 tools/preview/turbo_check.py

`roundabout_preview.py`'s own case table carries two Turbo scenes. This runs the
full set, and - the part that matters - runs a BREAK-TEST per rule in
`check_turbo`. Three of that function's rules have been invalidated by design
changes they were not re-read against (ROUNDABOUT.md 6), and each of them passed
everything until a break-test was written for it specifically. A rule with no
break-test beside it is an assumption.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import roundabout_preview as m

case, two_way, one_way = m.case, m.two_way, m.one_way
LANE = m.LANE_M * m.SCALE

T = {
    "uk 2-lane 4-leg": case(70, 2, True, [(a, two_way(2, 2, True)) for a in (0, 90, 180, 270)],
                            markings="Turbo"),
    "us 2-lane 4-leg": case(70, 2, False, [(a, two_way(2, 2, False)) for a in (0, 90, 180, 270)],
                            markings="Turbo"),
    "1-lane (must not peel)": case(50, 1, True, [(a, two_way(1, 1, True)) for a in (0, 120, 240)],
                                   markings="Turbo"),
    "skew 4-leg": case(70, 2, True, [(a, two_way(2, 2, True)) for a in (0, 65, 170, 250)],
                       markings="Turbo"),
    "tight 3-leg": case(45, 2, True, [(a, two_way(2, 2, True)) for a in (0, 130, 220)],
                        markings="Turbo"),
    "uk 3-lane / 2-lane exits": case(80, 3, True, [(a, two_way(2, 2, True)) for a in (0, 90, 180, 270)],
                                     markings="Turbo"),
    "uk 3-lane / 3-lane exits": case(90, 3, True, [(a, two_way(3, 3, True)) for a in (0, 90, 180, 270)],
                                     markings="Turbo"),
    "us 3-lane 3-leg (turbo3x)": m.CASES["turbo3x"],
}

# One break-test per rule, each isolating the rule it targets. The defect is
# introduced in the emitted PARTS as well as the spans: check_turbo reads the
# parts for one of its rules and the spans for the others, and a break-test that
# doctors only one of the two passes for the wrong reason. That happened while
# writing these - two "caught" results were the untouched geometry answering.
def break_tests():
    print("break-tests (each MUST report a fault):")
    real = m.turbo_spiral

    def transform(fn):
        """Rebuild the peel's parts and spans through a plane map."""
        def wrapped(center, ring_r, island_r, lanes, lane_m, dol, exits):
            parts, spans = real(center, ring_r, island_r, lanes, lane_m, dol, exits)
            out = []
            for p in parts:
                out.append(m.Part(p.name, [fn(center, q) for q in p.poly], p.color,
                                  fn(center, p.center), p.y))
            sp = []
            for n, k, a0, r0, a1, r1 in spans:
                q0 = fn(center, (center[0] + math.cos(a0) * r0, center[1] + math.sin(a0) * r0))
                q1 = fn(center, (center[0] + math.cos(a1) * r1, center[1] + math.sin(a1) * r1))
                sp.append((n, k,
                           math.atan2(q0[1] - center[1], q0[0] - center[0]),
                           math.hypot(q0[0] - center[0], q0[1] - center[1]),
                           math.atan2(q1[1] - center[1], q1[0] - center[0]),
                           math.hypot(q1[0] - center[0], q1[1] - center[1])))
            return out, sp
        return wrapped

    def push_out(center, q):
        """Shove the whole peel 1.5 lanes outward: it starts on no divider."""
        d = LANE * 1.5
        a = math.atan2(q[1] - center[1], q[0] - center[0])
        r = math.hypot(q[0] - center[0], q[1] - center[1]) + d
        return (center[0] + math.cos(a) * r, center[1] + math.sin(a) * r)

    def spin(center, q):
        """Rotate the peel 40deg: right radii, but it ends at no exit."""
        a, r = math.atan2(q[1] - center[1], q[0] - center[0]), math.hypot(q[0] - center[0], q[1] - center[1])
        a += math.radians(40)
        return (center[0] + math.cos(a) * r, center[1] + math.sin(a) * r)

    def backwards(center, ring_r, island_r, lanes, lane_m, dol, exits):
        parts, spans = real(center, ring_r, island_r, lanes, lane_m, dol, exits)
        return parts, [(n, k, a1, r1, a0, r0) for n, k, a0, r0, a1, r1 in spans]

    ok = True
    for name, fn in (("peel 1.5 lanes off any divider", transform(push_out)),
                     ("peel that ends at no exit", transform(spin)),
                     ("peel run backwards", backwards)):
        m.turbo_spiral = fn
        try:
            scene = m.build(tag="brk", **T["uk 2-lane 4-leg"])
            faults = m.check_turbo(scene)
        finally:
            m.turbo_spiral = real
        print(f"  {name:36s} {'caught: ' + faults[0] if faults else 'NOT CAUGHT'}")
        ok &= bool(faults)
    return ok


def radii_trace(scene, label):
    """Every peel span's radius, in emission order, so a dip is visible."""
    bad = 0
    for _, _, a0, r0, a1, r1 in scene["spiral_spans"]:
        if r1 < r0 - 0.5:
            bad += 1
    if bad:
        print(f"    {label}: {bad} inward spans")
        for _, _, a0, r0, a1, r1 in scene["spiral_spans"]:
            flag = "  <-- INWARD" if r1 < r0 - 0.5 else ""
            print(f"      {math.degrees(a0) % 360:7.1f}deg r {r0:6.1f}  ->  "
                  f"{math.degrees(a1) % 360:7.1f}deg r {r1:6.1f}{flag}")


ok = True
for name, cfg in T.items():
    scene = m.build(tag=name, **cfg)
    faults = m.check_turbo(scene)
    n = len(scene["spiral"])
    print(f"{name:28s} {n:4d} peel parts  {'OK' if not faults else 'FAIL'}")
    for f in faults:
        print(f"    - {f}")
        ok = False
    radii_trace(scene, name)

print()
ok &= break_tests()
print()
print("ALL OK" if ok else "FAILURES")
sys.exit(0 if ok else 1)
