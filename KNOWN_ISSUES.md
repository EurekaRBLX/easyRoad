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
  sawtooth, no drift) with real testing. If gaps are still visible, the
  likely next step is the fully exact wedge-trapezoid taper already
  specified in `TODO.md`, since each transition strip is still a
  constant-width rectangle for its own length.
- **Road placement click-swallowing - fixed this round, but this is the
  second time a variant of this exact bug has shipped** (see the pie-menu
  full-screen hover trap, and now the two-panel Road Tools HUD's oversized
  shared wrapper - both in `SHIPPED.md`). Any future HUD layout change
  needs its hover-tracking scope checked explicitly against the *visible*
  footprint of each panel, not the bounding box of a Frame that merely
  contains them - the two aren't always the same, especially once a layout
  has panels of different heights/widths grouped under one wrapper.
