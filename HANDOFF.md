# EasyRoad — handoff

Read this first. `ROUNDABOUT.md` is the deep dive on the roundabout (the most
expensive part of this project), `TODO.md` is the live feature backlog,
`OPTIMIZATION.md` the measured performance plan, `SHIPPED.md` the chronological
history, and `KNOWN_ISSUES.md` confirmed bugs.

---

## Ground rules for this repo

- Work directly on `main`. Rebuild `dist/EasyRoad.rbxmx` with
  `python3 tools/build_rbxmx.py` **in the same commit** as any `src/` change —
  the user installs that file, so a stale dist means they test old code.
- `stylua --verify src/<file>` then `stylua --check src/<file>` before
  committing. `.stylua.toml` pins Luau/tabs/LF and `.gitattributes` keeps those
  bytes consistent on native Windows, WSL, and Linux. The repo is not globally
  stylua-clean under the installed version; only keep touched files clean.
  (`src/Mesh/FillTriangle.lua` has a pre-existing diff — leave it.)
- Commit trailer, exactly:
  `Co-Authored-By: Gameson <79436209+gamesonrblx@users.noreply.github.com>`
  No `Claude-Session:` trailer, no model identifier anywhere in commits, PRs,
  code or artifacts.
- Log every round in `SHIPPED.md` (newest at top) and update `TODO.md`.
- Push with `git push -u origin main`, retry up to 4× with backoff.

---

## THE standing hazard: no Luau runtime or typechecker

`stylua` proves a file **parses**. Nothing proves an identifier exists. This has
already shipped one live crash (`ringComponents` referencing a nil global, so
every `Make Roundabout` threw on its first line) and produced three more
near-misses in a single session:

- `RegionStyles.RoundaboutMarkingStyles = ...` written ~300 lines **above**
  `local RegionStyles = {}`.
- A `RegionStyles.X` type reference added to `JunctionInstance.lua`, which does
  not require `RegionStyles` at all.
- `Components.Checkbox` given `Value`/`OnChanged` when it takes
  `Label`/`Checked`/`OnToggled`.

**So: after every edit, check that each new identifier is defined above its
first use, and that the module it comes from is actually required in that
file.** A one-off Python regex over the file is enough and takes seconds. Two
helpers had to be physically moved (`DOWN`, `angleDelta`) when `buildIsland`
grew to need them.

Closing this properly is the highest-value unbuilt item in `TODO.md`. Checked,
not assumed: GitHub and npm are blocked here (403) so `luau-analyze` cannot be
fetched, but crates.io is reachable and `full_moon` (the Luau parser stylua
itself uses) would do it. It needs SCOPE awareness — the name in that crash was
a real parameter of a different function in the same file.

---

## Current state

### Selectable roadway snap reference - built, needs live confirmation

Road Tools exposes **Snap point** whenever road snapping is enabled: Road
centreline, Left roadway edge, or Right roadway edge. The persistent
`Settings.SnapReference` default is Centre. Left/right are the target road's
stored start-to-end profile orientation and use the actual roadway limits (so
outer pavements/medians are not mistaken for carriageway).

`createRoadSession` stores a `SnapMatch` for every magnetic click. Its visible
position may be laterally shifted in the target road's banked frame, but its
Road/Station/RoadEnd and centreline topology position remain separate. Commit
uses that identity directly: mid-span snaps split the target at the original
centreline station and endpoint snaps connect to the original road end. This
avoids proximity rediscovery silently missing an edge farther than the snap
radius from centre. `JunctionBuilder.isSmoothPassThrough` also requires both
centreline endpoints to coincide with the node, so a laterally offset road
cannot incorrectly suppress the required junction pad. Live-check all three
choices on a banked curve and a wide divided road. Widening/narrowing roads
remain endpoint-only snap targets because `RoadSplit.CanSplit` deliberately
rejects their mid-span split; their start and end references use ProfileStart
and ProfileEnd respectively.

### Exact-straight road surfaces — built, needs live performance confirmation

`RoadBuilder` now proves a whole curve is monotonic and exactly collinear from
its raw control points before replacing the normal adaptive stations with
up-to-2048-stud ranges. It keeps marking/kerb-stretch endpoints as split points,
merges only adjacent identical Drive surfaces, and stamps each output surface
with source component/station ranges. The complete curve/profile metadata stays
on the road Model and remains authoritative for editing, rebuilds, junctions,
markings, and structures; no consumer maps behavior from generated Part
granularity. Curves, transitions, and sliced bay builds explicitly fall back.

Run `tools/preview/straight_optimization_preview.py --check` for boundary and
metadata contracts or render its before/after view. Its 5000-stud 3+3 baseline
is 5625 -> 15 surface Parts. Still do a live Studio build/reopen/edit/split test
and record timings/serialized-place size before treating headless count savings
as a complete performance benchmark. Mixed straight sub-runs inside one curved
PolyCurve remain an `OPTIMIZATION.md` follow-up.

### Multinode junction editing - built, unconfirmed live

One logical junction now derives stable approach ids from persistent road-end
port ids and stable corner ids from adjacent approach pairs. Road splits retain
the original outer port ids. The viewport's cyan corner
handles are selectable; the React-Lua junction panel can link every radius or
store an independent override for the selected corner. Old junctions default to
linked mode. `tools/preview/multinode_junction_preview.py --check` validates the
identity/radius contract, triangulated pad, and full component-width mouth
seams. Its `uk6x4` bird's-eye QA case uses the same `preview_core` Parts emitter,
UK component dimensions/directions, and `*_parts.png` / `*_gaps.png` convention
as the roundabout preview; it is no longer a US-styled schematic. The additional
`*_controls.png` render traces and labels the actual curb returns, and repeatable
`--radius "CORNER=METRES"` arguments demonstrate independent overrides. This is
the foundation for per-approach stop/crossing/signal controls; those markings
are still open.

The first live selection attempt exposed a panel-mount crash rather than a
selection failure: `packingRadiusStuds` omitted `armProfileFor`'s required
ring-pavement-width argument, producing a nil component width inside
`RoadProfile.TotalWidthM`. It now passes `ringSidewalkWidthM(style)`, and the
optional roundabout-radius advisor is guarded so it cannot hide the whole
junction editor again. Reinstall the freshly rebuilt dist before retesting.

### Junctions — fixed, unconfirmed live
The self-intersecting spiked pad and the faceted seam are both fixed.
`cornerBoundaries` was aiming its edge directions along `+outward` on any span
wider than 180°, so `Fillet.Compute` correctly rejected every one and the
Hermite fallback looped the boundary across the pad interior. The pad is now
ear-clipped (not centroid-fanned, which is invalid on the concave shapes a real
pad has) with a convex-hull fallback, and wide gaps carry the kerb line through
instead of chording. Regression test: `tools/preview/junction_pad_preview.py`,
66 cases, all filling exactly once over.

### Roundabout — see ROUNDABOUT.md
The mouth indentation, radius inflation, island/ring gaps, and splitter
regressions are fixed headlessly. Generated rings and arms now use the Python
preview's dedicated white edge/divider marking plan rather than ordinary-road
defaults. Constant-width arm pavement keeps its ring overlap but replaces the
raised approach-cut cap with exact station-edge triangles; tapering arms retain
their full exact surface chain. A later Studio check found the remaining wedges
and extra strokes at the ring opening itself: centre-only sector removal kept
boundary-straddling sidewalk/outer-line corners. Those Parts are now clipped at
the exact sector ray, retaining the outside fragment so sparse rings do not gain
holes. The Python port models and rejects boundary intrusion. Reinstall the
rebuilt dist and compare a UK 2-lane ring side-by-side before closing live visual
parity.

The next live comparison found the remaining Luau-only lines were sunk arm
markings protruding through ring ownership, not a different marking grammar.
Arm lines now stop at a per-offset kerb crossing, and Turbo's peel has a small
deterministic layer gap above the retained concentric divider. Run
`tools/preview/roundabout_parity_contract.py`: it covers entry/exit bounds,
mouth fragments, Turbo layer ownership, both traffic hands, and five break-tests.

Roundabouts are now selectable and editable after creation. A connected ring
retains a `Kind = Roundabout` Junction controller; its road ends keep that
controller id, while the ring remains the stable visible Selection owner.
`RoundaboutEditSession` + `RoundaboutPanel` edit geometry/appearance and rebuild
the ring in place. Rebuild uses exact `ConnectedRoads`, never proximity. Source
curves let the controller-side trim grow/shrink without replacing road/port ids
or raw road attributes. Connected rings can convert back to ordinary multinode
junctions. Old connected rings remain read-only because their original road
sources cannot be recovered safely; recreate them once to opt into the editor.

Run `tools/preview/roundabout_editor_preview.py --check`, or pass `--out` for
before/after bird's-eye PNGs generated through the existing roundabout pipeline.

### Nothing has been confirmed in Studio
Every result in these docs is headless. The user's screenshots are the
authority, and they have repeatedly shown defects the tooling passed.

### Structures - placement/management workflow built, unconfirmed live
`STRUCTURES.md` is the contract. The top-level Road Assets surface imports and
manages Workspace Models in `ServerStorage/EasyRoadAssets`; Road Tools and the
Road Inspector only select/configure them. Custom Models tile as viaduct/tunnel
modules. No-asset viaducts generate a slab, parapets, and downward-raycast
piers; no-asset tunnels generate a base, walls, and segmented arched vault. Structure data
survives all known road rebuild paths. Tunnel Terrain excavation, special
portal/abutment modules, custom pier assets, and in-place asset replacement are
still open. The Python render/checks are `tools/preview/structure_preview.py`
and `tools/preview/hardware_reference_check.py`.

The latest follow-up adds independent material/colour channels for the
structural base/piers, viaduct edge walls, tunnel sidewalls, and tunnel roof,
plus interface overlap, parapet/tunnel clearance, outside-edge longitudinal
coverage, and base-matched viaduct medians. Detailed structure settings are
collapsed in Road Tools; Settings holds the defaults for new roads. Imported
Models keep their own appearance. Viaduct supports can be a single adjustable
pillar or an atomic twin-column bent with independently raycast feet and a
configurable transverse cap beam. Old serialized roads migrate to the original
grey Concrete and Single layout. Validate both paths with
`tools/preview/structure_preview.py --check`.
Parallel placement builds 2-16 offset PolyCurves with opposed-pair or per-road
direction choices. It does not yet synthesize coordinated parallel junctions;
straight primaries retain the ordinary single-road crossing path, while a
curved six-segment offset is shown as blocked at crossings. One-way presets cover 1-5
lanes with shoulders. The Road Editor/placed-road designer is 440 pixels tall
so its upper property/library columns no longer overflow the lane strip.
Validate the curved offset port with `tools/preview/parallel_preview.py`.

### Marking boundaries - centre line and Road Editor path built, unconfirmed live

`RightBoundary` remains serialized once on the component to the physical
boundary's left, but the UI no longer exposes it as a lane-owned field. **Show
lane markings** inserts selectors between adjacent Drive lane tiles and opens a
boundary editor naming both lanes. `Markings.IsEditableLaneBoundary` includes
the opposing-direction centre line; `RoadEditSession` hit-testing and
`Markings.Compute` both use that contract, so a centre line can receive an
explicit profile rule or a longitudinal marking stretch. In **All** mode the
centre line is its own group rather than leaking into either direction's lane
siblings. Reinstall the rebuilt dist and live-check a 3+3 bidirectional road.
`tools/preview/marking_boundary_preview.py` renders that case with the selected
centre stretch in amber and runs its grouping assertions in the validator.

---

## How to actually make progress here

The pattern that works, learned the hard way over many wasted rounds:

1. **Reproduce headlessly before fixing.** The junction zigzag survived three
   rounds of guessing and fell in one session once `junction_pad_preview.py`
   could reproduce it. Same for the R-band.
2. **Measure, don't eyeball a screenshot.** Diagnosing from images produced a
   repro of the wrong bug once, and two wrong root-cause hypotheses that probes
   disproved outright (`openRingPavement` deleting by centre; `convexHull`
   being the zigzag's cause).
3. **Check what the tool does NOT cover before trusting a pass.** Every "clean"
   this repo's preview printed for a long time was about a region that was
   already fine — see the table in `ROUNDABOUT.md` §6.
4. **Wait for the full run.** Twice in one session a conclusion was drawn from
   partial output while the complete sweep was still running.

---

## tools/preview

Python, stdlib only (its own PNG rasteriser). Simulates the **parts
`RoadBuilder` actually emits** — rigid boxes per station interval, not
idealised polygons.

```sh
cd tools/preview
python3 roundabout_preview.py                 # uk4 uk3 us4, WITH renders
python3 roundabout_preview.py --no-render     # numbers only
python3 multinode_junction_preview.py uk6x4 --out out  # UK 3+3 x 2+2 junction
python3 multinode_junction_preview.py uk6x4 --radius "A1>A2=18" --out out
python3 multinode_junction_preview.py --check # component seams/topology only
python3 junction_pad_preview.py               # junction regression, 66 cases
python3 junction_pad_preview.py --legacy      # show the pre-fix behaviour
python3 check_parity.py                       # constants shared with the Lua
```

**Renders are on by default** — `out/*_parts.png` and `out/*_gaps.png`, where
**magenta is bare ground**. Do not habitually pass `--no-render`; the images are
the fastest way to see what a change did, and the user will ask for them.

Ad-hoc probing:

```python
import roundabout_preview as P
legs = [(b, P.two_way(1, 1, True)) for b in (0, 120, 240)]
sc = P.build(35.0, 1, legs, True, "probe",
             grow=False, sidewalk=True, island=True, turbo=False)
holes, pitch = P.scan_gaps(sc)      # ring annulus
findings     = P.scan_mouths(sc)    # mouths: holes AND overhang
P.render(sc, "out")
```

Its limits are written down in `ROUNDABOUT.md` §6 and matter — in particular
`check_parity.py` compares **constants, not behaviour**, and two behaviour
divergences slipped past it in one session.

---

## Reference sources

`reference/` is vendored read-only material, outside `src/` and not built:
RoadCreator (Unity C#, MIT, pinned commit, `reference/roadcreator/README.md`)
and a Lua road helper. Its algorithms may be translated with attribution.

`src/Geometry/BezierCorner.lua` is a translation of that C# and is currently
**unused** — nothing imports it, though it does ship in the built plugin. Either
wire it in or delete it; it is a bounded-by-construction corner primitive, which
is a stronger guarantee than the `chordExcursion` guard now used instead.

---

## Immediate next steps, in order

1. **Reinstall `dist/EasyRoad.rbxmx` and look.** Confirm the highway shoulder
   and pavement taper, its solid separator, mouth apron, junction pad, and turbo markings in Studio; all are
   headlessly clean but the renderer cannot catch height or z-fighting issues.
2. **Intersection controls and crossings.** Add stop/give-way markings,
   pedestrian/cycle crossings, and a Commonwealth zig-zag toggle. Define the
   basic EasyRoad signal socket/controller plus optional EasyLight extension
   contract before coupling any traffic-light UI to geometry.
3. **Live-check the new structure workflow.** Use Road Assets to import both
   explicit-socket and automatic-socket Models, then exercise
   curves, elevated Terrain raycasts, Apply/Revert, split, and junction trims.
4. **Static identifier checking.** Still the highest-value safety tool before a
   large new system; no Luau runtime currently checks undefined identifiers.
5. **Ordinary RoadBuilder highway transitions.** The roundabout arm is fixed,
   but highway-to-parkway/avenue/street width transitions remain untraced.
