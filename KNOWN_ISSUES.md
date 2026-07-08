# EasyRoad — Known Issues

Confirmed bugs that are logged but not yet fixed. Not user-facing;
internal planning only. See `TODO.md` for planned new features and
`SHIPPED.md` for what's already been fixed/built.

- **Narrowing (transition) lane algorithm still produces bad geometry.**
  Even after the "taper at the end of the segment" + z-fighting epsilon
  fixes, a tapering road can still show corrupted-looking shading on the
  transition zone. Needs a fresh look at `RoadBuilder.Build`'s
  `transitionAlpha` / adaptive station stepping interaction — possibly the
  taper zone's station density isn't fine enough, or strip mitering breaks
  down when component count differs across the taper. The curve-miter fix
  (see `SHIPPED.md`, shared by every strip regardless of width
  interpolation) may already help here since transition strips go through
  the same code path, but wasn't specifically targeted or verified against
  this symptom — re-check before closing this out.
