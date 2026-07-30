# EasyRoad — the roundabout, end to end

Written for whoever picks this up next, human or agent. `SHIPPED.md` has the
chronological history and `TODO.md` the live backlog; this file is the standing
picture: what the roundabout is meant to be, how it is built, what has been
settled and must not be re-litigated blind, and what is still wrong.

The roundabout has been the single most expensive part of this project. Several
rounds shipped geometry that looked right in theory and cursed in Studio. Almost
everything below was paid for that way — please read it before changing
`Mesh/RoundaboutBuilder.lua`.

---

## 1. The vision

A roundabout is **one continuous circulating ring** with **split one-way arms**
merging tangentially onto its rim.

- The ring is never sliced. It is a single closed curve built by
  `RoadBuilder.Build`, exactly like any other road.
- Each approach is trimmed back and split into an **entry arm** and an **exit
  arm**, each a genuine one-way road with its own profile.
- An arm's centreline ends at the radius that puts its outer roadway edge
  exactly on the ring's kerb, carrying the ring's own tangent — so kerb,
  pavement and carriageway flow *into* the ring rather than butting against it.
- The wedge between an entry and its exit is the **gore**, filled by a raised
  **splitter island**.
- The hole inside the ring is the **centre island**.

The reference for this shape is the user's own M20 J4 photograph plus the
CivicArc / RoadCreator sources vendored in `reference/` (read-only, MIT,
attributed — see `reference/roadcreator/README.md`).

---

## 2. The build pipeline

`RoundaboutBuilder.CreateAtJunction` (the junction→roundabout path) and
`RoundaboutBuilder.Create` (the standalone tool path) both run:

1. `circleSegments` → four cubic Béziers approximating a circle. **Not** an
   analytic circle: anything that assumes exact radius will drift.
2. `ringComponents` → the ring's profile (N circulating lanes + one pavement on
   the outward side).
3. `RoadBuilder.Build` → the ring's parts.
4. `buildIsland` → the centre island (see §3.6).
5. Per approach: `planMouth` → `trimSpoke` → `splitApproachLanes` →
   `armProfileFor` → `buildArm` ×2 → `buildSplitterIsland`.
6. `openRingPavement` → deletes the ring's own outer pavement inside each
   mouth's angular sector, so the mouth opens instead of being walled off.

Step 6 is the one that makes step 5 load-bearing: **the ring pavement is
deleted on the assumption the arms and splitter island replace it.** Anything
that shortens or skips the island leaves bare ground. That single coupling
caused the worst defect of this session (§4.1).

---

## 3. Settled decisions — do not re-litigate blind

Each of these was arrived at by measurement or by a live failure. Changing one
without reading its note will re-open a bug that has already been paid for.

### 3.1 Circulation sign
`circleSegments` uses `sign = if driveOnLeft then 1`. Increasing angle runs +X
toward +Z, which viewed from above is clockwise, so left-hand drive is `+1`.
Everything downstream reads handedness off this: pavement side in
`ringComponents` / `armProfileFor`, island side in `ringInnerHalfWidthM`,
`flow` in `buildMouth`. It was inverted before `cfe4ca9` and was *internally
consistent*, which is exactly why it survived so long — nothing looked wrong
until the arms encoded direction.

### 3.2 Arms are aligned to the approach's own roadway edges
Not sized from their own half-width plus a splitter. Sizing them the latter way
makes the pair wider than the road and steps the whole cross-section at the cut.

### 3.3 Lanes split by `Direction`, not by halving the count
`Direction` is relative to the curve's own travel, so the inbound sign flips
with `atStart` (`inboundSign = if atStart then -1 else 1`). Halving breaks the
moment a road is asymmetric: a 3/1 dual carriageway gets two 2-lane arms that
line up with neither side, and a one-way road gets an entry *and* an exit where
only one exists. One-way approaches get a single arm with pavements on both
sides and no splitter island.

### 3.4 The mouth sector is inset, never expanded
Deleting less ring pavement than the arms cover is invisible. Deleting more is
bare ground in a ring of pavement.

### 3.5 `ARM_HANDLE = 0.30`
Both ends fight: a long handle walks the ring-end control point across the gore
until entry and exit close on each other; a short one kinks the arm into a
hairpin. 0.30 was measured, not chosen.

### 3.6 The centre island matches the ring's polygon above a measured threshold
The ring is emitted as rigid strips, so its inner edge is a **polygon**
inscribed in a circle. A `Cylinder` island of the matching radius overlaps it in
a scallop all the way round. `buildIsland` therefore fans the island onto the
ring's **own station angles**, obtained from `RoadBuilder.StationsFor` — never
re-derived, because the station rule is adaptive and a second copy would agree
only until someone retuned `CHORD_TOLERANCE`.

The cylinder is kept when the scallop is under `ISLAND_FAN_MIN_SCALLOP_STUDS`
(0.02). The test is on the **scallop**, not the radius, because station count
does not track radius the way one would guess — it is set from chord tolerance
against the ring's own half-width, so a *small* ring with a wide carriageway
gets very fine stations. A radius threshold would have spent 300+ Parts
smoothing rings whose scallop was already a thousandth of a stud.

### 3.7 A mouth has TWO fills, not one: flat apron, then raised island
The gore — the wedge between a diverging entry and exit — is **never left open**.
It carries flat asphalt at deck level from the cut until it has opened wide
enough to be a refuge, and a raised kerbed island from there in to the ring.

    cut ............ 2 m wide ............ ring kerb
    |<- flat apron ->|<- raised splitter island ->|

Three earlier versions all asked "raised island, or nothing?", and every answer
to that question is wrong, because near the cut that wedge is not a median at
all — it is the approach's own carriageway fanning out into the mouth. All three
shipped and all three were reported:

1. island filled the whole gore → a raised strip down an approach with no
   median ("there is median when there is no median for the type of road used")
2. island started at the width crossing → the same, thinner: a raised sliver
   ~17 studs down the approach
3. island started at the ring's outer edge → the wedge in front of it became
   bare ground, reported as the mouth indentation

The width test now chooses **which surface**, not whether there is one, and the
two questions it was being asked at once are separated:

- `MEDIAN_AT_CUT_M = 0.5` — does this approach arrive with a median? Measured at
  the cut, where a road without one is zero by construction. If it does, the
  island continues it straight from the cut and no apron is laid.
- `ISLAND_MIN_WIDTH_M = 2.0` — on an approach with no median, how wide must the
  gore open before the splitter earns a kerb? 2 m is the usual minimum for a
  pedestrian refuge. At the old 0.5 m the island began as a knife edge tens of
  studs out, which is defect 2 above.

This also retires the "start at the ring's outer edge" rule that used to live
here. Its job was to cover the pavement `openRingPavement` deletes across the
mouth sector (§4.1); the apron covers that band now, and covers it with the
right material — a mouth is precisely where the circulatory pavement ring is
interrupted by carriageway.

---

## 4. Defects fixed, with their measurements

### 4.1 Bare-ground band at R=34–36
Two faults, both introduced by the `MIN_GORE_WIDTH_M` change itself:

1. Leading samples were dropped from a **fixed grid** with `continue`, while the
   same loop also breaks at the ring kerb — so on rings whose arms converge
   early the skipped samples were consumed and the break fired before enough
   rungs accumulated. Fixed by **re-parameterising** the rungs.
2. The island could start **inside** the ring's outer edge. At R=35 the gore
   reached radius 42.3 against an outer edge of 45.1, and **all 150**
   bare-ground samples sat in the 2.8 studs between.

Bare-ground samples, 3-leg 1+1: 172/250 → 1/2, at 0.13–0.21 studs against a
0.084-stud sample pitch.

**A hypothesis that was wrong and is worth not repeating:** that
`openRingPavement` deleted parts by their *centre* while their bodies extended
past the sector edge. The probe disproved it outright — all 250 holes sat
*inside* the sectors, and the sectors are identical at R=33 (clean) and R=35
(broken). Deletion was never involved.

### 4.2 Phantom median on approaches with no median
The gore is measured between the two arms' **inner roadway edges**. On a road
with a median those start that median's width apart; on one without, they start
touching. Filling from the cut regardless put a raised strip down the middle of
a road that has none. See §3.7 for the rule that resolves it.

### 4.3 Approach roads not detected
`collectNearbyRoads` measured each candidate by the smaller of its two
**endpoint** distances, so any road whose closest point is mid-span was silently
dropped. Now samples the curve for the true nearest approach. **This is only
half the problem — see §5.1.**

### 4.4 The mouth indentation, and the sign error that hid it
The V-notch (design in §3.7). What made it survive three rounds is worth more
than the fix: **the check that was supposed to catch it was scanning the wrong
ground.**

`scan_mouths` walked `cut - inward * at` while `inward` points from the cut
toward the centre, so `at` marched *outward down the plain approach road*
instead of inward into the mouth. Every "no bare ground inside the mouth
envelope" it had ever printed was measured over the one stretch of road nobody
was worried about — the same blind spot the function's own docstring was written
to close, reintroduced one line below the paragraph describing it.

Correcting one sign failed three defects at once on the default cases:

| case | GORE | HOLE | OVERHANG |
|---|---|---|---|
| uk4 | 32 samples, worst 7.67 studs | 56, worst 3.67 | 4, worst 8.67 |
| uk3 | 102 samples, worst 15.00 studs | — | 3, worst 15.67 |
| us4 | 32 samples, worst 7.67 studs | 48, worst 3.00 | 4, worst 8.67 |

Open gore also stopped being excused as by-design, since under the two-fill rule
no part of a mouth is ever legitimately bare, and `report()` started folding
mouth findings into its pass/fail result — it had been printing them and then
returning clean.

Two further faults in the check surfaced while verifying the fix, both of which
would have made the *next* result untrustworthy:

- **The envelope reached into the neighbouring leg.** Taking the outermost
  covered samples as the mouth's edges assumes nothing else is within the
  sweep's 70-stud span. On a R=45 ring with legs 65° apart it hit the next road
  and called the 44 studs of grass between them a tear inside the mouth. It now
  walks outward from the centreline and stops at the first bare run wider than
  `max_skip`.
- **`min_gap` was below the sample pitch,** so one dark sample read as a hole:
  a 0.33-stud "gore" at R=10, R=15 and on a 3/1 approach, exactly one pitch
  wide, all gone at four times the density. `min_gap` is now floored at two
  pitches.

After the fix: **zero bare ground and zero overhang across 24 cases** — 16 radii
from R=10 to R=70 on a 3-leg 1+1, plus 5-leg, 4-leg 2+2, a 3/1 approach, two
median profiles, pavement off, island off, and the 65° skew. The R=34–38 band
of §4.1 stays clean.

The check was verified to still have teeth by stripping the apron back out of a
built scene — that *is* the pre-fix geometry — and confirming it fails: uk4 back
to 20 GORE / 44 HOLE, uk3 to 66 GORE. A fix that passes by blinding its own test
is the one failure mode this repo cannot afford again.

---

## 5. Open problems

### 5.1 Roads passing *beside* the roundabout still are not connected
Detection is fixed; **handling is not.** `ConnectRoad` calls `ringSideIsStart`,
which picks whichever *end* of the road is nearer the centre, and skips the road
entirely when that is unreadable. A road that passes beside or through the
roundabout has both ends far away, so choosing an end is meaningless — it needs
**splitting at the nearest point**, the way `RoadSplit.SplitMany` already does
for X intersections. Until then a detected-but-unsplittable road does nothing,
which reads exactly like a detection failure.

### 5.2 ~~Small radius requests are silently inflated~~ — FIXED
The requested radius is now **built as asked**. `MinimumRadiusStuds` is advice,
shown in the panel before the click, never a clamp applied after it.

The clamp was wrong on the merits as well as the UX. Measured with it disabled,
the geometry is clean far below what it enforced:

    3-leg 1+1   minimum 27.5   clean at R = 10, 14, 18, 22, 26
    4-leg 2+2   minimum 70.5   clean at R = 10 .. 35

The formula is a conservative packing estimate, not a measured failure point.
Small rings do eventually crowd - the split gets squeezed until entry and exit
run up against each other and the splitter pinches - but that degrades
gradually and visibly, which the user can judge.

**Still open:** re-derive the minimum from where the geometry actually fails,
so the recommendation is worth following.

### 5.3b Optional pavement and optional island — SHIPPED
`RoundaboutSidewalk` and `RoundaboutIsland` on both `RegionStyle` (region
default, checkboxes in the region editor) and `JunctionData` (per-roundabout,
tri-state dropdowns in the junction panel). Optional, and nil reads as ENABLED,
so nothing built before them changes.

The subtle part is not the toggle, it is what the pavement width is used FOR.
Several radii are derived by subtracting it from the ring's outer edge, so
`ringSidewalkWidthM(style)` returns 0 when the pavement is off and every one of
those sites goes through it. Using the region's nominal width with no pavement
present would put the ring's kerb *inside* its own carriageway.

`ringComponents` returns early rather than inserting a zero-width Sidewalk: a
zero-width component is still emitted as a Part and still swept up by
`openRingPavement`'s name match.

Island off leaves the centre as open ground on purpose — the ring is a closed
annulus either way, so this is a landscaped centre the user fills, not a hole.
A flush drivable centre (mini-roundabout) is a different feature, not built.

### 5.3a Continuous vs SolidLanes — SHIPPED
`RegionStyle.RoundaboutMarkings` ("Continuous" | "Turbo") sets the regional
default; `JunctionData.RoundaboutMarkings` overrides it per roundabout. Both
optional, both nil-reads-as-Continuous, so every region and junction that
predates the field keeps its behaviour.

`SolidLanes` sets `RightBoundary = "Solid"` on every circulating lane but the
last, discouraging weaving on the ring. `Continuous` leaves the boundary on
"Auto", which resolves to the region's dashed lane line.

**This was briefly shipped with the value named "Turbo", which it is not** —
see 5.3c. Renamed before anyone could build against it. The last lane is
skipped deliberately: `RightBoundary` describes the gap to the component on its
right, and the last lane's neighbour is the pavement, whose edge line is the
region's business.

`JunctionInstance` validates the value against a local list rather than
importing `RegionStyles`' union — it is a leaf module everything else reads and
is worth keeping free of that dependency for one field. The two lists are kept
in step by hand.

### 5.3 Markings do not match the preview
The preview never ported `Mesh/Markings.lua`; it approximates it in ~30 lines.
**Do not "fix" this by replacing `Markings.lua` with the Python rule** — eleven
modules read its specs and the swap would delete the boundary dropdown, kerb
lines, restriction lines, dash overrides and the marking-stretch and
kerb-stretch features. The roundabout's ring and arm profiles are built *inline
with no marking specs*, so every gap falls through to region defaults tuned for
a straight road. Setting explicit specs on those two profiles is the fix, and it
is profile data, not engine code.

Requested on top of that: a **Turbo / Continuous** toggle in the roundabout
build panel, with a default in regional settings.

### 5.3c A real TURBO roundabout — NOT BUILT, but smaller than first thought

**Correcting an earlier entry in this file.** It claimed turbo needs a second
ring generator because "lane count and lane centres vary with angle". An aerial
of a real spiral-marked roundabout (Tollbar End, A46) shows otherwise: the
circulating **carriageway is a constant-width annulus**, exactly what is built
today. Only the LANE BOUNDARIES inside it spiral, migrating outward with angle
so the lane a driver entered is delivered to an exit.

So this is a markings feature after all — just not a solid/dashed flag. What it
needs is a lane boundary whose **radial offset is a function of angle**, moving
outward by roughly one lane width between consecutive mouths.

The primitive already exists. `Markings.MarkingLine` carries `OffsetStartM` and
`OffsetEndM` — a lateral offset that ramps along the curve — so a spiral is a
series of lines, one per arc between mouths, each ramping outward. Nothing in
`Markings.lua` has to change to express it.

What does have to be worked out:

- where each boundary starts and ends radially, given leg count and lane count
  (they must line up with an exit, not land mid-carriageway);
- the ring is ONE closed curve, so the lines have to be emitted per arc between
  mouths rather than once around, and the seams have to meet;
- what the innermost lane does when its boundary reaches the outer edge — in
  the reference it becomes the exit lane and the next boundary takes over;
- entry lanes would ideally feed the matching spiral lane, which the mouth
  model does not represent (`splitApproachLanes` splits by `Direction` only).

The first three are the actual build. The fourth is lane-connection work that
can follow.

### 5.3d ~~The mouth INDENTATION~~ — FIXED, see §3.7 and §4.4
The long thin V-notch down the middle of every approach. Three rounds of
raised-or-nothing; the answer was a second fill. Design and thresholds in §3.7,
measurements in §4.4.

### 5.4 Clipping at arm ends — no longer reproduces, and the old evidence was bad
A wedge of raised pavement jutting across the asphalt where an arm meets its
approach. This was recorded as "detector built, does not reproduce" across 1+1,
2+2, medians and a 3/1 approach. **That detector was scanning the wrong ground**
— `scan_mouths` swept away from the ring down the plain approach road (§4.4), so
it never looked anywhere the clipping could be.

Pointed at the mouth it fires immediately, 4 to 75 samples a case. **All of it
is the splitter island**, which is raised material strictly inside the mouth's
lateral span by definition — exactly what the overhang rule looks for. Excluding
the island by identity (tagging the gore triangles, not inferring from position)
leaves **zero** overhang across 24 cases: 16 radii from 10 to 70, plus 5-leg,
3/1, medians, no-pavement, no-island and a 65° skew.

So there is no measured reproduction of this defect at all, and the earlier
"does not reproduce" was worth nothing either way. It stays open only because
the user has seen it in Studio. Next step is unchanged: compare the arm's
first/last emitted Part against the approach's **in the Lua** — CFrame and Size,
not lateral extent (`seam_steps` reads 0.00 flush there because extent is not
what differs).

### 5.5 Smaller, known limits
- **Crowded rings.** 5+ legs, or wide approaches on a small radius, squeeze the
  split until the arms run up against each other partway along. A 4-leg ring
  with legs 65° apart at R=45 now scans clean, so this is narrower than it was.
- **Splitter waist.** A 4-leg ring dips ~0.7 studs partway along. Cosmetic.
- **Island rim hairline.** ~0.1 studs where the ring's innermost strips chord
  across the island. Reported by the tooling as below visible, not failed.

---

## 6. The tooling, and exactly what it does not cover

`tools/preview/roundabout_preview.py` simulates **the parts `RoadBuilder`
actually emits** — rigid boxes per station interval, not idealised polygons.

| check | covers | blind to |
|---|---|---|
| `scan_gaps` | bare ground, `island_r` → `outerR` | everything outside the ring annulus |
| `scan_mouths` | bare ground **and** overhang, cut → ring | a wrong marking (it counts a marking Part as coverage); anything narrower than two sample pitches; whether raised material *should* be raised, only that the splitter island is |
| `seam_steps` | lateral extent at the cut | the *shape* of an end cap |
| `check_parity.py` | constants shared with the Lua | the algorithm, and any missing rule set |

Four lessons that cost real time:

0. **A check can point at the wrong ground and still print "clean".**
   `scan_mouths` was added *because* `scan_gaps` never looked at the mouths, and
   then swept away from the ring for its entire life (§4.4). One sign. The
   habit that catches this: before believing a pass, make the check fail on
   purpose. Stripping the apron out of a built scene and confirming the numbers
   come back is what proved the mouth fix was real rather than invisible.

1. **`scan_gaps` never looked at the mouths.** On a 40-stud ring it covers
   29.9→50.1 studs and never examined 50.1→92.7 — 68% of the built radius, and
   every bit of the entry/exit slip. Every "no bare ground" it printed for a
   year was about the annulus that was already fine. `scan_mouths` exists now
   because of this.
2. **The preview did not apply the plugin's radius growth.** So every
   small-radius case it certified was a ring the plugin would never build.
   Fixed; `build(..., grow=False)` inspects un-grown geometry deliberately.
3. **`check_parity.py` compares constants, not behaviour.** Both gaps above were
   behaviour divergences it structurally cannot see. `dump_compare.py` +
   the junction panel's *Print geometry to Output* button compare behaviour, and
   **have still never been run against a live junction.**

Reproduce the R-band defect (now fixed, keep as a regression check):

```sh
cd tools/preview
python3 -c "import roundabout_preview as P; \
  legs=[(b,P.two_way(1,1,True)) for b in (0,120,240)]; \
  P.render(P.build(35.0,1,legs,True,'probe',grow=False),'out')"
```

Renders `out/probe_parts.png` and `out/probe_gaps.png` — **magenta is bare
ground**. Run the full suite with `python3 roundabout_preview.py` (no
`--no-render`, which is how you get the images).

---

## 7. The standing hazard

**There is no Luau runtime or typechecker in the dev environment.** `stylua`
proves a file *parses*; nothing proves an identifier exists. A misplaced edit
once shipped `ringComponents` referencing a nil global, and every
`Make Roundabout` threw on its first line until it was caught live in Studio.
`tools/preview` structurally cannot catch that class — it re-implements the
geometry rather than executing the Lua.

So: when adding a helper to `RoundaboutBuilder.lua`, check it is defined **above**
its first use. `DOWN` and `angleDelta` had to be moved for exactly this reason
when `buildIsland` grew to need them. Closing this properly is the highest-value
unbuilt item in `TODO.md`.

**Nothing in this file has been confirmed in Studio by the agent that wrote it.**
Every result quoted here is headless. Treat live screenshots as the authority.
