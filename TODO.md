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

**Select a placed road → contextual edit panel.** Right now a road is
frozen the moment it's placed: no way to add a bus/taxi bay, flip the kerb
indent, or retouch a lane width on something already in the world — you'd
have to delete and re-place it. The user has asked for exactly this
workflow ("this is for when a user press on a road segment where they will
see option to do so") for both Bay and kerb-indent. This requires:
- Click-detection on placed `Road` models in the viewport (outside of an
  active build session)
- Per-instance profile storage on the placed model (today only
  `RW_ProfileStartId` / `RW_ProfileEndId` attributes are stored — the full
  component list with any live edits needs to travel with the instance,
  not just a profile-library reference)
- A contextual panel (reuse the glass HUD style) that edits that instance
  and rebuilds just that model
- This is also the natural foundation for "editing already-placed roads"
  in general (drag endpoints, re-profile), and for future lane-connector /
  junction editing interactions.

This is the recommended next step — it's smaller than full junctions,
unlocks two already-requested features, and closes a real workflow gap.
Alternative: go straight to the junction/node foundation (see below),
which is the structurally biggest missing capability but doesn't depend on
selection.

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
