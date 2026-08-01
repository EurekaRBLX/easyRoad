# EasyRoad — handoff

Read this first. `ROUNDABOUT.md` is the deep dive on the roundabout (the most
expensive part of this project), `TODO.md` is the live backlog, `SHIPPED.md` the
chronological history, `KNOWN_ISSUES.md` confirmed bugs.

---

## Ground rules for this repo

- Work directly on `main`. Rebuild `dist/EasyRoad.rbxmx` with
  `python3 tools/build_rbxmx.py` **in the same commit** as any `src/` change —
  the user installs that file, so a stale dist means they test old code.
- `stylua src/<file>` then `stylua --check` before committing. The repo is not
  globally stylua-clean under the installed version; only keep touched files
  clean. (`src/Mesh/FillTriangle.lua` has a pre-existing diff — leave it.)
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
Fixed this session: the R=34–36 bare-ground band (an own-goal regression), the
centre island's polygon mismatch, approach detection, roads passing beside the
ring, the forced radius minimum, and the splitter running down the approach.
Added: optional pavement, optional island, Continuous/SolidLanes markings.

**Still open, highest priority: the mouth INDENTATION** — the V-notch down each
approach. It has now been through three wrong states because raised-or-nothing
is a false choice; near the cut that wedge is carriageway, not median. Full
analysis and the two-fill design in `ROUNDABOUT.md` §5.3d.

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

The latest follow-up adds configurable concrete colour, interface overlap,
parapet/tunnel clearance, outside-edge longitudinal coverage, and concrete
viaduct medians. Detailed structure settings are collapsed in Road Tools.
Parallel placement builds 2-16 offset PolyCurves with opposed-pair or per-road
direction choices. It does not yet synthesize coordinated parallel junctions;
straight primaries retain the ordinary single-road crossing path, while a
curved six-segment offset is shown as blocked at crossings. One-way presets cover 1-5
lanes with shoulders. The Road Editor/placed-road designer is 440 pixels tall
so its upper property/library columns no longer overflow the lane strip.
Validate the curved offset port with `tools/preview/parallel_preview.py`.

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
