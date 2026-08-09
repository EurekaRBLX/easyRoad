# EasyRoad — Shipped

A running log of what's been built, most recent first. Not user-facing;
internal planning only. See `TODO.md` for planned new features and
`KNOWN_ISSUES.md` for confirmed bugs.

## US traffic-left edge markings

- The United States regional preset now gives each directional carriageway a
  solid yellow traffic-left edge line. This covers both median-facing edges of
  divided highways and the inner-shoulder edge of one-way highway presets.
- Same-direction lane separators remain dashed white, and an undivided
  opposing-flow centre remains double yellow. Regions without the new optional
  rule—including the UK—retain their existing edge colours exactly.
- Custom regional presets can edit and persist the traffic-left edge rule.
  The Windows Python preview compares US and UK undivided, divided, one-way,
  and 2x2-to-3x3 transition layouts. It also verifies UK highway `NoLine`
  suppression and an explicit local `NoLine` span, with nine injected
  colour/ownership regressions.

## Lane-marking selector containment + JSON backup/restore

- The Road Editor's boundary-marking dropdown now takes only the remaining
  width beside its label. Its old 100%-wide flex basis caused the selector to
  spill past the right edge of the lane card.
- Because the boundary editor lives against the bottom of the viewport, its
  choices now open upward. Dropdown choices use a bounded vertical
  `ScrollingFrame`, so all marking types remain reachable instead of only the
  first row being visible below the screen edge.
- Regional Preference gained a **Data Safety** section. **Back up data** emits
  versioned JSON containing every current grand setting plus custom road and
  region presets. Studio plugins have no supported clipboard API, so the field
  is selected for the ordinary Ctrl+C flow.
- **Restore data** accepts pasted JSON, rejects malformed/wrong-format/
  unsupported-version/oversized payloads, sanitizes settings, filters malformed
  custom presets through the existing deserializers, and reports valid preset
  counts. Applying it requires a separate red **Restore now** confirmation and
  activates the restored libraries immediately.
- Placed roads are deliberately excluded: their data already lives in the
  place, while this backup protects plugin-global preferences and presets.

## Road Asset export to Workspace

The Road Assets manager can now clone a selected stored viaduct/tunnel module
back into Workspace for inspection or editing. Export preserves the library
asset and its metadata/usage count, chooses a non-conflicting Workspace name,
selects the new Model, and records the operation as one Studio Undo step. The
action remains visible but disabled until an asset is selected.

## Error-bounded curved and superelevated surface optimization

Curved roads now coalesce adjacent compatible Drive surfaces without touching
the original cross-section or its marking boundaries. Flat and constant-bank
intervals greedily merge only while their midpoint boxes stay inside a
0.025-stud plan-overhang budget; changing-bank intervals apply a separate
0.025-stud twist-error budget. Both fall back to the existing per-lane emitter
when a wider band cannot be proven safe. Profile widening/narrowing and bus-bay
slices remain on the conservative coalescing path.

`Superelevation.BuildProfile` now owns one deterministic, arc-length-weighted
roll curve independent of preview/final mesh density. `RoadBuilder.StationPlanFor`
returns the exact final stations and rolls consumed by emission, checking both
quarter probes and every enclosed canonical control so narrow bank humps cannot
be skipped. Procedural viaducts and tunnels interpolate that same profile and
refine rigid shell ranges to a structural seating-error budget; marking roll
lookup is now logarithmic instead of scanning every station for each span.

The new Python 3D contract renders bird's-eye, outside-edge side, and five
cross-section views. Its six-lane cases measure 44.4% fewer surface Parts on a
gentle curve and 2.7% fewer through a six-degree runoff, with zero outer-edge
displacement, 0.0206 studs maximum bank twist, and 0.0209 studs maximum curved
box overhang. Live Studio appearance and build-time measurements remain the
final verification step.

## Roundabout approach compatibility, lane advice, seam ownership, and Turbo width parity

Roundabout conversion is now profile-driven rather than category-gated. Highway
profiles, directed one-way roads, and legacy/custom single-Drive profiles can
all form mouths. The missing exact outer-band crossing helper used by solo
one-way mouths has been restored with deterministic sampling plus bisection.
An undirected single Drive is no longer cut into two half-width lanes; it keeps
its full width through the shared entry/exit flare. Shoulders remain reserve,
not traffic lanes. Solo one-way highway mouths retain independent left/right
shoulder widths, taper both surfaces to zero, and preserve the asymmetric live
lane centre instead of carrying either shoulder into the ring as a lane. Only
the solo arm's traffic-outboard pavement reaches the ring footway; its inboard
pavement tapers to zero before the circulating carriageway.

The junction editor now suggests the circulating-lane count from the widest
connected motor carriageway. It counts only positive-width `Drive` components,
separates carriageways at medians, and counts opposing directions independently:
3/2 suggests 3, an undivided 2+2 suggests 2, and a five-lane one-way road
suggests 5. The suggestion follows selection/profile changes until the user
edits the lane field, then preserves that explicit override.

Two separate mouth ownership errors are fixed in source. The controller-side
end of a trimmed source road can now end raised Sidewalk/Median components on
the exact station plane, while interior RoadBuilder intervals keep their normal
overlap. At the ring, outer arm edge paint is preserved to its actual tangent
handoff and the ring edge opening uses the full marking sector; surface Parts
still use the conservative pavement sector. Arm surfaces remain sunk, but
paint stays on the normal marking plane.

Turbo no longer guesses exit lane boundaries by dividing arm width by the
edited ring lane width. Each peel resolves the exit profile's actual adjacent
Drive/Drive boundary, eases from the circulating divider radius to that real
handoff radius, and follows the arm line. The ordinary concentric divider is
clipped only over the peel-owned arc, preventing its short dash phase from
filling the Turbo line's deliberate gaps. The Python bird's-eye port and static
contracts use the same edited-width and replacement-sector rules.

The remaining conversion limit is structural rather than categorical: an
editable connected approach must still have exactly one source segment and no
unsliceable transition, bay, or marking/kerb stretch. Multi-segment parallel
carriageways remain a follow-up. Headless contracts pass; the rebuilt plugin
still needs the requested Studio visual check.

## Persistent selectable roundabout editor

Selecting a generated roundabout ring or arm now opens a dedicated React-Lua
editor for radius, circulating lane count, lane width, Continuous/Solid/Turbo
markings, pavement, and centre island. Every edit is one Studio undo recording;
the visible ring Model is rebuilt in place so Selection and non-EasyRoad custom
attributes survive. The panel also exposes geometry diagnostics, standalone
deletion, and connected conversion back to an ordinary junction.

Connected builds now retain their original Junction as a
`Kind = "Roundabout"` topology controller. Road ends keep stable controller,
road, and port ids. Rebuilds use only that controller's exact connected-road
set; proximity discovery is restricted to initial placement/connection. Legacy
connected rings remain read-only because their original road sources are not
recoverable. Approach trims derive from a durable source segment and preserve
the untouched far end, raw/custom attributes, structures, bus stops, and
source-relative coordinates. Transition profiles, bays, and marking/kerb
stretches are rejected before mutation until safe source slicing exists.
Removing an approach rebuilds
the remaining ring; removing the last deletes its controller; deleting a
connected ring directly restores an ordinary junction.

`roundabout_editor_preview.py` adds a before/after UK bird's-eye contract using
the canonical roundabout component renderer, including editable lane width,
appearance toggles, mouths, seams, and marking ownership.

## Selectable centre/left-edge/right-edge road snapping

Road Tools now shows a persistent **Snap point** dropdown whenever **Snap to
existing road** is enabled. It offers Road centreline, Left roadway edge, and
Right roadway edge. Roadway edges come from the first/last paved-roadway
components rather than the profile's outer extent, and their world positions
use the target curve's banked frame.

The magnetic position is no longer also assumed to be the topology anchor.
Each clicked snap stores the target road identity, original centreline station
or endpoint, centreline topology position, shifted visible position, and
tangent. Post-commit endpoint connections therefore reuse the exact road end,
while mid-span connections split at the exact original centreline station even
when the chosen edge lies outside the normal snap radius. A two-road junction
is only classified as a seamless pass-through when both actual centreline ends
coincide with its node; matching tangents on a laterally offset connection no
longer suppress the junction surface.

Widening/narrowing roads remain endpoint-only snap targets because their
mid-span split is intentionally unsupported; the two endpoint references use
their exact ProfileStart/ProfileEnd widths.

## Exact roundabout mouth-sector clipping

The live Studio comparison confirmed why the Python render looked cleaner even
after the marking-plan port: `openRingPavement` decided whether to remove each
ring sidewalk or outer edge-line Part from its **centre point only**. A Part
whose centre sat just outside the mouth still had a long tangential corner
inside it, leaving the concrete wedges and white slashes visible in the report.

The live builder now measures every candidate Part's full top-face angular
footprint. Parts wholly inside the mouth are removed; boundary straddlers are
clipped against the exact radial sector ray and their outside polygon is rebuilt
with exact triangles. Keeping that fragment matters: deleting the whole
straddler removed the visual intrusion but opened 6-7 stud holes in the sparse
three-leg UK case.

The Python preview uses the same polygon clip and now fails if any retained ring
sidewalk/edge-line vertex lies strictly inside a mouth sector. The standard full
validator and the extended small-radius, five-leg, stress, turbo, and highway
matrix report zero boundary intrusion and flush seams. The one documented
`stress_us` arm tear is unchanged and remains the sole known-open failure.

## Preview-matched roundabout markings and exact approach caps

Generated roundabout rings and arms now use the accepted Python preview as
their marking appearance contract instead of falling through to marking rules
tuned for ordinary straight roads. A roundabout-owned plan emits solid white
roadway edges, 3m/3m dashed white Drive/Drive dividers, solid
Drive/Shoulder separators, and solid circulating dividers in SolidLanes mode.
RoadBuilder accepts this plan through an internal optional hook; ordinary roads,
regional styles, marking stretches, kerb restrictions, and the Road Editor keep
using Markings.Compute unchanged. Roundabout dash phase now also starts at the
curve origin and retains the final partial dash, matching the Python renderer.

At constant-width approach seams, only the raised pavement strip touching the
approach cut is replaced by exact station-edge triangles. This removes the
rotated padded end cap that could project across the adjoining carriageway
without deleting the padded interior/ring-end overlap needed to keep the mouth
closed. Width-changing pavement and shoulder tapers retain their full exact
triangle chain. Per-roundabout sidewalk/marking overrides now flow consistently
through ring, mouth, and arm construction.

The Python port models the same cut-cap rule, and the dump comparator no longer
silently grows a requested radius that the live builder honours. The quick
roundabout cases, parity checker, and static integration contracts are clean;
Studio confirmation remains required for actual Part rendering and z-fighting.

## Cross-platform StyLua formatting gate

The repository now carries `.stylua.toml` with Luau syntax, tabs, and LF line
endings plus matching Lua/Luau rules in `.gitattributes`. A plain
`stylua --check <touched files>` therefore evaluates the same source bytes on
native Windows, WSL, and Linux CI instead of producing platform-only CRLF
drift. The seven source files from the structure/straight-optimization round
were formatted with `stylua --verify`, which reparses the output and confirms
its AST matches the input. Rebuilt `dist/EasyRoad.rbxmx` afterward.

## Independent structure finishes and twin-pillar viaduct bents

Procedural structures no longer share one hard-coded concrete appearance.
Each road serializes a base/pier finish, a separate viaduct edge-wall finish,
and separate tunnel side-wall and roof finishes; every finish has its own
Roblox material and colour. Settings exposes the same groups as defaults for
new roads. Imported Roblox Models retain their authored appearance, while a
custom viaduct can still use the base finish for EasyRoad-generated supports.
Older road/settings JSON migrates to the previous grey Concrete appearance.

Viaduct supports now expose the existing pillar width clearly and add Single
or Twin layout. Twin stations raycast both column centres independently and
emit the pair atomically, then place a transverse cap beam under the slab.
Centre separation plus cap width, height, and depth are editable; cap width is
clamped to cover both pillars. The updated Python structure preview renders the
twin cross-section and distinct finish channels and asserts cap coverage,
terrain contact, base clearance, wall compensation, and tunnel-vault joins.

## Exact-straight surface coalescing with preserved raw road data

RoadBuilder now has a conservative straight-road fast path. Only a monotonic,
collinear set of line/Bezier control points with a constant cross-section can
use it; shallow curves, transitions, and sliced bay geometry keep the existing
adaptive emitter. Compatible surface ranges are emitted in Parts no longer
than 2048 studs, with marking and kerb-stretch endpoints retained as hard split
points. A 5000-stud straight therefore uses three longitudinal ranges instead
of 625 default 8-stud intervals.

Adjacent identical Drive lanes on that path are one asphalt surface band, but
their lane mathematics are unchanged: markings still compute from the original
profile components. Generated surfaces carry source component-index and station
ranges, while the parent road keeps its full serialized curve, profiles, bay,
stretch, junction, and structure metadata. Editors and rebuilders continue to
read that authoritative Model data rather than infer anything from Part count.

`straight_optimization_preview.py` checks the 2048 boundary cases, 4096+ runs,
forced edit splits, material/colour mismatches, Drive-only compatibility, and
the source-metadata contract. Its before/after render measures a 5000-stud 3+3
boulevard at 5625 -> 15 surface Parts (99.73% fewer); live Studio timing and
place-size benchmarking remain follow-up measurements.

## Explicit between-lane marking editor and editable centre-line stretches

Road Editor no longer presents `RightBoundary` as if it belonged to whichever
lane tile happens to be selected. A **Show lane markings** control reveals a
real marking selector in each gap between adjacent Drive lane tiles. The glyph
previews the region/default or explicit single, double, dashed, or mixed rule;
selecting it opens a boundary editor that names both neighbouring lanes. Lane
width, direction, reorder, and removal remain on the lane tile itself. Hiding
the markings returns the compact cross-section, and the strip is shorter now
that marking and lane controls share one context-sensitive row.

Opposing traffic is no longer a special uneditable hole. Every Drive/Drive
boundary is now a valid Road Editor and marking-stretch target. The centre line
keeps its region centre-line colour and dash rhythm under Auto, but explicit
boundary rules and longitudinal marking stretches run through the same splice
pipeline as ordinary lane lines. **All** still selects only one same-direction
lane group; an opposing-direction centre line is deliberately a one-boundary
group. Static integration contracts guard the centre-line hit test, render
splice, between-tile selector, and removal of the old lane-owned field. The
standard validator also runs `marking_boundary_preview.py`: its UK-style 3+3
road asserts the two same-direction groups plus the singleton centre boundary,
and renders the selected centre-line stretch in amber for visual QA.

## Thin procedural bases with downward-compensated walls

The broad procedural base could visually cover the road surface, especially
with a large interface-overlap setting. Both structure types now use a thin
central base (`0.2m`, with a small stud minimum), and overlap is capped so its
top remains at least 0.08 studs below the road surface.

The lost depth is kept at the edges instead of under the entire carriageway:
viaduct parapets now continue downward as fascia walls to the original deck
depth, and tunnel sidewalls continue below the shortened base to the original
shell depth. Piers terminate against the new central-base underside. The Python
structure preview measures the surface clearance, the shorter bases, the
downward wall compensation, pier contact, and tunnel-vault continuity.

Added `OPTIMIZATION.md` as the dedicated performance backlog. Its first two
targets are up-to-2048-stud Parts for compatible straight runs and lateral
coalescing of adjacent identical lane surfaces, with explicit split conditions,
measurement requirements, and correctness gates. These optimizations are
planned, not claimed as shipped.

## Selected-junction panel opens instead of crashing in radius advice

Studio selection was working: the junction Model selected in Explorer and the
cyan corner handles appeared. React then crashed while mounting `JunctionPanel`,
so the editor itself looked absent. The Output stack traced this to
`packingRadiusStuds`: `armProfileFor` gained a required ring-pavement-width
argument during the highway taper work, but the panel's suggested-roundabout-
radius path still called it with five arguments. That created a Sidewalk with
`WidthM = nil`, which failed in `RoadProfile.TotalWidthM`.

The packing path now supplies `ringSidewalkWidthM(style)`, matching the real
roundabout mouth builder. The optional radius advisor is also isolated behind
`pcall`; any future malformed approach can disable the two advisory figures and
warn without taking down the junction editor, its corner controls, or rebuild
actions. `integration_contracts.py` guards both the missing argument and the
panel-level failure boundary. Rebuilt `dist/EasyRoad.rbxmx`; live confirmation
still requires reinstalling that file and selecting the junction again.

## Multinode junction controller and per-corner turn radii

Ordinary intersections still have one logical owner `JunctionNode`, but their
editable topology is now decomposed into stable approach ports and stable
corner nodes. Every road receives a persistent `RW_RoadId` plus independent
`RW_StartPortId` / `RW_EndPortId` identities; each corner id is the ordered pair
of its angular-neighbour endpoint ports. Re-enumerating connected roads
therefore no longer renumbers a corner control. Road splitting preserves the
original outer port ids, so editing a remote mid-span does not discard existing
corner overrides at either end.

The junction editor exposes a **Link all corner radii** toggle. Linked mode is
backward-compatible with the old single radius; unlinked mode lets a cyan
viewport corner handle be selected and assigned its own radius. Overrides are
serialized on the junction and `JunctionBuilder` resolves the matching radius
while constructing each curb-return boundary. Old junctions read as linked and
migrate without losing their existing radius.

`multinode_junction_preview.py` now shares `preview_core` with the roundabout
preview instead of drawing an idealised lane diagram. Its bird's-eye render
uses EasyRoad Drive/Median/Sidewalk component tuples, UK left-hand direction
ordering, UK dimensions, the shared material colours, and white road markings.
The `uk6x4` case joins a custom 3+3 boulevard to the exact built-in UK 2+2
avenue profile. Matching `*_parts.png` and magenta `*_gaps.png` views check the
component-width mouths and triangulated pad. A third `*_controls.png` view
highlights the selected curb return and labels all four stable corner ids and
independent radii. Repeatable `--radius "CORNER=METRES"` arguments rebuild the
same scene with overrides, so radius adjustability is visible rather than only
asserted. The preview is part of the standard validator.

## Procedural gap controls, parallel carriageways, and one-way highways

Procedural viaduct slabs now overlap the road underside by a configurable
amount, parapets default to meeting the road edge exactly, and viaduct/tunnel
Parts receive longitudinal outside-edge allowance through bends and grades.
Road Tools Advanced and Settings expose concrete colour, interface overlap,
parapet gap, tunnel wall clearance, and the viaduct concrete-median toggle.
Pier controls and the other detailed structure fields are collapsed until
requested.

Road Tools can place 2-16 parallel carriageways from one clicked alignment.
Curves are represented by six fitted lateral-offset cubics per source segment;
two-roadway groups can automatically oppose directions based on regional drive
side, while larger groups expose a reverse toggle per roadway. Generated Models
carry a shared group id plus index, offset, count, and direction attributes.
The Highways category now includes one-way 1-5 lane profiles with shoulders.

The Road Editor and placed-road designer are now 440 pixels tall. Its fixed
190-pixel lane strip previously left only 162 pixels for the property and
library cards, less than the library list itself, which caused both columns to
overflow behind the strip.

`parallel_preview.py` renders the opposed-pair and four-roadway cases and checks
the offset fit between control stations. `structure_preview.py` now asserts
that the procedural slab/base overlaps the road and the default parapet has no
lateral edge gap.

## Dedicated Road Assets UI and real procedural structure defaults

The React-Lua top mode bar now separates **Road Assets** from **Road Editor**.
Road Assets owns Workspace Model import plus stored-asset selection, rename,
usage count, and safe deletion; deletion is refused while any placed road still
references that asset. Road Tools and placed-road editing no longer show an
import button and stay focused on choosing/configuring a structure.

The standalone cross-section editor and placed-road designer were lowered to a
360-pixel bottom surface with a 16-pixel margin, instead of covering roughly
420-470 pixels of the viewport. The Software dock now describes easyRoad only.

No-asset viaducts now generate an actual concrete structural slab and continuous
edge parapets in addition to terrain-projected piers. No-asset tunnels now
generate a base, tall sidewalls, and a nine-panel elliptical vault instead of a
flat three-Part box. The user's five `hardware/*.rbxmx` viaduct/tunnel Models
are checked-in geometry references; a new XML checker confirms their structural
cues, and the Python structure preview validates/renders the slab, raycast-pier
elevation, and arched tunnel cross-section. Terrain excavation remains explicit.

## Studio-facing structures, selectable junctions, and Software settings

The structure system is available in **Road Tools** instead of being reachable
only after placing a road and opening its inspector. Ground, Elevated viaduct,
and Tunnel modes, stored-asset selection, pier settings, and status are
available before placement; import/management now lives in Road Assets. Every committed road is stamped and
rendered immediately, and the choice remains active for chained segments.

Viaduct mode raycasts at least one candidate support on a short span instead of
silently producing a floating road. Tunnel mode no longer fails when no custom
asset is selected: it generates concrete side walls and a roof sized to the
road's cross-section. Imported socketed modules still override that default.
Terrain carving remains explicit and unimplemented because implicit carving
cannot restore arbitrary removed terrain safely.

The existing junction editor was wired but its visible `JunctionSurface` Parts
were `CanQuery = false`, preventing the Studio selection hit the editor depends
on. Those surfaces are now queryable; road placement already excludes the whole
Junctions folder from ground raycasts. A Python static integration check locks
that selection and UI wiring in place.

Settings now includes a local **Software** dock with easyRoad build and product
information.

## Custom structure Models, viaducts, tunnels, and raycast piers

Placed roads now have a serialized structure configuration in addition to
their procedural cross-section. In Road Tools or the Road Inspector a user can
choose Ground level, Elevated viaduct, or Tunnel. Selecting a literal Workspace
`Model` imports a clone into the game-owned
`ServerStorage/EasyRoadAssets` library as the selected viaduct/tunnel module.

An imported Model may provide `EasyRoadStart` and `EasyRoadEnd` Attachments.
When they are absent, the importer creates transparent bounding-box sockets so
an ordinary Model remains immediately usable and tells the user that explicit
sockets will make the joints more precise. The renderer walks the road by the
socket-to-socket chord length, aligns anchored clones to the curve, and overlaps
the final module when necessary rather than leaving an uncovered tail.

Viaducts can use the ordinary generated road as the deck with no imported
module. Optional concrete piers are stationed independently of road strip
sampling and raycast vertically to Terrain or world parts, with configurable
spacing, width, depth, vertical module offset, and maximum drop. Ground-level
hits do not create decorative stubs. Tunnels use an imported shell module when
selected or a generated concrete shell otherwise; Terrain excavation is
deliberately not implied or performed.

The configuration and generated children survive lane/marking edits, bus-bay
rebuilds, road splits, junction approach trimming, and roundabout spoke
trimming. `tools/preview/structure_preview.py` ports the socket stepping and
terrain projection, asserts continuous module coverage/pier contact, and
renders viaduct plan/elevation plus tunnel plan as a PNG. This is headless and
still needs a live Studio check; Roblox Model contents, collisions, Attachment
orientation, and actual raycast filtering are outside the Python model.

## Highway shoulders and pavement taper into a two-lane roundabout arm

A motorway approach has shoulders but no footway. Roundabout arms still need
the ring's pavement at their merge, because `openRingPavement` removes the
ring-owned strip across each mouth and the arm replaces it. Keeping that
pavement full-width to the approach cut produced a measured 7.20-stud edge
step; removing it instead opened roughly 6 studs of bare ground.

`RoundaboutBuilder.armProfileFor` now keeps only a zero-width Shoulder marker at
the ring-side boundary. That marker is intentional: `Markings.lua` sees
Drive/Shoulder and emits the continuous solid separator, but the shoulder can no
longer be counted or rendered as a third running lane. `buildArm` lays the real
paved shoulder separately, smoothstepping it from its full source width to zero
at the merge. The two Drive strips stay fixed and feed the two circulating
lanes.

The pavement is coordinated with the same taper. It begins outside the current
shoulder edge, grows from the approach's real footway width (zero for a
motorway) to the ring width, and takes over as the shoulder disappears. This
keeps the whole mouth covered without recentering or sliding the travel lanes.

The Python emission port builds the same surfaces and now renders
Drive/Shoulder boundaries as solid instead of dashed. Measurements:

- `hw4`: 7.20 -> 0.00 studs
- `hw4us`: 7.20 -> 0.00 studs
- `hwmix`: worst seam 0.10 studs (flush threshold 0.50)
- every 3.3 m shoulder: 11.78 studs at the cut -> at most 0.02 at the ring

No mouth holes or visible ring gaps were introduced. `check_arm_kinds` now
asserts that the running surfaces keep their kinds while the ring-side shoulder
marker has zero width; `check_shoulder_tapers` measures the emitted polygons at
both ends. The three highway seam entries remain removed from `validate.py`'s
`KNOWN_OPEN`. Not yet confirmed in Studio.

## Cross-platform UTF-8 validation

`tools/preview/check_parity.py` now opens the Lua and Python sources as
UTF-8 explicitly instead of inheriting the host locale. Linux already defaulted
to UTF-8, but native Windows with a CP950 locale crashed before comparing any
constants. The checker now behaves the same on both platforms without requiring
`PYTHONUTF8` or `PYTHONIOENCODING` environment overrides.

The no-Rojo artifact builder now also forces LF output and sorts directory
entries by their raw filename string. Its previous use of host defaults made a
native-Windows build write CRLF and use `WindowsPath`'s case-insensitive order,
while Linux wrote LF and sorted case-sensitively. The latter reordered most of
the generated instance tree and produced a roughly 42,000-line artifact diff
from identical inputs. Repeated builds are now byte-deterministic across hosts.

Verified from native Windows under the normal locale: 25 shared constants agree,
the turbo and road break-tests pass, and the complete quick `validate.py` sweep
passes. Its three highway-seam exceptions were then closed by the newer entry
above.

## Highway shoulders reach the mouth as shoulders, and a preview past the roundabout

Historical first pass, superseded by the newer taper entry above: this fixed the
kind/order corruption but still kept the shoulder full-width to the ring. The
current implementation keeps its solid boundary and tapers its surface to zero.

Two things: the reported bug, and the tooling that should have caught it years
of rounds ago.

THE BUG. A shoulder is Direction = 0 roadway, so splitApproachLanes folds it
into whichever side it abuts and armProfileFor re-emitted every strip as
{ Kind = "Drive" }. A 2+2 motorway built 3+3 arms - wrong colour, and
Markings.lua puts a lane boundary between two Drive components where a solid
edge line belongs. LaneGroup now carries a LaneSpec { Kind, WidthM, Directional }
per strip.

Fixing that exposed two ordering bugs underneath, both invisible while every
strip came out as an identical-width Drive - reordering identical things changes
nothing you can see:

  - the undirected pass runs AFTER the directional one and appended as it went,
    so a shoulder landed at the inboard end of its group however far outboard it
    really sat. Indices are collected and sorted now
  - an arm whose own travel runs against the approach curve sees the
    cross-section MIRRORED, and nothing accounted for it. Which arm that is
    depends on the arm AND which end of the road the junction sits at:
    mirrored = (travelsInward == atStart)

Either one alone puts the hard shoulder on the gore side of the mouth, against
the splitter island. check_arm_kinds compares the built arm to its source group
as a multiset AND tests the shoulder is outboard, because the two defects mask
each other. Three break-tests, one per defect.

Left open and now MEASURED rather than suspected: the arm gets a pavement even
when its approach has none, stepping the roadway edge 7.2 studs at the cut. That
pavement is load-bearing - openRingPavement deletes the ring's own footway
across each mouth and the arm's is what covers the band. Removing it trades the
step for 6 studs of bare ground on the highway legs. Wants a taper. Carried in
validate.py's KNOWN_OPEN. The RoadBuilder half of the original report is still
untraced.

THE TOOLING. tools/preview only ever knew how to build a ring and its arms, so
every sliver gap and sawtooth on a plain curved road was found by a user in
Studio. The emission port was always generic, so it is now preview_core.py and
the roundabout is one scenario among others:

  - road_preview.py: straights, arcs down to R=30, an S-curve, avenues,
    motorways. Bare ground inside the road, edge sawtooth, broken edge lines
  - road_break_tests.py: reintroduces defects that actually shipped - no miter
    padding, farEdgePad, a missing edge line - and confirms each scan catches it
  - validate.py: one command for everything, with a KNOWN_OPEN table of
    (suite, case, check) triples that fail on purpose. It fails on a NEW failure
    and also when a known-open one starts PASSING, since a stale expected-failure
    list is the same trap as an invariant nobody re-reads

Both new road scans passed every case on the first run and both were measuring
nothing. The sawtooth scan compared adjacent samples, but a strip boundary is a
single jump with flat runs either side, so every jump was measured against a
zero and no sign change was ever seen. Its threshold was then a fixed 0.1 studs,
which the clean road's own miter breathing exceeded; it is now 1% of the road's
width, because the legitimate jitter scales with the road - 0.121 studs on a
40-stud road, 0.233 on an 85-stud one.

Also found while adding the highway cases: the preview spelled "is this
roadway?" as != "Sidewalk" where the Lua uses RoadProfile.IsRoadway, whose table
excludes Median. So on every median profile the preview adopted the median into
an arm while the plugin left it as the splitter gore. Two different roundabouts,
both reported clean, for as long as those cases have existed.

Also cleared while here: the preview's min_radius_studs still computed the OLD
packing number while calling itself a port of MinimumRadiusStuds, which has
meant the hard floor since the two were separated. Split into
suggested_radius_studs and a real min_radius_studs, so check_parity is clean
again. The floor lands at 18.6 studs for a 2-lane UK ring - the same place the
circulating_width sweeps independently found the geometry stops holding.

The core extraction is verified as a pure move: uk4 comes out at 1527 parts,
501 ring, 156 gore tris, 134 removed, identical to before.

Not confirmed in Studio.

## Roundabout: the turbo peel is two phases, and the check that missed it

Two things, one cause. The peel was fitted as a single curve across the whole
span and it kinked; the check that should have caught the kink was measuring
something else.

GEOMETRY. The peel is now the ring's own divider as far as the exit, then the
exit arm's own lane line, with nothing interpolated between them. Those two
already join: the arm merges tangentially to the ring and its outer edge lands
on the ring's kerb, so at the merge the arm's boundary k lanes in from that edge
IS the ring's boundary k lanes out from the island. Position and heading are
both continuous already, and the radius is monotonic by construction - phase one
holds it constant, phase two only runs outward.

The blend it replaces cured the earlier cubic's eight-stud sag but paired
mismatched parameters: at low progress it mixes a ring point with an arm point
40 degrees away, and the chord between them cuts inward. 1.4 studs on a 3-lane
ring - small, but a kink in the one line a driver is being asked to follow out
of the roundabout, and the two 3-lane cases were failing on it.

CHECKS. Three of check_turbo's rules have now been invalidated by design changes
they were not re-read against, and this round killed two of them.

  - "ends near any Marking" was real while Turbo suppressed the ring's lane
    lines and became a tautology the moment it stopped - the peel now lies along
    a ring divider for its whole first phase, so the nearest marking is ~0
    always, and the rule passed a peel rotated 40 degrees off its exit
  - scoping it to the exit arms' own markings was still not enough. Measured
    over the whole peel it ALSO passed the rotated peel, because a 30-degree arc
    and an 80-stud arm cross somewhere however they are turned

What it asks now is the narrow question: each peel's FAR END, against the lane
lines of the exit it was built for, keyed per (exit, divider) so a ring handing
three of four boundaries over correctly cannot cover for the fourth. The exit
arms' markings are kept by identity as they are emitted rather than found later
by name, the same fix the gore triangles needed - every marking in the scene is
called "Marking", so any search matches the line the peel starts on.

Eight turbo cases clean, including the two 3-lane ones that were failing:
uk/us 2-lane 4-leg, 1-lane fallback, skew, tight 3-leg, uk 3-lane with 2-lane
exits, uk 3-lane with 3-lane exits, us 3-lane 3-leg. Three break-tests written
one per rule - peel shoved 1.5 lanes off any divider, peel rotated off its
exits, peel run backwards - and each is caught by the rule it targets. Standard
bare-ground suite unchanged.

Not confirmed in Studio.

## Roundabout: turbo is a peel-off at each exit, not a spiral round the ring

Settled by asking rather than guessing again. Four rounds went into spiralling
the whole ring and every one was wrong in a different way; the user chose
"concentric ring, turbo on the arms" from a set of options, which is what the
reference photos show and what this now builds.

The ring's circulating divider is an ordinary concentric line under every
marking mode. Turbo no longer suppresses it (the RightBoundary = "None" trick is
gone from ringComponents) and instead draws a PEEL-OFF at each exit on top: a
short dashed line leaving the divider a share of the way back from the exit -
TURBO_FLING_FRACTION of the gap to the previous exit, so it scales with leg
count - and swinging out one lane width to arrive at the ring's outer edge
exactly on the exit. Dashes still walk backwards from that terminus so one lands
flush on it.

The four dead ends, recorded in ROUNDABOUT.md 3.8 so nobody repeats them:

  - migrate evenly across each arc: reads as a slow drift, loses the commitment
    a turbo is meant to signal
  - aim at the mouth CENTRE: the exit is not the centre. Kerb reached at 88.7
    degrees against an exit at 55.0, a half-mouth late
  - entry edge to exit edge: delivered exactly (53.9 vs 55.0) but drew nothing
    across the mouths, leaving the divider on ~30% of the ring
  - exit to exit: full coverage and correct delivery, but a 13-stud jump at
    every exit reads as two unrelated lines, and driving the divider to the kerb
    pinches the outer lane to zero exactly where a two-lane exit needs it widest

The last one is what settled it: a full-ring spiral cannot both stay
concentric-looking and hand off cleanly, because our exits are two lanes wide
and the ring only has two.

Still not built, and it is the other half of "turbo on the arms": lane arrows
and destination legends on the approaches, which is how a real turbo tells a
driver which lane to pick. Markings.lua work on ordinary one-way roads, not ring
geometry.

Six turbo cases clean; both break-tests still fail as they should. Bare-ground
scans unchanged.

Not confirmed in Studio.

## Roundabout: turbo divider round the whole ring, and dashed tighter

Reported as "why only 4 markings in the circle", with a close-up photo showing
the circulating divider running continuously past a mouth.

Both parts of that were right, and the second corrects reasoning from the
previous round. I had argued there should be no boundary between a mouth's exit
and its entry, because the outer lane has left and the entry's has not joined so
there is one lane and nothing to divide. That was over-thinking it; the photo
shows the divider carrying straight on. Since a mouth spans Ahead + Behind ~= 62
degrees at default splits, excluding them left the divider on barely 30% of the
ring - eight dashes for a whole roundabout.

Arcs now run EXIT TO EXIT, which covers the full circle while keeping the
delivery property the round before that was fixed to get: each arc holds its
radius, flings out to the kerb at the exit that ends it, and the next arc
restarts inside. There is a deliberate step at every exit - that step IS the
hand-off - and unbroken marking everywhere else. 48 dashes on a 4-leg 2-lane
ring against 8, all four exits reached at r=79.3 against a kerb of 79.5.

Dash geometry is now TURBO_DASH_M / TURBO_GAP_M (1 m / 1.5 m) rather than the
region's open-road LaneLine. At the region default of 1 m / 5 m a whole quadrant
carries about five dashes and the ring reads as unmarked. A circulating divider
is short-dashed on purpose - it is telling you not to drift between lanes, not
merely separating them - and the reference is nearer 1:1.5 than 1:5.

Three rounds on this one marking, each fixing a real defect and each exposing
the next: even drift, then late delivery, then no coverage. All three were only
visible in a render or a photo; every automated check was green throughout, and
the delivery invariant only exists because one of those rounds made it
necessary.

Six turbo cases clean; both break-tests still fail as they should.

Not confirmed in Studio.

## Roundabout: aim the turbo fling at the exit, not the mouth centre

Correcting the previous entry, on a report that the boundary was "still drifted,
not seamlessly to the exit". It was, and the numbers say so plainly: on a 4-leg
ring the 90-degree mouth's exit edge sits at 55.0 degrees, and the boundary was
only reaching the kerb at 88.7 - still drifting 34 degrees after the traffic it
is meant to deliver had already left, touching the kerb halfway across the
opening. Now 53.9 against 55.0.

The previous round moved the arcs from the mouth SECTOR EDGES to mouth CENTRES.
That was my mistake. The sector edges are the entry and exit splits inset by
SECTOR_INSET_RAD - they ARE the hand-off points - and aiming at the centre put
the completion a whole half-mouth late. The real defects that round were the
even drift across the arc and the dash phasing, both of which are fixed
separately and stay fixed.

Between a mouth's exit and its entry there is now deliberately no boundary: the
outer lane has left and the entry's has not joined, so there is one circulating
lane there and nothing to divide.

KNOWN CONSEQUENCE, worth reading before anyone "fixes" it. That leaves the
divider on only about 30% of the ring. A mouth spans Ahead + Behind ~= 62
degrees at default splits and does so REGARDLESS OF RADIUS, because
SPLIT_ANGLE_RAD is an angle and not a length - so four legs occupy ~250 degrees
of any 4-leg ring and only ~110 is genuine two-lane running. The markings are
right; the mouths are wide. Narrowing the split is what would make a turbo ring
look like the reference aerial, and that is an arm-geometry decision, not a
markings one.

check_turbo's delivery invariant now targets the exit edge rather than the mouth
centre. Six turbo cases clean, all break-tests still fail as they should.

Not confirmed in Studio.

## Roundabout: island nose taper, and turbo markings corrected against a reference

Both found by looking at the renders. Every automated check was green through
all of it.

THE MOUTH INDENTATION, AGAIN. With the bare ground gone the mouth still read
wrong, and the zoomed render says why: the splitter island stopped dead at the
2 m width crossing in a blunt flat chop across the middle of the carriageway,
with both arms' edge lines carrying on past it. A real splitter tapers to a
point. It now grows a nose back down the approach over ISLAND_NOSE_TAPER_M
(6 m), each rung the gore scaled about its own midline so it closes to a point.
The nose sits ON the apron rather than replacing it - the apron is flat asphalt
at deck level and the nose is raised, so the wedge either side stays
carriageway. Bounded, so this is a nose and not the knife-edge sliver that
filling from the cut produced.

TURBO MARKINGS, two corrections.

First: the arcs ran between the mouth SECTOR EDGES. That completed the outward
migration a few degrees early, left the boundary hanging in mid-carriageway and
blanked every mouth of circulating markings - a bare band of asphalt at each
leg. Arcs now run mouth CENTRE to mouth centre, so the boundary reaches the
outer edge exactly where the exit is and the spiral is continuous all the way
round.

Second, from an aerial the user supplied, and the bigger one: the migration was
spread evenly across each arc, so the divider climbed steadily from island to
kerb over a whole quadrant. The reference does something different - the divider
holds a CONSTANT radius for most of the way round, exactly like an ordinary
concentric lane line, and is flung outward into the exit over a short run at the
end. It is also dashed, not solid. Both fixed: TURBO_FLING_FRACTION = 0.35 of
each arc, smoothstepped, dashed on the region's own LaneLine geometry.

Dashes walk BACKWARDS from the exit so one lands flush on it. Starting from the
other end leaves the pattern wherever it happens to run out, and on a 65-degree
arc that was 22 degrees of unmarked fling right at the mouth - the one part of a
turbo boundary that has to be marked, because it is where the lane is handed to
the exit.

check_turbo's "no spiral inside a mouth sector" rule was REPLACED, not relaxed.
Crossing the mouth is correct now so the rule was wrong, but deleting it would
have left nothing checking the mouths at all. It is now "the boundary must reach
the outer edge at each mouth centre" - the delivery property itself. All three
deliberate break-tests still fail as they should, including winding the spiral
the wrong way round.

Six turbo cases clean: both hands, 1/2/3 lanes, a 65-degree skew, a tight
3-leg. Bare-ground sweeps clean across 16 radii and 8 profile variations after
the taper.

Not confirmed in Studio.

## Roundabout: stop the splitter island paving the circulating lanes, and re-derive the minimum radius

Started as "re-derive MinimumRadiusStuds", which needed a definition of failure
that is not bare ground. Bare ground cannot answer the question at all: a
too-small ring fails by being COVERED, not by being empty. At R=10 a 4-leg 2+2
comes out as a four-pointed raised star with a hexagon in the middle and no
circulating lane anywhere, and scan_gaps calls it clean because nothing is
missing.

So a new check, `circulating_width`: sweep every angle radially from the island
to the kerb and total the deck-only run. The minimum over all angles is how wide
the ring gets at its tightest, and a ring narrower than a lane is not a
roundabout. The overhang check cannot stand in for it, and for an instructive
reason - it deliberately excludes the splitter islands by identity, because a
splitter IS raised material inside the mouth's lateral span and flagging it was
pure noise. Right for that question, blind to this one, where the splitter
islands are exactly what is wrong.

### The defect it found

Not a small-radius problem: a BAND. 4-leg 2+2 held a full 2 lanes from R=25 to
R=40, then dropped to 0.58 lanes at R=45, 0.96 at R=50 and 1.75 at R=60 before
recovering by R=70. After the fix those three read 2.00, 2.00 and 2.00. Same
shape on a 1+1 ring from R=22 to R=40. The render shows it plainly - blocks of
raised pavement sitting on the circulating carriageway at each mouth.

Cause, and it was mine: the flat-apron change earlier the same day retired the
outer-edge override, and with it the guarantee that the island starts outside
the ring kerb. On a crowded ring the 2 m width test can first be met at a
station already past the kerb. The rung loop then keeps its first rung - its
break only fires from i > 0 - the nose fan runs from that deep apex out to the
kerb arc, and the mouth gets a raised wedge laid across the circulating lanes.
Measured at R=45: gore material from r=36.1 out to a kerb at r=54.5.

Fixed by computing the kerb crossing as well, and refusing to start a raised
splitter past it - that mouth gets apron only, which is what a mini-roundabout
looks like anyway. The apron and the island want opposite roundings of that one
crossing: the apron stops one probe PAST it, the island must start one probe
BEFORE it. Stopping the apron exactly at the crossing left a 0.25-stud hairline
of bare ground just outside the kerb, because the rung is a chord and the kerb
is an arc. Apron rungs are also sunk by ARM_SINK_STUDS now - the arms' Parts are
dropped after building but their curves are not, so an apron laid on the curve
sat a hair proud of the carriageway it is continuous with.

Whether this is the "clipping" reported live is NOT settled. It is the same
class - a wedge of raised pavement across the carriageway - but it sits at the
mouth by the ring, and the report described the arm's seam with its approach.
Recorded as a lead, not a closure.

### The minimum radius itself

Two different numbers were being asked of one function.

  - MinimumRadiusStuds is now the hard floor: the centre island's radius is
    radius - ringInnerHalfWidth, so below that half-width the ring's inner edge
    has passed the centre and the annulus is a self-overlapping disc. Closed
    form, exact, small.
  - SuggestedRadiusStuds carries the angular packing estimate that used to be
    called the minimum.

With the wedge fixed, the geometry holds down to R=18 on 4-leg 2+2, 4-leg 1+1,
3-leg 1+1 and 5-leg 1+1 - against packing numbers of 70.5, 42.8, 27.5 and 64.2.
Two to four times too conservative as a floor, and the real failure is a cliff
rather than a slope, which is why a conservative estimate never located it. The
radius is advisory now, so this matters: a minimum four times the truth teaches
people to ignore it.

Bare-ground sweeps re-run clean afterwards across the radius sweep and the
profile/leg-count variations.

Not confirmed in Studio.

## Roundabout: turbo markings

A third circulating-marking mode beside Continuous and SolidLanes, chosen per
roundabout in the junction panel or as a regional default. Neither existing mode
was a turbo - "continuous" is the ordinary dashed ring and "solid lanes" just
discourages weaving. A turbo is a spiral.

An earlier note claimed this needed a second ring generator because lane count
and lane centres vary with angle. It does not: the circulating carriageway is a
constant-width annulus, exactly what is already built, and only the boundaries
inside it move. Across each arc between two mouths every boundary migrates
outward by one lane width, from inner + k*w to inner + (k+1)*w. That conserves
the carriageway without conserving the lane count - the outermost boundary
reaches the outer edge, its lane having been delivered to the exit, and the
innermost lane arrives at the mouth two lanes wide for the next arc's new
boundary to split. A mouth is entered with L-1 lanes and left with L, the extra
one being the entry's own traffic. No special case per lane count.

Two things it deliberately does not go through:

  - not a RightBoundary rule, because a spiral is not a line style. Turbo sets
    the ring's lane boundaries to a new "None" BoundaryRule, which
    Markings.addLine already drops, and lays its own lines.
  - not RoadBuilder.Build, because the spiral needs the mouth angles and those
    are not known until every leg has been trimmed and planned - after the ring
    model exists. buildTurboMarkings emits its own parts, using two newly
    exported RoadBuilder constants for lift and thickness so the two sets of
    markings cannot drift apart in height.

Runs after openRingPavement: the spiral only covers arcs between mouths, so that
pass has nothing to remove, and going first would hand these parts to a
ringPavement list captured before they existed. Falls back to a plain ring on
one lane or one mouth.

The preview grew a matching port and, more usefully, `check_turbo` - invariants
rather than a re-derivation of the same formula, which would pass by
construction. It asserts the spiral stays between island and kerb, never enters
a mouth sector, starts one lane width off the island and finishes one further
out, and moves outward IN THE DIRECTION OF TRAVEL.

That last one earns its place. Breaking the build three ways on purpose: an
anchor at the ring centreline instead of the island edge, and ignoring the mouth
sectors, were both caught by the earlier checks - but winding the spiral the
wrong way round was not. On a symmetric ring it is geometrically
indistinguishable, right radii, right sectors, every other check green, and it
means the exact opposite thing: the outer lane flung inward. The travel
invariant catches it and nothing else does.

Clean on both hands and on 2 and 3 lanes.

Not confirmed in Studio.

## Roundabout mouths: close the indentation with a flat apron

The V-notch down the middle of every approach, reported more times than any
other defect and wrong in three different ways before this.

The wedge between a diverging entry and exit is unavoidable - they coincide at
the cut and part toward the ring - so the only question is what fills it. Every
previous answer treated `MIN_GORE_WIDTH_M` as a build-or-don't switch and so
answered "raised island, or nothing", which is a false choice: near the cut
that wedge is not a median at all, it is the approach's own carriageway fanning
out into the mouth. Filling the whole gore put a raised strip down a road with
no median; starting at the width crossing did the same thing thinner; starting
at the ring's outer edge left the wedge in front of it bare, which is the
indentation.

A mouth now has two fills - flat asphalt apron from the cut, raised kerbed
island from 2 m of gore width in - and the width test chooses which surface
rather than whether there is one. The two questions it was being asked at once
are separated: `MEDIAN_AT_CUT_M` (does this approach arrive with a median at
all, measured at the cut) and `ISLAND_MIN_WIDTH_M` (how wide before a splitter
earns a kerb; 2 m is the usual minimum for a pedestrian refuge, against the old
0.5 m that made the island start as a knife edge tens of studs out).

This retires the "start the island at the ring's outer edge" rule. Its job was
to cover the pavement `openRingPavement` deletes across the mouth sector; the
apron covers that band now, and with the right material - a mouth is exactly
where the circulatory pavement ring is interrupted by carriageway.

### The check was looking at the wrong ground

`scan_mouths` swept `cut - inward * at` while `inward` points from the cut
toward the centre, so it marched outward down the plain approach road instead
of inward into the mouth. Every "no bare ground inside the mouth envelope" it
had printed was about the one stretch of road nobody was worried about. That is
the same blind spot the function was written to close - `scan_gaps` only ever
looked at the ring annulus - reintroduced one line below the paragraph
describing it.

Correcting the sign failed three defects at once (uk3: 102 gore samples, worst
15.00 studs). Open gore also stopped being excused as by-design, since under the
two-fill rule no part of a mouth is legitimately bare, and `report()` started
folding mouth findings into its result instead of printing them and returning
clean.

Two more faults in the check surfaced while verifying the fix, both of which
would have made the next result untrustworthy: the envelope reached into a
neighbouring leg and called 44 studs of grass between two roads a tear inside
the mouth, and `min_gap` sat below the sample pitch so a single dark sample read
as a 0.33-stud hole. The envelope now walks out from the centreline and stops at
the first bare run wider than `max_skip`; `min_gap` is floored at two pitches.

A correction to the previous commit message: it claimed the sign fix reproduced
the clipping defect of ROUNDABOUT.md 5.4. It did not. All 4-75 overhang samples
were the splitter island, which is raised material strictly inside the mouth's
lateral span by definition and so is exactly what the overhang rule looks for.
The island is now excluded by identity - the gore triangles are tagged, not
inferred from position, since the asymmetric entry/exit split puts the gore
off-axis and defeats a centreline test.

Result: zero bare ground and zero overhang across 24 cases - 16 radii from R=10
to R=70, plus 5-leg, 4-leg 2+2, a 3/1 approach, two median profiles, pavement
off, island off, and a 65-degree skew. The R=34-38 band stays clean. Verified to
still have teeth by stripping the apron back out of a built scene, which is the
pre-fix geometry, and confirming it fails: uk4 back to 20 gore / 44 hole, uk3 to
66 gore.

Not confirmed in Studio.

## Roundabout: find approach roads by their nearest point, not their ends

Placing a roundabout sometimes ignored a road that was plainly next to it.
`collectNearbyRoads` measured each candidate by the smaller of its two
ENDPOINT distances to the centre, so any road whose closest point is mid-span
had both ends far away and was silently dropped - a road running past or
through where the roundabout is going, or a curved approach that bows out
before coming back in.

It now samples the curve for the road's true nearest approach and tests that
against `maxDist`. Measured against the old behaviour, with a 40-stud ring:

    case                              endpoint d   nearest d   was      now
    road ending at the mouth                60.0        60.0   found    found
    road passing beside, 30 off            202.2        30.0   MISSED   found
    road passing straight through          200.0         0.0   MISSED   found
    long road, ends far, grazes            305.9         0.0   MISSED   found
    road well away                         500.0       300.0   missed   missed

The `minDist` test deliberately still uses the ENDPOINT distance. Switching it
to the nearest approach too would reject strictly more roads rather than fewer,
since anything passing through the middle has a nearest approach near zero -
the opposite of the bug.

Worth recording because it looks wrong and is not: `ConnectRoad` re-collects
and connects every nearby road itself, so `Place` handing it `nearby[1]` is
not a "only connects one road" bug.

Not confirmed in Studio yet.

## Roundabout: match the centre island to the ring instead of a true circle

The ring is emitted by `RoadBuilder` as rigid strips, so its inner edge is not
a circle - it is a POLYGON inscribed in one, pulled inside the true radius at
every chord midpoint. The island was a single `Enum.PartType.Cylinder`, a true
circle of the matching radius, so it overlapped the ring's asphalt in a scallop
all the way round.

`RoadBuilder.StationsFor(options)` is new: the stations `Build` would use for
those exact options, without building anything. The station rule is adaptive
(chord tolerance against the road's own half-width) and re-deriving it inside
`RoundaboutBuilder` would have made the two agree only until someone retuned
`CHORD_TOLERANCE`. `Build` and `StationsFor` now share one private helper, so
there is still exactly one place that decides stations.

The island's rim is built by offsetting the ring curve's OWN station points
radially inward by the ring's inner half-width - not by reprojecting onto a
nominal radius. The ring is four Bezier arcs approximating a circle, and a
nominal radius would reintroduce that approximation's error, about 0.03 studs
at a 120-stud ring, which is the same size as the scallop being removed.

**The cylinder is kept when it is the better answer**, and the test is on the
scallop rather than the radius. Station count does not track radius the way one
would guess - it is set from the chord tolerance against the ring's half-width,
so a SMALL ring with a wide carriageway gets very fine stations (a 20-stud ring
runs to ~64) while a large one gets stations that are coarse relative to its
size. A radius threshold would have spent 300-odd Parts smoothing rings whose
scallop was already a thousandth of a stud. Measured:

    ring R   lanes   island R   stations   scallop   built as   parts
        15       1        4.9         96   0.0026s   cylinder       1
        20       1        9.9         64   0.0119s   cylinder       1
        30       1       19.9         67   0.0219s   fan           67
        40       1       29.9         73   0.0277s   fan           73
       120       1      109.9        114   0.0417s   fan          114
        40       2       23.4         83   0.0168s   cylinder       1
        60       2       43.4         91   0.0259s   fan           91

So it still falls out as "cylinder on small rings, fan on large ones" - just
derived rather than asserted, and it gets the two-lane cases right, where a
radius rule would have fanned a ring whose scallop was already invisible.

Worth stating plainly: the scallop this removes is 0.01-0.04 studs. This is a
polish fix, not a visible-geometry bug - the fan's own overlap is zero by
construction, since its rim vertices ARE the ring's.

All nine roundabout preview cases still report zero bare ground and a
0.00-stud approach/arm seam.

Not confirmed in Studio yet.

## Roundabout: cut roads that PASS the ring instead of dropping them

Fixing detection last round only moved the failure one step later.
`collectNearbyRoads` now finds a road whose closest point is mid-span, but
`ConnectRoad` then called `ringSideIsStart`, which picks whichever END is
nearer the centre - meaningless when both ends are far away - and skipped the
road. Same symptom as before, different cause, and it read to the user as the
detection bug never having been fixed.

`ConnectRoad` now runs a split pass first: for each nearby road it finds the
station of closest approach (coarse scan then a ternary refine) and, when that
station is genuinely interior, cuts the road there with
`RoadSplit.SplitAtJunction`, which stamps both pieces with this junction. The
two halves then come back through the ordinary approach path - the same shape
an X intersection is built with.

"Interior" uses the arm run as its margin, so a road that stops just short of
the ring is still treated as ending at it rather than being cut into a stub.
Decision rule, tested against synthetic layouts at outerR = 50.1:

    case                        nearest s   length   margin   action
    ends at the mouth                35.0     35.0     11.7   connect by end
    passes straight through         200.0    400.0     42.6   SPLIT
    passes beside, 30 studs off     200.0    400.0     42.6   SPLIT
    long, ends far, grazes centre   305.9    611.9     42.6   SPLIT
    stops just short of the ring     98.0     98.0     32.7   connect by end

`RoadSplit.CanSplitAt` still gates every cut, so roads carrying a transition or
a bay are left alone rather than split into something invalid.

Not confirmed in Studio yet - and the split path has no preview equivalent, so
only the decision rule above is machine-verified, not the cut itself.

## Roundabout: fix the bare-ground band at R=34-36

A band of bare ground appeared inside the ring at radii 34-38, up to 4.4 studs
deep, with clean geometry either side of it. My own regression, from the
`MIN_GORE_WIDTH_M` splitter change below.

Two distinct faults, both now fixed:

1. **Samples were dropped from a fixed grid.** The width test skipped leading
   samples with `continue`, but the same loop also breaks when a gore edge
   reaches the ring kerb - so on rings whose arms converge early the skipped
   samples were consumed and the break fired before enough rungs accumulated.
   The island came out truncated or was never built. Both implementations now
   RE-PARAMETERISE the rungs from where the gore opens, so the full
   `GORE_SAMPLES` resolution goes to whatever island is built.

2. **The island could start inside the ring's outer edge.** `openRingPavement`
   deletes ring pavement across the whole mouth sector out to that radius on
   the assumption the arms and the island replace it, so an island starting
   inside it leaves the deleted band bare. That was the bulk of the defect: at
   R=35 the gore reached only radius 42.3 while the ring's outer edge is 45.1,
   and **all 150** bare-ground samples sat in the 2.8 studs between them. The
   island start is now clamped to the outer edge - and stepped back one probe
   cell, since the probe grid would otherwise still land up to one cell inside
   it. Past the outer edge there is no deleted pavement to replace, so the
   width test is still free to trim there, which is what it was added for.

Bare-ground samples on a 3-leg 1+1 ring:

    R      before    after re-parameterising    after clamping
    34     172       158                        1
    35     250       150                        2
    36      34        57                        0
    38      38         0                        0

The remaining 1-2 samples are 0.13 and 0.21 studs deep against a 0.084-stud
sample pitch - at or below the 0.15-stud hairline threshold the ring rim
already reports as below visible.

A wider sweep (17 radii x 3-leg and 4-leg) shows residual samples at R=50, 60
and 80 as well - 5, 13 and 49. Those are NOT this defect: every one sits at
`island_r + 0.04`, i.e. within one 0.084-stud sample pitch of the island edge,
and the count grows with radius simply because the rim is longer. That is the
island-rim hairline this file already documents. The sweep called `scan_gaps`
raw; the tool's own `report()` path applies the 0.15-stud threshold and
classifies them as below visible, which is why `uk3` has always printed its 13
hairline clusters.

Worth recording: the first hypothesis was that `openRingPavement` deleted
parts by their CENTRE while their bodies extended past the sector edge. That
was wrong, and the probe killed it cleanly - all 250 holes sat INSIDE the
sectors, and the sectors are identical at R=33 (clean) and R=35 (broken).
Deletion was never the problem.

Not confirmed in Studio yet.

## Roundabout: stop the splitter island inventing a median

An approach whose road type has no median came out of the roundabout with a
raised strip down the middle of it, tapering to nothing — reported live as
"there is median when there is no median for the type of road used", with the
taper reading as an indentation.

The splitter island is filled between the two arms' INNER ROADWAY EDGES, and
it ran from the approach cut all the way to the ring. On an approach that has
a median those two edges start that median's width apart, so the gore is a
real one for the whole run. On an approach that has none they start touching,
and only separate as the arms diverge toward the ring — so the first part of
that fill was a raised median the source road does not have.

The fix is the user's own suggestion, applied to the gore width rather than to
a profile component: the island now starts at the first sample where the gore
reaches `MIN_GORE_WIDTH_M` (0.5m). Expressing it that way removes the need for
a "does this road have a median" test entirely — an approach with a median is
already wider than the threshold at the cut and is untouched, and one without
gets island only where its two carriageways have genuinely parted, which is
the part of a splitter that does real work. It skips leading samples only; a
later pinch mid-run is still carried through, which is what the waist note in
that function is about.

Measured in `tools/preview/roundabout_preview.py`:

- Island reach back from the ring grows with median width — 1.0m median: 6
  studs, 2.0m: 30, 4.0m: 38. Wider median, more island, as intended.
- Gore triangles on the standard cases roughly halved (uk4 and us4: 132 → 68).
- All nine cases (uk4 uk3 us4 stress stress_us liveX2 liveX4 liveT2 liveT4)
  keep zero bare ground and a 0.00-stud approach/arm seam.

A wide approach with no median still gets a long island, and that is correct
rather than a leftover: once the two arms have separated by more than the
threshold the space between them is a genuine gore, and filling it is the
right answer. The bug was only ever the near-zero-width part at the cut.

Constant is mirrored in the preview, so `check_parity.py` covers it (15
shared constants).

Not confirmed in Studio yet.

## Junction pad: fix the outer corner arc and make the fill defensive

A junction between roads meeting at a bend rendered as a jagged, spiked,
self-intersecting slab. The cause was one direction convention, and it is
provable rather than a guess.

`cornerBoundaries` took an `exterior` flag and, on any gap wider than 180
degrees, aimed its edge directions along `+outward` instead of `-outward`.
That is wrong: take an L of two roads of half-width w, with A's outer edge
running along `z = -w` and B's along `x = +w`. Those lines meet at `(w, -w)`,
the outside corner of the L, and from A's kerb point at `(-d, -w)` that vertex
lies in `+X` — which is `-outwardA`. The corner vertex is toward `-outward` on
both the short and the long way round; there is no side of a bend on which the
edges converge the other way.

The cost was not a poor fillet, it was **no** fillet. `Fillet.Compute`
correctly rejects a vertex sitting behind the ray, so every exterior span fell
through to the Hermite fallback, which was then handed mismatched directions
(`+outwardA` at one end, `-outwardB` at the other) and looped the outer
boundary back *across* the pad interior. The assembled outline crossed itself
at every bend from 45 to 150 degrees, and the centroid fan over that crossing
outline is what put spikes on screen.

Spans over 180 degrees are not exclusive to two-road bends: any junction whose
legs bunch to one side has one, so T, X and 5-leg nodes were exposed too.

Changed in `Mesh/JunctionBuilder.lua`:

- The `exterior` flag is gone from `cornerBoundaries`. Both sides aim at the
  corner vertex along `-outward`.
- The Hermite fallback is bounded. It is right for near-parallel edges but
  wrong for a sharp hairpin whose two trimmed ends have already passed each
  other, where chord-length tangents loop it out of the pad; a Hermite that
  strays more than 0.6 of its own chord is discarded for the straight chord.
- The pad is filled by **ear clipping**, following CART `JunctionTool`'s
  `_triangulatePolygon`, not a centroid fan. A fan is only valid for a polygon
  star-shaped about the point it fans from, and a pad carrying a corner
  treatment per gap is concave by construction — an L-bend has a short inner
  corner and a long outer wrap-around, and its centroid can fall outside the
  pad entirely.
- The outline is validated before it is trusted: duplicate and collinear
  vertices merged, then rejected outright if it self-crosses. Anything that
  fails drops to the convex hull of the kerb points, which is convex by
  construction and so always fillable. A blunter pad, never a torn one.
- `convexHull` itself is now trustworthy enough to be that fallback. It used to
  return three-or-fewer points unchanged, in whatever order the roads were read
  in — "already convex" is true of any three points and is not the property
  that matters, perimeter order is — and fully collinear input could empty the
  hull, which the caller then averaged into a NaN apex. Three points now go
  through the same chain construction as any other count, the chain trim is
  conditional, and a degenerate result falls back to angular order.

`tools/preview/junction_pad_preview.py` is new and is the regression test: a
line-by-line port of the real walk, scoring every case on whether the outline
self-crosses and whether the triangles tile the pad exactly once. It reproduces
the bug under `--legacy` (fan overdraw up to 800x) and passes all 66 shipped
cases at exactly 1.000 — two-road bends from 35 to 170 degrees, square, skewed
and bunched T and X, and a 5-leg node, across three road widths.

Not yet confirmed in Studio. The next live check is the shallow bend that was
reported, plus a T and an X.
## True X intersections and visible road snapping

Drawing a new road all the way across an existing road now creates a real
four-arm intersection. The placement flow previously inspected only the new
road's start and end positions, so its centreline could visibly cross another
road while neither endpoint landed close enough to trigger `findMidSpanMatch`;
the result was two unrelated overlapping roads. That limitation is removed.

- `Geometry/CurveIntersections.lua` flattens the pending and existing curves
  at short arc-length intervals, finds ground-plane chord crossings, then
  refines each candidate back onto the actual line/quadratic/cubic curves with
  a bounded Newton solve.
- Valid crossings are shown live as green **X INTERSECTION** markers. The hint
  states how many nodes the click will create. A final point near an endpoint,
  junction, or road centreline now moves there in the preview and gets a blue
  **SNAPPED** marker instead of connecting invisibly after the click.
- Commit groups every crossing by road and splits both the newly placed road
  and every crossed road around the same `JunctionNode`. Multiple crossings
  in one placement are supported and remain one Studio Undo recording.
- `RoadSplit.SplitMany` is the shared N-cut primitive. It preserves the old
  road's outer junction ids and assigns the caller-provided junction id to
  both pieces around every cut.
- Junction approach trimming now derives both ends from the same preserved
  source segment. A piece bounded by two intersections therefore keeps both
  trims; rebuilding one node no longer restores the other end.
- Crossings at a different deck height are treated as grade-separated. Near
  parallel contacts are ignored, avoiding accidental junctions between roads
  that merely run alongside each other.
- Unsupported cuts are explicit rather than silent: crossings involving a
  widening/narrowing road, bus bay, missing editable data, or cuts too close
  together show a red marker with the reason. Turning off **Snap to existing
  road** still bypasses every automatic connection path.

The existing endpoint, T-junction, Y-junction and roundabout attachment paths
remain in place. This round changes the missing interior-to-interior case and
the feedback around all placement snapping; it does not add transition/bay
subdivision.

## Behavioural dump: prove the preview and the plugin agree

`tools/preview` is a Python re-implementation of `RoundaboutBuilder.lua`, not
an execution of it, so "the preview says it is clean" only ever meant the
preview agrees with itself. `check_parity.py` closed the constants half of that
gap. This closes the behaviour half, which is the half that matters - two
implementations can agree on every number and still do different things.

Plugin side: `RoundaboutBuilder.DescribeJunction` prints every figure the
roundabout would be built from - per leg the mouth angle, split budget, split
and entry split, both merge angles, and per arm the merge radius, lateral
offset, outer/inner offsets and total width - plus the requested, minimum and
actually-used radius. Reached from a **Print geometry to Output** button on the
Junction panel.

Two properties it was built to have:

- **It reuses the real functions.** `planMouth`, `splitBudgetFor` and
  `resolveSplits` are called, not reimplemented, so the dump cannot quietly
  become a third implementation that agrees with neither. `resolveSplits` was
  extracted from `buildMouth` for exactly this - the split maths now has one
  home.
- **It does not build anything.** The trim station is found on the road's
  existing curve rather than by trimming it, so it is safe to press on a live
  junction.

Preview side: `tools/preview/dump_compare.py` prints the same fields, in the
same order and precision, for the same inputs, so a plain `diff` settles it.

Recorded in advance, because it is a known modelling gap rather than a
surprise: the preview's legs are radial, so its mouth angle is just the leg
bearing, while the plugin aims along the approach's own centreline via
`rayCircleFirstHit`. Those coincide only for radial approaches. Roads produced
by an X-split frequently are not radial - so `mouthAngle` is the field most
likely to differ, and that difference would be informative rather than a bug in
either side.

## Roundabout radius: suggest an optimal one, let the user decide

Following the radius floor, the Radius box no longer starts at a fixed 30. The
Junction panel asks the builder what these particular approaches need and
pre-fills a suggestion - `MinimumRadiusStuds` rounded up to a 5-stud step with
15% headroom, because the minimum is a hard floor where every mouth touches its
neighbour's kerb with nothing spare, and handing that over as the default gives
the tightest legal roundabout rather than a good one.

The suggestion follows the lane count and lane width, since those change what
fits, and stops following the moment the user types their own number - a stale
suggestion sitting in the box after changing lanes is how you build the tight
version by accident. The hint line underneath states the actual minimum and the
suggestion, and if the typed radius is under the floor it says so and that it
will be grown, rather than silently correcting after the click.

Both figures come from the builder via a callback the panel invokes with its
current lane settings, not a number computed once in `main.lua` with assumed
ones - the first cut of this hardcoded `laneCount = 1` and would have quoted the
wrong minimum for every multi-lane ring.

`check_parity.py` earned itself immediately: it failed the moment the two new
suggestion constants were added on the Lua side only, which is exactly the
silent drift it exists to catch. They are UI-side rounding with no preview
counterpart, so they are whitelisted rather than mirrored.

## Roundabout: enforce a minimum radius; parity check for the preview

Two live reports - an X intersection and a T turned into roundabouts - came out
cursed: a tiny island, mouths overrunning each other, and the splitter islands
collapsed into almond-shaped slivers. Reproduced exactly by feeding the live
settings (radius 30, 1 lane) into `tools/preview`.

**Codex did not cause it.** `RoundaboutBuilder.lua` is not in `6b1405d`'s diff;
the X-intersection commit only touched CurveIntersections, RoadSplit,
JunctionBuilder and createRoadSession. This was our own geometry failing below
a radius it never enforced.

The arithmetic, once measured: four 2-lane legs on a radius-30 ring demand
**479 degrees of a 360 degree ring**. Every leg needs two arms, a deflection
split between them and a strip of kerb before the next leg, and below a certain
radius those simply do not fit. `RoundaboutBuilder.MinimumRadiusStuds` now
solves

    sum(armWidth_i) / R + legs * (2*MIN_SPLIT + MIN_KERB_GAP) <= 2*pi

for R, using each arm's FULL width (pavement included - the kerb is what must
not overrun, and counting only roadway lets two mouths sit a pavement's width
inside each other), then converts back to the ring's centreline radius and also
requires the circulating carriageway to be at least as wide as the widest thing
merging onto it. `CreateAtJunction` grows the requested radius to meet it
rather than building garbage. The live cases grow 30 -> 43 (2-lane X), 30 -> 71
(4-lane X) and 30 -> 45 (4-lane T); a 2-lane T already fitted at 30.

**`tools/preview/check_parity.py`** is new, and answers a question worth asking
of any simulator: is it still the same algorithm? The preview is a hand-written
Python re-implementation, not an execution of the Lua, and nothing kept the two
in sync. It compares every constant present on both sides and flags orphans.
It immediately found two - `SPLITTER_WIDTH_FACTOR` and `MIN_GORE_WIDTH_STUDS`,
both deleted from the Lua rounds ago and still sitting in the preview. They
turned out to be dead there too, so no result was wrong, but that is luck
rather than process. It does NOT compare the algorithm; two implementations can
agree on every number and still differ.

Preview gains `liveX2/liveX4/liveT2/liveT4` covering the reported shapes. All
nine cases pass with a flush seam and no bare ground.

Still open and visible: the splitter islands go thin and needle-like once the
mouths are wide relative to the ring. That is the almond-sliver artifact in the
reports; the radius floor makes it far less severe but does not remove it.

## Roundabout: crash fix, direction-aware arms, mixed-approach stress test

**A crash shipped in `3fd2066` and broke Make Roundabout entirely.** A
pavement-width edit meant for `armProfileFor` landed in `ringComponents`
instead - the anchor text it matched appears in both, and the first match won -
leaving `ringComponents` referencing `spokeProfile`, a nil global. Every
`CreateAtJunction` and `Create` threw on its first line and the tool silently
built nothing. Fixed in `152b233`.

`tools/preview` did not catch it and structurally cannot: it re-implements the
geometry in Python rather than executing the Lua, so it validates the algorithm
and never that the code runs. `stylua` only proves the file parses. Getting
`luau-analyze` into CI is now the highest-value unbuilt item in TODO.

**Then a mixed-approach stress test** - one ring carrying a 2-lane two-way, a
1-lane one-way, a 4-lane 2/2 and a 4-lane 3/1 - broke the arm sizing three
ways. Arms were built by halving the approach's lane count, which is only ever
right for a symmetric two-way road.

Lanes are now split by their own `Direction`. It is tagged relative to the
curve's travel, so the sign meaning "toward the ring" flips with which end of
the road the junction sits at. Inbound lanes become the entry arm, outbound the
exit arm: exact on 3/1, and on a one-way road one group is simply empty.

- **One-way approaches** build a single arm, no splitter island, and that arm
  keeps a pavement on BOTH sides - with no sibling arm its gore side is open
  ground and the road it replaces has a footway there. Before, the mouth came
  out one pavement narrower than the road: a 7.1-stud seam step.
- **A solo arm's pavement opening** is now found by walking the arm until its
  outer edge lifts clear of the ring's band, instead of being assumed from the
  split angle. A tangential merge runs inside that band for ~24 degrees on a
  70-stud ring, so guessing left bare kerb at one end and an uncut kerb across
  the carriageway at the other.
- **The splitter island takes each arm's OWN inner offset.** Sharing the
  entry's is only correct when both arms are the same width; on the 3/1 leg it
  tracked the exit's edge a lane and a half out of place and the island missed
  the carriageway entirely, leaving a 7-stud bare wedge.

`tools/preview` gained `stress` and `stress_us` cases covering all four
approach shapes on one ring. All six cases now report a flush 0.00-stud
approach/arm seam and no visible bare ground.

Also added `HANDOFF.md`, a short statement of where the roundabout work stands
and which decisions are settled, for picking this up cold.

## Roundabout: arms aligned to the approach's own cross-section

The mouth had a seam. Each arm was sized from its own half-width plus a
splitter gap, so the pair came out one splitter WIDER than the road it
replaces - and every approach stepped outward at the cut, asphalt, kerb and
pavement all breaking together. It reads exactly as reported: the median and
the pavement not properly linked to the road.

Arms are now placed from the APPROACH's own roadway edges instead. Each arm's
lateral offset is `spokeRoadwayEdge - arm.OuterOffsetStuds`, so its outer
roadway edge lands on the approach's, its pavement lands on the approach's
pavement, and the pair tiles the road exactly. Whatever is left over in the
middle becomes the splitter - which is where that width belongs anyway, so the
island now starts as a nose at the cut instead of appearing out of a step. The
offset is floored at the arm's inner offset, so a road too narrow to split
gives two arms that abut rather than two that overlap.

The arm's pavement width is also copied from the approach's own widest
pavement rather than the region default, so the kerb line runs on unbroken
even where a road carries a non-standard footway.

Measured, not eyeballed: `tools/preview` gained a seam check that sweeps the
road's perpendicular either side of the cut and compares how far material
reaches. The old sizing scores a 1.80-stud step; aligned scores 0.00 across
4-leg (both drive-side conventions), 3-leg and a crowded 5-leg mini, all still
with no visible bare ground.

## Roundabout: part-level preview tool, and the three defects it found

Every check up to here worked on idealised geometry - centrelines and offset
polygons. Roblox never sees those. It sees rigid boxes, one per (component,
station interval), each a rotated rectangle approximating an arc, and defects
at that level are invisible to an idealised render. So `tools/preview/` now
ports the emission path itself (`buildStations`, the deck-strip branch,
`curveMiterPad`, `placeMarkingSpan`, plus the ring/arm/sector code) and renders
two views per case: the parts as Studio will show them, and a **bare-ground
map** where magenta is ground no part covers. A polar scan clusters any holes
by angle and reports each cluster's depth, and the tool exits non-zero if a
visible one survives. Stdlib only; it lives in the repo rather than a scratch
dir, so it runs on any checkout.

It immediately found three real defects, none of which the idealised renders
could have shown:

1. **Ring pavement was deleted wider than the arms actually cover.** The mouth
   sector was `max(entrySplit, split) + margin` on BOTH sides, but the arms land
   at `entrySplit` and `split` respectively - so on a 4-leg ring a ~10 degree
   wedge of kerb was stripped off ground no arm reaches. `MouthSector` is now
   asymmetric (`Ahead`/`Behind`) and INSET by `SECTOR_INSET_RAD` rather than
   expanded: deleting less than the arms cover is invisible, deleting more is
   bare ground in a ring of pavement.
2. **The splitter island ended one rung short of the ring**, leaving a crescent
   of bare kerb at every mouth. The island now runs out to each arm's own kerb
   crossing and closes around the kerb ARC between them, not the chord.
3. **On a crowded ring the island bailed out at its waist** and threw away
   everything past it, including the wide part against the ring. It now runs
   through the pinch - the pinched rungs collapse to zero area and FillTriangle
   drops them.

Worth recording: the first attempt at (2) projected the gore edge points
radially onto the kerb instead of clipping to it. That paves the island
straight over the circulating carriageway, because near the merge an arm's
inner edge is already a full roadway width INSIDE the kerb. The bare-ground
scan still read clean - it only looks for holes, not for island where asphalt
belongs - and it was the parts render that caught it. Both views earn their
keep.

After the fixes: 4-leg (both drive-side conventions), 3-leg and a crowded
5-leg mini all scan with no visible bare ground. The 3-leg keeps 13 hairline
clusters ~0.05 studs deep where the ring's innermost strips chord across the
island circle - an order of magnitude below visible, and unfixable by padding
without overlapping the island instead, so the tool classifies and passes them
rather than hiding them.

## Roundabout: circulation direction was inverted; splitter reshaped

Checked the shipped geometry against the reference sketches and two things
were off.

**Circulation ran the wrong way.** `circleSegments` had
`sign = if driveOnLeft then -1 else 1`. Increasing angle runs from +X toward
+Z, which viewed from above (down -Y) is CLOCKWISE - so left-hand drive, which
circulates clockwise, needed +1. The old sign was internally consistent (the
pavement still landed on the outer edge, because `ringComponents` put it on the
side that happened to be outward under that sign) which is exactly why it
survived: nothing looked broken until the arms encoded direction and the entry
and exit landed on the wrong sides of every approach.

Fixed at the source and followed through everywhere handedness is read off it:

- `circleSegments`: `sign = if driveOnLeft then 1 else -1`
- `ringComponents` / `armProfileFor`: pavement placement swapped, since
  right-of-travel is `-sign * outward` - the outward side is the LEFT of travel
  when circulating clockwise
- `ringInnerHalfWidthM`: island is on the opposite side from the pavement
- `buildMouth`: `flow` follows the same sign

Verified by rendering the arrowed diagram in the reference's own style: ring
clockwise, and on a north approach the exit sits west and the entry east, which
is what driving on the left gives you.

**The splitter island was the wrong shape** - fattest at the approach, pinched
in the middle, and cut off short of the ring by a fixed 0.45 length fraction.
It should be a thin painted slit running back up the approach that opens into a
broad wedge at the ring. Three changes:

- `SPLITTER_WIDTH_FACTOR` 2 -> 0.5, so the arms leave the approach about a
  metre apart instead of two pavements apart
- the gore now runs until an edge reaches the ring kerb, where it stops -
  past that the "gap" between the arms is the circulating carriageway itself
- `MIN_KERB_GAP_RAD` 12 -> 8 deg and `SECTOR_MARGIN_RAD` 5 -> 3 deg, which
  gives a 4-leg ring the full 38 deg split instead of 34

That last one is what actually fixes the pinch: the waist comes from the
ring-end control point pulling across the gore, and a wider split outruns it.
Measured on a 4-leg 2-lane ring with 4-lane approaches, the island now goes
3.6 studs at the approach -> 13.2 at the ring (was 14.3 -> 6.7 -> 10.4), and on
a 3-leg it widens monotonically the whole way. 3- and 4-leg rings pass clean in
both drive-side conventions; the crowded-ring limit below is unchanged.

## Roundabout mouths: split entry/exit arms merging on the rim

Replaces the single full-width feeder per approach. Each approach is now cut
back and **splits into a one-way entry arm and a one-way exit arm**, with a
raised splitter island in the gore between them, and both arms meet the ring
**tangentially on its rim**. The ring itself is still one continuous annulus -
only its outer pavement is opened over each mouth sector, as before.

The merge is the point of the design. An arm's centreline ends at
`ringKerbRadius - OuterOffsetStuds`, i.e. exactly the radius that puts its
outer roadway edge on the ring's kerb, carrying the ring's own tangent there.
So the arm's kerb line lands on the ring's kerb line and its pavement band on
the ring's pavement band, and the carriageway flows in instead of butting into
it. That removes the whole class of defect the old feeder had - the triangular
notch on the acute side of every mouth and the kerb that stopped dead - so
`buildMouthCorners`, `buildFeederRoad` and the flare/bulge constants are all
gone rather than patched.

Geometry, all derived from the ring's own sign convention
(`flow = if DriveOnLeft then -1 else 1`, matching `circleSegments`):

- Arm profile: half the approach's running lanes, one-way, with a **single**
  pavement on the arm's OUTER side (`ringComponents`' placement rule). A
  pavement on both sides would lay a raised strip down the middle of the mouth.
- Going round the ring you meet a mouth's EXIT first (upstream) and its ENTRY
  after (downstream): entry merge at `angle + flow*entrySplit`, exit at
  `angle - flow*split`.
- Mouth angle comes from `rayCircleFirstHit` along the approach's own
  centreline, not the cut point's radial, so an off-centre approach keeps its
  mouth on the road line.
- Legs are trimmed and **planned first, built second**: a mouth's split budget
  is `nearestNeighbourGap/2 - MIN_KERB_GAP/2`, which needs every leg's landed
  angle. Assuming an even spread hands a leg wedged 45 deg from its neighbour
  the same budget as one with the ring to itself.
- Both arms approach their merge points from the mouth side, so the pair's
  angular footprint lies INSIDE the split - the opened sector is
  `split + 5 deg` margin, with nothing added for the arms' own width. (An
  earlier version added `atan(armHalf/mergeR)` and squeezed a 4-leg ring's
  split from 34 deg down to 26, which is where the arms started closing up.)
- `RoundaboutEntryCurve` now means the entry merges at `0.8x` the exit's split
  - traffic joining is turned harder than traffic leaving - rather than
  reshaping corner fillets.

Constants were **measured in the headless renderer, not eyeballed**. The cubic
handle is the delicate one: the ring-end tangent runs sideways to the approach,
so a long handle walks that control point across the gore until the entry and
its own exit close up on each other, while a short one buys the clearance back
by kinking the arm into a hairpin (min radius 4-5 studs at 0.14). 0.30 is the
measured middle - ~20-stud min radius on a 4-leg ring with a full carriageway
of gore left between the arms. Checked headless for 3-, 4- and 5-leg rings in
both drive-side conventions: no arm crossings, no sector overlaps, and every
arm's outer edge lands on the ring kerb to within 0.5 studs.

Known limit, logged rather than hidden: on a ring genuinely too small for the
mouths it carries (5+ legs, or wide approaches on a ~40-stud radius) the split
is squeezed until the two arms run up against each other partway along. The
mouth still builds - it reads as one wide opening, which is what a roundabout
that tight looks like - and the splitter island gives out at
`MIN_GORE_WIDTH_STUDS` instead of trailing into slivers.

Also: arms are sunk `0.05` studs below the ring deck. Near the merge an arm's
inner half necessarily lies over the ring's carriageway (that overlap IS the
merge) and two coplanar asphalt decks z-fight; letting the ring win is
invisible and also hides the arm's edge lines where they run inside the ring.

## Roundabout entrance/exit deflection (asymmetric mouth corners) — superseded

Entries used to butt into the ring dead straight, with no deflection. Now each
mouth's two corners are shaped differently, which is where deflection actually
lives on a real roundabout - the entry centreline stays near-radial.

Traffic-direction logic: `circleSegments` circulates +1 (increasing angle) for
right-hand drive and -1 for left-hand. Going round the ring you meet a mouth's
**exit** corner first (behind, against the flow) and its **entry** corner after
(ahead, with the flow). So a corner is an entry iff its side sign equals
`flow`. Standard practice is a **tight entry radius** - the deflection that
slows traffic joining - and a **generous exit** so traffic leaves freely:

- entry corner: flare x0.55, bulge 0.18 (tight)
- exit corner:  flare x1.55, bulge 0.42 (sweeping)
- per-side flare clamped to 4-30 deg; symmetric mode (toggle off) keeps the
  previous single flare + 0.25 bulge exactly

Only `cornerSide` changed - `buildFeederRoad` is untouched. New
`RoundaboutEntryCurve` setting (default on) with a "Deflected entries / exits"
checkbox in the Road Tool panel.

**Prototyped in the headless renderer first and only then ported**, after the
earlier centreline-swing attempt had to be reverted (rotating the feeder's ring
attach point moved it ~23 studs sideways over a 14-stud feeder = hairpin). The
shipped Luau constants and the entry/exit test were diffed against the
validated prototype. Rendered 3-leg 2-lane and 4-leg 3-lane: mouths visibly
asymmetric, ring intact, no hairpins.

## Marking simulation: outer edge-line bound must derive from MarkingWidthM

Extended the headless renderer to model lane markings using the real rules
from `Markings.lua` / `RegionStyles.lua` (same-direction lanes -> dashed
LaneLine, opposing -> CenterLine, roadway edges -> solid EdgeLine inset by
`MarkingWidthM * 1.5`). That immediately exposed a latent bug in the
radius bound shipped one commit earlier.

The bound was a hardcoded `ringKerbRadius - 1`. The ring's outer EDGE LINE
sits at `ringKerbRadius - MarkingWidthM * 1.5 * scale`, which at the default
`MarkingWidthM = 0.1` is only **0.46 studs** inside the bound - it passed by
luck. At `MarkingWidthM >= 0.2` (reachable: the Region Editor exposes the
field) the edge line falls *inside* the bound and survives, leaving a solid
white line painted straight across every mouth.

Bound now derives from the same inset Markings.lua uses:
`ringKerbRadius - MarkingWidthM * 1.5 * scale - 0.5`. Checked at
MarkingWidthM 0.1 / 0.2 / 0.3 / 0.5: the outer edge line is removed at the
mouth in all four, and the outermost lane divider (a full lane further in)
is never caught.

Rendered 2-lane and 3-lane rings with 4-lane entries: island edge line and
all circulating lane dividers continuous, outer edge line opening only at
the mouths.

## Multi-lane ring: only open the OUTER band, not every marking

`openRingPavement` filtered purely by ANGLE, so inside a mouth sector it
destroyed every captured `Sidewalk`/`Marking` part at any radius. On a
single-lane ring that is nearly harmless (the outer parts are the ones meant
to go), but on a **multi-lane** ring it also deleted the inter-lane dashed
dividers and - worse - the edge line around the central island, which would
gain a gap at every entry despite the island being continuous.

Added a `minRadiusStuds` bound (ring kerb radius - 1) so only the outer
pavement band is opened. Checked on a 3-lane ring: island edge line (r=37.7)
and both lane dividers (r=50.2, 62.7) survive; outer kerb line (r=75.2) and
pavement band (r=78.7) open at the mouth.

## Multi-lane roundabout: bound the flare, stop sectors overlapping

Testing multi-lane rings + multi-lane entries in the headless renderer caught
a serious regression in the ring-opening change below, before it ever reached
Studio. With 4-lane entries on a 4-leg ring the mouth sectors summed to **133%
of the circle and overlapped each other**, so `openRingPavement` would have
deleted the ENTIRE outer band - a roundabout with no carriageway edge at all.
A 3-lane ring with 6-lane entries was similar (118%, overlapping).

Two compounding causes, both fixed:

- **The flare scaled without bound with road width.** `halfWidth * 0.9` on a
  wide road saturated the old 30 deg cap, piling a huge swing on top of an
  already angularly-wide mouth. Now `clamp(halfWidth * 0.9, 6, 14)` studs and
  `clamp(.., 6 deg, 20 deg)` - the flare adds about a lane of extra width
  rather than a proportion of an arbitrarily wide road. The single-lane case
  is unchanged (still 9.9 studs), so the earlier validated behaviour holds.
- **Nothing stopped neighbouring mouths overlapping.** New `clampSectors`
  sorts sectors by angle and lets each claim at most half the gap to either
  neighbour, less half of `MIN_KERB_GAP_RAD` (12 deg), plus an absolute
  `MAX_SECTOR_HALF_RAD` (60 deg) cap. Symmetric, so overlap is impossible.

After: 4-lane/4-leg goes 357 -> 312 deg (48 deg of kerb retained, no overlap);
6-lane stress goes 338 -> 324 deg (36 deg retained). Verified across three
configurations, all asserting no overlap and a surviving ring band.

**Known limitation (not a bug):** entries much wider than the ring genuinely
consume most of the circumference, so a 4-lane-entry roundabout at radius 40
degrades into a crossroads with a central island. That is geometrically
honest - the ring radius has to scale with entry width. Auto-sizing the
minimum radius from the widest connected road is logged in `TODO.md`.

## Roundabout: open the ring pavement at each mouth (root cause)

Found by building an out-of-engine renderer (see "Headless geometry preview"
below) instead of guessing from screenshots again.

**The ring's outer pavement was never opened.** `CreateAtJunction` builds the
ring as ONE continuous `RoadBuilder` circle whose profile includes a Sidewalk
component, so a raised kerb + pavement band ran unbroken *across every entry*.
No amount of corner tuning could fix that - the mouth was walled off by the
ring's own carriageway edge. This is exactly the reported "the mouth still has
to open, not close into it", and it explains why four rounds of corner fixes
kept not landing.

- `buildMouthCorners` now returns the angular sector each entry occupies
  (centre = mouth radial, half = widest flared corner offset).
- The ring's own `Sidewalk`/`Marking` parts are captured immediately after the
  ring is built (before feeders/corners are parented in, so only the ring's
  own band is considered), and `openRingPavement` deletes those falling inside
  any mouth sector.
- Simulated on a 3-leg roundabout: ~46 deg opened per entry, 62% of the ring
  band left intact - it opens the mouths without eating the carriageway edge.

## Headless geometry preview (no Studio needed)

Repeated blind iterations on the roundabout were costing rounds, so there is
now a way to actually SEE what the geometry code produces without Studio:
`scratchpad/mouthsim.py` (faithful port of the shipped `buildMouthCorners`
maths) + a dependency-free rasterizer (`raster.py`, stdlib `zlib` only) that
renders a top-down PNG. This is what surfaced the root cause above. Not a
substitute for Studio - it models the corner algorithm, not part-level
rendering - but it turns "guess from a screenshot" into "look at the output".

## Units settings (km/h / mph, metres / feet)

Backlog item: measurements were hardcoded metric in the UI. Added
display-only unit conversion, deliberately built as the exact parallel of
`Locale.lua`'s British/American terminology swap.

- New `src/Units.lua`: `SpeedSuffix`/`SpeedFromKph`/`SpeedToKph`/`SpeedField`
  and `LengthSuffix`/`LengthFromM`/`LengthToM`/`LengthField`/`FormatLength`.
- New settings `SpeedUnit` ("Kmh"/"Mph") and `LengthUnit` ("Meters"/"Feet"),
  persisted and validated on load exactly like `LanguageVariant`, with two
  dropdowns beside Terminology in Regional Preference.
- **Storage stays canonically metric.** `DesignSpeedKph` and every `*M` field
  keep their values; only display converts. That is deliberate: the
  superelevation relationship (e + f = V^2/127R) is only valid with V in km/h
  and R in metres, so converting at the edges means switching a display unit
  can never change the geometry that gets built.
- The `*Field` helpers convert the Min/Max **bounds** along with the value -
  a field showing mph but clamped to km/h limits would silently refuse valid
  input, which is the easy bug here.

Wired at every field that had `settings` in scope: design speed (Road Tool
panel + Regional Preference), superelevation transition length (both), dash
length/gap, roundabout lane width. `RoadDesigner`'s lane width and
`RegionEditor`'s region dimensions still read in metres - they take no
`Settings` prop, so it needs threading first; logged in `TODO.md`.

## Roundabout mouth flares open into the ring

Reported live: "the mouth still has to open, not close into it". The curb
returns were closing each mouth back down to plain road width - both rails
attached at the feeder's own ring angle, so the opening never widened.

Each side's ring attachment is now swung AWAY from the mouth centre by an
arc distance (`max(6, halfWidth * 0.9)` studs, clamped 8-30 deg), so the two
sides diverge and the entry reads as a trumpet flaring into the circulating
lane. Side is taken from the cross product of the mouth-centre radial with
the side radial, falling back to the edge point's lateral offset when those
radials coincide. Verified out-of-engine: mouth arc span widens (24 -> 36
deg) with both sides moving outward. Awaiting live confirmation.

## Roundabout mouth corners: tame the bulge + close the throat

Follow-up on the first live screenshot of the mouth corners: the curb
returns ballooned into flower-petal lobes past the ring, and a dark
triangular notch remained at each mouth centre.

- Bulge cap on the corner Bezier control cut from 1.0 -> 0.25 of the chord,
  so the corner is a gentle round hugging the mouth instead of a lobe bowing
  out to the far edge-line intersection.
- The two per-side asphalt fans both start at the mouth-centre apex, so the
  wedge straight between the feeder's two kerb points was never filled (the
  centre notch). Added one `FillTriangle(apex, LeftKerb, RightKerb)` to close
  the throat roadway.

Still not live-verified.

## Roundabout mouth curb-return corners

With the feeders now aligned, the remaining defect was at each mouth: a
feeder butts into the ring at an angle, so on each side its edge left a
triangular notch against the ring's outer circle and its kerb line stopped
dead (no curb return). `CreateAtJunction` built ring + feeders and nothing
between them; `trimSpoke` even computed the feeder edge points and threw
them away.

- `buildFeederRoad` now also returns the feeder's cross-section edge points
  where it meets the ring (`edgePointsAt` at the feeder's ring-end station).
- New `buildMouthCorners`: for each feeder side, a bounded quadratic-Bezier
  corner (`BezierCorner`, cannot spike at any mouth angle) from the feeder
  edge to the radially-projected ring edge, filled as a raised sidewalk band
  plus roadway asphalt (`FillTriangle`), mirroring the junction curb returns
  in `JunctionBuilder`. Colours/heights come from the same style fields as
  the ring (`AsphaltColor`, `SidewalkColor`, `CurbHeightM`).
- Robustness: the corner control point is clamped so it never sits more than
  the chord length from the chord midpoint (a very off-centre approach could
  otherwise balloon the curve ~9 studs — verified out-of-engine at 0/10/25/40
  stud offsets), and a side whose feeder edge already sits at the ring edge is
  skipped (no notch to fill).

Not live-verified (no Studio here); geometry checked out-of-engine.

## Roundabout feeders attach along the road, not the ring radial

Follow-up to the feeder-gap fix below: with connection now triggering, the
feeders built but came out as diagonal stubs floating beside an unfilled gap
whenever the approach road did not aim at the ring centre (the common case).

`buildFeederRoad` attached each feeder's ring end on the **radial through the
cut mid**, which for an off-centre approach sits sideways of where the road
actually points — so the feeder bent 15-45 deg off the road line, landed on
the radial instead of in front of the road, and left the real road→ring gap
open. Now the end is found by intersecting the road's **own continued
centreline** with the ring circle (`rayCircleFirstHit`), so the feeder is a
straight continuation that fills the gap (0 deg bend for any approach that
reaches the ring; radial fallback only if the ray misses it entirely).
Verified out-of-engine across 0/15/30/45-stud offsets.

## Roundabout tool connects nearby roads (feeder gap fix)

Reported live: a roundabout dropped into a scene left the surrounding roads
disconnected — each spoke stopped short of the ring with a bare gap, no
feeder bridging it.

Root cause was the trigger, not the feeder geometry. The Roundabout tool
committed via `RoundaboutBuilder.Create`, which builds only the ring +
island and connects *nothing*; feeders are only ever built on the
`ConnectRoad` → `CreateAtJunction` path, which the tool never invoked. So
placing a roundabout onto an existing cluster of roads produced a bare ring
sitting among untouched roads.

- New `RoundaboutBuilder.Place`: builds the ring, then collects roads within
  the feeder band (`outerR + SETBACK_STUDS + SnapRadius + 8`) and, if any,
  hands the ring + one nearby road to `ConnectRoad`, which forms the
  junction and rebuilds with feeders for all of them. No nearby roads → it
  is exactly `Create`. `commitRoundabout` now calls `Place`.
- `FindNear` match band widened by `SETBACK_STUDS` so a road drawn *toward*
  an already-placed roundabout but stopping a little short still snaps and
  connects (matches the collection band `ConnectRoad` already uses).

Also translated MarcusElg/roadcreator's bounded quadratic-Bézier corner to
`src/Geometry/BezierCorner.lua` (MIT) — the robust corner primitive for the
feeder-blend follow-up in `TODO.md`. Standalone, not yet wired in.

Not live-verified (no Studio in this environment); diagnosis is from the
code path + screenshot.

## Polar roundabout rebuild + junction median/offset sidewalk

**Phase A — Roundabout as polar annulus (replaces failed feed stack).**
`CreateAtJunction` no longer uses large `SETBACK_STUDS`, Hermite feed
cubics as ring-owned roads, or mouth exclusions from feed outer ClosestS
(that pipeline produced knotted partial rings in Studio). New model:

- Trim spokes to outer pavement + small margin only (Pythagorean half-width).
- Continuous full-circle drive lanes; outer sidewalk off only in angular
  entry sectors derived from mouth midpoint + half-width (`asin`).
- Mouth joins = `Fillet.Compute` flares only (decoration on continuous ring).
- Island, `stampRingMeta`, `FindNear`, `ConnectRoad` kept (ConnectRoad maxDist
  no longer depends on SETBACK_STUDS).

**Phase B — Junction approach-node richness.**

- Sidewalk corner band uses true parallel offset of the kerb polyline
  (`offsetKerbPolyline`) with endpoints pinned to real outers — not only
  fillet-circle inset, which mis-tracked on curved approaches (indent).
- Approaches with a Median get a raised grass **nose** into the pad so
  dual-carriageway T-junctions no longer end as a blunt median slab.

## Priority plan: roundabout feed curves, snap, raycast, curve faceting

- **P0 raycast:** `raycastGround` now excludes `workspace.Roundabouts` (was
  only Roads + Junctions). Clicks over a ring hit terrain / set elevation,
  not the ring deck - fixes "road stacked on roundabout".
- **P0 collision:** `RoadBuilder.makePart` sets `CanCollide = false` for
  real roads too (was only previews); geometry is visual, not a physics box.
- **P1 snap + connect:** Rings stamp `RW_Center` / `RW_RingRadius` /
  `RW_OuterRadius` / lane config. `RoundaboutBuilder.FindNear` snaps the
  first placement point to the outer rim with an outward tangent.
  `ConnectRoad` rebuilds the ring with the new road as a spoke (temp
  junction + CreateAtJunction pipeline).
- **P2 feed-in/out:** After setback trim (`SETBACK_STUDS` 16), each spoke
  gets a Hermite cubic feed built onto the ring (full spoke profile) from
  the cut to the outer kerb arriving on the circulating tangent - real
  merge geometry rather than only corner flares + ruled mouth band.
  Residual mouth fill + flares remain as seam insurance. Feeds are
  ring-owned (not multi-segment roads) so `RoadInstance` single-segment
  stamping still works.
- **P3 curve faceting:** Tighter `CHORD_TOLERANCE` (0.05), `MIN_STEP`
  (0.4), `MAX_TURN_PER_STEP` (0.2) so outer sidewalk edges on tight U-bends
  subdivide more instead of reading as indented facets.

## Roundabout setback feed-in/out + mouth fill (live broken-ring reports)

Driven by live screenshots of a 4-leg roundabout whose feeders stopped as
flat cuts against a discontinuous ring sidewalk (bare notches, rectangular
asphalt blocks at mouths, no real entry/exit curve).

- **Setback trim.** `CreateAtJunction` now trims every spoke to
  `outerRadius + SETBACK_STUDS` (10 studs past the ring's outer pavement
  edge), not flush to the ring. Gives entry/exit geometry real length so
  flares read as feed-in/out lanes rather than tiny corner wedges.
- **Mouth asphalt fill (the missing piece).** A ruled `FillTriangle` band
  from the spoke's setback cut (LeftKerb -> RightKerb) to the ring's outer
  kerb arc across the mouth station interval (`sampleRingStations` takes
  the short arc, including mouths that straddle the ring's station-0 seam).
  Without this, setback alone would open bare ground across the middle of
  every feeder mouth - which is why it was deliberately deferred before.
- **Larger flares + raised sidewalk bridges.** `FLARE_RADIUS_M` 8 -> 10;
  each mouth side still gets a deck-level `Fillet.Compute` asphalt flare
  (spoke kerb <-> ring kerb), and now also a raised sidewalk band outside
  that flare (spoke Outer -> ring outer-sidewalk point, sampled along the
  same arc) so the feeder's pavement continues into the ring's sidewalk
  gap instead of ending as a hard cut. Degenerate/tangential feeders fall
  back to a plain raised quad.
- **Constants.** `RING_TRIM_MARGIN_STUDS` 2 -> 0.5 (setback is the real
  clearance now; margin is only floating-point safety).

Still not done: per-lane merge tapering into the circulating lanes, yield
/ give-way markings, live ring preview, wiring the ring into the junction
data model so a new road can snap onto it.

## Ring banking off, mouth-angle sort, Hermite corner fallback (three live screenshot reports)

- **Roundabout "humps and lumps" - root cause found in the actual math,
  not guessed.** `Superelevation.RollAt` in Auto mode banks ANY curve by
  the highway design formula `e + f = V^2/(127R)`; a 30-stud ring is
  ~8.4m radius, so at any realistic design speed the demand saturates at
  the region's MAXIMUM superelevation - the ring was being built as a
  maximally-banked circle of hundreds of short tilted strips. Real
  roundabouts are never superelevated (low-speed geometry). Both ring
  build paths (`Create` and `CreateAtJunction`'s span slices) now build
  with a settings clone whose `SuperelevationMode` is forced `"Off"`
  (`flatSettings`); spokes keep the caller's real settings. Also sank the
  entry/exit flares 0.02 studs below deck: they overlap both the spoke's
  and the ring's own asphalt where they meet, and three coplanar surfaces
  z-fight (flickering streaks).
- **3+-road junctions losing their corners (reported live: "seems to only
  support 2 additional roads").** The per-approach node sort used the
  road's outward CURVE TANGENT angle - and every approach in the reported
  layouts was strongly curved, so the tangent at the trimmed end pointed
  somewhere very different from where the mouth physically sits,
  mis-sorting the angular neighbour order and pairing corners between
  non-adjacent approaches (which the mouth-crossing guard then rightly
  killed, leaving bare pads). The approach angle is now the angle of the
  MOUTH MIDPOINT around the junction centre - the mouth's position can't
  lie about where the mouth is, regardless of how the road curves.
- **Indent/notch where a curved road passes through a T/Y junction.** The
  nearly-opposite "through" pair's fillet is correctly rejected as
  degenerate (near-collinear), but the old fallback was a straight chord
  across the whole pad - which cuts visibly INSIDE the curved sidewalk
  line the two roads actually follow, a sharp notch at each mouth
  (reported live). New middle fallback: a cubic HERMITE tangent-matched
  to both roads' own edge lines (leaves a.Kerb travelling into the pad
  along A's line, arrives at b.Kerb travelling out along B's), sampled at
  5 interior points, for both the kerb boundary and the outer sidewalk
  boundary. No kink at either end for any approach geometry, and bounded
  near the chord by construction (tangents scaled to chord length =
  every Bezier control point within chord/3 of an endpoint). The straight
  chamfer now only remains for the "tangent unreadable" case.
- **NOT done this round, deliberately: the "setback shaping feed-in/out
  lanes" ask for roundabouts.** Pulling spokes further back from the ring
  (like the junction setback) without new mouth-fill geometry would open
  a strip of bare ground across the middle of every feeder mouth - the
  flares only bridge the two corner wedges, not the span between them.
  Logged in TODO.md with that requirement spelled out rather than shipped
  half-broken.

## Junction corners: per-approach node model (user's architecture suggestion)

- Implemented the decomposition the user proposed: "break an intersection
  down to different nodes (the cross section itself) and join them all."
  Each connected road now contributes one explicit APPROACH NODE - its
  cross-section at the trimmed end (left/right kerb + outer EdgePoints)
  plus the angle its outward tangent leaves the junction at. Nodes are
  sorted by that angle, and every corner treatment (fillet bulge + raised
  sidewalk band, unchanged construction) is built between ANGULAR
  NEIGHBOURS: approach A's counter-clockwise-side point paired with the
  next approach B's clockwise-side point.
- Which of an approach's two edge points is its Cw vs Ccw side is resolved
  purely computationally - the signed angular offset of each point around
  the junction centre relative to the road's own outward angle - rather
  than from any left/right or driving-side convention. Two of the last
  three geometry bugs in this codebase were direction-sign errors in
  hand-reasoned conventions; deriving the sides from the actual computed
  angles leaves no convention to get wrong.
- Why angular-neighbour pairing is the right join order (and the old
  radial POINT sort, tried rounds ago, wasn't): approaches are whole-road
  slots, one per road, with well-separated directions by construction -
  they can't interleave the way raw kerb points from different-width
  roads could. And unlike hull-adjacent pairing (the outgoing model), a
  narrow road whose kerb points fall hull-interior still gets real
  corners with both its neighbours instead of being paved across - the
  live-reported Y-junction "sidewalk band walling off an approach" bug is
  structurally impossible between angular neighbours.
- Per the migration caution logged in TODO.md when this was proposed: the
  convex hull fan REMAINS the unconditional base asphalt - the corner
  layer decorates on top of an intact pad, so any corner failure degrades
  to less decoration, never a torn/holed surface. The mouth-crossing
  guard also remains, belt-and-braces, for pathological approach sets
  (three roads clustered at nearly the same angle).
- Not live-tested in Studio (no Roblox client here) - but the corner
  construction itself (fillet, band, local fan) is byte-identical to what
  was already live-verified; only WHICH PAIRS receive it changed.

## Big fix round: junction re-connect (real root cause), roundabout speed bumps -> flares, setback, mouth guard, UI inset revert

Driven by three live screenshots (a roundabout with raised strips at every
feeder join, a Y-junction with sidewalk bands crossing the carriageway, a
T-junction with no setback) plus "still can't add a road to an
intersection" and "the UI is still up".

- **"Cannot add new road to an intersection" - the REAL root cause this
  time.** The previous fix added a junction fallback to `connectEnd`, but
  put it LAST - after `findMidSpanMatch`. Near an already-built
  intersection that made it unreachable: every trimmed approach's curve
  passes within the mid-span matcher's width-scaled tolerance of a click
  near the pad, so the mid-span branch matched a station right at that
  approach's cut END and returned unconditionally - and `RoadSplit`
  declined the degenerate near-end split, so the whole connection silently
  died before the junction check ever ran. Reordered: road endpoint ->
  junction -> mid-span. Also: junction matching now uses the pad's real
  FOOTPRINT (`JunctionBuilder.PadRadiusStuds`, new export - centre
  distance <= snap radius + pad radius) instead of a bare centre-point
  search whose radius a wide avenue's pad dwarfs, in both the click-time
  snap guide and the post-commit connect; and `connectAt` accepts the
  already-found junction so its own narrow internal re-search can't miss
  it and mint a duplicate node.
- **Roundabout "random speed bumps" removed.** The previous round's
  raised sidewalk "bridge quads" between the ring's cut sidewalk edge and
  each spoke's sidewalk edge were the bumps: a raised quad whose corner
  resolution goes even slightly wrong lands concrete strips across the
  driving surface, and that failure mode was reported live at multiple
  feeder joins. Deleted outright rather than patched - replaced by:
- **Roundabout entry/exit FLARES (the "no curves for feeding in and out"
  request).** Each side of each spoke's mouth now gets a deck-level
  asphalt fillet between the spoke's own kerb line and the ring's outer
  kerb line (locally approximated by its tangent at that station), built
  with the same proven circular-fillet construction as junction corners -
  now extracted to a shared `Geometry/Fillet.lua` (verbatim move, one
  implementation for both callers) - and fanned locally from the spoke's
  own kerb point. Deliberately DECK-LEVEL asphalt: worst failure mode is
  flat asphalt overlapping flat asphalt (invisible), never a raised
  obstacle; `Fillet.Compute` returning nil (tangential feeder) just means
  no flare on that side. Also fixed a latent wrap-around bug found while
  restructuring: a spoke straddling the ring curve's own station-0 seam
  produced a "mouth interval" spanning nearly the whole circumference,
  which would have deleted the ring's sidewalk everywhere EXCEPT the
  mouth - now detected (interval > half the circumference) and split
  into the two end fragments.
- **Junction setback (`PAD_MARGIN_STUDS` 2 -> 6).** Explicitly requested:
  approaches now stop visibly short of the interior, reading as roads
  arriving at a distinct intersection area instead of ending flush
  against its geometry.
- **Junction mouth guard.** On a 3+ way junction where one road's kerb
  points fall hull-interior, the hull edge between its two neighbours
  spans right across that road's mouth - and the corner treatment built
  on it (raised sidewalk band) walled off the approach (reported live:
  bands crossing the carriageway). Cross-road hull edges that PROPERLY
  intersect a third road's mouth segment (2D orientation-test crossing
  check, endpoint-touch excluded - `segmentsCross2D`, the same idea as
  RoadArchitect's `Intersects2D`) now skip the corner treatment entirely;
  the base asphalt fan still fills the area.
- **UI "pushed upward" - second attempt, different theory.** The
  GetGuiInset-margin fix didn't work (confirmed live), so it's reverted.
  New approach: `IgnoreGuiInset` is now OFF for both HUD ScreenGuis. The
  pie-menu ScreenGui has never set the flag and is the one HUD surface
  that has always positioned correctly in the user's Studio; both HUD
  guis now follow its convention, and the flag's known-inconsistent
  codepath is avoided entirely. NOT verified live (no Studio here). If it
  STILL sits high, the next step is data, not another theory: run
  `print(workspace.CurrentCamera.ViewportSize, game:GetService("GuiService"):GetGuiInset(), game:GetService("CoreGui").EasyRoadHUD.AbsolutePosition, game:GetService("CoreGui").EasyRoadHUD.AbsoluteSize)`
  in Studio's command bar while the Road Tools panel is open.

## Fix bottom HUD panels sitting well above the true viewport bottom ("pushed upward")

- Reported live with a screenshot: the Road Tools panel and Road Library
  box both floated with a large, unexplained gap of empty space beneath
  them instead of sitting near the bottom edge as their `-40` studs
  margin intends - same for every other bottom-anchored panel
  (RoadDesigner, RoadInspector, JunctionPanel, the bay/marking/kerb-stretch
  sub-panels).
- Root cause: every one of these panels lives in `bottomScreenGui`, which
  has `IgnoreGuiInset = true`. That flag is documented (multiple Roblox
  Developer Forum engine-bug reports, current as of checking) to NOT
  reliably zero out the GUI inset for a ScreenGui's own descendant layout
  in the current engine, despite the flag's whole purpose being exactly
  that - so `AnchorPoint(_, 1)` + `Position(_, 1, -40)` was resolving
  against a shorter-than-true effective height, landing the panel's
  bottom edge well above the actual viewport bottom by roughly the size
  of the (supposedly ignored) inset.
- Fixed without touching the flag itself (it's still needed for the
  drag-and-drop hit-testing fix from an earlier round, which uses
  `GuiService:GetGuiObjectsAtPosition` and doesn't depend on this
  particular inconsistency): added `bottomMarginStuds(base)`, which reads
  the ACTUAL current inset via `GuiService:GetGuiInset()`'s bottom-right
  component and adds it back into the margin, so every bottom-anchored
  panel's `-40` became `-bottomMarginStuds(40)` - self-correcting against
  whatever the engine is actually doing at the moment, rather than
  hard-coding a guessed pixel offset that would drift again on the next
  engine change. All 9 occurrences of the pattern across `main.lua`
  updated identically.
- The top nav bar (`TopBar.lua`, its own `topScreenGui`) was NOT touched -
  confirmed live that only the bottom-anchored panels were affected, not
  the top pill.

## Roundabout: outer-edge-only sidewalk, larger island, defensive stale-pad cleanup

- Reported live: a fan of thin shards visible inside a roundabout's
  island, and (separately) a request to drop the pointless inner sidewalk
  strip entirely and let the island grow to fill that space instead - real
  roundabouts don't have pedestrian pavement on the side facing the centre
  island either.
- `ringComponents` now places exactly ONE Sidewalk component, on the
  physically OUTER edge only - resolved via `style.DriveOnLeft`, not
  guessed: `PolyCurve.FrameAt`'s `RightVector = LookVector x UpVector`
  formula was checked against Roblox's own identity CFrame
  (`Look=(0,0,-1)`, `Up=(0,1,0)` gives `Right=(1,0,0)`, confirmed via a
  standalone cross-product check) before relying on it this time, given
  the sidewalk-band sign error found earlier this same session in
  unrelated (junction fillet) code. `ringInnerHalfWidthM` reads the
  correct side's own `ComponentOffsetsM` extreme accordingly.
- `buildIsland` now sizes the island against that real inner LANE edge
  (previously a symmetric total-width/2, which assumed a sidewalk existed
  on both sides) - the island grows to fill exactly the space the removed
  inner sidewalk used to occupy, reaching right up to the traffic lanes.
- `CreateAtJunction`'s gap-cutting (`sidewalkIndices`) now excludes just
  the one real sidewalk component instead of two.
- **Root cause of the fan-of-shards artifact wasn't conclusively
  identified** (no live Studio access to debug interactively) - the
  leading theory is a pre-existing `JunctionBuilder` pad (the convex-hull
  asphalt fan, built whenever the location was an ordinary intersection
  before being converted to a roundabout) persisting because something
  between the start of `CreateAtJunction` and its final
  `JunctionInstance.Delete` call didn't complete (most plausibly a runtime
  error partway through, which Roblox logs but doesn't necessarily halt
  script execution loudly). Added a defensive, unconditional cleanup of
  the junction's own `Geometry` child at the very START of
  `CreateAtJunction`, independent of whether the rest of the function
  succeeds - this should eliminate the SYMPTOM even without having
  confirmed the exact mechanism, but flagging that honestly rather than
  claiming the root cause is fully understood.

## Roundabout: cut a gap in the ring's own sidewalk where each feeder connects, bridge the seam

- Two real, concrete bugs behind "the ring's sidewalk clips through the
  driving lanes where feeders join": (1) spokes were trimmed to the ring's
  CENTRELINE radius, not its true outer pavement edge - the ring's own
  cross-section extends `halfWidth` beyond its centreline on each side (via
  the sidewalks added a couple rounds ago), so every spoke stopped a full
  half-ring-width short of the ring's actual kerb, a real gap that simply
  wasn't visible before the ring had a sidewalk to expose it against; (2)
  the ring's outer sidewalk band ran fully unbroken around the whole
  circle, with no opening cut for a feeder to connect through, so even
  once a spoke reached the right radius its lanes would run straight under
  the ring's continuous sidewalk pavement.
- `trimSpokeToRing` now takes an explicit `targetRadiusStuds` (the ring's
  outer edge, `radiusStuds + ringHalfWidthStuds` - not the centreline) and
  returns the spoke's own freshly-cut edge points (kerb + sidewalk-outer,
  both sides) so `CreateAtJunction` can use them to cut a matching gap.
- `CreateAtJunction` finds each gap's exact station interval on the ring's
  own curve via `PolyCurve:ClosestS` on the spoke's real edge points (not
  an assumed angular width - it always matches the spoke's true width),
  then builds the ring as alternating slices: normal (full profile, both
  sidewalks) between gaps, `ExcludeComponentIndices` (just the two
  Sidewalk components, first and last) across each gap so the DRIVE LANES
  stay fully continuous - the ring is never actually cut open for traffic,
  only its sidewalk band is - while the spoke's own asphalt (now reaching
  the ring's true outer radius) flows straight into the ring's lanes with
  a little harmless overlap in the gap zone (same material, same height,
  no visible seam).
- Each gap is bridged with a plain two-triangle quad connecting the ring's
  own outer-sidewalk edge (computed analytically at the gap boundary,
  since no Part was built there) to the spoke's real sidewalk edge -
  deliberately the same plain a.Outer-a.Kerb-b.Kerb-b.Outer shape
  `JunctionBuilder`'s `cornerBoundaries` uses for an ordinary straight
  chamfer, not a new curve-fitting/fillet system - that's exactly the kind
  of code that needed a sign-error fix earlier this same round, and both
  edges meeting the gap are already smooth curves, so a straight bridge
  between them reads as a continuation rather than a sharp corner.
- Which physical side of the ring's cross-section is "outer" (facing a
  feeder) vs "inner" (facing the island) still flips with
  `style.DriveOnLeft` (see `ringComponents`'s own note) - rather than
  track that sign for the bridge, `ringEdgeNear` just picks whichever side
  is physically closer to the spoke's own edge point at that station.
  Nearest-point matching sidesteps the entire class of directional sign
  error that bit the junction fillet fix earlier this round.
- **Not live-tested in Studio** (no Roblox client in this environment) -
  this is a substantial new code path (ring construction split into
  multiple sliced sub-builds merged into one Model, analytic edge-point
  computation independent of any built Part) built from careful reasoning
  and this codebase's own already-proven primitives (`PolyCurve.Slice`/
  `ClosestS`, `ExcludeComponentIndices`, `FillTriangle`), not verified
  live. Flagged explicitly rather than claimed working.

## Junction corners: fix sidewalk band offset direction (was inset toward the interior)

- The offset-band fix from the previous round (below) had the offset
  direction backwards: `offsetOutward` pushed each fillet arc point AWAY
  from the fillet circle's own centre, which - worked through with
  concrete coordinates - is actually TOWARD the corner's true (un-rounded)
  vertex, i.e. toward the junction interior/asphalt, not toward the
  sidewalk. Reported live as a spurious inward "indent" cut into the kerb
  at ordinary intersections that previously looked fine.
- Why the earlier reasoning was wrong: `computeFillet` places the circle
  centre at `vertex + bisector * (tangentLength / cos(theta/2))`, strictly
  FARTHER from the vertex than the circle's own radius
  (`tangentLength * tan(theta/2)`) - so the vertex always sits OUTSIDE the
  circle, on the far side of the arc from the centre. That means the
  asphalt (which meets the arc on the vertex side) is on the side AWAY
  from centre, and the sidewalk is on the side TOWARD centre - the
  opposite of what the previous round assumed.
- Fixed by replacing `offsetOutward` with `insetTowardCenter`: rather than
  pushing a point further from centre by a generic direction vector, it
  computes the same point on a smaller CONCENTRIC arc (same centre, same
  angle, radius reduced by the sidewalk width) - the mathematically exact
  parallel offset of a circular arc, and impossible to get the sign wrong
  on since there's only one way to shrink a radius.

## Junction corners: sidewalk is now a proper offset band, not a fan (fixes the hook/sliver)

- The previous round's fix decoupled the asphalt fan (base pad vs. corner
  bulge) but left the SIDEWALK still fanned from a single `a.Outer` point
  across the curved kerb arc. That fan skewed the sidewalk triangles across
  the asphalt fillet and produced hook/sliver artifacts at rounded corners
  (reported live - a curl of concrete at a curve/straight merge, and
  scattered fragments around a junction).
- Root cause: a fan from one fixed point is only correct across a STRAIGHT
  span. Across the fillet's outward-bulging arc it reaches over the asphalt.
  Fixed by building the sidewalk as a real BAND: `cornerBoundaries` now
  returns the kerb (asphalt-edge) boundary AND a matching OUTER boundary,
  each kerb point offset radially outward (away from the fillet circle
  centre - which for the corner-facing arc is the sidewalk direction) by
  the sidewalk width, interpolated from road A's width at one end to road
  B's at the other, with the two endpoints pinned to the roads' own real
  `a.Outer`/`b.Outer` so the band meets each connected road's sidewalk
  seamlessly. The band is filled a quad (two triangles) per span between
  the two boundaries - it runs parallel to the kerb arc and never crosses
  into the asphalt.
- The straight-chamfer case is provably unchanged: `cornerBoundaries`
  returns exactly `({a.Kerb, b.Kerb}, {a.Outer, b.Outer})`, so the band
  loop emits the identical single `a.Outer-a.Kerb-b.Kerb-b.Outer` quad as
  before. Only genuinely-filleted corners take the new arc-following path.
- Asphalt is untouched by this change (base apex fan + local-a.Kerb corner
  bulge, both from the prior round); only the sidewalk construction moved
  from a fan to a band.

## Junction/curve fixes round: fillet tear, sidewalk height, curve faceting, junction re-connection, roundabout sidewalks + island

Five separate, concrete bugs found from live Studio screenshots (a real
4-way avenue intersection and a roundabout), fixed individually rather than
as one sweeping rewrite:

- **Torn, self-intersecting asphalt shards at filleted corners (the actual
  bug behind the fillet-rounding work shipped last round).** Root cause:
  the fillet's arc points were fanned from the pad's single GLOBAL apex,
  same as the base hull pad. A fillet arc bulges OUTWARD from the straight
  `a.Kerb-b.Kerb` chord (toward where the two roads' own kerb lines would
  actually meet), which on a sharp corner reaches past the global apex's
  own straight-line "view" of that edge - fanning that from apex is what
  produced the jagged dark shards visible at every corner of a real 4-way
  intersection. Fixed by decoupling `JunctionBuilder.Rebuild`'s asphalt fan
  into two layers: an unconditional BASE pad (the plain straight hull,
  fanned from the global apex, exactly as before corner rounding existed -
  never varies with whether a fillet succeeds) plus a strictly ADDITIVE
  rounding OVERLAY, fanned from each edge's own LOCAL `a.Kerb` point
  instead. A bad fillet case can now at worst overlap the already-correct
  base pad (invisible - same material, same height), never tear it.
- **Junction sidewalk/kerb sat flush with the roadway instead of raised.**
  `edgePointsForRoad`'s `Outer` points (and the hull's `Kerb` points) are
  sampled at the road's own deck-level Y - they were never lifted before
  being handed to `FillTriangle` for the sidewalk corner fill, so the
  junction's sidewalk pad rendered completely flat with the asphalt, right
  next to the connecting roads' properly raised (curb-height) sidewalks -
  a visible step exactly at the seam. Fixed: sidewalk fills now raise every
  point by `style.CurbHeightM` and use `thickness + curbHeight` as the
  extrusion depth, matching the exact convention `RoadBuilder` already uses
  for every raised (Sidewalk/Median) component elsewhere in the codebase
  (same `-thickness` bottom, `+curbHeight` top).
- **Straight-line faceting on tight curves (a roundabout ring, a tight
  junction spoke).** `RoadBuilder.buildStations` spaced adaptive stations
  by the CENTRELINE's own curvature only. A wide cross-section's
  concave-side (inner) edge on a tight bend rides a tighter effective
  radius than the centreline (offset a curve by `d` toward the inside of a
  bend of radius `R` and its own radius is `R - d`), so centreline-only
  spacing under-subdivides exactly that edge - it read as a smooth
  centreline with a visibly faceted kerb/sidewalk line just inside it.
  Fixed by computing an effective curvature `k / (1 - maxOffsetStuds * k)`
  (denominator floored so a radius tighter than the offset itself still
  yields a large-but-finite value instead of blowing up) using the widest
  lateral offset in the road's own cross-section, and spacing stations by
  that instead.
- **Couldn't connect a new road to an already-built intersection.** Root
  cause: `commitRoad`'s post-placement connection logic only ever checked
  for a nearby ROAD endpoint (`findConnectableEndpoint`) or a nearby road's
  MID-SPAN (`findMidSpanMatch`) - neither ever looked at `JunctionInstance`
  directly. Since `TrimApproaches` (shipped two rounds ago) now always
  pulls every connected approach's real endpoint back from the junction
  centre to the pad boundary, a new road aimed at an existing junction's
  centre had no nearby road endpoint or curve left to match against, so it
  silently placed unlinked. Fixed with a third fallback in `commitRoad`:
  `JunctionInstance.FindNear` directly, which `connectAt` already knew how
  to use (its `otherModel`/`otherEnd` args are optional). Also extended the
  live placement guide (`findEndpointSnap`) to snap toward a nearby
  junction's own centre (tangent left unlocked - no single tangent makes
  sense for a junction with more than one road already meeting there), so
  the click that's supposed to land there is actually easy to make.
- **Roundabout ring had no sidewalk pavement or a distinguished central
  island.** `RoundaboutBuilder.Create`'s profile was lane components only.
  Now flanks the lanes with a Sidewalk component on BOTH sides - the
  ring's frame (`CFrame.lookAt`, `RightVector = tangent x Up`) points
  toward the centre for a `DriveOnLeft = false` region but away from it
  for `DriveOnLeft = true` (reversing the tangent reverses `RightVector`
  too), so which physical edge is "first" vs "last" in the profile swaps
  with the region's driving side - flanking both sides sidesteps needing
  to track that, and the inner strip reads as a normal paved verge/truck
  apron against the island's own kerb anyway. The central island itself is
  new: a raised, kerbed disc sized via `RoadProfile.ComponentOffsetsM`'s
  own symmetric span (`-halfWidth` to `+halfWidth` around the centreline,
  regardless of which side is which) to reach exactly the ring's own inner
  pavement edge with no gap or overlap, using the same raised-part
  convention (`+curbHeight` top, `-thickness` bottom) as every other
  raised component in the codebase.
- **Investigated, not fixed this round: kerb/edge-line markings don't
  continue through a junction pad or around a roundabout ring.** Neither
  `JunctionBuilder` nor `RoundaboutBuilder`'s ring ever calls `Markings` at
  all (confirmed - no reference to it in either file), so the white
  edge-line simply stops dead at the pad/ring boundary instead of
  continuing around the corner. This needs a real marking system for an
  arbitrary polyline boundary (the hull edges/fillet arcs, or the ring's
  own kerb line), not a one-line fix - logged in `TODO.md` with a concrete
  sketch rather than rushed this round.
- Declined a much larger ask this round to rewrite the roundabout module
  as "Component-Based Generation (Spline Patching)" - polar-coordinate ring
  baking, plane-clipping feeder roads, asymmetric Bézier tangent blending -
  in favour of the concrete, verifiable fixes above. The specific symptoms
  described (missing island pavement, feeder-join tearing) are addressed
  by the sidewalk/island fix and the offset-aware curve subdivision fix
  respectively, both built from this codebase's own existing primitives
  (`RoadProfile`, `RoadBuilder.buildStations`, the trim-and-transplant
  mechanism already in place) rather than a new unverified architecture -
  consistent with how the RoadArchitect citation was handled earlier this
  project: verify and adapt concretely, don't adopt framing wholesale.

## Junction corners: real curb-return fillets, not straight chamfers

- Layered a bounded, fixed-radius circular fillet (`FILLET_RADIUS_M = 6`,
  a typical urban kerb-return radius) on top of every cross-road edge of
  the convex-hull pad, upgrading the straight chamfer shipped last round
  into an actual rounded corner - the shape a real intersection has.
- The construction is adapted from the user-supplied CivicArcRoadToolkit
  (CART) reference, specifically `JunctionTool.lua`'s `chooseArcCenter`/
  `sampleArc2D`: a genuine tangent circle, not a Bézier approximation.
  `computeFillet` first finds the corner VERTEX (where the two roads' own
  kerb lines would meet if extended - 2D line intersection on the ground
  plane), then derives a true circle tangent to both lines at that vertex
  via standard `tangent length = radius / tan(half-angle)` trigonometry,
  capped so it never reaches past the roads' own kerb points (a corner
  tighter than the requested radius, e.g. a short trimmed approach, gets
  a smaller effective radius instead of overshooting). `sampleFilletArc`
  samples the true arc by angle (`atan2`/`cos`/`sin`), not a spline
  approximation.
- Every failure mode - parallel kerb lines, roads diverging instead of
  converging from these points, a vertex unreasonably far away relative
  to the chord (near-parallel roads), a near-collinear pass-through -
  makes `computeFillet` return nil, and the caller (`cornerBoundaryPoints`)
  falls straight back to the plain `{ a.Kerb, b.Kerb }` chamfer already
  proven safe by the convex-hull property. The fillet can only ever make
  one corner MORE conservative than the last shipped round, never less -
  the same "bound the worst case, not just the common case" principle
  that came out of every earlier round's unbounded-arc failures.
- `JunctionBuilder.Rebuild`'s fan loop was rewritten to walk every hull
  boundary edge uniformly (same-road edges included, via wraparound)
  instead of special-casing "corner" vs "diagonal" edges, computing a
  boundary point list per edge (2 points for a straight chamfer, `2 +
  FILLET_ARC_SAMPLES` for a rounded corner) and fanning every consecutive
  pair - `FillTriangle`'s own degenerate-triangle guard silently no-ops
  the zero-length edges touching the fan's own apex, so no special case
  was needed there either.
- Investigated the user's earlier citation of RoadArchitect's
  `IntersectionCornerCalc()` (`GSDRoadUtility.cs`) before building this:
  pulled the real source via WebFetch and couldn't find any such method -
  only `Intersects2D`, a containment test against an already-computed
  fixed quadrilateral, not a corner generator. Reported this back rather
  than building on an unverified citation; CART's uploaded, actually-
  readable source became the real reference instead.

## Roundabouts: same spoke-trim robustness fixes as the junction approach trim

- Ported the two correctness fixes from `JunctionBuilder.trimApproach`
  into `RoundaboutBuilder.trimSpokeToRing`, which had the same two latent
  bugs:
  - **3D distance -> ground-plane distance.** `findRingCrossing` measured
    `(pos - center).Magnitude`, so a spoke arriving on a grade (its inner
    end higher/lower than the ring) reported an inflated distance and got
    under-trimmed, leaving it poking into the ring. Now uses ground-plane
    `distanceXZ`, matching the ring's actual circular footprint.
  - **Destroy-and-replace -> transplant in place.** `trimSpokeToRing` built
    a replacement road then called `road:Destroy()` on the original, which
    fired main.lua's `workspace.DescendantRemoving` road-removal listener
    once per spoke - each firing spuriously rebuilding the roundabout
    junction we're about to delete (and each spoke's far junction) from
    inside the trim loop. Now transplants the rebuilt geometry into the
    existing Model (swap children + attributes in place), so the listener
    never fires: only the road *Model* carries `RW_Road`, and it's never
    destroyed. Same mechanism the junction trim now uses.
- No behaviour change for the common flat-ground single-junction case;
  this hardens the grade and multi-junction-spoke cases.

## Junctions: approaches now TERMINATE at the pad boundary (RoadArchitect model)

- **The deeper root cause behind every "faulty intersection" report,
  finally identified by stepping back instead of re-patching the pad:**
  the pad was never the whole problem - the approach roads were. Each
  connected road was built FULL-PROFILE (sidewalks, kerb lines, edge
  markings) all the way to the junction's centre point, so every
  intersection interior had 2-4 complete road cross-sections overlapping
  each other with a pad drawn over the pile. That's what the pale
  sidewalk bands and white edge lines crossing the interior in every
  screenshot were - no pad shape could ever have looked right on top.
  The user's RoadArchitect reference (and our own RoundaboutBuilder, via
  trimSpokeToRing) both use the opposite model: roads STOP at the
  intersection boundary and the intersection owns the interior.
- **`JunctionBuilder.TrimApproaches` (new):** cuts every connected road
  back to the pad boundary (widest connected half-width + margin from
  the junction centre; ground-plane bisection for the crossing station,
  `CurveSegment.Sub` to truncate - same mechanism as the roundabout's
  spoke trim, except the trimmed end keeps its junction link). The
  rebuilt shorter geometry is TRANSPLANTED into the existing Model
  (children + attributes swapped in place) rather than destroy+replace,
  so commitRoad's still-held reference for the road's other-end
  connection stays valid and main.lua's removal listener doesn't fire
  mid-connect. Idempotent: an end already at the boundary is skipped, so
  repeat connects only trim further if a new wider road grew the pad.
  Called from `connectAt`/`connectAtSplit` right before `Rebuild` -
  deliberately NOT from Rebuild itself, which also runs from the
  road-deletion listener (including undo-driven removals) where
  re-trimming restored roads would fight the user's undo.
- **`connectAt` now reuses the junction an end is already linked to**
  before falling back to the position search: a trimmed end sits a
  half-road-width from its junction's centre - outside the snap-radius
  position search - and treating it as unlinked would have stamped a
  fresh junction over the existing link.
- Result: pad interior is clean continuous asphalt; each road's own
  markings, kerb lines, and sidewalks stop at the pad edge, and the pad's
  sidewalk corner fills connect neighbouring roads' pavement ends.
  Known gaps logged in TODO.md: roads with a transition/bay can't be
  trimmed (CanSplit guard - still overlap the old way), trims don't grow
  back if the widest road is later deleted, very oblique crossings can
  still overlap slightly beyond the circular trim radius, and the
  placement chain still seeds from the pre-trim endpoint.

## Junction pad rewritten as a convex hull fan - the actual fix

- **The centroid fix (previous round) was NOT enough** - confirmed live
  with a Google Maps reference for comparison: the same tight-angle fork
  still produced a jagged, self-intersecting star. Root cause this time:
  even fanning from a point guaranteed to be INSIDE the boundary doesn't
  make the fan simple unless the points are walked in their true boundary
  order - the "sort by raw angle around a point" scheme can still
  interleave two different roads' kerb points in the wrong sequence for a
  tight fork, producing overlapping triangles regardless of where the
  apex sits.
- **Replaced the whole per-pair scheme with a proper convex hull.**
  `JunctionBuilder.lua` now computes the actual convex hull of every
  connected road's kerb points (`convexHull`, standard Andrew's
  monotone-chain construction) and fan-triangulates THAT from one of its
  own vertices. A convex polygon can always be validly fan-triangulated
  from any of its own vertices - this isn't "a better heuristic," it's a
  property of convex polygons, so there is no remaining case where this
  can produce self-intersecting geometry. This removes `isOpposingPair`
  and the angular-span threshold entirely - a convex hull's own boundary
  IS the correct answer to "which gaps are real corners," no separate
  judgement call needed.
- **This also fixes something that was arguably wrong even in the
  "working" cases**: real intersections (see the Google Maps references
  from earlier this project) are one continuous connected pad, not a set
  of pieces with gaps left open on the far side of a T-junction or a
  gentle bend. The old "skip gaps wider than ~130°" logic was cutting
  those away specifically to prevent spikes; the convex hull naturally
  produces the same continuous, gap-free pad a real intersection has,
  without needing that special case at all.
- Corners are still straight chamfers (hull edges), not rounded curb
  returns - see TODO.md for why, and what proper rounding would need.

## Junction pad: fan from the kerb-point centroid, not the stored junction position

- **Confirmed live with a deselected screenshot that the straight-chamfer
  rewrite (previous round) was STILL broken** - not another oversized
  spike this time, but a jagged, self-intersecting star of small
  overlapping triangles with a visible hole in the middle of the actual
  asphalt, on a tight-angle fork (two roads diverging at a narrow angle
  plus a third crossing road). Root cause: the fan was built from
  `junctionData.Position` - the junction's stored `RW_Position`, set ONCE
  in `JunctionInstance.Create` from wherever the first two roads
  happened to snap together, and never recomputed as more roads connect
  later. A fan triangulation is only guaranteed non-self-intersecting
  when its apex is actually inside the region the boundary points
  enclose; for a tight fork the stored position can end up outside that
  region entirely, and fanning triangles from an apex outside their own
  boundary produces exactly this kind of self-crossing mess. Fixed by
  computing the fan apex fresh on every rebuild as the CENTROID of the
  actual kerb points being used - the centroid of a point set always
  lies inside its convex hull, which is what a fan needs to stay simple.
  `junctionData.Position` is untouched for everything else (the fallback
  circular pad, roundabout centre, spoke trimming).

## Junction corners rewritten as straight chamfers (dropped the arc entirely)

- **Confirmed live a third time (screenshot, reference to
  github.com/MicroGSD/RoadArchitect) that the corner geometry is still
  broken** - after two rounds of capping the rounded-corner Bézier
  construction (angular gap threshold, then chord-relative control-point
  distance) it kept resurfacing on the same class of junction. Rather
  than add a fourth threshold, replaced the whole rounded-corner
  construction with a straight chamfer: `FillTriangle(center, a.Kerb,
  b.Kerb, ...)` directly, no Bézier, no control point, no distance cap.
  Two fixed points joined by a straight line can't spike, self-intersect,
  or need bounding - the entire bug class is gone by construction instead
  of by another patch. Removed `cornerControlPoint`/`sampleCornerArc` and
  the now-dead `MAX_CONTROL_DISTANCE_STUDS`/`_CHORD_RATIO`/
  `CORNER_ARC_SAMPLES` constants and the unused `EdgePoint.Tangent`
  field. Trades the rounded curb-return look (matching the Google Maps
  references from earlier this session) for reliability - noted in
  TODO.md as still worth doing properly later via a fixed-radius fillet
  tangent to both kerb lines, which doesn't have the same unbounded-reach
  failure mode a tangent-line intersection does.
- **Clarified the "curved road tool sometimes needs only 1 click instead
  of 2" report** - not a bug: when the start point snaps onto an existing
  road's own end, its tangent is locked and the Curve/Freeform tools
  genuinely need one fewer click (no separate guide point - the shape is
  derived from the locked tangent instead). `GetHint()` didn't explain
  why, so it read as the guide-point step randomly vanishing. Now says so
  explicitly, and points at the new "Snap to existing road" toggle (see
  above) as the way to always get the full click sequence.

## Road Editor layout overflow fix + junction corner opposing-pair check

- **"There is still a window below my road cross section" - the Lane
  Strip card's own content was overflowing its container.** Confirmed
  from a screenshot: selecting a lane tile shows a Controls row (width/
  direction/reorder/remove) AND, when that lane isn't the rightmost one,
  a Marking row - together taller than `STRIP_HEIGHT`'s fixed 140-stud
  budget (only ever sized for Header + Strip + Controls, never accounting
  for the Marking row appearing at the same time). The overflow spilled
  out the bottom of the card's fixed-height Frame, past the whole panel's
  own bounds, landing near the true screen edge - which is also why an
  earlier report ("tile editor now renders below the road cross section")
  couldn't be reproduced from its screenshot: it's the same overflow,
  just caught with a different lane selected. Raised `STRIP_HEIGHT` to
  190 and the Road Editor panel's own height from 420 to 470 to match.
  Also bumped every bottom-anchored panel's screen margin from 12 to 40
  studs (`main.lua`, 9 call sites) for headroom against Studio's own
  command bar, which sits in the region our `IgnoreGuiInset = true`
  ScreenGuis extend into.
- **Junction corner spike - still recurring after two prior fixes,
  confirmed live again with a screenshot.** Root cause, finally: both
  previous fixes (skip wide angular gaps, cap the control point relative
  to chord length) only look at where the two KERB POINTS ended up, never
  at whether the two ROADS are actually opposing. A through-piece that's
  even slightly curved right at the junction shifts its kerb points just
  enough that the angular gap between them can land under any reasonable
  threshold while the roads themselves are still clearly "the same
  through-road, split by a branch" - no threshold on the point geometry
  alone was ever going to catch every case. Added `isOpposingPair`: skips
  corner-fill between two DIFFERENT roads whenever their own outward
  tangents (not their kerb points) are more than ~120 degrees apart,
  independent of profile matching (so a highway narrowing into a street
  is still caught, unlike `isSmoothPassThrough`'s whole-junction skip)
  and independent of the resulting point-angular-gap size.

## Snap toggles + standalone Roundabout tool in Road Tools

- **Requested live: "there is currently no button on road tools to: Snap
  to existing road, Snap to grid, Build roundabout."** All three now have
  a home in `BuildBar.lua`:
  - New `Settings.SnapToRoad` (default true) gates
    `findEndpointSnap`/`findConnectableEndpoint`/`findMidSpanMatch` in
    `createRoadSession.lua` - previously always-on with no way to turn it
    off. `Settings.SnapToGrid` already existed but only had a checkbox in
    the Regional Preference settings dock, not in Road Tools itself where
    it's actually used while placing - both now have checkboxes right in
    the tool panel.
  - New "Roundabout" tool mode alongside Straight/Curve/Freeform - a
    single click drops a standalone ring (`RoundaboutBuilder.Create`)
    centred at the clicked point, with the same Radius/Lane-count/
    Lane-width fields the junction panel's "Make Roundabout" already
    used. Previously the ONLY way to place a roundabout was to first
    connect roads into a junction, select it, and use its panel - this
    adds a direct path that doesn't require an existing junction at all.
    Shares the junction-triggered ring's known limitation: the ring isn't
    wired into the road/junction data model, so a road drawn to cross it
    afterwards won't auto-connect (see TODO.md).
  - Icon note: the new Roundabout tool button has no dedicated icon yet
    (falls back to blank, identified by its hover label like the other
    tool buttons) - the icon-asset pipeline that built the category tab
    icons wasn't re-run this round.

## Junction corner geometry: bound the control point relative to chord length

- **Reported live with a screenshot: a T-junction still produced a wildly
  oversized diamond-shaped spike**, despite the previous round's fix
  (skip a between-road gap wider than ~160deg). Root cause: the 160deg
  angular-span guard only caught gaps that were ALREADY very wide - it
  didn't help when the two "through" pieces at a T-junction weren't
  perfectly opposite (e.g. one piece curves right where it meets the
  junction), landing the gap somewhere under 160deg but still nowhere
  near a real corner. Once a gap passed that guard, the corner control
  point (`cornerControlPoint`'s tangent-line intersection) was only
  capped by a flat `MAX_CONTROL_DISTANCE_STUDS = 200` - a fixed distance
  that dwarfs a typical junction's actual scale (kerb points usually sit
  10-30 studs from the centre), so a near-parallel pair could still push
  the control point (and therefore the whole arc) many times larger than
  the junction itself. Fixed two ways: tightened the angular guard from
  160deg to 130deg (closer to what a genuine curb-return corner spans in
  practice), and added a SECOND cap on the control point - relative to
  the chord length between the two points (`MAX_CONTROL_DISTANCE_CHORD_RATIO
  = 3`), not just an absolute stud count - so even a pair that slips past
  the angular guard can't bulge disproportionately; it degrades to a
  bounded straight blend instead. This is a general fix (bounds the
  geometry by construction) rather than another special-cased threshold
  tuned to one screenshot, since the previous two rounds' fixes for this
  same "spike" symptom (skip pass-throughs, then skip wide angular gaps)
  each turned out to have a gap of their own.

## Highway shoulders no longer get a kerb/edge line by default

- Both built-in Highway profiles (`builtin_highway`, `builtin_highway_3`)
  now default `KerbRestriction = "NoLine"` - requested a while back
  ("by default lets not include the outer edge kerb marking for
  highways") but never actually applied to the profile data, only logged.
  Still overridable per-road via the existing "Kerb lines" dropdown in the
  Road Editor (`ProfileFields.lua`) for anyone who wants it back.

## Fix stale elevation preview (root cause of the "elevation doesn't work" report)

- **Root-caused the elevation report from the previous round**: typing a
  new value into the Elevation textbox, pressing R/F, or clicking the
  up/down arrows all changed the session's `elevation` number correctly,
  but the live placement ghost didn't move - it stayed at whatever height
  was current the last time the mouse itself physically moved.
  `createRoadSession.lua`'s `hoverPos` was only ever recomputed from
  inside the `mouse.Move` handler, so any height change made without also
  nudging the mouse (typing a number, pressing a keybind while aiming) had
  no visible effect until the cursor happened to move again - which reads
  exactly like "the elevation control stopped working." Fixed by caching
  the last raw ground point (`lastGroundPos`) on every mouse-move and
  extracting the snap/elevation-offset logic into `refreshHoverPos()`,
  called both from `mouse.Move` and from `adjustElevation`/`setElevation`
  directly, so a height change is reflected in the ghost immediately.
  (The `BuildBar.lua` row-collision bug fixed last round was real but
  turned out to be a different, unrelated issue - kept fixed regardless.)

## Roundabout ring pavement notch fix + BuildBar row-collision bug

- **Fixed the roundabout ring/spoke pavement misalignment** (reported live
  with a screenshot: rectangular notches where each trimmed spoke's
  sidewalk cut into the ring). Root cause: `trimSpokeToRing` searched for
  where the spoke's *centerline* crosses the ring's radius, but the
  sidewalk/kerb edges sit laterally offset from the centerline, so at that
  same station their true distance from the junction centre is
  `sqrt(d^2 + halfWidth^2)` (Pythagoras) - farther out than the centerline
  point, poking past the ring's true circular boundary. Fixed by searching
  for the crossing at an adjusted radius (`sqrt(radius^2 - halfWidth^2)`,
  minus a small `RING_TRIM_MARGIN_STUDS` safety margin) instead of the
  ring's raw radius, so the spoke's widest cross-section point stays just
  inside the ring instead of outside it.
- **Found and fixed a real, unrelated bug while investigating a separate
  "superelevation breaks elevation" report** (see `KNOWN_ISSUES.md` - that
  one's still unconfirmed): `BuildBar.lua` had two different rows both
  assigned to `children.Transition` - the "Widen to" dropdown and the
  superelevation "Transition (m)" slider - so the second silently dropped
  the first from the panel whenever Superelevation was on. Renamed the
  superelevation one to `children.BankTransition`.

## Fixed junction corner spike bug (2-road bends and T-junctions)

- **Confirmed live with screenshots (a curving 2-road bend, then a
  T-junction) that the new curb-return corner code produced a wildly
  broken, self-intersecting spike.** Root cause: every between-road gap
  in the sorted kerb-point list was getting a corner-arc treatment,
  including gaps that wrap most of the way around the far side of a bend,
  or - for a T-junction - the "through" span between the two separate
  road Models that visually form one straight through road on either
  side of the branch. Bridging a 170°+ gap with a single quadratic-Bézier
  corner produced exactly the oversized spike reported. Fixed by
  computing each gap's actual angular span and skipping corner treatment
  entirely past ~160° - there's no real intersection surface out there,
  just open space beside the road. Verified the fix against a worked
  T-junction example by hand (a ~174° "through" gap correctly skipped,
  two genuine ~84° corners correctly built).
- Confirmed the standing "plain `BasePart`s, no Union/MeshPart/
  EditableMesh" constraint is already satisfied everywhere in the
  codebase - audited every `Shape =` assignment; `Wedge` only appears
  inside `FillTriangle.lua` itself (the shared exact-angled-fill utility),
  everything else defaults to `Block` or uses `Cylinder` for genuinely
  circular shapes. No code changes needed for this one.

## Junctions: real curb-return corners, not a flat pad

- **Confirmed live that the ordinary junction fillet "genuinely doesn't
  change the roads"** - same class of complaint that led to the
  roundabout spoke-trim fix, now addressed for plain intersections.
  `JunctionBuilder.lua`'s pad is now real curb-return geometry: each
  connected road contributes its own KERB points (the roadway/
  non-roadway boundary, where a kerb physically sits) and OUTER points
  (the profile's true outer edge, e.g. a sidewalk's outer edge). Between
  two angularly-adjacent roads, a tangent-continuous quadratic-Bézier
  corner - built via the classic "intersect the two roads' own tangent
  lines for the control point" construction, degrading to a straight
  blend for near-parallel roads or unreasonable intersection distances -
  is fanned from the junction centre as the asphalt surface, and the
  strip between that arc and each road's outer edge is filled separately
  with sidewalk material as the actual pedestrian corner. A road's own
  kerb-to-kerb span (both points from the same road, not a gap between
  two different roads) still just fans directly - no corner needed
  there, that's the road's own pavement.
- Known remaining gaps (superelevation roll ignored, sidewalk corner
  material doesn't inspect what's actually there, no lane markings
  through the junction) and newly-reported issues (roundabout
  sidewalk/pavement alignment at the ring boundary, no mid-span-to-
  mid-span crossing detection, no snap-to-road/grid UI toggle) are
  logged in `TODO.md`.

## Roundabouts: configurable lanes + trims spokes to the ring boundary

- **Confirmed live that generating the ring as a free-standing object with
  no effect on the connected roads read as broken**, not just rough (a
  screenshot showed a 4-way crossroads with roads running straight
  through an untouched ring). `RoundaboutBuilder.CreateAtJunction` now
  trims every connected spoke back to the ring's own boundary before
  building it: for each spoke, bisects along its curve to find the
  station where it crosses the ring's circle (reusing the same
  transition/bus-bay guard `RoadSplit` uses - a spoke with either is left
  untouched), truncates it there via `CurveSegment.Sub`, and removes the
  junction node itself once the ring is built, since the ring now serves
  as the intersection surface in its place. Still no per-lane merge
  tapering at each approach (a trimmed spoke's pavement just stops at the
  boundary) - see `TODO.md` for the full remaining gap list.
- **Lane count and lane width are now configurable** (were hardcoded to a
  single region-default-width lane) - two new fields alongside the radius
  on the junction panel's "Make Roundabout" controls.

## Junctions Phase 2+3 v0: roundabout ring generator + lane/traffic-light API surface

- **Requested to build all remaining phases now, roughly, to be refined
  later** - so this round trades depth for breadth on purpose. Full scope
  of what's real vs. deliberately stubbed is in `TODO.md`; summary below.
- **`RoundaboutBuilder.lua` generates a real single-lane, one-way ring.**
  A `PolyCurve` of 4 cubic-Bézier quarter-arcs approximates a true circle
  (the standard `k = 0.5522847498` construction) - not a new
  `CurveSegment` kind, since a closed ring is mechanically just an
  ordinary road whose curve starts and ends at the same point, so
  `RoadBuilder.Build` needed zero changes to build it. Triggered from a
  selected junction's panel: a "Make Roundabout" button + radius field,
  shown once 3+ roads are connected. Deliberately doesn't merge the
  connected roads into the ring (a visible seam is expected), isn't
  wired into the road/junction data model at all (not selectable/
  editable/deletable in-plugin yet - delete via the Explorer), and only
  supports single-lane.
- **`JunctionLanes.lua` computes a real per-lane connection graph** - every
  incoming lane at a junction paired with every outgoing lane on a
  different connected road (using each component's own traffic
  `Direction` and which end it connects with) - but nothing calls it yet.
  No drag UI, no turn classification, no persistence (references live
  road Models directly, so it only makes sense freshly computed). A
  `DefaultPhases`/`SignalPhase` mock proves the data shape a future
  traffic-light plugin would consume, not a real signal-phase algorithm.

## Junctions Phase 1b cleanup: orphan cleanup, selection UI, real fillet polygon

- **Ground-picking for new road placements now ignores existing roads and
  junctions entirely.** Reported live: placing a road across an existing
  one used to "stack" on top of its deck instead of measuring true ground
  height, because `raycastGround` didn't exclude the Roads/Junctions
  folders from its raycast - crossing over something was never actually
  routed around ("we have a intersection node handler anyway, there's
  already an elevation control"), it just looked like it was because the
  raycast picked up whatever was physically highest under the cursor.
  Fixed by excluding both folders; elevation stays an explicit, separate
  control for the cases that genuinely want a different height.
- **Deleting a connected road no longer leaves a stale junction pad.** A
  `workspace.DescendantRemoving` listener in `main.lua` (owned at the
  top level so it doesn't come and go with tool activation, unlike a
  per-session hook) fires just before a Road model is actually removed -
  while its `RW_StartJunctionId`/`RW_EndJunctionId` attributes are still
  readable - and either rebuilds that junction's pad against whatever
  roads are left, or deletes the junction outright if this was its last
  connection.
- **A junction can now be selected and deleted directly.**
  `JunctionEditSession.lua` mirrors `RoadEditSession`'s own
  Selection-service-driven pattern (click a junction's pad in the
  viewport or Explorer, no tool activation needed) but stays its own
  small module rather than folding into the already-large road-specific
  state machine - a road and a junction are never selected by the same
  click. `JunctionPanel.lua` shows how many roads meet there and a Delete
  button that unlinks them (clears their `Start`/`EndJunctionId`
  attributes) without touching the roads' own geometry.
- **The pad is now a real fillet polygon, not a circle.** Each connected
  road contributes its own left/right pavement-edge points at the exact
  station it meets the junction; sorted by angle around the junction
  centre and fan-triangulated from there using `FillTriangle` (the same
  "exact shared edges, no padding" technique already proven for curve
  joints and superelevation wedges), so the pad's outline actually
  follows the roads that meet there instead of an arbitrary generously-
  sized circle. Falls back to the old circular pad only if no road
  contributed usable edge points at all (an empty profile).

## Junctions Phase 1b: mid-span connect + skip pads for pass-throughs

- **Drawing a new road across an existing one now actually connects them**,
  not just visual overlap. Previously a junction could only form where two
  roads' stored endpoints coincided (Phase 1a) - confirmed live that this
  wasn't enough ("i cant connect new roads to it yet"). `RoadSplit.lua`
  splits an existing road at whatever station a new road's endpoint lands
  closest to, using genuine Bézier subdivision (`CurveSegment.Sub`, added
  via the standard De Casteljau split algorithm) rather than
  `PolyCurve:Slice`'s lightweight view - the two resulting pieces are real,
  independently-persisted roads, each stamped with their own curve control
  points. A JunctionNode is created at the cut and the new road links to
  it, same as an ordinary endpoint connection. Match tolerance scales with
  the existing road's own width (half its pavement plus the normal snap
  radius) so clicking anywhere on its visible surface counts, not just
  within a few studs of its exact centreline.
  - v1 scope: only plain roads can be split (no active widen/narrow
    transition, no bus bay - both refuse cleanly rather than risk wrong
    geometry); MarkingStretches/KerbStretches on the original road are
    dropped rather than remapped across the cut.
- **Junction pads now skip themselves for a plain 2-road pass-through**
  (matching profiles, roughly opposite outward tangents - a chained
  straight or gently-curving continuation) - confirmed live that every
  meeting point getting a pad, including ordinary chaining, was more
  clutter than signal. A genuine corner, crossing, or 3+-way junction
  still gets one.

## Junctions Phase 1a: node data model + auto-fillet pads

- **First real step of the intersections/roundabouts feature** (CS2-style:
  an intersection is a node, not just two roads happening to touch). Two
  roads meeting has always been pure positional coincidence up to now -
  each road's `Curve` is a fully independent `PolyCurve`, with nothing
  recording "this road's end is the same physical point as that other
  road's start." `JunctionInstance.lua` adds a real `JunctionNode` (its own
  Model under `workspace.Junctions`, a stable GUID) that roads reference by
  Id (`RW_StartJunctionId`/`RW_EndJunctionId` attributes, threaded through
  `RoadInstance.RoadData`) - the junction doesn't keep its own reverse list
  of connected roads (same "single source of truth, no dual bookkeeping"
  choice already made for Bay/MarkingStretches/KerbStretches); it's derived
  by scanning for matching Ids.
- **Endpoint snapping now creates junctions on BOTH ends of a placement**,
  not just the already-working chained-continuation case.
  `createRoadSession.commitRoad` checks both the new road's start and end
  position against every other road's stamped endpoint attributes after
  committing, and links whichever ends coincide into a shared junction
  (reusing one within snap radius if a third road lands on an
  already-shared corner, rather than stacking duplicates) - all inside the
  same `ChangeHistoryService` recording as the placement itself, so undo
  doesn't leave an orphaned junction or a half-linked neighbour behind.
- **`JunctionBuilder.lua`** builds the junction's visible geometry: a v1
  circular asphalt pad flush with the roads' deck height, radius sized to
  the widest connected road's profile. Deliberately simple for a first
  pass - no exact per-corner fillet polygon yet, no skip for a plain
  2-road pass-through, no lane markings drawn through it. Full phased plan
  (Phase 2 roundabouts, Phase 3 lane connector/traffic-light API) and the
  complete Phase 1a scope-out list are in `TODO.md`.

## Fixed kerb-stretch selectability/rendering (EdgeIndex) + category autofocus

- **All kerb lines are now selectable, and stretches actually render.**
  Two bug reports traced to one root cause: `KerbStretch.Side` only ever
  supported `"Left" | "Right"` (the road's two true outermost edges), but
  the render loop's own gate for "is this position a genuine kerb line
  eligible for splicing" was `previousComponent == nil` / `nextComponent
  == nil` - literally "is this array index 1 or n" - while the hit-test
  helper (`Markings.KerbSides`) correctly checked "is the neighbouring
  component nil-or-raised". Those two conditions only agree when the
  roadway component is the very first/last element of the whole profile,
  which is false for almost every real profile (`Sidewalk, Drive, Drive,
  Sidewalk` puts the kerb line at the boundary between components 1 and
  2). Confirming a stretch always saved correctly; the renderer just
  silently never spliced it in for a typical road, reading as "pressing
  change kerb type does not work."
  - Generalised `KerbStretch.Side` to `KerbStretch.EdgeIndex: number` - a
    boundary-index scheme matching lane boundaries (`0` = the road's true
    left edge, `i` = the boundary between `components[i]` and
    `components[i+1]`, `#components` = the true right edge), so a profile
    with an internal median now has every one of its kerb lines
    independently selectable and overridable, not just the outer two.
  - `Markings.KerbSides` replaced with `Markings.KerbEdges`, which mirrors
    the render loop's own `leftIsKerb`/`rightIsKerb` condition exactly
    (single source of truth, same pattern already used for
    `IsSameDirectionBoundary`/`SiblingBoundaries`) - hit-testing and
    rendering can no longer disagree about what counts as a kerb line.
  - Threaded through `RoadEditSession.lua` (drag/hit-test/ghost/draft/
    overwrite), `RoadInstance.lua` (stamped-attribute decode),
    `RoadBuilder.lua` (per-slice remap), `KerbStretchPanel.lua` and
    `MarkingStretchListPanel.lua` (dropped the now-meaningless Left/Right
    wording in favour of an Edge-index label).
- **Fixed "adding new category doesn't actually add category."** The
  "+ New Category..." text field never received focus when it appeared,
  so typing immediately after selecting it (the natural expectation) went
  nowhere - clicking away then fired `FocusLost` with empty text, which
  silently reverted back to the dropdown. Now calls `:CaptureFocus()` on
  mount via a ref + effect.

## Custom roads can be categorised into Road Library tabs

- **Road Editor gained a Category field**, letting a custom road be filed
  under Streets/Avenues/Highways/Paths (the built-in tabs) instead of
  always landing in "Custom" - or under a freely-typed new category name
  via a "+ New Category..." option, which becomes its own tab the next
  time the library renders. This was already fully supported on the
  READ side - `RoadLibraryPanel.lua` already renders any `Category`
  string as its own tab, falling back to a generic icon via
  `CategoryThumbnail.Build` for one it doesn't specifically recognise -
  the only missing piece was ever being able to SET it to anything other
  than "Custom" in the first place.
  - The dropdown's options are the four built-ins plus whatever category
    names are already in use across the whole library (scanned from
    `props.Picker.Options`, only available in the standalone Road Editor
    context - Category is a library-organization concept, so the field
    doesn't appear on `RoadInspector`, which edits one specific placed
    road instance).
  - "Save as Copy" (for a built-in template) no longer force-overwrites
    `Category` back to `"Custom"` after the copy is made - it used to,
    which would have silently discarded a category chosen in the new
    field the moment Save was clicked. "Use as Template" (from a placed
    road) still defaults a fresh copy to `"Custom"` before the editor even
    opens, which is fine since that's just an initial value the new field
    can then change.

## Slider actually follows the mouse; transition length in Road Tools; keybinds panel back to keyboard-first

- **Fixed the slider not following the mouse during a press-and-slide**
  (reported live with a screenshot of the transition-length slider).
  `Components.Slider` was built on HueBar's track-local `InputChanged`
  convention, which only receives events while the cursor is physically
  inside the 16px-tall track - drift a few pixels above or below mid-drag
  (which always happens) and the handle froze. Rewritten: pressing the
  track starts a drag that a GLOBAL `UserInputService.InputChanged`
  connection tracks until release, wherever the cursor goes (the same
  pattern `useLaneDrag` uses). Also decoupled drag visuals from the
  commit: while dragging, position/readout update from cheap local React
  state only, and `props.OnChanged` fires ONCE on release - both callers
  wire `OnChanged` into genuinely heavy work (settings persistence plus
  rebuilding the built-in road library via `OnSettingsChanged`), which
  was far too slow to run per mouse-move and the second half of why
  dragging felt rough.
- **Superelevation transition length is now editable from Road Tools
  too** - the same `SuperelevationRunoffM` slider Regional Preference
  got last round, surfaced in the BuildBar under the Speed field whenever
  banking isn't Off, so the transition feel can be dialled in while
  actually placing roads without leaving for a settings dock.
- **Keybinds panel reworked back to keyboard-first, mouse capture
  removed** ("We dont need mouse binding bro, we need keybinds"). The
  live-capture flow shipped earlier this session could only ever capture
  mouse buttons (keyboard input from the capture flow confirmed dead by
  live testing), which isn't what was wanted from a keybinds panel.
  Removed the whole capture apparatus from `main.lua` (WindowFocused
  gate, InputBegan listener, per-action capture state);
  `KeybindsGui.lua` is now a clean read-only reference again: each
  action's always-working built-in keys plus the exact PluginAction name
  ("easyRoad: ...") to search for in Studio's Customize Shortcuts dialog,
  which the user confirmed is the right mechanism for plugin keybinds
  ("PluginActions is the way... PluginAction keybind can be set by
  user"). The PluginAction registrations themselves were already in
  place and are unchanged.

## Kerb marking "stretch" - the lane-marking stretch tool's own kerb-line counterpart

- **Kerb restriction lines (single/double yellow, no line at all) can now
  be overridden over a free-form sub-range** of the road's own left or
  right kerb line, the same click-a-target-then-drag-a-range interaction
  the lane-marking stretch tool already established - a new "Stretch Kerb
  Marking" pill on the segment menu. Deliberately scoped to just the
  road's two OUTERMOST edges (`Markings.KerbStretch.Side: "Left" |
  "Right"`), not every individual kerb-adjacent boundary a profile might
  have (e.g. around an internal median) - matches the same Left/Right-only
  scope the bus bay tool already uses for "which side of the road," and
  sidesteps a much bigger disambiguation problem (which internal kerb edge
  does "Left"/"Right" even refer to with more than two). An internal
  kerb-adjacent boundary still renders correctly, just always at the
  whole-road `KerbRestriction`, unspliced - flagged in `TODO.md` rather
  than solved blind, mirroring the existing `BuildWithBay`-transition
  caveat already logged for lane stretches.
  - **`Mesh/Markings.lua`**: new `KerbStretch` type + `MarkingOptions.
    KerbStretches`; new exported `Markings.KerbSides(components)` (mirrors
    the render loop's own leftIsKerb/rightIsKerb condition for the
    cross-section's outermost roadway component specifically, so a click
    can't target a "kerb" that doesn't actually render); the kerb-line
    emission loop refactored into `emitKerbEdge`/`emitKerbSide` helpers
    that splice stretches sorted by station exactly like
    `emitBoundaryLine` does for lane markings - each spliced piece
    independently re-derives its own line type AND lateral offset from
    its own effective restriction (kerb-restriction offset vs. plain
    edge-line offset are genuinely different lateral positions, unlike
    the lane-boundary case where only the line type changes).
  - **`RoadEditSession.lua`**: new `PlacingKerbStretch`/
    `ConfirmingKerbStretch` modes, built as a deliberately PARALLEL (not
    intertwined) state machine to the lane-stretch one - separate draft/
    drag state, separate ghost list (`EasyRoadKerbStretchGhost`), to avoid
    risking a regression in the lane-stretch flow that took many rounds
    to stabilize this session. `resolveKerbSideFromHit` picks whichever
    kerb side a click lands nearer to (gated on `Markings.KerbSides` so a
    profile with no roadway component at all can't be clicked). The two
    stretch kinds DO share one rebuild helper now
    (`rebuildWithMarkingStretches` generalized to `rebuildRoad(marking
    Stretches, kerbStretches, historyLabel)`) since that part was already
    a pure mechanical "rebuild in place and re-stamp both lists" step with
    no drag/hit-test logic to entangle. `applyKerbStretchOverwrite`
    mirrors the lane tool's overwrite-on-overlap semantics, simplified
    since a kerb stretch only ever has one `Side`, not an arbitrary
    `ComponentIndices` set to intersect.
  - **`RoadInstance.lua`**: `RoadData.KerbStretches` (stamped/read via
    `RW_KerbStretchesJson`, same pattern as `RW_MarkingStretchesJson`).
    Every place a `RoadData`/build-options table gets reconstructed
    (`session.Apply`, `session.ConfirmBay`) now explicitly threads
    `KerbStretches` through too, or it would silently wipe on the next
    unrelated edit - the exact bug class the `MarkingStretches` comment
    already warned about for that same reconstruction site.
  - **`Mesh/RoadBuilder.lua`**: `BuildOptions.KerbStretches`, plus a
    `kerbStretchesForSlice` mirroring `BuildWithBay`'s existing
    `stretchesForSlice` (simpler - no `ComponentIndices` to remap, `Side`
    is stable across slices, just the station clip/offset).
  - **UI**: new `KerbStretchPanel.lua` (confirm-step: From/To/Restriction,
    mirrors `MarkingStretchPanel.lua`); `MarkingStretchListPanel.lua`
    gained a second "Kerb Stretches" section so "Edit Lane Markings"
    surfaces both kinds in one place rather than needing a separate list
    view; `PieMenu.lua` gained a sixth ring slot (`TopRight`, already
    added this session for "Place More (Start)") to fit "Stretch Kerb
    Marking" alongside the existing five segment-menu pills; the
    segment-menu's "Clear Marking Stretches" pill now clears both kinds
    in one action (`ClearMarkingStretches` + `ClearKerbStretches`
    together) rather than needing a second dedicated pill on an
    already-full ring.
  - **Not verified in a live Studio session** - this is a large amount of
    new geometry/state-machine code built in one pass without live
    testing, following the same architecture (and reusing the same
    helpers: `frameAtWithRoll`, `GHOST_MAX_SEGMENTS` facet-chain ghosts,
    the click-then-drag-then-confirm pie-menu flow) that took several
    live-tested rounds to get fully right for lane-marking stretches.
    Flagging this explicitly rather than claiming confidence a first pass
    at this scale doesn't warrant.

## Per-stretch dash length/gap override

- **Marking stretches can now override dash length/gap independently of
  the region default**, not just the line type. `Markings.MarkingStretch`
  gained optional `DashLengthM`/`DashGapM` fields, threaded through
  `emitBoundaryLine`'s stretch-piece `addLine` call (previously hardcoded
  `nil, nil`, always falling back to the region/whole-road default no
  matter what). `RoadEditSession`'s stretch draft pre-fills both from the
  region's own current defaults the moment a range is dragged out (so the
  confirm panel's number fields always show a real, editable value rather
  than a blank one) via two new setters,
  `SetMarkingStretchDraftDashLength`/`DashGap`. `MarkingStretchPanel.lua`
  shows the two new fields only when the selected line type actually has a
  dashed component (Dashed/DoubleDashed/SolidDash/DashSolid) - stored but
  unused on solid-only types.
- Threaded the two new fields through every place a `MarkingStretch` gets
  reconstructed rather than passed through whole, so they can't get
  silently dropped: `RoadInstance.lua`'s JSON stamp/read,
  `RoadBuilder.lua`'s `BuildWithBay` slice-remapping, and
  `RoadEditSession.lua`'s `applyStretchOverwrite` (all three of its
  existing-stretch remainder pieces).

## Superelevation transition length: fixed a real scale bug, added a slider

- **Root-caused "at 6.667stud=>1m instead of 3.57 it is more abrupt."**
  `RoadBuilder.lua`'s superelevation runoff/smoothing window was a bare
  stud constant (`RUNOFF_LENGTH_STUDS = 40`), not a real-world distance -
  at a higher studs-per-meter scale than the ~3.571 default, the same 40
  studs covers fewer real-world meters, so the bank transition physically
  happens over a shorter distance and reads as more abrupt. Replaced with
  `settings.SuperelevationRunoffM * settings.MetersToStuds`, so the
  transition covers the same real-world distance regardless of a user's
  own scale - the actual bug, independent of whether it's ever exposed as
  a setting at all.
- **New `Settings.SuperelevationRunoffM`** (meters, default 11.2 - exactly
  reproduces the old fixed 40-stud behaviour at the default 3.571
  studs/meter scale) plus a new `Components.Slider` (drag-a-track-and-
  handle control, same InputBegan/InputChanged +
  `UserInputService:IsMouseButtonPressed` drag convention the colour
  picker's hue bar already uses) wired into Regional Preference's
  Superelevation section as "Transition length (m)", shown whenever
  banking isn't Off. `Components.Slider`'s own Frame carries a
  `UIFlexItem(Grow)` rather than defaulting to `Components.Row`'s 100%-of-
  parent sizing, so it shares the row's actual remaining width (after the
  Label) instead of overflowing past it - the same "share the row"
  mechanism `Components.Button`'s existing `Grow` prop already relies on.

## "Place More" can now continue from either end of the road

- **"Place More" always continued from the road's far end** regardless of
  which end the user actually wanted to build onward from -
  `RoadEditSession.GetContinuation()` hardcoded `curve.Length`. Split into
  two pills on the selection pie menu: "Place More (End)" (the original
  behaviour, unchanged) and a new "Place More (Start)", which continues
  from station 0 instead - using the OPPOSITE of the curve's own tangent
  there, since the curve's forward tangent at its own start point points
  into the existing road, not away from it. `GetContinuation` now takes a
  `fromEnd: "Start" | "End"` parameter instead of always assuming the far
  end. `PieMenu.lua` gained a sixth slot (`TopRight`, at the +45 degree ring
  position the existing five-slot layout left open) to fit the new pill
  without restructuring the menu.

## Scoped in-plugin keybind capture to mouse buttons only, per user confirmation

- **User confirmed directly**: "PluginActions is the way to create keybinds
  for plugins... currently the register system for plugin does not work
  other than mouse click in the viewport." This settles what three earlier
  rounds (plus this session's `WindowFocused` attempt) circled around
  without fully landing on: Studio's own `PluginAction` + Customize
  Shortcuts is the correct, reliable mechanism for KEYBOARD rebinding - it
  doesn't route through `UserInputService` inside a plugin GUI at all,
  which is exactly why it's reliable where a custom capture listener here
  provably isn't (keyboard input just doesn't arrive, confirmed live).
  `main.lua`'s capture `InputBegan` listener is now explicitly filtered to
  the three mouse-button `UserInputType`s only, rather than accepting
  whatever `Keybinds.CaptureLabel` recognizes - it's the one input class
  this flow can actually capture reliably from inside the dock.
- **`KeybindsGui.lua` now tells the truth about which mechanism does what**:
  "+ Add mouse binding" (was "+ Add binding") for the live capture flow,
  plus a per-action note naming the exact `PluginAction` to search for in
  Studio's Customize Shortcuts for a keyboard shortcut - restoring the
  `ACTION_NAMES` reference table from the original read-only panel (dropped
  when this session first rebuilt the panel as fully live) instead of
  implying a single in-plugin flow covers both input classes.

## Found the actual palette-drop crash; fixed Keybinds Remove button overlap

- **The real reason drops never inserted anything** ("nah cant drop still" -
  this time with a Studio Output screenshot showing the exact error):
  `useLaneDrag` calls its insert callback as `onInsertAt(index, kind)`, but
  `Panel`'s own `insertKind(kind, atIndex)` takes the arguments in the
  opposite order (it's also called directly by the click-to-insert path as
  `insertKind(kind, nil)`, which is why that path never showed a problem).
  Passing `insertKind` straight through as the drag callback sent the tile
  index into the `kind` parameter and the kind string into `atIndex`,
  so every real drop crashed `math.clamp(atIndex, ...)` with "number
  expected, got string" - the drag itself (ghost tracking, hover
  detection) had been correct since the previous two rounds; nothing ever
  actually reached `table.insert` on a drop. Fixed by wrapping the callback
  passed to `useLaneDrag` to swap the arguments back into `insertKind`'s
  order, instead of changing either signature (both are used correctly by
  their own respective call sites otherwise).
- **Fixed the Keybinds "Remove" button rendering on top of its own label**
  instead of beside it (screenshot: overlapping red buttons, text
  unreadable). `Components.Button` only reads a fixed set of known props
  (`Text`/`Icon`/`OnClick`/`Selected`/`Danger`/`LayoutOrder`/`Size`/`Grow`)
  and builds its own `TextButton` prop table rather than spreading
  arbitrary props through - the previous round's `AnchorPoint`/`Position`
  passed to it to right-anchor the Remove button were silently no-ops, so
  both the label and the button defaulted to the same top-left corner.
  Switched `BindingRow` to `Components.Row` (the same horizontal
  `UIListLayout` flow every other button row in this UI already uses),
  which makes overlap impossible by construction instead of relying on
  manual positioning `Components.Button` doesn't actually support.

## Fixed the drag ghost blocking its own drop target; Keybinds as a proper list

- **Fixed "can drag now but can't drop"** - live-tested feedback on last
  round's UIListLayout fix, which did fix the ghost's cursor-tracking (drag
  now visibly follows the mouse) but exposed the actual remaining bug: the
  ghost is a `Frame` with `BackgroundTransparency = 0.2` (not fully
  transparent), and Roblox's mouse hit-testing treats that as opaque to
  input - so a ghost correctly centered exactly on the cursor sits directly
  on top of whatever tile the hover-tracking drop logic
  (`OnTileHoverChanged`) needs to detect, blocking its own drop target. This
  was very likely present through every earlier "fix" of this bug (tasks
  #19, #26, #36, #47, #91) too, just masked each time by some other visual
  breakage landing first. Fixed with an OS-cursor-style offset: the ghost
  now renders 14px down-right of the actual pointer position instead of
  centered on it, so the exact point Roblox hit-tests against is never
  covered by the ghost sprite itself.
- **Keybinds panel rebuilt as a real list**, not chips crammed onto one
  horizontal row. The live capture UI shipped last round packed a label,
  every binding as an inline chip, and an Add/Cancel button all onto a
  single `Components.Row` per action - fine with one short binding, but
  overflowed the docked panel's width the moment an action had 2+ longer
  bindings ("Right Click", "Middle Click" ran off the visible edge, per a
  live screenshot). Each action is now its own `Components.Section` group
  (matching this panel's existing divider convention) with one binding per
  row (label left, a "Remove" button right-anchored) and the Add/Cancel
  button on its own row underneath - same underlying capture logic
  (`main.lua`'s `WindowFocused`-gated two-phase listener), purely a layout
  fix.

## Fixed the real root cause of the recurring palette drag bug; live in-plugin keybind rebinding

- **Found the actual root cause of "Palette drag is broken again"** after
  five previous rounds (tasks #19, #26, #36, #47, #91) each rewrote the
  *input-tracking* mechanism (GuiService hit-testing, `plugin:GetMouse()` +
  `RenderStepped`, then `UserInputService`) without the breakage going away
  for good. The actual bug was never the input mechanism: `RoadDesigner.Panel`'s
  root `Frame` has a `UIListLayout` directly on it, and the cursor-following
  drag ghost (`Ghost`) was a sibling *under that same layout*. A
  `UIListLayout` unconditionally overrides its direct children's `Position`
  to lay them out in a column - so the instant a drag passed the pickup
  threshold and the ghost started rendering, the layout engine was fighting
  its manually-computed cursor-following `Position` every frame, snapping it
  into the list flow and shoving `Top`/`StripCard` down by the ghost's
  height. That reflow is what made the whole panel look "broken" while
  dragging (tiles jumping/misaligning under the cursor, drops missing)
  regardless of which input mechanism drove the drag underneath - explaining
  why rewriting the input tracking alone kept not fixing it. Fixed by moving
  `Layout`/`Top`/`StripCard` into an inner `Stack` frame and keeping `Ghost`
  as an unmanaged sibling of that `Stack`, so its explicit `Position` is
  finally respected.
- **Live in-plugin keybind rebinding**, replacing the read-only "go find
  Studio's own Customize Shortcuts dialog" panel from the `PluginAction`
  rework. Per the TODO's option B: capture is two-phase, gated on
  `UserInputService.WindowFocused` rather than the raw next keypress -
  clicking "+ Add" in the docked Keybinds panel only arms
  `capturingAction`; the actual `InputBegan` capture additionally requires
  `capturingReady`, which only flips true once `WindowFocused` fires (i.e.
  once the user has actually clicked/refocused into the 3D viewport). That
  first refocusing click is consumed as "becoming ready," not as the
  binding itself, so a plain click-to-refocus-then-press-a-key gesture
  can't accidentally bind `MouseButton1` by mistake. The listener pair
  lives in `main.lua`, connected once for the plugin's whole lifetime
  (independent of the Keybinds dock's own React mount/unmount), and is
  cancelled if the dock closes mid-capture. `KeybindsGui.lua` is now a live
  editable list (chips per binding with a small remove "x", always leaving
  at least one binding per action so it can't go fully unbound) instead of
  a static reference table; the Customize Shortcuts / `PluginAction` route
  from the previous round is untouched and still works as a fallback.
  **Not verified in a live Studio session** - this is exactly the kind of
  focus-handoff behaviour that's broken three times before on variations
  of "capture from inside the docked panel," so it's flagged rather than
  claimed working; if `WindowFocused` doesn't fire the way it's expected to
  in Studio's specific plugin-dock window model, capture will just hang
  waiting (Cancel button recovers cleanly) rather than silently misbinding.

## Fixed dashed-marking wobble on superelevated curves; stretches overwrite instead of stacking

- **Root-caused a real regression from this session's own roll-refinement
  work** (reported live, with a screenshot of visibly zigzagging dashes on
  a banked curve - "originally its ok, weird" after "the new patch").
  `RoadBuilder.Build`'s roll-based station refinement (inserting extra
  stations wherever the bank angle changes too fast between neighbours)
  was recomputing `Superelevation.SmoothRolls` from scratch on the new,
  denser-in-places grid. `SmoothRolls`'s box filter is a plain per-sample
  average, not arc-length-weighted, so it's implicitly biased toward
  whichever part of a smoothing window happens to have more samples -
  once refinement made station density jump sharply in some spots but not
  others, re-deriving the average on that uneven grid shifted
  non-smoothly as the window slid across the density boundary, producing
  small oscillations in the roll curve. Dashed markings sample `rollAt()`
  at arbitrary intermediate points (not anchored to stations, unlike solid
  lines and deck strips), so they visibly picked up on that now-non-smooth
  curve as a wobble along otherwise-straight dashes - solid lines and the
  deck barely showed it, matching exactly what was reported. Fixed by
  resampling (linearly interpolating) the coarse grid's *already-smoothed*
  roll curve at the new refinement stations instead of recomputing
  smoothing on the denser grid - mathematically consistent by
  construction (same curve, just more samples), so it can't introduce new
  oscillation.
- **Marking stretches now overwrite instead of stacking on genuine
  overlap.** The multi-stretch work shipped a few messages ago intentionally
  let a lane keep more than one stretch (e.g. solid near two separate
  junctions), but that meant dragging a *new* stretch over a section that
  already had one just layered both, fighting over the same physical
  markings - reported as "i want overwrite when i do it on existing
  section." `ConfirmMarkingStretch` now runs `applyStretchOverwrite`: for
  each existing stretch, only the boundaries it shares with the new one
  AND whose station range actually overlaps gets carved out (split into
  a "before" and/or "after" remainder, or dropped entirely if fully
  covered); boundaries the new stretch doesn't touch, or ranges that don't
  overlap at all, are left completely alone. Two stretches on different
  lanes, or two non-overlapping ranges on the same lane, still coexist -
  only genuine overlaps are resolved in the new stretch's favour.
- Not verified in a live Studio session (this environment can't render
  Studio).

## Ghost Parts now match the real road's superelevation tilt; stale-ghost sweep

Reported live: the marking-stretch ghost "sometimes shows, sometimes not"
specifically on curved sections, alongside a screenshot showing a dozen-plus
leftover `EasyRoadMarkingStretchGhost` Parts sitting loose in the Explorer.

- **Root cause of the intermittent ghost**: every ghost frame in
  `RoadEditSession.lua` (the stretch drag/select ghosts, the bus bay ghost)
  was built with a plain `curve:FrameAt(s)` - roll defaults to 0 with no
  second argument. `RoadBuilder.Build` computes the *real* road's frames
  with `Superelevation.RollAt(curve:CurvatureAt(s), settings, style)`, the
  actual bank angle for that station. On a real banked curve those two
  frames diverge - a flat, un-rolled ghost drifts away from the true
  (tilted) pavement surface, more so the sharper the bend, landing either
  floating above it or clipped inside it (invisible, since Parts don't
  render through other opaque Parts) depending on how much bank was in
  effect at that particular station. New shared `frameAtWithRoll(curve, s)`
  helper reproduces the exact same roll formula the real build uses;
  wired into both the marking-stretch ghosts and the bus bay ghost (same
  underlying bug, not previously reported for that one).
- **Stale ghost sweep**: rather than trying to prove every cleanup code
  path is airtight (the underlying leak in the screenshot was never
  conclusively root-caused - possibly debris from testing an earlier
  version, possibly a real remaining path), `RoadEditSession`'s setup now
  destroys any stray Part named `EasyRoadMarkingStretchGhost` or
  `EasyRoadBayGhost` already sitting under `workspace` once, at plugin
  load - cheap, and can't touch anything else since it matches ghost Parts'
  exact, distinctive names. Existing leaked ghosts in an already-open file
  clear the moment the plugin reloads.
- Not verified in a live Studio session (this environment can't render
  Studio) - the roll-frame fix in particular is a strong, well-reasoned
  hypothesis (matches the reported symptom's shape - "curved sections"
  specifically), not something confirmed against an actual banked curve.

## Marking stretch v2: multiple stretches per boundary, All/Individual/Select modes, curve-following ghosts, decoupled "Edit Lane Markings"

Four related fixes/requests landed together since they all touch the same
drag/ghost machinery:

- **A boundary can now carry more than one stretch.** `ConfirmMarkingStretch`
  used to replace any existing stretch on the same boundary before adding
  the new one - dragging a second stretch onto the same lane pair (e.g.
  solid approaching two separate junctions) silently deleted the first.
  `MarkingStretch.ComponentIndex: number` became `ComponentIndices:
  {number}` (touches `Markings.lua`, `RoadBuilder.lua`'s `BuildWithBay`
  slice remap, and `RoadInstance.lua`'s JSON stamp/read), and
  `Markings.Compute`'s `stretchByBoundary` is now keyed to a *list* per
  boundary - `emitBoundaryLine` sorts every stretch on a boundary by
  station and splices in "before/stretch/between/stretch/.../after" pieces
  instead of just "before/stretch/after". `ConfirmMarkingStretch` now
  always appends.
- **All / Individual / Select boundary-selection modes**, exposed as a new
  bottom "pod" (`UI/MarkingSelectionModePod.lua`, shown only while
  `PlacingMarkingStretch`) - the plain click-drag interaction now branches
  on `RoadEditSession`'s `stretchSelectionMode`:
  - **All** (previous/default behaviour): the whole same-direction sibling
    run.
  - **Individual**: just the clicked boundary.
  - **Select**: click boundaries one at a time (a plain click, not a drag,
    toggles membership - shown as a persistent amber highlight spanning the
    whole road) to build an arbitrary set, then drag any point to set the
    range for that set - falls back to "just the dragged boundary" if
    nothing was toggled first, so a plain click-drag with no prior toggles
    behaves like Individual. `resolvePreviewIndices` is the single function
    both the live ghost preview and the final committed `stretchDraft` call,
    so they can't disagree. Mode persists across separate stretch
    placements on the same road; the pending Select toggle set does not
    (cleared on cancel/confirm/mode-switch).
- **Ghost previews now follow the curve** instead of being one straight
  chord directly connecting their two endpoints (visibly cut corners on an
  actual curve - reported live, with a screenshot showing the chord slicing
  across a bend). `buildGhostStrips` (shared by both the active-drag range
  preview and the persistent Select-mode highlight) subdivides into up to 8
  straight facets scaled to the drag length, rather than 1 - a deliberate
  accuracy/performance tradeoff since these are ephemeral preview Parts
  redrawn on every mouse-move, not committed geometry (which already uses
  proper adaptive/exact station-following elsewhere in `RoadBuilder.lua`).
- **"Edit Lane Markings" no longer opens the full Designer.** It used to be
  identical to "Edit on Road Builder" (literally the same `OpenEditor()`
  call) - reported as confusing now that a stretch is a road-local, spatial
  edit rather than a whole-profile one. New `ViewingStretches` mode (own
  pie menu: just "Back") shows a dedicated `UI/MarkingStretchListPanel.lua`
  instead - the same per-stretch Remove-button list already added to the
  Designer's own Road Properties card, just without forcing a detour
  through the full cross-section editor to see it. The Designer's own
  section stays too (harmless extra context if you go there for other
  reasons) rather than ripping out already-working code for this.
- The `PlacingMarkingStretch` bottom pod required the same
  `skipGenericHover` treatment the placement session's ToolMode/RoadLibrary
  panels already use: its wrapper Frame spans the whole screen (so the pod
  can self-position bottom-center), which would otherwise latch
  `uiState.Hovered` permanently on any viewport hover at all - the exact
  hover-trap bug fixed earlier this session, now guarded against
  proactively for this new surface via an `OnHoverChanged` prop instead.
- Not verified in a live Studio session (this environment can't render
  Studio) - flagging the Select-mode toggle interaction in particular,
  since distinguishing "a click" from "a drag" by distance threshold is the
  kind of thing that's easy to get subtly wrong without hands-on testing.

## Fixed a leaked ghost Part; "Edit Lane Markings" now manages existing stretches

- **Fixed a stray `EasyRoadMarkingStretchGhost`/bay-ghost Part left behind
  in the workspace.** Reported live: an orphaned ghost sitting loose in the
  Explorer with nothing placing it. Root cause: the top-level "Road Editor"
  tab and starting a new placement session (`main.lua`'s `openEditor`/
  `startSession`) only ever reset `session`/`designProfile` and called
  `plugin:Deactivate()` - neither touches `RoadEditSession`'s own internal
  state at all. If a bay or marking-stretch drag was active on a selected
  road when either was clicked, `plugin:Deactivate()` stopped the tool from
  outside, but `editSession`'s own `mode` stayed `"PlacingBay"`/
  `"PlacingMarkingStretch"` forever, its mouse connections were never
  disconnected, and any ghost Parts it had created were never destroyed -
  `RoadEditSession.lua` only ever cleans that state up from *inside* itself
  (`Selection.SelectionChanged`, its own Cancel/Apply paths), none of which
  fire when a completely different part of the UI switches the whole
  plugin's top-level mode out from under it. Fixed by having both
  `openEditor` and `startSession` unconditionally call
  `editSession.CancelBayPlacement()` / `CancelMarkingStretchPlacement()`
  first (both are no-ops if no such drag is in progress).
- **"Edit Lane Markings" now lists a placed road's active marking
  stretches for management**, not just the same generic designer "Edit on
  Road Builder" already opens. Asked which direction to take this in first
  (surface stretches for management vs. retire the redundant pill vs.
  something else) since it changes the designer's shared layout either
  way - user picked management. `RoadDesigner.Panel` gains optional
  `MarkingStretches`/`OnRemoveMarkingStretch` props (only ever populated by
  `RoadInspector`, which has a real `editSession` behind it - the
  standalone road-*type* editor has no concept of a specific placed road's
  station-based stretches, so the section is simply absent there). Each
  stretch renders as a `From-To studs (Line type)` row with its own Remove
  button, backed by a new `RoadEditSession.RemoveMarkingStretch(index)` -
  this also closes the "removal is all-or-nothing" v1 limitation logged
  earlier (`ClearMarkingStretches`, the bulk version, stays for clearing
  everything at once).
- Not verified in a live Studio session (this environment can't render
  Studio).

## Marking "stretch" - drag a lane boundary's marking to a different type over part of the road

The last piece of the original "Edit Road Segment" ask that was deliberately
scoped out earlier (see the old `TODO.md` entry, now removed). Two design
questions were asked up front rather than guessed at, since they'd change
the interaction entirely: (1) should parallel same-direction lane boundaries
move together when you drag one - yes, and (2) should the dragged range be
anchored to a segment end, or free-form on both ends - free-form. Shipped
matching both answers:

- **New pie-menu flow**: "Edit Road Segment" gained a **Stretch Marking**
  pill (`Right` slot) alongside Add Bus Bay/Edit Lane Markings. Click a
  same-direction lane boundary line, then drag along the road (either
  direction, from anywhere to anywhere - not anchored to either end); a
  confirm panel (`UI/MarkingStretchPanel.lua`) lets you fine-tune the
  From/To stations (studs) and pick the override line type (Solid, Double
  Solid, Dashed, Double Dashed, Solid/Dash, Dash/Solid) before an "Apply
  Stretch" pill on the pie menu commits it. A **Clear Marking Stretches**
  pill appears on the segment menu once any exist (bulk-remove only - see
  `TODO.md` for the deferred per-stretch removal).
- **Sibling resolution lives in `Mesh/Markings.lua`**, the module that
  already owns the "is this a same-direction Drive/Drive boundary" rule: a
  new pre-pass groups every such boundary into contiguous same-direction
  runs (a run breaks on a direction change or a non-Drive component), so a
  `MarkingStretch` naming any one boundary in a run (`ComponentIndex`)
  expands to every member of that run automatically - dragging one lane's
  line stretches every parallel same-direction lane's line with it, matching
  how a real multi-lane "no lane changing" zone before a junction reads. A
  separate run elsewhere in the cross-section (e.g. the opposing
  carriageway on a divided road) is untouched.
- **Station-range clipping added to `MarkingLine`** (`FromStationStuds`/
  `ToStationStuds`, nil = whole segment as before): `Markings.Compute`
  splices a stretched boundary into up to three line entries (before/
  override/after) sharing the same lateral-offset function but different
  ranges; `RoadBuilder.Build`'s `renderSolid`/`renderDashed` clip their
  per-station loop to `[loS, hiS]`. Adjacent spliced ranges share an exact
  station endpoint (both compute the same `curve:FrameAt(s, roll)`), so
  there's no gap or overlap at the splice, and `renderDashed`'s dash phase
  is computed from the whole segment's start regardless of range, so a
  dashed line resuming after a solid stretch continues its rhythm instead
  of restarting.
- **Data model**: `RoadInstance.RoadData.MarkingStretches` (a list, not a
  single optional like `Bay` - a road can have independent stretches on
  each direction), stamped/read via a new `RW_MarkingStretchesJson`
  attribute, same pattern as `StampBay`/`bayFromModel`. Threaded through
  `RoadBuilder.BuildOptions.MarkingStretches` into `Markings.Compute`, and
  through `BuildWithBay`'s three curve-slice `Build` calls with a
  `stretchesForSlice` remap (each slice is its own `PolyCurve` with station
  0 at the slice's own start per `PolyCurve.Slice`, so stretch stations get
  offset and clipped per slice, dropping anything outside it entirely).
- **Drag interaction reuses the bay's established click-drag-via-
  `plugin:GetMouse()` convention** (`RoadEditSession`'s new
  `PlacingMarkingStretch`/`ConfirmingMarkingStretch` modes): mouse-down
  resolves the clicked lane boundary by projecting the hit point onto the
  road's `RightVector` at the clicked station and picking the nearest
  same-direction boundary; mouse-move updates a live ghost preview; mouse-up
  finalizes the free-form `[min, max]` station range.
  `rebuildWithMarkingStretches` factors the "swap children, re-stamp,
  re-render bus stops" rebuild-in-place sequence shared by
  `ConfirmMarkingStretch`/`ClearMarkingStretches` (Apply/ConfirmBay keep
  their own copies, unchanged, to avoid touching already-working code for
  this).
- **Fast-follow: ghost preview shows every sibling, not just the clicked
  line.** The first cut only drew a single ghost strip at the clicked
  boundary while dragging - the committed geometry was already correct for
  every sibling in the run, but the preview didn't show that, so on a
  multi-lane carriageway it looked like only one lane's marking would
  change (user feedback: "it should be 2 dashes right"). Fixed by exporting
  `Markings.SiblingBoundaries(components, componentIndex)` - the same
  run-resolution `Compute` already used internally, now a shared function
  instead of a private pre-pass - and having `RoadEditSession`'s
  `updateStretchGhost` draw one strip per sibling boundary, rebuilt fresh
  each drag-move. `resolveComponentIndexFromHit` (deciding which boundary a
  click landed on) was also switched to the same exported helper instead of
  its own inline copy of the same-direction check, so there's one source of
  truth for "is this boundary a valid stretch target" across preview,
  click-resolution, and the real build.
- **Known v1 limitations, deliberately accepted rather than solved now**
  (all logged in `TODO.md` under "Marking stretch v1 follow-ups"):
  removal is all-or-nothing (no per-stretch delete), `ComponentIndex`-keyed
  storage isn't stable across a structural cross-section edit (add/remove/
  reorder lanes) in the designer, and a road with a transition AND a bay
  AND a stretch all at once can misalign the index between the bay
  builder's matched vs. unmatched component lists.
- Not verified in a live Studio session (this environment can't render
  Studio) - this is the largest single feature built this session without
  in-engine testing, worth a careful look before relying on it.

## Curved bay chord gap, fewer bay wedges, superelevation twist smoothing, colour picker z-order

- **Fixed a curve gap on bus bays.** `RoadBuilder.BuildWithBay`'s dwell
  rectangle and both tapers were each a single flat/straight `Part` (or one
  `FillTriangle` triangle) spanning only the 2-4 stations bounding the
  dwell/tapers - a straight chord. On a curved road the base road's own
  edge at that same nominal offset (built by the normal `Build` call,
  which follows the true curve with fine adaptive stations) bows away from
  that chord, leaving exactly the sliver gap in the user's screenshot.
  Rewrote the bay's own asphalt (dwell + both tapers) as one adaptive-
  station chain sharing the same `bayAlphaAt` ramp the nearside pavement
  shift already used, so its inner/outer edges sit on the true curve at
  every station, closing the gap exactly.
- **Cut bay wedge-part count back down.** The fix above initially reused
  the nearside pavement loop's `math.min(settings.MaxSegmentLengthStuds,
  4, ...)` step cap, but that cap exists to keep the main widen/narrow
  loop's *smoothstepped* taper reading smooth - the bay's own ramp
  (`bayAlphaAt`) is plain linear, so `FillTriangle` is already exact for
  any interval size; the only thing that should drive subdivision here is
  curvature (for curve-following), not width-change rate. Dropped the cap
  down to just `settings.MaxSegmentLengthStuds` for both the bay asphalt
  and nearside-pavement loops, so a straight or gently-curved bay collapses
  back to the same 1-2 wedge parts it used before this round's curve fix,
  and only a genuinely sharp curve subdivides further.
- **Superelevation transitions now subdivide by bank-angle change, not just
  curvature, AND use exact-corner wedges instead of averaged flat boxes.**
  Two-part fix:
  - `buildStations` only ever sized steps off lateral curvature - it had
    no idea the bank angle (roll) can change quickly across a span the
    curve itself considers straight enough for one long strip: the
    deliberate ramp-to-zero-bank at both ends of every segment, and
    `SmoothRolls`' box filter smearing bank in from a nearby curve onto an
    adjoining flat run. Added a refinement pass in `RoadBuilder.Build`:
    after computing the curvature-only station grid and its rolls, walk
    consecutive rolls and insert extra stations (capped at 8 per interval)
    wherever the bank-angle step between them exceeds `MAX_ROLL_PER_STEP`
    (0.02 rad), then recompute rolls once over the final, denser grid -
    same mitigation curvature already gets via `MAX_TURN_PER_STEP`, just
    driven by roll instead.
  - The main deck-strip loop's non-transitioning ("flat box") branch was
    still using a single *averaged* roll (`(rolls[i] + rolls[i+1]) / 2`)
    for the whole strip whenever offset/width didn't change - exact
    nowhere, and visibly kinks against a neighbour strip that averaged a
    different pair. The FillTriangle branch right next to it, used for
    lateral (offset/width) transitions, was *already* roll-correct by
    construction - it builds its 4 corners from `frames[i]`/`frames[i+1]`,
    which already carry each station's own true roll. So the same branch
    now also triggers on a meaningful per-strip roll change
    (`ROLL_WEDGE_EPSILON`, 1e-4 rad), even with no lateral change, giving
    every strip exact-roll corners instead of an averaged tilt. A
    continuously twisting deck between two different rolls is still a
    non-planar ruled surface, so this isn't a mathematically exact curved
    surface (no flat wedge can be, unlike the lateral case, which really
    is a flat quad) - but anchoring every strip's corners to the true
    per-station roll means adjacent strips always share an exact edge with
    no gap, same as the lateral case, and the residual twist is a small
    facet instead of an averaging error. Since a constant-radius curve's
    roll stabilizes to the same value station-to-station once past the
    entry/exit runoff, this only adds wedges in the actual transition
    zones, not along the whole curve.
- **Fixed the colour picker's SV square rendering wrong colours** (bottom
  of the square wasn't reaching true black, read as a washed-out
  olive/grey instead). `Components.ColorField`'s `SVSquare` stacks two
  alpha-blended overlay `Frame`s (white for saturation, black for value)
  over a pure-hue background with no explicit `ZIndex` - their table keys
  are plain Lua hash keys, so paint order (and therefore which overlay
  wins where they overlap) wasn't guaranteed by write order in the
  constructor. Alpha-compositing two overlays isn't order-independent
  (white-then-black composites differently than black-then-white at the
  same point), and the black (value) layer must win at low-value pixels
  for them to read as true black regardless of saturation. Pinned explicit
  `ZIndex` (Saturation = 1, Value = 2, Cursor = 3) so the stacking order is
  deterministic.
- Not verified in a live Studio session (this environment can't render
  Studio) - flagging the superelevation fix in particular for a live check
  since the roll-subdivision threshold (`MAX_ROLL_PER_STEP`) was chosen by
  reasoning about typical max-superelevation magnitudes (~0.06-0.08 ratio,
  so ~4.5° peak bank), not measured against an actual rendered curve.

## True "no kerb line" option, CanTouch perf win

- **Added a genuine "no kerb line at all" option.** `RoadProfile
  .KerbRestriction = "None"` ("No restriction" in the dropdown) turned out
  to still draw a plain white edge line at every kerb boundary -
  `Mesh/Markings.lua` only ever skipped the *yellow* restriction line, and
  always fell back to `style.EdgeLine` whenever there wasn't one, so there
  was actually no way to have zero markings at a kerb. Added a new
  `KerbRestriction = "NoLine"` value ("No line at all" in
  `UI/ProfileFields.lua`'s Kerb Lines dropdown) that suppresses both,
  scoped to genuine kerb boundaries specifically (a non-kerb roadway edge,
  e.g. a median, keeps its plain edge line regardless - that's a separate
  concept from a road's kerb restriction).
- **Disabled `CanTouch` on every generated road Part, real and preview**
  (previously preview-only) - confirmed via a full-codebase grep that
  nothing anywhere listens for `.Touched`, so this is a free perf win with
  zero functional risk. Also applied to `BusStops.lua`'s marker parts,
  where it's paired with a now-safe `CanQuery = false` too, since the only
  code that ever raycast against a bus stop marker (`onBusStopClick`,
  add/remove-by-click) was removed earlier this round.
  - **`CanQuery` was NOT disabled on real (non-preview) road Parts**,
    despite the user's original ask covering both flags - investigating
    first (per the standing caution already logged) found two genuine
    dependencies: `createRoadSession.lua`'s ground raycast needs to detect
    an *existing* placed road as "ground" (continuing a road across
    another's surface, or just finding height under the cursor while
    hovering one), and `RoadEditSession.lua`'s bus bay drag positioning
    needs `mouse.Hit` to actually land on the selected road's own surface.
    `CanQuery = false` would make roads invisible to both. Scoped down to
    just the confirmed-safe `CanTouch` win rather than risk breaking
    either of those to chase the full claimed perf number.
- Not verified in a live Studio session (this environment can't render
  Studio).

## Diagonal-strip seams closed exactly with FillTriangle, not padded

- **Replaced the flat `WEDGE_WIDTH_PAD` width margin with an exact fix**,
  per the plan scoped after the padding attempt didn't fully close the
  gaps a user confirmed with a follow-up screenshot. The true shape
  between two stations of a transitioning (offset- and/or width-changing)
  strip is a quadrilateral whose two "width" edges generally aren't
  parallel - no single rigid `Part` can represent that exactly, so no
  amount of padding a rotated-rectangle approximation was ever going to
  fully close it. Both `RoadBuilder.Build`'s main transition loop and
  `BuildWithBay`'s pavement-shift overlay now split that true quad into
  two triangles (along the innerStart-outerEnd diagonal) and fill each
  exactly with `Mesh/FillTriangle.lua` - the same exact-fill helper the
  bay's own pull-in-lane taper already used. Adjacent intervals share
  their exact corner positions by construction (both computed from the
  same per-station offset/width data), so there's no gap or overlap
  regardless of how sharply the offset or width changes station to
  station - not an approximation tuned to look acceptable, but the exact
  shape. `WEDGE_WIDTH_PAD` is removed entirely, now dead code.
- **Confirmed fixed live** - user re-tested against the same
  exaggerated-size bay used to catch the padding attempt's residual gaps
  and confirmed the seams are closed.

## Gaps at diagonal-strip seams (the "wedge, not blocks" fix's own residual gap)

- **Fixed sliver gaps at the seams between diagonally-oriented strips**,
  visible on an exaggerated-size bay a user built specifically to make the
  defect easier to see. Each transitioning strip is rotated to follow its
  own local slope (see the earlier "wedge, not blocks" round in
  `SHIPPED.md`), but the slope keeps changing along a taper - consecutive
  strips' width-direction edges are perpendicular to slightly different
  angles even though their centerline endpoints connect exactly, fanning
  apart a little at every seam. Added a flat `WEDGE_WIDTH_PAD` (0.15 studs)
  to diagonally-oriented strips' width, same "flat safety margin" approach
  already used for the existing length padding - applies to both the
  general `RoadBuilder.Build` transition loop and `BuildWithBay`'s
  pavement-shift overlay.
- Not verified in a live Studio session (this environment can't render
  Studio) - a flat pad should cover the normal case (adaptive station
  stepping already bounds the per-interval angle change), but an
  extremely exaggerated taper might still show a hairline residual gap.

## Bay ghost preview no longer hidden behind the road's own sidewalk

- **Fixed the bay drag ghost rendering underneath (and getting visually
  hidden by) the road's own sidewalk.** It was positioned a flat 0.1 studs
  above the frame's base level - fine for a flat drive lane, but raised
  components (sidewalk/median) sit `curbHeight` above that, and regions
  with any real curb height had the ghost sitting *below* the opaque
  sidewalk surface, which then visually occluded it wherever they
  overlapped. Since `RoadBuilder.Build`'s raised-component math places a
  sidewalk's top surface at exactly `curbHeight` above the frame (not an
  approximation - `centerY + partHeight/2` reduces to exactly that), the
  ghost now sits at `style.CurbHeightM * scale + 0.15` instead of a flat
  `0.1`, guaranteed above every part of the road regardless of the
  region's curb height.
- Not verified in a live Studio session (this environment can't render
  Studio).

## Keybinds rebuilt on PluginAction - the real fix, not another patch

- **Replaced the custom "click + Add binding, press a key" capture UI with
  Roblox's native `plugin:CreatePluginAction`.** Three rounds of patches to
  the old capture mechanism (removing a stray `gameProcessed` check, then
  gating mouse clicks on panel hover) never fully fixed rebinding, because
  the root cause isn't fixable from inside a docked panel's own script at
  all: `UserInputService` is scoped to the main 3D viewport, and a
  `DockWidgetPluginGui` is a genuinely separate native window - once it has
  focus, further input (keyboard especially) doesn't reliably reach
  `UserInputService`. This is a documented Roblox Studio platform
  limitation (confirmed via several devforum threads), not a bug specific
  to this codebase.
  - `main.lua` now registers three `PluginAction`s (Raise/Lower Elevation,
    Cancel Placement) once at startup. Their `.Triggered` events route
    directly into whichever session is active (`session.AdjustElevation`/
    `session.CancelPlacement`, or `editSession.CancelBayPlacement` while
    placing/confirming a bay) - Studio's own native "Customize Shortcuts"
    dialog (right-click any toolbar, or File > Advanced > Customize
    Shortcuts) is what assigns the actual key, and that dialog isn't built
    on `UserInputService`, so it doesn't have this focus problem.
  - The hardcoded R/F/Escape/middle-click defaults in
    `createRoadSession.lua`/`RoadEditSession.lua`'s own live listeners are
    untouched and still work with zero setup for everyone - they were never
    actually broken (they only matter while the 3D viewport itself has
    focus, during active placement, which was always a UserInputService-
    friendly context). The PluginActions are purely an *additional* way to
    trigger the same three actions, via whatever key the user assigns.
  - `UI/KeybindsGui.lua` is now a read-only reference (the three defaults,
    plus the exact `PluginAction` names to search for in Customize
    Shortcuts) instead of an interactive capture UI - there's no more
    capture code left in a docked panel at all, so this bug class can't
    recur here again.
- Not verified in a live Studio session (this environment can't render
  Studio) - `CreatePluginAction`'s exact signature/behavior was confirmed
  against Roblox's own Creator Hub documentation, but the end-to-end flow
  (Customize Shortcuts actually finding and letting you bind these three
  actions) hasn't been checked hands-on.

## Pie-menu hover-trap breaking bay drag entirely

- **Fixed the bus bay drag being completely unusable** ("i simply cant draw
  the area"). Root cause: every pie-menu mode (Menu/SegmentMenu/PlacingBay/
  ConfirmingBay) swaps in a totally different set of `PillButton`s at the
  same world anchor. Clicking "Add Bus Bay" fires its `OnClick`, which
  switches the mode and re-renders the pie menu with a *different* set of
  pills - the "Add Bus Bay" pill itself unmounts immediately while the
  mouse is still sitting on it, and React destroying a hovered element
  never fires its own `MouseLeave`. `uiState.Hovered` (set by that pill's
  `MouseEnter`) got stuck `true` forever after, and `onBayDragBegin`'s
  "don't place through the HUD" guard silently blocked every subsequent
  viewport click - the third occurrence of this hover-trap class of bug in
  this codebase (see `KNOWN_ISSUES.md`). Fixed by resetting
  `uiState.Hovered` whenever the pie menu's rendered mode actually changes
  between renders, tracked via a `lastPieMenuMode` value in `main.lua`.
- Not verified in a live Studio session (this environment can't render
  Studio) - flagged as high-confidence given the mechanism is fully
  traceable in the code, unlike some other unverified entries.

## Bay side-of-drag, wedge-not-block tapers, keybind capture fix

- **Fixed the bus bay always appearing on the region's default driving
  side, ignoring which side the user actually dragged toward.**
  `BuildWithBay`/the drag ghost derived their "nearside" purely from
  `style.DriveOnLeft`, never from the drag itself - a user screenshot
  showed the bay rendering on the opposite side from where they dragged.
  `RoadInstance.BayData`/`RoadBuilder.BayPlacement`/`RoadEditSession.BayDraft`
  all gained a `Side: "Left" | "Right"` field, computed from the *signed*
  lateral component of the drag (`(currentHit - startHit):Dot(frame.RightVector)`)
  instead of the region setting - a bay can go on either side of a road
  regardless of which side traffic drives on.
- **Replaced axis-aligned staircase strips with diagonally-oriented ones**
  wherever a strip's offset shifts between two stations (an ordinary
  widen/narrow transition, or the bay's displaced-pavement overlay) - a
  user screenshot showed a visible staircase on the bay's shifted sidewalk.
  Previously every strip was built flat-and-square to the curve tangent,
  holding a constant offset for its whole length before the next strip
  stepped to a new one; now, whenever a component's center offset differs
  between its two stations, the strip is oriented via `CFrame.lookAt`
  between its own true endpoint positions instead - not a mathematically
  exact trapezoid (a `Part` still can't taper along its own length), but
  angled to follow the true taper rather than holding flat until a sudden
  step, which fine adaptive stepping should now read as smooth. Applies to
  both the general `RoadBuilder.Build` transition loop and `BuildWithBay`'s
  pavement-shift overlay; completely unaffected for the ordinary
  non-transitioning case (same construction as before when a component's
  offset doesn't change).
- **Fixed the Keybinds capture listener treating a click on its own Close
  button as the captured input.** `UserInputService.InputBegan` fires on
  mouse-*down*, before a clicked button's own `Activated` (mouse-*up*)
  runs - so clicking Close while a capture was pending had that same
  click's mouse-down captured and bound as "MouseButton1" a moment before
  Close's own effect (closing the dock) fired, which is what a user's "it
  detects my left click after i press close" report was describing.
  `KeybindsGui` now reports its own hover state up (`OnHoverChanged`,
  mirroring the `uiState.Hovered` pattern already used for the 3D viewport
  HUD), and `captureNextKeybind` ignores mouse-button input (but not
  keyboard keys, which have no such ambiguity) while the pointer is over
  the panel's own buttons.
- Not verified in a live Studio session (this environment can't render
  Studio).

## Bus bay overlap, drag reliability, bus stop consolidation

- **Fixed the bus bay overlapping the nearside pavement.** `BuildWithBay`
  previously overlaid the bay's asphalt outward of the kerb but never
  moved the sidewalk, which the base build still rendered at its original
  (raised) position - the two occupied the same footprint, so the raised
  sidewalk visibly floated above/through the new low bay asphalt.
  `RoadBuilder.Build` gained `ExcludeComponentIndices` (skips deck-strip
  Parts for specific component indices without touching anything else);
  `BuildWithBay` now builds the road in three pieces (normal / bay-
  affected with the nearside component excluded / normal) and overlays a
  new chain of small strips for the displaced pavement, its inner edge
  following the exact same straight-line ramp as the bay's own
  `FillTriangle` taper edge - the two boundaries are the same line by
  construction, so there's no gap and no overlap. See `KNOWN_ISSUES.md`
  for a remaining gap (kerb-restriction line markings don't follow the
  bulge yet).
- **Fixed bay drag placement registering unreliably** ("sometimes it just
  doesn't do anything"). `onBayDragBegin` required `mouse.Target` to land
  on the road itself to start the drag, but `onBayDragMove`/`onBayDragEnd`
  never had that requirement - a drag that started a pixel off the road's
  edge (baseplate showing through a thin gap, a grazing camera angle)
  silently failed to register at all, with no ghost, no feedback, nothing.
  Removed the requirement; the drag now always registers off
  `ClosestS(mouse.Hit.Position)` regardless of what was actually hit,
  matching how the rest of the gesture already worked.
- **Removed the standalone "Add Bus Stop" marker feature.** Per user
  feedback, a real bus bay already serves as a stop, so a separate
  marker-only mode was redundant. Removed the button, `PlacingBusStop`
  mode, and its click handler from `RoadEditSession`/`main.lua`; kept
  `BusStops.Render` in the Apply/ConfirmBay rebuild paths so any markers
  placed before this change keep rendering correctly - no data loss for
  existing roads, just no way to add new ones.
- **Hid "Add Bus Bay" for Highway-category roads** - real highways don't
  have bus bays, per user feedback ("not up to code").
- Not verified in a live Studio session (this environment can't render
  Studio) - the bay/pavement geometry fix in particular is substantial new
  slicing logic and warrants real testing.

## Icon-based category tabs

- **Category tabs (Streets/Avenues/Highways/Paths/Custom) are now live 3D
  icons instead of text**, fixing the truncation the user's screenshot
  showed ("Aven...", "Highw...", "Custo..."). New `Mesh/CategoryThumbnail.lua`
  reuses `ProfileThumbnail`'s existing 3/4 top-down camera technique against
  a fixed representative built-in profile per category (there's no single
  "shape" for a category itself) - Streets from the two-lane street, Avenues
  from the boulevard, Paths from the pedestrian path, Custom from the same
  generic template `main.lua`'s "+ New" starts from (no built-in exists for
  a user-only category). Highways additionally get a simple two-post
  overhead gantry overlay purely for the icon - EasyRoad has no real
  gantry/sign-structure feature to build from, so this is decorative only.
  `ProfileThumbnail.Build`'s camera-framing math is now exposed separately
  (`FrameCamera`) so the gantry overlay can re-frame after adding its own
  geometry instead of duplicating that math.
- A generated roundabout icon was part of the same request but deliberately
  **not** built this round - roundabouts aren't an implemented feature and
  there's no UI slot that would use a roundabout icon yet, so it would be
  orphaned geometry with no consumer. Left as a `TODO.md` note instead.
- Not verified in a live Studio session (this environment can't render
  Studio).

## Road Tools left-aligned, Road Library grid

- **Tool Mode is now left-aligned with padding** instead of sitting bottom-
  center as half of a shared wrapper - Studio has much less usable screen
  width than a dedicated game window, so CS2's own bottom-center layout
  doesn't translate directly (queued user feedback from a prior round).
  Road Library moved to be independently bottom-right-anchored (same 16px/
  12px padding) rather than positioned relative to Tool Mode, so the two
  panels no longer share one sized wrapper - each is now anchored straight
  to the screen. (Hover-tracking already lived on each panel individually
  after this round's placement-bug fix, so decoupling their positioning
  didn't reintroduce the hover-trap bug.)
- **Road Library tiles are now a real wrapping grid** (`UIGridLayout`,
  auto-column-count, vertical scroll for more rows), not a single
  horizontal scrolling strip - closer to CS2's own library grid.

## Fixed road placement, centerline-anchored curves, trapezoid bay, drag-to-draw bay

- **Critical: road placement was completely broken by last round's two-panel
  split.** `bottomFrameProps` for the Road Tools HUD wraps both new panels
  in one shared 612x430 box, and the generic hover-tracking `MouseEnter`/
  `MouseLeave` handlers were attached to that *whole* box - but the two
  actual panels only fill small corners of it (Road Library is 170px tall
  inside a 430px-tall column), leaving a large transparent dead zone in the
  lower-center of the screen that still counted as "hovering the HUD". That
  dead zone sits right where placement clicks land, so `uiState.Hovered`
  stayed `true` and `createRoadSession.onClick`'s "don't place through the
  HUD" guard silently swallowed essentially every placement click - the
  same class of bug as the earlier pie-menu full-screen hover trap, just
  reintroduced in a new spot. Fixed by tracking hover on the two inner
  panels (`ToolMode`/`RoadLibrary` frames) independently and OR-ing them
  into `uiState.Hovered`, instead of on their shared outer wrapper.
- **Reverted curve deck strips to centerline-anchored, removed
  `Settings.CurveAlignment` (Center/Inside/Outside) entirely.** The
  Inside/Outside anchored-edge construction (built two rounds ago) anchored
  one edge of each strip exactly to the curve while approximating the
  other - which turned out to be the actual cause of a reported "drift"
  where the road's visual centerline wandered off the originally-clicked
  path on sustained curves, since only one edge (never the centerline)
  tracked the true path. Combined with continuing wedge artifacts and holes
  under that scheme, reverted entirely rather than patched further: every
  deck strip is now always centered on the curve's true midpoint frame for
  its own interval (`curve:FrameAt(sMid, rollMid)`), both edges padded via
  the existing `curveMiterPad` formula. This can't drift, by construction -
  the strip's center is always an exact point on the curve. Also removed
  `WEDGE_GAP_THRESHOLD_STUDS` and the conditional wedge-fill path that went
  with the anchored-edge scheme.
- **Bus bay is now an actual trapezoid**, not a taper built from the general
  widen/narrow staircase-of-rectangles machinery. `RoadBuilder.BuildWithBay`
  no longer slices the curve into 5 sub-builds and threads a `Bay` profile
  component through the transition system (removed `RoadProfile.WithBay`
  entirely) - it now builds the base road normally with one plain `Build()`
  call, then overlays the bay as its own exact geometry: a flat rectangular
  "dwell" section at full bay width, plus one `FillTriangle` call at each
  end for the taper. Each taper is provably a single triangle, not a full
  quadrilateral - the narrow end of any taper has zero width by definition,
  so there's exactly one "pinch point", fillable exactly instead of
  approximated.
- **Bay placement is click-and-drag, not click-then-type.** Previously,
  clicking a single point on the road immediately committed a
  default-sized bay, with no way to see or adjust it before it existed.
  Now `RoadEditSession` tracks a `Button1Down` → `Move` → `Button1Up` drag:
  a live translucent ghost part shows the bay's footprint (length along the
  road, width from the kerb) while dragging, sized/positioned exactly like
  `BuildWithBay`'s own geometry, and releasing the drag hands off to the
  existing length/width fine-tune panel (`BayDraftPanel.lua`) before
  Add Bay commits it - matching how the user actually wants to draw a real
  bay's footprint by hand.
- Not verified in a live Studio session (this environment can't render
  Studio) - all four changes above are logic/geometry fixes that need real
  in-Studio testing, especially the placement-click fix given how critical
  it is.

## Two separate CS2-style boxes: Tool Mode + Road Library

- **Split into two independent floating panels side by side**, not one
  panel with everything stacked inside it - a screenshot from the user
  showed the CS2 reference is genuinely two separate boxes (Tool Mode on
  the left, Road Library on the right), which an earlier same-round attempt
  (one wider bar with an internal "Road Library" section) still didn't
  match. `BuildBar.lua` is now Tool Mode only (drawing mode, widen-to,
  banking, elevation, hint, stop button); the road picker moved to a new
  `UI/RoadLibraryPanel.lua`, rendered as its own bottom-right-anchored
  panel next to Tool Mode's bottom-left one.
- **`RoadLibraryPanel.lua`: Streets / Avenues / Highways / Paths / Custom
  category tabs above a horizontal strip of road tiles** (thumbnail over a
  small label, side-scrolling), replacing the old vertical thumbnail-row
  list - closer to CS2's horizontal tile strip than the previous round's
  kept-as-is vertical list. Categories are read straight off each
  `RoadProfile.Category` value already in the data model, in a fixed
  preferred order with any unrecognized category appended after.
- Both panels sit inside one shared invisible hover-tracking wrapper sized
  to their combined footprint (not the whole screen - the pie menu's
  earlier click-swallowing bug this round was a direct lesson in getting
  that scope wrong).

## Real bus bay geometry, gradient colour picker, drag-and-drop fix, locale toggle

- **Fixed the farEdgePad regression from last round** (sawtooth/serrated
  curve edges on widen/narrow roads) - see `KNOWN_ISSUES.md` for the full
  root-cause writeup. Removed entirely; deck strips are back to plain exact
  anchored width.
- **Real bus bay geometry**, not just marker stickers. What used to be
  called "Add Bus Bay" only ever placed small bus-stop icon markers
  (`BusStops.lua`) - a real bay (per the user's reference photo) is a
  physical pull-in carved into the road, which didn't exist at all. Now:
  - `Geometry/PolyCurve.lua` gained `Slice(s0, s1)` (a thin re-indexed view
    over a sub-range of an existing curve - no new segment data, delegates
    every query to the base curve plus an offset) and `ClosestS(point)` (a
    coarse-sample-then-refine numeric search for where a 3D click lands
    along the curve).
  - `RoadProfile.WithBay(profile, driveOnLeft, widthM)` inserts a Bay
    component next to the nearside kerb.
  - `Mesh/RoadBuilder.BuildWithBay(options, bay)` stitches 5 sub-builds
    (normal / taper-in / dwell / taper-out / normal) from `Curve:Slice()`
    ranges into one merged model, reusing the existing widen/narrow taper
    machinery for both tapers rather than inventing a new shape.
  - `RoadEditSession` gained a `PlacingBay` -> `ConfirmingBay` flow: click a
    point on the road, then adjust length/width (defaulting to a standard
    dwell length and one lane's width) in a small HUD panel
    (`UI/BayDraftPanel.lua`) before committing. Bay placement persists as a
    `RW_BayJson` attribute (`RoadInstance.StampBay`/read) so later edits via
    `RoadEditSession.Apply` rebuild through `BuildWithBay` instead of
    silently dropping the bay.
  - The old marker feature is renamed throughout (mode, functions, pie
    label) from "Bus Bay" to "Bus Stop" to stop misleading users about what
    it actually does; both now sit side by side in the segment pie menu.
  - Not verified in a live Studio session - this is substantial new
    geometry code and warrants real testing before being trusted.
- **Real gradient colour picker.** There's no Studio API to open the native
  color picker from a plugin (devforum's been asking since ~2016, never
  shipped), so `Components.ColorField` now includes its own: a saturation/
  value gradient square and a hue bar, built from plain Frames + UIGradient
  (no image asset needed), drag-to-pick via each square/bar's own
  InputBegan/InputChanged + `UserInputService:IsMouseButtonPressed` - plus
  the existing hex/Color3-text field and R/G/B number fields for precise
  entry.
- **Drag-and-drop from the Modules palette, real fix attempt.** Previous
  rounds' rewrites used `plugin:GetMouse()` polled on `RenderStepped`,
  reasoning that `UserInputService` is unreliable for Studio plugin GUIs -
  but that reasoning was borrowed from a different, unrelated bug
  (`DockWidgetPluginGui` panels marking input as `gameProcessed` while
  focused). This palette is a plain ScreenGui in CoreGui, not a docked
  panel, and `plugin:GetMouse()`'s `Button1Up` is a 3D-viewport/tool
  oriented event not guaranteed to fire reliably for a 2D GUI drag that
  never activates the plugin as a tool - which would explain drops never
  registering. Rewritten to use `UserInputService.InputChanged`/`InputEnded`
  instead, the same proven pattern this round's colour picker drag uses.
- **British/American English terminology toggle** (`Settings.LanguageVariant`,
  default British). New `Locale.lua` maps display-only term pairs (Kerb/Curb,
  Pavement/Sidewalk) - internal field/kind names are unchanged. Wired into
  the Kerb-lines rows, Region Editor's dimension/colour labels, with a
  dropdown in Regional Preference to switch it.

## Wedge scope-down, real click-swallowing bug, settings home, elevation editing

- **Wedge joints now only appear on genuinely sharp turns/superelevation.**
  `Mesh/RoadBuilder.lua`'s Inside/Outside curve joints used to insert a
  `FillTriangle` wedge at every curved joint, however gentle. Deck strips now
  widen slightly on their far (non-anchor) edge every interval (reusing the
  existing `curveMiterPad` formula, applied to width instead of length,
  anchor-side face held fixed so it doesn't disturb the exact anchor edge),
  and a wedge is only added at a joint if the true remaining gap
  (`WEDGE_GAP_THRESHOLD_STUDS = 0.5` studs) is still bigger than that padding
  could plausibly cover - i.e. only where a flat rectangle genuinely
  couldn't hide the defect.
- **Lane markings now anchor to true curve position at both of their own
  endpoints** (`placeMarkingSpan`), the same technique the deck's anchored
  strips already used, instead of a `curveMiterPad`-padded box centered on a
  midpoint frame plus a separate joint-patch part. Solid rails now meet
  exactly at every interior station with no patch needed, and align with
  whichever deck edge sits at the same lateral offset (previously the
  approximation used by markings and the exact anchor used by
  Inside/Outside deck strips could visibly disagree at a joint - this is
  what showed up as a lane marking not lining up with the road edge, and the
  patch could show up as an overlap).
- **Root cause found for "Bus Bay doesn't work" / "can't stretch a lane
  marking, it just opens Road Builder":** the pie menu's screen-covering
  wrapper `Frame` in `main.lua` had `MouseEnter`/`MouseLeave` wired to
  `uiState.Hovered` - since that frame spans the *entire* viewport (needed
  so the anchored pie menu can appear anywhere within it), the mouse
  "entered" it almost immediately whenever any pie menu showed (i.e.
  whenever a road was selected), latching `Hovered` true and never really
  clearing. `RoadEditSession.onBusBayClick`'s "don't place through the HUD"
  guard (`if uiState.Hovered then return end`) then swallowed essentially
  every click in the 3D viewport while a road was selected. Fixed by moving
  hover tracking onto each individual `PillButton` (`PieMenu.lua`'s new
  `SetGlobalHover` prop) instead of the full-screen wrapper. ("Edit Lane
  Markings" opening the full designer instead of a dedicated stretch
  interaction is separate and expected - that interaction was never built,
  see `TODO.md`.)
- **Pie menu pills now sit on one consistent ring.** The old per-slot pixel
  offsets (`Top`/`TopLeft`/`Left`/`Right`/`Bottom`) had different distances
  from the anchor (70-110px) - not actually on a circle, which is what read
  as "not all on the circumference." `PieMenu.lua` now generates every
  offset from a single `RING_RADIUS` and an angle.
- **Settings now has a home menu instead of forcing both docks open/closed
  together.** The Settings button used to toggle `regionalDock.Enabled` and
  `keybindsDock.Enabled` as one unit - both docks default to the same float
  position, so the second one opened was effectively invisible/unreachable
  behind the first, which was very likely why keybind capture still seemed
  broken even after the earlier `gameProcessed` fix (the user was probably
  never actually looking at the Keybinds dock). `TopBar.lua`'s Settings
  button now opens a small popover to choose "Regional Preference" or
  "Keybinds" - each its own independently-toggled dock.
- **Elevation is now directly editable** (`BuildBar.lua`'s elevation control
  is a `Components.NumberField`, wired through a new
  `createRoadSession.SetElevation`) instead of a read-only label, with no
  "+" prefix on positive values (only negatives show a sign). Added a CS2-
  style step-size field (`Settings.ElevationStepStuds`) right next to it, so
  how far each R/F press or arrow click moves no longer requires opening a
  separate settings dock.
- **Widen/narrow taper smoothed.** `transitionAlpha` used to be a flat 0
  followed by a linear ramp - a real slope discontinuity (kink) exactly
  where the taper zone begins, since the flat zone's derivative is 0 and the
  ramp's is a nonzero constant. Now smoothstepped (`3t^2 - 2t^3`), whose
  derivative is 0 at both ends, so the taper blends in and out with no
  visible bend. Station spacing inside a transition now also scales with
  how fast the width is changing (studs of width change per stud of length)
  instead of a flat 4-stud cap, so a short/steep taper still gets short
  enough strips to read as a smooth line rather than a staircase. (A fully
  exact wedge-trapezoid taper - each strip literally tapering across its own
  length instead of stepping between strips - is specified as a follow-up
  in `TODO.md` if this isn't enough on real testing.)
- **Colour fields are far more compact and take hex/Color3 text input.**
  `Components.ColorField` was a swatch plus 3 separate R/G/B number fields -
  wide enough (~300px) to overflow the settings dock's 260px minimum width,
  which is very likely what read as "doesn't render within the size
  constraint." Now a swatch plus one text field accepting either `#RRGGBB`
  or an `r, g, b` triplet, with the full R/G/B fields available by clicking
  the swatch to expand.
- **Section headers now have a divider and breathing room above them**
  (`Components.Section`), instead of blending straight into the previous
  section's last row - addresses "better separation between each section,"
  applied everywhere `Components.Section` is used (Regional Preference,
  Keybinds, Region Editor, Road Tool/Road Library, Road Editor).
- **Road Tool and Road Library are now visually two distinct groups** in
  `BuildBar.lua` (matching the CS2 reference screenshot), separated by
  `Components.Section`'s divider rather than sitting in one unbroken stack.

## Keybind capture bug + elevation hint + cancel default

- **Fixed: adding a new keybind silently did nothing.** Root cause:
  `main.lua`'s `captureNextKeybind` listened via
  `UserInputService.InputBegan` but bailed whenever `gameProcessed` was
  true - and Studio marks essentially all input as game-processed while a
  docked plugin panel has focus (so it doesn't also trigger 3D-viewport
  shortcuts), meaning the listener's callback returned immediately on
  every keypress/click during capture and nothing ever got added. Fixed
  by not checking `gameProcessed` for this specific listener - during an
  explicit "press a key or click..." capture, whatever the user just
  pressed IS the input we want, regardless of what else has focus. (Live
  R/F/Escape handling elsewhere, e.g. `createRoadSession.lua`, still
  checks `gameProcessed` correctly - that's a different, correct use of
  the same guard, for a different listener.)
- **Elevation hint now shows the user's actual configured keys**, not a
  hardcoded "(or R / F keys)" - `BuildBar.lua` reads
  `settings.Keybinds.ElevationUp`/`ElevationDown` through
  `Keybinds.Describe` so it updates automatically after a rebind.
- **Right-click is no longer a default for Cancel Placement.** It still
  works as Studio's own camera-orbit gesture and can still be added back
  manually via "+", but the shipped default is now just Escape and
  middle-click (the scroll-wheel button) - avoids a right-click meant to
  nudge the camera accidentally cancelling a placement.

## Superelevation + curved-section gap fixes

Both `Mesh/RoadBuilder.lua` bugs identified and fixed:

- **Superelevation inconsistency root cause found**: the runoff/smoothing
  window was a fixed `RUNOFF_LENGTH_STUDS` (40 studs) regardless of segment
  length, capped only at `length / 2`. For a short segment this meant the
  ramp-up and ramp-down taper zones could consume the *entire* road with no
  flat "full bank" middle ever reached, while a long segment of the same
  curve radius reached full target bank easily - so two curves that looked
  equally sharp banked to very different peak amounts purely because of
  their length. Fixed: both the `Superelevation.SmoothRolls` window and the
  end-of-segment taper now use `math.min(RUNOFF_LENGTH_STUDS, length * 0.3)`
  - proportional to the segment, always leaving at least a 40% flat middle
  zone, so short and long curves of the same radius now shape the same way.
- **Curved-section gaps root cause found**: the per-strip "miter" padding
  used `math.abs(centerOffset + width/2) * math.sin(turnAngle)`, clamped to
  `math.min(miter, chord * 2)`. That clamp silently truncated the needed
  padding whenever a component's lateral distance from the centerline was
  large relative to the (adaptively short) chord on a tight curve - exactly
  the case for wide roads (multi-lane avenues/highways) on anything but
  gentle curves, which is why gaps were visible. Replaced with a new
  `curveMiterPad` helper derived directly from arc length (a point offset
  `r` studs from the centerline traces `r * curvature * length` more arc
  than the centerline over the same span - the exact deficit a flat strip
  needs to make up) with no arbitrary clamp; applied using the larger of
  each component's two edge distances (not just the right edge) and using
  true arc length (`s1 - s0`) instead of the straight chord as the base
  span. Also applied to lane markings (`renderSolid`/`renderDashed`), which
  previously got a flat `0.05` stud pad with zero curvature awareness at
  all - markings are thin and high-contrast against the asphalt, so an
  un-mitered gap there was arguably the most visible instance of this bug.
- **Follow-up: verified the miter fix numerically, then closed the
  residual exactly instead of approximating it.** The user pointed at
  [stravant/roblox-gapfill](https://github.com/stravant/roblox-gapfill) (a
  real Studio plugin for closing gaps between arbitrary geometry, using
  `fillTriangle`-style wedge parts oriented via `CFrame.fromMatrix`, MIT
  licensed) and [stravant/roblox-redupe](https://github.com/stravant/roblox-redupe)
  (an array-duplication tool - read for completeness, not directly
  applicable here). Worked out the exact 2D geometry by hand for a
  circular-arc test case (17° turn per strip, 15-stud lateral offset -
  deliberately aggressive) first, to check whether the miter padding
  actually closes the gap or just approximates it: confirmed it closes it
  to within ~0.03-0.06 studs even in that extreme case (the padding
  extends each strip along its own straight tangent, which tracks the true
  curve closely but not exactly). A first pass closed that residual with
  another generously-sized approximation (a small block patch at each
  joint); the user then asked for GapFill's actual technique to be
  included properly, not just referenced - so `Mesh/FillTriangle.lua` now
  ports `fillTriangle` itself (the tricky part: the edge-reordering that
  avoids thin sliver wedges, and the exact `CFrame.fromMatrix` + Wedge
  construction), simplified for our case since we always know which way is
  down (a direct `downVector` argument, replacing the original tool's
  ambiguous `desiredSurfaceNormal`/reference-part heuristics, which exist
  because *its* fills are between arbitrary, not-necessarily-related
  geometry). `RoadBuilder.Build` now records each interval's `MidFrame` +
  per-component offsets/widths as it builds the main strips, then a second
  pass at every interior curve joint reconstructs each component's exact
  (unpadded) end corners on both sides, splits that quad into two
  triangles, and fills them with `FillTriangle` - an exact closure, not
  just a generous approximation, superseding the deck strips' block-patch
  pass. Solid markings still use the earlier (simpler, block-patch) fix
  rather than the new exact one - their miter-padding residual is already
  tiny and extending `FillTriangle` to markings/dashes would add real
  complexity for a mostly cosmetic, already-small discrepancy; revisit if
  it turns out to matter in practice.
- **Follow-up: Curve Alignment setting (Center/Inside/Outside), replacing
  approximation with exact construction on one edge.** The user asked
  about [Archimedes 3](https://devforum.roblox.com/t/introducing-archimedes-3-a-building-plugin/1610366),
  a popular Roblox building plugin with a Center/Inside/Outside path-
  alignment concept. Looked into it: Archimedes' modes pick which
  reference line an extruded shape follows (like choosing whether a wall
  hugs a room's inside, outside, or center line) - its "Outside" mode
  still leaves a gap at corners for the user to patch by hand, so it isn't
  a fancier gap-closing algorithm than what was already here. But the idea
  suggested a real improvement: instead of centering every strip on its
  own interval's tangent frame and *padding* to approximate closing the
  gap on both edges (today's `Center` mode, unchanged), a strip can be
  built by anchoring one specific edge directly to the true curve points
  at both of its station endpoints. Since adjacent intervals reference the
  literal same cached station frame (not two independent approximations),
  that edge becomes gap-free *by construction*, not by tuning a padding
  formula - only the opposite (residual) edge can still gap, and that gets
  closed exactly with `FillTriangle` (one triangle per joint per
  component, not the two-triangle quad Center mode's joint fill needs,
  since one corner of the gap collapses to the shared exact anchor point).
  Shipped as a new `Settings.CurveAlignment` field ("Center" | "Inside" |
  "Outside", default `Inside`), exposed as a dropdown in Regional
  Preference → Geometry. `Mesh/RoadBuilder.lua`'s deck-strip section now
  branches on it: `Center` is the untouched original approach; `Inside`/
  `Outside` use a new `anchoredStripCFrame` helper (built via
  `CFrame.lookAt` between the two true anchor-edge points, reusing Roblox's
  own frame-construction primitive rather than re-deriving a right-vector
  convention by hand, to sidestep a whole class of sign-error risk).
  Markings aren't threaded through `CurveAlignment` yet - they keep the
  existing miter-padding treatment regardless of the setting, matching the
  `FillTriangle` scope decision above.

## Custom region profiles

- **Users can now create and edit their own region presets**, not just pick
  from the seven built-ins.
  - `RegionStyles.lua` gained `BuiltIn: boolean` on the type (all seven
    built-ins flagged `true` via `makeStyle`), plus `Clone`/`Serialize`/
    `Deserialize` mirroring `RoadProfile.lua`'s pattern exactly - Color3
    fields serialize to a plain `{R, G, B}` (0-255) table, never a raw
    `Color3`, matching this codebase's settings-storage rule.
  - `Settings.UserRegions` (serialized user presets) mirrors `UserProfiles`;
    new `RegionLibrary.lua` mirrors `RoadLibrary.lua` exactly
    (`GetAll`/`Get`/`SaveUserRegion`/`DeleteUserRegion`/
    `SerializeUserRegions`). `main.lua`'s `getStyle()` now resolves through
    `regionLibrary.Get` instead of `RegionStyles.Get` directly, so every
    consumer (road building, previews, the designer, thumbnails) picks up
    custom regions with no other code aware anything changed.
  - New `UI/RegionEditor.lua` covers all ~25 fields grouped into sections
    (identity, traffic layout, dimensions, superelevation limits, the three
    marking specs with conditional dash length/gap, marking width/colours,
    seven surface colours) using the same clone-and-transform `OnChange`
    convention as `RoadDesigner`/`ProfileFields`. Two new shared inputs
    support it: `Components.TextField` and `Components.ColorField` (a
    swatch + R/G/B number fields - no gesture-based hue/saturation picker,
    just reliable typed input).
  - Wired into `RegionalPreferenceGui.lua`: "Customize This Region" (built-
    in - Save always creates a copy, same convention as editing a built-in
    road) / "Edit This Region" (already custom - edits in place) / "+ New
    Region" (clones the active style as a starting point) buttons above the
    region dropdown, which now lists user regions too (suffixed
    "(custom)"). The editor replaces the normal settings view while active
    (Save/Delete/Cancel), matching the Road Editor's designProfile-swap
    pattern.

## Road library thumbnails + "Edit Road Segment" (scoped)

- **Road library rows now render a live 3D cross-section thumbnail**
  instead of plain text, CS2-style. `Mesh/ProfileThumbnail.lua` calls the
  real `RoadBuilder.Build` with a short straight `PolyCurve` (no new
  extrusion algorithm needed, confirmed feasible per an earlier note) and
  returns a framing camera CFrame; `UI/RoadThumbnail.lua` renders that into
  a `ViewportFrame` (its own `WorldModel` + `Camera`, built/torn down in a
  `useEffect` keyed on the profile's serialized content + region style id).
  `RoadDesigner.RoadLibraryList`'s `Options` now carry the full
  `RoadProfile` (`LibraryOption` type) instead of just `{Id, Text}`, and
  every call site (`RoadDesigner.Panel`'s Created Roads tab, `BuildBar`'s
  road picker) threads `RegionStyle`/`Settings` down so the thumbnail can
  build. No pooling yet - acceptable for the current library sizes; flag if
  a long user library makes per-row live `ViewportFrame`s a real cost.
- **"Edit Road Segment" pie-menu submenu**, scoped down from the full
  original ask (see `TODO.md` for what's still deferred - the marking
  "stretch" interaction). The pie menu's top level gained a fifth pill
  (`PieMenu.lua`'s new `TopLeft` slot) - "Edit Road Segment" - opening a
  second-level submenu at the same world anchor: **Add Bus Bay** / **Edit
  Lane Markings** / **Back**. `RoadEditSession.lua`'s pie-menu state is now
  a 4-state machine (`Menu` / `SegmentMenu` / `PlacingBusBay` / `Designer`)
  instead of a boolean.
  - **Add Bus Bay** starts a click-to-place mode (`plugin:Activate` +
    `plugin:GetMouse()`, matching the established mouse-tracking
    convention): click a `Sidewalk`/`Parking` part on the selected road to
    drop a stop marker, click an existing marker to remove it, cancel-
    placement key returns to the submenu. New `BusStops.lua` module stores
    stops as a JSON attribute (`RW_BusStops`, mirroring the
    `RW_ProfileStartJson` pattern) and renders them as a billboard-icon
    marker folder under the road model; `RoadEditSession.Apply` re-renders
    them after a geometry rebuild since they'd otherwise be destroyed along
    with the old parts. This is a marker/decoration, not a cross-section
    change - the full "designate part of the roadway as a bus lane"
    geometry feature remains the existing `Bay` component kind, unchanged.
  - **Edit Lane Markings** opens the existing full designer (same as "Edit
    on Road Builder"), where a selected lane's marking can now also be set
    directly with number keys 1-4 (`RoadDesigner.lua`'s
    `NUMBER_KEY_TO_BOUNDARY`), alongside the existing dropdown.

## Keybinds, docked settings split, drag-and-drop take 3

- **Rebindable keybinds.** New `Keybinds.lua` module (action ids, default
  bindings, human-readable `Describe`, `CaptureLabel` for turning a live
  `InputObject` into a plain string, `Matches`/`Sanitize`). Settings now
  persist `Keybinds: {[actionId]: {string}}` (plain strings, e.g. `"R"`/
  `"MouseButton2"` - never raw `Enum`s, matching `RoadProfile`'s
  Kind-as-string convention) and a new `KeybindsGui.lua` lets each action
  have multiple bound inputs, each with its own "-" remove button and a
  shared "+ Add binding" that listens for the next key/click.
  `createRoadSession.lua` now reads `settings.Keybinds` instead of
  hardcoded R/F/Escape.
- **Settings split into two independent docks**, not tabs sharing one
  panel: "Regional Preference" (region/scale/superelevation/snapping/
  geometry - everything the old single settings page had minus keybinds)
  and "Keybinds", each its own `DockWidgetPluginGui` (`loader.server.lua`),
  toggled together from the top bar's Settings button.
- **Elevation height now remembered across sessions**
  (`Settings.LastElevationStuds`), instead of resetting to 0 every time a
  build session starts.
- **Scrollbar styling.** `Components.ScrollBar()` returns a shared
  grey-black, 50%-transparent scrollbar style
  (`Theme.SCROLLBAR_COLOR`/`_TRANSPARENCY`/`_THICKNESS`) applied to every
  `ScrollingFrame` in the plugin; every one of them also now forces
  `ScrollingDirection = Y` + a zeroed `CanvasSize.X` (the lane strip is the
  deliberate exception, staying horizontal) so nothing can drift
  sideways.
- **Drag-and-drop rewritten a third time**, now using `plugin:GetMouse()`
  polled on `RunService.RenderStepped` for position and `mouse.Button1Up`
  to end the drag - the pattern the user supplied from the devforum -
  instead of `UserInputService.InputChanged`/`InputEnded`, which is
  suspected unreliable for mouse tracking (as opposed to keyboard input,
  which already worked fine via `UserInputService.InputBegan`) over
  Studio's docked plugin GUIs in edit mode. The hover-based drop-target
  resolution (`MouseEnter`/`MouseLeave` on tiles/strip) from the previous
  rewrite is unchanged - only the begin/end/position tracking moved.
  `RoadDesigner.Panel`/`RoadInspector` now take a `PluginObj: Plugin` prop
  threaded down from `main.lua` so the hook can call `:GetMouse()`.
- **BuildBar tool buttons are icon-first**: the Straight/Curve/Free text
  label now only appears on hover (tooltip-style), matching the request to
  reduce visual weight when nothing's focused.
- **New elevation arrow icons** (`rbxassetid://6034818379` up /
  `6034818372` down) replace the unicode ↑/↓ glyphs on the elevation
  buttons; `Components.Button` gained an optional `Icon` prop to support
  this without a one-off button variant.
- **Road Editor's Top row**: Properties and Modules/Library are now
  independently anchored (`AnchorPoint`/`Position`, no shared horizontal
  `UIListLayout`) - Properties pinned to the left edge, Modules pinned to
  the right edge, so the gap opens in the middle instead of the two cards
  hugging each other with dead space only past the Palette.

## Real fixes from Studio testing (round after the pie menu)

- **Found and fixed the actual root cause of the recurring "Properties
  card too wide" bug.** `Components.Button`'s `Grow` option still set
  `AutomaticSize.X` alongside the `UIFlexItem` - combining "size exactly to
  text" with "share available row space" meant a row of Grow buttons with
  long labels ("Save as Copy", "Use as Template", ...) reported its full
  text width as its flex basis and could still overflow a fixed-width
  column. This is why the overflow kept coming back after earlier
  formatting fixes. Fixed: `Grow` now forces `AutomaticSize.None` and adds
  `TextTruncate`.
- **Lane strip is now centered**, not left-stuck with dead space on short
  roads.
- **Drag-and-drop rewritten again**, this time using plain hover tracking
  (`MouseEnter`/`MouseLeave` on tiles and the strip) instead of hit-testing
  a screen coordinate. The previous `GuiService:GetGuiObjectsAtPosition`
  attempt was still unreliable - plausibly because that API doesn't
  reliably see `CoreGui`-parented plugin UI in Studio's edit-mode context,
  which would explain "still just bugs." Hover events are the same
  mechanism every hover-highlight in this UI already uses successfully, so
  this version has much less room for a coordinate-space mismatch to hide
  in.
- **Settings split into tabs**: Regional Preference (everything that used
  to be the whole page) and a new Keybinds tab (currently informational -
  lists R/F for elevation and Esc/right-click/middle-click for cancel;
  not rebindable yet).
- **Middle-click also cancels placement**, alongside the existing Escape
  and right-click - right-click doubles as Studio's camera-orbit gesture,
  so a quick right-click meant to nudge the camera could cancel a
  placement unintentionally. Right-click was kept (not removed) since CS2
  users expect it; say the word if it should go. (Later removed from the
  default entirely - see the keybind round above.)
- **Pie menu rename**: the existing "open the full designer" action is now
  labelled "Edit on Road Builder" - "Edit Road Segment" is reserved for the
  new, not-yet-built feature described below.

## Pie menu (click a placed road)

The reference the user provided (a screenshot from a CS2-like game) clarified
that the "pie menu" isn't an actual wedge-sliced radial widget - it's a
handful of plain pill-shaped buttons scattered around the object (top/left/
right/bottom), which is much cheaper to build well in Roblox than a true
radial menu. Shipped this round:

- **`UI/PieMenu.lua`**: 4 fixed pill-button slots around a world-space
  anchor point, camera-tracked every frame via `WorldToViewportPoint` (its
  own `ScreenGui`, deliberately *not* `IgnoreGuiInset` - that convention
  matches `WorldToViewportPoint`'s coordinate space, whereas the bottom
  HUD's `ScreenGui` ignores the inset for the drag-ghost math; the two
  needed to differ). Hides itself when the anchor is off-screen or behind
  the camera.
- Selecting a placed road now shows this menu **first**, before the full
  designer: **Edit Road Segment** (opens today's `RoadInspector` designer,
  unchanged), **Place More** (starts a new build session seeded at this
  road's exact end position/tangent with its exact profile - via
  `createRoadSession`'s new optional `seed` parameter and
  `RoadEditSession.GetContinuation()` - no proximity re-snapping needed),
  **Use as Template** (clones this road's profile into a new user profile
  and opens the Road Editor with it pre-loaded), **Cancel** (deselects).
  `RoadEditSession` gained `IsShowingMenu`/`OpenEditor` to track which of
  the two states (menu vs. full designer) is current for the selected road.

**Not done yet at the time** (later partly built, see the rounds above):
hover-based (not click-based) triggering, the Road Editor's own
entry-point pie menu ("Edit existing" / "Create new empty" / "Place more"),
numeric-key shortcuts for marking selection, retractable side panels, and
the "stretch dash" marking style / bus stop placement mentioned alongside
"Edit Road Segment". Still unscoped (see `TODO.md`):

- **Hover** (rather than click-to-select) as the trigger needs new
  always-on mouse-hover raycast logic, distinct from the
  `Selection`-based approach `RoadEditSession` uses today - clicking was
  the tractable first step; hover is a separate follow-up.
- **Road Editor's own entry pie menu** and an empty-layout "Create new"
  (today's New still uses the 4-component starter template, not zero
  components) haven't been touched.
- **Retractable side panels** are UI polish on top of the current
  designer, not started.
- **"Stretch dash" marking style** isn't a `LineType` `Mesh/Markings.lua`
  understands yet.

## Foundational build (road designer, HUD, branding, inspector)

- **Bug-fix round: overflow, elevation, library placement, drag-and-drop.**
  - Fixed horizontal overflow in the Road Properties column: the dash
    length/gap row was packed too tightly for the fixed-width card and
    forced a horizontal scrollbar; split into two narrower rows
    (`ProfileFields.lua`). Road Tool panel's tool buttons now share row
    width evenly (`UIFlexItem`) instead of relying on auto-sized text width,
    removing the same risk there.
  - Elevation now has explicit up/down arrow buttons in the Road Tool
    panel (alongside R/F, which still works) - `createRoadSession.lua`
    exposes `AdjustElevation(delta)`, shared by both the keybinds and the
    new buttons.
  - The road picker moved out of the Road Properties card into its own
    "Created Roads" tab sharing the right-hand card with Modules
    (`RoadDesigner.PaletteOrLibraryCard`), matching CS2's AVAILABLE LANES /
    CREATED ROADS tab bar instead of living inside Properties.
  - Rewrote drag-and-drop to use `GuiService:GetGuiObjectsAtPosition` at
    drop time (walking ancestry for a named lane tile/strip) instead of
    comparing raw input coordinates against a cached `AbsolutePosition` +
    assumed tile width - the previous version had a real GuiInset/coordinate
    mismatch (ScreenGuis now also set `IgnoreGuiInset = true` so the drag
    ghost tracks the cursor precisely) and no longer depends on tile-size
    assumptions matching what's actually rendered.
  - Note: the logo image mentioned below was tried and reverted per
    follow-up feedback - the top bar is text-only again, styled in
    `BuilderSansMedium` and the brand orange.
- **Branding pass: brand orange + Builder Sans + logo.** Every button/
  checkbox/selected-state colour that used to be blue is now the easyRoad
  brand orange (#D98455, `Theme.ACCENT`/`SELECTED`/`ACCENT_HOVER`); UI text
  uses `Enum.Font.BuilderSans`/`BuilderSansBold` instead of SourceSans; the
  top bar shows the easyRoad logo (`rbxassetid://73102883268322`) next to
  the title.
- **Icon updates.** Bike (`117323310944439`) and Parking
  (`135215443300853`) module icons updated; new tool-mode icons for
  Straight/Curve/Freeform in the Road Tool panel (`80355330590276`/
  `90102359516465`/`112290052468250`). "Bus Bay" is removed from the
  Modules palette - see `TODO.md`'s Bus Lane entry, it moved to the
  per-instance road panel as "Bus Lane" with a new icon.
- **Discoverable lane marking control.** The per-lane boundary control (in
  the lane strip's selected-tile row) is now a labeled dropdown - "Solid -
  no lane change", "Solid | Dash - right may merge left", etc. - instead of
  an unlabeled glyph-cycling button, so the existing per-lane marking-type
  feature (already fully implemented in `Mesh/Markings.lua`) is actually
  discoverable. Global dash length/gap remain in Road Properties.
- **Road Editor layout overhaul.** `RoadDesigner.Panel` now matches the
  CS2 / easyRoad 2 reference layout: Road Properties (left) and Modules
  (right) are two full-height columns, with the lane strip ("Road Layout")
  pinned along the very bottom spanning the full width underneath both -
  instead of three cards crammed into one row that forced the properties
  column to scroll. The road picker in both the Road Editor and the Road
  Tool panel is now a scrollable library list (name, click to select, "+
  New Road") instead of a dropdown.
- **Drag-and-drop module insertion.** Palette tiles in the Road Editor can
  now be dragged onto the lane strip to insert at the drop position (press
  and drag past a small threshold; a plain click still inserts after the
  selected lane, unchanged). Implemented as a small shared controller in
  `RoadDesigner.lua` using `useState`/`useRef`/`useEffect` + a global
  `UserInputService` listener while dragging is active.
- **Settings panel indent.** The docked settings sidebar no longer draws
  its own glass card/corner (it's already inside a bordered Studio dock
  widget); content is now inset ~5px further from the panel edges.
- **Top mode bar + separated surfaces (CS2 architecture).** A glass top
  bar (`UI/TopBar.lua`) toggled by the toolbar button switches between the
  plugin's three functions so nothing is crammed into one surface:
  - *Road Tools* — placement session with a compact CS2-style tool panel
    bottom-left (`UI/BuildBar.lua`: tool mode, road picker, widen-to,
    banking, elevation, hints, stop) — like the CS2 road tool box.
  - *Road Editor* — the full designer bottom bar (properties | lane strip
    | modules palette) for creating/editing road types, now with a road
    picker + New button directly in the properties card
    (`RoadDesigner.Panel` `Picker` prop). Tools/Editor are exclusive modes.
  - *Settings* — the grand settings (region profile, scale, banking,
    snapping, geometry) live in the docked Studio sidebar panel.
  `UI/EasyRoadGui.lua` and `UI/LaneEditor.lua` (the old page-routed dock
  UI) are deleted. Selecting a placed road still opens the designer bound
  to that road, independent of the top bar.
- **CS2-style build bar; old right-side panel removed.** The floating
  right-anchored panel is gone. While placing roads, the bottom bar now
  shows [Road Tool card | live lane strip | Modules palette]: tool modes,
  road picker, transition target, banking + design speed, elevation and
  hints on the left; the ACTIVE road's cross-section as editable tiles in
  the middle (session-only tweaks, kept via "Save as New Road..."); module
  insertion on the right. `UI/RoadDesigner.lua` was split into reusable
  `LaneStripCard` / `PaletteCard` / `Panel` so build, library editing, and
  placed-road editing all share one strip implementation
  (`UI/BuildBar.lua` composes the build variant). Layout fixes for small
  logical viewports (high-DPI screens): the bottom bar spans the full
  width, fixed card widths shrunk (240 / flex / 140), section headers
  truncate instead of bleeding across cards. Glyph fixes: dropdown chevron
  and boundary/move/remove button labels now use ASCII-safe characters
  (Studio's SourceSans renders ▾ and box-drawing glyphs as tofu boxes).
  The dock panel still carries the legacy page UI as a secondary surface
  (also the nav to Settings / road picker).
- **CS2-style road designer (`UI/RoadDesigner.lua`).** The road
  configuration UI is now a wide bottom-of-viewport HUD with three glass
  cards, modelled on the CS2 road builder / easyRoad 2 reference: a lane
  strip (one tile per component — module icon, direction arrow ↑/↓, width;
  click to select, then edit width/direction/boundary or reorder/remove), a
  Modules palette (Lane / Pavement / Median / Shoulder / Bike / Parking /
  Bus Bay tiles using the reference icon set; click to insert after the
  selection), and a Road Properties card (name, kerb lines, kerb offset,
  line colour, dash spacing, action buttons). The same designer serves
  both the library editor (Edit Roads → pick a road → designer opens with
  Save/Delete/Close) and the placed-road inspector (select a placed road →
  designer opens with Apply/Revert/Close). The old vertical list editor
  and left-side inspector panel are gone; `UI/LaneEditor.lua` is now just
  the picker page, `UI/RoadInspector.lua` the session-binding wrapper, and
  `UI/ProfileFields.lua` the shared kerb/colour/dash rows.
- **Select a placed road → contextual edit panel.** Click any already-placed
  road in the viewport with Studio's ordinary selection tool (no need to
  activate easyRoad) and a left-anchored inspector HUD appears, editing that
  road's cross-section (kind/width/direction/boundary per component, with
  add/remove/reorder), kerb restriction, kerb line offset, marking colour,
  and dash spacing in place — "Apply to Road" rebuilds just that model as a
  single undo step. Placed roads now carry their full curve control points
  and serialized start/end profiles as attributes (`RW_CurveKind`/`RW_P0..P3`/
  `RW_ProfileStartJson`/`RW_ProfileEndJson` — see `RoadInstance.lua`), so a
  road with session-only tweaks (a widened lane, a swapped-in Bay) can be
  reopened and edited without needing the library profile it started from.
  Roads that transition between two profiles show a note and only expose the
  kerb/colour/dash rows (component-by-component editing across a transition
  is still Road Editor-only). Roads placed before this change lack the new
  attributes and show a "can't be edited in place" note in the inspector.
  New modules: `RoadInstance.lua`, `RoadEditSession.lua`,
  `UI/RoadInspector.lua`; `UI/ProfileFields.lua` factors the shared
  component/kerb/colour/dash rows out of `UI/LaneEditor.lua` so the road
  editor and the new inspector can't drift apart.
- Marking rule engine: full line vocabulary (solid/dashed/double/asymmetric
  merge), per-lane boundary rules, kerb restrictions (single/double
  yellow), region-forced marking colour, per-road dash spacing override.
- Kerb restriction lines now replace (not duplicate) the plain edge line at
  any roadway edge that meets a kerb — previously only worked for `Drive`
  lanes, so `Parking`/`Shoulder`/`Bay` never got a kerb line at all.
- **Bay** component kind (bus / taxi pull-in bay) — full kind support:
  region-configurable colour (`RegionStyle.BayColor`), material, icon
  fallback, generic editor support (it's just another entry in the kind
  dropdown, same as Parking/Shoulder).
- **Kerb line offset** choice per road: "Inset (default)" vs "Flush at
  edge" — exposed in the road editor next to Kerb lines / Line colour /
  Dash spacing.
- Live width tweaking in the build HUD ("Adjust Widths") with a
  session-only override and "Save as New Road..." to persist it.
- Viewport glass HUD, easyRoad branding (toolbar/icon/tooltip).
