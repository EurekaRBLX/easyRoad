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

local Superelevation = {}

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

-- Smooth the roll along the curve so the bank develops gradually instead of
-- snapping on the instant curvature changes (a cheap stand-in for proper
-- superelevation runoff). Takes the raw per-sample rolls and box-filters
-- them over the given transition length.
function Superelevation.SmoothRolls(
	rolls: { number },
	sValues: { number },
	transitionLength: number
): { number }
	local n = #rolls
	if n <= 2 or transitionLength <= 0 then
		return rolls
	end
	local smoothed = table.create(n)
	local halfWindow = transitionLength / 2
	local lo = 1
	local hi = 1
	local sum = rolls[1]
	for i = 1, n do
		local center = sValues[i]
		-- Advance window bounds; sValues is monotonically increasing
		while hi < n and sValues[hi + 1] <= center + halfWindow do
			hi += 1
			sum += rolls[hi]
		end
		while lo < i and sValues[lo] < center - halfWindow do
			sum -= rolls[lo]
			lo += 1
		end
		smoothed[i] = sum / (hi - lo + 1)
	end
	return smoothed
end

return Superelevation
