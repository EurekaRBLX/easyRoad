--!strict
-- Builds the visible geometry for a JunctionNode (see JunctionInstance.lua):
-- a flat pad covering the seam where its connected roads' decks meet.
--
-- v1 deliberately keeps this simple: a single circular asphalt pad sized to
-- the widest connected road, flush with the roads' own deck height. It
-- doesn't yet compute an exact per-corner fillet polygon (the way curve
-- joints and superelevation wedges do elsewhere in Mesh/ via FillTriangle),
-- doesn't skip itself for a plain two-road pass-through (a straight chained
-- placement gets a redundant-but-harmless pad too), and doesn't re-derive
-- lane markings through the junction - see TODO.md's "Junctions &
-- roundabouts" section for the follow-up work this is scoped out of.

local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")
local RoadInstance = require("../RoadInstance")
local JunctionInstance = require("../JunctionInstance")

local JunctionBuilder = {}

local PAD_MARGIN_STUDS = 2 -- Extra reach beyond the widest connected road's half-width

-- The profile actually present at the end of `road` that connects to this
-- junction - ProfileEnd for a widen/narrow transition's far end, ProfileStart
-- otherwise (also the fallback if somehow neither end matches, which
-- shouldn't happen for a road JunctionInstance.ConnectedRoads returned).
local function profileAtJunctionEnd(road: Model, junctionId: string): RoadProfile.RoadProfile?
	local data = RoadInstance.Read(road)
	if not data then
		return nil
	end
	if data.EndJunctionId == junctionId then
		return data.ProfileEnd or data.ProfileStart
	end
	return data.ProfileStart
end

-- Rebuilds the junction's pad from scratch based on whichever roads
-- currently reference it - call after stamping a road's Start/EndJunctionId
-- (both the newly placed road and whatever it snapped onto), and again after
-- deleting a road so a since-orphaned junction's pad shrinks or disappears.
function JunctionBuilder.Rebuild(
	junctionId: string,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
)
	local junctionModel = JunctionInstance.FindById(junctionId)
	if not junctionModel then
		return
	end
	local geometry = junctionModel:FindFirstChild("Geometry")
	if geometry then
		geometry:Destroy()
	end

	local roads = JunctionInstance.ConnectedRoads(junctionId)
	if #roads < 2 then
		-- A single connected road (or none, if this was the last one
		-- removed) doesn't need a seam pad at all.
		return
	end

	local junctionData = JunctionInstance.Read(junctionModel)
	if not junctionData then
		return
	end

	local maxHalfWidthM = 0
	for _, road in roads do
		local profile = profileAtJunctionEnd(road, junctionId)
		if profile then
			maxHalfWidthM = math.max(maxHalfWidthM, RoadProfile.TotalWidthM(profile) / 2)
		end
	end
	if maxHalfWidthM <= 0 then
		return
	end

	local radiusStuds = maxHalfWidthM * settings.MetersToStuds + PAD_MARGIN_STUDS
	local thickness = settings.RoadThicknessStuds

	local folder = Instance.new("Folder")
	folder.Name = "Geometry"

	local pad = Instance.new("Part")
	pad.Name = "Pad"
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(thickness, radiusStuds * 2, radiusStuds * 2)
	pad.CFrame = CFrame.new(junctionData.Position + Vector3.new(0, -thickness / 2, 0))
		* CFrame.Angles(0, 0, math.rad(90))
	pad.Anchored = true
	pad.CanCollide = false
	pad.CanTouch = false
	pad.CanQuery = false
	pad.CastShadow = false
	pad.Material = Enum.Material.Asphalt
	pad.Color = style.AsphaltColor
	pad.Parent = folder

	folder.Parent = junctionModel
end

return JunctionBuilder
