#!/usr/bin/env python3
"""Print the preview's geometry in the same format as the plugin's dump.

`check_parity.py` compares the two implementations' CONSTANTS. This compares
their BEHAVIOUR, which is the thing that actually matters: two implementations
can agree on every number and still do different things with them.

Workflow:

  1. In Studio, select the junction, set Radius / Lanes / Lane width, and press
     "Print geometry to Output" (RoundaboutBuilder.DescribeJunction).
  2. Run this with the same inputs:

         python3 dump_compare.py --radius 30 --lanes 1 --legs 0,90,180,270

  3. Diff the two. Every line should match to the printed precision.

Fields are emitted in the same order and format as the Lua so a plain `diff`
works. Angles are degrees, distances studs.

A mismatch here is a real divergence and means preview results cannot be
trusted until it is explained. A match means the remaining difference between
preview renders and Studio is the RENDERER - idealised polygons versus rigid
parts - not the algorithm.
"""
import argparse
import math

import roundabout_preview as P


def min_radius(legs, lane_count, lane_w, dol):
    """Port of RoundaboutBuilder.MinimumRadiusStuds."""
    total = widest = outer_off = 0.0
    for _, spoke in legs:
        inbound, outbound = P.split_approach_lanes(spoke, 1)
        solo = (inbound is None) != (outbound is None)
        for group in (inbound, outbound):
            if not group:
                continue
            comps, outer, _inner, _centre, _cut_shoulders, _core_shift = P.arm_from_group(
                group, dol, solo
            )
            width = sum(c[1] for c in comps) * P.SCALE
            total += width
            widest = max(widest, width)
            outer_off = max(outer_off, outer)
    spare = 2 * math.pi - len(legs) * (2 * P.MIN_SPLIT_RAD + P.MIN_KERB_GAP_RAD)
    merge = total / spare if spare > 0.2 else total
    ring_w = max(1, lane_count) * lane_w + P.SW_M
    ring_half = max(ring_w * P.SCALE, widest) / 2
    return merge + outer_off + P.SW_M * P.SCALE - ring_half


def split_budget_for(angles, index):
    """Port of splitBudgetFor."""
    angle = angles[index]
    nearest = 2 * math.pi
    for i, other in enumerate(angles):
        if i == index:
            continue
        ahead = (other - angle) % (2 * math.pi)
        nearest = min(nearest, ahead, 2 * math.pi - ahead)
    return max(P.MIN_SPLIT_RAD, nearest / 2 - P.MIN_KERB_GAP_RAD / 2)


def resolve_splits(mouth_angle, budget, flow, deflect):
    """Port of resolveSplits."""
    split = max(P.MIN_SPLIT_RAD,
                min(P.SPLIT_ANGLE_RAD, max(P.MIN_SPLIT_RAD, budget - P.SECTOR_MARGIN_RAD)))
    entry_split = max(P.MIN_SPLIT_RAD, split * P.ENTRY_SPLIT_SCALE) if deflect else split
    return split, entry_split, mouth_angle + flow * entry_split, mouth_angle - flow * split


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--radius", type=float, default=30.0)
    ap.add_argument("--lanes", type=int, default=1)
    ap.add_argument("--lane-width", type=float, default=P.LANE_M)
    ap.add_argument("--legs", default="0,90,180,270",
                    help="comma-separated leg bearings in degrees")
    ap.add_argument("--approach-lanes", type=int, default=1,
                    help="running lanes EACH WAY on every approach")
    ap.add_argument("--right-hand", action="store_true", help="model a right-hand-drive region")
    ap.add_argument("--no-deflect", action="store_true")
    args = ap.parse_args()

    dol = not args.right_hand
    deflect = not args.no_deflect
    flow = 1 if dol else -1
    bearings = [float(x) for x in args.legs.split(",") if x.strip()]
    legs = [(b, P.two_way(args.approach_lanes, args.approach_lanes, dol)) for b in bearings]

    minimum = min_radius(legs, args.lanes, args.lane_width, dol)
    # Minimum is advice only. The live builder deliberately honours the radius
    # the user requested, so growing it here compares against a ring Studio
    # never builds.
    grown = args.radius
    ring_total = max(1, args.lanes) * args.lane_width + P.SW_M
    outer = grown + ring_total / 2 * P.SCALE
    kerb = outer - P.SW_M * P.SCALE

    print("=== roundabout dump: junction <preview> ===")
    print(f"scale={P.SCALE:.4f} driveOnLeft={str(dol).lower()} deflect={str(deflect).lower()}")
    print(f"radius requested={args.radius:.3f} minimum={minimum:.3f} used={grown:.3f} "
          f"outer={outer:.3f} kerb={kerb:.3f} flow={flow}")

    # Legs are radial in the preview, so the mouth angle IS the bearing. The
    # plugin instead aims along the approach's own centreline
    # (rayCircleFirstHit), which only agrees for radial approaches - see TODO.
    angles = [math.radians(b) for b in bearings]
    print(f"legs planned={len(angles)}")
    for index, angle in enumerate(angles):
        budget = split_budget_for(angles, index)
        split, entry_split, entry_angle, exit_angle = resolve_splits(angle, budget, flow, deflect)
        print(f"leg {index + 1} mouthAngle={math.degrees(angle):.4f} "
              f"budget={math.degrees(budget):.4f} split={math.degrees(split):.4f} "
              f"entrySplit={math.degrees(entry_split):.4f} "
              f"entryAngle={math.degrees(entry_angle):.4f} "
              f"exitAngle={math.degrees(exit_angle):.4f}")
        inbound, outbound = P.split_approach_lanes(legs[index][1], 1)
        solo = (inbound is None) != (outbound is None)
        for label, group, travels_inward in (("entry", inbound, True), ("exit", outbound, False)):
            if not group:
                print(f"     {label}: none")
                continue
            comps, outer_off, inner_off, road_centre, _cut_shoulders, core_shift = (
                P.arm_from_group(group, dol, solo, not travels_inward)
            )
            merge = kerb - outer_off
            span_centre = (group["left"] + group["right"]) / 2
            core_centre = span_centre + core_shift * (1 if travels_inward else -1)
            lat = ((core_centre - road_centre) if travels_inward
                   else (core_centre + road_centre))
            print(f"     {label}: merge={merge:.4f} lateral={lat * P.SCALE:.4f} "
                  f"outer={outer_off:.4f} inner={inner_off:.4f} "
                  f"width={sum(c[1] for c in comps) * P.SCALE:.4f}")


if __name__ == "__main__":
    main()
