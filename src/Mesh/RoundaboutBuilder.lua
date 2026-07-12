--!strict
-- Generates a roundabout: a closed, one-way ring road (configurable lane
-- count/width) built from 4 cubic-Bezier quarter-arcs approximating a true
-- circle (the standard "k = 0.5522847498" construction, ~0.03% max radial
-- error) - reuses RoadBuilder.Build completely unmodified, since a closed
-- ring is mechanically just an ordinary road whose curve happens to start
-- and end at the same physical point; every station/curvature/marking
-- query PolyCurve exposes already works across multiple segments, only the
-- single-segment persistence shortcut in RoadBuilder.Build's own stamping
-- step doesn't apply here (handled below).
--
-- CreateAtJunction trims each of the junction's connected spoke roads back
-- to the ring's own boundary (so they no longer visibly run straight
-- through it) and removes the junction node itself, since the ring now
-- serves as the intersection surface in its place. Still v1/rough per
-- TODO.md's phased plan - see its "Junctions & roundabouts" section for
-- exactly what this does and doesn't do (no per-lane merge tapering at
-- each approach, no median island, no in-plugin selection/editing of a
-- placed ring).

local CurveSegment = require("../Geometry/CurveSegment")
local PolyCurve = require("../Geometry/PolyCurve")
local RoadBuilder = require("./RoadBuilder")
local RoadInstance = require("../RoadInstance")
local RoadProfile = require("../RoadProfile")
local RoadSplit = require("../RoadSplit")
local JunctionInstance = require("../JunctionInstance")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")

local RoundaboutBuilder = {}

local ROUNDABOUTS_FOLDER_NAME = "Roundabouts"
local BEZIER_CIRCLE_K = 0.5522847498307936
local RING_TRIM_MARGIN_STUDS = 2

-- True circulates clockwise (viewed from above, +Y up) for DriveOnLeft
-- regions, counter-clockwise otherwise - not yet verified against real
-- regional roundabout convention (only reasoned through, never checked
-- live in Studio); flip the ternary below if it reads backwards once
-- tested.
local function circleSegments(center: Vector3, radiusStuds: number, driveOnLeft: boolean): { CurveSegment.Segment }
	local sign = if driveOnLeft then -1 else 1
	local function pointAt(angle: number): Vector3
		return center + Vector3.new(math.cos(angle) * radiusStuds, 0, math.sin(angle) * radiusStuds)
	end
	local function tangentAt(angle: number): Vector3
		return Vector3.new(-math.sin(angle), 0, math.cos(angle)) * sign
	end
	local handleLength = radiusStuds * BEZIER_CIRCLE_K
	local segments: { CurveSegment.Segment } = {}
	for i = 0, 3 do
		local a0 = sign * (i / 4) * (2 * math.pi)
		local a1 = sign * ((i + 1) / 4) * (2 * math.pi)
		local p0 = pointAt(a0)
		local p3 = pointAt(a1)
		local p1 = p0 + tangentAt(a0) * handleLength
		local p2 = p3 - tangentAt(a1) * handleLength
		table.insert(segments, CurveSegment.Cubic(p0, p1, p2, p3))
	end
	return segments
end

local function getRoundaboutsFolder(): Folder
	local existing = workspace:FindFirstChild(ROUNDABOUTS_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing :: Folder
	end
	local folder = Instance.new("Folder")
	folder.Name = ROUNDABOUTS_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

-- Builds and parents a one-way roundabout ring of `radiusStuds` centred at
-- `center`, with `laneCount` lanes (>= 1) each `laneWidthM` wide.
--
-- The lane stack is flanked by a Sidewalk component on BOTH sides, not just
-- the outer edge - the ring's own frame is built by PolyCurve.FrameAt via
-- CFrame.lookAt, whose local +X (RightVector = tangent x Up) points inward
-- (toward centre) for a DriveOnLeft=false region but OUTWARD for
-- DriveOnLeft=true (reversing the tangent direction reverses RightVector
-- too), so "first component" and "last component" swap which physical edge
-- (inner/outer) they land on depending on the region's driving side. Rather
-- than track that sign, both edges get a sidewalk - the inner one reads as
-- a paved verge/truck apron against the central island's own kerb (built
-- below), which is normal on a real roundabout anyway, and it means this
-- never needs updating if a future style flips DriveOnLeft.
function RoundaboutBuilder.Create(
	center: Vector3,
	radiusStuds: number,
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): Model
	local curve = PolyCurve.new(circleSegments(center, radiusStuds, style.DriveOnLeft))
	local sidewalkComponent: RoadProfile.ProfileComponent =
		{ Kind = "Sidewalk", WidthM = style.SidewalkWidthM, Direction = 0 }
	local components: { RoadProfile.ProfileComponent } = { sidewalkComponent }
	for _ = 1, math.max(1, math.floor(laneCount)) do
		table.insert(components, { Kind = "Drive", WidthM = laneWidthM, Direction = 1 })
	end
	table.insert(components, sidewalkComponent)
	local profile: RoadProfile.RoadProfile = {
		Id = "roundabout_ring",
		Name = "Roundabout",
		Category = "Custom",
		BuiltIn = false,
		Components = components,
	}
	local model = RoadBuilder.Build({
		Curve = curve,
		ProfileStart = profile,
		Style = style,
		Settings = settings,
		Preview = false,
	})
	-- RoadBuilder.Build's multi-segment fallback stamps RW_Road (for
	-- endpoint-snapping) since it doesn't yet know this curve is closed -
	-- clear it so nothing (endpoint snapping, mid-span split, the
	-- selection-based road editor) mistakes this ring for an ordinary,
	-- splittable, single-segment road.
	model:SetAttribute("RW_Road", nil)
	model:SetAttribute("RW_Roundabout", true)
	model.Name = "Roundabout"

	-- Central island: a raised, kerbed disc filling the hole the ring
	-- leaves in the middle, sized to reach exactly the ring's own inner
	-- pavement edge so there's no gap or overlap at the seam. Doesn't need
	-- to know which physical side (inner/outer) is which - ComponentOffsetsM
	-- always centres the whole cross-section on the curve (spans exactly
	-- -halfWidth to +halfWidth), so both edges sit the same radial distance
	-- from the ring's own centreline regardless of DriveOnLeft. Same
	-- raised-part convention RoadBuilder itself uses for every Sidewalk
	-- component (top at curbHeight above the ring's own plane, bottom at
	-- -thickness) so the two meet flush.
	local scale = settings.MetersToStuds
	local thickness = settings.RoadThicknessStuds
	local curbHeight = style.CurbHeightM * scale
	local halfWidthM = RoadProfile.TotalWidthM(profile) / 2
	local islandRadiusStuds = radiusStuds - halfWidthM * scale
	if islandRadiusStuds > 1 then
		local island = Instance.new("Part")
		island.Name = "Island"
		island.Anchored = true
		island.CanCollide = false
		island.CanTouch = false
		island.CanQuery = false
		island.CastShadow = false
		island.TopSurface = Enum.SurfaceType.Smooth
		island.BottomSurface = Enum.SurfaceType.Smooth
		island.Material = Enum.Material.Concrete
		island.Color = style.SidewalkColor
		island.Shape = Enum.PartType.Cylinder
		island.Size = Vector3.new(thickness + curbHeight, islandRadiusStuds * 2, islandRadiusStuds * 2)
		island.CFrame = CFrame.new(center + Vector3.new(0, curbHeight - (thickness + curbHeight) / 2, 0))
			* CFrame.Angles(0, 0, math.rad(90))
		island.Parent = model
	end

	model.Parent = getRoundaboutsFolder()
	return model
end

-- Ground-plane distance - the ring is a ground-plane circle, and a 3D
-- magnitude would under-trim a spoke arriving on a grade (its inner end
-- sits higher/lower than the ring, inflating the distance so the crossing
-- lands too far out). Matches JunctionBuilder's own distanceXZ.
local function distanceXZ(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- The station along `curve`, searched between `fromStation` (assumed
-- inside the ring - at or near the junction centre) and `towardStation`
-- (the spoke's far end), where distance from `center` first reaches
-- `radiusStuds` - nil if the whole span stays inside the ring (the spoke
-- is shorter than the roundabout's own radius, so there's nothing
-- meaningful to trim).
local function findRingCrossing(
	curve: PolyCurve.PolyCurve,
	fromStation: number,
	towardStation: number,
	center: Vector3,
	radiusStuds: number
): number?
	local function distanceAt(s: number): number
		return distanceXZ(curve:PosAt(s), center)
	end
	if distanceAt(towardStation) < radiusStuds then
		return nil
	end
	local lo, hi = fromStation, towardStation
	for _ = 1, 30 do
		local mid = (lo + hi) / 2
		if distanceAt(mid) < radiusStuds then
			lo = mid
		else
			hi = mid
		end
	end
	return (lo + hi) / 2
end

-- Shortens `road` so it stops at the ring's own boundary instead of
-- running through to the junction centre - the inner portion is simply
-- discarded (the ring covers that area now). The rebuilt shorter geometry
-- is TRANSPLANTED into the existing Model (children + attributes swapped
-- in place) rather than destroy-and-replace: destroying the original would
-- fire main.lua's road-removal listener, which would spuriously rebuild
-- the very junction we're about to delete (and each spoke's far junction)
-- mid-loop from inside road:Destroy(). Same in-place approach as
-- JunctionBuilder.trimApproach. The far end (away from the junction) keeps
-- whatever it was connected to; the ring-side end is left unconnected (the
-- ring isn't wired into the junction data model). Leaves `road` untouched
-- if it has an active transition/bay (RoadSplit's own guard) or is shorter
-- than the ring's radius.
--
-- findRingCrossing walks the spoke's CENTERLINE, but the crossing needs to
-- keep the spoke's full cross-section (its sidewalk/kerb edges, which sit
-- `halfWidthStuds` either side of the centerline) inside the ring - not
-- just the centerline point itself. At a centerline point `d` studs from
-- `center`, the laterally-offset edge is `sqrt(d^2 + halfWidthStuds^2)`
-- from `center` (Pythagoras), which is farther out than `d`. Trimming the
-- centerline exactly at `radiusStuds` therefore let the edges poke past
-- the ring's true boundary, showing up as rectangular notches where each
-- spoke's sidewalk cut into the ring. Solving `sqrt(d^2 + h^2) <=
-- radiusStuds` for `d` gives the centerline trim radius below, plus a
-- small margin so the seam sits just inside rather than exactly on it.
local function trimSpokeToRing(
	road: Model,
	junctionId: string,
	center: Vector3,
	radiusStuds: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
)
	if not RoadSplit.CanSplit(road) then
		return
	end
	local data = RoadInstance.Read(road)
	if not data then
		return
	end
	local atStart = data.StartJunctionId == junctionId
	local atEnd = data.EndJunctionId == junctionId
	if not atStart and not atEnd then
		return
	end
	local halfWidthStuds = RoadProfile.TotalWidthM(data.ProfileStart) / 2 * settings.MetersToStuds
	local trimRadiusStuds =
		math.max(0, math.sqrt(math.max(0, radiusStuds ^ 2 - halfWidthStuds ^ 2)) - RING_TRIM_MARGIN_STUDS)
	local curve = data.Curve
	local fromStation = if atStart then 0 else curve.Length
	local towardStation = if atStart then curve.Length else 0
	local crossing = findRingCrossing(curve, fromStation, towardStation, center, trimRadiusStuds)
	if not crossing then
		return
	end
	local segment = curve.Segments[1]
	local outerSegment = if atStart
		then CurveSegment.Sub(segment, crossing, curve.Length)
		else CurveSegment.Sub(segment, 0, crossing)
	local rebuilt = RoadBuilder.Build({
		Curve = PolyCurve.new({ outerSegment }),
		ProfileStart = data.ProfileStart,
		Style = style,
		Settings = settings,
		Preview = false,
	})
	road:ClearAllChildren()
	for name in road:GetAttributes() do
		road:SetAttribute(name, nil)
	end
	for name, value in rebuilt:GetAttributes() do
		road:SetAttribute(name, value)
	end
	for _, child in rebuilt:GetChildren() do
		child.Parent = road
	end
	rebuilt:Destroy()
	local farJunctionId = if atStart then data.EndJunctionId else data.StartJunctionId
	if atStart then
		RoadInstance.StampJunctions(road, nil, farJunctionId)
	else
		RoadInstance.StampJunctions(road, farJunctionId, nil)
	end
end

-- Builds a roundabout replacing the junction `junctionId`: trims every
-- currently-connected spoke road back to the ring's boundary, builds the
-- ring, and removes the junction node (its fillet pad is superseded by
-- the ring). Returns the ring model, or nil if the junction can't be read.
function RoundaboutBuilder.CreateAtJunction(
	junctionId: string,
	radiusStuds: number,
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): Model?
	local junctionModel = JunctionInstance.FindById(junctionId)
	if not junctionModel then
		return nil
	end
	local junctionData = JunctionInstance.Read(junctionModel)
	if not junctionData then
		return nil
	end
	local center = junctionData.Position

	for _, road in JunctionInstance.ConnectedRoads(junctionId) do
		trimSpokeToRing(road, junctionId, center, radiusStuds, style, settings)
	end

	local ring = RoundaboutBuilder.Create(center, radiusStuds, laneCount, laneWidthM, style, settings)
	JunctionInstance.Delete(junctionModel)
	return ring
end

return RoundaboutBuilder
