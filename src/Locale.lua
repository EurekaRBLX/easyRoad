--!strict
-- Display-only British/American English terminology swap. Internal data
-- model names (RegionStyles.CurbHeightM, RoadProfile.KerbRestriction, the
-- "Sidewalk" component Kind, ...) stay as they are regardless of this
-- setting - only user-facing label text should ever call through here.

local Settings = require("./Settings")

local Locale = {}

local TERMS: { [string]: { British: string, American: string } } = {
	Kerb = { British = "Kerb", American = "Curb" },
	KerbLines = { British = "Kerb lines", American = "Curb lines" },
	KerbLineOffset = { British = "Kerb line offset", American = "Curb line offset" },
	KerbHeight = { British = "Kerb height", American = "Curb height" },
	Pavement = { British = "Pavement", American = "Sidewalk" },
	PavementWidth = { British = "Pavement width", American = "Sidewalk width" },
	CarPark = { British = "Car park", American = "Parking lot" },
}

-- Term(settings, "Kerb") -> "Kerb" or "Curb" depending on
-- settings.LanguageVariant.
function Locale.Term(settings: Settings.EasyRoadSettings, key: string): string
	local entry = TERMS[key]
	if not entry then
		return key
	end
	return if settings.LanguageVariant == "American" then entry.American else entry.British
end

return Locale
