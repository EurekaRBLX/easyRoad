#!/usr/bin/env python3
"""Static wiring checks for Studio-only interaction paths.

These do not execute Luau. They protect the exact contracts that previously
made a feature look shipped while remaining unreachable in Studio: queryable
junction geometry, placement-time structure controls/rendering, dedicated
asset management, procedural viaduct/tunnel fallbacks, and the Software dock.
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


def main():
    problems = []
    junction = source("src/Mesh/JunctionBuilder.lua")
    junction_instance = source("src/JunctionInstance.lua")
    junction_session = source("src/JunctionEditSession.lua")
    junction_panel = source("src/UI/JunctionPanel.lua")
    session = source("src/createRoadSession.lua")
    build_bar = source("src/UI/BuildBar.lua")
    structure = source("src/StructureBuilder.lua")
    settings = source("src/Settings.lua")
    road_instance = source("src/RoadInstance.lua")
    road_split = source("src/RoadSplit.lua")
    profiles = source("src/RoadProfile.lua")
    curve = source("src/Geometry/CurveSegment.lua")
    parallel_controls = source("src/UI/ParallelControls.lua")
    loader = source("loader.server.lua")
    main_source = source("src/main.lua")
    top_bar = source("src/UI/TopBar.lua")
    asset_panel = source("src/UI/RoadAssetsPanel.lua")
    software = source("src/UI/SoftwareGui.lua")
    multinode_preview = source("tools/preview/multinode_junction_preview.py")

    require(junction, 'part.Name = "JunctionSurface"', "junction surface factory missing", problems)
    surface_factory = junction[junction.find('part.Name = "JunctionSurface"'):]
    require(surface_factory[:900], "part.CanQuery = true", "visible junction pad is not selectable", problems)
    require(road_instance, 'model:SetAttribute("RW_RoadId"', "roads have no stable id for junction approach ports", problems)
    require(road_instance, 'model:SetAttribute("RW_StartPortId"', "road starts have no stable approach-port identity", problems)
    require(road_instance, 'model:SetAttribute("RW_EndPortId"', "road ends have no stable approach-port identity", problems)
    require(road_split, "RoadInstance.PreserveOuterPortIds", "road splitting discards existing junction approach identities", problems)
    require(junction_instance, 'model:SetAttribute("RW_MultiNodeVersion", 2)', "junctions are not stamped as multinode v2", problems)
    require(junction_instance, "CornerRadiiM: { [string]: number }", "junctions do not persist per-corner radii", problems)
    require(junction, "FromApproachId: string", "junction layout does not expose approach-linked corner nodes", problems)
    require(junction, "radiusForCorner(junctionData, id)", "junction geometry ignores per-corner radius overrides", problems)
    require(junction_session, 'c:SetAttribute("RW_CornerId", corner.Id)', "corner handles do not retain stable corner identities", problems)
    require(junction_session, "SetSelectedCornerRadiusM", "selected corner radius cannot be edited", problems)
    require(junction_panel, 'Label = "Link all corner radii"', "junction editor cannot switch to per-corner radii", problems)
    require(multinode_preview, "from preview_core import (", "multinode preview no longer shares the roundabout component pipeline", problems)
    require(multinode_preview, "SIX_LANE_BOULEVARD = uk_two_way(3)", "multinode preview lost the UK six-lane boulevard case", problems)
    require(multinode_preview, 'suffix = "gaps" if flat else "parts"', "multinode preview no longer emits matching parts/gaps QA views", problems)
    require(multinode_preview, 'controls_name = f\'junction_{scene["tag"]}_controls.png\'', "multinode preview no longer emits the corner-radius showcase", problems)
    require(multinode_preview, 'metavar="CORNER=METRES"', "multinode preview corner radii are not adjustable from its CLI", problems)
    require(multinode_preview, "[1, 1, 1, -1, -1, -1]", "multinode preview no longer asserts UK left-hand direction ordering", problems)

    require(session, "GetStructure: () -> RoadInstance.StructureData", "placement session has no structure API", problems)
    require(session, "RoadInstance.StampStructure(model, appliedStructure)", "placed roads do not persist structure mode", problems)
    require(session, "StructureBuilder.Render(model, curve, structure, settings)", "placed roads do not render structures", problems)
    require(
        build_bar,
        'children.Structure = props.ToolMode ~= "Roundabout" and e(StructureControls',
        "Road Tools does not expose structure controls",
        problems,
    )
    require(structure, "placeProceduralTunnel(generated, road, curve, data, settings)", "no-asset tunnel fallback is missing", problems)
    require(structure, "placeProceduralViaduct(generated, road, curve, data, settings)", "no-asset viaduct fallback is missing", problems)
    require(structure, 'string.format("DeckSlab_%04d"', "procedural viaduct has no structural slab", problems)
    require(structure, 'string.format("Vault_%02d_%04d"', "procedural tunnel has no segmented vault", problems)
    require(structure, "data.InterfaceOverlapM * scale", "procedural structures cannot close the road interface gap", problems)
    require(structure, "data.ViaductParapetGapM * scale", "viaduct parapet gap is not configurable", problems)
    require(structure, "data.TunnelWallClearanceM * scale", "tunnel wall clearance is not configurable", problems)
    require(structure, "restyleElevatedMedian", "viaduct medians cannot be changed to concrete", problems)
    require(settings, "StructureConcreteColorHex", "settings do not persist procedural concrete colour", problems)
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

    for lane_count in range(1, 6):
        require(
            profiles,
            f'builtin_highway_oneway_{lane_count}',
            f"one-way {lane_count}-lane highway preset is missing",
            problems,
        )

    require(top_bar, 'Text = "Road Assets"', "top mode bar has no Road Assets surface", problems)
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
    print("integration contracts passed: multinode junctions, assets, procedural structures, parallel roadways, highway presets, Software dock")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
