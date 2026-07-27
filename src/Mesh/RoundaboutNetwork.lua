--!strict
-- Roundabout as a NETWORK of ordinary roads + junctions, not one bespoke node.
--
-- Motivated by real grade-separated interchanges (e.g. M20 J4): the entry and
-- exit are separate ONE-WAY arms meeting the circulating carriageway at
-- DIFFERENT points, with a splitter island between them - a shape a single
-- procedural ring node cannot express. Building it out of the plugin's normal
-- primitives also means every piece stays individually selectable and
-- editable, and junction geometry is whatever `JunctionBuilder` produces
-- rather than a parallel implementation.
--
-- Topology, for N approaches:
--   * each approach contributes TWO ring connection points - an EXIT upstream
--     (against the flow) and an ENTRY downstream, +/- `SPLIT_ANGLE` either
--     side of the approach's own radial
--   * the ring becomes 2N ONE-WAY arc roads running between consecutive
--     connection points, in the circulating direction
--   * each connection point is an ordinary 3-way junction (arriving ring arc,
--     departing ring arc, and the arm)
--   * arms are one-way roads that meet the ring TANGENTIALLY - a cubic with
--     both end tangents pinned, so an entry merges into the circulating
--     direction instead of butting into it
--
-- `RoundaboutBuilder` (the single-node ring) is left alone; this is the
-- "build me a real interchange" path, and its output is plain roads.

local CurveSegment = require("../Geometry/CurveSegment")
local PolyCurve = require("../Geometry/PolyCurve")
local RoadBuilder = require("./RoadBuilder")
local RoadInstance = require("../RoadInstance")
local RoadProfile = require("../RoadProfile")
local JunctionInstance = require("../JunctionInstance")
local JunctionBuilder = require("./JunctionBuilder")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")

local RoundaboutNetwork = {}

-- How far either side of an approach's radial its exit/entry connect. Wide
-- enough that the two arms are clearly separate roads with an island between
-- them, tight enough that adjacent approaches keep a ring arc between them.
local SPLIT_ANGLE_RAD = math.rad(22)
-- Where the two-way approach splits into the two one-way arms, measured out
-- from the ring's outer edge. The arms need real length to reach the ring
-- tangentially - too short and the cubic becomes a hairpin.
local ARM_RUN_STUDS = 52

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
	local handle = (p1 - p0).Magnitude / 3
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
	table.insert(components, 1, { Kind = "Sidewalk", WidthM = style.SidewalkWidthM, Direction = 0 })
	table.insert(components, { Kind = "Sidewalk", WidthM = style.SidewalkWidthM, Direction = 0 })
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

	local folder = Instance.new("Folder")
	folder.Name = "RoundaboutNetwork"
	folder.Parent = workspace

	-- Connection points: exit upstream, entry downstream of each approach.
	type Conn = { Angle: number, IsEntry: boolean, Approach: Approach }
	local conns: { Conn } = {}
	for _, approach in approaches do
		table.insert(conns, {
			Angle = approach.Angle - flow * SPLIT_ANGLE_RAD,
			IsEntry = false,
			Approach = approach,
		})
		table.insert(conns, {
			Angle = approach.Angle + flow * SPLIT_ANGLE_RAD,
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

	-- A junction node at every connection point.
	local nodes: { Model } = {}
	local nodeIds: { string } = {}
	for _, conn in conns do
		local pos = Vector3.new(
			center.X + math.cos(conn.Angle) * radiusStuds,
			center.Y,
			center.Z + math.sin(conn.Angle) * radiusStuds
		)
		local node = JunctionInstance.Create(pos)
		local data = JunctionInstance.Read(node)
		table.insert(nodes, node)
		table.insert(nodeIds, if data then data.Id else "")
	end

	-- Ring arcs between consecutive connection points, running with the flow.
	for i = 1, #conns do
		local j = if i < #conns then i + 1 else 1
		local a0, a1 = conns[i].Angle, conns[j].Angle
		local sweep = flow * (norm(flow * (a1 - a0)))
		if math.abs(sweep) < 1e-4 then
			continue
		end
		local segment = arcSegment(center, radiusStuds, a0, sweep, center.Y)
		local arc = buildRoad(segment, ring, "RingArc", style, settings, folder)
		RoadInstance.StampJunctions(arc, nodeIds[i], nodeIds[j])
	end

	-- Entry / exit arms.
	for index, conn in conns do
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
		local offset = perp * ((armHalf + 1.5) * flow)
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
		local road = buildRoad(segment, arm, name, style, settings, folder)
		if conn.IsEntry then
			RoadInstance.StampJunctions(road, nil, nodeIds[index])
		else
			RoadInstance.StampJunctions(road, nodeIds[index], nil)
		end
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

	-- Now that every road references its nodes, let the normal junction
	-- builder produce each 3-way's pad and curb returns.
	for _, id in nodeIds do
		if id ~= "" then
			JunctionBuilder.Rebuild(id, style, settings)
		end
	end

	return folder
end

return RoundaboutNetwork
