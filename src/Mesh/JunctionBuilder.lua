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
-- 2. Rebuild: the pad itself - the CONVEX HULL of every connected road's
--    KERB points (the roadway/non-roadway boundary at each trimmed end),
--    fan-triangulated from one of its own hull vertices as the asphalt
--    surface. A convex polygon can ALWAYS be fanned from any of its own
--    vertices without self-intersection - a property, not a heuristic,
--    adopted after several rounds of per-pair corner constructions
--    (Bézier arcs, chamfers, angle-sorted point walks) each producing
--    broken geometry on some junction shape. The strip between each
--    cross-road hull edge and the roads' OUTER points (sidewalk outer
--    edge) is filled as the pedestrian corner (sidewalk material).
--
-- Skips itself entirely for a plain two-road pass-through (matching
-- profiles, roughly opposite outward directions) - a chained straight or
-- gently-curving continuation needs neither trimming nor a pad.
--
-- 3. Rounded corners: each cross-road hull edge is upgraded from a straight
--    chamfer to a real curb-return fillet where it safely can be - see
--    `filletPoints` for the construction and, importantly, why it can only
--    ever make one corner MORE conservative (fall back to the straight
--    hull edge already proven safe), never introduce a new way to break
--    the whole pad. A fixed radius (`FILLET_RADIUS_M`) tangent to both
--    roads' own kerb lines, not a Bézier control point search - the
--    earlier "intersect the two tangent lines for a control point"
--    construction (still used here to find the underlying corner VERTEX)
--    is exactly what kept breaking when used unbounded; here it's one
--    input to a fillet whose reach is capped by construction, not by a
--    threshold discovered after something broke.
--
-- Still missing (TODO.md): stop lines/crosswalks/lane guidance through the
-- pad, and approach trimming for roads with a transition or bay
-- (RoadSplit's CanSplit guard - those roads still overlap the old way).

local CurveSegment = require("../Geometry/CurveSegment")
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

local PAD_MARGIN_STUDS = 2 -- Pad reach beyond the widest connected road's half-width
-- An approach end already this close to the pad boundary counts as trimmed
-- (makes TrimApproaches idempotent across repeated connect/rebuild rounds).
local TRIM_EPSILON_STUDS = 0.5
-- Don't trim if the piece left over would be shorter than this - a road
-- stub that barely pokes out of the pad reads worse than a small overlap.
local MIN_APPROACH_REMAINDER_STUDS = 2
-- A typical urban kerb-return radius (real-world design values run roughly
-- 3-15m depending on road class; 6m is a reasonable general default for a
-- residential/collector corner). Cross-checked against CivicArcRoadToolkit
-- (CART)'s JunctionTool.lua: its chooseArcCenter/sampleArc2D build a true
-- circular fillet (perpendicular-offset lines intersected to find a centre
-- equidistant from both tangent points, then sampled by angle) rather than
-- a Bézier approximation - the construction here follows that same shape
-- (find the vertex, derive tangent points and a true circle through them,
-- sample by angle), just built from this file's own kerb-point data
-- instead of taking the tangent points as a given input the way CART's
-- helper does.
local FILLET_RADIUS_M = 6
local FILLET_ARC_SAMPLES = 4 -- interior points sampled along each fillet
-- The corner vertex (where the two roads' own kerb lines would meet if
-- extended) is rejected as "too far to be a real corner" beyond this
-- multiple of the straight a.Kerb-b.Kerb chord length - guards the same
-- near-parallel-tangent case that made the old unbounded Bézier corner
-- spike, except here rejecting just means "skip rounding, keep the
-- already-safe straight hull edge" instead of corrupting anything.
local MAX_VERTEX_CHORD_RATIO = 4
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
	local center = junctionData.Position
	local scale = settings.MetersToStuds
	local maxHalfWidthStuds = 0
	for _, road in roads do
		local profile = profileAtJunctionEnd(road, junctionId)
		if profile then
			maxHalfWidthStuds = math.max(maxHalfWidthStuds, RoadProfile.TotalWidthM(profile) / 2 * scale)
		end
	end
	if maxHalfWidthStuds <= 0 then
		return
	end
	local padRadiusStuds = maxHalfWidthStuds + PAD_MARGIN_STUDS
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

-- A real curb-return fillet between two roads' kerb lines meeting at
-- `aKerb`/`bKerb` - the roads' own edge points, which the fillet must
-- connect to WITHOUT moving them. `inwardA`/`inwardB` are each road's kerb
-- line direction pointing INTO the junction (toward where the two lines
-- would cross if extended).
--
-- Two stages, both bounded so a bad case just loses the rounding for this
-- one corner (returns nil - caller falls back to the straight hull edge,
-- already proven safe) rather than producing anything unbounded:
--
-- 1. Find the corner VERTEX: where the two roads' own kerb lines actually
--    meet if extended (2D line intersection, ground plane). Rejected if
--    the lines are parallel, if either road's line only reaches the
--    vertex going BACKWARD (t <= 0 - the roads diverge instead of
--    converging, not a real corner), or if the vertex is unreasonably far
--    away relative to the chord between the two points (near-parallel
--    roads) - the same class of case that made the old unbounded Bézier
--    corner spike, except rejecting it here only skips rounding.
-- 2. Derive a true circular fillet of `radiusStuds` tangent to both lines
--    at that vertex, the same shape CivicArcRoadToolkit's chooseArcCenter/
--    sampleArc2D build (see this file's header) - standard "tangent
--    length = radius / tan(half-angle)" trigonometry, capped to never
--    reach past the roads' own aKerb/bKerb points (a corner tighter than
--    the requested radius needs, e.g. a short trimmed approach, gets a
--    smaller effective radius instead of overshooting).
--
-- Returns (tangent point near aKerb, circle centre, tangent point near
-- bKerb, effective radius) or nil.
local function computeFillet(
	aKerb: Vector3,
	inwardA: Vector3,
	bKerb: Vector3,
	inwardB: Vector3,
	radiusStuds: number
): (Vector3?, Vector3?, Vector3?, number?)
	local ax, az = inwardA.X, inwardA.Z
	local bx, bz = inwardB.X, inwardB.Z
	local det = ax * -bz - az * -bx
	if math.abs(det) < 1e-6 then
		return nil, nil, nil, nil
	end
	local dx, dz = bKerb.X - aKerb.X, bKerb.Z - aKerb.Z
	local t1 = (dx * -bz - dz * -bx) / det
	local t2 = (ax * dz - dx * az) / det
	if t1 <= 1e-3 or t2 <= 1e-3 then
		return nil, nil, nil, nil -- roads diverge from these points, not a real corner
	end
	local chordLength = (bKerb - aKerb).Magnitude
	if chordLength < 1e-3 or t1 > chordLength * MAX_VERTEX_CHORD_RATIO or t2 > chordLength * MAX_VERTEX_CHORD_RATIO then
		return nil, nil, nil, nil -- vertex too far away: near-parallel roads
	end
	local vertex = aKerb + inwardA * t1
	local dirA = (-inwardA).Unit -- from vertex back toward aKerb
	local dirB = (-inwardB).Unit
	local cosTheta = math.clamp(dirA:Dot(dirB), -1, 1)
	local theta = math.acos(cosTheta)
	if theta < 1e-3 then
		return nil, nil, nil, nil -- roads nearly collinear here: no real corner to round
	end
	local tangentLength = math.min(radiusStuds / math.tan(theta / 2), t1, t2)
	if tangentLength < 1e-3 then
		return nil, nil, nil, nil
	end
	local effectiveRadius = tangentLength * math.tan(theta / 2)
	local bisector = dirA + dirB
	if bisector.Magnitude < 1e-6 then
		return nil, nil, nil, nil
	end
	bisector = bisector.Unit
	local center = vertex + bisector * (tangentLength / math.cos(theta / 2))
	local p1 = vertex + dirA * tangentLength
	local p2 = vertex + dirB * tangentLength
	return p1, center, p2, effectiveRadius
end

-- Samples `samples` interior points (excluding the endpoints) along the
-- TRUE circular arc from `p1` to `p2` around `center` with the given
-- radius - the short way around, which is always well-defined here since
-- computeFillet's geometry guarantees the angle subtended is less than
-- 180 degrees. Interpolates height linearly between the two endpoints
-- (the fillet is small enough, relative to any grade change across a
-- junction, that this is visually indistinguishable from tracking the
-- true 3D surface).
local function sampleFilletArc(
	center: Vector3,
	radiusStuds: number,
	p1: Vector3,
	p2: Vector3,
	samples: number
): { Vector3 }
	local v1 = p1 - center
	local v2 = p2 - center
	local a1 = math.atan2(v1.Z, v1.X)
	local a2 = math.atan2(v2.Z, v2.X)
	local delta = a2 - a1
	while delta > math.pi do
		delta -= 2 * math.pi
	end
	while delta <= -math.pi do
		delta += 2 * math.pi
	end
	local points: { Vector3 } = {}
	for i = 1, samples do
		local t = i / (samples + 1)
		local angle = a1 + delta * t
		local y = p1.Y + (p2.Y - p1.Y) * t
		table.insert(
			points,
			Vector3.new(center.X + math.cos(angle) * radiusStuds, y, center.Z + math.sin(angle) * radiusStuds)
		)
	end
	return points
end

-- The ordered boundary points between `a.Kerb` and `b.Kerb` for one
-- cross-road hull edge - either the two points directly (straight
-- chamfer, always safe) or, when computeFillet finds a valid rounded
-- corner, `a.Kerb`, the fillet's sampled arc, then `b.Kerb`.
local function cornerBoundaryPoints(a: EdgePoint, b: EdgePoint, junctionId: string, radiusStuds: number): { Vector3 }
	local inwardA = outwardTangentAt(a.Road, junctionId)
	local inwardB = outwardTangentAt(b.Road, junctionId)
	if not inwardA or not inwardB then
		return { a.Kerb, b.Kerb }
	end
	local p1, center, p2, effectiveRadius = computeFillet(a.Kerb, -inwardA, b.Kerb, -inwardB, radiusStuds)
	if not p1 or not center or not p2 or not effectiveRadius then
		return { a.Kerb, b.Kerb }
	end
	local boundary: { Vector3 } = { a.Kerb, p1 }
	for _, point in sampleFilletArc(center, effectiveRadius, p1, p2, FILLET_ARC_SAMPLES) do
		table.insert(boundary, point)
	end
	table.insert(boundary, p2)
	table.insert(boundary, b.Kerb)
	return boundary
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
		local filletRadiusStuds = FILLET_RADIUS_M * settings.MetersToStuds
		-- Walk every boundary edge of the hull uniformly (with wraparound,
		-- so the two edges touching `apex` itself are included, not just
		-- the ones the fan below treats as diagonals). A same-road edge is
		-- always a plain straight span (that's just the road's own
		-- pavement); a cross-road edge tries for a real rounded corner via
		-- cornerBoundaryPoints, falling back to the straight hull edge
		-- when a safe fillet can't be found.
		for i = 1, #hull do
			local a = hull[i]
			local b = hull[if i < #hull then i + 1 else 1]
			local boundary = if a.Road == b.Road
				then { a.Kerb, b.Kerb }
				else cornerBoundaryPoints(a, b, junctionId, filletRadiusStuds)
			-- Asphalt: fan every consecutive boundary point from the hull's
			-- own apex. A boundary point that equals `apex` itself (the two
			-- edges touching the apex vertex) produces a zero-length edge,
			-- silently skipped by FillTriangle's own degenerate-triangle
			-- guard - no special-casing needed here for that.
			for j = 1, #boundary - 1 do
				FillTriangle(apex, boundary[j], boundary[j + 1], thickness, DOWN, makeAsphaltPart, folder)
			end
			-- Sidewalk corner: only for a real (cross-road) corner - the
			-- pedestrian strip between the same boundary and each road's
			-- own outer (e.g. sidewalk) edge, fanned from a.Outer.
			if a.Road ~= b.Road then
				for j = 1, #boundary - 1 do
					FillTriangle(a.Outer, boundary[j], boundary[j + 1], thickness, DOWN, makeSidewalkPart, folder)
				end
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
