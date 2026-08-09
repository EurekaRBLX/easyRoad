#!/usr/bin/env python3
"""Bird's-eye contract for UK and US ordinary-road marking colours.

The eight panels are arranged as US/UK columns and undivided/divided-highway/
one-way-highway/2x2-to-3x3-transition rows.  The semantic checker covers the
distinctions that are easy to lose when all lane boundaries are emitted through
one generic path:

* an opposing-flow boundary is the US yellow centre line;
* same-direction lane separators stay white;
* each US divided carriageway has yellow on its traffic-left (median) edge and
  white on its traffic-right edge;
* a shoulder-equipped one-way highway paints that yellow line once, at the
  traffic-left Drive/shoulder boundary rather than again at the shoulder rim;
* a widening or narrowing maps each yellow line by traffic direction to the
  destination median edge, never to the newly inserted lane divider;
* a local ``NoLine`` span suppresses even a mandatory US yellow edge and then
  resumes it, while the UK highway's global ``NoLine`` leaves median edges
  unpainted rather than inventing white lines.

    python regional_marking_preview.py --check
    python regional_marking_preview.py --out out/regional-marking-colours.png

This is a Python model, not a Luau execution.  integration_contracts.py guards
the corresponding source wiring separately.
"""
import argparse
from dataclasses import dataclass, replace
import os

from raster import Canvas


ASPHALT = (60, 60, 62)
SHOULDER = (150, 156, 164)
MEDIAN = (114, 132, 104)
WHITE = (235, 235, 228)
US_YELLOW = (255, 196, 18)
BACKGROUND = (232, 238, 244)
PANEL = (214, 222, 230)
ARROW = (138, 158, 178)


@dataclass(frozen=True)
class Region:
    name: str
    drive_on_left: bool
    centre: tuple
    lane: tuple
    edge: tuple
    traffic_left_edge: tuple | None


@dataclass(frozen=True)
class Marking:
    role: str
    x: float
    colour: tuple
    pattern: str
    direction: int = 0


@dataclass(frozen=True)
class Component:
    kind: str
    width: float
    direction: int = 0


@dataclass(frozen=True)
class TrafficEdge:
    edge: int
    direction: int
    x: float


@dataclass(frozen=True)
class TransitionLine:
    direction: int
    start_edge: int
    end_edge: int
    start_x: float
    end_x: float
    colour: tuple


@dataclass(frozen=True)
class StationLine:
    direction: int
    colour: tuple
    from_station: float
    to_station: float


US = Region("US", False, US_YELLOW, WHITE, WHITE, US_YELLOW)
UK = Region("UK", True, WHITE, WHITE, WHITE, None)


def traffic_left_edge_colour(region, direction, profile_left):
    """Port the signed profile-edge rule used by Markings.Compute."""
    is_traffic_left = ((profile_left and direction > 0)
                       or (not profile_left and direction < 0))
    if is_traffic_left and region.traffic_left_edge is not None:
        return region.traffic_left_edge, "traffic-left edge"
    return region.edge, "traffic-right edge" if not is_traffic_left else "traffic-left edge"


def undivided_plan(region):
    """A four-lane undivided road: two lanes in each direction."""
    directions = (-1, -1, 1, 1)
    lane_width = 1.0
    left = -len(directions) * lane_width / 2
    lines = [Marking("outer edge", left, region.edge, "solid", directions[0])]
    for index, (a, b) in enumerate(zip(directions, directions[1:])):
        x = left + (index + 1) * lane_width
        if a != b:
            pattern = "double" if region.name == "US" else "dashed"
            lines.append(Marking("opposing centre", x, region.centre, pattern))
        else:
            lines.append(Marking("same-direction lane", x, region.lane, "dashed", a))
    lines.append(Marking("outer edge", -left, region.edge, "solid", directions[-1]))
    return lines


def divided_plan(region):
    """Two shoulder-equipped carriageways with highway ``NoLine`` enabled."""
    forward_left = region.drive_on_left
    runs = (
        (-2.2, -0.2, 1 if forward_left else -1, False),
        (0.2, 2.2, -1 if forward_left else 1, True),
    )
    lines = []
    for left, right, direction, median_on_left in runs:
        outer = right if median_on_left else left
        median = left if median_on_left else right
        lines.append(Marking("outer Drive/shoulder edge", outer,
                             region.edge, "solid", direction))
        lines.append(Marking("same-direction lane", (left + right) / 2,
                             region.lane, "dashed", direction))
        median_is_profile_left = median_on_left
        colour, role = traffic_left_edge_colour(
            region, direction, median_is_profile_left)
        # Built-in highways use KerbRestriction=NoLine.  That suppresses a
        # plain UK median edge, but the mandatory US traffic-left spec survives
        # unless a local NoLine stretch explicitly targets it.
        if role == "traffic-left edge" and region.traffic_left_edge is not None:
            lines.append(Marking(role, median, colour, "solid", direction))
    return lines


def divided_faults(region, lines):
    faults = []
    lane_lines = [line for line in lines if line.role == "same-direction lane"]
    outer_lines = [line for line in lines if line.role == "outer Drive/shoulder edge"]
    median_lines = [line for line in lines if abs(abs(line.x) - 0.2) < 1e-9]
    if len(lane_lines) != 2 or any(line.colour != WHITE for line in lane_lines):
        faults.append(f"{region.name} divided same-direction separators are not white")
    if len(outer_lines) != 2 or any(line.colour != WHITE for line in outer_lines):
        faults.append(f"{region.name} divided Drive/shoulder edges are not white")
    if region.name == "US":
        if len(median_lines) != 2 or any(line.colour != US_YELLOW for line in median_lines):
            faults.append("US divided median-side edges are not yellow")
    elif median_lines:
        faults.append("UK highway NoLine did not suppress its median-edge lines")
    return faults


def one_way_highway_plan(region):
    """Three forward lanes bounded by inner and outer highway shoulders."""
    direction = 1
    lines = []
    colour, role = traffic_left_edge_colour(region, direction, True)
    lines.append(Marking(role, -1.5, colour, "solid", direction))
    lines.append(Marking("same-direction lane", -0.5,
                         region.lane, "dashed", direction))
    lines.append(Marking("same-direction lane", 0.5,
                         region.lane, "dashed", direction))
    colour, role = traffic_left_edge_colour(region, direction, False)
    lines.append(Marking(role, 1.5, colour, "solid", direction))
    return lines


def one_way_faults(region, lines):
    faults = []
    yellow = [line for line in lines if line.colour == US_YELLOW]
    if region.name == "US":
        if len(yellow) != 1:
            faults.append(f"US one-way highway has {len(yellow)} yellow lines, expected one")
        elif yellow[0].role != "traffic-left edge" or abs(yellow[0].x + 1.5) > 1e-9:
            faults.append("US one-way yellow is not at the Drive/inner-shoulder boundary")
        if any(line.role == "inner shoulder outer edge" for line in yellow):
            faults.append("US one-way yellow is duplicated at the inner shoulder rim")
    elif any(line.colour != WHITE for line in lines):
        faults.append("UK one-way highway markings no longer remain white")
    if any(line.colour != WHITE for line in lines
           if line.role in ("same-direction lane", "traffic-right edge")):
        faults.append(f"{region.name} one-way lane/traffic-right marking is not white")
    return faults


def highway_components(lanes):
    """Compact US/RHT equivalent of the built-in divided-highway profile."""
    return ([Component("Shoulder", 0.5)]
            + [Component("Drive", 1.0, -1) for _ in range(lanes)]
            + [Component("Median", 0.4)]
            + [Component("Drive", 1.0, 1) for _ in range(lanes)]
            + [Component("Shoulder", 0.5)])


def match_for_transition(start, end):
    """Port RoadProfile.MatchForTransition's two-edge greedy matching."""
    start_count, end_count = len(start), len(end)
    left = 0
    while (left < start_count and left < end_count
           and start[left].kind == end[left].kind):
        left += 1
    right = 0
    while (right < start_count - left and right < end_count - left
           and start[start_count - right - 1].kind == end[end_count - right - 1].kind):
        right += 1

    def zero_of(component):
        return replace(component, width=0.0)

    out_start = list(start[:left])
    out_end = list(end[:left])
    middle_start = start_count - left - right
    middle_end = end_count - left - right
    for index in range(max(middle_start, middle_end)):
        out_start.append(start[left + index] if index < middle_start
                         else zero_of(end[left + index]))
        out_end.append(end[left + index] if index < middle_end
                       else zero_of(start[left + index]))
    if right:
        out_start.extend(start[-right:])
        out_end.extend(end[-right:])
    return out_start, out_end


def component_boundaries(components):
    total = sum(component.width for component in components)
    result = [-total / 2]
    for component in components:
        result.append(result[-1] + component.width)
    return result


def traffic_left_edges(components):
    boundaries = component_boundaries(components)
    edges = []
    for index, component in enumerate(components):
        if component.kind != "Drive" or component.direction == 0:
            continue
        profile_left = component.direction > 0
        neighbor_index = index - 1 if profile_left else index + 1
        neighbor = (components[neighbor_index]
                    if 0 <= neighbor_index < len(components) else None)
        if neighbor is None or neighbor.kind != "Drive":
            edge = index if profile_left else index + 1
            edges.append(TrafficEdge(edge, component.direction, boundaries[edge]))
    return edges


def same_direction_edges(components):
    return {index for index in range(1, len(components))
            if components[index - 1].kind == "Drive"
            and components[index].kind == "Drive"
            and components[index - 1].direction == components[index].direction}


def edge_touches_median(components, edge):
    neighbors = []
    if edge > 0:
        neighbors.append(components[edge - 1])
    if edge < len(components):
        neighbors.append(components[edge])
    return any(component.kind == "Median" for component in neighbors)


def transition_plan(start_lanes, end_lanes):
    start, end = match_for_transition(
        highway_components(start_lanes), highway_components(end_lanes))
    start_groups, end_groups = {}, {}
    for edge in traffic_left_edges(start):
        start_groups.setdefault(edge.direction, []).append(edge)
    for edge in traffic_left_edges(end):
        end_groups.setdefault(edge.direction, []).append(edge)
    lines = []
    for direction, start_edges in start_groups.items():
        destination = end_groups.get(direction, [])
        for ordinal, start_edge in enumerate(start_edges):
            if ordinal >= len(destination):
                continue
            end_edge = destination[ordinal]
            lines.append(TransitionLine(
                direction, start_edge.edge, end_edge.edge,
                start_edge.x, end_edge.x, US_YELLOW))
    return start, end, lines


def transition_faults(start, end, lines):
    faults = []
    destination_dividers = same_direction_edges(end)
    expected_directions = {-1, 1}
    if {line.direction for line in lines} != expected_directions or len(lines) != 2:
        faults.append("transition does not retain one yellow edge per traffic direction")
    for line in lines:
        if line.colour != US_YELLOW:
            faults.append(f"direction {line.direction:+d} transition edge is not yellow")
        if not edge_touches_median(end, line.end_edge):
            faults.append(f"direction {line.direction:+d} does not end at the median edge")
        if line.end_edge in destination_dividers:
            faults.append(f"direction {line.direction:+d} yellow maps to a lane divider")
        destination = [edge for edge in traffic_left_edges(end)
                       if edge.direction == line.direction]
        if not destination or line.end_edge != destination[0].edge:
            faults.append(f"direction {line.direction:+d} maps to the wrong semantic edge")
    return faults


def apply_local_no_line(lines, direction, start, end):
    """Splice a local NoLine span into one traffic-left edge."""
    result = []
    for line in lines:
        if line.direction != direction:
            result.append(line)
            continue
        if line.from_station < start:
            result.append(replace(line, to_station=start))
        if line.to_station > end:
            result.append(replace(line, from_station=end))
    return result


def local_no_line_faults(lines, direction=1, start=0.35, end=0.65):
    faults = []
    target = sorted((line.from_station, line.to_station) for line in lines
                    if line.direction == direction)
    other = sorted((line.from_station, line.to_station) for line in lines
                   if line.direction == -direction)
    if target != [(0.0, start), (end, 1.0)]:
        faults.append("local NoLine does not cut and resume the selected yellow edge")
    if other != [(0.0, 1.0)]:
        faults.append("local NoLine altered the opposite carriageway edge")
    if any(line.colour != US_YELLOW for line in lines):
        faults.append("local NoLine changed the surviving edge colour")
    return faults


def semantic_faults(us=US, uk=UK):
    faults = []
    us_undivided = undivided_plan(us)
    uk_undivided = undivided_plan(uk)
    us_divided = divided_plan(us)
    uk_divided = divided_plan(uk)
    us_one_way = one_way_highway_plan(us)
    uk_one_way = one_way_highway_plan(uk)

    us_centres = [line for line in us_undivided if line.role == "opposing centre"]
    if len(us_centres) != 1 or us_centres[0].colour != US_YELLOW:
        faults.append("US opposing-flow centre is not yellow")
    if any(line.colour != WHITE for line in us_undivided
           if line.role == "same-direction lane"):
        faults.append("US same-direction separator is not white")

    faults.extend(divided_faults(us, us_divided))
    faults.extend(divided_faults(uk, uk_divided))
    if any(line.colour != WHITE for line in uk_undivided + uk_divided):
        faults.append("UK ordinary-road markings no longer remain white")
    faults.extend(one_way_faults(us, us_one_way))
    faults.extend(one_way_faults(uk, uk_one_way))

    for start_lanes, end_lanes in ((2, 3), (3, 2)):
        start, end, lines = transition_plan(start_lanes, end_lanes)
        faults.extend(transition_faults(start, end, lines))

    no_line_base = [
        StationLine(-1, US_YELLOW, 0.0, 1.0),
        StationLine(1, US_YELLOW, 0.0, 1.0),
    ]
    no_line = apply_local_no_line(no_line_base, 1, 0.35, 0.65)
    faults.extend(local_no_line_faults(no_line))
    return faults


def check():
    faults = semantic_faults()
    if faults:
        raise AssertionError("; ".join(faults))

    # Prove each colour assertion observes its intended failure mode.
    break_cases = (
        replace(US, centre=WHITE),
        replace(US, lane=US_YELLOW),
        replace(US, edge=US_YELLOW, traffic_left_edge=WHITE),
    )
    for broken in break_cases:
        if not semantic_faults(us=broken):
            raise AssertionError(f"break-test escaped for {broken}")
    if not semantic_faults(uk=replace(UK, lane=US_YELLOW)):
        raise AssertionError("UK yellow-leak break-test escaped")
    duplicate = one_way_highway_plan(US) + [
        Marking("inner shoulder outer edge", -2.5, US_YELLOW, "solid", 1)
    ]
    if not one_way_faults(US, duplicate):
        raise AssertionError("one-way shoulder-duplicate break-test escaped")
    for start_lanes, end_lanes in ((2, 3), (3, 2)):
        start, end, lines = transition_plan(start_lanes, end_lanes)
        divider = next(iter(same_direction_edges(end)))
        broken = list(lines)
        broken[0] = replace(broken[0], end_edge=divider,
                            end_x=component_boundaries(end)[divider])
        if not transition_faults(start, end, broken):
            raise AssertionError(
                f"{start_lanes}x{start_lanes}->{end_lanes}x{end_lanes} transition break-test escaped")
    unsuppressed = [
        StationLine(-1, US_YELLOW, 0.0, 1.0),
        StationLine(1, US_YELLOW, 0.0, 1.0),
    ]
    if not local_no_line_faults(unsuppressed):
        raise AssertionError("local NoLine break-test escaped")
    invented_uk_median = divided_plan(UK) + [
        Marking("median-side edge", -0.2, WHITE, "solid", 1),
        Marking("median-side edge", 0.2, WHITE, "solid", -1),
    ]
    if not divided_faults(UK, invented_uk_median):
        raise AssertionError("UK median NoLine break-test escaped")
    return 9


def box(canvas, left, top, right, bottom, colour):
    canvas.fill_poly([(left, top), (right, top), (right, bottom), (left, bottom)], colour)


def dashed_vertical(canvas, x, top, bottom, colour, width=3, dash=18, gap=18):
    y = top
    while y < bottom:
        canvas.line((x, y), (x, min(y + dash, bottom)), colour, width)
        y += dash + gap


def dashed_line(canvas, start, end, colour, width=3, dash=18, gap=18):
    dx, dy = end[0] - start[0], end[1] - start[1]
    length = (dx * dx + dy * dy) ** 0.5
    cursor = 0.0
    while cursor < length:
        finish = min(cursor + dash, length)
        a = (start[0] + dx * cursor / length,
             start[1] + dy * cursor / length)
        b = (start[0] + dx * finish / length,
             start[1] + dy * finish / length)
        canvas.line(a, b, colour, width)
        cursor += dash + gap


def draw_marking(canvas, line, map_x, top, bottom):
    x = map_x(line.x)
    if line.pattern == "solid":
        canvas.line((x, top), (x, bottom), line.colour, 4)
    elif line.pattern == "double":
        canvas.line((x - 4, top), (x - 4, bottom), line.colour, 3)
        canvas.line((x + 4, top), (x + 4, bottom), line.colour, 3)
    else:
        dashed_vertical(canvas, x, top, bottom, line.colour)


def arrow(canvas, x, y, direction):
    tip_y = y - 20 * direction
    tail_y = y + 18 * direction
    canvas.line((x, tail_y), (x, tip_y), ARROW, 4)
    canvas.line((x, tip_y), (x - 8, tip_y + 10 * direction), ARROW, 4)
    canvas.line((x, tip_y), (x + 8, tip_y + 10 * direction), ARROW, 4)


def flag_us(canvas, x, y):
    box(canvas, x, y, x + 54, y + 32, WHITE)
    for stripe in range(0, 7, 2):
        box(canvas, x, y + stripe * 4, x + 54, y + (stripe + 1) * 4, (190, 48, 55))
    box(canvas, x, y, x + 23, y + 17, (45, 70, 120))


def flag_uk(canvas, x, y):
    box(canvas, x, y, x + 54, y + 32, (42, 62, 112))
    canvas.line((x, y), (x + 54, y + 32), WHITE, 7)
    canvas.line((x + 54, y), (x, y + 32), WHITE, 7)
    canvas.line((x + 27, y), (x + 27, y + 32), WHITE, 10)
    canvas.line((x, y + 16), (x + 54, y + 16), WHITE, 10)
    canvas.line((x + 27, y), (x + 27, y + 32), (190, 48, 55), 5)
    canvas.line((x, y + 16), (x + 54, y + 16), (190, 48, 55), 5)


def draw_undivided(canvas, region, left, top, width, height):
    road_left = left + width * 0.23
    road_right = left + width * 0.77
    road_top, road_bottom = top + 8, top + height - 8
    box(canvas, road_left - 8, road_top, road_right + 8, road_bottom, SHOULDER)
    box(canvas, road_left, road_top, road_right, road_bottom, ASPHALT)
    map_x = lambda x: (road_left + road_right) / 2 + x * (road_right - road_left) / 4
    for line in undivided_plan(region):
        draw_marking(canvas, line, map_x, road_top, road_bottom)
    centres = (-1.5, -0.5, 0.5, 1.5)
    directions = (-1, -1, 1, 1)
    for lane, direction in zip(centres, directions):
        arrow(canvas, map_x(lane), top + height / 2, direction)


def draw_divided(canvas, region, left, top, width, height):
    road_left = left + width * 0.20
    road_right = left + width * 0.80
    road_top, road_bottom = top + 8, top + height - 8
    map_x = lambda x: (road_left + road_right) / 2 + x * (road_right - road_left) / 4.4
    for run_left, run_right in ((-2.2, -0.2), (0.2, 2.2)):
        a, b = map_x(run_left), map_x(run_right)
        box(canvas, a - 8, road_top, b + 8, road_bottom, SHOULDER)
        box(canvas, a, road_top, b, road_bottom, ASPHALT)
    box(canvas, map_x(-0.2), road_top, map_x(0.2), road_bottom, MEDIAN)
    for line in divided_plan(region):
        draw_marking(canvas, line, map_x, road_top, road_bottom)

    forward_left = region.drive_on_left
    runs = ((-1.7, -0.7, 1 if forward_left else -1),
            (0.7, 1.7, -1 if forward_left else 1))
    for lane_a, lane_b, direction in runs:
        for lane in (lane_a, lane_b):
            arrow(canvas, map_x(lane), top + height / 2, direction)


def draw_one_way_highway(canvas, region, left, top, width, height):
    road_left = left + width * 0.18
    road_right = left + width * 0.82
    road_top, road_bottom = top + 8, top + height - 8
    map_x = lambda x: (road_left + road_right) / 2 + x * (road_right - road_left) / 5
    box(canvas, road_left - 22, road_top, map_x(-2.5), road_bottom, MEDIAN)
    box(canvas, map_x(-2.5), road_top, map_x(-1.5), road_bottom, SHOULDER)
    box(canvas, map_x(-1.5), road_top, map_x(1.5), road_bottom, ASPHALT)
    box(canvas, map_x(1.5), road_top, map_x(2.5), road_bottom, SHOULDER)
    for line in one_way_highway_plan(region):
        draw_marking(canvas, line, map_x, road_top, road_bottom)
    for lane in (-1.0, 0.0, 1.0):
        arrow(canvas, map_x(lane), top + height / 2, 1)


def draw_transition(canvas, region, left, top, width, height):
    """Idealised 2x2-to-3x3 widening with semantic median-edge ownership."""
    center = left + width / 2
    road_top, road_bottom = top + 8, top + height - 8
    median_half = 12
    lane_width = min(42, width * 0.075)
    shoulder_width = 18
    two_lane_edge = 2 * lane_width
    three_lane_edge = 3 * lane_width

    left_inner, right_inner = center - median_half, center + median_half
    left_drive_top = left_inner - two_lane_edge
    left_drive_bottom = left_inner - three_lane_edge
    right_drive_top = right_inner + two_lane_edge
    right_drive_bottom = right_inner + three_lane_edge

    canvas.fill_poly([
        (left_drive_top - shoulder_width, road_top),
        (left_drive_top, road_top),
        (left_drive_bottom, road_bottom),
        (left_drive_bottom - shoulder_width, road_bottom),
    ], SHOULDER)
    canvas.fill_poly([
        (left_drive_top, road_top), (left_inner, road_top),
        (left_inner, road_bottom), (left_drive_bottom, road_bottom),
    ], ASPHALT)
    canvas.fill_poly([
        (right_inner, road_top), (right_drive_top, road_top),
        (right_drive_bottom, road_bottom), (right_inner, road_bottom),
    ], ASPHALT)
    canvas.fill_poly([
        (right_drive_top, road_top),
        (right_drive_top + shoulder_width, road_top),
        (right_drive_bottom + shoulder_width, road_bottom),
        (right_drive_bottom, road_bottom),
    ], SHOULDER)
    box(canvas, left_inner, road_top, right_inner, road_bottom, MEDIAN)

    # The Drive/outer-shoulder boundaries stay white.
    canvas.line((left_drive_top, road_top),
                (left_drive_bottom, road_bottom), WHITE, 4)
    canvas.line((right_drive_top, road_top),
                (right_drive_bottom, road_bottom), WHITE, 4)

    # Existing divider remains; the new divider grows out of the old shoulder
    # boundary. Neither may inherit the US yellow median-edge identity.
    dashed_line(canvas,
                (left_inner - lane_width, road_top),
                (left_inner - lane_width, road_bottom), WHITE)
    dashed_line(canvas,
                (right_inner + lane_width, road_top),
                (right_inner + lane_width, road_bottom), WHITE)
    dashed_line(canvas,
                (left_drive_top, road_top),
                (left_inner - 2 * lane_width, road_bottom), WHITE)
    dashed_line(canvas,
                (right_drive_top, road_top),
                (right_inner + 2 * lane_width, road_bottom), WHITE)

    if region.traffic_left_edge is not None:
        canvas.line((left_inner, road_top),
                    (left_inner, road_bottom), US_YELLOW, 4)
        # Explicit local NoLine stretch on the +1 carriageway: the mandatory
        # yellow line resumes after the selected span.
        gap_start = road_top + (road_bottom - road_top) * 0.38
        gap_end = road_top + (road_bottom - road_top) * 0.64
        canvas.line((right_inner, road_top),
                    (right_inner, gap_start), US_YELLOW, 4)
        canvas.line((right_inner, gap_end),
                    (right_inner, road_bottom), US_YELLOW, 4)


def render(path):
    check()
    width, height = 1180, 1440
    canvas = Canvas(width, height, BACKGROUND)
    margin, gap = 40, 28
    panel_width = (width - margin * 2 - gap) / 2
    header_height = 52
    panel_height = (height - margin * 2 - header_height - gap * 3) / 4

    flag_us(canvas, margin + 12, margin + 10)
    flag_uk(canvas, margin + panel_width + gap + 12, margin + 10)
    for column, region in enumerate((US, UK)):
        left = margin + column * (panel_width + gap)
        top_a = margin + header_height
        top_b = top_a + panel_height + gap
        top_c = top_b + panel_height + gap
        top_d = top_c + panel_height + gap
        box(canvas, left, top_a, left + panel_width, top_a + panel_height, PANEL)
        box(canvas, left, top_b, left + panel_width, top_b + panel_height, PANEL)
        box(canvas, left, top_c, left + panel_width, top_c + panel_height, PANEL)
        box(canvas, left, top_d, left + panel_width, top_d + panel_height, PANEL)
        draw_undivided(canvas, region, left, top_a, panel_width, panel_height)
        draw_divided(canvas, region, left, top_b, panel_width, panel_height)
        draw_one_way_highway(canvas, region, left, top_c, panel_width, panel_height)
        draw_transition(canvas, region, left, top_d, panel_width, panel_height)

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    canvas.save(path)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="semantic and injected break-tests only; do not render")
    parser.add_argument("--out", default=os.path.join(
        os.path.dirname(__file__), "out", "regional-marking-colours.png"))
    args = parser.parse_args()
    break_tests = check()
    print(f"regional marking colours passed; {break_tests} injected break-tests caught")
    if not args.check:
        print(f"wrote {render(args.out)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
