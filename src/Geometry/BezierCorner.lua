--!strict
-- Bounded quadratic-Bezier corner, translated from MarcusElg/roadcreator
-- (MIT, Copyright 2019 MCrafterzz - see reference/roadcreator/). A drop-in
-- alternative to Geometry/Fillet's circular-arc corner that CANNOT spike or
-- self-intersect for any corner angle.
--
-- Why this exists: Fillet.Compute builds a corner from the INTERSECTION of
-- the two edge lines and a tangent circle. When those lines are
-- near-parallel, diverging, or the corner is reflex, that construction
-- fails or "scoops" inward - the source of the live-reported junction
-- spikes/notches, which every caller then has to guard against after the
-- fact.
--
-- RoadCreator's corner is a QUADRATIC BEZIER `q(t) = (1-t)^2*a + 2(1-t)t*c
-- + t^2*b` through a control point `c`. A quadratic Bezier is a convex
-- combination of {a, c, b}, so the whole curve is bounded INSIDE that
-- triangle - it bulges toward `c` (the rounded corner) but can never
-- overshoot, scoop, or cross itself, for ANY placement of `c` and ANY
-- corner angle. Robustness is a property of the curve form, not of getting
-- the control point exactly right.
--
-- `c` is auto-placed where the two edge lines meet (the corner vertex),
-- with the same fallbacks RoadCreator uses when they're parallel. Ported
-- from Intersection.ResetCurvePointPosition + Misc.{Lerp3, Lerp3CenterHeight,
-- GetLineIntersection, CalculateLeft, GetCenter, CalculateDistance}.

local BezierCorner = {}

-- Ground-plane (XZ) perpendicular of `v`, normalised - Misc.CalculateLeft.
-- Used to turn a mouth-cross vector (right edge - left edge) into the
-- direction the road's edge LINES run.
function BezierCorner.Perpendicular(v: Vector3): Vector3
	local flat = Vector3.new(-v.Z, 0, v.X)
	if flat.Magnitude < 1e-9 then
		return flat
	end
	return flat.Unit
end

-- 2D (ground-plane) intersection of the line through `p1` in direction
-- `d1` with the line through `p2` in direction `d2`. Returns nil when the
-- lines are parallel (Misc.GetLineIntersection's MaxVector3 sentinel).
--
-- Faithful to the source EXCEPT the "is the hit in front of both points"
-- test: RoadCreator does it with Unity's epsilon-tolerant Vector3 `==`,
-- which has no exact Luau equivalent and isn't needed here - the Bezier is
-- bounded wherever `c` lands, and the caller's fallbacks below already
-- cover the degenerate directions - so this returns the infinite-line
-- intersection and lets `ControlPoint` decide.
function BezierCorner.LineIntersection2D(p1: Vector3, d1: Vector3, p2: Vector3, d2: Vector3): Vector3?
	-- Solve p1 + t*d1 = p2 + s*d2 in the XZ plane. cross(d1, d2) is the
	-- z-component of the 2D cross product; ~0 means parallel.
	local cross = d1.X * d2.Z - d1.Z * d2.X
	if math.abs(cross) < 1e-6 then
		return nil
	end
	local vx, vz = p2.X - p1.X, p2.Z - p1.Z
	local t = (vx * d2.Z - vz * d2.X) / cross
	return Vector3.new(p1.X + d1.X * t, p1.Y, p1.Z + d1.Z * t)
end

-- Midpoint of `a` and `b` - Misc.GetCenter.
local function center(a: Vector3, b: Vector3): Vector3
	return a + (b - a) / 2
end

-- The corner control point between edge point `aEdge` (whose road's edge
-- line runs along `aDir`) and edge point `bEdge` (edge line along `bDir`).
-- `aDir`/`bDir` are the ground-plane directions the two roads' edge lines
-- run in - e.g. each road's outward tangent at the junction.
--
-- Ported from Intersection.ResetCurvePointPosition:
--   * lines meet -> the meeting point (the true corner vertex; the Bezier
--     rounds toward it)
--   * parallel and pointing similarly (angle < 90 deg, a through-ish pair)
--     -> midpoint pushed out along the road direction, so the Bezier
--     bulges smoothly through instead of cutting a flat chord
--   * parallel and diverging (>= 90 deg) -> plain midpoint
function BezierCorner.ControlPoint(aEdge: Vector3, aDir: Vector3, bEdge: Vector3, bDir: Vector3): Vector3
	local hit = BezierCorner.LineIntersection2D(aEdge, aDir, bEdge, bDir)
	if hit then
		return hit
	end
	local au = if aDir.Magnitude > 1e-9 then aDir.Unit else aDir
	local bu = if bDir.Magnitude > 1e-9 then bDir.Unit else bDir
	local mid = center(aEdge, bEdge)
	if au:Dot(bu) > 0 then
		-- Nearly parallel, same heading: push the control out along the
		-- road direction by the gap width so the curve reads as a smooth
		-- continuation (Vector3.Angle < 90 in the source).
		return mid + au * (bEdge - aEdge).Magnitude
	end
	return mid
end

-- One point on the quadratic Bezier a->b through control `c` at parameter
-- `t` in [0,1], with height interpolated linearly a.Y -> b.Y (the corner
-- is small relative to any grade, matching Fillet.SampleArc's convention
-- and Misc.Lerp3CenterHeight).
function BezierCorner.PointAt(a: Vector3, c: Vector3, b: Vector3, t: number): Vector3
	local u = 1 - t
	local flat = u * u * a + 2 * u * t * c + t * t * b
	return Vector3.new(flat.X, a.Y + (b.Y - a.Y) * t, flat.Z)
end

-- Rough ground-plane arc length of the Bezier (Misc.CalculateDistance) -
-- for choosing a sample count proportional to how long the corner is.
function BezierCorner.ArcLength(a: Vector3, c: Vector3, b: Vector3): number
	local total = 0
	local last = a
	for i = 1, 100 do
		local p = BezierCorner.PointAt(a, c, b, i / 100)
		local dx, dz = p.X - last.X, p.Z - last.Z
		total += math.sqrt(dx * dx + dz * dz)
		last = p
	end
	return total
end

-- The ordered corner boundary from `aEdge` to `bEdge`, INCLUSIVE of both
-- endpoints, with `samples` interior points along the bounded quadratic
-- Bezier through the auto-placed control point. This is the shape a
-- caller drops in where it used a straight chord or a Fillet arc.
function BezierCorner.Boundary(
	aEdge: Vector3,
	aDir: Vector3,
	bEdge: Vector3,
	bDir: Vector3,
	samples: number
): { Vector3 }
	local c = BezierCorner.ControlPoint(aEdge, aDir, bEdge, bDir)
	local points: { Vector3 } = { aEdge }
	for i = 1, samples do
		table.insert(points, BezierCorner.PointAt(aEdge, c, bEdge, i / (samples + 1)))
	end
	table.insert(points, bEdge)
	return points
end

return BezierCorner
