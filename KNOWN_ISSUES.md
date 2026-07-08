# EasyRoad — Known Issues

Confirmed bugs that are logged but not yet fixed. Not user-facing;
internal planning only. See `TODO.md` for planned new features and
`SHIPPED.md` for what's already been fixed/built.

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
- **Superelevation (banking) on curves may look worse at the final build's
  finer station spacing than in the coarser placement preview - reported,
  not yet root-caused.** A user compared a live placement preview against
  the same road placed for real and said the preview looked smoother; a
  follow-up screenshot of the *actual* final geometry (not just another
  preview frame) was requested to confirm before diagnosing further, but
  the conversation moved on to other bugs before one was shared. Leading
  hypothesis: each deck strip is rolled (banked) using only its own
  midpoint's roll angle, with no accommodation for the roll *changing*
  between adjacent stations - on a superelevated curve this could show up
  as a small seam at every station boundary, and finer final-build spacing
  would mean *more* boundaries (more visible seams) rather than fewer, even
  though each individual seam should be smaller. Unconfirmed - revisit with
  a real "after placement" screenshot.
- **Road placement click-swallowing - fixed this round, but this is the
  second time a variant of this exact bug has shipped** (see the pie-menu
  full-screen hover trap, and now the two-panel Road Tools HUD's oversized
  shared wrapper - both in `SHIPPED.md`). Any future HUD layout change
  needs its hover-tracking scope checked explicitly against the *visible*
  footprint of each panel, not the bounding box of a Frame that merely
  contains them - the two aren't always the same, especially once a layout
  has panels of different heights/widths grouped under one wrapper.
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
