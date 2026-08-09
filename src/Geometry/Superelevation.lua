--!strict
-- Superelevation (banking) computation.
--
-- In "Auto" mode the bank is derived from the standard highway design
-- relationship:
--
--     e + f = V^2 / (127 * R)
--
-- where e is the superelevation rate (rise/run), f the side friction factor,
-- V the design speed in km/h, and R the curve radius in meters. We solve for
-- e, clamp it to the region's maximum, and never bank below zero (no
-- negative camber). The bank angle is atan(e), signed to raise the outside
-- edge of the turn.
--
-- In "Manual" mode a fixed user-set angle is applied, signed by curve
-- direction. In "Off" mode roads are always flat.

local Settings = require("../Settings")
local RegionStyles = require("../RegionStyles")

local GRAVITY_FUDGE = 127 -- (3.6 km/h per m/s)^2 / 9.81, from the metric design formula
local PROFILE_MAX_SPACING_M = 2
local PROFILE_MIN_SPACING_M = 0.25
local PROFILE_LINEARITY_TOLERANCE_RAD = math.rad(0.05)
local PROFILE_MAX_REFINEMENT_DEPTH = 4

local Superelevation = {}

export type RollProfile = {
	Length: number,
	Stations: { number },
	Rolls: { number },
}

-- Side friction factor by design speed (approximation of AASHTO table)
local function sideFriction(speedKph: number): number
	if speedKph <= 30 then
		return 0.17
	elseif speedKph <= 50 then
		return 0.16
	elseif speedKph <= 80 then
		return 0.14
	elseif speedKph <= 100 then
		return 0.12
	else
		return 0.10
	end
end

-- Compute the signed roll angle (radians) for a given signed curvature.
--
-- curvaturePerStud: signed ground-plane curvature in 1/studs
--   (positive = left turn)
-- Returns a roll for PolyCurve.FrameAt: positive raises the right edge
-- (outside of a left turn).
function Superelevation.RollAt(
	curvaturePerStud: number,
	settings: Settings.EasyRoadSettings,
	style: RegionStyles.RegionStyle
): number
	if settings.SuperelevationMode == "Off" then
		return 0
	end

	local sign = if curvaturePerStud >= 0 then 1 else -1
	local k = math.abs(curvaturePerStud)
	if k < 1e-6 then
		return 0
	end

	if settings.SuperelevationMode == "Manual" then
		return sign * math.rad(settings.ManualBankDeg)
	end

	-- Auto mode: convert curvature to a radius in meters
	local radiusStuds = 1 / k
	local radiusM = radiusStuds / settings.MetersToStuds
	local v = settings.DesignSpeedKph
	local demand = (v * v) / (GRAVITY_FUDGE * radiusM)
	local e = demand - sideFriction(v)
	e = math.clamp(e, 0, style.MaxSuperelevation)
	return sign * math.atan(e)
end

local function intervalIndex(sValues: { number }, s: number): number
	local lo = 1
	local hi = #sValues
	while hi - lo > 1 do
		local mid = math.floor((lo + hi) / 2)
		if sValues[mid] <= s then
			lo = mid
		else
			hi = mid
		end
	end
	return lo
end

local function linearValueAt(sValues: { number }, values: { number }, s: number): number
	local n = #sValues
	if n == 0 then
		return 0
	elseif n == 1 or s <= sValues[1] then
		return values[1]
	elseif s >= sValues[n] then
		return values[n]
	end
	local lo = intervalIndex(sValues, s)
	local span = sValues[lo + 1] - sValues[lo]
	if span <= 1e-9 then
		return values[lo]
	end
	local alpha = (s - sValues[lo]) / span
	return values[lo] + (values[lo + 1] - values[lo]) * alpha
end

local function integralValueAt(sValues: { number }, values: { number }, prefixAreas: { number }, s: number): number
	local n = #sValues
	if n <= 1 or s <= sValues[1] then
		return 0
	elseif s >= sValues[n] then
		return prefixAreas[n]
	end
	local lo = intervalIndex(sValues, s)
	local span = sValues[lo + 1] - sValues[lo]
	if span <= 1e-9 then
		return prefixAreas[lo]
	end
	local distance = s - sValues[lo]
	local slope = (values[lo + 1] - values[lo]) / span
	return prefixAreas[lo] + values[lo] * distance + slope * distance * distance / 2
end

-- Smooth the roll along the curve so the bank develops gradually instead of
-- snapping on the instant curvature changes (a cheap stand-in for proper
-- superelevation runoff). Treats the samples as one piecewise-linear signal
-- and integrates that signal over the moving window. This makes the result
-- depend on arc length rather than on how densely a caller happened to sample
-- one portion of the curve.
function Superelevation.SmoothRolls(rolls: { number }, sValues: { number }, transitionLength: number): { number }
	local n = #rolls
	if n <= 1 or transitionLength <= 0 or #sValues ~= n then
		return rolls
	end
	local prefixAreas = table.create(n)
	prefixAreas[1] = 0
	for i = 1, n - 1 do
		local span = math.max(sValues[i + 1] - sValues[i], 0)
		prefixAreas[i + 1] = prefixAreas[i] + (rolls[i] + rolls[i + 1]) * span / 2
	end
	local smoothed = table.create(n)
	local halfWindow = transitionLength / 2
	for i = 1, n do
		local center = sValues[i]
		local windowStart = math.max(sValues[1], center - halfWindow)
		local windowEnd = math.min(sValues[n], center + halfWindow)
		local windowLength = windowEnd - windowStart
		if windowLength <= 1e-9 then
			smoothed[i] = rolls[i]
		else
			local areaStart = integralValueAt(sValues, rolls, prefixAreas, windowStart)
			local areaEnd = integralValueAt(sValues, rolls, prefixAreas, windowEnd)
			smoothed[i] = (areaEnd - areaStart) / windowLength
		end
	end
	return smoothed
end

local function appendAdaptiveInterval(
	stations: { number },
	rolls: { number },
	s0: number,
	r0: number,
	s1: number,
	r1: number,
	minimumSpacing: number,
	depth: number,
	rawRollAt: (number) -> number
)
	local span = s1 - s0
	local mid = (s0 + s1) / 2
	local quarter = s0 + span / 4
	local threeQuarter = s0 + span * 3 / 4
	local rMid = rawRollAt(mid)
	local rQuarter = rawRollAt(quarter)
	local rThreeQuarter = rawRollAt(threeQuarter)
	local linearQuarter = r0 + (r1 - r0) * 0.25
	local linearMid = (r0 + r1) / 2
	local linearThreeQuarter = r0 + (r1 - r0) * 0.75
	local linearityError = math.max(
		math.abs(rQuarter - linearQuarter),
		math.abs(rMid - linearMid),
		math.abs(rThreeQuarter - linearThreeQuarter)
	)
	if
		depth < PROFILE_MAX_REFINEMENT_DEPTH
		and span > minimumSpacing * 2
		and linearityError > PROFILE_LINEARITY_TOLERANCE_RAD
	then
		appendAdaptiveInterval(stations, rolls, s0, r0, mid, rMid, minimumSpacing, depth + 1, rawRollAt)
		appendAdaptiveInterval(stations, rolls, mid, rMid, s1, r1, minimumSpacing, depth + 1, rawRollAt)
		return
	end
	table.insert(stations, s1)
	table.insert(rolls, r1)
end

-- Builds the authoritative roll curve independently of RoadBuilder's mesh
-- stations. A fixed real-world maximum spacing makes preview/final builds use
-- the same signal, while local refinement preserves sharp changes in curvature
-- without globally increasing the control-point count.
function Superelevation.BuildProfile(
	length: number,
	curvatureAt: (number) -> number,
	settings: Settings.EasyRoadSettings,
	style: RegionStyles.RegionStyle
): RollProfile
	length = math.max(length, 0)
	if length <= 1e-6 then
		return { Length = 0, Stations = { 0 }, Rolls = { 0 } }
	end
	if settings.SuperelevationMode == "Off" then
		return { Length = length, Stations = { 0, length }, Rolls = { 0, 0 } }
	end

	local function rawRollAt(station: number): number
		return Superelevation.RollAt(curvatureAt(math.clamp(station, 0, length)), settings, style)
	end

	local configuredRunoff = math.max(settings.SuperelevationRunoffM * settings.MetersToStuds, 0)
	local runoffLength = math.min(configuredRunoff, length * 0.3)
	local maximumSpacing = math.max(PROFILE_MAX_SPACING_M * settings.MetersToStuds, 0.1)
	local minimumSpacing = math.max(PROFILE_MIN_SPACING_M * settings.MetersToStuds, 0.05)
	-- The runoff multiplier is applied only after smoothing. Its slope changes
	-- at these three positions, so they must exist in the raw control grid even
	-- when the entire curve is shorter than the normal 2 m profile spacing.
	-- Without them a short constant-radius curve had only two endpoint samples;
	-- tapering both endpoints to zero then made the whole interpolated profile
	-- flat instead of leaving the intended 40% full-bank middle.
	local rawControlStations = { 0, runoffLength, length / 2, length - runoffLength, length }
	local station = maximumSpacing
	while station < length do
		table.insert(rawControlStations, station)
		station += maximumSpacing
	end
	table.sort(rawControlStations)
	local baseStations = { rawControlStations[1] }
	for i = 2, #rawControlStations do
		if rawControlStations[i] - baseStations[#baseStations] > 1e-7 then
			table.insert(baseStations, rawControlStations[i])
		end
	end

	local stations = { baseStations[1] }
	local rolls = { rawRollAt(0) }
	local s0 = baseStations[1]
	local r0 = rolls[1]
	for i = 2, #baseStations do
		local s1 = baseStations[i]
		local r1 = rawRollAt(s1)
		appendAdaptiveInterval(stations, rolls, s0, r0, s1, r1, minimumSpacing, 0, rawRollAt)
		s0 = s1
		r0 = r1
	end

	rolls = Superelevation.SmoothRolls(rolls, stations, runoffLength)
	if runoffLength > 1e-3 then
		for i, station in stations do
			local taper = math.min(1, station / runoffLength, (length - station) / runoffLength)
			rolls[i] *= math.max(taper, 0)
		end
	end
	return { Length = length, Stations = stations, Rolls = rolls }
end

function Superelevation.RollAtProfile(profile: RollProfile, station: number): number
	return linearValueAt(profile.Stations, profile.Rolls, math.clamp(station, 0, profile.Length))
end

return Superelevation
