--!strict
-- Display-only unit conversion, the same idea as Locale.lua's British/American
-- terminology swap: the data model stays canonically METRIC everywhere
-- (DesignSpeedKph, every *WidthM / *HeightM / *LengthM field), and only
-- user-facing number fields and labels convert through here.
--
-- Keeping storage metric is deliberate, not laziness: the superelevation
-- design relationship in Geometry/Superelevation.lua (e + f = V^2 / 127R) is
-- only valid with V in km/h and R in metres, and MetersToStuds is the single
-- world-scale conversion. Converting at the edges means switching a display
-- unit can never change the geometry that gets built.
--
-- Typical use at a NumberField call site:
--   local shown, min, max = Units.LengthField(settings, widthM, 0.5, 20)
--   ... Value = shown, Min = min, Max = max,
--       OnChanged = function(v) set(Units.LengthToM(settings, v)) end

local Settings = require("./Settings")

local Units = {}

local KPH_PER_MPH = 1.609344
local KPH_PER_MPS = 3.6
local M_PER_FT = 0.3048

-- Speed ----------------------------------------------------------------------

function Units.SpeedSuffix(settings: Settings.EasyRoadSettings): string
	if settings.SpeedUnit == "StudsPerSecond" then
		return "studs/s"
	end
	return if settings.SpeedUnit == "Mph" then "mph" else "km/h"
end

-- Canonical km/h -> the number to show in the field.
function Units.SpeedFromKph(settings: Settings.EasyRoadSettings, kph: number): number
	if settings.SpeedUnit == "StudsPerSecond" then
		return kph / KPH_PER_MPS * settings.MetersToStuds
	end
	if settings.SpeedUnit == "Mph" then
		return kph / KPH_PER_MPH
	end
	return kph
end

-- A number the user typed in the field -> canonical km/h for storage.
function Units.SpeedToKph(settings: Settings.EasyRoadSettings, shown: number): number
	if settings.SpeedUnit == "StudsPerSecond" then
		return shown / settings.MetersToStuds * KPH_PER_MPS
	end
	if settings.SpeedUnit == "Mph" then
		return shown * KPH_PER_MPH
	end
	return shown
end

-- Value + bounds for a speed field, all converted together. Converting the
-- bounds matters as much as the value: a field showing mph but clamped to a
-- km/h Min/Max would silently refuse perfectly valid speeds.
function Units.SpeedField(
	settings: Settings.EasyRoadSettings,
	kph: number,
	minKph: number,
	maxKph: number
): (number, number, number)
	return Units.SpeedFromKph(settings, kph), Units.SpeedFromKph(settings, minKph), Units.SpeedFromKph(settings, maxKph)
end

-- Length ---------------------------------------------------------------------

function Units.LengthSuffix(settings: Settings.EasyRoadSettings): string
	if settings.LengthUnit == "Studs" then
		return "studs"
	end
	return if settings.LengthUnit == "Feet" then "ft" else "m"
end

-- Canonical metres -> the number to show in the field.
function Units.LengthFromM(settings: Settings.EasyRoadSettings, meters: number): number
	if settings.LengthUnit == "Studs" then
		return meters * settings.MetersToStuds
	end
	if settings.LengthUnit == "Feet" then
		return meters / M_PER_FT
	end
	return meters
end

-- A number the user typed in the field -> canonical metres for storage.
function Units.LengthToM(settings: Settings.EasyRoadSettings, shown: number): number
	if settings.LengthUnit == "Studs" then
		return shown / settings.MetersToStuds
	end
	if settings.LengthUnit == "Feet" then
		return shown * M_PER_FT
	end
	return shown
end

-- Value + bounds for a length field (see SpeedField on why bounds convert).
function Units.LengthField(
	settings: Settings.EasyRoadSettings,
	meters: number,
	minM: number,
	maxM: number
): (number, number, number)
	return Units.LengthFromM(settings, meters), Units.LengthFromM(settings, minM), Units.LengthFromM(settings, maxM)
end

-- "3.5 m" / "11.5 ft" for read-only readouts. `decimals` defaults to 1;
-- feet get one fewer decimal since a foot is a finer unit than a metre and
-- the extra digit is just noise.
function Units.FormatLength(settings: Settings.EasyRoadSettings, meters: number, decimals: number?): string
	local shown = Units.LengthFromM(settings, meters)
	local places = decimals or 1
	if settings.LengthUnit == "Feet" and not decimals then
		places = 0
	end
	return string.format("%." .. places .. "f %s", shown, Units.LengthSuffix(settings))
end

return Units
