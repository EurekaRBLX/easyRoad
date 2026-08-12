# EasyRoad — Known Issues

Confirmed bugs that are logged but not yet fixed. Not user-facing;
internal planning only. See `TODO.md` for planned new features and
`SHIPPED.md` for what's already been fixed/built.

- **Live roundabout appearance parity needs one more rebuilt-dist check.** The
  first rebuilt parity attempt still left concrete wedges at ring mouths.
  Headlessly, every arm sidewalk is now an exact station-quad surface and the
  ring footway is subtracted only by actual arm, apron, and splitter footprints.
  The splitter's final frontage keeps a flat GoreApron underlay and restores
  raised concrete only outside a circumscribed kerb-disc cutter, reconnecting
  the median kerb without restoring the two triangles that chorded across the
  circulating lanes. Arms, markings, the approach cut, the splitter apron, and
  the ring share one datum; exact arm roadway footprints are subtracted from the
  ring roadway so only one coplanar surface owner remains. Full parity,
  including `stress_us`, passes with all 25 injected defects caught. Keep this
  open only until the rebuilt plugin is visually checked in Studio.
- **Exact curved surfaces and canonical superelevation need rebuilt-dist Studio
  confirmation.** Every non-straight surface interval now uses cached start/end
  station-corner quads, replacing padded midpoint rectangles and the alternating
  0.004-stud deck drop while preserving transition anchors and profile offsets.
  `Superelevation.BuildProfile` still owns one arc-length-weighted roll curve,
  `RoadBuilder.StationPlanFor` supplies the roll-refined stations to preview and
  final emission, and procedural structures consume the same profile. Headless
  contracts cover the shared-edge geometry and outer-edge displacement, but not
  Roblox Wedge rendering, collision feel, or z-fighting. Keep this open until
  the rebuilt plugin is driven over ordinary chained bends and every roundabout
  mouth in Studio.
- **Hover-trap click-swallowing keeps recurring - three separate instances
  now, all fixed as found, but treat any future report of "clicking in the
  viewport does nothing" as this bug family first.** (1) The pie menu's
  original full-screen hover-tracking wrapper. (2) The two-panel Road Tools
  HUD's oversized shared wrapper. (3) `PillButton`s that unmount mid-hover
  when the pie menu switches modes (`MouseLeave` never fires for a
  destroyed element) - this one specifically broke bus bay dragging
  entirely. All three are the same root shape: `uiState.Hovered` gets set
  `true` by something that then goes away without a matching `false`. Any
  new hover-tracked UI needs to be checked against this specifically:
  either its bounding box must exactly match its visible interactive
  footprint (not a wrapper around several - #1, #2), or its hover state
  must be reset on whatever transition could cause it to unmount while
  still hovered (#3).
- **Bus bay's displaced pavement doesn't drag its own kerb-restriction line
  marking along with it.** `BuildWithBay`'s nearside-pavement overlay (see
  `SHIPPED.md`) correctly moves the physical sidewalk/verge Parts outward
  over the bay's footprint, but `Markings.Compute` (called once per
  RoadBuilder.Build slice) still computes any kerb-restriction line
  (single/double yellow no-stopping line) from the *unmodified* profile's
  component offsets, since the exclusion only affects which Parts get
  built, not the marking pass. If a road's `KerbRestriction` is set, its
  line will stay at the original kerb position through the bay's range
  instead of following the bulge outward. Scoped out of this round's fix
  (which focused on eliminating the pavement overlap and the drag
  reliability bug) - would need the marking pass to accept the same
  per-station offset override the pavement overlay uses.
- **Bus-bay overlays are intentionally suppressed on a road that is also
  widening or narrowing.** A profile transition can insert matched zero-width
  components and move the kerb offset, while the current bay overlay owns one
  constant start-profile cross-section. `BuildWithBay` therefore emits the
  complete transition road without the bay rather than risk excluding the wrong
  component or producing pavement gaps/overlaps. Supporting the combination
  needs a per-station bay/kerb profile and dedicated visual coverage.
