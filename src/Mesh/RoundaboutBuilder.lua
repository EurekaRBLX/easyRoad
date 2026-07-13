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
-- CreateAtJunction trims each connected spoke back past the ring's outer
-- pavement by SETBACK_STUDS, fills the setback span with a ruled asphalt
-- mouth band + circular entry/exit flares + raised sidewalk bridges, then
-- removes the junction node (the ring is the intersection surface). Still
-- rough per TODO.md on per-lane merge tapering, yield markings, and
-- in-plugin selection/editing of a placed ring.

local CurveSegment = require("../Geometry/CurveSegment")
local Fillet = require("../Geometry/Fillet")
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
-- Small safety so the spoke's outermost cross-section edge lands just
-- inside the setback target rather than exactly on it (floating-point and
-- strip-anchoring can otherwise leave a hairline of the spoke past the cut).
local RING_TRIM_MARGIN_STUDS = 0.5
-- Pull every feeder back past the ring's outer pavement edge so entry/exit
-- flares and the mouth-fill band have real room to read as feed-in / feed-out
-- lanes (requested live: "the setback can alter the neighbouring roads for
-- feed in and out lanes"). Without this the spoke asphalt ends flush against
-- the ring and the flares only fill two tiny corner wedges - with no middle
-- fill that looks like a broken, notched join (see road_abc / live reports).
local SETBACK_STUDS = 10
-- Samples along the mouth's ring-side kerb arc for the ruled asphalt fill
-- between the setback cut and the ring.
local MOUTH_ARC_SAMPLES = 8

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

-- The ring's profile Components - lanes with a Sidewalk on the OUTER edge
-- only. No pavement is needed on the inner edge (facing the island) - real
-- roundabouts don't have a pedestrian strip there either, and the island
-- itself (built below) reaches right up to the lanes instead.
--
-- Which physical side (first or last in the list) is the OUTER edge
-- depends on the region's driving side: the ring's own frame is built by
-- PolyCurve.FrameAt via CFrame.lookAt, whose local +X (RightVector =
-- LookVector x UpVector - verified against Roblox's own identity CFrame,
-- Look=(0,0,-1)/Up=(0,1,0)/Right=(1,0,0)) points inward (toward centre)
-- for a DriveOnLeft=false region but outward for DriveOnLeft=true
-- (reversing the tangent direction reverses RightVector too). Positive
-- ComponentOffsetsM values are the LAST component (walks from -total/2 to
-- +total/2), which sits in the RightVector direction - so for
-- DriveOnLeft=false, "last component" = inward = the sidewalk belongs
-- FIRST; for DriveOnLeft=true it's the opposite.
--
-- Shared by Create and CreateAtJunction's gap-cutting build, which both
-- need this to reason about which edge to size the island against.
local function ringComponents(
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle
): { RoadProfile.ProfileComponent }
	local components: { RoadProfile.ProfileComponent } = {}
	for _ = 1, math.max(1, math.floor(laneCount)) do
		table.insert(components, { Kind = "Drive", WidthM = laneWidthM, Direction = 1 })
	end
	local sidewalkComponent: RoadProfile.ProfileComponent =
		{ Kind = "Sidewalk", WidthM = style.SidewalkWidthM, Direction = 0 }
	if style.DriveOnLeft then
		table.insert(components, sidewalkComponent)
	else
		table.insert(components, 1, sidewalkComponent)
	end
	return components
end

-- The ring's own inner pavement edge (the lane boundary facing the
-- island, on whichever side has no sidewalk - see ringComponents), as a
-- positive distance in meters from the centreline.
local function ringInnerHalfWidthM(profile: RoadProfile.RoadProfile, style: RegionStyles.RegionStyle): number
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	if style.DriveOnLeft then
		return -offsets[1].Left
	end
	return offsets[#offsets].Right
end

-- Builds and parents, under `model`, a raised kerbed disc filling the hole
-- the ring leaves in the middle - sized to reach exactly the ring's own
-- inner LANE edge (not a symmetric half-width - there's no sidewalk on
-- that side any more, so the island can extend right up to the traffic
-- lanes) with no gap or overlap. Same raised-part convention RoadBuilder
-- itself uses for every Sidewalk component (top at curbHeight above the
-- ring's own plane, bottom at -thickness) so the two meet flush.
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
	local islandRadiusStuds = radiusStuds - ringInnerHalfWidthM(profile, style) * scale
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

-- Settings clone with superelevation forced OFF, for building the ring's
-- own pavement. In Auto mode Superelevation.RollAt banks ANY curve by the
-- highway design formula, and a roundabout-sized radius (e.g. 30 studs =
-- ~8.4m) at any realistic design speed saturates the formula at the
-- region's MAXIMUM superelevation - so the ring was being built as a
-- maximally-banked circle of hundreds of short tilted strips, reported
-- live as "a lot of humps and lumps" across the circulating lane. Real
-- roundabouts are never superelevated (they're low-speed geometry, often
-- deliberately built with adverse crossfall); the ring is always flat.
-- Spoke roads keep the caller's real settings - they're ordinary roads,
-- and their own per-segment runoff already tapers bank to zero at ends.
local function flatSettings(settings: Settings.EasyRoadSettings): Settings.EasyRoadSettings
	local clone = table.clone(settings)
	clone.SuperelevationMode = "Off"
	return clone
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
		Settings = flatSettings(settings),
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
	-- Ground-plane unit direction the spoke's cut end faces - from the cut
	-- toward the ring/junction centre. The entry/exit flare construction
	-- needs the direction each kerb EDGE LINE runs in, which is parallel to
	-- this (the kerb lines run alongside the centreline).
	Inward: Vector3,
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
	-- Direction the cut end faces (toward the ring centre): the curve's
	-- tangent at the cut, flipped when the junction was at the road's start
	-- (tangent at 0 points AWAY from the junction, along the road).
	local tangent = newData.Curve:TangentAt(cutStation)
	local inward = if atStart then -tangent else tangent
	inward = Vector3.new(inward.X, 0, inward.Z)
	if inward.Magnitude < 1e-6 then
		return nil
	end
	return {
		LeftKerb = worldPoint(kerbLeftM),
		LeftOuter = worldPoint(outerLeftM),
		RightKerb = worldPoint(kerbRightM),
		RightOuter = worldPoint(outerRightM),
		Inward = inward.Unit,
	}
end

local DOWN = Vector3.new(0, -1, 0)

-- Radius for the asphalt entry/exit flare arc where a feeder's kerb line
-- meets the ring's own outer kerb line - larger than an urban street
-- corner's kerb return (roundabout entries are designed to be driven at
-- speed, not turned into from a stop). Sized to work with SETBACK_STUDS
-- so the curve has room to develop between the setback cut and the ring.
local FLARE_RADIUS_M = 10
local FLARE_ARC_SAMPLES = 5

-- Shortest station path on a closed ring curve from sA to sB (inclusive
-- endpoints), as `samples + 1` points. Prefers the short arc so a mouth
-- that straddles the station-0 seam still walks only across the mouth,
-- not the long way around the whole ring.
local function sampleRingStations(sA: number, sB: number, length: number, samples: number): { number }
	local forward = (sB - sA) % length
	if forward < 0 then
		forward += length
	end
	local backward = length - forward
	local delta = if forward <= backward then forward else -(backward)
	local out: { number } = {}
	for i = 0, samples do
		local t = i / samples
		local s = (sA + delta * t) % length
		if s < 0 then
			s += length
		end
		-- Keep the final sample exactly at sB (avoids % rounding away from
		-- the endpoint when delta is negative and t == 1).
		if i == samples then
			s = sB
		elseif i == 0 then
			s = sA
		end
		table.insert(out, s)
	end
	return out
end

local function lerp3(a: Vector3, b: Vector3, t: number): Vector3
	return a + (b - a) * t
end

-- Builds a roundabout replacing the junction `junctionId`: trims every
-- currently-connected spoke road back past the ring's OUTER pavement edge
-- by SETBACK_STUDS (so feed-in/out geometry has room), cuts a matching gap
-- in the ring's own outer sidewalk at each spoke's angular mouth, fills the
-- setback span with a ruled asphalt MOUTH band (spoke cut cross-section ->
-- ring outer kerb arc), fills each mouth corner with an asphalt entry/exit
-- FLARE (Fillet.Compute circular arc between spoke kerb and ring kerb),
-- bridges the raised sidewalk at each mouth side, then removes the junction
-- node. Returns the ring model, or nil if the junction can't be read.
--
-- The ring's DRIVE LANES are never cut, only its outer sidewalk band -
-- ExcludeComponentIndices skips just the Sidewalk component across each
-- gap's station range, so the ring stays fully driveable straight through
-- every junction point.
--
-- The flares are deliberately DECK-LEVEL asphalt (worst failure = flat on
-- flat, never a raised obstacle). The mouth band is the piece that was
-- missing in v1: without it, setback alone opens bare ground across the
-- middle of every feeder mouth (flares only bridge the two corner wedges).
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

	-- Defensively clear the junction's own pad `Geometry` (JunctionBuilder's
	-- convex-hull fan, from whenever this junction was last rebuilt as an
	-- ordinary intersection) up front, not just relying on the
	-- JunctionInstance.Delete call at the very end of this function - if
	-- anything below this point were to error out partway through, the old
	-- pad would otherwise be left showing through the new ring/island
	-- (reported live as a fan of thin shards visible inside the island).
	local staleGeometry = junctionModel:FindFirstChild("Geometry")
	if staleGeometry then
		staleGeometry:Destroy()
	end

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
	-- Spoke cut lands SETBACK past the ring's outer pavement edge so the
	-- mouth band + flares have a real feed-in/out span to fill.
	local setbackTargetRadius = outerRadiusStuds + SETBACK_STUDS
	local curve = PolyCurve.new(circleSegments(center, radiusStuds, style.DriveOnLeft))

	local kerbLeftM, kerbRightM = roadwayEdgeOffsetsM(profile)
	-- The ring's outer lane edge (kerb) offset: positive ComponentOffsetsM
	-- side points outward for DriveOnLeft and inward otherwise - see
	-- ringComponents' derivation.
	local outerKerbM = if style.DriveOnLeft then kerbRightM else kerbLeftM
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	local outerSidewalkM = if style.DriveOnLeft then offsets[#offsets].Right else offsets[1].Left

	-- Trim every spoke to the setback target, recording per spoke: the
	-- station interval its mouth spans on the ring (sidewalk EXCLUSION +
	-- mouth-fill arc), edge points at the setback cut, and flare anchors.
	--
	-- A spoke whose mouth straddles the ring curve's own start/end seam
	-- yields ClosestS values on opposite extremes - naively treating
	-- [min, max] as the mouth would exclude the sidewalk around almost the
	-- WHOLE ring. Detected by the interval spanning more than half the
	-- circumference and split into the two end fragments for exclusion
	-- only; mouth fill still walks the short arc via sampleRingStations.
	type FlareAnchor = {
		Station: number,
		Kerb: Vector3,
		Outer: Vector3,
		Inward: Vector3,
	}
	type Mouth = {
		Edges: SpokeCutEdges,
		SLeft: number,
		SRight: number,
	}
	local exclusions: { { Lo: number, Hi: number } } = {}
	local flares: { FlareAnchor } = {}
	local mouths: { Mouth } = {}
	for _, road in JunctionInstance.ConnectedRoads(junctionId) do
		local edges = trimSpokeToRing(road, junctionId, center, setbackTargetRadius, style, settings)
		if edges then
			local sLeft = curve:ClosestS(edges.LeftOuter)
			local sRight = curve:ClosestS(edges.RightOuter)
			local lo = math.min(sLeft, sRight)
			local hi = math.max(sLeft, sRight)
			if hi - lo > curve.Length / 2 then
				table.insert(exclusions, { Lo = hi, Hi = curve.Length })
				table.insert(exclusions, { Lo = 0, Hi = lo })
			else
				table.insert(exclusions, { Lo = lo, Hi = hi })
			end
			table.insert(mouths, { Edges = edges, SLeft = sLeft, SRight = sRight })
			table.insert(flares, {
				Station = sLeft,
				Kerb = edges.LeftKerb,
				Outer = edges.LeftOuter,
				Inward = edges.Inward,
			})
			table.insert(flares, {
				Station = sRight,
				Kerb = edges.RightKerb,
				Outer = edges.RightOuter,
				Inward = edges.Inward,
			})
		end
	end
	table.sort(exclusions, function(a, b)
		return a.Lo < b.Lo
	end)

	local ring = Instance.new("Model")
	ring.Name = "Roundabout"

	-- The single Sidewalk component is first or last depending on
	-- DriveOnLeft (see ringComponents) - excluded across each gap's
	-- station range so the ring's outer sidewalk opens up for the feeder.
	-- Built with superelevation forced off (see flatSettings above) - the
	-- ring is never banked.
	local ringSettings = flatSettings(settings)
	local sidewalkIndices = { if style.DriveOnLeft then #components else 1 }
	local function buildSpan(fromStation: number, toStation: number, excludeSidewalks: boolean)
		if toStation - fromStation < 1e-3 then
			return
		end
		local piece = RoadBuilder.Build({
			Curve = curve:Slice(fromStation, toStation),
			ProfileStart = profile,
			Style = style,
			Settings = ringSettings,
			Preview = false,
			ExcludeComponentIndices = if excludeSidewalks then sidewalkIndices else nil,
		})
		for _, child in piece:GetChildren() do
			child.Parent = ring
		end
		piece:Destroy()
	end

	-- `Lo` clamped to never go backward relative to `cursor` (guards
	-- pathologically close/overlapping exclusions - two feeders placed
	-- closer together than their own combined width - degrading to a
	-- zero-length, harmlessly-skipped paved span between them rather than
	-- an inverted station range).
	local cursor = 0
	for _, exclusion in exclusions do
		local lo = math.max(exclusion.Lo, cursor)
		local hi = math.max(exclusion.Hi, lo)
		buildSpan(cursor, lo, false)
		buildSpan(lo, hi, true)
		cursor = hi
	end
	buildSpan(cursor, curve.Length, false)

	ring:SetAttribute("RW_Roundabout", true)
	buildIsland(ring, center, radiusStuds, profile, style, settings)

	local thickness = settings.RoadThicknessStuds
	local curbHeight = style.CurbHeightM * scale
	local sidewalkDepth = thickness + curbHeight
	-- Mouth fill / flares sit 0.02 studs below deck: they overlap both the
	-- spoke's and the ring's own asphalt where they meet, and three coplanar
	-- surfaces z-fight (flickering streaks). 0.02 is invisible as a step.
	local sink = Vector3.new(0, -0.02, 0)
	local function raise(point: Vector3): Vector3
		return point + Vector3.new(0, curbHeight, 0)
	end

	local function makeAsphaltPart(): Part
		local part = Instance.new("Part")
		part.Name = "RoundaboutMouth"
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
	local function makeFlarePart(): Part
		local part = makeAsphaltPart()
		part.Name = "RoundaboutFlare"
		return part
	end
	local function makeSidewalkPart(): Part
		local part = Instance.new("Part")
		part.Name = "RoundaboutMouthSidewalk"
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

	local function ringPointAt(station: number, offsetM: number): Vector3
		local frame = curve:FrameAt(station)
		return (frame * CFrame.new(offsetM * scale, 0, 0)).Position
	end

	-- Mouth asphalt: ruled band from the spoke's setback cut (LeftKerb ->
	-- RightKerb) to the ring's outer kerb arc across the mouth. This is
	-- what makes setback safe - without it the middle of every feeder mouth
	-- would be bare ground between the two corner flares.
	for _, mouth in mouths do
		local stations = sampleRingStations(mouth.SLeft, mouth.SRight, curve.Length, MOUTH_ARC_SAMPLES)
		local n = #stations
		if n >= 2 then
			for i = 1, n - 1 do
				local t0 = (i - 1) / (n - 1)
				local t1 = i / (n - 1)
				local a0 = lerp3(mouth.Edges.LeftKerb, mouth.Edges.RightKerb, t0) + sink
				local a1 = lerp3(mouth.Edges.LeftKerb, mouth.Edges.RightKerb, t1) + sink
				local r0 = ringPointAt(stations[i], outerKerbM) + sink
				local r1 = ringPointAt(stations[i + 1], outerKerbM) + sink
				FillTriangle(a0, a1, r1, thickness, DOWN, makeAsphaltPart, ring)
				FillTriangle(a0, r1, r0, thickness, DOWN, makeAsphaltPart, ring)
			end
		end
	end

	-- Entry/exit flares: a deck-level asphalt fillet on each side of each
	-- spoke's mouth, between the spoke's own kerb line (direction: Inward,
	-- since kerb lines run parallel to the centreline) and the ring's outer
	-- kerb line (locally approximated by its tangent at the flare station).
	-- Ring tangent orientation is picked by which way faces the spoke (dot
	-- test) - no CW/CCW or DriveOnLeft sign-tracking.
	for _, flare in flares do
		local ringKerb = ringPointAt(flare.Station, outerKerbM)
		local toSpoke = Vector3.new(flare.Kerb.X - ringKerb.X, 0, flare.Kerb.Z - ringKerb.Z)
		local tangent = curve:TangentAt(flare.Station)
		tangent = Vector3.new(tangent.X, 0, tangent.Z)
		if toSpoke.Magnitude > 1e-3 and tangent.Magnitude > 1e-6 then
			tangent = tangent.Unit
			local inwardRing = if tangent:Dot(toSpoke) >= 0 then tangent else -tangent
			local p1, arcCenter, p2, arcRadius =
				Fillet.Compute(flare.Kerb, flare.Inward, ringKerb, inwardRing, FLARE_RADIUS_M * scale)
			if p1 and arcCenter and p2 and arcRadius then
				local boundary: { Vector3 } = { flare.Kerb + sink, p1 + sink }
				for _, point in Fillet.SampleArc(arcCenter, arcRadius, p1, p2, FLARE_ARC_SAMPLES) do
					table.insert(boundary, point + sink)
				end
				table.insert(boundary, p2 + sink)
				table.insert(boundary, ringKerb + sink)
				for j = 1, #boundary - 1 do
					FillTriangle(boundary[1], boundary[j], boundary[j + 1], thickness, DOWN, makeFlarePart, ring)
				end

				-- Raised sidewalk band outside the flare: same kerb arc,
				-- outer edge from spoke Outer -> ring outer-sidewalk point
				-- at this station. Mirrors JunctionBuilder's corner sidewalk
				-- band so the feeder's pavement continues into the ring's
				-- sidewalk opening instead of ending as a hard cut.
				local ringOuter = ringPointAt(flare.Station, outerSidewalkM)
				local outerBoundary: { Vector3 } = { flare.Outer }
				local kerbBoundary: { Vector3 } = { flare.Kerb, p1 }
				for _, point in Fillet.SampleArc(arcCenter, arcRadius, p1, p2, FLARE_ARC_SAMPLES) do
					table.insert(kerbBoundary, point)
				end
				table.insert(kerbBoundary, p2)
				table.insert(kerbBoundary, ringKerb)
				-- Outer path: straight chord from spoke outer to ring outer
				-- (good enough at flare scale; a true offset curve of the
				-- fillet would need another radius and more failure modes).
				for j = 2, #kerbBoundary - 1 do
					local t = (j - 1) / (#kerbBoundary - 1)
					table.insert(outerBoundary, lerp3(flare.Outer, ringOuter, t))
				end
				table.insert(outerBoundary, ringOuter)
				for j = 1, #kerbBoundary - 1 do
					FillTriangle(
						raise(outerBoundary[j]),
						raise(kerbBoundary[j]),
						raise(kerbBoundary[j + 1]),
						sidewalkDepth,
						DOWN,
						makeSidewalkPart,
						ring
					)
					FillTriangle(
						raise(outerBoundary[j]),
						raise(kerbBoundary[j + 1]),
						raise(outerBoundary[j + 1]),
						sidewalkDepth,
						DOWN,
						makeSidewalkPart,
						ring
					)
				end
			else
				-- Degenerate fillet (near-tangential feeder): still bridge
				-- sidewalk with a plain raised quad so the mouth doesn't
				-- leave a bare notch at the spoke's pavement edge.
				local ringOuter = ringPointAt(flare.Station, outerSidewalkM)
				FillTriangle(
					raise(flare.Outer),
					raise(flare.Kerb),
					raise(ringKerb),
					sidewalkDepth,
					DOWN,
					makeSidewalkPart,
					ring
				)
				FillTriangle(
					raise(flare.Outer),
					raise(ringKerb),
					raise(ringOuter),
					sidewalkDepth,
					DOWN,
					makeSidewalkPart,
					ring
				)
			end
		end
	end

	ring.Parent = getRoundaboutsFolder()
	JunctionInstance.Delete(junctionModel)
	return ring
end

return RoundaboutBuilder
