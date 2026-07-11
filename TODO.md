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

Deliberately still out of scope after Phase 1, in rough priority order:

- **`RoadSplit` refuses to split a road with a transition or bus bay.**
  Interpolating the exact profile at an arbitrary cut station, or deciding
  which piece keeps a bay, is real geometry work not attempted yet -
  splitting simply doesn't happen for those roads (the new road's end is
  left unconnected, same as today).
- **`RoadSplit` drops MarkingStretches/KerbStretches across a cut** rather
  than remapping their station ranges into each piece's own local
  coordinate space - the same class of complexity already flagged for
  marking stretches surviving a structural profile edit, above.
- **The fillet polygon ignores superelevation roll.** Edge points are
  computed via a plain `FrameAt(station)` (roll defaults to 0); a road
  banked right at the point it meets a junction will have its pad edge
  slightly off from the true tilted deck surface. Uncommon in practice
  (banking transitions run mid-segment, not usually right at an endpoint).
- **No lane markings drawn through the junction.** Stop lines, give-way
  markings, crosswalks, lane-guidance paint - `Markings.Compute` is
  fundamentally "one road, station 0 to Length" and deliberately wasn't
  touched; junction marking geometry needs its own module.

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
- **No live preview.** Unlike ordinary road placement (which ghosts the
  road as you aim), there's no preview of the ring or the trimmed spokes
  before clicking "Make Roundabout" - you only see the result after
  committing. Same gap exists for the ordinary junction fillet pad itself
  (no preview while approach roads are still being placed).
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

## Kerb marking editor + highway shoulder default (not started)

Reported live: highway profiles currently draw a plain edge-line "kerb"
marking on the outer edge of the shoulder, where real highway marking
convention has nothing there (it's pavement running into open embankment/
grass, not an actual kerb or a parking-relevant edge). Root cause: kerb
line generation (`Markings.KerbEdges`/`Compute`) treats a profile's
`KerbRestriction` as ONE setting applying uniformly to every kerb-eligible
edge - there's no way for a profile to say "no line on the outer edge,
but the usual restriction elsewhere." Two related asks:
- **Default fix**: built-in Highway-category profiles should default to
  no marking on the outer shoulder edge. Smallest correct fix is probably
  making `RoadProfile.BuiltInProfiles`'s highway entries default
  `KerbRestriction = "NoLine"` - but confirm this doesn't also suppress a
  wanted restriction on an inner (median-adjacent) edge first, since
  today's model can't distinguish the two.
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
