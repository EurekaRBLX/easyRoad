# Roundabout pre-render preview

Simulates the **parts `RoadBuilder` actually emits** and checks the result for
bare ground, without Studio.

Every other check in this repo works on idealised geometry - centrelines and
offset polygons. Roblox never sees those. It sees rigid boxes, one per
(component, station interval), each a rotated rectangle approximating an arc.
Facets, sliver gaps and z-fighting only exist at that level, so an idealised
render cannot show them. This tool ports the emission path directly:

| ported from | what |
| --- | --- |
| `RoadBuilder.buildStations` | adaptive stepping, incl. the offset-edge curvature term |
| `RoadBuilder` deck-strip branch | `Size = (width, h, nominalLength + padding)`, `CFrame = midFrame * CFrame.new(centerOffset, y, 0)` |
| `RoadBuilder.curveMiterPad` | `padding = |edgeDistance| * curvature * nominalLength + 0.08` |
| `RoadBuilder.placeMarkingSpan` | endpoints anchored to true curve positions |
| `RoundaboutBuilder` | ring, split arms, splitter island, mouth sector opening |

## Usage

```sh
cd tools/preview
python3 roundabout_preview.py             # uk4 uk3 us4
python3 roundabout_preview.py uk5mini     # a named case
python3 roundabout_preview.py --no-render # scan only
```

Exits non-zero if any case has visible bare ground, so it works as a check.
Stdlib only - no numpy, no Pillow; `raster.py` writes PNGs with `zlib`.

## Output

Two views per case, in `out/` (gitignored):

- `<case>_parts.png` - every emitted part in its material colour, which is
  roughly what Studio will show.
- `<case>_gaps.png` - **magenta is bare ground.** Anything magenta inside the
  ring footprint is a hole no part covers.

It also measures the **approach/arm seam**: it sweeps the road's own
perpendicular either side of the cut and compares how far the covered material
reaches on each side. A non-zero step is the pavement or kerb line jogging
sideways where the road meets the mouth. Sizing the arms from their own
half-width plus a splitter (rather than from the approach's roadway edges)
scores 1.80 studs stepped; aligned, 0.00.

The bare-ground scan samples the ring footprint on a polar grid and clusters whatever it
finds by angle, reporting each cluster's depth in studs. Clusters shallower
than `--hairline` (default 0.15 studs) are reported but do not fail: the ring's
innermost strips are chords of the island circle, so their inner edge stands
off it by about 0.05 studs at default settings, and no padding removes that
without overlapping the island instead.

## Parity with the Lua

`roundabout_preview.py` is a hand-written Python **re-implementation** of
`RoundaboutBuilder.lua`, not an execution of it. Nothing keeps the two in sync,
so a constant tuned on one side and forgotten on the other lets the preview
quietly certify geometry the plugin never builds.

```sh
python3 check_parity.py     # exits non-zero on drift
```

It compares every constant present on both sides and flags orphans, so renames
and deletions surface. It does **not** compare the algorithm - two
implementations can agree on every number and still do different things with
them. Run it alongside `roundabout_preview.py` after touching either file.

## Behavioural comparison (`dump_compare.py`)

`check_parity.py` compares constants. This compares what the two
implementations actually *do*, which is the part that matters.

1. In Studio, select the junction, set Radius / Lanes / Lane width, press
   **Print geometry to Output**. That calls
   `RoundaboutBuilder.DescribeJunction`, which reuses `planMouth`,
   `splitBudgetFor` and `resolveSplits` - the same functions the real build
   calls - and does not modify anything.
2. Run the preview side with the same inputs:

   ```sh
   python3 dump_compare.py --radius 30 --lanes 1 --legs 0,90,180,270
   ```

3. Diff. Same field order and precision on both sides, so plain `diff` works.

A mismatch is a real divergence and preview results cannot be trusted until it
is explained. A match means the difference between preview renders and Studio
is the RENDERER - idealised polygons versus rigid parts - and not the geometry.

Known caveat: the preview's legs are radial, so its mouth angle is simply the
leg bearing. The plugin aims along the approach's own centreline
(`rayCircleFirstHit`), which only coincides for radial approaches. Expect
`mouthAngle` to differ for legs that do not point at the centre - which is
common for roads produced by an X-split.

## Caveats

It models part **footprints in plan**. It does not model heights, render order,
dash phase, or Studio's own z-fighting behaviour - a live check is still the
last word on those.
