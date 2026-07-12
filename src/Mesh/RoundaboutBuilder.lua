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
local FillTriangle = require("./FillTriangle")

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

-- The ring's profile Components - lanes flanked by a Sidewalk on BOTH
-- sides, not just the outer edge. The ring's own frame is built by
-- PolyCurve.FrameAt via CFrame.lookAt, whose local +X (RightVector =
-- tangent x Up) points inward (toward centre) for a DriveOnLeft=false
-- region but OUTWARD for DriveOnLeft=true (reversing the tangent direction
-- reverses RightVector too), so "first component" and "last component"
-- swap which physical edge (inner/outer) they land on depending on the
-- region's driving side. Rather than track that sign, both edges get a
-- sidewalk - the inner one reads as a paved verge/truck apron against the
-- central island's own kerb, which is normal on a real roundabout anyway,
-- and it means this never needs updating if a future style flips
-- DriveOnLeft. Shared by Create and CreateAtJunction's gap-cutting build,
-- which both need to reason about the ring's own total width up front.
local function ringComponents(
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle
): { RoadProfile.ProfileComponent }
	local sidewalkComponent: RoadProfile.ProfileComponent =
		{ Kind = "Sidewalk", WidthM = style.SidewalkWidthM, Direction = 0 }
	local components: { RoadProfile.ProfileComponent } = { sidewalkComponent }
	for _ = 1, math.max(1, math.floor(laneCount)) do
		table.insert(components, { Kind = "Drive", WidthM = laneWidthM, Direction = 1 })
	end
	table.insert(components, sidewalkComponent)
	return components
end

-- Builds and parents, under `model`, a raised kerbed disc filling the hole
-- the ring leaves in the middle - sized via `profile`'s own symmetric
-- ComponentOffsetsM span (-halfWidth to +halfWidth around the centreline,
-- regardless of which physical side is which) to reach exactly the ring's
-- own inner pavement edge with no gap or overlap. Same raised-part
-- convention RoadBuilder itself uses for every Sidewalk component (top at
-- curbHeight above the ring's own plane, bottom at -thickness) so the two
-- meet flush.
local function buildIsland(
	model: Model,
	center: Vector3,
	radiusStuds: number,
	profile: RoadProfile.RoadProfile,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
)
	local scale = settings.MetersToStuds
	local thickness = settings.RoadThicknessStuds
	local curbHeight = style.CurbHeightM * scale
	local halfWidthM = RoadProfile.TotalWidthM(profile) / 2
	local islandRadiusStuds = radiusStuds - halfWidthM * scale
	if islandRadiusStuds <= 1 then
		return
	end
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

-- Builds and parents a one-way roundabout ring of `radiusStuds` centred at
-- `center`, with `laneCount` lanes (>= 1) each `laneWidthM` wide.
function RoundaboutBuilder.Create(
	center: Vector3,
	radiusStuds: number,
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): Model
	local curve = PolyCurve.new(circleSegments(center, radiusStuds, style.DriveOnLeft))
	local components = ringComponents(laneCount, laneWidthM, style)
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
	buildIsland(model, center, radiusStuds, profile, style, settings)
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

-- Kerb (roadway-edge) and Outer (profile's true outer edge) offsets in
-- meters for `profile`'s left and right sides - a raised Sidewalk/Median
-- component sits beyond the roadway's own kerb line. Same distinction
-- JunctionBuilder's own roadwayEdgeOffsetsM draws.
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

export type SpokeCutEdges = {
	LeftKerb: Vector3,
	LeftOuter: Vector3,
	RightKerb: Vector3,
	RightOuter: Vector3,
}

-- Shortens `road` so it stops at `targetRadiusStuds` from `center` instead
-- of running through to the junction centre - the inner portion is simply
-- discarded (the ring covers that area now). The rebuilt shorter geometry
-- is TRANSPLANTED into the existing Model (children + attributes swapped
-- in place) rather than destroy-and-replace: destroying the original would
-- fire main.lua's road-removal listener, which would spuriously rebuild
-- the very junction we're about to delete (and each spoke's far junction)
-- mid-loop from inside road:Destroy(). Same in-place approach as
-- JunctionBuilder.trimApproach. The far end (away from the junction) keeps
-- whatever it was connected to; the ring-side end is left unconnected (the
-- ring isn't wired into the junction data model). Leaves `road` untouched
-- (returns nil) if it has an active transition/bay (RoadSplit's own
-- guard), is shorter than `targetRadiusStuds`, or can't be read.
--
-- `targetRadiusStuds` should be the ring's own OUTER pavement edge (not
-- its centreline) - CreateAtJunction needs every spoke's own edges to
-- reach all the way out to where the ring's actual kerb/sidewalk sits, not
-- stop a whole half-ring-width short of it, which is what passing the
-- centreline radius here did before (a real, if previously unnoticed, gap
-- between the spoke and the ring - it only became visible once the ring
-- itself grew a proper sidewalk).
--
-- findRingCrossing walks the spoke's CENTERLINE, but the crossing needs to
-- keep the spoke's full cross-section (its sidewalk/kerb edges, which sit
-- `halfWidthStuds` either side of the centerline) inside `targetRadiusStuds`
-- - not just the centerline point itself. At a centerline point `d` studs
-- from `center`, the laterally-offset edge is `sqrt(d^2 + halfWidthStuds^2)`
-- from `center` (Pythagoras), which is farther out than `d`. Trimming the
-- centerline exactly at `targetRadiusStuds` therefore lets the edges poke
-- past it. Solving `sqrt(d^2 + h^2) <= targetRadiusStuds` for `d` gives the
-- centerline trim radius below, plus a small margin so the seam sits just
-- inside rather than exactly on it.
--
-- Returns the freshly-trimmed cut end's own edge points (world space, both
-- the roadway/kerb edge and the sidewalk's true outer edge, each side) on
-- success - CreateAtJunction uses these to cut a matching gap in the
-- ring's own outer sidewalk and bridge it to this spoke.
local function trimSpokeToRing(
	road: Model,
	junctionId: string,
	center: Vector3,
	targetRadiusStuds: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): SpokeCutEdges?
	if not RoadSplit.CanSplit(road) then
		return nil
	end
	local data = RoadInstance.Read(road)
	if not data then
		return nil
	end
	local atStart = data.StartJunctionId == junctionId
	local atEnd = data.EndJunctionId == junctionId
	if not atStart and not atEnd then
		return nil
	end
	local halfWidthStuds = RoadProfile.TotalWidthM(data.ProfileStart) / 2 * settings.MetersToStuds
	local trimRadiusStuds =
		math.max(0, math.sqrt(math.max(0, targetRadiusStuds ^ 2 - halfWidthStuds ^ 2)) - RING_TRIM_MARGIN_STUDS)
	local curve = data.Curve
	local fromStation = if atStart then 0 else curve.Length
	local towardStation = if atStart then curve.Length else 0
	local crossing = findRingCrossing(curve, fromStation, towardStation, center, trimRadiusStuds)
	if not crossing then
		return nil
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

	local newData = RoadInstance.Read(road)
	if not newData then
		return nil
	end
	local cutStation = if atStart then 0 else newData.Curve.Length
	local cutProfile = if atStart then newData.ProfileStart else (newData.ProfileEnd or newData.ProfileStart)
	local offsets = RoadProfile.ComponentOffsetsM(cutProfile)
	if #offsets == 0 then
		return nil
	end
	local kerbLeftM, kerbRightM = roadwayEdgeOffsetsM(cutProfile)
	local outerLeftM, outerRightM = offsets[1].Left, offsets[#offsets].Right
	local frame = newData.Curve:FrameAt(cutStation)
	local scale = settings.MetersToStuds
	local function worldPoint(offsetM: number): Vector3
		return (frame * CFrame.new(offsetM * scale, 0, 0)).Position
	end
	return {
		LeftKerb = worldPoint(kerbLeftM),
		LeftOuter = worldPoint(outerLeftM),
		RightKerb = worldPoint(kerbRightM),
		RightOuter = worldPoint(outerRightM),
	}
end

local DOWN = Vector3.new(0, -1, 0)

-- Builds a roundabout replacing the junction `junctionId`: trims every
-- currently-connected spoke road back to the ring's own OUTER pavement
-- edge (not just its centreline - see trimSpokeToRing for why that
-- distinction matters), cuts a matching gap in the ring's own outer
-- sidewalk at each spoke's connection point so the ring's sidewalk band
-- doesn't sit in the way of the spoke's driving lanes (reported live as
-- the ring's pavement "clipping through" a feeder's lanes at the join),
-- bridges each gap's cut sidewalk edges to the spoke's own sidewalk edges
-- with a plain two-triangle quad, then removes the junction node (its
-- fillet pad is superseded by the ring). Returns the ring model, or nil if
-- the junction can't be read.
--
-- The ring's DRIVE LANES are never cut, only its outer sidewalk band -
-- ExcludeComponentIndices skips just the first/last (Sidewalk) components
-- across each gap's station range, so the ring stays fully driveable
-- straight through every junction point. A spoke's own asphalt reaching
-- the ring's outer radius therefore overlaps a little into the ring's own
-- lane area in the gap zone - harmless (same material, same height, no
-- visible seam), and far simpler than computing an exact non-overlapping
-- asphalt handoff.
--
-- The bridge quad deliberately reuses the plain a.Outer-a.Kerb-b.Kerb-
-- b.Outer shape JunctionBuilder's cornerBoundaries falls back to for an
-- ordinary straight chamfer (already proven correct) rather than a
-- fillet-arc curve fit - that arc-fitting code is exactly what needed a
-- sign-error fix earlier this same round, so a second, independent
-- attempt at it here isn't worth the risk for what's fundamentally a
-- small, already-mostly-curved seam (both the ring's edge and the spoke's
-- edge are already smooth curves arriving at the gap; the straight bridge
-- between them reads as a continuation, not a sharp kink).
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
	local scale = settings.MetersToStuds

	local components = ringComponents(laneCount, laneWidthM, style)
	local profile: RoadProfile.RoadProfile = {
		Id = "roundabout_ring",
		Name = "Roundabout",
		Category = "Custom",
		BuiltIn = false,
		Components = components,
	}
	local halfWidthStuds = RoadProfile.TotalWidthM(profile) / 2 * scale
	local outerRadiusStuds = radiusStuds + halfWidthStuds
	local curve = PolyCurve.new(circleSegments(center, radiusStuds, style.DriveOnLeft))

	-- Trim every spoke to the ring's outer edge, recording a gap (a
	-- station interval on the ring's own curve, found via ClosestS on the
	-- spoke's OWN cut-end edge points - so it always matches the spoke's
	-- real width exactly, not an assumed angular span) for each one that
	-- actually got trimmed. `Lo`/`Hi` are tagged by whichever of the
	-- spoke's own Left/Right edge points has the smaller/larger station,
	-- purely from the computed values - no assumption about which
	-- physical side that corresponds to.
	local gaps: { { Lo: number, Hi: number, LoOuter: Vector3, LoKerb: Vector3, HiOuter: Vector3, HiKerb: Vector3 } } =
		{}
	for _, road in JunctionInstance.ConnectedRoads(junctionId) do
		local edges = trimSpokeToRing(road, junctionId, center, outerRadiusStuds, style, settings)
		if edges then
			local sLeft = curve:ClosestS(edges.LeftOuter)
			local sRight = curve:ClosestS(edges.RightOuter)
			if sLeft <= sRight then
				table.insert(gaps, {
					Lo = sLeft,
					Hi = sRight,
					LoOuter = edges.LeftOuter,
					LoKerb = edges.LeftKerb,
					HiOuter = edges.RightOuter,
					HiKerb = edges.RightKerb,
				})
			else
				table.insert(gaps, {
					Lo = sRight,
					Hi = sLeft,
					LoOuter = edges.RightOuter,
					LoKerb = edges.RightKerb,
					HiOuter = edges.LeftOuter,
					HiKerb = edges.LeftKerb,
				})
			end
		end
	end
	table.sort(gaps, function(a, b)
		return a.Lo < b.Lo
	end)

	local ring = Instance.new("Model")
	ring.Name = "Roundabout"

	-- The two Sidewalk components are always first and last (see
	-- ringComponents) - excluded together across each gap's station range.
	-- Only the side actually facing the feeder needs the opening, but
	-- excluding both is harmless (the ring's inner sidewalk, against the
	-- island, isn't near any feeder) and avoids having to determine which
	-- physical side is which here too.
	local sidewalkIndices = { 1, #components }
	local function buildSpan(fromStation: number, toStation: number, excludeSidewalks: boolean)
		if toStation - fromStation < 1e-3 then
			return
		end
		local piece = RoadBuilder.Build({
			Curve = curve:Slice(fromStation, toStation),
			ProfileStart = profile,
			Style = style,
			Settings = settings,
			Preview = false,
			ExcludeComponentIndices = if excludeSidewalks then sidewalkIndices else nil,
		})
		for _, child in piece:GetChildren() do
			child.Parent = ring
		end
		piece:Destroy()
	end

	-- `Lo` clamped to never go backward relative to `cursor` (guards
	-- pathologically close/overlapping gaps - two feeders placed closer
	-- together than their own combined width - degrading to a zero-length,
	-- harmlessly-skipped paved span between them rather than an inverted
	-- station range).
	local cursor = 0
	for _, gap in gaps do
		local lo = math.max(gap.Lo, cursor)
		local hi = math.max(gap.Hi, lo)
		buildSpan(cursor, lo, false)
		buildSpan(lo, hi, true)
		cursor = hi
	end
	buildSpan(cursor, curve.Length, false)

	ring:SetAttribute("RW_Roundabout", true)
	buildIsland(ring, center, radiusStuds, profile, style, settings)

	-- Bridge each gap: connect the ring's own outer-sidewalk edge (computed
	-- analytically at the exact gap-boundary station, even though no Part
	-- was built there) to the spoke's real edge point recorded above.
	local thickness = settings.RoadThicknessStuds
	local curbHeight = style.CurbHeightM * scale
	local sidewalkDepth = thickness + curbHeight
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	local outerLeftM, outerRightM = offsets[1].Left, offsets[#offsets].Right
	local kerbLeftM, kerbRightM = roadwayEdgeOffsetsM(profile)
	local function raise(point: Vector3): Vector3
		return point + Vector3.new(0, curbHeight, 0)
	end
	local function makeBridgePart(): Part
		local part = Instance.new("Part")
		part.Name = "RoundaboutBridge"
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Material = Enum.Material.Concrete
		part.Color = style.SidewalkColor
		return part
	end
	-- Picks whichever side (left or right) of the ring's cross-section at
	-- `station` is physically closer to `targetOuter` (the spoke's own
	-- edge point) - not an assumed "outer = first/last component" side,
	-- since which physical edge that is flips with DriveOnLeft (see
	-- ringComponents). Proximity is unambiguous regardless of that sign.
	local function ringEdgeNear(station: number, targetOuter: Vector3): (Vector3, Vector3)
		local frame = curve:FrameAt(station)
		local leftOuter = (frame * CFrame.new(outerLeftM * scale, 0, 0)).Position
		local rightOuter = (frame * CFrame.new(outerRightM * scale, 0, 0)).Position
		local leftKerb = (frame * CFrame.new(kerbLeftM * scale, 0, 0)).Position
		local rightKerb = (frame * CFrame.new(kerbRightM * scale, 0, 0)).Position
		if (leftOuter - targetOuter).Magnitude <= (rightOuter - targetOuter).Magnitude then
			return leftOuter, leftKerb
		end
		return rightOuter, rightKerb
	end
	for _, gap in gaps do
		local ringLoOuter, ringLoKerb = ringEdgeNear(gap.Lo, gap.LoOuter)
		local ringHiOuter, ringHiKerb = ringEdgeNear(gap.Hi, gap.HiOuter)
		FillTriangle(
			raise(ringLoOuter),
			raise(ringLoKerb),
			raise(gap.LoKerb),
			sidewalkDepth,
			DOWN,
			makeBridgePart,
			ring
		)
		FillTriangle(
			raise(ringLoOuter),
			raise(gap.LoKerb),
			raise(gap.LoOuter),
			sidewalkDepth,
			DOWN,
			makeBridgePart,
			ring
		)
		FillTriangle(
			raise(ringHiOuter),
			raise(ringHiKerb),
			raise(gap.HiKerb),
			sidewalkDepth,
			DOWN,
			makeBridgePart,
			ring
		)
		FillTriangle(
			raise(ringHiOuter),
			raise(gap.HiKerb),
			raise(gap.HiOuter),
			sidewalkDepth,
			DOWN,
			makeBridgePart,
			ring
		)
	end

	ring.Parent = getRoundaboutsFolder()
	JunctionInstance.Delete(junctionModel)
	return ring
end

return RoundaboutBuilder
