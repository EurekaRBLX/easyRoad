--!strict
-- Builds the visible geometry for a JunctionNode (see JunctionInstance.lua):
-- real curb-return corners between the roads that meet here, not just a
-- flat pad covering the seam.
--
-- Every connected road contributes, at the station where it meets the
-- junction, its own KERB points (the roadway/non-roadway boundary - where a
-- real kerb physically sits) and OUTER points (the profile's true outer
-- edge, typically a sidewalk's outer/property edge - the same position as
-- the kerb point when the road has no sidewalk). Sorted by angle around the
-- junction centre: between two ADJACENT roads' kerb points, a
-- tangent-continuous rounded corner (a quadratic Bézier, built from the
-- classic "intersect the two tangent lines for the control point"
-- construction - degrades to a straight blend for near-parallel roads) is
-- fanned from the centre as the drivable asphalt surface, and the strip
-- between that arc and each road's own outer edge is filled separately as
-- the pedestrian corner (sidewalk material) - the actual curb-return shape,
-- not just an unshaped flat pad. A road's OWN kerb-to-kerb span (both
-- points from the same road) needs no corner treatment - that's just its
-- own pavement, fanned directly.
--
-- Still doesn't re-derive lane markings through the junction (stop lines,
-- give-way markings, lane-guidance paint) - see TODO.md's "Junctions &
-- roundabouts" section for that and other follow-up work. Skips itself
-- entirely for a plain two-road pass-through (matching profiles, roughly
-- opposite outward directions) - a chained straight or gently-curving
-- continuation doesn't need any of this.

local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")
local RoadInstance = require("../RoadInstance")
local JunctionInstance = require("../JunctionInstance")
local FillTriangle = require("./FillTriangle")

local JunctionBuilder = {}

local PAD_MARGIN_STUDS = 2 -- Extra reach beyond the widest connected road's half-width (fallback pad only)
local CORNER_ARC_SAMPLES = 5
local MAX_CONTROL_DISTANCE_STUDS = 200 -- Beyond this, treat the corner as a straight blend instead
local DOWN = Vector3.new(0, -1, 0)

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

-- The roadway's own left/right edge offsets (meters from centreline) -
-- where a kerb physically sits - as opposed to
-- RoadProfile.ComponentOffsetsM's outermost entries, which include any
-- sidewalk/median beyond the roadway.
local function roadwayEdgeOffsetsM(profile: RoadProfile.RoadProfile): (number, number)
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	local firstRoadway: number? = nil
	local lastRoadway: number? = nil
	for i, component in profile.Components do
		if RoadProfile.IsRoadway(component.Kind) then
			if not firstRoadway then
				firstRoadway = i
			end
			lastRoadway = i
		end
	end
	if not firstRoadway or not lastRoadway then
		return offsets[1].Left, offsets[#offsets].Right
	end
	return offsets[firstRoadway].Left, offsets[lastRoadway].Right
end

type EdgePoint = {
	Road: Model,
	Kerb: Vector3,
	Outer: Vector3,
	Tangent: Vector3, -- outward (away-from-junction) direction at this point
}

-- `road`'s own left and right edge points at the station where it meets
-- this junction (world space, at deck-top height, matching the road's own
-- FrameAt convention) - both the kerb (roadway boundary) and outer
-- (profile's true outer edge) position for each side. nil if the road
-- can't be read or its profile has no components at all.
local function edgePointsForRoad(road: Model, junctionId: string, settings: Settings.EasyRoadSettings): { EdgePoint }?
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
	local outward = outwardTangentAt(road, junctionId)
	if not outward then
		return nil
	end
	local kerbLeftM, kerbRightM = roadwayEdgeOffsetsM(profile)
	local outerLeftM, outerRightM = offsets[1].Left, offsets[#offsets].Right
	local frame = data.Curve:FrameAt(station)
	local scale = settings.MetersToStuds
	local function worldPoint(offsetM: number): Vector3
		return (frame * CFrame.new(offsetM * scale, 0, 0)).Position
	end
	return {
		{ Road = road, Kerb = worldPoint(kerbLeftM), Outer = worldPoint(outerLeftM), Tangent = outward },
		{ Road = road, Kerb = worldPoint(kerbRightM), Outer = worldPoint(outerRightM), Tangent = outward },
	}
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

-- The quadratic Bézier control point for a corner from `a` (tangent
-- `tangentA`, already pointing INTO the corner) to `b` (tangent `tangentB`,
-- likewise) - the classic "intersect the two tangent lines" construction,
-- so the resulting curve continues smoothly out of each road's own kerb
-- line rather than kinking. Falls back to the straight-line midpoint if
-- the tangent lines are parallel, or the intersection lands unreasonably
-- far away (near-parallel roads) - degrades to a gentle blend instead of
-- an absurdly oversized arc.
local function cornerControlPoint(a: Vector3, tangentA: Vector3, b: Vector3, tangentB: Vector3): Vector3
	local ax, az = tangentA.X, tangentA.Z
	local bx, bz = tangentB.X, tangentB.Z
	local det = ax * -bz - az * -bx
	if math.abs(det) < 1e-6 then
		return (a + b) / 2
	end
	local dx, dz = b.X - a.X, b.Z - a.Z
	local t1 = (dx * -bz - dz * -bx) / det
	if t1 < 0 or t1 > MAX_CONTROL_DISTANCE_STUDS then
		return (a + b) / 2
	end
	return a + tangentA * t1
end

-- Samples `samples` interior points (excluding the endpoints themselves)
-- along the rounded corner from `a` to `b`.
local function sampleCornerArc(
	a: Vector3,
	tangentA: Vector3,
	b: Vector3,
	tangentB: Vector3,
	samples: number
): { Vector3 }
	local control = cornerControlPoint(a, tangentA.Unit, b, tangentB.Unit)
	local points: { Vector3 } = {}
	for i = 1, samples do
		local t = i / (samples + 1)
		local u = 1 - t
		table.insert(points, a * (u * u) + control * (2 * u * t) + b * (t * t))
	end
	return points
end

-- Rebuilds the junction's geometry from scratch based on whichever roads
-- currently reference it - call after stamping a road's Start/EndJunctionId
-- (both the newly placed road and whatever it snapped onto), and again after
-- deleting a road so a since-orphaned junction's geometry shrinks or
-- disappears.
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
		-- removed) doesn't need any junction geometry at all.
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

	local function makePart(material: Enum.Material, color: Color3): Part
		local part = Instance.new("Part")
		part.Name = "JunctionSurface"
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Material = material
		part.Color = color
		return part
	end
	local function makeAsphaltPart(): Part
		return makePart(Enum.Material.Asphalt, style.AsphaltColor)
	end
	local function makeSidewalkPart(): Part
		return makePart(Enum.Material.Concrete, style.SidewalkColor)
	end

	local folder = Instance.new("Folder")
	folder.Name = "Geometry"

	local edgePoints: { EdgePoint } = {}
	for _, road in roads do
		local points = edgePointsForRoad(road, junctionId, settings)
		if points then
			for _, point in points do
				table.insert(edgePoints, point)
			end
		end
	end

	if #edgePoints >= 3 then
		-- Angular order around the junction centre, so adjacent roads'
		-- kerb points are joined by the corner between them rather than the
		-- fan winding back on itself.
		table.sort(edgePoints, function(a: EdgePoint, b: EdgePoint): boolean
			local angleA = math.atan2(a.Kerb.Z - center.Z, a.Kerb.X - center.X)
			local angleB = math.atan2(b.Kerb.Z - center.Z, b.Kerb.X - center.X)
			return angleA < angleB
		end)
		for i = 1, #edgePoints do
			local nextIndex = if i < #edgePoints then i + 1 else 1
			local a = edgePoints[i]
			local b = edgePoints[nextIndex]
			if a.Road == b.Road then
				-- Same road's own kerb-to-kerb span - already its own
				-- pavement, no corner needed; fan it directly (mostly
				-- redundant underlay, but harmless).
				FillTriangle(center, a.Kerb, b.Kerb, thickness, DOWN, makeAsphaltPart, folder)
			else
				local arc = sampleCornerArc(a.Kerb, -a.Tangent, b.Kerb, -b.Tangent, CORNER_ARC_SAMPLES)
				-- Asphalt: fan from the centre through the rounded corner.
				local previous = a.Kerb
				for _, point in arc do
					FillTriangle(center, previous, point, thickness, DOWN, makeAsphaltPart, folder)
					previous = point
				end
				FillTriangle(center, previous, b.Kerb, thickness, DOWN, makeAsphaltPart, folder)
				-- Sidewalk corner: the strip between the arc and each
				-- road's own outer edge, fanned from a.Outer.
				previous = a.Kerb
				for _, point in arc do
					FillTriangle(a.Outer, previous, point, thickness, DOWN, makeSidewalkPart, folder)
					previous = point
				end
				FillTriangle(a.Outer, previous, b.Kerb, thickness, DOWN, makeSidewalkPart, folder)
				FillTriangle(a.Outer, b.Kerb, b.Outer, thickness, DOWN, makeSidewalkPart, folder)
			end
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
			local pad = makeAsphaltPart()
			pad.Shape = Enum.PartType.Cylinder
			pad.Size = Vector3.new(thickness, radiusStuds * 2, radiusStuds * 2)
			pad.CFrame = CFrame.new(center + Vector3.new(0, -thickness / 2, 0)) * CFrame.Angles(0, 0, math.rad(90))
			pad.Parent = folder
		end
	end

	folder.Parent = junctionModel
end

return JunctionBuilder
