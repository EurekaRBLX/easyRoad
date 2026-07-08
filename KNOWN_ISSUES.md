# EasyRoad — Known Issues

Confirmed bugs that are logged but not yet fixed. Not user-facing;
internal planning only. See `TODO.md` for planned new features and
`SHIPPED.md` for what's already been fixed/built.

- **Narrowing (transition) lane algorithm - re-check after this round's
  smoothing fix.** User-reported (with a screenshot) that a widen/narrow
  transition still looked wrong - described as looking like "a derivative"
  rather than a smooth or cleanly straight taper. Root cause found and
  fixed this round: `transitionAlpha` was a flat 0 followed by a linear
  ramp, a real slope discontinuity right where the taper zone begins, plus
  a flat 4-stud station cap regardless of how steep the taper was (see
  `SHIPPED.md`). Not verified against the original screenshot in a live
  Studio session (this environment can't render Studio), so leaving this
  entry open until confirmed fixed - if it still looks off, the likely next
  step is the fully exact wedge-trapezoid taper already specified in
  `TODO.md`, since each strip is still a constant-width rectangle for its
  own length even after the smoothing/finer-stepping fix.
