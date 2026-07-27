--!strict
-- Roundabout composed from ordinary ONE-WAY roads, not one bespoke ring node.
--
-- Motivated by real grade-separated interchanges (e.g. M20 J4): the entry and
-- exit are separate one-way arms meeting the circulating carriageway at
-- DIFFERENT points, with a splitter island between them - a shape a single
-- procedural ring node cannot express. Building it from normal primitives also
-- means every piece stays individually selectable and editable.
--
-- Topology, for N approaches:
--   * each approach contributes TWO ring connection points - an EXIT upstream
--     (against the flow) and an ENTRY downstream, +/- SPLIT_ANGLE_RAD either
--     side of the approach's own radial
--   * the ring is 2N one-way arc roads between consecutive connection points,
--     running with the flow. Consecutive arcs share an endpoint AND a tangent,
--     so the circulating carriageway is CONTINUOUS while each arc stays
--     separately editable
--   * arms are one-way roads meeting the ring TANGENTIALLY - a cubic with both
--     end tangents pinned - so an entry merges into the circulating direction
--     instead of butting into it
--
-- Deliberately NO junction nodes on the ring. A junction would either trim the
-- arcs back to a pad boundary (breaking the carriageway into disconnected
-- pieces) or, since JunctionBuilder.Rebuild deliberately does not trim, stamp
-- a pad on top of an already-continuous ring. Neither is wanted here: the ring
-- must read as one unbroken loop.
--
-- `RoundaboutBuilder` (the single-node ring) is left alone; this is the
-- "build me a real interchange" path, and its output is plain roads.

local CurveSegment = require("../Geometry/CurveSegment")
local PolyCurve = require("../Geometry/PolyCurve")
local RoadBuilder = require("./RoadBuilder")
local RoadInstance = require("../RoadInstance")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")

local RoundaboutNetwork = {}

-- How far either side of an approach's radial its exit/entry connect. Wide
-- enough that the two arms are clearly separate roads with an island between
-- them, tight enough that adjacent approaches keep a ring arc between them.
local SPLIT_ANGLE_RAD = math.rad(30)
-- Where the two-way approach splits into the two one-way arms, measured out
-- from the ring's outer edge. Slip roads are LONG sweeping curves on a real
-- interchange; a short run gives a stubby arm that barely bends before it
-- reaches the ring.
local ARM_RUN_STUDS = 120
-- Tangent handle as a fraction of the arm's chord, and how far apart the two
-- arms start either side of the approach centreline.
--
-- The handle is what gives a slip its sweep, but it CANNOT be raised freely:
-- the arm's far tangent runs along the ring (i.e. sideways), so `p1 - t1*h`
-- walks the second control point ACROSS the approach as `h` grows. At 0.55 it
-- lands on the far side and the entry and exit arms swing through each other -
-- measured as an actual centreline intersection at every leg. Swept
-- run/handle/split/offset: 0.33 with these companions gives the most bow
-- (~19 studs) while keeping the arms a full width apart (~43 studs).
local ARM_HANDLE = 0.33
-- Verified clean (no crossing, arms a full width apart) for 3-6 legs. Beyond
-- that the ring is over-subscribed - 2N arms simply do not fit the
-- circumference - and the radius has to grow with the leg count.
local ARM_OFFSET_SCALE = 2.4

local function flatUnit(v: Vector3): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-6 then
		return flat
	end
	return flat.Unit
end

-- Exact-ish cubic Bezier for a circular arc: handle length k = (4/3)tan(θ/4)r.
local function arcSegment(center: Vector3, radius: number, a0: number, sweep: number, y: number): CurveSegment.Segment
	local function at(angle: number): Vector3
		return Vector3.new(center.X + math.cos(angle) * radius, y, center.Z + math.sin(angle) * radius)
	end
	local function tangent(angle: number): Vector3
		local sign = if sweep >= 0 then 1 else -1
		return Vector3.new(-math.sin(angle), 0, math.cos(angle)) * sign
	end
	local a1 = a0 + sweep
	local handle = (4 / 3) * math.tan(math.abs(sweep) / 4) * radius
	local p0, p3 = at(a0), at(a1)
	return CurveSegment.Cubic(p0, p0 + tangent(a0) * handle, p3 - tangent(a1) * handle, p3)
end

-- Cubic with BOTH end tangents pinned, so an arm leaves the approach along the
-- road and arrives on the ring along the circulating direction.
local function tangentSegment(p0: Vector3, t0: Vector3, p1: Vector3, t1: Vector3): CurveSegment.Segment
	local handle = (p1 - p0).Magnitude * ARM_HANDLE
	return CurveSegment.Cubic(p0, p0 + flatUnit(t0) * handle, p1 - flatUnit(t1) * handle, p1)
end

-- One-way ring cross-section: `laneCount` lanes all running the same way, with
-- the pavement on the OUTER side (left of travel for right-hand drive, since
-- the ring is walked anticlockwise).
local function ringProfile(
	laneCount: number,
	laneWidthM: number,
	style: RegionStyles.RegionStyle
): RoadProfile.RoadProfile
	local components: { RoadProfile.ProfileComponent } = {}
	for _ = 1, math.max(1, math.floor(laneCount)) do
		table.insert(components, { Kind = "Drive", WidthM = laneWidthM, Direction = 1 })
	end
	local pavement: RoadProfile.ProfileComponent = { Kind = "Sidewalk", WidthM = style.SidewalkWidthM, Direction = 0 }
	if style.DriveOnLeft then
		table.insert(components, pavement)
	else
		table.insert(components, 1, pavement)
	end
	return {
		Id = "roundabout_ring_arc",
		Name = "Ring",
		Category = "Custom",
		BuiltIn = false,
		Components = components,
	}
end

-- One-way arm cross-section carrying half an approach's roadway.
--
-- Pavement on the OUTER side ONLY. An arm merges into the ring travelling WITH
-- the flow, so its outer side is the same side as the ring's own pavement and
-- its inner side opens straight onto the circulating carriageway. Giving the
-- arm a second, inner sidewalk lays a raised strip right across the ring at
-- every merge, which chops the circulating band into disconnected arcs - the
-- reported "roundabout isn't continuous".
local function armProfile(
	approach: RoadProfile.RoadProfile?,
	laneWidthM: number,
	style: RegionStyles.RegionStyle
): RoadProfile.RoadProfile
	local lanes = 1
	if approach then
		local drive = 0
		for _, component in approach.Components do
			if RoadProfile.IsRoadway(component.Kind) then
				drive += 1
			end
		end
		lanes = math.max(1, math.floor(drive / 2))
	end
	local components: { RoadProfile.ProfileComponent } = {}
	for _ = 1, lanes do
		table.insert(components, { Kind = "Drive", WidthM = laneWidthM, Direction = 1 })
	end
	-- Same side as the ring's pavement (see ringProfile): index 1 is the
	-- leftmost component, and left is outward when travelling with the flow.
	local pavement: RoadProfile.ProfileComponent = { Kind = "Sidewalk", WidthM = style.SidewalkWidthM, Direction = 0 }
	if style.DriveOnLeft then
		table.insert(components, pavement)
	else
		table.insert(components, 1, pavement)
	end
	return {
		Id = "roundabout_arm",
		Name = "Arm",
		Category = "Custom",
		BuiltIn = false,
		Components = components,
	}
end

local function buildRoad(
	segment: CurveSegment.Segment,
	profile: RoadProfile.RoadProfile,
	name: string,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings,
	parent: Instance
): Model
	local flat = table.clone(settings)
	flat.SuperelevationMode = "Off"
	local model = RoadBuilder.Build({
		Curve = PolyCurve.new({ segment }),
		ProfileStart = profile,
		Style = style,
		Settings = flat,
		Preview = false,
	})
	model.Name = name
	-- Stamped as a genuine road so it is selectable, editable and splittable
	-- like anything else the user drew.
	RoadInstance.StampModel(model, segment, profile)
	model.Parent = parent
	return model
end

export type Approach = {
	Angle: number, -- radians, direction from the centre out to the approach
	Profile: RoadProfile.RoadProfile?, -- the two-way road being served
}

-- Approach directions taken from roads already near `center`, so dropping an
-- interchange onto an existing junction serves the roads that are actually
-- there. Falls back to nothing, and the caller supplies default legs.
function RoundaboutNetwork.ApproachesFromNearbyRoads(center: Vector3, maxDistStuds: number): { Approach }
	local out: { Approach } = {}
	local roads = workspace:FindFirstChild("Roads")
	if not roads then
		return out
	end
	for _, child in roads:GetChildren() do
		if child:GetAttribute("RW_Road") ~= true or not child:IsA("Model") then
			continue
		end
		local data = RoadInstance.Read(child)
		if not data then
			continue
		end
		local startPos = data.Curve:PosAt(0)
		local endPos = data.Curve:PosAt(data.Curve.Length)
		local near = if (startPos - center).Magnitude <= (endPos - center).Magnitude then startPos else endPos
		local offset = flatUnit(near - center)
		if offset.Magnitude < 1e-6 or (near - center).Magnitude > maxDistStuds then
			continue
		end
		table.insert(out, { Angle = math.atan2(offset.Z, offset.X), Profile = data.ProfileStart })
	end
	return out
end

-- `count` legs spread evenly, for a standalone interchange with nothing to
-- serve yet.
function RoundaboutNetwork.DefaultApproaches(count: number): { Approach }
	local out: { Approach } = {}
	local n = math.max(1, math.floor(count))
	for i = 0, n - 1 do
		table.insert(out, { Angle = (i / n) * 2 * math.pi, Profile = nil })
	end
	return out
end

-- Lays out the whole interchange and returns the folder holding it.
function RoundaboutNetwork.Create(
	center: Vector3,
	radiusStuds: number,
	ringLanes: number,
	laneWidthM: number,
	approaches: { Approach },
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): Folder?
	if #approaches == 0 then
		return nil
	end
	local scale = settings.MetersToStuds
	local ring = ringProfile(ringLanes, laneWidthM, style)
	local ringHalf = RoadProfile.TotalWidthM(ring) / 2 * scale
	local outerRadius = radiusStuds + ringHalf
	-- Matches circleSegments' own convention: +1 (increasing angle) for
	-- right-hand drive, -1 for left-hand.
	local flow = if style.DriveOnLeft then -1 else 1

	-- With N evenly spaced legs the connections must stay inside their own
	-- share of the circle: 2*split < 2pi/N, so cap at 35% of the spacing.
	local splitAngle = math.min(SPLIT_ANGLE_RAD, 0.35 * (2 * math.pi / #approaches))

	local folder = Instance.new("Folder")
	folder.Name = "RoundaboutNetwork"
	folder.Parent = workspace

	-- Connection points: exit upstream, entry downstream of each approach.
	type Conn = { Angle: number, IsEntry: boolean, Approach: Approach }
	local conns: { Conn } = {}
	for _, approach in approaches do
		table.insert(conns, {
			Angle = approach.Angle - flow * splitAngle,
			IsEntry = false,
			Approach = approach,
		})
		table.insert(conns, {
			Angle = approach.Angle + flow * splitAngle,
			IsEntry = true,
			Approach = approach,
		})
	end
	local function norm(a: number): number
		return a % (2 * math.pi)
	end
	table.sort(conns, function(a, b)
		return norm(a.Angle) < norm(b.Angle)
	end)

	-- NO junction nodes on the ring. A junction would either trim the arcs
	-- back to a pad boundary (breaking the circulating carriageway into
	-- disconnected pieces) or, since Rebuild deliberately does not trim, stamp
	-- a pad ON TOP of an already-continuous ring. Instead the arcs simply abut:
	-- consecutive arcs share an endpoint AND a tangent, so the ring reads as
	-- one unbroken carriageway while each arc stays separately editable, and
	-- the arms merge into it tangentially.

	-- Ring arcs between consecutive connection points, running with the flow.
	for i = 1, #conns do
		local j = if i < #conns then i + 1 else 1
		local a0, a1 = conns[i].Angle, conns[j].Angle
		local sweep = flow * (norm(flow * (a1 - a0)))
		if math.abs(sweep) < 1e-4 then
			continue
		end
		local segment = arcSegment(center, radiusStuds, a0, sweep, center.Y)
		buildRoad(segment, ring, "RingArc", style, settings, folder)
	end

	-- Entry / exit arms.
	for _, conn in conns do
		local approach = conn.Approach
		local a = approach.Angle
		local inward = Vector3.new(-math.cos(a), 0, -math.sin(a))
		-- Left of travel; the inbound half of a right-hand-drive approach sits
		-- on the opposite side, which is also the side the downstream
		-- connection lies on - keeping entry and exit from crossing.
		local perp = Vector3.new(-inward.Z, 0, inward.X)
		local arm = armProfile(approach.Profile, laneWidthM, style)
		local armHalf = RoadProfile.TotalWidthM(arm) / 2 * scale
		local splitRadius = outerRadius + ARM_RUN_STUDS
		local splitMid =
			Vector3.new(center.X + math.cos(a) * splitRadius, center.Y, center.Z + math.sin(a) * splitRadius)
		local offset = perp * ((armHalf + 1.5) * ARM_OFFSET_SCALE * flow)
		local ringPoint = Vector3.new(
			center.X + math.cos(conn.Angle) * radiusStuds,
			center.Y,
			center.Z + math.sin(conn.Angle) * radiusStuds
		)
		local ringTangent = Vector3.new(-math.sin(conn.Angle), 0, math.cos(conn.Angle)) * flow

		local segment: CurveSegment.Segment
		local name: string
		if conn.IsEntry then
			segment = tangentSegment(splitMid - offset, inward, ringPoint, ringTangent)
			name = "EntryArm"
		else
			segment = tangentSegment(ringPoint, ringTangent, splitMid + offset, -inward)
			name = "ExitArm"
		end
		buildRoad(segment, arm, name, style, settings, folder)
	end

	-- Central island, sized to the ring's inner edge.
	local islandRadius = radiusStuds - ringHalf
	if islandRadius > 1 then
		local curbHeight = style.CurbHeightM * scale
		local thickness = settings.RoadThicknessStuds
		local island = Instance.new("Part")
		island.Name = "Island"
		island.Anchored = true
		island.CanCollide = false
		island.CanTouch = false
		island.CanQuery = false
		island.CastShadow = false
		island.TopSurface = Enum.SurfaceType.Smooth
		island.BottomSurface = Enum.SurfaceType.Smooth
		island.Material = Enum.Material.Grass
		island.Color = style.SidewalkColor
		island.Shape = Enum.PartType.Cylinder
		island.Size = Vector3.new(thickness + curbHeight, islandRadius * 2, islandRadius * 2)
		island.CFrame = CFrame.new(center + Vector3.new(0, curbHeight - (thickness + curbHeight) / 2, 0))
			* CFrame.Angles(0, 0, math.rad(90))
		island.Parent = folder
	end

	return folder
end

return RoundaboutNetwork
