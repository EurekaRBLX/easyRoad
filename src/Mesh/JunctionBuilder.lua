--!strict
-- Builds the visible geometry for a JunctionNode (see JunctionInstance.lua):
-- a flat pad covering the seam where its connected roads' decks meet.
--
-- v1 deliberately keeps this simple: a single circular asphalt pad sized to
-- the widest connected road, flush with the roads' own deck height. It
-- doesn't yet compute an exact per-corner fillet polygon (the way curve
-- joints and superelevation wedges do elsewhere in Mesh/ via FillTriangle),
-- and doesn't re-derive lane markings through the junction - see TODO.md's
-- "Junctions & roundabouts" section for the follow-up work this is scoped
-- out of. It DOES skip itself for a plain two-road pass-through (matching
-- profiles, roughly opposite outward directions) - a chained straight or
-- gently-curving continuation doesn't need a seam pad at all.

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

-- The direction `road` extends AWAY from this junction - +TangentAt(0) if
-- the junction is at the road's start (the road runs forward from here),
-- -TangentAt(Length) if it's at the road's end (the road arrives here
-- travelling forward, so away-from-junction is the reverse).
local function outwardTangentAt(road: Model, junctionId: string): Vector3?
	local data = RoadInstance.Read(road)
	if not data then
		return nil
	end
	if data.StartJunctionId == junctionId then
		return data.Curve:TangentAt(0)
	elseif data.EndJunctionId == junctionId then
		return -data.Curve:TangentAt(data.Curve.Length)
	end
	return nil
end

-- Roughly opposite outward directions (within ~32 degrees of dead
-- straight) - a chained continuation's tangent is locked exactly
-- opposite (dot = -1); this leaves headroom for a gentle through-curve
-- placed independently rather than chained.
local PASS_THROUGH_DOT_THRESHOLD = -0.85

-- True when exactly two roads meet here with matching profiles, extending
-- away from the junction in roughly opposite directions - a plain chained
-- continuation (or gentle through-curve) that doesn't need a seam pad at
-- all, as opposed to a genuine corner or crossing.
local function isSmoothPassThrough(roads: { Model }, junctionId: string): boolean
	if #roads ~= 2 then
		return false
	end
	local profileA = profileAtJunctionEnd(roads[1], junctionId)
	local profileB = profileAtJunctionEnd(roads[2], junctionId)
	if not profileA or not profileB or profileA.Id ~= profileB.Id then
		return false
	end
	local tangentA = outwardTangentAt(roads[1], junctionId)
	local tangentB = outwardTangentAt(roads[2], junctionId)
	if not tangentA or not tangentB then
		return false
	end
	return tangentA:Dot(tangentB) < PASS_THROUGH_DOT_THRESHOLD
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
	if isSmoothPassThrough(roads, junctionId) then
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
