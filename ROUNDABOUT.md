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

### 3.7 The splitter island spans exactly [ring outer edge → ring kerb]
`MIN_GORE_WIDTH_M` exists so an approach with no median does not get a raised
strip down the middle of it. But the island must also cover the pavement
`openRingPavement` deleted. Both are satisfied by one rule: **start the island
at the ring's outer edge.** Inside it, the island replaces deleted pavement;
outside it, there is nothing to replace and any island is a median the road does
not have.

Getting this wrong in either direction produces a visible defect, and both have
shipped:
- starting too late → bare ground in the deleted band (§4.1)
- starting too early → a thin sliver of raised island running ~17 studs down
  the approach, which is the phantom median coming back

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

### 5.3c A real TURBO roundabout — NOT BUILT
A turbo roundabout is a **spiral**, not a marking style. The inner lane is flung
progressively outward until it becomes an exit lane, so the lane a driver enters
commits them to a particular exit. Weaving is impossible by geometry, and the
solid dividers merely enforce what the layout already decides.

That means it changes the RING GEOMETRY, and none of the current model supports
it:

- the ring is one constant-width annulus of N concentric lanes
  (`ringComponents` builds a fixed profile and `circleSegments` a plain
  circle). A turbo ring's lane count and lane centres vary with angle.
- each lane boundary would have to spiral outward between mouths rather than
  close on itself, so `RoadBuilder`'s constant cross-section along a curve is
  the wrong primitive for the circulating carriageway.
- entries would have to feed specific lanes and exits take specific lanes,
  which the mouth model does not represent - `splitApproachLanes` splits an
  approach by `Direction` only, with no notion of which exit a lane serves.
- the splitter islands and gores would follow the spiral, not the radial
  mouth sectors `openRingPavement` assumes.

So this is a second ring generator alongside the existing one, not an option on
it. Worth scoping deliberately rather than growing into.

### 5.3d The mouth INDENTATION — OPEN, and the most reported defect
Visible in every render and every Studio shot: a long thin V-shaped notch down
the middle of each approach, from the ring back toward the cut, tapering to
nothing.

It is not a bug in the splitter island. It is a consequence of the arm model
that the island was being used to paper over, and it has now been seen in all
three possible states:

1. **Island filled the whole gore** (before `MIN_GORE_WIDTH_M`) — a raised
   strip down the middle of an approach with no median. Reported as "there is
   median when there is no median for the type of road used".
2. **Island started too far out** (the first fix) — a thin raised sliver
   running ~17 studs down the approach. Same complaint, smaller.
3. **Island starts at the ring's outer edge** (current) — the wedge between the
   cut and the outer edge is now OPEN GROUND. Reported as the indentation.

The wedge itself is unavoidable: entry and exit are separate one-way roads that
coincide at the cut and diverge toward the ring, so there is always a V between
them. The question is only what fills it.

**All three states answer that wrongly, because raised-or-nothing is a false
choice.** Between the cut and roughly where a splitter becomes physically
plausible, that wedge is not a median at all — it is the approach's own
carriageway widening as it fans into the mouth. It should be **flat asphalt at
deck level**, continuous with both arms. Only further in, where the gore is wide
enough to stand on, should it become a raised kerbed island.

So the fix is a third fill, not a different threshold:

    cut ......... outer edge ......... ring kerb
    |<- flat asphalt ->|<- raised splitter island ->|

`MIN_GORE_WIDTH_M` then stops being a "build or don't" switch and becomes the
boundary between the two fills, which is what it was reaching for.

Note the preview cannot currently fail this: the wedge is open ground BETWEEN
two roads, so `scan_mouths` classifies it as GORE (open by design since the
splitter change) rather than HOLE. That classification was right for the
question it was asked and wrong for this one — it will need revisiting alongside
the fix.

### 5.4 Clipping at arm ends
A wedge of raised pavement juts across the asphalt where an arm meets its
approach. `scan_mouths` detects this class now but **it does not reproduce**
across 1+1, 2+2, medians and a 3/1 approach at R=40 and R=55. Most likely the
arm's end-cap shape, which the preview idealises as a rotated rectangle while
`RoadBuilder` emits a Part whose corners can overhang on a curve. Next step is
comparing the arm's first/last emitted Part against the approach's **in the
Lua** — CFrame and Size, not lateral extent (`seam_steps` reads 0.00 flush there
because extent is not what differs).

### 5.5 Smaller, known limits
- **Crowded rings.** 5+ legs, or wide approaches on a small radius, squeeze the
  split until the arms run up against each other partway along.
- **Splitter waist.** A 4-leg ring dips ~0.7 studs partway along. Cosmetic.
- **Island rim hairline.** ~0.1 studs where the ring's innermost strips chord
  across the island. Reported by the tooling as below visible, not failed.
- Optional sidewalk and optional centre island were both requested; neither
  exists.

---

## 6. The tooling, and exactly what it does not cover

`tools/preview/roundabout_preview.py` simulates **the parts `RoadBuilder`
actually emits** — rigid boxes per station interval, not idealised polygons.

| check | covers | blind to |
|---|---|---|
| `scan_gaps` | bare ground, `island_r` → `outerR` | everything outside the ring annulus |
| `scan_mouths` | bare ground **and** overhang, cut → ring | a wrong marking (it counts a marking Part as coverage) |
| `seam_steps` | lateral extent at the cut | the *shape* of an end cap |
| `check_parity.py` | constants shared with the Lua | the algorithm, and any missing rule set |

Three lessons that cost real time:

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
