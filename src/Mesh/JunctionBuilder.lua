--!strict
-- Builds the visible geometry for a JunctionNode (see JunctionInstance.lua):
-- a flat pad covering the seam where its connected roads' decks meet.
--
-- The pad is a fan of exact wedges (FillTriangle, the same "no padding,
-- exact shared edges" technique already used for curve joints and
-- superelevation wedges elsewhere in Mesh/) tracing each connected road's
-- own left/right pavement edge at the point it meets the junction - a real
-- shaped fillet outline, not an arbitrary circle. Every connected road
-- contributes two edge points; sorted by angle around the junction centre
-- and fan-triangulated from there, so the polygon naturally follows
-- whatever roads actually meet here regardless of how many or at what
-- angles. Doesn't yet re-derive lane markings through the junction (stop
-- lines, give-way markings, lane-guidance paint) - see TODO.md's
-- "Junctions & roundabouts" section for that follow-up work. Skips itself
-- entirely for a plain two-road pass-through (matching profiles, roughly
-- opposite outward directions) - a chained straight or gently-curving
-- continuation doesn't need a seam pad at all.

local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")
local RoadInstance = require("../RoadInstance")
local JunctionInstance = require("../JunctionInstance")
local FillTriangle = require("./FillTriangle")

local JunctionBuilder = {}

local PAD_MARGIN_STUDS = 2 -- Extra reach beyond the widest connected road's half-width (fallback pad only)

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

-- `road`'s own left/right pavement edge points at the exact station where
-- it connects to this junction (world space, at deck-top height, matching
-- the road's own FrameAt convention) - the fillet polygon's raw material.
-- nil if the road can't be read or its profile has no components at all.
local function edgePointsForRoad(road: Model, junctionId: string, settings: Settings.EasyRoadSettings): { Vector3 }?
	local data = RoadInstance.Read(road)
	if not data then
		return nil
	end
	local station: number
	if data.StartJunctionId == junctionId then
		station = 0
	elseif data.EndJunctionId == junctionId then
		station = data.Curve.Length
	else
		return nil
	end
	local profile = profileAtJunctionEnd(road, junctionId)
	if not profile then
		return nil
	end
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	if #offsets == 0 then
		return nil
	end
	local frame = data.Curve:FrameAt(station)
	local scale = settings.MetersToStuds
	local leftPoint = (frame * CFrame.new(offsets[1].Left * scale, 0, 0)).Position
	local rightPoint = (frame * CFrame.new(offsets[#offsets].Right * scale, 0, 0)).Position
	return { leftPoint, rightPoint }
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
	local center = junctionData.Position
	local thickness = settings.RoadThicknessStuds

	local function makePart(): Part
		local part = Instance.new("Part")
		part.Name = "Pad"
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Material = Enum.Material.Asphalt
		part.Color = style.AsphaltColor
		return part
	end

	local folder = Instance.new("Folder")
	folder.Name = "Geometry"

	local edgePoints: { Vector3 } = {}
	for _, road in roads do
		local points = edgePointsForRoad(road, junctionId, settings)
		if points then
			for _, point in points do
				table.insert(edgePoints, point)
			end
		end
	end

	if #edgePoints >= 3 then
		-- Fan-triangulate around the junction centre, in angular order, so
		-- adjacent roads' edges are joined by the wedge between them rather
		-- than the fan winding back on itself.
		table.sort(edgePoints, function(a: Vector3, b: Vector3): boolean
			local angleA = math.atan2(a.Z - center.Z, a.X - center.X)
			local angleB = math.atan2(b.Z - center.Z, b.X - center.X)
			return angleA < angleB
		end)
		for i = 1, #edgePoints do
			local nextIndex = if i < #edgePoints then i + 1 else 1
			FillTriangle(
				center,
				edgePoints[i],
				edgePoints[nextIndex],
				thickness,
				Vector3.new(0, -1, 0),
				makePart,
				folder
			)
		end
	else
		-- Fallback for the rare case no road contributed a usable edge pair
		-- (an empty profile) - a plain circular pad still beats no pad.
		local maxHalfWidthM = 0
		for _, road in roads do
			local profile = profileAtJunctionEnd(road, junctionId)
			if profile then
				maxHalfWidthM = math.max(maxHalfWidthM, RoadProfile.TotalWidthM(profile) / 2)
			end
		end
		if maxHalfWidthM > 0 then
			local radiusStuds = maxHalfWidthM * settings.MetersToStuds + PAD_MARGIN_STUDS
			local pad = makePart()
			pad.Shape = Enum.PartType.Cylinder
			pad.Size = Vector3.new(thickness, radiusStuds * 2, radiusStuds * 2)
			pad.CFrame = CFrame.new(center + Vector3.new(0, -thickness / 2, 0)) * CFrame.Angles(0, 0, math.rad(90))
			pad.Parent = folder
		end
	end

	folder.Parent = junctionModel
end

return JunctionBuilder
