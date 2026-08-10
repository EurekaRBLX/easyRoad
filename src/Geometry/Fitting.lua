--!strict
-- Curve fitting helpers used by the placement tools.
--
-- The Cities: Skylines style tools work in clicks:
--   * Straight: start, end                          -> Line
--   * Curve:    start, guide (tangent control), end -> Quadratic bezier
--   * Freeform: start, control, control, end        -> Cubic bezier
--
-- When a road continues from an existing endpoint the start tangent is
-- locked, so the guide point can be derived instead of clicked.

local CurveSegment = require("./CurveSegment")

local Fitting = {}

function Fitting.Straight(startPos: Vector3, endPos: Vector3): CurveSegment.Segment
	return CurveSegment.Line(startPos, endPos)
end

function Fitting.Curve(startPos: Vector3, guide: Vector3, endPos: Vector3): CurveSegment.Segment
	return CurveSegment.Quadratic(startPos, guide, endPos)
end

function Fitting.Freeform(
	startPos: Vector3,
	control1: Vector3,
	control2: Vector3,
	endPos: Vector3
): CurveSegment.Segment
	return CurveSegment.Cubic(startPos, control1, control2, endPos)
end

-- Curve from a locked start tangent. The end tangent of the circular arc
-- through both points is the start tangent mirrored across the chord
-- direction; building a cubic from both tangents (Hermite style)
-- approximates that arc and - unlike a guide-point quadratic - stays smooth
-- at ANY turn angle, including end points placed beside or behind the
-- start. No cusps, no folded frames.
function Fitting.CurveFromTangent(startPos: Vector3, startTangent: Vector3, endPos: Vector3): CurveSegment.Segment
	local chord = endPos - startPos
	local chordLength = chord.Magnitude
	if chordLength < 1e-6 then
		return CurveSegment.Line(startPos, endPos)
	end
	local tangent = startTangent.Unit
	local chordDir = chord / chordLength
	local cosAngle = tangent:Dot(chordDir)

	-- Nearly straight ahead: a plain line is exact
	if cosAngle > 0.9999 then
		return CurveSegment.Line(startPos, endPos)
	end

	local endTangent = chordDir * (2 * cosAngle) - tangent
	if endTangent.Magnitude < 1e-6 then
		endTangent = chordDir
	else
		endTangent = endTangent.Unit
	end

	local handle = chordLength / 3
	local control1 = startPos + tangent * handle
	local control2 = endPos - endTangent * handle
	return CurveSegment.Cubic(startPos, control1, control2, endPos)
end

-- Straight continuation from a locked tangent: the road goes exactly along
-- the tangent for the projected distance to the clicked point.
function Fitting.StraightFromTangent(startPos: Vector3, startTangent: Vector3, endPos: Vector3): CurveSegment.Segment
	local tangent = startTangent.Unit
	local distance = math.max((endPos - startPos):Dot(tangent), 1)
	return CurveSegment.Line(startPos, startPos + tangent * distance)
end

-- Treat a target-road tangent as an undirected axis and point it along the
-- authored segment's chord. Sharing this convention with placement keeps the
-- endpoint's tangent and its lateral profile-offset frame from choosing
-- opposite signs.
function Fitting.OrientedTangentAxis(axis: Vector3, chord: Vector3): Vector3
	local chordDirection = if chord.Magnitude > 1e-6 then chord.Unit else Vector3.zAxis
	local direction = if axis.Magnitude > 1e-6 then axis.Unit else chordDirection
	return if direction:Dot(chordDirection) < 0 then -direction else direction
end

-- Mirrors PolyCurve.FrameAt's unrolled right vector. Cross-section placement
-- uses it to solve the authored curve point whose later RoadBuilder profile
-- offset will put the visible carriageway centre exactly on the snap target.
function Fitting.TangentRightVector(tangent: Vector3): Vector3
	local direction = if tangent.Magnitude > 1e-6 then tangent.Unit else Vector3.zAxis
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-6 then
		direction = Vector3.zAxis
	end
	return CFrame.lookAt(Vector3.zero, direction, Vector3.yAxis).RightVector
end

-- Re-expresses any supported segment as an equivalent cubic, then constrains
-- whichever endpoint tangent axes were supplied.  The endpoints themselves
-- never move and the unconstrained handle stays mathematically equivalent to
-- the original Line / Quadratic / Cubic shape.  This is used by
-- cross-section-only road placement: the target road remains untouched, while
-- the new road arrives along the selected carriageway reference instead of
-- ending in an abrupt angled butt joint.
--
-- A tangent is treated as an AXIS rather than a directed vector.  Its sign is
-- chosen from the endpoint chord, so the same target-road tangent works for a
-- merge or a diverge and for either end of the newly placed road.  Capping a
-- constrained handle at one third of the chord keeps a very distant user
-- control from turning into a loop after its direction is rotated.
function Fitting.ConstrainEndpointTangents(
	segment: CurveSegment.Segment,
	startTangentAxis: Vector3?,
	endTangentAxis: Vector3?
): CurveSegment.Segment
	if not startTangentAxis and not endTangentAxis then
		return segment
	end

	local p0 = segment.P0
	local p3: Vector3
	local p1: Vector3
	local p2: Vector3
	if segment.Kind == "Line" then
		p3 = segment.P1
		p1 = p0:Lerp(p3, 1 / 3)
		p2 = p0:Lerp(p3, 2 / 3)
	elseif segment.Kind == "Quadratic" then
		p3 = segment.P2 :: Vector3
		-- Exact degree elevation: a quadratic represented as a cubic follows
		-- the identical curve before either requested endpoint is constrained.
		p1 = p0 + (segment.P1 - p0) * (2 / 3)
		p2 = p3 + (segment.P1 - p3) * (2 / 3)
	else
		p3 = segment.P3 :: Vector3
		p1 = segment.P1
		p2 = segment.P2 :: Vector3
	end

	local chord = p3 - p0
	local chordLength = chord.Magnitude
	if chordLength < 1e-6 then
		return segment
	end
	local maximumHandle = chordLength / 3

	if startTangentAxis then
		local handleLength = math.min((p1 - p0).Magnitude, maximumHandle)
		if handleLength < 1e-4 then
			handleLength = maximumHandle
		end
		p1 = p0 + Fitting.OrientedTangentAxis(startTangentAxis, chord) * handleLength
	end
	if endTangentAxis then
		local handleLength = math.min((p3 - p2).Magnitude, maximumHandle)
		if handleLength < 1e-4 then
			handleLength = maximumHandle
		end
		p2 = p3 - Fitting.OrientedTangentAxis(endTangentAxis, chord) * handleLength
	end

	return CurveSegment.Cubic(p0, p1, p2, p3)
end

return Fitting
