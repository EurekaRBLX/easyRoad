# EasyRoad — To Do (New Features)

> **Working on the roundabout? Read `ROUNDABOUT.md` first.** It carries the
> vision, the settled decisions that must not be re-litigated blind, the
> defects already paid for, and what each preview check is blind to.

Planned/requested work not yet built, roughly ordered by how developed the
plan is. Not user-facing; internal planning only. See `SHIPPED.md` for
what's already built and `KNOWN_ISSUES.md` for confirmed bugs.

## Road Editor marking-selector overflow + data backup/restore — SHIPPED

The bottom boundary editor is width-contained, opens upward, and scrolls
through all options. Settings > Backups now exports/imports versioned JSON for
plugin preferences and custom road/region presets with validation and explicit
confirmation, in its own dock rather than Regional Preference. See
`SHIPPED.md`; placed-road/world backup remains correctly owned by the place.

Performance work is tracked separately in `OPTIMIZATION.md`. The first exact-
straight phase (2048-stud longitudinal Parts plus identical adjacent Drive-lane
surface merging) is shipped; mixed straight/curve sub-runs, Studio benchmarks,
and the P1 incremental/preview/structure work remain open there.

Cross-platform StyLua parsing/formatting is configured and is no longer a
tooling blocker; a real Luau scope/type checker remains open infrastructure.

## Next major system - intersection controls, crossings, and signals

The geometry can create and trim ordinary intersections, but it does not yet
communicate who stops or where vulnerable road users cross. Build these as
junction-owned controls, not decorations guessed independently by every road:

The multinode foundation is now shipped: one logical junction owns stable
road-end approach ids and angular-neighbour corner ids, with linked or
per-corner curb radii in the editor. Reuse those approach ids for the controls
below rather than inventing a second indexing scheme.

1. **Approach control markings.** Per approach: None, Stop, Give Way/Yield.
   Generate the transverse line at the trimmed mouth and expose its setback,
   width, colour, and regional defaults. Stop text/triangles can follow after
   the line geometry is reliable.
2. **Pedestrian and cycle crossings.** Per approach: None, Zebra, Parallel
   cycle, Combined, and signal-controlled. Keep pedestrian and bicycle bands
   separately addressable even when they render as one crossing so later
   traffic logic has meaningful conflict zones.
3. **Commonwealth zig-zag toggle.** A per-crossing switch with a regional
   default. It must be a marking generator leading into the crossing, not fake
   extra lanes; left/right handedness and approach direction choose the mirrored
   pattern.
4. **Modular traffic lights.** EasyRoad core owns stable signal sockets,
   approach/crossing IDs, a basic head/controller, and serialized phase data.
   `EasyLight` is an optional second plugin that discovers those attributes and
   replaces or augments the controller/UI. EasyRoad must never require
   EasyLight to open or rebuild a junction, and unknown EasyLight attributes
   must survive an EasyRoad rebuild.

### Traffic-hand and regional-marking prerequisites

The current roundabout geometry already derives circulation direction,
entry/exit ownership, roadside placement, and Turbo peel direction from
`RegionStyle.DriveOnLeft`. Preserve that role-based foundation: future code
must ask for traffic-inboard/outboard and entry/exit, never assume that raw
world-left/world-right has one fixed meaning. Before the control-marking work
above is considered region-compatible:

1. **Contract-protect signed LHT/RHT behaviour.** Add geometrically reflected
   fixture pairs with identical topology for both traffic hands. Assert signed
   Turbo angular travel, entry/exit ownership, and outboard-side selection --
   not only whether a peel eventually lands on an exit line. Negative tests
   must catch independently flipped Turbo `travel`, mouth `flow`, and outboard
   selection. Exercise junctions attached at both the start and end of a road;
   the Python preview currently models only the far-end branch.
2. **Make roundabout marking grammar regional data.** The current Turbo peel
   uses one fixed white 4 m mark / 2 m gap pattern. Move Turbo dash/gap, line
   type, width, colour, peel/setback rules, and future stop/give-way/crossing
   defaults into the region or a dedicated `RoundaboutMarkingStandard`. Keep
   per-roundabout overrides without losing the regional default.
3. **~~Resolve traffic hand once.~~ SHIPPED.** Quick Setup and Regional
   Preference now resolve Region/Left/Right into the effective cloned style
   consumed by the builders. Keep future renderers on that effective style;
   do not read the raw region default and silently ignore the override.
4. **Respect the global marking switch.** Turbo peels must obey
   `settings.AutoMarkings`, just like RoadBuilder's ordinary markings, and the
   preview needs an AutoMarkings-off regression.
5. **Persist entry-side control geometry.** Add a stable approach/entry trace
   keyed by the existing road-end approach ID. Stop/give-way lines,
   pedestrian/cycle crossings, Commonwealth zig-zags, arrows, and later signal
   sockets should all consume that same hand-aware trace. Turbo destination
   guidance should eventually map entry lanes to circulating lanes and exit
   approach IDs rather than remain decorative geometry only.

Before UI work, document the serialized junction-control schema and the public
socket/attribute contract EasyLight can depend on. Then render stop/crossing
markings in the Python junction preview and add break-tests for approach-side
mirroring, line setback, and zig-zag clipping.

## Model-backed ground roads and procedural/custom structures - WORKFLOW SHIPPED

The selected-Model ownership and rigid-module path now exists; see
`STRUCTURES.md` and `SHIPPED.md`. A Workspace Model is copied into
`ServerStorage/EasyRoadAssets`, explicit `EasyRoadStart` / `EasyRoadEnd`
Attachments define its socket chord (or the importer creates bounding-box
sockets), and the dedicated Road Assets surface imports, lists, renames, and
deletes unused assets. Ground assets now replace the ordinary generated surface
only after their rigid modules build successfully; the editable profile remains
their topology/snapping envelope. Road Tools exposes road/structure selection
before placement. Every committed road serializes it immediately. Viaduct mode
generates a structural slab and parapets, tiles an optional custom model, and
raycasts generic concrete piers down to Terrain/world parts. Tunnel mode tiles
an optional custom model or generates a base, sidewalls, and segmented arched vault without
destructively editing Terrain. Road edits, bus bays, junction trimming, and
roundabout trimming regenerate structures. Automatic splitting is currently
blocked on structured roads so rigid modules and piers cannot restart their
spacing phase independently on each piece.

Follow-ups still open:

- start/middle/end modules for portals, abutments, and expansion joints;
- user-provided pier models and explicit pier socket Attachments;
- turn/grade warnings for a rigid module that is too long for the curve;
- a persisted longitudinal structure phase so structured roads can be split
  without restarting rigid modules or duplicating pier stations;
- replace/update-in-place for an existing game-owned asset;
- an explicit undoable Terrain excavation/restoration phase for tunnels;
- live Studio validation of selection UX, sockets, collisions, and raycasts.

Completed in the current follow-up: procedural road/structure seating overlap,
surface-safe thin bases with downward-compensated edge walls, outside-edge
segment coverage, independent material/colour controls for the base, viaduct
walls, tunnel sidewalls, and tunnel roof, parapet/tunnel gap controls, a
base-matched elevated-median toggle, collapsed advanced structure controls,
and single/twin raycast piers with editable column and cap-beam dimensions.
Parallel placement supports 2-16 curved carriageways, opposed pairs, and
per-roadway reversal for larger groups. Parallel groups do not yet
synthesize coordinated junction splits/connections automatically; a straight
primary can still use the ordinary single-road crossing path.
## Roundabout split entry/exit arms — SHIPPED (see SHIPPED.md)

Superseded the asymmetric-mouth-corner build, which in turn superseded the
reverted centreline-swing attempt kept below as history. Deflection now lives
in where the entry arm merges, not in corner fillets.

### Follow-ups left open

- **Crowded rings.** With 5+ legs, or wide approaches on a ~40-stud radius, the
  split gets squeezed until an entry and its own exit run up against each other
  partway along and the splitter island gives out. Nothing overlaps or spikes,
  but the mouth reads as one wide opening. Real fix is to auto-size the minimum
  ring radius from the entry width and leg count (see below) and warn when the
  requested radius can't carry them.
- **Give-way / yield markings** across each entry arm at the merge, and the
  circulating-lane arrows. The arms are ordinary one-way roads, so this is a
  Markings.lua job, not a geometry one.
- **Splitter island waist.** Mostly gone once the split widened to 38 deg, but
  a 4-leg ring still dips ~0.7 studs partway along before opening out. A
  nose-to-tail taper would need the island built from its own curve rather than
  from the two arm edges.
## Junction pad zigzag — FIXED in code, NOT yet confirmed live

The self-intersecting, spiked junction pad is fixed; see the SHIPPED.md entry
"Junction pad: fix the outer corner arc and make the fill defensive" for what
changed and why. Summary of the cause, because two earlier guesses in this
file were wrong and worth not repeating: `cornerBoundaries` aimed its edge
directions along **+outward** on any span wider than 180 degrees. The corner
vertex is toward **-outward** on both sides of a bend, so `Fillet.Compute`
correctly rejected every such span and the Hermite fallback looped the outer
boundary back across the pad interior.

`tools/preview/junction_pad_preview.py` reproduces it (`--legacy`) and is the
regression test - 66 cases, all filling exactly once over. Run it after any
`JunctionBuilder` corner or fill change.

**Still needs a live check in Studio**, on the same shallow bend that was
reported plus a T and an X.

Corrections to earlier entries here, so they are not acted on again:

- The cylinder pad (`Enum.PartType.Cylinder`, bottom of `Rebuild`) is NOT
  reachable from a two-road bend. It is the `else` branch of
  `#approaches >= 2`, and a two-road bend has two approaches. It only fires
  when no road contributed a usable edge pair, which is what it is for.
- `convexHull` was not the cause either, though it was made defensive in the
  same change (it is the fallback fill now, so it has to be trustworthy):
  three-or-fewer points used to be returned in road order rather than
  perimeter order, and collinear input could empty the hull and produce a NaN
  apex.

## Roundabout: Studio reports and follow-through

These entries preserve the Studio evidence and the reasoning behind each fix.
Most are now fixed headlessly; anything labelled for a live recheck remains
open until the rebuilt plugin is inspected in Studio.

1. ~~Centre island is a true cylinder; the ring around it is a polygon~~ -
   FIXED, see the SHIPPED.md entry. `RoadBuilder.StationsFor` now exposes the
   station list and the island fans onto it above a measured scallop
   threshold. Not confirmed live yet.

2. ~~A median appears on approaches whose road type has no median~~ - FIXED,
   see the SHIPPED.md entry. The splitter island now starts where the gore
   first reaches `MIN_GORE_WIDTH_M`. Not confirmed live yet.

3. ~~Roads passing BESIDE the roundabout are not connected~~ - FIXED, see the
   SHIPPED.md entry. `ConnectRoad` now cuts them at the station of closest
   approach via `RoadSplit.SplitAtJunction`. Not confirmed live yet. The
   original note, for context: detection was fixed
   (`collectNearbyRoads` samples the curve); HANDLING was not.
   `ConnectRoad` calls `ringSideIsStart`, which picks whichever END of the road
   is nearer the centre and skips the road when that is unreadable. A road
   passing beside or through has both ends far away, so choosing an end is
   meaningless - it needs SPLITTING at the nearest point, the way
   `RoadSplit.SplitMany` already does for X intersections. Until then a
   detected-but-unsplittable road does nothing, which reads exactly like a
   detection failure. See ROUNDABOUT.md section 5.1.

   NOTE while here: `ConnectRoad` re-collects and connects every nearby road
   itself, so `Place` passing `nearby[1]` is NOT a bug - do not "fix" it.

4. ~~The preview's bare-ground scan does not cover the mouths~~ - CLOSED.
   `scan_mouths` now sweeps each mouth from the approach cut to the ring with
   a self-defining envelope (the outermost covered points either side ARE the
   mouth's edges at that station), splitting interior gaps into GORE (open by
   design since the splitter change) and HOLE (a real defect). Runs by default.

   **Result: zero holes on every case, gore closed.** That is the important
   finding and it redirects the search. The mouths are clean in the geometry
   the preview models, so the defects still visible in Studio are NOT in that
   geometry. They are in one of:

   - **markings** (item 5 below) - the preview simulates them but the mouth
     scan treats a marking as coverage, so a wrong marking is invisible to it;
   - **part heights / render order / z-fighting** - explicitly out of the
     preview's plan-only model;
   - **the Lua diverging from the Python port** - `check_parity.py` compares
     constants only, and `dump_compare.py` has still never been run against a
     live junction.

   Take those in that order. Markings first.

5. ~~Bare-ground band at R=34-36~~ - FIXED. Was my regression; see the
   SHIPPED.md entry. Residual is 1-2 samples at 0.13-0.21 studs deep, below
   the 0.15-stud hairline threshold the ring rim already reports. Not
   confirmed live yet.

6. ~~Small radius requests are silently inflated~~ - FIXED; the radius is
   built as asked and the panel warns instead. STILL OPEN: re-derive the
   minimum from where the geometry actually fails, since it is currently a
   conservative packing estimate (clean at R=10..35 on a 4-leg 2+2 whose
   "minimum" is 70.5). Original note: `CreateAtJunction` does
   `grown = max(radius, MinimumRadiusStuds(...))`, and for a 4-leg 1+1 ring
   that minimum is **42.8 studs** - so a 12-stud request and a 40-stud request
   build the identical ring. That, not a geometry fault, is the most likely
   thing behind "bugs out on smaller intersections": the user asks small and
   gets large, with no indication why.

   The growth also turns out to be OVER-CONSERVATIVE. With `grow=False` the
   un-grown geometry is clean at R=12, 16, 20, 25 and 30 for a 4-leg ring, so
   the minimum is well above where the geometry actually fails. Worth
   re-deriving it rather than just surfacing it - but surface it either way
   (item 8), because silently ignoring the number the user typed is the
   underlying complaint.

   `roundabout_preview.build()` now defaults to `grow=False`, matching the live
   builder's requested-radius rule. `grow=True` remains an explicit
   suggestion-sized what-if view. `dump_compare.py` also reports the minimum as
   advice while using the requested radius, so its output describes the ring
   Studio actually builds.

6. ~~**Clipping: pavement over the carriageway at an arm end.**~~ ROOT CAUSE
   FIXED HEADLESS; LIVE RECHECK OPEN. The newest Studio view showed that the
   visible wedge was at a ring mouth boundary, not the approach-cut cap.

   `scan_mouths` now DETECTS this class - it classifies each swept sample as
   deck or raised and flags raised material strictly inside the carriageway's
   own lateral span. That closes the tool's other structural blind spot: the
   gap search can only find material that is MISSING, never material that
   should not be there.

   **It does not reproduce.** Clean across 1+1, 2+2, 1+1 with a 2m median,
   2+2 with a 3m median, and a 3/1 asymmetric approach, at R=40 and R=55. So
   the defect is not in the geometry the preview models, and the suspects are
   the same three as the mouth holes - most likely the arm's END-CAP shape at
   the seam, which the preview idealises as a rotated rectangle while
   RoadBuilder emits a real Part whose corners can overhang on a curve.
   `seam_steps` reports 0.00 flush there, but it measures lateral EXTENT, not
   the shape of the cap, so a diagonal corner poking out would not move it.

   The earlier approach-cut mitigation remains valid but did not fix the live
   report. Actual cause: `openRingPavement` tested only each ring Part's centre.
   A sidewalk Part centred just outside the mouth could still project a corner
   across it. The builder now clips boundary straddlers to the exact sector ray
   and retains their outside fragment. Deleting each whole straddler was tested
   and rejected because it opened 6-7 stud holes on `uk3`.

7. ~~**Markings: match the preview's layout.**~~ SHIPPED HEADLESS; REBUILT-DIST
   CONFIRMATION OPEN.

   User's call, given the two renders side by side: the roundabout should look
   like `tools/preview/out/uk4_parts.png`. That is the TARGET APPEARANCE.

   Cause of the divergence, already traced: the preview never ported
   `Mesh/Markings.lua`. It approximates it in ~30 lines inside `emit_road` - a
   solid line just inside each roadway edge, a dashed line between adjacent
   non-Sidewalk components, nothing else. `Markings.lua` (569 lines) has
   region-driven boundary specs per gap (Solid/DoubleSolid/Dashed/SolidDash/
   DashSolid), kerb lines with `KerbIndent`, region edge lines, restriction
   lines, per-road and per-stretch dash overrides, and colour rules.

   **Do NOT reach for that by replacing `Markings.lua` with the Python rule.**
   Eleven modules read those specs - `RegionStyles`, `RoadBuilder`,
   `RoundaboutBuilder`, `MarkingStretchPanel`, `MarkingStretchListPanel`,
   `KerbStretchPanel`, `RoadDesigner`, `RegionEditor`, `RegionalPreferenceGui`,
   `RoadInspector`, `ProfileFields` - and the swap would delete the boundary
   dropdown, kerb lines, restriction lines, dash overrides and the whole
   marking-stretch and kerb-stretch feature set. The preview's rule has two
   marking types and no concept of a stretch.

   Implemented as a roundabout-only marking plan passed to RoadBuilder: solid
   white roadway edges, 3m/3m dashed Drive/Drive dividers, solid
   Drive/Shoulder separators, and solid circulating dividers in SolidLanes
   mode. Dash phase and the final partial dash match `emit_road`. Ordinary roads
   still use the complete `Markings.Compute` pipeline. The excess live strokes
   were surviving fragments of the ring's outer edge line at sector boundaries,
   plus, in Turbo mode, the ordinary concentric divider remaining under each
   peel with a different dash phase. Exact sector clips now trim both ownership
   conflicts: full mouth sectors for outer edge paint and peel-only replacement
   sectors for circulating dividers.
   Remaining step: reinstall the rebuilt dist and compare against the bird's-eye
   target.

8. **The radius suggestion is not offered by the Roundabout tool in the Road
   Builder widget**, only on the junction panel. `RoundaboutBuilder.SuggestedRadiusStuds`
   already exists and is UI-agnostic; this is wiring.

9. ~~**The circulating-lane suggestion does not adapt to the connected
   roads.**~~ FIXED HEADLESS. The junction panel now takes the maximum motor
   lane count of any individual connected carriageway: 3/2 -> 3, 2+2 -> 2,
   one-way five -> 5. Only positive-width Drive components count; shoulders,
   parking, cycle lanes, bays and pavements do not. It follows the suggestion
   until the user edits the lane field, then keeps that override.

10. **Cul-de-sacs**: asked for, nothing exists. Open question, not a bug.

## Roundabout minimum radius — RE-DERIVED, not yet confirmed live

`MinimumRadiusStuds` now means the hard geometric floor (below it the ring's
inner edge has passed the centre and there is no annulus at all);
`SuggestedRadiusStuds` carries the angular packing estimate that used to be
called the minimum. See ROUNDABOUT.md 3.9 for the measurements — the packing
number was 2-4x too conservative as a floor.

Doing this turned up, and fixed, a bug that mattered more: the splitter island's
nose fan laying a raised wedge across the circulating lanes at ordinary radii
(ROUNDABOUT.md 3.7, 4.5). That was a regression from the apron change earlier
the same day.

Left open:

- **The panel does not show the hard floor and the suggestion differently.**
  They are two different kinds of number now - "this cannot be built" versus
  "this will be tight" - and the warning should say which.
- **`circulating_width` is not in the standard preview run.** It is the only
  check that can see a ring paved over rather than left bare, and it costs a
  few seconds per case, so it should be in `report()` behind a flag at least.
- **The hard floor uses a 2-stud island minimum**, picked because `buildIsland`
  bails below 1. Not measured against anything.
- **~~The preview never followed the split~~ — DONE.** The packing estimate is
  `suggested_radius_studs` and the hard floor is `min_radius_studs`, matching
  the Lua's own split; `build(grow=True)` still grows to the suggestion, which
  is what it documents. Parity is clean again. The floor comes out at 18.6
  studs for a 2-lane UK ring, which is where the `circulating_width` sweeps in
  ROUNDABOUT.md 3.9 independently found the geometry stops holding (R=18).

## Turbo roundabout markings — SHIPPED HEADLESS, rebuilt Studio recheck open

Third `RoundaboutMarkings` mode beside Continuous and SolidLanes, selectable per
roundabout in the junction panel and as a regional default. Outside a peel the
ring keeps its ordinary concentric divider. Inside the peel-owned arc that base
divider is clipped out, so its short dash phase cannot fill the Turbo marking's
deliberate gaps. The peel resolves the exit profile's actual Drive/Drive
boundary instead of inferring a lane count from total arm width divided by the
ring lane width. It therefore survives edited lane widths and unequal/custom
approach widths. Rule and reasoning are in ROUNDABOUT.md 3.8.

The Studio/Python visual divergence is now fixed in source: every arm marking
gets a `FromStationStuds` or `ToStationStuds` bound at that line offset's exact
ring-kerb crossing, while the outboard edge line is preserved to its tangent
handoff. Turbo's peel has a distinct top plane where it follows the arm, and
the base ring divider is physically replaced over the polar peel. The Python
preview validates with the edited `lane_width_m` and requires replacement
sectors rather than relying on painter order.

Left open:

- **Entry lanes are not matched to spiral lanes.** In a real turbo the lane you
  enter in commits you to a destination, which means `splitApproachLanes` has to
  know which circulating lane each approach lane feeds. It splits by `Direction`
  only. Lane-connection work, not markings — and the markings are right without
  it.
- **No arrows or lane-destination legends** on the approaches. This is now the
  ONLY unbuilt half of turbo: the ring side is settled (concentric divider plus
  a peel-off at each exit, ROUNDABOUT.md 3.8) and the arm side is how a real
  turbo tells a driver which lane to pick. Same Markings.lua job as the give-way
  lines already logged above.

## Roundabout mouth indentation — SHIPPED, not yet confirmed live

The V-notch down the middle of each approach. Fixed with the two-fill design:
flat asphalt apron from the cut, raised island from 2 m of gore width in. See
ROUNDABOUT.md 3.7 for the rule and 4.4 for the measurements — including the
`scan_mouths` sign error that let it survive three rounds, and the two further
detector faults found while verifying the fix.

Left open by that round, both cheap:

- **`MEDIAN_AT_CUT_M` and `ISLAND_MIN_WIDTH_M` are not exposed.** A user with a
  narrow median, or one who wants kerbed splitters further out, has to edit the
  source. Natural home is the region style, beside `RoundaboutSidewalk` and
  `RoundaboutIsland`.
- **The apron carries no markings.** A real mouth has hatching or a ghost
  island painted on that wedge; it is currently plain asphalt. `MarkingLine`
  already ramps a lateral offset along a curve, so this is the same machinery
  the turbo work needs.

## Highway/one-way roundabout approaches and shoulder semantics — FIXED HEADLESS

There is no Highway-category rejection in roundabout conversion. Directed
one-way roads create only the arm their traffic direction permits, and the
solo-mouth outer pavement crossing now has the same sampled-and-bisected helper
as the Python reference. A legacy/custom profile with one undirected Drive uses
a full-width shared entry/exit flare instead of two half-width fictional lanes.

`LaneGroup` now carries a `LaneSpec { Kind, WidthM, Directional }` per strip
instead of a bare width, so the arm can distinguish a shoulder from a Drive.
Fixing that exposed a second defect underneath it, invisible while every strip
came out as an identical-width Drive: the undirected pass runs *after* the
directional one and appended, so a shoulder landed at the inboard end of its
group however far outboard it really sat — and the exit arm's cross-section is
MIRRORED (its travel runs against the approach curve), which nothing accounted
for. Either one alone puts the hard shoulder on the gore side of the mouth,
against the splitter island. `splitApproachLanes` now collects indices and
sorts them; `armProfileFor` takes a `mirrored` flag, `travelsInward == atStart`.

Terminal shoulders are no longer carried full-width into the ring.
`armProfileFor` leaves a zero-width Shoulder marker at every tapered boundary
so `Markings.lua` paints the solid Drive/Shoulder separator, while `buildArm`
emits each physical shoulder as an independent edge-anchored surface taper from
its source width to zero. Paired arms taper their traffic-outboard shoulder;
solo one-way highway mouths taper both sides and retain the resulting asymmetric
lane-centre shift. The running lanes stay fixed: a 2+2 highway therefore has
two-lane arms, not three-lane arms with a differently coloured third strip.

Covered by `check_arm_kinds`, `check_shoulder_tapers`, the mixed highway cases,
and the dedicated one-way-highway fixture.

The ring-side pavement is coordinated outside that shoulder taper, growing from
the approach's real pavement width (zero on a motorway) while the shoulder
shrinks. `hw4` and `hw4us` measure 0.00 studs of edge step; `hwmix` measures
0.10. Every 3.3 m shoulder measures 11.78 studs at the cut and at most 0.02 at
the ring (below the emitter's 0.02-stud cutoff), all with no mouth holes. The three seam entries have been removed from
`KNOWN_OPEN`.

Still open:

- **Multi-segment connected approaches.** Editable conversion still requires
  exactly one recoverable source segment. Curved parallel carriageways are
  commonly serialized as PolyCurves and remain blocked even though their
  Highway/one-way profiles are now valid. Source-window slicing must be
  generalized before this restriction can be removed safely.
- **`RoadBuilder`'s half is still untraced.** The live report was that both
  sides do this; only the roundabout was confirmed. Widen/narrow transitions
  between a highway and a parkway/avenue/street are the case to look at.

## Junction corners: remaining work

- **Bunched legs fall back to the convex hull.** When several legs sit within
  ~45 degrees of each other the corner walk produces a self-crossing outline
  and the fill drops to the hull - intact, but blunter than intended (no
  curb returns on those gaps). Visible in `junction_pad_preview.py` as the
  "T bunched" / "X bunched" cases choosing `convex hull`. The fix is a corner
  treatment that stays simple at small gap angles, not a change to the fill.
- **A two-road bend is arguably a CORNER PATH, not a junction.** CivicArc
  RoadToolkit gates on `canUseCornerPath = ... and angleDegrees >= 18` and
  joins the two roads with a curve; the clipping-circle paper draws its
  L-shaped case with no clipping lines at all, unlike its T and Y cases. Our
  `isSmoothPassThrough` only skips a bend under ~32 degrees, so a real L is
  still built as a junction pad. That is now a fidelity question rather than a
  broken-geometry one - the pad it builds is sound. Doing it properly means
  miter on the inner edges, fillet arc on the outer, asphalt + raised sidewalk
  band + kerb line around the arc; `corner_preview.py` already models and
  measures that shape (0 bare ground, 0 out-of-envelope) but it is Python
  only, and the inner-side pavement-across-carriageway problem is unsolved.

- **Static identifier checking.** HIGHEST VALUE. There is no Luau runtime or
  typechecker in the dev environment: `stylua` proves a file parses, nothing
  proves an identifier exists. A misplaced edit shipped `ringComponents`
  referencing a nil global and Make Roundabout threw on every use until it was
  caught live in Studio. `tools/preview` cannot catch this class of bug - it
  re-implements the geometry rather than executing the Lua.

  Network reality, checked rather than assumed: **GitHub and the npm registry
  are blocked from this environment (403), so the official `luau-analyze`
  binary cannot be fetched. crates.io and PyPI ARE reachable.** The viable path
  is therefore a small Rust helper built on `full_moon` (2.2.0, the Luau parser
  stylua itself uses) doing scope-aware undefined-identifier detection.

  Note the bug that motivates this needs SCOPE awareness, not just a
  file-level global scan: `spokeProfile` was a legitimate parameter of a
  different function in the same file, so a whole-file "is this name declared
  anywhere" check would have passed it.
- **Auto-size a minimum ring radius** from entry width and leg count, and warn
  when the requested radius cannot carry the mouths. This is the real fix for
  the crowded-ring limit below, which currently just degrades quietly.
- **The preview only ever tests RADIAL legs.** Every case builds approaches
  that aim straight at the ring centre, so `rayCircleFirstHit` - the path that
  places a mouth for an approach which does NOT aim at the centre - is never
  exercised. Roads produced by an X-split frequently do not aim at the centre,
  so this is an untested path on exactly the geometry the live reports came
  from. Add an off-centre case.
- **Verify the preview against the Lua by BEHAVIOUR, not constants.**
  `check_parity.py` compares numbers; two implementations can agree on every
  constant and still diverge in logic. The way to settle it is a debug dump
  from the plugin - each arm's merge radius, merge angle, lateral offset and
  sector Ahead/Behind for a real junction - diffed against what the preview
  computes for the same input.
- **~~Extend `tools/preview` past the roundabout~~ — PARTLY DONE.** The generic
  emission port is now `preview_core.py`, and `road_preview.py` scans an
  ordinary road (straights, arcs to R=30, an S-curve, avenues, motorways) for
  bare ground, edge sawtooth and broken edge lines. `validate.py` runs
  everything. Still not covered, and deliberately so:
  - **Lane-width transitions (`MatchForTransition`) and bus bays
    (`BuildWithBay`) are not ported.** These are exactly where sliver gaps have
    shipped before, so they are the highest-value scenarios left. They need the
    Lua ported the way `build_stations` and `emit_road` were — modelling them
    from scratch would produce a check that agrees with the model rather than
    with RoadBuilder.
  - `junction_pad_preview.py` and `corner_preview.py` exist but are not wired
    into `validate.py`, so they only run if someone remembers them.
  - The roundabout suite is slow — minutes per case, because the scans are
    point-in-polygon over every part. A coarse spatial index would make `--full`
    routine rather than something you kick off and walk away from.
- **Preview does not model heights or render order**, only part footprints in
  plan. Z-fighting between coplanar decks, dash phase and marking lift are
  still Studio-only checks.

## History: the failed centreline-swing attempt

Requested feature: entries should curve tangentially into the circulating
direction (real roundabout entry deflection) rather than butting in radially,
ideally behind a toggle.

**A first attempt was built and reverted after the headless renderer showed it
produces hairpins.** The naive construction - rotate the feeder's ring attach
point around the ring by a deflection angle, in the direction of circulation,
and let `Fitting.CurveFromTangent` bend into it - is geometrically unsound
here: rotating 26 deg around a radius-51 ring moves the attach point ~23 studs
sideways, and the feeder is only `SETBACK_STUDS` (14) long, so the road has to
make that lateral jump almost immediately. Raising the setback to 30 and
capping deflection at 18 deg did not rescue it; the feeders still swung across
the front of the ring and the mouth corners (which derive from the feeder's end
cross-section) followed them into nonsense.

The mistake is treating deflection as a *centreline* swing. On a real
roundabout the entry centreline stays close to radial - the deflection reads
mainly in the **kerb geometry**: an asymmetric pair of mouth corners, with a
large sweeping radius on the entry side (turning traffic into the circulating
direction) and a tighter one on the exit side. `buildMouthCorners` already
builds each side independently, so the natural implementation is to give
`cornerSide` a per-side radius/flare rather than the symmetric one it uses now,
and leave `buildFeederRoad` alone.

Needs: per-side corner parameters, a sensible entry/exit radius ratio, and a
`RoundaboutEntryCurve` toggle (the settings field + Road Tool checkbox from the
reverted attempt are straightforward to re-add). Verify in the renderer before
shipping - this is exactly the case it caught.

## Multi-node roundabout (built, reverted at the user's request)

Built `RoundaboutNetwork.lua` - ring as 2N one-way arc roads, separate one-way
entry/exit arms meeting tangentially, splitter islands - after the M20 J4
reference. Reverted: it never rendered as a continuous roundabout to the user's
satisfaction, and after several rounds the sensible call was to go back to the
single-node builder rather than keep iterating blind.

What was learned, if it is ever picked up again:
- Junction nodes must NOT sit on the ring. A junction either trims the arcs to
  a pad boundary (breaking the carriageway) or, since `Rebuild` does not trim,
  stamps a pad on top of it.
- The arms must have pavement on the OUTER side only. A second, inner sidewalk
  lays a raised strip across the circulating carriageway at every merge.
- The arm tangent handle cannot exceed ~0.4 of the chord: the far tangent runs
  along the ring, so a larger handle walks the control point across the
  approach and the entry/exit arms swing through each other.
- Verified clean for 3-6 legs; beyond that 2N arms do not fit the
  circumference and the radius has to grow with the leg count.

Both of the last two were found only by rendering it out-of-engine, and both
were still not enough to make it read right - which is the honest reason it was
dropped rather than a specific unfixed defect.

## Roundabout give-way lines at each entry (missing)

The marking simulation (see `SHIPPED.md`) renders a correct multi-lane
roundabout except for one real omission: there is **no give-way / yield line
across each entry**. Real roundabouts paint one (double dashed in the UK,
solid triangle-backed elsewhere) at the point the entry meets the circulating
carriageway - which the mouth code already knows exactly, since it computes
`ringEdges.LeftKerb`/`RightKerb` and the apex on the ring kerb radius.

This is part of the wider junction marking gap already noted for
`JunctionBuilder` (stop lines, crosswalks) and would share that work - the
give-way line is the roundabout case of the same "paint a transverse line
across an approach" primitive.

## Roundabout: auto-size minimum radius from entry width

Multi-lane testing (see `SHIPPED.md`) showed that entries much wider than the
ring consume most of the circumference: 4-lane entries on a radius-40 ring
leave only 48 deg of carriageway edge, so it reads as a crossroads with a
central island rather than a roundabout. The geometry is valid and no longer
breaks, but the shape is wrong for what the user asked for.

Real roundabouts size the inscribed circle from entry width. Proposal: when
creating/rebuilding a roundabout, compute a minimum radius from the widest
connected road (e.g. enough that the summed mouth sectors stay under ~60% of
the circle) and either raise the radius automatically or surface it in the
Road Tool panel as a suggested minimum. Needs a UX decision - silently
overriding a user-set radius is worse than telling them - so not built.

## Units: remaining length fields - SHIPPED

Roblox, metric, and imperial display units now reach the Road Designer,
Region Editor, structure controls, bays, marking stretches, parallel roads,
junction corner radii, and roundabout lane widths. Values and bounds convert
together through `Units.lua`; stored geometry remains metric. Fields whose
actual canonical meaning is Roblox space (stations, setbacks, placement
elevation, snap/grid radii, and imported module lengths) intentionally remain
labelled in studs.

## Roundabout feeder blend with BezierCorner (robustness follow-up)

The roundabout now connects nearby roads (see `SHIPPED.md`), but each feeder
is still a separate short `Fitting.CurveFromTangent` road bridging a
setback gap to the ring — a real merge, but the join to the ring edge is a
butt-join, not a blended mouth, so wide-angle or offset approaches can still
read as a seam/kink. Follow-up: replace the per-feeder bridge with a
RoadCreator-style ring projection + bounded quadratic-Bézier blend of the
feeder cross-section into the ring edge, using the already-translated
`src/Geometry/BezierCorner.lua`. Bounded-by-construction, so it cannot spike
regardless of approach angle. Same primitive can replace `Fillet.Compute` in
junction curb returns. Needs Studio verification of the mouth continuity.

## Marking stretch v1 follow-ups (deliberately deferred, not forgotten)

The marking-stretch feature (drag a lane boundary's marking to override its
type over a free-form sub-range, siblings moving together - see
`SHIPPED.md`) shipped a real v1, but a few things were deliberately scoped
out rather than solved, and should get their own pass later:

Completed in the current pass: the opposing-direction centre line is now an
editable stretch target and accepts the same explicit boundary rules as a lane
line. Road Editor reveals markings as selectors physically between the two
Drive lane tiles, with a boundary-specific editor, instead of showing a
misleading `Lane marking` property inside one selected lane.

- **`ComponentIndices`-keyed storage isn't stable across a structural
  profile edit.** A stretch stores which cross-section boundaries it
  targets by index; if the user later adds/removes/reorders lanes in the
  designer and hits Apply, an existing stretch can end up pointing at the
  wrong boundary (or silently drop an index, if it no longer resolves to a
  Drive/Drive boundary at all - `Markings.lua` degrades safely per
  index, it just doesn't warn). A `RightBoundary` rule doesn't have this
  problem since it lives on the component itself and moves/deletes with
  it; a stretch is a separate list keyed by position instead.
- **`BuildWithBay` + transition + stretch is only approximately handled.**
  When a road has both a widen/narrow transition AND a bus bay AND a
  stretch, the stretch's `ComponentIndices` are resolved against whichever
  component list produced them, but the bay-aware builder's "before"/
  "after" taper slices use `MatchForTransition`'s (possibly reindexed/
  padded) component list while the middle bay slice uses the unmatched
  `baseProfile.Components` list directly - if a transition inserts an extra
  component before a targeted boundary, an index can point at the wrong
  boundary in one slice but not another. A genuinely rare combination
  (transition + bay + stretch all on the same road); flagging rather than
  fixing blind.

## Next up — needs a decision or real design work

**Roundabout icon - still not built, but there's now a slot for it.** The
"Roundabout" tool button in `BuildBar.lua`'s Tools row (see "Snap toggles +
standalone Roundabout tool" in `SHIPPED.md`) currently falls back to a blank
image (`TOOL_ICONS[props.Mode] or ""`) since there's no dedicated icon asset
yet - identifiable only by its hover label like the other tool buttons.
Originally skipped because there was no UI slot to use it (see prior note,
kept for history below); that's no longer true. Needs the same icon-asset
process the category tabs used (`Build icon-only reference scenes for
category icons`, task #102).

## Junctions & intersections — phased plan (Phase 1 shipped, Phase 2/3 v0)

CS2-style node model: a `JunctionNode` (`JunctionInstance.lua`) is a real,
first-class entity roads reference by Id (`RW_StartJunctionId`/
`RW_EndJunctionId` attributes, see `RoadInstance.lua`), replacing pure
positional endpoint-snap coincidence. A road ending at a junction is just
`curve:Slice(0, s)` handed to the unmodified `RoadBuilder.Build` (the same
mechanism already used for bus-bay tapers/marking stretches) - the
junction's own pad/fillet surface is a separate module that stitches the
seam, so ordinary road geometry needed no surgery. See `SHIPPED.md` for
the full round-by-round detail.

**Phase 1a:** node data model, auto-create-on-snap at both placement
endpoints (not just the chained-continuation case).

**Phase 1b:** mid-span connect (crossing an existing road actually splits
and links it, not just visual overlap - `RoadSplit.lua`, genuine Bézier
subdivision via `CurveSegment.Sub`); pads skip themselves for a plain
2-road pass-through; ground-picking for new placements now ignores
existing roads/junctions entirely (ground-relative by default, no
snap-up-onto-whatever's-underneath); orphan cleanup when a connected road
is deleted (`workspace.DescendantRemoving` in `main.lua`); a junction can
be selected (Studio's ordinary Selection, same as a road) and deleted
directly (`JunctionEditSession.lua` + `JunctionPanel.lua` - unlinks the
roads, doesn't delete them); the pad is now a real fan-triangulated
polygon tracing each connected road's own pavement edges
(`FillTriangle`-based, angular sort around the junction centre), not an
arbitrary circle.

**Live retest checkpoint:** selecting the junction Model and spawning its cyan
handles are confirmed. The same test exposed a React mount crash before the
panel could appear: the suggested-roundabout-radius path omitted
`armProfileFor`'s ring-pavement-width argument. That call and a panel-safe
fallback are now fixed; reinstall the current `dist/EasyRoad.rbxmx` and confirm
the editor, link toggle, and selected-corner radius field appear before calling
multinode editing live-verified.

**Approach trimming (shipped) - the RoadArchitect model.** Connected roads
now TERMINATE at the pad boundary instead of running full-profile
(sidewalks, markings, kerb lines) through to the junction centre -
`JunctionBuilder.TrimApproaches`, called from the placement flow's
`connectAt`/`connectAtSplit` before `Rebuild`. See `SHIPPED.md` for the
full write-up. Follow-ups deliberately left open:
- Roads with a transition or bay can't be trimmed (`RoadSplit.CanSplit`
  guard) - they still overlap the junction interior the old way.
- Trims never grow back: if the widest connected road is deleted, the
  remaining approaches keep the larger pad radius (inner material was
  discarded). Same one-way limitation the roundabout spoke trim has.
- The trim radius is circular (centre + widest half-width + margin); two
  roads crossing at a very oblique angle can still overlap slightly
  beyond it. A per-pair footprint (halfwidth / sin of crossing angle)
  would fix that if it shows up in practice.
- After a commit whose end connected to a junction, the placement chain
  still seeds from the PRE-trim endpoint (the junction centre), so
  "continue building" starts inside the pad. Cosmetic; cancel + snap to
  the trimmed end works.

**Curb-return corners - current state: convex hull fan (see `SHIPPED.md`
for the full history of what didn't work before this).** `JunctionBuilder.lua`
computes the actual convex hull of every connected road's kerb points and
fan-triangulates it from one of its own hull vertices. This is provably
safe - a convex polygon can always be fan-triangulated from any of its own
vertices without self-intersecting - which is why it was reached for
after four separate rounds of narrower fixes (a Bézier corner with an
unbounded control point, then a straight chamfer, then fanning from the
point-set centroid instead of the junction's stale stored position) each
patched one specific reported symptom without addressing that a per-pair
"is this gap a real corner" judgement call, walked in a possibly-wrong
order, can produce self-intersecting geometry no matter how the individual
corner is drawn or where the fan apex sits. The convex hull sidesteps the
whole class: there's no per-pair decision left to get wrong.
**Corners are now rounded (shipped - see `SHIPPED.md`'s "Junction corners:
real curb-return fillets").** Every cross-road hull edge tries a bounded,
fixed-radius fillet (`chooseArcCenter`/`sampleArc2D`-style true circle,
adapted from the user-supplied CivicArcRoadToolkit reference) before
falling back to the plain chamfer described above - the fallback is the
same hull edge, so the worst case is still the reliability this section
describes, and rounding only ever adds to it, never regresses it.

**Per-approach NODE model - SHIPPED (user's suggestion: "break an
intersection down to different nodes, the cross section itself, and join
them all").** Each connected road is now an explicit approach node (its
cross-section's left/right kerb + outer points, plus the angle it leaves
the junction at); nodes are sorted by angle around the centre and corner
treatments are built between ANGULAR NEIGHBOURS (first road's
counter-clockwise-side point paired with the next road's clockwise-side
point, both sides resolved computationally from signed angles - no
handedness conventions). This replaced corner-pairing by adjacent
convex-hull points, which paved straight across any road whose kerb
points fell hull-interior (the live-reported Y-junction walling-off bug).
Per the migration caution logged when this was proposed: the convex hull
fan is DELIBERATELY KEPT as the unconditional base asphalt underneath, so
no corner-layer failure can tear or hole the pad itself, and the
mouth-crossing guard is kept as belt-and-braces for pathological
near-parallel approach clusters.

**Other trade-offs, still current:**
- **A corner pair that would properly cross a THIRD road's mouth still
  skips its raised treatment** (`segmentsCross2D` guard) - structurally
  near-impossible under angular-neighbour pairing, but kept because a
  silently-missing corner beats a band walling off a carriageway.
- **The pad is now one continuous surface with no unfilled gaps** - the
  old "skip gaps wider than ~130°" logic (meant to avoid bridging the far
  side of a bend or a T-junction's through span with a spike) is gone;
  the convex hull just includes that area now, same as a real intersection
  actually looks (continuous pavement, not a shape with a bite taken out
  of one side). This is a genuine behavior change worth watching for
  reports of "extra pavement where I didn't expect it," not just a
  side-effect to shrug off.
- A road whose kerb point ends up hull-interior (dominated by other,
  wider/farther roads' points) contributes nothing to the boundary - its
  own pavement is unaffected (already built by `RoadBuilder`), but it also
  gets no dedicated corner treatment at the pad edge. Not expected to be
  common (needs one road much narrower/closer to centre than the others),
  not yet seen live.

Deliberately still out of scope, in rough priority order:

- **`RoadSplit` refuses to split a road with a transition or bus bay.**
  Interpolating the exact profile at an arbitrary cut station, or deciding
  which piece keeps a bay, is real geometry work not attempted yet -
  splitting simply doesn't happen for those roads (the new road's end is
  left unconnected, same as today).
- **`RoadSplit` drops MarkingStretches/KerbStretches across a cut** rather
  than remapping their station ranges into each piece's own local
  coordinate space - the same class of complexity already flagged for
  marking stretches surviving a structural profile edit, above.
- **Corner geometry ignores superelevation roll.** Edge points are
  computed via a plain `FrameAt(station)` (roll defaults to 0); a road
  banked right at the point it meets a junction will have its edge
  slightly off from the true tilted deck surface. Uncommon in practice
  (banking transitions run mid-segment, not usually right at an endpoint).
- **Sidewalk corner fill always uses plain sidewalk material/colour**,
  regardless of what the road's actual outermost non-roadway component
  is (doesn't inspect Median vs Sidewalk, or a future median-variety
  sub-kind once that's built).
- **No lane markings (or even the plain kerb/edge line) drawn through the
  junction or around the roundabout ring.** Confirmed by grep - neither
  `JunctionBuilder.lua` nor `RoundaboutBuilder.lua` references `Markings`
  at all, so the white edge-line that runs along every ordinary road's
  kerb simply stops dead at the pad/ring boundary instead of continuing
  around the corner - reported live, visible as a gap in the white line
  exactly at each corner of a real intersection. Stop lines, give-way
  markings, crosswalks, lane-guidance paint are the same underlying gap.
  `Markings.Compute` is fundamentally "one road, station 0 to Length" and
  deliberately wasn't touched; junction/ring marking geometry needs its
  own pass. Rough sketch for whenever this is picked up: for the junction
  pad, walk the same hull-edge boundary `JunctionBuilder.Rebuild` already
  computes (straight chord or `cornerBoundaryPoints`' fillet arc) and lay
  a thin marking strip along each cross-road edge's OWN a.Kerb/boundary
  points (not through `Markings.Compute`, which is curve/station-shaped,
  not polyline-shaped) - same technique the deck-strip marking Parts use,
  just addressed by explicit point pairs instead of curve stations. For
  the roundabout ring, simpler: the ring is already a `PolyCurve` built by
  the ordinary `RoadBuilder.Build`, so passing it a `KerbRestriction`/kerb
  line marking config through its `RoadProfile.Components` (the same as
  any real road) may already work without new code - worth checking before
  building anything bespoke for the ring specifically.
- **Mid-span-to-mid-span X crossings - shipped.** The pending curve is now
  intersected against every existing road during the live preview, using
  sampled ground-plane chords plus bounded refinement back onto the real
  curves. Green markers become shared `JunctionNode`s on commit and
  `RoadSplit.SplitMany` cuts BOTH roads; multiple crossings in one placement
  are supported. Different-height crossings remain grade-separated. Red
  markers explain unsupported cases rather than silently overlapping.
  Remaining subdivision work is the existing transition/bus-bay limitation:
  those roads still cannot be split without remapping their changing profile
  or bay data.
- **Snap-to-road / snap-to-grid toggles in Road Tools - shipped.** See
  `SHIPPED.md`. `Settings.SnapToRoad` (new) gates
  `findEndpointSnap`/`findConnectableEndpoint`/`findMidSpanMatch` in
  `createRoadSession.lua`; `Settings.SnapToGrid` already existed but had
  no Road Tools surface, only the Regional Preference dock. Both now have
  checkboxes in `BuildBar.lua` next to the tool buttons.
- **Shifted-profile edge-snap topology policy.** Centre snapping now places an
  endpoint or mid-span junction on the visible, offset carriageway centre.
  Left/right edge snapping deliberately remains alignment-only and retains the
  authored curve as its topology datum; decide whether a future explicit edge
  connection mode should instead create an off-centre junction node.
- **Cross-section merge envelope.** The topology-free Cross-section mode now
  gives the new road a persistent G1 tangent lead-in, but it keeps the authored
  road at full width. A true on/off-ramp gore needs serialized start/end
  connection-envelope fields that taper surface components and markings without
  pretending the Road Editor profile itself is zero-width. That model must also
  define RoadSplit and custom Ground-module behaviour before it ships.
- **No box-junction ("keep clear") markings.** Real intersections
  (reference: Google Maps screenshots of live HK/TW intersections)
  commonly paint a yellow cross-hatch box over the intersection interior
  where a vehicle mustn't stop even with right of way, blocking the
  junction - `JunctionBuilder`'s asphalt fill has nowhere to paint
  markings at all yet (see "no lane markings drawn through the junction"
  above, which this falls under). Same references also show large,
  distinctly-paved plaza-style corners at bigger intersections (not just
  a narrow curb-return strip) - the current sidewalk-corner fill always
  uses the same plain material regardless of how much area the corner
  spans; worth a variant for larger corners once this is revisited.

Standing constraint for all of the above (confirmed explicitly): stick to
plain `BasePart`s (`Part` with `Wedge`/`Block`/`Cylinder` shapes, same
`FillTriangle` convention already used everywhere in `Mesh/`) for
performance - no `UnionOperation`/`MeshPart`/`EditableMesh` unless a
shape genuinely can't be built any other way.

**Phase 2 - roundabouts (v1, still rough on purpose).** `RoundaboutBuilder.lua`
generates a real one-way ring (configurable lane count/width) - not a new
`CurveSegment` kind, a `PolyCurve` of 4 cubic-Bézier quarter-arcs
approximating a true circle (the standard "k = 0.5522847498"
construction), reusing `RoadBuilder.Build` completely unmodified since a
closed ring is mechanically just an ordinary road whose curve starts and
ends at the same point. `CreateAtJunction` now also trims every connected
spoke road back to the ring's own boundary (bisection to find where each
spoke's curve crosses the ring's circle, `CurveSegment.Sub` to truncate,
same transition/bay guard `RoadSplit` uses) and removes the junction node
itself, since the ring replaces its fillet pad as the intersection
surface - confirmed live that leaving spokes running straight through an
untouched ring read as broken, not just rough. Triggered from a selected
junction's panel ("Make Roundabout," shown once 3+ roads are connected)
with radius/lane-count/lane-width fields. **Also now triggerable directly
from Road Tools** - a new "Roundabout" tool mode (`createRoadSession.lua`'s
`commitRoundabout`) drops a standalone ring at a single click, calling
`RoundaboutBuilder.Create` directly (not `CreateAtJunction`, since there's
no junction) - requested explicitly ("no button on road tools to ... Build
roundabout"). Same radius/lane-count/lane-width fields, shown in
`BuildBar.lua` while that tool is selected. Has the exact same "not wired
into the data model" limitation as the junction-triggered ring (below) -
any road drawn to cross it afterwards won't auto-connect.
**What's still deliberately missing:**
- **No per-lane merge tapering at each approach.** A trimmed spoke's
  pavement just stops at the ring boundary - there's no shaped merge lane
  blending its own lane(s) into the ring's circulating lane(s), no
  yield/give-way markings, nothing modelling how many ring lanes a given
  approach's lanes should feed into. This is the single biggest remaining
  gap between v1 and a real roundabout.
- **Setback/Hermite ring feeds - REPLACED by polar annulus (see SHIPPED.md).**
  Large setback + Hermite feeds-as-second-roads were reverted after live
  knotted-ring failures. Ring is continuous drive + angular sidewalk gaps +
  mouth fillets. True deflected spoke centreline feed-in remains future work
  (edit the spoke curve; do not add ring-owned feed roads again).
- **Ring pavement/sidewalk notch at the trim point - fixed.** The spoke
  trim originally cut the whole cross-section at a flat perpendicular station,
  leaving rectangular notches or padded ring Parts outside the true curve.
  The current builder emits exact ring-sidewalk station quads and subtracts
  each paired/solo mouth roadway footprint before creating Parts. One-way arms
  carry independent left/right pavement widths and taper only their real
  traffic-inboard footway to zero at the ring kerb. LHT/RHT headless close-ups
  now assert no ring/mouth holes and a flush approach seam.
- **If a fan of thin shards ever reappears inside a roundabout's island**
  (reported live once, see `SHIPPED.md`'s "defensive stale-pad cleanup"
  entry): the leading but UNCONFIRMED theory is a stale `JunctionBuilder`
  pad (the old intersection's convex-hull asphalt fan) surviving because
  something in `CreateAtJunction` errored before reaching its
  `JunctionInstance.Delete` call. A defensive early cleanup was added, but
  the actual root cause was never pinned down (no live Studio access to
  check the Output window for the real error) - if it recurs, check Output
  for a Luau error during roundabout creation first, before assuming the
  defensive cleanup didn't work.
- **No live preview.** Unlike ordinary road placement (which ghosts the
  road as you aim), there's no preview of the ring or the trimmed spokes
  before clicking "Make Roundabout" - you only see the result after
  committing. Same gap exists for the ordinary junction fillet/corner
  geometry itself (no preview while approach roads are still being
  placed) - requested explicitly for both.
- **~~No way to edit a roundabout's own form after creating it~~ — SHIPPED.**
  Selecting a ring/arm opens a dedicated React-Lua editor for radius,
  lane-count, lane-width, markings, pavement, and island, with undoable
  in-place rebuild, delete/convert actions, and radius advice.
- **~~The ring isn't wired into the junction/road data model~~ — FIXED for new
  builds.** The ring intentionally remains a closed non-`RW_Road` owner, while
  a retained `Kind = Roundabout` junction controller owns exact road-end
  topology. Legacy connected rings remain read-only because their original
  source approaches are unrecoverable; an ordinary rebuild never annexes roads
  by proximity.
- **Source-window slicing for advanced approach data.** Editable roundabout
  conversion currently rejects widening/narrowing transitions, bus bays, and
  marking/kerb stretches before mutation. Implement source-space profile
  interpolation plus durable feature partitioning before allowing these road
  types to be trimmed or split around a ring. The same source-station metadata
  is needed before trimming an existing transition can preserve its original
  taper parameterization instead of remapping it across the shortened curve.
- **Winding direction (which way traffic circulates for `DriveOnLeft`)
  is reasoned through, not verified live.** Flip
  `RoundaboutBuilder`'s `circleSegments` ternary if it reads backwards
  once tested in Studio.
- **~~No central island or true Turbo guidance~~ — SHIPPED.** The centre island
  is independently toggleable and Turbo adds preview-matched spiral exit
  guidance above the retained concentric divider.

**Phase 3 - lane connector + traffic light API (v0, data-model only, no
UI).** `JunctionLanes.lua`'s `ComputeConnections` is a real, live
computation - every incoming lane at a junction paired with every
outgoing lane on a different connected road, using each component's own
`Direction` and which end it connects with - but nothing calls it yet:
no drag-based visualization/editing UI, no turn classification (through/
left/right), no persistence (a `LaneConnection` references roads by live
Model, not a stable Id, so it only makes sense freshly computed). Reads
`JunctionBuilder`'s own angular-sort-around-centre logic as the natural
place to add turn classification later, once something actually
consumes this. `DefaultPhases`/`SignalPhase` is a genuinely thin mock -
proves the shape a future traffic-light plugin would consume (all
connections green at once), not a real conflict-aware phase-grouping
algorithm.

## Kerb marking editor (not started) - default fix shipped

Reported live: highway profiles currently draw a plain edge-line "kerb"
marking on the outer edge of the shoulder, where real highway marking
convention has nothing there (it's pavement running into open embankment/
grass, not an actual kerb or a parking-relevant edge). Root cause: kerb
line generation (`Markings.KerbEdges`/`Compute`) treats a profile's
`KerbRestriction` as ONE setting applying uniformly to every kerb-eligible
edge - there's no way for a profile to say "no line on the outer edge,
but the usual restriction elsewhere." Two related asks:
- **Default fix - shipped.** Both built-in highway profiles now default
  `KerbRestriction = "NoLine"` (see `SHIPPED.md`). Confirmed this doesn't
  suppress anything on an inner/median-adjacent edge for the built-in
  two-lane-each-way highway profiles specifically (their only two
  kerb-eligible edges ARE the two outer shoulder edges - the median
  doesn't register as kerb-eligible since `Markings.KerbEdges` only
  treats `IsRaised` components as a kerb boundary, and `median` isn't
  raised). A custom highway profile with a raised median could still want
  a restriction on one edge and not the other - that's the "real fix"
  below, still not built.
- **Real fix / feature**: extend the single whole-profile
  `KerbRestriction` into a per-edge override map (same `EdgeIndex`
  numbering `KerbStretch` already uses), and add a UI section to
  `RoadDesigner.lua` (next to `ProfileFields.InsertMarkingOptions`, which
  currently renders the single whole-profile dropdown) listing every
  kerb-eligible edge from `Markings.KerbEdges` with its own restriction
  dropdown - the profile-level, always-on counterpart to the
  already-built per-instance `KerbStretch` free-form override tool.
  Comparable in size to the `KerbStretch.Side` → `EdgeIndex`
  generalisation already done for stretches.

## Median variety + elevated/underground sections (not started)

User's own sequencing: tackle after the intersection tool. Logged here,
not scoped in detail yet:
- **Different forms of median** - currently `Median` is one flat raised
  strip with a single colour (`RegionStyles.MedianColor`). Wants variety:
  at minimum grass vs. paved/flush vs. barrier (e.g. Jersey barrier)
  medians, likely as different `ComponentKind`s or a sub-kind on
  `Median` rather than a colour-only distinction, since a barrier median
  reads as physically different geometry (raised concrete profile) from
  a grass one (flat, no kerb).
- **Elevated / protected / underground sections** - the existing
  "Tunnels / bridges standard" backlog item below (auto-generated
  barriers/parapets, pillars) is the closest existing scoping for this;
  "protected" (presumably protected/segregated cycle lanes or similar)
  hasn't been scoped at all yet.

Smaller, independent alternative that builds on the inspector instead of
junctions: dragging a placed road's endpoint, or a duplicate/delete action
in the inspector panel — both reuse the `RoadEditSession.Apply` rebuild-
in-place machinery already built, unrelated to the junction work above.

## Backlog (not yet started)

- **Crossings.** Zebra crossings and HK/UK-style uncontrolled cautionary
  crossings (zigzag give-way markings).
- **Tunnels / bridges standard.** Promoted and expanded into the model-backed
  roads, viaducts, and tunnels priority section at the top of this file.
- **Deep settings: material/colour overrides.** Per-component-kind material
  and colour tweaks in the standalone settings page.
- **Units settings.** Speed in km/h / mph / studs-per-second; distance in
  km / mi / kilostuds. Currently everything is hardcoded metric internally.
- **Shoulder-optional highway presets.** Built-in highway profiles always
  include a shoulder; should be a toggle.
- **Bus Lane as a per-instance road-click option.** The old "Bus Bay"
  module is being retired from the general Modules palette on purpose -
  the user wants it (renamed "Bus Lane") to instead appear when clicking an
  already-placed road, alongside other per-instance options (kerb indent,
  etc.) in the future contextual click-road panel. Icon reserved:
  `Icons.BusLane` (`rbxassetid://86439959503324`). The `Bay` component kind
  itself still exists in `RoadProfile`/`RoadBuilder`/`RegionStyles` (only
  the palette tile was removed), so this is a UI-surfacing task, not a
  rebuild of the underlying feature.
- **Parallel mode.** CS2-style "place a mirrored road alongside an existing
  one, offset by N studs" workflow. Not started.
- **Per-point elevation - clarify with user.** The user asked for "define
  the position and elevation of point A, then point B, like CS2." As far
  as I can tell this already works mechanically:
  `createRoadSession.lua`'s `elevation` value is live and applied to
  whichever point is clicked next (press R/F to change height, then click -
  that click's point gets the height that was current at the moment of the
  click; earlier already-placed points keep whatever height they had when
  *they* were clicked), and since curve points are full `Vector3`s the
  resulting curve already ramps smoothly between differing point heights.
  If the ask was actually about something else - editing a point's height
  *after* it's placed without restarting the whole placement, or a visible
  ramp preview UI - that's not implemented and would need new work. Flagged
  here rather than guessed at and possibly built wrong.
- **Road furniture / signage tool.** A new tool sitting alongside the road
  library, for placing detailing along a road independent of its
  cross-section: surface road markings (arrows, yield/give-way lines,
  custom lane indicators - decals or thin meshes, distinct from the lane
  boundary lines `Mesh/Markings.lua` already generates), road signage
  (regulatory/warning signs, placed at a point with a facing direction),
  gantries (overhead structures spanning a road, lane-specific routing
  signs), and highway signs (large directional signage, likely with
  dynamic text/texture mapping for destination names). Needs its own data
  model (a "furniture" item: kind, position/orientation relative to a road
  or the world, and kind-specific parameters) and placement UI - probably
  closer to `BusStops.lua`'s click-to-place pattern than a cross-section
  component, since these are discrete placed objects, not something
  extruded along the curve. Scope/ordering not decided yet; flagging the
  full ask (signage + surface markings + gantries + highway signs)
  together since they likely share the same underlying placement
  mechanism even though visually very different.

## Housekeeping

- **Cross-platform parity validation - SHIPPED.** `check_parity.py` now reads
  both source files as UTF-8 explicitly, so it works under native Windows
  locales as well as Linux without an environment override. The native Windows
  quick validation sweep passes; the three highway seam exceptions it carried
  at the time have since been fixed and removed.
- Extract exact dimensions/assets from the user's `easyRoad 2` Studio
  reference environment (roundabout exemplar, T-junction demo, expressway
  barriers, yellow box). This cloud session can't reach a local Studio
  instance — needs a local Claude Code session with the Roblox Studio MCP
  plugin installed, run from the user's PC.
- GitHub Actions workflow still fails at startup on this repo (unresolved
  billing/permissions issue) — `tools/build_rbxmx.py` is the working
  around-it build path; `dist/EasyRoad.rbxmx` is rebuilt and committed by
  hand each round.
- Stale branch `claude/roblox-road-plugin-diml46` in the `roblox-redupe`
  repo (the plugin's original, since-superseded home) — could be deleted.
- No LICENSE file in this repo yet.
