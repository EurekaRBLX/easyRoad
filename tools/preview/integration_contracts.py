#!/usr/bin/env python3
"""Static wiring checks for Studio-only interaction paths.

These do not execute Luau. They protect the exact contracts that previously
made a feature look shipped while remaining unreachable in Studio: queryable
junction geometry, placement-time structure controls/rendering, lateral road
snap references, dedicated asset management, procedural viaduct/tunnel
fallbacks, and the Software dock.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


def require(text, needle, message, problems):
    if needle not in text:
        problems.append(message)


def reject(text, needle, message, problems):
    if needle in text:
        problems.append(message)


def require_count(text, needle, minimum, message, problems):
    if text.count(needle) < minimum:
        problems.append(message)


def max_motor_lanes_per_carriageway(components):
    """Executable contract for RoadProfile.MaxMotorLanesPerCarriageway.

    Component tuples are (kind, width_m, direction). A Median separates
    carriageways; direction signs separate flows on an undivided carriageway.
    """
    maximum = forward = backward = undirected = 0

    def flush():
        nonlocal maximum, forward, backward, undirected
        maximum = max(maximum, forward, backward, undirected)
        forward = backward = undirected = 0

    for kind, width_m, direction in components:
        if kind == "Median":
            flush()
        elif kind == "Drive" and width_m > 1e-6:
            if direction > 0:
                forward += 1
            elif direction < 0:
                backward += 1
            else:
                undirected += 1
    flush()
    return maximum


def main():
    problems = []
    junction = source("src/Mesh/JunctionBuilder.lua")
    history = source("src/History.lua")
    junction_instance = source("src/JunctionInstance.lua")
    junction_session = source("src/JunctionEditSession.lua")
    junction_panel = source("src/UI/JunctionPanel.lua")
    session = source("src/createRoadSession.lua")
    build_bar = source("src/UI/BuildBar.lua")
    structure = source("src/StructureBuilder.lua")
    structure_controls = source("src/UI/StructureControls.lua")
    regional_preferences = source("src/UI/RegionalPreferenceGui.lua")
    structure_materials = source("src/StructureMaterials.lua")
    settings = source("src/Settings.lua")
    road_instance = source("src/RoadInstance.lua")
    road_split = source("src/RoadSplit.lua")
    profiles = source("src/RoadProfile.lua")
    curve = source("src/Geometry/CurveSegment.lua")
    parallel_controls = source("src/UI/ParallelControls.lua")
    road_designer = source("src/UI/RoadDesigner.lua")
    road_edit_session = source("src/RoadEditSession.lua")
    markings = source("src/Mesh/Markings.lua")
    road_builder = source("src/Mesh/RoadBuilder.lua")
    loader = source("loader.server.lua")
    main_source = source("src/main.lua")
    top_bar = source("src/UI/TopBar.lua")
    asset_panel = source("src/UI/RoadAssetsPanel.lua")
    software = source("src/UI/SoftwareGui.lua")
    multinode_preview = source("tools/preview/multinode_junction_preview.py")
    preview_core = source("tools/preview/preview_core.py")
    roundabout = source("src/Mesh/RoundaboutBuilder.lua")
    roundabout_instance = source("src/RoundaboutInstance.lua")
    roundabout_session = source("src/RoundaboutEditSession.lua")
    roundabout_panel = source("src/UI/RoundaboutPanel.lua")
    road_source = source("src/RoadSource.lua")
    roundabout_preview = source("tools/preview/roundabout_preview.py")
    roundabout_editor_preview = source("tools/preview/roundabout_editor_preview.py")
    dump_compare = source("tools/preview/dump_compare.py")

    require(history, "ChangeHistoryService:TryBeginRecording", "history transactions never start a Studio recording", problems)
    require(history, "if not recording then", "history transactions mutate even when Studio refuses a recording", problems)
    require(history, "xpcall(function()", "history transactions can leak an open recording after a runtime error", problems)
    require(history, "ChangeHistoryService:FinishRecording", "history transactions never close their Studio recording", problems)
    require(history, "else Enum.FinishRecordingOperation.Commit", "partial runtime failures lose their Undo recovery point", problems)
    for label, mutation_source in (
        ("road placement", session),
        ("road editing", road_edit_session),
        ("junction editing", junction_session),
        ("roundabout editing", roundabout_session),
        ("main actions", main_source),
    ):
        reject(mutation_source, "TryBeginRecording", f"{label} bypasses the guarded history transaction helper", problems)
        reject(mutation_source, "FinishRecording", f"{label} can leave a Studio history recording open", problems)
    require(session, 'History.Record("EasyRoadPlace", "Place road"', "road placement is not one Undo transaction per segment", problems)
    require(session, 'History.Record("EasyRoadPlace", "Place roundabout"', "roundabout placement is not an isolated Undo transaction", problems)

    require(junction, 'part.Name = "JunctionSurface"', "junction surface factory missing", problems)
    surface_factory = junction[junction.find('part.Name = "JunctionSurface"'):]
    require(surface_factory[:900], "part.CanQuery = true", "visible junction pad is not selectable", problems)
    require(surface_factory[:900], "part.CanCollide = true", "junction surfaces do not carry vehicles", problems)
    require(road_builder, "part.CanCollide = not preview", "placed road surfaces are not collidable", problems)
    marking_factory = road_builder[road_builder.find('part.Name = "Marking"'):]
    require(marking_factory[:500], "part.CanCollide = false", "lane paint becomes a physical bump", problems)
    structure_factory = structure[structure.find("local function makeStructurePart"):]
    require(structure_factory[:900], "part.CanCollide = true", "procedural slabs, walls, pillars, or beams are not collidable", problems)
    island_factory = roundabout[roundabout.find('part.Name = "Island"'):]
    require(island_factory[:500], "part.CanCollide = true", "roundabout island is not collidable", problems)
    roundabout_surface_factory = roundabout[roundabout.find("local function makeSurfacePart"):]
    require(roundabout_surface_factory[:600], "part.CanCollide = true", "roundabout replacement surfaces are not collidable", problems)
    splitter_factory = roundabout[roundabout.find("local function buildSplitterIsland"):]
    require(splitter_factory[:1200], "part.CanCollide = true", "roundabout splitter surfaces are not collidable", problems)
    require(road_instance, 'model:SetAttribute("RW_RoadId"', "roads have no stable id for junction approach ports", problems)
    require(road_instance, 'model:SetAttribute("RW_StartPortId"', "road starts have no stable approach-port identity", problems)
    require(road_instance, 'model:SetAttribute("RW_EndPortId"', "road ends have no stable approach-port identity", problems)
    require(road_split, "RoadInstance.PreserveOuterPortIds", "road splitting discards existing junction approach identities", problems)
    require(junction_instance, 'model:SetAttribute("RW_MultiNodeVersion", 2)', "junctions are not stamped as multinode v2", problems)
    require(junction_instance, "CornerRadiiM: { [string]: number }", "junctions do not persist per-corner radii", problems)
    require(junction_instance, "ApproachSetbacksStuds: { [string]: number }", "junctions do not persist per-approach setbacks", problems)
    require(junction_instance, 'model:SetAttribute("RW_ApproachSetbacksJson"', "per-approach setbacks are not serialized", problems)
    require(junction_instance, "function JunctionInstance.SetApproachSetbackStuds", "per-approach setbacks cannot be set or reset", problems)
    require(junction, "FromApproachId: string", "junction layout does not expose approach-linked corner nodes", problems)
    require(junction, "radiusForCorner(junctionData, id)", "junction geometry ignores per-corner radius overrides", problems)
    require(junction, "function JunctionBuilder.ApproachTrimRadiusStuds", "junctions have no endpoint-specific trim radius", problems)
    require(junction, "trimStationFor(data.StartJunctionId, data.StartPortId, true)", "junction start cuts ignore their stable port setback", problems)
    require(junction, "trimStationFor(data.EndJunctionId, data.EndPortId, false)", "junction end cuts ignore their stable port setback", problems)
    require(junction_session, 'c:SetAttribute("RW_CornerId", corner.Id)', "corner handles do not retain stable corner identities", problems)
    require(junction_session, 'bar:SetAttribute("RW_ApproachId", mouth.Id)', "mouth handles do not retain stable approach identities", problems)
    require(junction_session, "SetSelectedCornerRadiusM", "selected corner radius cannot be edited", problems)
    require(junction_session, "GetApproachSetbacks", "junction sessions do not expose approach setback rows", problems)
    require(junction_session, "ResetApproachSetbackStuds", "junction sessions cannot return an approach to the default setback", problems)
    require(junction_panel, 'Label = "Link all corner radii"', "junction editor cannot switch to per-corner radii", problems)
    require(junction_panel, 'Text = "Default setback"', "junction editor does not distinguish its inherited setback", problems)
    require(junction_panel, '"Edit individual setbacks"', "junction editor has no advanced per-roadway setback disclosure", problems)
    require(junction_panel, "props.OnApproachSetbackChanged(row.Id, nil)", "junction editor Reset does not restore inheritance", problems)
    require(main_source, "ApproachSetbacks = junctionEditSession.GetApproachSetbacks()", "per-approach setback rows are not wired into the junction panel", problems)
    packing_start = roundabout.find("local function packingRadiusStuds")
    packing_end = roundabout.find("function RoundaboutBuilder.MinimumRadiusStuds", packing_start)
    packing = roundabout[packing_start:packing_end]
    require(packing, "ringSidewalkWidthM(style)", "junction panel radius suggestion passes nil pavement width to armProfileFor", problems)
    require(main_source, "local ok, radii = pcall", "roundabout advice is not isolated from the selected-junction panel", problems)
    require(main_source, "junction editor remains available", "roundabout advice failure has no panel-safe fallback", problems)
    require(profiles, "function RoadProfile.MaxMotorLanesPerCarriageway", "profiles cannot infer the widest motor carriageway", problems)
    lane_rule_start = profiles.find("function RoadProfile.MaxMotorLanesPerCarriageway")
    lane_rule_end = profiles.find("function RoadProfile.IsRaised", lane_rule_start)
    lane_rule = profiles[lane_rule_start:lane_rule_end]
    require(lane_rule, 'component.Kind == "Median"', "roundabout lane advice does not separate divided carriageways", problems)
    require(lane_rule, 'component.Kind == "Drive" and component.WidthM > 1e-6', "roundabout lane advice counts shoulders/non-drive reserve", problems)
    require(lane_rule, "forward += 1", "roundabout lane advice does not count forward traffic independently", problems)
    require(lane_rule, "backward += 1", "roundabout lane advice does not count opposing traffic independently", problems)
    require(roundabout, "function RoundaboutBuilder.SuggestedLaneCount", "roundabout builder has no connected-profile lane suggestion", problems)
    require(roundabout, "RoadProfile.MaxMotorLanesPerCarriageway(profile)", "roundabout lane suggestion bypasses the carriageway rule", problems)
    require(roundabout, "data.ProfileEnd or data.ProfileStart", "roundabout lane suggestion ignores the connected endpoint profile", problems)
    require(main_source, "pcall(RoundaboutBuilder.SuggestedLaneCount", "junction UI does not isolate or request roundabout lane advice", problems)
    require(main_source, "SuggestedRoundaboutLaneCount = suggestedRoundaboutLaneCount", "junction UI does not receive roundabout lane advice", problems)
    require(junction_panel, "SuggestedRoundaboutLaneCount: number", "junction panel has no suggested circulating-lane input", problems)
    require(junction_panel, "local laneCountTouched", "junction panel cannot preserve an explicit lane-count override", problems)
    require(junction_panel, "setLaneCount(suggestedLaneCount)", "junction panel does not apply the connected-road lane suggestion", problems)
    require(junction_panel, "props.JunctionId", "junction panel does not reset lane advice when selection changes", problems)
    require(junction_panel, "setLaneWidthM(DEFAULT_LANE_WIDTH_M)", "junction selection leaks the previous roundabout lane width", problems)
    require(junction_panel, "setMarkings(nil)", "junction selection leaks the previous roundabout marking override", problems)
    require(junction_panel, "setRingWalk(nil)", "junction selection leaks the previous roundabout pavement override", problems)
    require(junction_panel, "setRingIsland(nil)", "junction selection leaks the previous roundabout island override", problems)
    require(junction_panel, "props.ConnectedRoadCount >= 2", "two-road/one-way junctions cannot expose roundabout conversion", problems)

    lane_cases = {
        "asymmetric divided 3/2": (
            [("Shoulder", 3.0, 0)]
            + [("Drive", 3.65, 1)] * 3
            + [("Median", 2.0, 0)]
            + [("Drive", 3.65, -1)] * 2,
            3,
        ),
        "undivided 2+2": (
            [("Sidewalk", 2.0, 0)]
            + [("Drive", 3.65, -1)] * 2
            + [("Drive", 3.65, 1)] * 2
            + [("Sidewalk", 2.0, 0)],
            2,
        ),
        "one-way five": (
            [("Shoulder", 1.0, 0)]
            + [("Drive", 3.65, 1)] * 5
            + [("Shoulder", 3.0, 0)],
            5,
        ),
        "non-drive components ignored": (
            [
                ("Sidewalk", 2.0, 0),
                ("Parking", 2.5, 0),
                ("Bike", 1.8, 1),
                ("Shoulder", 3.0, 0),
                ("Bay", 3.0, 0),
                ("Drive", 0.0, 1),
                ("Drive", 3.65, 1),
            ],
            1,
        ),
    }
    for label, (components, expected) in lane_cases.items():
        actual = max_motor_lanes_per_carriageway(components)
        if actual != expected:
            problems.append(f"roundabout lane contract {label}: expected {expected}, got {actual}")
    require(junction_instance, 'Kind: "Intersection" | "Roundabout"', "junction data cannot retain a roundabout controller", problems)
    require(junction_instance, 'model:SetAttribute("RW_JunctionKind", kind)', "junction kind is not persisted", problems)
    require(junction_instance, "SetRoundaboutGeometry", "roundabout geometry is not mirrored to its controller", problems)
    require(junction, 'junctionData.Kind == "Roundabout"', "ordinary junction builder does not ignore roundabout controllers", problems)
    require(road_source, 'road:GetAttribute("RW_SourceKind")', "roundabout edits have no durable source curve", problems)
    require(roundabout_instance, "function RoundaboutInstance.FindByJunctionId", "roundabout owner cannot be found from its controller", problems)
    require(roundabout_instance, "function RoundaboutInstance.SetGeometry", "roundabout owner geometry is not editable", problems)
    require(roundabout, "local function replaceRoundaboutInPlace", "roundabout edits replace the selected owner Model", problems)
    require(roundabout, "function RoundaboutBuilder.Rebuild", "roundabout builder has no editor rebuild API", problems)
    require(roundabout, "function RoundaboutBuilder.AdoptLegacy", "legacy roundabout migration policy is missing", problems)
    require(roundabout, "original approach sources cannot be recovered safely", "legacy connected rings are not guarded from unsafe proximity adoption", problems)
    require(roundabout, "function RoundaboutBuilder.ConvertToJunction", "roundabouts cannot be converted back to junctions", problems)
    rebuild_start = roundabout.find("function RoundaboutBuilder.Rebuild")
    rebuild_end = roundabout.find("function RoundaboutBuilder.AdoptLegacy", rebuild_start)
    rebuild_scope = roundabout[rebuild_start:rebuild_end]
    reject(rebuild_scope, "collectNearbyRoads", "ordinary roundabout rebuild still absorbs roads by proximity", problems)
    require(roundabout, 'name ~= "RW_RoadId"', "roundabout trimming replaces stable road identity", problems)
    require(roundabout, 'name ~= "RW_StartPortId"', "roundabout trimming replaces stable start-port identity", problems)
    require(roundabout, 'name ~= "RW_EndPortId"', "roundabout trimming replaces stable end-port identity", problems)
    require(roundabout, "if hasStoredFeatures then featureOffset else windowStart", "roundabout trimming does not establish a local feature origin for later edits", problems)
    require(roundabout, "local function prospectiveApproachError(", "roundabout snapping splits roads before validating future mouths", problems)
    require(roundabout, "function RoundaboutBuilder.PrepareForRingRemoval", "direct one-road ring deletion cannot restore its approach", problems)
    require(roundabout, "RW_RoundaboutGenerated", "roundabout editor rebuilds have no generated-geometry ownership boundary", problems)
    require(road_split, "hasActiveSourceWindow", "road splitting can discard an active untrimmed source window", problems)
    reject(junction, 'road:SetAttribute(name, nil)', "junction conversion still clears road/custom attributes", problems)
    require(junction, "RoadInstance.StampModel(road, outerCurve", "junction conversion leaves trimmed road metadata stale", problems)
    require(junction, "BusStops.Render(road)", "junction conversion drops bus-stop visuals", problems)
    require(roundabout_session, "Selection.SelectionChanged:Connect", "roundabout editor is not selection-driven", problems)
    require(roundabout_session, "History.Record", "roundabout editor changes are not undoable", problems)
    require(roundabout_panel, 'Text = "Circulating lanes"', "roundabout editor has no lane-count control", problems)
    require(roundabout_panel, 'Text = "Convert to junction"', "roundabout editor has no reverse conversion action", problems)
    require(main_source, 'require("./RoundaboutEditSession")', "roundabout edit session is not mounted", problems)
    require(main_source, "React.createElement(RoundaboutPanel", "roundabout editor panel is unreachable", problems)
    require(main_source, "Selection:Set({ ring :: Model })", "junction conversion does not transition selection into the roundabout editor", problems)
    require(roundabout_editor_preview, "import roundabout_preview as rp", "roundabout editor preview does not use the canonical component pipeline", problems)
    require(roundabout_editor_preview, 'lane_width_m=4.4', "roundabout editor preview does not exercise the Turbo width regression", problems)
    require(roundabout_editor_preview, 'rp.CASES["hw_oneway"]', "roundabout editor preview does not exercise one-way highway mouths", problems)
    require(road_builder, "MarkingLines: { Markings.MarkingLine }?", "RoadBuilder has no exact marking-plan hook", problems)
    require(roundabout, "local function roundaboutMarkingLines(", "roundabouts do not own a preview-matched marking plan", problems)
    require(roundabout, "Color3.fromRGB(245, 245, 245)", "roundabout marking colour differs from the Python appearance contract", problems)
    require(preview_core, "MARK_C = (245, 245, 245)", "Python roundabout marking colour changed without its Lua contract", problems)
    require(roundabout, "MarkingLines = roundaboutMarkingLines(", "roundabout builds still fall through to generic road markings", problems)
    require(roundabout, "local function clipArmMarkingLinesAtRing(", "arm markings are not clipped at per-offset ring ownership", problems)
    require(roundabout, "line.ToStationStuds = crossing", "entry-arm markings still protrude through the ring deck", problems)
    require(roundabout, "line.FromStationStuds = crossing", "exit-arm markings still protrude through the ring deck", problems)
    require(roundabout, "MarkingLines = markingLines", "RoadBuilder does not receive the clipped arm marking plan", problems)
    require(roundabout, "local y = center.Y + TURBO_MARKING_LIFT_STUDS", "Turbo overlay is coplanar with the concentric divider", problems)
    require(roundabout, "local function armDriveBoundaryOffsetsStuds(", "Turbo still has no actual exit-boundary lookup", problems)
    require(roundabout, "components[i].Kind == \"Drive\" and components[i + 1].Kind == \"Drive\"", "Turbo accepts shoulder/non-drive boundaries as lane targets", problems)
    require(roundabout, "local targetOffsets = armDriveBoundaryOffsetsStuds(arm, style, scale)", "Turbo does not use the exit arm's real Drive boundaries", problems)
    require(roundabout, "local targetIndex = lanes - k", "Turbo no longer maps ring dividers to outside-in exit boundaries", problems)
    require(roundabout, "local radius = ringRadius + (targetRadius - ringRadius) * eased", "Turbo does not ease to the edited-width handoff radius", problems)
    require(roundabout, "local function openTurboReplacementArcs(", "Turbo does not remove the base divider under a peel", problems)
    require(roundabout, "openTurboReplacementArcs(ringMarkings, center, replacements", "Turbo replacement sectors are not applied to the built ring", problems)
    require(roundabout, "openRingPavement(matching, center, { replacement.Sector }, 0, false)", "Turbo base-divider opening is clamped shorter than its peel", problems)
    require(roundabout, "local TURBO_MIN_SAMPLE_SPACING_STUDS = 0.5", "Turbo has no bounded spatial sampling floor", problems)
    require(roundabout, "if ringRadius <= math.max(markingWidth, 1e-3) then", "Turbo samples invalid/non-positive edited divider radii", problems)
    reject(roundabout, "(arm.OuterOffsetStuds + arm.InnerOffsetStuds) / laneStuds", "Turbo still infers arm lanes from edited ring lane width", problems)
    require(roundabout_preview, 'scene["lane_width_m"] * SCALE', "Python Turbo validation still assumes the default lane width", problems)
    require(roundabout_preview, 'scene.get("turbo_replacements")', "Python Turbo validation does not require base-divider replacement", problems)
    require(roundabout, "local function bandEdgeExitAngle(", "one-way roundabout mouths have no generalized edge-crossing helper", problems)
    require(roundabout, "signedOffsetStuds: number", "one-way edge crossing is still hard-wired to the outboard edge", problems)
    require(roundabout, "rightOf(tangent) * signedOffsetStuds", "one-way edge crossing ignores its signed lateral offset", problems)
    require(roundabout, "local SOLO_SPLIT_CLEARANCE_RAD = math.rad(3)", "solo one-way mouths have no width-fit merge clearance", problems)
    require(roundabout, "local SOLO_SPLIT_MAX_RAD = math.rad(26)", "solo one-way mouths can regress to the paired 38-degree tangent", problems)
    require(roundabout, "local fitAngle = math.asin", "solo one-way merge angles are not derived from actual arm width", problems)
    reject(roundabout, "SOLO_SECTOR_INSET_RAD", "solo one-way pavement still uses the obsolete angular inset", problems)
    reject(roundabout, "SOLO_SECTOR_OVERLAP_SHARE", "solo one-way pavement still uses the obsolete overlap share", problems)
    reject(roundabout, "local function bandExitAngle(", "solo one-way pavement still uses the obsolete outboard-only crossing", problems)
    require(roundabout, "local BAND_EXIT_SAMPLES = 96", "one-way outer-band crossing has no deterministic bracket", problems)
    require_count(roundabout, "bandEdgeExitAngle(", 3, "one-way edge-crossing helper is not applied to both roadway edges", problems)
    require(roundabout, "local outboardOffsetStuds = -only.Profile.OuterOffsetStuds * flow", "solo openings do not use the signed traffic-outboard edge", problems)
    require(roundabout, "local inboardOffsetStuds = only.Profile.InnerOffsetStuds * flow", "solo openings do not use the signed traffic-inboard edge", problems)
    require(roundabout, "local function sectorAtRadius(targetRadiusStuds: number): MouthSector", "solo edge paint does not derive a sector from both edge crossings", problems)
    require(roundabout, "local sweep = angleDelta(inboardAngle, outboardAngle)", "solo edge paint is not the full outboard-to-inboard angular span", problems)
    require(roundabout, "return { Angle = outboardAngle + sweep / 2, Ahead = half, Behind = half }", "solo edge paint does not retain the complete edge-to-edge sector", problems)
    reject(roundabout, "local outerBandRadius =", "solo pavement has regressed to a radial outer-band sector", problems)
    reject(roundabout, "sectorAtRadius(outerBandRadius)", "solo pavement is still deleted by an angular sector", problems)
    require(roundabout, "local edgeLineRadius = ringKerbRadius - style.MarkingWidthM * 1.5 * settings.MetersToStuds", "solo edge-paint opening is not measured at the actual outer edge-line centre", problems)
    require(roundabout, "return nil, sectorAtRadius(edgeLineRadius), soloTrace, soloRoadwayCutters", "solo mouths do not return footprint-owned pavement plus edge-line paint", problems)
    require(roundabout, "type ConvexFootprint = { Vector3 }", "roundabout arms cannot expose analytical roadway footprints", problems)
    require(roundabout, "local function subtractConvexFootprint(", "solo sidewalk ownership has no exact convex subtraction", problems)
    require(roundabout, "local function openRingSidewalkByFootprints(", "solo sidewalks are not opened by roadway footprints", problems)
    require(roundabout, "local survivors, subtracted = subtractConvexFootprint(fragment, cutter.Polygon)", "solo sidewalk opening does not subtract each exact cutter polygon", problems)
    require(roundabout, "replaceWithClippedPolygons(part, fragments)", "solo sidewalk subtraction discards its exact surviving fragments", problems)
    require(roundabout, "collectRoadwayFootprints: boolean", "buildArm cannot opt into solo roadway footprint capture", problems)
    require(roundabout, "local stations = RoadBuilder.StationsFor(options)", "solo roadway cutters do not share RoadBuilder's station grid", problems)
    require(roundabout, "local roadwayPartNames: { [string]: boolean }", "solo roadway cutters have no complete generated-part kind filter", problems)
    require(roundabout, "Bay = true", "solo roadway cutters omit generated Bay blocks", problems)
    require(roundabout, "table.insert(roadwayFootprints, partTopPolygon(descendant))", "solo roadway cutters do not use the exact generated core block footprint", problems)
    require(roundabout, "{ shoulderInner0, shoulderOuter0, shoulderOuter1, shoulderInner1 }", "solo roadway cutters omit the exact shoulder-taper quad", problems)
    require(roundabout, "return model, roadwayFootprints", "buildArm drops the captured roadway footprints", problems)
    require(roundabout, "): (MouthSector?, MouthSector, ExitTrace?, { ConvexFootprint })", "buildMouth cannot distinguish footprint-owned solo pavement from paired sectors", problems)
    require(roundabout, "local soloMouth = not (plan.Entry and plan.Exit)", "buildMouth does not restrict roadway cutters to solo arms", problems)
    require(roundabout, "local collectSoloRoadway = soloMouth and ringSidewalkWidthM(style) > 1e-6", "buildMouth captures solo cutters when no ring sidewalk exists", problems)
    require(roundabout, "if sector then", "solo nil pavement sectors cannot be excluded from paired mouth sectors", problems)
    require(roundabout, "table.insert(mouthSectors, sector)", "paired pavement sectors are no longer preserved", problems)
    require(roundabout, "return pavementSector,", "paired mouths no longer return their angular pavement sector", problems)
    require(roundabout, "openRingSidewalkByFootprints(ringSidewalk, soloRoadwayCutters)", "solo roadway cutters are not applied to the original ring sidewalk", problems)
    require(roundabout, "openRingPavement(ringSidewalk, center, mouthSectors, 0)", "paired angular sidewalk openings are no longer applied", problems)
    footprint_open = roundabout.find("openRingSidewalkByFootprints(ringSidewalk, soloRoadwayCutters)")
    paired_open = roundabout.find("openRingPavement(ringSidewalk, center, mouthSectors, 0)")
    if footprint_open >= 0 and paired_open >= 0 and footprint_open > paired_open:
        problems.append("solo footprint subtraction must run before paired angular sidewalk opening")
    require(roundabout, "if driveCount == 1 and onlyDriveIndex then", "legacy one-lane roads are still split into two half-width lanes", problems)
    require(roundabout, "return sharedGroup(), sharedGroup()", "legacy one-lane roads do not retain full-width entry/exit arms", problems)
    reject(roundabout, 'Category == "Highways"', "roundabout conversion still rejects Highway profiles by category", problems)
    require(roundabout, "CutShoulderLeftM: number", "solo one-way highway arms cannot retain their left shoulder width", problems)
    require(roundabout, "CutShoulderRightM: number", "solo one-way highway arms cannot retain their right shoulder width", problems)
    require(roundabout, "if style.DriveOnLeft or solo then", "solo one-way arms do not taper their left terminal shoulder", problems)
    require(roundabout, "if not style.DriveOnLeft or solo then", "solo one-way arms do not taper their right terminal shoulder", problems)
    require(roundabout, "if outward < 0 then arm.CutShoulderLeftM else arm.CutShoulderRightM", "arm surface emission does not select shoulder width per side", problems)
    require_count(roundabout, "pavement(0)", 2, "solo one-way arms carry their inboard kerb across the circulating carriageway", problems)
    require(roundabout, "while expanded do", "contiguous undirected shoulder runs are not assigned to their lane group", problems)
    require(roundabout, "leftShoulderMarkerIndex", "terminal shoulder runs are not collapsed to one marking boundary", problems)
    require(roundabout, "rightShoulderMarkerIndex", "mirrored terminal shoulder runs are not collapsed to one marking boundary", problems)
    require(roundabout, "local function replaceCutPavementCaps()", "roundabout approach seams still use padded pavement end caps", problems)
    require(road_builder, "ExactStartRaisedCap: boolean?", "RoadBuilder cannot end raised start caps at an ownership plane", problems)
    require(road_builder, "ExactEndRaisedCap: boolean?", "RoadBuilder cannot end raised end caps at an ownership plane", problems)
    require(road_builder, "local exactRaisedCap = raised", "RoadBuilder exact-cap options are declared but not emitted", problems)
    require(roundabout, "ExactStartRaisedCap = if exactRaisedCapAtStart == true", "roundabout trimming does not wire an exact raised start cap", problems)
    require(roundabout, "ExactEndRaisedCap = if exactRaisedCapAtStart == false", "roundabout trimming does not wire an exact raised end cap", problems)
    require(roundabout, "approach.LinkedAtStart", "roundabout preflight does not choose which source-road end receives the exact cap", problems)
    require(roundabout, "local function angularFootprintHalfSpan(", "roundabout mouth opening still clips ring Parts by centre only", problems)
    require(roundabout, "local function clipToAngularSide(", "roundabout mouth boundary Parts are deleted instead of clipped exactly", problems)
    require(roundabout_preview, "def ring_boundary_intrusions(", "Python preview does not reject ring Parts intruding across a mouth boundary", problems)
    require(dump_compare, "grown = args.radius", "roundabout dump comparison still grows the requested radius", problems)
    reject(dump_compare, "grown = max(args.radius, minimum)", "roundabout dump comparison disagrees with the live radius rule", problems)
    require(dump_compare, "road_centre, _cut_shoulders, core_shift", "roundabout dump comparison still expects the old arm-profile contract", problems)
    require(dump_compare, "core_centre = span_centre + core_shift", "roundabout dump comparison ignores two-sided shoulder core shift", problems)
    require(multinode_preview, "from preview_core import (", "multinode preview no longer shares the roundabout component pipeline", problems)
    require(multinode_preview, "SIX_LANE_BOULEVARD = uk_two_way(3)", "multinode preview lost the UK six-lane boulevard case", problems)
    require(multinode_preview, 'suffix = "gaps" if flat else "parts"', "multinode preview no longer emits matching parts/gaps QA views", problems)
    require(multinode_preview, 'controls_name = f\'junction_{scene["tag"]}_controls.png\'', "multinode preview no longer emits the corner-radius showcase", problems)
    require(multinode_preview, 'metavar="CORNER=METRES"', "multinode preview corner radii are not adjustable from its CLI", problems)
    require(multinode_preview, '"uk6x4_setback": case(', "multinode preview has no asymmetric setback fixture", problems)
    require(multinode_preview, 'metavar="APPROACH=STUDS"', "multinode preview setbacks are not adjustable from its CLI", problems)
    require(multinode_preview, '"effective_setbacks"', "multinode preview does not retain stable-id setback metadata", problems)
    require(multinode_preview, "[1, 1, 1, -1, -1, -1]", "multinode preview no longer asserts UK left-hand direction ordering", problems)
    require(roundabout_preview, '"solo_flare": case(', "roundabout preview has no focused one-way mouth regression", problems)
    require(roundabout_preview, '"solo_bay": case(', "roundabout preview has no left-hand solo Bay cutter regression", problems)
    require(roundabout_preview, '"solo_bay_us": case(', "roundabout preview has no right-hand solo Bay cutter regression", problems)
    require(roundabout_preview, "def check_solo_merges(", "roundabout preview does not validate width-fit solo merges", problems)
    reject(roundabout_preview, "SOLO_SECTOR_INSET_RAD", "Python solo pavement still carries the obsolete angular inset", problems)
    reject(roundabout_preview, "SOLO_SECTOR_OVERLAP_SHARE", "Python solo pavement still carries the obsolete overlap share", problems)
    reject(roundabout_preview, "def band_exit_angle(", "Python solo pavement still carries the obsolete outboard-only crossing", problems)
    require(roundabout_preview, "def band_edge_crossing(", "Python parity has no generalized signed-edge crossing", problems)
    require(roundabout_preview, 'curve, -arm["outer"] * flow', "Python solo openings do not cross the traffic-outboard edge", problems)
    require(roundabout_preview, 'curve, arm["inner"] * flow', "Python solo openings do not cross the traffic-inboard edge", problems)
    require(roundabout_preview, "return sector_between_crossings(crossings", "Python edge-paint opening is not the complete edge-to-edge sector", problems)
    require(roundabout_preview, "ring_kerb - MARKING_W_M * 1.5 * SCALE", "Python edge-paint sector is not tied to the outer edge-line centre", problems)
    require(roundabout_preview, "marking_crossings = {\"outer\": marking_cap, \"inner\": marking_inner}", "Python edge-paint sector does not use the merge cap and inboard crossing", problems)
    require(roundabout_preview, "def open_parts_by_footprints(", "Python parity has no exact roadway-footprint subtraction", problems)
    require(roundabout_preview, "_convex_difference(fragment, cutter_poly, area_tolerance)", "Python footprint opening does not retain exact sidewalk survivors", problems)
    require(roundabout_preview, "roadway_parts=[", "Python solo mouths do not retain their emitted roadway cutters", problems)
    require(roundabout_preview, "if is_roadway((part.name, 0.0))", "Python solo cutters do not use the shared roadway-kind rule", problems)
    require(preview_core, 'ROADWAY = {"Drive", "Bike", "Parking", "Shoulder", "Bay"}', "Python roadway-kind parity omits Bay or another RoadProfile roadway surface", problems)
    require(roundabout_preview, 'mouth.get("roadway_parts", [])', "Python solo roadway cutters are never applied", problems)
    require(roundabout_preview, 'lambda part: part.name == "Sidewalk"', "Python footprint subtraction is not restricted to raised ring sidewalk", problems)
    require(roundabout_preview, "solo_pavement_sectors.append(pavement_sector)", "Python parity does not keep solo angular diagnostics separate from live paired sectors", problems)
    reject(roundabout_preview, "\n            pavement_sectors.append(pavement_sector)", "Python solo pavement has regressed to angular deletion", problems)
    require(roundabout_preview, "def check_solo_sidewalk_clearance(", "Python parity does not scan the complete solo roadway span", problems)
    require(roundabout_preview, "faults.extend(check_solo_sidewalk_clearance(scene))", "Python solo sidewalk-clearance check is unreachable", problems)

    require(session, "GetStructure: () -> RoadInstance.StructureData", "placement session has no structure API", problems)
    require(session, "RoadInstance.StampStructure(model, appliedStructure)", "placed roads do not persist structure mode", problems)
    require(session, "StructureBuilder.Render(model, curve, structure, settings)", "placed roads do not render structures", problems)
    require(
        build_bar,
        'children.Structure = props.ToolMode ~= "Roundabout"',
        "Road Tools does not expose structure controls",
        problems,
    )
    require(
        build_bar,
        "and e(StructureControls, {",
        "Road Tools structure controls are not mounted",
        problems,
    )
    require(settings, 'export type SnapReference = "Centre" | "LeftRoadwayEdge" | "RightRoadwayEdge"', "snap-reference setting is missing", problems)
    require(build_bar, '{ Id = "LeftRoadwayEdge", Text = "Left roadway edge" }', "Road Tools has no left-edge snap option", problems)
    require(build_bar, '{ Id = "RightRoadwayEdge", Text = "Right roadway edge" }', "Road Tools has no right-edge snap option", problems)
    require(session, "TopologyPosition: Vector3", "lateral snaps do not preserve a centreline topology anchor", problems)
    require(session, "connectAtSplit(snapMatch.Road, snapMatch.Station", "mid-span lateral snaps do not split at the captured centreline station", problems)
    require(junction, "dx * dx + dz * dz > 0.25 * 0.25", "offset snap connections can still be mistaken for seamless pass-throughs", problems)
    require(structure, "placeProceduralTunnel(generated, road, curve, data, settings)", "no-asset tunnel fallback is missing", problems)
    require(structure, "placeProceduralViaduct(generated, road, curve, data, settings)", "no-asset viaduct fallback is missing", problems)
    require(structure, 'string.format("DeckSlab_%04d"', "procedural viaduct has no structural slab", problems)
    require(structure, "local baseThickness = exposedBaseDepth + interfaceOverlap", "viaduct overlap can consume the visible structural deck", problems)
    require(structure, "local function offsetSegmentFrame(", "curved viaduct parapets still use the centreline chord", problems)
    require(structure, "side * barrierCenter", "viaduct parapets are not aligned to their own lateral chords", problems)
    require(structure, "STRUCTURE_EDGE_CLEARANCE_STUDS + barrierThickness / 2", "viaduct parapets can overlap the road edge", problems)
    require(structure, "local deckHalfWidth = barrierCenter - barrierThickness / 2", "viaduct deck can overshoot and block its sidewalls", problems)
    require(structure, 'string.format("Vault_%02d_%04d"', "procedural tunnel has no segmented vault", problems)
    require(structure, "local function safeInterfaceOverlap(", "procedural structures do not bound their road interface overlap", problems)
    require(structure, "local function centralBaseThickness(", "procedural structures have no shortened central base", problems)
    require(structure, "local barrierBottom = baseTopY - fasciaDepth", "viaduct parapets do not extend below the shortened base", problems)
    require(structure, "local wallBottom = floorTop - thickness", "tunnel walls do not extend below the shortened base", problems)
    require(structure, "data.ViaductParapetGapM * scale", "viaduct parapet gap is not configurable", problems)
    require(structure, "data.ViaductParapetHeightM * scale", "viaduct parapet height is not configurable", problems)
    require(structure, "data.TunnelWallClearanceM * scale", "tunnel wall clearance is not configurable", problems)
    require(structure, "data.TunnelVerticalClearanceM * scale", "tunnel vertical clearance is not configurable", problems)
    require(structure, "local function makeBankedFrameAt(", "structures do not share the road superelevation frame", problems)
    require_count(structure, "local bankedFrameAt = makeBankedFrameAt(curve, settings)", 4, "not every structure path inherits road banking", problems)
    require(structure, "offsetSegmentFrame(curve, bankedFrameAt", "curved viaduct parapets ignore the banked road frame", problems)
    require(structure, "restyleElevatedMedian", "viaduct medians cannot be changed to concrete", problems)
    require(settings, "StructureConcreteColorHex", "settings do not persist procedural concrete colour", problems)
    require(settings, "StructureBaseMaterial", "settings do not persist the structural base material", problems)
    require(settings, "ViaductWallMaterial", "settings do not persist the viaduct wall finish", problems)
    require(settings, "TunnelWallMaterial", "settings do not persist the tunnel wall finish", problems)
    require(settings, "TunnelRoofMaterial", "settings do not persist the tunnel roof finish", problems)
    require(settings, "ViaductParapetHeightM", "settings do not persist viaduct parapet height", problems)
    require(settings, "TunnelVerticalClearanceM", "settings do not persist tunnel vertical clearance", problems)
    require(road_instance, 'PillarLayout: PillarLayout', "roads do not persist single/twin pillar layout", problems)
    require(road_instance, "CapBeamWidthM", "roads do not persist cap-beam dimensions", problems)
    require(structure, 'local twin = data.PillarLayout == "Twin"', "viaducts cannot generate twin pillars", problems)
    require(structure, 'cap.Name = string.format("CapBeam_%04d"', "twin supports have no cap beam", problems)
    require(structure, "StructureMaterials.Resolve(data.TunnelRoofMaterial)", "tunnel roof material is ignored", problems)
    require(structure_controls, 'Text = "Twin pillars + cap beam"', "Road Tools does not expose twin supports", problems)
    require(structure_controls, 'Label = "Pillar width (m)"', "Road Tools does not expose pillar width clearly", problems)
    require(structure_controls, 'Text = "Parapet height (m)"', "Road Tools does not expose viaduct parapet height", problems)
    require(structure_controls, 'Text = "Vertical clearance (m)"', "Road Tools does not expose tunnel height clearance", problems)
    require(regional_preferences, "Width = props.LabelWidth or 184", "Regional Preference rows cannot choose a control-appropriate label width", problems)
    require_count(regional_preferences, "LabelWidth = 120", 7, "Regional Preference dropdowns or bank slider still lose space to wide labels", problems)
    reject(regional_preferences, 'Text = "Auto (from speed + curvature)"', "Regional Preference banking mode still overflows its dropdown", problems)
    require(regional_preferences, 'Label = "Viaduct wall height (m)"', "Regional Preference lacks a compact viaduct wall-height label", problems)
    require(regional_preferences, 'Label = "Tunnel height (m)"', "Regional Preference lacks a compact tunnel height-clearance label", problems)
    require(regional_preferences, 'Label = "Concrete viaduct medians"', "Regional Preference viaduct-median copy still overflows the dock", problems)
    require(structure_materials, "Enum.Material.Concrete", "procedural material catalogue is missing", problems)
    require(settings, "ParallelRoadwayGapM", "settings do not persist the parallel roadway gap", problems)

    require(curve, "function CurveSegment.OffsetMany", "parallel roadways have no curved offset/refit", problems)
    require(curve, "function CurveSegment.Reverse", "parallel roadways cannot reverse direction", problems)
    require(road_instance, 'model:SetAttribute("RW_CurveJson"', "multi-segment parallel curves are not serialized", problems)
    require(road_instance, "local function curveFromModel", "multi-segment parallel curves cannot be reopened", problems)
    require(session, "GetParallel: () -> ParallelConfig", "placement session has no parallel roadway API", problems)
    require(session, 'target:SetAttribute("RW_ParallelGroupId"', "parallel roadway grouping is not serialized", problems)
    require(build_bar, "e(ParallelControls", "Road Tools does not expose parallel roadway controls", problems)
    require(parallel_controls, 'Label = "Opposite traffic directions"', "opposed roadway pairs are not configurable", problems)
    require(parallel_controls, 'string.format("Roadway %d runs in reverse"', "multi-roadway direction controls are missing", problems)
    require(main_source, "local ROAD_DESIGNER_HEIGHT = 440", "Road Editor columns are too short for their fixed content", problems)
    require(markings, "function Markings.IsEditableLaneBoundary", "opposing Drive lanes are not exposed as editable marking boundaries", problems)
    centre_start = markings.find('if a.Direction ~= 0 and b.Direction ~= 0 and a.Direction ~= b.Direction then')
    centre_end = markings.find("else", centre_start)
    require(markings[centre_start:centre_end], "emitBoundaryLine(", "centre lines bypass marking stretches and boundary overrides", problems)
    require(road_edit_session, "Markings.IsEditableLaneBoundary(components, i)", "marking-stretch hit testing still excludes the centre line", problems)
    require(road_designer, '"Show lane markings"', "Road Editor cannot reveal explicit marking boundaries", problems)
    require(road_designer, "local function BoundaryButton", "Road Editor has no between-lane marking selector", problems)
    require(road_designer, '"Boundary between %s %s and %s %s"', "Road Editor does not identify both lanes around a selected boundary", problems)
    reject(road_designer, 'Text = "Lane marking"', "Road Editor still presents a boundary as a selected-lane property", problems)

    for lane_count in range(1, 6):
        require(
            profiles,
            f'builtin_highway_oneway_{lane_count}',
            f"one-way {lane_count}-lane highway preset is missing",
            problems,
        )

    require(top_bar, 'Text = "Road Assets"', "top mode bar has no Road Assets surface", problems)
    require(main_source, "local function duplicateRoadProfile", "Road Editor cannot duplicate its current road template", problems)
    require(main_source, 'Text = if editing.BuiltIn then "Duplicate road" else "Save"', "built-in roads do not expose Duplicate as their primary action", problems)
    require(main_source, 'Text = "Duplicate road"', "user roads do not expose Duplicate alongside Save", problems)
    require(main_source, 'duplicate.Name = nextRoadCopyName(source.Name)', "duplicated road names are ambiguous", problems)
    require(main_source, 'HttpService:GenerateGUID(false)', "duplicated roads can overwrite each other when created in the same second", problems)
    require(main_source, 'require("./UI/RoadAssetsPanel")', "Road Assets surface is not rendered", problems)
    require(asset_panel, 'Text = "Import Selection as Viaduct"', "Road Assets cannot import viaduct Models", problems)
    require(asset_panel, 'Text = "Delete Selected Asset"', "Road Assets cannot manage stored Models", problems)
    reject(build_bar, "ImportStructureAsset", "Road Tools still owns the structure import workflow", problems)

    require(loader, 'createDock("EasyRoadSoftwareDock"', "Software dock is not created", problems)
    require(main_source, 'require("./UI/SoftwareGui")', "Software dock content is not rendered", problems)
    require(top_bar, 'Text = "Software"', "Settings menu has no Software entry", problems)
    reject(software.lower(), "easyrail", "Software dock still links or advertises easyRail", problems)

    if problems:
        for problem in problems:
            print("FAILED:", problem)
        return 1
    print("integration contracts passed: isolated undo history, road duplication, editable roundabouts, lane inference, one-way/highway mouths, Turbo width parity, exact caps, multinode junctions, assets, procedural structures, snap references, parallel roadways, marking boundaries, highway presets, Software dock")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
