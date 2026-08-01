#!/usr/bin/env python3
"""Static wiring checks for Studio-only interaction paths.

These do not execute Luau. They protect the exact contracts that previously
made a feature look shipped while remaining unreachable in Studio: queryable
junction geometry, placement-time structure controls/rendering, a no-asset
tunnel fallback, and the Software settings dock.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


def require(text, needle, message, problems):
    if needle not in text:
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

    require(loader, 'createDock("EasyRoadSoftwareDock"', "Software dock is not created", problems)
    require(main_source, 'require("./UI/SoftwareGui")', "Software dock content is not rendered", problems)
    require(top_bar, 'Text = "Software"', "Settings menu has no Software entry", problems)

    if problems:
        for problem in problems:
            print("FAILED:", problem)
        return 1
    print("integration contracts passed: junction selection, placement structures, procedural tunnel, Software dock")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
