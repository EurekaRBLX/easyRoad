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
function Fitting.CurveFromTangent(
	startPos: Vector3,
	startTangent: Vector3,
	endPos: Vector3
): CurveSegment.Segment
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
function Fitting.StraightFromTangent(
	startPos: Vector3,
	startTangent: Vector3,
	endPos: Vector3
): CurveSegment.Segment
	local tangent = startTangent.Unit
	local distance = math.max((endPos - startPos):Dot(tangent), 1)
	return CurveSegment.Line(startPos, startPos + tangent * distance)
end

return Fitting
