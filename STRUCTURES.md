# Custom roads and structures

An imported Roblox `Model` can repeat along a road alignment. A **Ground road**
asset supplies the visible road, markings, kerbs, and pavement. **Viaduct** and
**Tunnel** assets supply structure around the generated road surface. These
roles use the same rigid module placement and saved asset library.

## Select a structure

1. Open **Road Tools**.
2. Find **Structure**.
3. Choose **Ground level**, **Custom ground road**, **Elevated viaduct**, or **Tunnel**.
4. Set **Elevation** for the alignment.
5. Select an imported asset if required.
6. Place the road.

Positive elevation puts the alignment above the terrain. Negative elevation
puts it below the terrain. Elevation changes between control points set the
road grade. The structure choice remains active along the placement chain.

A custom Ground road requires an imported Ground asset. Viaduct and Tunnel
modes can use an imported asset or generated structure.

Open **Edit advanced structure options** for finish, fit, pier, and module
placement fields. Settings supplies the defaults for new placement sessions.
Generated base, edge wall, tunnel sidewall, and roof surfaces have independent
material and colour controls. Imported Models keep their authored appearance.

## Import a Model

1. Put the source Model in Workspace.
2. Orient its forward direction along local **-Z**, or add explicit sockets.
3. Select the Model.
4. Open **Road Assets**.
5. Select the matching **Import Selection** action for Ground Road, Viaduct, or Tunnel.
6. Select that asset in **Road Tools** before placement.

For an existing road, select it and open **Edit on Road Builder**. Choose the
asset, then select **Apply to Road**.

The importer clones the Model into `ServerStorage/EasyRoadAssets`. The source
Model remains in Workspace. The stored clone, its generated ID, and each road's
asset reference are saved with the place. No asset upload is required.

**Export Selected Asset to Workspace** creates a uniquely named inspection
copy. It preserves the stored asset ID and usage count. Import, rename, and
delete operations use Studio undo history. The library refuses deletion while
a placed road references the asset.

Rendered copies are anchored. Scripts and LocalScripts in each copy are
disabled. ModuleScripts remain as data and are not executed by the tiler. Put
active behavior in a separate controller if the generated road needs scripts.

## Sockets and rigid fit

Add these Attachments inside the Model for explicit joints:

| Attachment | Position |
| --- | --- |
| `EasyRoadStart` | Centre of the module's start joint. |
| `EasyRoadEnd` | Centre of the module's end joint. |

The distance between the sockets defines the module chord. The Start socket's
UpVector defines source roll. The road curve supplies target roll.

Use both sockets or neither. With neither socket, the importer adds them at
the oriented bounding box's +Z and -Z faces. It uses a transparent,
non-colliding helper Part. Explicit sockets are preferable for asymmetric
bridges, overlap joints, and tunnel portals.

The importer rejects a lone socket, duplicate socket names, overlapping
sockets, and sockets far outside the bounds. It warns about modest external
overlap, a Start socket facing away from End, or opposed UpVectors. Those
layouts can be intentional when the chord is unambiguous.

Modules remain rigid. The tiler rotates and repeats them; it does not bend
meshes. Use shorter modules on tight curves or rapid grade changes. The final
module can overlap the preceding module to cover the endpoint. If the entire
road is shorter than one module, the full module remains. The road status
reports its endpoint overshoot.

## Ground road assets

Author the road surface, markings, kerbs, medians, barriers, collision, and
metadata in one Model. Put the sockets on the datum that must follow the
alignment, usually the carriageway centre at surface height. The advanced
**Y offset** moves the repeated asset relative to that datum.

The road profile remains the alignment, width, snapping, and junction topology
source. Placement previews show that profile as the alignment envelope. The
committed road shows the imported Model.

The builder first creates a recoverable procedural road. It validates and
clones the modules before it removes generated surface Parts. The asset then
owns visible geometry, collision, materials, and hierarchy. Bus-bay and
marking-stretch data remain saved, but their procedural visuals are not added
over the Ground asset. Author equivalent details in the asset when needed.

## Generated viaducts

Without a custom asset, viaduct mode builds a thin structural base and edge
walls. Piers project vertically to Terrain or other eligible world geometry.
Generated roads, junctions, and roundabouts are excluded from that projection.

Single-pier layout uses one centre column. Twin-pier layout projects both
lateral column positions. It emits the pair only when both find usable ground,
then adds a transverse cap beam. A missed projection, a drop beyond the
configured maximum, or insufficient visible clearance produces no pier.

Slab and parapet segments include outside-edge arc allowance to reduce gaps
on bends. Interface overlap seats the base into the road underside. It is
capped to keep the base at least 0.08 studs below the road surface. Parapet gap
is measured outward from the road edge. Custom pier assets and explicit pier
sockets are not available.

## Generated tunnels

Without a custom asset, tunnel mode builds a thin base, extended sidewalls,
and a nine-panel elliptical vault. The shell follows the alignment and uses
the widest cross-section. The base clearance cap keeps it below the asphalt.

Tunnel mode does not excavate or restore Roblox Terrain. Prepare the opening
separately in Studio.

## Saved and generated data

| Data | Location or name |
| --- | --- |
| Asset library | `ServerStorage/EasyRoadAssets` |
| Road configuration attribute | `RW_StructureJson` |
| Generated child | `EasyRoadStructure` |
| Generated subfolders | `Modules`, `Piers`, `ProceduralViaduct`, `ProceduralTunnel` |
| Suppressed surface count | `EasyRoadStructure.RW_SuppressedSurfacePartCount` |

Generated children are disposable. Supported road rebuilds recreate them from
saved configuration. Direct edits to generated clones are overwritten.
Structured roads cannot yet split into junction pieces because module and pier
spacing require a shared phase. The library has no replace/update workflow for
an existing asset. Import a new asset and select it explicitly when changing
the module source.

## Reference geometry and checks

The five `hardware/*.rbxmx` files provide geometry references. They do not
populate the asset library automatically. Their redistribution provenance
must be confirmed before a public release. See the
[release checklist](docs/release-readiness.md).

Run the relevant checks from the repository root:

```sh
python3 tools/preview/hardware_reference_check.py
python3 tools/preview/structure_preview.py --check
python3 tools/preview/ground_asset_preview.py --check
python3 tools/preview/structure_break_tests.py
```

The Python tools check reference dimensions, module fit, socket validation,
procedural structures, and selected source contracts. They do not execute the
plugin. Inspect fit, collision, grade changes, undo, and asset rebuilds in
Studio before release.
