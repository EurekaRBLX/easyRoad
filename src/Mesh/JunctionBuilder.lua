--!strict
-- Builds the visible geometry for a JunctionNode (see JunctionInstance.lua):
-- a solid pad covering the CONVEX HULL of every connected road's kerb
-- points, not a per-corner decision about which gaps to bridge.
--
-- Every connected road contributes, at the station where it meets the
-- junction, its own KERB points (the roadway/non-roadway boundary - where a
-- real kerb physically sits) and OUTER points (the profile's true outer
-- edge, typically a sidewalk's outer/property edge - the same position as
-- the kerb point when the road has no sidewalk). `convexHull` computes the
-- true outer boundary of all the KERB points (2D, on the ground plane) via
-- the standard monotone-chain construction; that boundary is fan-
-- triangulated from one of its own vertices for the asphalt, and the strip
-- between each cross-road hull edge and the corresponding OUTER points is
-- filled as the pedestrian corner (sidewalk material).
--
-- A convex polygon can ALWAYS be validly fan-triangulated from any of its
-- own vertices - no self-intersection is possible, by construction. This
-- replaces an entire lineage of per-pair heuristics (a tangent-continuous
-- Bézier corner, then a straight chamfer, in both cases deciding case by
-- case whether a given gap between two points was "a real corner" via an
-- angular-span threshold and/or a tangent-opposition check, then fanning
-- from a single junction-wide apex point) that kept producing broken
-- geometry through five separate rounds of live reports and fixes: an
-- unbounded Bézier control point for near-parallel pairs (twice), a fan
-- apex outside the true boundary on a tight fork, and - even after
-- switching to a straight chamfer - the same self-intersection risk any
-- time the per-pair "walk consecutive angle-sorted points" ordering didn't
-- match the true boundary ordering. A convex hull sidesteps all of that:
-- there's no per-pair judgement call left to get wrong, and no apex-choice
-- problem, because "fan from any hull vertex" is unconditionally safe for
-- a convex shape. See TODO.md for the trade-off this makes (every
-- connected road's kerb points end up inside one continuous pad, matching
-- how a real intersection actually looks - see the Google Maps references
-- from earlier in this project - rather than leaving gaps unfilled for
-- roads meeting at a very oblique angle) and what's still worth doing
-- later (rounded corners via a proper fixed-radius fillet, and per-lane
-- markings through the junction).
--
-- Skips itself entirely for a plain two-road pass-through (matching
-- profiles, roughly opposite outward directions) - a chained straight or
-- gently-curving continuation doesn't need any pad at all.

local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")
local RoadInstance = require("../RoadInstance")
local JunctionInstance = require("../JunctionInstance")
local FillTriangle = require("./FillTriangle")

local JunctionBuilder = {}

local PAD_MARGIN_STUDS = 2 -- Extra reach beyond the widest connected road's half-width (fallback pad only)
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

-- 2D cross product (XZ plane, ground plane) of (a - o) and (b - o) - the
-- standard turn test: positive means b is to the left of the line o->a
-- extended, negative means right, zero means collinear.
local function cross2D(o: Vector3, a: Vector3, b: Vector3): number
	return (a.X - o.X) * (b.Z - o.Z) - (a.Z - o.Z) * (b.X - o.X)
end

-- The convex hull of `points`' Kerb positions (2D, ground plane), via the
-- standard Andrew's monotone chain construction: sort by X (ties by Z),
-- then sweep building a lower and upper chain, popping the last point
-- whenever the turn it makes isn't a left turn. Returns hull vertices in
-- order (their EdgePoint records, not just positions) - a point that ends
-- up strictly inside the hull (dominated by its neighbours) is dropped
-- entirely, same as any convex hull algorithm. Degenerates to returning
-- `points` unchanged when there are 3 or fewer (always already convex).
local function convexHull(points: { EdgePoint }): { EdgePoint }
	if #points <= 3 then
		return points
	end
	local sorted = table.clone(points)
	table.sort(sorted, function(a: EdgePoint, b: EdgePoint): boolean
		if a.Kerb.X ~= b.Kerb.X then
			return a.Kerb.X < b.Kerb.X
		end
		return a.Kerb.Z < b.Kerb.Z
	end)
	local lower: { EdgePoint } = {}
	for _, p in sorted do
		while #lower >= 2 and cross2D(lower[#lower - 1].Kerb, lower[#lower].Kerb, p.Kerb) <= 0 do
			table.remove(lower)
		end
		table.insert(lower, p)
	end
	local upper: { EdgePoint } = {}
	for i = #sorted, 1, -1 do
		local p = sorted[i]
		while #upper >= 2 and cross2D(upper[#upper - 1].Kerb, upper[#upper].Kerb, p.Kerb) <= 0 do
			table.remove(upper)
		end
		table.insert(upper, p)
	end
	table.remove(lower) -- last point of each chain is the first of the other
	table.remove(upper)
	local hull: { EdgePoint } = {}
	for _, p in lower do
		table.insert(hull, p)
	end
	for _, p in upper do
		table.insert(hull, p)
	end
	return hull
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
		local hull = convexHull(edgePoints)
		-- A convex polygon can always be fan-triangulated from any of its
		-- own vertices without self-intersecting - unlike a fixed external
		-- apex (the junction's stored position, or even the point set's
		-- own centroid), which can end up outside the true boundary for an
		-- oddly-shaped set of roads and produce exactly the crossing,
		-- jagged geometry reported live through several earlier rounds.
		local apex = hull[1].Kerb
		for i = 2, #hull - 1 do
			FillTriangle(apex, hull[i].Kerb, hull[i + 1].Kerb, thickness, DOWN, makeAsphaltPart, folder)
		end
		-- Sidewalk corners: walk every boundary edge of the hull (not just
		-- the ones the fan above used as diagonals - the two edges
		-- touching the apex vertex are boundary edges too, just never
		-- explicitly visited by the fan loop). A hull edge between two
		-- DIFFERENT roads is a real corner - fill the pedestrian strip
		-- between it and each road's own outer (e.g. sidewalk) edge. A
		-- hull edge between the SAME road's own two kerb points needs no
		-- corner treatment (that's just its own pavement, already built
		-- by RoadBuilder).
		for i = 1, #hull do
			local a = hull[i]
			local b = hull[if i < #hull then i + 1 else 1]
			if a.Road ~= b.Road then
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
