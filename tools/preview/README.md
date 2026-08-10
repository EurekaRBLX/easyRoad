# Headless preview and validation

There is no Roblox Studio in this environment and no Luau runtime. This
directory is the only automated evidence the geometry works, and it is worth
being precise about what that evidence is: **these tools re-implement the
geometry in Python; they do not execute the plugin.** A green run says the
algorithm as ported produces sound geometry. It cannot say the Lua does.

Run everything:

```sh
python3 tools/preview/validate.py          # quick set, ~1-2 min
python3 tools/preview/validate.py --full   # every case, several minutes
python3 tools/preview/validate.py --list   # what would run
```

`validate.py` carries a `KNOWN_OPEN` table of (suite, case, check) triples that
fail on purpose, each with a reason. It fails on a **new** failure and also when
a known-open one starts **passing** - a stale expected-failure list is the same
trap as an invariant nobody re-reads.

## The pieces

| file | what it is |
|---|---|
| `preview_core.py` | The shared emission port: curve + cross-section to the rigid boxes RoadBuilder emits, one per (component, station interval). Geometry, `build_stations`, `emit_road`, `Part`, `point_in`, colours, region constants. Scenario-agnostic. |
| `roundabout_preview.py` | Ring, arms, mouths, splitter islands, turbo markings, and the scans that only mean anything on a roundabout. |
| `roundabout_editor_preview.py` | Before/after bird's-eye editor showcase for a connected UK roundabout. Reuses `roundabout_preview.py` directly so adjustable radius, lane count/width, appearance toggles, mouths, and markings are rendered by the canonical component pipeline. |
| `road_preview.py` | An ordinary road on its own - straights, arcs down to R=30, an S-curve, avenues, motorways. Bare ground inside the road, edge sawtooth, broken edge lines. |
| `straight_optimization_preview.py` | Exact-straight 2048-stud splitting, explicit stretch breakpoints, conservative Drive-only lateral merging, source-range metadata contracts, and a before/after surface-Part render. |
| `curved_superelevation_optimization_preview.py` | Feasibility and regression harness for conservative Drive-band merging on curves and bank runoff. Ports the density-independent roll profile (including short-curve runoff controls), roll-aware station refinement, per-interval 0.025-stud twist and curved-box overhang budgets, exact outer-edge parity, actual midpoint-box plan footprints, injected break-tests, Part counts, and a combined bird's-eye/side/cross-section render. |
| `structure_preview.py` | Rigid imported-module socket stepping, procedural viaduct elevation, single/twin pier and cap geometry, independent finish channels, and arched tunnel cross-section; check-only or one combined PNG. |
| `ground_asset_preview.py` | Source-linked custom Ground asset contract: strict/recoverable socket validation, safe procedural-surface replacement ordering, shared rigid repeat-to-fit coverage, injected failures, and a combined plan/cross-section PNG. |
| `parallel_preview.py` | Curved parallel-carriageway offset/refit, an opposed pair, and independent direction choices for larger groups. |
| `transition_anchor_preview.py` | Bird's-eye one-way 3-to-4 and 4-to-3 transition datum contract. Shows Centre / Left edge / Right edge side by side, checks the selected reference remains numerically fixed throughout the smoothstep taper and into a chained constant-width segment, verifies legacy offsets default to zero, and includes twelve injected break-tests. |
| `cross_section_connection_preview.py` | Bird's-eye connection-mode contract across left / centre / right snap references. Contrasts the default split-and-build-junction workflow with target-preserving tangential lead-ins, covers distance-ranked endpoint/mid-span selection, parallel carriageway anchoring, carried/transition profile-offset alignment, live preview refresh, and feature-bearing targets, and includes 26 injected break-tests. |
| `setup_wizard_preview.py` | Source-linked first-run setup QA: representative Welcome, Units, and Enjoy screens, the actual six-step progress fractions, easyRoad's theme accent, full-host sizing, unit choices, and five injected break-tests. |
| `regional_marking_preview.py` | Bird's-eye US/UK marking-colour contract: yellow US opposing-flow centre and divided-carriageway traffic-left edges, white same-direction/traffic-right lines, global highway `NoLine` suppression for UK median edges, exactly one yellow line at a one-way highway's Drive/inner-shoulder boundary, and direction-stable 2x2↔3x3 yellow-edge mapping. The bottom US panel also shows an explicit local `NoLine` span. Includes nine injected semantic break-tests. |
| `hardware_reference_check.py` | Parses the five `hardware/*.rbxmx` references and verifies their deck/base, parapet/wall, and tunnel-crown cues. |
| `junction_pad_preview.py`, `corner_preview.py` | Junction pad and curb-return shapes. Not yet wired into `validate.py`. |
| `turbo_check.py`, `road_break_tests.py`, `structure_break_tests.py` | Break-tests: reintroduce a defect and confirm the relevant scan catches it. |
| `roundabout_parity_contract.py` | Static plus geometry contract for per-offset arm-line clipping, mouth-boundary ownership, and non-coplanar Turbo overlay; includes five break-tests. |
| `check_parity.py` | Constants shared with the Lua. Constants only. |
| `dump_compare.py` | Diffs a live plugin dump against this port. |
| `raster.py` | Stdlib-only PNG writer. |

`preview_core.py` was split out of `roundabout_preview.py`, which used to be the
whole tool. The emission port was always generic, so a road scenario cost a file
rather than a rewrite.

## Adding a scenario

Import from `preview_core`, build a parts list, write scans that ask questions
your scenario can actually answer - then **write a break-test before believing
any of them**. Every scan in `road_preview.py` passed every case the first time
it ran, and two were measuring nothing:

- the sawtooth scan compared adjacent samples, but a strip boundary is a single
  jump with flat runs either side, so every jump was measured against a zero and
  no sign change was ever seen;
- its threshold was then a fixed 0.1 studs, which the clean road's own miter
  breathing exceeded. It is now 1% of the road's own width, because the
  legitimate jitter scales with the road: 0.121 studs on a 40-stud road, 0.233
  on an 85-stud one - 0.30% and 0.27%.

Three rules in `check_turbo` died the same way. See ROUNDABOUT.md section 6.

## Simulating the emission

Every other check in this repo works on idealised geometry - centrelines and
offset polygons. Roblox never sees those. It sees rigid boxes, one per
(component, station interval), each a rotated rectangle approximating an arc.
Facets, sliver gaps and z-fighting only exist at that level, so an idealised
render cannot show them. This tool ports the emission path directly:

| ported from | what |
| --- | --- |
| `RoadBuilder.buildStations` | adaptive stepping, incl. the offset-edge curvature term |
| `RoadBuilder` deck-strip branch | `Size = (width, h, nominalLength + padding)`, `CFrame = midFrame * CFrame.new(centerOffset, y, 0)` |
| `RoadBuilder.curveMiterPad` | `padding = |edgeDistance| * curvature * nominalLength + 0.08` |
| `RoadBuilder.placeMarkingSpan` | endpoints anchored to true curve positions |
| `RoundaboutBuilder` | ring, split arms, splitter island, mouth sector opening |

## Running one scenario directly

```sh
cd tools/preview
python3 roundabout_preview.py             # uk4 uk3 us4
python3 roundabout_preview.py uk5mini     # a named case
python3 roundabout_preview.py --no-render # scan only
python3 roundabout_editor_preview.py --check
python3 roundabout_editor_preview.py --out out/roundabout-editor
python3 road_preview.py --render          # every road case, with PNGs
python3 turbo_check.py                    # turbo peel + its break-tests
python3 road_break_tests.py               # road scans + their break-tests
python3 straight_optimization_preview.py --check
python3 straight_optimization_preview.py --out out/straight-optimization.png
python3 curved_superelevation_optimization_preview.py --check
python3 curved_superelevation_optimization_preview.py --out out/curved-bank.png
python3 structure_preview.py --check      # module coverage + pier contact
python3 ground_asset_preview.py --check   # Ground import, sockets + replacement ownership
python3 parallel_preview.py --check       # curved offsets + direction layouts
python3 transition_anchor_preview.py --check
python3 transition_anchor_preview.py --out out/transition-anchors.png
python3 cross_section_connection_preview.py --check
python3 cross_section_connection_preview.py --out out/cross-section-connections.png
python3 setup_wizard_preview.py --check
python3 setup_wizard_preview.py --out out/setup-wizard.png
python3 regional_marking_preview.py --check
python3 regional_marking_preview.py --out out/regional-marking-colours.png
python3 structure_break_tests.py          # prove gaps/hovering piers fail
python3 hardware_reference_check.py       # inspect rbxmx structural references
python3 structure_preview.py --out out/structures.png
python3 ground_asset_preview.py --out out/ground-road-assets.png
python3 parallel_preview.py --out out/parallel-roadways.png
```

Exits non-zero if any case has visible bare ground, so it works as a check.
Stdlib only - no numpy, no Pillow; `raster.py` writes PNGs with `zlib`.

## Output

Two views per case, in `out/` (gitignored):

- `<case>_parts.png` - every emitted part in its material colour, which is
  roughly what Studio will show.
- `<case>_gaps.png` - **magenta is bare ground.** Anything magenta inside the
  ring footprint is a hole no part covers.

It also measures the **approach/arm seam**: it sweeps the road's own
perpendicular either side of the cut and compares how far the covered material
reaches on each side. A non-zero step is the pavement or kerb line jogging
sideways where the road meets the mouth. Sizing the arms from their own
half-width plus a splitter (rather than from the approach's roadway edges)
scores 1.80 studs stepped; aligned, 0.00.

The bare-ground scan samples the ring footprint on a polar grid and clusters whatever it
finds by angle, reporting each cluster's depth in studs. Clusters shallower
than `--hairline` (default 0.15 studs) are reported but do not fail: the ring's
innermost strips are chords of the island circle, so their inner edge stands
off it by about 0.05 studs at default settings, and no padding removes that
without overlapping the island instead.

## Parity with the Lua

`roundabout_preview.py` is a hand-written Python **re-implementation** of
`RoundaboutBuilder.lua`, not an execution of it. Nothing keeps the two in sync,
so a constant tuned on one side and forgotten on the other lets the preview
quietly certify geometry the plugin never builds.

```sh
python3 check_parity.py     # exits non-zero on drift
```

It compares every constant present on both sides and flags orphans, so renames
and deletions surface. It does **not** compare the algorithm - two
implementations can agree on every number and still do different things with
them. Run it alongside `roundabout_preview.py` after touching either file.

## Behavioural comparison (`dump_compare.py`)

`check_parity.py` compares constants. This compares what the two
implementations actually *do*, which is the part that matters.

1. In Studio, select the junction, set Radius / Lanes / Lane width, press
   **Print geometry to Output**. That calls
   `RoundaboutBuilder.DescribeJunction`, which reuses `planMouth`,
   `splitBudgetFor` and `resolveSplits` - the same functions the real build
   calls - and does not modify anything.
2. Run the preview side with the same inputs:

   ```sh
   python3 dump_compare.py --radius 30 --lanes 1 --legs 0,90,180,270
   ```

3. Diff. Same field order and precision on both sides, so plain `diff` works.

A mismatch is a real divergence and preview results cannot be trusted until it
is explained. A match means the difference between preview renders and Studio
is the RENDERER - idealised polygons versus rigid parts - and not the geometry.

Known caveat: the preview's legs are radial, so its mouth angle is simply the
leg bearing. The plugin aims along the approach's own centreline
(`rayCircleFirstHit`), which only coincides for radial approaches. Expect
`mouthAngle` to differ for legs that do not point at the centre - which is
common for roads produced by an X-split.

## What a green run does NOT cover

- Nothing executes in Roblox. A nil identifier, a Luau error, or the Lua
  diverging from this port are all invisible here.
- Mostly Part **footprints in plan**. The roundabout parity contract models the
  two explicit marking top planes, but general heights, render order, dash phase
  and z-fighting still require a live check.
- `transition_anchor_preview.py` deliberately ports only the cross-section datum
  translation: Centre remains at zero, Left edge remains at the source left
  coordinate, or Right edge remains at the source right coordinate. It checks
  both one-way 3-to-4 widening and 4-to-3 narrowing, then carries the resulting
  profile-centre offset into a constant-width continuation and requires both
  edges and the centre to meet with zero join error. General emitted transition
  strips, `MatchForTransition` topology, and bus bays (`BuildWithBay`) are not
  ported, so this does not certify their Part-level seams.
- `curved_superelevation_optimization_preview.py` is deliberately narrower than
  a general 3D road port: it models an exact circular centreline with a
  station-defined bank runoff and the current two-triangle top-surface
  construction. It proves each greedy lateral merge stays inside the builder's
  0.025-stud bank-twist bound and, for constant roll, the 0.025-stud extra
  midpoint-box plan-overhang bound. Its bird's-eye panels draw the actual
  curvature-padded midpoint boxes rather than ideal station-edge quads. It does
  not certify arbitrary Bezier grade, Roblox Wedge render order, collision, or a
  lane-width transition.
- `Markings.lua` is not ported - `emit_road` approximates it in ~30 lines, so a
  wrong marking is largely invisible, and `scan_mouths` counts a marking Part as
  coverage.
