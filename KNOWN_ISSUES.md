# EasyRoad — Known Issues

Confirmed bugs that are logged but not yet fixed. Not user-facing;
internal planning only. See `TODO.md` for planned new features and
`SHIPPED.md` for what's already been fixed/built.

- **Narrowing (transition) lane algorithm - re-check after two rounds of
  fixes now.** User-reported (with screenshots, twice) that a widen/narrow
  transition looked wrong. Round 1 fixed a real slope discontinuity in
  `transitionAlpha` (flat-then-linear-ramp kink) and tightened station
  spacing on steep tapers. Round 2 found a second, likely bigger cause:
  `farEdgePad` (a same-round addition meant to widen deck strips on their
  far edge to avoid needing curve-joint wedges) reused the `curveMiterPad`
  length-defect formula reinterpreted as a *width* pad - a formula derived
  specifically for length padding, not width, and it visibly over-widened
  strips into a sawtooth/serrated edge instead of fixing anything ("with
  the new road generation algorithm we are probably worse off" - the
  user's words). `farEdgePad` has been removed entirely; strips are back to
  their plain exact anchored width, with wedges only at joints whose real
  residual gap exceeds `WEDGE_GAP_THRESHOLD_STUDS` (unaffected by the
  removal, since it measures the raw gap, not the padding). Not verified
  in a live Studio session (this environment can't render Studio) - leaving
  this entry open until confirmed. If gaps (as opposed to serration) are
  still visible after this fix, the likely next step is the fully exact
  wedge-trapezoid taper already specified in `TODO.md`, since each transition
  strip is still a constant-width rectangle for its own length.
