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

## Next up — needs a decision or real design work

**"Edit Road Segment" — a genuinely new feature, not yet built.** The pie
menu's "Edit on Road Builder" (renamed this round, was "Edit Road Segment")
opens today's full designer. The user's *actual* "Edit Road Segment" ask is
a different, deeper thing entirely - shown by a second-level hover menu with
its own options:
- **Add Bus Bay**: pick it, then click directly on a Sidewalk/Parking part
  in the 3D viewport to designate that spot as a bus stop - a real in-world
  point-and-click placement flow, not a UI-only toggle.
- **Edit Lane Markings**: pick a marking and change its type via numpad/
  number keys (1/2/3/4) instead of a dropdown; a **"stretch" interaction**
  where dragging a marking's end (Studio-resize-handle style) extends it
  and its sibling lanes' markings together in that segment, i.e. lengthens
  the marking for a run of lanes at once.
- Both of the above are meant to be reachable through their own small
  hover-circle-style menu (same "pills around a point" pattern as the pie
  menu, not a literal circle).

This needs its own design pass before writing code: the marking "stretch"
in particular means real drag-resize handles in the 3D viewport (adorner-
style, like Studio's own resize handles) plus a rule for how "siblings in
that segment" is defined and how the extended length is stored/rendered -
none of which exists in `Mesh/Markings.lua` today (markings are computed
per-segment as one continuous run already, so "stretching" would mean
something like a *partial-length* override on top of that, a new concept).
Attempting this alongside everything else already in this round risked
shipping something as unreliable as the first drag-and-drop attempt was;
it's called out here specifically so it isn't quietly dropped.

**Custom region profiles.** The user wants to create their own region
presets (not just pick from UK/HK/SG/EU/US/JP/AU). `RegionStyles.RegionStyle`
has ~25 fields (drive side, six component widths, curb height, three
marking specs, marking width/dash length/gap, white/yellow colours, max
superelevation + design speed, six material colours, `BayColor`) - building
a full editor for it is comparable in size to the `RoadProfile` editor
(`RoadDesigner.lua`) that took a full round on its own. The shape of the
work: a `RegionStyles.Serialize`/`Deserialize` pair (mirroring
`RoadProfile.lua`'s), a `Settings.UserRegions` slot (mirroring
`UserProfiles`), a small library layer (mirroring `RoadLibrary.lua`), and
an editor UI (mirroring `RoadDesigner`/`ProfileFields`, but for region
fields instead of lane components). Reasonable to tackle as its own round;
flagging rather than shipping a partial version that only exposes a few of
the ~25 fields.

**Road library icons — CS2-style thumbnails ARE feasible, not ruled out.**
The user asked whether matching CS2's per-road rendered cross-section
thumbnails needs "a render algorithm." It doesn't need an external one:
Roblox's `ViewportFrame` renders a live 3D scene into a 2D UI panel, so each
`RoadLibraryList` row could hold a small `ViewportFrame` with a simplified,
flat (non-curved) extrusion of that road's cross-section and its own
`Camera`, built via a cut-down version of `Mesh/RoadBuilder.lua`'s
extrusion logic. Not started - the current library rows are plain text -
but confirmed buildable rather than needing a "render algorithm" problem
solved first. Main cost is per-row `ViewportFrame` + model instance
overhead if the library grows long (would want to reuse/pool instances
rather than one permanently-live `ViewportFrame` per row).

## Recently shipped: real fixes from Studio testing (round after the pie menu)

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
  users expect it; say the word if it should go.
- **Pie menu rename**: the existing "open the full designer" action is now
  labelled "Edit on Road Builder" - "Edit Road Segment" is reserved for the
  new, not-yet-built feature described below.

## Recently shipped: pie menu (click a placed road)

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

**Not done yet** (still needs its own design pass, per the reasoning
below): hover-based (not click-based) triggering, the Road Editor's own
entry-point pie menu ("Edit existing" / "Create new empty" / "Place more"),
numeric-key shortcuts for marking selection, retractable side panels, and
the "stretch dash" marking style / bus stop placement mentioned alongside
"Edit Road Segment". These remain unscoped:

- **Hover** (rather than click-to-select) as the trigger needs new
  always-on mouse-hover raycast logic, distinct from the
  `Selection`-based approach `RoadEditSession` uses today - clicking was
  the tractable first step; hover is a separate follow-up.
- **Road Editor's own entry pie menu** and an empty-layout "Create new"
  (today's New still uses the 4-component starter template, not zero
  components) haven't been touched.
- **Numeric key shortcuts** and **retractable side panels** are UI polish
  on top of the current designer, not started.
- **"Stretch dash" marking style** isn't a `LineType` `Mesh/Markings.lua`
  understands yet.

## Recently shipped

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
  Modules palette - see the Backlog entry below, it's moving to the future
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
    snapping, geometry) live in the docked Studio sidebar panel
    (`SettingsGui` renders straight into the DockWidgetPluginGui).
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
  ramp preview UI - that's not implemented and would need new work Flagged
  here rather than guessed at and possibly built wrong.
- **"ProductIon" (settings page ask, unclear).** The request included "in
  the settings page we just add ProductIon" with no further context - not
  acted on this round since I couldn't confidently tell what was meant.
  Please clarify and it'll go in next round.

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
