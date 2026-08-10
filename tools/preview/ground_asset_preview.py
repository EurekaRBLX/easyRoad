#!/usr/bin/env python3
"""Source-linked QA and PNG preview for custom Ground road modules.

The geometry port reuses ``structure_preview.module_ranges`` because Ground,
Viaduct, and Tunnel assets intentionally share one rigid socket-chord tiler.
It also exercises the importer's duplicate/partial/bounds/orientation policy
and checks that Lua suppresses the procedural road only after module placement
succeeds.

    python tools/preview/ground_asset_preview.py --check
    python tools/preview/ground_asset_preview.py --out tools/preview/out/ground-road-assets.png
"""

import argparse
import math
import os
import sys

from raster import Canvas
from structure_preview import Cubic3, EPSILON, dist, module_errors, module_ranges


HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def magnitude(vector):
    return math.sqrt(dot(vector, vector))


def unit(vector):
    length = magnitude(vector)
    return tuple(value / length for value in vector)


def bounds_excess(size, position):
    return max(*(abs(value) - extent / 2 for value, extent in zip(position, size)), 0.0)


def validate_socket_contract(
    start_count,
    end_count,
    start=(-0.0, 0.0, 15.0),
    end=(0.0, 0.0, -15.0),
    bounds=(24.0, 4.0, 30.0),
    start_forward=(0.0, 0.0, -1.0),
    start_up=(0.0, 1.0, 0.0),
    end_up=(0.0, 1.0, 0.0),
):
    """Python port of StructureAssets' acceptance and warning decisions."""
    if start_count > 1 or end_count > 1:
        return None, "duplicate sockets"
    if (start_count == 1) != (end_count == 1):
        return None, "partial socket pair"
    if start_count == 0:
        return [], None
    chord = tuple(b - a for a, b in zip(start, end))
    length = magnitude(chord)
    if length < 0.1:
        return None, "overlapping sockets"
    largest = max(bounds)
    worst = max(bounds_excess(bounds, start), bounds_excess(bounds, end))
    if worst > max(16.0, largest * 2.0):
        return None, "socket far outside bounds"
    warnings = []
    if worst > max(0.5, length * 0.15):
        warnings.append("socket outside visible bounds")
    if dot(start_forward, unit(chord)) < 0.35:
        warnings.append("start orientation disagrees with chord")
    if dot(start_up, end_up) < 0:
        warnings.append("socket up vectors disagree")
    return warnings, None


def clone_is_complete(expected_descendants, cloned_descendants, expected_parts, cloned_parts):
    """Mirrors the all-or-nothing hierarchy gate around Instance:Clone."""
    return expected_descendants == cloned_descendants and expected_parts == cloned_parts


def visible_after_ground_attempt(existing_ground, procedural_surface, replacement_complete):
    """A failed detached build must leave whichever visible fallback existed."""
    if not replacement_complete:
        return existing_ground or procedural_surface
    return True


def demo_curve():
    return Cubic3((0, 0, 0), (60, 0, -18), (125, 0, 75), (215, 0, 82))


def source_contract_errors():
    with open(os.path.join(ROOT, "src", "StructureAssets.lua"), encoding="utf-8") as handle:
        assets = handle.read()
    with open(os.path.join(ROOT, "src", "StructureBuilder.lua"), encoding="utf-8") as handle:
        builder = handle.read()
    with open(os.path.join(ROOT, "src", "RoadInstance.lua"), encoding="utf-8") as handle:
        instance = handle.read()
    with open(os.path.join(ROOT, "src", "UI", "RoadAssetsPanel.lua"), encoding="utf-8") as handle:
        panel = handle.read()
    with open(os.path.join(ROOT, "src", "UI", "StructureControls.lua"), encoding="utf-8") as handle:
        controls = handle.read()

    errors = []
    expected = (
        (assets, 'export type AssetKind = "Ground" | "Viaduct" | "Tunnel"', "Ground asset kind is absent"),
        (assets, 'clone:SetAttribute("ER_ModuleFit", "RigidRepeat")', "asset fit contract is not persisted"),
        (assets, "socketCount(clone, START_SOCKET)", "duplicate socket validation is absent"),
        (assets, "validateSockets(clone, startSocket, endSocket, autoSockets)", "socket geometry is not validated"),
        (instance, 'export type StructureMode = "None" | "Ground" | "Viaduct" | "Tunnel"', "Ground mode is not serializable"),
        (builder, 'data.Mode == "Ground" and not data.AssetId', "Ground mode lacks a safe missing-asset fallback"),
        (assets, "function StructureAssets.CloneComplete(source: Model)", "asset cloning is not all-or-nothing"),
        (assets, "instance.Archivable = true", "non-Archivable descendants can be silently omitted"),
        (assets, "#clone:GetDescendants() ~= #instances - 1", "complete hierarchy counts are not verified"),
        (assets, "local clone, cloneError = StructureAssets.CloneComplete(source)", "Ground import bypasses complete hierarchy cloning"),
        (assets, "local readable = pcall(function()", "damaged legacy asset bounds can crash the asset UI"),
        (builder, "StructureAssets.CloneComplete(template)", "edited library assets can be cloned only partially"),
        (builder, 'data.Mode == "Ground" then suppressGeneratedRoadSurface(road)', "Ground mode does not replace the procedural surface"),
        (builder, 'generated.Name = GENERATED_NAME .. "_Pending"', "replacement structures are not committed transactionally"),
        (builder, 'existingMode == "Ground" and not proceduralSurfacePresent', "Ground mode switching can remove the only visible road"),
        (panel, 'Text = "Import Selection as Ground Road"', "Road Assets UI cannot import Ground Models"),
        (controls, '{ Id = "Ground", Text = "Custom ground road" }', "Road Tools cannot select Ground modules"),
    )
    for source, needle, message in expected:
        if needle not in source:
            errors.append(message)

    placed = builder.find("placeModules(generated, road, curve, asset")
    parented = builder.find("generated.Parent = road", placed)
    suppressed = builder.find('data.Mode == "Ground" then suppressGeneratedRoadSurface(road)')
    removed_previous = builder.find("existingStructure:Destroy()", suppressed)
    if placed < 0 or parented < placed or suppressed < parented or removed_previous < suppressed:
        errors.append("procedural surface can be removed before custom modules succeed")
    render = builder.find("function StructureBuilder.Render(")
    none_branch = builder.find('if data.Mode == "None" then', render)
    clear = builder.find("StructureBuilder.Clear(road)", render)
    generated = builder.find("local generated = makeGeneratedModel()", render)
    if min(render, none_branch, clear, generated) < 0 or not (none_branch < clear < generated):
        errors.append("Render still clears an existing Ground structure before replacement validation")
    return errors


def validate():
    errors = source_contract_errors()
    warnings, error = validate_socket_contract(1, 1)
    if error or warnings:
        errors.append("valid explicit socket pair was not accepted cleanly")
    warnings, error = validate_socket_contract(0, 0)
    if error or warnings:
        errors.append("socket-free Model did not receive automatic-bounds acceptance")
    if validate_socket_contract(1, 0)[1] != "partial socket pair":
        errors.append("lone socket was not rejected")
    if validate_socket_contract(2, 1)[1] != "duplicate sockets":
        errors.append("duplicate socket was not rejected")
    if validate_socket_contract(1, 1, end=(0.0, 0.0, 15.02))[1] != "overlapping sockets":
        errors.append("overlapping socket pair was not rejected")
    warnings, error = validate_socket_contract(1, 1, start_forward=(0.0, 0.0, 1.0))
    if error or not warnings or "orientation" not in warnings[0]:
        errors.append("reversed start orientation did not produce a recoverable warning")
    if validate_socket_contract(1, 1, start=(0.0, 0.0, 200.0))[1] != "socket far outside bounds":
        errors.append("wildly displaced socket was not rejected")
    if clone_is_complete(12, 11, 5, 4):
        errors.append("partial non-Archivable clone was accepted as a complete rigid module")
    if not clone_is_complete(12, 12, 5, 5):
        errors.append("complete rigid module clone was rejected")
    if not visible_after_ground_attempt(True, False, False):
        errors.append("failed Ground replacement erased the existing custom road")
    if not visible_after_ground_attempt(False, True, False):
        errors.append("failed Ground replacement erased the procedural fallback")

    curve = demo_curve()
    ranges = module_ranges(curve, 30.0)
    errors.extend(module_errors(curve, ranges, 30.0))
    if not ranges or abs(ranges[-1][1] - curve.length) > EPSILON:
        errors.append("Ground module repetition does not close the road end")
    return curve, ranges, errors


def quad_around(a, b, half_width):
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = math.hypot(dx, dy) or 1.0
    nx, ny = -dy / length * half_width, dx / length * half_width
    return [(a[0] + nx, a[1] + ny), (b[0] + nx, b[1] + ny),
            (b[0] - nx, b[1] - ny), (a[0] - nx, a[1] - ny)]


def render(path):
    curve, ranges, errors = validate()
    if errors:
        raise AssertionError("; ".join(errors))

    canvas = Canvas(1100, 680, (27, 31, 39))
    canvas.line((35, 390), (1065, 390), (72, 82, 96), 2)

    def plan(position):
        x, _y, z = position
        return 65 + x * 4.25, 150 + z * 2.35

    centerline = [plan(curve.pos(curve.length * i / 180)) for i in range(181)]
    canvas.polyline(centerline, (94, 102, 115), 42)
    colours = ((73, 127, 154), (85, 148, 126))
    for index, (start, end) in enumerate(ranges):
        a, b = plan(curve.pos(start)), plan(curve.pos(end))
        canvas.fill_poly(quad_around(a, b, 19), colours[index % 2])
        canvas.line(a, b, (57, 61, 69), 7)
        canvas.line(a, b, (232, 230, 216), 2)
        canvas.disc(a[0], a[1], 5, (217, 132, 85))
        canvas.disc(b[0], b[1], 5, (217, 132, 85))

    # Replacement ownership: the compact red-crossed procedural section on the
    # left is discarded only after the intact authored module on the right has
    # cloned successfully. Orange endpoints are the module sockets.
    surface_y = 515
    canvas.fill_poly([(65, surface_y), (320, surface_y), (320, surface_y + 34), (65, surface_y + 34)], (81, 84, 91))
    for x in (130, 195, 260):
        canvas.line((x, surface_y + 2), (x, surface_y + 31), (226, 226, 220), 2)
    canvas.line((50, 585), (335, 480), (196, 43, 28), 7)
    canvas.line((50, 480), (335, 585), (196, 43, 28), 7)
    canvas.line((365, 532), (435, 532), (217, 132, 85), 7)
    canvas.fill_poly([(435, 532), (416, 519), (416, 545)], (217, 132, 85))

    canvas.fill_poly([(465, surface_y), (745, surface_y), (745, surface_y + 42), (465, surface_y + 42)], (62, 65, 72))
    canvas.fill_poly([(465, surface_y - 20), (515, surface_y - 20), (515, surface_y), (465, surface_y)], (181, 167, 139))
    canvas.fill_poly([(695, surface_y - 20), (745, surface_y - 20), (745, surface_y), (695, surface_y)], (181, 167, 139))
    for x in (560, 605, 650):
        canvas.line((x, surface_y + 2), (x, surface_y + 38), (235, 235, 227), 3)
    canvas.disc(465, surface_y + 20, 7, (217, 132, 85))
    canvas.disc(745, surface_y + 20, 7, (217, 132, 85))

    # Import validation glyphs: explicit pair, automatic bounds, and a partial
    # pair rejected before it can enter the game-owned library.
    panels = ((825, (85, 148, 126)), (935, (73, 127, 154)), (1045, (196, 43, 28)))
    for x, colour in panels:
        canvas.fill_poly([(x - 43, 485), (x + 43, 485), (x + 43, 565), (x - 43, 565)], colour)
    for x in (825, 935):
        canvas.disc(x - 29, 525, 7, (217, 132, 85))
        canvas.disc(x + 29, 525, 7, (217, 132, 85))
        canvas.line((x - 22, 525), (x + 22, 525), (232, 230, 216), 3)
    canvas.disc(1016, 525, 7, (217, 132, 85))
    canvas.line((1002, 575), (1088, 475), (232, 230, 216), 7)
    canvas.line((1002, 475), (1088, 575), (232, 230, 216), 7)

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    canvas.save(path)
    return len(ranges), curve.length


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--out")
    args = parser.parse_args()
    if args.out:
        count, length = render(args.out)
        print(f"wrote {args.out}: {count} rigid Ground modules cover {length:.1f} studs")
        return 0
    curve, ranges, errors = validate()
    if errors:
        for error in errors:
            print("FAILED:", error)
        return 1
    print(f"ground asset checks passed: {len(ranges)} rigid modules cover {curve.length:.1f} studs; socket failures are recoverable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
