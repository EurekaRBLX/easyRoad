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
local Markings = require("./Markings")
local RoadInstance = require("../RoadInstance")
local RoadSource = require("../RoadSource")
local RoundaboutInstance = require("../RoundaboutInstance")
local RoadProfile = require("../RoadProfile")
local RoadSplit = require("../RoadSplit")
local JunctionInstance = require("../JunctionInstance")
local BusStops = require("../BusStops")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")
local StructureBuilder = require("../StructureBuilder")
local JunctionBuilder = require("./JunctionBuilder")

local RoundaboutBuilder = {}

local ROUNDABOUTS_FOLDER_NAME = "Roundabouts"
local BEZIER_CIRCLE_K = 0.5522847498307936
local ROUNDABOUT_DASH_LENGTH_M = 3
local ROUNDABOUT_DASH_GAP_M = 3
local ROUNDABOUT_MARKING_COLOR = Color3.fromRGB(245, 245, 245)

-- Python's preview is a painter: the ordinary ring is drawn over the sunk arms
-- and Turbo is drawn over the ordinary ring markings. Studio has no equivalent
-- draw order for opaque Parts, so equal or nearly equal top faces flicker and
-- the sunk arm markings can poke up to 0.009 studs through the ring. Keep the
-- same visible geometry, but make those two ownership boundaries explicit. The
-- apron is also painted last in Python, but its interior does not intersect the
-- arm/Turbo lines; lifting that asphalt would introduce a visible lip instead
-- of fixing a real overlap. All affected marking Parts are non-collidable.
local MARKING_LAYER_GAP_STUDS = 0.005
local ROADBUILDER_MARKING_ALT_STUDS = 0.004
-- A different top plane is sufficient: the Parts may interpenetrate because
-- they are visual-only, but their visible faces must not be coplanar. Keeping
-- the offset small avoids a visibly floating Turbo stripe in an oblique view.
local TURBO_MARKING_LIFT_STUDS = RoadBuilder.MarkingLiftStuds + ROADBUILDER_MARKING_ALT_STUDS + MARKING_LAYER_GAP_STUDS

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
	-- CONTINUOUS leaves the lane boundary on "Auto", which resolves to the
	-- region's own dashed lane line. SOLIDLANES marks it solid, to discourage
	-- weaving on the ring.
	--
	-- TURBO starts with the same concentric divider, then replaces only the arc
	-- owned by each exit peel. Keeping the ordinary line under that arc mixes
	-- two dash phases and is the source of the doubled/excess markings reported
	-- in Studio; suppressing the divider around the whole ring is equally wrong.
	--
	-- Set on every lane but the last: `RightBoundary` describes the gap to the
	-- component on its right, and the last lane's right-hand neighbour is the
	-- pavement, whose edge line is the region's business rather than ours.
	local lanes = math.max(1, math.floor(laneCount))
	local between: RoadProfile.BoundaryRule? = if style.RoundaboutMarkings == "SolidLanes" then "Solid" else nil
	for i = 1, lanes do
		table.insert(components, {
			Kind = "Drive",
			WidthM = laneWidthM,
			Direction = 1,
			RightBoundary = if i < lanes then between else nil,
		})
	end
	-- An opted-out pavement means the ring is carriageway only. Bail before the
	-- placement below rather than inserting a zero-width component: a zero-width
	-- Sidewalk would still be emitted as a Part and still be swept up by
	-- openRingPavement's name match.
	if style.RoundaboutSidewalk == false then
		return components
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

-- The Python roundabout preview is the accepted appearance contract. It uses a
-- deliberately small rule set: solid white lines just inside both roadway
-- edges, dashed white dividers between Drive lanes, and a solid white separator
-- wherever a Drive lane meets another roadway kind such as Shoulder. Build
-- those lines explicitly for roundabout-owned profiles instead of allowing
-- straight-road regional defaults to choose a different visual grammar.
local function roundaboutMarkingLines(
	profile: RoadProfile.RoadProfile,
	style: RegionStyles.RegionStyle,
	solidLaneLines: boolean
): { Markings.MarkingLine }
	local components = profile.Components
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	local roadwayIndices: { number } = {}
	for i, component in components do
		if RoadProfile.IsRoadway(component.Kind) then
			table.insert(roadwayIndices, i)
		end
	end

	local lines: { Markings.MarkingLine } = {}
	local function addLine(offsetM: number, lineType: RegionStyles.LineType)
		table.insert(lines, {
			OffsetStartM = offsetM,
			OffsetEndM = offsetM,
			Line = lineType,
			Color = ROUNDABOUT_MARKING_COLOR,
			DashLengthM = ROUNDABOUT_DASH_LENGTH_M,
			DashGapM = ROUNDABOUT_DASH_GAP_M,
		})
	end

	if #roadwayIndices > 0 then
		local firstIndex = roadwayIndices[1]
		local lastIndex = roadwayIndices[#roadwayIndices]
		local first = components[firstIndex]
		local last = components[lastIndex]
		local leftCoveredByShoulder = first.Kind == "Shoulder"
			and first.WidthM <= 1e-6
			and firstIndex < #components
			and components[firstIndex + 1].Kind == "Drive"
		local rightCoveredByShoulder = last.Kind == "Shoulder"
			and last.WidthM <= 1e-6
			and lastIndex > 1
			and components[lastIndex - 1].Kind == "Drive"
		local inset = style.MarkingWidthM * 1.5
		if not leftCoveredByShoulder then
			addLine(offsets[firstIndex].Left + inset, "Solid")
		end
		if not rightCoveredByShoulder then
			addLine(offsets[lastIndex].Right - inset, "Solid")
		end
	end

	for i = 1, #components - 1 do
		local a = components[i]
		local b = components[i + 1]
		if RoadProfile.IsRoadway(a.Kind) and RoadProfile.IsRoadway(b.Kind) then
			if a.Kind == "Drive" and b.Kind == "Drive" then
				addLine(offsets[i].Right, if solidLaneLines then "Solid" else "Dashed")
			elseif (a.Kind == "Drive") ~= (b.Kind == "Drive") then
				addLine(offsets[i].Right, "Solid")
			end
		end
	end

	return lines
end

-- Lateral offset of the arm line that physically hands onto the ring's outer
-- edge line. Ordinary carriageways use the familiar inset edge line. Highway
-- arms instead retain a zero-width Shoulder marker after their real shoulder
-- surface is tapered away; in that case roundaboutMarkingLines emits the
-- Drive/Shoulder separator exactly on the roadway edge. Returning the inset
-- offset for that profile would fail to match any generated line, so the real
-- highway edge would still be clipped early.
local function outboardArmMarkingOffsetsM(
	profile: RoadProfile.RoadProfile,
	style: RegionStyles.RegionStyle
): (number?, number?)
	local components = profile.Components
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	local roadwayIndices: { number } = {}
	for i, component in components do
		if RoadProfile.IsRoadway(component.Kind) then
			table.insert(roadwayIndices, i)
		end
	end
	if #roadwayIndices == 0 then
		return nil, nil
	end
	local inset = style.MarkingWidthM * 1.5
	if style.DriveOnLeft then
		local firstIndex = roadwayIndices[1]
		local first = components[firstIndex]
		local ringOffset = offsets[firstIndex].Left + inset
		if
			first.Kind == "Shoulder"
			and first.WidthM <= 1e-6
			and firstIndex < #components
			and components[firstIndex + 1].Kind == "Drive"
		then
			return offsets[firstIndex].Right, ringOffset
		end
		return ringOffset, ringOffset
	end
	local lastIndex = roadwayIndices[#roadwayIndices]
	local last = components[lastIndex]
	local ringOffset = offsets[lastIndex].Right - inset
	if
		last.Kind == "Shoulder"
		and last.WidthM <= 1e-6
		and lastIndex > 1
		and components[lastIndex - 1].Kind == "Drive"
	then
		return offsets[lastIndex].Left, ringOffset
	end
	return ringOffset, ringOffset
end

-- The ring's own outer pavement width. Zero when the pavement is opted out,
-- which matters because several radii are derived by subtracting it from the
-- outer edge: with no pavement the ring's kerb IS its outer edge, and using the
-- region's nominal width there would put the kerb inside the carriageway.
local function ringSidewalkWidthM(style: RegionStyles.RegionStyle): number
	return if style.RoundaboutSidewalk == false then 0 else style.SidewalkWidthM
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
	if style.RoundaboutIsland == false then
		-- Centre left open on purpose. The ring is a closed annulus either way,
		-- so this leaves ground rather than a hole in the carriageway - it is
		-- for a landscaped or decorated centre the user fills themselves.
		return
	end
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
	laneWidthM: number,
	junctionId: string?
)
	model:SetAttribute("RW_Roundabout", true)
	model:SetAttribute("RW_Center", center)
	model:SetAttribute("RW_RingRadius", radiusStuds)
	model:SetAttribute("RW_OuterRadius", outerRadiusStuds)
	model:SetAttribute("RW_LaneCount", laneCount)
	model:SetAttribute("RW_LaneWidthM", laneWidthM)
	model:SetAttribute("RW_JunctionId", junctionId)
	model:SetAttribute("RW_LegacyConnected", false)
end

local function stampRingOverrides(model: Model, markings: string?, sidewalk: boolean?, island: boolean?)
	model:SetAttribute("RW_RoundaboutMarkings", markings)
	model:SetAttribute("RW_RoundaboutSidewalk", sidewalk)
	model:SetAttribute("RW_RoundaboutIsland", island)
end

local function styleWithRoundaboutOverrides(
	style: RegionStyles.RegionStyle,
	markings: string?,
	sidewalk: boolean?,
	island: boolean?
): RegionStyles.RegionStyle
	if markings == nil and sidewalk == nil and island == nil then
		return style
	end
	local result = table.clone(style)
	if markings ~= nil then
		result.RoundaboutMarkings = markings :: RegionStyles.RoundaboutMarkingStyle
	end
	if sidewalk ~= nil then
		result.RoundaboutSidewalk = sidewalk
	end
	if island ~= nil then
		result.RoundaboutIsland = island
	end
	return result
end

local GENERATED_GEOMETRY_NAME = "GeneratedGeometry"

local LEGACY_GENERATED_NAMES: { [string]: boolean } = {
	Drive = true,
	Sidewalk = true,
	Median = true,
	Shoulder = true,
	Bike = true,
	Parking = true,
	Bay = true,
	Marking = true,
	Island = true,
	RoundaboutArm = true,
}

local function packGeneratedGeometry(model: Model, assumeAllGenerated: boolean?): Folder
	for _, child in model:GetChildren() do
		if
			child:IsA("Folder")
			and child.Name == GENERATED_GEOMETRY_NAME
			and child:GetAttribute("RW_RoundaboutGenerated") == true
		then
			return child :: Folder
		end
	end
	local folder = Instance.new("Folder")
	folder.Name = GENERATED_GEOMETRY_NAME
	folder:SetAttribute("RW_RoundaboutGenerated", true)
	for _, child in model:GetChildren() do
		if
			assumeAllGenerated
			or child:GetAttribute("RW_RoundaboutGeneratedChild") == true
			or LEGACY_GENERATED_NAMES[child.Name] == true
		then
			child:SetAttribute("RW_RoundaboutGeneratedChild", true)
			child.Parent = folder
		end
	end
	folder.Parent = model
	return folder
end

-- Replace only generated state.  The Model itself is the Studio selection
-- target, so destroying it during an editor Apply would close the inspector
-- and break undo/redo selection continuity. User/plugin children placed beside
-- GeneratedGeometry, custom naming, and non-EasyRoad attributes survive.
local function replaceRoundaboutInPlace(target: Model, built: Model): Model
	local targetName = target.Name
	local oldGeometry = packGeneratedGeometry(target, false)
	oldGeometry:Destroy()
	local newGeometry = packGeneratedGeometry(built, true)
	for name in target:GetAttributes() do
		if string.sub(name, 1, 3) == "RW_" then
			target:SetAttribute(name, nil)
		end
	end
	for name, value in built:GetAttributes() do
		target:SetAttribute(name, value)
	end
	newGeometry.Parent = target
	target.Name = targetName
	built:Destroy()
	return target
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
		MarkingLines = roundaboutMarkingLines(profile, style, style.RoundaboutMarkings == "SolidLanes"),
		MarkingDashStartsAtZero = true,
	}
	local model = RoadBuilder.Build(ringOptions)
	model:SetAttribute("RW_Road", nil)
	model.Name = "Roundabout"
	local halfW = RoadProfile.TotalWidthM(profile) / 2 * settings.MetersToStuds
	stampRingMeta(model, center, radiusStuds, radiusStuds + halfW, laneCount, laneWidthM, nil)
	buildIsland(model, center, radiusStuds, profile, style, settings, curve, RoadBuilder.StationsFor(ringOptions))
	packGeneratedGeometry(model, true)
	model.Parent = getRoundaboutsFolder()
	return model
end

local function distanceXZ(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Python draws the ring deck after the sunk arm Parts, so any arm marking that
-- reaches inside the ring kerb simply disappears beneath it. In Studio the
-- marking's 0.03-stud lift plus half its thickness is just larger than the
-- 0.05-stud arm sink, leaving the fragments reported at every mouth. Give each
-- line its own exact longitudinal bound at the circle crossing of that line's
-- lateral offset. The half-width-expanded radius keeps the marking rectangle,
-- not only its centreline, outside the ring-owned deck.
local ARM_MARKING_CLIP_SAMPLES = 96
local function clipArmMarkingLinesAtRing(
	lines: { Markings.MarkingLine },
	curve: PolyCurve.PolyCurve,
	center: Vector3,
	ringKerbRadiusStuds: number,
	cutAtStart: boolean,
	markingWidthStuds: number,
	scale: number,
	preserveRingOffsetM: number?
)
	local length = curve.Length
	if length <= 1e-6 then
		return
	end
	local clipRadius = ringKerbRadiusStuds + markingWidthStuds / 2 + MARKING_LAYER_GAP_STUDS
	local outsideStation = if cutAtStart then 0 else length
	local ringStation = if cutAtStart then length else 0

	for _, line in lines do
		-- The outboard edge line has an exact tangent hand-off to the ring at
		-- the arm endpoint. Radially clipping it early creates the visible gap
		-- reported at every mouth; only internal/inboard lines need the ring-deck
		-- ownership clip.
		local ringOffsetM = if cutAtStart then line.OffsetEndM else line.OffsetStartM
		if preserveRingOffsetM and math.abs(ringOffsetM - preserveRingOffsetM) < 1e-6 then
			continue
		end
		local function radiusAt(station: number): number
			local alpha = station / length
			local offsetM = line.OffsetStartM + (line.OffsetEndM - line.OffsetStartM) * alpha
			local point = (curve:FrameAt(station) * CFrame.new(offsetM * scale, 0, 0)).Position
			return distanceXZ(point, center)
		end

		-- A future unusual arm may never enter the ring at this offset. In that
		-- case Python has nothing to cover and the full line is correct.
		if radiusAt(outsideStation) <= clipRadius or radiusAt(ringStation) > clipRadius then
			continue
		end

		local previous = outsideStation
		local crossing: number? = nil
		for i = 1, ARM_MARKING_CLIP_SAMPLES do
			local station = outsideStation + (ringStation - outsideStation) * (i / ARM_MARKING_CLIP_SAMPLES)
			if radiusAt(station) <= clipRadius then
				local outsideS = previous
				local insideS = station
				for _ = 1, 24 do
					local mid = (outsideS + insideS) / 2
					if radiusAt(mid) > clipRadius then
						outsideS = mid
					else
						insideS = mid
					end
				end
				crossing = (outsideS + insideS) / 2
				break
			end
			previous = station
		end

		if crossing then
			if cutAtStart then
				line.ToStationStuds = crossing
			else
				line.FromStationStuds = crossing
			end
		end
	end
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

-- The station along `road` whose position is closest to `center`, found by a
-- coarse scan then a bisection refine. Used to decide whether a road ENDS at
-- the roundabout or merely PASSES it, and where to cut it if the latter.
local function nearestStation(curve: PolyCurve.PolyCurve, center: Vector3): number
	local length = curve.Length
	if length < 1e-3 then
		return 0
	end
	local samples = math.clamp(math.ceil(length / 4), 8, 256)
	local best, bestDist = 0, math.huge
	for i = 0, samples do
		local station = length * i / samples
		local d = distanceXZ(curve:PosAt(station), center)
		if d < bestDist then
			best, bestDist = station, d
		end
	end
	local step = length / samples
	local lo = math.max(0, best - step)
	local hi = math.min(length, best + step)
	for _ = 1, 24 do
		local a = lo + (hi - lo) / 3
		local b = hi - (hi - lo) / 3
		if distanceXZ(curve:PosAt(a), center) < distanceXZ(curve:PosAt(b), center) then
			hi = b
		else
			lo = a
		end
	end
	return (lo + hi) / 2
end

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

local function nearestSourceStation(curve: PolyCurve.PolyCurve, point: Vector3): number
	local length = curve.Length
	if length <= 1e-6 then
		return 0
	end
	local samples = math.clamp(math.ceil(length / 4), 16, 256)
	local bestStation = 0
	local bestDistance = math.huge
	for i = 0, samples do
		local station = length * i / samples
		local distance = (curve:PosAt(station) - point).Magnitude
		if distance < bestDistance then
			bestDistance = distance
			bestStation = station
		end
	end
	local step = length / samples
	local low = math.max(0, bestStation - step)
	local high = math.min(length, bestStation + step)
	for _ = 1, 28 do
		local a = low + (high - low) / 3
		local b = high - (high - low) / 3
		if (curve:PosAt(a) - point).Magnitude < (curve:PosAt(b) - point).Magnitude then
			high = b
		else
			low = a
		end
	end
	local station = (low + high) / 2
	-- Exact source endpoints are common and must remain exact.  Without this
	-- snap, repeated source->subcurve->source nearest-point searches can shave a
	-- few floating-point microns from the untouched far end on every edit.
	if station < 1e-3 then
		return 0
	elseif length - station < 1e-3 then
		return length
	end
	return station
end

local function markingStretchesForSourceWindow(
	stretches: { Markings.MarkingStretch },
	featureOffset: number,
	windowStart: number,
	windowEnd: number
): { Markings.MarkingStretch }?
	local result: { Markings.MarkingStretch } = {}
	for _, stretch in stretches do
		local from = math.max(featureOffset + stretch.FromStationStuds, windowStart)
		local to = math.min(featureOffset + stretch.ToStationStuds, windowEnd)
		if to > from then
			table.insert(result, {
				ComponentIndices = stretch.ComponentIndices,
				FromStationStuds = from - windowStart,
				ToStationStuds = to - windowStart,
				Line = stretch.Line,
				DashLengthM = stretch.DashLengthM,
				DashGapM = stretch.DashGapM,
			})
		end
	end
	return if #result > 0 then result else nil
end

local function kerbStretchesForSourceWindow(
	stretches: { Markings.KerbStretch },
	featureOffset: number,
	windowStart: number,
	windowEnd: number
): { Markings.KerbStretch }?
	local result: { Markings.KerbStretch } = {}
	for _, stretch in stretches do
		local from = math.max(featureOffset + stretch.FromStationStuds, windowStart)
		local to = math.min(featureOffset + stretch.ToStationStuds, windowEnd)
		if to > from then
			table.insert(result, {
				EdgeIndex = stretch.EdgeIndex,
				FromStationStuds = from - windowStart,
				ToStationStuds = to - windowStart,
				Restriction = stretch.Restriction,
			})
		end
	end
	return if #result > 0 then result else nil
end

-- Rebuild one rendered road from a window of its immutable source segment.
-- Feature attributes remain byte-for-byte on the owner Model; local copies are
-- remapped only for rendering.  The companion offset records which source
-- station their existing numbers are relative to, so repeated radius edits do
-- not move a bay/stretch or progressively shorten the road.
local function rebuildRoadFromSource(
	road: Model,
	data: RoadInstance.RoadData,
	source: CurveSegment.Segment,
	windowStart: number,
	windowEnd: number,
	currentSourceStart: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings,
	exactRaisedCapAtStart: boolean?
): RoadInstance.RoadData?
	if windowEnd - windowStart < 1e-3 then
		return nil
	end
	local segment = CurveSegment.Sub(source, windowStart, windowEnd)
	local curve = PolyCurve.new({ segment })
	local storedFeatureOffset = road:GetAttribute("RW_FeatureSourceOffsetStuds")
	local featureOffset = if typeof(storedFeatureOffset) == "number" then storedFeatureOffset else currentSourceStart
	local markingStretches =
		markingStretchesForSourceWindow(data.MarkingStretches, featureOffset, windowStart, windowEnd)
	local kerbStretches = kerbStretchesForSourceWindow(data.KerbStretches, featureOffset, windowStart, windowEnd)
	local options = {
		Curve = curve,
		ProfileStart = data.ProfileStart,
		ProfileEnd = data.ProfileEnd,
		Style = style,
		Settings = settings,
		Preview = false,
		MarkingStretches = markingStretches,
		KerbStretches = kerbStretches,
		-- A live roundabout arm owns the surface immediately past the linked
		-- source-road end. End raised components exactly at that trim plane so
		-- their usual longitudinal overlap cannot protrude into the arm. Nil is
		-- intentional for restoration and unrelated source-window rebuilds.
		ExactStartRaisedCap = if exactRaisedCapAtStart == true then true else nil,
		ExactEndRaisedCap = if exactRaisedCapAtStart == false then true else nil,
	}
	local visualBay = if data.Bay then table.clone(data.Bay) else nil
	if visualBay then
		visualBay.StationStuds = featureOffset + visualBay.StationStuds - windowStart
	end
	local rebuilt = if visualBay then RoadBuilder.BuildWithBay(options, visualBay) else RoadBuilder.Build(options)

	road:ClearAllChildren()
	for name, value in rebuilt:GetAttributes() do
		-- RoadBuilder creates fresh identities.  The existing owner and its two
		-- approach ports are stable topology keys and must never be replaced.
		-- Localized feature attrs belong only to the renderer; retaining the owner
		-- values and their source offset prevents cumulative shifts and clipping.
		if
			name ~= "RW_RoadId"
			and name ~= "RW_StartPortId"
			and name ~= "RW_EndPortId"
			and name ~= "RW_BayJson"
			and name ~= "RW_MarkingStretchesJson"
			and name ~= "RW_KerbStretchesJson"
		then
			road:SetAttribute(name, value)
		end
	end
	for _, child in rebuilt:GetChildren() do
		child.Parent = road
	end
	rebuilt:Destroy()

	RoadInstance.StampModel(road, curve, data.ProfileStart, data.ProfileEnd)
	RoadInstance.StampJunctions(road, data.StartJunctionId, data.EndJunctionId)
	RoadSource.WriteSegment(road, source)
	local hasStoredFeatures = data.Bay ~= nil or #data.MarkingStretches > 0 or #data.KerbStretches > 0
	road:SetAttribute("RW_FeatureSourceOffsetStuds", if hasStoredFeatures then featureOffset else windowStart)
	StructureBuilder.Render(road, curve, data.Structure or StructureBuilder.DefaultData(settings), settings)
	BusStops.Render(road)
	return RoadInstance.Read(road)
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
	local data = RoadInstance.Read(road)
	if not data or #data.Curve.Segments ~= 1 then
		return nil
	end
	local scale = settings.MetersToStuds
	local source = RoadSource.ReadSegment(road) or data.Curve.Segments[1]
	local sourceCurve = PolyCurve.new({ source })
	local currentSourceStart = nearestSourceStation(sourceCurve, data.Curve:PosAt(0))
	local currentSourceEnd = nearestSourceStation(sourceCurve, data.Curve:PosAt(data.Curve.Length))
	local profile = if atStart then data.ProfileStart else (data.ProfileEnd or data.ProfileStart)
	local crossing = findProfileRingCrossing(
		sourceCurve,
		profile,
		if atStart then 0 else sourceCurve.Length,
		if atStart then sourceCurve.Length else 0,
		center,
		targetRadiusStuds,
		scale
	)
	if not crossing then
		return nil
	end
	local windowStart = if atStart then crossing else currentSourceStart
	local windowEnd = if atStart then currentSourceEnd else crossing
	if windowEnd - windowStart < 2 then
		return nil
	end
	local newData =
		rebuildRoadFromSource(road, data, source, windowStart, windowEnd, currentSourceStart, style, settings)
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
type ConvexFootprint = { Vector3 }
type BoundedFootprint = {
	Polygon: ConvexFootprint,
	MinX: number,
	MaxX: number,
	MinZ: number,
	MaxZ: number,
}

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
-- A paired highway mouth replaces its terminal hard shoulders with tapered
-- shoulder/kerb wedges. Their rigid outer facets sit farther inside the merge
-- ray than ordinary full-width pavement, so the normal three-degree ownership
-- overlap can delete ring sidewalk the taper has not reached yet. The strict
-- component sweep closes the final outer-band crescent at eight degrees.
-- Keep this shoulder-specific: ordinary mouths retain the tighter opening,
-- while solo mouths use exact roadway-footprint subtraction below.
local SHOULDER_SECTOR_INSET_RAD = math.rad(8)

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

-- Half of the angular footprint a generated ring Part occupies about `center`.
-- Testing only the Part's centre is not enough here: the long tangential edge of
-- a sidewalk or solid marking can be centred just outside a mouth sector while
-- one of its corners still projects well inside it. In Studio that surviving
-- corner reads as a concrete wedge or a white slash across the mouth even though
-- the centre-only Python coverage scan calls the opening clean.
local function partTopPolygon(part: BasePart): { Vector3 }
	local half = part.Size / 2
	return {
		(part.CFrame * CFrame.new(-half.X, half.Y, -half.Z)).Position,
		(part.CFrame * CFrame.new(half.X, half.Y, -half.Z)).Position,
		(part.CFrame * CFrame.new(half.X, half.Y, half.Z)).Position,
		(part.CFrame * CFrame.new(-half.X, half.Y, half.Z)).Position,
	}
end

local POLYGON_AREA_EPSILON = 1e-7

local function signedAreaXZ(polygon: ConvexFootprint): number
	local area = 0
	local previous = polygon[#polygon]
	for _, current in polygon do
		area += previous.X * current.Z - current.X * previous.Z
		previous = current
	end
	return area / 2
end

local function polygonBoundsXZ(polygon: ConvexFootprint): (number, number, number, number)
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, point in polygon do
		minX = math.min(minX, point.X)
		maxX = math.max(maxX, point.X)
		minZ = math.min(minZ, point.Z)
		maxZ = math.max(maxZ, point.Z)
	end
	return minX, maxX, minZ, maxZ
end

local function clipConvexHalfPlane(
	polygon: ConvexFootprint,
	a: Vector3,
	b: Vector3,
	orientation: number,
	keepInside: boolean
): ConvexFootprint
	if #polygon == 0 then
		return {}
	end
	local edgeX, edgeZ = b.X - a.X, b.Z - a.Z
	local function side(point: Vector3): number
		return orientation * (edgeX * (point.Z - a.Z) - edgeZ * (point.X - a.X))
	end
	local function accepted(value: number): boolean
		return if keepInside then value >= -1e-9 else value <= 1e-9
	end

	local clipped: ConvexFootprint = {}
	local previous = polygon[#polygon]
	local previousSide = side(previous)
	local previousAccepted = accepted(previousSide)
	for _, current in polygon do
		local currentSide = side(current)
		local currentAccepted = accepted(currentSide)
		if currentAccepted ~= previousAccepted then
			local denominator = previousSide - currentSide
			if math.abs(denominator) > 1e-12 then
				table.insert(clipped, previous:Lerp(current, previousSide / denominator))
			end
		end
		if currentAccepted then
			table.insert(clipped, current)
		end
		previous = current
		previousSide = currentSide
		previousAccepted = currentAccepted
	end
	return clipped
end

-- Convex fragments covering `subject` minus `cutter`. The carried `inside`
-- polygon is the intersection accumulated so far; each rejected half-plane is
-- one disjoint convex survivor. If no intersection survives every cutter edge,
-- the tentative fragments are discarded and the subject is returned unchanged.
local function subtractConvexFootprint(
	subject: ConvexFootprint,
	cutter: ConvexFootprint
): ({ ConvexFootprint }, boolean)
	if
		#subject < 3
		or #cutter < 3
		or math.abs(signedAreaXZ(subject)) <= POLYGON_AREA_EPSILON
		or math.abs(signedAreaXZ(cutter)) <= POLYGON_AREA_EPSILON
	then
		return { subject }, false
	end
	local orientation = if signedAreaXZ(cutter) >= 0 then 1 else -1
	local inside = table.clone(subject)
	local outsideFragments: { ConvexFootprint } = {}
	for i, a in cutter do
		if #inside < 3 then
			break
		end
		local b = cutter[if i < #cutter then i + 1 else 1]
		local outside = clipConvexHalfPlane(inside, a, b, orientation, false)
		if #outside >= 3 and math.abs(signedAreaXZ(outside)) > POLYGON_AREA_EPSILON then
			table.insert(outsideFragments, outside)
		end
		inside = clipConvexHalfPlane(inside, a, b, orientation, true)
	end
	if #inside < 3 or math.abs(signedAreaXZ(inside)) <= POLYGON_AREA_EPSILON then
		return { subject }, false
	end
	return outsideFragments, true
end

local POLYGON_POINT_EPSILON = 1e-5

local function pointsNearXZ(a: Vector3, b: Vector3): boolean
	local dx, dz = a.X - b.X, a.Z - b.Z
	return dx * dx + dz * dz <= POLYGON_POINT_EPSILON * POLYGON_POINT_EPSILON
end

local function crossXZ(a: Vector3, b: Vector3, c: Vector3): number
	return (b.X - a.X) * (c.Z - b.Z) - (b.Z - a.Z) * (c.X - b.X)
end

local function cleanConvexBoundary(polygon: ConvexFootprint): ConvexFootprint
	local cleaned: ConvexFootprint = {}
	for _, point in polygon do
		if #cleaned == 0 or not pointsNearXZ(cleaned[#cleaned], point) then
			table.insert(cleaned, point)
		end
	end
	if #cleaned > 1 and pointsNearXZ(cleaned[1], cleaned[#cleaned]) then
		table.remove(cleaned)
	end

	local changed = true
	while changed and #cleaned > 3 do
		changed = false
		for i, point in cleaned do
			local previous = cleaned[if i > 1 then i - 1 else #cleaned]
			local nextOne = cleaned[if i < #cleaned then i + 1 else 1]
			local abX, abZ = point.X - previous.X, point.Z - previous.Z
			local bcX, bcZ = nextOne.X - point.X, nextOne.Z - point.Z
			local abLength = math.sqrt(abX * abX + abZ * abZ)
			local bcLength = math.sqrt(bcX * bcX + bcZ * bcZ)
			local collinear = math.abs(crossXZ(previous, point, nextOne))
				<= POLYGON_POINT_EPSILON * (abLength + bcLength)
			local continuesForward = abX * bcX + abZ * bcZ >= -(POLYGON_POINT_EPSILON ^ 2)
			if collinear and continuesForward then
				table.remove(cleaned, i)
				changed = true
				break
			end
		end
	end
	return cleaned
end

local function isConvexBoundary(polygon: ConvexFootprint): boolean
	if #polygon < 3 then
		return false
	end
	local area = signedAreaXZ(polygon)
	if math.abs(area) <= POLYGON_AREA_EPSILON then
		return false
	end
	local orientation = if area >= 0 then 1 else -1
	for i, point in polygon do
		local previous = polygon[if i > 1 then i - 1 else #polygon]
		local nextOne = polygon[if i < #polygon then i + 1 else 1]
		local previousLength = distanceXZ(previous, point)
		local nextLength = distanceXZ(point, nextOne)
		if orientation * crossXZ(previous, point, nextOne) < -POLYGON_POINT_EPSILON * (previousLength + nextLength) then
			return false
		end
	end
	return true
end

-- Merge only across one complete edge traversed in opposite directions. A
-- convex union with conserved area cannot bridge a concavity or two disjoint
-- curb returns; uncertain/partial-edge cases simply stay as separate polygons.
local function tryMergeConvexFootprints(a: ConvexFootprint, b: ConvexFootprint): ConvexFootprint?
	local areaA, areaB = signedAreaXZ(a), signedAreaXZ(b)
	if areaA * areaB <= 0 then
		return nil
	end
	local edgeA, edgeB: number? = nil, nil
	for i, a0 in a do
		local a1 = a[if i < #a then i + 1 else 1]
		for j, b0 in b do
			local b1 = b[if j < #b then j + 1 else 1]
			if pointsNearXZ(a0, b1) and pointsNearXZ(a1, b0) then
				edgeA, edgeB = i, j
				break
			end
		end
		if edgeA then
			break
		end
	end
	if not edgeA or not edgeB then
		return nil
	end

	local merged: ConvexFootprint = {}
	local aIndex = if edgeA < #a then edgeA + 1 else 1
	while true do
		table.insert(merged, a[aIndex])
		if aIndex == edgeA then
			break
		end
		aIndex = if aIndex < #a then aIndex + 1 else 1
	end
	local bSharedEnd = if edgeB < #b then edgeB + 1 else 1
	local bIndex = if bSharedEnd < #b then bSharedEnd + 1 else 1
	while bIndex ~= edgeB do
		table.insert(merged, b[bIndex])
		bIndex = if bIndex < #b then bIndex + 1 else 1
	end
	merged = cleanConvexBoundary(merged)
	if not isConvexBoundary(merged) then
		return nil
	end
	local expectedArea = math.abs(areaA) + math.abs(areaB)
	local mergedArea = math.abs(signedAreaXZ(merged))
	local areaTolerance = math.max(POLYGON_AREA_EPSILON * 10, expectedArea * 1e-7)
	if math.abs(mergedArea - expectedArea) > areaTolerance then
		return nil
	end
	return merged
end

local function coalesceConvexFootprints(polygons: { ConvexFootprint }): { ConvexFootprint }
	local coalesced: { ConvexFootprint } = {}
	for _, polygon in polygons do
		local cleaned = cleanConvexBoundary(polygon)
		if #cleaned >= 3 and math.abs(signedAreaXZ(cleaned)) > POLYGON_AREA_EPSILON then
			table.insert(coalesced, cleaned)
		end
	end

	local mergedOne = true
	while mergedOne do
		mergedOne = false
		for i = 1, #coalesced - 1 do
			for j = i + 1, #coalesced do
				local merged = tryMergeConvexFootprints(coalesced[i], coalesced[j])
				if merged then
					coalesced[i] = merged
					table.remove(coalesced, j)
					mergedOne = true
					break
				end
			end
			if mergedOne then
				break
			end
		end
	end
	return coalesced
end

local function angularFootprintHalfSpan(part: BasePart, center: Vector3, centerAngle: number): number
	local angularHalf = 0
	for _, corner in partTopPolygon(part) do
		local offset = corner - center
		local flat = Vector3.new(offset.X, 0, offset.Z)
		if flat.Magnitude > 1e-6 then
			angularHalf = math.max(angularHalf, math.abs(angleDelta(math.atan2(flat.Z, flat.X), centerAngle)))
		end
	end
	return angularHalf
end

-- Clips one convex Part footprint to one side of the radial line at
-- `boundaryAngle`. `keepSign` is +1 for the counter-clockwise side and -1 for
-- the clockwise side. Ring strips are short enough that a boundary-straddler
-- can meet at most one mouth edge (the mandatory inter-mouth kerb gap is wider
-- than one strip), so this produces the exact outside fragment we need without
-- a general polygon-difference operation.
local function clipToAngularSide(
	polygon: { Vector3 },
	center: Vector3,
	boundaryAngle: number,
	keepSign: number
): { Vector3 }
	local boundaryX = math.cos(boundaryAngle)
	local boundaryZ = math.sin(boundaryAngle)
	local function side(point: Vector3): number
		local x = point.X - center.X
		local z = point.Z - center.Z
		return keepSign * (boundaryX * z - boundaryZ * x)
	end

	local clipped: { Vector3 } = {}
	local previous = polygon[#polygon]
	local previousSide = side(previous)
	local previousInside = previousSide >= -1e-6
	for _, current in polygon do
		local currentSide = side(current)
		local currentInside = currentSide >= -1e-6
		if currentInside ~= previousInside then
			local denominator = previousSide - currentSide
			if math.abs(denominator) > 1e-9 then
				table.insert(clipped, previous:Lerp(current, previousSide / denominator))
			end
		end
		if currentInside then
			table.insert(clipped, current)
		end
		previous = current
		previousSide = currentSide
		previousInside = currentInside
	end
	return clipped
end

local function replaceWithClippedPolygons(part: BasePart, polygons: { ConvexFootprint })
	local parent = part.Parent
	if not parent then
		return
	end
	local template = part:Clone()
	if not template:IsA("Part") then
		template:Destroy()
		part:Destroy()
		return
	end
	local depth = part.Size.Y
	local down = -part.CFrame.UpVector
	template.Parent = nil
	part:Destroy()
	local function makePart(): Part
		return template:Clone() :: Part
	end
	for _, polygon in polygons do
		for i = 2, #polygon - 1 do
			FillTriangle(polygon[1], polygon[i], polygon[i + 1], depth, down, makePart, parent)
		end
	end
	template:Destroy()
end

local function replaceWithClippedPolygon(part: BasePart, polygon: ConvexFootprint)
	replaceWithClippedPolygons(part, { polygon })
end

-- Remove only the top-plane overlap between the ring's original Sidewalk
-- strips and solo one-way roadway footprints. A polar sector cannot describe a
-- curved finite-width arm: making it wide enough to clear the inboard edge also
-- deletes 3-5 stud curb-return crescents beside the outboard edge. Sequential
-- convex subtraction keeps those returns and removes no concrete that is not
-- actually over Drive/Shoulder geometry.
local function openRingSidewalkByFootprints(parts: { BasePart }, cutters: { ConvexFootprint })
	if #cutters == 0 then
		return
	end
	local ringMinX, ringMaxX = math.huge, -math.huge
	local ringMinZ, ringMaxZ = math.huge, -math.huge
	local hasRingPart = false
	for _, part in parts do
		if part.Parent then
			local minX, maxX, minZ, maxZ = polygonBoundsXZ(partTopPolygon(part))
			ringMinX = math.min(ringMinX, minX)
			ringMaxX = math.max(ringMaxX, maxX)
			ringMinZ = math.min(ringMinZ, minZ)
			ringMaxZ = math.max(ringMaxZ, maxZ)
			hasRingPart = true
		end
	end
	if not hasRingPart then
		return
	end

	local boundedCutters: { BoundedFootprint } = {}
	for _, cutter in cutters do
		if #cutter >= 3 and math.abs(signedAreaXZ(cutter)) > POLYGON_AREA_EPSILON then
			local minX, maxX, minZ, maxZ = polygonBoundsXZ(cutter)
			if maxX >= ringMinX and minX <= ringMaxX and maxZ >= ringMinZ and minZ <= ringMaxZ then
				table.insert(boundedCutters, {
					Polygon = cutter,
					MinX = minX,
					MaxX = maxX,
					MinZ = minZ,
					MaxZ = maxZ,
				})
			end
		end
	end

	for _, part in parts do
		if not part.Parent then
			continue
		end
		local fragments: { ConvexFootprint } = { partTopPolygon(part) }
		local touched = false
		for _, cutter in boundedCutters do
			local nextFragments: { ConvexFootprint } = {}
			for _, fragment in fragments do
				local minX, maxX, minZ, maxZ = polygonBoundsXZ(fragment)
				if maxX < cutter.MinX or minX > cutter.MaxX or maxZ < cutter.MinZ or minZ > cutter.MaxZ then
					table.insert(nextFragments, fragment)
				else
					local survivors, subtracted = subtractConvexFootprint(fragment, cutter.Polygon)
					if subtracted then
						touched = true
					end
					for _, survivor in survivors do
						table.insert(nextFragments, survivor)
					end
				end
			end
			fragments = nextFragments
			if #fragments == 0 then
				break
			end
		end
		if touched then
			fragments = coalesceConvexFootprints(fragments)
			replaceWithClippedPolygons(part, fragments)
		end
	end
end

-- Delete ring pavement/kerb Parts wholly inside an entry sector and clip a Part
-- that crosses either sector boundary to the exact radial ray. The outside
-- fragment must survive: deleting the whole straddler opens a several-stud hole
-- on sparse three-leg rings, while keeping it whole causes the Studio clipping
-- and excess-marking report this path exists to prevent.
-- `minRadiusStuds` restricts removal to the OUTER band. Without it the filter
-- is purely angular and takes out every marking in the sector at any radius -
-- including a multi-lane ring's inter-lane dashes and, worse, the edge line
-- around the central island, which would gain a gap at every entry even though
-- the island itself is continuous.
local function openRingPavement(
	parts: { BasePart },
	center: Vector3,
	rawSectors: { MouthSector },
	minRadiusStuds: number,
	clampOpenings: boolean?
)
	local sectors = if clampOpenings == false then rawSectors else clampSectors(rawSectors)
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
		local angularHalf = angularFootprintHalfSpan(part, center, angle)
		for _, sector in sectors do
			local delta = angleDelta(angle, sector.Angle)
			local fullyInside = delta + angularHalf <= sector.Ahead and -delta + angularHalf <= sector.Behind
			if fullyInside then
				part:Destroy()
				break
			elseif delta <= sector.Ahead + angularHalf and -delta <= sector.Behind + angularHalf then
				-- A straddler's CENTRE may still be inside the opening even though
				-- one end crosses a boundary. Comparing the centre with `Ahead`
				-- therefore picked the opposite ray for exactly those terminal
				-- pieces, which either deleted the useful fragment or left a seam.
				-- Select the boundary its footprint actually overruns most.
				local aheadOverflow = delta + angularHalf - sector.Ahead
				local behindOverflow = -delta + angularHalf - sector.Behind
				local aheadSide = aheadOverflow >= behindOverflow
				local boundaryAngle = sector.Angle + (if aheadSide then sector.Ahead else -sector.Behind)
				local clipped =
					clipToAngularSide(partTopPolygon(part), center, boundaryAngle, if aheadSide then 1 else -1)
				replaceWithClippedPolygon(part, clipped)
				break
			end
		end
	end
end

-- Angular step for one span of a spiralling lane boundary. At 2 degrees the
-- chord sags r*(1-cos 1deg) off the true arc - 0.015 studs on a 100-stud ring,
-- an order of magnitude under the marking's own width.
local TURBO_ARC_STEP_RAD = math.rad(2)
-- A tiny/invalid edited divider radius must not turn the arm phase into
-- millions of samples. Half a stud remains far below the paint scale while
-- providing a hard upper bound for deliberately extreme editor values.
local TURBO_MIN_SAMPLE_SPACING_STUDS = 0.5
-- Fraction of each arc over which a boundary makes its outward move. Corrected
-- from a reference aerial: the divider does NOT climb steadily from the island
-- to the kerb across the whole arc. It holds a constant radius for most of the
-- way round, exactly like an ordinary concentric lane line, and is flung
-- outward into the exit over a short run at the end. Spreading the migration
-- evenly instead reads as a slow drift and loses the thing that makes a turbo
-- legible - that the lane you are in is committed to the next exit.
local TURBO_FLING_FRACTION = 0.35
-- Dash geometry for the circulating divider, deliberately not the region's
-- open-road LaneLine - see where they are used.
-- LONG mark, SHORT gap: the hazard ratio. A mark shorter than its gap reads as
-- an ordinary permissive lane line - cross when it suits you - which is the
-- opposite of what this line means. The peel is where a driver becomes
-- committed to the exit, so it is marked the way a warning line is, about 2:1
-- mark to gap rather than the region's open-road 1:5.
local TURBO_DASH_M, TURBO_GAP_M = 4.0, 2.0
-- How far down the exit arm the peel lands. It has to reach far enough that it
-- is unambiguously ON the arm's own lane line rather than grazing the ring's
-- edge, and not so far that it draws a lane boundary halfway to the approach.
local TURBO_PEEL_INTO_M = 9.0
-- The peel may not eat more than this share of the gap back to the previous
-- exit, however wide the legs are spaced.
local TURBO_PEEL_MAX_SHARE = 0.5

-- TURBO markings: lane boundaries that spiral outward, so the lane a driver is
-- in is carried to an exit rather than needing a lane change on the ring. The
-- circulating carriageway is a constant-width annulus either way - only the
-- boundaries inside it move - so this is markings, not a second ring generator
-- (ROUNDABOUT.md 5.3c corrects an earlier claim otherwise).
--
-- Across each arc between two mouths, every boundary migrates outward by
-- exactly one lane width:
--
--     boundary k runs from  inner + k*w  to  inner + (k+1)*w
--
-- which conserves the carriageway without conserving the lane count. On an
-- L-lane ring the outermost boundary reaches the outer edge - its lane has
-- been delivered to the exit - and the innermost lane arrives at the mouth 2*w
-- wide, which the next arc's new innermost boundary splits back into two. So a
-- mouth is entered with L-1 lanes and left with L, the extra one being the
-- entry's own traffic. That is the "inner lane flung out to the exit" the
-- reference aerial shows.
--
-- This cannot go through RoadBuilder.Build with the rest of the ring's
-- markings: it needs the mouth angles, and those are not known until every leg
-- has been trimmed and planned, which happens after the ring model exists.
-- Hence its own emitter, sharing RoadBuilder's lift and thickness so the two
-- sets of markings sit at the same height.
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
-- A lone one-way arm has no sibling carriageway or splitter island to justify
-- the paired mouth's full 38-degree fan. Driving it to that same ray makes the
-- approach orbit the ring before it joins, which reads as a pasted-on slip
-- road and leaves a bulbous kerb return. Fit the solo deflection to the arm's
-- actual half-width at the merge circle, with a small clearance and a hard cap
-- comfortably below the paired layout.
local SOLO_SPLIT_CLEARANCE_RAD = math.rad(3)
local SOLO_SPLIT_MAX_RAD = math.rad(26)
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
-- Rungs across the flat apron in front of the island. It is a long, very
-- shallow taper - much longer than the island on a wide-radius ring - but both
-- of its edges are the arms' own inner edges, so it needs only enough rungs to
-- track their curvature, not to resolve any shape of its own.
local APRON_SAMPLES = 24
-- On a ring too crowded for the mouths it carries - many legs, or wide
-- approaches on a small radius - the split gets squeezed until the two arms run
-- right up against each other partway along. The strip runs THROUGH that waist
-- rather than stopping at it: the pinched rungs collapse to zero area and
-- FillTriangle drops them, while the island still forms either side. Bailing out
-- at the waist instead threw away everything beyond it, including the wide part
-- against the ring, and left bare kerb at the mouth.
-- Arc step for the island's nose fan where it meets the ring kerb.
local NOSE_ARC_STEP_RAD = math.rad(2)
-- The gore is the gap between the two arms' INNER roadway edges, so on an
-- approach with a median it starts out that median's width at the cut, and on
-- one WITHOUT a median it starts at zero and only opens as the arms diverge.
-- Two different questions get asked of it, and conflating them is what put a
-- raised strip down the middle of an approach whose road has no median -
-- reported live as "there is median when there is no median for the type of
-- road used".
--
-- Does this approach arrive with a median at all? Anything above a hairline
-- does; a road without one measures zero here by construction.
local MEDIAN_AT_CUT_M = 0.5
-- On an approach with no median, how wide must the gore have opened before the
-- splitter becomes a raised kerbed island rather than flat asphalt? This is a
-- refuge you could stand on, not the first millimetre of daylight between two
-- diverging kerbs: at 0.5 m the island began as a knife edge tens of studs down
-- the approach and read as a sliver of median on a road that has none. 2 m is
-- the usual minimum width for a pedestrian refuge and is wide enough to read as
-- a deliberate island.
local ISLAND_MIN_WIDTH_M = 2.0
-- Length of the tapering nose the island grows back down the approach from
-- there. Without one the island stops dead at the width crossing, in a blunt
-- flat chop across the middle of the carriageway with the two arms' edge lines
-- carrying on past it - which is what the mouth "indentation" looks like once
-- the bare ground is gone. A real splitter tapers to a point. Bounded, so this
-- is a nose and not the knife-edge sliver that filling from the cut produced.
local ISLAND_NOSE_TAPER_M = 6.0
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
	-- Width of the source approach's terminal shoulders in the arm's own local
	-- left/right frame. A normal divided approach contributes only its traffic-
	-- outboard shoulder; a solo one-way highway has open edges on both sides and
	-- contributes both. The profile keeps zero-width Shoulder components at
	-- those boundaries so Markings emits the solid Drive/Shoulder separators,
	-- while buildArm lays the actual paved shoulders as independent wedges.
	CutShoulderM: number,
	CutShoulderLeftM: number,
	CutShoulderRightM: number,
	-- Centre shift of the remaining live roadway after those terminal shoulder
	-- widths are removed, in the arm's local lateral frame.
	CoreShiftM: number,
	-- Centreline to roadway edge, on the side facing away from / toward the gore.
	OuterOffsetStuds: number,
	InnerOffsetStuds: number,
	-- Centre of the arm's ROADWAY relative to its centreline. The two differ
	-- because the pavement sits on one side only, and it is the roadway that has
	-- to land on the lanes the arm is replacing.
	RoadwayCentreM: number,
}

-- What the turbo peel needs from a mouth: the exit arm's own curve, which
-- starts AT the ring, and the profile that says where its lane boundaries sit.
-- Nothing else in the ring pass has this, which is why five attempts at the
-- peel missed the line it is supposed to join (ROUNDABOUT.md 3.8).
export type ExitTrace = { Curve: PolyCurve.PolyCurve, Arm: ArmProfile }

type TurboReplacement = {
	DividerRadiusStuds: number,
	Sector: MouthSector,
}

-- Actual Drive/Drive boundaries on an exit arm, ordered from its outboard edge
-- toward the splitter.  Turbo used to divide total arm width by the EDITED
-- ring lane width; changing that width therefore changed the inferred arm lane
-- count and could make every peel disappear.  Component offsets are the source
-- of truth and also support unequal/custom lane widths.
local function armDriveBoundaryOffsetsStuds(arm: ArmProfile, style: RegionStyles.RegionStyle, scale: number): { number }
	local components = arm.Profile.Components
	local offsets = RoadProfile.ComponentOffsetsM(arm.Profile)
	local boundaries: { number } = {}
	for i = 1, #components - 1 do
		if components[i].Kind == "Drive" and components[i + 1].Kind == "Drive" then
			table.insert(boundaries, offsets[i].Right * scale)
		end
	end
	local outerLocal = if style.DriveOnLeft then -arm.OuterOffsetStuds else arm.OuterOffsetStuds
	table.sort(boundaries, function(a, b)
		return math.abs(a - outerLocal) < math.abs(b - outerLocal)
	end)
	return boundaries
end

local function buildTurboMarkings(
	ring: Model,
	center: Vector3,
	radiusStuds: number,
	profile: RoadProfile.RoadProfile,
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings,
	exits: { ExitTrace }
): { TurboReplacement }
	local lanes = math.max(1, math.floor(laneCount))
	-- One circulating lane has no boundary to peel off in the first place.
	if lanes < 2 or #exits == 0 then
		return {}
	end
	local replacements: { TurboReplacement } = {}
	local scale = settings.MetersToStuds
	local innerRadiusStuds = radiusStuds - ringInnerHalfWidthM(profile, style) * scale
	local laneStuds = laneWidthM * scale
	local travel = if style.DriveOnLeft then 1 else -1
	local markingWidth = style.MarkingWidthM * scale
	-- Python paints Turbo after the ordinary concentric divider. Lift this
	-- non-collidable overlay above RoadBuilder's highest alternate marking
	-- layer, preserving that same visible union without coplanar Parts.
	local y = center.Y + TURBO_MARKING_LIFT_STUDS
	local dashStuds = math.max(0.5, TURBO_DASH_M * scale)
	local gapStuds = math.max(0.5, TURBO_GAP_M * scale)

	local function place(p0: Vector3, p1: Vector3): boolean
		local span = (p1 - p0).Magnitude
		if span < 1e-4 then
			return false
		end
		local part = Instance.new("Part")
		part.Name = "Marking"
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Material = Enum.Material.SmoothPlastic
		part.Color = ROUNDABOUT_MARKING_COLOR
		part.Size = Vector3.new(markingWidth, RoadBuilder.MarkingThicknessStuds, span)
		part.CFrame = CFrame.lookAt((p0 + p1) / 2, p1, Vector3.yAxis)
		part.Parent = ring
		return true
	end

	-- Each exit arm's curve starts ON the ring, so its own merge angle comes
	-- straight off it rather than out of a sector.
	local angles: { number } = {}
	for i, trace in exits do
		local p = trace.Curve:PosAt(0)
		angles[i] = math.atan2(p.Z - center.Z, p.X - center.X)
	end

	for i, trace in exits do
		-- Room back to the previous exit in travel order, so a crowded ring
		-- gets a shorter peel rather than one that runs into its neighbour.
		local room = 2 * math.pi
		for j, other in angles do
			if j ~= i then
				room = math.min(room, ((angles[i] - other) * travel) % (2 * math.pi))
			end
		end
		local sweep = room * TURBO_PEEL_MAX_SHARE * TURBO_FLING_FRACTION * 2
		if sweep <= 1e-6 then
			continue
		end
		local curve = trace.Curve
		local arm = trace.Arm
		local into = math.min(TURBO_PEEL_INTO_M * scale, curve.Length * 0.9)
		if flatUnit(curve:TangentAt(into)).Magnitude < 1e-6 then
			continue
		end
		local targetOffsets = armDriveBoundaryOffsetsStuds(arm, style, scale)
		for k = 1, lanes - 1 do
			-- Ring boundary k is (lanes-k) boundaries in from the outside.
			-- Resolve that ordinal against the exit's ACTUAL Drive/Drive
			-- boundaries. A narrower arm simply cannot receive an inner ring
			-- divider; shoulders and parking never count as destinations.
			local targetIndex = lanes - k
			local offset = targetOffsets[targetIndex]
			if not offset then
				continue
			end
			local ringRadius = innerRadiusStuds + k * laneStuds
			if ringRadius <= math.max(markingWidth, 1e-3) then
				continue
			end
			local mergePosition = curve:PosAt(0)
			local mergeRight = rightOf(flatUnit(curve:TangentAt(0)))
			local targetMerge = mergePosition + mergeRight * offset
			local targetAngle = math.atan2(targetMerge.Z - center.Z, targetMerge.X - center.X)
			local targetRadius = distanceXZ(targetMerge, center)
			local startAngle = targetAngle - travel * sweep
			-- TWO PHASES: a polar peel over the ring, then the exit arm's own
			-- boundary. When ring and exit lane widths differ, those two
			-- boundaries do not have the same radius. Ease between their actual
			-- radii with zero radial derivative at both ends, so editing lane
			-- width produces a smooth hand-off instead of a jump or no marking.
			--
			-- Two constructions came before this one. A free cubic pinned to the
			-- ring tangent at one end and the arm tangent at the other sagged:
			-- the control polygon cuts the chord, and on a 4-leg 2+2 the peel
			-- dropped to r=57.8 against a divider at 66.4 - eight studs toward
			-- the island on its way out. Capping the handles did not help, since
			-- the span is 61 degrees of arc once the arm's own swing is counted
			-- and no handle length makes a straight-ish chord follow a circle
			-- that far. Blending the two curves by progress cured the sag but
			-- pairs mismatched parameters: early on it mixes a ring point with
			-- an arm point 40 degrees away, and the chord between them cuts
			-- inward. Only 1.4 studs on a 3-lane ring, but a kink in the one
			-- line a driver is being asked to follow out of the roundabout.
			local arcSamples = math.max(4, math.ceil(sweep / TURBO_ARC_STEP_RAD))
			local pts: { Vector3 } = {}
			for j = 0, arcSamples do
				local t = j / arcSamples
				local eased = t * t * (3 - 2 * t)
				local radius = ringRadius + (targetRadius - ringRadius) * eased
				table.insert(pts, ringPointAt(center, startAngle + travel * sweep * t, radius, y))
			end
			-- The arc's angular step converted to arc length at this radius, so
			-- both phases are sampled to one visual tolerance rather than to a
			-- count each.
			local armSamples =
				math.max(4, math.ceil(into / math.max(TURBO_MIN_SAMPLE_SPACING_STUDS, TURBO_ARC_STEP_RAD * ringRadius)))
			for j = 1, armSamples do
				local armS = into * j / armSamples
				local aPos = curve:PosAt(armS)
				local aTan = flatUnit(curve:TangentAt(armS))
				local onArm = aPos + rightOf(aTan) * offset
				table.insert(pts, Vector3.new(onArm.X, y, onArm.Z))
			end
			local cum: { number } = { 0 }
			for j = 2, #pts do
				table.insert(cum, cum[j - 1] + (pts[j] - pts[j - 1]).Magnitude)
			end
			local total = cum[#cum]
			local function pointAtLength(d: number): Vector3
				d = math.clamp(d, 0, total)
				for m = 1, #cum - 1 do
					if d <= cum[m + 1] then
						local seg = cum[m + 1] - cum[m]
						local f = if seg > 1e-9 then (d - cum[m]) / seg else 0
						return pts[m]:Lerp(pts[m + 1], f)
					end
				end
				return pts[#pts]
			end
			-- Backwards from the arm end, so a dash lands flush where the peel
			-- meets the line it is handing over to.
			local placedAny = false
			local d = total - dashStuds
			while d >= 0 do
				placedAny = place(pointAtLength(d), pointAtLength(d + dashStuds)) or placedAny
				d -= dashStuds + gapStuds
			end
			if placedAny then
				table.insert(replacements, {
					DividerRadiusStuds = ringRadius,
					Sector = {
						Angle = startAngle + travel * sweep / 2,
						Ahead = sweep / 2,
						Behind = sweep / 2,
					},
				})
			end
		end
	end
	return replacements
end

-- The ordinary concentric divider must yield over the arc owned by a Turbo
-- peel. Leaving both dash grammars in the same place is the source of the
-- doubled/excess markings visible in Studio: the permissive short dash fills
-- the hazard line's deliberate gaps. Clip only the matching divider radius;
-- edge lines and other circulating boundaries remain untouched.
local function openTurboReplacementArcs(
	baseParts: { BasePart },
	center: Vector3,
	replacements: { TurboReplacement },
	markingWidthStuds: number
)
	local tolerance = math.max(0.5, markingWidthStuds * 1.5)
	for _, replacement in replacements do
		local matching: { BasePart } = {}
		for _, part in baseParts do
			if
				part.Parent
				and part.Name == "Marking"
				and math.abs(distanceXZ(part.Position, center) - replacement.DividerRadiusStuds) <= tolerance
			then
				table.insert(matching, part)
			end
		end
		-- The peel itself owns this exact span. Neighbour-sector clamping here
		-- would leave a short ordinary dash under either end of a wide peel.
		openRingPavement(matching, center, { replacement.Sector }, 0, false)
	end
end

-- One strip of an approach's roadway, kept as the KIND it actually is.
--
-- This used to be a bare width, and flattening it was a real bug: a shoulder is
-- `Direction = 0` roadway, so it was swept into a side by the undirected pass
-- below and then re-emitted as `{ Kind = "Drive" }`. A 2+2 highway built 3+3
-- arms - wrong colour (AsphaltColor, not ShoulderColor) and wrong markings,
-- since Markings.lua puts a lane boundary between two Drive components where a
-- solid edge line belongs.
--
-- `Directional` records whether the strip had a travel direction in the source
-- profile, not which one: an arm is one-way, so every directional strip becomes
-- Direction = 1, while a shoulder or a parking bay stays undirected as it was.
type LaneSpec = { Kind: RoadProfile.ComponentKind, WidthM: number, Directional: boolean }

-- The lanes of an approach travelling one way, and the span they occupy in the
-- approach profile's own frame. `Lanes` is in the approach's own left-to-right
-- order; `armProfileFor` reverses it when the arm's frame is mirrored.
type LaneGroup = { Lanes: { LaneSpec }, LeftM: number, RightM: number, PavementM: number }

-- One direction's worth of an approach, as a one-way road: the lanes that
-- actually travel that way, plus a single pavement on the arm's OUTER side. A
-- pavement on both sides would lay a raised strip down the middle of the mouth,
-- since the gore side is where the splitter island goes.
local function armProfileFor(
	group: LaneGroup,
	solo: boolean,
	style: RegionStyles.RegionStyle,
	scale: number,
	mirrored: boolean,
	pavementM: number
): ArmProfile
	local components: { RoadProfile.ProfileComponent } = {}
	-- `group.Lanes` is in the APPROACH's left-to-right order. An arm whose own
	-- travel runs opposite to the approach curve sees that cross-section
	-- mirrored - what was at approach offset +x is at arm offset -x - so its
	-- components have to be listed back to front.
	--
	-- Invisible until now, and it would have stayed invisible: every strip was
	-- emitted as an identical-width Drive, so reversing the list changed
	-- nothing observable. Emitting shoulders as shoulders is what gives the
	-- order something to get wrong, and it would have put the hard shoulder
	-- down the middle of the mouth against the splitter island.
	local first, last, step = 1, #group.Lanes, 1
	if mirrored then
		first, last, step = #group.Lanes, 1, -1
	end
	local ordered: { LaneSpec } = {}
	for i = first, last, step do
		table.insert(ordered, group.Lanes[i])
	end
	-- A hard shoulder is paved road reserve, not another running lane. Keep a
	-- zero-width component at each tapered boundary so Markings.lua still emits
	-- its mandatory solid separator, and hand the real widths to buildArm. A
	-- paired entry/exit tapers only the ring-outboard side; a solo one-way arm
	-- borders open ground on both sides and must taper both terminal shoulders.
	-- Internal shoulders remain real profile components rather than silently
	-- moving to a road edge.
	local taperedShoulder: { [number]: boolean } = {}
	local cutShoulderLeftM = 0
	local cutShoulderRightM = 0
	local leftShoulderMarkerIndex: number? = nil
	local rightShoulderMarkerIndex: number? = nil
	if style.DriveOnLeft or solo then
		for i = 1, #ordered do
			if ordered[i].Kind ~= "Shoulder" then
				break
			end
			taperedShoulder[i] = true
			cutShoulderLeftM += ordered[i].WidthM
			leftShoulderMarkerIndex = i
		end
	end
	if not style.DriveOnLeft or solo then
		for i = #ordered, 1, -1 do
			if ordered[i].Kind ~= "Shoulder" or taperedShoulder[i] then
				break
			end
			taperedShoulder[i] = true
			cutShoulderRightM += ordered[i].WidthM
			rightShoulderMarkerIndex = i
		end
	end
	for i, lane in ordered do
		if taperedShoulder[i] then
			-- Collapse a contiguous terminal run to one semantic marker next to
			-- the live lanes. Multiple adjacent zero-width Shoulders would make
			-- roundaboutMarkingLines emit both an inset edge and a separator.
			if i == leftShoulderMarkerIndex or i == rightShoulderMarkerIndex then
				table.insert(components, { Kind = "Shoulder", WidthM = 0, Direction = 0 })
			end
		else
			table.insert(components, {
				Kind = lane.Kind,
				WidthM = lane.WidthM,
				Direction = if lane.Directional then 1 else 0,
			})
		end
	end
	local function pavement(widthM: number?): RoadProfile.ProfileComponent
		return { Kind = "Sidewalk", WidthM = widthM or pavementM, Direction = 0 }
	end
	-- This is the RING-side pavement width. `buildArm` keeps the running lanes
	-- fixed to this profile and replaces the physical shoulder/Sidewalk surface
	-- outside their solid line with coordinated edge-anchored ramps. That matters:
	-- a profile transition recentres the whole cross-section as total width
	-- changes, which would slide the lanes and shoulder sideways along the arm.
	-- The pavement taper must move only its own OUTER edge.
	if solo then
		-- A one-way approach has no sibling arm or splitter. Its traffic-outboard
		-- side hands onto the ring pavement; its inboard side opens directly into
		-- the circulating carriageway. Keep a zero-width Sidewalk component on
		-- that inboard side so buildArm can taper any source footway away without
		-- carrying a raised kerb deep across the ring.
		if style.DriveOnLeft then
			table.insert(components, 1, pavement())
			table.insert(components, pavement(0))
		else
			table.insert(components, 1, pavement(0))
			table.insert(components, pavement())
		end
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
		CutShoulderM = cutShoulderLeftM + cutShoulderRightM,
		CutShoulderLeftM = cutShoulderLeftM,
		CutShoulderRightM = cutShoulderRightM,
		CoreShiftM = (cutShoulderLeftM - cutShoulderRightM) / 2,
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
		-- Zero means the approach genuinely has no pavement (a motorway). The
		-- arm still receives the ring-side width in `armProfileFor`; `buildArm`
		-- tapers between the two instead of pretending the approach had one.
		return { Lanes = {}, LeftM = math.huge, RightM = -math.huge, PavementM = 0 }
	end
	local inbound, outbound = newGroup(), newGroup()
	-- Indices, not widths, and sorted into cross-section order at the end. The
	-- undirected pass below runs AFTER the directional one, so appending as we
	-- go would put a shoulder at the inboard end of its own group however far
	-- outboard it actually sits.
	local picked: { [LaneGroup]: { number } } = { [inbound] = {}, [outbound] = {} }
	local assigned: { [number]: boolean } = {}
	local function add(group: LaneGroup, index: number)
		if assigned[index] then
			return
		end
		assigned[index] = true
		table.insert(picked[group], index)
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
	-- Undirected roadway (shoulders, parking) belongs to whichever side it
	-- abuts; anything left in the middle is a median and becomes the splitter
	-- gore. Repeat until stable because a terminal reserve can contain multiple
	-- adjacent components ordered outside-to-inside: the inner one must join
	-- before the outer one becomes adjacent to the directional lane group.
	local expanded = true
	while expanded do
		expanded = false
		for i, component in profile.Components do
			if assigned[i] or not RoadProfile.IsRoadway(component.Kind) or component.Direction ~= 0 then
				continue
			end
			local edge = offsets[i]
			for _, group in { inbound, outbound } do
				if
					#picked[group] > 0
					and (math.abs(edge.Right - group.LeftM) < 1e-6 or math.abs(edge.Left - group.RightM) < 1e-6)
				then
					add(group, i)
					expanded = true
					break
				end
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
		local indices = picked[group]
		if #indices == 0 then
			return nil
		end
		table.sort(indices)
		for _, index in indices do
			local component = profile.Components[index]
			table.insert(group.Lanes, {
				Kind = component.Kind,
				WidthM = component.WidthM,
				Directional = component.Direction ~= 0,
			})
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
	local componentOffsets = RoadProfile.ComponentOffsetsM(profile)
	local onlyDriveIndex: number? = nil
	local driveCount = 0
	for i, component in profile.Components do
		if component.Kind == "Drive" and component.WidthM > 1e-6 then
			driveCount += 1
			onlyDriveIndex = i
		end
	end
	-- Legacy/custom one-lane profiles sometimes predate direction metadata.
	-- Halving that single lane creates two unusable half-width arms. Treat it as
	-- a shared narrow approach which flares to one full-width entry and one
	-- full-width exit at the mouth.
	if driveCount == 1 and onlyDriveIndex then
		local index = onlyDriveIndex :: number
		local component = profile.Components[index]
		local edge = componentOffsets[index]
		local pavement = style.SidewalkWidthM
		for _, candidate in profile.Components do
			if candidate.Kind == "Sidewalk" then
				pavement = math.max(pavement, candidate.WidthM)
			end
		end
		local function sharedGroup(): LaneGroup
			return {
				Lanes = {
					{ Kind = "Drive" :: RoadProfile.ComponentKind, WidthM = component.WidthM, Directional = true },
				},
				LeftM = edge.Left,
				RightM = edge.Right,
				PavementM = pavement,
			}
		end
		return sharedGroup(), sharedGroup()
	end
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
	local function half(widthM: number): { LaneSpec }
		return { { Kind = "Drive" :: RoadProfile.ComponentKind, WidthM = widthM, Directional = true } }
	end
	return { Lanes = half(midM - leftM), LeftM = leftM, RightM = midM, PavementM = pavement }, {
		Lanes = half(rightM - midM),
		LeftM = midM,
		RightM = rightM,
		PavementM = pavement,
	}
end

local function buildArm(
	curve: PolyCurve.PolyCurve,
	arm: ArmProfile,
	cutPavementM: number,
	cutAtStart: boolean,
	center: Vector3,
	ringKerbRadiusStuds: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings,
	collectRoadwayFootprints: boolean
): (Model, { ConvexFootprint })
	local roadwayFootprints: { ConvexFootprint } = {}
	local sidewalkIndices: { number } = {}
	local needsSurfaceTaper = arm.CutShoulderM > 1e-6
	for i, component in arm.Profile.Components do
		if component.Kind == "Sidewalk" then
			table.insert(sidewalkIndices, i)
			if math.abs(component.WidthM - cutPavementM) > 1e-6 then
				needsSurfaceTaper = true
			end
		end
	end

	local markingLines = roundaboutMarkingLines(arm.Profile, style, false)
	local sourceOutboardOffsetM, ringOutboardOffsetM = outboardArmMarkingOffsetsM(arm.Profile, style)
	-- A motorway's solid Drive/Shoulder separator starts exactly on that
	-- boundary at the source cut, while the ring edge line is inset from its
	-- kerb. Let the generated arm line make that small lateral transition so it
	-- reaches the ring at the same point and tangent instead of leaving a radial
	-- gap. Ordinary road edge lines already use the inset at both ends.
	if sourceOutboardOffsetM and ringOutboardOffsetM then
		for _, line in markingLines do
			if
				math.abs(line.OffsetStartM - sourceOutboardOffsetM) < 1e-6
				and math.abs(line.OffsetEndM - sourceOutboardOffsetM) < 1e-6
			then
				if cutAtStart then
					line.OffsetEndM = ringOutboardOffsetM
				else
					line.OffsetStartM = ringOutboardOffsetM
				end
				break
			end
		end
	end
	clipArmMarkingLinesAtRing(
		markingLines,
		curve,
		center,
		ringKerbRadiusStuds,
		cutAtStart,
		style.MarkingWidthM * settings.MetersToStuds,
		settings.MetersToStuds,
		ringOutboardOffsetM
	)
	local options = {
		Curve = curve,
		ProfileStart = arm.Profile,
		Style = style,
		Settings = flatSettings(settings),
		Preview = false,
		-- Widths/offsets still include the ring-side pavement and the zero-width
		-- Shoulder marker, so both travel lanes and their solid outer line stay
		-- exactly where planMouth placed them. Only the physical surface outside
		-- that line is replaced below.
		ExcludeComponentIndices = if needsSurfaceTaper then sidewalkIndices else nil,
		MarkingLines = markingLines,
		MarkingDashStartsAtZero = true,
	}
	local model = RoadBuilder.Build(options)
	local stations = RoadBuilder.StationsFor(options)

	if collectRoadwayFootprints then
		-- RoadBuilder's flat arm core is emitted as midpoint-aligned rectangles
		-- with curvature-dependent length padding. Cutting against ideal station
		-- quads misses those real corner protrusions (and can cut bare crescents on
		-- the opposite side), so use the generated block footprints themselves.
		-- Bay is roadway too; custom profiles must not leave its mouth kerbed off.
		local roadwayPartNames: { [string]: boolean } = {
			Drive = true,
			Shoulder = true,
			Bike = true,
			Parking = true,
			Bay = true,
		}
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") and roadwayPartNames[descendant.Name] then
				table.insert(roadwayFootprints, partTopPolygon(descendant))
			end
		end
	end

	if needsSurfaceTaper then
		local scale = settings.MetersToStuds
		local curbHeight = style.CurbHeightM * scale
		local roadDepth = settings.RoadThicknessStuds
		local pavementDepth = roadDepth + curbHeight
		local offsets = RoadProfile.ComponentOffsetsM(arm.Profile)
		local length = curve.Length

		local function makeSurfacePart(name: string, material: Enum.Material, color: Color3): Part
			local part = Instance.new("Part")
			part.Name = name
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
		local function makeShoulderPart(): Part
			return makeSurfacePart("Shoulder", Enum.Material.Asphalt, style.ShoulderColor)
		end
		local function makePavementPart(): Part
			return makeSurfacePart("Sidewalk", Enum.Material.Concrete, style.SidewalkColor)
		end

		local function ringAlphaAt(station: number): number
			local t = if cutAtStart then station / length else 1 - station / length
			t = math.clamp(t, 0, 1)
			return t * t * (3 - 2 * t)
		end

		for _, componentIndex in sidewalkIndices do
			local component = arm.Profile.Components[componentIndex]
			local edge = offsets[componentIndex]
			local leftSide = (edge.Left + edge.Right) / 2 < 0
			local outward = if leftSide then -1 else 1
			local innerOffsetM = if leftSide then edge.Right else edge.Left
			local ringPavementM = component.WidthM
			local cutShoulderM = if outward < 0 then arm.CutShoulderLeftM else arm.CutShoulderRightM

			local function surfacePoints(station: number): (Vector3, Vector3, Vector3, Vector3, number, number)
				local alpha = ringAlphaAt(station)
				local shoulderWidthM = cutShoulderM * (1 - alpha)
				local pavementWidthM = cutPavementM + (ringPavementM - cutPavementM) * alpha
				local frame = curve:FrameAt(station)
				local shoulderOuterM = innerOffsetM + outward * shoulderWidthM
				local pavementOuterM = shoulderOuterM + outward * pavementWidthM
				local shoulderInner = (frame * CFrame.new(innerOffsetM * scale, 0, 0)).Position
				local shoulderOuter = (frame * CFrame.new(shoulderOuterM * scale, 0, 0)).Position
				local pavementInner = (frame * CFrame.new(shoulderOuterM * scale, curbHeight, 0)).Position
				local pavementOuter = (frame * CFrame.new(pavementOuterM * scale, curbHeight, 0)).Position
				return shoulderInner, shoulderOuter, pavementInner, pavementOuter, shoulderWidthM, pavementWidthM
			end

			for i = 1, #stations - 1 do
				local s0, s1 = stations[i], stations[i + 1]
				local shoulderInner0, shoulderOuter0, pavementInner0, pavementOuter0, shoulderWidth0, pavementWidth0 =
					surfacePoints(s0)
				local shoulderInner1, shoulderOuter1, pavementInner1, pavementOuter1, shoulderWidth1, pavementWidth1 =
					surfacePoints(s1)
				local down = -curve:FrameAt((s0 + s1) / 2).UpVector
				if math.max(shoulderWidth0, shoulderWidth1) * scale >= 0.02 then
					if collectRoadwayFootprints then
						-- These surfaces are FillTriangle wedges, so their BasePart
						-- bounding boxes are not their plan-view footprint. The source
						-- quad is exact and convex on RoadBuilder's adaptive station grid.
						table.insert(
							roadwayFootprints,
							{ shoulderInner0, shoulderOuter0, shoulderOuter1, shoulderInner1 }
						)
					end
					FillTriangle(
						shoulderInner0,
						shoulderOuter0,
						shoulderOuter1,
						roadDepth,
						down,
						makeShoulderPart,
						model
					)
					FillTriangle(
						shoulderInner0,
						shoulderOuter1,
						shoulderInner1,
						roadDepth,
						down,
						makeShoulderPart,
						model
					)
				end
				if math.max(pavementWidth0, pavementWidth1) * scale >= 0.02 then
					FillTriangle(
						pavementInner0,
						pavementOuter0,
						pavementOuter1,
						pavementDepth,
						down,
						makePavementPart,
						model
					)
					FillTriangle(
						pavementInner0,
						pavementOuter1,
						pavementInner1,
						pavementDepth,
						down,
						makePavementPart,
						model
					)
				end
			end
		end
	elseif #sidewalkIndices > 0 then
		-- Constant-width raised surfaces can keep RoadBuilder's padded interior
		-- strips: that overlap is what closes the mouth against the ring. Replace
		-- only the strip at the approach cut, where a rotated rectangular end cap
		-- can project across the adjoining carriageway.
		local function replaceCutPavementCaps()
			local scale = settings.MetersToStuds
			local curbHeight = style.CurbHeightM * scale
			local pavementDepth = settings.RoadThicknessStuds + curbHeight
			local offsets = RoadProfile.ComponentOffsetsM(arm.Profile)
			-- With one interval the cut cap is also the ring cap. Keep its overlap
			-- rather than opening a hole at the mouth.
			if #stations < 3 then
				return
			end
			local intervalIndex = if cutAtStart then 1 else #stations - 1
			local s0 = stations[intervalIndex]
			local s1 = stations[intervalIndex + 1]

			local function makePavementPart(): Part
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

			for _, componentIndex in sidewalkIndices do
				for _, descendant in model:GetDescendants() do
					local stationStart = descendant:GetAttribute("RW_StationStartStuds")
					local stationEnd = descendant:GetAttribute("RW_StationEndStuds")
					if
						descendant:IsA("BasePart")
						and descendant.Name == "Sidewalk"
						and descendant:GetAttribute("RW_ComponentStartIndex") == componentIndex
						and typeof(stationStart) == "number"
						and typeof(stationEnd) == "number"
						and math.abs(stationStart - s0) < 1e-4
						and math.abs(stationEnd - s1) < 1e-4
					then
						descendant:Destroy()
					end
				end

				local edge = offsets[componentIndex]
				local frame0 = curve:FrameAt(s0)
				local frame1 = curve:FrameAt(s1)
				local left0 = (frame0 * CFrame.new(edge.Left * scale, curbHeight, 0)).Position
				local right0 = (frame0 * CFrame.new(edge.Right * scale, curbHeight, 0)).Position
				local left1 = (frame1 * CFrame.new(edge.Left * scale, curbHeight, 0)).Position
				local right1 = (frame1 * CFrame.new(edge.Right * scale, curbHeight, 0)).Position
				local down = -curve:FrameAt((s0 + s1) / 2).UpVector
				FillTriangle(left0, right0, right1, pavementDepth, down, makePavementPart, model)
				FillTriangle(left0, right1, left1, pavementDepth, down, makePavementPart, model)
			end
		end

		replaceCutPavementCaps()
	end
	-- Not a free-standing editable road - owned by the roundabout mesh.
	model:SetAttribute("RW_Road", nil)
	model.Name = "RoundaboutArm"
	for _, descendant in model:GetDescendants() do
		-- Deck/surfaces sink below the ring to avoid coplanar asphalt. Markings
		-- have explicit longitudinal ownership above and must stay on the normal
		-- road/ring paint plane so the preserved outer edge line has no vertical
		-- step at either hand-off.
		if descendant:IsA("BasePart") and descendant.Name ~= "Marking" then
			descendant.CFrame = descendant.CFrame - Vector3.new(0, ARM_SINK_STUDS, 0)
		end
	end
	return model, roadwayFootprints
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
	local function makePart(name: string, material: Enum.Material, color: Color3): Part
		local part = Instance.new("Part")
		part.Name = name
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
	local function makeSidewalkPart(): Part
		return makePart("Sidewalk", Enum.Material.Concrete, style.SidewalkColor)
	end
	local function makeApronPart(): Part
		return makePart("GoreApron", Enum.Material.Asphalt, style.AsphaltColor)
	end
	-- Gore-side roadway edge: the inner offset lies on +flow * right-of-travel for
	-- both arms (the exit's travel is reversed, and so is its own right).
	-- Each arm gets its OWN inner offset. Sharing the entry's is only right when
	-- the two are the same width; on a 3/1 approach it tracks the narrow exit's
	-- edge a lane and a half out of place, and the island misses the carriageway.
	--
	-- `lift` is the height of the surface being laid: curb height for the raised
	-- island, zero for the flat apron in front of it.
	local function goreEdgeAt(curve: PolyCurve.PolyCurve, station: number, arm: ArmProfile, lift: number): Vector3
		local s = math.clamp(station, 0, curve.Length)
		local position = curve:PosAt(s)
		local tangent = flatUnit(curve:TangentAt(s))
		if tangent.Magnitude < 1e-6 then
			return position
		end
		return position + rightOf(tangent) * (arm.InnerOffsetStuds * flow) + Vector3.new(0, lift, 0)
	end
	local function goreEdge(curve: PolyCurve.PolyCurve, station: number, arm: ArmProfile): Vector3
		return goreEdgeAt(curve, station, arm, curbHeight)
	end
	-- Width of the gore `along` studs in from the cut, measured between the two
	-- arms' own inner edges.
	local function goreWidth(along: number): number
		return distanceXZ(goreEdge(entryCurve, along, entryArm), goreEdge(exitCurve, exitCurve.Length - along, exitArm))
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
	-- Where the gore first opens out to island width. This RE-PARAMETERISES the
	-- rungs below; it does not drop samples from a fixed grid.
	--
	-- Dropping them is what the first version did, and it was wrong in a way
	-- that only showed at some radii: the loop also breaks when either edge
	-- reaches the ring kerb, so on a ring whose arms converge early the skipped
	-- samples were consumed and the break then fired before enough rungs had
	-- accumulated to build anything. The island came out truncated or never
	-- started, leaving the gore bare - measured as a band of bare ground at
	-- R=34..38 on a 3-leg ring, up to 4.4 studs deep, with clean geometry
	-- either side of it. Re-parameterising keeps the full GORE_SAMPLES
	-- resolution for whatever island does get built.
	-- Where the raised island starts, and by the same token where the flat
	-- apron in front of it stops. Default `reach`: a gore that never opens to
	-- island width gets apron for its whole length and no island at all.
	--
	-- THE GORE IS NEVER LEFT OPEN. Both earlier versions of this treated the
	-- width test as build-or-don't and left bare ground in front of the island,
	-- which is the V-notch reported down the middle of every approach. The
	-- choice was never raised-or-nothing: between the cut and the point where a
	-- splitter is wide enough to stand on, that wedge is not a median at all -
	-- it is the approach's own carriageway fanning out into the mouth, and it
	-- belongs at deck level, continuous with both arms. So the width test now
	-- picks WHICH surface, not WHETHER there is one.
	--
	-- This also drops the outer-edge override that used to sit here. Its job
	-- was to guarantee the island reached the ring's outer edge, because
	-- `openRingPavement` deletes ring pavement across the mouth sector out to
	-- that radius and anything short of it left the deleted band bare (the
	-- R=34..36 defect: at R=35 the gore reached radius 42.3 against an outer
	-- edge of 45.1, and all 150 bare-ground samples sat in the 2.8 studs
	-- between). The apron covers that band now, and covers it with the right
	-- material: a mouth is exactly where the circulatory pavement ring is
	-- interrupted by carriageway. Forcing the island out instead is what ran a
	-- raised sliver 17 studs down the approach.
	local startAlong = reach
	if goreWidth(0) >= MEDIAN_AT_CUT_M * scale then
		-- The approach arrives with a median: the island continues it straight
		-- from the cut. Anything else makes the median stop and restart.
		startAlong = 0
	else
		local probes = 64
		for i = 0, probes do
			local along = (i / probes) * reach
			if goreWidth(along) >= ISLAND_MIN_WIDTH_M * scale then
				startAlong = along
				break
			end
		end
	end

	-- Where the gore stops being beside the circulating carriageway and starts
	-- being ON it. Nothing raised may begin past here.
	--
	-- Dropping the outer-edge override above removed the guarantee that used to
	-- make this impossible, and on a crowded ring the width test can now first
	-- reach 2 m at a station already inside the kerb. The rung loop below then
	-- keeps its first rung (its break only fires from i > 0), the nose fan runs
	-- from that deep apex out to the kerb arc, and the result is a raised wedge
	-- laid straight across the circulating lanes. Measured on a 4-leg 2+2 at
	-- R=45: gore material from r=36.1 out to the kerb at r=54.5, leaving 7.6
	-- studs of a 26.1-stud carriageway drivable - 0.58 of one lane. Same shape
	-- at R=50 and, on a 1+1 ring, from R=22 to R=40.
	--
	-- Two values, because the apron and the island want opposite roundings of
	-- the same crossing. `kerbAlongIn` is the first probe at or inside the kerb
	-- and is where the APRON stops: stopping one probe short instead left a
	-- ~0.9-stud ring of bare ground just outside the kerb at every mouth, in
	-- exactly the band `openRingPavement` had deleted. Running slightly past is
	-- free - the overlap is flat asphalt over the ring's own flat asphalt.
	-- `kerbAlongOut` is the last probe still outside, and is the latest the
	-- ISLAND may start.
	local kerbAlongIn, kerbAlongOut = reach, reach
	local kerbProbes = 64
	for i = 0, kerbProbes do
		local along = (i / kerbProbes) * reach
		if
			distanceXZ(goreEdge(entryCurve, along, entryArm), center) <= ringKerbRadiusStuds
			or distanceXZ(goreEdge(exitCurve, exitCurve.Length - along, exitArm), center) <= ringKerbRadiusStuds
		then
			-- One probe PAST the crossing, not at it. Landing exactly on the
			-- first inside sample still left a 0.25-stud hairline of bare
			-- ground at r=33.0 against a kerb at 32.95, because the rung is a
			-- chord and the kerb is an arc. Overlapping the ring deck by half
			-- a probe costs nothing.
			kerbAlongIn = math.min(reach, ((i + 1) / kerbProbes) * reach)
			kerbAlongOut = math.max(0, (i - 1) / kerbProbes) * reach
			break
		end
	end

	-- The apron: flat asphalt from the cut to wherever the island takes over,
	-- or to the kerb if the island never gets to start. Its rungs are the two
	-- arms' own inner edges, so it abuts each arm exactly and overlaps neither -
	-- at the cut the two edges coincide and it tapers to nothing, which is what
	-- an approach with no median should look like. An approach that DOES have
	-- one took the `startAlong = 0` branch above, so no apron is laid at all and
	-- its median continues straight into the raised island.
	local apronEnd = math.min(startAlong, kerbAlongIn)
	if apronEnd > 0 then
		local apronDepth = settings.RoadThicknessStuds
		local prevA, prevB
		for i = 0, APRON_SAMPLES do
			local along = (i / APRON_SAMPLES) * apronEnd
			-- Sunk with the arms. The arms' Parts are dropped ARM_SINK_STUDS
			-- after building but their CURVES are not, so an apron laid on the
			-- curve sits a hair proud of the carriageway it is continuous with -
			-- and, where it runs past the kerb, coplanar with the ring deck.
			local a = goreEdgeAt(entryCurve, along, entryArm, -ARM_SINK_STUDS)
			local b = goreEdgeAt(exitCurve, exitCurve.Length - along, exitArm, -ARM_SINK_STUDS)
			if prevA and prevB then
				FillTriangle(prevA, prevB, b, apronDepth, DOWN, makeApronPart, ring)
				FillTriangle(prevA, b, a, apronDepth, DOWN, makeApronPart, ring)
			end
			prevA, prevB = a, b
		end
	end
	-- The nose: rungs from `taperStart` up to `startAlong`, each one the gore
	-- scaled about its own midline so the island closes to a point. It sits ON
	-- the apron rather than replacing it - the apron is flat asphalt at deck
	-- level and this is raised, so the wedge either side of the nose stays
	-- carriageway, which is what it should be.
	if startAlong > 0 and startAlong < kerbAlongOut then
		local taperStart = math.max(0, startAlong - ISLAND_NOSE_TAPER_M * scale)
		local span = startAlong - taperStart
		if span > 1e-3 then
			local steps = math.max(2, math.ceil(APRON_SAMPLES / 2))
			local prevA, prevB
			for i = 0, steps do
				local t = i / steps
				local along = taperStart + t * span
				local a = goreEdge(entryCurve, along, entryArm)
				local b = goreEdge(exitCurve, exitCurve.Length - along, exitArm)
				local mid = a:Lerp(b, 0.5)
				a, b = mid:Lerp(a, t), mid:Lerp(b, t)
				if prevA and prevB then
					FillTriangle(prevA, prevB, b, depth, DOWN, makeSidewalkPart, ring)
					FillTriangle(prevA, b, a, depth, DOWN, makeSidewalkPart, ring)
				end
				prevA, prevB = a, b
			end
		end
	end

	if startAlong >= reach or startAlong >= kerbAlongOut then
		-- Either the gore never opens to island width, or it only does so past
		-- the kerb. Both mean there is no room for a raised splitter here and
		-- the apron above is the whole mouth.
		return
	end
	local entrySide: { Vector3 } = {}
	local exitSide: { Vector3 } = {}
	local lastAlong = startAlong
	for i = 0, GORE_SAMPLES do
		local along = startAlong + (i / GORE_SAMPLES) * (reach - startAlong)
		local a = goreEdge(entryCurve, along, entryArm)
		local b = goreEdge(exitCurve, exitCurve.Length - along, exitArm)
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
	-- Pavement width on the source approach at the cut. May be zero; the arm's
	-- profile above carries the ring-side width and `buildArm` joins the two.
	CutPavementM: number,
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
		-- The arm's cross-section is mirrored whenever its own travel runs
		-- against the approach curve. The entry runs inward and the exit
		-- outward, and which of those matches the curve depends on which END of
		-- the road the junction sits at - so it is neither "always the exit" nor
		-- a property of the arm alone.
		local profile = armProfileFor(group, solo, style, scale, travelsInward == atStart, ringSidewalkWidthM(style))
		local mergeRadius = ringKerbRadiusStuds - profile.OuterOffsetStuds
		if mergeRadius <= 1 then
			return nil
		end
		-- Land the arm's RUNNING LANES on the very lanes they replace. The shoulder
		-- is outside that alignment and tapers independently; including its width in
		-- the centre calculation is what made a 2-lane highway look like 3 lanes.
		-- An arm running outward
		-- has its own right-of-travel reversed against the inward frame, so its
		-- roadway offset flips with it.
		local spanCentreInward = (group.LeftM + group.RightM) / 2 * toInward
		local coreShiftLocalM = profile.CoreShiftM
		local coreCentreInward = spanCentreInward + coreShiftLocalM * (if travelsInward then 1 else -1)
		local lateralM = if travelsInward
			then coreCentreInward - profile.RoadwayCentreM
			else coreCentreInward + profile.RoadwayCentreM
		return {
			Profile = profile,
			CutPavementM = group.PavementM,
			MergeRadius = mergeRadius,
			LateralStuds = lateralM * scale,
		}
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

-- Angle at which either roadway edge has crossed a target ring radius. Solo
-- one-way mouths use both crossings: their complete carriageway, rather than a
-- centre-to-outboard approximation, owns the opening through each ring band.
--
-- Sample to find the first bracket, then bisect it.  Returning the first sample
-- outside the radius (the old Python-only approximation) leaves a visible
-- several-tenths-of-a-stud step at wide/shallow joins.
local BAND_EXIT_SAMPLES = 96
local function bandEdgeExitAngle(
	curve: PolyCurve.PolyCurve,
	signedOffsetStuds: number,
	fromStation: number,
	away: number,
	center: Vector3,
	targetRadiusStuds: number
): number
	local length = curve.Length
	local function edgeAt(station: number): Vector3
		local position = curve:PosAt(station)
		local tangent = flatUnit(curve:TangentAt(station))
		return position + rightOf(tangent) * signedOffsetStuds
	end
	local function radiusAt(station: number): number
		return distanceXZ(edgeAt(station), center)
	end
	local station = math.clamp(fromStation, 0, length)
	local step = if length > 1e-6 then length / BAND_EXIT_SAMPLES else 0
	if step > 0 and radiusAt(station) <= targetRadiusStuds then
		for _ = 1, BAND_EXIT_SAMPLES do
			local nextStation = math.clamp(station + away * step, 0, length)
			if math.abs(nextStation - station) < 1e-9 then
				break
			end
			if radiusAt(nextStation) > targetRadiusStuds then
				local inside = station
				local outside = nextStation
				for _ = 1, 24 do
					local mid = (inside + outside) / 2
					if radiusAt(mid) > targetRadiusStuds then
						outside = mid
					else
						inside = mid
					end
				end
				station = (inside + outside) / 2
				break
			end
			station = nextStation
		end
	end
	local edge = edgeAt(station)
	return math.atan2(edge.Z - center.Z, edge.X - center.X)
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
	local solo = (plan.Entry == nil) ~= (plan.Exit == nil)
	if solo then
		local arm = (plan.Entry or plan.Exit) :: MouthArm
		local halfWidth = (arm.Profile.OuterOffsetStuds + arm.Profile.InnerOffsetStuds) / 2
		local fitAngle = math.asin(math.clamp(halfWidth / math.max(arm.MergeRadius, 1), 0, 0.95))
		local budgetCap = math.min(SOLO_SPLIT_MAX_RAD, math.max(MIN_SPLIT_RAD, splitBudgetRad - SECTOR_MARGIN_RAD))
		local soloSplit = math.clamp(fitAngle + SOLO_SPLIT_CLEARANCE_RAD, MIN_SPLIT_RAD, budgetCap)
		return soloSplit, soloSplit, plan.Angle + flow * soloSplit, plan.Angle - flow * soloSplit
	end
	local split =
		math.clamp(SPLIT_ANGLE_RAD, MIN_SPLIT_RAD, math.max(MIN_SPLIT_RAD, splitBudgetRad - SECTOR_MARGIN_RAD))
	local entrySplit = if settings.RoundaboutEntryCurve
		then math.max(MIN_SPLIT_RAD, split * ENTRY_SPLIT_SCALE)
		else split
	-- Going round the ring you meet a mouth's EXIT first (upstream, against the
	-- flow) and its ENTRY after (downstream, with it).
	return split, entrySplit, plan.Angle + flow * entrySplit, plan.Angle - flow * split
end

-- One mouth: entry arm, exit arm, splitter island. Paired mouths return an
-- angular pavement sector; solo mouths return nil plus exact roadway cutters.
-- Edge paint remains angular for both because its handoff is a radial ring line.
local function buildMouth(
	ring: Model,
	plan: MouthPlan,
	center: Vector3,
	splitBudgetRad: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): (MouthSector?, MouthSector, ExitTrace?, { ConvexFootprint })
	-- Which way traffic circulates, matching circleSegments' own sign.
	local flow = if style.DriveOnLeft then 1 else -1
	local soloMouth = not (plan.Entry and plan.Exit)
	local collectSoloRoadway = soloMouth and ringSidewalkWidthM(style) > 1e-6
	local soloRoadwayCutters: { ConvexFootprint } = {}
	local dir = plan.Direction
	local side = rightOf(dir)

	local split, entrySplit, entryAngle, exitAngle = resolveSplits(plan, splitBudgetRad, flow, settings)

	local entryCurve: PolyCurve.PolyCurve? = nil
	local exitCurve: PolyCurve.PolyCurve? = nil
	local ringKerbRadius = 0

	local entry = plan.Entry
	if entry then
		local entryRingKerbRadius = entry.MergeRadius + entry.Profile.OuterOffsetStuds
		entryCurve = PolyCurve.new({
			armSegment(
				plan.CutMid + side * entry.LateralStuds,
				dir,
				ringPointAt(center, entryAngle, entry.MergeRadius, plan.CutMid.Y),
				ringTangentAt(entryAngle, flow),
				ARM_HANDLE
			),
		})
		local armModel, roadwayCutters = buildArm(
			entryCurve :: PolyCurve.PolyCurve,
			entry.Profile,
			entry.CutPavementM,
			true,
			center,
			entryRingKerbRadius,
			style,
			settings,
			collectSoloRoadway
		)
		armModel.Parent = ring
		for _, cutter in roadwayCutters do
			table.insert(soloRoadwayCutters, cutter)
		end
		ringKerbRadius = entryRingKerbRadius
	end

	local exit = plan.Exit
	if exit then
		local exitRingKerbRadius = exit.MergeRadius + exit.Profile.OuterOffsetStuds
		exitCurve = PolyCurve.new({
			armSegment(
				ringPointAt(center, exitAngle, exit.MergeRadius, plan.CutMid.Y),
				ringTangentAt(exitAngle, flow),
				plan.CutMid + side * exit.LateralStuds,
				-dir,
				ARM_HANDLE
			),
		})
		local armModel, roadwayCutters = buildArm(
			exitCurve :: PolyCurve.PolyCurve,
			exit.Profile,
			exit.CutPavementM,
			false,
			center,
			exitRingKerbRadius,
			style,
			settings,
			collectSoloRoadway
		)
		armModel.Parent = ring
		for _, cutter in roadwayCutters do
			table.insert(soloRoadwayCutters, cutter)
		end
		ringKerbRadius = exitRingKerbRadius
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
	-- each arm is covered throughout. With only ONE arm there is no island, so
	-- edge paint is opened exactly between that arm's two roadway-edge crossings.
	-- Raised pavement is not represented by a polar sector at all: the caller
	-- subtracts the analytical roadway footprints gathered above, preserving the
	-- curb-return concrete beside the curved arm.
	if not (entry and exit) then
		local only = (entry or exit) :: MouthArm
		local onlyCurve = (entryCurve or exitCurve) :: PolyCurve.PolyCurve
		local fromStation = if entry then onlyCurve.Length else 0
		local away = if entry then -1 else 1
		local outboardOffsetStuds = -only.Profile.OuterOffsetStuds * flow
		local inboardOffsetStuds = only.Profile.InnerOffsetStuds * flow
		local function sectorAtRadius(targetRadiusStuds: number): MouthSector
			local outboardAngle =
				bandEdgeExitAngle(onlyCurve, outboardOffsetStuds, fromStation, away, center, targetRadiusStuds)
			local inboardAngle =
				bandEdgeExitAngle(onlyCurve, inboardOffsetStuds, fromStation, away, center, targetRadiusStuds)
			local sweep = angleDelta(inboardAngle, outboardAngle)
			local half = math.abs(sweep) / 2
			return { Angle = outboardAngle + sweep / 2, Ahead = half, Behind = half }
		end
		local edgeLineRadius = ringKerbRadius - style.MarkingWidthM * 1.5 * settings.MetersToStuds
		local soloTrace: ExitTrace? = if exit and exitCurve
			then { Curve = exitCurve :: PolyCurve.PolyCurve, Arm = exit.Profile }
			else nil
		return nil, sectorAtRadius(edgeLineRadius), soloTrace, soloRoadwayCutters
	end
	-- Open exactly as far as each arm actually reaches, inset so the opening can
	-- never outrun them.
	local hasTaperedShoulder = ((entry :: MouthArm).Profile.CutShoulderM > 1e-6)
		or ((exit :: MouthArm).Profile.CutShoulderM > 1e-6)
	local pavementInset = if hasTaperedShoulder then SHOULDER_SECTOR_INSET_RAD else SECTOR_INSET_RAD
	local entryHalf = math.max(0, entrySplit - pavementInset)
	local exitHalf = math.max(0, split - pavementInset)
	local pavementSector = {
		Angle = plan.Angle,
		Ahead = if flow > 0 then entryHalf else exitHalf,
		Behind = if flow > 0 then exitHalf else entryHalf,
	}
	local edgeMarkingSector = {
		Angle = plan.Angle,
		Ahead = if flow > 0 then entrySplit else split,
		Behind = if flow > 0 then split else entrySplit,
	}
	return pavementSector,
		edgeMarkingSector,
		{ Curve = exitCurve :: PolyCurve.PolyCurve, Arm = (exit :: MouthArm).Profile },
		soloRoadwayCutters
end

-- COMFORTABLE ring radius: one that gives every leg room for its two arms, a
-- deflection split between them, and a strip of kerb before the next leg. Add
-- those up and they must fit in 360 degrees:
--
--   sum(armWidth_i) / R  +  legs * (2*MIN_SPLIT + MIN_KERB_GAP)  <=  2*pi
--
-- This was called MinimumRadiusStuds and used as a hard floor, and it is not
-- one. Sweeping radius against the narrowest DRIVABLE width of the circulating
-- carriageway (`circulating_width` in the preview - bare ground cannot answer
-- this question, because a too-small ring fails by being covered in kerb, not
-- by being empty) the geometry holds all the way down to R=18 on every
-- configuration tested: 4-leg 2+2, 4-leg 1+1, 3-leg 1+1, 5-leg 1+1. Against
-- packing numbers of 70.5, 42.8, 27.5 and 64.2. It is 2-4x too conservative as
-- a floor, which is why it now feeds the SUGGESTION and the real floor is
-- measured separately below.
local function packingRadiusStuds(
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
		-- Written out rather than looped, because the mirror flag differs
		-- between the two and a `{ inbound, outbound }` loop cannot say which
		-- one it is holding. It also silently skipped a nil group by way of
		-- `next`; being explicit costs two lines and hides nothing.
		local function measure(group: LaneGroup?, travelsInward: boolean)
			if not group then
				return
			end
			local arm = armProfileFor(group, solo, style, scale, travelsInward == atStart, ringSidewalkWidthM(style))
			-- FULL width, pavement included. The kerb is what must not overrun
			-- the next mouth's kerb; counting only the roadway lets two mouths
			-- sit a pavement's width inside each other.
			local width = RoadProfile.TotalWidthM(arm.Profile) * scale
			totalArmStuds += width
			widestArmStuds = math.max(widestArmStuds, width)
			outerOffsetStuds = math.max(outerOffsetStuds, arm.OuterOffsetStuds)
		end
		measure(inbound, true)
		measure(outbound, false)
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

-- The HARD floor, and the only number here that deserves the word minimum.
--
-- Below it there is no roundabout, in the literal sense: the ring's own inner
-- edge has passed the centre, so the "annulus" is a self-overlapping disc with
-- no centre island and no circulating lane. A 4-leg 2+2 at R=10 comes out as a
-- four-pointed raised star with a hexagon in the middle. The centre island
-- radius is `radius - ringInnerHalfWidth`, so the floor is that half-width plus
-- enough for an island worth drawing (`buildIsland` itself bails below 1 stud).
--
-- Everything above this held in the sweep, so the failure is a cliff rather
-- than a slope: the packing number above is comfort, this is possibility.
local ISLAND_MIN_RADIUS_STUDS = 2

function RoundaboutBuilder.MinimumRadiusStuds(
	junctionId: string,
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): number
	local profile: RoadProfile.RoadProfile = {
		Id = "roundabout_ring",
		Name = "Roundabout",
		Category = "Custom",
		BuiltIn = false,
		Components = ringComponents(laneCount, laneWidthM, style),
	}
	return ringInnerHalfWidthM(profile, style) * settings.MetersToStuds + ISLAND_MIN_RADIUS_STUDS
end

-- What to actually put in the Radius box. Rounded up to a 5-stud step with a
-- margin so the suggestion looks like a decision rather than a solver output,
-- and never below the hard floor.
local SUGGESTED_RADIUS_HEADROOM = 1.15
local SUGGESTED_RADIUS_STEP_STUDS = 5

function RoundaboutBuilder.SuggestedRadiusStuds(
	junctionId: string,
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): number
	local packing = packingRadiusStuds(junctionId, laneCount, laneWidthM, style, settings)
	local floor = RoundaboutBuilder.MinimumRadiusStuds(junctionId, laneCount, laneWidthM, style, settings)
	local target = math.max(packing, floor)
	if target <= 0 then
		return 0
	end
	return math.ceil(target * SUGGESTED_RADIUS_HEADROOM / SUGGESTED_RADIUS_STEP_STUDS) * SUGGESTED_RADIUS_STEP_STUDS
end

-- Default circulating-lane advice for a junction.  A roundabout serves the
-- widest individual carriageway feeding it, not the sum of both directions
-- and certainly not its shoulders.  Endpoint profiles matter because a road
-- may legitimately widen away from the junction even though editable
-- roundabout conversion will reject that transition until source slicing is
-- implemented.
function RoundaboutBuilder.SuggestedLaneCount(junctionId: string): number
	local suggested = 0
	for _, road in JunctionInstance.ConnectedRoads(junctionId) do
		local data = RoadInstance.Read(road)
		if not data then
			continue
		end
		local atStart = data.StartJunctionId == junctionId
		if not atStart and data.EndJunctionId ~= junctionId then
			continue
		end
		local profile = if atStart then data.ProfileStart else (data.ProfileEnd or data.ProfileStart)
		suggested = math.max(suggested, RoadProfile.MaxMotorLanesPerCarriageway(profile))
	end
	return math.max(1, suggested)
end

type ApproachPreflight = {
	Road: Model,
	Data: RoadInstance.RoadData,
	Source: CurveSegment.Segment,
	LinkedAtStart: boolean,
	CurrentSourceStart: number,
	WindowStart: number,
	WindowEnd: number,
	Plan: MouthPlan,
}

local function editableApproachBlockReason(data: RoadInstance.RoadData): string?
	if data.ProfileEnd ~= nil then
		return "uses a widening/narrowing transition, which editable roundabout trimming does not yet slice safely"
	elseif data.Bay ~= nil then
		return "has a bus bay, which editable roundabout trimming does not yet remap safely"
	elseif #data.MarkingStretches > 0 or #data.KerbStretches > 0 then
		return "has marking or kerb stretches, which must be baked or cleared before roundabout conversion"
	end
	return nil
end

local function prospectiveApproachError(
	source: CurveSegment.Segment,
	currentCurve: PolyCurve.PolyCurve,
	spokeProfile: RoadProfile.RoadProfile,
	linkedAtStart: boolean,
	center: Vector3,
	trimTarget: number,
	ringKerbRadius: number,
	laneWidthM: number,
	ringStyle: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): string?
	local sourceCurve = PolyCurve.new({ source })
	local currentSourceStart = nearestSourceStation(sourceCurve, currentCurve:PosAt(0))
	local currentSourceEnd = nearestSourceStation(sourceCurve, currentCurve:PosAt(currentCurve.Length))
	local crossing = findProfileRingCrossing(
		sourceCurve,
		spokeProfile,
		if linkedAtStart then 0 else sourceCurve.Length,
		if linkedAtStart then sourceCurve.Length else 0,
		center,
		trimTarget,
		settings.MetersToStuds
	)
	if not crossing then
		return "does not reach the requested roundabout trim radius"
	end
	local windowStart = if linkedAtStart then crossing else currentSourceStart
	local windowEnd = if linkedAtStart then currentSourceEnd else crossing
	if windowEnd - windowStart < 2 then
		return "would leave less than 2 studs of usable road"
	end
	local proposedCurve = PolyCurve.new({ CurveSegment.Sub(source, windowStart, windowEnd) })
	local cutStation = if linkedAtStart then 0 else proposedCurve.Length
	local tangent = proposedCurve:TangentAt(cutStation)
	local inward = if linkedAtStart then -tangent else tangent
	inward = Vector3.new(inward.X, 0, inward.Z)
	if inward.Magnitude < 1e-6 then
		return "has no valid inward direction at the controller"
	end
	inward = inward.Unit
	local edges = edgePointsAt(proposedCurve, spokeProfile, cutStation, inward, settings.MetersToStuds)
	if not edges then
		return "has no valid carriageway edge at the trim point"
	end
	local plan = planMouth(
		proposedCurve:PosAt(cutStation),
		edges.Inward,
		spokeProfile,
		linkedAtStart,
		center,
		ringKerbRadius,
		laneWidthM,
		ringStyle,
		settings
	)
	return if plan then nil else "cannot form a valid entry/exit mouth"
end

-- RoadInstance.Read lazily migrates stable road/port identities.  Preflight
-- must leave a failing approach byte-for-byte as it found it, including older
-- roads that have not gone through that migration yet.  Successful apply will
-- stamp the identities normally when rebuildRoadFromSource replaces geometry.
local function readRoadForPreflight(road: Model): RoadInstance.RoadData?
	local roadId = road:GetAttribute("RW_RoadId")
	local startPortId = road:GetAttribute("RW_StartPortId")
	local endPortId = road:GetAttribute("RW_EndPortId")
	local restoreRoadId = typeof(roadId) ~= "string"
	local restoreStartPortId = typeof(startPortId) ~= "string"
	local restoreEndPortId = typeof(endPortId) ~= "string"
	local data = RoadInstance.Read(road)
	if restoreRoadId then
		road:SetAttribute("RW_RoadId", roadId)
	end
	if restoreStartPortId then
		road:SetAttribute("RW_StartPortId", startPortId)
	end
	if restoreEndPortId then
		road:SetAttribute("RW_EndPortId", endPortId)
	end
	return data
end

-- Validate the complete exact topology before CreateAtJunction touches the
-- controller, selected ring, or any connected road.  A previously unreadable
-- approach was silently skipped, yielding a successful rebuild with a missing
-- mouth; editor Apply must instead be all-or-nothing at this boundary.
local function preflightApproaches(
	junctionId: string,
	center: Vector3,
	ringKerbRadius: number,
	trimTarget: number,
	laneWidthM: number,
	ringStyle: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): ({ ApproachPreflight }?, string?)
	local prepared: { ApproachPreflight } = {}
	for index, road in JunctionInstance.ConnectedRoads(junctionId) do
		local label = string.format("approach %d (%s)", index, road.Name)
		local data = readRoadForPreflight(road)
		if not data then
			return nil, label .. " is missing editable road data."
		end
		local blockedReason = editableApproachBlockReason(data)
		if blockedReason then
			return nil, label .. " " .. blockedReason .. "."
		end
		if #data.Curve.Segments ~= 1 then
			return nil, label .. " must have exactly one source segment."
		end
		local linkedAtStart = data.StartJunctionId == junctionId
		local linkedAtEnd = data.EndJunctionId == junctionId
		if linkedAtStart == linkedAtEnd then
			return nil, label .. " is not linked to exactly one controller end."
		end

		local source = RoadSource.ReadSegment(road) or data.Curve.Segments[1]
		local sourceCurve = PolyCurve.new({ source })
		local currentSourceStart = nearestSourceStation(sourceCurve, data.Curve:PosAt(0))
		local currentSourceEnd = nearestSourceStation(sourceCurve, data.Curve:PosAt(data.Curve.Length))
		local spokeProfile = if linkedAtStart then data.ProfileStart else (data.ProfileEnd or data.ProfileStart)
		local crossing = findProfileRingCrossing(
			sourceCurve,
			spokeProfile,
			if linkedAtStart then 0 else sourceCurve.Length,
			if linkedAtStart then sourceCurve.Length else 0,
			center,
			trimTarget,
			settings.MetersToStuds
		)
		if not crossing then
			return nil, label .. " does not reach the requested roundabout trim radius."
		end
		local windowStart = if linkedAtStart then crossing else currentSourceStart
		local windowEnd = if linkedAtStart then currentSourceEnd else crossing
		if windowEnd - windowStart < 2 then
			return nil, label .. " would leave less than 2 studs of usable road."
		end

		local proposedCurve = PolyCurve.new({ CurveSegment.Sub(source, windowStart, windowEnd) })
		local cutStation = if linkedAtStart then 0 else proposedCurve.Length
		local tangent = proposedCurve:TangentAt(cutStation)
		local inward = if linkedAtStart then -tangent else tangent
		inward = Vector3.new(inward.X, 0, inward.Z)
		if inward.Magnitude < 1e-6 then
			return nil, label .. " has no valid inward direction at the controller."
		end
		inward = inward.Unit
		local edges = edgePointsAt(proposedCurve, spokeProfile, cutStation, inward, settings.MetersToStuds)
		if not edges then
			return nil, label .. " has no valid carriageway edge at the trim point."
		end
		local plan = planMouth(
			proposedCurve:PosAt(cutStation),
			edges.Inward,
			spokeProfile,
			linkedAtStart,
			center,
			ringKerbRadius,
			laneWidthM,
			ringStyle,
			settings
		)
		if not plan then
			return nil, label .. " cannot form a valid entry/exit mouth."
		end
		table.insert(prepared, {
			Road = road,
			Data = data,
			Source = source,
			LinkedAtStart = linkedAtStart,
			CurrentSourceStart = currentSourceStart,
			WindowStart = windowStart,
			WindowEnd = windowEnd,
			Plan = plan,
		})
	end
	return prepared, nil
end

function RoundaboutBuilder.CreateAtJunction(
	junctionId: string,
	radiusStuds: number,
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings,
	requestedData: RoundaboutInstance.RoundaboutData?
): (Model?, string?)
	local junctionModel = JunctionInstance.FindById(junctionId)
	if not junctionModel then
		return nil, "The roundabout junction controller no longer exists."
	end
	local junctionData = JunctionInstance.Read(junctionModel)
	if not junctionData then
		return nil, "The roundabout junction controller is unreadable."
	end
	local existingRing = RoundaboutInstance.FindByJunctionId(junctionId)
	local center = junctionData.Position
	local scale = settings.MetersToStuds

	-- Grow rather than build garbage. A radius the approaches cannot fit into
	-- The requested radius is BUILT AS ASKED. `MinimumRadiusStuds` is advice,
	-- surfaced by the panel before the click, not a clamp applied after it.
	--
	-- It used to be a clamp, and that was both wrong for the user - a 12-stud
	-- request and a 40-stud request produced the identical ring, with no
	-- indication why - and wrong on the merits. Measured with the clamp
	-- disabled, the geometry is clean far below the number it was enforcing:
	-- a 3-leg 1+1 ring is clean at R=10..26 against a minimum of 27.5, and a
	-- 4-leg 2+2 ring is clean at R=10..35 against a minimum of 70.5. The
	-- formula is a conservative packing estimate, not a measured failure point.
	--
	-- Small rings do eventually crowd - the split gets squeezed until entry and
	-- exit run up against each other and the splitter pinches - but that
	-- degrades gradually and visibly, which the user can judge for themselves.

	-- Per-roundabout marking override, falling back to the region's default.
	-- Applied by cloning the style rather than threading another argument
	-- through every builder that touches it - `ringComponents` already reads
	-- the style, so this is the narrowest place to inject it.
	local requestedMarkings = if requestedData then requestedData.Markings else junctionData.RoundaboutMarkings
	local requestedSidewalk = if requestedData then requestedData.Sidewalk else junctionData.RoundaboutSidewalk
	local requestedIsland = if requestedData then requestedData.Island else junctionData.RoundaboutIsland
	local ringStyle = styleWithRoundaboutOverrides(style, requestedMarkings, requestedSidewalk, requestedIsland)

	local components = ringComponents(laneCount, laneWidthM, ringStyle)
	local profile: RoadProfile.RoadProfile = {
		Id = "roundabout_ring",
		Name = "Roundabout",
		Category = "Custom",
		BuiltIn = false,
		Components = components,
	}
	local halfWidthStuds = RoadProfile.TotalWidthM(profile) / 2 * scale
	local outerRadiusStuds = radiusStuds + halfWidthStuds
	local ringKerbRadius = outerRadiusStuds - ringSidewalkWidthM(ringStyle) * scale
	local trimTarget = outerRadiusStuds + armRunStuds(outerRadiusStuds)
	local approaches, preflightError =
		preflightApproaches(junctionId, center, ringKerbRadius, trimTarget, laneWidthM, ringStyle, settings)
	if not approaches then
		return nil, "Roundabout rebuild blocked: " .. (preflightError or "approach preflight failed.")
	end

	-- Mutation starts only after every exact connected approach has passed the
	-- source-window, edge and mouth checks above.
	JunctionInstance.SetKind(junctionModel, "Roundabout")
	JunctionInstance.SetRoundaboutGeometry(junctionModel, radiusStuds, laneCount, laneWidthM)
	JunctionInstance.SetRoundaboutMarkings(junctionModel, requestedMarkings)
	JunctionInstance.SetRoundaboutSidewalk(junctionModel, requestedSidewalk)
	JunctionInstance.SetRoundaboutIsland(junctionModel, requestedIsland)
	local stale = junctionModel:FindFirstChild("Geometry")
	if stale then
		stale:Destroy()
	end

	-- ONE continuous ring — never slice (knotted arcs).
	local ringCurve = PolyCurve.new(circleSegments(center, radiusStuds, style.DriveOnLeft))
	local ringOptions = {
		Curve = ringCurve,
		ProfileStart = profile,
		Style = ringStyle,
		Settings = flatSettings(settings),
		Preview = false,
		MarkingLines = roundaboutMarkingLines(profile, ringStyle, ringStyle.RoundaboutMarkings == "SolidLanes"),
		MarkingDashStartsAtZero = true,
	}
	local ring = RoadBuilder.Build(ringOptions)
	ring:SetAttribute("RW_Road", nil)
	ring.Name = "Roundabout"
	stampRingMeta(ring, center, radiusStuds, outerRadiusStuds, laneCount, laneWidthM, junctionId)
	stampRingOverrides(ring, requestedMarkings, requestedSidewalk, requestedIsland)

	-- The ring's OWN outer pavement, captured before any arm parts are parented
	-- in. It is built as one unbroken circle, so without this it runs a
	-- raised kerb + pavement band straight across every entry - the mouth reads
	-- as walled off rather than open ("the mouth still has to open, not close
	-- into it"). Each mouth below reports the angular sector it occupies and we
	-- delete the ring pavement inside it.
	local ringSidewalk: { BasePart } = {}
	local ringMarkings: { BasePart } = {}
	for _, descendant in ring:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name == "Sidewalk" then
			table.insert(ringSidewalk, descendant :: BasePart)
		elseif descendant:IsA("BasePart") and descendant.Name == "Marking" then
			table.insert(ringMarkings, descendant :: BasePart)
		end
	end

	buildIsland(
		ring,
		center,
		radiusStuds,
		profile,
		ringStyle,
		settings,
		ringCurve,
		RoadBuilder.StationsFor(ringOptions)
	)

	-- Apply the already-proved source windows.  The plans were computed from the
	-- same proposed subcurves, so no road can disappear from this second phase.
	local plans: { MouthPlan } = {}
	for _, approach in approaches do
		local rebuilt = rebuildRoadFromSource(
			approach.Road,
			approach.Data,
			approach.Source,
			approach.WindowStart,
			approach.WindowEnd,
			approach.CurrentSourceStart,
			style,
			settings,
			approach.LinkedAtStart
		)
		if not rebuilt then
			ring:Destroy()
			return nil, "Roundabout rebuild failed while applying a preflighted approach."
		end
		table.insert(plans, approach.Plan)
	end

	local mouthSectors: { MouthSector } = {}
	local edgeMarkingSectors: { MouthSector } = {}
	local exitTraces: { ExitTrace } = {}
	local soloRoadwayCutters: { ConvexFootprint } = {}
	for i, plan in plans do
		local sector, edgeSector, trace, roadwayCutters =
			buildMouth(ring, plan, center, splitBudgetFor(plans, i), ringStyle, settings)
		if sector then
			table.insert(mouthSectors, sector)
		end
		table.insert(edgeMarkingSectors, edgeSector)
		if trace then
			table.insert(exitTraces, trace)
		end
		for _, cutter in roadwayCutters do
			table.insert(soloRoadwayCutters, cutter)
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
	local edgeLineInset = ringStyle.MarkingWidthM * 1.5 * scale
	-- Solo curved arms are not polar sectors. Subtract their actual roadway
	-- triangles first, while `ringSidewalk` still contains the original block
	-- footprints; this keeps both curb returns without leaving concrete over the
	-- live carriageway. Inter-mouth kerb separation keeps these fragments clear
	-- of the paired angular openings applied immediately afterward.
	openRingSidewalkByFootprints(ringSidewalk, soloRoadwayCutters)
	openRingPavement(ringSidewalk, center, mouthSectors, 0)
	-- Edge paint has a different physical hand-off from raised pavement. Open
	-- it to the full merge angles so the preserved arm edge line reaches the
	-- same point and tangent; the radial bound keeps all internal dividers.
	openRingPavement(ringMarkings, center, edgeMarkingSectors, ringKerbRadius - edgeLineInset - 0.5, false)

	-- After openRingPavement, deliberately. The spiral is laid only on the arcs
	-- BETWEEN mouths, so there is nothing in a sector for that pass to remove -
	-- and running it first would hand these parts to `ringPavement`, which was
	-- captured before any of them existed.
	if ringStyle.RoundaboutMarkings == "Turbo" then
		local replacements = buildTurboMarkings(
			ring,
			center,
			radiusStuds,
			profile,
			laneCount,
			laneWidthM,
			ringStyle,
			settings,
			exitTraces
		)
		openTurboReplacementArcs(ringMarkings, center, replacements, ringStyle.MarkingWidthM * scale)
	end

	packGeneratedGeometry(ring, true)
	ring.Parent = getRoundaboutsFolder()
	if existingRing and existingRing ~= ring then
		return replaceRoundaboutInPlace(existingRing, ring)
	end
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
	-- Reported, not applied: the build uses the requested radius as asked, so
	-- the dump must too or it describes a ring nobody builds.
	local minimum = RoundaboutBuilder.MinimumRadiusStuds(junctionId, laneCount, laneWidthM, style, settings)
	local grown = radiusStuds

	local components = ringComponents(laneCount, laneWidthM, style)
	local profile: RoadProfile.RoadProfile = {
		Id = "roundabout_ring",
		Name = "Roundabout",
		Category = "Custom",
		BuiltIn = false,
		Components = components,
	}
	local outerRadiusStuds = grown + RoadProfile.TotalWidthM(profile) / 2 * scale
	local ringKerbRadius = outerRadiusStuds - ringSidewalkWidthM(style) * scale
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
		-- Two distances, because the two tests ask different questions.
		--
		-- "Is this road near enough to be an approach?" must use the road's TRUE
		-- nearest approach to the centre, sampled along the curve. Testing only
		-- the endpoints - which is what this did - misses every road whose
		-- closest point is mid-span: a road running past or through where the
		-- roundabout is being placed has both ends far away and was silently
		-- dropped. That is the live "sometimes does not detect existing
		-- connections". A curved approach that bows out before coming back in
		-- was lost the same way.
		--
		-- "Is this road too close to treat as an approach?" keeps using the
		-- ENDPOINT distance. Switching that one to the nearest approach as well
		-- would reject strictly MORE roads rather than fewer - anything passing
		-- through the middle has a nearest approach near zero - which is the
		-- opposite of the bug being fixed.
		local length = data.Curve.Length
		local endpointDist =
			math.min(distanceXZ(data.Curve:PosAt(0), center), distanceXZ(data.Curve:PosAt(length), center))
		local nearestDist = endpointDist
		if length > 1e-3 then
			local samples = math.clamp(math.ceil(length / 4), 8, 256)
			for i = 1, samples - 1 do
				nearestDist = math.min(nearestDist, distanceXZ(data.Curve:PosAt(length * i / samples), center))
			end
		end
		if nearestDist <= maxDist and endpointDist >= minDist then
			table.insert(out, child :: Model)
		end
	end
	return out
end

local function syncControllerFromRing(controller: Model, data: RoundaboutInstance.RoundaboutData)
	JunctionInstance.SetKind(controller, "Roundabout")
	JunctionInstance.SetRoundaboutGeometry(controller, data.RadiusStuds, data.LaneCount, data.LaneWidthM)
	JunctionInstance.SetRoundaboutMarkings(controller, data.Markings)
	JunctionInstance.SetRoundaboutSidewalk(controller, data.Sidewalk)
	JunctionInstance.SetRoundaboutIsland(controller, data.Island)
end

type AttachPlan = {
	Road: Model,
	Data: RoadInstance.RoadData,
	SplitStation: number?,
	AtStart: boolean?,
}

local function attachRoadsToController(
	roads: { Model },
	ringData: RoundaboutInstance.RoundaboutData,
	junctionId: string,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings,
	requestedRoad: Model?
): ({ Model }?, string?)
	-- Passing roads are explicitly split only in connect/adopt flows.  A normal
	-- editor rebuild starts from JunctionInstance.ConnectedRoads and never calls
	-- this helper, so changing a radius cannot silently absorb a nearby road.
	-- Validate every candidate first: an unsplittable interior road must never
	-- fall through and attach an arbitrary far endpoint.
	local plans: { AttachPlan } = {}
	local requestedPlanned = requestedRoad == nil
	local center = ringData.Center
	local outerRadiusStuds = ringData.OuterRadiusStuds
	local ringStyle = styleWithRoundaboutOverrides(style, ringData.Markings, ringData.Sidewalk, ringData.Island)
	local ringKerbRadius = outerRadiusStuds - ringSidewalkWidthM(ringStyle) * settings.MetersToStuds
	local trimTarget = outerRadiusStuds + armRunStuds(outerRadiusStuds)
	for index, road in roads do
		local data = RoadInstance.Read(road)
		if not data then
			return nil, string.format("Nearby road %d (%s) is missing editable road data.", index, road.Name)
		end
		local blockedReason = editableApproachBlockReason(data)
		if blockedReason then
			return nil, string.format("Nearby road %d (%s) %s.", index, road.Name, blockedReason)
		end
		if #data.Curve.Segments ~= 1 then
			return nil, string.format("Nearby road %d (%s) must have exactly one curve segment.", index, road.Name)
		end
		local length = data.Curve.Length
		local station = nearestStation(data.Curve, center)
		local margin = math.min(length / 3, armRunStuds(outerRadiusStuds))
		if station > margin and station < length - margin then
			if data.StartJunctionId ~= nil or data.EndJunctionId ~= nil then
				return nil,
					string.format(
						"Nearby road %d (%s) crosses the roundabout interior but is already connected to another junction.",
						index,
						road.Name
					)
			end
			if not RoadSplit.CanSplitAt(road, station) then
				return nil,
					string.format(
						"Nearby road %d (%s) crosses the roundabout interior but cannot be split: %s.",
						index,
						road.Name,
						RoadSplit.SplitBlockReason(road) or "the cut is too close to an endpoint"
					)
			end
			local originalSegment = data.Curve.Segments[1]
			local firstSource = CurveSegment.Sub(originalSegment, 0, station)
			local secondSource = CurveSegment.Sub(originalSegment, station, length)
			local firstError = prospectiveApproachError(
				firstSource,
				PolyCurve.new({ firstSource }),
				data.ProfileStart,
				false,
				center,
				trimTarget,
				ringKerbRadius,
				ringData.LaneWidthM,
				ringStyle,
				settings
			)
			local secondError = prospectiveApproachError(
				secondSource,
				PolyCurve.new({ secondSource }),
				data.ProfileStart,
				true,
				center,
				trimTarget,
				ringKerbRadius,
				ringData.LaneWidthM,
				ringStyle,
				settings
			)
			if firstError or secondError then
				return nil,
					string.format(
						"Nearby road %d (%s) cannot be split into valid roundabout approaches: %s.",
						index,
						road.Name,
						firstError or secondError
					)
			end
			table.insert(plans, { Road = road, Data = data, SplitStation = station })
		else
			local atStart = ringSideIsStart(road, center)
			if atStart == nil then
				return nil, string.format("Nearby road %d (%s) has no usable endpoint.", index, road.Name)
			end
			local occupied = if atStart then data.StartJunctionId else data.EndJunctionId
			if occupied ~= nil and occupied ~= junctionId then
				return nil,
					string.format("Nearby road %d (%s) is already connected to another junction.", index, road.Name)
			end
			local source = RoadSource.ReadSegment(road) or data.Curve.Segments[1]
			local approachError = prospectiveApproachError(
				source,
				data.Curve,
				if atStart then data.ProfileStart else (data.ProfileEnd or data.ProfileStart),
				atStart,
				center,
				trimTarget,
				ringKerbRadius,
				ringData.LaneWidthM,
				ringStyle,
				settings
			)
			if approachError then
				return nil, string.format("Nearby road %d (%s) %s.", index, road.Name, approachError)
			end
			table.insert(plans, { Road = road, Data = data, AtStart = atStart })
		end
		if road == requestedRoad then
			requestedPlanned = true
		end
	end
	if not requestedPlanned then
		return nil, "The road requested for roundabout snapping was not attachable."
	end

	local approaches: { Model } = {}
	for _, plan in plans do
		if plan.SplitStation then
			local first, second = RoadSplit.SplitAtJunction(plan.Road, plan.SplitStation, junctionId, style, settings)
			if not first or not second then
				return approaches, "A preflighted passing road could not be split. Undo this placement and try again."
			end
			table.insert(approaches, first)
			table.insert(approaches, second)
		else
			if not RoadSource.ReadSegment(plan.Road) then
				RoadSource.WriteSegment(plan.Road, plan.Data.Curve.Segments[1])
			end
			local atStart = plan.AtStart == true
			if atStart then
				RoadInstance.StampJunctions(plan.Road, junctionId, plan.Data.EndJunctionId)
			else
				RoadInstance.StampJunctions(plan.Road, plan.Data.StartJunctionId, junctionId)
			end
			table.insert(approaches, plan.Road)
		end
	end
	return approaches, nil
end

type RestorePreflight = {
	Road: Model,
	Data: RoadInstance.RoadData,
	Source: CurveSegment.Segment,
	AtStart: boolean,
	CurrentSourceStart: number,
	WindowStart: number,
	WindowEnd: number,
}

local function preflightControllerRestore(road: Model, junctionId: string, index: number): (RestorePreflight?, string?)
	local label = string.format("connected road %d (%s)", index, road.Name)
	local data = readRoadForPreflight(road)
	if not data or #data.Curve.Segments ~= 1 then
		return nil, label .. " is missing readable one-segment source data."
	end
	local blockedReason = editableApproachBlockReason(data)
	if blockedReason then
		return nil, label .. " " .. blockedReason .. ". Clear that feature before converting the roundabout."
	end
	local linkedAtStart = data.StartJunctionId == junctionId
	local linkedAtEnd = data.EndJunctionId == junctionId
	if linkedAtStart == linkedAtEnd then
		return nil, label .. " is not linked to exactly one controller end."
	end
	local source = RoadSource.ReadSegment(road) or data.Curve.Segments[1]
	local sourceCurve = PolyCurve.new({ source })
	local currentSourceStart = nearestSourceStation(sourceCurve, data.Curve:PosAt(0))
	local currentSourceEnd = nearestSourceStation(sourceCurve, data.Curve:PosAt(data.Curve.Length))
	local windowStart = if linkedAtStart then 0 else currentSourceStart
	local windowEnd = if linkedAtStart then currentSourceEnd else sourceCurve.Length
	if windowEnd - windowStart < 2 then
		return nil, label .. " would leave less than 2 studs after restoring the controller end."
	end
	return {
		Road = road,
		Data = data,
		Source = source,
		AtStart = linkedAtStart,
		CurrentSourceStart = currentSourceStart,
		WindowStart = windowStart,
		WindowEnd = windowEnd,
	},
		nil
end

local function applyControllerRestore(
	prepared: RestorePreflight,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
)
	local restored = rebuildRoadFromSource(
		prepared.Road,
		prepared.Data,
		prepared.Source,
		prepared.WindowStart,
		prepared.WindowEnd,
		prepared.CurrentSourceStart,
		style,
		settings
	)
	assert(restored ~= nil, "preflighted controller-end restore unexpectedly failed")
end

local function unlinkRestoredControllerEnd(prepared: RestorePreflight): Model
	local restoredData = RoadInstance.Read(prepared.Road)
	assert(restoredData ~= nil, "restored single approach became unreadable")
	if prepared.AtStart then
		RoadInstance.StampJunctions(prepared.Road, nil, restoredData.EndJunctionId)
	else
		RoadInstance.StampJunctions(prepared.Road, restoredData.StartJunctionId, nil)
	end
	return prepared.Road
end

-- Explorer deletion removes the ring independently of the editor conversion
-- command.  Main calls this hook only for the one-road branch: restore the
-- source window, unlink precisely the controller-facing end, and remove the
-- now-orphan controller.  The ring is deliberately not destroyed here.
function RoundaboutBuilder.PrepareForRingRemoval(
	ring: Model,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): (Model?, string?)
	local data = RoundaboutInstance.Read(ring)
	if not data or not data.JunctionId then
		return nil, nil
	end
	local controller = JunctionInstance.FindById(data.JunctionId)
	if not controller then
		return nil, "This roundabout's junction controller is missing."
	end
	local roads = JunctionInstance.ConnectedRoads(data.JunctionId)
	if #roads ~= 1 then
		return nil, nil
	end
	local restore, preflightError = preflightControllerRestore(roads[1], data.JunctionId, 1)
	if not restore then
		return nil, "Ring removal cleanup blocked: " .. (preflightError or "road restore preflight failed.")
	end
	applyControllerRestore(restore, style, settings)
	local restoredRoad = unlinkRestoredControllerEnd(restore)
	controller:Destroy()
	return restoredRoad, "Single approach restored; orphaned roundabout controller removed."
end

function RoundaboutBuilder.Rebuild(
	model: Model,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): (Model?, string?)
	local ring = RoundaboutInstance.FindRoundabout(model)
	local data = if ring then RoundaboutInstance.Read(ring) else nil
	if not ring or not data then
		return nil, "Select an editable EasyRoad roundabout."
	end

	if data.JunctionId then
		local controller = JunctionInstance.FindById(data.JunctionId)
		if not controller then
			return nil, "This roundabout's junction controller is missing."
		end
		local rebuilt, message = RoundaboutBuilder.CreateAtJunction(
			data.JunctionId,
			data.RadiusStuds,
			data.LaneCount,
			data.LaneWidthM,
			style,
			settings,
			data
		)
		return if rebuilt then rebuilt else nil, if rebuilt then nil else (message or "Roundabout rebuild failed.")
	end

	if data.LegacyConnected then
		return nil, "This connected legacy roundabout is read-only; recreate its junction once to use the editor."
	end

	local ringStyle = styleWithRoundaboutOverrides(style, data.Markings, data.Sidewalk, data.Island)
	local built =
		RoundaboutBuilder.Create(data.Center, data.RadiusStuds, data.LaneCount, data.LaneWidthM, ringStyle, settings)
	stampRingOverrides(built, data.Markings, data.Sidewalk, data.Island)
	return replaceRoundaboutInPlace(ring, built), nil
end

function RoundaboutBuilder.AdoptLegacy(
	model: Model,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): (Model?, string?)
	local ring = RoundaboutInstance.FindRoundabout(model)
	local data = if ring then RoundaboutInstance.Read(ring) else nil
	if not ring or not data then
		return nil, "Select an editable EasyRoad roundabout."
	end
	if data.JunctionId then
		return RoundaboutBuilder.Rebuild(ring, style, settings)
	end
	if not data.LegacyConnected then
		return nil, "This roundabout has no legacy connections to adopt."
	end

	-- Old connected rings contain already-shortened feeder geometry but no
	-- recoverable untrimmed road sources. Proximity adoption would make edits
	-- look successful while conversion/radius shrink could never restore those
	-- approaches. Keep them explicitly read-only instead of guessing topology.
	return nil,
		"Legacy connected roundabouts are read-only because their original approach sources cannot be recovered safely. Recreate the junction once to use the editor."
end

function RoundaboutBuilder.ConvertToJunction(
	model: Model,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): (Model?, string?)
	local ring = RoundaboutInstance.FindRoundabout(model)
	local data = if ring then RoundaboutInstance.Read(ring) else nil
	if not ring or not data then
		return nil, "Select an editable EasyRoad roundabout."
	end
	if not data.JunctionId then
		if data.LegacyConnected then
			return nil,
				"This legacy roundabout cannot be converted because its original approach sources are unavailable."
		end
		ring:Destroy()
		return nil, "Standalone roundabout removed."
	end

	local controller = JunctionInstance.FindById(data.JunctionId)
	if not controller then
		return nil, "This roundabout's junction controller is missing."
	end
	local roads = JunctionInstance.ConnectedRoads(data.JunctionId)
	local prepared: { RestorePreflight } = {}
	for index, road in roads do
		local restore, preflightError = preflightControllerRestore(road, data.JunctionId, index)
		if not restore then
			return nil, "Junction conversion blocked: " .. (preflightError or "road restore preflight failed.")
		end
		table.insert(prepared, restore)
	end
	-- No restore starts until the complete exact topology has passed above.
	for _, restore in prepared do
		applyControllerRestore(restore, style, settings)
	end

	if #prepared == 0 then
		ring:Destroy()
		controller:Destroy()
		return nil, "Empty roundabout and controller removed."
	elseif #prepared == 1 then
		local only = prepared[1]
		local restoredRoad = unlinkRestoredControllerEnd(only)
		ring:Destroy()
		controller:Destroy()
		return restoredRoad, "Single approach restored; orphaned roundabout controller removed."
	end
	JunctionInstance.SetKind(controller, "Intersection")
	ring:Destroy()
	JunctionBuilder.TrimApproaches(data.JunctionId, style, settings)
	JunctionBuilder.Rebuild(data.JunctionId, style, settings)
	return controller, nil
end

function RoundaboutBuilder.ConnectRoad(
	ring: Model,
	road: Model,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): (Model?, string?)
	local ringData = RoundaboutInstance.Read(ring)
	if not ringData then
		return nil, "The selected roundabout is unreadable."
	end
	if ringData.LegacyConnected then
		return nil,
			"Legacy connected roundabouts are read-only because their original approach sources cannot be recovered safely. Recreate the junction once to use snapping."
	end

	local controller: Model?
	local roads: { Model }
	local createdController = false
	if ringData.JunctionId then
		controller = JunctionInstance.FindById(ringData.JunctionId)
		if not controller then
			return nil, "The roundabout's topology controller is missing."
		end
		local requestedData = RoadInstance.Read(road)
		if
			requestedData
			and (
				requestedData.StartJunctionId == ringData.JunctionId
				or requestedData.EndJunctionId == ringData.JunctionId
			)
		then
			return ring, nil
		end
		-- An established roundabout has exact topology.  Connecting one newly
		-- snapped road must not absorb every unrelated road in its radius.
		roads = { road }
	else
		controller = JunctionInstance.Create(ringData.Center)
		createdController = true
		local collected = collectNearbyRoads(
			ringData.Center,
			ringData.OuterRadiusStuds + armRunStuds(ringData.OuterRadiusStuds) + settings.SnapRadiusStuds + 8,
			math.max(1, ringData.RadiusStuds * 0.25)
		)
		local hasRequested = false
		for _, candidate in collected do
			if candidate == road then
				hasRequested = true
				break
			end
		end
		if not hasRequested then
			table.insert(collected, road)
		end
		roads = collected
	end

	local controllerData = JunctionInstance.Read(controller :: Model)
	if not controllerData then
		if createdController then
			(controller :: Model):Destroy()
		end
		return nil, "Could not read the roundabout topology controller."
	end
	if ringData.JunctionId then
		local ringStyle = styleWithRoundaboutOverrides(style, ringData.Markings, ringData.Sidewalk, ringData.Island)
		local ringKerbRadius = ringData.OuterRadiusStuds - ringSidewalkWidthM(ringStyle) * settings.MetersToStuds
		local trimTarget = ringData.OuterRadiusStuds + armRunStuds(ringData.OuterRadiusStuds)
		local existingApproaches, existingError = preflightApproaches(
			controllerData.Id,
			ringData.Center,
			ringKerbRadius,
			trimTarget,
			ringData.LaneWidthM,
			ringStyle,
			settings
		)
		if not existingApproaches then
			return nil,
				"Connect blocked until the existing roundabout approaches are repaired: "
					.. (existingError or "approach preflight failed.")
		end
	end
	local approaches, attachError = attachRoadsToController(roads, ringData, controllerData.Id, style, settings, road)
	if not approaches or attachError then
		if approaches then
			for _, approach in approaches do
				local data = RoadInstance.Read(approach)
				if data then
					RoadInstance.StampJunctions(
						approach,
						if data.StartJunctionId == controllerData.Id then nil else data.StartJunctionId,
						if data.EndJunctionId == controllerData.Id then nil else data.EndJunctionId
					)
				end
			end
		end
		if createdController then
			(controller :: Model):Destroy()
		end
		return nil, attachError or "No road approach could be attached to this roundabout."
	end

	local previousJunctionId = ring:GetAttribute("RW_JunctionId")
	local previousLegacy = ring:GetAttribute("RW_LegacyConnected")
	syncControllerFromRing(controller :: Model, ringData)
	ring:SetAttribute("RW_JunctionId", controllerData.Id)
	ring:SetAttribute("RW_LegacyConnected", false)
	local ok, rebuilt, rebuildMessage = pcall(function()
		return RoundaboutBuilder.CreateAtJunction(
			controllerData.Id,
			ringData.RadiusStuds,
			ringData.LaneCount,
			ringData.LaneWidthM,
			style,
			settings
		)
	end)
	if ok and rebuilt then
		return rebuilt, nil
	end

	-- Normal CreateAtJunction rejection is mutation-free. Detach only the
	-- approaches introduced by this connect transaction and restore the ring's
	-- prior ownership metadata; split pieces remain safe independent roads.
	for _, approach in approaches do
		local data = RoadInstance.Read(approach)
		if data then
			RoadInstance.StampJunctions(
				approach,
				if data.StartJunctionId == controllerData.Id then nil else data.StartJunctionId,
				if data.EndJunctionId == controllerData.Id then nil else data.EndJunctionId
			)
		end
	end
	ring:SetAttribute("RW_JunctionId", previousJunctionId)
	ring:SetAttribute("RW_LegacyConnected", previousLegacy)
	if createdController then
		(controller :: Model):Destroy()
	end
	return nil, tostring(if ok then rebuildMessage else rebuilt)
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
): (Model, string?)
	local ring = RoundaboutBuilder.Create(center, radiusStuds, laneCount, laneWidthM, style, settings)
	local outerR = ring:GetAttribute("RW_OuterRadius") :: number?
	if not outerR then
		return ring, "Roundabout placed, but its outer radius metadata was unavailable for auto-connect."
	end
	local nearby = collectNearbyRoads(
		center,
		outerR + armRunStuds(outerR) + settings.SnapRadiusStuds + 8,
		math.max(1, radiusStuds * 0.25)
	)
	if #nearby == 0 then
		return ring, nil
	end
	local connected, message = RoundaboutBuilder.ConnectRoad(ring, nearby[1], style, settings)
	if connected then
		return connected, nil
	end
	return ring, "Roundabout placed standalone; nearby roads were not changed. " .. (message or "Auto-connect failed.")
end

return RoundaboutBuilder
