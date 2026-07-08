# EasyRoad — To Do (New Features)

Planned/requested work not yet built, roughly ordered by how developed the
plan is. Not user-facing; internal planning only. See `SHIPPED.md` for
what's already built and `KNOWN_ISSUES.md` for confirmed bugs.

## Next up — needs a decision or real design work

**CS2-style road-tool UI polish, part 2 - icon-based category tabs, still
queued.** Left-aligning Tool Mode and turning Road Library into a real grid
both shipped this round (see `SHIPPED.md`); still outstanding from the same
queued request:
- **Category tabs (Streets/Avenues/Highways/Paths/Custom) currently
  text-truncate** ("Aven...", "Highw...", "Custo..." per the user's
  screenshot) - replace the text labels with icons, using the same
  45°-tilted `ViewportFrame` camera technique already used for
  `RoadThumbnail`/`ProfileThumbnail`.
- **Needs a small "icon library" of purpose-built profiles/scenes purely
  for generating good category icons**, not real placeable roads: a 2-lane
  street with a dashed centerline, a 2-lane avenue (collector/arterial
  style), a highway with a gantry (gantries aren't modeled anywhere yet -
  new geometry), and a roundabout icon similar to CS2's (roundabouts
  aren't an implemented feature at all yet, so this would be purely
  cosmetic icon geometry, not real roundabout support).

**Marking "stretch" interaction — still not built (the one piece of "Edit
Road Segment" deliberately left out of that round).** Dragging a lane
marking's end (Studio-resize-handle style) to extend it and its sibling
lanes' markings together across a run, i.e. a *partial-length* override on
top of `Mesh/Markings.lua`'s per-segment-continuous-run computation. This
needs real drag-resize handles in the 3D viewport (adorner-style, like
Studio's own resize handles) plus a rule for how "siblings in that segment"
is defined and how the extended length is stored/rendered - none of which
exists today. The rest of "Edit Road Segment" (bus stop / bus bay
click-placement, numpad marking shortcut, the hover submenu itself) already
shipped - see `SHIPPED.md`. Flagging this specifically so it isn't quietly
dropped.

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
- **Bus stop icon reserved, unused.** `Icons.BusStop`
  (`rbxassetid://97224093362859`) is stashed in `UI/Icons.lua` for a future
  bus-stop decoration/marking; nothing renders it yet.
- **Parallel mode.** CS2-style "place a mirrored road alongside an existing
  one, offset by N studs" workflow. Not started.
- **True wedge-trapezoid taper for widen/narrow transitions.** Each transition
  strip is still a constant-width rectangular `Part` for its whole length, so
  a lane's width change between one station and the next shows up as a small
  step on the non-anchor edge rather than a continuous taper - a stairstep
  made of straight segments, most visible on a short/steep taper. This round
  smoothed the taper's alpha curve (no more sharp kink where the taper zone
  begins) and tightened station spacing to keep each step small, which should
  read as clean in most cases, but the fully correct fix is a real trapezoid:
  build each transitioning strip as a rectangle (at the smaller of its two
  end widths) plus a triangular `FillTriangle` wedge covering the width
  delta, tapering to a point exactly at whichever station has the smaller
  width - same machinery already built for curve joints this round, just
  driven by a width delta between stations instead of a curvature-driven
  lateral gap. Worth doing if the smoothed/finer-stepped version still looks
  chunky on real in-Studio testing.
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
