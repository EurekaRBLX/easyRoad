--!strict
-- EasyRoad grand settings: persisted plugin-wide configuration.
--
-- These are the "grand settings" that control the style of every road the
-- plugin builds: the active region preset (US / UK / EU / JP / AU), the
-- meters-to-studs scale, superelevation behavior, snapping, and geometry
-- quality. Per-road configuration lives in RoadProfile / RoadLibrary instead.

local Keybinds = require("./Keybinds")

local kSettingsKey = "easyRoadState"

local LANGUAGE_VARIANTS = { "British", "American" }
local SPEED_UNITS = { "Kmh", "Mph" }
local LENGTH_UNITS = { "Meters", "Feet" }

export type SuperelevationMode = "Auto" | "Manual" | "Off"

-- Which English variant to use for user-facing terminology that differs
-- between them (Kerb/Curb, Pavement/Sidewalk, ...) - see Locale.lua. Purely
-- a display concern: internal data model field/kind names (CurbHeightM,
-- "Sidewalk" component kind, etc.) don't change with this setting.
export type LanguageVariant = "British" | "American"

-- Display-only measurement units (see Units.lua). Storage stays canonically
-- metric regardless: DesignSpeedKph and every *M field keep their values, so
-- switching these never changes the geometry that gets built.
export type SpeedUnit = "Kmh" | "Mph"
export type LengthUnit = "Meters" | "Feet"

export type EasyRoadSettings = {
	-- Grand style settings
	RegionId: string,
	MetersToStuds: number, -- 1 stud = 0.28m -> 3.571 studs per meter
	DesignSpeedKph: number, -- Used by auto superelevation
	SuperelevationMode: SuperelevationMode,
	ManualBankDeg: number, -- Used when SuperelevationMode == "Manual"
	-- How gradually the bank angle ramps in/out of a curve, in real-world
	-- METERS (not studs) - RoadBuilder.lua converts via MetersToStuds at
	-- build time, so this stays a constant real-world transition distance
	-- regardless of a user's own studs-per-meter scale. Previously a bare
	-- stud constant (40), which meant a user running a larger
	-- studs-per-meter ratio than the ~3.571 default got a shorter, more
	-- abrupt real-world transition for the exact same value - the whole
	-- point of storing distances in meters here instead of studs.
	SuperelevationRunoffM: number,
	AutoMarkings: boolean,
	DriveSideOverride: string, -- "Region" | "Left" | "Right"
	LanguageVariant: LanguageVariant,
	SpeedUnit: SpeedUnit,
	LengthUnit: LengthUnit,

	-- Default road
	DefaultProfileId: string,

	-- Placement behavior
	SnapRadiusStuds: number,
	GridSizeStuds: number,
	SnapToGrid: boolean,
	-- Whether placement endpoints/mid-span clicks snap onto an existing
	-- road's own end or pavement (see createRoadSession.lua's
	-- findEndpointSnap/findConnectableEndpoint/findMidSpanMatch) - on by
	-- default since that's what makes a network of roads actually connect
	-- into junctions instead of silently overlapping. Off skips all of it,
	-- for a road that's deliberately meant to run free of the existing
	-- network (an overpass with no at-grade connection, etc).
	SnapToRoad: boolean,
	ElevationStepStuds: number,
	-- Remembered so the next building session starts where the last one
	-- left off instead of always resetting to ground level.
	LastElevationStuds: number,

	-- Geometry quality / dimensions
	RoadThicknessStuds: number,
	MaxSegmentLengthStuds: number,
	PreviewMaxSegmentLengthStuds: number,

	-- Rebindable keys (see Keybinds.lua); each action may have multiple
	-- bound inputs.
	Keybinds: Keybinds.KeybindMap,

	-- Serialized user-created road profiles (managed by RoadLibrary)
	UserProfiles: { { [string]: any } },

	-- Serialized user-created region presets (managed by RegionLibrary)
	UserRegions: { { [string]: any } },
}

local function loadSettings(plugin: Plugin): EasyRoadSettings
	local raw = plugin:GetSetting(kSettingsKey) or {}
	return {
		RegionId = raw.RegionId or "UK",
		MetersToStuds = raw.MetersToStuds or 3.571,
		DesignSpeedKph = raw.DesignSpeedKph or 60,
		SuperelevationMode = raw.SuperelevationMode or "Auto",
		ManualBankDeg = raw.ManualBankDeg or 4,
		-- Default preserves the exact prior fixed behaviour (40 studs at
		-- the default 3.571 studs/meter scale, ~11.2m).
		SuperelevationRunoffM = raw.SuperelevationRunoffM or 11.2,
		AutoMarkings = if raw.AutoMarkings == nil then true else raw.AutoMarkings,
		DriveSideOverride = raw.DriveSideOverride or "Region",
		LanguageVariant = if typeof(raw.LanguageVariant) == "string"
				and table.find(LANGUAGE_VARIANTS, raw.LanguageVariant)
			then raw.LanguageVariant :: LanguageVariant
			else "British" :: LanguageVariant,
		SpeedUnit = if typeof(raw.SpeedUnit) == "string" and table.find(SPEED_UNITS, raw.SpeedUnit)
			then raw.SpeedUnit :: SpeedUnit
			else "Kmh" :: SpeedUnit,
		LengthUnit = if typeof(raw.LengthUnit) == "string" and table.find(LENGTH_UNITS, raw.LengthUnit)
			then raw.LengthUnit :: LengthUnit
			else "Meters" :: LengthUnit,
		DefaultProfileId = raw.DefaultProfileId or "builtin_two_lane",
		SnapRadiusStuds = raw.SnapRadiusStuds or 8,
		GridSizeStuds = raw.GridSizeStuds or 4,
		SnapToGrid = if raw.SnapToGrid == nil then false else raw.SnapToGrid,
		SnapToRoad = if raw.SnapToRoad == nil then true else raw.SnapToRoad,
		ElevationStepStuds = raw.ElevationStepStuds or 1,
		LastElevationStuds = raw.LastElevationStuds or 0,
		RoadThicknessStuds = raw.RoadThicknessStuds or 1,
		MaxSegmentLengthStuds = raw.MaxSegmentLengthStuds or 8,
		PreviewMaxSegmentLengthStuds = raw.PreviewMaxSegmentLengthStuds or 16,
		Keybinds = Keybinds.Sanitize(raw.Keybinds),
		UserProfiles = raw.UserProfiles or {},
		UserRegions = raw.UserRegions or {},
	}
end

local function saveSettings(plugin: Plugin, settings: EasyRoadSettings)
	plugin:SetSetting(kSettingsKey, {
		RegionId = settings.RegionId,
		MetersToStuds = settings.MetersToStuds,
		DesignSpeedKph = settings.DesignSpeedKph,
		SuperelevationMode = settings.SuperelevationMode,
		ManualBankDeg = settings.ManualBankDeg,
		SuperelevationRunoffM = settings.SuperelevationRunoffM,
		AutoMarkings = settings.AutoMarkings,
		DriveSideOverride = settings.DriveSideOverride,
		LanguageVariant = settings.LanguageVariant,
		SpeedUnit = settings.SpeedUnit,
		LengthUnit = settings.LengthUnit,
		DefaultProfileId = settings.DefaultProfileId,
		SnapRadiusStuds = settings.SnapRadiusStuds,
		GridSizeStuds = settings.GridSizeStuds,
		SnapToGrid = settings.SnapToGrid,
		SnapToRoad = settings.SnapToRoad,
		ElevationStepStuds = settings.ElevationStepStuds,
		LastElevationStuds = settings.LastElevationStuds,
		RoadThicknessStuds = settings.RoadThicknessStuds,
		MaxSegmentLengthStuds = settings.MaxSegmentLengthStuds,
		PreviewMaxSegmentLengthStuds = settings.PreviewMaxSegmentLengthStuds,
		Keybinds = settings.Keybinds,
		UserProfiles = settings.UserProfiles,
		UserRegions = settings.UserRegions,
	})
end

return {
	Load = loadSettings,
	Save = saveSettings,
}
