# EasyRoad — To Do (New Features)

Planned/requested work not yet built, roughly ordered by how developed the
plan is. Not user-facing; internal planning only. See `SHIPPED.md` for
what's already built and `KNOWN_ISSUES.md` for confirmed bugs.

## Marking stretch v1 follow-ups (deliberately deferred, not forgotten)

The marking-stretch feature (drag a lane boundary's marking to override its
type over a free-form sub-range, siblings moving together - see
`SHIPPED.md`) shipped a real v1, but a few things were deliberately scoped
out rather than solved, and should get their own pass later:

- **`ComponentIndices`-keyed storage isn't stable across a structural
  profile edit.** A stretch stores which cross-section boundaries it
  targets by index; if the user later adds/removes/reorders lanes in the
  designer and hits Apply, an existing stretch can end up pointing at the
  wrong boundary (or silently drop an index, if it no longer resolves to a
  same-direction boundary at all - `Markings.lua` degrades safely per
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

**Roundabout icon - deliberately not built.** The queued CS2-style UI polish
request (left-align Tool Mode, grid Road Library, icon-based category tabs)
is now fully shipped except for a "generate a roundabout icon similar to
CS2's" item - skipped because roundabouts aren't an implemented feature and
there's currently no UI slot that would display a roundabout icon, so
building one now would be orphaned geometry with no consumer. Revisit once
roundabouts (see Intersections & roundabouts below) or some other roundabout-
adjacent UI actually exists to use it.

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

**Curb-return corners (shipped):** confirmed live that the flat fillet
pad "genuinely doesn't change the roads" - `JunctionBuilder.lua` now
builds real curb-return corners instead. Each connected road contributes
its own KERB points (roadway/non-roadway boundary) and OUTER points
(profile's true outer edge, e.g. a sidewalk's outer edge); between
angularly-adjacent roads, a tangent-continuous quadratic-Bézier corner
(the classic "intersect the two tangent lines" construction) is fanned
from the junction centre as the asphalt surface, and the strip between
that arc and each road's outer edge is filled separately as the
pedestrian corner (sidewalk material) - a real curb-return shape, not an
unshaped flat pad. Fixed a follow-up bug (reported live, 2-road bend and
T-junction screenshots): a between-road gap wider than ~160° (the far
side of a bend, or the "through" span at a T-junction between the two
separate road Models forming one visually-straight through road either
side of the branch) isn't a real corner and was producing a wildly
oversized, self-intersecting spike when bridged anyway - now skipped
entirely rather than filled.

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
- **No lane markings drawn through the junction.** Stop lines, give-way
  markings, crosswalks, lane-guidance paint - `Markings.Compute` is
  fundamentally "one road, station 0 to Length" and deliberately wasn't
  touched; junction marking geometry needs its own module.
- **Roundabout ring's own pavement/sidewalk still doesn't align cleanly**
  with the trimmed spokes' sidewalks - reported live with a screenshot
  (visible gaps/misalignment where each spoke's sidewalk meets the ring).
  The spoke trim (see Phase 2 above) cuts the whole cross-section at the
  ring boundary, but nothing yet builds a matching corner/verge piece
  bridging a spoke's sidewalk into the ring's own edge, the way ordinary
  junction corners now do (just above) - the ring doesn't have a
  `JunctionBuilder`-style corner-fill pass of its own.
- **No mid-span-to-mid-span crossing detection.** `RoadSplit`'s existing
  mid-span connect (Phase 1b) only fires when a NEW road's endpoint lands
  on an EXISTING road - not when a new road is drawn crossing an existing
  one with both roads continuing past the crossing point on every side (a
  genuine "X" where neither road's own endpoint is at the intersection).
  Reported live: "i cannot create a new road that intersects with the
  road in question and extend it beyond ... I have to first explicitly
  connect them." Needs curve-curve intersection detection between the
  new road being placed and every existing road (no closed-form solution
  for Bézier-Bézier intersection - likely sampling/bisection, similar in
  spirit to `RoundaboutBuilder`'s ring-crossing bisection), then splitting
  BOTH roads at the crossing point (today's `RoadSplit.SplitAt` only
  splits one).
- **No snap-to-road / snap-to-grid toggle in Road Tools.** Both already
  exist as always-on background behaviour (`findEndpointSnap`,
  `applyGridSnap` in `createRoadSession.lua`, gated by
  `Settings.SnapToGrid`/`GridSizeStuds` for the grid case but with no UI
  surface to change it, and road-endpoint snapping isn't toggleable at
  all) - requested as an explicit, visible tool/toggle in the Road Tools
  panel rather than silent background behaviour.
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
with radius/lane-count/lane-width fields.
**What's still deliberately missing:**
- **No per-lane merge tapering at each approach.** A trimmed spoke's
  pavement just stops at the ring boundary - there's no shaped merge lane
  blending its own lane(s) into the ring's circulating lane(s), no
  yield/give-way markings, nothing modelling how many ring lanes a given
  approach's lanes should feed into. This is the single biggest remaining
  gap between v1 and a real roundabout.
- **Ring pavement/sidewalk notch at the trim point - fixed.** The spoke
  trim cuts the whole cross-section at a flat perpendicular station, but
  the ring boundary is curved, so a sidewalk's laterally-offset outer edge
  used to end up inside or outside the ring's actual radius at that same
  station (confirmed live with a screenshot: visible rectangular notches
  where each spoke's sidewalk cut into the ring). `trimSpokeToRing` now
  searches for the crossing at a Pythagorean-adjusted centerline radius
  (`sqrt(radius^2 - halfWidth^2)`, minus `RING_TRIM_MARGIN_STUDS`) instead
  of the ring's raw radius, so the spoke's widest cross-section point (its
  outer sidewalk edge, not just the centerline) lands just inside the
  ring's true boundary rather than poking through it. Still not a proper
  `JunctionBuilder`-style corner-fill bridging each spoke's sidewalk into
  the ring's own edge - there's a small margin gap by design, not a
  seamless join - but the notch itself is gone.
- **No live preview.** Unlike ordinary road placement (which ghosts the
  road as you aim), there's no preview of the ring or the trimmed spokes
  before clicking "Make Roundabout" - you only see the result after
  committing. Same gap exists for the ordinary junction fillet/corner
  geometry itself (no preview while approach roads are still being
  placed) - requested explicitly for both.
- **No way to edit a roundabout's own form after creating it.** Radius/
  lane-count/lane-width are one-shot inputs at creation time
  (`RoundaboutBuilder.CreateAtJunction`) - requested explicitly. Blocked
  on the same "not wired into the data model" gap below (nothing to
  select/re-open), so likely needs solving together rather than
  separately.
- **The ring still isn't wired into the junction/road data model.** Not
  stamped `RW_Road` (so `RoadEditSession`'s selection UI and the mid-span
  split scan ignore it - neither is built to handle a closed
  multi-segment curve), no `Start`/`EndJunctionId` link. There is
  currently no in-plugin way to select, edit, or delete a placed ring -
  delete it via the Explorer. A trimmed spoke's new ring-side end is
  likewise left unconnected.
- **Winding direction (which way traffic circulates for `DriveOnLeft`)
  is reasoned through, not verified live.** Flip
  `RoundaboutBuilder`'s `circleSegments` ternary if it reads backwards
  once tested in Studio.
- **No median/central island component**, no turbo lane-guidance
  markings, no spiral (true turbo) geometry - multi-lane concentric is
  now possible (lane count is configurable), but nothing beyond a flat
  multi-lane ring.

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
- **Tunnels / bridges standard.** Auto-generated barriers/parapets on
  elevated or sunken segments, pillars for bridges. Reference: the user's
  Commonwealth expressway assets in their Studio environment.
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
