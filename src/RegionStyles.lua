--!strict
-- Regional road style presets.
--
-- A RegionStyle captures everything about how roads *look and are laid out*
-- in a given part of the world: which side traffic drives on, default lane
-- widths, marking colors and dash patterns, sidewalk / shoulder dimensions,
-- and superelevation (banking) design limits.
--
-- All real-world dimensions are stored in meters and converted to studs at
-- build time using Settings.MetersToStuds.

export type MarkingPattern = "Solid" | "Dashed" | "DoubleSolid" | "None"

export type MarkingSpec = {
	Pattern: MarkingPattern,
	Color: Color3,
}

export type RegionStyle = {
	Id: string,
	Name: string,

	-- Traffic layout
	DriveOnLeft: boolean,

	-- Default dimensions (meters)
	DefaultLaneWidthM: number,
	SidewalkWidthM: number,
	ShoulderWidthM: number,
	MedianWidthM: number,
	BikeLaneWidthM: number,
	ParkingLaneWidthM: number,
	CurbHeightM: number,

	-- Markings
	CenterLine: MarkingSpec, -- Divides opposing traffic
	LaneLine: MarkingSpec, -- Divides same-direction lanes
	EdgeLine: MarkingSpec, -- Roadway outer edge
	MarkingWidthM: number,
	DashLengthM: number,
	DashGapM: number,

	-- Superelevation design values
	MaxSuperelevation: number, -- Max cross slope as a ratio, e.g. 0.08 = 8%
	DesignSpeedKph: number,

	-- Appearance
	AsphaltColor: Color3,
	ShoulderColor: Color3,
	SidewalkColor: Color3,
	CurbColor: Color3,
	MedianColor: Color3,
	BikeLaneColor: Color3,
}

local WHITE = Color3.fromRGB(235, 235, 228)
local YELLOW = Color3.fromRGB(255, 196, 18)
local ASPHALT_DARK = Color3.fromRGB(60, 60, 62)
local ASPHALT_LIGHT = Color3.fromRGB(78, 78, 80)
local CONCRETE = Color3.fromRGB(160, 160, 155)
local CURB = Color3.fromRGB(140, 140, 136)
local GRASS = Color3.fromRGB(88, 126, 66)
local BIKE_RED = Color3.fromRGB(122, 62, 56)
local BIKE_BLUE = Color3.fromRGB(52, 84, 130)

local function makeStyle(partial: RegionStyle): RegionStyle
	return partial
end

local Styles: { RegionStyle } = {
	makeStyle({
		Id = "US",
		Name = "United States",
		DriveOnLeft = false,
		DefaultLaneWidthM = 3.6,
		SidewalkWidthM = 1.8,
		ShoulderWidthM = 2.4,
		MedianWidthM = 1.8,
		BikeLaneWidthM = 1.5,
		ParkingLaneWidthM = 2.4,
		CurbHeightM = 0.15,
		CenterLine = { Pattern = "DoubleSolid" :: MarkingPattern, Color = YELLOW },
		LaneLine = { Pattern = "Dashed" :: MarkingPattern, Color = WHITE },
		EdgeLine = { Pattern = "Solid" :: MarkingPattern, Color = WHITE },
		MarkingWidthM = 0.12,
		DashLengthM = 3.0,
		DashGapM = 9.0,
		MaxSuperelevation = 0.08,
		DesignSpeedKph = 60,
		AsphaltColor = ASPHALT_DARK,
		ShoulderColor = ASPHALT_LIGHT,
		SidewalkColor = CONCRETE,
		CurbColor = CURB,
		MedianColor = GRASS,
		BikeLaneColor = BIKE_RED,
	}),
	makeStyle({
		Id = "UK",
		Name = "United Kingdom",
		DriveOnLeft = true,
		DefaultLaneWidthM = 3.65,
		SidewalkWidthM = 2.0,
		ShoulderWidthM = 3.3,
		MedianWidthM = 1.8,
		BikeLaneWidthM = 1.5,
		ParkingLaneWidthM = 2.4,
		CurbHeightM = 0.125,
		CenterLine = { Pattern = "Dashed" :: MarkingPattern, Color = WHITE },
		LaneLine = { Pattern = "Dashed" :: MarkingPattern, Color = WHITE },
		EdgeLine = { Pattern = "Solid" :: MarkingPattern, Color = WHITE },
		MarkingWidthM = 0.1,
		DashLengthM = 4.0,
		DashGapM = 2.0,
		MaxSuperelevation = 0.07,
		DesignSpeedKph = 60,
		AsphaltColor = ASPHALT_DARK,
		ShoulderColor = ASPHALT_LIGHT,
		SidewalkColor = CONCRETE,
		CurbColor = CURB,
		MedianColor = GRASS,
		BikeLaneColor = BIKE_RED,
	}),
	makeStyle({
		Id = "EU",
		Name = "Europe (Continental)",
		DriveOnLeft = false,
		DefaultLaneWidthM = 3.5,
		SidewalkWidthM = 2.0,
		ShoulderWidthM = 2.5,
		MedianWidthM = 2.0,
		BikeLaneWidthM = 1.7,
		ParkingLaneWidthM = 2.0,
		CurbHeightM = 0.12,
		CenterLine = { Pattern = "Dashed" :: MarkingPattern, Color = WHITE },
		LaneLine = { Pattern = "Dashed" :: MarkingPattern, Color = WHITE },
		EdgeLine = { Pattern = "Solid" :: MarkingPattern, Color = WHITE },
		MarkingWidthM = 0.12,
		DashLengthM = 3.0,
		DashGapM = 6.0,
		MaxSuperelevation = 0.07,
		DesignSpeedKph = 60,
		AsphaltColor = ASPHALT_DARK,
		ShoulderColor = ASPHALT_LIGHT,
		SidewalkColor = CONCRETE,
		CurbColor = CURB,
		MedianColor = GRASS,
		BikeLaneColor = BIKE_RED,
	}),
	makeStyle({
		Id = "JP",
		Name = "Japan",
		DriveOnLeft = true,
		DefaultLaneWidthM = 3.25,
		SidewalkWidthM = 2.0,
		ShoulderWidthM = 1.75,
		MedianWidthM = 1.5,
		BikeLaneWidthM = 1.5,
		ParkingLaneWidthM = 2.0,
		CurbHeightM = 0.15,
		CenterLine = { Pattern = "Solid" :: MarkingPattern, Color = YELLOW },
		LaneLine = { Pattern = "Dashed" :: MarkingPattern, Color = WHITE },
		EdgeLine = { Pattern = "Solid" :: MarkingPattern, Color = WHITE },
		MarkingWidthM = 0.15,
		DashLengthM = 5.0,
		DashGapM = 5.0,
		MaxSuperelevation = 0.08,
		DesignSpeedKph = 50,
		AsphaltColor = ASPHALT_DARK,
		ShoulderColor = ASPHALT_LIGHT,
		SidewalkColor = CONCRETE,
		CurbColor = CURB,
		MedianColor = GRASS,
		BikeLaneColor = BIKE_BLUE,
	}),
	makeStyle({
		Id = "AU",
		Name = "Australia / NZ",
		DriveOnLeft = true,
		DefaultLaneWidthM = 3.5,
		SidewalkWidthM = 1.8,
		ShoulderWidthM = 2.0,
		MedianWidthM = 1.8,
		BikeLaneWidthM = 1.5,
		ParkingLaneWidthM = 2.3,
		CurbHeightM = 0.15,
		CenterLine = { Pattern = "Dashed" :: MarkingPattern, Color = WHITE },
		LaneLine = { Pattern = "Dashed" :: MarkingPattern, Color = WHITE },
		EdgeLine = { Pattern = "Solid" :: MarkingPattern, Color = WHITE },
		MarkingWidthM = 0.1,
		DashLengthM = 3.0,
		DashGapM = 9.0,
		MaxSuperelevation = 0.07,
		DesignSpeedKph = 60,
		AsphaltColor = ASPHALT_DARK,
		ShoulderColor = ASPHALT_LIGHT,
		SidewalkColor = CONCRETE,
		CurbColor = CURB,
		MedianColor = GRASS,
		BikeLaneColor = BIKE_RED,
	}),
}

local byId: { [string]: RegionStyle } = {}
for _, style in Styles do
	byId[style.Id] = style
end

local RegionStyles = {}

RegionStyles.All = Styles

function RegionStyles.Get(id: string): RegionStyle
	return byId[id] or byId.US
end

function RegionStyles.Ids(): { string }
	local ids = {}
	for _, style in Styles do
		table.insert(ids, style.Id)
	end
	return ids
end

return RegionStyles
