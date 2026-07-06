--!strict
-- A PolyCurve is a chain of curve segments evaluated by total distance along
-- the chain (s from 0 to Length). This is what the mesh builder consumes:
-- it asks the curve for a frame (CFrame) at any s, with an optional roll
-- (superelevation bank) applied about the tangent.

local CurveSegment = require("./CurveSegment")

export type PolyCurve = {
	Segments: { CurveSegment.Segment },
	CumulativeLengths: { number }, -- CumulativeLengths[i] = length before segment i
	Length: number,

	PosAt: (self: PolyCurve, s: number) -> Vector3,
	TangentAt: (self: PolyCurve, s: number) -> Vector3,
	CurvatureAt: (self: PolyCurve, s: number) -> number,
	FrameAt: (self: PolyCurve, s: number, roll: number?) -> CFrame,
}

local PolyCurve = {}
PolyCurve.__index = PolyCurve

function PolyCurve.new(segments: { CurveSegment.Segment }): PolyCurve
	assert(#segments > 0, "PolyCurve needs at least one segment")
	local cumulative = { 0 }
	local total = 0
	for i, segment in segments do
		cumulative[i] = total
		total += segment.Length
	end
	local self = setmetatable({
		Segments = segments,
		CumulativeLengths = cumulative,
		Length = total,
	}, PolyCurve)
	return (self :: any) :: PolyCurve
end

-- Find (segment, local s) for a global s
local function locate(self: PolyCurve, s: number): (CurveSegment.Segment, number)
	local segments = self.Segments
	local n = #segments
	if s <= 0 then
		return segments[1], 0
	elseif s >= self.Length then
		return segments[n], segments[n].Length
	end
	for i = n, 1, -1 do
		local start = self.CumulativeLengths[i]
		if s >= start then
			return segments[i], s - start
		end
	end
	return segments[1], 0
end

function PolyCurve.PosAt(self: PolyCurve, s: number): Vector3
	local segment, localS = locate(self, s)
	return CurveSegment.PosAtS(segment, localS)
end

function PolyCurve.TangentAt(self: PolyCurve, s: number): Vector3
	local segment, localS = locate(self, s)
	return CurveSegment.TangentAtS(segment, localS)
end

function PolyCurve.CurvatureAt(self: PolyCurve, s: number): number
	local segment, localS = locate(self, s)
	return CurveSegment.CurvatureAtS(segment, localS)
end

-- Build a frame at distance s along the curve:
--   * Position on the curve
--   * LookVector along the tangent (including grade)
--   * Optional roll (radians) about the tangent for superelevation.
--     Positive roll raises the right-hand edge of the road surface, which
--     banks correctly into a left-hand (positive curvature) turn.
function PolyCurve.FrameAt(self: PolyCurve, s: number, roll: number?): CFrame
	local pos = self:PosAt(s)
	local tangent = self:TangentAt(s)

	-- Guard against near-vertical tangents (roads should never be vertical,
	-- but preview states can be degenerate)
	local flat = Vector3.new(tangent.X, 0, tangent.Z)
	if flat.Magnitude < 1e-6 then
		tangent = Vector3.zAxis
	end

	local frame = CFrame.lookAt(pos, pos + tangent, Vector3.yAxis)
	if roll and roll ~= 0 then
		frame = frame * CFrame.Angles(0, 0, roll)
	end
	return frame
end

return PolyCurve
