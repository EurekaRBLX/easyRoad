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

-- Max ground-plane distance from `center` of the profile's centerline and
-- both true outer edges at station `s`. Pythagorean half-width trim only
-- works for RADIAL approaches (cut perpendicular to a ray from centre). A
-- curved spoke's frame is skewed, so outer edges can sit well outside the
-- ring while the centerline is "inside" - live triangle gap between a flat
-- cut and the ring. Measuring the real outer points fixes that.
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
	-- fromStation is near the junction (inside); toward is far (outside).
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

-- Trim spoke so its FULL cross-section (outer edges) sits at targetRadius.
-- Returns mouth edges at the cut.
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

local function mouthStation(curve: PolyCurve.PolyCurve, point: Vector3): number
	return curve:ClosestS(point)
end

-- Short-arc station interval from sA to sB on a closed ring (never the long way).
local function shortArcInterval(sA: number, sB: number, length: number): { { Lo: number, Hi: number } }
	local lo, hi = sA, sB
	local forward = (hi - lo) % length
	if forward < 0 then
		forward += length
	end
	if forward > length / 2 then
		-- swap so we walk the short way: from hi to lo wrapping
		return {
			{ Lo = hi, Hi = length },
			{ Lo = 0, Hi = lo },
		}
	end
	if hi < lo then
		return {
			{ Lo = lo, Hi = length },
			{ Lo = 0, Hi = hi },
		}
	end
	-- pad slightly so sidewalk opens a hair past the true outer edges
	local pad = math.min(length * 0.01, 1.5)
	lo = math.max(0, lo - pad)
	hi = math.min(length, hi + pad)
	return { { Lo = lo, Hi = hi } }
end

local function sampleRingStations(sA: number, sB: number, length: number, samples: number): { number }
	local forward = (sB - sA) % length
	if forward < 0 then
		forward += length
	end
	local backward = length - forward
	local delta = if forward <= backward then forward else -backward
	local out: { number } = {}
	for i = 0, samples do
		local t = i / samples
		local s: number
		if i == 0 then
			s = sA
		elseif i == samples then
			s = sB
		else
			s = (sA + delta * t) % length
			if s < 0 then
				s += length
			end
		end
		table.insert(out, s)
	end
	return out
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
	-- Full-profile outer edge lands on the ring outer pavement (margin is
	-- inside the bisection target so the cut sits flush, not short).
	local trimTarget = outerRadiusStuds - 0.25
	local curve = PolyCurve.new(circleSegments(center, radiusStuds, style.DriveOnLeft))

	local kerbLeftM, kerbRightM = roadwayEdgeOffsetsM(profile)
	local outerKerbM = if style.DriveOnLeft then kerbRightM else kerbLeftM
	local offsets = RoadProfile.ComponentOffsetsM(profile)
	local outerSidewalkM = if style.DriveOnLeft then offsets[#offsets].Right else offsets[1].Left

	type FlareAnchor = { Station: number, Kerb: Vector3, Outer: Vector3, Inward: Vector3 }
	type Mouth = {
		Edges: SpokeCutEdges,
		SLeft: number,
		SRight: number,
	}
	local exclusions: { { Lo: number, Hi: number } } = {}
	local flares: { FlareAnchor } = {}
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
		-- Exclusion + mouth fill use REAL outer/kerb stations (short arc),
		-- not mid ± asin(halfWidth) which only fits radial approaches.
		local sLeft = mouthStation(curve, edges.LeftOuter)
		local sRight = mouthStation(curve, edges.RightOuter)
		for _, interval in shortArcInterval(sLeft, sRight, curve.Length) do
			table.insert(exclusions, interval)
		end
		table.insert(mouths, { Edges = edges, SLeft = sLeft, SRight = sRight })
		table.insert(flares, { Station = sLeft, Kerb = edges.LeftKerb, Outer = edges.LeftOuter, Inward = edges.Inward })
		table.insert(flares, { Station = sRight, Kerb = edges.RightKerb, Outer = edges.RightOuter, Inward = edges.Inward })
	end

	table.sort(exclusions, function(a, b)
		return a.Lo < b.Lo
	end)
	local merged: { { Lo: number, Hi: number } } = {}
	for _, ex in exclusions do
		if #merged == 0 or ex.Lo > merged[#merged].Hi + 1e-3 then
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
		buildSpan(lo, hi, true)
		cursor = hi
	end
	buildSpan(cursor, curve.Length, false)

	stampRingMeta(ring, center, radiusStuds, outerRadiusStuds, laneCount, laneWidthM)
	buildIsland(ring, center, radiusStuds, profile, style, settings)

	local thickness = settings.RoadThicknessStuds
	local curbHeight = style.CurbHeightM * scale
	local sidewalkDepth = thickness + curbHeight
	local sink = Vector3.new(0, -0.02, 0)
	local function raise(point: Vector3): Vector3
		return point + Vector3.new(0, curbHeight, 0)
	end
	local function makeAsphaltPart(): Part
		local part = Instance.new("Part")
		part.Name = "RoundaboutMouth"
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
	local function makeFlarePart(): Part
		local part = makeAsphaltPart()
		part.Name = "RoundaboutFlare"
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

	-- Mouth asphalt: ruled band spoke kerb cut → ring outer kerb arc.
	-- Closes the triangle gap when the cut is flat and the ring is curved,
	-- and when Fillet.Compute returns nil on near-radial mouths.
	local MOUTH_SAMPLES = 6
	for _, mouth in mouths do
		local stations = sampleRingStations(mouth.SLeft, mouth.SRight, curve.Length, MOUTH_SAMPLES)
		local n = #stations
		if n >= 2 then
			for i = 1, n - 1 do
				local t0 = (i - 1) / (n - 1)
				local t1 = i / (n - 1)
				local a0 = mouth.Edges.LeftKerb:Lerp(mouth.Edges.RightKerb, t0) + sink
				local a1 = mouth.Edges.LeftKerb:Lerp(mouth.Edges.RightKerb, t1) + sink
				local r0 = ringPointAt(stations[i], outerKerbM) + sink
				local r1 = ringPointAt(stations[i + 1], outerKerbM) + sink
				FillTriangle(a0, a1, r1, thickness, DOWN, makeAsphaltPart, ring)
				FillTriangle(a0, r1, r0, thickness, DOWN, makeAsphaltPart, ring)
			end
		end
	end

	-- Corner fillets + sidewalk bridges (when geometry allows).
	for _, flare in flares do
		local ringKerb = ringPointAt(flare.Station, outerKerbM)
		local ringOuter = ringPointAt(flare.Station, outerSidewalkM)
		local toSpoke = Vector3.new(flare.Kerb.X - ringKerb.X, 0, flare.Kerb.Z - ringKerb.Z)
		local tangent = curve:TangentAt(flare.Station)
		tangent = Vector3.new(tangent.X, 0, tangent.Z)
		local filleted = false
		if toSpoke.Magnitude > 1e-3 and tangent.Magnitude > 1e-6 then
			tangent = tangent.Unit
			local inwardRing = if tangent:Dot(toSpoke) >= 0 then tangent else -tangent
			local p1, arcCenter, p2, arcRadius =
				Fillet.Compute(flare.Kerb, flare.Inward, ringKerb, inwardRing, FLARE_RADIUS_M * scale)
			if p1 and arcCenter and p2 and arcRadius then
				filleted = true
				local boundary: { Vector3 } = { flare.Kerb + sink, p1 + sink }
				for _, point in Fillet.SampleArc(arcCenter, arcRadius, p1, p2, FLARE_ARC_SAMPLES) do
					table.insert(boundary, point + sink)
				end
				table.insert(boundary, p2 + sink)
				table.insert(boundary, ringKerb + sink)
				for j = 1, #boundary - 1 do
					FillTriangle(boundary[1], boundary[j], boundary[j + 1], thickness, DOWN, makeFlarePart, ring)
				end
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
		if not filleted then
			-- Straight sidewalk bridge when fillet degenerates.
			FillTriangle(
				raise(flare.Outer),
				raise(flare.Kerb),
				raise(ringKerb),
				sidewalkDepth,
				DOWN,
				makeSidewalkPart,
				ring
			)
			FillTriangle(
				raise(flare.Outer),
				raise(ringKerb),
				raise(ringOuter),
				sidewalkDepth,
				DOWN,
				makeSidewalkPart,
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
