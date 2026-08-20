#!/usr/bin/env python3
"""Static wiring checks for Studio-only interaction paths.

These do not execute Luau. They protect the exact contracts that previously
made a feature look shipped while remaining unreachable in Studio: queryable
junction geometry, placement-time structure controls/rendering, lateral road
snap references, dedicated asset management, procedural viaduct/tunnel
fallbacks, and the independent Settings docks.
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


def require_exact_count(text, needle, expected, message, problems):
    if text.count(needle) != expected:
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
    region_styles = source("src/RegionStyles.lua")
    region_editor = source("src/UI/RegionEditor.lua")
    road_builder = source("src/Mesh/RoadBuilder.lua")
    superelevation = source("src/Geometry/Superelevation.lua")
    loader = source("loader.server.lua")
    main_source = source("src/main.lua")
    top_bar = source("src/UI/TopBar.lua")
    asset_panel = source("src/UI/RoadAssetsPanel.lua")
    structure_assets = source("src/StructureAssets.lua")
    software = source("src/UI/SoftwareGui.lua")
    backups = source("src/UI/BackupsGui.lua")
    multinode_preview = source("tools/preview/multinode_junction_preview.py")
    preview_core = source("tools/preview/preview_core.py")
    roundabout = source("src/Mesh/RoundaboutBuilder.lua")
    roundabout_instance = source("src/RoundaboutInstance.lua")
    roundabout_session = source("src/RoundaboutEditSession.lua")
    roundabout_panel = source("src/UI/RoundaboutPanel.lua")
    road_source = source("src/RoadSource.lua")
    roundabout_preview = source("tools/preview/roundabout_preview.py")
    roundabout_editor_preview = source("tools/preview/roundabout_editor_preview.py")
    roundabout_arm_height_preview = source("tools/preview/roundabout_arm_height_preview.py")
    dump_compare = source("tools/preview/dump_compare.py")
    transition_anchor_preview = source("tools/preview/transition_anchor_preview.py")
    setup_wizard = source("src/UI/SetupWizard.lua")
    setup_wizard_preview = source("tools/preview/setup_wizard_preview.py")
    units = source("src/Units.lua")

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

    require(
        superelevation,
        "function Superelevation.BuildProfile(",
        "superelevation has no canonical arc-length roll profile",
        problems,
    )
    require(
        superelevation,
        "function Superelevation.RollAtProfile(",
        "superelevation consumers cannot share one interpolated roll profile",
        problems,
    )
    require(
        superelevation,
        "local rawControlStations = { 0, runoffLength, length / 2, length - runoffLength, length }",
        "short curves can lose all banking when their endpoint-taper controls are omitted",
        problems,
    )
    require(
        road_builder,
        "function RoadBuilder.StationPlanFor(",
        "RoadBuilder does not expose its final curved/banked station plan",
        problems,
    )
    road_build_start = road_builder.find("function RoadBuilder.Build(options")
    road_build_end = road_builder.find("function RoadBuilder.BuildWithBay", road_build_start)
    road_build = road_builder[road_build_start:road_build_end]
    require(
        road_build,
        "RoadBuilder.StationPlanFor(options)",
        "RoadBuilder exposes StationPlanFor but Build does not consume it",
        problems,
    )
    require(
        road_builder,
        "Superelevation.BuildProfile(",
        "RoadBuilder still derives a private roll profile",
        problems,
    )
    require(
        road_builder,
        "Superelevation.RollAtProfile(",
        "RoadBuilder bypasses the canonical roll-profile interpolation path",
        problems,
    )
    require(road_builder, "SuperelevationProfile: Superelevation.RollProfile?", "RoadBuilder cannot consume a shared canonical roll profile", problems)
    require(road_builder, "SuperelevationStationOffsetStuds: number?", "RoadBuilder cannot sample a canonical profile from a sliced road offset", problems)
    require(road_builder, "DisableSurfaceCoalescing: boolean?", "RoadBuilder slices cannot preserve canonical per-component surface ownership", problems)
    require(road_builder, "local fullRollProfile = Superelevation.BuildProfile", "bay roads rebuild bank independently per slice", problems)
    require_exact_count(road_builder, "SuperelevationProfile = fullRollProfile", 3, "not every bay slice consumes the full canonical roll profile", problems)
    require_exact_count(road_builder, "DisableSurfaceCoalescing = true", 3, "bay slices can coalesce surfaces across canonical slice ownership", problems)
    require(
        road_builder,
        "local overlayStations: { number } = {}",
        "bay asphalt and displaced pavement do not share one station grid",
        problems,
    )
    require(
        road_builder,
        "overlayStations = refineStationsForRoll(",
        "banked bay overlays are not refined against the canonical roll profile",
        problems,
    )
    require_exact_count(
        road_builder,
        "or math.abs(rollAt(s1) - rollAt(s0)) > ROLL_WEDGE_EPSILON",
        2,
        "bay asphalt or shifted pavement can remain a rigid box through bank runoff",
        problems,
    )
    require(
        road_builder,
        "if options.ProfileEnd and options.ProfileEnd.Id ~= baseProfile.Id then",
        "bay geometry can overlap a widening/narrowing cross-section transition",
        problems,
    )
    require(
        main_source,
        "and not editSession.IsTransition()",
        "Road Editor still offers an invisible bus bay on a profile transition",
        problems,
    )
    require(
        road_edit_session,
        'or session.IsTransition() then',
        "non-UI calls can still start bus-bay placement on a profile transition",
        problems,
    )
    for offset in ("0", "taperInStart", "taperOutEnd"):
        require(
            road_builder,
            f"SuperelevationStationOffsetStuds = {offset}",
            f"bay slice is missing canonical superelevation offset {offset}",
            problems,
        )
    for label, consumer in (("placement snapping", session), ("road editing", road_edit_session)):
        require(consumer, "Superelevation.BuildProfile(", f"{label} does not cache a canonical roll profile", problems)
        require(consumer, "Superelevation.RollAtProfile(", f"{label} does not sample the canonical roll profile", problems)
        reject(consumer, "Superelevation.RollAt(", f"{label} still samples raw station-by-station banking", problems)
    require(
        road_builder,
        'model:SetAttribute("RW_CurvedSurfaceCoalesced", false)',
        "curved surfaces can still enter the regressed lateral-coalescing path",
        problems,
    )
    require(
        road_builder,
        'model:SetAttribute("RW_BankedSurfaceCoalesced", false)',
        "banked surfaces can still enter the regressed lateral-coalescing path",
        problems,
    )
    require(
        road_builder,
        "if optimizedStraight and options.DisableSurfaceCoalescing ~= true then",
        "surface-band merging is not restricted to the exact-straight fast path",
        problems,
    )
    require(
        road_builder,
        "local componentEnd = bandEndByStart[c] or c",
        "non-straight emission no longer falls back to source components",
        problems,
    )
    reject(
        road_builder,
        "compatibleBandEndByStart",
        "retired curved/banked compatible-band planner is still present",
        problems,
    )

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
    require(road_split, "local function activeSourceWindow(", "road splitting cannot detect a junction/roundabout-trimmed source window", problems)
    require(road_split, "local sourceSegment, sourceCurve = activeSourceWindow(road, data)", "road splitting ignores the preserved source behind a trimmed approach", problems)
    require(road_split, "local function visibleSourceOrigin(", "trimmed-road cuts cannot use their stored durable-source origin", problems)
    require(road_split, "local visibleSourceStart = visibleSourceOrigin(road, data, sourceCurve)", "trimmed-road cuts are not mapped back into durable source coordinates", problems)
    require(road_split, "local function projectSourceStationNear(", "trimmed-road cuts rely on drifting independent arc-length tables", problems)
    require(road_split, "previousVisibleStation + SOURCE_WINDOW_EPSILON_STUDS", "trimmed-road cut projection can reverse physical source order", problems)
    require(road_split, "RoadSource.WriteSegment(piece, pieceSourceSegment)", "split pieces discard their restorable outer junction/roundabout source", problems)
    require(road_split, 'piece:SetAttribute("RW_FeatureSourceOffsetStuds", math.max(0, visiblePieceSourceStart - pieceSourceStart))', "a start-trimmed first split piece loses its visible source-window origin", problems)
    require(road_split, "RW_ParallelGroupId = true", "splitting a parallel road drops its corridor group", problems)
    require(road_split, "RW_ParallelReverse = true", "splitting a parallel road drops its travel-direction metadata", problems)
    require(road_split, "Roads with a changing profile-centre offset cannot be split yet", "unsupported offset-only transitions are silently reparameterised by splitting", problems)
    require(road_split, "local function hasUnsupportedStructure(", "structured roads have no split-safety boundary", problems)
    require(road_split, "Roads with custom or procedural structures cannot be split yet", "road splitting can restart custom modules or duplicate procedural supports", problems)
    reject(road_split, 'return "Roundabout approaches cannot be split while connected"', "roundabout-linked approaches still disable all mid-span snapping", problems)
    reject(junction, 'road:SetAttribute(name, nil)', "junction conversion still clears road/custom attributes", problems)
    require(junction, "RoadInstance.StampModel(\n\t\troad,\n\t\touterCurve", "junction conversion leaves trimmed road metadata stale", problems)
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
    require(roundabout_arm_height_preview, "def static_faults(source: str)", "roundabout arm-height QA is not source-linked", problems)
    require(roundabout_arm_height_preview, "legacy_sunk_arm_delta", "roundabout arm-height QA does not retain the reported 0.05-stud regression mutant", problems)
    reject(roundabout, "ARM_SINK_STUDS", "roundabout arms are still vertically displaced from their source roads", problems)
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
    require(roundabout, "return nil, sectorAtRadius(edgeLineRadius), soloTrace, surfaceCutters", "solo mouths do not return footprint-owned pavement plus edge-line paint", problems)
    require(roundabout, "type ConvexFootprint = { Vector3 }", "roundabout arms cannot expose analytical roadway footprints", problems)
    require(roundabout, "local function subtractConvexFootprint(", "solo sidewalk ownership has no exact convex subtraction", problems)
    require(roundabout, "local buildExactRingSidewalk: any", "ring pavement has no deferred exact-emission path", problems)
    require(roundabout, "buildExactRingSidewalk = function(", "ring pavement exact-emission path is never defined", problems)
    require(roundabout, "for _, cutter in roadwayCutters do", "mouth surface cutters are not fed into exact ring pavement", problems)
    require(roundabout, "local survivors = subtractConvexFootprint(fragment, cutter.Polygon)", "exact ring pavement does not subtract each mouth ownership polygon", problems)
    require(roundabout, 'part:SetAttribute("RW_ExactRoundaboutPavement", true)', "exact ring pavement parts are not source-identifiable", problems)
    require_count(roundabout, "ExcludeComponentIndices = ringSidewalkComponentIndices(profile)", 2, "RoadBuilder still emits padded ring sidewalk beneath the exact strip", problems)
    require(roundabout, "collectRoadwayFootprints: boolean", "buildArm cannot opt into solo roadway footprint capture", problems)
    require(roundabout, "local stations = RoadBuilder.StationsFor(options)", "solo roadway cutters do not share RoadBuilder's station grid", problems)
    require(roundabout, "local roadwayPartNames: { [string]: boolean }", "generated core cutters have no physical-Part allow-list", problems)
    require(roundabout, "table.insert(roadwayFootprints, partTopPolygon(descendant))", "generated core cutters do not match RoadBuilder Parts", problems)
    require(roundabout, "{ shoulderInner0, shoulderOuter0, shoulderOuter1 }", "solo roadway cutters omit the exact shoulder-taper triangle", problems)
    require(roundabout, "{ pavementInner0, pavementOuter0, pavementOuter1 }", "roundabout arm Sidewalk cutters omit their exact station triangle", problems)
    require(roundabout, "return model, roadwayFootprints", "buildArm drops the captured roadway footprints", problems)
    require(roundabout, "): (MouthSector?, MouthSector, ExitTrace?, { ConvexFootprint })", "buildMouth cannot distinguish footprint-owned solo pavement from paired sectors", problems)
    require(roundabout, "local collectSurfaceFootprints = ringSidewalkWidthM(style) > 1e-6", "paired mouths are excluded from physical surface ownership", problems)
    require(roundabout, "surfaceCutters: { ConvexFootprint }", "splitter/GoreApron surfaces cannot own the ring-pavement cut", problems)
    require(roundabout, "table.insert(surfaceCutters, { a, b, c })", "splitter/GoreApron triangles are not captured as cutters", problems)
    require(roundabout, "return pavementSector,", "paired mouths no longer return their angular pavement sector", problems)
    require_count(roundabout, "buildExactRingSidewalk(", 2, "exact ring sidewalk is not emitted for both standalone and connected roundabouts", problems)
    exact_open = roundabout.rfind("\tbuildExactRingSidewalk(")
    mouth_build = roundabout.find("\t\t\tbuildMouth(ring, plan")
    if exact_open < 0 or mouth_build < 0 or exact_open < mouth_build:
        problems.append("exact ring pavement is emitted before mouth ownership is known")
    require(roundabout, "\t\t{},\n\t\tsurfaceCutters\n\t)", "connected ring pavement still uses broad angular mouth sectors", problems)
    reject(roundabout, "openRingSidewalkByFootprints(ringSidewalk, soloRoadwayCutters)", "solo pavement regressed to post-build Part clipping", problems)
    reject(roundabout, "openRingPavement(ringSidewalk, center, mouthSectors, 0)", "paired pavement regressed to post-build Part clipping", problems)
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
    require(roundabout, "local needsExactSurface = arm.CutShoulderM > 1e-6", "roundabout arms have no exact raised-surface path", problems)
    require(roundabout, "ExcludeComponentIndices = if #sidewalkIndices > 0 then sidewalkIndices else nil", "RoadBuilder can still emit padded midpoint Sidewalk boxes on roundabout arms", problems)
    require(roundabout, "needsExactSurface = true", "constant-width roundabout arm Sidewalks can bypass exact station strips", problems)
    require(roundabout, 'part:SetAttribute("RW_ExactRoundaboutArmSurface", true)', "exact roundabout arm surfaces are not source-identifiable", problems)
    reject(roundabout, "local function replaceCutPavementCaps()", "roundabout arms regressed to replacing only one padded pavement cap", problems)
    require(roundabout, "Close the last frontage with a hybrid surface", "splitter frontage has no hybrid asphalt/concrete ownership at the kerb", problems)
    require(roundabout, "fillSurface(flatTriangle[1], flatTriangle[2], flatTriangle[3], apronDepth, makeApronPart)", "splitter frontage does not retain its complete flat asphalt underlay", problems)
    require(roundabout, "local exteriorFragments = subtractConvexFootprint(flatTriangle, ringDisc)", "splitter frontage does not clip raised concrete at the circular kerb", problems)
    require(roundabout, "local cutterRadius = ringKerbRadiusStuds / math.cos(circleStep / 2)", "splitter frontage kerb cutter is not conservatively circumscribed", problems)
    require(roundabout, "table.insert(raisedFragment, point + raisedLift)", "splitter frontage does not restore exterior median kerb fragments", problems)
    reject(roundabout, "FillTriangle(apex, boundary[k], boundary[k + 1], depth, DOWN, makeSidewalkPart, ring)", "splitter frontage still lays raised concrete chords across the circular kerb", problems)
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
    require(roundabout_preview, "mouth_surface_parts", "Python paired and solo mouth surfaces do not share ring ownership", problems)
    require(roundabout_preview, 'lambda part: part in ring_sidewalk', "Python footprint subtraction is not restricted to raised ring sidewalk", problems)
    require(roundabout_preview, "solo_pavement_sectors.append(pavement_sector)", "Python parity does not keep solo angular diagnostics separate from live paired sectors", problems)
    reject(roundabout_preview, "\n            pavement_sectors.append(pavement_sector)", "Python solo pavement has regressed to angular deletion", problems)
    require(roundabout_preview, "def check_solo_sidewalk_clearance(", "Python parity does not scan the complete solo roadway span", problems)
    require(roundabout_preview, "needs_exact_surface = bool(sidewalk_indices)", "Python parity can still model a constant arm Sidewalk as padded boxes", problems)
    reject(roundabout_preview, "exact_core = []", "Python roundabout preview no longer models RoadBuilder's padded core Parts", problems)
    require(roundabout_preview, "Keep RoadBuilder's midpoint rectangles", "Python padded-core ownership contract is undocumented", problems)
    reject(roundabout_preview, "victim = min(candidates", "Python parity still models single-cap replacement instead of exact arm strips", problems)
    require(roundabout_preview, "part_center = (sum(p[0] for p in poly)", "Python arm emission mutates the immutable roundabout centre", problems)
    require(roundabout_preview, "def seam_step_faults(", "Python parity has no failing approach/arm seam invariant", problems)
    require(roundabout_preview, "if worst > SEAM_STEP_TOLERANCE:", "Python CLI still reports a stepped seam as success", problems)
    require(roundabout_preview, '"solo_pavement_identity"', "Python parity does not exercise the exact-width asymmetric pavement cap path", problems)
    require(roundabout_preview, "faults.extend(check_solo_sidewalk_clearance(scene))", "Python solo sidewalk-clearance check is unreachable", problems)
    require(roundabout_preview, "def splitter_ring_intrusions(", "Python parity does not reject splitter chords inside the ring kerb", problems)
    require(roundabout_preview, '"mouth_sidewalk_lht": case(', "Python parity has no focused LHT arm-sidewalk regression", problems)
    require(roundabout_preview, '"mouth_sidewalk_rht": case(', "Python parity has no focused RHT arm-sidewalk regression", problems)

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
    require(settings, 'export type SnapConnectionMode = "AutomaticJunction" | "CrossSection"', "snap connection mode is missing", problems)
    require(settings, '"AutomaticJunction"\n\t\t) :: SnapConnectionMode', "legacy settings do not default to automatic junction building", problems)
    require(build_bar, '{ Id = "LeftRoadwayEdge", Text = "Left roadway edge" }', "Road Tools has no left-edge snap option", problems)
    require(build_bar, '{ Id = "RightRoadwayEdge", Text = "Right roadway edge" }', "Road Tools has no right-edge snap option", problems)
    require(build_bar, '{ Id = "AutomaticJunction", Text = "Build junction" }', "Road Tools cannot select automatic junction connections", problems)
    require(build_bar, '{ Id = "CrossSection", Text = "Cross-section only" }', "Road Tools cannot select alignment-only cross-section connections", problems)
    require(session, 'return placementConnectionMode == "AutomaticJunction"', "placement has no latched automatic-junction predicate", problems)
    require(session, "local function endpointSnapCandidate(", "controller-owned endpoint snapping has no canonicalisation boundary", problems)
    require(session, "if not automaticJunctionsEnabled() then\n\t\t\treturn {", "cross-section endpoint snaps jump to a controller centre instead of the selected visible section", problems)
    require(session, 'Kind = "Roundabout",\n\t\t\t\t\t\tPosition = attach', "automatic snapping cannot route a roundabout-owned approach back through its ring", problems)
    require(session, "RoundaboutBuilder.ConnectRoad(ring, model", "roundabout-owned endpoints can still fall through generic junction building", problems)
    require(session, "if isStart or isEnd then", "cross-section-only snapping is not reachable from both placement endpoints", problems)
    require(session, "if midDistance + 1e-4 < endpointDistance then", "cross-section snapping does not choose the closest station near road endpoints", problems)
    require(session, "if automaticJunctionsEnabled() and not RoadSplit.CanSplit(child) then", "alignment-only snapping still rejects feature-bearing target roads", problems)
    require(session, "not automaticJunctionsEnabled() or RoadSplit.CanSplitAt(child, station)", "automatic near-end snapping can preview a split that commit must reject", problems)
    require(session, 'if placementConnectionMode == "CrossSection" then', "parallel cross-section placement does not anchor a real carriageway on the selected datum", problems)
    require(session, "alignmentOriginOffsetM = (anchorIndex - (count + 1) / 2) * spacingM", "parallel cross-section placement still aligns an empty corridor centre", problems)
    require(session, "if not settings.SnapToRoad or not automaticJunctionsEnabled() then\n\t\t\treturn {}", "cross-section-only roads can still trigger automatic crossing junctions", problems)
    require(session, 'structure.Mode ~= "None"\n\t\t\tthen "Roads with custom or procedural structures cannot be split at a crossing yet"', "structured crossing previews can promise a junction that commit must reject", problems)
    require(session, "if not automaticJunctionsEnabled() then\n\t\t\t\treturn", "cross-section-only endpoint placement still mutates target topology", problems)
    require(session, "RefreshPlacementSettings: () -> ()", "live connection-mode changes cannot refresh the placement hover", problems)
    require(session, "local snapSemanticsChanged = requestedMode ~= placementConnectionMode", "connection mode is not latched for an active placement", problems)
    require(session, "or requestedSnapToRoad ~= placementSnapToRoad", "Snap to road changes can reinterpret an active placement", problems)
    require(session, "or requestedSnapReference ~= placementSnapReference", "snap-reference changes can mix datums in one placement", problems)
    require(session, "if #points > 0 then\n\t\t\t\tcancelPlacement()", "changing connection mode can reinterpret captured snap targets", problems)
    require(session, "profileOffsetM = 0\n\t\thoverSnapPos = nil", "cancelling an edge-anchored chain leaks its lateral offset into a new road", problems)
    require(session, "return Fitting.ConstrainEndpointTangents(segment, startTangentAxis, endTangentAxis)", "cross-section-only roads still end in an abrupt butt joint", problems)
    require(session, "local segment = buildSegment(hoverPos, hoverSnapMatch)", "cross-section preview does not use the committed tangent transition", problems)
    require(session, "solvedEnd = endSnapMatch.Position", "cross-section profile offsets can move the rendered carriageway off its target", problems)
    require(main_source, "currentSession.RefreshPlacementSettings()", "Road Tools changes leave a stale magnetic preview until the mouse moves", problems)
    require(session, "TopologyPosition: Vector3", "magnetic snaps do not preserve a separate topology datum", problems)
    require(session, 'local endTopologyPos = if settings.SnapReference == "Centre"', "endpoint Centre snaps leave topology on the hidden authored curve", problems)
    require(session, 'local startTopologyPos = if settings.SnapReference == "Centre"', "reverse endpoint Centre snaps leave topology on the hidden authored curve", problems)
    require(session, 'local topologyPosition = if settings.SnapReference == "Centre"', "mid-span Centre snaps leave topology on the hidden authored curve", problems)
    require(session, 'local refineSelectedReference = settings.SnapReference ~= "Centre"', "mid-span snapping does not refine against the selected visible reference", problems)
    require(session, "or math.abs(RoadInstance.ProfileOffsetAtStationM(data, station, settings.MetersToStuds)) > 1e-9", "offset Centre snapping still searches only the hidden authored curve", problems)
    require(session, "RoadSplit.SplitAt(road, station, getStyle(), settings, topologyPosition)", "mid-span snaps do not pass their captured physical topology datum to RoadSplit", problems)
    require_count(session, "midSpanMatch.TopologyPosition,", 1, "fallback mid-span connection drops its captured physical topology datum", problems)
    require(road_split, "junctionPosition: Vector3?", "RoadSplit cannot accept an offset profile-centre junction position", problems)
    require(road_split, "local splitPos = junctionPosition or data.Curve:PosAt(stationStuds)", "RoadSplit ignores an offset profile-centre junction position", problems)
    require(junction, "dx * dx + dz * dz > 0.25 * 0.25", "offset snap connections can still be mistaken for seamless pass-throughs", problems)

    require(road_instance, 'export type TransitionAnchor = "Centre" | "LeftEdge" | "RightEdge"', "road instances have no widening datum choices", problems)
    require(road_instance, "TransitionAnchor: TransitionAnchor", "road data cannot retain its widening datum", problems)
    require(road_instance, 'model:SetAttribute("RW_TransitionAnchor"', "widening datum is not stamped onto placed roads", problems)
    require(road_instance, 'model:GetAttribute("RW_TransitionAnchor")', "saved widening datum cannot be read back", problems)
    require(road_instance, "function RoadInstance.NormalizeTransitionAnchor", "legacy roads have no safe Centre-anchor fallback", problems)
    require(road_instance, "ProfileOffsetStartM: number", "road data cannot retain its starting profile-centre offset", problems)
    require(road_instance, "ProfileOffsetEndM: number", "road data cannot retain its destination profile-centre offset", problems)
    require(road_instance, "function RoadInstance.NormalizeProfileOffsetM", "legacy roads have no safe zero profile-offset fallback", problems)
    require(road_instance, "function RoadInstance.ProfileTransitionAlphaAtStation(", "read-side consumers cannot share RoadBuilder's transition progress", problems)
    require(road_instance, "function RoadInstance.ProfileOffsetAtStationM(", "read-side consumers have no canonical station-aware corridor offset", problems)
    require(road_instance, "local alpha = RoadInstance.ProfileTransitionAlphaAtStation(data, stationStuds, metersToStuds)", "station-aware corridor offsets do not follow the canonical transition taper", problems)
    require(road_instance, 'model:SetAttribute("RW_ProfileOffsetStartM"', "starting profile offset is not stamped onto placed roads", problems)
    require(road_instance, 'model:SetAttribute("RW_ProfileOffsetEndM"', "destination profile offset is not stamped onto placed roads", problems)
    require(road_instance, 'model:GetAttribute("RW_ProfileOffsetStartM")', "saved starting profile offset cannot be read back", problems)
    require(road_instance, 'model:GetAttribute("RW_ProfileOffsetEndM")', "saved destination profile offset cannot be read back", problems)
    require(road_builder, "TransitionAnchor: RoadInstance.TransitionAnchor?", "RoadBuilder has no widening datum input", problems)
    require(road_builder, "ProfileOffsetStartM: number?", "RoadBuilder cannot receive an inherited corridor offset", problems)
    require(road_builder, "ProfileOffsetEndM: number?", "RoadBuilder cannot receive an explicit destination corridor offset", problems)
    require(road_builder, "function RoadBuilder.TransitionAnchorOffsetM(", "RoadBuilder does not expose canonical widening datum math", problems)
    require(road_builder, "return (currentWidthM - startWidthM) / 2", "LeftEdge anchoring uses the wrong lateral sign", problems)
    require(road_builder, "return (startWidthM - currentWidthM) / 2", "RightEdge anchoring uses the wrong lateral sign", problems)
    require(road_builder, "function RoadBuilder.ProfileOffsetsMFor(", "RoadBuilder has no canonical persistent profile-offset derivation", problems)
    require(road_builder, "startOffsetM + RoadBuilder.TransitionAnchorOffsetM(", "destination corridor offset is not derived from its widening datum", problems)
    require(road_builder, "local x = -total / 2 + profileOffsetM * scale", "deck components ignore the persistent profile offset", problems)
    require(road_builder, "return offset0 + (offset1 - offset0) * u + profileOffsetM * scale", "lane markings ignore the persistent profile offset", problems)
    require(road_builder, "profileOffsetStartM,\n\t\tprofileOffsetEndM", "built roads do not persist their applied endpoint profile offsets", problems)
    require(session, "SetTransitionAnchor: (anchor: RoadInstance.TransitionAnchor) -> ()", "placement session cannot change the widening datum", problems)
    require(session, "GetTransitionAnchor: () -> RoadInstance.TransitionAnchor", "Road Tools cannot read the active widening datum", problems)
    require(session, "ProfileOffsetM: number?", "continuation sessions cannot inherit a corridor offset", problems)
    require(session, 'local transitionAnchor: RoadInstance.TransitionAnchor = "Centre"', "new transitions no longer preserve the historical centred default", problems)
    require(session, "local profileOffsetM = RoadInstance.NormalizeProfileOffsetM(", "new or legacy placement seeds do not safely normalize their corridor offset", problems)
    require(session, "local function corridorProfileOffsetsM()", "placement cannot derive a persistent destination corridor offset", problems)
    require(session, "return -endOffsetM, -startOffsetM", "reversed parallel placement does not mirror and swap endpoint profile offsets", problems)
    require_count(session, "TransitionAnchor = transitionAnchorForPlacement(", 4, "preview/final or parallel placement drops the widening datum", problems)
    require_count(session, "ProfileOffsetStartM =", 4, "preview/final or parallel placement drops the starting profile offset", problems)
    require_count(session, "ProfileOffsetEndM =", 4, "preview/final or parallel placement drops the destination profile offset", problems)
    require(session, 'elseif transitionAnchor == "LeftEdge" then\n\t\t\treturn "RightEdge"', "reversed parallel placement does not swap its physical left anchor", problems)
    require(session, 'elseif transitionAnchor == "RightEdge" then\n\t\t\treturn "LeftEdge"', "reversed parallel placement does not swap its physical right anchor", problems)
    require(session, "local leftM, rightM = roadwayEdgeOffsetsAtStationM(data, station)", "edge snapping ignores the road width at the selected transition station", problems)
    require(session, "RoadInstance.ProfileOffsetAtStationM(data, station, settings.MetersToStuds)", "Centre or edge snapping targets the authored curve instead of the station-shifted pavement mouth", problems)
    require(session, "leftM += profileOffsetM", "left-edge snapping ignores the station-aware corridor offset", problems)
    require(session, "rightM += profileOffsetM", "right-edge snapping ignores the station-aware corridor offset", problems)
    require(session, "then profileOffsetM", "Centre snapping ignores the station-aware corridor offset", problems)
    require(session, "profileOffsetM = nextProfileOffsetM", "a chained constant-width road recentres after an edge-anchored transition", problems)
    require(build_bar, "TransitionAnchor: RoadInstance.TransitionAnchor", "Road Tools has no widening datum prop", problems)
    require(build_bar, "children.TransitionAnchor = props.EndProfileId", "widening datum control is not scoped to transition placement", problems)
    require(build_bar, '{ Id = "Centre", Text = "Keep centre fixed" }', "Road Tools cannot keep a transition centred", problems)
    require(build_bar, '{ Id = "LeftEdge", Text = "Keep left edge fixed" }', "Road Tools cannot add/drop width on the right", problems)
    require(build_bar, '{ Id = "RightEdge", Text = "Keep right edge fixed" }', "Road Tools cannot add/drop width on the left", problems)
    require(build_bar, "props.SetTransitionAnchor(id :: RoadInstance.TransitionAnchor)", "widening datum dropdown does not change the placement session", problems)
    require(main_source, "TransitionAnchor = currentSession.GetTransitionAnchor()", "Road Tools does not receive the active widening datum", problems)
    require(main_source, "currentSession.SetTransitionAnchor(anchor)", "Road Tools widening datum changes never reach the placement session", problems)
    require_count(road_edit_session, "TransitionAnchor = data.TransitionAnchor", 3, "road edits can recenter an edge-anchored transition", problems)
    require_count(road_edit_session, "ProfileOffsetStartM = data.ProfileOffsetStartM", 3, "road edits can recenter a persisted corridor start", problems)
    require_count(road_edit_session, "ProfileOffsetEndM = data.ProfileOffsetEndM", 3, "road edits can recenter a persisted corridor destination", problems)
    require(road_edit_session, "ProfileOffsetM: number", "Place More continuation does not carry the profile-centre offset", problems)
    require(road_edit_session, "return RoadInstance.ProfileOffsetAtStationM(data, station, settings.MetersToStuds)", "editor hit-tests and ghosts can recenter an anchored transition", problems)
    require(road_edit_session, "ProfileOffsetM = -originalData.ProfileOffsetStartM", "Place More (Start) does not mirror the reversed local profile offset", problems)
    require(road_edit_session, "ProfileOffsetM = originalData.ProfileOffsetEndM", "Place More (End) does not retain the destination profile offset", problems)
    require_exact_count(main_source, "ProfileOffsetM = continuation.ProfileOffsetM", 2, "one of the two Place More actions drops its continuation profile offset", problems)
    require(junction, "TransitionAnchor = data.TransitionAnchor", "junction trimming can recenter an edge-anchored transition", problems)
    require(junction, "ProfileOffsetStartM = data.ProfileOffsetStartM", "junction trimming can recenter a persisted corridor start", problems)
    require(junction, "ProfileOffsetEndM = data.ProfileOffsetEndM", "junction trimming can recenter a persisted corridor destination", problems)
    require(roundabout, "TransitionAnchor = data.TransitionAnchor", "roundabout source-window rebuilds can recenter an edge-anchored transition", problems)
    require(roundabout, "ProfileOffsetStartM = data.ProfileOffsetStartM", "roundabout source-window rebuilds can recenter a persisted corridor start", problems)
    require(roundabout, "ProfileOffsetEndM = data.ProfileOffsetEndM", "roundabout source-window rebuilds can recenter a persisted corridor destination", problems)
    require(road_split, "TransitionAnchor = data.TransitionAnchor", "road splitting drops the persisted transition datum", problems)
    require(road_split, "ProfileOffsetStartM = data.ProfileOffsetStartM", "road splitting drops the persisted corridor start", problems)
    require(road_split, "ProfileOffsetEndM = data.ProfileOffsetEndM", "road splitting drops the persisted corridor destination", problems)
    require(structure, "-startWidthM / 2 + roadData.ProfileOffsetStartM", "procedural structures ignore the persisted starting road envelope", problems)
    require(structure, "-endWidthM / 2 + roadData.ProfileOffsetEndM", "procedural structures ignore the persisted destination road envelope", problems)
    require(structure, "local function targetPositionAt(station: number): Vector3", "custom structure modules have no station-aware road target", problems)
    require(structure, "RoadInstance.ProfileOffsetAtStationM(roadData, station, settings.MetersToStuds)", "custom structure modules recenter along an anchored transition", problems)
    require(structure, "return curve:PosAt(station) + frame.RightVector * profileOffsetStuds + frame.UpVector * offsetStuds", "custom structure modules do not apply the offset in the banked road frame", problems)
    require(structure, "local p0, p1 = targetPositionAt(s0), targetPositionAt(s1)", "custom structure module chords bypass the station-aware target", problems)
    require(structure, "RoadInstance.ProfileOffsetAtStationM(roadData, station, scale) * scale", "viaduct piers recenter beneath an anchored transition", problems)
    require(structure, "+ frame.RightVector * profileOffsetStuds", "viaduct piers do not follow the shifted banked deck", problems)
    require(structure, "frame * CFrame.new(roadCenterOffset, baseY, 0)", "procedural viaduct slab is not recentered around the transition envelope", problems)
    require(structure, "frame * CFrame.new(roadCenterOffset, floorTop - baseThickness / 2, 0)", "procedural tunnel shell is not recentered around the transition envelope", problems)
    require(transition_anchor_preview, 'ANCHORS = ("Centre", "LeftEdge", "RightEdge")', "Python widening preview omits a datum choice", problems)
    require(transition_anchor_preview, "for start_lanes, end_lanes in ((3, 4), (4, 3))", "Python widening preview does not exercise both widening and narrowing", problems)
    require(transition_anchor_preview, "CONTINUATION_LENGTH_M", "Python widening preview does not render the chained destination road", problems)
    require(transition_anchor_preview, "chained constant-width road recentres at the transition join", "Python widening preview has no chain-continuity invariant", problems)
    require(transition_anchor_preview, "def legacy_offset_faults", "Python widening preview does not verify legacy offsets default to zero", problems)
    require(transition_anchor_preview, "def injected_break_count()", "Python widening invariants have no injected break-tests", problems)

    require(setup_wizard, '"Welcome",', "first-run setup has no welcome step", problems)
    require(setup_wizard, '"Region",', "first-run setup cannot choose a regional standard", problems)
    require(setup_wizard, '"Terminology",', "first-run setup cannot choose US/UK terminology", problems)
    require(setup_wizard, '"Traffic side",', "first-run setup cannot choose traffic preference", problems)
    require(setup_wizard, '"Units",', "first-run setup cannot choose display units", problems)
    require(setup_wizard, '"Enjoy",', "first-run setup has no completion step", problems)
    require(setup_wizard, "local TOTAL_STEPS = #STEP_NAMES", "setup progress can drift from its actual step count", problems)
    require(setup_wizard, "local progress = currentStep / TOTAL_STEPS", "setup progress is not tied to the current step", problems)
    require(setup_wizard, "Size = UDim2.new(progress, 0, 1, 0)", "setup progress fill does not advance", problems)
    require(setup_wizard, "BackgroundColor3 = Theme.ACCENT", "setup progress does not use the easyRoad theme accent", problems)
    require(setup_wizard, "Size = UDim2.fromScale(1, 1)", "first-run setup does not cover its full host viewport", problems)
    require(setup_wizard, "local CONTENT_BORDER_INSET = 2", "setup content border is flush with its clipping viewport", problems)
    require(setup_wizard, 'ContentCard = e("Frame", {', "setup content stroke is still owned by the clipped ScrollingFrame", problems)
    region_dropdown_start = setup_wizard.find('DropdownRow = e("Frame", {')
    region_dropdown_scope = setup_wizard[region_dropdown_start:region_dropdown_start + 350]
    require(region_dropdown_scope, "AutomaticSize = Enum.AutomaticSize.Y", "region dropdown does not reserve space for its open menu", problems)
    require(setup_wizard, 'Title = "Enjoy!"', "setup completion page does not welcome the user", problems)
    require(setup_wizard, "props.OnComplete(copyResult(values))", "Finish does not apply the setup draft", problems)
    require(setup_wizard, "OnClick = props.OnSkip", "setup cannot be skipped cleanly", problems)
    require(setup_wizard_preview, "for column, step in enumerate((1, 5, 6))", "headless setup QA does not show Welcome, Units, and Enjoy", problems)
    require(setup_wizard_preview, "ACCENT = rgb_from_source(THEME_SOURCE", "headless setup QA invents a progress colour instead of reading Theme.ACCENT", problems)
    require(setup_wizard_preview, "def check()", "headless setup QA has no invariant/break-test entry point", problems)
    require(settings, "local ONBOARDING_VERSION = 1", "first-run completion has no versioned sentinel", problems)
    require(settings, "OnboardingVersion: number", "setup completion is absent from persisted settings", problems)
    require(settings, 'OnboardingVersion = math.floor(numberOr(raw, "OnboardingVersion", 0, 0, ONBOARDING_VERSION))', "setup completion is not sanitized on load", problems)
    require(settings, "OnboardingVersion = settings.OnboardingVersion", "setup completion is not serialized", problems)
    require(main_source, 'require("./UI/SetupWizard")', "first-run setup component is never mounted", problems)
    require(main_source, "return settings.OnboardingVersion >= Settings.OnboardingVersion", "completed users can be shown setup again", problems)
    require(main_source, "local gateSetup = pluginOpen and not gateEula and not reviewEula and not setupIsComplete()", "setup is not correctly sequenced after the commercial EULA", problems)
    require(main_source, 'screen.Name = "EasyRoadSetup"', "setup has no dedicated full-screen host", problems)
    require(main_source, "screen.Parent = CoreGui", "setup is constrained to a short plugin dock instead of Studio's viewport", problems)
    require(main_source, "React.createElement(SetupWizard", "setup host never renders the wizard", problems)
    require(main_source, "settings.RegionId = result.RegionId", "setup does not apply the chosen region", problems)
    require(main_source, "settings.LanguageVariant = result.LanguageVariant", "setup does not apply US/UK terminology", problems)
    require(main_source, "settings.DriveSideOverride = result.DriveSideOverride", "setup does not apply traffic-side preference", problems)
    require(main_source, 'if result.UnitsPreset == "Roblox" then', "setup does not apply Roblox display units", problems)
    require(main_source, 'elseif result.UnitsPreset == "Imperial" then', "setup does not apply imperial display units", problems)
    require_exact_count(main_source, "settings.OnboardingVersion = Settings.OnboardingVersion", 2, "Finish or Skip can leave setup incomplete and reopen it next launch", problems)
    require_exact_count(main_source, "OnComplete = function(result:", 1, "setup completion controller is missing or duplicated", problems)
    require_exact_count(main_source, "OnSkip = function()", 1, "setup skip controller is missing or duplicated", problems)
    require(main_source, "styleWithDriveSideOverride(regionLibrary.Get(settings.RegionId), settings.DriveSideOverride)", "saved traffic-side overrides are not applied to the initial built-in road library", problems)
    require(main_source, "styleWithDriveSideOverride(restoredRegions.Get(restored.RegionId), restored.DriveSideOverride)", "restored traffic-side overrides are not applied to rebuilt road presets", problems)
    run_setup_start = main_source.find("OnRunSetup = function()")
    run_setup_scope = main_source[run_setup_start:run_setup_start + 700]
    require(run_setup_scope, "destroySession()", "manual Quick Setup leaves an active placement on stale built-in profiles", problems)
    require(run_setup_scope, "editSession.CancelBayPlacement()", "manual Quick Setup leaves an active bus-bay editor behind its overlay", problems)
    require(run_setup_scope, "editSession.CancelMarkingStretchPlacement()", "manual Quick Setup leaves an active marking-stretch editor behind its overlay", problems)
    require(run_setup_scope, "editSession.CancelKerbStretchPlacement()", "manual Quick Setup leaves an active kerb-stretch editor behind its overlay", problems)
    require(run_setup_scope, "pluginOpen = true", "manual Quick Setup silently fails while the toolbar UI is closed", problems)
    require(settings, 'local SPEED_UNITS = { "Kmh", "Mph", "StudsPerSecond" }', "Roblox speed units are rejected by settings sanitization", problems)
    require(settings, 'local LENGTH_UNITS = { "Meters", "Feet", "Studs" }', "Roblox length units are rejected by settings sanitization", problems)
    require(units, 'settings.SpeedUnit == "StudsPerSecond"', "Roblox speed display has no conversion path", problems)
    require(units, 'settings.LengthUnit == "Studs"', "Roblox length display has no conversion path", problems)
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
    require_exact_count(structure, "local bankedFrameAt = makeBankedFrameAt(curve, settings)", 2, "imported structure paths no longer have the expected legacy bank-frame calls", problems)
    require_exact_count(structure, "local bankedFrameAt = makeBankedFrameAt(curve, settings, rollProfile)", 2, "procedural viaduct/tunnel paths do not share their refined canonical roll profile", problems)
    require(structure, "local STRUCTURE_BANK_MISMATCH_BUDGET_STUDS", "procedural structure bank mismatch has no explicit error budget", problems)
    require(structure, "local function refinedStructureRanges(", "procedural structures do not refine rigid bays through bank runoff", problems)
    require_exact_count(structure, 'folder:SetAttribute("RW_BankRefinementCapped", refinementCapped)', 2, "procedural structure refinement-cap diagnostics are missing", problems)
    require_exact_count(structure, 'folder:SetAttribute("RW_BankMismatchBudgetStuds", STRUCTURE_BANK_MISMATCH_BUDGET_STUDS)', 2, "procedural structure bank-mismatch budgets are not exposed", problems)
    viaduct_start = structure.find("local function placeProceduralViaduct(")
    tunnel_start = structure.find("local function placeProceduralTunnel(", viaduct_start)
    viaduct_scope = structure[viaduct_start:tunnel_start]
    require(viaduct_scope, "offsetSegmentFrame(", "curved viaduct parapets ignore their lateral chord", problems)
    require(viaduct_scope, "bankedFrameAt,", "curved viaduct parapets ignore the banked road frame", problems)
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
    require(structure_controls, 'Label = "Pillar width"', "Road Tools does not expose pillar width clearly", problems)
    require(structure_controls, 'Text = lengthLabel("Parapet height")', "Road Tools does not expose viaduct parapet height", problems)
    require(structure_controls, 'Text = lengthLabel("Vertical clearance")', "Road Tools does not expose tunnel height clearance", problems)
    require(regional_preferences, "Width = props.LabelWidth or 184", "Regional Preference rows cannot choose a control-appropriate label width", problems)
    require_count(regional_preferences, "LabelWidth = 120", 7, "Regional Preference dropdowns or bank slider still lose space to wide labels", problems)
    reject(regional_preferences, 'Text = "Auto (from speed + curvature)"', "Regional Preference banking mode still overflows its dropdown", problems)
    require(regional_preferences, 'Label = "Viaduct wall height (" .. Units.LengthSuffix(settings)', "Regional Preference lacks a compact unit-aware viaduct wall-height label", problems)
    require(regional_preferences, 'Label = "Tunnel height (" .. Units.LengthSuffix(settings)', "Regional Preference lacks a compact unit-aware tunnel height-clearance label", problems)
    require(regional_preferences, 'Label = "Concrete viaduct medians"', "Regional Preference viaduct-median copy still overflows the dock", problems)
    require(regional_preferences, "Units.LengthFromM(settings, activeStyle.DefaultLaneWidthM)", "Regional Preference region summary ignores the selected length units", problems)
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

    require(region_styles, "TrafficLeftEdgeLine: MarkingSpec?", "regional styles cannot distinguish the traffic-left roadway edge", problems)
    require(region_styles, "TrafficLeftEdgeLine = solid(US_YELLOW)", "the US preset does not default its traffic-left edge line to yellow", problems)
    require(region_styles, "cloneMarking(style.TrafficLeftEdgeLine)", "custom region copies lose their traffic-left edge rule", problems)
    require(region_styles, "serializeMarking(style.TrafficLeftEdgeLine)", "traffic-left edge rules are not persisted", problems)
    require(region_styles, "deserializeMarking(raw.TrafficLeftEdgeLine", "saved traffic-left edge rules cannot be restored", problems)
    require(markings, "local function collectTrafficLeftEdges(", "marking generation does not classify semantic traffic-left edges", problems)
    require(markings, "startEdge and style.TrafficLeftEdgeLine", "non-US regions cannot retain their legacy edge-line behavior", problems)
    require(markings, 'neighbor == nil or neighbor.Kind ~= "Drive"', "traffic-left edge detection can paint same-direction lane boundaries yellow", problems)
    require(markings, "endTrafficLeftForStartEdge[startEdge.EdgeIndex] = endEdge", "topology-changing transitions match yellow edges by raw component index", problems)
    require(markings, "if endTrafficEdge then endTrafficEdge.BoundaryOffsetM else boundaryEnd", "internal traffic-left separators ignore their semantic transition destination", problems)
    require(markings, 'restriction == "NoLine" and (not plainIsTrafficLeft or not keepTrafficLeftForNoLine)', "highway NoLine still suppresses the required US median-side yellow line", problems)
    same_direction_start = markings.find("-- Same-direction boundary: apply the component's rule")
    same_direction_end = markings.find('elseif (a.Kind == "Drive") ~= (b.Kind == "Drive")', same_direction_start)
    require(markings[same_direction_start:same_direction_end], "style.LaneLine.Color", "US same-direction lane separators no longer remain white", problems)
    require(region_editor, 'Label = "Traffic-left edge line"', "custom regional preferences cannot edit the traffic-left edge rule", problems)

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
    require(asset_panel, 'Text = "Import Selection as Ground Road"', "Road Assets cannot import literal ground-road Models", problems)
    require(asset_panel, 'Text = "Delete Selected Asset"', "Road Assets cannot manage stored Models", problems)
    require(structure_assets, 'export type AssetKind = "Ground" | "Viaduct" | "Tunnel"', "the stored asset library cannot classify Ground road modules", problems)
    require(structure_assets, 'clone:SetAttribute("ER_ModuleFit", "RigidRepeat")', "imported module fit semantics are not durable", problems)
    require(structure_assets, "socketCount(clone, START_SOCKET)", "custom road import does not reject ambiguous duplicate sockets", problems)
    require(structure_assets, "validateSockets(clone, startSocket, endSocket, autoSockets)", "custom road sockets have no bounds/orientation validation", problems)
    require(structure_assets, "function StructureAssets.CloneComplete(source: Model)", "custom road cloning can silently omit non-Archivable descendants", problems)
    require(structure_assets, "#clone:GetDescendants() ~= #instances - 1", "custom road cloning does not verify complete hierarchy parity", problems)
    require(structure_assets, "local clone, cloneError = StructureAssets.CloneComplete(source)", "custom road import bypasses complete hierarchy cloning", problems)
    require(structure_assets, "local readable = pcall(function()", "damaged custom-asset bounds can crash the Road Assets UI", problems)
    require(road_instance, 'export type StructureMode = "None" | "Ground" | "Viaduct" | "Tunnel"', "placed roads cannot serialize custom Ground mode", problems)
    require(structure, 'data.Mode == "Ground" and not data.AssetId', "custom Ground mode can erase a road when its asset is missing", problems)
    require(structure, 'generated.Name = GENERATED_NAME .. "_Pending"', "custom Ground replacement is not committed transactionally", problems)
    require(structure, 'existingMode == "Ground" and not proceduralSurfacePresent', "custom Ground mode switching can remove the only visible road", problems)
    require(structure, "StructureAssets.CloneComplete(template)", "stored custom road modules can be cloned only partially", problems)
    require(structure, 'data.Mode == "Ground" then suppressGeneratedRoadSurface(road)', "custom Ground modules overlay instead of replacing the procedural surface", problems)
    require(structure_controls, '{ Id = "Ground", Text = "Custom ground road" }', "Road Tools cannot select a custom Ground module", problems)
    require(session, 'structure.Mode == "Ground" then "New roads will use the selected custom ground-road module."', "Ground module placement has no explicit status", problems)
    require(main_source, 'elseif placementStructure.Mode == "Ground" then "Ground"', "Road Tools does not filter the library to Ground assets", problems)
    require(structure_assets, "function StructureAssets.ExportToWorkspace(assetId: string)", "stored road assets cannot be exported back to Workspace", problems)
    require(structure_assets, "local clone, cloneError = StructureAssets.CloneComplete(asset)", "Road Assets export does not clone the complete stored library Model", problems)
    require(structure_assets, "clone.Parent = workspace", "Road Assets export does not place its editable copy in Workspace", problems)
    require(main_source, 'History.Record("EasyRoadAssetExport", "Export road asset"', "Road Assets export is not one undoable history transaction", problems)
    require(main_source, "Selection:Set({ exported :: Model })", "Road Assets export does not select the new Workspace Model", problems)
    require(main_source, "OnExport = exportRoadAsset", "Road Assets panel export action is not wired to its controller", problems)
    require(asset_panel, 'Text = "Export Selected Asset to Workspace"', "Road Assets panel has no export button", problems)
    require(asset_panel, "Disabled = exportId == nil", "Road Assets export remains enabled without a selected library asset", problems)
    require(asset_panel, "props.OnExport(exportId)", "Road Assets export button does not invoke its callback", problems)
    reject(build_bar, "ImportStructureAsset", "Road Tools still owns the structure import workflow", problems)

    require(loader, 'createDock("EasyRoadSoftwareDock"', "Software dock is not created", problems)
    require(main_source, 'require("./UI/SoftwareGui")', "Software dock content is not rendered", problems)
    require(top_bar, 'Text = "Software"', "Settings menu has no Software entry", problems)
    reject(software.lower(), "easyrail", "Software dock still links or advertises easyRail", problems)
    require(loader, 'createDock("EasyRoadBackupsDock"', "Backups dock is not created", problems)
    require(main_source, 'local BackupsGui = require("./UI/BackupsGui")', "Backups dock has no renderer", problems)
    require(main_source, "BackupsOpen = backupsDock.Enabled", "Settings menu cannot show the active Backups dock", problems)
    require(top_bar, 'Text = "Backups"', "Settings menu has no Backups entry", problems)
    require(top_bar, "props.OnOpenBackups()", "Backups submenu entry is not wired", problems)
    require(backups, 'Text = "Backups"', "Backups dock has no task heading", problems)
    require(backups, 'Text = "Back up data"', "Backups dock cannot export plugin data", problems)
    require(backups, 'Text = "Restore data"', "Backups dock cannot begin a restore", problems)
    require(backups, "props.OnValidateRestoreData(transferText)", "Backups restore bypasses validation", problems)
    require(backups, 'Text = "Restore now"', "Backups dock has no explicit destructive confirmation", problems)
    reject(regional_preferences, 'Text = "Data Safety"', "backup controls remain embedded in Regional Preference", problems)
    reject(regional_preferences, "OnBackupData", "Regional Preference still owns backup behavior", problems)

    if problems:
        for problem in problems:
            print("FAILED:", problem)
        return 1
    print("integration contracts passed: isolated undo history, road duplication, curved/banked station plans, widening anchors, first-run setup, editable roundabouts, lane inference, one-way/highway mouths, Turbo width parity, exact caps, multinode junctions, assets, procedural structures, snap references, parallel roadways, marking boundaries, regional edge markings, highway presets, independent Settings docks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
