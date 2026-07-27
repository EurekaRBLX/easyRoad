--!strict
-- Roundabout: continuous ring (never sliced) + setback + RoadBuilder feeders.
--
-- Ring is always ONE full RoadBuilder circle — never slice the annulus and
-- never parent Hermite "entry roads" onto the ring curve (those knot it).
-- Each spoke is trimmed with a junction-style setback, then bridged to the
-- ring with a normal curved road (Fitting + RoadBuilder.Build, same path as
-- freeform/curve placement). Full-width profile feeders stay outward; the
-- old edge-Hermite + FillTriangle mouths pinched inward at ClosestS.

local CurveSegment = require("../Geometry/CurveSegment")
local Fitting = require("../Geometry/Fitting")
local PolyCurve = require("../Geometry/PolyCurve")
local BezierCorner = require("../Geometry/BezierCorner")
local FillTriangle = require("./FillTriangle")
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
-- Pull spokes back so feed curves have length (studs past ring outer edge).
local SETBACK_STUDS = 14
-- Slight inset past the ring outer edge so feeder asphalt blends into the ring.
local FEED_OVERLAP_STUDS = 1

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

local function ringComponents(
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle
): { RoadProfile.ProfileComponent }
	local components: { RoadProfile.ProfileComponent } = {}
	for _ = 1, math.max(1, math.floor(laneCount)) do
		table.insert(components, { Kind = "Drive", WidthM = laneWidthM, Direction = 1 })
	end
	local sidewalk: RoadProfile.ProfileComponent = { Kind = "Sidewalk", WidthM = style.SidewalkWidthM, Direction = 0 }
	if style.DriveOnLeft then
		table.insert(components, sidewalk)
	else
		table.insert(components, 1, sidewalk)
	end
	return components
end

local function ringInnerHalfWidthM(profile: RoadProfile.RoadProfile, style: RegionStyles.RegionStyle): number
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	if style.DriveOnLeft then
		return -offsets[1].Left
	end
	return offsets[#offsets].Right
end

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

local function flatSettings(settings: Settings.EasyRoadSettings): Settings.EasyRoadSettings
	local clone = table.clone(settings)
	clone.SuperelevationMode = "Off"
	return clone
end

local function stampRingMeta(
	model: Model,
	center: Vector3,
	radiusStuds: number,
	outerRadiusStuds: number,
	laneCount: number,
	laneWidthM: number
)
	model:SetAttribute("RW_Roundabout", true)
	model:SetAttribute("RW_Center", center)
	model:SetAttribute("RW_RingRadius", radiusStuds)
	model:SetAttribute("RW_OuterRadius", outerRadiusStuds)
	model:SetAttribute("RW_LaneCount", laneCount)
	model:SetAttribute("RW_LaneWidthM", laneWidthM)
end

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
	model:SetAttribute("RW_Road", nil)
	model.Name = "Roundabout"
	local halfW = RoadProfile.TotalWidthM(profile) / 2 * settings.MetersToStuds
	stampRingMeta(model, center, radiusStuds, radiusStuds + halfW, laneCount, laneWidthM)
	buildIsland(model, center, radiusStuds, profile, style, settings)
	model.Parent = getRoundaboutsFolder()
	return model
end

local function distanceXZ(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

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
	Inward: Vector3,
	HalfWidthStuds: number,
}

local function ringSideIsStart(road: Model, center: Vector3): boolean?
	local data = RoadInstance.Read(road)
	if not data then
		return nil
	end
	return distanceXZ(data.Curve:PosAt(0), center) <= distanceXZ(data.Curve:PosAt(data.Curve.Length), center)
end

local function edgePointsAt(
	curve: PolyCurve.PolyCurve,
	profile: RoadProfile.RoadProfile,
	station: number,
	inward: Vector3,
	scale: number
): SpokeCutEdges?
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	if #offsets == 0 then
		return nil
	end
	local kerbLeftM, kerbRightM = roadwayEdgeOffsetsM(profile)
	local outerLeftM, outerRightM = offsets[1].Left, offsets[#offsets].Right
	local frame = curve:FrameAt(station)
	local function worldPoint(offsetM: number): Vector3
		return (frame * CFrame.new(offsetM * scale, 0, 0)).Position
	end
	local flatIn = Vector3.new(inward.X, 0, inward.Z)
	if flatIn.Magnitude < 1e-6 then
		return nil
	end
	return {
		LeftKerb = worldPoint(kerbLeftM),
		LeftOuter = worldPoint(outerLeftM),
		RightKerb = worldPoint(kerbRightM),
		RightOuter = worldPoint(outerRightM),
		Inward = flatIn.Unit,
		HalfWidthStuds = RoadProfile.TotalWidthM(profile) / 2 * scale,
	}
end

local function transplantRoad(road: Model, rebuilt: Model, startJ: string?, endJ: string?)
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
	RoadInstance.StampJunctions(road, startJ, endJ)
end

local function maxProfileRadiusAt(
	curve: PolyCurve.PolyCurve,
	profile: RoadProfile.RoadProfile,
	station: number,
	center: Vector3,
	scale: number
): number
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	if #offsets == 0 then
		return distanceXZ(curve:PosAt(station), center)
	end
	local outerLeftM, outerRightM = offsets[1].Left, offsets[#offsets].Right
	local frame = curve:FrameAt(station)
	local mid = frame.Position
	local left = (frame * CFrame.new(outerLeftM * scale, 0, 0)).Position
	local right = (frame * CFrame.new(outerRightM * scale, 0, 0)).Position
	return math.max(distanceXZ(mid, center), distanceXZ(left, center), distanceXZ(right, center))
end

local function findProfileRingCrossing(
	curve: PolyCurve.PolyCurve,
	profile: RoadProfile.RoadProfile,
	fromStation: number,
	towardStation: number,
	center: Vector3,
	targetRadiusStuds: number,
	scale: number
): number?
	local function radiusAt(s: number): number
		return maxProfileRadiusAt(curve, profile, s, center, scale)
	end
	if radiusAt(towardStation) < targetRadiusStuds then
		return nil
	end
	local lo, hi = fromStation, towardStation
	for _ = 1, 32 do
		local mid = (lo + hi) / 2
		if radiusAt(mid) < targetRadiusStuds then
			lo = mid
		else
			hi = mid
		end
	end
	return (lo + hi) / 2
end

local function trimSpoke(
	road: Model,
	atStart: boolean,
	center: Vector3,
	targetRadiusStuds: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): SpokeCutEdges?
	if not RoadSplit.CanSplit(road) then
		return nil
	end
	local data = RoadInstance.Read(road)
	if not data or #data.Curve.Segments ~= 1 then
		return nil
	end
	local scale = settings.MetersToStuds
	local curve = data.Curve
	local fromStation = if atStart then 0 else curve.Length
	local towardStation = if atStart then curve.Length else 0
	local crossing =
		findProfileRingCrossing(curve, data.ProfileStart, fromStation, towardStation, center, targetRadiusStuds, scale)
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
	local farJunctionId = if atStart then data.EndJunctionId else data.StartJunctionId
	if atStart then
		transplantRoad(road, rebuilt, nil, farJunctionId)
	else
		transplantRoad(road, rebuilt, farJunctionId, nil)
	end
	local newData = RoadInstance.Read(road)
	if not newData then
		return nil
	end
	local cutStation = if atStart then 0 else newData.Curve.Length
	local tangent = newData.Curve:TangentAt(cutStation)
	local inward = if atStart then -tangent else tangent
	inward = Vector3.new(inward.X, 0, inward.Z)
	if inward.Magnitude < 1e-6 then
		return nil
	end
	local profile = if atStart then newData.ProfileStart else (newData.ProfileEnd or newData.ProfileStart)
	return edgePointsAt(newData.Curve, profile, cutStation, inward.Unit, scale)
end

-- First forward crossing (t > 0) of the ground-plane ray `from + t*dir` with
-- the circle of radius `R` about `center`. `dir` need not be unit. Returns nil
-- if the ray never reaches that radius (points away from / stays outside it).
local function rayCircleFirstHit(from: Vector3, dir: Vector3, center: Vector3, R: number): Vector3?
	local ux, uz = dir.X, dir.Z
	local lenSq = ux * ux + uz * uz
	if lenSq < 1e-12 then
		return nil
	end
	local dx, dz = from.X - center.X, from.Z - center.Z
	-- Solve |(from - center) + t*dir|^2 = R^2 for the smaller positive t.
	local b = (dx * ux + dz * uz) / lenSq
	local c = (dx * dx + dz * dz - R * R) / lenSq
	local disc = b * b - c
	if disc < 0 then
		return nil
	end
	local sq = math.sqrt(disc)
	local t = -b - sq
	if t <= 1e-6 then
		t = -b + sq
	end
	if t <= 1e-6 then
		return nil
	end
	return Vector3.new(from.X + ux * t, from.Y, from.Z + uz * t)
end

-- Short feeder from a setback cut mid into the ring, built with the same
-- Fitting + RoadBuilder path as normal curved roads. The end lands where the
-- spoke's OWN centreline, continued into the ring, first crosses just inside
-- the outer edge - so the feeder is a straight (or gently curved) continuation
-- of the road and actually fills the gap the road leaves. (It used to attach on
-- the ring RADIAL through the cut mid, which for an off-centre approach - the
-- common case - pulled the feeder end sideways off the road line, leaving the
-- real road->ring gap unfilled with a diagonal stub floating beside it.)
local function buildFeederRoad(
	cutMid: Vector3,
	inward: Vector3,
	center: Vector3,
	attachRadiusStuds: number,
	profile: RoadProfile.RoadProfile,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): (Model?, SpokeCutEdges?)
	local flatIn = Vector3.new(inward.X, 0, inward.Z)
	if flatIn.Magnitude < 1e-6 then
		local toCenter = Vector3.new(center.X - cutMid.X, 0, center.Z - cutMid.Z)
		if toCenter.Magnitude < 1e-6 then
			return nil
		end
		flatIn = toCenter
	end
	local startTan = flatIn.Unit

	-- Attach where the road's own centreline, continued along its travel
	-- direction, first crosses just inside the ring's outer edge, so the feeder
	-- is a straight continuation that fills the gap the road leaves.
	local ringAttach = rayCircleFirstHit(cutMid, startTan, center, attachRadiusStuds)
	if not ringAttach then
		-- Spoke points away from / tangent to the ring: fall back to the radial
		-- point (a head-on spoke lands correctly here too).
		local radial = Vector3.new(cutMid.X - center.X, 0, cutMid.Z - center.Z)
		if radial.Magnitude < 1e-6 then
			radial = -startTan
		else
			radial = radial.Unit
		end
		ringAttach =
			Vector3.new(center.X + radial.X * attachRadiusStuds, cutMid.Y, center.Z + radial.Z * attachRadiusStuds)
	end
	ringAttach = Vector3.new(ringAttach.X, cutMid.Y, ringAttach.Z)
	if (ringAttach - cutMid).Magnitude < 0.5 then
		return nil
	end

	-- Locked start tangent = spoke travel into the ring (same as freeform curve
	-- continuation from an existing road end).
	local segment = Fitting.CurveFromTangent(cutMid, startTan, ringAttach)
	local feederCurve = PolyCurve.new({ segment })
	local feeder = RoadBuilder.Build({
		Curve = feederCurve,
		ProfileStart = profile,
		Style = style,
		Settings = flatSettings(settings),
		Preview = false,
	})
	-- Not a free-standing editable road — owned by the roundabout mesh.
	feeder:SetAttribute("RW_Road", nil)
	feeder.Name = "RoundaboutFeeder"

	-- Cross-section edge points where the feeder meets the ring, so the caller
	-- can build the mouth curb-return corners against them.
	local ringStation = feederCurve.Length
	local endTangent = feederCurve:TangentAt(ringStation)
	local ringEdges = edgePointsAt(feederCurve, profile, ringStation, endTangent, settings.MetersToStuds)
	return feeder, ringEdges
end

local DOWN = Vector3.new(0, -1, 0)

-- The angular slice of the ring one entry occupies, centred on the mouth's
-- radial. Used to open the ring's own pavement over that entry.
export type MouthSector = { Angle: number, Half: number }

-- Shortest signed difference between two angles, in (-pi, pi].
local function angleDelta(a: number, b: number): number
	local d = (a - b) % (2 * math.pi)
	if d > math.pi then
		d -= 2 * math.pi
	end
	return d
end

-- Minimum kerb that must survive between two adjacent entries, and the most
-- any single entry may open. Without these, wide (multi-lane) entries produce
-- sectors that overlap their neighbours and between them delete the entire
-- ring band, leaving a roundabout with no carriageway edge at all.
local MIN_KERB_GAP_RAD = math.rad(12)
local MAX_SECTOR_HALF_RAD = math.rad(60)

-- Entry/exit deflection: per-side multipliers on a mouth's symmetric flare,
-- and the matching corner bulge. A tight entry is the deflection that slows
-- traffic joining the ring; a generous exit lets it leave freely. Applied to
-- the CORNERS only - swinging the feeder centreline instead just produces a
-- hairpin, since the feeder is barely a setback long (see TODO history).
local ENTRY_FLARE_SCALE = 0.55
local EXIT_FLARE_SCALE = 1.55
local ENTRY_BULGE = 0.18
local EXIT_BULGE = 0.42
local SYMMETRIC_BULGE = 0.25

-- Shrink sectors until each leaves MIN_KERB_GAP_RAD of kerb to its angular
-- neighbours. Each sector may claim at most half of the gap on either side
-- (minus half the required kerb), which is symmetric and cannot overlap.
local function clampSectors(sectors: { MouthSector }): { MouthSector }
	if #sectors == 0 then
		return sectors
	end
	local sorted = table.clone(sectors)
	table.sort(sorted, function(a, b)
		return a.Angle < b.Angle
	end)
	if #sorted == 1 then
		sorted[1].Half = math.min(sorted[1].Half, MAX_SECTOR_HALF_RAD)
		return sorted
	end
	local clamped: { MouthSector } = {}
	for i, sector in sorted do
		local prev = sorted[if i > 1 then i - 1 else #sorted]
		local nextOne = sorted[if i < #sorted then i + 1 else 1]
		local gapPrev = (sector.Angle - prev.Angle) % (2 * math.pi)
		local gapNext = (nextOne.Angle - sector.Angle) % (2 * math.pi)
		local half = math.min(
			sector.Half,
			MAX_SECTOR_HALF_RAD,
			math.max(0, (gapPrev - MIN_KERB_GAP_RAD) / 2),
			math.max(0, (gapNext - MIN_KERB_GAP_RAD) / 2)
		)
		if half > 0 then
			table.insert(clamped, { Angle = sector.Angle, Half = half })
		end
	end
	return clamped
end

-- Delete the ring's own outer pavement/kerb parts that fall inside an entry
-- sector, so each mouth is an actual opening in the circulating carriageway
-- rather than a continuous raised band the traffic would have to cross.
-- `minRadiusStuds` restricts removal to the OUTER band. Without it the filter
-- is purely angular and takes out every marking in the sector at any radius -
-- including a multi-lane ring's inter-lane dashes and, worse, the edge line
-- around the central island, which would gain a gap at every entry even though
-- the island itself is continuous.
local function openRingPavement(
	parts: { BasePart },
	center: Vector3,
	rawSectors: { MouthSector },
	minRadiusStuds: number
)
	local sectors = clampSectors(rawSectors)
	if #sectors == 0 then
		return
	end
	for _, part in parts do
		if not part.Parent then
			continue
		end
		local offset = part.Position - center
		local flat = Vector3.new(offset.X, 0, offset.Z)
		if flat.Magnitude < 1e-6 then
			continue
		end
		if flat.Magnitude < minRadiusStuds then
			continue
		end
		local angle = math.atan2(flat.Z, flat.X)
		for _, sector in sectors do
			if math.abs(angleDelta(angle, sector.Angle)) <= sector.Half then
				part:Destroy()
				break
			end
		end
	end
end

local function flatUnit(v: Vector3): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-6 then
		return flat
	end
	return flat.Unit
end

-- Curb-return corners where a feeder meets the ring. Each feeder is a straight
-- road butting into the ring at an angle, so on each side its edge leaves a
-- triangular notch against the ring's outer circle and its kerb line stops
-- dead. This closes both notches (per side) with a bounded quadratic-Bezier
-- corner (BezierCorner - cannot spike at any mouth angle) from the feeder's
-- edge to the radially-projected ring edge, filled as a raised sidewalk band
-- plus roadway asphalt, mirroring the junction curb returns in JunctionBuilder.
local function buildMouthCorners(
	ring: Model,
	ringEdges: SpokeCutEdges,
	center: Vector3,
	outerRadiusStuds: number,
	ringSidewalkStuds: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
)
	local scale = settings.MetersToStuds
	local thickness = settings.RoadThicknessStuds
	local curbHeight = style.CurbHeightM * scale
	local sidewalkDepth = thickness + curbHeight
	local ringKerbRadius = math.max(1, outerRadiusStuds - ringSidewalkStuds)
	local SAMPLES = 6

	local function makePart(material: Enum.Material, color: Color3): Part
		local part = Instance.new("Part")
		part.Name = "RoundaboutMouth"
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
	local function raise(p: Vector3): Vector3
		return p + Vector3.new(0, curbHeight, 0)
	end
	local function projectTo(p: Vector3, radius: number): Vector3
		local u = flatUnit(p - center)
		if u.Magnitude < 1e-6 then
			return p
		end
		return Vector3.new(center.X + u.X * radius, p.Y, center.Z + u.Z * radius)
	end

	local dir = flatUnit(ringEdges.Inward)
	if dir.Magnitude < 1e-6 then
		return
	end
	-- Roadway corner apex: the ring kerb point on the feeder's own centreline.
	local mouthMid = ringEdges.LeftKerb:Lerp(ringEdges.RightKerb, 0.5)
	local apexAsphalt = projectTo(mouthMid, ringKerbRadius)

	-- A clamped quadratic-Bezier corner from `aEdge` (edge line along `aDir`) to
	-- `bEdge` (along `bDir`). The raw control is where the two edge lines meet,
	-- but that point sits well outside the chord and bowing the curve all the
	-- way out to it makes the corner bulge into a flower-petal lobe past the
	-- ring. Keep only a gentle round: pull the control to at most a small
	-- fraction of the chord length off the midpoint. Bounded inside
	-- {aEdge, control, bEdge} either way.
	local function cornerPolyline(
		aEdge: Vector3,
		aDir: Vector3,
		bEdge: Vector3,
		bDir: Vector3,
		bulgeCap: number
	): { Vector3 }
		local control = BezierCorner.ControlPoint(aEdge, aDir, bEdge, bDir)
		local mid = aEdge:Lerp(bEdge, 0.5)
		local off = Vector3.new(control.X - mid.X, 0, control.Z - mid.Z)
		local maxBulge = distanceXZ(aEdge, bEdge) * bulgeCap
		if off.Magnitude > maxBulge and off.Magnitude > 1e-6 then
			local capped = off.Unit * maxBulge
			control = Vector3.new(mid.X + capped.X, control.Y, mid.Z + capped.Z)
		end
		local points: { Vector3 } = table.create(SAMPLES + 2)
		for i = 0, SAMPLES + 1 do
			table.insert(points, BezierCorner.PointAt(aEdge, control, bEdge, i / (SAMPLES + 1)))
		end
		return points
	end

	-- How far each side's ring attachment is swung AWAY from the mouth centre,
	-- as an arc distance converted to an angle. This is what makes the entry
	-- flare OPEN into the ring (a trumpet, like a real roundabout) instead of
	-- the corners closing it back down to plain road width.
	-- Bounded in BOTH studs and angle. A multi-lane entry is already angularly
	-- wide at the ring, so letting the flare keep scaling with road width piles
	-- a ~30 deg swing on top of an already-huge mouth and the entries end up
	-- eating the whole carriageway edge (measured: 4-lane entries on a 4-leg
	-- ring wanted 133% of the ring band). The flare should add roughly a lane
	-- of extra width, not a proportion of an arbitrarily wide road.
	local flareStuds = math.clamp(ringEdges.HalfWidthStuds * 0.9, 6, 14)
	local flareRad = math.clamp(flareStuds / outerRadiusStuds, math.rad(6), math.rad(20))
	local mouthDir = flatUnit(mouthMid - center)
	-- Widest angular offset any flared corner reaches, so the caller can open
	-- the ring's own pavement over exactly this sector.
	local sectorHalf = 0
	-- Which way traffic circulates, matching circleSegments' own sign: +1
	-- (increasing angle) for right-hand drive, -1 for left-hand.
	local flow = if style.DriveOnLeft then -1 else 1
	local deflect = settings.RoundaboutEntryCurve

	local function rotateXZ(v: Vector3, angle: number): Vector3
		local ca, sa = math.cos(angle), math.sin(angle)
		return Vector3.new(v.X * ca - v.Z * sa, v.Y, v.X * sa + v.Z * ca)
	end

	local MIN_CORNER_STUDS = 0.75
	local function cornerSide(fKerb: Vector3, fOuter: Vector3)
		-- Attach BOTH boundaries at one ring angle so the band's ring end is a
		-- clean radial segment. Giving the kerb and outer ends their own radial
		-- projections puts them at different angles for a steeply-angled
		-- approach, which twists the band into a triangular flap across the
		-- mouth (the "wrong way" corner).
		local ringDir = flatUnit(fOuter - center)
		if ringDir.Magnitude < 1e-6 then
			return
		end
		-- Swing that angle away from the mouth centre so the mouth opens out,
		-- by a per-side amount when entry deflection is on.
		local bulgeCap = SYMMETRIC_BULGE
		if mouthDir.Magnitude > 1e-6 then
			local cross = mouthDir.X * ringDir.Z - mouthDir.Z * ringDir.X
			if math.abs(cross) < 1e-6 then
				-- Side radial coincides with the mouth centre radial: take the
				-- side from the edge point's own lateral offset instead.
				local lateral = fOuter - mouthMid
				cross = mouthDir.X * lateral.Z - mouthDir.Z * lateral.X
			end
			local sign = if cross >= 0 then 1 else -1
			local sideFlare = flareRad
			if deflect then
				-- Going round the ring you meet a mouth's EXIT corner first
				-- (behind, against the flow) and its ENTRY corner after
				-- (ahead, with the flow). Standard practice is a tight entry
				-- radius - that is the deflection that slows traffic joining -
				-- and a generous exit so traffic leaves freely.
				local isEntry = sign == flow
				sideFlare = flareRad * (if isEntry then ENTRY_FLARE_SCALE else EXIT_FLARE_SCALE)
				bulgeCap = if isEntry then ENTRY_BULGE else EXIT_BULGE
			end
			sideFlare = math.clamp(sideFlare, math.rad(4), math.rad(30))
			ringDir = flatUnit(rotateXZ(ringDir, sign * sideFlare))
			-- Track how far out this side reaches (signed angle to mouth centre).
			local dot = math.clamp(mouthDir.X * ringDir.X + mouthDir.Z * ringDir.Z, -1, 1)
			sectorHalf = math.max(sectorHalf, math.acos(dot))
		end
		local rKerb = Vector3.new(center.X + ringDir.X * ringKerbRadius, fKerb.Y, center.Z + ringDir.Z * ringKerbRadius)
		local rOuter =
			Vector3.new(center.X + ringDir.X * outerRadiusStuds, fOuter.Y, center.Z + ringDir.Z * outerRadiusStuds)
		-- Feeder edge already at the ring edge on this side: no notch to fill.
		if distanceXZ(fOuter, rOuter) < MIN_CORNER_STUDS and distanceXZ(fKerb, rKerb) < MIN_CORNER_STUDS then
			return
		end
		-- Both corner points share the ring tangent at that single angle.
		local ringTan = BezierCorner.Perpendicular(ringDir)
		local kerbB = cornerPolyline(fKerb, dir, rKerb, ringTan, bulgeCap)
		local outerB = cornerPolyline(fOuter, dir, rOuter, ringTan, bulgeCap)
		local n = math.min(#kerbB, #outerB)
		-- Raised sidewalk band between the kerb and outer boundaries.
		for j = 1, n - 1 do
			FillTriangle(
				raise(outerB[j]),
				raise(kerbB[j]),
				raise(kerbB[j + 1]),
				sidewalkDepth,
				DOWN,
				makeSidewalkPart,
				ring
			)
			FillTriangle(
				raise(outerB[j]),
				raise(kerbB[j + 1]),
				raise(outerB[j + 1]),
				sidewalkDepth,
				DOWN,
				makeSidewalkPart,
				ring
			)
		end
		-- Roadway asphalt inside the kerb: fan from the mouth-centre apex.
		for j = 1, #kerbB - 1 do
			FillTriangle(apexAsphalt, kerbB[j], kerbB[j + 1], thickness, DOWN, makeAsphaltPart, ring)
		end
	end

	cornerSide(ringEdges.LeftKerb, ringEdges.LeftOuter)
	cornerSide(ringEdges.RightKerb, ringEdges.RightOuter)

	-- Central throat: both side fans start at `apexAsphalt`, so the wedge
	-- straight between the feeder's two kerb points is left open (the dark
	-- notch at the mouth centre). Close it with the roadway between the feeder
	-- end and the ring's kerb.
	FillTriangle(
		apexAsphalt,
		ringEdges.LeftKerb,
		ringEdges.RightKerb,
		settings.RoadThicknessStuds,
		DOWN,
		makeAsphaltPart,
		ring
	)

	if mouthDir.Magnitude < 1e-6 or sectorHalf <= 0 then
		return nil
	end
	return { Angle = math.atan2(mouthDir.Z, mouthDir.X), Half = sectorHalf }
end

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

	local stale = junctionModel:FindFirstChild("Geometry")
	if stale then
		stale:Destroy()
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

	-- ONE continuous ring — never slice (knotted arcs).
	local ringCurve = PolyCurve.new(circleSegments(center, radiusStuds, style.DriveOnLeft))
	local ring = RoadBuilder.Build({
		Curve = ringCurve,
		ProfileStart = profile,
		Style = style,
		Settings = flatSettings(settings),
		Preview = false,
	})
	ring:SetAttribute("RW_Road", nil)
	ring.Name = "Roundabout"
	stampRingMeta(ring, center, radiusStuds, outerRadiusStuds, laneCount, laneWidthM)

	-- The ring's OWN outer pavement, captured before any feeder/corner parts are
	-- parented in. It is built as one unbroken circle, so without this it runs a
	-- raised kerb + pavement band straight across every entry - the mouth reads
	-- as walled off rather than open ("the mouth still has to open, not close
	-- into it"). Each mouth below reports the angular sector it occupies and we
	-- delete the ring pavement inside it.
	local ringPavement: { BasePart } = {}
	for _, descendant in ring:GetDescendants() do
		if descendant:IsA("BasePart") and (descendant.Name == "Sidewalk" or descendant.Name == "Marking") then
			table.insert(ringPavement, descendant :: BasePart)
		end
	end

	buildIsland(ring, center, radiusStuds, profile, style, settings)

	local mouthSectors: { MouthSector } = {}

	-- Setback: full cross-section beyond outer pavement so feeders have length.
	local trimTarget = outerRadiusStuds + SETBACK_STUDS
	-- Feeder centerline ends just inside outer pavement (blend, no gap).
	local feedAttachR = math.max(radiusStuds, outerRadiusStuds - FEED_OVERLAP_STUDS)

	for _, road in JunctionInstance.ConnectedRoads(junctionId) do
		local data = RoadInstance.Read(road)
		if not data then
			continue
		end
		local atStart = data.StartJunctionId == junctionId
		if not atStart and data.EndJunctionId ~= junctionId then
			continue
		end
		local edges = trimSpoke(road, atStart, center, trimTarget, style, settings)
		if not edges then
			continue
		end
		local trimmed = RoadInstance.Read(road)
		if not trimmed then
			continue
		end
		local cutStation = if atStart then 0 else trimmed.Curve.Length
		local cutMid = trimmed.Curve:PosAt(cutStation)
		local spokeProfile = if atStart then trimmed.ProfileStart else (trimmed.ProfileEnd or trimmed.ProfileStart)
		local feeder, ringEdges =
			buildFeederRoad(cutMid, edges.Inward, center, feedAttachR, spokeProfile, style, settings)
		if feeder then
			feeder.Parent = ring
		end
		if ringEdges then
			local sector = buildMouthCorners(
				ring,
				ringEdges,
				center,
				outerRadiusStuds,
				style.SidewalkWidthM * scale,
				style,
				settings
			)
			if sector then
				table.insert(mouthSectors, sector)
			end
		end
	end

	-- Open the ring's outer pavement over every entry so traffic actually flows
	-- in, instead of meeting a continuous raised kerb.
	-- Only the outer pavement band: from just inside the ring's outer EDGE LINE
	-- outward, so inner lane markings and the island edge line are untouched.
	-- The bound is derived from the same inset Markings.lua uses to place that
	-- edge line (MarkingWidthM * 1.5) rather than a flat constant - with a
	-- hardcoded 1-stud margin any region whose MarkingWidthM is 0.2 or more
	-- pushes the edge line inside the bound, and it survives as a white line
	-- painted straight across the mouth.
	local ringKerbRadius = outerRadiusStuds - style.SidewalkWidthM * scale
	local edgeLineInset = style.MarkingWidthM * 1.5 * scale
	openRingPavement(ringPavement, center, mouthSectors, ringKerbRadius - edgeLineInset - 0.5)

	ring.Parent = getRoundaboutsFolder()
	JunctionInstance.Delete(junctionModel)
	return ring
end

function RoundaboutBuilder.FindNear(pos: Vector3, snapRadiusStuds: number): (Model?, Vector3?, Vector3?)
	local folder = workspace:FindFirstChild(ROUNDABOUTS_FOLDER_NAME)
	if not folder then
		return nil, nil, nil
	end
	local best: Model? = nil
	local bestAttach: Vector3? = nil
	local bestOut: Vector3? = nil
	local bestScore = math.huge
	for _, child in folder:GetChildren() do
		if child:GetAttribute("RW_Roundabout") ~= true then
			continue
		end
		local c = child:GetAttribute("RW_Center") :: Vector3?
		local outerR = child:GetAttribute("RW_OuterRadius") :: number?
		if not c or not outerR then
			continue
		end
		local d = distanceXZ(pos, c)
		-- Include the setback zone: a road drawn toward the ring but stopping a
		-- little short (within the feeder setback) should still connect, matching
		-- the collection band ConnectRoad uses when it rebuilds.
		if d <= outerR + snapRadiusStuds + SETBACK_STUDS then
			local score = math.abs(d - outerR)
			if score < bestScore then
				bestScore = score
				local radial = Vector3.new(pos.X - c.X, 0, pos.Z - c.Z)
				if radial.Magnitude < 1e-6 then
					radial = Vector3.new(1, 0, 0)
				else
					radial = radial.Unit
				end
				best = child :: Model
				bestAttach = Vector3.new(c.X + radial.X * outerR, c.Y, c.Z + radial.Z * outerR)
				bestOut = radial
			end
		end
	end
	return best, bestAttach, bestOut
end

local function collectNearbyRoads(center: Vector3, maxDist: number, minDist: number): { Model }
	local folder = workspace:FindFirstChild("Roads")
	local out: { Model } = {}
	if not folder then
		return out
	end
	for _, child in folder:GetChildren() do
		if child:GetAttribute("RW_Road") ~= true then
			continue
		end
		local data = RoadInstance.Read(child :: Model)
		if not data then
			continue
		end
		local dNear =
			math.min(distanceXZ(data.Curve:PosAt(0), center), distanceXZ(data.Curve:PosAt(data.Curve.Length), center))
		if dNear <= maxDist and dNear >= minDist then
			table.insert(out, child :: Model)
		end
	end
	return out
end

function RoundaboutBuilder.ConnectRoad(
	ring: Model,
	road: Model,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): Model?
	local center = ring:GetAttribute("RW_Center") :: Vector3?
	local radiusStuds = ring:GetAttribute("RW_RingRadius") :: number?
	local outerR = ring:GetAttribute("RW_OuterRadius") :: number?
	local laneCount = ring:GetAttribute("RW_LaneCount") :: number?
	local laneWidthM = ring:GetAttribute("RW_LaneWidthM") :: number?
	if not center or not radiusStuds or not outerR or not laneCount or not laneWidthM then
		return nil
	end
	local roads = collectNearbyRoads(
		center,
		outerR + SETBACK_STUDS + settings.SnapRadiusStuds + 8,
		math.max(1, radiusStuds * 0.25)
	)
	local has = false
	for _, r in roads do
		if r == road then
			has = true
			break
		end
	end
	if not has then
		table.insert(roads, road)
	end
	if #roads < 1 then
		return nil
	end
	local junctionModel = JunctionInstance.Create(center)
	local junctionData = JunctionInstance.Read(junctionModel)
	if not junctionData then
		JunctionInstance.Delete(junctionModel)
		return nil
	end
	local jid = junctionData.Id
	for _, r in roads do
		local atStart = ringSideIsStart(r, center)
		if atStart == nil then
			continue
		end
		local data = RoadInstance.Read(r)
		if not data then
			continue
		end
		if atStart then
			RoadInstance.StampJunctions(r, jid, data.EndJunctionId)
		else
			RoadInstance.StampJunctions(r, data.StartJunctionId, jid)
		end
	end
	ring:Destroy()
	return RoundaboutBuilder.CreateAtJunction(jid, radiusStuds, laneCount, laneWidthM, style, settings)
end

-- Place a roundabout at `center` AND wire up any roads already sitting near it.
-- The Roundabout tool used to call Create directly, which builds only a bare
-- ring + island and ignores every nearby road - so dropping a roundabout onto
-- an existing cluster of roads left them all disconnected (the reported
-- "feeders don't reach the ring" gap). Here we build the ring, then hand it and
-- one nearby road to ConnectRoad, which collects the rest, forms a junction,
-- and rebuilds with feeders for all of them. With no nearby roads it is exactly
-- Create.
function RoundaboutBuilder.Place(
	center: Vector3,
	radiusStuds: number,
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): Model
	local ring = RoundaboutBuilder.Create(center, radiusStuds, laneCount, laneWidthM, style, settings)
	local outerR = ring:GetAttribute("RW_OuterRadius") :: number?
	if not outerR then
		return ring
	end
	local nearby = collectNearbyRoads(
		center,
		outerR + SETBACK_STUDS + settings.SnapRadiusStuds + 8,
		math.max(1, radiusStuds * 0.25)
	)
	if #nearby == 0 then
		return ring
	end
	return RoundaboutBuilder.ConnectRoad(ring, nearby[1], style, settings) or ring
end

return RoundaboutBuilder
