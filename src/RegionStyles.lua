--!strict
-- Regional road style presets.
--
-- A RegionStyle captures everything about how roads *look and are laid out*
-- in a given part of the world: which side traffic drives on, default lane
-- widths, marking line types with per-role dash geometry, sidewalk /
-- shoulder dimensions, and superelevation design limits.
--
-- Commonwealth regions (UK / HK / SG) are the primary, most detailed
-- presets; other regions are workable approximations.
--
-- All real-world dimensions are stored in meters and converted to studs at
-- build time using Settings.MetersToStuds.

export type LineType = "None" | "Solid" | "Dashed" | "DoubleSolid" | "DoubleDashed" | "SolidDash" | "DashSolid"

export type MarkingSpec = {
	Line: LineType,
	Color: Color3,
	-- Dash geometry for dashed variants; falls back to the style defaults
	DashLengthM: number?,
	DashGapM: number?,
}

-- How a roundabout's circulating lanes are marked.
--   Continuous - concentric dashed lane lines; changing lanes on the ring is
--                permitted, which is the ordinary UK/US pattern.
--   Turbo      - solid lines between circulating lanes, so a vehicle is held in
--                the lane it entered the whole way round. Dutch "turbo"
--                roundabout practice; safer at high flow, and the reason is
--                that lane changing on the ring is what causes most conflicts.
export type RoundaboutMarkingStyle = "Continuous" | "Turbo"

local RoundaboutMarkingStyles: { RoundaboutMarkingStyle } = {
	"Continuous" :: RoundaboutMarkingStyle,
	"Turbo" :: RoundaboutMarkingStyle,
}
export type RegionStyle = {
	Id: string,
	Name: string,
	BuiltIn: boolean,

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
	DashLengthM: number, -- Fallback dash geometry
	DashGapM: number,
	WhiteMarking: Color3,
	YellowMarking: Color3,

	-- Default roundabout build options. All optional; nil reads as the value
	-- the plugin had before the field existed, so no region needs updating.
	RoundaboutSidewalk: boolean?, -- nil = true: ring carries an outer pavement
	RoundaboutIsland: boolean?, -- nil = true: raised centre island

	-- Default roundabout marking style. Optional: nil reads as "Continuous",
	-- so a region that never mentions it - including every user region
	-- serialised before this existed - keeps the previous behaviour.
	RoundaboutMarkings: RoundaboutMarkingStyle?,

	-- Superelevation design values
	MaxSuperelevation: number, -- Max cross slope as a ratio, e.g. 0.07 = 7%
	DesignSpeedKph: number,

	-- Appearance
	AsphaltColor: Color3,
	ShoulderColor: Color3,
	SidewalkColor: Color3,
	CurbColor: Color3,
	MedianColor: Color3,
	BikeLaneColor: Color3,
	BayColor: Color3, -- Bus/taxi bay surface
}

local WHITE = Color3.fromRGB(235, 235, 228)
local YELLOW = Color3.fromRGB(228, 180, 30)
local US_YELLOW = Color3.fromRGB(255, 196, 18)
local ASPHALT_DARK = Color3.fromRGB(60, 60, 62)
local ASPHALT_LIGHT = Color3.fromRGB(78, 78, 80)
local CONCRETE = Color3.fromRGB(160, 160, 155)
local CURB = Color3.fromRGB(140, 140, 136)
local GRASS = Color3.fromRGB(88, 126, 66)
local BIKE_RED = Color3.fromRGB(122, 62, 56)
local BIKE_GREEN = Color3.fromRGB(60, 110, 70)
local BIKE_BLUE = Color3.fromRGB(52, 84, 130)
local BAY_AMBER = Color3.fromRGB(120, 96, 58)

local function dashed(color: Color3, dashLengthM: number, dashGapM: number): MarkingSpec
	return {
		Line = "Dashed" :: LineType,
		Color = color,
		DashLengthM = dashLengthM,
		DashGapM = dashGapM,
	}
end

local function solid(color: Color3): MarkingSpec
	return { Line = "Solid" :: LineType, Color = color }
end

local function doubleSolid(color: Color3): MarkingSpec
	return { Line = "DoubleSolid" :: LineType, Color = color }
end

local function makeStyle(partial: any): RegionStyle
	partial.BuiltIn = true
	return partial :: RegionStyle
end

local Styles: { RegionStyle } = {
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
		CenterLine = dashed(WHITE, 2.0, 7.0),
		LaneLine = dashed(WHITE, 1.0, 5.0),
		EdgeLine = solid(WHITE),
		MarkingWidthM = 0.1,
		DashLengthM = 2.0,
		DashGapM = 7.0,
		WhiteMarking = WHITE,
		YellowMarking = YELLOW,
		MaxSuperelevation = 0.07,
		DesignSpeedKph = 60,
		AsphaltColor = ASPHALT_DARK,
		ShoulderColor = ASPHALT_LIGHT,
		SidewalkColor = CONCRETE,
		CurbColor = CURB,
		MedianColor = GRASS,
		BikeLaneColor = BIKE_RED,
		BayColor = BAY_AMBER,
	}),
	makeStyle({
		Id = "HK",
		Name = "Hong Kong",
		DriveOnLeft = true,
		DefaultLaneWidthM = 3.3,
		SidewalkWidthM = 2.0,
		ShoulderWidthM = 2.5,
		MedianWidthM = 1.5,
		BikeLaneWidthM = 1.5,
		ParkingLaneWidthM = 2.3,
		CurbHeightM = 0.125,
		CenterLine = dashed(WHITE, 1.5, 4.5),
		LaneLine = dashed(WHITE, 1.0, 5.0),
		EdgeLine = solid(WHITE),
		MarkingWidthM = 0.1,
		DashLengthM = 1.5,
		DashGapM = 4.5,
		WhiteMarking = WHITE,
		YellowMarking = YELLOW,
		MaxSuperelevation = 0.08,
		DesignSpeedKph = 50,
		AsphaltColor = ASPHALT_DARK,
		ShoulderColor = ASPHALT_LIGHT,
		SidewalkColor = CONCRETE,
		CurbColor = CURB,
		MedianColor = GRASS,
		BikeLaneColor = BIKE_GREEN,
		BayColor = BAY_AMBER,
	}),
	makeStyle({
		Id = "SG",
		Name = "Singapore",
		DriveOnLeft = true,
		DefaultLaneWidthM = 3.5,
		SidewalkWidthM = 1.8,
		ShoulderWidthM = 2.5,
		MedianWidthM = 1.5,
		BikeLaneWidthM = 1.7,
		ParkingLaneWidthM = 2.3,
		CurbHeightM = 0.15,
		CenterLine = dashed(WHITE, 2.0, 4.0),
		LaneLine = dashed(WHITE, 1.0, 5.0),
		EdgeLine = solid(WHITE),
		MarkingWidthM = 0.1,
		DashLengthM = 2.0,
		DashGapM = 4.0,
		WhiteMarking = WHITE,
		YellowMarking = YELLOW,
		MaxSuperelevation = 0.06,
		DesignSpeedKph = 60,
		AsphaltColor = ASPHALT_DARK,
		ShoulderColor = ASPHALT_LIGHT,
		SidewalkColor = CONCRETE,
		CurbColor = CURB,
		MedianColor = GRASS,
		BikeLaneColor = BIKE_GREEN,
		BayColor = BAY_AMBER,
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
		CenterLine = dashed(WHITE, 3.0, 6.0),
		LaneLine = dashed(WHITE, 3.0, 6.0),
		EdgeLine = solid(WHITE),
		MarkingWidthM = 0.12,
		DashLengthM = 3.0,
		DashGapM = 6.0,
		WhiteMarking = WHITE,
		YellowMarking = YELLOW,
		MaxSuperelevation = 0.07,
		DesignSpeedKph = 60,
		AsphaltColor = ASPHALT_DARK,
		ShoulderColor = ASPHALT_LIGHT,
		SidewalkColor = CONCRETE,
		CurbColor = CURB,
		MedianColor = GRASS,
		BikeLaneColor = BIKE_RED,
		BayColor = BAY_AMBER,
	}),
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
		CenterLine = doubleSolid(US_YELLOW),
		LaneLine = dashed(WHITE, 3.0, 9.0),
		EdgeLine = solid(WHITE),
		MarkingWidthM = 0.12,
		DashLengthM = 3.0,
		DashGapM = 9.0,
		WhiteMarking = WHITE,
		YellowMarking = US_YELLOW,
		MaxSuperelevation = 0.08,
		DesignSpeedKph = 60,
		AsphaltColor = ASPHALT_DARK,
		ShoulderColor = ASPHALT_LIGHT,
		SidewalkColor = CONCRETE,
		CurbColor = CURB,
		MedianColor = GRASS,
		BikeLaneColor = BIKE_RED,
		BayColor = BAY_AMBER,
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
		CenterLine = solid(US_YELLOW),
		LaneLine = dashed(WHITE, 5.0, 5.0),
		EdgeLine = solid(WHITE),
		MarkingWidthM = 0.15,
		DashLengthM = 5.0,
		DashGapM = 5.0,
		WhiteMarking = WHITE,
		YellowMarking = US_YELLOW,
		MaxSuperelevation = 0.08,
		DesignSpeedKph = 50,
		AsphaltColor = ASPHALT_DARK,
		ShoulderColor = ASPHALT_LIGHT,
		SidewalkColor = CONCRETE,
		CurbColor = CURB,
		MedianColor = GRASS,
		BikeLaneColor = BIKE_BLUE,
		BayColor = BAY_AMBER,
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
		CenterLine = dashed(WHITE, 3.0, 9.0),
		LaneLine = dashed(WHITE, 3.0, 9.0),
		EdgeLine = solid(WHITE),
		MarkingWidthM = 0.1,
		DashLengthM = 3.0,
		DashGapM = 9.0,
		WhiteMarking = WHITE,
		YellowMarking = YELLOW,
		MaxSuperelevation = 0.07,
		DesignSpeedKph = 60,
		AsphaltColor = ASPHALT_DARK,
		ShoulderColor = ASPHALT_LIGHT,
		SidewalkColor = CONCRETE,
		CurbColor = CURB,
		MedianColor = GRASS,
		BikeLaneColor = BIKE_RED,
		BayColor = BAY_AMBER,
	}),
}

local byId: { [string]: RegionStyle } = {}
for _, style in Styles do
	byId[style.Id] = style
end

local RegionStyles = {}

-- Exported for the UI's dropdown. Declared here rather than beside the type
-- above because that point is before `RegionStyles` itself exists.
RegionStyles.RoundaboutMarkingStyles = RoundaboutMarkingStyles

RegionStyles.All = Styles

function RegionStyles.Get(id: string): RegionStyle
	return byId[id] or byId.UK
end

function RegionStyles.Ids(): { string }
	local ids = {}
	for _, style in Styles do
		table.insert(ids, style.Id)
	end
	return ids
end

-- Cloning + serialization (for custom user-created region presets) ------------
-- Plain, JSON-safe data only in the serialized form - Color3 becomes a
-- {R, G, B} (0-255) table, matching this codebase's rule of never putting
-- raw Roblox types into plugin settings storage (see Keybinds/RoadProfile).

local LineTypes: { LineType } = {
	"None" :: LineType,
	"Solid" :: LineType,
	"Dashed" :: LineType,
	"DoubleSolid" :: LineType,
	"DoubleDashed" :: LineType,
	"SolidDash" :: LineType,
	"DashSolid" :: LineType,
}

local function cloneMarking(spec: MarkingSpec): MarkingSpec
	return {
		Line = spec.Line,
		Color = spec.Color,
		DashLengthM = spec.DashLengthM,
		DashGapM = spec.DashGapM,
	}
end

function RegionStyles.Clone(style: RegionStyle): RegionStyle
	return {
		Id = style.Id,
		Name = style.Name,
		BuiltIn = style.BuiltIn,
		DriveOnLeft = style.DriveOnLeft,
		DefaultLaneWidthM = style.DefaultLaneWidthM,
		SidewalkWidthM = style.SidewalkWidthM,
		ShoulderWidthM = style.ShoulderWidthM,
		MedianWidthM = style.MedianWidthM,
		BikeLaneWidthM = style.BikeLaneWidthM,
		ParkingLaneWidthM = style.ParkingLaneWidthM,
		CurbHeightM = style.CurbHeightM,
		CenterLine = cloneMarking(style.CenterLine),
		LaneLine = cloneMarking(style.LaneLine),
		EdgeLine = cloneMarking(style.EdgeLine),
		MarkingWidthM = style.MarkingWidthM,
		DashLengthM = style.DashLengthM,
		DashGapM = style.DashGapM,
		WhiteMarking = style.WhiteMarking,
		YellowMarking = style.YellowMarking,
		RoundaboutSidewalk = style.RoundaboutSidewalk,
		RoundaboutIsland = style.RoundaboutIsland,
		RoundaboutMarkings = style.RoundaboutMarkings,
		MaxSuperelevation = style.MaxSuperelevation,
		DesignSpeedKph = style.DesignSpeedKph,
		AsphaltColor = style.AsphaltColor,
		ShoulderColor = style.ShoulderColor,
		SidewalkColor = style.SidewalkColor,
		CurbColor = style.CurbColor,
		MedianColor = style.MedianColor,
		BikeLaneColor = style.BikeLaneColor,
		BayColor = style.BayColor,
	}
end

local function serializeColor(color: Color3): { [string]: number }
	return {
		R = math.round(color.R * 255),
		G = math.round(color.G * 255),
		B = math.round(color.B * 255),
	}
end

local function deserializeColor(raw: any, fallback: Color3): Color3
	if
		typeof(raw) ~= "table"
		or typeof(raw.R) ~= "number"
		or typeof(raw.G) ~= "number"
		or typeof(raw.B) ~= "number"
	then
		return fallback
	end
	return Color3.fromRGB(math.clamp(raw.R, 0, 255), math.clamp(raw.G, 0, 255), math.clamp(raw.B, 0, 255))
end

local function serializeMarking(spec: MarkingSpec): { [string]: any }
	return {
		Line = spec.Line,
		Color = serializeColor(spec.Color),
		DashLengthM = spec.DashLengthM,
		DashGapM = spec.DashGapM,
	}
end

local function deserializeMarking(raw: any, fallback: MarkingSpec): MarkingSpec
	if typeof(raw) ~= "table" then
		return cloneMarking(fallback)
	end
	local line = if typeof(raw.Line) == "string" and table.find(LineTypes, raw.Line)
		then raw.Line :: LineType
		else fallback.Line
	return {
		Line = line,
		Color = deserializeColor(raw.Color, fallback.Color),
		DashLengthM = if typeof(raw.DashLengthM) == "number" then raw.DashLengthM else fallback.DashLengthM,
		DashGapM = if typeof(raw.DashGapM) == "number" then raw.DashGapM else fallback.DashGapM,
	}
end

function RegionStyles.Serialize(style: RegionStyle): { [string]: any }
	return {
		Id = style.Id,
		Name = style.Name,
		DriveOnLeft = style.DriveOnLeft,
		DefaultLaneWidthM = style.DefaultLaneWidthM,
		SidewalkWidthM = style.SidewalkWidthM,
		ShoulderWidthM = style.ShoulderWidthM,
		MedianWidthM = style.MedianWidthM,
		BikeLaneWidthM = style.BikeLaneWidthM,
		ParkingLaneWidthM = style.ParkingLaneWidthM,
		CurbHeightM = style.CurbHeightM,
		CenterLine = serializeMarking(style.CenterLine),
		LaneLine = serializeMarking(style.LaneLine),
		EdgeLine = serializeMarking(style.EdgeLine),
		MarkingWidthM = style.MarkingWidthM,
		DashLengthM = style.DashLengthM,
		DashGapM = style.DashGapM,
		WhiteMarking = serializeColor(style.WhiteMarking),
		YellowMarking = serializeColor(style.YellowMarking),
		RoundaboutSidewalk = style.RoundaboutSidewalk,
		RoundaboutIsland = style.RoundaboutIsland,
		RoundaboutMarkings = style.RoundaboutMarkings,
		MaxSuperelevation = style.MaxSuperelevation,
		DesignSpeedKph = style.DesignSpeedKph,
		AsphaltColor = serializeColor(style.AsphaltColor),
		ShoulderColor = serializeColor(style.ShoulderColor),
		SidewalkColor = serializeColor(style.SidewalkColor),
		CurbColor = serializeColor(style.CurbColor),
		MedianColor = serializeColor(style.MedianColor),
		BikeLaneColor = serializeColor(style.BikeLaneColor),
		BayColor = serializeColor(style.BayColor),
	}
end

function RegionStyles.Deserialize(raw: any): RegionStyle?
	if typeof(raw) ~= "table" or typeof(raw.Id) ~= "string" then
		return nil
	end
	local fallback = RegionStyles.Get("UK")
	local function num(value: any, default: number): number
		return if typeof(value) == "number" then value else default
	end
	return {
		Id = raw.Id,
		Name = if typeof(raw.Name) == "string" then raw.Name else raw.Id,
		BuiltIn = false,
		DriveOnLeft = if typeof(raw.DriveOnLeft) == "boolean" then raw.DriveOnLeft else fallback.DriveOnLeft,
		DefaultLaneWidthM = num(raw.DefaultLaneWidthM, fallback.DefaultLaneWidthM),
		SidewalkWidthM = num(raw.SidewalkWidthM, fallback.SidewalkWidthM),
		ShoulderWidthM = num(raw.ShoulderWidthM, fallback.ShoulderWidthM),
		MedianWidthM = num(raw.MedianWidthM, fallback.MedianWidthM),
		BikeLaneWidthM = num(raw.BikeLaneWidthM, fallback.BikeLaneWidthM),
		ParkingLaneWidthM = num(raw.ParkingLaneWidthM, fallback.ParkingLaneWidthM),
		CurbHeightM = num(raw.CurbHeightM, fallback.CurbHeightM),
		CenterLine = deserializeMarking(raw.CenterLine, fallback.CenterLine),
		LaneLine = deserializeMarking(raw.LaneLine, fallback.LaneLine),
		EdgeLine = deserializeMarking(raw.EdgeLine, fallback.EdgeLine),
		MarkingWidthM = num(raw.MarkingWidthM, fallback.MarkingWidthM),
		DashLengthM = num(raw.DashLengthM, fallback.DashLengthM),
		DashGapM = num(raw.DashGapM, fallback.DashGapM),
		WhiteMarking = deserializeColor(raw.WhiteMarking, fallback.WhiteMarking),
		YellowMarking = deserializeColor(raw.YellowMarking, fallback.YellowMarking),
		RoundaboutSidewalk = if typeof(raw.RoundaboutSidewalk) == "boolean" then raw.RoundaboutSidewalk else nil,
		RoundaboutIsland = if typeof(raw.RoundaboutIsland) == "boolean" then raw.RoundaboutIsland else nil,
		RoundaboutMarkings = if table.find(RoundaboutMarkingStyles, raw.RoundaboutMarkings)
			then raw.RoundaboutMarkings :: RoundaboutMarkingStyle
			else nil,
		MaxSuperelevation = num(raw.MaxSuperelevation, fallback.MaxSuperelevation),
		DesignSpeedKph = num(raw.DesignSpeedKph, fallback.DesignSpeedKph),
		AsphaltColor = deserializeColor(raw.AsphaltColor, fallback.AsphaltColor),
		ShoulderColor = deserializeColor(raw.ShoulderColor, fallback.ShoulderColor),
		SidewalkColor = deserializeColor(raw.SidewalkColor, fallback.SidewalkColor),
		CurbColor = deserializeColor(raw.CurbColor, fallback.CurbColor),
		MedianColor = deserializeColor(raw.MedianColor, fallback.MedianColor),
		BikeLaneColor = deserializeColor(raw.BikeLaneColor, fallback.BikeLaneColor),
		BayColor = deserializeColor(raw.BayColor, fallback.BayColor),
	}
end

return RegionStyles
