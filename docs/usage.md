# User guide

## Start the plugin

1. Open a test place in Roblox Studio.
2. Click **easyRoad** in the Plugins toolbar.
3. Complete Quick Setup.

Quick Setup selects the region, terminology, traffic side, and unit system.
Use **Settings → Regional Preference** to change these choices later. Use
**Settings → Software** to check the build or run setup again.

The top mode bar provides **Road Tools**, **Road Editor**, **Road Assets**, and
**Settings**. Settings opens separate docks for Regional Preference, Keybinds,
Software, and Backups.

## Place a road

1. Open **Road Tools**.
2. Select a road profile.
3. Select a placement tool.
4. Click the required points in the viewport.

| Tool | Points to place |
| --- | --- |
| Straight | Start, then end |
| Curve | Start, guide point, then end |
| Freeform | Start, two control points, then end |

The preview follows the pointer. Curve uses a quadratic Bezier curve.
Freeform uses a cubic Bezier curve.

| Default input | Action |
| --- | --- |
| R | Raise placement elevation |
| F | Lower placement elevation |
| Escape | Cancel placement |
| Middle mouse button | Cancel placement |

Change these bindings in **Settings → Keybinds**. Right-click is available for
Studio camera movement by default.

After placement, the tool can continue from the road just created. Use Studio
Undo to reverse a placed segment. The plugin uses ChangeHistoryService
recordings for persistent edits. It refuses an edit if it cannot start the
required recording.

## Connect roads

Start near a road endpoint to snap to it. The placement tool uses the existing
tangent to make a smooth continuation.

When an endpoint snaps to an existing road, the preview shows a blue
**SNAPPED** marker. In Road Tools, **Snap point** selects the centerline,
left roadway edge, or right roadway edge.

**Connection** selects the connection behavior:

- **Build junction** connects the road topology. It can split the target road
  and create a junction.
- **Cross-section only** aligns a ramp, flyover, or custom connection without
  splitting the target road or creating a junction pad.

A crossing at the same elevation can show a green **X INTERSECTION** marker.
Placement splits both roads into a shared junction. A red marker explains why
a crossing cannot be split. Crossings at different elevations remain separate.

To extend an existing road, select it and use **Place More** at the required
end. Check the preview before you commit the new segment.

## Widen or narrow a road

1. Select the starting road profile in Road Tools.
2. Set **Widen / narrow to** to the target profile.
3. Select the required **Lane placement** alignment.
4. Place the segment.

The profile changes from the starting profile to the target profile along the
segment. Lane placement keeps the center, left edge, or right edge fixed.
The next chained segment uses the target profile and the same alignment.

Bus-bay overlays are not supported on a profile transition. See
[known issues](../KNOWN_ISSUES.md).

## Edit a road profile

Open **Road Editor** to change the road cross-section. Components run from
left to right. Available kinds include **Drive**, **Sidewalk**, **Median**,
**Shoulder**, **Bike**, and **Parking**.

Set a width for each component. For traffic components, also set the travel
direction. Use **Duplicate road** to make an editable copy of an existing
profile. Saved user profiles persist in plugin settings.

The marking selector controls the boundaries between components. It scrolls
when the list is longer than the available panel space.

**Surface appearance** sets the Roblox material and color for each component
kind. Unset values use the active region defaults. These controls affect
generated surfaces. Imported ground road models keep their own materials
and colors.

## Place parallel roads

1. Enable parallel roadways in Road Tools.
2. Select between 2 and 16 roadways.
3. Set the gap under the advanced controls.
4. Set the travel directions.
5. Place the alignment.

A pair can use opposing directions automatically. Larger groups provide a
separate reverse setting for each roadway. Curved parallel roads use fitted
offset curves.

## Edit an intersection

1. Select the junction's asphalt pad.
2. Open the junction controls.
3. Keep **Link all corner radii** enabled for one shared corner radius.

To set one corner separately, disable the link, select its cyan handle, and
set the radius. Each connected road has a stable approach identifier. Each
corner has a separate identifier for editing and rebuilds.

## Edit a roundabout

Select the circulating ring or a generated arm to open the roundabout controls.
You can change the radius, circulating lane count, lane width, markings,
sidewalk, and center island. The panel provides radius advice for the selected
configuration.

Current connected roundabouts can be converted back to an ordinary junction.
Some older connected roundabouts are read-only because their deleted source
roads cannot be reconstructed safely. Save the place before recreating them.

## Use custom roads and structures

In Road Tools, choose the structure mode before placement:

- **Ground level** uses generated road surfaces.
- **Custom ground road** repeats an imported ground model in place of generated
  lanes, markings, kerbs, and sidewalks.
- **Elevated viaduct** adds a structure beneath the road.
- **Tunnel** adds a base, walls, and a roof around the road.

Set placement elevation above the ground for a viaduct or below it for a
tunnel. Tunnel mode does not excavate terrain.

To import a custom model:

1. Put the model in Workspace.
2. Select the model.
3. Open **Road Assets**.
4. Select the import action for Ground Road, Viaduct, or Tunnel.
5. Return to Road Tools.
6. Select the matching structure mode and the imported asset.

The asset library is stored with the place under
`ServerStorage/EasyRoadAssets`. Imported models keep their authored materials
and colors. The road profile still supplies the alignment and snapping width.

See [STRUCTURES.md](../STRUCTURES.md) for sockets, module fitting, support
geometry, and asset validation.

## Change regional and geometry settings

Open **Settings → Regional Preference**. Region presets supply traffic-side,
lane-width, marking, kerb, and banking defaults. The world scale controls the
number of studs per meter.

Superelevation is the banking of a road on a curve:

- **Auto** calculates banking from the design speed and curve radius, subject
  to the region limit.
- **Manual** applies a selected angle with the curve's direction.
- **Off** keeps the road unbanked.

Placement and geometry controls include snapping distance, grid snapping,
elevation step, road thickness, and strip length. Structure settings supply
defaults for new placement sessions. Advanced Road Tools controls can override
those defaults for a road.

## Back up settings and presets

1. Open **Settings → Backups**.
2. Select **Back up data**.
3. Copy the JSON with **Ctrl+C**.
4. Save the JSON in a file outside the plugin.

To restore data, paste the JSON into **Restore data**. Review the validation
result and preset counts. Confirm the replacement only after that review.

This backup contains plugin settings and custom road and region presets.
Placed roads and imported model assets are stored in the Roblox place.
Save the place separately to preserve them.
