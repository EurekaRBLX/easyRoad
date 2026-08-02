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

## P0 — straight-run longitudinal coalescing

A genuinely straight, constant cross-section run should use long Parts rather
than inheriting the normal curve station spacing.

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

## P0 — lateral coalescing on straight runs

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

## Acceptance gates

Every optimization needs:

1. before/after Instance count and build-time measurements;
2. Python coverage/gap renders for affected geometry;
3. parity tests for materials, colours, markings, and cross-section bounds;
4. split/edit/reopen/rebuild checks in Studio;
5. no Part dimension above 2048 studs;
6. a straightforward fallback to the existing segmented emitter for any case
   whose compatibility cannot be proven.
