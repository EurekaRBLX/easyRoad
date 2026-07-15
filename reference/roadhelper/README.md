# RoadHelper reference (junction generation)

Vendored, read-only reference material — **not built into the plugin**
(`reference/` is outside `src/`, so `tools/build_rbxmx.py` never sees it).
Extracted at the user's request as a "less-faulty" junction-generation
codebase to draw on while easyRoad keeps its own procedural methodology.

## Source & license

- Repo: https://github.com/stravant/roblox-roadhelper
- Commit: `bfa5c5dde79a2927bb758b17abbc6f878af508fb`
  ("Crosswalk Width setting for selected intersections", 2026-07-12)
- License: MIT — Copyright 2025 Mark Langen (@stravant). Full text in
  `LICENSE-roadhelper`. Any code ADAPTED from here into `src/` must keep an
  attribution comment; a straight copy would keep the license header.

## What's here

| File | What it is |
|------|-----------|
| `RoadIntersectionGenerator.lua` | The one that matters — the procedural intersection **mesh** generator (609 lines). Fixed 2-axis crossing. |
| `StraightRoadGenerator.lua` | Straight-segment mesh generator (for cross-referencing the marking/cross-section conventions). |
| `CurveRoadGenerator.lua` | Curved-segment mesh generator. |
| `RoadMath.lua` | Pure connection/joint math: endpoint frames, `findJoint`, `solveMove`, `placementFrame` (squares intersection angles), `matchingAdjust` (flush Dir/Grade/Bank). Segment-placement, not mesh. |

## The one big finding

**There is NO roundabout anywhere in RoadHelper** (only Straight / Curve /
Intersection templates — confirmed by search). easyRoad's roundabout stays
entirely bespoke; there is nothing to extract for it.

**RoadHelper's intersection uses the SAME circular-fillet corner concept
easyRoad already has** (`Fillet.Compute` ≈ its lines 305-331: `theta =
acos(edgeA · edgeB)`, `r = d * tan(theta/2)`, centre on the bisector at
`d / cos(theta/2)`, swept in `maxAngle` steps). It is not a different
corner algorithm.

What makes it **fault-free where easyRoad's is fragile is the FRAME it runs
in**, not the corner formula:

- It is a **fixed 2-axis (X/Z) crossing** — `LaneWidthX/CountX`,
  `LaneWidthZ/CountZ`, one `IntersectionAngle` (± `MaxAngle`, default 10°),
  and a `ThroughRoad` bool (false = T-junction). Never an arbitrary N-way.
- Every geometric point is **derived analytically** from the two roads'
  widths and the crossing angle via `cornerPoint(sZ, sX)` — the four
  corners of the central overlap parallelogram. There is no convex hull, no
  angle-sorting of approaches, no "which point pairs with which" decision.
  Those decisions are exactly what has produced easyRoad's live-reported
  faults (5-way spikes, through-pair notches, mouth-crossing bands).
- The corner fillet's tangent length is **bounded by the space actually
  available in the box**: `d = min(dzAvail, dxAvail)` (distance along each
  pavement edge to its open-end plane). A corner physically cannot
  overshoot into a neighbour — the failure mode easyRoad keeps guarding
  against after the fact is structurally impossible here.
- T-junctions are a **one-line flag**, not special geometry: `if not
  throughRoad and sZ == -1 then continue` skips the two corners on the far
  side of the crossbar. Road-X open ends are **squared** (cut perpendicular
  at the 90°-equivalent length) so straight continuations join flush.

## What's directly transferable to easyRoad (procedural, kept)

Without adopting the fixed-topology model wholesale, these are liftable:

1. **The full marking pass through the pad** — easyRoad has none. RoadHelper
   draws, all keyed off the same `cornerData` it keeps per corner:
   centreline, lane markings that follow the corner curve as **miter-extended
   chord strips** (outer corners meet, no wedge gap), **edge-line arcs**
   concentric with the curb (`EDGE_INSET` inside it), **stop lines**
   (`STOP_LINE_END_DISTANCE` back from each open end), and **zebra
   crosswalks** (`CROSSWALK_STRIPE`/`CROSSWALK_GAP`). This is a real feature
   gap, independent of the corner-geometry work the other agent is doing.
2. **Squared / flush open ends** — cutting each approach's terminating face
   perpendicular at its 90°-equivalent length so a continuing straight joins
   without a seam. easyRoad trims approaches to a circular pad boundary
   instead, which is part of why its seams need the fillet/Hermite dance.
3. **Corner radius as available-space-bounded, not a fixed constant** —
   easyRoad hardcodes `FILLET_RADIUS_M = 6`; RoadHelper derives it from the
   box (`d = min(dzAvail, dxAvail)`, then `r = d*tan(theta/2)`), so a bigger
   junction automatically gets smoother corners and a corner physically
   can't exceed its space. easyRoad's `chord * 0.45` radius cap (added by
   the other agent) is the same idea, less precisely.
4. **`RoadMath.placementFrame` / `matchingAdjust`** — for a future
   "snap-square" connect mode: when a road joins an intersection it squares
   to the nearest 90°-family face and matches Dir/Grade/Bank flush.

## What would be an architectural fork (NOT done without a decision)

Adopting the fixed X/Z-box intersection wholesale would make easyRoad's
junctions robust by construction, but trades away arbitrary angles/widths
per leg and arbitrary leg counts. Per the user's steer ("use our current
methodology"), that fork is **not** taken; this folder exists so the clean
implementation is on hand when the procedural corner work wants to borrow
from it.
