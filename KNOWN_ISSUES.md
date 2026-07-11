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
- **"Superelevation triggers elevation not working" - reported live, not
  yet root-caused.** User report: toggling/using Superelevation (banking)
  seems to make the Elevation control stop having an effect on placed
  roads. Investigated without a live Studio repro and could not confirm a
  mechanism: `Superelevation.RollAt` only rotates the cross-section frame
  about the tangent (`PolyCurve.FrameAt`'s `CFrame.Angles(0, 0, roll)`
  multiply) and never touches the centerline position itself, so banking
  shouldn't be able to move a road's height; `createRoadSession.lua`'s
  `pickPoint`/mouse-move handler add the current `elevation` value to every
  placed point regardless of `SuperelevationMode`; toggling the banking
  checkbox (`BuildBar.lua`) only calls `OnSettingsChanged` (persist +
  `updateUI`), which doesn't touch or reset the session's `elevation`
  state. Did find and fix one real, related bug while looking (see
  `SHIPPED.md`): `BuildBar.lua` had two different rows both writing to
  `children.Transition` (the "Widen to" dropdown and the superelevation
  "Transition (m)" slider), so enabling banking silently dropped the
  Widen-to row from the panel - fixed by renaming the second to
  `children.BankTransition`. Not confirmed this was the actual bug the
  user saw. Revisit with specifics: does the *committed* road sit flat
  regardless of the Elevation field's value, or only the live preview; does
  it happen with Superelevation on, or specifically when toggling it
  off/on mid-placement; does R/F still nudge the number in the panel.
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
