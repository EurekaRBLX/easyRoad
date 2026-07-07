--!strict
-- EasyRoad grand settings: persisted plugin-wide configuration.
--
-- These are the "grand settings" that control the style of every road the
-- plugin builds: the active region preset (US / UK / EU / JP / AU), the
-- meters-to-studs scale, superelevation behavior, snapping, and geometry
-- quality. Per-road configuration lives in RoadProfile / RoadLibrary instead.

local Keybinds = require("./Keybinds")

local kSettingsKey = "easyRoadState"

export type SuperelevationMode = "Auto" | "Manual" | "Off"

export type EasyRoadSettings = {
	-- Grand style settings
	RegionId: string,
	MetersToStuds: number, -- 1 stud = 0.28m -> 3.571 studs per meter
	DesignSpeedKph: number, -- Used by auto superelevation
	SuperelevationMode: SuperelevationMode,
	ManualBankDeg: number, -- Used when SuperelevationMode == "Manual"
	AutoMarkings: boolean,
	DriveSideOverride: string, -- "Region" | "Left" | "Right"

	-- Default road
	DefaultProfileId: string,

	-- Placement behavior
	SnapRadiusStuds: number,
	GridSizeStuds: number,
	SnapToGrid: boolean,
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
}

local function loadSettings(plugin: Plugin): EasyRoadSettings
	local raw = plugin:GetSetting(kSettingsKey) or {}
	return {
		RegionId = raw.RegionId or "UK",
		MetersToStuds = raw.MetersToStuds or 3.571,
		DesignSpeedKph = raw.DesignSpeedKph or 60,
		SuperelevationMode = raw.SuperelevationMode or "Auto",
		ManualBankDeg = raw.ManualBankDeg or 4,
		AutoMarkings = if raw.AutoMarkings == nil then true else raw.AutoMarkings,
		DriveSideOverride = raw.DriveSideOverride or "Region",
		DefaultProfileId = raw.DefaultProfileId or "builtin_two_lane",
		SnapRadiusStuds = raw.SnapRadiusStuds or 8,
		GridSizeStuds = raw.GridSizeStuds or 4,
		SnapToGrid = if raw.SnapToGrid == nil then false else raw.SnapToGrid,
		ElevationStepStuds = raw.ElevationStepStuds or 1,
		LastElevationStuds = raw.LastElevationStuds or 0,
		RoadThicknessStuds = raw.RoadThicknessStuds or 1,
		MaxSegmentLengthStuds = raw.MaxSegmentLengthStuds or 8,
		PreviewMaxSegmentLengthStuds = raw.PreviewMaxSegmentLengthStuds or 16,
		Keybinds = Keybinds.Sanitize(raw.Keybinds),
		UserProfiles = raw.UserProfiles or {},
	}
end

local function saveSettings(plugin: Plugin, settings: EasyRoadSettings)
	plugin:SetSetting(kSettingsKey, {
		RegionId = settings.RegionId,
		MetersToStuds = settings.MetersToStuds,
		DesignSpeedKph = settings.DesignSpeedKph,
		SuperelevationMode = settings.SuperelevationMode,
		ManualBankDeg = settings.ManualBankDeg,
		AutoMarkings = settings.AutoMarkings,
		DriveSideOverride = settings.DriveSideOverride,
		DefaultProfileId = settings.DefaultProfileId,
		SnapRadiusStuds = settings.SnapRadiusStuds,
		GridSizeStuds = settings.GridSizeStuds,
		SnapToGrid = settings.SnapToGrid,
		ElevationStepStuds = settings.ElevationStepStuds,
		LastElevationStuds = settings.LastElevationStuds,
		RoadThicknessStuds = settings.RoadThicknessStuds,
		MaxSegmentLengthStuds = settings.MaxSegmentLengthStuds,
		PreviewMaxSegmentLengthStuds = settings.PreviewMaxSegmentLengthStuds,
		Keybinds = settings.Keybinds,
		UserProfiles = settings.UserProfiles,
	})
end

return {
	Load = loadSettings,
	Save = saveSettings,
}
