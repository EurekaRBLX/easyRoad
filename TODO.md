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

## Junctions & intersections — phased plan (Phase 1a shipped, rest in progress)

CS2-style node model: a `JunctionNode` (`JunctionInstance.lua`) is a real,
first-class entity roads reference by Id (`RW_StartJunctionId`/
`RW_EndJunctionId` attributes, see `RoadInstance.lua`), replacing pure
positional endpoint-snap coincidence. A road ending at a junction is just
`curve:Slice(0, s)` handed to the unmodified `RoadBuilder.Build` (the same
mechanism already used for bus-bay tapers/marking stretches) - the
junction's own pad/fillet surface is a separate module that stitches the
seam, so ordinary road geometry needed no surgery. See `SHIPPED.md` for
what Phase 1a actually built.

**Phase 1a (shipped):** node data model, auto-create-on-snap at both
placement endpoints (not just the chained-continuation case), a v1
circular asphalt pad sized to the widest connected road. Deliberately
scoped out of Phase 1a, in rough priority order:

- **No skip-for-simple-pass-through.** Every 2-road meeting point gets a
  pad, including a plain chained straight continuation where one isn't
  really needed - harmless but redundant geometry. A fast follow: skip pad
  generation when exactly 2 roads meet with roughly-opposite tangents and
  matching profiles.
- **No orphan cleanup on road deletion.** Deleting a road via Studio's
  native Delete key doesn't currently shrink or remove the junction it was
  connected to (there's no plugin-level delete hook to react to today -
  would need a `workspace.Roads.ChildRemoved` listener, owned at the
  `main.lua` level rather than per-session so it doesn't come and go with
  placement tool activation).
- **No junction selection/editing UI.** Can't currently select a placed
  junction, see what's connected to it, or delete one directly (only
  indirectly, by deleting all its roads and never rebuilding the pad - see
  above).
- **No mid-span split tool.** A junction is only ever created where two
  roads' endpoints already coincide (on placement). Clicking a point
  partway along an *existing* road to split it and insert a junction there
  is a separate, not-yet-built tool - this is also the prerequisite for
  "a new road crosses an existing one mid-network," not just endpoint-to-
  endpoint meetings.
- **Pad is a crude circular disc, not an exact fillet polygon.** Unlike
  curve joints and superelevation wedges elsewhere in `Mesh/`, which
  converged on exact corner geometry via `FillTriangle` after a padding
  scheme proved insufficient, the junction pad doesn't yet compute the
  real per-corner fillet outline from each connected road's edge
  geometry - it's sized generously enough to always cover the seam, but
  won't look like a proper rounded-corner intersection.
- **No lane markings drawn through the junction.** Stop lines, give-way
  markings, crosswalks, lane-guidance paint - `Markings.Compute` is
  fundamentally "one road, station 0 to Length" and deliberately wasn't
  touched; junction marking geometry needs its own module.

**Phase 2 - roundabouts.** A specialised junction node, same connectivity
model, different surface generator (circular deck instead of a fillet).
Needs a new arc-based `CurveSegment.SegmentKind` first - there's currently
no true circular-arc primitive, only Line/Quadratic/Cubic Bézier. Variants
in roughly increasing complexity: single-lane, multi-lane concentric
standard, multi-lane concentric with turbo markings, true turbo (spiral,
Netherlands-style) roundabouts.

**Phase 3 - lane connector + traffic light API.** Per-lane connection
graph at a junction (drag connections between incoming/outgoing lanes,
markings re-render from the graph); a mock Traffic Light API sharing that
same per-lane graph model so it's designed once for both.

Smaller, independent alternative that builds on the inspector instead of
junctions: dragging a placed road's endpoint, or a duplicate/delete action
in the inspector panel — both reuse the `RoadEditSession.Apply` rebuild-
in-place machinery already built, unrelated to the junction work above.

## Backlog (not yet started)

- **Crossings.** Zebra crossings and HK/UK-style uncontrolled cautionary
  crossings (zigzag give-way markings).
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
- **Snapping beyond endpoints.** Mid-segment snap, automatic junction
  creation when a new road crosses an existing one.
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
