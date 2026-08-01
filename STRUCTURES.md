# EasyRoad custom structures

EasyRoad keeps its existing procedural cross-section as the road surface and
can attach a repeated literal Roblox `Model` to a placed road. The first
supported structure roles are viaduct modules and tunnel modules.

Use the Road Builder's **Elevation** field (or its raise/lower keybinds) while
placing control points: positive values create an elevated alignment for
viaducts, and negative values create a sunken alignment for tunnel shells.
Changing elevation between points creates the grade already supported by the
3D road curve; structure mode supplies the previously missing deck modules,
lining, and ground-projected supports.

## Importing a Model

1. Put the source `Model` in Workspace and orient its forward direction along
   local **-Z** if it does not have explicit sockets.
2. Select the placed EasyRoad road, then Ctrl-select the source Model (or a Part
   inside it) so both remain selected.
3. In the Road Inspector choose **Elevated viaduct** or **Tunnel modules** and
   press **Import selected Model**.
4. Press **Apply to Road** to rebuild the placed road with that module.

The importer clones the Model into `ServerStorage/EasyRoadAssets`. The source
remains untouched in Workspace and may be deleted afterward. The stored clone,
its generated ID, and the road's configuration are saved with the Roblox place;
no external asset upload is required.

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

An elevated viaduct may omit a custom module; the procedural EasyRoad surface
then acts as the deck. Auto piers start halfway into the chosen spacing and
raycast vertically down. Generated road, junction, and roundabout folders are
excluded so a pier searches for Terrain or world geometry rather than landing
on another generated road. No pier is made for a miss, a hit beyond Max drop,
or a ground-level hit with no visible clearance.

The generic concrete pier is intentionally simple. Custom pier Models and
explicit pier sockets are later extensions.

## Tunnels

Tunnel mode requires an imported tunnel module and repeats it along the road.
It does **not** edit Roblox Terrain. Excavating and later restoring Terrain is a
destructive operation with different undo/data requirements, so it will be a
separate explicit feature rather than a side effect of selecting a tunnel
shell.

## Generated data

- Asset library: `ServerStorage/EasyRoadAssets`
- Road configuration attribute: `RW_StructureJson`
- Generated road child: `EasyRoadStructure`
- Generated subfolders: `Modules`, and `Piers` for viaducts

Generated children are disposable. EasyRoad recreates them from the serialized
road configuration after lane, marking, bus-bay, split, junction, and
roundabout rebuilds. Edit the source library Model and re-apply only after a
future replace/update workflow exists; direct edits to generated clones will be
overwritten.
