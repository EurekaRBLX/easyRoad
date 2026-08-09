# EasyRoad — Known Issues

Confirmed bugs that are logged but not yet fixed. Not user-facing;
internal planning only. See `TODO.md` for planned new features and
`SHIPPED.md` for what's already been fixed/built.

- **Live roundabout appearance parity needs one more rebuilt-dist check.** The
  user confirmed that the first parity build still left concrete wedges and
  excess white slashes at ring mouths. The live root cause is now fixed
  headlessly: ring sidewalk/outer-edge Parts were opened by centre position, so
  boundary-straddling corners survived inside a sector. They are now clipped at
  the exact sector ray instead of kept whole or over-deleted. Keep this open
  until that rebuilt plugin is checked in Studio.
- **The `stress_us` four-approach roundabout preview has one deterministic mouth
  tear sample.** The full validator measures a 3.00-stud hole on leg 2,
  73.6 studs from the approach cut. The roundabout port and builder were
  untouched by the current structure/parallel work, so the case is carried
  explicitly in `validate.py` rather than attributed to those changes.
- **Curve rendering - deck strips reverted to centerline-anchored, still
  unverified live.** After `farEdgePad` was removed (previous round) and
  the Inside/Outside anchored-edge scheme was removed (this round, see
  `SHIPPED.md`), curved deck strips are back to the original
  centerline-symmetric construction: every strip is centered on the curve's
  true midpoint frame for its own interval, both edges padded via
  `curveMiterPad`. This is the simplest scheme in the codebase's history
  and can't drift by construction, but has not been checked in a live
  Studio session (this environment can't render Studio) - leaving this
  entry open until a user confirms curves render cleanly (no gaps, no
  sawtooth, no drift) with real testing.
- **Superelevation preview/final parity is fixed headlessly but still needs a
  rebuilt-dist Studio check.** The previous density-dependent box average and
  midpoint-roll hypothesis are no longer current: `Superelevation.BuildProfile`
  now owns one arc-length-weighted roll curve independent of mesh density,
  `RoadBuilder.StationPlanFor` supplies the final roll-refined stations to both
  preview and final emission, and changing-roll strips use exact station-edge
  wedges. Procedural structures consume the same profile. The Python 3D
  contract verifies zero outer-edge displacement and a maximum accepted merged
  facet error below 0.025 studs, but Roblox rendering and live rebuild parity
  remain unverified until the rebuilt plugin is exercised in Studio.
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
