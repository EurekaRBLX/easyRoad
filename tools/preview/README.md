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

## Caveats

It models part **footprints in plan**. It does not model heights, render order,
dash phase, or Studio's own z-fighting behaviour - a live check is still the
last word on those.
