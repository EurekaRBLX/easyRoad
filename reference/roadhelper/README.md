# RoadHelper reference

This directory contains selected RoadHelper source files for geometry research.
The files are outside the plugin build paths. They are not included in the
generated plugin.

## Source and license

- Source: [stravant/roblox-roadhelper](https://github.com/stravant/roblox-roadhelper)
- Recorded commit: `bfa5c5dde79a2927bb758b17abbc6f878af508fb`
- License: MIT
- Copyright: 2025 Mark Langen (@stravant)
- Full license: [LICENSE-roadhelper](LICENSE-roadhelper)

Keep the copyright and license notices when you copy or adapt this code.
Record the source in an attribution comment when you adapt an algorithm.

## Files

| File | Purpose |
| --- | --- |
| [RoadIntersectionGenerator.lua](RoadIntersectionGenerator.lua) | Generates a T or X intersection with two road axes. |
| [StraightRoadGenerator.lua](StraightRoadGenerator.lua) | Generates a straight road segment. |
| [CurveRoadGenerator.lua](CurveRoadGenerator.lua) | Generates a curved road segment. |
| [RoadMath.lua](RoadMath.lua) | Calculates endpoint frames, joint matching, placement, and segment movement. |

## Intersection geometry

The intersection generator uses two axes, X and Z. Each axis has its own lane
width and lane count. `IntersectionAngle` changes the crossing angle within
`MaxAngle`, which defaults to 10 degrees. `ThroughRoad = false` removes one
approach to produce a T intersection.

`cornerPoint(sZ, sX)` derives the central overlap corners from the road widths
and crossing angle. The generator then places circular corner fillets. It
limits the tangent distance to the space available along each road edge.
This layout supports a fixed T or X template. It does not provide an arbitrary
number of approaches.

The marking pass uses the same corner data to place lane lines, edge lines,
stop lines, and crosswalk stripes. This makes it a useful reference for keeping
markings aligned with the generated intersection surface.

## Placement geometry

`RoadMath` provides these operations:

| Operation | Purpose |
| --- | --- |
| `findJoint` | Finds a compatible road endpoint. |
| `solveMove` | Calculates a segment transform after an endpoint moves. |
| `placementFrame` | Calculates a placement frame at an open endpoint. |
| `matchingAdjust` | Matches direction, grade, and bank at a joint. |

The selected files do not include a roundabout generator. See the
[RoadCreator reference](../roadcreator/README.md) for a different approach to
roundabout connections.
