# EasyRoad — To Do (New Features)

Planned/requested work not yet built, roughly ordered by how developed the
plan is. Not user-facing; internal planning only. See `SHIPPED.md` for
what's already built and `KNOWN_ISSUES.md` for confirmed bugs.

## Marking stretch v1 follow-ups (deliberately deferred, not forgotten)

The marking-stretch feature (drag a lane boundary's marking to override its
type over a free-form sub-range, siblings moving together - see
`SHIPPED.md`) shipped a real v1, but a few things were deliberately scoped
out rather than solved, and should get their own pass later:

- **Removal is all-or-nothing.** `ClearMarkingStretches` wipes every stretch
  on the road; there's no per-stretch removal (e.g. click an existing ghost
  line to delete just that one). Fine for the common "one stretch per road"
  case, annoying once someone has stretches on both directions of a divided
  road and only wants one gone.
- **`ComponentIndex`-keyed storage isn't stable across a structural profile
  edit.** A stretch stores which cross-section boundary it targets by
  index; if the user later adds/removes/reorders lanes in the designer and
  hits Apply, an existing stretch can end up pointing at the wrong boundary
  (or silently drop, if the index no longer resolves to a same-direction
  boundary at all - `Markings.lua` degrades safely, it just doesn't warn).
  A `RightBoundary` rule doesn't have this problem since it lives on the
  component itself and moves/deletes with it; a stretch is a separate list
  keyed by position instead.
- **`BuildWithBay` + transition + stretch is only approximately handled.**
  When a road has both a widen/narrow transition AND a bus bay AND a
  stretch, the stretch's `ComponentIndex` is resolved against whichever
  component list produced it, but the bay-aware builder's "before"/"after"
  taper slices use `MatchForTransition`'s (possibly reindexed/padded)
  component list while the middle bay slice uses the unmatched
  `baseProfile.Components` list directly - if a transition inserts an extra
  component before the targeted boundary, the index can point at the wrong
  boundary in one slice but not another. A genuinely rare combination
  (transition + bay + stretch all on the same road); flagging rather than
  fixing blind.
## Keybinds - user wants an in-plugin UI to change them, not just Studio's

User feedback after the `PluginAction` rework (see `SHIPPED.md`): "now it is
hardcoded but i want it to be changable on a ui." `UI/KeybindsGui.lua` is
currently read-only (lists the 3 hardcoded defaults + points at Studio's own
Customize Shortcuts dialog for rebinding) - that rebuild fixed a real,
repeatedly-broken bug (capturing a keypress from inside a docked panel isn't
reliable, a documented Studio platform limitation), but the resulting UX
regresses from "click + Add binding, press a key, done in this same panel"
to "leave the plugin, go find Studio's own dialog, search for the right
action name." Worth a follow-up design pass on how to get BOTH reliability
and an in-plugin experience:
- Simplest real option: keep everything as-is, but add a button in
  `KeybindsGui.lua` that does the equivalent of clicking into the 3D
  viewport first (or a `PluginGui`/`PluginMenu` bridge, if one exists) to
  make the SUBSEQUENT native Studio Customize Shortcuts dialog opening feel
  more like "one click away" rather than requiring the user to know where
  it lives - needs research into whether Studio exposes a way to
  programmatically open that dialog scoped to our plugin's actions (no
  known API for this as of the last research pass; would need re-checking).
- Alternative: since `plugin:GetMouse()` events (used successfully for
  actual road/bay placement) demonstrably work while the 3D viewport has
  focus, a capture flow that explicitly waits for the user to click INTO
  the 3D viewport (not the docked panel) before listening might sidestep
  the docked-widget-focus limitation - e.g. "click + Add binding, then
  click or press your key anywhere in the 3D viewport" instead of pressing
  it immediately while still hovering the settings panel. Worth prototyping
  carefully given three previous rounds already failed on variations of
  "capture from inside the docked panel" - the key difference here is
  requiring the capture moment to happen in the viewport specifically, not
  the panel, which is the actual root cause the PluginAction rework
  sidestepped rather than solved.

## Next up — needs a decision or real design work

**Roundabout icon - deliberately not built.** The queued CS2-style UI polish
request (left-align Tool Mode, grid Road Library, icon-based category tabs)
is now fully shipped except for a "generate a roundabout icon similar to
CS2's" item - skipped because roundabouts aren't an implemented feature and
there's currently no UI slot that would display a roundabout icon, so
building one now would be orphaned geometry with no consumer. Revisit once
roundabouts (see Intersections & roundabouts below) or some other roundabout-
adjacent UI actually exists to use it.

**Junctions & intersections.** With placed roads now selectable and
editable, the next structurally biggest gap is that roads can only ever
meet end-to-end (chained placement or endpoint snap) — there's no way to
make two roads actually intersect mid-network, no corner fillets, no stop
lines, no roundabouts. This is a large, mostly-greenfield feature (junction
node data model, per-lane connection graph, re-deriving markings at the
junction) and probably deserves a design pass before code. Worth reusing
the inspector's rebuild-in-place convention (`RoadEditSession.Apply`) for
whatever rebuilds a junction node's roads after an edit, so the two
features share one pattern instead of two.

Smaller alternative that builds on the inspector instead of junctions:
dragging a placed road's endpoint, or a duplicate/delete action in the
inspector panel — both reuse the same Apply-in-place machinery already
built.

## Backlog (not yet started)

- **Intersections & roundabouts.** Junction nodes where roads meet
  mid-network, corner fillets, stop lines. Biggest missing capability
  overall. Roundabout variants to support, in roughly increasing order of
  complexity:
  - **Single-lane roundabouts** - standard geometry for low-capacity
    intersections.
  - **Multi-lane, concentric standard** - the classic multi-lane layout,
    concentric rings with normal (non-spiral) lane markings.
  - **Multi-lane, concentric standard with turbo markings** - same
    concentric geometry, but with spiral/turbo-style lane-guidance
    markings painted on top to guide lane changes on approach.
  - **True turbo roundabouts** - spiral geometry with physical or marked
    lane dividers between rings, not just concentric circles (the
    Netherlands-style layout designed to prevent side-by-side lane
    changes entirely).
- **Lane connector (CS2-style).** Per-lane graph at junctions; drag
  connections between incoming/outgoing lanes; markings re-render from the
  connection graph.
- **Traffic Light API (mock).** Reserve an API surface for a future plugin
  to specify signal phases down to a per-lane basis. Shares the per-lane
  graph model with the lane connector — design together.
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
