#!/usr/bin/env python3
"""Validate and render the parallel-roadway offset/refit used by placement.

The image shows a two-carriageway opposed pair around the clicked centre
alignment, followed by a four-roadway example with independent direction
choices. It is a headless geometric port, not a Roblox render.
"""
import argparse
import bisect
import math
import os
import sys

from raster import Canvas


SUBDIVISIONS = 6


def add(a, b):
    return tuple(x+y for x, y in zip(a, b))


def sub(a, b):
    return tuple(x-y for x, y in zip(a, b))


def mul(a, scalar):
    return tuple(x*scalar for x in a)


def distance(a, b):
    return math.sqrt(sum((x-y)**2 for x, y in zip(a, b)))


class Cubic:
    def __init__(self, p0, p1, p2, p3):
        self.p = (p0, p1, p2, p3)
        self._ts = [index/300 for index in range(301)]
        self._lengths = [0.0]
        previous = self.at(0.0)
        for t in self._ts[1:]:
            current = self.at(t)
            self._lengths.append(self._lengths[-1]+distance(previous, current))
            previous = current
        self.length = self._lengths[-1]

    def at(self, t):
        p0, p1, p2, p3 = self.p
        u = 1-t
        return tuple(u**3*p0[i]+3*u*u*t*p1[i]+3*u*t*t*p2[i]+t**3*p3[i]
                     for i in range(3))

    def tangent(self, t):
        p0, p1, p2, p3 = self.p
        u = 1-t
        raw = tuple(3*u*u*(p1[i]-p0[i])+6*u*t*(p2[i]-p1[i])+3*t*t*(p3[i]-p2[i])
                    for i in range(3))
        mag = math.hypot(raw[0], raw[2]) or 1.0
        return raw[0]/mag, 0.0, raw[2]/mag

    def station_t(self, fraction):
        target = min(max(fraction, 0.0), 1.0)*self.length
        upper = min(bisect.bisect_left(self._lengths, target), len(self._lengths)-1)
        if upper == 0:
            return 0.0
        lower = upper-1
        span = self._lengths[upper]-self._lengths[lower]
        alpha = 0.0 if span == 0 else (target-self._lengths[lower])/span
        return self._ts[lower]+(self._ts[upper]-self._ts[lower])*alpha

    def at_station(self, fraction):
        return self.at(self.station_t(fraction))

    def tangent_station(self, fraction):
        return self.tangent(self.station_t(fraction))


def offset_point(curve, fraction, offset):
    point = curve.at_station(fraction)
    tangent = curve.tangent_station(fraction)
    right = (-tangent[2], 0.0, tangent[0])
    return add(point, mul(right, offset))


def offset_chunk(curve, offset, start, end):
    def sample(u):
        return offset_point(curve, start+(end-start)*u, offset)
    q0, q1, q2, q3 = (sample(0), sample(1/3), sample(2/3), sample(1))
    a = mul(sub(sub(mul(q1, 27), mul(q0, 8)), q3), 1/6)
    c = mul(sub(sub(mul(q2, 27), q0), mul(q3, 8)), 1/6)
    p1 = mul(sub(mul(a, 2), c), 1/3)
    p2 = mul(sub(mul(c, 2), a), 1/3)
    return Cubic(q0, p1, p2, q3)


class OffsetPath:
    def __init__(self, chunks):
        self.chunks = chunks

    def at(self, t):
        scaled = min(max(t, 0.0), 1.0)*len(self.chunks)
        index = min(int(scaled), len(self.chunks)-1)
        return self.chunks[index].at(scaled-index)


def offset_curve(curve, offset):
    return OffsetPath([
        offset_chunk(curve, offset, index/SUBDIVISIONS, (index+1)/SUBDIVISIONS)
        for index in range(SUBDIVISIONS)
    ])


def demo_curve():
    return Cubic((0, 0, 0), (65, 0, -25), (135, 0, 115), (225, 0, 82))


def offset_errors():
    curve = demo_curve()
    errors = []
    for offset in (-24.0, 24.0, -60.0, 60.0):
        fitted = offset_curve(curve, offset)
        # Every chunk meets its neighbours and its four fitted stations.
        for chunk_index, chunk in enumerate(fitted.chunks):
            start, end = chunk_index/SUBDIVISIONS, (chunk_index+1)/SUBDIVISIONS
            for u in (0.0, 1/3, 2/3, 1.0):
                t = start+(end-start)*u
                if distance(chunk.at(u), offset_point(curve, t, offset)) > 1e-7:
                    errors.append(f"offset cubic misses fit station at t={t}")
        # Between fit stations the approximation must remain close to the
        # requested separation even on this deliberately strong S-curve.
        for index in range(41):
            t = index/40
            requested = offset_point(curve, t, offset)
            if distance(fitted.at(t), requested) > max(0.5, abs(offset)*0.01):
                errors.append(f"offset drift exceeds tolerance at t={t:.3f}")
                break
    return errors


def map_point(point, top):
    x, _y, z = point
    return 75+x*4.1, top+150-z*1.35


def arrow(canvas, curve, t, reverse, top, color):
    before = map_point(curve.at(max(0, t-0.015)), top)
    after = map_point(curve.at(min(1, t+0.015)), top)
    if reverse:
        before, after = after, before
    dx, dy = after[0]-before[0], after[1]-before[1]
    mag = math.hypot(dx, dy) or 1
    ux, uy = dx/mag, dy/mag
    nx, ny = -uy, ux
    tip = (after[0]+ux*7, after[1]+uy*7)
    canvas.fill_poly([tip, (after[0]-ux*5+nx*5, after[1]-uy*5+ny*5),
                      (after[0]-ux*5-nx*5, after[1]-uy*5-ny*5)], color)


def render(path):
    errors = offset_errors()
    if errors:
        raise AssertionError("; ".join(errors))
    canvas = Canvas(1100, 520, (29, 34, 43))
    canvas.line((40, 260), (1060, 260), (72, 82, 96), 2)
    centre = demo_curve()

    # Two carriageways, opposed traffic directions.
    canvas.polyline([map_point(centre.at_station(i/120), 10) for i in range(121)], (72, 82, 96), 2)
    pair = (offset_curve(centre, -24), offset_curve(centre, 24))
    pair_colors = ((57, 171, 160), (89, 126, 207))
    for index, roadway in enumerate(pair):
        points = [map_point(roadway.at(i/120), 10) for i in range(121)]
        canvas.polyline(points, (48, 53, 60), 28)
        canvas.polyline(points, pair_colors[index], 3)
        for t in (0.25, 0.55, 0.82):
            arrow(canvas, roadway, t, index == 0, 10, (225, 230, 235))

    # Four carriageways; roadway 1 and 3 are independently reversed.
    canvas.polyline([map_point(centre.at_station(i/120), 275) for i in range(121)], (72, 82, 96), 2)
    for index, offset in enumerate((-54, -18, 18, 54), start=1):
        roadway = offset_curve(centre, offset)
        points = [map_point(roadway.at(i/120), 275) for i in range(121)]
        canvas.polyline(points, (48, 53, 60), 20)
        canvas.polyline(points, pair_colors[index % 2], 3)
        arrow(canvas, roadway, 0.55, index in (1, 3), 275, (225, 230, 235))

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    canvas.save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--out")
    args = parser.parse_args()
    errors = offset_errors()
    if errors:
        for error in errors:
            print("FAILED:", error)
        return 1
    if args.out:
        render(args.out)
        print(f"wrote {args.out}: opposed pair and four-roadway direction example")
    else:
        print(f"parallel roadway checks passed: {SUBDIVISIONS} offset cubics meet all fit stations and stay within drift tolerance")
    return 0


if __name__ == "__main__":
    sys.exit(main())
