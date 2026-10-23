# Performance work

This guide separates implemented optimizations from proposed work. Preserve
road geometry, saved editing data, regional markings, and rebuild behavior
when changing performance.

## Measure before changing emission

Use repeatable straight, curved, transitioning, junction-connected, viaduct,
and tunnel fixtures. Record:

- BasePart and total Instance counts;
- placement preview, build, and rebuild time;
- allocation and garbage collection data available in Studio;
- saved place size for the same road network;
- counts for road surfaces, markings, structures, and helper objects.

Report the complete fixture and its slowest road. A total alone can hide an
expensive segment. Python model counts do not establish Studio performance.

## Implemented: exact straight runs

`src/Mesh/RoadBuilder.lua` checks the Bézier control points for a monotonic,
collinear path with constant grade. A complete exact straight build can use
stations up to 2048 studs apart. Shallow curves retain adaptive segmentation.
Transitions and bus-bay slices retain their separate emission paths.

Adjacent Drive components can share a surface Part on this straight path when
their material, colour, height, and exclusion state agree. Markings still use
the original component arrays. Generated surface metadata retains source
component indices and station ranges. The road Model keeps the full curve and
profile data needed for editing and rebuilds.

Marking and kerb stretch endpoints are required stations. Junction trims arrive
as separate build ranges. No Part dimension may exceed Roblox's 2048-stud
limit. Other component kinds do not join the Drive bands.

`tools/preview/straight_optimization_preview.py` checks lengths below, at, and
above 2048 studs, longer runs, edit boundaries, surface mismatches, and source
metadata. Its default 5000-stud boulevard fixture compares 5625 legacy surface
Parts with 15 modeled optimized Parts. This is a model count, not a measured
Studio build-time improvement.

## Current curved and banked surfaces

Curved surfaces do not merge laterally across Drive components. A rigid Part
cannot follow a curved centreline or a changing bank angle.

`Superelevation.BuildProfile` owns the roll profile as a function of arc length.
`Superelevation.RollAtProfile` evaluates that profile. Sampling density must not
change it. `RoadBuilder.StationPlanFor` refines the station grid for curve and
roll changes. Road surfaces, markings, and structures consume that shared plan.

Every non-straight runtime interval uses exact station-corner quadrilaterals,
split into triangles by `FillTriangle`. Adjacent intervals share their station
edges. Width, lateral offset, and bank changes also use exact station geometry.
The runtime no longer uses padded midpoint boxes or alternating deck heights
for curved surfaces. Exact straight ranges retain compatible Drive merging.

`tools/preview/curved_superelevation_optimization_preview.py` checks roll and
station rules and retains a retired wide-band candidate as a regression
reference. Several preview paths still draw legacy midpoint boxes. Its old
990/882 surface-Part baselines do not measure the current exact-quad runtime
emitter. Use Studio measurements for current counts, render quality, collision,
and saved place size.

## Proposed work

These items require profiling and implementation before they can be claimed as
performance improvements.

| Area | Candidate | Required boundary |
| --- | --- | --- |
| Incremental rebuild | Rebuild only changed station ranges. | Preserve source data and unaffected structure phase. |
| Cached planning | Reuse curve samples, frames, and marking plans. | Invalidate on curve, profile, or settings changes. |
| Placement preview | Reuse Parts and process only the latest pointer state. | Keep snap points, width, and elevation exact. |
| Structures | Join constant straight slab, wall, or vault runs. | Split at sockets, pier stations, and structural joints. |
| Markings | Join compatible collinear solid spans. | Preserve dash cadence and regional rules. |
| Spatial lookup | Index nearby roads and junctions. | Return the same eligible roads as the existing query. |
| Serialization | Avoid unchanged attribute and JSON writes. | Preserve complete saved editing data. |
| Mixed curves | Optimize proven straight sub-runs. | Retain exact control-point checks and edit boundaries. |

Roundabout mouth clipping is another profiling target. The current convex
fragment coalescer requires a shared full edge, a convex union, and conserved
area. An indexed shared-edge lookup could reduce pair searches. A different
surface representation must preserve the same clipped footprint and keep
raised pavement outside the roadway.

## Acceptance checks

For each optimization:

1. Record before and after Instance counts and Studio timings.
2. Run the checks for the affected geometry.
3. Compare materials, colours, markings, and cross-section bounds.
4. Check split, edit, reopen, and rebuild operations in Studio.
5. Check undo and redo.
6. Confirm every Part dimension is at most 2048 studs.
7. Retain a segmented fallback for cases that fail the compatibility checks.

Run the [development checks](docs/development.md) and inspect the affected
geometry in Studio. A faster Python model does not prove a faster plugin.
