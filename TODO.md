# EasyRoad — Backlog

Working notes on what's shipped, what's known-broken, and what's next.
Not user-facing; internal planning only.

## Known bugs (logged, not top priority right now)

- **Superelevation / curve algorithm inconsistency.** Reference screenshots
  from the `easyRoad 2` environment show a banked curve and an unbanked
  curve of otherwise-similar geometry looking inconsistent — banking
  doesn't appear to apply uniformly across equivalent curves. Needs
  investigation into `Geometry/Superelevation.lua` (`RollAt`, `SmoothRolls`)
  and how `Mesh/RoadBuilder.lua` samples roll per station — likely an issue
  in how curvature is sampled per-station vs. how the runoff taper
  interacts with short/long segments.
- **Narrowing (transition) lane algorithm still produces bad geometry.**
  Even after the "taper at the end of the segment" + z-fighting epsilon
  fixes, a tapering road can still show corrupted-looking shading on the
  transition zone. Needs a fresh look at `RoadBuilder.Build`'s
  `transitionAlpha` / adaptive station stepping interaction — possibly the
  taper zone's station density isn't fine enough, or strip mitering breaks
  down when component count differs across the taper.

## Recently shipped

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
  `UI/ProfileFields.lua` the shared kerb/colour/dash rows. Not yet done:
  true drag-and-drop (insertion is click-based), and the build HUD's
  "Adjust Widths" section hasn't been replaced by a strip yet.
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

## Next up — needs a decision

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
inspector panel — both reuse the same Apply-in-place machinery just added.

## Backlog (not yet started)

- **Intersections & roundabouts.** Junction nodes where roads meet
  mid-network, corner fillets, stop lines. Turbo and concentric roundabout
  layouts (UK/HK). Biggest missing capability overall.
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
- **Full CS2-style module-palette UI redesign** (icon-tile drag/drop,
  matching the `easyRoad 2` reference screenshots). Explicitly deferred —
  "stick with current UI for developing's sake" — revisit once the core
  feature set stabilizes.

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
