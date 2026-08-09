# EasyRoad — optimization backlog

This is the performance plan, not a claim that the items below are shipped.
Correct geometry, editing semantics, regional markings, and rebuild stability
remain hard gates: an optimization that changes the visible road or makes a
segment uneditable is a regression.

## Measure first

Before changing emission, record representative baselines for straight, curved,
transitioning, junction-connected, elevated, and tunnel roads:

- generated BasePart and total Instance counts;
- build/rebuild and placement-preview time;
- Lua allocation/GC pressure where Studio exposes it;
- serialized `.rbxl` size for a fixed test network;
- part counts by kind: road surface, markings, structures, and helpers.

Keep a repeatable benchmark place or generator. Report both totals and the
worst individual road so a large map cannot hide one pathological segment.

## P0 — straight-run longitudinal coalescing (phase 1 shipped)

A genuinely straight, constant cross-section run should use long Parts rather
than inheriting the normal curve station spacing.

Phase 1 is implemented in `RoadBuilder`: a whole build whose Bezier control
points prove one monotonic, collinear, constant-grade path uses explicit
stations up to 2048 studs apart. The proof is deliberately exact rather than a
curvature sample, so shallow curves retain adaptive segmentation. Profile
transitions and sliced bus-bay geometry also retain the old emitter. Marking
and kerb-stretch endpoints are mandatory stations; separate road/junction trims
already arrive as separate build ranges.

- Emit one longitudinal Part per compatible surface band for up to **2048
  studs**, Roblox's Part-axis limit. Split longer runs into consecutive Parts,
  with a tiny controlled overlap only if a render seam is measurable.
- A run is compatible only while tangent, grade, roll, component widths,
  lateral offsets, elevation, material, colour, and surface height are constant.
- Break at transitions, bus bays, marking/kerb stretches, junction/roundabout
  trims, structure boundaries that require sockets, or any explicit user cut.
- Curves remain error-tolerance segmented; never call a shallow curve
  "straight" merely to reduce Instances.
- Add a regression covering 2048, just below/above 2048, and a multi-part run
  longer than 4096 studs.

## P0 — lateral coalescing on straight runs (Drive phase shipped)

Adjacent lane/component surfaces may share one Part when their rendered surface
signature is identical:

- same material, colour, top/bottom height, longitudinal range, roll, and
  collision/query policy;
- no raised curb or physical gap between them;
- lane divider and edge markings remain separate marking geometry computed from
  the original profile, so merging asphalt never erases lane mathematics;
- retain source-component index/range metadata on the merged Part if any editor
  or diagnostic needs to map the geometry back to the cross-section.

The first target is adjacent Drive lanes with identical asphalt material and
colour on a straight section. Do not merge sidewalks, medians, shoulders, bike
lanes, parking, or differently styled lanes merely because they happen to look
similar in one theme; expand the compatibility table only with tests.

That first target is now implemented. Adjacent Drive components merge only on
the exact-straight fast path and only while their material, colour, height, and
exclusion state remain compatible. Lane markings still compute from the raw
component arrays. Every emitted surface carries its source component-index and
station range, while the road Model continues to store the complete serialized
curve and profiles used by reopen, rebuild, split, junction, marking, and
structure systems.

Headless baseline (surface Parts only, default 8-stud legacy segmentation): a
5000-stud 3+3 boulevard falls from 5625 surface Parts to 15 (99.73% fewer: five
lateral bands across three longitudinal ranges). `straight_optimization_preview.py`
covers just below/at/above 2048 studs, 4096+, forced edit boundaries, signature
mismatches, source metadata, and produces the before/after render. Studio build
time, GC, place-size, and live edit/reopen measurements remain required before
closing the wider measurement program.

## P0 — error-bounded curved and banked coalescing (phase 1 shipped)

Curves cannot use the exact-straight 2048-stud shortcut: a rigid Part cannot
follow a curved centreline, and a superelevation runoff is a twisting surface.
The optimization target is therefore fewer proven-compatible Parts, not a
visual guess that a shallow curve is straight.

The first curved/banked phase has these contracts:

- `Superelevation.BuildProfile` owns the canonical arc-length roll profile and
  `Superelevation.RollAtProfile` is the only interpolation path used by road
  surfaces, markings, and other geometry that must share the road bank. Sample
  density must not change the resulting smoothed roll curve.
- `RoadBuilder.StationPlanFor` returns the **final** stations and rolls used by
  emission, including any curvature and roll refinement. `RoadBuilder.Build`
  and the public station-query compatibility path must consume this same plan;
  callers must never receive the pre-runoff grid while the built road silently
  inserts more stations.
- On a constant-profile, non-transition curve, adjacent Drive components may
  form one surface band when their material, colour, surface height, collision
  policy, station range, and generated shape are compatible. Markings continue
  to use the untouched component boundaries, and emitted metadata retains the
  complete source-component range.
- A banked interval may merge laterally only while an explicit twist-error test
  keeps the candidate band's horizontal and vertical deviation within the
  configured surface tolerance. If that proof fails, the existing per-component
  triangle/wedge emitter is the authoritative fallback. Part-count pressure is
  never permission to bridge a median, raised component, physical gap, or
  differently styled surface.
- Models record whether curved and banked surface coalescing actually occurred,
  so benchmarks and Studio diagnostics can distinguish the optimized path from
  its conservative fallback.

This phase deliberately excludes `ProfileEnd` widening/narrowing transitions
and `BuildWithBay`/bay slices. Their moving offsets, zero-width matched
components, explicit cut ranges, and exact ownership caps need a separate error
model. They continue through the current segmented emitter until dedicated
coverage proves equivalent geometry.

Before enabling the optimized path, extend the Python visualizer with banked
curve plan, side, and cross-section cases. Report maximum plan/height deviation,
gaps, overlaps, surface/marking Part counts, and fallback decisions for shallow
curves, tight curves, S-curves, narrow/wide profiles, constant bank, and runoff.
The preview must consume the same final station-plan rules rather than certifying
an independently sampled approximation.

Phase 1 now implements those contracts. The headless six-lane boulevard cases
retain zero outer-edge displacement: a gentle curve falls from 990 to 550
surface Parts (44.4% fewer), while a six-degree bank runoff falls from 882 to
858 (2.7% fewer). The worst accepted bank-twist error is 0.0206 studs and the
worst constant-roll box overhang is 0.0209 studs, both below their 0.025-stud
limits; more aggressive intervals fall back to the per-component emitter.
Studio build-time, serialized-size, and live render measurements remain open
under **Measure first**.

## P1 — incremental rebuilds

- Rebuild only dirty station ranges after a local bay, marking, kerb, or corner
  edit instead of destroying and regenerating the complete road.
- Preserve unaffected structure modules and piers when their curve range and
  configuration are unchanged.
- Cache pure station frames, profile offsets, marking plans, and curve samples
  behind explicit curve/profile/settings signatures. Invalidate deliberately;
  avoid caches keyed only by mutable Model identity.

## P1 — preview reuse

- Pool or update placement-preview Parts instead of destroying and allocating
  the full preview every mouse movement.
- Use a coarser, measured visual-error tolerance for previews while keeping
  endpoint, snap, cross-section width, and elevation exact.
- Throttle work to one latest pending pointer state; discard superseded preview
  builds rather than completing them in order.

## P1 — structures and markings

- Apply the same straight-run coalescing to procedural slabs, walls, parapets,
  vault bands, and repeated markings where their geometry is actually constant.
- Keep tunnel/viaduct expansion joints, custom-asset sockets, pier stations, and
  portal/abutment boundaries as mandatory split points.
- Merge collinear solid marking spans with identical width/colour; preserve dash
  cadence and regional phase for dashed lines.

## P1 — roundabout mouth clipping

Solo one-way mouths now subtract the emitted roadway footprint from the ring
sidewalk so curb returns remain exact. This is deliberately correctness-first:
wide/highway mouths can fragment a small number of ring strips into hundreds
of triangles before `FillTriangle` converts them to Wedge Parts.

- Keep the shipped safe coalescer (shared full edge, convex union, conserved
  area) and benchmark its pair-search cost on wide and closely spaced mouths.
- Investigate an indexed shared-edge lookup instead of repeated all-pairs
  survivor scans.
- Investigate a lower-Part representation for the same exact clipped surface
  (for example a purpose-built mesh), with the current convex fragments as the
  authoritative fallback. It must not bridge disjoint curb returns or restore
  raised pavement over Drive, Shoulder, Bike, Parking, or Bay surfaces.
- Add Studio baselines for generated Part count and rebuild time on solo,
  one-way-highway, mixed-hand test fixtures, and custom Bay profiles.

## Candidates to investigate

These need profiling before implementation:

- broader-phase spatial lookup for nearby roads/junctions instead of repeated
  full-folder scans;
- dirty-junction queues so several road edits trigger one final rebuild;
- reduced attribute/JSON churn by writing only changed serialized fields;
- disabling unnecessary touch, collision, shadow, or query work on generated
  decorative structure Parts after checking tool raycast requirements;
- distance-based display simplification for very large networks, provided it
  does not alter saved authoritative geometry;
- parallelized pure geometry planning outside Instance creation if Roblox's
  execution model and determinism make it worthwhile.

- recognize and coalesce proven straight sub-runs inside a mixed straight/curve
  PolyCurve without weakening the exact-control-point proof or crossing curve
  segment/edit boundaries; phase 1 optimizes whole exact-straight builds.

## Acceptance gates

Every optimization needs:

1. before/after Instance count and build-time measurements;
2. Python coverage/gap renders for affected geometry;
3. parity tests for materials, colours, markings, and cross-section bounds;
4. split/edit/reopen/rebuild checks in Studio;
5. no Part dimension above 2048 studs;
6. a straightforward fallback to the existing segmented emitter for any case
   whose compatibility cannot be proven.
