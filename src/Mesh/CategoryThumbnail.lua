--!strict
-- Builds a representative flat road-extrusion scene for a road-library
-- category tab icon (Streets/Avenues/Highways/Paths/Custom) - a category
-- has no single "shape" of its own, so each one is rendered from a fixed
-- representative built-in profile via ProfileThumbnail's existing 3/4
-- top-down camera technique. Highways additionally get a simple overhead
-- gantry overlay (icon-only decoration - EasyRoad has no real gantry/
-- sign-structure feature to build from).

local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")
local ProfileThumbnail = require("./ProfileThumbnail")

local CategoryThumbnail = {}

local REPRESENTATIVE_ID: { [string]: string } = {
	Streets = "builtin_two_lane",
	Avenues = "builtin_boulevard",
	Highways = "builtin_highway",
	Paths = "builtin_path",
}

-- "Custom" built-ins don't exist (Category = "Custom" only ever appears on
-- user-created profiles) - use the same generic template shape main.lua's
-- "+ New" action starts from, so the icon at least reads as "a road" like
-- the other four.
local function customProfile(style: RegionStyles.RegionStyle): RoadProfile.RoadProfile
	return {
		Id = "icon_custom",
		Name = "Custom",
		Category = "Custom",
		BuiltIn = false,
		Components = {
			{ Kind = "Sidewalk" :: RoadProfile.ComponentKind, WidthM = style.SidewalkWidthM, Direction = 0 },
			{ Kind = "Drive" :: RoadProfile.ComponentKind, WidthM = style.DefaultLaneWidthM, Direction = -1 },
			{ Kind = "Drive" :: RoadProfile.ComponentKind, WidthM = style.DefaultLaneWidthM, Direction = 1 },
			{ Kind = "Sidewalk" :: RoadProfile.ComponentKind, WidthM = style.SidewalkWidthM, Direction = 0 },
		},
	}
end

local function findBuiltIn(id: string, style: RegionStyles.RegionStyle): RoadProfile.RoadProfile?
	for _, candidate in RoadProfile.BuiltInProfiles(style) do
		if candidate.Id == id then
			return candidate
		end
	end
	return nil
end

-- A plain two-post overhead gantry spanning the road, positioned toward the
-- far end of the thumbnail extrusion so it reads as a sign structure ahead
-- on the highway rather than blocking the near lanes.
local function addGantry(model: Model, profile: RoadProfile.RoadProfile, settings: Settings.EasyRoadSettings)
	local scale = settings.MetersToStuds
	local totalWidthStuds = RoadProfile.TotalWidthM(profile) * scale
	local margin = 1.5 * scale
	local halfSpan = totalWidthStuds / 2 + margin
	local postHeight = 8 * scale
	local postSize = 0.35 * scale
	local beamHeight = 0.5 * scale
	local gantryZ = -10

	local gantryColor = Color3.fromRGB(150, 150, 155)

	local function post(x: number): Part
		local part = Instance.new("Part")
		part.Anchored = true
		part.CastShadow = false
		part.Material = Enum.Material.Metal
		part.Color = gantryColor
		part.Size = Vector3.new(postSize, postHeight, postSize)
		part.CFrame = CFrame.new(x, postHeight / 2, gantryZ)
		part.Parent = model
		return part
	end

	post(-halfSpan)
	post(halfSpan)

	local beam = Instance.new("Part")
	beam.Anchored = true
	beam.CastShadow = false
	beam.Material = Enum.Material.Metal
	beam.Color = gantryColor
	beam.Size = Vector3.new(halfSpan * 2 + postSize, beamHeight, postSize)
	beam.CFrame = CFrame.new(0, postHeight, gantryZ)
	beam.Parent = model
end

function CategoryThumbnail.Build(
	category: string,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): (Model, CFrame)
	local profile: RoadProfile.RoadProfile
	if category == "Custom" then
		profile = customProfile(style)
	else
		profile = findBuiltIn(REPRESENTATIVE_ID[category] or "", style) or customProfile(style)
	end

	local model = ProfileThumbnail.Build(profile, style, settings)
	if category == "Highways" then
		addGantry(model, profile, settings)
	end

	return model, ProfileThumbnail.FrameCamera(model)
end

return CategoryThumbnail
