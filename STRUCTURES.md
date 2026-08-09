# EasyRoad custom structures

EasyRoad keeps its existing procedural cross-section as the road surface and
can attach a repeated literal Roblox `Model` while placing or editing a road.
The supported structure roles are viaducts and tunnels.

Use the Road Builder's **Elevation** field (or its raise/lower keybinds) while
placing control points: positive values create an elevated alignment for
viaducts, and negative values create a sunken alignment for tunnel shells.
Changing elevation between points creates the grade already supported by the
3D road curve; structure mode supplies the previously missing deck modules,
lining, and ground-projected supports.

## Building from Road Tools

1. Open **Road Tools** and scroll to **Structure**.
2. Choose **Ground level**, **Elevated viaduct**, or **Tunnel**.
3. Set **Elevation** above the terrain for a viaduct or below it for a tunnel.
4. Place the road normally. The selected structure is serialized and generated
   as soon as each segment is committed; the choice stays active along the
   placement chain.

Without a custom module, viaduct mode builds a thin central structural base and
edge parapet/fascia walls beneath/along the generated road, then raycasts piers
down to the world. Tunnel mode builds a thin base, bottom-extended sidewalls,
and a segmented arched vault.

Road Tools keeps the common mode/asset choices visible and collapses the
geometry fields under **Edit advanced structure options**. Those fields control
independent material/colour finishes for the structural base, viaduct edge
walls, tunnel sidewalls, and tunnel roof; the small overlap that seats the road
into the structure; parapet gap or tunnel wall clearance; pier layout and
dimensions; and whether a viaduct matches generated grass medians to its base
finish. Settings exposes the same finish and fit values as defaults for new
placement sessions. Imported modules keep their authored appearance.

## Importing a Model

1. Put the source `Model` in Workspace and orient its forward direction along
   local **-Z** if it does not have explicit sockets.
2. Open **Road Assets** from the top mode bar, then press **Import Selection as
   Viaduct** or **Import Selection as Tunnel**. The same surface lists every
   stored asset and provides rename/delete controls.
3. Open **Road Tools**, choose the matching structure mode and select the
   imported asset before placing. For an existing road, select it, open **Edit
   on Road Builder**, choose the asset, then press **Apply to Road**.

To edit or inspect a stored module in the world, select it in **Road Assets**
and press **Export Selected Asset to Workspace**. EasyRoad creates and selects
a uniquely named Workspace copy while leaving the ServerStorage library asset,
its asset ID, and its placed-road usage count unchanged.

The importer clones the Model into `ServerStorage/EasyRoadAssets`. The source
remains untouched in Workspace and may be deleted afterward. The stored clone,
its generated ID, and the road's configuration are saved with the Roblox place;
no external asset upload is required.

Deletion is refused while a placed road still references the asset, so a road
cannot silently lose its structure source. Rename and all import/delete changes
participate in Studio undo history.

Scripts and LocalScripts inside rendered module clones are disabled so a
single source script is not executed once per repeated road module. ModuleScripts
are preserved as inert data. Put active road behaviour in a separate controller
that discovers generated modules instead of embedding it in the tiled Model.

## Socket contract

For precise joints, add these Attachments anywhere inside the source Model:

- `EasyRoadStart` - centre of the module's start joint;
- `EasyRoadEnd` - centre of the module's end joint.

Their position-to-position distance is the rigid module chord. The Start
Attachment's UpVector establishes source roll; the road curve supplies the
target roll. When either socket is missing, the importer adds both at the
oriented bounding box's +Z/-Z faces using a transparent non-colliding Part.
That fallback makes ordinary Models usable, but explicit sockets are recommended
for asymmetric bridges, deliberate overlap joints, and tunnel portals.

A Model is rigid: EasyRoad rotates and repeats clones but does not bend their
meshes. Use shorter modules on tight curves and steep grade changes. The last
module may overlap its predecessor so the road ends at a socket instead of
leaving an uncovered gap.

## Viaducts

An elevated viaduct may omit a custom module. EasyRoad then emits a continuous,
thin structural base below the road plus parapet/fascia walls at both
outer edges. Those walls extend downward to retain the old structural depth
without carrying a broad concrete block up near the asphalt. Auto piers are
distributed along the span (including one on short spans) and meet the slab
underside after raycasting vertically down. Single layout emits one adjustable
centre pillar. Twin layout raycasts both configurable lateral centres
independently, emits the pair only when both projections find usable ground,
and places an adjustable transverse cap beam between the columns and slab.
Generated road, junction, and roundabout folders are
excluded so a pier searches for Terrain or world geometry rather than landing
on another generated road. No pier is made for a miss, a hit beyond Max drop,
or a ground-level hit with no visible clearance.

The generic procedural support can use the configured structural base material
and colour. Custom pier Models and explicit pier sockets are later extensions.

Procedural slab/parapet segments use outside-edge arc allowance in their
longitudinal depth, so bends and grade changes overlap instead of opening a
hairline between rigid Parts. The default interface overlap also seats the base
slightly into the road underside, but it is capped so the concrete always stays
at least 0.08 studs below the road surface. Set it to zero only for a deliberate
flush underside joint. Parapet gap is measured outward from the road edge.

## Tunnels

Tunnel mode repeats an imported tunnel module when one is selected. With no
custom asset it builds a thin concrete base, sidewalls extended below that base
to preserve the shell depth, and a nine-panel elliptical vault following every
road segment, sized from the road's widest cross-section. The same surface-
clearance cap prevents the base from covering the generated asphalt.

It does **not** edit Roblox Terrain. Excavating and later restoring Terrain is a
destructive operation with different undo/data requirements, so it remains a
separate explicit feature rather than a side effect of selecting a tunnel.

## Generated data

- Asset library: `ServerStorage/EasyRoadAssets`
- Road configuration attribute: `RW_StructureJson`
- Generated road child: `EasyRoadStructure`
- Generated subfolders: `Modules`, `Piers`, `ProceduralViaduct`, or `ProceduralTunnel`

Generated children are disposable. EasyRoad recreates them from the serialized
road configuration after lane, marking, bus-bay, split, junction, and
roundabout rebuilds. Edit the source library Model and re-apply only after a
future replace/update workflow exists; direct edits to generated clones will be
overwritten.

## Hardware references and validation

The `hardware/*.rbxmx` files are geometry references, not automatically shipped
as a user's asset library. Their deck, parapet, wall, and crown proportions
informed the procedural defaults. `tools/preview/hardware_reference_check.py`
parses those XML files, while `structure_preview.py` validates and renders the
procedural slab/piers, twin cap beam, independently styled wall/roof channels,
and arched tunnel cross-section without Roblox Studio.
