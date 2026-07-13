--!strict
-- Roundabout: continuous ring (never sliced) + setback + FillTriangle feeds.
--
-- Ring is always ONE full RoadBuilder circle — never Hermite "entry roads"
-- parented onto it (those knot the annulus). Feed-in/out is pure edge
-- geometry: sample Hermite left/right kerb paths from the setback cut to the
-- ring, fill asphalt between them, sidewalk bands outside them.

local CurveSegment = require("../Geometry/CurveSegment")
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
-- Pull spokes back so feed curves have length (studs past ring outer edge).
local SETBACK_STUDS = 14
local FEED_SAMPLES = 10
local DOWN = Vector3.new(0, -1, 0)

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
	local crossing = findProfileRingCrossing(
		curve,
		data.ProfileStart,
		fromStation,
		towardStation,
		center,
		targetRadiusStuds,
		scale
	)
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

-- Sample a cubic Hermite from p0→p1 with travel dirs d0/d1 (unit).
local function sampleHermite(p0: Vector3, d0: Vector3, p1: Vector3, d1: Vector3, samples: number): { Vector3 }
	local flat0 = Vector3.new(d0.X, 0, d0.Z)
	local flat1 = Vector3.new(d1.X, 0, d1.Z)
	if flat0.Magnitude < 1e-6 or flat1.Magnitude < 1e-6 then
		return { p0, p1 }
	end
	local chord = Vector3.new(p1.X - p0.X, 0, p1.Z - p0.Z).Magnitude
	local handle = math.max(chord * 0.4, 1)
	local m0 = flat0.Unit * handle
	local m1 = flat1.Unit * handle
	local points: { Vector3 } = table.create(samples + 1)
	for i = 0, samples do
		local t = i / samples
		local t2 = t * t
		local t3 = t2 * t
		local h00 = 2 * t3 - 3 * t2 + 1
		local h10 = t3 - 2 * t2 + t
		local h01 = -2 * t3 + 3 * t2
		local h11 = t3 - t2
		local y = p0.Y + (p1.Y - p0.Y) * t
		local x = p0.X * h00 + m0.X * h10 + p1.X * h01 + m1.X * h11
		local z = p0.Z * h00 + m0.Z * h10 + p1.Z * h01 + m1.Z * h11
		table.insert(points, Vector3.new(x, y, z))
	end
	return points
end

local function circulationTan(center: Vector3, point: Vector3, driveOnLeft: boolean): Vector3
	local dx, dz = point.X - center.X, point.Z - center.Z
	local mag = math.sqrt(dx * dx + dz * dz)
	if mag < 1e-6 then
		return Vector3.new(1, 0, 0)
	end
	local sign = if driveOnLeft then -1 else 1
	return Vector3.new(-dz / mag * sign, 0, dx / mag * sign)
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
	local kerbLeftM, kerbRightM = roadwayEdgeOffsetsM(profile)
	local outerKerbM = if style.DriveOnLeft then kerbRightM else kerbLeftM
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	local outerSidewalkM = if style.DriveOnLeft then offsets[#offsets].Right else offsets[1].Left

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
	buildIsland(ring, center, radiusStuds, profile, style, settings)

	-- Setback: full cross-section beyond outer pavement so feeds have length.
	local trimTarget = outerRadiusStuds + SETBACK_STUDS
	type Mouth = { Edges: SpokeCutEdges, SLeft: number, SRight: number }
	local mouths: { Mouth } = {}

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
		local sLeft = ringCurve:ClosestS(edges.LeftOuter)
		local sRight = ringCurve:ClosestS(edges.RightOuter)
		table.insert(mouths, { Edges = edges, SLeft = sLeft, SRight = sRight })
	end

	local thickness = settings.RoadThicknessStuds
	local curbHeight = style.CurbHeightM * scale
	local sidewalkDepth = thickness + curbHeight
	local sink = Vector3.new(0, -0.015, 0)

	local function raise(p: Vector3): Vector3
		return p + Vector3.new(0, curbHeight, 0)
	end
	local function makeAsphalt(): Part
		local p = Instance.new("Part")
		p.Name = "RoundaboutFeed"
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.CastShadow = false
		p.Material = Enum.Material.Asphalt
		p.Color = style.AsphaltColor
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		return p
	end
	local function makeSidewalk(): Part
		local p = Instance.new("Part")
		p.Name = "RoundaboutFeedSidewalk"
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.CastShadow = false
		p.Material = Enum.Material.Concrete
		p.Color = style.SidewalkColor
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		return p
	end
	local function ringAt(station: number, offsetM: number): Vector3
		return (ringCurve:FrameAt(station) * CFrame.new(offsetM * scale, 0, 0)).Position
	end
	local function ringTanAt(station: number): Vector3
		local t = ringCurve:TangentAt(station)
		return Vector3.new(t.X, 0, t.Z)
	end

	for _, mouth in mouths do
		local e = mouth.Edges
		local rKerbL = ringAt(mouth.SLeft, outerKerbM)
		local rKerbR = ringAt(mouth.SRight, outerKerbM)
		local rOuterL = ringAt(mouth.SLeft, outerSidewalkM)
		local rOuterR = ringAt(mouth.SRight, outerSidewalkM)

		-- Arrive along the ring tangent that faces the mouth (into the gap).
		local tanL = ringTanAt(mouth.SLeft)
		local tanR = ringTanAt(mouth.SRight)
		if tanL.Magnitude > 1e-6 then
			tanL = tanL.Unit
		else
			tanL = e.Inward
		end
		if tanR.Magnitude > 1e-6 then
			tanR = tanR.Unit
		else
			tanR = e.Inward
		end
		-- Orient arrival so travel continues from spoke inward into the ring.
		local toRingL = Vector3.new(rKerbL.X - e.LeftKerb.X, 0, rKerbL.Z - e.LeftKerb.Z)
		local toRingR = Vector3.new(rKerbR.X - e.RightKerb.X, 0, rKerbR.Z - e.RightKerb.Z)
		if toRingL.Magnitude > 1e-3 and tanL:Dot(toRingL) < 0 then
			tanL = -tanL
		end
		if toRingR.Magnitude > 1e-3 and tanR:Dot(toRingR) < 0 then
			tanR = -tanR
		end

		-- Feed-in/out edge curves (Hermite): setback cut → ring, curved.
		local leftKerb = sampleHermite(e.LeftKerb, e.Inward, rKerbL, tanL, FEED_SAMPLES)
		local rightKerb = sampleHermite(e.RightKerb, e.Inward, rKerbR, tanR, FEED_SAMPLES)
		local leftOuter = sampleHermite(e.LeftOuter, e.Inward, rOuterL, tanL, FEED_SAMPLES)
		local rightOuter = sampleHermite(e.RightOuter, e.Inward, rOuterR, tanR, FEED_SAMPLES)
		local n = math.min(#leftKerb, #rightKerb, #leftOuter, #rightOuter)
		if n < 2 then
			continue
		end

		-- Asphalt deck between left/right kerb curves.
		for i = 1, n - 1 do
			local a0 = leftKerb[i] + sink
			local a1 = leftKerb[i + 1] + sink
			local b0 = rightKerb[i] + sink
			local b1 = rightKerb[i + 1] + sink
			FillTriangle(a0, a1, b1, thickness, DOWN, makeAsphalt, ring)
			FillTriangle(a0, b1, b0, thickness, DOWN, makeAsphalt, ring)
		end
		-- Sidewalk patches outside each kerb curve.
		for i = 1, n - 1 do
			FillTriangle(
				raise(leftOuter[i]),
				raise(leftOuter[i + 1]),
				raise(leftKerb[i + 1]),
				sidewalkDepth,
				DOWN,
				makeSidewalk,
				ring
			)
			FillTriangle(
				raise(leftOuter[i]),
				raise(leftKerb[i + 1]),
				raise(leftKerb[i]),
				sidewalkDepth,
				DOWN,
				makeSidewalk,
				ring
			)
			FillTriangle(
				raise(rightOuter[i]),
				raise(rightKerb[i]),
				raise(rightKerb[i + 1]),
				sidewalkDepth,
				DOWN,
				makeSidewalk,
				ring
			)
			FillTriangle(
				raise(rightOuter[i]),
				raise(rightKerb[i + 1]),
				raise(rightOuter[i + 1]),
				sidewalkDepth,
				DOWN,
				makeSidewalk,
				ring
			)
		end
	end

	ring.Parent = getRoundaboutsFolder()
	JunctionInstance.Delete(junctionModel)
	return ring
end

function RoundaboutBuilder.FindNear(
	pos: Vector3,
	snapRadiusStuds: number
): (Model?, Vector3?, Vector3?)
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
		if d <= outerR + snapRadiusStuds then
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
		local dNear = math.min(
			distanceXZ(data.Curve:PosAt(0), center),
			distanceXZ(data.Curve:PosAt(data.Curve.Length), center)
		)
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

return RoundaboutBuilder
