# Intersection and roundabout geometry options

This document compares geometry approaches for future development. It does
not define the current implementation or promise a change to it. See
[ROUNDABOUT.md](../ROUNDABOUT.md) for the current roundabout design.

## Existing reference code

| Reference | Useful properties | Limits |
| --- | --- | --- |
| [RoadHelper](roadhelper/README.md) | Analytic T/X geometry, bounded corner fillets, intersection markings, and endpoint matching. | Uses two road axes and a fixed approach layout. The selected files have no roundabout generator. |
| [RoadCreator](roadcreator/README.md) | Angle-sorted approaches, quadratic Bézier corners, and approach-to-ring connections. | Uses Unity mesh APIs. A Luau adaptation needs coordinate, surface, and editing checks. |

Both selected code sets have MIT license texts in their directories. Keep
their notices with copied or adapted code. The easyRoad
[BezierCorner.lua](../src/Geometry/BezierCorner.lua) module already records a
RoadCreator adaptation. Its presence does not mean that every junction uses
that corner method.

## Separate topology from surface generation

A junction generator must decide which approach edges connect before it emits
surface triangles. A roundabout generator must also decide which surface owns
each part of an approach mouth. Keep those decisions explicit.

Test the resulting boundaries for winding, intersections, degenerate edges,
and overlap. A bounded corner curve alone does not make the full boundary
valid. A polygon union can produce several components or holes, so a boolean
operation alone does not guarantee one simple outline.

## Polygon operations in Luau

One option is to combine approach footprints in the ground plane before
triangulating the resulting surface. For a roundabout, footprint subtraction
can open a pavement band at an approach mouth.

This approach can retain synchronous geometry planning and output made from
Roblox Parts. It also requires explicit rules for shared vertices, collinear
edges, holes, disconnected results, numerical tolerances, and triangulation.
Ground-plane clipping must preserve the intended surface height on banked or
graded roads.

Possible research sources include
[2d-polygon-boolean-lua](https://github.com/Bigfoot71/2d-polygon-boolean-lua)
and PolyBool implementations. They are not vendored dependencies here.
Verify the exact implementation, license, and degenerate-input behavior before
adopting any code. Do not perturb input coordinates merely to hide an invalid
boundary; a perturbation can change a visible road joint.

The current roundabout builder already uses convex footprint subtraction for
surface ownership. Evaluate a general polygon library against that existing
behavior before increasing the scope of the geometry system.

## Roblox solid geometry operations

Engine boolean operations are another possible approach. A prototype would
need purpose-built solid inputs, current API and plugin permission checks,
measured execution time, and tests for the resulting collision geometry.

The output and execution model can differ from the current per-Part surface
builder. Lane markings, source metadata, undo, live preview, and local edits
still need a design. Solid union does not by itself supply rounded kerbs or a
road editing model.

## Other algorithm references

[Eclipse SUMO](https://github.com/eclipse-sumo/sumo) includes junction boundary
construction in `NBNodeShapeComputer`. It can inform research into approach
ordering and special cases. It is not vendored code or a dependency. Review
the license of the exact source files before copying or translating code.

## Evaluation procedure

1. Define the input and output boundary rules.
2. Record the source and license of each proposed dependency.
3. Test T, X, skewed, and multi-approach junctions.
4. Test unequal widths, one-way roads, close mouths, and both traffic sides.
5. Test shared vertices, collinear edges, short approaches, and steep grades.
6. Compare surface coverage, overlap, Part count, and rebuild time.
7. Check placement, edits, undo, save, and reload in Roblox Studio.

Keep the existing geometry path available until the replacement preserves
these behaviors. Python previews provide algorithm checks; they do not
execute the Roblox plugin.
