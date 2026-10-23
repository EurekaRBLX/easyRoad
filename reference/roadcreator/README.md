# RoadCreator reference

This directory contains selected C# source files from a Unity road tool.
The files are references for intersection and roundabout geometry. They are
outside the plugin build paths and are not included in the generated plugin.

## Source and license

- Source: [MarcusElg/roadcreator](https://github.com/MarcusElg/roadcreator)
- Recorded commit: `ba42880192d366febb92da87fd09ba985e923b68`
- License: MIT
- Copyright: 2019 MCrafterzz
- Full license: [LICENSE-roadcreator.md](LICENSE-roadcreator.md)

Keep the copyright and license notices when you copy or translate this code.
The easyRoad module [BezierCorner.lua](../../src/Geometry/BezierCorner.lua)
records its adaptation from this project.

## Files

| File | Purpose |
| --- | --- |
| [Intersection.cs](Intersection.cs) | Builds intersection surfaces and connection corners. |
| [Roundabout.cs](Roundabout.cs) | Builds the circulating ring, approach connections, and central island. |
| [IntersectionConnection.cs](IntersectionConnection.cs) | Stores approach data and sorts connections by `YRotation`. |
| [MainRoad.cs](MainRoad.cs) | Stores a pair of through-road connections. |
| [RoundaboutExtraMesh.cs](RoundaboutExtraMesh.cs) | Describes an additional surface band. |
| [Misc.cs](Misc.cs) | Provides curve, intersection, and distance calculations. |

## Intersection geometry

Each approach stores its left and right edges, a centre reference, a corner
control point, and its facing angle. The connections are sorted by
`YRotation`. Adjacent connections then define the boundary corners.

`CreateMainMesh` samples a quadratic Bézier curve between an approach edge and
the next approach edge. `curvePoint` controls the corner shape.
`Misc.Lerp3CenterHeight` evaluates the curve in plan view and interpolates the
height between its endpoints. The surface triangles connect that boundary to
the intersection centre.

A quadratic Bézier curve stays within the triangle formed by its endpoints
and control point in plan view. This bounds an individual corner curve. It does not prove
that a complete intersection boundary is valid. Approach order, degenerate
edges, control-point distance, and neighbouring corners still need checks.

`GetLineIntersection` helps place the control points. The caller uses a
midpoint fallback when the lines have no usable intersection. Through-road
pairs use separate left and right control points.

## Roundabout geometry

`GenerateRoundabout` combines these operations:

1. `CreateRoundaboutVertices` creates the inner and outer ring vertices.
2. `CalculateNearestIntersectionPoint` projects each approach edge toward the ring.
3. `FindNearestPoints` selects the ring connection vertices.
4. `AddNewRoadConnectionVertices` samples Bézier connections from the approach to the ring.
5. `CreateRoadSections` fills the ring surface between the connections.
6. `CreateCenterExtraMeshes` builds the central island surfaces.

These operations are a reference for connecting a road cross-section to a
ring. They are not a direct replacement for easyRoad's surface ownership,
regional markings, editing metadata, or rebuild logic.

## Translation considerations

`Misc.cs` contains useful small primitives: `Lerp3CenterHeight`,
`GetLineIntersection`, `CalculateLeft`, `CalculateDistance`, and `GetCenter`.
Check Unity and Roblox coordinate conventions before translating them.
Use explicit tolerances for parallel lines and degenerate vectors. Preserve
the upstream attribution with each adaptation.
