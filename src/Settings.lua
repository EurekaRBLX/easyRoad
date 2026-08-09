--!strict
-- EasyRoad grand settings: persisted plugin-wide configuration.
--
-- These are the "grand settings" that control the style of every road the
-- plugin builds: the active region preset (US / UK / EU / JP / AU), the
-- meters-to-studs scale, superelevation behavior, snapping, and geometry
-- quality. Per-road configuration lives in RoadProfile / RoadLibrary instead.

local Keybinds = require("./Keybinds")
local StructureMaterials = require("./StructureMaterials")

local kSettingsKey = "easyRoadState"
local BACKUP_FORMAT = "easyRoad-data"
local BACKUP_VERSION = 1
local ONBOARDING_VERSION = 1
local MAX_BACKUP_BYTES = 2 * 1024 * 1024

local LANGUAGE_VARIANTS = { "British", "American" }
local SPEED_UNITS = { "Kmh", "Mph", "StudsPerSecond" }
local LENGTH_UNITS = { "Meters", "Feet", "Studs" }

export type SuperelevationMode = "Auto" | "Manual" | "Off"
export type SnapReference = "Centre" | "LeftRoadwayEdge" | "RightRoadwayEdge"

-- Which English variant to use for user-facing terminology that differs
-- between them (Kerb/Curb, Pavement/Sidewalk, ...) - see Locale.lua. Purely
-- a display concern: internal data model field/kind names (CurbHeightM,
-- "Sidewalk" component kind, etc.) don't change with this setting.
export type LanguageVariant = "British" | "American"

-- Display-only measurement units (see Units.lua). Storage stays canonically
-- metric regardless: DesignSpeedKph and every *M field keep their values, so
-- switching these never changes the geometry that gets built.
export type SpeedUnit = "Kmh" | "Mph" | "StudsPerSecond"
export type LengthUnit = "Meters" | "Feet" | "Studs"

export type EasyRoadSettings = {
	-- First-run setup is versioned so future releases can introduce a new,
	-- materially different setup without showing the same wizard repeatedly.
	OnboardingVersion: number,

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
	-- Lateral reference on an existing road used by magnetic endpoint and
	-- mid-span snapping. Left/right follow that road's stored start -> end
	-- profile orientation; topology still connects to its centreline station.
	SnapReference: SnapReference,
	-- Deflect roundabout entries: each mouth's entry arm merges closer in to the
	-- mouth than its exit arm peels off, so traffic joining the ring is turned
	-- harder than traffic leaving (see RoundaboutBuilder). Off = a symmetric pair.
	RoundaboutEntryCurve: boolean,
	ElevationStepStuds: number,
	-- Remembered so the next building session starts where the last one
	-- left off instead of always resetting to ground level.
	LastElevationStuds: number,

	-- Geometry quality / dimensions
	RoadThicknessStuds: number,
	MaxSegmentLengthStuds: number,
	PreviewMaxSegmentLengthStuds: number,

	-- Defaults copied into each new procedural viaduct/tunnel. Existing roads
	-- keep their serialized values when these defaults change.
	StructureConcreteColorHex: string,
	StructureBaseMaterial: StructureMaterials.MaterialName,
	ViaductWallColorHex: string,
	ViaductWallMaterial: StructureMaterials.MaterialName,
	TunnelWallColorHex: string,
	TunnelWallMaterial: StructureMaterials.MaterialName,
	TunnelRoofColorHex: string,
	TunnelRoofMaterial: StructureMaterials.MaterialName,
	StructureInterfaceOverlapM: number,
	ViaductParapetGapM: number,
	ViaductParapetHeightM: number,
	TunnelWallClearanceM: number,
	TunnelVerticalClearanceM: number,
	ElevatedMedianConcrete: boolean,
	ParallelRoadwayGapM: number,

	-- Rebindable keys (see Keybinds.lua); each action may have multiple
	-- bound inputs.
	Keybinds: Keybinds.KeybindMap,

	-- Serialized user-created road profiles (managed by RoadLibrary)
	UserProfiles: { { [string]: any } },

	-- Serialized user-created region presets (managed by RegionLibrary)
	UserRegions: { { [string]: any } },
}

local function numberOr(raw: any, key: string, fallback: number, minimum: number, maximum: number): number
	local value = raw[key]
	if typeof(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return math.clamp(value, minimum, maximum)
end

local function stringOr(raw: any, key: string, fallback: string): string
	return if typeof(raw[key]) == "string" then raw[key] else fallback
end

local function booleanOr(raw: any, key: string, fallback: boolean): boolean
	return if typeof(raw[key]) == "boolean" then raw[key] else fallback
end

local function enumOr(raw: any, key: string, allowed: { string }, fallback: string): string
	local value = raw[key]
	return if typeof(value) == "string" and table.find(allowed, value) then value else fallback
end

local function arrayOrEmpty(value: any): { { [string]: any } }
	return if typeof(value) == "table" then value :: any else {}
end

-- One sanitizer owns both ordinary plugin loads and JSON restores. Besides
-- making old settings forward-compatible, this is the trust boundary for a
-- pasted backup: wrong types and out-of-range numbers never reach geometry.
local function sanitizeSettings(rawValue: any): EasyRoadSettings
	local raw = if typeof(rawValue) == "table" then rawValue else {}
	return {
		OnboardingVersion = math.floor(numberOr(raw, "OnboardingVersion", 0, 0, ONBOARDING_VERSION)),
		RegionId = stringOr(raw, "RegionId", "UK"),
		MetersToStuds = numberOr(raw, "MetersToStuds", 3.571, 0.5, 20),
		DesignSpeedKph = numberOr(raw, "DesignSpeedKph", 60, 10, 200),
		SuperelevationMode = enumOr(raw, "SuperelevationMode", { "Auto", "Manual", "Off" }, "Auto") :: SuperelevationMode,
		ManualBankDeg = numberOr(raw, "ManualBankDeg", 4, 0, 30),
		-- Default preserves the exact prior fixed behaviour (40 studs at
		-- the default 3.571 studs/meter scale, ~11.2m).
		SuperelevationRunoffM = numberOr(raw, "SuperelevationRunoffM", 11.2, 2, 30),
		AutoMarkings = booleanOr(raw, "AutoMarkings", true),
		DriveSideOverride = enumOr(raw, "DriveSideOverride", { "Region", "Left", "Right" }, "Region"),
		LanguageVariant = enumOr(raw, "LanguageVariant", LANGUAGE_VARIANTS, "British") :: LanguageVariant,
		SpeedUnit = enumOr(raw, "SpeedUnit", SPEED_UNITS, "Kmh") :: SpeedUnit,
		LengthUnit = enumOr(raw, "LengthUnit", LENGTH_UNITS, "Meters") :: LengthUnit,
		DefaultProfileId = stringOr(raw, "DefaultProfileId", "builtin_two_lane"),
		SnapRadiusStuds = numberOr(raw, "SnapRadiusStuds", 8, 0, 64),
		GridSizeStuds = numberOr(raw, "GridSizeStuds", 4, 0.5, 64),
		SnapToGrid = booleanOr(raw, "SnapToGrid", false),
		SnapToRoad = booleanOr(raw, "SnapToRoad", true),
		SnapReference = enumOr(raw, "SnapReference", { "Centre", "LeftRoadwayEdge", "RightRoadwayEdge" }, "Centre") :: SnapReference,
		RoundaboutEntryCurve = booleanOr(raw, "RoundaboutEntryCurve", true),
		ElevationStepStuds = numberOr(raw, "ElevationStepStuds", 1, 0.25, 32),
		LastElevationStuds = numberOr(raw, "LastElevationStuds", 0, -100000, 100000),
		RoadThicknessStuds = numberOr(raw, "RoadThicknessStuds", 1, 0.1, 16),
		MaxSegmentLengthStuds = numberOr(raw, "MaxSegmentLengthStuds", 8, 2, 64),
		PreviewMaxSegmentLengthStuds = numberOr(raw, "PreviewMaxSegmentLengthStuds", 16, 2, 128),
		StructureConcreteColorHex = if typeof(raw.StructureConcreteColorHex) == "string"
			then raw.StructureConcreteColorHex
			else "#696B70",
		StructureBaseMaterial = StructureMaterials.Sanitize(raw.StructureBaseMaterial),
		ViaductWallColorHex = if typeof(raw.ViaductWallColorHex) == "string"
			then raw.ViaductWallColorHex
			elseif typeof(raw.StructureConcreteColorHex) == "string" then raw.StructureConcreteColorHex
			else "#696B70",
		ViaductWallMaterial = StructureMaterials.Sanitize(raw.ViaductWallMaterial),
		TunnelWallColorHex = if typeof(raw.TunnelWallColorHex) == "string"
			then raw.TunnelWallColorHex
			elseif typeof(raw.StructureConcreteColorHex) == "string" then raw.StructureConcreteColorHex
			else "#696B70",
		TunnelWallMaterial = StructureMaterials.Sanitize(raw.TunnelWallMaterial),
		TunnelRoofColorHex = if typeof(raw.TunnelRoofColorHex) == "string"
			then raw.TunnelRoofColorHex
			elseif typeof(raw.StructureConcreteColorHex) == "string" then raw.StructureConcreteColorHex
			else "#696B70",
		TunnelRoofMaterial = StructureMaterials.Sanitize(raw.TunnelRoofMaterial),
		StructureInterfaceOverlapM = numberOr(raw, "StructureInterfaceOverlapM", 0.2, 0, 2),
		ViaductParapetGapM = numberOr(raw, "ViaductParapetGapM", 0, 0, 5),
		ViaductParapetHeightM = numberOr(raw, "ViaductParapetHeightM", 1.2, 0.2, 5),
		TunnelWallClearanceM = numberOr(raw, "TunnelWallClearanceM", 0.75, 0, 10),
		TunnelVerticalClearanceM = numberOr(raw, "TunnelVerticalClearanceM", 6, 2, 12),
		ElevatedMedianConcrete = booleanOr(raw, "ElevatedMedianConcrete", true),
		ParallelRoadwayGapM = numberOr(raw, "ParallelRoadwayGapM", 2, 0, 50),
		Keybinds = Keybinds.Sanitize(raw.Keybinds),
		UserProfiles = arrayOrEmpty(raw.UserProfiles),
		UserRegions = arrayOrEmpty(raw.UserRegions),
	}
end

local function serializeSettings(settings: EasyRoadSettings): { [string]: any }
	return {
		OnboardingVersion = settings.OnboardingVersion,
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
		SnapReference = settings.SnapReference,
		RoundaboutEntryCurve = settings.RoundaboutEntryCurve,
		ElevationStepStuds = settings.ElevationStepStuds,
		LastElevationStuds = settings.LastElevationStuds,
		RoadThicknessStuds = settings.RoadThicknessStuds,
		MaxSegmentLengthStuds = settings.MaxSegmentLengthStuds,
		PreviewMaxSegmentLengthStuds = settings.PreviewMaxSegmentLengthStuds,
		StructureConcreteColorHex = settings.StructureConcreteColorHex,
		StructureBaseMaterial = settings.StructureBaseMaterial,
		ViaductWallColorHex = settings.ViaductWallColorHex,
		ViaductWallMaterial = settings.ViaductWallMaterial,
		TunnelWallColorHex = settings.TunnelWallColorHex,
		TunnelWallMaterial = settings.TunnelWallMaterial,
		TunnelRoofColorHex = settings.TunnelRoofColorHex,
		TunnelRoofMaterial = settings.TunnelRoofMaterial,
		StructureInterfaceOverlapM = settings.StructureInterfaceOverlapM,
		ViaductParapetGapM = settings.ViaductParapetGapM,
		ViaductParapetHeightM = settings.ViaductParapetHeightM,
		TunnelWallClearanceM = settings.TunnelWallClearanceM,
		TunnelVerticalClearanceM = settings.TunnelVerticalClearanceM,
		ElevatedMedianConcrete = settings.ElevatedMedianConcrete,
		ParallelRoadwayGapM = settings.ParallelRoadwayGapM,
		Keybinds = settings.Keybinds,
		UserProfiles = settings.UserProfiles,
		UserRegions = settings.UserRegions,
	}
end

local function loadSettings(plugin: Plugin): EasyRoadSettings
	return sanitizeSettings(plugin:GetSetting(kSettingsKey))
end

local function saveSettings(plugin: Plugin, settings: EasyRoadSettings)
	plugin:SetSetting(kSettingsKey, serializeSettings(settings))
end

local function exportSettings(settings: EasyRoadSettings, httpServiceOverride: HttpService?): string
	local httpService = httpServiceOverride or game:GetService("HttpService")
	return httpService:JSONEncode({
		Format = BACKUP_FORMAT,
		Version = BACKUP_VERSION,
		Data = serializeSettings(settings),
	})
end

local function importSettings(json: string, httpServiceOverride: HttpService?): (EasyRoadSettings?, string)
	if json:match("^%s*$") then
		return nil, "Paste an easyRoad backup first."
	end
	if #json > MAX_BACKUP_BYTES then
		return nil, "Backup is larger than the 2 MB safety limit."
	end

	local httpService = httpServiceOverride or game:GetService("HttpService")
	local ok, decoded = pcall(httpService.JSONDecode, httpService, json)
	if not ok or typeof(decoded) ~= "table" then
		return nil, "That text is not valid JSON."
	end
	if decoded.Format ~= BACKUP_FORMAT then
		return nil, "This is not an easyRoad data backup."
	end
	if decoded.Version ~= BACKUP_VERSION then
		return nil, "This backup version is not supported by this build."
	end
	if typeof(decoded.Data) ~= "table" then
		return nil, "The backup has no settings data."
	end

	return sanitizeSettings(decoded.Data), ""
end

local function replaceSettings(target: EasyRoadSettings, source: EasyRoadSettings)
	local targetTable = target :: any
	for key in targetTable do
		targetTable[key] = nil
	end
	for key, value in source :: any do
		targetTable[key] = value
	end
end

return {
	OnboardingVersion = ONBOARDING_VERSION,
	Load = loadSettings,
	Save = saveSettings,
	Export = exportSettings,
	Import = importSettings,
	Replace = replaceSettings,
}
