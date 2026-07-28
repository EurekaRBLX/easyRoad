# EasyRoad — handoff

Written for whoever picks this up next. `SHIPPED.md` is the full history
(most recent first), `TODO.md` the backlog, `KNOWN_ISSUES.md` confirmed bugs.
This file is the short version of where the most recent intersection and
roundabout work stands.

## Ground rules for this repo

- Work directly on `main`. Rebuild `dist/EasyRoad.rbxmx` with
  `python3 tools/build_rbxmx.py` in the **same commit** as any `src/` change —
  the user installs that file, so a stale dist means they test old code.
- `stylua src/ && stylua --check src/` before committing. Note the repo is not
  globally stylua-clean under the currently installed version; only keep the
  files you touch clean.
- Commit trailer, exactly:
  `Co-Authored-By: Gameson <79436209+gamesonrblx@users.noreply.github.com>`
  No `Claude-Session:` trailer, no model identifier anywhere in commits, PRs,
  code or artifacts.
- Log every round in `SHIPPED.md` (newest at top) and update `TODO.md`.

## Latest: true X intersections and snap feedback

The user reported two related placement failures: snapping did not feel
visible, and drawing one road through another with both ends beyond the
crossing produced overlapping roads instead of an X junction.

The shipped path is now:

- `Geometry/CurveIntersections.lua` detects real line/Bezier crossings in the
  ground plane and reports vertical separation.
- The final point magnetically previews on endpoints, junctions, roundabouts,
  and splittable road centrelines. Blue means snapped, green means a true
  interior X will be created, and red explains why a detected crossing cannot
  be split.
- `RoadSplit.SplitMany` cuts the new and existing road(s) around caller-owned
  shared node ids. One placement can cross multiple roads and is one Undo
  recording.
- `JunctionBuilder.TrimApproaches` trims both ends of a between-junctions
  piece from the same preserved source segment, preventing one node rebuild
  from undoing the other end's trim.
- A vertical gap greater than `max(2, RoadThicknessStuds * 2)` is treated as
  grade separation. Near-parallel contacts are not intersections.

Still deliberately blocked, with red feedback: widening/narrowing roads, bus
bays, missing editable curve data, and cuts that would leave a piece shorter
than four studs. The first live Studio check should cover a straight X, a
curve/straight X, multiple crossings in one placement, an elevated overpass,
Undo, and one red blocked case.

## There is no Luau runtime or typechecker here

This is the single biggest hazard, and it has already cost a shipped crash.
`stylua` only proves the file **parses**. Nothing checks that an identifier
exists. In `3fd2066` an edit landed in the wrong function and left
`ringComponents` referencing `spokeProfile` — a nil global — so **every**
`Make Roundabout` threw on its first line and built nothing. Fixed in
`152b233`.

Two lessons worth keeping:

1. When patching by matched text, anchor on something unique. That bug came
   from a `replace(..., 1)` whose anchor line appears in two functions and
   matched the wrong one first.
2. `tools/preview` did **not** catch it, and structurally cannot: it is a
   Python re-implementation of the geometry, not an execution of the Lua. It
   validates the algorithm, never that the code runs.

Closing this is the highest-value unbuilt item in `TODO.md`. Checked, not
assumed: GitHub and npm are blocked here (403) so the official `luau-analyze`
cannot be downloaded, but crates.io is reachable and `full_moon` parses Luau -
see TODO for the path. Note it needs scope awareness: the name in that crash
was a real parameter of a *different* function in the same file, so a
whole-file global scan would not have caught it.

## Is the preview actually the same algorithm?

Fair question, and it was asked. `tools/preview` is a hand-written Python
re-implementation of `RoundaboutBuilder.lua`, not an execution of it, so
"the preview says it is fine" on its own only means the preview agrees with
itself. Two checks exist:

- `check_parity.py` - every constant present on both sides must match. Caught
  real orphans the day it was written.
- `dump_compare.py` + the **Print geometry to Output** button on the Junction
  panel - compares BEHAVIOUR. The plugin side
  (`RoundaboutBuilder.DescribeJunction`) reuses `planMouth`, `splitBudgetFor`
  and `resolveSplits`, so it cannot drift into being a third implementation.
  Run both, diff the text.

Until that diff has actually been run on a live junction, treat preview results
as strong but unconfirmed.

## `tools/preview` — read its README first

`tools/preview/roundabout_preview.py` simulates the **parts `RoadBuilder`
actually emits** (rigid boxes per station interval, not idealised polygons)
and reports two things:

- **bare ground** — polar scan of the ring footprint, clustered by angle with
  a depth in studs; hairlines under `--hairline` (0.15) are reported, not failed
- **approach/arm seam** — sweeps the road's perpendicular either side of the
  cut and measures the cross-section step; 0.00 is flush

```sh
cd tools/preview && python3 roundabout_preview.py            # uk4 uk3 us4
python3 roundabout_preview.py stress stress_us --no-render
```

Exits non-zero on visible bare ground, so it works as a check. **Run it after
any `RoundaboutBuilder` change.** All six cases currently pass.

It models footprints in plan only — not heights, render order, dash phase or
z-fighting. Those remain Studio-only checks.

## Roundabout geometry, as it now stands

The ring is one continuous annulus, never sliced. Each approach is trimmed
back and split into one-way arms that merge **tangentially onto the ring's
rim**: an arm's centreline ends at the radius that puts its outer roadway edge
exactly on the ring's kerb, carrying the ring's own tangent, so kerb, pavement
and carriageway all flow in rather than butting into it.

Things that are settled, and why — don't re-litigate these blind:

- **Circulation sign.** `circleSegments` uses `sign = if driveOnLeft then 1`.
  Increasing angle runs +X toward +Z, which viewed from above is clockwise, so
  left-hand drive is `+1`. Everything downstream reads handedness off this:
  pavement side in `ringComponents`/`armProfileFor`, island side in
  `ringInnerHalfWidthM`, `flow` in `buildMouth`. It was inverted before
  `cfe4ca9` and was internally consistent, which is exactly why it survived so
  long — nothing looked wrong until the arms encoded direction.
- **Arms are aligned to the approach's own roadway edges**, not sized from
  their own half-width plus a splitter. Sizing them the latter way makes the
  pair wider than the road and steps the whole cross-section at the cut.
- **Lanes split by `Direction`**, not by halving the count. Direction is
  relative to the curve's travel, so the inbound sign flips with `atStart`.
  One-way approaches get a single arm with pavements on both sides and no
  splitter island.
- **The mouth sector is inset, never expanded.** Deleting less ring pavement
  than the arms cover is invisible; deleting more is bare ground in a ring of
  pavement.
- **Cubic handle is 0.30.** Both ends fight: a long handle walks the ring-end
  control point across the gore until entry and exit close on each other, a
  short one kinks the arm into a hairpin. 0.30 was measured, not chosen.

## Known limits, honestly stated

- **Crowded rings.** 5+ legs, or wide approaches on a ~40-stud radius, squeeze
  the split until the arms run up against each other partway along. Nothing
  overlaps; the mouth just reads as one wide opening and the island pinches.
  The real fix is auto-sizing a minimum radius from entry width and leg count.
- **Splitter waist.** A 4-leg ring still dips ~0.7 studs partway along.
  Cosmetic.
- **Hairlines at the island rim.** ~0.05 studs where the ring's innermost
  strips chord across the island circle. Unfixable by padding without
  overlapping the island instead.
- **Nothing has been confirmed in Studio since the arm rewrite.** The last
  live signal was the crash. The geometry is verified headless only.

## Immediate next step

Have the user reinstall `dist/EasyRoad.rbxmx` and exercise the X-intersection
matrix above. Then place a roundabout among a few roads; that still needs the
first live look at the split-arm mouths. Everything after that is in
`TODO.md`.
