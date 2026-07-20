# RoadCreator reference (junction + roundabout, translate C# → Luau)

Vendored read-only reference (outside `src/`, not built). The strongest
reference found so far: a Unity/C# road tool with BOTH a working
arbitrary-N-way intersection generator AND a real roundabout generator (the
only OSS roundabout mesh generator located in this whole survey). MIT
licensed, so its algorithms can be translated into Luau.

## Source & license

- Repo: https://github.com/MarcusElg/roadcreator
- Commit: `ba42880192d366febb92da87fd09ba985e923b68` (2019-10-12)
- License: MIT — Copyright 2019 MCrafterzz. `LICENSE-roadcreator.md`.
  Translated algorithms keep an attribution comment.

## Files

| File | Lines | What |
|------|-------|------|
| `Intersection.cs` | 1071 | Arbitrary-N-way intersection mesh. `CreateMainMesh` is the core. |
| `Roundabout.cs` | 1274 | Roundabout mesh: ring + per-feeder blend sections + centre island. |
| `IntersectionConnection.cs` | 31 | Per-approach record. **`IComparable` by `YRotation`** — the ring is angle-sorted. |
| `MainRoad.cs` | 21 | Through-road pair (start/end connection indices) for 4-ways. |
| `RoundaboutExtraMesh.cs` | 26 | Sidewalk/verge band descriptor. |
| `Misc.cs` | ~380 | The portable math primitives (translate these first). |

## How its INTERSECTION works (and why it's more robust than ours)

Each approach is an `IntersectionConnection`: `leftPoint`, `rightPoint`
(its two pavement-edge points at the intersection), `lastPoint` (a centre
reference), `curvePoint` (a corner control point), and `YRotation` (its
facing angle). Connections are **sorted by `YRotation`** (the `IComparable`)
so they form an ordered ring — each adjacent pair gets exactly one corner,
no "which pairs with which" decision per rebuild.

`CreateMainMesh` walks the sorted ring. Between `connection[i].leftPoint`
and `connection[i+1].rightPoint` it draws the corner as a **quadratic
Bézier through `curvePoint`** (`Misc.Lerp3CenterHeight(left, curvePoint,
right, t)`), and fills inward to the intersection centre as a fan (`t<0.5`
lerps a centre-reference toward centre, `t>0.5` back out).

**The key difference from easyRoad's corner:** our corner is a circular
fillet built from the *intersection of the two edge lines* (`Fillet.Compute`),
which fails or scoops when the lines are near-parallel, diverging, or
reflex — the whole source of the spikes/notches. RoadCreator's corner is a
Bézier that is a **convex combination of three fixed points**
(left, curvePoint, right): it is bounded inside their triangle by
construction and **cannot spike or self-intersect for ANY corner angle**.
`curvePoint` is auto-placed where the edge lines meet (via
`Misc.GetLineIntersection`, which returns a `MaxVector3` sentinel when
parallel → fall back to the midpoint) and is also an editable drag handle.

Through-roads on a 4-way (`MainRoad` + `CreateMainRoadsMeshes`) get their
control points from `GetLineIntersection` of the two roads' edge lines,
with a `GetCenter` midpoint fallback when parallel — clean through-pair
handling with no special "is this a through pair" dot test.

## How its ROUNDABOUT works (the humps fix)

`Roundabout.GenerateRoundabout`:
1. `CreateRoundaboutVertices` — the ring circle vertices (inner + outer).
2. `CreateRoadSections` — the ring pavement between feeders.
3. Per feeder: `FindNearestPoints` / `CalculateNearestIntersectionPoint`
   project the feeder's left/right edges onto the ring, then
   `AddNewRoadConnectionVertices` builds a **connection section** — a Bézier
   blend (`curvePoint`/`curvePoint2`) from the feeder's cross-section into
   the ring's own edge. This is a real merge lane, not two corner triangles.
4. `CreateCenterExtraMeshes` — the central island.

easyRoad's roundabout builds isolated flare triangles at each mouth, which
is where the "humps and lumps" come from. RoadCreator instead **projects
the feeder onto the ring and blends with a Bézier section along the ring**,
so the feeder pavement and ring pavement are one continuous surface.

## Portable primitives to translate first (`Misc.cs`)

- `Lerp3CenterHeight(start, center, end, t)` — quadratic Bézier through 3
  points; the corner/merge curve. ~10 lines. **The single most useful lift.**
- `GetLineIntersection(p1, d1, p2, d2)` — 2D line intersection, returns a
  `MaxVector3` sentinel when parallel/behind. The corner control-point and
  through-pair primitive.
- `CalculateLeft(forward)` — ground-plane perpendicular.
- `CalculateDistance(a, ctrl, b)` — Bézier arc-length estimate → segment
  count. `GetCenter`, `MaxVector3` sentinel.

## Recommended takeaways for easyRoad (keeping our methodology)

1. **Swap the fillet corner for a quadratic-Bézier-through-a-control-point.**
   Bounded by construction → kills the spike/notch/scoop class outright.
   Auto-place the control at the edge-line intersection (midpoint fallback),
   optionally editable later. This is a smaller, safer change than the
   polygon-boolean rewrite in `../INTERSECTION_ROUNDABOUT_OPTIONS.md`, and
   it composes with easyRoad's existing angle-sorted approach nodes.
2. **Roundabout: project each feeder onto the ring and Bézier-blend** the
   cross-section into the ring edge, replacing the flare triangles — the
   direct fix for the humps.
3. Both are C#→Luau translation of MIT code, not a paradigm change.
