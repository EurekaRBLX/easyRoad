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

**Nothing raised may begin inside the ring kerb**, and that has to be stated
separately because retiring the outer-edge rule removed the guarantee that used
to make it impossible. On a crowded ring the width test can first reach 2 m at a
station already past the kerb; the rung loop then keeps its first rung (its
break only fires from `i > 0`), the nose fan runs from that deep apex out to the
kerb arc, and the mouth gets a raised wedge laid straight across the circulating
lanes. Measured on a 4-leg 2+2 at R=45: gore material from r=36.1 out to a kerb
at r=54.5, leaving 7.6 studs of a 26.1-stud carriageway drivable — 0.58 of one
lane, on an ordinary radius. Same shape at R=50, and on a 1+1 ring from R=22 to
R=40. So the kerb crossing is computed too, and if the island cannot start
before it there simply is no raised splitter at that mouth — the apron is the
whole of it, which is what a mini-roundabout looks like anyway.

**The island tapers to a nose.** Stopping it dead at the width crossing leaves a
blunt flat chop across the middle of the carriageway with both arms' edge lines
carrying on past it — which is what the mouth still read as once the bare ground
was gone, and was reported as the indentation a second time. From the width
crossing the island now grows a nose back down the approach over
`ISLAND_NOSE_TAPER_M` (6 m), each rung the gore scaled about its own midline so
it closes to a point. It sits ON the apron rather than replacing it: the apron
is flat asphalt at deck level and the nose is raised, so the wedge either side
of the nose stays carriageway. Bounded, so this is a nose and not the knife-edge
sliver that filling from the cut produced.

The apron and the island want opposite roundings of that one crossing: the apron
stops one probe PAST it (stopping at it left a 0.25-stud hairline of bare ground
just outside the kerb, because the rung is a chord and the kerb is an arc, and
overlapping the ring deck with flat asphalt costs nothing), the island must
start one probe BEFORE it. Apron rungs are also sunk by `ARM_SINK_STUDS`: the
arms' Parts are dropped after building but their curves are not, so an apron
laid on the curve would sit proud of the carriageway it is continuous with.

### 3.8 Turbo is a concentric divider plus an exit peel
The authoritative design keeps the same constant-width annulus and the same
ordinary concentric Drive/Drive divider as Continuous mode. Turbo adds a short
dashed peel at each exit; it does **not** suppress that divider and does not
migrate every boundary across the full arc. Earlier text in this section mixed
that rejected full-ring spiral with the shipped peel design and contradicted
the implementation.

The peel holds the divider's radius for most of its run, then moves outward
over `TURBO_FLING_FRACTION = 0.35` of the available exit span and hands over to
the exit arm's own lane line. Dashes are walked backwards from the exit so the
last one lands at the handover. `buildTurboMarkings` emits these Parts only
after the mouth angles and exit traces exist; the base concentric divider still
comes from the normal roundabout marking plan.

Python resolves the coincident base-divider/peel phase by painter order. Studio
cannot rely on coplanar Part order, so `TURBO_MARKING_LIFT_STUDS` puts the peel's
top face 0.005 studs above RoadBuilder's highest alternate marking layer. This
changes only 3D ownership, not the accepted bird's-eye appearance.

**The ring's divider stays concentric under every mode.** What makes a turbo a
turbo here is a **peel-off at each exit**, drawn on top of it: a short dashed
line that leaves the divider a share of the way back from the exit
(`TURBO_FLING_FRACTION` of the gap to the previous exit, so it scales with leg
count) and swings out one lane width, arriving at the ring's outer edge exactly
on the exit. Dashes are walked backwards from that terminus so one lands flush
on it — the end of the mark is the whole point of it.

Four rounds were spent instead trying to spiral the WHOLE ring, and every one
was wrong in a different way. Recorded so nobody tries again:

| attempt | what broke |
|---|---|
| migrate evenly across each arc | reads as a slow drift; loses the commitment a turbo is meant to signal |
| aim at the mouth **centre** | the exit is not the centre — kerb reached at 88.7° against an exit at 55.0°, a half-mouth late |
| entry edge → exit edge | delivered exactly (53.9° vs 55.0°) but drew nothing across the mouths, leaving the divider on ~30% of the ring |
| exit → exit | full coverage and correct delivery, but a 13-stud jump at every exit reads as two unrelated lines, and driving the divider to the kerb pinches the outer lane to zero exactly where a 2-lane exit needs it widest |

The last of those is what settled it: a full-ring spiral cannot both stay
concentric-looking and hand off cleanly, because our exits are two lanes wide
and the ring only has two. A concentric divider plus a peel does both, and it is
what the reference photographs actually show.

**The peel ends on the exit arm's own lane line**, not on the ring. That took
threading the exit arm's `PolyCurve` and `ArmProfile` out of `buildMouth`
(`ExitTrace`) into the marking pass; five earlier versions tried to land on that
line using ring coordinates alone and every one ended on the ring's outer EDGE
line instead, because the line they were aiming at is out in the arm and moving.

Two things about how it is built, both learned by getting them wrong:

- **The peel is TWO PHASES, and there is nothing to interpolate.** It is the
  ring's own divider as far as the exit, then the exit arm's own lane line.
  Those two already join: the arm merges **tangentially** and its outer edge
  lands on the ring's kerb, so at the merge the arm's boundary k lanes in from
  that edge *is* the ring's boundary k lanes out from the island — position and
  heading both continuous, and the radius monotonic because phase one holds it
  constant and phase two only runs outward. Two constructions came first. A
  cubic pinned to the ring tangent at one end and the arm tangent at the other
  sagged: measured r=57.8 against a divider at 66.4, a marking bulging eight
  studs toward the island. Capping the handles did not help — the span is 61° of
  arc once the arm's own swing is counted, and no handle length makes a
  straight-ish chord follow a circle that far. Blending the two curves by
  progress cured the sag but pairs mismatched parameters: early on it mixes a
  ring point with an arm point 40° away, and the chord between them cuts inward.
  1.4 studs on a 3-lane ring — small, but a kink in the one line a driver is
  being asked to follow out of the roundabout, and it was the 3-lane cases that
  surfaced it.
- **Which offset sign points outward is MEASURED, not assumed.** That was got
  wrong twice: once by omitting the flow factor (invisible on left-hand drive,
  mirrored on right) and once by adding it (target 22 studs the wrong way, peel
  diving to r=47 inside a ring whose divider is at 66). Comparing the two
  candidate radii at the merge cannot be wrong on either hand.

Also not built, the other half of "turbo on the arms": **lane arrows and
destination legends on the approaches**, which is how a real turbo tells a
driver which lane to pick. A `Markings.lua` job on ordinary one-way roads, not
ring geometry.

It runs after `openRingPavement`, deliberately: that pass deletes ring pavement
and edge lines inside the mouth sectors, and these parts must survive there.
Running first would hand them to a `ringPavement` list captured before they
existed.

Falls back to a plain ring on one lane (no boundary to spiral) or one mouth (no
arc to spiral along).

### 3.8b A shoulder is a tapered reserve behind a solid line, not a lane
A `LaneGroup` carries a `LaneSpec { Kind, WidthM, Directional }` per strip, not
a bare width. Flattening to a width was a real bug: a shoulder is
`Direction = 0` roadway, so the "undirected roadway belongs to whichever side it
abuts" pass folds it into a group, and `armProfileFor` then re-emitted every
strip as `{ Kind = "Drive" }`. A 2+2 motorway built 3+3 arms — wrong colour, and
`Markings.lua` puts a lane boundary between two Drive components where a solid
edge line belongs.

Fixing that exposed **two ordering bugs underneath it**, both invisible while
every strip came out as an identical-width Drive, because reordering identical
things changes nothing you can see:

- the undirected pass runs *after* the directional one and appended as it went,
  so a shoulder landed at the inboard end of its group however far outboard it
  actually sat. `splitApproachLanes` now collects indices and sorts them.
- **an arm whose own travel runs against the approach curve sees the
  cross-section mirrored.** What was at approach offset +x is at arm offset −x,
  so its components list back to front. Which arm that is depends on both the
  arm and which END of the road the junction sits at: `mirrored =
  (travelsInward == atStart)`. It is neither "always the exit" nor a property of
  the arm alone.

Either one alone puts the hard shoulder on the **gore** side of the mouth,
against the splitter island. But preserving its kind and full width all the way
to the ring is also wrong: it still draws three surface strips feeding a
two-lane ring. `armProfileFor` now replaces only the contiguous OUTBOARD
shoulder with a zero-width Shoulder marker. That marker keeps the semantic
Drive/Shoulder boundary, so `Markings.lua` draws the required solid line, while
the two Drive components remain the only running lanes at the merge.

**The arm's pavement is load-bearing, and now tapers.** An arm needs one at
`style.SidewalkWidthM` by the ring even when its approach has none. Keeping it
full-width to the cut stepped the outer edge 7.2 studs sideways on a motorway
approach. It cannot simply be removed:
`openRingPavement` deletes the ring's own footway across each mouth sector, and
it is the arm's pavement that covers the band from the ring's kerb out to its
outer edge there. Removing it trades the step for **6 studs of bare ground** on
exactly the highway legs.

`buildArm` now fills two coordinated edge-anchored surfaces outside the fixed
travel lanes. The shoulder smoothsteps from full width at the cut to zero at the
merge. Pavement starts outside the current shoulder edge and grows from the
approach's real width (zero for a motorway) to the ring width, so the surfaces
never overlap and never expose ground. The three highway cases measure
0.00 / 0.00 / 0.10 studs of seam step; every 3.3 m shoulder measures
11.78 -> <=0.02 studs (the surface-emission cutoff); none carries a
`KNOWN_OPEN` exception.

### 3.9 "Minimum" radius means the cliff, not the comfort
Two different numbers were being asked of one function, and the answer was the
wrong one.

- **`MinimumRadiusStuds`** is now the hard floor: below it there is no
  roundabout in the literal sense. The centre island's radius is
  `radius − ringInnerHalfWidth`, so once the requested radius drops below that
  half-width the ring's inner edge has passed the centre and the "annulus" is a
  self-overlapping disc. A 4-leg 2+2 at R=10 comes out as a four-pointed raised
  star with a hexagon in the middle. Closed form, exact, and small.
- **`SuggestedRadiusStuds`** carries the angular packing estimate that used to
  be called the minimum — every leg's two arms, its deflection split, and a
  strip of kerb before the next leg, summed against 360°.

The packing number is a fine suggestion and was a bad floor. Sweeping radius
against `circulating_width`, the geometry holds all the way down to **R=18** on
4-leg 2+2, 4-leg 1+1, 3-leg 1+1 and 5-leg 1+1 — against packing numbers of 70.5,
42.8, 27.5 and 64.2. Two to four times too conservative, and the failure below
the real floor is a cliff rather than a slope, which is why a conservative
estimate never located it.

This matters beyond tidiness: the radius is advisory now, so the user sees the
number and decides. A "minimum" that is four times the truth teaches them to
ignore it.

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
`RegionStyle.RoundaboutMarkings` ("Continuous" | "SolidLanes" | "Turbo") sets the regional
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

### 5.3 ~~Markings do not match the preview~~ — SHIPPED HEADLESS
The preview never ported `Mesh/Markings.lua`; it approximates it with solid
white roadway edges, dashed white Drive/Drive boundaries, and solid
Drive/non-Drive roadway separators. The Lua now supplies that same
roundabout-owned line plan directly to RoadBuilder, with the preview's 3m/3m
dash rhythm, origin phase, and final partial dash. SolidLanes switches only the
circulating Drive/Drive dividers to solid.

This deliberately does **not** replace `Markings.lua`: ordinary roads retain
regional boundary rules, the Road Editor, restrictions, and both stretch
systems. The generated ring and arms are the only callers of the exact-plan
hook. The first live Studio comparison showed extra white slashes despite this
line plan being correct. They were fragments of the ring's outer edge line whose
Part centres lay outside a mouth while their corners crossed inside. The exact
sector-boundary clip in section 5.4 now removes only those fragments.

The later live comparison exposed a separate painter-order mismatch. Python
draws the sunk arms before the ring deck; Studio left their marking tops up to 0.009
studs proud. Each arm line is now bounded at its own offset's expanded ring-kerb
crossing (`FromStationStuds` on exits, `ToStationStuds` on entries). Turbo keeps
the same concentric-divider-plus-peel pixels but puts the peel on a distinct top
plane. `tools/preview/roundabout_parity_contract.py` locks those 3D ownership
rules with five destructive break-tests.

Requested on top of that: a **Turbo / Continuous** toggle in the roundabout
build panel, with a default in regional settings.

### 5.3c ~~A real TURBO roundabout~~ — SHIPPED, see §3.8
Built as a third `RoundaboutMarkings` mode. Rule and reasoning in §3.8.

Not built, and not needed for the markings to be right: **entry lanes are not
matched to spiral lanes.** A driver should be committed to a destination by the
lane they enter in, which means `splitApproachLanes` would have to know which
circulating lane each approach lane feeds. It splits by `Direction` only. That
is lane-connection work, not markings.

### 5.3d ~~The mouth INDENTATION~~ — FIXED, see §3.7 and §4.4
The long thin V-notch down the middle of every approach. Three rounds of
raised-or-nothing; the answer was a second fill. Design and thresholds in §3.7,
measurements in §4.4.

### 5.4 Clipping at mouth-sector boundaries — fixed headlessly, live recheck open
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

So the overhang detector has never reproduced this, and the earlier "does not
reproduce" was worth nothing either way.

**A defect of exactly this class was then found by a different check**, and is
fixed: the splitter island's nose fan laying a raised wedge across the
circulating lanes (§3.7, §4.5). Whether it is the one reported is not settled —
that wedge sits at the mouth by the ring, and the report described the arm's
seam with its approach. Treat it as a lead, not a closure. What it does settle
is why the overhang check could not find it: the check excludes the splitter
island by identity, and the splitter island was the thing at fault.

The Lua still replaces the constant-width raised pavement Part touching the
approach cut with exact station-edge triangles, but the next Studio screenshot
proved that was not the reported wedge. The visible defect was a ring sidewalk
Part straddling the angular edge of a mouth: `openRingPavement` kept it because
its centre was outside, even though its corner was inside.

The opening pass now measures the full Part footprint. A fully interior Part is
deleted; a straddler is clipped by the radial boundary half-plane and its exact
outside polygon is triangulated back into the ring. The outer edge-line Parts
use the same operation, removing the excess white slashes. Whole-Part deletion
was rejected because it opens multi-stud holes on three-leg rings. The Python
port models and asserts the clipped boundary. Next step is the rebuilt Studio
look; keep this open until the reported overlap is visibly gone.

### 5.5 Smaller, known limits
- **Crowded rings.** 5+ legs, or wide approaches on a small radius, squeeze the
  split until the arms run up against each other partway along. A 4-leg ring
  with legs 65° apart at R=45 now scans clean, so this is narrower than it was.
- **Splitter waist.** A 4-leg ring dips ~0.7 studs partway along. Cosmetic.
- **Island rim hairline.** ~0.1 studs where the ring's innermost strips chord
  across the island. Reported by the tooling as below visible, not failed.

---

## 6. The tooling, and exactly what it does not cover

`tools/preview` simulates **the parts `RoadBuilder` actually emits** — rigid
boxes per station interval, not idealised polygons. `preview_core.py` is the
generic emission port; `roundabout_preview.py` and `road_preview.py` are
scenarios on top of it, and `validate.py` runs the lot with a `KNOWN_OPEN` table
of failures that are expected today. See `tools/preview/README.md`.

| check | covers | blind to |
|---|---|---|
| `scan_gaps` | bare ground, `island_r` → `outerR` | everything outside the ring annulus |
| `scan_mouths` | bare ground **and** overhang, cut → ring | a wrong marking (it counts a marking Part as coverage); anything narrower than two sample pitches; whether raised material *should* be raised, only that the splitter island is |
| `circulating_width` | narrowest DRIVABLE width of the ring, all the way round | anything outside the ring band; it answers "can you drive round it", nothing else |
| `seam_steps` | lateral extent at the cut | the *shape* of an end cap |
| `check_turbo` (run it via `turbo_check.py`) | each peel starts on a ring divider, runs outward, and its FAR END lands on the lane lines of the exit it was built for | whether the peel is the right line to draw at all — that is a judgement from reference photographs, and it was wrong six times while every check stayed green |
| `check_arm_kinds` | non-shoulder running surfaces keep their KIND and width; the shoulder marker is outboard and zero-width at the ring | the physical shoulder wedge between cut and ring |
| `check_shoulder_tapers` | emitted shoulder polygons have source width at the cut and zero width at the ring | markings and vertical/z-fighting defects |
| `road_preview.py` | an ordinary road: bare ground inside its own footprint, edge sawtooth, broken edge lines | lane-width transitions and bus bays, which are **not ported at all** |
| `check_parity.py` | constants shared with the Lua | the algorithm, and any missing rule set |

Five lessons that cost real time:

0. **Every check here answers one question, and says nothing about the rest.**
   `scan_gaps` and `scan_mouths` both look for MISSING material, so neither can
   see a ring paved over in kerb — which is exactly how a too-small roundabout
   fails. `circulating_width` exists because of that, and it in turn knows
   nothing about bare ground. Three green checks are three answers, not a
   verdict.

0. **A check can point at the wrong ground and still print "clean".**
   `scan_mouths` was added *because* `scan_gaps` never looked at the mouths, and
   then swept away from the ring for its entire life (§4.4). One sign. The
   habit that catches this: before believing a pass, make the check fail on
   purpose. Stripping the apron out of a built scene and confirming the numbers
   come back is what proved the mouth fix was real rather than invisible.

0. **An invariant kept across a design change certifies what you stopped
   wanting.** Three of `check_turbo`'s rules have now died this way. The first
   asserted the peel "reaches the ring's outer edge at each exit" — that
   property turned out to *be* the defect, so it was replaced rather than
   relaxed. The second asked whether the peel ended near any `Marking`; a real
   test while Turbo suppressed the ring's lane lines, and a tautology the moment
   it stopped, because the peel now lies along a ring divider for its whole
   first phase and the nearest marking is always ~0. Scoping it to the exit
   arms' own markings was still not enough: measured over the whole peel it
   passed a peel rotated 40° off its exit, since a 30° arc and an 80-stud arm
   cross somewhere however they are turned. Only the peel's **far end**, against
   **that exit's** lines, says anything. Each of those passed everything until a
   break-test was written for it specifically.
1. **`scan_gaps` never looked at the mouths.** On a 40-stud ring it covers
   29.9→50.1 studs and never examined 50.1→92.7 — 68% of the built radius, and
   every bit of the entry/exit slip. Every "no bare ground" it printed for a
   year was about the annulus that was already fine. `scan_mouths` exists now
   because of this.
2. **The preview and plugin once disagreed about radius growth.** Both now use
   the requested radius by default; `build(..., grow=True)` is an explicit
   suggestion-sized experiment only. `dump_compare.py` was the last stale path
   and now reports the advisory minimum without applying it.
0. **The port can be wrong in ways nothing compares.** `split_approach_lanes`
   spelled "is this roadway?" as `!= "Sidewalk"` where the Lua uses
   `RoadProfile.IsRoadway`, whose table excludes `Median`. So on every median
   profile the preview adopted the median into whichever arm it abutted, while
   the plugin correctly left it to become the splitter gore — two different
   roundabouts, both reported clean, for as long as the median cases have
   existed. Nothing compared them, and `check_parity.py` structurally cannot:
   it diffs constants. The habit that catches this class is spelling a shared
   rule the same way on both sides (`is_roadway` now mirrors `ROADWAY`), not
   re-deriving it per call site.
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

The turbo peel has its own runner, because its interesting cases are lane-count
combinations rather than radii and because it carries the break-tests:

```sh
python3 tools/preview/turbo_check.py
```

Eight scenes plus one break-test per `check_turbo` rule. The break-tests are the
point — every rule that has silently died here passed the real geometry right up
until one was written for it.

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
