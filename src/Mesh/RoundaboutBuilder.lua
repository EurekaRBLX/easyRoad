--!strict
-- Roundabout: continuous ring (never sliced) + split entry/exit arms.
--
-- Ring is always ONE full RoadBuilder circle — never slice the annulus and
-- never parent Hermite "entry roads" onto the ring curve (those knot it).
--
-- Each approach is trimmed back and splits into a pair of ONE-WAY arms: an
-- entry that sweeps downstream onto the ring and an exit that peels upstream
-- off it, with a raised splitter island in the gore between them. Both arms
-- meet the ring TANGENTIALLY on its rim — the arm centreline ends at exactly
-- the radius that puts its outer roadway edge on the ring's kerb, carrying the
-- ring's own tangent — so kerb, pavement and carriageway flow into the ring
-- instead of butting into it. That replaces the old single full-width feeder
-- per approach, which butted the road square into the ring and needed
-- curb-return corner fills to patch the notches it left on either side.

local CurveSegment = require("../Geometry/CurveSegment")
local PolyCurve = require("../Geometry/PolyCurve")
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

-- How far past the ring's outer edge each approach is cut back, so the entry
-- and exit arms have the length to split apart and swing round onto the rim.
-- Scaled off the ring so a big roundabout gets long sweeping arms and a mini
-- one doesn't eat 90 studs of the user's road.
local ARM_RUN_FACTOR = 0.85
local ARM_RUN_MIN_STUDS = 28
local ARM_RUN_MAX_STUDS = 90

local function armRunStuds(outerRadiusStuds: number): number
	return math.clamp(outerRadiusStuds * ARM_RUN_FACTOR, ARM_RUN_MIN_STUDS, ARM_RUN_MAX_STUDS)
end

-- Circulation sign. Increasing angle runs from +X toward +Z, which viewed from
-- above (down -Y) is CLOCKWISE - so left-hand drive, which circulates
-- clockwise, is +1. Everything downstream reads its handedness off this: the
-- side the ring's own pavement goes on, and which of a mouth's two arms is the
-- entry (see armProfileFor / buildMouth).
local function circleSegments(center: Vector3, radiusStuds: number, driveOnLeft: boolean): { CurveSegment.Segment }
	local sign = if driveOnLeft then 1 else -1
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
	-- Right of travel is -sign * radially-outward, so the OUTWARD side is the
	-- left of travel when circulating clockwise (left-hand drive) and the right
	-- when anticlockwise. The pavement always belongs on the outward side.
	if style.DriveOnLeft then
		table.insert(components, 1, sidewalk)
	else
		table.insert(components, sidewalk)
	end
	return components
end

-- Centreline to the ring's INNER edge, i.e. the side the central island is on -
-- the opposite side from the pavement (see ringComponents).
local function ringInnerHalfWidthM(profile: RoadProfile.RoadProfile, style: RegionStyles.RegionStyle): number
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	if style.DriveOnLeft then
		return offsets[#offsets].Right
	end
	return -offsets[1].Left
end

-- Down, for FillTriangle's extrude direction. Everything this module fills
-- is flat ground-plane geometry, so it never varies.
local DOWN = Vector3.new(0, -1, 0)

-- Shortest signed difference between two angles, in (-pi, pi].
local function angleDelta(a: number, b: number): number
	local d = (a - b) % (2 * math.pi)
	if d > math.pi then
		d -= 2 * math.pi
	end
	return d
end

-- A Cylinder island is kept while the scallop it leaves against the ring's
-- inner edge is narrower than this; past it the island is fanned onto the
-- ring's own vertices instead.
--
-- The test is on the scallop rather than on the radius because the trade is
-- real in both directions. A cylinder is ONE Part; a fan is one per station,
-- and station count does not track radius the way one would guess - RoadBuilder
-- sets it from its chord tolerance against the ring's own half-width, so a
-- SMALL ring with a wide carriageway gets very fine stations (a 20-stud ring
-- runs to ~64) while a large one gets stations that are coarse relative to its
-- size. Picking a radius threshold would have spent 300-odd Parts smoothing
-- rings whose scallop was already a thousandth of a stud.
--
-- Measured across realistic rings the scallop runs about 0.012 studs at R=20,
-- 0.028 at R=40 and 0.040 at R=100 - so testing it directly still falls out as
-- "cylinder on small rings, fan on large ones", just derived instead of
-- asserted. 0.02 sits below anything visible at working zoom and inside
-- RoadBuilder's own 0.05-stud chord tolerance, so the island is never the least
-- accurate thing on screen.
local ISLAND_FAN_MIN_SCALLOP_STUDS = 0.02

-- The centre island, filling the hole inside the ring.
--
-- `ringStations` is where RoadBuilder put this ring's strips (via
-- RoadBuilder.StationsFor). That matters because the ring is emitted as RIGID
-- strips: its inner edge is not a circle, it is a POLYGON inscribed in one,
-- pulled inside the true radius by up to RoadBuilder's own chord tolerance at
-- every chord midpoint. A Cylinder island of the matching radius is a true
-- circle, so it overlaps the ring's asphalt in a scallop all the way round -
-- reported live as the island reading as a polygon against the ring.
--
-- Building the island's rim on the ring's OWN station angles makes the two
-- share a boundary by construction. Sampling the ring curve rather than
-- assuming a uniform angular step also keeps it exact if the stations are ever
-- non-uniform (the ring is four Bezier arcs, not an analytic circle).
local function buildIsland(
	model: Model,
	center: Vector3,
	radiusStuds: number,
	profile: RoadProfile.RoadProfile,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings,
	ringCurve: PolyCurve.PolyCurve?,
	ringStations: { number }?
)
	local scale = settings.MetersToStuds
	local thickness = settings.RoadThicknessStuds
	local curbHeight = style.CurbHeightM * scale
	local islandRadiusStuds = radiusStuds - ringInnerHalfWidthM(profile, style) * scale
	if islandRadiusStuds <= 1 then
		return
	end

	local function makeIslandPart(): Part
		local part = Instance.new("Part")
		part.Name = "Island"
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

	-- The ring's station angles, deduplicated. The curve is closed, so its
	-- last station lands back on the first and must not become a zero-width
	-- wedge.
	local angles: { number } = {}
	local rim: { Vector3 } = {}
	if ringCurve and ringStations then
		local seenAngles: { number } = {}
		local seenRim: { Vector3 } = {}
		local innerHalfStuds = ringInnerHalfWidthM(profile, style) * scale
		for _, station in ringStations do
			local point = ringCurve:PosAt(math.clamp(station, 0, ringCurve.Length))
			local dx, dz = point.X - center.X, point.Z - center.Z
			local radius = math.sqrt(dx * dx + dz * dz)
			if radius > 1e-3 then
				table.insert(seenAngles, math.atan2(dz, dx))
				-- Pull the ring's own point radially inward by the ring's inner
				-- half-width, rather than reprojecting onto a nominal radius.
				-- The ring curve is four Bezier arcs approximating a circle, not
				-- an exact one, so a nominal radius would reintroduce that
				-- approximation's error - about 0.03 studs at a 120-stud ring,
				-- the same size as the scallop this exists to remove.
				local inner = (radius - innerHalfStuds) / radius
				table.insert(seenRim, Vector3.new(center.X + dx * inner, center.Y + curbHeight, center.Z + dz * inner))
			end
		end
		for i, angle in seenAngles do
			local previous = if i > 1 then seenAngles[i - 1] else seenAngles[#seenAngles] - 2 * math.pi
			if math.abs(angleDelta(angle, previous)) > 1e-4 then
				table.insert(angles, angle)
				table.insert(rim, seenRim[i])
			end
		end
	end

	-- Worst scallop a Cylinder would leave: the sagitta of the widest gap
	-- between two adjacent ring vertices, at the island's own radius.
	local widestGap = 0
	for i, angle in angles do
		local previous = if i > 1 then angles[i - 1] else angles[#angles] - 2 * math.pi
		widestGap = math.max(widestGap, math.abs(angleDelta(angle, previous)))
	end
	local scallopStuds = islandRadiusStuds * (1 - math.cos(widestGap / 2))

	if #angles < 3 or scallopStuds < ISLAND_FAN_MIN_SCALLOP_STUDS then
		-- No station list, or a scallop too small to see: a Cylinder is one
		-- Part instead of one per station, and nothing is gained by the fan.
		local island = makeIslandPart()
		island.Shape = Enum.PartType.Cylinder
		island.Size = Vector3.new(thickness + curbHeight, islandRadiusStuds * 2, islandRadiusStuds * 2)
		island.CFrame = CFrame.new(center + Vector3.new(0, curbHeight - (thickness + curbHeight) / 2, 0))
			* CFrame.Angles(0, 0, math.rad(90))
		island.Parent = model
		return
	end

	local top = Vector3.new(center.X, center.Y + curbHeight, center.Z)
	local depth = thickness + curbHeight
	for i = 1, #rim do
		FillTriangle(top, rim[i], rim[if i < #rim then i + 1 else 1], depth, DOWN, makeIslandPart, model)
	end
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
	local ringOptions = {
		Curve = curve,
		ProfileStart = profile,
		Style = style,
		Settings = flatSettings(settings),
		Preview = false,
	}
	local model = RoadBuilder.Build(ringOptions)
	model:SetAttribute("RW_Road", nil)
	model.Name = "Roundabout"
	local halfW = RoadProfile.TotalWidthM(profile) / 2 * settings.MetersToStuds
	stampRingMeta(model, center, radiusStuds, radiusStuds + halfW, laneCount, laneWidthM)
	buildIsland(model, center, radiusStuds, profile, style, settings, curve, RoadBuilder.StationsFor(ringOptions))
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

-- The angular slice of the ring one mouth occupies. ASYMMETRIC: a mouth's two
-- arms merge at different distances from its centreline (the entry closer, when
-- deflection is on), so a single half-angle either under-opens one side or
-- over-opens the other. `Ahead` extends in the +angle direction, `Behind` in -.
export type MouthSector = { Angle: number, Ahead: number, Behind: number }

-- Minimum kerb that must survive between two adjacent entries, and the most
-- any single entry may open. Without these, wide (multi-lane) entries produce
-- sectors that overlap their neighbours and between them delete the entire
-- ring band, leaving a roundabout with no carriageway edge at all.
local MIN_KERB_GAP_RAD = math.rad(8)
local MAX_SECTOR_HALF_RAD = math.rad(60)
-- The sector is pulled IN from where the arms actually land, never pushed out.
-- Deleting less than the arms cover is invisible - the arm's own pavement lies
-- over the ring's there. Deleting more strips the kerb off ground no arm
-- reaches, which is bare ground in a ring of pavement. Sized at about one
-- strip's angular length so a part whose centre is just inside the bound, and
-- which therefore straddles it, is still fully covered.
local SECTOR_INSET_RAD = math.rad(3)

-- Shrink sectors until each leaves MIN_KERB_GAP_RAD of kerb to its angular
-- neighbours. Each sector may claim at most half of the gap on either side
-- (minus half the required kerb), which cannot overlap.
local function clampSectors(sectors: { MouthSector }): { MouthSector }
	if #sectors == 0 then
		return sectors
	end
	local sorted = table.clone(sectors)
	table.sort(sorted, function(a, b)
		return a.Angle < b.Angle
	end)
	if #sorted == 1 then
		return {
			{
				Angle = sorted[1].Angle,
				Ahead = math.min(sorted[1].Ahead, MAX_SECTOR_HALF_RAD),
				Behind = math.min(sorted[1].Behind, MAX_SECTOR_HALF_RAD),
			},
		}
	end
	local clamped: { MouthSector } = {}
	for i, sector in sorted do
		local prev = sorted[if i > 1 then i - 1 else #sorted]
		local nextOne = sorted[if i < #sorted then i + 1 else 1]
		local gapPrev = (sector.Angle - prev.Angle) % (2 * math.pi)
		local gapNext = (nextOne.Angle - sector.Angle) % (2 * math.pi)
		local ahead = math.min(sector.Ahead, MAX_SECTOR_HALF_RAD, math.max(0, (gapNext - MIN_KERB_GAP_RAD) / 2))
		local behind = math.min(sector.Behind, MAX_SECTOR_HALF_RAD, math.max(0, (gapPrev - MIN_KERB_GAP_RAD) / 2))
		if ahead > 0 or behind > 0 then
			table.insert(clamped, { Angle = sector.Angle, Ahead = ahead, Behind = behind })
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
			local delta = angleDelta(angle, sector.Angle)
			if delta <= sector.Ahead and -delta <= sector.Behind then
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

-- Split entry/exit arms --------------------------------------------------------
--
-- Angle between a mouth's centreline and each of its two merge points on the
-- ring, the floor it may be squeezed to when the legs are crowded, and the strip
-- of untouched kerb kept just outside each mouth. Because both arms approach
-- their merge points from the mouth side, the pair's whole angular footprint
-- lies INSIDE the split - so the sector is the split plus that margin, and
-- nothing extra for the arms' own width.
local SPLIT_ANGLE_RAD = math.rad(38)
local MIN_SPLIT_RAD = math.rad(14)
-- Kerb reserved beyond a mouth's own split when budgeting against neighbouring
-- legs. Distinct from SECTOR_INSET_RAD, which trims the PAVEMENT OPENING back
-- inside the arms; this one just keeps two mouths from growing into each other.
local SECTOR_MARGIN_RAD = math.rad(3)
-- Cubic handle as a fraction of the arm's chord. Both ends fight each other
-- here: the ring-end tangent runs sideways to the approach, so a long handle
-- walks that control point across the gore and the entry and its own exit close
-- up against each other, while a short one buys the clearance back by kinking
-- the arm into a hairpin at the ring. 0.30 is the measured middle - roughly a
-- 20-stud minimum radius on a 4-leg ring with a full carriageway of gore left
-- between the arms.
local ARM_HANDLE = 0.30
-- Tight entry, generous exit: the entry merges closer to the mouth, and that
-- deflection is what slows traffic joining the ring (Settings.RoundaboutEntryCurve).
local ENTRY_SPLIT_SCALE = 0.8
-- Splitter island: the gore fill runs from the approach right up to the ring's
-- kerb, where it stops - past that the "gap" between the two arms is the
-- circulating carriageway itself, so filling further would lay a raised band
-- across the mouth the island exists to divide.
local GORE_SAMPLES = 18
-- On a ring too crowded for the mouths it carries - many legs, or wide
-- approaches on a small radius - the split gets squeezed until the two arms run
-- right up against each other partway along. The strip runs THROUGH that waist
-- rather than stopping at it: the pinched rungs collapse to zero area and
-- FillTriangle drops them, while the island still forms either side. Bailing out
-- at the waist instead threw away everything beyond it, including the wide part
-- against the ring, and left bare kerb at the mouth.
-- Arc step for the island's nose fan where it meets the ring kerb.
local NOSE_ARC_STEP_RAD = math.rad(2)
-- Narrowest gore that counts as a splitter island. The gore is the gap between
-- the two arms' INNER roadway edges, so on an approach with a median it starts
-- out that median's width, and on one WITHOUT a median it starts at zero and
-- only opens up as the arms diverge toward the ring.
--
-- Filling from the cut regardless put a raised strip down the middle of an
-- approach whose road has no median at all - reported live as "there is median
-- when there is no median for the type of road used", with the taper reading as
-- an indentation. Starting the island where the gore first reaches a width a
-- median could actually have needs no "does this road have a median" test: an
-- approach that has one is already wider than this at the cut and is unchanged,
-- and one that doesn't gets island only where the two carriageways have genuinely
-- separated - which is the part of a splitter that does real work anyway.
local MIN_GORE_WIDTH_M = 0.5
-- Arms are dropped a hair below the ring deck. Near the merge an arm's inner
-- half necessarily lies over the ring's own carriageway (that overlap IS the
-- merge), and two coplanar asphalt decks z-fight. Same colour and material, so
-- letting the ring win is invisible - except that it also hides the arm's edge
-- lines where they run inside the ring, which is what we want anyway.
local ARM_SINK_STUDS = 0.05

local function rightOf(tangent: Vector3): Vector3
	return Vector3.new(-tangent.Z, 0, tangent.X)
end

-- Ring tangent/point at an angle, matching circleSegments' own sign convention
-- so an arm that ends here is genuinely tangent to the circulating carriageway.
local function ringTangentAt(angle: number, flow: number): Vector3
	return Vector3.new(-math.sin(angle), 0, math.cos(angle)) * flow
end

local function ringPointAt(center: Vector3, angle: number, radiusStuds: number, y: number): Vector3
	return Vector3.new(center.X + math.cos(angle) * radiusStuds, y, center.Z + math.sin(angle) * radiusStuds)
end

-- Cubic with BOTH end tangents pinned, so the arm leaves the approach along the
-- road and arrives on the ring along the ring.
local function armSegment(p0: Vector3, t0: Vector3, p1: Vector3, t1: Vector3, handle: number): CurveSegment.Segment
	local h = math.max(2, distanceXZ(p0, p1) * handle)
	return CurveSegment.Cubic(p0, p0 + t0 * h, p1 - t1 * h, p1)
end

type ArmProfile = {
	Profile: RoadProfile.RoadProfile,
	-- Centreline to roadway edge, on the side facing away from / toward the gore.
	OuterOffsetStuds: number,
	InnerOffsetStuds: number,
	-- Centre of the arm's ROADWAY relative to its centreline. The two differ
	-- because the pavement sits on one side only, and it is the roadway that has
	-- to land on the lanes the arm is replacing.
	RoadwayCentreM: number,
}

-- The lanes of an approach travelling one way, and the span they occupy in the
-- approach profile's own frame.
type LaneGroup = { Widths: { number }, LeftM: number, RightM: number, PavementM: number }

-- One direction's worth of an approach, as a one-way road: the lanes that
-- actually travel that way, plus a single pavement on the arm's OUTER side. A
-- pavement on both sides would lay a raised strip down the middle of the mouth,
-- since the gore side is where the splitter island goes.
local function armProfileFor(
	group: LaneGroup,
	solo: boolean,
	style: RegionStyles.RegionStyle,
	scale: number
): ArmProfile
	local components: { RoadProfile.ProfileComponent } = {}
	for _, widthM in group.Widths do
		table.insert(components, { Kind = "Drive", WidthM = widthM, Direction = 1 })
	end
	local function pavement(): RoadProfile.ProfileComponent
		return { Kind = "Sidewalk", WidthM = group.PavementM, Direction = 0 }
	end
	if solo then
		-- A one-way approach has no sibling arm and so no splitter island: its gore
		-- side is open ground, and the road it replaces carries a footway there.
		-- Give it both, or the mouth comes out a pavement narrower than the road.
		table.insert(components, 1, pavement())
		table.insert(components, pavement())
	elseif style.DriveOnLeft then
		-- Same placement rule as ringComponents, and it lands on the same world
		-- side: an arm merges tangentially, so at the merge its right of travel is
		-- the ring's, and the outward side is the same one either way.
		table.insert(components, 1, pavement())
	else
		table.insert(components, pavement())
	end
	local profile: RoadProfile.RoadProfile = {
		Id = "roundabout_arm",
		Name = "Roundabout arm",
		Category = "Custom",
		BuiltIn = false,
		Components = components,
	}
	local leftM, rightM = roadwayEdgeOffsetsM(profile)
	return {
		Profile = profile,
		OuterOffsetStuds = (if style.DriveOnLeft then -leftM else rightM) * scale,
		InnerOffsetStuds = (if style.DriveOnLeft then rightM else -leftM) * scale,
		RoadwayCentreM = (leftM + rightM) / 2,
	}
end

-- Split an approach into the lanes running INTO the ring and the lanes running
-- out of it, by each lane's own Direction rather than by halving the count.
-- Halving is wrong the moment a road isn't symmetric: a 3/1 dual carriageway
-- gets two 2-lane arms that don't line up with either side, and a one-way road
-- gets an entry AND an exit where only one of them exists.
--
-- `inboundSign` is the Direction value that means "toward the ring": lanes are
-- tagged relative to the curve's own travel, so it flips depending on which end
-- of the road the junction sits at.
local function splitApproachLanes(
	profile: RoadProfile.RoadProfile,
	inboundSign: number,
	style: RegionStyles.RegionStyle
): (LaneGroup?, LaneGroup?)
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	local function newGroup(): LaneGroup
		return { Widths = {}, LeftM = math.huge, RightM = -math.huge, PavementM = style.SidewalkWidthM }
	end
	local inbound, outbound = newGroup(), newGroup()
	local function add(group: LaneGroup, index: number)
		table.insert(group.Widths, profile.Components[index].WidthM)
		group.LeftM = math.min(group.LeftM, offsets[index].Left)
		group.RightM = math.max(group.RightM, offsets[index].Right)
	end
	for i, component in profile.Components do
		if not RoadProfile.IsRoadway(component.Kind) then
			continue
		end
		if component.Direction == inboundSign then
			add(inbound, i)
		elseif component.Direction == -inboundSign then
			add(outbound, i)
		end
	end
	-- Undirected roadway (shoulders, parking) belongs to whichever side it abuts;
	-- anything left in the middle is a median and becomes the splitter gore.
	for i, component in profile.Components do
		if not RoadProfile.IsRoadway(component.Kind) or component.Direction ~= 0 then
			continue
		end
		local edge = offsets[i]
		for _, group in { inbound, outbound } do
			if
				#group.Widths > 0
				and (math.abs(edge.Right - group.LeftM) < 1e-6 or math.abs(edge.Left - group.RightM) < 1e-6)
			then
				add(group, i)
				break
			end
		end
	end
	-- Pavement width per side, taken from the footway the approach actually has
	-- outboard of those lanes, so the kerb line runs on unbroken.
	local function adoptPavement(group: LaneGroup)
		for i, component in profile.Components do
			if component.Kind ~= "Sidewalk" then
				continue
			end
			local edge = offsets[i]
			if math.abs(edge.Right - group.LeftM) < 1e-6 or math.abs(edge.Left - group.RightM) < 1e-6 then
				group.PavementM = component.WidthM
			end
		end
	end
	local function finish(group: LaneGroup): LaneGroup?
		if #group.Widths == 0 then
			return nil
		end
		adoptPavement(group)
		return group
	end
	return finish(inbound), finish(outbound)
end

-- Fallback for a profile whose lanes carry no direction at all: split the
-- roadway down the middle, which is what the old halving did for everything.
local function splitUndirected(
	profile: RoadProfile.RoadProfile,
	fallbackLaneWidthM: number,
	style: RegionStyles.RegionStyle
): (LaneGroup?, LaneGroup?)
	local leftM, rightM = roadwayEdgeOffsetsM(profile)
	if rightM - leftM < 1e-6 then
		leftM, rightM = -fallbackLaneWidthM / 2, fallbackLaneWidthM / 2
	end
	local midM = (leftM + rightM) / 2
	local pavement = style.SidewalkWidthM
	for _, component in profile.Components do
		if component.Kind == "Sidewalk" then
			pavement = math.max(pavement, component.WidthM)
		end
	end
	return { Widths = { midM - leftM }, LeftM = leftM, RightM = midM, PavementM = pavement }, {
		Widths = { rightM - midM },
		LeftM = midM,
		RightM = rightM,
		PavementM = pavement,
	}
end

local function buildArm(
	curve: PolyCurve.PolyCurve,
	arm: ArmProfile,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): Model
	local model = RoadBuilder.Build({
		Curve = curve,
		ProfileStart = arm.Profile,
		Style = style,
		Settings = flatSettings(settings),
		Preview = false,
	})
	-- Not a free-standing editable road - owned by the roundabout mesh.
	model:SetAttribute("RW_Road", nil)
	model.Name = "RoundaboutArm"
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CFrame = descendant.CFrame - Vector3.new(0, ARM_SINK_STUDS, 0)
		end
	end
	return model
end

-- Raised splitter island in the gore between an entry and its exit, bounded by
-- the two arms' inner roadway edges.
local function buildSplitterIsland(
	ring: Model,
	entryCurve: PolyCurve.PolyCurve,
	exitCurve: PolyCurve.PolyCurve,
	entryArm: ArmProfile,
	exitArm: ArmProfile,
	center: Vector3,
	ringKerbRadiusStuds: number,
	flow: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
)
	local scale = settings.MetersToStuds
	local curbHeight = style.CurbHeightM * scale
	local depth = settings.RoadThicknessStuds + curbHeight
	local function makeSidewalkPart(): Part
		local part = Instance.new("Part")
		part.Name = "Sidewalk"
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
	-- Gore-side roadway edge: the inner offset lies on +flow * right-of-travel for
	-- both arms (the exit's travel is reversed, and so is its own right).
	-- Each arm gets its OWN inner offset. Sharing the entry's is only right when
	-- the two are the same width; on a 3/1 approach it tracks the narrow exit's
	-- edge a lane and a half out of place, and the island misses the carriageway.
	local function goreEdge(curve: PolyCurve.PolyCurve, station: number, arm: ArmProfile): Vector3
		local s = math.clamp(station, 0, curve.Length)
		local position = curve:PosAt(s)
		local tangent = flatUnit(curve:TangentAt(s))
		if tangent.Magnitude < 1e-6 then
			return position
		end
		return position + rightOf(tangent) * (arm.InnerOffsetStuds * flow) + Vector3.new(0, curbHeight, 0)
	end
	-- Station at which one arm's gore edge first drops inside the ring's kerb,
	-- searched forward from `station` in `direction` (+1 along the entry, -1
	-- along the exit, which is parameterised from the ring outward).
	local function kerbCrossing(curve: PolyCurve.PolyCurve, station: number, direction: number, arm: ArmProfile): number
		local step = curve.Length / 128
		local s = station
		for _ = 1, 160 do
			local nextS = s + direction * step
			if nextS < 0 or nextS > curve.Length then
				return math.clamp(nextS, 0, curve.Length)
			end
			if distanceXZ(goreEdge(curve, nextS, arm), center) <= ringKerbRadiusStuds then
				local lo, hi = s, nextS
				for _ = 1, 24 do
					local mid = (lo + hi) / 2
					if distanceXZ(goreEdge(curve, mid, arm), center) > ringKerbRadiusStuds then
						lo = mid
					else
						hi = mid
					end
				end
				return hi
			end
			s = nextS
		end
		return s
	end
	-- Rungs are paired by DISTANCE FROM THE APPROACH, not by curve fraction: the
	-- entry and exit are different lengths, so equal fractions sit at different
	-- distances back from the cut and the island comes out sheared.
	local reach = math.min(entryCurve.Length, exitCurve.Length)
	local minGoreStuds = MIN_GORE_WIDTH_M * scale
	local entrySide: { Vector3 } = {}
	local exitSide: { Vector3 } = {}
	local lastAlong = 0
	for i = 0, GORE_SAMPLES do
		local along = (i / GORE_SAMPLES) * reach
		local a = goreEdge(entryCurve, along, entryArm)
		local b = goreEdge(exitCurve, exitCurve.Length - along, exitArm)
		-- Stop once either edge has dropped inside the kerb. Past that the island
		-- would be laid over the circulating carriageway, not beside it - an
		-- earlier attempt projected these points radially out onto the kerb
		-- instead of stopping, which paved the mouth shut.
		if i > 0 and (distanceXZ(a, center) <= ringKerbRadiusStuds or distanceXZ(b, center) <= ringKerbRadiusStuds) then
			break
		end
		-- Don't start the island until the gore is wide enough to be one. Only
		-- skips leading samples: once the strip has started, a later pinch is
		-- carried through (see the waist note above), it is only the approach
		-- end that must not invent a median.
		if #entrySide == 0 and distanceXZ(a, b) < minGoreStuds then
			continue
		end
		table.insert(entrySide, a)
		table.insert(exitSide, b)
		lastAlong = along
	end
	for j = 1, #entrySide - 1 do
		FillTriangle(entrySide[j], exitSide[j], exitSide[j + 1], depth, DOWN, makeSidewalkPart, ring)
		FillTriangle(entrySide[j], exitSide[j + 1], entrySide[j + 1], depth, DOWN, makeSidewalkPart, ring)
	end

	-- Nose. The strip stops at the FIRST of the two edges to reach the kerb, so
	-- the other one still has a run of island left outside it, and beyond both
	-- the frontage is an arc of the kerb rather than the chord the last rung
	-- draws. Close all of that here: out along each edge to its own crossing,
	-- then around the kerb between them. Without it every mouth keeps a crescent
	-- of bare ground where the island should meet the carriageway.
	local nose, tail = entrySide[#entrySide], exitSide[#exitSide]
	if not nose or not tail then
		return
	end
	local noseEnd = goreEdge(entryCurve, kerbCrossing(entryCurve, lastAlong, 1, entryArm), entryArm)
	local tailEnd = goreEdge(exitCurve, kerbCrossing(exitCurve, exitCurve.Length - lastAlong, -1, exitArm), exitArm)
	local a0 = math.atan2(noseEnd.Z - center.Z, noseEnd.X - center.X)
	local a1 = math.atan2(tailEnd.Z - center.Z, tailEnd.X - center.X)
	local sweep = angleDelta(a1, a0)
	local steps = math.max(1, math.ceil(math.abs(sweep) / NOSE_ARC_STEP_RAD))
	local apex = nose:Lerp(tail, 0.5)
	local boundary: { Vector3 } = { nose, noseEnd }
	for k = 1, steps - 1 do
		table.insert(boundary, ringPointAt(center, a0 + sweep * (k / steps), ringKerbRadiusStuds, nose.Y))
	end
	table.insert(boundary, tailEnd)
	table.insert(boundary, tail)
	for k = 1, #boundary - 1 do
		FillTriangle(apex, boundary[k], boundary[k + 1], depth, DOWN, makeSidewalkPart, ring)
	end
end

-- Everything about a mouth that is fixed by the approach alone. Worked out for
-- every leg BEFORE any arm is built, because how far a mouth may split depends
-- on where its neighbours actually landed.
type MouthArm = {
	Profile: ArmProfile,
	MergeRadius: number,
	-- Centreline offset at the cut, measured from the approach's centreline along
	-- the RIGHT OF THE INWARD direction, so both arms use one frame.
	LateralStuds: number,
}

type MouthPlan = {
	CutMid: Vector3,
	Direction: Vector3,
	-- Either may be absent: a one-way approach only has the one.
	Entry: MouthArm?,
	Exit: MouthArm?,
	-- Ring angle the approach aims at.
	Angle: number,
}

local function planMouth(
	cutMid: Vector3,
	inward: Vector3,
	spokeProfile: RoadProfile.RoadProfile,
	atStart: boolean,
	center: Vector3,
	ringKerbRadiusStuds: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): MouthPlan?
	local dir = flatUnit(inward)
	if dir.Magnitude < 1e-6 then
		return nil
	end
	local scale = settings.MetersToStuds

	-- Lanes are tagged relative to the curve's own travel, so which sign means
	-- "toward the ring" depends on which end of the road the junction is at.
	local inboundSign = if atStart then -1 else 1
	local inbound, outbound = splitApproachLanes(spokeProfile, inboundSign, style)
	if not inbound and not outbound then
		inbound, outbound = splitUndirected(spokeProfile, laneWidthM, style)
	end
	if not inbound and not outbound then
		return nil
	end

	-- Spoke profile offsets are in the CURVE's frame; the arms are laid out in
	-- the inward frame. They are the same frame only when the junction is at the
	-- far end of the road.
	local toInward = if atStart then -1 else 1

	local solo = (inbound == nil) ~= (outbound == nil)
	local function makeArm(group: LaneGroup?, travelsInward: boolean): MouthArm?
		if not group then
			return nil
		end
		local profile = armProfileFor(group, solo, style, scale)
		local mergeRadius = ringKerbRadiusStuds - profile.OuterOffsetStuds
		if mergeRadius <= 1 then
			return nil
		end
		-- Land the arm's ROADWAY on the very lanes it replaces, so asphalt, kerb
		-- and pavement all run straight through the cut. An arm running outward
		-- has its own right-of-travel reversed against the inward frame, so its
		-- roadway offset flips with it.
		local spanCentreInward = (group.LeftM + group.RightM) / 2 * toInward
		local lateralM = if travelsInward
			then spanCentreInward - profile.RoadwayCentreM
			else spanCentreInward + profile.RoadwayCentreM
		return { Profile = profile, MergeRadius = mergeRadius, LateralStuds = lateralM * scale }
	end

	local entry = makeArm(inbound, true)
	local exit = makeArm(outbound, false)
	if not entry and not exit then
		return nil
	end

	-- Mouth angle: where the approach's OWN centreline, continued, first meets
	-- the merge circle. Taking the cut point's radial instead swings the whole
	-- mouth off the road line for any approach that doesn't aim at the centre.
	local aimRadius = if entry then entry.MergeRadius else (exit :: MouthArm).MergeRadius
	local aim = rayCircleFirstHit(cutMid, dir, center, aimRadius) or cutMid
	local aimDir = flatUnit(aim - center)
	if aimDir.Magnitude < 1e-6 then
		return nil
	end
	return {
		CutMid = cutMid,
		Direction = dir,
		Entry = entry,
		Exit = exit,
		Angle = math.atan2(aimDir.Z, aimDir.X),
	}
end

-- How far either side of its centreline one mouth may swing, from the angular
-- room its nearest neighbour actually leaves - not from an assumed even spread
-- of legs, which hands a mouth wedged 45 degrees from its neighbour the same
-- budget as one with the ring to itself.
local function splitBudgetFor(plans: { MouthPlan }, index: number): number
	local angle = plans[index].Angle
	local nearest = 2 * math.pi
	for i, other in plans do
		if i ~= index then
			local ahead = (other.Angle - angle) % (2 * math.pi)
			nearest = math.min(nearest, ahead, 2 * math.pi - ahead)
		end
	end
	return math.max(MIN_SPLIT_RAD, nearest / 2 - MIN_KERB_GAP_RAD / 2)
end

-- The two split angles for a mouth, and where each arm therefore meets the
-- ring. Shared by the builder and the debug dump on purpose: a dump that
-- recomputes these itself is a third implementation to disagree with.
local function resolveSplits(
	plan: MouthPlan,
	splitBudgetRad: number,
	flow: number,
	settings: Settings.EasyRoadSettings
): (number, number, number, number)
	local split =
		math.clamp(SPLIT_ANGLE_RAD, MIN_SPLIT_RAD, math.max(MIN_SPLIT_RAD, splitBudgetRad - SECTOR_MARGIN_RAD))
	local entrySplit = if settings.RoundaboutEntryCurve
		then math.max(MIN_SPLIT_RAD, split * ENTRY_SPLIT_SCALE)
		else split
	-- Going round the ring you meet a mouth's EXIT first (upstream, against the
	-- flow) and its ENTRY after (downstream, with it).
	return split, entrySplit, plan.Angle + flow * entrySplit, plan.Angle - flow * split
end

-- One mouth: entry arm, exit arm, splitter island. Returns the angular sector
-- the mouth occupies so the caller can open the ring's own pavement over it.
local function buildMouth(
	ring: Model,
	plan: MouthPlan,
	center: Vector3,
	splitBudgetRad: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): MouthSector
	-- Which way traffic circulates, matching circleSegments' own sign.
	local flow = if style.DriveOnLeft then 1 else -1
	local dir = plan.Direction
	local side = rightOf(dir)

	local split, entrySplit, entryAngle, exitAngle = resolveSplits(plan, splitBudgetRad, flow, settings)

	local entryCurve: PolyCurve.PolyCurve? = nil
	local exitCurve: PolyCurve.PolyCurve? = nil
	local ringKerbRadius = 0

	local entry = plan.Entry
	if entry then
		entryCurve = PolyCurve.new({
			armSegment(
				plan.CutMid + side * entry.LateralStuds,
				dir,
				ringPointAt(center, entryAngle, entry.MergeRadius, plan.CutMid.Y),
				ringTangentAt(entryAngle, flow),
				ARM_HANDLE
			),
		})
		buildArm(entryCurve :: PolyCurve.PolyCurve, entry.Profile, style, settings).Parent = ring
		ringKerbRadius = entry.MergeRadius + entry.Profile.OuterOffsetStuds
	end

	local exit = plan.Exit
	if exit then
		exitCurve = PolyCurve.new({
			armSegment(
				ringPointAt(center, exitAngle, exit.MergeRadius, plan.CutMid.Y),
				ringTangentAt(exitAngle, flow),
				plan.CutMid + side * exit.LateralStuds,
				-dir,
				ARM_HANDLE
			),
		})
		buildArm(exitCurve :: PolyCurve.PolyCurve, exit.Profile, style, settings).Parent = ring
		ringKerbRadius = exit.MergeRadius + exit.Profile.OuterOffsetStuds
	end

	-- Splitter island only where there are actually two carriageways to divide.
	-- A one-way approach has a single arm and no gore, and building one would
	-- put a raised island alongside a road with nothing on the other side of it.
	if entry and exit and entryCurve and exitCurve then
		buildSplitterIsland(
			ring,
			entryCurve :: PolyCurve.PolyCurve,
			exitCurve :: PolyCurve.PolyCurve,
			entry.Profile,
			exit.Profile,
			center,
			ringKerbRadius,
			flow,
			style,
			settings
		)
	end

	-- With BOTH arms the sector spans the mouth: the arms bound it and the
	-- splitter island fills the middle, so opening from the mouth centre out to
	-- each arm is covered throughout. With only ONE arm there is no island and
	-- nothing holds the middle, so the opening shrinks to the arm itself -
	-- centred where it merges, one arm-width wide. Opening the full sector there
	-- strips the kerb off ground the single arm never reaches.
	if not (entry and exit) then
		local only = (entry or exit) :: MouthArm
		local onlyCurve = (entryCurve or exitCurve) :: PolyCurve.PolyCurve
		local mergeAngle = if entry then entryAngle else exitAngle
		local outerRadius = ringKerbRadius + style.SidewalkWidthM * settings.MetersToStuds
		local edgeAngle = bandExitAngle(
			onlyCurve,
			only.Profile,
			if entry then onlyCurve.Length else 0,
			if entry then -1 else 1,
			center,
			outerRadius,
			flow
		)
		local sweep = angleDelta(mergeAngle, edgeAngle)
		local half = math.max(0, math.abs(sweep) / 2 - SECTOR_INSET_RAD)
		return { Angle = edgeAngle + sweep / 2, Ahead = half, Behind = half }
	end
	-- Open exactly as far as each arm actually reaches, inset so the opening can
	-- never outrun them.
	local entryHalf = math.max(0, entrySplit - SECTOR_INSET_RAD)
	local exitHalf = math.max(0, split - SECTOR_INSET_RAD)
	return {
		Angle = plan.Angle,
		Ahead = if flow > 0 then entryHalf else exitHalf,
		Behind = if flow > 0 then exitHalf else entryHalf,
	}
end

-- Smallest ring that can actually carry the approaches meeting here.
--
-- A roundabout is not free to be any size. Every leg needs its two arms plus a
-- deflection split between them, and a strip of kerb before the next leg
-- starts. Add those up and they must fit in 360 degrees:
--
--   sum(armWidth_i) / R  +  legs * (2*MIN_SPLIT + MIN_KERB_GAP)  <=  2*pi
--
-- Below that radius the mouths overrun each other and the result is not a
-- roundabout at all - it is a blob with slivers of island where the splitters
-- collapsed. Measured on the live report: four 2-lane legs on a radius-30 ring
-- demanded 479 degrees of a 360 degree ring, and looked exactly as bad as that
-- sounds. The tool used to build it anyway.
function RoundaboutBuilder.MinimumRadiusStuds(
	junctionId: string,
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): number
	local scale = settings.MetersToStuds
	local totalArmStuds = 0
	local widestArmStuds = 0
	local outerOffsetStuds = 0
	local legs = 0
	for _, road in JunctionInstance.ConnectedRoads(junctionId) do
		local data = RoadInstance.Read(road)
		if not data then
			continue
		end
		local atStart = data.StartJunctionId == junctionId
		if not atStart and data.EndJunctionId ~= junctionId then
			continue
		end
		legs += 1
		local profile = if atStart then data.ProfileStart else (data.ProfileEnd or data.ProfileStart)
		local inbound, outbound = splitApproachLanes(profile, if atStart then -1 else 1, style)
		if not inbound and not outbound then
			inbound, outbound = splitUndirected(profile, style.DefaultLaneWidthM, style)
		end
		local solo = (inbound == nil) ~= (outbound == nil)
		for _, group in { inbound, outbound } do
			local arm = armProfileFor(group :: LaneGroup, solo, style, scale)
			-- FULL width, pavement included. The kerb is what must not overrun
			-- the next mouth's kerb; counting only the roadway lets two mouths
			-- sit a pavement's width inside each other.
			local width = RoadProfile.TotalWidthM(arm.Profile) * scale
			totalArmStuds += width
			widestArmStuds = math.max(widestArmStuds, width)
			outerOffsetStuds = math.max(outerOffsetStuds, arm.OuterOffsetStuds)
		end
	end
	if legs == 0 then
		return 0
	end
	-- Angular fit. The denominator is what is left of the circle once every leg
	-- has taken its split and its kerb; if the legs alone have eaten the circle
	-- there is no radius that works, so fall back to a wide multiple of the
	-- approaches rather than dividing by zero or a negative.
	local perLeg = 2 * MIN_SPLIT_RAD + MIN_KERB_GAP_RAD
	local spare = 2 * math.pi - legs * perLeg
	local mergeRadius = if spare > 0.2 then totalArmStuds / spare else totalArmStuds
	-- The circulating carriageway should be at least as wide as the widest thing
	-- merging onto it; a ring narrower than its own entries reads as a blob.
	local ringWidthM = math.max(1, math.floor(laneCount)) * laneWidthM + style.SidewalkWidthM
	local ringHalfStuds = math.max(ringWidthM * scale, widestArmStuds) / 2
	-- Convert the merge radius back to the ring's CENTRELINE radius, which is
	-- what the caller passes: merge = centreline + ringHalf - pavement - armOuter.
	return mergeRadius + outerOffsetStuds + style.SidewalkWidthM * scale - ringHalfStuds
end

-- What to actually put in the Radius box. The minimum is a hard geometric
-- floor - at it, every mouth is touching its neighbour's kerb with nothing to
-- spare - so offering it as the default hands the user the tightest legal
-- roundabout and no room to breathe. Rounded up to a 5-stud step with a margin
-- so the suggestion looks like a decision rather than a solver output.
local SUGGESTED_RADIUS_HEADROOM = 1.15
local SUGGESTED_RADIUS_STEP_STUDS = 5

function RoundaboutBuilder.SuggestedRadiusStuds(
	junctionId: string,
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): number
	local minimum = RoundaboutBuilder.MinimumRadiusStuds(junctionId, laneCount, laneWidthM, style, settings)
	if minimum <= 0 then
		return 0
	end
	return math.ceil(minimum * SUGGESTED_RADIUS_HEADROOM / SUGGESTED_RADIUS_STEP_STUDS) * SUGGESTED_RADIUS_STEP_STUDS
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

	-- Grow rather than build garbage. A radius the approaches cannot fit into
	-- produces overrunning mouths and collapsed splitters, and there is no
	-- meaningful "best effort" version of that.
	radiusStuds =
		math.max(radiusStuds, RoundaboutBuilder.MinimumRadiusStuds(junctionId, laneCount, laneWidthM, style, settings))

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
	local ringOptions = {
		Curve = ringCurve,
		ProfileStart = profile,
		Style = style,
		Settings = flatSettings(settings),
		Preview = false,
	}
	local ring = RoadBuilder.Build(ringOptions)
	ring:SetAttribute("RW_Road", nil)
	ring.Name = "Roundabout"
	stampRingMeta(ring, center, radiusStuds, outerRadiusStuds, laneCount, laneWidthM)

	-- The ring's OWN outer pavement, captured before any arm parts are parented
	-- in. It is built as one unbroken circle, so without this it runs a
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

	buildIsland(ring, center, radiusStuds, profile, style, settings, ringCurve, RoadBuilder.StationsFor(ringOptions))

	local ringKerbRadius = outerRadiusStuds - style.SidewalkWidthM * scale

	-- Cut every approach back past the outer pavement so its entry/exit pair has
	-- the room to split apart and swing round onto the rim.
	local trimTarget = outerRadiusStuds + armRunStuds(outerRadiusStuds)

	-- Trim and PLAN every leg before building any of them: how far a mouth may
	-- split depends on where its neighbours actually landed, which isn't known
	-- until they have all been measured.
	local plans: { MouthPlan } = {}
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
		local spokeProfile = if atStart then trimmed.ProfileStart else (trimmed.ProfileEnd or trimmed.ProfileStart)
		local plan = planMouth(
			trimmed.Curve:PosAt(cutStation),
			edges.Inward,
			spokeProfile,
			atStart,
			center,
			ringKerbRadius,
			laneWidthM,
			style,
			settings
		)
		if plan then
			table.insert(plans, plan)
		end
	end

	local mouthSectors: { MouthSector } = {}
	for i, plan in plans do
		table.insert(mouthSectors, buildMouth(ring, plan, center, splitBudgetFor(plans, i), style, settings))
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
	local edgeLineInset = style.MarkingWidthM * 1.5 * scale
	openRingPavement(ringPavement, center, mouthSectors, ringKerbRadius - edgeLineInset - 0.5)

	ring.Parent = getRoundaboutsFolder()
	JunctionInstance.Delete(junctionModel)
	return ring
end

-- Debug dump: every number the roundabout would be built from, without
-- building it.
--
-- `tools/preview` is a Python re-implementation of this file, so "the preview
-- says it is fine" only ever meant "the preview agrees with itself".
-- check_parity.py compares the two sides' CONSTANTS; this compares their
-- BEHAVIOUR. It deliberately reuses planMouth, splitBudgetFor and
-- resolveSplits - the same functions CreateAtJunction calls - so it cannot
-- quietly become a third implementation.
--
-- Non-destructive: the trim station is found on the road's existing curve
-- instead of trimming it, so this is safe to run on a live junction.
function RoundaboutBuilder.DescribeJunction(
	junctionId: string,
	radiusStuds: number,
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): string
	local junctionModel = JunctionInstance.FindById(junctionId)
	local junctionData = if junctionModel then JunctionInstance.Read(junctionModel) else nil
	if not junctionData then
		return "roundabout dump: junction not found"
	end
	local center = junctionData.Position
	local scale = settings.MetersToStuds
	local minimum = RoundaboutBuilder.MinimumRadiusStuds(junctionId, laneCount, laneWidthM, style, settings)
	local grown = math.max(radiusStuds, minimum)

	local components = ringComponents(laneCount, laneWidthM, style)
	local profile: RoadProfile.RoadProfile = {
		Id = "roundabout_ring",
		Name = "Roundabout",
		Category = "Custom",
		BuiltIn = false,
		Components = components,
	}
	local outerRadiusStuds = grown + RoadProfile.TotalWidthM(profile) / 2 * scale
	local ringKerbRadius = outerRadiusStuds - style.SidewalkWidthM * scale
	local trimTarget = outerRadiusStuds + armRunStuds(outerRadiusStuds)
	local flow = if style.DriveOnLeft then 1 else -1

	local lines = {
		string.format("=== roundabout dump: junction %s ===", junctionId),
		string.format(
			"scale=%.4f driveOnLeft=%s deflect=%s",
			scale,
			tostring(style.DriveOnLeft),
			tostring(settings.RoundaboutEntryCurve)
		),
		string.format(
			"radius requested=%.3f minimum=%.3f used=%.3f outer=%.3f kerb=%.3f flow=%d",
			radiusStuds,
			minimum,
			grown,
			outerRadiusStuds,
			ringKerbRadius,
			flow
		),
	}

	local plans: { MouthPlan } = {}
	for _, road in JunctionInstance.ConnectedRoads(junctionId) do
		local data = RoadInstance.Read(road)
		if not data or #data.Curve.Segments ~= 1 then
			continue
		end
		local atStart = data.StartJunctionId == junctionId
		if not atStart and data.EndJunctionId ~= junctionId then
			continue
		end
		local spokeProfile = if atStart then data.ProfileStart else (data.ProfileEnd or data.ProfileStart)
		local fromStation = if atStart then 0 else data.Curve.Length
		local towardStation = if atStart then data.Curve.Length else 0
		local crossing =
			findProfileRingCrossing(data.Curve, spokeProfile, fromStation, towardStation, center, trimTarget, scale)
		if not crossing then
			table.insert(lines, string.format("leg %s: no pad crossing - would be skipped", road.Name))
			continue
		end
		local tangent = data.Curve:TangentAt(crossing)
		local inward = if atStart then tangent else -tangent
		local plan = planMouth(
			data.Curve:PosAt(crossing),
			inward,
			spokeProfile,
			atStart,
			center,
			ringKerbRadius,
			laneWidthM,
			style,
			settings
		)
		if plan then
			table.insert(plans, plan)
		else
			table.insert(lines, string.format("leg %s: planMouth returned nil", road.Name))
		end
	end

	table.insert(lines, string.format("legs planned=%d", #plans))
	for index, plan in plans do
		local budget = splitBudgetFor(plans, index)
		local split, entrySplit, entryAngle, exitAngle = resolveSplits(plan, budget, flow, settings)
		table.insert(
			lines,
			string.format(
				"leg %d mouthAngle=%.4f budget=%.4f split=%.4f entrySplit=%.4f entryAngle=%.4f exitAngle=%.4f",
				index,
				math.deg(plan.Angle),
				math.deg(budget),
				math.deg(split),
				math.deg(entrySplit),
				math.deg(entryAngle),
				math.deg(exitAngle)
			)
		)
		local function describeArm(label: string, arm: MouthArm?)
			if not arm then
				table.insert(lines, string.format("     %s: none", label))
				return
			end
			table.insert(
				lines,
				string.format(
					"     %s: merge=%.4f lateral=%.4f outer=%.4f inner=%.4f width=%.4f",
					label,
					arm.MergeRadius,
					arm.LateralStuds,
					arm.Profile.OuterOffsetStuds,
					arm.Profile.InnerOffsetStuds,
					RoadProfile.TotalWidthM(arm.Profile.Profile) * scale
				)
			)
		end
		describeArm("entry", plan.Entry)
		describeArm("exit", plan.Exit)
	end
	return table.concat(lines, "\n")
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
		if d <= outerR + snapRadiusStuds + armRunStuds(outerR) then
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
		outerR + armRunStuds(outerR) + settings.SnapRadiusStuds + 8,
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
		outerR + armRunStuds(outerR) + settings.SnapRadiusStuds + 8,
		math.max(1, radiusStuds * 0.25)
	)
	if #nearby == 0 then
		return ring
	end
	return RoundaboutBuilder.ConnectRoad(ring, nearby[1], style, settings) or ring
end

return RoundaboutBuilder
