# Roundabout design

This guide describes the roundabout geometry and its editing rules. See
[usage](docs/usage.md) for the main placement workflow and
[known issues](KNOWN_ISSUES.md) for current limitations.

## Geometry

A roundabout has one continuous circulating ring. Each connected approach has
an entry arm, an exit arm, or one directed arm. Arms meet the ring tangentially.
The space between a paired entry and exit is the gore. Flat asphalt covers the
gore near the approach cut. A raised splitter island can occupy its wider part.
The centre island fills the inside of the ring when that option is enabled.

`src/Mesh/RoundaboutBuilder.lua` owns the build pipeline:

1. `circleSegments` constructs four cubic Bézier segments.
2. `ringComponents` defines the circulating lanes and optional outer pavement.
3. `RoadBuilder.Build` emits the ring surfaces.
4. `buildIsland` constructs the optional centre island.
5. `planMouth` plans each connection.
6. `trimSpoke` trims the source road.
7. `splitApproachLanes` and `armProfileFor` define each directed arm.
8. `buildArm` and `buildSplitterIsland` emit the mouth surfaces.
9. The clipping passes remove ring surfaces where the mouth owns the surface.

The four Bézier segments approximate a circle. Use the evaluated curve and its
station plan for joins. An analytic radius alone does not describe every point
on that curve.

## Editing and saved topology

Select a ring or one of its generated arms to open the roundabout panel. The
panel can change radius, circulating lane count, lane width, marking mode,
pavement, and centre island. The clearance guide and suggested radius are
advice. The builder uses the requested radius.

A connected roundabout retains a hidden junction controller. Its
`RW_JunctionKind` is `Roundabout`. The ring stores the controller ID. Each
connected road retains its road ID, endpoint port IDs, and junction connection.
`RoundaboutBuilder.Rebuild` reads roads connected to that controller. A normal
edit does not adopt unrelated nearby roads.

Each supported approach retains an untrimmed `RoadSource`. Radius edits derive
a new source window from that data. This prevents repeated edits from
progressively shortening the road. **Convert to junction** restores the source
ends and rebuilds an ordinary junction. Each edit uses one Studio undo
recording.

The initial circulating lane count comes from the widest individual motor
carriageway. Drive components with positive width count as lanes. A median
separates carriageways, and traffic directions are counted separately.
Shoulders, pavement, cycle lanes, parking, and bus bays do not add lanes.

Initial placement and explicit connection can split a passing road at a safe
interior station. Subsequent editor rebuilds use the saved connections.

### Supported approach sources

Editable connected conversion requires one recoverable curve segment for each
approach. Conversion rejects these features before it changes the road:

- a widening or narrowing transition;
- a bus bay;
- marking or kerb stretches;
- an unreadable or unsupported source curve.

The panel identifies the blocking road. Remove the blocking feature or use a
separate approach segment before conversion. Multi-segment parallel roadways
can therefore remain unavailable even when their profiles are valid.

Standalone legacy rings remain editable. A legacy connected ring without a
recoverable controller is read-only. Recreate its junction to use the current
editor. Connected centre movement is not available.

## Geometry rules

### Circulation and lane direction

Left-hand traffic circulates clockwise. `circleSegments` uses a positive angle
sign for that direction. Downstream calculations use the same traffic-side
choice for pavement placement and entry or exit selection.

Approach lanes split by `Direction`, relative to the source curve. The inbound
sign reverses when the junction is at the start of that curve. Do not split an
asymmetric profile by halving its lane count.

A directed one-way approach has one arm and no paired splitter island. A
legacy profile with one undirected Drive component uses full-width shared
entry and exit flares. This compatibility case does not divide the component
into half-width lanes.

Arms use the approach's roadway edges as their alignment reference. Component
order reverses when arm travel reverses the source cross-section. Preserve each
component kind: a Shoulder remains a Shoulder and does not become a Drive lane.
Terminal shoulder widths taper independently toward the ring. Pavement grows
from the actual approach width to the required ring-side width.

### Surface ownership

Arms, the approach cut, the circulating ring, and the flat apron share a road
surface datum. Exact arm roadway footprints are subtracted from the ring
roadway. This avoids a vertical step between the arm and ring.

Raised ring pavement starts from exact station quadrilaterals. The clipping
pass subtracts the footprints of arm roadway, arm pavement, flat apron, and
splitter surfaces. A broad angular opening does not match a curved arm and can
remove pavement beside the connection. A Part-centre test can leave corners
over the carriageway.

`FillTriangle` records source triangle vertices, depth, and extrusion direction.
The clipper uses that data instead of treating a Wedge as a rectangular top
surface. Adjacent curved road surfaces use shared station corners in the
current `RoadBuilder` implementation.

Paint has its own ownership rules. The ring edge line opens at the tangent
handoff. Arm markings terminate at their ring-kerb crossings, except where the
outboard edge line continues to that handoff. Turbo markings use a separate
visible top plane where they follow arm paint.

### Splitter island and centre island

A mouth without an approach median starts with a flat asphalt apron. The
splitter can become raised after the gore reaches `ISLAND_MIN_WIDTH_M`,
currently 2 m. Its nose tapers over `ISLAND_NOSE_TAPER_M`, currently 6 m. An
approach median wider than `MEDIAN_AT_CUT_M`, currently 0.5 m, can continue into
the raised splitter from the cut.

Raised splitter material must remain outside the circulating kerb. A crowded
mouth can use only a flat apron if there is no room for a raised splitter.
The final splitter frontage uses a flat underlay and a kerb-disc cutter. Only
the portion outside the circulating kerb becomes raised pavement.

The centre island follows the ring's own station boundary when its circular
scallop exceeds `ISLAND_FAN_MIN_SCALLOP_STUDS`, currently 0.02 studs. Smaller
scallops use a cylinder. Disabling the centre island leaves open ground for
landscaping; it does not create a drivable mini-roundabout centre.

## Marking modes

| Mode | Result |
| --- | --- |
| `Continuous` | Dashed circulating lane dividers. |
| `SolidLanes` | Solid circulating Drive-to-Drive dividers. |
| `Turbo` | Bounded exit peels replace matching portions of the concentric dividers. |

The regional style supplies the default. Each roundabout can override it.
Missing values retain `Continuous` mode. Pavement and centre island options are
also available as regional defaults and per-roundabout overrides.

Turbo mode keeps a constant-width ring. It does not spiral the whole annulus.
Each peel targets an actual adjacent Drive-to-Drive boundary on the exit arm.
The radial transition uses smooth interpolation, then follows the exit arm's
own line. A narrower exit can omit a peel when no compatible boundary exists.
The peel replaces its base-divider arc instead of adding a second dash pattern.
One circulating lane, no exits, or no compatible exit boundary uses the ordinary
ring marking result for that divider.

Approach arrows, destination legends, and explicit entry-to-circulating lane
connections remain separate work. Turbo markings do not provide those features.

## Validation

Run the suite from the repository root:

```sh
python3 tools/preview/validate.py
python3 tools/preview/validate.py --full
python3 tools/preview/roundabout_parity_contract.py
python3 tools/preview/turbo_check.py
python3 tools/preview/check_parity.py
```

Generate a named preview:

```sh
python3 tools/preview/roundabout_preview.py uk5mini
python3 tools/preview/roundabout_editor_preview.py --out tools/preview/out/roundabout-editor
```

These tools are Python models and source checks. They do not execute Luau or
Roblox Studio. Some rendering paths still model legacy midpoint boxes, while
current curved runtime surfaces use exact station-corner quadrilaterals.
See the [preview guide](tools/preview/README.md) for the scope of each check.

In Studio, inspect ordinary and asymmetric approaches on both traffic sides.
Check the arm cut, pavement returns, splitter frontage, lane markings, and the
full circulating width. Test radius edits, conversion, undo, and redo. Inspect
from low and high camera angles for gaps, raised wedges, and flickering faces.
Drive over the joins to check collision. Python render order cannot verify
Roblox Wedge rendering or collision.
