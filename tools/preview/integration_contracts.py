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
    session = source("src/createRoadSession.lua")
    build_bar = source("src/UI/BuildBar.lua")
    structure = source("src/StructureBuilder.lua")
    loader = source("loader.server.lua")
    main_source = source("src/main.lua")
    top_bar = source("src/UI/TopBar.lua")
    asset_panel = source("src/UI/RoadAssetsPanel.lua")
    software = source("src/UI/SoftwareGui.lua")

    require(junction, 'part.Name = "JunctionSurface"', "junction surface factory missing", problems)
    surface_factory = junction[junction.find('part.Name = "JunctionSurface"'):]
    require(surface_factory[:900], "part.CanQuery = true", "visible junction pad is not selectable", problems)

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
    print("integration contracts passed: junction selection, Road Assets, placement structures, procedural viaduct/tunnel, Software dock")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
