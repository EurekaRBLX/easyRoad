--!strict
-- Builds the visible geometry for a JunctionNode (see JunctionInstance.lua),
-- following the same model RoadArchitect-style tools (and our own
-- RoundaboutBuilder) use: the roads TERMINATE at the intersection boundary,
-- and the intersection owns the interior surface.
--
-- Two halves, called in order by the placement flow (createRoadSession):
--
-- 1. TrimApproaches: every connected road is cut back so it STOPS at the
--    pad boundary (max connected half-width + margin from the junction
--    centre) instead of running full-profile to the junction centre point.
--    Untrimmed approaches were the root cause of the long-standing "faulty
--    intersection" reports: each road's sidewalks, kerb lines, and edge
--    markings plowed straight through the intersection interior, overlapping
--    each other and whatever pad was drawn - no pad shape could ever look
--    right on top of that. Same mechanism as RoundaboutBuilder's
--    trimSpokeToRing (bisection for the boundary crossing, CurveSegment.Sub
--    to truncate, rebuild + restamp, destroy the original), except the
--    trimmed end KEEPS its junction link. Idempotent: an end already at the
--    boundary is skipped, so re-running when another road joins later only
--    trims further if the pad radius actually grew.
--
-- 2. Rebuild: the pad's asphalt, filled from the OUTLINE walked in point 3
--    below - each approach's mouth joined to the next by that gap's corner
--    treatment - triangulated by EAR CLIPPING. Ear clipping, not a fan:
--    a fan is only valid for a polygon that is star-shaped about the point
--    it fans from, and a pad carrying a corner treatment per gap is
--    concave by construction (an L-bend has a short inner corner and a
--    long outer wrap-around, and its centroid can fall outside the pad).
--    The outline is validated before it is trusted - cleaned of duplicate
--    and collinear vertices, then rejected outright if it crosses itself.
--    Anything that fails validation falls back to the CONVEX HULL of every
--    connected road's KERB points, which is convex by construction and so
--    can always be triangulated: a blunter pad than intended, but never a
--    torn one. That fallback is the standing guarantee that no corner
--    logic failure can leave the pad itself holed, and it is the reason
--    the hull code is kept even though corners no longer come from it.
--
-- Skips itself entirely for a plain two-road pass-through (matching
-- profiles, roughly opposite outward directions) - a chained straight or
-- gently-curving continuation needs neither trimming nor a pad.
--
-- 3. Corners: PER-APPROACH NODE model (suggested by the user - "break an
--    intersection down to different nodes, the cross section itself, and
--    join them all"). Each connected road contributes one node: its
--    cross-section at the trimmed end (left/right kerb + outer points)
--    plus the angle it leaves the junction at. Nodes are sorted by that
--    angle and corner treatments are built between ANGULAR NEIGHBOURS -
--    each adjacent pair gets a curb-return fillet (`Fillet.Compute`,
--    Geometry/Fillet.lua - fixed radius `FILLET_RADIUS_M`, tangent to both
--    roads' kerb lines, straight-chamfer fallback on any degenerate case)
--    between the first road's counter-clockwise-side point and the second
--    road's clockwise-side point, both sides resolved computationally from
--    signed angles around the centre (no left/right or driving-side
--    conventions to get wrong). Corner-pairing by approach rather than by
--    adjacent hull points means a road whose kerb points fall
--    hull-interior (a narrow road between two wide ones) still gets real
--    corners with both neighbours instead of being paved across - the
--    live-reported "sidewalk band walling off an approach" class of bug is
--    structurally impossible between angular neighbours (a mouth-crossing
--    guard is kept anyway for pathological near-parallel approach sets).
--    The corner's asphalt bulge is fanned from the pair's own LOCAL kerb
--    point (never the global apex - fanning arcs from a distant apex is
--    what tore the mesh on a real 4-way), and its SIDEWALK is a BAND
--    between the kerb boundary and an outward-offset outer boundary,
--    filled a quad per span (never a fan from a single outer point, which
--    skewed triangles across the asphalt). Every failure mode in this
--    layer degrades to less decoration on top of an intact base pad.
--
-- Still missing (TODO.md): stop lines/crosswalks/lane guidance through the
-- pad, and approach trimming for roads with a transition or bay
-- (RoadSplit's CanSplit guard - those roads still overlap the old way).

local CurveSegment = require("../Geometry/CurveSegment")
local Fillet = require("../Geometry/Fillet")
local PolyCurve = require("../Geometry/PolyCurve")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")
local RoadInstance = require("../RoadInstance")
local RoadSplit = require("../RoadSplit")
local JunctionInstance = require("../JunctionInstance")
local RoadBuilder = require("./RoadBuilder")
local FillTriangle = require("./FillTriangle")
local StructureBuilder = require("../StructureBuilder")

local JunctionBuilder = {}

-- Pad reach beyond the widest connected road's half-width. Raised from 2
-- to 6 after live feedback asking for a real SETBACK at intersections:
-- with only 2 studs of clearance the approaches' medians/sidewalks ended
-- flush against the pad's own geometry, reading as one continuous mess
-- rather than roads arriving at a distinct intersection area.
local PAD_MARGIN_STUDS = 6
-- An approach end already this close to the pad boundary counts as trimmed
-- (makes TrimApproaches idempotent across repeated connect/rebuild rounds).
local TRIM_EPSILON_STUDS = 0.5
-- Don't trim if the piece left over would be shorter than this - a road
-- stub that barely pokes out of the pad reads worse than a small overlap.
local MIN_APPROACH_REMAINDER_STUDS = 2
-- A typical urban kerb-return radius (real-world design values run roughly
-- 3-15m depending on road class; 6m is a reasonable general default for a
-- residential/collector corner). The fillet construction itself lives in
-- Geometry/Fillet.lua (shared with the roundabout's entry/exit flares) -
-- see that file for the CART-derived true-circle technique and its
-- bounded-failure design.
local FILLET_RADIUS_M = 6
local FILLET_ARC_SAMPLES = 4 -- interior points sampled along each fillet
-- Don't build a curb-return between angular neighbours whose mouths are
-- farther apart than this: a T-junction's through-pair sits ~180° apart, and
-- treating that gap as a "corner" draws a Hermite/fillet across the through
-- carriageway (live: jagged zigzag through the pad, sidewalk spikes into
-- asphalt). Real corners on urban junctions are almost always well under
-- 135°.
local MAX_CORNER_SPAN_RAD = math.rad(135)
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

-- Leftmost and rightmost offsets (meters) of any Median components, or nil
-- if the profile has no median. Used to terminate medians at the pad mouth.
local function medianOffsetsM(profile: RoadProfile.RoadProfile): (number?, number?)
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	local left: number? = nil
	local right: number? = nil
	for i, component in profile.Components do
		if component.Kind == "Median" then
			if not left then
				left = offsets[i].Left
			end
			right = offsets[i].Right
		end
	end
	return left, right
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

-- Ground-plane distance - the pad is a ground-plane construct, and a 3D
-- magnitude would under-trim an approach arriving on a grade.
local function distanceXZ(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- The station along `curve`, searched between `fromStation` (the junction
-- end, assumed inside the pad) and `towardStation` (the far end), where
-- ground-plane distance from `center` first reaches `radiusStuds` - nil if
-- the whole road stays inside the pad (too short to trim meaningfully).
-- Same bisection RoundaboutBuilder.findRingCrossing uses for its spokes.
local function findPadCrossing(
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

-- Untrimmed source curve for a road (preserved across setback changes so
-- TrimApproaches can shorten OR lengthen when pad margin changes).
local function readSourceSegment(road: Model): CurveSegment.Segment?
	local kind = road:GetAttribute("RW_SourceKind")
	local p0 = road:GetAttribute("RW_SourceP0")
	local p1 = road:GetAttribute("RW_SourceP1")
	if typeof(kind) ~= "string" or typeof(p0) ~= "Vector3" or typeof(p1) ~= "Vector3" then
		return nil
	end
	local p2 = road:GetAttribute("RW_SourceP2")
	local p3 = road:GetAttribute("RW_SourceP3")
	if kind == "Line" then
		return CurveSegment.Line(p0, p1)
	elseif kind == "Quadratic" and typeof(p2) == "Vector3" then
		return CurveSegment.Quadratic(p0, p1, p2)
	elseif kind == "Cubic" and typeof(p2) == "Vector3" and typeof(p3) == "Vector3" then
		return CurveSegment.Cubic(p0, p1, p2, p3)
	end
	return nil
end

local function writeSourceSegment(road: Model, segment: CurveSegment.Segment)
	road:SetAttribute("RW_SourceKind", segment.Kind)
	road:SetAttribute("RW_SourceP0", segment.P0)
	road:SetAttribute("RW_SourceP1", segment.P1)
	road:SetAttribute("RW_SourceP2", segment.P2)
	road:SetAttribute("RW_SourceP3", segment.P3)
end

-- Cuts `road` back at every active junction it references. Handling both
-- ends from one preserved source segment matters once a placed road crosses
-- more than one existing road: trimming one end and then the other in two
-- independent passes would otherwise restore the first end from the source.
local function trimApproach(road: Model, style: RegionStyles.RegionStyle, settings: Settings.EasyRoadSettings)
	if not RoadSplit.CanSplit(road) then
		return
	end
	local data = RoadInstance.Read(road)
	if not data or #data.Curve.Segments ~= 1 or (not data.StartJunctionId and not data.EndJunctionId) then
		return
	end
	local source = readSourceSegment(road)
	if not source then
		source = data.Curve.Segments[1]
	end
	local sourceCurve = PolyCurve.new({ source })
	local startStation = 0
	local endStation = sourceCurve.Length
	local trimmed = false

	local function trimStationFor(junctionId: string, atStart: boolean): number?
		local junctionModel = JunctionInstance.FindById(junctionId)
		local junctionData = if junctionModel then JunctionInstance.Read(junctionModel) else nil
		if not junctionData then
			return nil
		end
		local connected = JunctionInstance.ConnectedRoads(junctionId)
		if #connected < 2 or isSmoothPassThrough(connected, junctionId) then
			return nil
		end
		local radiusStuds = JunctionBuilder.PadRadiusStuds(junctionId, settings)
		if not radiusStuds then
			return nil
		end
		return findPadCrossing(
			sourceCurve,
			if atStart then 0 else sourceCurve.Length,
			if atStart then sourceCurve.Length else 0,
			junctionData.Position,
			radiusStuds
		)
	end

	if data.StartJunctionId then
		local crossing = trimStationFor(data.StartJunctionId, true)
		if crossing then
			startStation = crossing
			trimmed = true
		end
	end
	if data.EndJunctionId then
		local crossing = trimStationFor(data.EndJunctionId, false)
		if crossing then
			endStation = crossing
			trimmed = true
		end
	end
	if not trimmed or endStation - startStation < MIN_APPROACH_REMAINDER_STUDS then
		return
	end
	local outerSegment = CurveSegment.Sub(source, startStation, endStation)
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
	writeSourceSegment(road, source)
	RoadInstance.StampJunctions(road, data.StartJunctionId, data.EndJunctionId)
	RoadInstance.StampStructure(road, data.Structure)
	StructureBuilder.Render(
		road,
		PolyCurve.new({ outerSegment }),
		data.Structure or StructureBuilder.DefaultData(),
		settings
	)
end

-- The radius (studs, from the junction centre) of this junction's pad -
-- widest connected road's half-width plus the setback margin, the same
-- number TrimApproaches cuts every approach back to. nil when no connected
-- road contributes a usable width. Public so createRoadSession can match a
-- click against the pad's real physical extent (its visible footprint)
-- rather than just a fixed snap radius around the centre point, which for
-- a wide avenue's junction is far smaller than the pad itself.
function JunctionBuilder.PadRadiusStuds(junctionId: string, settings: Settings.EasyRoadSettings): number?
	local roads = JunctionInstance.ConnectedRoads(junctionId)
	if #roads == 0 then
		return nil
	end
	local scale = settings.MetersToStuds
	local maxHalfWidthStuds = 0
	for _, road in roads do
		local profile = profileAtJunctionEnd(road, junctionId)
		if profile then
			maxHalfWidthStuds = math.max(maxHalfWidthStuds, RoadProfile.TotalWidthM(profile) / 2 * scale)
		end
	end
	if maxHalfWidthStuds <= 0 then
		return nil
	end
	local margin = PAD_MARGIN_STUDS
	local junctionModel = JunctionInstance.FindById(junctionId)
	if junctionModel then
		local data = JunctionInstance.Read(junctionModel)
		if data and data.PadMarginStuds then
			margin = math.clamp(data.PadMarginStuds, 1, 40)
		end
	end
	return maxHalfWidthStuds + margin
end

-- Layout snapshot for the node controller (viewport handles / panel).
export type JunctionLayout = {
	Center: Vector3,
	FilletRadiusM: number,
	PadMarginStuds: number,
	Mouths: { { Road: Model, Left: Vector3, Right: Vector3, Mid: Vector3 } },
	Corners: { { Index: number, Mid: Vector3, SpanRad: number } },
}

function JunctionBuilder.GetLayout(junctionId: string, settings: Settings.EasyRoadSettings): JunctionLayout?
	local junctionModel = JunctionInstance.FindById(junctionId)
	if not junctionModel then
		return nil
	end
	local junctionData = JunctionInstance.Read(junctionModel)
	if not junctionData then
		return nil
	end
	local center = junctionData.Position
	local filletM = junctionData.FilletRadiusM or FILLET_RADIUS_M
	local margin = junctionData.PadMarginStuds or PAD_MARGIN_STUDS
	local mouths: { { Road: Model, Left: Vector3, Right: Vector3, Mid: Vector3 } } = {}
	local corners: { { Index: number, Mid: Vector3, SpanRad: number } } = {}
	local approaches: { { Angle: number, Cw: EdgePoint, Ccw: EdgePoint } } = {}
	local function angleDelta(a: number, b: number): number
		return (a - b + math.pi) % (2 * math.pi) - math.pi
	end
	for _, road in JunctionInstance.ConnectedRoads(junctionId) do
		local points = edgePointsForRoad(road, junctionId, settings)
		if points and #points == 2 then
			local mid = (points[1].Kerb + points[2].Kerb) / 2
			table.insert(mouths, {
				Road = road,
				Left = points[1].Kerb,
				Right = points[2].Kerb,
				Mid = mid,
			})
			local mx, mz = mid.X - center.X, mid.Z - center.Z
			if mx * mx + mz * mz > 1e-6 then
				local angle = math.atan2(mz, mx)
				local d1 = angleDelta(math.atan2(points[1].Kerb.Z - center.Z, points[1].Kerb.X - center.X), angle)
				local d2 = angleDelta(math.atan2(points[2].Kerb.Z - center.Z, points[2].Kerb.X - center.X), angle)
				local cw = if d1 <= d2 then points[1] else points[2]
				local ccw = if d1 <= d2 then points[2] else points[1]
				table.insert(approaches, { Angle = angle, Cw = cw, Ccw = ccw })
			end
		end
	end
	table.sort(approaches, function(a, b)
		return a.Angle < b.Angle
	end)
	for i = 1, #approaches do
		local nextI = if i < #approaches then i + 1 else 1
		local span = approaches[nextI].Angle - approaches[i].Angle
		if span < 0 then
			span += 2 * math.pi
		end
		local turnAngle = math.min(span, 2 * math.pi - span)
		if turnAngle <= MAX_CORNER_SPAN_RAD and turnAngle >= math.rad(20) then
			local a = approaches[i].Ccw
			local b = approaches[nextI].Cw
			local mid = (a.Kerb + b.Kerb) * 0.5
			table.insert(corners, { Index = i, Mid = mid, SpanRad = turnAngle })
		end
	end
	return {
		Center = center,
		FilletRadiusM = filletM,
		PadMarginStuds = margin,
		Mouths = mouths,
		Corners = corners,
	}
end

-- Trims every connected approach back to this junction's pad boundary -
-- call from the placement flow right before Rebuild, whenever a road is
-- connected to the junction. Deliberately NOT called from Rebuild itself:
-- Rebuild also runs from the road-deletion listener in main.lua (including
-- removals driven by undo), and trimming from there would re-cut roads the
-- user is trying to restore. Idempotent per pad radius - re-running only
-- trims further when a new, wider road has grown the pad.
function JunctionBuilder.TrimApproaches(
	junctionId: string,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
)
	local junctionModel = JunctionInstance.FindById(junctionId)
	if not junctionModel then
		return
	end
	local junctionData = JunctionInstance.Read(junctionModel)
	if not junctionData then
		return
	end
	local roads = JunctionInstance.ConnectedRoads(junctionId)
	if #roads < 2 or isSmoothPassThrough(roads, junctionId) then
		return
	end
	local padRadiusStuds = JunctionBuilder.PadRadiusStuds(junctionId, settings)
	if not padRadiusStuds then
		return
	end
	for _, road in roads do
		trimApproach(road, style, settings)
	end
end

-- 2D cross product (XZ plane, ground plane) of (a - o) and (b - o) - the
-- standard turn test: positive means b is to the left of the line o->a
-- extended, negative means right, zero means collinear.
local function cross2D(o: Vector3, a: Vector3, b: Vector3): number
	return (a.X - o.X) * (b.Z - o.Z) - (a.Z - o.Z) * (b.X - o.X)
end

-- True when segments a1-a2 and b1-b2 PROPERLY cross in the ground plane
-- (strict interior crossing - merely touching at an endpoint doesn't
-- count, so a corner band sharing a kerb point with an adjacent road's
-- mouth isn't a false positive). Same segment-overlap idea RoadArchitect's
-- GSDRoadIntersection.Intersects2D uses for its own boundary tests: four
-- orientation (turn) tests, crossing iff each segment's endpoints straddle
-- the other's line.
local function segmentsCross2D(a1: Vector3, a2: Vector3, b1: Vector3, b2: Vector3): boolean
	local o1 = cross2D(a1, a2, b1)
	local o2 = cross2D(a1, a2, b2)
	local o3 = cross2D(b1, b2, a1)
	local o4 = cross2D(b1, b2, a2)
	return o1 * o2 < 0 and o3 * o4 < 0
end

-- Angular order about the centroid. Not a hull - just an ordering, used as
-- the last-resort perimeter order when the hull construction below has
-- nothing convex to work with.
local function sortAroundCentroid(points: { EdgePoint }): { EdgePoint }
	local cx, cz = 0, 0
	for _, p in points do
		cx += p.Kerb.X
		cz += p.Kerb.Z
	end
	cx /= #points
	cz /= #points
	local sorted = table.clone(points)
	table.sort(sorted, function(a: EdgePoint, b: EdgePoint): boolean
		return math.atan2(a.Kerb.Z - cz, a.Kerb.X - cx) < math.atan2(b.Kerb.Z - cz, b.Kerb.X - cx)
	end)
	return sorted
end

-- The convex hull of `points`' Kerb positions (2D, ground plane), via the
-- standard Andrew's monotone chain construction: sort by X (ties by Z),
-- then sweep building a lower and upper chain, popping the last point
-- whenever the turn it makes isn't a left turn. Returns hull vertices in
-- ORDER (their EdgePoint records, not just positions) - a point that ends
-- up strictly inside the hull (dominated by its neighbours) is dropped
-- entirely, same as any convex hull algorithm.
--
-- The ORDER is the entire value of this function: it is the pad's
-- guaranteed-safe fallback shape, and a convex polygon taken in perimeter
-- order can always be triangulated without self-intersection. Two ways
-- that guarantee used to be silently lost, both closed here:
--
--  * the old `if #points <= 3 then return points end` early-out handed the
--    points back in whatever order the ROADS happened to be read in.
--    "Already convex" is true of any 3 points and is not the property that
--    matters - perimeter ORDER is - so the supposedly-always-safe fallback
--    could itself wind backwards and fold. Three points now go through the
--    same chain construction as any other count.
--  * fully collinear or coincident input collapses both chains to one
--    point each, and the unconditional `table.remove` that followed could
--    leave the hull EMPTY - which the caller then averaged (a divide by
--    zero) into a NaN apex and fed to the part builder. The chain trim is
--    now conditional and a degenerate result falls back to angular order.
local function convexHull(points: { EdgePoint }): { EdgePoint }
	if #points < 3 then
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
	-- Each chain's last point is the other chain's first, so one copy of
	-- each is dropped - but only when both chains actually have a point to
	-- spare. Collinear input leaves chains of one, and trimming those
	-- unconditionally emptied the hull.
	if #lower >= 2 and #upper >= 2 then
		table.remove(lower)
		table.remove(upper)
	end
	local hull: { EdgePoint } = {}
	for _, p in lower do
		table.insert(hull, p)
	end
	for _, p in upper do
		table.insert(hull, p)
	end
	if #hull < 3 then
		return sortAroundCentroid(points) -- degenerate: collinear or coincident
	end
	return hull
end

-- Twice the signed area of a ground-plane polygon (shoelace). The sign is
-- the winding direction, which the ear clipper needs; the magnitude is
-- twice the area, which the collapse check needs.
local function polygonArea2(poly: { Vector3 }): number
	local sum = 0
	for i, p in poly do
		local q = poly[if i < #poly then i + 1 else 1]
		sum += p.X * q.Z - q.X * p.Z
	end
	return sum
end

-- Vertices closer together than this merge; vertices this close to the
-- straight line between their neighbours are dropped as collinear.
local POLY_MERGE_STUDS = 0.05
local POLY_COLLINEAR_STUDS = 0.02

-- Merges coincident vertices (including across the closing wrap) and thins
-- collinear runs. Both matter to the ear clipper below: a repeated vertex
-- makes a zero-area "ear" and a straight run makes a corner that is never
-- a valid ear, either of which stalls it on an otherwise fine polygon.
-- Same preparation CART's JunctionTool does before triangulating a traced
-- junction outline.
local function cleanPolygon(poly: { Vector3 }): { Vector3 }
	local out: { Vector3 } = {}
	for _, p in poly do
		if #out == 0 or distanceXZ(out[#out], p) > POLY_MERGE_STUDS then
			table.insert(out, p)
		end
	end
	while #out >= 2 and distanceXZ(out[1], out[#out]) <= POLY_MERGE_STUDS do
		table.remove(out)
	end
	local changed = true
	while changed and #out > 3 do
		changed = false
		for i = 1, #out do
			local prev = out[if i > 1 then i - 1 else #out]
			local nextPoint = out[if i < #out then i + 1 else 1]
			local base = distanceXZ(prev, nextPoint)
			if base > 1e-6 and math.abs(cross2D(prev, nextPoint, out[i])) / base <= POLY_COLLINEAR_STUDS then
				table.remove(out, i)
				changed = true
				break
			end
		end
	end
	return out
end

-- True when any two non-adjacent edges of the closed polygon cross. A
-- boundary that crosses itself has no well-defined interior, so anything
-- filled from it is guesswork - the caller drops to the convex hull.
local function polygonSelfIntersects(poly: { Vector3 }): boolean
	local n = #poly
	if n < 4 then
		return false
	end
	for i = 1, n do
		local nextI = if i < n then i + 1 else 1
		for j = i + 1, n do
			local nextJ = if j < n then j + 1 else 1
			if nextI ~= j and nextJ ~= i then
				if segmentsCross2D(poly[i], poly[nextI], poly[j], poly[nextJ]) then
					return true
				end
			end
		end
	end
	return false
end

local function pointInTriangle2D(p: Vector3, a: Vector3, b: Vector3, c: Vector3, orientation: number): boolean
	return cross2D(a, b, p) * orientation >= -1e-5
		and cross2D(b, c, p) * orientation >= -1e-5
		and cross2D(c, a, p) * orientation >= -1e-5
end

-- Bound on the ear-clipping loop. Each successful pass removes one vertex,
-- so a well-formed polygon finishes in #poly - 3 passes; the guard only
-- fires on input the ear test cannot make progress on.
local EAR_CLIP_GUARD = 512

-- Ear-clipping triangulation of a closed ground-plane polygon, following
-- CART's JunctionTool `_triangulatePolygon`. Returns nil - never a partial
-- or approximate answer - when the outline cannot be triangulated, so the
-- caller can fall back to a shape that provably can be.
--
-- Why not a centroid fan, which is what this replaced: a fan is only valid
-- for a polygon that is star-shaped about the point it fans from. A pad
-- with a corner treatment on each gap is CONCAVE by construction - an
-- L-bend has a short inner corner and a long outer wrap-around, and its
-- centroid can sit outside the pad entirely. Fanning that double-covers
-- part of the pad and hangs the rest outside the boundary, which is the
-- spiked, jagged pad reported live. Ear clipping is correct on any simple
-- polygon, concave included.
local function triangulatePolygon(poly: { Vector3 }): { { Vector3 } }?
	if #poly < 3 then
		return nil
	end
	local area2 = polygonArea2(poly)
	if math.abs(area2) < 1e-4 then
		return nil -- collapsed to a line
	end
	local orientation = if area2 >= 0 then 1 else -1
	local indices: { number } = {}
	for i = 1, #poly do
		table.insert(indices, i)
	end
	local triangles: { { Vector3 } } = {}
	local guard = 0
	while #indices > 3 and guard < EAR_CLIP_GUARD do
		guard += 1
		local found = false
		for i = 1, #indices do
			local prevIndex = indices[((i - 2) % #indices) + 1]
			local currIndex = indices[i]
			local nextIndex = indices[(i % #indices) + 1]
			local a, b, c = poly[prevIndex], poly[currIndex], poly[nextIndex]
			if cross2D(a, b, c) * orientation > 1e-5 then
				local blocked = false
				for _, testIndex in indices do
					if testIndex ~= prevIndex and testIndex ~= currIndex and testIndex ~= nextIndex then
						if pointInTriangle2D(poly[testIndex], a, b, c, orientation) then
							blocked = true
							break
						end
					end
				end
				if not blocked then
					table.insert(triangles, { a, b, c })
					table.remove(indices, i)
					found = true
					break
				end
			end
		end
		if not found then
			return nil -- outline crosses itself
		end
	end
	if #indices == 3 then
		table.insert(triangles, { poly[indices[1]], poly[indices[2]], poly[indices[3]] })
	end
	return triangles
end

-- Insets `point` (assumed to already lie on the fillet circle of the given
-- `radius`, centred at `center`) radially TOWARD `center` by `distance`
-- studs - i.e. the same centre and angle, just a smaller concentric arc.
-- This, not pushing the point further from centre, is the correct
-- direction for the sidewalk's outer edge: the kerb arc is the ASPHALT's
-- boundary, and the asphalt sits on the side of the arc AWAY from the
-- circle's own centre (nearer the corner's true, un-rounded vertex, which
-- sits OUTSIDE the circle - vertex-to-centre distance is always > radius
-- by construction, since `Fillet.Compute` derives centre as vertex offset
-- along the bisector by `tangentLength / cos(theta/2)`, strictly more than
-- the radius `tangentLength * tan(theta/2)` for any real corner). The
-- pavement/sidewalk therefore lies on the CENTRE side of the arc, so its
-- outer edge is a smaller, concentric arc - NOT the arc pushed further
-- from centre, which is what an earlier version of this function did and
-- which pushed the sidewalk band toward the vertex/asphalt instead of away
-- from it, reported live as a spurious inward "indent" at every rounded
-- corner of an ordinary intersection.
local function insetTowardCenter(point: Vector3, center: Vector3, radius: number, distance: number): Vector3
	local dx, dz = point.X - center.X, point.Z - center.Z
	local mag = math.sqrt(dx * dx + dz * dz)
	if mag < 1e-6 then
		return point
	end
	local newRadius = math.max(0.1, radius - distance)
	local scale = newRadius / mag
	return Vector3.new(center.X + dx * scale, point.Y, center.Z + dz * scale)
end

-- Cubic Hermite from `p0` to `p1` whose travel direction is `d0` at the
-- start and `d1` at the end, sampled at `samples` interior points.
-- Tangent magnitudes are the chord length (the standard "taut" choice), so
-- in Bezier terms every control point sits within chord/3 of an endpoint -
-- the curve is bounded near the straight chord by construction, with none
-- of the unbounded-reach failure modes that plagued earlier corner code.
local function hermiteBoundary(p0: Vector3, d0: Vector3, p1: Vector3, d1: Vector3, samples: number): { Vector3 }
	local chord = (p1 - p0).Magnitude
	local m0 = d0.Unit * chord
	local m1 = d1.Unit * chord
	local points: { Vector3 } = { p0 }
	for i = 1, samples do
		local t = i / (samples + 1)
		local t2 = t * t
		local t3 = t2 * t
		local h00 = 2 * t3 - 3 * t2 + 1
		local h10 = t3 - 2 * t2 + t
		local h01 = -2 * t3 + 3 * t2
		local h11 = t3 - t2
		table.insert(points, p0 * h00 + m0 * h10 + p1 * h01 + m1 * h11)
	end
	table.insert(points, p1)
	return points
end

local HERMITE_SAMPLES = 5
-- Wide gaps get more samples than corners do. A corner's Hermite spans a
-- short curb return; a wide gap spans the whole open side of the pad, and
-- the rendered edge IS the polyline, so a coarse one shows its first chord
-- as a visible break against the road's kerb line. Measured at a 35 degree
-- bend: 5 samples leaves 3.1 degrees of break, 12 leaves 1.4.
local THROUGH_SAMPLES = 12

-- How far a corner polyline may stray from its own straight chord, as a
-- multiple of that chord's length, before it is discarded for the chord.
-- A curb return bulges a little past the straight line between its two
-- endpoints; it never loops. 0.6 passes every real corner measured in
-- tools/preview/junction_pad_preview.py and rejects the runaway Hermites.
local MAX_HERMITE_EXCURSION = 0.6

-- The furthest any point of `points` sits from the straight chord between
-- its first and last, measured as a multiple of that chord. Counts
-- overshoot past either end as excursion too, so a polyline that doubles
-- back along the chord is caught as well as one that bows away from it.
local function chordExcursion(points: { Vector3 }): number
	local first, last = points[1], points[#points]
	local chord = distanceXZ(first, last)
	if chord < 1e-6 then
		return math.huge
	end
	local dx, dz = (last.X - first.X) / chord, (last.Z - first.Z) / chord
	local worst = 0
	for _, p in points do
		local vx, vz = p.X - first.X, p.Z - first.Z
		local along = vx * dx + vz * dz
		worst = math.max(worst, math.abs(vx * -dz + vz * dx))
		if along < 0 then
			worst = math.max(worst, -along)
		elseif along > chord then
			worst = math.max(worst, along - chord)
		end
	end
	return worst / chord
end

-- Parallel offset of a kerb polyline AWAY from the junction centre (pad
-- asphalt is toward the centre; sidewalk is outside). Picking "toward
-- fillet centre" alone flips on some Hermite spans and spikes sidewalk
-- into the carriageway (live zigzag pad). Endpoints pinned to real outers.
local function offsetKerbPolyline(
	kerb: { Vector3 },
	widthStart: number,
	widthEnd: number,
	junctionCenter: Vector3,
	pinStart: Vector3,
	pinEnd: Vector3
): { Vector3 }
	local n = #kerb
	if n < 2 then
		return { pinStart, pinEnd }
	end
	local outer: { Vector3 } = table.create(n)
	for i = 1, n do
		local t = if n > 1 then (i - 1) / (n - 1) else 0
		local w = widthStart + (widthEnd - widthStart) * t
		local prev = kerb[math.max(1, i - 1)]
		local nextp = kerb[math.min(n, i + 1)]
		local tx, tz = nextp.X - prev.X, nextp.Z - prev.Z
		local len = math.sqrt(tx * tx + tz * tz)
		local p = kerb[i]
		if len < 1e-6 or w < 1e-4 then
			outer[i] = p
		else
			local nx1, nz1 = -tz / len, tx / len
			local nx2, nz2 = tz / len, -tx / len
			-- Prefer the normal that points away from the junction centre.
			local awayX, awayZ = p.X - junctionCenter.X, p.Z - junctionCenter.Z
			local use1 = nx1 * awayX + nz1 * awayZ >= nx2 * awayX + nz2 * awayZ
			local nx = if use1 then nx1 else nx2
			local nz = if use1 then nz1 else nz2
			outer[i] = Vector3.new(p.X + nx * w, p.Y, p.Z + nz * w)
		end
	end
	outer[1] = pinStart
	outer[n] = pinEnd
	return outer
end

-- The paired KERB (asphalt-edge) and OUTER (sidewalk-outer-edge) boundaries
-- for one corner pair. `junctionCenter` steers sidewalk offset outward.
--
-- Three shapes, in order of preference:
-- 1. FILLET: circular kerb arc + parallel-offset sidewalk
-- 2. HERMITE: cubic kerb + parallel-offset sidewalk
-- 3. STRAIGHT chamfer when tangents are unreadable, when the fillet is
--    rejected AND the Hermite comes out unbounded, or as the honest answer
--    for a pair whose edges genuinely diverge (see below)
--
-- On the direction convention, which is where the live "outer arc" bug
-- lived. This used to take an `exterior` flag and, on the long way round a
-- bend, aim the edge directions along +outward instead of -outward. That is
-- wrong, and provably so: take an L of two roads half-width w, A's outer
-- edge running along z = -w and B's along x = +w. Those two lines meet at
-- (w, -w) - the outside corner of the L - and from A's kerb point at
-- (-d, -w) that vertex lies in +X, which is -outwardA. The corner vertex is
-- toward -outward on BOTH the short and the long way round; a bend has no
-- side on which the edges converge in the other direction.
--
-- The cost of getting it backwards was not a bad fillet, it was NO fillet:
-- `Fillet.Compute` correctly rejects a vertex that sits behind the ray
-- (t <= 0), so every exterior span fell through to the Hermite, which was
-- then handed mismatched directions (+outwardA at one end, -outwardB at the
-- other) and looped the outer boundary back ACROSS the pad interior. The
-- assembled outline crossed itself at every bend from 45 to 150 degrees -
-- measured, not estimated, in tools/preview/junction_pad_preview.py - and
-- the centroid fan over that self-crossing outline is the jagged, spiked
-- pad reported live.
local function cornerBoundaries(
	a: EdgePoint,
	b: EdgePoint,
	junctionId: string,
	radiusStuds: number,
	junctionCenter: Vector3
): ({ Vector3 }, { Vector3 })
	local outwardA = outwardTangentAt(a.Road, junctionId)
	local outwardB = outwardTangentAt(b.Road, junctionId)
	if not outwardA or not outwardB then
		return { a.Kerb, b.Kerb }, { a.Outer, b.Outer }
	end
	local widthA = distanceXZ(a.Outer, a.Kerb)
	local widthB = distanceXZ(b.Outer, b.Kerb)
	local chord = distanceXZ(a.Kerb, b.Kerb)
	local cappedRadius = math.min(radiusStuds, chord * 0.45)
	-- Toward the corner vertex where the two edge lines meet.
	local dirA, dirB = -outwardA, -outwardB
	local p1, filletCenter, p2, effectiveRadius = Fillet.Compute(a.Kerb, dirA, b.Kerb, dirB, cappedRadius)
	if not p1 or not filletCenter or not p2 or not effectiveRadius then
		-- No real corner here. Usually near-parallel edges, where a Hermite
		-- is the right blend - but also the sharp-hairpin case where the two
		-- trimmed ends have already passed each other, and there a Hermite
		-- spun on the chord-length tangents loops right out of the pad. Only
		-- keep it if it stays near its own chord.
		local kerb = hermiteBoundary(a.Kerb, -outwardA, b.Kerb, outwardB, HERMITE_SAMPLES)
		if chordExcursion(kerb) > MAX_HERMITE_EXCURSION then
			kerb = { a.Kerb, b.Kerb }
		end
		local outer = offsetKerbPolyline(kerb, widthA, widthB, junctionCenter, a.Outer, b.Outer)
		return kerb, outer
	end
	local kerb: { Vector3 } = { a.Kerb, p1 }
	local arc = Fillet.SampleArc(filletCenter, effectiveRadius, p1, p2, FILLET_ARC_SAMPLES)
	for _, point in arc do
		table.insert(kerb, point)
	end
	table.insert(kerb, p2)
	table.insert(kerb, b.Kerb)
	local outer = offsetKerbPolyline(kerb, widthA, widthB, junctionCenter, a.Outer, b.Outer)
	return kerb, outer
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
	-- Sidewalk fill needs to sit at the same raised height RoadBuilder gives
	-- every connecting road's own sidewalk/median Parts (top at curbHeight
	-- above the deck, same -thickness bottom as the asphalt) - previously
	-- the junction's sidewalk corner fan used the roadway-level Kerb/Outer
	-- points unmodified, so the pad's own sidewalk sat flush with the
	-- asphalt instead of raised, producing a visible height step right at
	-- the seam with the connecting roads' real (raised) sidewalks.
	local curbHeight = style.CurbHeightM * settings.MetersToStuds
	local sidewalkDepth = thickness + curbHeight
	local function raise(point: Vector3): Vector3
		return point + Vector3.new(0, curbHeight, 0)
	end

	local function makePart(material: Enum.Material, color: Color3): Part
		local part = Instance.new("Part")
		part.Name = "JunctionSurface"
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		-- JunctionEditSession is selection-driven: Studio must be able to hit
		-- the visible pad and walk back up to its RW_Junction model. Road
		-- placement already excludes workspace.Junctions from its own ground
		-- raycast, so keeping these queryable does not make new roads sit on
		-- top of the pad.
		part.CanQuery = true
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
	-- Each road's MOUTH: the segment between its own left and right kerb
	-- points at its junction end - the opening its traffic flows through.
	-- Used below to stop a corner treatment between two OTHER roads from
	-- being drawn straight across it (see the crossesMouth check).
	local mouths: { { Road: Model, L: Vector3, R: Vector3 } } = {}
	-- Per-approach NODE (see the header's point 3): each connected road's
	-- cross-section at its trimmed end, as an explicit record - which way
	-- it leaves the junction (Angle, from its outward tangent) and which of
	-- its two edge points sits on its clockwise vs counter-clockwise side
	-- as seen from the junction centre. Corner treatments are built between
	-- ANGULAR NEIGHBOURS from this list, not between adjacent convex-hull
	-- points - so a road whose kerb points fall hull-interior (narrower
	-- road between two wide ones) still gets its own corners instead of
	-- being paved over by its neighbours' corner spanning across it.
	type Approach = {
		Road: Model,
		Angle: number,
		Cw: EdgePoint,
		Ccw: EdgePoint,
		MedianL: Vector3?,
		MedianR: Vector3?,
	}
	local approaches: { Approach } = {}
	-- Signed shortest angular difference a - b, wrapped to (-pi, pi].
	local function angleDelta(a: number, b: number): number
		return (a - b + math.pi) % (2 * math.pi) - math.pi
	end
	for _, road in roads do
		local points = edgePointsForRoad(road, junctionId, settings)
		if points then
			for _, point in points do
				table.insert(edgePoints, point)
			end
			if #points == 2 then
				table.insert(mouths, { Road = road, L = points[1].Kerb, R = points[2].Kerb })
				local mid = (points[1].Kerb + points[2].Kerb) / 2
				local mx, mz = mid.X - center.X, mid.Z - center.Z
				if mx * mx + mz * mz > 1e-6 then
					local angle = math.atan2(mz, mx)
					local d1 = angleDelta(math.atan2(points[1].Kerb.Z - center.Z, points[1].Kerb.X - center.X), angle)
					local d2 = angleDelta(math.atan2(points[2].Kerb.Z - center.Z, points[2].Kerb.X - center.X), angle)
					local cw = if d1 <= d2 then points[1] else points[2]
					local ccw = if d1 <= d2 then points[2] else points[1]
					local medianL: Vector3? = nil
					local medianR: Vector3? = nil
					local prof = profileAtJunctionEnd(road, junctionId)
					local data = RoadInstance.Read(road)
					if prof and data then
						local mLeft, mRight = medianOffsetsM(prof)
						if mLeft and mRight then
							local station = if data.StartJunctionId == junctionId then 0 else data.Curve.Length
							local frame = data.Curve:FrameAt(station)
							local function wp(offsetM: number): Vector3
								return (frame * CFrame.new(offsetM * settings.MetersToStuds, 0, 0)).Position
							end
							medianL = wp(mLeft)
							medianR = wp(mRight)
						end
					end
					table.insert(approaches, {
						Road = road,
						Angle = angle,
						Cw = cw,
						Ccw = ccw,
						MedianL = medianL,
						MedianR = medianR,
					})
				end
			end
		end
	end
	table.sort(approaches, function(a: Approach, b: Approach): boolean
		return a.Angle < b.Angle
	end)

	if #approaches >= 2 then
		-- User-tunable fillet (node controller); default FILLET_RADIUS_M.
		local filletRadiusM = FILLET_RADIUS_M
		if junctionData.FilletRadiusM then
			filletRadiusM = math.clamp(junctionData.FilletRadiusM, 0.5, 40)
		end
		local filletRadiusStuds = filletRadiusM * settings.MetersToStuds

		-- Continuous pad boundary: walk approaches in angle order, append
		-- each corner's kerb polyline (or a straight mouth-to-mouth chord
		-- for wide through-gaps). Fan-fill that closed polygon — not the
		-- convex hull of raw kerb points, which ignored corner arcs and
		-- produced creases when through-pair Hermites ran across the pad.
		type BuiltCorner = {
			Kerb: { Vector3 },
			Outer: { Vector3 },
			Sidewalk: boolean,
		}
		local builtCorners: { BuiltCorner } = {}
		local padPoly: { Vector3 } = {}
		local function appendUnique(point: Vector3)
			if #padPoly > 0 then
				local last = padPoly[#padPoly]
				if (last - point).Magnitude < 0.05 then
					return
				end
			end
			table.insert(padPoly, point)
		end

		for i = 1, #approaches do
			local nextI = if i < #approaches then i + 1 else 1
			local span = approaches[nextI].Angle - approaches[i].Angle
			if span < 0 then
				span += 2 * math.pi
			end
			-- Turning angle of this gap (short way). An L-corner has spans
			-- 90° and 270° — both are 90° turns (inner + outer). Using raw
			-- span alone treated the 270° exterior as a "through-gap" and
			-- drew a sharp miter (live). Through-pairs on a T still sit at
			-- ~180° short-way and stay skipped.
			local turnAngle = math.min(span, 2 * math.pi - span)
			local a = approaches[i].Ccw
			local b = approaches[nextI].Cw
			if a.Road == b.Road then
				appendUnique(a.Kerb)
				continue
			end
			local isRealCorner = turnAngle <= MAX_CORNER_SPAN_RAD and turnAngle >= math.rad(20)
			local crossesMouth = false
			if isRealCorner then
				for _, mouth in mouths do
					if
						mouth.Road ~= a.Road
						and mouth.Road ~= b.Road
						and segmentsCross2D(a.Kerb, b.Kerb, mouth.L, mouth.R)
					then
						crossesMouth = true
						break
					end
				end
			end
			if isRealCorner and not crossesMouth then
				local kerbBoundary, outerBoundary = cornerBoundaries(a, b, junctionId, filletRadiusStuds, center)
				table.insert(builtCorners, { Kerb = kerbBoundary, Outer = outerBoundary, Sidewalk = true })
				for _, p in kerbBoundary do
					appendUnique(p)
				end
			else
				-- Wide gap. On a T's through-pair the two roads are collinear
				-- and a straight edge across it is genuinely right. On a
				-- SHALLOW BEND - a two-road node whose turn is too gentle to
				-- read as a corner but too sharp for isSmoothPassThrough to
				-- skip - it is not: chording straight across left a hard facet
				-- exactly where the road's own kerb line should carry through,
				-- reported live as "straight lines not continuous curves".
				--
				-- The OUTER sidewalk edge here was already a Hermite while the
				-- kerb was a chord, so the two edges of one band disagreed: the
				-- asphalt edge cut the corner while the pavement edge curved
				-- around it. Both now follow the same directions.
				--
				-- This does not change a T. For a collinear through-pair
				-- -outwardA and outwardB are the same direction, so the Hermite
				-- degenerates to exactly the straight chord it replaced.
				local outwardA = outwardTangentAt(a.Road, junctionId)
				local outwardB = outwardTangentAt(b.Road, junctionId)
				local kerbBand: { Vector3 } = { a.Kerb, b.Kerb }
				local outerBand: { Vector3 } = { a.Outer, b.Outer }
				if outwardA and outwardB then
					local curvedKerb = hermiteBoundary(a.Kerb, -outwardA, b.Kerb, outwardB, THROUGH_SAMPLES)
					if chordExcursion(curvedKerb) <= MAX_HERMITE_EXCURSION then
						kerbBand = curvedKerb
						outerBand = hermiteBoundary(a.Outer, -outwardA, b.Outer, outwardB, THROUGH_SAMPLES)
					else
						-- Kerb curve unusable, but the sidewalk still has to
						-- connect (live: T missing sidewalk on the open side).
						outerBand = hermiteBoundary(a.Outer, -outwardA, b.Outer, outwardB, HERMITE_SAMPLES)
					end
				end
				-- Sidewalk only if outers actually sit outside the kerb (has
				-- a sidewalk/median strip).
				local hasSidewalk = distanceXZ(a.Outer, a.Kerb) > 0.15 or distanceXZ(b.Outer, b.Kerb) > 0.15
				table.insert(builtCorners, {
					Kerb = kerbBand,
					Outer = outerBand,
					Sidewalk = hasSidewalk,
				})
				for _, point in kerbBand do
					appendUnique(point)
				end
			end
		end

		-- Fill the pad from the walked outline, but do NOT assume the walk
		-- produced a usable one. A corner treatment that misbehaves - or a
		-- hairpin bend whose two trimmed ends have already passed each
		-- other, where no walk can produce a simple boundary at all - hands
		-- back an outline that crosses itself, and filling from that is what
		-- put the jagged, spiked pad in front of the user.
		--
		-- So: clean it, reject it if it self-crosses, and triangulate by ear
		-- clipping (correct on the concave shapes a real pad actually has).
		-- Anything that fails drops to the convex hull of the kerb points,
		-- which is convex by construction and therefore always fillable -
		-- the pad may be blunter than intended, but it is never torn.
		local outline = cleanPolygon(padPoly)
		local triangles: { { Vector3 } }? = nil
		if #outline >= 3 and not polygonSelfIntersects(outline) then
			triangles = triangulatePolygon(outline)
		end
		if not triangles and #edgePoints >= 3 then
			local hull = convexHull(edgePoints)
			local hullPoly: { Vector3 } = table.create(#hull)
			for _, point in hull do
				table.insert(hullPoly, point.Kerb)
			end
			triangles = triangulatePolygon(cleanPolygon(hullPoly))
		end
		if triangles then
			for _, tri in triangles do
				FillTriangle(tri[1], tri[2], tri[3], thickness, DOWN, makeAsphaltPart, folder)
			end
		end

		-- Sidewalk bands on real corners AND T through-side (open edge).
		for _, corner in builtCorners do
			if corner.Sidewalk and #corner.Kerb >= 2 and #corner.Outer >= 2 then
				local kerbBoundary = corner.Kerb
				local outerBoundary = corner.Outer
				-- Through-chord has 2 kerb pts but N outer pts (Hermite) —
				-- sample kerb linearly to match outer count.
				if #outerBoundary ~= #kerbBoundary then
					local resampled: { Vector3 } = {}
					for j = 1, #outerBoundary do
						local t = if #outerBoundary > 1 then (j - 1) / (#outerBoundary - 1) else 0
						table.insert(resampled, kerbBoundary[1]:Lerp(kerbBoundary[#kerbBoundary], t))
					end
					kerbBoundary = resampled
				end
				for j = 1, #kerbBoundary - 1 do
					FillTriangle(
						raise(outerBoundary[j]),
						raise(kerbBoundary[j]),
						raise(kerbBoundary[j + 1]),
						sidewalkDepth,
						DOWN,
						makeSidewalkPart,
						folder
					)
					FillTriangle(
						raise(outerBoundary[j]),
						raise(kerbBoundary[j + 1]),
						raise(outerBoundary[j + 1]),
						sidewalkDepth,
						DOWN,
						makeSidewalkPart,
						folder
					)
				end
			end
		end

		-- Median noses: each approach that carries a Median ends with a
		-- blunt slab at the trim without this - fill a short triangle into
		-- the pad along the inward radial so the median terminates cleanly
		-- instead of a raw rectangular cut (live report on dual-carriageway
		-- T-junctions).
		local function makeMedianPart(): Part
			return makePart(Enum.Material.Grass, style.MedianColor)
		end
		local medianDepth = thickness + curbHeight
		for _, approach in approaches do
			if approach.MedianL and approach.MedianR then
				local mid = (approach.MedianL + approach.MedianR) * 0.5
				local radial = Vector3.new(center.X - mid.X, 0, center.Z - mid.Z)
				if radial.Magnitude > 1e-3 then
					local noseLen = math.clamp(distanceXZ(approach.MedianL, approach.MedianR) * 0.6, 1.5, 6)
					local tip = mid + radial.Unit * noseLen
					tip = Vector3.new(tip.X, mid.Y, tip.Z)
					FillTriangle(
						raise(approach.MedianL),
						raise(approach.MedianR),
						raise(tip),
						medianDepth,
						DOWN,
						makeMedianPart,
						folder
					)
				end
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
