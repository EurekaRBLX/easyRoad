# Known issues

Check these limitations before you use a new build in an existing place.
Save a separate copy of the place before testing changes.

## Curves and roundabout connections need Studio confirmation

The current geometry uses shared station edges for curved surfaces. Connected
roundabout arms and the ring also use one surface elevation.

Headless checks cover the intended geometry. They do not confirm Roblox Wedge
rendering, collision, or surface flicker in Studio. Check chained curves and
each roundabout connection after you install a new build. Include screenshots
and the road settings if you report a visible defect.

## Bus-bay kerb markings do not follow the bay

A bus bay moves the sidewalk outward. A kerb-restriction marking can remain at
the original kerb position instead of following the bay. Avoid that marking
on the affected segment until the marking path supports the bay offset.

## Bus bays are suppressed on profile transitions

The plugin does not apply a bus-bay overlay to a road that widens or narrows.
It builds the complete transition road without the bay. Use a separate road
segment with a constant profile for the bus bay.

## Older connected roundabouts can be read-only

Some older roundabouts do not retain the source roads needed for a safe
rebuild. The plugin keeps those roundabouts read-only. Recreate the junction
and roundabout if you need the current editing workflow. Save the place first.

## Tunnel shells do not excavate terrain

Tunnel mode builds the structure around the road. It does not remove or restore
Roblox Terrain. Manage terrain separately and keep a place backup.

## Viewport input can be blocked by interface hover state

Past defects left the interface marked as hovered after a panel or button
closed. This blocked placement clicks. Those reported cases were fixed, but
the behavior remains a regression risk.

If viewport clicks stop working, cancel placement and reopen the plugin.
Report the interface action that occurred immediately before the problem.
Include the plugin build and the active tool.

## Automated checks do not run the plugin

The Python checks model geometry and inspect selected source contracts. They
do not execute the plugin in Roblox Studio. A passing check does not establish
that every interface action or runtime path works. See the
[development guide](docs/development.md#validation) for the required live checks.
