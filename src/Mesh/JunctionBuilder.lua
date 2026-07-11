--!strict
-- Builds the visible geometry for a JunctionNode (see JunctionInstance.lua):
-- a straight-chamfered pad between the roads that meet here, not just a
-- flat circular pad covering the seam.
--
-- Every connected road contributes, at the station where it meets the
-- junction, its own KERB points (the roadway/non-roadway boundary - where a
-- real kerb physically sits) and OUTER points (the profile's true outer
-- edge, typically a sidewalk's outer/property edge - the same position as
-- the kerb point when the road has no sidewalk). Sorted by angle around the
-- junction centre: between two ADJACENT roads' kerb points, the corner is
-- filled with a STRAIGHT chamfer (a plain triangle fan from the centre
-- through a.Kerb/b.Kerb directly) as the drivable asphalt surface, and the
-- strip between that chamfer and each road's own outer edge is filled
-- separately as the pedestrian corner (sidewalk material). A road's OWN
-- kerb-to-kerb span (both points from the same road) gets the same
-- treatment - that's just its own pavement, fanned directly.
--
-- Previously this rounded each corner with a tangent-continuous quadratic
-- Bézier (the classic "intersect the two tangent lines for the control
-- point" construction) instead of a straight chamfer - closer to how a
-- real kerb looks, but the construction's core weakness (an unbounded
-- control point for near-parallel tangent pairs) kept resurfacing as a
-- self-intersecting spike even after two rounds of capping it (first by
-- angular gap size, then by distance relative to chord length) - each fix
-- closed one specific case without addressing why the construction itself
-- needed a cap at all. Reverted to the straight chamfer this round after a
-- third live report of broken geometry on the same class of junction:
-- two fixed points connected by a straight line can never spike,
-- self-intersect, or need a distance cap, so the entire bug class is gone
-- by construction rather than by another threshold. Real per-corner
-- rounding (a proper fixed-radius fillet tangent to both kerb lines,
-- rather than an unbounded tangent-line intersection) is still worth
-- doing later - see TODO.md.
--
-- A between-road gap wider than MAX_CORNER_SPAN_RADIANS, or between two
-- roads whose outward tangents are roughly opposite (isOpposingPair), is
-- skipped entirely (no fill) rather than chamfered - confirmed live
-- (screenshots of a 2-road bend and multiple T-junctions) that bridging a
-- gap that wraps most of the way around, or connecting what's actually
-- the same through-road split by a branch, isn't a real intersection
-- surface: it's the far side of a bend, or the "through" span between two
-- separate road Models that visually form one straight through road on
-- either side of the branch - there's nothing to pave there, just open
-- space beside the road.
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
-- Beyond this, it's not a corner - leave it unfilled (see isOpposingPair
-- below for the other, tangent-based guard against the same class of
-- non-corner gap).
local MAX_CORNER_SPAN_RADIANS = math.rad(130)
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
		{ Road = road, Kerb = worldPoint(kerbLeftM), Outer = worldPoint(outerLeftM) },
		{ Road = road, Kerb = worldPoint(kerbRightM), Outer = worldPoint(outerRightM) },
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

-- Tangents more than ~120 degrees apart - looser than
-- PASS_THROUGH_DOT_THRESHOLD above (which additionally requires matching
-- profiles and skips the WHOLE junction) and evaluated per ROAD PAIR
-- rather than as a global junction-wide check. Two roads leaving the
-- junction in roughly opposite directions read as "the same through-road,
-- split into two separate Models by a branch here" - there's no real
-- curb-return corner between them - even when their profiles differ (e.g.
-- a highway narrowing into a street) so isSmoothPassThrough can't skip the
-- junction outright, and even when one piece is curved enough right at the
-- junction that the raw angular gap between their KERB POINTS happens to
-- land under MAX_CORNER_SPAN_RADIANS anyway. That gap-size-only check
-- alone still produced an oversized spike (reported live, twice) because
-- it only measures where the two POINTS ended up, not whether the ROADS
-- themselves are actually opposing - this checks the roads' own tangents
-- directly instead of inferring it from point geometry.
local OPPOSING_DOT_THRESHOLD = -0.5

local function isOpposingPair(roadA: Model, roadB: Model, junctionId: string): boolean
	if roadA == roadB then
		return false
	end
	local tangentA = outwardTangentAt(roadA, junctionId)
	local tangentB = outwardTangentAt(roadB, junctionId)
	if not tangentA or not tangentB then
		return false
	end
	return tangentA:Dot(tangentB) < OPPOSING_DOT_THRESHOLD
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
		-- Fan from the CENTROID of the actual kerb points, not the
		-- junction's stored RW_Position - that position is recorded once,
		-- from wherever the first two roads happened to snap together
		-- (JunctionInstance.Create), and never recomputed as more roads
		-- connect later. For a tight-angle fork (confirmed live with a
		-- screenshot: two roads diverging at a narrow angle plus a third
		-- crossing road), the stored position can end up outside the true
		-- kerb-point footprint entirely - fanning triangles from an apex
		-- that isn't actually inside the region they're meant to cover
		-- produces exactly the self-intersecting, jagged-star geometry
		-- reported (as opposed to the earlier spike bugs, which were
		-- oversized but not self-crossing in this way). The centroid of a
		-- point set always lies inside its convex hull, which is what a
		-- fan triangulation actually needs to stay simple (non-crossing).
		local fanCenter = Vector3.zero
		for _, point in edgePoints do
			fanCenter += point.Kerb
		end
		fanCenter /= #edgePoints
		-- Angular order around the fan centre, so adjacent roads' kerb
		-- points are joined by the corner between them rather than the
		-- fan winding back on itself.
		local function angleOf(point: Vector3): number
			return math.atan2(point.Z - fanCenter.Z, point.X - fanCenter.X)
		end
		table.sort(edgePoints, function(a: EdgePoint, b: EdgePoint): boolean
			return angleOf(a.Kerb) < angleOf(b.Kerb)
		end)
		for i = 1, #edgePoints do
			local nextIndex = if i < #edgePoints then i + 1 else 1
			local a = edgePoints[i]
			local b = edgePoints[nextIndex]
			if a.Road == b.Road then
				-- Same road's own kerb-to-kerb span - already its own
				-- pavement, no corner needed; fan it directly (mostly
				-- redundant underlay, but harmless).
				FillTriangle(fanCenter, a.Kerb, b.Kerb, thickness, DOWN, makeAsphaltPart, folder)
			elseif
				not isOpposingPair(a.Road, b.Road, junctionId)
				and (angleOf(b.Kerb) - angleOf(a.Kerb)) % (2 * math.pi) <= MAX_CORNER_SPAN_RADIANS
			then
				-- A gap this wide isn't a genuine corner - it's the far
				-- side of a bend or the "through" span of a T-junction
				-- (two separate road Models forming one visually-straight
				-- through road, on either side of a branch) - there's no
				-- real intersection surface out there, just open space
				-- beside the road. Bridging it anyway produced a wildly
				-- oversized, self-intersecting spike (reported live,
				-- repeatedly) - past this span, just leave it unfilled.
				--
				-- The corner itself is a straight chamfer, not a rounded
				-- arc - see this file's header for why.
				FillTriangle(fanCenter, a.Kerb, b.Kerb, thickness, DOWN, makeAsphaltPart, folder)
				FillTriangle(a.Outer, a.Kerb, b.Kerb, thickness, DOWN, makeSidewalkPart, folder)
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
