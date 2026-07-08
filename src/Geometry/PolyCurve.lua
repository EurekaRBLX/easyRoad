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
	Slice: (self: PolyCurve, s0: number, s1: number) -> PolyCurve,
	ClosestS: (self: PolyCurve, point: Vector3) -> number,
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

-- Coarse sample + local refine search for the s (distance along the curve)
-- whose position is closest to `point` - used to turn a 3D click into a
-- station along an already-placed road (e.g. where to insert a bus bay).
-- Shared between PolyCurve and SlicedPolyCurve (both call it with their own
-- posAt/length), so a slice's search stays confined to its own range.
local function closestSSearch(posAt: (s: number) -> Vector3, length: number, point: Vector3): number
	if length < 1e-3 then
		return 0
	end
	local coarseSteps = 40
	local bestS = 0
	local bestDist = math.huge
	for i = 0, coarseSteps do
		local s = length * i / coarseSteps
		local dist = (posAt(s) - point).Magnitude
		if dist < bestDist then
			bestDist = dist
			bestS = s
		end
	end
	-- Local refine: repeatedly narrow a window around the best sample.
	local window = length / coarseSteps
	for _ = 1, 12 do
		local lo = math.max(0, bestS - window)
		local hi = math.min(length, bestS + window)
		for i = 0, 10 do
			local s = lo + (hi - lo) * i / 10
			local dist = (posAt(s) - point).Magnitude
			if dist < bestDist then
				bestDist = dist
				bestS = s
			end
		end
		window /= 2
	end
	return bestS
end

function PolyCurve.ClosestS(self: PolyCurve, point: Vector3): number
	return closestSSearch(function(s)
		return self:PosAt(s)
	end, self.Length, point)
end

-- A read-only view of a sub-range [s0, s1] of an existing curve, reindexed
-- so its own s runs from 0 to (s1 - s0) - used to build a small piece of
-- geometry (e.g. one taper of a bus bay) by handing RoadBuilder.Build a
-- "curve" that already knows the sub-range, with zero changes to
-- RoadBuilder itself. Position/tangent/curvature/frame queries just add
-- the offset and delegate to the base curve - no new segment data, so this
-- is exact, not an approximation.
local SlicedPolyCurve = {}
SlicedPolyCurve.__index = SlicedPolyCurve

function SlicedPolyCurve.PosAt(self, s: number): Vector3
	return self._base:PosAt(self._offset + s)
end
function SlicedPolyCurve.TangentAt(self, s: number): Vector3
	return self._base:TangentAt(self._offset + s)
end
function SlicedPolyCurve.CurvatureAt(self, s: number): number
	return self._base:CurvatureAt(self._offset + s)
end
function SlicedPolyCurve.FrameAt(self, s: number, roll: number?): CFrame
	return self._base:FrameAt(self._offset + s, roll)
end
function SlicedPolyCurve.Slice(self, s0: number, s1: number): PolyCurve
	return (self._base :: PolyCurve):Slice(self._offset + s0, self._offset + s1)
end
function SlicedPolyCurve.ClosestS(self, point: Vector3): number
	return closestSSearch(function(s)
		return self:PosAt(s)
	end, self.Length, point)
end

function PolyCurve.Slice(self: PolyCurve, s0: number, s1: number): PolyCurve
	s0 = math.clamp(s0, 0, self.Length)
	s1 = math.clamp(s1, 0, self.Length)
	local sliced = setmetatable({
		Segments = self.Segments,
		CumulativeLengths = self.CumulativeLengths,
		Length = math.max(s1 - s0, 0),
		_base = self,
		_offset = s0,
	}, SlicedPolyCurve)
	return (sliced :: any) :: PolyCurve
end

return PolyCurve
