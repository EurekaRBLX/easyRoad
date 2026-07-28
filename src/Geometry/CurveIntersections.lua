--!strict
-- Ground-plane intersections between two PolyCurves.
--
-- Roads are single line/quadratic/cubic segments today, but this works
-- through the PolyCurve API so the placement flow does not depend on that
-- implementation detail. Curves are flattened at a short arc-length step,
-- chord crossings provide stable starting guesses, and a bounded Newton
-- solve brings each guess back onto the real curves. Y is deliberately not
-- part of the solve: callers use VerticalSeparation to decide whether the
-- crossing is at grade or an over/underpass.

local PolyCurve = require("./PolyCurve")

export type Intersection = {
	StationA: number,
	StationB: number,
	Position: Vector3,
	VerticalSeparation: number,
	CrossAngleSin: number,
}

type Sample = {
	Station: number,
	Position: Vector3,
}

local SAMPLE_STEP_STUDS = 4
local MAX_SAMPLE_INTERVALS = 256
local NEWTON_ITERATIONS = 8
local MAX_REFINED_ERROR_STUDS = 0.35
local MIN_CROSS_ANGLE_SIN = 0.025
local STATION_DEDUP_STUDS = 0.75

local CurveIntersections = {}

local function crossXZ(a: Vector3, b: Vector3): number
	return a.X * b.Z - a.Z * b.X
end

local function horizontalMagnitude(v: Vector3): number
	return math.sqrt(v.X * v.X + v.Z * v.Z)
end

local function sampleCurve(curve: PolyCurve.PolyCurve): { Sample }
	local intervalCount = math.clamp(math.ceil(curve.Length / SAMPLE_STEP_STUDS), 1, MAX_SAMPLE_INTERVALS)
	local samples: { Sample } = table.create(intervalCount + 1)
	for i = 0, intervalCount do
		local station = curve.Length * i / intervalCount
		table.insert(samples, {
			Station = station,
			Position = curve:PosAt(station),
		})
	end
	return samples
end

local function sampleBounds(samples: { Sample }): (number, number, number, number)
	local minX = math.huge
	local maxX = -math.huge
	local minZ = math.huge
	local maxZ = -math.huge
	for _, sample in samples do
		local pos = sample.Position
		minX = math.min(minX, pos.X)
		maxX = math.max(maxX, pos.X)
		minZ = math.min(minZ, pos.Z)
		maxZ = math.max(maxZ, pos.Z)
	end
	return minX, maxX, minZ, maxZ
end

local function boundsOverlap(
	aMinX: number,
	aMaxX: number,
	aMinZ: number,
	aMaxZ: number,
	bMinX: number,
	bMaxX: number,
	bMinZ: number,
	bMaxZ: number
): boolean
	return aMaxX >= bMinX and bMaxX >= aMinX and aMaxZ >= bMinZ and bMaxZ >= aMinZ
end

local function chordIntersection(a0: Vector3, a1: Vector3, b0: Vector3, b1: Vector3): (number?, number?)
	local aDirection = a1 - a0
	local bDirection = b1 - b0
	local denominator = crossXZ(aDirection, bDirection)
	if math.abs(denominator) < 1e-7 then
		return nil, nil
	end
	local between = b0 - a0
	local fractionA = crossXZ(between, bDirection) / denominator
	local fractionB = crossXZ(between, aDirection) / denominator
	local epsilon = 1e-5
	if fractionA < -epsilon or fractionA > 1 + epsilon or fractionB < -epsilon or fractionB > 1 + epsilon then
		return nil, nil
	end
	return math.clamp(fractionA, 0, 1), math.clamp(fractionB, 0, 1)
end

local function refineStations(
	curveA: PolyCurve.PolyCurve,
	curveB: PolyCurve.PolyCurve,
	stationA: number,
	stationB: number,
	minA: number,
	maxA: number,
	minB: number,
	maxB: number
): (number, number)
	for _ = 1, NEWTON_ITERATIONS do
		local posA = curveA:PosAt(stationA)
		local posB = curveB:PosAt(stationB)
		local tangentA = curveA:TangentAt(stationA)
		local tangentB = curveB:TangentAt(stationB)
		local difference = posA - posB

		-- [ A'x  -B'x ] [deltaA] = [-difference.x]
		-- [ A'z  -B'z ] [deltaB]   [-difference.z]
		local determinant = tangentA.X * -tangentB.Z - -tangentB.X * tangentA.Z
		if math.abs(determinant) < 1e-8 then
			break
		end
		local rightX = -difference.X
		local rightZ = -difference.Z
		local deltaA = (rightX * -tangentB.Z - -tangentB.X * rightZ) / determinant
		local deltaB = (tangentA.X * rightZ - rightX * tangentA.Z) / determinant
		stationA = math.clamp(stationA + deltaA, minA, maxA)
		stationB = math.clamp(stationB + deltaB, minB, maxB)
		if math.abs(deltaA) + math.abs(deltaB) < 1e-4 then
			break
		end
	end
	return stationA, stationB
end

local function crossAngleSin(
	curveA: PolyCurve.PolyCurve,
	stationA: number,
	curveB: PolyCurve.PolyCurve,
	stationB: number
)
	local tangentA = curveA:TangentAt(stationA)
	local tangentB = curveB:TangentAt(stationB)
	local magnitudeA = horizontalMagnitude(tangentA)
	local magnitudeB = horizontalMagnitude(tangentB)
	if magnitudeA < 1e-8 or magnitudeB < 1e-8 then
		return 0
	end
	return math.abs(crossXZ(tangentA, tangentB)) / (magnitudeA * magnitudeB)
end

local function alreadyIncluded(intersections: { Intersection }, stationA: number, stationB: number): boolean
	for _, intersection in intersections do
		if
			math.abs(intersection.StationA - stationA) <= STATION_DEDUP_STUDS
			and math.abs(intersection.StationB - stationB) <= STATION_DEDUP_STUDS
		then
			return true
		end
	end
	return false
end

function CurveIntersections.Find(curveA: PolyCurve.PolyCurve, curveB: PolyCurve.PolyCurve): { Intersection }
	if curveA.Length < 1e-3 or curveB.Length < 1e-3 then
		return {}
	end
	local samplesA = sampleCurve(curveA)
	local samplesB = sampleCurve(curveB)
	local aMinX, aMaxX, aMinZ, aMaxZ = sampleBounds(samplesA)
	local bMinX, bMaxX, bMinZ, bMaxZ = sampleBounds(samplesB)
	if not boundsOverlap(aMinX, aMaxX, aMinZ, aMaxZ, bMinX, bMaxX, bMinZ, bMaxZ) then
		return {}
	end

	local intersections: { Intersection } = {}
	for aIndex = 1, #samplesA - 1 do
		local a0 = samplesA[aIndex]
		local a1 = samplesA[aIndex + 1]
		local aChordMinX = math.min(a0.Position.X, a1.Position.X)
		local aChordMaxX = math.max(a0.Position.X, a1.Position.X)
		local aChordMinZ = math.min(a0.Position.Z, a1.Position.Z)
		local aChordMaxZ = math.max(a0.Position.Z, a1.Position.Z)
		for bIndex = 1, #samplesB - 1 do
			local b0 = samplesB[bIndex]
			local b1 = samplesB[bIndex + 1]
			if
				not boundsOverlap(
					aChordMinX,
					aChordMaxX,
					aChordMinZ,
					aChordMaxZ,
					math.min(b0.Position.X, b1.Position.X),
					math.max(b0.Position.X, b1.Position.X),
					math.min(b0.Position.Z, b1.Position.Z),
					math.max(b0.Position.Z, b1.Position.Z)
				)
			then
				continue
			end
			local fractionA, fractionB = chordIntersection(a0.Position, a1.Position, b0.Position, b1.Position)
			if not fractionA or not fractionB then
				continue
			end
			local stationA = a0.Station + (a1.Station - a0.Station) * fractionA
			local stationB = b0.Station + (b1.Station - b0.Station) * fractionB
			stationA, stationB =
				refineStations(curveA, curveB, stationA, stationB, a0.Station, a1.Station, b0.Station, b1.Station)
			local posA = curveA:PosAt(stationA)
			local posB = curveB:PosAt(stationB)
			local horizontalError = horizontalMagnitude(posA - posB)
			local angleSin = crossAngleSin(curveA, stationA, curveB, stationB)
			if
				horizontalError <= MAX_REFINED_ERROR_STUDS
				and angleSin >= MIN_CROSS_ANGLE_SIN
				and not alreadyIncluded(intersections, stationA, stationB)
			then
				table.insert(intersections, {
					StationA = stationA,
					StationB = stationB,
					Position = (posA + posB) * 0.5,
					VerticalSeparation = math.abs(posA.Y - posB.Y),
					CrossAngleSin = angleSin,
				})
			end
		end
	end
	table.sort(intersections, function(a, b)
		return a.StationA < b.StationA
	end)
	return intersections
end

return CurveIntersections
