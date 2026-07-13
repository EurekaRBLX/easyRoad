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
-- 2. Rebuild: the pad's BASE asphalt - the CONVEX HULL of every connected
--    road's KERB points (the roadway/non-roadway boundary at each trimmed
--    end), fan-triangulated from one of its own hull vertices. A convex
--    polygon can ALWAYS be fanned from any of its own vertices without
--    self-intersection - a property, not a heuristic, adopted after
--    several rounds of per-pair corner constructions (Bézier arcs,
--    chamfers, angle-sorted point walks) each producing broken geometry on
--    some junction shape. The hull is deliberately kept as the
--    unconditional base fill even now that corners are driven by the
--    per-approach node model below - it's the guarantee that no corner
--    logic failure can ever leave the pad itself torn or holed.
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

-- Cuts `road` back so its junction-side end sits at the pad boundary
-- instead of running through to the junction centre. The rebuilt, shorter
-- geometry is TRANSPLANTED into the existing Model (children and attributes
-- swapped in place) rather than destroy-and-replace: callers up the stack
-- (createRoadSession's commitRoad) still hold this Model reference for the
-- road's other-end connection, Studio's selection stays valid, and main.lua's
-- road-removal listener doesn't fire mid-connect. Unlike RoundaboutBuilder's
-- spoke trim, the trimmed end KEEPS its junction link, since the junction
-- still exists and still needs to know its approaches. Leaves the road
-- untouched if it has an active transition/bay (RoadSplit's own guard),
-- its end is already at the boundary, or trimming would leave a sliver.
-- Any MarkingStretches/KerbStretches are dropped by the rebuild (their
-- station ranges wouldn't survive the cut) - same limitation RoadSplit has.
local function trimApproach(
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
	local curve = data.Curve
	local fromStation = if atStart then 0 else curve.Length
	local towardStation = if atStart then curve.Length else 0
	if distanceXZ(curve:PosAt(fromStation), center) >= radiusStuds - TRIM_EPSILON_STUDS then
		return -- already at/outside the boundary: nothing to trim
	end
	local crossing = findPadCrossing(curve, fromStation, towardStation, center, radiusStuds)
	if not crossing then
		return
	end
	local remaining = if atStart then curve.Length - crossing else crossing
	if remaining < MIN_APPROACH_REMAINDER_STUDS then
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
	if atStart then
		RoadInstance.StampJunctions(road, junctionId, data.EndJunctionId)
	else
		RoadInstance.StampJunctions(road, data.StartJunctionId, junctionId)
	end
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
	return maxHalfWidthStuds + PAD_MARGIN_STUDS
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
	local center = junctionData.Position
	for _, road in roads do
		trimApproach(road, junctionId, center, padRadiusStuds, style, settings)
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

-- The paired KERB (asphalt-edge) and OUTER (sidewalk-outer-edge) boundaries
-- for one cross-road hull corner, returned as two equal-length point lists
-- so the sidewalk can be filled as a proper BAND between them (quad per
-- span) rather than a fan from a single point - fanning the sidewalk from
-- one `a.Outer` across a curved kerb arc skewed the triangles across the
-- asphalt and produced hook/sliver artifacts at the corner.
--
-- Straight chamfer (no valid fillet): kerb {a.Kerb, b.Kerb}, outer
-- {a.Outer, b.Outer} - a single sidewalk quad, exactly as before rounding.
-- Rounded corner: the kerb list follows the fillet arc; each interior arc
-- point's outer partner is the same point on a smaller, concentric arc
-- (see `insetTowardCenter`) inset by the sidewalk width, interpolated from
-- road A's width at the a end to road B's at the b end. The two endpoints
-- are pinned to the roads' own real `a.Outer`/`b.Outer` so the band meets
-- each connected road's sidewalk seamlessly.
local function cornerBoundaries(
	a: EdgePoint,
	b: EdgePoint,
	junctionId: string,
	radiusStuds: number
): ({ Vector3 }, { Vector3 })
	local inwardA = outwardTangentAt(a.Road, junctionId)
	local inwardB = outwardTangentAt(b.Road, junctionId)
	if not inwardA or not inwardB then
		return { a.Kerb, b.Kerb }, { a.Outer, b.Outer }
	end
	local p1, center, p2, effectiveRadius = Fillet.Compute(a.Kerb, -inwardA, b.Kerb, -inwardB, radiusStuds)
	if not p1 or not center or not p2 or not effectiveRadius then
		return { a.Kerb, b.Kerb }, { a.Outer, b.Outer }
	end
	local widthA = distanceXZ(a.Outer, a.Kerb)
	local widthB = distanceXZ(b.Outer, b.Kerb)
	-- Sampled arc points, plus p1 (t=0) and p2 (t=1), each tagged with the
	-- t used to interpolate its sidewalk width. Fillet.SampleArc uses
	-- t = i/(samples+1), so the interior points sit strictly between.
	local kerb: { Vector3 } = { a.Kerb, p1 }
	local outer: { Vector3 } = { a.Outer, insetTowardCenter(p1, center, effectiveRadius, widthA) }
	local arc = Fillet.SampleArc(center, effectiveRadius, p1, p2, FILLET_ARC_SAMPLES)
	for i, point in arc do
		local t = i / (FILLET_ARC_SAMPLES + 1)
		local width = widthA + (widthB - widthA) * t
		table.insert(kerb, point)
		table.insert(outer, insetTowardCenter(point, center, effectiveRadius, width))
	end
	table.insert(kerb, p2)
	table.insert(outer, insetTowardCenter(p2, center, effectiveRadius, widthB))
	table.insert(kerb, b.Kerb)
	table.insert(outer, b.Outer)
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
	type Approach = { Road: Model, Angle: number, Cw: EdgePoint, Ccw: EdgePoint }
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
				local outward = outwardTangentAt(road, junctionId)
				if outward then
					local angle = math.atan2(outward.Z, outward.X)
					-- Which side each edge point sits on, resolved purely
					-- computationally (the signed angular offset of the
					-- point around the junction centre, relative to the
					-- road's own outward direction) - no left/right or
					-- driving-side sign conventions to get wrong.
					local d1 = angleDelta(math.atan2(points[1].Kerb.Z - center.Z, points[1].Kerb.X - center.X), angle)
					local d2 = angleDelta(math.atan2(points[2].Kerb.Z - center.Z, points[2].Kerb.X - center.X), angle)
					local cw = if d1 <= d2 then points[1] else points[2]
					local ccw = if d1 <= d2 then points[2] else points[1]
					table.insert(approaches, { Road = road, Angle = angle, Cw = cw, Ccw = ccw })
				end
			end
		end
	end
	table.sort(approaches, function(a: Approach, b: Approach): boolean
		return a.Angle < b.Angle
	end)

	if #edgePoints >= 3 then
		local hull = convexHull(edgePoints)
		-- A convex polygon can always be fan-triangulated from any of its
		-- own vertices without self-intersecting - unlike a fixed external
		-- apex (the junction's stored position, or even the point set's
		-- own centroid), which can end up outside the true boundary for an
		-- oddly-shaped set of roads and produce exactly the crossing,
		-- jagged geometry reported live through several earlier rounds.
		local apex = hull[1].Kerb
		local filletRadiusStuds = FILLET_RADIUS_M * settings.MetersToStuds
		-- Base asphalt: the plain convex-hull fan, and nothing else - every
		-- hull edge's straight chord filled from the global apex
		-- (unconditional, so no corner-layer failure below can ever leave
		-- the pad torn or holed - see the header's point 2). A chord point
		-- equal to `apex` itself (the two edges touching the apex vertex)
		-- makes a zero-length edge, silently skipped by FillTriangle's
		-- degenerate-triangle guard.
		for i = 1, #hull do
			local a = hull[i]
			local b = hull[if i < #hull then i + 1 else 1]
			FillTriangle(apex, a.Kerb, b.Kerb, thickness, DOWN, makeAsphaltPart, folder)
		end

		-- Corner treatments: between ANGULAR NEIGHBOURS in the per-approach
		-- node list, not between adjacent hull points. Walking approaches
		-- (one angular slot per road, well separated by construction - they
		-- are distinct roads leaving one junction) instead of raw points
		-- avoids the point-interleaving that made the old radial point walk
		-- self-intersect, and it means a road whose kerb points fall
		-- hull-interior still gets real corners with both its neighbours.
		-- Going from approach A to the next approach B in ascending-angle
		-- order, the corner between them is bounded by A's Ccw-side point
		-- and B's Cw-side point (both resolved computationally above).
		for i = 1, #approaches do
			local a = approaches[i].Ccw
			local b = approaches[if i < #approaches then i + 1 else 1].Cw
			if a.Road == b.Road then
				continue -- degenerate (a road looping both ends into one junction)
			end
			-- Belt-and-braces guard kept from the hull-walk era: skip the
			-- raised corner treatment if it would properly cross a THIRD
			-- road's mouth (with angular-neighbour pairing this should be
			-- structurally impossible for sane layouts, but three roads
			-- clustered at nearly the same angle can still produce it, and
			-- a silently-missing corner beats a band walling off a
			-- carriageway - the failure reported live under the old
			-- pairing).
			local crossesMouth = false
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
			if not crossesMouth then
				local kerbBoundary, outerBoundary = cornerBoundaries(a, b, junctionId, filletRadiusStuds)
				-- Asphalt corner bulge: only when a real fillet was found
				-- (otherwise kerbBoundary is just the 2 chord endpoints, and
				-- the base fan above already covered the chord). Fanned from
				-- the LOCAL a.Kerb across the arc.
				if #kerbBoundary > 2 then
					for j = 1, #kerbBoundary - 1 do
						FillTriangle(
							a.Kerb,
							kerbBoundary[j],
							kerbBoundary[j + 1],
							thickness,
							DOWN,
							makeAsphaltPart,
							folder
						)
					end
				end
				-- Sidewalk band: one quad (two triangles) per span between
				-- the kerb boundary and its outward-offset outer boundary,
				-- both raised to curb height. For a straight chamfer this is
				-- the single a.Outer-a.Kerb-b.Kerb-b.Outer quad; for a
				-- rounded corner it follows the arc without ever crossing
				-- into the asphalt.
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
