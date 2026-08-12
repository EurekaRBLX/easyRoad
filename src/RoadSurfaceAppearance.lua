--!strict
-- Resolves a road profile's optional per-surface finish over region defaults.

local RoadProfile = require("./RoadProfile")
local RegionStyles = require("./RegionStyles")
local RoadSurfaceMaterials = require("./RoadSurfaceMaterials")

local DEFAULT_MATERIAL_BY_KIND: { [string]: Enum.Material } = {
	Drive = Enum.Material.Asphalt,
	Shoulder = Enum.Material.Asphalt,
	Bike = Enum.Material.Asphalt,
	Parking = Enum.Material.Asphalt,
	Bay = Enum.Material.Asphalt,
	Sidewalk = Enum.Material.Concrete,
	Median = Enum.Material.Grass,
}

local RoadSurfaceAppearance = {}

function RoadSurfaceAppearance.DefaultColor(kind: RoadProfile.ComponentKind, style: RegionStyles.RegionStyle): Color3
	if kind == "Drive" then
		return style.AsphaltColor
	elseif kind == "Shoulder" then
		return style.ShoulderColor
	elseif kind == "Sidewalk" then
		return style.SidewalkColor
	elseif kind == "Median" then
		return style.MedianColor
	elseif kind == "Bike" then
		return style.BikeLaneColor
	elseif kind == "Parking" then
		return style.AsphaltColor:Lerp(Color3.new(0, 0, 0), 0.15)
	elseif kind == "Bay" then
		return style.BayColor
	end
	return style.AsphaltColor
end

function RoadSurfaceAppearance.Resolve(
	profile: RoadProfile.RoadProfile,
	style: RegionStyles.RegionStyle,
	kind: RoadProfile.ComponentKind
): (Enum.Material, Color3)
	local override = if profile.SurfaceOverrides then profile.SurfaceOverrides[kind] else nil
	local material = if override then RoadSurfaceMaterials.Resolve(override.Material) else nil
	return material or DEFAULT_MATERIAL_BY_KIND[kind] or Enum.Material.Asphalt,
		(if override and override.Color then override.Color else RoadSurfaceAppearance.DefaultColor(kind, style))
end

return RoadSurfaceAppearance
