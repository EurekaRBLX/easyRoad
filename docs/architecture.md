# Architecture

easyRoad runs as a Roblox Studio plugin. The loader creates the toolbar button
and docks. The main module connects settings, road data, editing sessions,
geometry builders, and the React interface.

## Source layout

| Path | Responsibility |
| --- | --- |
| `loader.server.lua` | Toolbar, dock creation, and lazy loading |
| `src/main.lua` | Plugin lifecycle, shared state, and interface wiring |
| `src/Settings.lua` | Persisted preferences and backup data |
| `src/RegionStyles.lua`, `src/RegionLibrary.lua` | Built-in and custom region data |
| `src/RoadProfile.lua`, `src/RoadLibrary.lua` | Cross-sections and saved road types |
| `src/createRoadSession.lua` | Placement input, snapping, preview, and commit |
| `src/RoadEditSession.lua` | Editing placed roads and local road features |
| `src/JunctionEditSession.lua`, `src/RoundaboutEditSession.lua` | Junction and roundabout edit lifecycles |
| `src/RoadSource.lua`, `src/RoadInstance.lua` | Durable road source and placed-road metadata |
| `src/RoadSplit.lua` | Splitting roads at shared junctions |
| `src/JunctionInstance.lua`, `src/RoundaboutInstance.lua` | Persistent junction and roundabout controls |
| `src/Geometry/` | Curves, fitting, intersections, and banking |
| `src/Mesh/` | Road surfaces, markings, junctions, and roundabouts |
| `src/StructureAssets.lua`, `src/StructureBuilder.lua` | Asset validation, module placement, and generated structures |
| `src/History.lua` | Studio change recordings |
| `src/ProductLicense.lua` | Build identity and license information |
| `src/UI/` | React components and dock content |
| `src/EasyAPI/TopBarBridge.lua` | Shared top-bar placement protocol |
| `Packages/` | Included third-party modules |
| `tools/build_rbxmx.py` | XML model packaging |
| `tools/preview/` | Python geometry models and source checks |
| `reference/` | Separately licensed reference material |
| `hardware/` | Structure reference models |

The top bar uses `UI/TopBar.lua`. Placement controls use `UI/BuildBar.lua`.
`UI/RoadLibraryPanel.lua` selects profiles, and `UI/RoadDesigner.lua` edits them.
`UI/RegionalPreferenceGui.lua`, `UI/KeybindsGui.lua`, `UI/SoftwareGui.lua`, and
`UI/BackupsGui.lua` provide separate settings surfaces.

## Geometry and road data

Curve segments keep arc-length lookup tables. Builders use distance along a
curve to place cross-sections, markings, and profile transitions.

`Geometry/Superelevation.lua` supplies the banking profile.
`Mesh/RoadBuilder.lua` supplies the station plan for preview and final geometry.
Curved surfaces use shared station edges. Exact straight runs can merge
compatible surface parts to reduce the instance count.

`RoadProfile.MatchForTransition` matches components between the start and end
profiles. It can insert zero-width components so the widths change gradually.
Profile offsets preserve the selected center or edge alignment.

Placed models carry `RW_*` attributes. Sessions use those attributes to find
endpoints, profiles, tangents, and topology. `RoadSource.lua` retains source
geometry so trims and connected structures can be rebuilt.

Junctions own stable approach and corner identifiers. Roundabouts use a
circulating ring and separate entry and exit arms. Builders manage shared
surface ownership where those parts meet.

## Persistent changes

Persistent edits use ChangeHistoryService recordings through the history
helpers. Keep each user action within its recording. Do not change the
DataModel when a required recording cannot start.

Plugin preferences and custom profiles use plugin settings. Placed roads and
imported assets belong to the Roblox place. A settings JSON backup does not
replace a place backup.

## Validation boundary

Python geometry models are separate implementations. Source checks cover
selected contracts between the Python model and Luau source. They cannot prove
that all runtime behavior matches. Use the
[development guide](development.md#check-the-plugin-in-studio) for Studio checks.
