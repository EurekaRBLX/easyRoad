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

-- Curve from a locked start tangent: the guide point is placed along the
-- start tangent, at the classic "half chord" distance which produces a
-- near-circular arc for moderate turn angles.
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

	-- Project to find the ideal guide distance: intersection of the start
	-- tangent ray with the perpendicular bisector direction gives a circular
	-- arc; fall back to half-chord when nearly straight.
	local flatTangent = Vector3.new(tangent.X, 0, tangent.Z)
	local flatChord = Vector3.new(chord.X, 0, chord.Z)
	local guideDistance = chordLength * 0.5
	if flatTangent.Magnitude > 1e-6 and flatChord.Magnitude > 1e-6 then
		local cosAngle = flatTangent.Unit:Dot(flatChord.Unit)
		-- Guide sits where tangent ray meets the chord's far half. For a
		-- circular arc through both points: d = |chord| / (2 * cos(theta))
		if cosAngle > 0.1 then
			guideDistance = math.min(chordLength / (2 * cosAngle), chordLength * 2)
		end
	end

	local guide = startPos + tangent * guideDistance
	return CurveSegment.Quadratic(startPos, guide, endPos)
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
