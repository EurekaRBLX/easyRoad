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
- **Snap-to-road / snap-to-grid toggles in Road Tools - shipped.** See
  `SHIPPED.md`. `Settings.SnapToRoad` (new) gates
  `findEndpointSnap`/`findConnectableEndpoint`/`findMidSpanMatch` in
  `createRoadSession.lua`; `Settings.SnapToGrid` already existed but had
  no Road Tools surface, only the Regional Preference dock. Both now have
  checkboxes in `BuildBar.lua` next to the tool buttons.
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
