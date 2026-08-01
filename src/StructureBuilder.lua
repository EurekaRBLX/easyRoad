--!strict
-- Repeats imported rigid Models along a placed road. Without a custom asset it
-- builds a concrete viaduct deck/parapets or a tunnel base/walls/arched vault;
-- viaduct piers are projected vertically down to Terrain/world parts.

local Workspace = game:GetService("Workspace")

local PolyCurve = require("./Geometry/PolyCurve")
local RoadInstance = require("./RoadInstance")
local RoadProfile = require("./RoadProfile")
local Settings = require("./Settings")
local StructureAssets = require("./StructureAssets")

local GENERATED_NAME = "EasyRoadStructure"
local EPSILON = 0.05
local MAX_MODULES = 2000
local MAX_PIERS = 1000
local MAX_PROCEDURAL_PARTS = 6000
local TUNNEL_ARCH_SEGMENTS = 9
local DEFAULT_CONCRETE_HEX = "#696B70"

local StructureBuilder = {}

function StructureBuilder.ColorFromHex(value: string?): Color3
	local hex = if value then value:match("^#?(%x%x%x%x%x%x)$") else nil
	if not hex then
		hex = DEFAULT_CONCRETE_HEX:sub(2)
	end
	local parsed = hex :: string
	return Color3.fromRGB(
		tonumber(parsed:sub(1, 2), 16) or 105,
		tonumber(parsed:sub(3, 4), 16) or 107,
		tonumber(parsed:sub(5, 6), 16) or 112
	)
end

function StructureBuilder.ColorToHex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.round(color.R * 255),
		math.round(color.G * 255),
		math.round(color.B * 255)
	)
end

function StructureBuilder.DefaultData(settings: Settings.EasyRoadSettings?): RoadInstance.StructureData
	return {
		Mode = "None",
		AssetId = nil,
		ModuleOffsetM = 0,
		AutoPillars = true,
		PillarSpacingM = 18,
		PillarWidthM = 1.8,
		PillarDepthM = 1.8,
		MaxPillarHeightM = 200,
		ConcreteColorHex = if settings then settings.StructureConcreteColorHex else DEFAULT_CONCRETE_HEX,
		InterfaceOverlapM = if settings then settings.StructureInterfaceOverlapM else 0.2,
		ViaductParapetGapM = if settings then settings.ViaductParapetGapM else 0,
		TunnelWallClearanceM = if settings then settings.TunnelWallClearanceM else 0.75,
		ConcreteMedian = if settings then settings.ElevatedMedianConcrete else true,
	}
end

function StructureBuilder.CloneData(data: RoadInstance.StructureData): RoadInstance.StructureData
	return {
		Mode = data.Mode,
		AssetId = data.AssetId,
		ModuleOffsetM = data.ModuleOffsetM,
		AutoPillars = data.AutoPillars,
		PillarSpacingM = data.PillarSpacingM,
		PillarWidthM = data.PillarWidthM,
		PillarDepthM = data.PillarDepthM,
		MaxPillarHeightM = data.MaxPillarHeightM,
		ConcreteColorHex = data.ConcreteColorHex,
		InterfaceOverlapM = data.InterfaceOverlapM,
		ViaductParapetGapM = data.ViaductParapetGapM,
		TunnelWallClearanceM = data.TunnelWallClearanceM,
		ConcreteMedian = data.ConcreteMedian,
	}
end

function StructureBuilder.Clear(road: Model)
	local existing = road:FindFirstChild(GENERATED_NAME)
	if existing then
		existing:Destroy()
	end
end

local function flatFrameAt(position: Vector3, look: Vector3): CFrame
	local forward = Vector3.new(look.X, 0, look.Z)
	if forward.Magnitude < 1e-6 then
		forward = Vector3.new(0, 0, -1)
	else
		forward = forward.Unit
	end
	local right = forward:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-6 then
		right = Vector3.xAxis
	else
		right = right.Unit
	end
	return CFrame.fromMatrix(position, right, Vector3.yAxis, -forward)
end

local function safeLookAt(position: Vector3, target: Vector3, preferredUp: Vector3): CFrame
	local forward = target - position
	if forward.Magnitude < 1e-6 then
		return CFrame.new(position)
	end
	forward = forward.Unit
	local up = preferredUp
	if up.Magnitude < 1e-6 or math.abs(up.Unit:Dot(forward)) > 0.98 then
		up = if math.abs(Vector3.yAxis:Dot(forward)) < 0.98 then Vector3.yAxis else Vector3.xAxis
	end
	return CFrame.lookAt(position, position + forward, up)
end

-- Finds the next station whose straight chord from `startStation` matches the
-- rigid module's socket length. On a curve this is slightly farther than one
-- module of arc length, which is exactly what prevents socket gaps.
local function advanceByChord(curve: PolyCurve.PolyCurve, startStation: number, chordLength: number): number
	local length = curve.Length
	if startStation >= length then
		return length
	end
	local startPos = curve:PosAt(startStation)
	local lo = startStation
	local hi = math.min(length, startStation + chordLength * 1.25 + 2)
	while hi < length and (curve:PosAt(hi) - startPos).Magnitude < chordLength do
		hi = math.min(length, startStation + (hi - startStation) * 1.75)
	end
	if (curve:PosAt(hi) - startPos).Magnitude < chordLength then
		return length
	end
	for _ = 1, 28 do
		local mid = (lo + hi) / 2
		if (curve:PosAt(mid) - startPos).Magnitude < chordLength then
			lo = mid
		else
			hi = mid
		end
	end
	return hi
end

local function retreatByChord(curve: PolyCurve.PolyCurve, endStation: number, chordLength: number): number
	local endPos = curve:PosAt(endStation)
	local lo = math.max(0, endStation - chordLength * 1.75 - 2)
	local hi = endStation
	while lo > 0 and (endPos - curve:PosAt(lo)).Magnitude < chordLength do
		lo = math.max(0, endStation - (endStation - lo) * 1.75)
	end
	if (endPos - curve:PosAt(lo)).Magnitude < chordLength then
		return 0
	end
	for _ = 1, 28 do
		local mid = (lo + hi) / 2
		if (endPos - curve:PosAt(mid)).Magnitude > chordLength then
			lo = mid
		else
			hi = mid
		end
	end
	return hi
end

local function moduleRanges(curve: PolyCurve.PolyCurve, moduleLength: number): { { number } }
	local ranges: { { number } } = {}
	if curve.Length < EPSILON then
		return ranges
	end
	if (curve:PosAt(curve.Length) - curve:PosAt(0)).Magnitude < moduleLength and curve.Length < moduleLength * 1.1 then
		return { { 0, curve.Length } }
	end
	local station = 0
	while station < curve.Length - EPSILON and #ranges < MAX_MODULES do
		local nextStation = advanceByChord(curve, station, moduleLength)
		if nextStation <= station + EPSILON then
			break
		end
		if nextStation >= curve.Length - EPSILON then
			local lastStart = retreatByChord(curve, curve.Length, moduleLength)
			local previousStart = if #ranges > 0 then ranges[#ranges][1] else -math.huge
			if lastStart > previousStart + EPSILON then
				table.insert(ranges, { lastStart, curve.Length })
			elseif #ranges == 0 then
				table.insert(ranges, { 0, curve.Length })
			end
			break
		end
		table.insert(ranges, { station, nextStation })
		station = nextStation
	end
	return ranges
end

local function makeGeneratedModel(): Model
	local model = Instance.new("Model")
	model.Name = GENERATED_NAME
	model:SetAttribute("RW_StructureGenerated", true)
	return model
end

local function placeModules(
	parent: Model,
	curve: PolyCurve.PolyCurve,
	template: Model,
	offsetStuds: number
): (number, string?)
	local startSocket = StructureAssets.FindSocket(template, "EasyRoadStart")
	local endSocket = StructureAssets.FindSocket(template, "EasyRoadEnd")
	if not startSocket or not endSocket then
		return 0, "The stored asset is missing EasyRoadStart/EasyRoadEnd sockets. Re-import it."
	end
	local sourceStart = startSocket.WorldPosition
	local sourceEnd = endSocket.WorldPosition
	local moduleLength = (sourceEnd - sourceStart).Magnitude
	if moduleLength < 0.1 then
		return 0, "The stored asset's sockets overlap."
	end
	local sourceFrame = safeLookAt(sourceStart, sourceEnd, startSocket.WorldCFrame.UpVector)
	local pivotRelative = sourceFrame:ToObjectSpace(template:GetPivot())
	local ranges = moduleRanges(curve, moduleLength)
	local modules = Instance.new("Folder")
	modules.Name = "Modules"
	modules.Parent = parent

	for index, range in ranges do
		local s0, s1 = range[1], range[2]
		local p0, p1 = curve:PosAt(s0), curve:PosAt(s1)
		local middleFrame = curve:FrameAt((s0 + s1) / 2)
		local targetFrame = safeLookAt(p0, p1, middleFrame.UpVector)
		targetFrame = targetFrame + middleFrame.UpVector * offsetStuds
		local clone = template:Clone()
		clone.Name = string.format("Module_%04d", index)
		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
			elseif descendant:IsA("BaseScript") then
				-- Importing literal geometry must not multiply and execute a source
				-- Model's scripts once per tiled module. ModuleScripts remain
				-- available as data but do not execute on their own.
				descendant.Enabled = false
			end
		end
		clone:PivotTo(targetFrame * pivotRelative)
		clone.Parent = modules
	end
	return #ranges, nil
end

local function raycastExclusions(road: Model): { Instance }
	local excluded: { Instance } = { road }
	for _, name in { "Roads", "Junctions", "Roundabouts" } do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			table.insert(excluded, folder)
		end
	end
	return excluded
end

local function viaductSlabThickness(scale: number): number
	return math.max(0.55 * scale, 1.5)
end

local function proceduralDepth(curve: PolyCurve.PolyCurve, s0: number, s1: number, halfWidth: number): number
	local nominalLength = s1 - s0
	local curvature = math.abs(curve:CurvatureAt((s0 + s1) / 2))
	-- Match RoadBuilder's outside-edge coverage principle: a wide wall/deck
	-- traces a longer arc than the centreline. Arc length also covers vertical
	-- grades better than sizing from the shorter endpoint chord.
	return nominalLength + halfWidth * curvature * nominalLength + 0.16
end

local function placePiers(
	parent: Model,
	road: Model,
	curve: PolyCurve.PolyCurve,
	data: RoadInstance.StructureData,
	settings: Settings.EasyRoadSettings
): number
	if not data.AutoPillars then
		return 0
	end
	local scale = settings.MetersToStuds
	local spacing = math.max(data.PillarSpacingM * scale, 1)
	local maxDrop = math.max(data.MaxPillarHeightM * scale, 1)
	local width = math.max(data.PillarWidthM * scale, 0.2)
	local depth = math.max(data.PillarDepthM * scale, 0.2)
	local slabThickness = viaductSlabThickness(scale)
	local interfaceOverlap = math.min(data.InterfaceOverlapM * scale, slabThickness * 0.9)
	local concreteColor = StructureBuilder.ColorFromHex(data.ConcreteColorHex)
	local folder = Instance.new("Folder")
	folder.Name = "Piers"
	folder.Parent = parent

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = raycastExclusions(road)
	-- "Ground" means the terrain below water, not the water surface.
	params.IgnoreWater = true

	-- Distribute the supports evenly and always try one support on a short
	-- elevated span. The old spacing/2 loop produced zero piers whenever a
	-- road was shorter than roughly half the configured spacing, which made
	-- a perfectly valid short viaduct look like a floating road.
	local targetCount = math.min(MAX_PIERS, math.max(1, math.floor(curve.Length / spacing)))
	local count = 0
	for index = 1, targetCount do
		local station = curve.Length * index / (targetCount + 1)
		local frame = curve:FrameAt(station)
		local top = curve:PosAt(station)
			+ frame.UpVector
				* (
					data.ModuleOffsetM * scale
					- settings.RoadThicknessStuds
					+ interfaceOverlap
					- slabThickness
				)
		local result = Workspace:Raycast(top + Vector3.new(0, 2, 0), Vector3.new(0, -(maxDrop + 2), 0), params)
		if result then
			local height = top.Y - result.Position.Y
			-- At ground level the ray immediately hits the terrain; no decorative
			-- stub is emitted. A real viaduct support needs visible clearance.
			if height > 0.5 then
				count += 1
				local part = Instance.new("Part")
				part.Name = string.format("Pier_%04d", count)
				part.Anchored = true
				part.Material = Enum.Material.Concrete
				part.Color = concreteColor
				part.Size = Vector3.new(width, height, depth)
				part.CFrame = flatFrameAt(Vector3.new(top.X, result.Position.Y + height / 2, top.Z), frame.LookVector)
				part:SetAttribute("RW_StationStuds", station)
				part:SetAttribute("RW_GroundPosition", result.Position)
				part.Parent = folder
			end
		end
	end
	return count
end

local function roadWidthStuds(road: Model, settings: Settings.EasyRoadSettings): number
	local roadData = RoadInstance.Read(road)
	if not roadData then
		return 10 * settings.MetersToStuds
	end
	local widthM = RoadProfile.TotalWidthM(roadData.ProfileStart)
	if roadData.ProfileEnd then
		widthM = math.max(widthM, RoadProfile.TotalWidthM(roadData.ProfileEnd))
	end
	return math.max(widthM * settings.MetersToStuds, 4)
end

local function makeConcretePart(name: string, size: Vector3, frame: CFrame, color: Color3, parent: Folder): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = true
	part.CanTouch = true
	part.CanQuery = true
	part.CastShadow = true
	part.Material = Enum.Material.Concrete
	part.Color = color
	part.Size = size
	part.CFrame = frame
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- The no-asset viaduct mirrors the hardware reference's construction rather
-- than leaving a normal road floating on bare columns: a structural slab runs
-- under the pavement, with continuous concrete parapets on both outside edges.
local function placeProceduralViaduct(
	parent: Model,
	road: Model,
	curve: PolyCurve.PolyCurve,
	data: RoadInstance.StructureData,
	settings: Settings.EasyRoadSettings
): number
	if curve.Length < EPSILON then
		return 0
	end
	local scale = settings.MetersToStuds
	local roadWidth = roadWidthStuds(road, settings)
	local concreteColor = StructureBuilder.ColorFromHex(data.ConcreteColorHex)
	local parapetGap = data.ViaductParapetGapM * scale
	local edgeAllowance = 0.45 * scale
	local slabThickness = viaductSlabThickness(scale)
	local interfaceOverlap = math.min(data.InterfaceOverlapM * scale, slabThickness * 0.9)
	local barrierThickness = math.max(0.35 * scale, 0.8)
	local barrierHeight = math.max(1.2 * scale, 2.5)
	local barrierCenter = roadWidth / 2 + parapetGap + barrierThickness / 2
	local deckHalfWidth = math.max(roadWidth / 2 + edgeAllowance, barrierCenter + barrierThickness / 2)
	local deckWidth = deckHalfWidth * 2
	local offset = data.ModuleOffsetM * scale
	local step = math.max(settings.MaxSegmentLengthStuds, 4)
	local segmentCount = math.min(
		math.floor(MAX_PROCEDURAL_PARTS / 3),
		math.max(1, math.ceil(curve.Length / step))
	)
	local folder = Instance.new("Folder")
	folder.Name = "ProceduralViaduct"
	folder:SetAttribute("RW_ProceduralViaduct", true)
	folder.Parent = parent

	local partCount = 0
	for index = 1, segmentCount do
		local s0 = curve.Length * (index - 1) / segmentCount
		local s1 = curve.Length * index / segmentCount
		local p0 = curve:PosAt(s0)
		local p1 = curve:PosAt(s1)
		local chord = (p1 - p0).Magnitude
		if chord < EPSILON then
			continue
		end
		local middle = (p0 + p1) * 0.5
		local roadFrame = curve:FrameAt((s0 + s1) * 0.5)
		local frame = safeLookAt(middle, middle + (p1 - p0), roadFrame.UpVector)
		frame = frame + roadFrame.UpVector * offset
		local depth = proceduralDepth(curve, s0, s1, deckHalfWidth)
		local slabY = -settings.RoadThicknessStuds + interfaceOverlap - slabThickness / 2

		makeConcretePart(
			string.format("DeckSlab_%04d", index),
			Vector3.new(deckWidth, slabThickness, depth),
			frame * CFrame.new(0, slabY, 0),
			concreteColor,
			folder
		)
		for _, side in { -1, 1 } do
			makeConcretePart(
				string.format("Parapet_%s_%04d", if side < 0 then "Left" else "Right", index),
				Vector3.new(barrierThickness, barrierHeight, depth),
				frame
					* CFrame.new(
						side * barrierCenter,
						barrierHeight / 2,
						0
					),
				concreteColor,
				folder
			)
		end
		partCount += 3
	end
	return partCount
end

-- A usable no-asset tunnel following the reference assets: a structural base,
-- tall sidewalls, and a segmented elliptical concrete vault. It provides
-- vehicle clearance without pretending that a flat three-Part box is a real
-- tunnel.
-- Terrain carving is deliberately not implicit because rebuilding/deleting a
-- road cannot faithfully reconstruct arbitrary terrain that was removed.
local function placeProceduralTunnel(
	parent: Model,
	road: Model,
	curve: PolyCurve.PolyCurve,
	data: RoadInstance.StructureData,
	settings: Settings.EasyRoadSettings
): number
	if curve.Length < EPSILON then
		return 0
	end
	local scale = settings.MetersToStuds
	local roadWidth = roadWidthStuds(road, settings)
	local concreteColor = StructureBuilder.ColorFromHex(data.ConcreteColorHex)
	local sideClearance = data.TunnelWallClearanceM * scale
	local thickness = math.max(0.35 * scale, 0.5)
	local interfaceOverlap = math.min(data.InterfaceOverlapM * scale, thickness * 0.9)
	local innerHalfWidth = roadWidth / 2 + sideClearance
	local outerWidth = innerHalfWidth * 2 + thickness * 2
	local wallHeight = math.max(6 * scale, innerHalfWidth * 0.72)
	local roofRise = math.max(2.5 * scale, innerHalfWidth * 0.22)
	local offset = data.ModuleOffsetM * scale
	local step = math.max(settings.MaxSegmentLengthStuds, 4)
	local partsPerSegment = TUNNEL_ARCH_SEGMENTS + 3
	local segmentCount = math.min(
		math.floor(MAX_PROCEDURAL_PARTS / partsPerSegment),
		math.max(1, math.ceil(curve.Length / step))
	)
	local folder = Instance.new("Folder")
	folder.Name = "ProceduralTunnel"
	folder:SetAttribute("RW_ProceduralTunnel", true)
	folder.Parent = parent

	local partCount = 0
	for index = 1, segmentCount do
		local s0 = curve.Length * (index - 1) / segmentCount
		local s1 = curve.Length * index / segmentCount
		local p0 = curve:PosAt(s0)
		local p1 = curve:PosAt(s1)
		local chord = (p1 - p0).Magnitude
		if chord < EPSILON then
			continue
		end
		local middle = (p0 + p1) * 0.5
		local roadFrame = curve:FrameAt((s0 + s1) * 0.5)
		local frame = safeLookAt(middle, middle + (p1 - p0), roadFrame.UpVector)
		frame = frame + roadFrame.UpVector * offset
		local depth = proceduralDepth(curve, s0, s1, outerWidth / 2)
		local floorTop = -settings.RoadThicknessStuds + interfaceOverlap

		makeConcretePart(
			string.format("Base_%04d", index),
			Vector3.new(outerWidth, thickness, depth),
			frame * CFrame.new(0, floorTop - thickness / 2, 0),
			concreteColor,
			folder
		)
		makeConcretePart(
			string.format("WallLeft_%04d", index),
			Vector3.new(thickness, wallHeight, depth),
			frame * CFrame.new(-innerHalfWidth - thickness / 2, floorTop + wallHeight / 2, 0),
			concreteColor,
			folder
		)
		makeConcretePart(
			string.format("WallRight_%04d", index),
			Vector3.new(thickness, wallHeight, depth),
			frame * CFrame.new(innerHalfWidth + thickness / 2, floorTop + wallHeight / 2, 0),
			concreteColor,
			folder
		)
		for archIndex = 1, TUNNEL_ARCH_SEGMENTS do
			local theta0 = math.pi * (archIndex - 1) / TUNNEL_ARCH_SEGMENTS
			local theta1 = math.pi * archIndex / TUNNEL_ARCH_SEGMENTS
			local x0 = -innerHalfWidth * math.cos(theta0)
			local y0 = floorTop + wallHeight + roofRise * math.sin(theta0)
			local x1 = -innerHalfWidth * math.cos(theta1)
			local y1 = floorTop + wallHeight + roofRise * math.sin(theta1)
			local panelWidth = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2) + 0.08
			local panelAngle = math.atan2(y1 - y0, x1 - x0)
			makeConcretePart(
				string.format("Vault_%02d_%04d", archIndex, index),
				Vector3.new(panelWidth, thickness, depth),
				frame
					* CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, 0)
					* CFrame.Angles(0, 0, panelAngle),
				concreteColor,
				folder
			)
		end
		partCount += partsPerSegment
	end
	return partCount
end

local function restyleElevatedMedian(road: Model, enabled: boolean, concreteColor: Color3)
	for _, descendant in road:GetDescendants() do
		if not descendant:IsA("BasePart") or descendant.Name ~= "Median" then
			continue
		end
		local part = descendant :: BasePart
		if part:GetAttribute("RW_ElevatedMedianStyled") == true then
			local originalColor = part:GetAttribute("RW_OriginalMedianColor")
			part.Material = Enum.Material.Grass
			if typeof(originalColor) == "Color3" then
				part.Color = originalColor
			end
			part:SetAttribute("RW_ElevatedMedianStyled", nil)
			part:SetAttribute("RW_OriginalMedianColor", nil)
		end
		if enabled then
			part:SetAttribute("RW_ElevatedMedianStyled", true)
			part:SetAttribute("RW_OriginalMedianColor", part.Color)
			part.Material = Enum.Material.Concrete
			part.Color = concreteColor
		end
	end
end

function StructureBuilder.Render(
	road: Model,
	curve: PolyCurve.PolyCurve,
	data: RoadInstance.StructureData,
	settings: Settings.EasyRoadSettings
): (boolean, string)
	local concreteColor = StructureBuilder.ColorFromHex(data.ConcreteColorHex)
	restyleElevatedMedian(road, data.Mode == "Viaduct" and data.ConcreteMedian, concreteColor)
	StructureBuilder.Clear(road)
	if data.Mode == "None" then
		return true, "Ground-level road; no generated structure."
	end

	local generated = makeGeneratedModel()
	local moduleCount = 0
	local proceduralPartCount = 0
	if data.AssetId then
		local asset = StructureAssets.Get(data.AssetId)
		if not asset then
			generated:Destroy()
			return false, "The selected structure asset no longer exists in ServerStorage/EasyRoadAssets."
		end
		local assetKind = asset:GetAttribute("ER_AssetKind")
		if assetKind ~= data.Mode then
			generated:Destroy()
			return false, "The selected asset belongs to the " .. tostring(assetKind) .. " library."
		end
		local count, err = placeModules(generated, curve, asset, data.ModuleOffsetM * settings.MetersToStuds)
		if err then
			generated:Destroy()
			return false, err
		end
		moduleCount = count
	elseif data.Mode == "Viaduct" then
		proceduralPartCount = placeProceduralViaduct(generated, road, curve, data, settings)
	elseif data.Mode == "Tunnel" then
		proceduralPartCount = placeProceduralTunnel(generated, road, curve, data, settings)
	end

	local pierCount = if data.Mode == "Viaduct" then placePiers(generated, road, curve, data, settings) else 0
	generated:SetAttribute("RW_StructureMode", data.Mode)
	generated:SetAttribute("RW_ModuleCount", moduleCount)
	generated:SetAttribute("RW_PierCount", pierCount)
	generated:SetAttribute("RW_ProceduralPartCount", proceduralPartCount)
	generated.Parent = road

	if data.Mode == "Viaduct" then
		if data.AssetId then
			return true, string.format("Built %d custom viaduct modules and %d raycast piers.", moduleCount, pierCount)
		end
		return true,
			string.format(
				"Built a procedural viaduct deck and parapets with %d parts and %d raycast piers.",
				proceduralPartCount,
				pierCount
			)
	end
	if data.AssetId then
		return true, string.format("Built %d custom tunnel modules. Terrain excavation is explicit.", moduleCount)
	end
	return true,
		string.format(
			"Built a procedural tunnel base, walls, and arched vault with %d parts. Terrain excavation is explicit.",
			proceduralPartCount
		)
end

return StructureBuilder
