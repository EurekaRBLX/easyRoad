--!strict
-- Generates a roundabout as a POLAR annulus: one continuous circulating
-- ring (drive always full-circle; outer sidewalk off only in angular entry
-- sectors), spokes trimmed to the outer pavement edge, mouth joins via
-- circular fillets only.
--
-- Deliberately NOT: large setback + Hermite feed cubics as second roads +
-- exclusion intervals derived from feed outer ClosestS. That stack produced
-- knotted partial rings (live screenshots). True tangential feed-in later
-- should deflect the spoke centreline itself, not add ring-owned feeds.

local CurveSegment = require("../Geometry/CurveSegment")
local Fillet = require("../Geometry/Fillet")
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
-- Spoke outermost edge lands just inside the ring outer pavement radius.
local RING_TRIM_MARGIN_STUDS = 1.5
-- Extra angular pad on each side of a mouth when opening the ring sidewalk.
local MOUTH_ANGLE_EPSILON = 0.04 -- radians (~2.3°)
local FLARE_RADIUS_M = 8
local FLARE_ARC_SAMPLES = 4
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
	local sidewalkComponent: RoadProfile.ProfileComponent =
		{ Kind = "Sidewalk", WidthM = style.SidewalkWidthM, Direction = 0 }
	if style.DriveOnLeft then
		table.insert(components, sidewalkComponent)
	else
		table.insert(components, 1, sidewalkComponent)
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

local function findRingCrossing(
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
	local d0 = distanceXZ(data.Curve:PosAt(0), center)
	local d1 = distanceXZ(data.Curve:PosAt(data.Curve.Length), center)
	return d0 <= d1
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
	local halfWidth = RoadProfile.TotalWidthM(profile) / 2 * scale
	return {
		LeftKerb = worldPoint(kerbLeftM),
		LeftOuter = worldPoint(outerLeftM),
		RightKerb = worldPoint(kerbRightM),
		RightOuter = worldPoint(outerRightM),
		Inward = flatIn.Unit,
		HalfWidthStuds = halfWidth,
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

-- Trim spoke so its outermost cross-section edge sits at targetRadius (outer
-- pavement + small margin). Returns mouth edges at the cut.
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
	local halfWidthStuds = RoadProfile.TotalWidthM(data.ProfileStart) / 2 * settings.MetersToStuds
	local trimRadiusStuds =
		math.max(0, math.sqrt(math.max(0, targetRadiusStuds ^ 2 - halfWidthStuds ^ 2)) - RING_TRIM_MARGIN_STUDS)
	local curve = data.Curve
	local fromStation = if atStart then 0 else curve.Length
	local towardStation = if atStart then curve.Length else 0
	local crossing = findRingCrossing(curve, fromStation, towardStation, center, trimRadiusStuds)
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
	return edgePointsAt(newData.Curve, profile, cutStation, inward.Unit, settings.MetersToStuds)
end

-- Map a world point's polar angle around centre to ring curve station by
-- ClosestS (handles Bezier circle approximation; more robust than raw θ).
local function mouthStation(curve: PolyCurve.PolyCurve, point: Vector3): number
	return curve:ClosestS(point)
end

-- Station half-span for sidewalk exclusion from spoke half-width at outer R.
local function mouthHalfStation(curveLength: number, halfWidthStuds: number, outerRadiusStuds: number): number
	if outerRadiusStuds < 1e-3 then
		return curveLength * 0.05
	end
	local alpha = math.asin(math.clamp(halfWidthStuds / outerRadiusStuds, 0, 0.99))
	local arc = (alpha + MOUTH_ANGLE_EPSILON) * outerRadiusStuds
	-- Convert arc length approx to station on the closed ring (centreline
	-- length ≈ 2π R_ring; outer arc is longer - use centreline fraction).
	local fraction = (alpha + MOUTH_ANGLE_EPSILON) / (2 * math.pi)
	return math.clamp(curveLength * fraction, 1, curveLength * 0.2)
end

local function normalizeInterval(lo: number, hi: number, length: number): { { Lo: number, Hi: number } }
	lo = lo % length
	hi = hi % length
	if lo < 0 then
		lo += length
	end
	if hi < 0 then
		hi += length
	end
	if hi < lo then
		-- wraps seam
		return { { Lo = lo, Hi = length }, { Lo = 0, Hi = hi } }
	end
	if hi - lo > length / 2 then
		-- pathologically wide; clamp to half
		local mid = (lo + hi) / 2
		local half = length / 4
		return { { Lo = mid - half, Hi = mid + half } }
	end
	return { { Lo = lo, Hi = hi } }
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

	local staleGeometry = junctionModel:FindFirstChild("Geometry")
	if staleGeometry then
		staleGeometry:Destroy()
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
	-- Trim target: outer pavement edge (no large structural setback).
	local trimTarget = outerRadiusStuds + RING_TRIM_MARGIN_STUDS
	local curve = PolyCurve.new(circleSegments(center, radiusStuds, style.DriveOnLeft))

	local kerbLeftM, kerbRightM = roadwayEdgeOffsetsM(profile)
	local outerKerbM = if style.DriveOnLeft then kerbRightM else kerbLeftM
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	local outerSidewalkM = if style.DriveOnLeft then offsets[#offsets].Right else offsets[1].Left

	type FlareAnchor = { Station: number, Kerb: Vector3, Outer: Vector3, Inward: Vector3 }
	local exclusions: { { Lo: number, Hi: number } } = {}
	local flares: { FlareAnchor } = {}

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
		local mid = (edges.LeftKerb + edges.RightKerb) * 0.5
		local sMid = mouthStation(curve, mid)
		local halfS = mouthHalfStation(curve.Length, edges.HalfWidthStuds, outerRadiusStuds)
		for _, interval in normalizeInterval(sMid - halfS, sMid + halfS, curve.Length) do
			table.insert(exclusions, interval)
		end
		local sLeft = mouthStation(curve, edges.LeftOuter)
		local sRight = mouthStation(curve, edges.RightOuter)
		table.insert(flares, { Station = sLeft, Kerb = edges.LeftKerb, Outer = edges.LeftOuter, Inward = edges.Inward })
		table.insert(flares, { Station = sRight, Kerb = edges.RightKerb, Outer = edges.RightOuter, Inward = edges.Inward })
	end

	table.sort(exclusions, function(a, b)
		return a.Lo < b.Lo
	end)
	-- Merge overlapping sidewalk exclusions so we never double-walk inverted spans.
	local merged: { { Lo: number, Hi: number } } = {}
	for _, ex in exclusions do
		if #merged == 0 or ex.Lo > merged[#merged].Hi then
			table.insert(merged, { Lo = ex.Lo, Hi = ex.Hi })
		else
			merged[#merged].Hi = math.max(merged[#merged].Hi, ex.Hi)
		end
	end
	exclusions = merged

	local ring = Instance.new("Model")
	ring.Name = "Roundabout"

	local ringSettings = flatSettings(settings)
	local sidewalkIndices = { if style.DriveOnLeft then #components else 1 }
	local function buildSpan(fromStation: number, toStation: number, excludeSidewalks: boolean)
		if toStation - fromStation < 1e-3 then
			return
		end
		local piece = RoadBuilder.Build({
			Curve = curve:Slice(fromStation, toStation),
			ProfileStart = profile,
			Style = style,
			Settings = ringSettings,
			Preview = false,
			ExcludeComponentIndices = if excludeSidewalks then sidewalkIndices else nil,
		})
		for _, child in piece:GetChildren() do
			child.Parent = ring
		end
		piece:Destroy()
	end

	local cursor = 0
	for _, exclusion in exclusions do
		local lo = math.max(exclusion.Lo, cursor)
		local hi = math.max(exclusion.Hi, lo)
		buildSpan(cursor, lo, false)
		buildSpan(lo, hi, true) -- drive continues; sidewalk only off
		cursor = hi
	end
	buildSpan(cursor, curve.Length, false)

	stampRingMeta(ring, center, radiusStuds, outerRadiusStuds, laneCount, laneWidthM)
	buildIsland(ring, center, radiusStuds, profile, style, settings)

	-- Mouth corner fillets only (decoration on continuous ring).
	local thickness = settings.RoadThicknessStuds
	local curbHeight = style.CurbHeightM * scale
	local sidewalkDepth = thickness + curbHeight
	local sink = Vector3.new(0, -0.02, 0)
	local function raise(point: Vector3): Vector3
		return point + Vector3.new(0, curbHeight, 0)
	end
	local function makeAsphaltPart(): Part
		local part = Instance.new("Part")
		part.Name = "RoundaboutFlare"
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Material = Enum.Material.Asphalt
		part.Color = style.AsphaltColor
		return part
	end
	local function makeSidewalkPart(): Part
		local part = Instance.new("Part")
		part.Name = "RoundaboutMouthSidewalk"
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
	local function ringPointAt(station: number, offsetM: number): Vector3
		local frame = curve:FrameAt(station)
		return (frame * CFrame.new(offsetM * scale, 0, 0)).Position
	end

	for _, flare in flares do
		local ringKerb = ringPointAt(flare.Station, outerKerbM)
		local toSpoke = Vector3.new(flare.Kerb.X - ringKerb.X, 0, flare.Kerb.Z - ringKerb.Z)
		local tangent = curve:TangentAt(flare.Station)
		tangent = Vector3.new(tangent.X, 0, tangent.Z)
		if toSpoke.Magnitude > 1e-3 and tangent.Magnitude > 1e-6 then
			tangent = tangent.Unit
			local inwardRing = if tangent:Dot(toSpoke) >= 0 then tangent else -tangent
			local p1, arcCenter, p2, arcRadius =
				Fillet.Compute(flare.Kerb, flare.Inward, ringKerb, inwardRing, FLARE_RADIUS_M * scale)
			if p1 and arcCenter and p2 and arcRadius then
				local boundary: { Vector3 } = { flare.Kerb + sink, p1 + sink }
				for _, point in Fillet.SampleArc(arcCenter, arcRadius, p1, p2, FLARE_ARC_SAMPLES) do
					table.insert(boundary, point + sink)
				end
				table.insert(boundary, p2 + sink)
				table.insert(boundary, ringKerb + sink)
				for j = 1, #boundary - 1 do
					FillTriangle(boundary[1], boundary[j], boundary[j + 1], thickness, DOWN, makeAsphaltPart, ring)
				end
				local ringOuter = ringPointAt(flare.Station, outerSidewalkM)
				local outerBoundary: { Vector3 } = { flare.Outer }
				local kerbBoundary: { Vector3 } = { flare.Kerb, p1 }
				for _, point in Fillet.SampleArc(arcCenter, arcRadius, p1, p2, FLARE_ARC_SAMPLES) do
					table.insert(kerbBoundary, point)
				end
				table.insert(kerbBoundary, p2)
				table.insert(kerbBoundary, ringKerb)
				for j = 2, #kerbBoundary - 1 do
					local t = (j - 1) / (#kerbBoundary - 1)
					table.insert(outerBoundary, flare.Outer:Lerp(ringOuter, t))
				end
				table.insert(outerBoundary, ringOuter)
				for j = 1, #kerbBoundary - 1 do
					FillTriangle(
						raise(outerBoundary[j]),
						raise(kerbBoundary[j]),
						raise(kerbBoundary[j + 1]),
						sidewalkDepth,
						DOWN,
						makeSidewalkPart,
						ring
					)
					FillTriangle(
						raise(outerBoundary[j]),
						raise(kerbBoundary[j + 1]),
						raise(outerBoundary[j + 1]),
						sidewalkDepth,
						DOWN,
						makeSidewalkPart,
						ring
					)
				end
			end
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
		local center = child:GetAttribute("RW_Center") :: Vector3?
		local outerR = child:GetAttribute("RW_OuterRadius") :: number?
		if not center or not outerR then
			continue
		end
		local d = distanceXZ(pos, center)
		if d <= outerR + snapRadiusStuds then
			local score = math.abs(d - outerR)
			if score < bestScore then
				bestScore = score
				local radial = Vector3.new(pos.X - center.X, 0, pos.Z - center.Z)
				if radial.Magnitude < 1e-6 then
					radial = Vector3.new(1, 0, 0)
				else
					radial = radial.Unit
				end
				best = child :: Model
				bestAttach = Vector3.new(center.X + radial.X * outerR, center.Y, center.Z + radial.Z * outerR)
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
		local d0 = distanceXZ(data.Curve:PosAt(0), center)
		local d1 = distanceXZ(data.Curve:PosAt(data.Curve.Length), center)
		local dNear = math.min(d0, d1)
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
	local maxDist = outerR + settings.SnapRadiusStuds + 8
	local minDist = math.max(1, radiusStuds * 0.25)
	local roads = collectNearbyRoads(center, maxDist, minDist)
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
