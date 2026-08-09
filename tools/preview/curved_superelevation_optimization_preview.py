#!/usr/bin/env python3
"""QA model for curved-road and superelevation-runoff surface coalescing.

This is a stdlib-only planning/validation model, not a Luau runtime. It ports
the current curve-station and constant-curvature runoff rules, then tests the
proposed conservative optimization: merge contiguous compatible Drive
components laterally while retaining every raw component boundary for markings
and metadata. Each interval greedily admits only the width whose triangulation
stays within ``MAX_BANKED_BAND_WARP_STUDS`` of the per-component surface.

    python curved_superelevation_optimization_preview.py --check
    python curved_superelevation_optimization_preview.py --out out/curved-bank.png
"""

import argparse
import math
import os
import re
from dataclasses import dataclass
from pathlib import Path

from raster import Canvas


ROOT = Path(__file__).resolve().parents[2]
SCALE = 3.571
MAX_SEGMENT_LENGTH = 8.0
CHORD_TOLERANCE = 0.05
MIN_STEP = 0.4
MAX_TURN_PER_STEP = 0.2
MAX_ROLL_PER_STEP = 0.02
MAX_ROLL_INTERPOLATION_ERROR = 0.0015
ROLL_WEDGE_EPSILON = 1e-4
MAX_BANKED_BAND_WARP_STUDS = 0.025
MAX_CURVED_BAND_OVERHANG_STUDS = 0.025
PROFILE_MAX_SPACING_M = 2.0
PROFILE_MIN_SPACING_M = 0.25
PROFILE_LINEARITY_TOLERANCE_RAD = math.radians(0.05)
PROFILE_MAX_REFINEMENT_DEPTH = 4
EPSILON = 1e-9


@dataclass(frozen=True)
class Component:
    kind: str
    width: float
    material: str
    colour: str
    height: float = 0.0
    collidable: bool = True
    excluded: bool = False


@dataclass(frozen=True)
class Band:
    start: int
    end: int
    left: float
    right: float
    kind: str

    @property
    def width(self):
        return self.right - self.left


@dataclass(frozen=True)
class RollProfile:
    length: float
    stations: tuple
    rolls: tuple


class ArcRoad:
    """Exact circular centreline, parameterised by arc length in studs."""

    def __init__(self, radius, sweep_deg):
        self.radius = float(radius)
        self.sweep = math.radians(float(sweep_deg))
        self.length = abs(self.radius * self.sweep)
        self.turn_sign = 1.0 if self.sweep >= 0 else -1.0

    def angle(self, station):
        return self.turn_sign * station / self.radius

    def plan_position(self, station):
        theta = self.angle(station)
        sign = self.turn_sign
        return self.radius * math.sin(theta), sign * self.radius * (1 - math.cos(theta))

    def right(self, station):
        theta = self.angle(station)
        tangent = self.forward(station)
        return -tangent[1], tangent[0]

    def forward(self, station):
        theta = self.angle(station)
        return math.cos(theta), self.turn_sign * math.sin(theta)

    def curvature(self, _station):
        return self.turn_sign / self.radius

    def point(self, station, lateral, roll):
        center = self.plan_position(station)
        right = self.right(station)
        horizontal = lateral * math.cos(roll)
        return (
            center[0] + right[0] * horizontal,
            center[1] + right[1] * horizontal,
            lateral * math.sin(roll),
        )


def linear_value_at(stations, values, station):
    if not stations:
        return 0.0
    if len(stations) == 1 or station <= stations[0]:
        return values[0]
    if station >= stations[-1]:
        return values[-1]
    lo, hi = 0, len(stations) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if stations[mid] <= station:
            lo = mid
        else:
            hi = mid
    span = stations[lo + 1] - stations[lo]
    alpha = 0.0 if span <= EPSILON else (station - stations[lo]) / span
    return values[lo] + (values[lo + 1] - values[lo]) * alpha


def integral_value_at(stations, values, prefix_areas, station):
    if len(stations) <= 1 or station <= stations[0]:
        return 0.0
    if station >= stations[-1]:
        return prefix_areas[-1]
    lo, hi = 0, len(stations) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if stations[mid] <= station:
            lo = mid
        else:
            hi = mid
    span = stations[lo + 1] - stations[lo]
    if span <= EPSILON:
        return prefix_areas[lo]
    distance = station - stations[lo]
    slope = (values[lo + 1] - values[lo]) / span
    return prefix_areas[lo] + values[lo] * distance + slope * distance * distance / 2.0


def smooth_rolls(rolls, stations, transition_length):
    """Arc-length weighted box filter over a piecewise-linear roll signal."""
    if len(rolls) <= 1 or transition_length <= 0 or len(stations) != len(rolls):
        return list(rolls)
    prefix = [0.0]
    for index in range(len(stations) - 1):
        span = max(stations[index + 1] - stations[index], 0.0)
        prefix.append(prefix[-1] + (rolls[index] + rolls[index + 1]) * span / 2.0)
    half_window = transition_length / 2.0
    smoothed = []
    for center in stations:
        start = max(stations[0], center - half_window)
        finish = min(stations[-1], center + half_window)
        window = finish - start
        if window <= EPSILON:
            smoothed.append(linear_value_at(stations, rolls, center))
        else:
            area = integral_value_at(stations, rolls, prefix, finish) - integral_value_at(
                stations, rolls, prefix, start
            )
            smoothed.append(area / window)
    return smoothed


def append_adaptive_interval(stations, rolls, start, start_roll, finish, finish_roll,
                             minimum_spacing, depth, raw_roll_at):
    span = finish - start
    probes = (0.25, 0.5, 0.75)
    error = max(abs(raw_roll_at(start + span * fraction)
                    - (start_roll + (finish_roll - start_roll) * fraction))
                for fraction in probes)
    if (
        depth < PROFILE_MAX_REFINEMENT_DEPTH
        and span > minimum_spacing * 2.0
        and error > PROFILE_LINEARITY_TOLERANCE_RAD
    ):
        midpoint = (start + finish) / 2.0
        midpoint_roll = raw_roll_at(midpoint)
        append_adaptive_interval(stations, rolls, start, start_roll, midpoint, midpoint_roll,
                                 minimum_spacing, depth + 1, raw_roll_at)
        append_adaptive_interval(stations, rolls, midpoint, midpoint_roll, finish, finish_roll,
                                 minimum_spacing, depth + 1, raw_roll_at)
        return
    stations.append(finish)
    rolls.append(finish_roll)


def build_roll_profile(length, raw_roll_at, runoff_m, meters_to_studs=SCALE, enabled=True):
    """Port of Superelevation.BuildProfile, independent of mesh density."""
    length = max(float(length), 0.0)
    if length <= 1e-6:
        return RollProfile(0.0, (0.0,), (0.0,))
    if not enabled:
        return RollProfile(length, (0.0, length), (0.0, 0.0))
    maximum_spacing = max(PROFILE_MAX_SPACING_M * meters_to_studs, 0.1)
    minimum_spacing = max(PROFILE_MIN_SPACING_M * meters_to_studs, 0.05)
    runoff = min(runoff_m * meters_to_studs, length * 0.3)
    # BuildProfile deliberately injects every endpoint-taper kink plus the
    # midpoint into the canonical grid.  This is essential when the whole road
    # is shorter than the normal 2 m spacing: endpoint-only samples would both
    # be tapered to zero and erase a valid constant-radius bank.
    raw_control_stations = [0.0, runoff, length / 2.0, length - runoff, length]
    station = maximum_spacing
    while station < length:
        raw_control_stations.append(station)
        station += maximum_spacing
    base_stations = unique_sorted(raw_control_stations)

    stations = [base_stations[0]]
    rolls = [raw_roll_at(base_stations[0])]
    start = base_stations[0]
    start_roll = rolls[0]
    for finish in base_stations[1:]:
        finish_roll = raw_roll_at(finish)
        append_adaptive_interval(stations, rolls, start, start_roll, finish, finish_roll,
                                 minimum_spacing, 0, raw_roll_at)
        start, start_roll = finish, finish_roll
    rolls = smooth_rolls(rolls, stations, runoff)
    if runoff > 1e-3:
        rolls = [roll * max(min(1.0, station / runoff, (length - station) / runoff), 0.0)
                 for station, roll in zip(stations, rolls)]
    return RollProfile(length, tuple(stations), tuple(rolls))


def roll_at_profile(profile, station):
    return linear_value_at(profile.stations, profile.rolls,
                           max(0.0, min(profile.length, station)))


def component_offsets(components):
    total = sum(component.width for component in components)
    cursor = -total / 2.0
    offsets = []
    for component in components:
        offsets.append((cursor, cursor + component.width))
        cursor += component.width
    return offsets


def merge_signature(component):
    return (
        component.material,
        component.colour,
        component.height,
        component.collidable,
        component.excluded,
    )


def candidate_bands(components):
    """Merge only adjacent, non-excluded Drive surfaces with one signature."""
    offsets = component_offsets(components)
    bands = []
    index = 0
    while index < len(components):
        component = components[index]
        end = index
        if component.kind == "Drive" and not component.excluded:
            signature = merge_signature(component)
            while end + 1 < len(components):
                following = components[end + 1]
                if (
                    following.kind != "Drive"
                    or following.excluded
                    or merge_signature(following) != signature
                ):
                    break
                end += 1
        bands.append(Band(index, end, offsets[index][0], offsets[end][1], component.kind))
        index = end + 1
    return bands


def raw_bands(components):
    offsets = component_offsets(components)
    return [Band(i, i, left, right, component.kind)
            for i, (component, (left, right)) in enumerate(zip(components, offsets))]


def unique_sorted(values):
    result = []
    for value in sorted(values):
        if not result or abs(value - result[-1]) > 1e-7:
            result.append(value)
    return result


def base_stations(road, max_offset):
    stations = [0.0]
    station = 0.0
    while station < road.length - EPSILON:
        curvature = abs(road.curvature(station))
        step = MAX_SEGMENT_LENGTH
        if curvature > 1e-6:
            effective = curvature / max(0.05, 1.0 - max_offset * curvature)
            step = min(step, math.sqrt(8.0 * CHORD_TOLERANCE / effective))
            step = min(step, MAX_TURN_PER_STEP / effective)
        step = max(step, MIN_STEP)
        station = min(station + step, road.length)
        stations.append(station)
    return unique_sorted(stations)


def refine_stations_for_roll(base, profile, max_offset, tolerance=CHORD_TOLERANCE,
                             profile_offset=0.0):
    """Port of RoadBuilder.refineStationsForRoll."""
    roll_at = lambda station: roll_at_profile(profile, station + profile_offset)
    stations = [base[0]]
    rolls = [roll_at(base[0])]

    def visit(start, start_roll, finish, finish_roll, depth):
        span = finish - start
        interpolation_error = 0.0
        vertical_error = 0.0
        for fraction in (0.25, 0.5, 0.75):
            sample = start + span * fraction
            actual = roll_at(sample)
            linear = start_roll + (finish_roll - start_roll) * fraction
            interpolation_error = max(interpolation_error, abs(actual - linear))
            vertical_error = max(vertical_error, max_offset * abs(math.sin(actual) - math.sin(linear)))
        accepted = (
            abs(finish_roll - start_roll) <= MAX_ROLL_PER_STEP
            and interpolation_error <= MAX_ROLL_INTERPOLATION_ERROR
            and vertical_error <= tolerance
        )
        if accepted or span <= MIN_STEP or depth >= 12:
            stations.append(finish)
            rolls.append(finish_roll)
            return
        midpoint = (start + finish) / 2.0
        midpoint_roll = roll_at(midpoint)
        visit(start, start_roll, midpoint, midpoint_roll, depth + 1)
        visit(midpoint, midpoint_roll, finish, finish_roll, depth + 1)

    for start, finish in zip(base, base[1:]):
        visit(start, roll_at(start), finish, roll_at(finish), 0)
    return unique_sorted(stations), [roll_at(station) for station in unique_sorted(stations)]


def band_warp(width, start_roll, finish_roll):
    return width * abs(math.sin(finish_roll) - math.sin(start_roll)) / 4.0


def curve_miter_pad(road, station, edge_distance, nominal_length):
    return abs(edge_distance) * abs(road.curvature(station)) * nominal_length


def band_plan_overhang(road, components, band, start, finish):
    """Actual plan-box half-length added over the shortest source box."""
    if band.start == band.end:
        return 0.0
    offsets = component_offsets(components)
    candidate_box = midpoint_box_plan_polygon(road, band, start, finish, 0.0)
    candidate_half_length = plan_box_half_length(road, candidate_box, start, finish)
    source_half_lengths = []
    for index in range(band.start, band.end + 1):
        left, right = offsets[index]
        source = Band(index, index, left, right, components[index].kind)
        source_box = midpoint_box_plan_polygon(road, source, start, finish, 0.0)
        source_half_lengths.append(plan_box_half_length(road, source_box, start, finish))
    return max(0.0, candidate_half_length - min(source_half_lengths))


def midpoint_box_plan_polygon(road, band, start, finish, roll):
    """Plan projection of the actual constant-roll Part emitted by RoadBuilder."""
    midpoint = (start + finish) / 2.0
    nominal = finish - start
    forward = road.forward(midpoint)
    right = road.right(midpoint)
    centerline = road.plan_position(midpoint)
    center_offset = (band.left + band.right) / 2.0
    center = (
        centerline[0] + right[0] * center_offset * math.cos(roll),
        centerline[1] + right[1] * center_offset * math.cos(roll),
    )
    edge_distance = max(abs(band.left), abs(band.right))
    padding = curve_miter_pad(road, midpoint, edge_distance, nominal) + 0.08
    half_length = (nominal + padding) / 2.0
    half_width = band.width * math.cos(roll) / 2.0
    return [
        (center[0] - forward[0] * half_length - right[0] * half_width,
         center[1] - forward[1] * half_length - right[1] * half_width),
        (center[0] - forward[0] * half_length + right[0] * half_width,
         center[1] - forward[1] * half_length + right[1] * half_width),
        (center[0] + forward[0] * half_length + right[0] * half_width,
         center[1] + forward[1] * half_length + right[1] * half_width),
        (center[0] + forward[0] * half_length - right[0] * half_width,
         center[1] + forward[1] * half_length - right[1] * half_width),
    ]


def plan_box_half_length(road, polygon, start, finish):
    midpoint = (start + finish) / 2.0
    center = road.plan_position(midpoint)
    forward = road.forward(midpoint)
    projections = [
        (point[0] - center[0]) * forward[0] + (point[1] - center[1]) * forward[1]
        for point in polygon
    ]
    return (max(projections) - min(projections)) / 2.0


def interval_bands(components, road, start, finish, start_roll, finish_roll):
    """Port of RoadBuilder's per-interval greedy compatible-width rule."""
    offsets = component_offsets(components)
    compatible = candidate_bands(components)
    compatible_end = {}
    for band in compatible:
        for index in range(band.start, band.end + 1):
            compatible_end[index] = band.end
    sin_delta = abs(math.sin(finish_roll) - math.sin(start_roll))
    max_width = math.inf if sin_delta <= EPSILON else 4.0 * MAX_BANKED_BAND_WARP_STUDS / sin_delta
    roll_delta = abs(finish_roll - start_roll)
    midpoint = (start + finish) / 2.0
    nominal = finish - start
    result = []
    index = 0
    while index < len(components):
        end = index
        limit = compatible_end.get(index, index)
        width = components[index].width
        source_left, source_right = offsets[index]
        minimum_source_miter = curve_miter_pad(
            road, midpoint, max(abs(source_left), abs(source_right)), nominal
        )
        while end < limit:
            next_width = components[end + 1].width
            if width + next_width > max_width:
                break
            next_left, next_right = offsets[end + 1]
            next_source_miter = curve_miter_pad(
                road, midpoint, max(abs(next_left), abs(next_right)), nominal
            )
            candidate_left = offsets[index][0]
            candidate_right = next_right
            candidate_miter = curve_miter_pad(
                road, midpoint, max(abs(candidate_left), abs(candidate_right)), nominal
            )
            candidate_minimum = min(minimum_source_miter, next_source_miter)
            if (
                roll_delta <= ROLL_WEDGE_EPSILON
                and (candidate_miter - candidate_minimum) / 2.0
                > MAX_CURVED_BAND_OVERHANG_STUDS
            ):
                break
            width += next_width
            minimum_source_miter = candidate_minimum
            end += 1
        result.append(Band(index, end, offsets[index][0], offsets[end][1], components[index].kind))
        index = end + 1
    return result


def subtract(a, b):
    return a[0] - b[0], a[1] - b[1], a[2] - b[2]


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def magnitude(vector):
    return math.sqrt(dot(vector, vector))


def fill_triangle_part_count(a, b, c):
    """Count the 1-2 Wedges emitted by FillTriangle for one top triangle."""
    ab, bc, ca = subtract(b, a), subtract(c, b), subtract(a, c)
    lengths = [magnitude(ab), magnitude(bc), magnitude(ca)]
    if min(lengths) < 1e-4:
        return 0
    candidates = [
        (abs(0.5 + dot(ca, ab) / (lengths[0] ** 2)), a, b, c),
        (abs(0.5 + dot(ab, bc) / (lengths[1] ** 2)), b, c, a),
        (abs(0.5 + dot(bc, ca) / (lengths[2] ** 2)), c, a, b),
    ]
    _score, first, second, third = min(candidates, key=lambda item: item[0])
    edge = subtract(second, first)
    opposite = subtract(first, third)
    edge_length = magnitude(edge)
    len1 = -dot(opposite, edge) / edge_length
    len2 = edge_length - len1
    return int(len1 > 0.001) + int(len2 > 0.001)


def quad_part_count(road, band, start, finish, roll_at):
    start_roll, finish_roll = roll_at(start), roll_at(finish)
    if abs(finish_roll - start_roll) <= ROLL_WEDGE_EPSILON:
        return 1
    a = road.point(start, band.left, start_roll)
    b = road.point(start, band.right, start_roll)
    c = road.point(finish, band.right, finish_roll)
    d = road.point(finish, band.left, finish_roll)
    return fill_triangle_part_count(a, b, c) + fill_triangle_part_count(a, c, d)


def surface_part_count(road, bands, stations, roll_at):
    return sum(
        quad_part_count(road, band, start, finish, roll_at)
        for start, finish in zip(stations, stations[1:])
        for band in bands
    )


def interval_surface_part_count(road, interval_band_plan, stations, roll_at):
    return sum(
        quad_part_count(road, band, start, finish, roll_at)
        for (start, finish, bands) in zip(stations, stations[1:], interval_band_plan)
        for band in bands
    )


def max_edge_error(road, raw, interval_band_plan, stations, roll_at):
    """Merged-band outer station edges must be bit-for-bit source edges."""
    worst = 0.0
    raw_by_index = {band.start: band for band in raw}
    for interval_index, bands in enumerate(interval_band_plan):
        for band in bands:
            left_source = raw_by_index[band.start]
            right_source = raw_by_index[band.end]
            for station in (stations[interval_index], stations[interval_index + 1]):
                roll = roll_at(station)
                pairs = (
                    (road.point(station, band.left, roll), road.point(station, left_source.left, roll)),
                    (road.point(station, band.right, roll), road.point(station, right_source.right, roll)),
                )
                for actual, expected in pairs:
                    worst = max(worst, magnitude(subtract(actual, expected)))
    return worst


def boulevard_components():
    asphalt = ("Asphalt", "#3C3C3C")
    return [
        Component("Sidewalk", 2.0 * SCALE, "Concrete", "#A8A8A8", 0.45),
        Component("Drive", 3.65 * SCALE, *asphalt),
        Component("Drive", 3.65 * SCALE, *asphalt),
        Component("Drive", 3.65 * SCALE, *asphalt),
        Component("Median", 2.7 * SCALE, "Grass", "#788270", 0.45),
        Component("Drive", 3.65 * SCALE, *asphalt),
        Component("Drive", 3.65 * SCALE, *asphalt),
        Component("Drive", 3.65 * SCALE, *asphalt),
        Component("Sidewalk", 2.0 * SCALE, "Concrete", "#A8A8A8", 0.45),
    ]


def build_case(tag, road, components, profile):
    offsets = component_offsets(components)
    max_offset = max(abs(offsets[0][0]), abs(offsets[-1][1]))
    roll_at = lambda station: roll_at_profile(profile, station)
    stations, rolls = refine_stations_for_roll(base_stations(road, max_offset), profile, max_offset)
    raw = raw_bands(components)
    interval_plan = [interval_bands(components, road, start, finish, start_roll, finish_roll)
                     for start, finish, start_roll, finish_roll
                     in zip(stations, stations[1:], rolls, rolls[1:])]
    baseline_parts = surface_part_count(road, raw, stations, roll_at)
    optimized_parts = interval_surface_part_count(road, interval_plan, stations, roll_at)
    twist = max((band_warp(band.width, rolls[index], rolls[index + 1])
                 for index, bands in enumerate(interval_plan)
                 for band in bands if band.end > band.start), default=0.0)
    overhang = max((band_plan_overhang(road, components, band, stations[index], stations[index + 1])
                    for index, bands in enumerate(interval_plan)
                    for band in bands
                    if band.end > band.start and abs(rolls[index + 1] - rolls[index]) <= ROLL_WEDGE_EPSILON),
                   default=0.0)
    edge = max_edge_error(road, raw, interval_plan, stations, roll_at)
    return {
        "tag": tag,
        "road": road,
        "components": components,
        "offsets": offsets,
        "profile": profile,
        "roll_at": roll_at,
        "rolls": rolls,
        "baseline_stations": stations,
        "optimized_stations": stations,
        "raw_bands": raw,
        "interval_bands": interval_plan,
        "baseline_parts": baseline_parts,
        "optimized_parts": optimized_parts,
        "max_twist_error": twist,
        "max_plan_overhang": overhang,
        "max_edge_error": edge,
    }


def parity_contracts():
    source = (ROOT / "src" / "Mesh" / "RoadBuilder.lua").read_text(encoding="utf-8")
    superelevation = (ROOT / "src" / "Geometry" / "Superelevation.lua").read_text(encoding="utf-8")
    expected = {
        "CHORD_TOLERANCE": CHORD_TOLERANCE,
        "MIN_STEP": MIN_STEP,
        "MAX_TURN_PER_STEP": MAX_TURN_PER_STEP,
        "MAX_ROLL_PER_STEP": MAX_ROLL_PER_STEP,
        "MAX_ROLL_INTERPOLATION_ERROR": MAX_ROLL_INTERPOLATION_ERROR,
        "MAX_BANKED_BAND_WARP_STUDS": MAX_BANKED_BAND_WARP_STUDS,
        "MAX_CURVED_BAND_OVERHANG_STUDS": MAX_CURVED_BAND_OVERHANG_STUDS,
        "ROLL_WEDGE_EPSILON": ROLL_WEDGE_EPSILON,
    }
    for name, value in expected.items():
        match = re.search(rf"local\s+{name}\s*=\s*([0-9.eE+-]+)", source)
        assert match, f"missing RoadBuilder constant {name}"
        assert abs(float(match.group(1)) - value) <= EPSILON, (name, match.group(1), value)
    assert "FillTriangle(innerStart, outerStart, outerEnd" in source
    assert "FillTriangle(innerStart, outerEnd, innerEnd" in source
    assert "4 * MAX_BANKED_BAND_WARP_STUDS / sinDelta" in source
    assert "(candidateMiter - candidateMinimumMiter) / 2 > MAX_CURVED_BAND_OVERHANG_STUDS" in source
    assert "Superelevation.BuildProfile" in source
    assert "local PROFILE_MAX_SPACING_M = 2" in superelevation
    assert "local PROFILE_MIN_SPACING_M = 0.25" in superelevation
    assert "local PROFILE_LINEARITY_TOLERANCE_RAD = math.rad(0.05)" in superelevation
    assert "local PROFILE_MAX_REFINEMENT_DEPTH = 4" in superelevation
    assert "prefixAreas[i + 1]" in superelevation
    assert "local rawControlStations = { 0, runoffLength, length / 2, length - runoffLength, length }" in superelevation
    assert "for _, fraction in { 0.25, 0.5, 0.75 }" in source
    # Bay slices reuse the authored road's one bank profile and offset local
    # slice stations into it; moving-offset overlays retain the legacy emitter.
    assert source.count("SuperelevationProfile = fullRollProfile") == 3
    assert "SuperelevationStationOffsetStuds = 0" in source
    assert "SuperelevationStationOffsetStuds = taperInStart" in source
    assert "SuperelevationStationOffsetStuds = taperOutEnd" in source
    assert source.count("DisableSurfaceCoalescing = true") >= 3


def semantic_break_tests(banked_case):
    components = banked_case["components"]

    # Quarter probes must catch a raw-roll hump whose interval endpoints match.
    spacing = PROFILE_MAX_SPACING_M * SCALE
    raw_hump = lambda station: math.radians(5.0) * math.sin(math.pi * station / spacing)
    hump_profile = build_roll_profile(spacing, raw_hump, 0.0)
    assert len(hump_profile.stations) > 2, "adaptive raw-roll quarter probes missed a hump"
    hump_stations, _ = refine_stations_for_roll([0.0, spacing], hump_profile, 40.0)
    assert len(hump_stations) > 2, "mesh quarter probes missed canonical roll curvature"

    # Arc-length integration must be invariant to inserting collinear samples.
    sparse = smooth_rolls([0.0, 1.0, 0.0], [0.0, 10.0, 20.0], 8.0)
    dense = smooth_rolls([0.0, 0.5, 1.0, 0.5, 0.0], [0.0, 5.0, 10.0, 15.0, 20.0], 8.0)
    assert max(abs(a - b) for a, b in zip(sparse, (dense[0], dense[2], dense[4]))) <= 1e-9

    # The endpoint runoff is the Luau contract's linear 30%-capped taper.
    full_roll = math.radians(6.0)
    constant = build_roll_profile(200.0, lambda _station: full_roll, 10.0)
    probe = constant.stations[1]
    runoff = min(10.0 * SCALE, 200.0 * 0.3)
    assert abs(roll_at_profile(constant, probe) - full_roll * probe / runoff) <= 1e-9

    # A constant-radius road shorter than the normal 2 m profile spacing still
    # needs a deterministic full-bank middle. Endpoints are zero by runoff,
    # while the injected runoff/mid/full-bank controls preserve the interior.
    short_length = spacing * 0.6
    short_runoff = short_length * 0.3
    short_profile = build_roll_profile(
        short_length,
        lambda _station: full_roll,
        runoff_m=short_runoff / SCALE,
    )
    expected_controls = (0.0, short_runoff, short_length / 2.0,
                         short_length - short_runoff, short_length)
    assert all(any(abs(station - expected) <= EPSILON for station in short_profile.stations)
               for expected in expected_controls)
    assert abs(short_profile.rolls[0]) <= EPSILON
    assert abs(short_profile.rolls[-1]) <= EPSILON
    assert roll_at_profile(short_profile, short_length / 2.0) >= full_roll * 0.99

    # Per-interval greedy planning may safely merge two lanes but not the third.
    lane = components[1].width
    sin_delta = 4.0 * MAX_BANKED_BAND_WARP_STUDS / (lane * 2.5)
    partial = interval_bands(components, banked_case["road"], 0.0, 2.0, 0.0, math.asin(sin_delta))
    drive_ranges = [(band.start, band.end) for band in partial if band.kind == "Drive"]
    assert drive_ranges == [(1, 2), (3, 3), (5, 6), (7, 7)], drive_ranges
    unsafe_width = sum(components[index].width for index in range(1, 4))
    assert band_warp(unsafe_width, 0.0, math.asin(sin_delta)) > MAX_BANKED_BAND_WARP_STUDS

    # Constant-roll curves use midpoint boxes. A globally merged three-lane
    # candidate would inherit its farthest edge's miter pad across every lane;
    # the greedy plan must reject it when that extra half-length exceeds 0.025.
    compatible = next(band for band in candidate_bands(components)
                      if band.start == 1 and band.end == 3)
    unsafe_overhang = band_plan_overhang(
        banked_case["road"], components, compatible, 0.0, MAX_SEGMENT_LENGTH
    )
    assert unsafe_overhang > MAX_CURVED_BAND_OVERHANG_STUDS
    guarded = interval_bands(
        components, banked_case["road"], 0.0, MAX_SEGMENT_LENGTH, full_roll, full_roll
    )
    assert not any(band.start == 1 and band.end == 3 for band in guarded)

    # A bay slice samples the full canonical profile at its source offset; it
    # must not acquire a second zero-bank endpoint taper at the slice boundary.
    slice_start, slice_length = 24.0, 20.0
    _slice_stations, slice_rolls = refine_stations_for_roll(
        [0.0, slice_length], banked_case["profile"], 40.0,
        profile_offset=slice_start,
    )
    assert abs(slice_rolls[0] - roll_at_profile(banked_case["profile"], slice_start)) <= EPSILON
    assert abs(slice_rolls[-1] - roll_at_profile(
        banked_case["profile"], slice_start + slice_length
    )) <= EPSILON

    # Broken compatibility: different colour/material/height and exclusions
    # must each stop a lateral merge.
    changed = list(components)
    original = changed[2]
    changed[2] = Component("Drive", original.width, "Concrete", "#454545", 0.2)
    assert not any(band.start <= 1 and band.end >= 3 for band in candidate_bands(changed))
    excluded = list(components)
    target = excluded[2]
    excluded[2] = Component(target.kind, target.width, target.material, target.colour,
                            target.height, target.collidable, True)
    assert not any(band.start <= 1 and band.end >= 3 for band in candidate_bands(excluded))

    # Broken edge mapping: a 0.1-stud drift must exceed the edge parity gate.
    probe = banked_case["road"].length * 0.18
    edge = next(band for bands in banked_case["interval_bands"] for band in bands
                if band.kind == "Drive")
    shifted = Band(edge.start, edge.end, edge.left + 0.1, edge.right, edge.kind)
    source = banked_case["raw_bands"][edge.start]
    roll_at = banked_case["roll_at"]
    actual = banked_case["road"].point(probe, shifted.left, roll_at(probe))
    expected = banked_case["road"].point(probe, source.left, roll_at(probe))
    assert magnitude(subtract(actual, expected)) > 0.09, "edge-drift break was not detected"


def check():
    parity_contracts()
    components = boulevard_components()
    # A motorway-scale shallow curve: tight curves intentionally fail the
    # midpoint-box overhang proof and retain per-lane surfaces.
    gentle_road = ArcRoad(5000.0, 10.0)
    gentle_profile = build_roll_profile(gentle_road.length, lambda _station: 0.0, 11.2, enabled=False)
    gentle = build_case("gentle_curve", gentle_road, components, gentle_profile)
    bank_road = ArcRoad(120.0, 100.0)
    bank_profile = build_roll_profile(
        bank_road.length,
        lambda _station: math.radians(6.0),
        11.2,
    )
    banked = build_case(
        "bank_runoff",
        bank_road,
        components,
        bank_profile,
    )

    for case in (gentle, banked):
        assert case["optimized_parts"] < case["baseline_parts"], case
        assert case["max_edge_error"] <= 1e-7, case
        assert case["max_twist_error"] <= MAX_BANKED_BAND_WARP_STUDS + 1e-7, case
        assert case["max_plan_overhang"] <= MAX_CURVED_BAND_OVERHANG_STUDS + 1e-7, case
        assert max(abs(b - a) for a, b in zip(case["rolls"], case["rolls"][1:])) <= MAX_ROLL_PER_STEP + 1e-7
        # Raw component boundaries remain independent of emitted band count.
        assert component_offsets(case["components"]) == case["offsets"]

    gentle_drive_before = sum(1 for band in gentle["raw_bands"] if band.kind == "Drive")
    gentle_drive_after = sum(1 for band in gentle["interval_bands"][0] if band.kind == "Drive")
    assert gentle_drive_before == 6 and gentle_drive_after == 2
    semantic_break_tests(banked)
    return gentle, banked


COLOURS = {
    "Drive": (64, 69, 78),
    "Sidewalk": (172, 177, 184),
    "Median": (114, 137, 96),
}
SEAM = (232, 145, 66)
REFERENCE = (35, 106, 164)
GROUND = (231, 235, 240)


def plan_bounds(case):
    road = case["road"]
    half = max(abs(case["offsets"][0][0]), abs(case["offsets"][-1][1])) + 8
    points = [road.plan_position(road.length * index / 200) for index in range(201)]
    return (
        min(point[0] for point in points) - half,
        min(point[1] for point in points) - half,
        max(point[0] for point in points) + half,
        max(point[1] for point in points) + half,
    )


def draw_plan(canvas, case, bands_or_plan, stations, box):
    x0, y0, x1, y1 = box
    lo_x, lo_y, hi_x, hi_y = plan_bounds(case)
    scale = min((x1 - x0) / (hi_x - lo_x), (y1 - y0) / (hi_y - lo_y))

    def transform(point):
        return x0 + (point[0] - lo_x) * scale, y1 - (point[1] - lo_y) * scale

    road, roll_at = case["road"], case["roll_at"]
    if bands_or_plan and isinstance(bands_or_plan[0], list):
        plans = bands_or_plan
    else:
        plans = [bands_or_plan for _ in range(len(stations) - 1)]
    for start, finish, bands in zip(stations, stations[1:], plans):
        start_roll, finish_roll = roll_at(start), roll_at(finish)
        for band in bands:
            if abs(finish_roll - start_roll) <= ROLL_WEDGE_EPSILON:
                quad = midpoint_box_plan_polygon(
                    road, band, start, finish, (start_roll + finish_roll) / 2.0
                )
            else:
                quad = [
                    road.point(start, band.left, start_roll),
                    road.point(start, band.right, start_roll),
                    road.point(finish, band.right, finish_roll),
                    road.point(finish, band.left, finish_roll),
                ]
            canvas.fill_poly([transform(point) for point in quad], COLOURS.get(band.kind, (120, 120, 120)))
    for station in stations:
        roll = roll_at(station)
        left = road.point(station, case["offsets"][0][0], roll)
        right = road.point(station, case["offsets"][-1][1], roll)
        canvas.line(transform(left), transform(right), SEAM, 1)
    center = [transform((*road.plan_position(road.length * index / 120), 0.0))
              for index in range(121)]
    canvas.polyline(center, (238, 238, 238), 1)


def draw_side(canvas, case, box):
    x0, y0, x1, y1 = box
    road, roll_at = case["road"], case["roll_at"]
    outside = max(abs(case["offsets"][0][0]), abs(case["offsets"][-1][1]))
    samples = []
    for index in range(241):
        station = road.length * index / 240
        samples.append((station, outside * math.sin(roll_at(station))))
    max_height = max(value for _, value in samples) or 1.0

    def transform(sample):
        station, height = sample
        return x0 + (x1 - x0) * station / road.length, y1 - (y1 - y0) * height / (max_height * 1.15)

    canvas.line((x0, y1), (x1, y1), (128, 134, 142), 1)
    canvas.polyline([transform(sample) for sample in samples], REFERENCE, 3)
    station_points = [(station, outside * math.sin(roll_at(station)))
                      for station in case["optimized_stations"]]
    canvas.polyline([transform(sample) for sample in station_points], SEAM, 1)
    for sample in station_points:
        x, y = transform(sample)
        canvas.disc(x, y, 2, SEAM)


def draw_cross_sections(canvas, case, box):
    x0, y0, x1, y1 = box
    fractions = (0.0, 0.25, 0.5, 0.75, 1.0)
    total_width = case["offsets"][-1][1] - case["offsets"][0][0]
    slot = (x1 - x0) / len(fractions)
    vertical_scale = (y1 - y0) * 0.65 / max(total_width, 1.0)
    for index, fraction in enumerate(fractions):
        station = case["road"].length * fraction
        roll = case["roll_at"](station)
        center_x = x0 + slot * (index + 0.5)
        center_y = y0 + (y1 - y0) * 0.62
        for band in case["raw_bands"]:
            left = band.left
            right = band.right
            a = (center_x + left * vertical_scale, center_y - left * math.sin(roll) * vertical_scale)
            b = (center_x + right * vertical_scale, center_y - right * math.sin(roll) * vertical_scale)
            canvas.line(a, b, COLOURS.get(band.kind, (120, 120, 120)), 5)
        canvas.line((center_x, y0 + 8), (center_x, y1 - 8), (205, 209, 214), 1)


def draw_count_bars(canvas, gentle, banked, box):
    x0, y0, x1, y1 = box
    cases = (gentle, banked)
    row = (y1 - y0) / 2
    for index, case in enumerate(cases):
        top = y0 + index * row + 10
        width = x1 - x0
        canvas.fill_poly([(x0, top), (x1, top), (x1, top + 14), (x0, top + 14)], (194, 83, 76))
        fraction = case["optimized_parts"] / case["baseline_parts"]
        canvas.fill_poly([(x0, top + 22), (x0 + width * fraction, top + 22),
                          (x0 + width * fraction, top + 36), (x0, top + 36)], (62, 155, 94))


def render(path, gentle=None, banked=None):
    if gentle is None or banked is None:
        gentle, banked = check()
    canvas = Canvas(1500, 980, GROUND)
    draw_plan(canvas, gentle, gentle["raw_bands"], gentle["baseline_stations"], (35, 30, 730, 455))
    draw_plan(canvas, gentle, gentle["interval_bands"], gentle["optimized_stations"], (770, 30, 1465, 455))
    draw_side(canvas, banked, (50, 510, 930, 700))
    draw_cross_sections(canvas, banked, (50, 735, 930, 945))
    draw_count_bars(canvas, gentle, banked, (990, 550, 1435, 890))
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    canvas.save(path)


def describe(case):
    reduction = (1.0 - case["optimized_parts"] / case["baseline_parts"]) * 100.0
    return (
        f"{case['tag']}: {case['baseline_parts']} -> {case['optimized_parts']} surface Parts "
        f"({reduction:.1f}% fewer), {len(case['baseline_stations']) - 1} -> "
        f"{len(case['optimized_stations']) - 1} intervals, max edge "
        f"{case['max_edge_error']:.6f}, max twist {case['max_twist_error']:.4f} studs, "
        f"max plan overhang {case['max_plan_overhang']:.4f} studs"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="semantic and break-tests only")
    parser.add_argument(
        "--out",
        default=os.path.join(os.path.dirname(__file__), "out", "curved_superelevation_optimization.png"),
        help="combined bird's-eye, side, cross-section, and count PNG",
    )
    args = parser.parse_args()
    gentle, banked = check()
    print("curved/superelevation optimization QA passed")
    print("  " + describe(gentle))
    print("  " + describe(banked))
    if not args.check:
        render(args.out, gentle, banked)
        print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
