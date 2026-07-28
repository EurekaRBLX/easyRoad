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
	-- Pavement width copied from the approach's own, not the region default, so
	-- the kerb line and the pavement's outer edge both run on unbroken from the
	-- road into the arm instead of stepping at the cut.
	local pavementM = style.SidewalkWidthM
	for _, component in spokeProfile.Components do
		if component.Kind == "Sidewalk" then
			pavementM = math.max(pavementM, component.WidthM)
		end
	end
	local sidewalk: RoadProfile.ProfileComponent = { Kind = "Sidewalk", WidthM = pavementM, Direction = 0 }
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

local DOWN = Vector3.new(0, -1, 0)

-- The angular slice of the ring one mouth occupies. ASYMMETRIC: a mouth's two
-- arms merge at different distances from its centreline (the entry closer, when
-- deflection is on), so a single half-angle either under-opens one side or
-- over-opens the other. `Ahead` extends in the +angle direction, `Behind` in -.
export type MouthSector = { Angle: number, Ahead: number, Behind: number }

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
}

-- One-way half of an approach: half its running lanes, plus a single pavement on
-- the arm's OUTER side. A pavement on both sides would lay a raised strip down
-- the middle of the mouth, since the gore side is where the splitter island goes.
local function armProfileFor(
	spokeProfile: RoadProfile.RoadProfile,
	fallbackLaneWidthM: number,
	style: RegionStyles.RegionStyle,
	scale: number
): ArmProfile
	local widths: { number } = {}
	for _, component in spokeProfile.Components do
		if component.Kind == "Drive" then
			table.insert(widths, component.WidthM)
		end
	end
	if #widths == 0 then
		widths = { fallbackLaneWidthM }
	end
	local lanes = math.max(1, math.floor(#widths / 2))
	local components: { RoadProfile.ProfileComponent } = {}
	for i = 1, lanes do
		table.insert(components, { Kind = "Drive", WidthM = widths[i] or widths[#widths], Direction = 1 })
	end
	local sidewalk: RoadProfile.ProfileComponent = { Kind = "Sidewalk", WidthM = style.SidewalkWidthM, Direction = 0 }
	-- Same placement rule as ringComponents, and it lands on the same world side:
	-- an arm merges tangentially, so at the merge its right of travel is the ring's
	-- right of travel, and the outward side is the same one either way.
	if style.DriveOnLeft then
		table.insert(components, 1, sidewalk)
	else
		table.insert(components, sidewalk)
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
	arm: ArmProfile,
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
	local function goreEdge(curve: PolyCurve.PolyCurve, station: number): Vector3
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
	local function kerbCrossing(curve: PolyCurve.PolyCurve, station: number, direction: number): number
		local step = curve.Length / 128
		local s = station
		for _ = 1, 160 do
			local nextS = s + direction * step
			if nextS < 0 or nextS > curve.Length then
				return math.clamp(nextS, 0, curve.Length)
			end
			if distanceXZ(goreEdge(curve, nextS), center) <= ringKerbRadiusStuds then
				local lo, hi = s, nextS
				for _ = 1, 24 do
					local mid = (lo + hi) / 2
					if distanceXZ(goreEdge(curve, mid), center) > ringKerbRadiusStuds then
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
	local entrySide: { Vector3 } = {}
	local exitSide: { Vector3 } = {}
	local lastAlong = 0
	for i = 0, GORE_SAMPLES do
		local along = (i / GORE_SAMPLES) * reach
		local a = goreEdge(entryCurve, along)
		local b = goreEdge(exitCurve, exitCurve.Length - along)
		-- Stop once either edge has dropped inside the kerb. Past that the island
		-- would be laid over the circulating carriageway, not beside it - an
		-- earlier attempt projected these points radially out onto the kerb
		-- instead of stopping, which paved the mouth shut.
		if i > 0 and (distanceXZ(a, center) <= ringKerbRadiusStuds or distanceXZ(b, center) <= ringKerbRadiusStuds) then
			break
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
	local noseEnd = goreEdge(entryCurve, kerbCrossing(entryCurve, lastAlong, 1))
	local tailEnd = goreEdge(exitCurve, kerbCrossing(exitCurve, exitCurve.Length - lastAlong, -1))
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
type MouthPlan = {
	CutMid: Vector3,
	Direction: Vector3,
	Arm: ArmProfile,
	MergeRadius: number,
	-- Ring angle the approach aims at.
	Angle: number,
	-- Where each arm's centreline sits at the cut, measured from the approach's
	-- centreline along its right-of-travel. Derived from the APPROACH's own
	-- roadway edges so the pair tiles the road exactly.
	EntryLateralStuds: number,
	ExitLateralStuds: number,
}

local function planMouth(
	cutMid: Vector3,
	inward: Vector3,
	spokeProfile: RoadProfile.RoadProfile,
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
	local arm = armProfileFor(spokeProfile, laneWidthM, style, settings.MetersToStuds)
	-- Centreline radius that puts the arm's OUTER roadway edge exactly on the
	-- ring's kerb - so its pavement band lands on the ring's pavement band and
	-- the kerb line runs on unbroken from the approach round onto the ring.
	local mergeRadius = ringKerbRadiusStuds - arm.OuterOffsetStuds
	if mergeRadius <= 1 then
		return nil
	end
	-- Mouth angle: where the approach's OWN centreline, continued, first meets
	-- the merge circle. Taking the cut point's radial instead swings the whole
	-- mouth off the road line for any approach that doesn't aim at the centre.
	local aim = rayCircleFirstHit(cutMid, dir, center, mergeRadius) or cutMid
	local aimDir = flatUnit(aim - center)
	if aimDir.Magnitude < 1e-6 then
		return nil
	end
	-- Align each arm to the approach's own roadway edge rather than giving the
	-- pair its own half-width plus a splitter. Sized the latter way the pair
	-- comes out wider than the road it replaces, and every mouth steps outward
	-- at the cut - asphalt, kerb and pavement all breaking at once. Aligned, the
	-- two arms tile the approach exactly and whatever is left over in the middle
	-- becomes the splitter, which is where that width belongs anyway.
	local flow = if style.DriveOnLeft then 1 else -1
	local spokeLeftM, spokeRightM = roadwayEdgeOffsetsM(spokeProfile)
	local entryEdgeM = if flow > 0 then -spokeLeftM else spokeRightM
	local exitEdgeM = if flow > 0 then spokeRightM else -spokeLeftM
	-- Floored at the inner offset: that puts an arm's inner edge on the
	-- approach's centreline, so a road too narrow to split gives two arms that
	-- abut rather than two that overlap.
	local function lateralFor(edgeM: number): number
		return math.max(arm.InnerOffsetStuds, edgeM * settings.MetersToStuds - arm.OuterOffsetStuds)
	end
	return {
		CutMid = cutMid,
		Direction = dir,
		Arm = arm,
		MergeRadius = mergeRadius,
		Angle = math.atan2(aimDir.Z, aimDir.X),
		EntryLateralStuds = lateralFor(entryEdgeM),
		ExitLateralStuds = lateralFor(exitEdgeM),
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
	local arm = plan.Arm
	local dir = plan.Direction
	local mergeRadius = plan.MergeRadius

	-- The split comes out of the room the neighbouring legs leave, keeping the
	-- kerb margin clear on both sides.
	local split =
		math.clamp(SPLIT_ANGLE_RAD, MIN_SPLIT_RAD, math.max(MIN_SPLIT_RAD, splitBudgetRad - SECTOR_MARGIN_RAD))
	local deflect = settings.RoundaboutEntryCurve
	local entrySplit = if deflect then math.max(MIN_SPLIT_RAD, split * ENTRY_SPLIT_SCALE) else split

	-- Going round the ring you meet a mouth's EXIT first (upstream, against the
	-- flow) and its ENTRY after (downstream, with it).
	local entryAngle = plan.Angle + flow * entrySplit
	local exitAngle = plan.Angle - flow * split

	-- At the cut each arm sits where the approach's own roadway edge puts it, so
	-- the pair tiles the road; the leftover in the middle is the splitter's nose.
	local side = rightOf(dir)
	local entryLateral = side * (plan.EntryLateralStuds * flow)
	local exitLateral = side * (plan.ExitLateralStuds * flow)
	local entryCurve = PolyCurve.new({
		armSegment(
			plan.CutMid - entryLateral,
			dir,
			ringPointAt(center, entryAngle, mergeRadius, plan.CutMid.Y),
			ringTangentAt(entryAngle, flow),
			ARM_HANDLE
		),
	})
	local exitCurve = PolyCurve.new({
		armSegment(
			ringPointAt(center, exitAngle, mergeRadius, plan.CutMid.Y),
			ringTangentAt(exitAngle, flow),
			plan.CutMid + exitLateral,
			-dir,
			ARM_HANDLE
		),
	})

	buildArm(entryCurve, arm, style, settings).Parent = ring
	buildArm(exitCurve, arm, style, settings).Parent = ring
	-- The kerb radius the arms were aimed at, back out of the merge radius.
	local ringKerbRadius = mergeRadius + arm.OuterOffsetStuds
	buildSplitterIsland(ring, entryCurve, exitCurve, arm, center, ringKerbRadius, flow, style, settings)

	-- Open exactly as far as each arm actually reaches, inset so the opening can
	-- never outrun them. `flow` says which of the two lands on the +angle side.
	local aheadSplit = if flow > 0 then entrySplit else split
	local behindSplit = if flow > 0 then split else entrySplit
	return {
		Angle = plan.Angle,
		Ahead = math.max(0, aheadSplit - SECTOR_INSET_RAD),
		Behind = math.max(0, behindSplit - SECTOR_INSET_RAD),
	}
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

	buildIsland(ring, center, radiusStuds, profile, style, settings)

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
