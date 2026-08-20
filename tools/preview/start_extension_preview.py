#!/usr/bin/env python3
"""Bird's-eye regression for ``Place More (Start)`` and ``Place More (End)``.

The two actions continue from opposite ends of a persisted road.  At ``End``
the new curve must leave in the stored forward tangent.  At ``Start`` it must
leave in the *negative* of the stored tangent: station zero points into the
existing road, so retaining that direction makes the new first curve turn back
over the source instead of extending the network outward.

The profile offset is directional too.  RoadBuilder applies it along the
curve's local right vector, therefore a Start continuation has to negate the
saved start offset when it reverses the tangent.  This script draws straight,
curved, and offset-curved source roads with both continuation choices, checks
the exact seam frame, and has injected mutants for all three sign mistakes.

It is a source-linked Python QA fixture, not Roblox execution:

    python tools/preview/start_extension_preview.py --check
    python tools/preview/start_extension_preview.py --out out/start-extension.png
"""

import argparse
from dataclasses import dataclass, replace
import json
import math
from pathlib import Path

from raster import Canvas
from setup_wizard_preview import draw_text


ROOT = Path(__file__).resolve().parents[2]
EDITOR = ROOT / "src" / "RoadEditSession.lua"
SESSION = ROOT / "src" / "createRoadSession.lua"
MAIN = ROOT / "src" / "main.lua"
PROFILE = ROOT / "src" / "RoadProfile.lua"

EPSILON = 1e-6
BACKGROUND = (23, 27, 34)
PANEL = (35, 41, 51)
ROAD = (76, 84, 99)
ROAD_DARK = (51, 58, 70)
EDGE = (222, 228, 235)
MARKING = (244, 244, 244)
CYAN = (76, 201, 210)
ORANGE = (225, 133, 80)
RED = (210, 79, 83)
DIM = (170, 180, 192)
MEDIAN = (103, 120, 105)
PROFILE_SCALE = 1.35


Point = tuple[float, float]


def add(a: Point, b: Point) -> Point:
    return a[0] + b[0], a[1] + b[1]


def sub(a: Point, b: Point) -> Point:
    return a[0] - b[0], a[1] - b[1]


def mul(a: Point, amount: float) -> Point:
    return a[0] * amount, a[1] * amount


def magnitude(value: Point) -> float:
    return math.hypot(value[0], value[1])


def unit(value: Point) -> Point:
    length = magnitude(value)
    if length <= EPSILON:
        raise ValueError("zero tangent")
    return value[0] / length, value[1] / length


def dot(a: Point, b: Point) -> float:
    return a[0] * b[0] + a[1] * b[1]


def right(tangent: Point) -> Point:
    """RoadBuilder's 2-D local right vector, for screen/world plan space."""
    return tangent[1], -tangent[0]


def cubic_at(points: tuple[Point, Point, Point, Point], t: float) -> Point:
    p0, p1, p2, p3 = points
    u = 1.0 - t
    return (
        u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
        u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1],
    )


def cubic_tangent(points: tuple[Point, Point, Point, Point], t: float) -> Point:
    p0, p1, p2, p3 = points
    u = 1.0 - t
    raw = (
        3 * u * u * (p1[0] - p0[0]) + 6 * u * t * (p2[0] - p1[0]) + 3 * t * t * (p3[0] - p2[0]),
        3 * u * u * (p1[1] - p0[1]) + 6 * u * t * (p2[1] - p1[1]) + 3 * t * t * (p3[1] - p2[1]),
    )
    return unit(raw)


def samples(points: tuple[Point, Point, Point, Point], count: int = 64) -> list[Point]:
    return [cubic_at(points, index / count) for index in range(count + 1)]


def offset_samples(points: tuple[Point, Point, Point, Point], offset: float, count: int = 64) -> list[Point]:
    return [
        add(cubic_at(points, index / count), mul(right(cubic_tangent(points, index / count)), offset))
        for index in range(count + 1)
    ]


@dataclass(frozen=True)
class SourceRoad:
    name: str
    points: tuple[Point, Point, Point, Point]
    profile_offset_start: float = 0.0
    profile_offset_end: float = 0.0
    # Left-to-right local components.  Their order matters at a reversed
    # continuation: a one-way highway's inner shoulder/median is asymmetric.
    components: tuple[tuple[str, float, int], ...] = (
        # Deliberately asymmetric 3/2 carriageways: this is the easy visual
        # tell for the old Start bug. Cloning instead of reversing the profile
        # moves the median and two lanes onto the wrong physical side.
        ("ShoulderA", 2.5, 0),
        ("DriveA1", 4.0, 1),
        ("DriveA2", 4.0, 1),
        ("DriveA3", 4.0, 1),
        ("Median", 3.5, 0),
        ("DriveB1", 4.0, -1),
        ("DriveB2", 4.0, -1),
        ("ShoulderB", 2.5, 0),
    )

    def position(self, end: str) -> Point:
        return cubic_at(self.points, 0.0 if end == "Start" else 1.0)

    def tangent(self, end: str) -> Point:
        return cubic_tangent(self.points, 0.0 if end == "Start" else 1.0)

    def offset(self, end: str) -> float:
        return self.profile_offset_start if end == "Start" else self.profile_offset_end


@dataclass(frozen=True)
class Seed:
    position: Point
    tangent: Point
    profile_offset: float
    components: tuple[tuple[str, float, int], ...]


def continuation_seed(source: SourceRoad, end: str, *, tangent_override: Point | None = None,
                      offset_override: float | None = None,
                      components_override: tuple[tuple[str, float, int], ...] | None = None) -> Seed:
    """Port the directional `RoadEditSession.GetContinuation` contract."""
    source_tangent = source.tangent(end)
    expected_tangent = mul(source_tangent, -1.0 if end == "Start" else 1.0)
    expected_offset = source.offset(end) * (-1.0 if end == "Start" else 1.0)
    expected_components = (
        tuple((kind, width, -direction) for kind, width, direction in reversed(source.components))
        if end == "Start" else source.components
    )
    return Seed(
        source.position(end),
        unit(tangent_override) if tangent_override is not None else expected_tangent,
        expected_offset if offset_override is None else offset_override,
        expected_components if components_override is None else components_override,
    )


def physical_datum(seed: Seed) -> Point:
    return add(seed.position, mul(right(seed.tangent), seed.profile_offset))


def source_datum(source: SourceRoad, end: str) -> Point:
    return add(source.position(end), mul(right(source.tangent(end)), source.offset(end)))


def component_datums(position: Point, tangent: Point, profile_offset: float,
                     components: tuple[tuple[str, float, int], ...]) -> dict[str, Point]:
    """World centres of asymmetric cross-section components at a road end."""
    total = sum(width for _, width, _ in components)
    x = -total / 2.0
    centres: dict[str, Point] = {}
    for kind, width, _direction in components:
        centre_x = x + width / 2.0
        centres[kind] = add(position, mul(right(tangent), profile_offset + centre_x))
        x += width
    return centres


def child_curve(seed: Seed, end: str) -> tuple[Point, Point, Point, Point]:
    """A deliberately bent first segment built from the locked seed tangent."""
    p0 = seed.position
    target = (
        add(p0, (-120, 38)) if end == "Start" else add(p0, (120, -38))
    )
    # The destination is intentionally not collinear: a perfect join needs the
    # *first handle*, not a coincidental straight chord.
    p1 = add(p0, mul(seed.tangent, 50.0))
    incoming = unit(sub(target, p0))
    p2 = sub(target, mul(incoming, 40.0))
    return p0, p1, p2, target


def seam_faults(source: SourceRoad, end: str, seed: Seed) -> list[str]:
    faults = []
    expected = mul(source.tangent(end), -1.0 if end == "Start" else 1.0)
    if dot(seed.tangent, expected) < 1.0 - EPSILON:
        faults.append(f"{end}: seed does not depart along the directed endpoint tangent")
    if magnitude(sub(physical_datum(seed), source_datum(source, end))) > EPSILON:
        faults.append(f"{end}: profile datum jumps at the source/child seam")
    source_components = component_datums(
        source.position(end), source.tangent(end), source.offset(end), source.components
    )
    child_components = component_datums(seed.position, seed.tangent, seed.profile_offset, seed.components)
    for kind, source_point in source_components.items():
        if kind not in child_components or magnitude(sub(source_point, child_components[kind])) > EPSILON:
            faults.append(f"{end}: asymmetric {kind} component jumps or swaps at the seam")
            break
    child = child_curve(seed, end)
    if dot(cubic_tangent(child, 0.0), seed.tangent) < 1.0 - EPSILON:
        faults.append(f"{end}: fitted first cubic does not retain locked seed tangent")
    # Start must leave away from the source's forward interior direction;
    # the strict sign check above is also clear to this human-facing harness.
    if end == "Start" and dot(seed.tangent, source.tangent("Start")) >= -1.0 + EPSILON:
        faults.append("Start: continuation points back into the source road")
    return faults


CASES = (
    SourceRoad("straight", ((170, 200), (216, 200), (264, 200), (310, 200))),
    SourceRoad("curve", ((160, 190), (210, 120), (265, 275), (320, 190))),
    SourceRoad("offset_curve", ((160, 205), (210, 128), (270, 280), (325, 192)), 12.0, -9.0),
)


def static_faults(editor: str, session: str, main: str, profile: str) -> list[str]:
    """Keep the preview tied to the production continuation hand-off."""
    faults = []
    for marker, message in (
        ("Tangent = -curve:TangentAt(0)", "Place More (Start) no longer reverses the source tangent"),
        ("Profile = RoadProfile.Reverse(profile)", "Place More (Start) no longer reverses asymmetric profile components"),
        ("ProfileOffsetM = -originalData.ProfileOffsetStartM", "Place More (Start) no longer mirrors its profile offset"),
        ("Tangent = curve:TangentAt(curve.Length)", "Place More (End) no longer keeps the forward tangent"),
        ("ProfileOffsetM = originalData.ProfileOffsetEndM", "Place More (End) no longer keeps its profile offset"),
    ):
        if marker not in editor:
            faults.append(message)
    if "local lockedTangent: Vector3? = if seed then seed.Tangent else nil" not in session:
        faults.append("seed tangent is not installed as the placement session's locked tangent")
    if main.count("Tangent = continuation.Tangent") != 2:
        faults.append("one Place More action drops the directed continuation tangent")
    for marker, message in (
        ("function RoadProfile.Reverse(profile: RoadProfile)", "RoadProfile has no directed continuation reversal helper"),
        ("Direction = -component.Direction", "reversed continuation does not invert lane directions"),
        ("source[oldIndex - 1].RightBoundary", "reversed continuation loses its physical boundary owner"),
        ("if rule == \"SolidDash\"", "reversed continuation does not mirror compound boundary order"),
        ("return \"DashSolid\"", "reversed continuation does not swap SolidDash to DashSolid"),
        ("elseif rule == \"DashSolid\"", "reversed continuation does not mirror DashSolid"),
        ("return \"SolidDash\"", "reversed continuation does not swap DashSolid to SolidDash"),
    ):
        if marker not in profile:
            faults.append(message)
    return faults


def validate(editor: str | None = None, session: str | None = None, main: str | None = None,
             profile: str | None = None) -> dict:
    editor = EDITOR.read_text(encoding="utf-8") if editor is None else editor
    session = SESSION.read_text(encoding="utf-8") if session is None else session
    main = MAIN.read_text(encoding="utf-8") if main is None else main
    profile = PROFILE.read_text(encoding="utf-8") if profile is None else profile
    faults = static_faults(editor, session, main, profile)
    rows = []
    for source in CASES:
        for end in ("Start", "End"):
            seed = continuation_seed(source, end)
            case_faults = seam_faults(source, end, seed)
            faults.extend(f"{source.name}/{fault}" for fault in case_faults)
            rows.append({
                "case": source.name,
                "end": end,
                "source_tangent": source.tangent(end),
                "seed_tangent": seed.tangent,
                "source_profile_offset": source.offset(end),
                "seed_profile_offset": seed.profile_offset,
                "physical_source_datum": source_datum(source, end),
                "physical_child_datum": physical_datum(seed),
            })
    return {"faults": faults, "rows": rows}


def injected_break_count() -> int:
    """Each historic sign mistake must produce a visible seam failure."""
    source = CASES[-1]
    mutants = (
        # The reported bug: Start gets the stored forward tangent.
        continuation_seed(source, "Start", tangent_override=source.tangent("Start")),
        # The tangent is right but the profile offset stays in its old local side.
        continuation_seed(source, "Start", offset_override=source.offset("Start")),
        # End is accidentally treated as a reversed continuation.
        continuation_seed(source, "End", tangent_override=mul(source.tangent("End"), -1.0)),
        continuation_seed(source, "End", offset_override=-source.offset("End")),
        # The original reported defect with an asymmetric one-way profile:
        # tangent/offset were reversed but local components were cloned intact.
        continuation_seed(source, "Start", components_override=source.components),
    )
    ends = ("Start", "Start", "End", "End", "Start")
    caught = 0
    for end, seed in zip(ends, mutants):
        if seam_faults(source, end, seed):
            caught += 1
    if caught != len(mutants):
        raise AssertionError(f"only {caught}/{len(mutants)} continuation sign regressions were caught")
    return caught


def check() -> dict:
    report = validate()
    if report["faults"]:
        raise AssertionError("; ".join(report["faults"]))
    report["injected_breaks"] = injected_break_count()
    return report


def clipped(canvas: Canvas, points: list[Point], width: int, colour: tuple[int, int, int]):
    canvas.polyline(points, colour, width)


def component_centres(components: tuple[tuple[str, float, int], ...]) -> list[tuple[str, float, int, float]]:
    total = sum(width for _, width, _ in components)
    x = -total / 2.0
    centres = []
    for kind, width, direction in components:
        centres.append((kind, width, direction, x + width / 2.0))
        x += width
    return centres


def draw_component_marks(canvas: Canvas, points: tuple[Point, Point, Point, Point], profile_offset: float,
                         components: tuple[tuple[str, float, int], ...], *, colour: tuple[int, int, int],
                         ghost: bool = False):
    """Show every travel lane and the unequal median in the rendered road frame."""
    for kind, width, _direction, centre_x in component_centres(components):
        component_path = offset_samples(points, profile_offset + centre_x * PROFILE_SCALE)
        if kind == "Median":
            clipped(canvas, component_path, max(3, int(width * PROFILE_SCALE)), RED if ghost else MEDIAN)
        elif kind.startswith("Drive"):
            # One dashed guide per actual lane: 3 on A, 2 on B. A legacy
            # un-reversed Start profile makes their groups visibly exchange
            # sides of the median (red ghost).
            for start in range(3, len(component_path) - 5, 11):
                clipped(canvas, component_path[start:start + 5], 2, colour)


def draw_road(canvas: Canvas, points: tuple[Point, Point, Point, Point], offset: float,
              components: tuple[tuple[str, float, int], ...], *, source: bool):
    path = offset_samples(points, offset)
    width = int(sum(component[1] for component in components) * PROFILE_SCALE + 8)
    clipped(canvas, path, width + 4, EDGE)
    clipped(canvas, path, width, ROAD if source else ROAD_DARK)
    draw_component_marks(canvas, points, offset, components, colour=MARKING)


def arrow(canvas: Canvas, origin: Point, tangent: Point, colour: tuple[int, int, int]):
    tip = add(origin, mul(tangent, 42))
    base = add(origin, mul(tangent, 9))
    normal = right(tangent)
    canvas.line(origin, tip, colour, 3)
    canvas.fill_poly([tip, add(base, mul(normal, 8)), sub(base, mul(normal, 8))], colour)


def render(path: Path) -> dict:
    report = check()
    canvas = Canvas(1500, 880, BACKGROUND)
    panel_w, panel_h = 470, 390
    draw_text(canvas, 38, 22, "PLACE MORE DIRECTED CONTINUATION", (245, 245, 245), 3)
    draw_text(canvas, 40, 52, "3/2 LANE PROFILE: WHITE/GREEN = CORRECT / RED GHOST = UNREVERSED START", DIM, 1)

    placements = (
        (CASES[0], "Start", 22, 105),
        (CASES[0], "End", 515, 105),
        (CASES[1], "Start", 1008, 105),
        (CASES[1], "End", 22, 500),
        (CASES[2], "Start", 515, 500),
        (CASES[2], "End", 1008, 500),
    )
    for source, end, x, y in placements:
        canvas.fill_poly([(x, y), (x + panel_w, y), (x + panel_w, y + panel_h), (x, y + panel_h)], PANEL)
        draw_text(canvas, x + 16, y + 15, f"{source.name} / {end}", (245, 245, 245), 2)
        seed = continuation_seed(source, end)
        child = child_curve(seed, end)
        # Shift local fixtures into their panel.  The standard source template
        # is chosen to fit all six panels without changing its endpoint frames.
        offset = (x - 28, y + 44)
        moved_source = tuple(add(point, offset) for point in source.points)
        moved_seed = replace(seed, position=add(seed.position, offset))
        moved_child = child_curve(moved_seed, end)
        draw_road(
            canvas,
            moved_source,
            source.profile_offset_start if end == "Start" else source.profile_offset_end,
            source.components,
            source=True,
        )
        draw_road(canvas, moved_child, moved_seed.profile_offset, moved_seed.components, source=False)
        if end == "Start":
            # Red dashes/median are not live geometry: they are the exact
            # historic clone-profile mutant, overlaid so the swapped 3/2
            # carriageways are plainly visible against the corrected bands.
            draw_component_marks(
                canvas,
                moved_child,
                moved_seed.profile_offset,
                source.components,
                colour=RED,
                ghost=True,
            )
        seam = physical_datum(moved_seed)
        canvas.disc(seam[0], seam[1], 8, CYAN)
        arrow(canvas, seam, moved_seed.tangent, ORANGE)
        draw_text(
            canvas,
            x + 16,
            y + panel_h - 36,
            "START = REVERSED 3/2 PROFILE / RED = LEGACY CLONE" if end == "Start"
            else "END = FORWARD 3/2 PROFILE",
            DIM,
            1,
        )

    path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(path)
    path.with_suffix(".json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="validate the production contracts and injected break tests")
    parser.add_argument("--out", type=Path, help="render bird's-eye continuation panels to this PNG")
    args = parser.parse_args()
    report = check() if args.check else (render(args.out) if args.out else check())
    print(f"start-extension continuation passed: {len(report['rows'])} endpoint frames, {report.get('injected_breaks', 4)} injected breaks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
