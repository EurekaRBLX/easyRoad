#!/usr/bin/env python3
"""Bird's-eye contract for widening/narrowing transition anchoring.

The six panels are Centre / Left edge / Right edge from left to right, with a
one-way 3->4 widening on the top row and a 4->3 narrowing on the bottom row.
The orange guide is the authored reference that must not move.  Cyan shows the
newly gained cross-section area (or the area removed by a narrowing).

This is a Python model, not a Luau execution.  ``integration_contracts.py``
guards the corresponding RoadBuilder, placement UI, and persistence wiring.

    python transition_anchor_preview.py --check
    python transition_anchor_preview.py --out out/transition-anchors.png
"""

import argparse
from dataclasses import dataclass, replace
import math
import os
import sys

from raster import Canvas


LANE_WIDTH_M = 3.65
ROAD_LENGTH_M = 80.0
CONTINUATION_LENGTH_M = 24.0
ANCHORS = ("Centre", "LeftEdge", "RightEdge")
EPSILON = 1e-9

BACKGROUND = (28, 33, 42)
PANEL = (42, 49, 60)
ASPHALT = (78, 85, 98)
ASPHALT_DARK = (57, 64, 76)
EDGE = (231, 234, 238)
MARKING = (220, 224, 229)
ACCENT = (226, 132, 79)
CHANGE = (66, 181, 190)
REFERENCE = (102, 116, 137)


@dataclass(frozen=True)
class CrossSection:
    station_m: float
    width_m: float
    shift_m: float

    @property
    def left_m(self):
        return -self.width_m / 2 + self.shift_m

    @property
    def centre_m(self):
        return self.shift_m

    @property
    def right_m(self):
        return self.width_m / 2 + self.shift_m


@dataclass(frozen=True)
class Transition:
    start_lanes: int
    end_lanes: int
    anchor: str
    samples: tuple
    continuation: tuple


def smoothstep(value):
    value = min(max(value, 0.0), 1.0)
    return value * value * (3.0 - 2.0 * value)


def anchor_shift(anchor, start_width_m, width_m):
    """Port the RoadBuilder lateral translation for an authored reference.

    Cross-section coordinates begin centred at ``[-width/2, +width/2]``.
    Therefore a widening must translate *towards* the fixed edge:

    * LeftEdge:  +(width - start_width) / 2
    * RightEdge: +(start_width - width) / 2
    """
    if anchor == "Centre":
        return 0.0
    if anchor == "LeftEdge":
        return (width_m - start_width_m) / 2
    if anchor == "RightEdge":
        return (start_width_m - width_m) / 2
    raise ValueError(f"unknown transition anchor: {anchor}")


def normalize_profile_offset(value):
    if isinstance(value, (int, float)) and math.isfinite(value):
        return float(value)
    return 0.0


def legacy_offset_faults(normalizer=normalize_profile_offset):
    faults = []
    for value in (None, "not a number", float("nan"), float("inf")):
        if normalizer(value) != 0:
            faults.append("legacy/invalid profile offset does not default to zero")
            break
    return faults


def build_transition(
        start_lanes,
        end_lanes,
        anchor,
        shift_fn=anchor_shift,
        profile_offset_start_m=0.0,
        continuation_offset_override=None):
    start_width = start_lanes * LANE_WIDTH_M
    end_width = end_lanes * LANE_WIDTH_M
    profile_offset_start_m = normalize_profile_offset(profile_offset_start_m)
    samples = []
    for index in range(81):
        station = ROAD_LENGTH_M * index / 80
        alpha = smoothstep(station / ROAD_LENGTH_M)
        width = start_width + (end_width - start_width) * alpha
        samples.append(CrossSection(
            station,
            width,
            profile_offset_start_m + shift_fn(anchor, start_width, width),
        ))
    destination_offset = samples[-1].shift_m
    continuation_offset = (destination_offset if continuation_offset_override is None
                           else normalize_profile_offset(continuation_offset_override))
    continuation = tuple(
        CrossSection(
            ROAD_LENGTH_M + CONTINUATION_LENGTH_M * index / 24,
            end_width,
            continuation_offset,
        )
        for index in range(25)
    )
    return Transition(start_lanes, end_lanes, anchor, tuple(samples), continuation)


def close(a, b, tolerance=EPSILON):
    return abs(a - b) <= tolerance


def transition_faults(transition):
    faults = []
    samples = transition.samples
    if not samples:
        return ["transition has no samples"]

    start_width = transition.start_lanes * LANE_WIDTH_M
    end_width = transition.end_lanes * LANE_WIDTH_M
    start = samples[0]
    finish = samples[-1]
    if not close(start.width_m, start_width) or not close(finish.width_m, end_width):
        faults.append("transition does not reach the requested lane counts")
    if not close(start.left_m, -start_width / 2) or not close(start.right_m, start_width / 2):
        faults.append("transition moves the source cross-section at station zero")

    previous_width = samples[0].width_m
    direction = 1 if end_width > start_width else -1
    for sample in samples:
        alpha = smoothstep(sample.station_m / ROAD_LENGTH_M)
        expected_width = start_width + (end_width - start_width) * alpha
        if not close(sample.width_m, expected_width):
            faults.append("transition width does not follow the canonical smoothstep")
            break
        if direction * (sample.width_m - previous_width) < -EPSILON:
            faults.append("transition reverses width part-way through the taper")
            break
        previous_width = sample.width_m

    if transition.anchor == "Centre":
        if any(not close(sample.centre_m, 0.0) for sample in samples):
            faults.append("Centre anchor lets the authored centreline drift")
        delta = end_width - start_width
        if not close(finish.left_m - start.left_m, -delta / 2):
            faults.append("Centre anchor does not split the width change on the left")
        if not close(finish.right_m - start.right_m, delta / 2):
            faults.append("Centre anchor does not split the width change on the right")
    elif transition.anchor == "LeftEdge":
        if any(not close(sample.left_m, -start_width / 2) for sample in samples):
            faults.append("LeftEdge anchor lets the authored left edge drift")
        if not close(finish.right_m - start.right_m, end_width - start_width):
            faults.append("LeftEdge anchor does not put the full width change on the right")
    elif transition.anchor == "RightEdge":
        if any(not close(sample.right_m, start_width / 2) for sample in samples):
            faults.append("RightEdge anchor lets the authored right edge drift")
        if not close(finish.left_m - start.left_m, start_width - end_width):
            faults.append("RightEdge anchor does not put the full width change on the left")
    else:
        faults.append(f"unsupported anchor {transition.anchor}")

    if not transition.continuation:
        faults.append("transition has no chained destination segment")
    else:
        chain_start = transition.continuation[0]
        if not (
                close(chain_start.left_m, finish.left_m)
                and close(chain_start.centre_m, finish.centre_m)
                and close(chain_start.right_m, finish.right_m)):
            faults.append("chained constant-width road recentres at the transition join")
        if any(
                not close(sample.width_m, finish.width_m)
                or not close(sample.shift_m, finish.shift_m)
                for sample in transition.continuation):
            faults.append("chained constant-width road does not preserve its destination profile offset")
    return faults


def semantic_faults():
    faults = []
    for start_lanes, end_lanes in ((3, 4), (4, 3)):
        for anchor in ANCHORS:
            transition = build_transition(start_lanes, end_lanes, anchor)
            for fault in transition_faults(transition):
                faults.append(f"{start_lanes}->{end_lanes} {anchor}: {fault}")
    faults.extend(legacy_offset_faults())
    return faults


def invariant_summary(transition):
    start = transition.samples[0]
    finish = transition.samples[-1]
    if transition.anchor == "Centre":
        drift = max(abs(sample.centre_m) for sample in transition.samples)
        movement = (
            f"left {finish.left_m - start.left_m:+.3f} m, "
            f"right {finish.right_m - start.right_m:+.3f} m"
        )
    elif transition.anchor == "LeftEdge":
        drift = max(abs(sample.left_m - start.left_m) for sample in transition.samples)
        movement = f"right {finish.right_m - start.right_m:+.3f} m"
    else:
        drift = max(abs(sample.right_m - start.right_m) for sample in transition.samples)
        movement = f"left {finish.left_m - start.left_m:+.3f} m"
    chain = transition.continuation[0]
    join_error = max(
        abs(chain.left_m - finish.left_m),
        abs(chain.centre_m - finish.centre_m),
        abs(chain.right_m - finish.right_m),
    )
    return drift, movement, join_error


def injected_break_count():
    caught = 0
    for start_lanes, end_lanes in ((3, 4), (4, 3)):
        for anchor in ANCHORS:
            def broken_shift(candidate, start_width, width, expected=anchor):
                if expected == "Centre":
                    return (width - start_width) * 0.2
                if expected == "LeftEdge":
                    return (start_width - width) / 2
                return (width - start_width) / 2

            broken = build_transition(start_lanes, end_lanes, anchor, broken_shift)
            if not transition_faults(broken):
                raise AssertionError(
                    f"{start_lanes}->{end_lanes} {anchor} anchor-drift break-test escaped")
            caught += 1

    valid = build_transition(3, 4, "Centre")
    wrong_finish = list(valid.samples)
    wrong_finish[-1] = replace(wrong_finish[-1], width_m=wrong_finish[-1].width_m - 0.4)
    if not transition_faults(replace(valid, samples=tuple(wrong_finish))):
        raise AssertionError("wrong destination width break-test escaped")

    chain_breaks = 0
    for start_lanes, end_lanes in ((3, 4), (4, 3)):
        for anchor in ("LeftEdge", "RightEdge"):
            broken = build_transition(
                start_lanes,
                end_lanes,
                anchor,
                continuation_offset_override=0.0,
            )
            if not transition_faults(broken):
                raise AssertionError(
                    f"{start_lanes}->{end_lanes} {anchor} chain-recentre break-test escaped")
            chain_breaks += 1

    if not legacy_offset_faults(lambda _value: 1.0):
        raise AssertionError("legacy profile-offset fallback break-test escaped")
    return caught + 1 + chain_breaks + 1


def dashed_polyline(canvas, points, colour, width=2, dash=10, gap=8):
    """Dash a sampled curve without restarting the pattern each interval."""
    drawing = True
    remaining = float(dash)
    for start, end in zip(points, points[1:]):
        dx, dy = end[0] - start[0], end[1] - start[1]
        length = math.hypot(dx, dy)
        if length <= EPSILON:
            continue
        cursor = 0.0
        while cursor < length - EPSILON:
            take = min(remaining, length - cursor)
            if drawing:
                a = (start[0] + dx * cursor / length,
                     start[1] + dy * cursor / length)
                b = (start[0] + dx * (cursor + take) / length,
                     start[1] + dy * (cursor + take) / length)
                canvas.line(a, b, colour, width)
            cursor += take
            remaining -= take
            if remaining <= EPSILON:
                drawing = not drawing
                remaining = float(dash if drawing else gap)
def panel_box(canvas, left, top, right, bottom):
    canvas.fill_poly([(left, top), (right, top), (right, bottom), (left, bottom)], PANEL)


def render_panel(canvas, transition, left, top, width, height):
    panel_box(canvas, left, top, left + width, top + height)
    x0 = left + 28
    x1 = left + width - 28
    centre_y = top + height / 2
    max_width = 4 * LANE_WIDTH_M
    lateral_scale = (height * 0.66) / max_width

    total_length = ROAD_LENGTH_M + CONTINUATION_LENGTH_M

    def point(sample, lateral):
        x = x0 + (x1 - x0) * sample.station_m / total_length
        return x, centre_y + lateral * lateral_scale

    all_samples = transition.samples + transition.continuation[1:]
    upper = [point(sample, sample.left_m) for sample in all_samples]
    lower = [point(sample, sample.right_m) for sample in reversed(all_samples)]
    canvas.fill_poly(upper + lower, ASPHALT)

    # Highlight the area gained or removed relative to the source cross-section.
    source_left = transition.samples[0].left_m
    source_right = transition.samples[0].right_m
    # Build the changing-side ribbons as proper polygons instead of per-column bars.
    moving_left = [point(sample, sample.left_m) for sample in transition.samples]
    fixed_source_left = [point(sample, source_left) for sample in reversed(transition.samples)]
    if any(not close(sample.left_m, source_left) for sample in transition.samples):
        canvas.fill_poly(moving_left + fixed_source_left, CHANGE)
    moving_right = [point(sample, sample.right_m) for sample in transition.samples]
    fixed_source_right = [point(sample, source_right) for sample in reversed(transition.samples)]
    if any(not close(sample.right_m, source_right) for sample in transition.samples):
        canvas.fill_poly(moving_right + fixed_source_right, CHANGE)

    # Lane separators interpolate with the full cross-section, matching the
    # user's mental model: the road owns the taper; the chosen reference owns
    # where that taper is allowed to move.
    divider_count = min(transition.start_lanes, transition.end_lanes) - 1
    for divider in range(1, divider_count + 1):
        points = []
        for sample in transition.samples:
            lane_count = (transition.start_lanes
                          + (transition.end_lanes - transition.start_lanes)
                          * smoothstep(sample.station_m / ROAD_LENGTH_M))
            lateral = sample.left_m + sample.width_m * divider / lane_count
            points.append(point(sample, lateral))
        for sample in transition.continuation[1:]:
            lateral = sample.left_m + sample.width_m * divider / transition.end_lanes
            points.append(point(sample, lateral))
        dashed_polyline(canvas, points, MARKING, 2, 7, 7)

    # The additional divider begins/ends at an edge, making the lane-count
    # change visible without pretending it is a separate curve-tool segment.
    wedge_points = []
    for sample in transition.samples:
        alpha = smoothstep(sample.station_m / ROAD_LENGTH_M)
        if transition.end_lanes > transition.start_lanes:
            fraction = transition.start_lanes / (transition.start_lanes + alpha)
        else:
            fraction = (transition.start_lanes - 1 + alpha) / transition.start_lanes
        lateral = sample.left_m + sample.width_m * min(max(fraction, 0), 1)
        wedge_points.append(point(sample, lateral))
    final_fraction = (transition.start_lanes / transition.end_lanes
                      if transition.end_lanes > transition.start_lanes else 1.0)
    for sample in transition.continuation[1:]:
        lateral = sample.left_m + sample.width_m * min(max(final_fraction, 0), 1)
        wedge_points.append(point(sample, lateral))
    dashed_polyline(canvas, wedge_points, MARKING, 2, 7, 7)

    canvas.polyline(upper, EDGE, 2)
    canvas.polyline(list(reversed(lower)), EDGE, 2)

    # Neutral authored centreline, plus the selected invariant in theme orange.
    centreline = [point(sample, 0.0) for sample in all_samples]
    dashed_polyline(canvas, centreline, REFERENCE, 1, 5, 7)
    if transition.anchor == "Centre":
        guide = [point(sample, sample.centre_m) for sample in all_samples]
    elif transition.anchor == "LeftEdge":
        guide = [point(sample, sample.left_m) for sample in all_samples]
    else:
        guide = [point(sample, sample.right_m) for sample in all_samples]
    canvas.polyline(guide, ACCENT, 3)


def render(path):
    faults = semantic_faults()
    if faults:
        raise AssertionError("; ".join(faults))
    canvas = Canvas(1200, 700, BACKGROUND)
    margin = 24
    gap = 18
    panel_width = (canvas.w - 2 * margin - 2 * gap) / 3
    panel_height = (canvas.h - 2 * margin - gap) / 2
    for row, (start_lanes, end_lanes) in enumerate(((3, 4), (4, 3))):
        for column, anchor in enumerate(ANCHORS):
            render_panel(
                canvas,
                build_transition(start_lanes, end_lanes, anchor),
                margin + column * (panel_width + gap),
                margin + row * (panel_height + gap),
                panel_width,
                panel_height,
            )
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    canvas.save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--out")
    args = parser.parse_args()
    faults = semantic_faults()
    if faults:
        for fault in faults:
            print("FAILED:", fault)
        return 1
    break_count = injected_break_count()
    if args.out:
        render(args.out)
        print(f"wrote {args.out}: Centre / LeftEdge / RightEdge, 3->4 and 4->3")
    else:
        for start_lanes, end_lanes in ((3, 4), (4, 3)):
            for anchor in ANCHORS:
                drift, movement, join_error = invariant_summary(
                    build_transition(start_lanes, end_lanes, anchor)
                )
                print(
                    f"  {start_lanes}->{end_lanes} {anchor:9s} "
                    f"max reference drift {drift:.9f} m; {movement}; "
                    f"chain join {join_error:.9f} m"
                )
        print(
            "transition anchor checks passed: Centre/LeftEdge/RightEdge preserve "
            f"their authored reference for 3->4 and 4->3; {break_count} injected break-tests caught"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
