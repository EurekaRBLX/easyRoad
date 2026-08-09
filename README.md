# easyRoad

A Roblox Studio plugin for building roads the way Cities: Skylines 2 does:
click-to-place curve tools, automatic superelevation (banking), lane
widening/narrowing transitions, fully configurable custom road
cross-sections, and regional style presets (US / UK / EU / JP / AU).

Build it with [Rojo](https://rojo.space) (`aftman install` provides it):

```
rojo build default.project.json -o EasyRoad.rbxm
```

Then drag the `.rbxm` into your Studio plugins folder (or use
`rojo build --plugin EasyRoad.rbxm`... i.e. install as a local plugin).

**No toolchain?** Two alternatives:

* Download the commercial/EULA [`dist/EasyRoad.rbxmx`](dist/EasyRoad.rbxmx)
  or the [`dist/EasyRoad-OSS.rbxmx`](dist/EasyRoad-OSS.rbxmx) build from this
  repo and drop it in your Studio plugins folder (Studio loads `.rbxmx` the
  same as `.rbxm`). Both are rebuilt whenever the source changes.

To rebuild both variants yourself without Rojo:

```
python3 tools/build_rbxmx.py --license commercial
python3 tools/build_rbxmx.py --license oss
```

## Using it

1. Click the **EasyRoad** toolbar button. On first launch, Quick Setup walks
   through region, terminology, traffic side, and Roblox/metric/imperial units;
   its choices remain editable under Settings. The panel then opens and the
   placement tool activates.
2. Pick a tool:
   * **Straight** — click start, click end.
   * **Curve** — click start, click a guide point (controls the tangent),
     click end. Quadratic bezier, like CS2's curved tool.
   * **Freeform** — click start, two control points, then the end. Cubic
     bezier.
3. Pick a road from the **Road** dropdown (the built-in set is generated
   from the active region style).
4. Click in the viewport to place points. A ghost preview follows the mouse.
   * **R / F** raise or lower the placement elevation.
   * **Right-click / Esc** cancels the current placement.
   * Starting a road near the end of an existing one snaps to it and locks
     the tangent for a smooth continuation (and after each placement the
     tool chains from the road you just placed).
   * Finishing near an existing road shows a blue **SNAPPED** marker. In Road
     Tools, **Snap point** chooses its centreline, left roadway edge, or right
     roadway edge; the choice is remembered between sessions.
   * Drawing completely across another road shows a green **X INTERSECTION**
     marker and splits both roads into one real junction when placed. Red
     markers explain crossings that cannot safely be split; roads at a
     different elevation remain grade-separated.
5. **Widening / narrowing**: set the "Widen / narrow to" dropdown to a
   second road profile. The segment you place transitions from the current
   profile at its start to the target profile at its end — lane widths (and
   the markings between them) interpolate along the segment, extra lanes
   taper in/out. **Lane placement** chooses whether the centre, left edge, or
   right edge stays fixed, so the new lane appears on the intended side. After
   placing a transition, the chain continues with the target profile on that
   same alignment.
6. **Viaducts and tunnels**: in Road Tools choose the structure mode before
   placing. Viaduct mode generates a structural slab, edge parapets, and
   terrain-projected concrete piers; Tunnel mode generates a base, tall walls,
   and a segmented arched vault. To replace either procedural structure, open
   **Road Assets**, import a Workspace Model, then choose it from Road Tools.
   See [`STRUCTURES.md`](STRUCTURES.md).
7. **Parallel roadways**: enable the option in Road Tools, choose 2-16
   carriageways, and set the edge-to-edge gap under Advanced. A pair can be
   made opposing automatically; larger groups expose an independent reverse
   switch for each roadway. Curves are laterally refitted instead of copied by
   one fixed world offset.
8. **Edit an intersection**: select its asphalt pad. The junction panel shows
   one stable approach port per connected road and one cyan handle per curb
   corner. Keep **Link all corner radii** enabled for one shared value, or turn
   it off, click a cyan handle, and set that corner's turn radius independently.
9. **Edit a roundabout**: select the circulating ring or any generated arm.
   The roundabout panel edits radius, circulating lane count, lane width,
   markings, pavement, and centre island, with minimum/suggested-radius advice.
   Connected rings can be converted back to an ordinary junction. Older
   connected rings remain read-only because their deleted source approaches
   cannot be reconstructed safely; recreate that junction once to opt in.

The Highways category includes one-way 1, 2, 3, 4, and 5-lane presets with an
inner and outer shoulder, intended for the parallel-carriageway workflow.

### Custom roads (Edit Roads...)

The road editor edits a road's cross-section as an ordered list of
components, left to right: **Drive**, **Sidewalk**, **Median**, **Shoulder**,
**Bike**, **Parking**. Each has a width in meters, and traffic-carrying
kinds have a direction (with/against the road). **Duplicate road** turns the
current built-in or user road into a separately named, editable user type;
user roads persist in plugin settings across sessions. The lane-marking
selector stays inside the editor at narrow widths, opens upward from the
bottom bar, and scrolls through every marking choice.

Persistent Studio changes use isolated ChangeHistoryService recordings. Each
placed segment, roundabout, junction edit, road rebuild, or asset operation is
therefore one Ctrl+Z step; EasyRoad refuses to mutate the DataModel if Studio
cannot open that action's recording.

### Grand settings (Settings...)

* **Region** — US / UK / EU / JP / AU preset. Controls drive side, default
  lane/sidewalk/shoulder widths, marking colors and dash patterns (double
  solid yellow center line in the US, dashed white in the UK, ...), curb
  height, and the maximum superelevation rate. Changing region regenerates
  the built-in road set.
* **Studs per meter** — the world scale (default 3.571, i.e. 1 stud = 0.28m).
* **Superelevation** — `Auto` derives the bank from the design speed and
  curve radius using the standard highway design relationship
  `e + f = V² / (127R)`, clamped to the region's maximum, with a smoothed
  runoff so the bank develops gradually. `Manual` applies a fixed angle
  signed by curve direction. `Off` builds flat roads.
* **Placement** — endpoint snap radius, optional grid snapping, elevation
  step for R/F.
* **Geometry** — road deck thickness and maximum strip length (strips adapt
  automatically: shorter where curvature is higher).

Settings also holds procedural-structure defaults: concrete colour,
road/structure overlap, viaduct parapet gap, tunnel wall clearance, elevated
concrete median, and the parallel-roadway gap. A road copies these when its
placement session starts and Road Tools Advanced can override them.

The Settings menu also includes **Software**, showing the local easyRoad build
and product information.

* **Data safety** — **Back up data** exposes portable JSON for plugin settings
  and custom road/region presets; copy it with Ctrl+C. **Restore data** accepts
  that JSON, validates it, previews the number of presets, and requires a
  second confirmation before replacing the current plugin data. Placed roads
  remain stored in the open place and are not part of this backup.

## Architecture

```
loader.server.lua          Toolbar button + dock panel + lazy loading
src/
  main.lua                 Wires settings, library, session, and UI together
  Settings.lua             Persisted grand settings (region, scale, snapping, ...)
  RegionStyles.lua         US/UK/EU/JP/AU style presets (pure data)
  RoadProfile.lua          Cross-section data model + transition matching
  RoadLibrary.lua          Built-in (style-derived) + user-saved road profiles
  createRoadSession.lua    Interactive placement: clicks, snapping, preview, undo
  RoadSplit.lua            Splits one road at one or more shared junction nodes
  JunctionInstance.lua     Junction owner plus serialized multinode controls
  RoundaboutInstance.lua   Selectable ring metadata linked to its controller
  RoundaboutEditSession.lua Selection, undo, rebuild, and conversion lifecycle
  RoadSource.lua           Durable untrimmed one-segment road source metadata
  StructureAssets.lua      Imports game-owned custom bridge/tunnel Models
  StructureBuilder.lua     Tiles modules; builds viaducts, tunnels, and piers
  Geometry/
    CurveSegment.lua       Line / quadratic / cubic segments, arc-length tables,
                           signed ground-plane curvature
    PolyCurve.lua          Segment chains evaluated by distance; frames with roll
    CurveIntersections.lua Ground-plane curve crossings + bounded refinement
    Fitting.lua            Click patterns -> segments (incl. tangent-locked fits)
    Superelevation.lua     Bank angle from curvature + design speed; runoff smoothing
  Mesh/
    Markings.lua           Cross-section boundaries -> marking line layout
    RoadBuilder.lua        Curve + profile + style -> Model of parts
    JunctionBuilder.lua    Stable approach/corner nodes, trims, pad, and curb returns
    RoundaboutBuilder.lua  Ring/arms plus persistent rebuild and conversion
  UI/
    Theme.lua              Colors and metrics
    Components.lua         Button / dropdown / number field / checkbox / rows
    RoadAssetsPanel.lua    Imports, renames, and removes custom structure Models
    EasyRoadGui.lua        Main panel + page routing
    LaneEditor.lua         Custom road (cross-section) editor
    SettingsGui.lua        Grand settings page
```

The code is layered in three parts: a **functionality layer**
(`createRoadSession` + `Mesh/` + `Geometry/`) that handles input, previews,
and placement; a **settings layer** (`Settings`, `RegionStyles`,
`RoadProfile`, `RoadLibrary`) that feeds configuration into it; and a
**React UI layer** (`UI/`) that edits the settings and drives the session.

Key mechanics:

* **Arc-length parameterization** — every curve segment precomputes a
  length lookup table, so cross-sections, dash patterns, and transitions are
  spaced by real distance along the road, not by bezier parameter.
* **Adaptive stripping** — the builder subdivides by chord-deviation
  tolerance (`step ≈ √(8·tol/κ)`), so tight curves get short strips and
  straights get long ones.
* **Transitions** — `RoadProfile.MatchForTransition` aligns two profiles
  component-by-component from the outer edges inward, padding the middle
  with zero-width lanes so widths (and markings) lerp cleanly along the
  segment.
* **Snapping metadata** — each placed road model carries `RW_*` attributes
  (endpoint positions, tangents, profile ids), which is what endpoint
  snapping and tangent continuation read back. At-grade interior crossings
  split both curves around a shared junction id.

## Roadmap / not yet implemented

* Junction lane guidance, stop/give-way lines, crosswalks and box markings.
* Explicit undoable Terrain excavation/restoration for tunnels.
* Custom portal, abutment, and pier assets.
* Arrow / text surface decals (turn arrows, crosswalks).
* A real toolbar icon.
