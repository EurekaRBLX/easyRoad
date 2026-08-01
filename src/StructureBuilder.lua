--!strict
-- Repeats imported rigid Models along a placed road and, for viaducts, places
-- simple concrete piers by raycasting vertically down to Terrain/world parts.

local Workspace = game:GetService("Workspace")

local PolyCurve = require("./Geometry/PolyCurve")
local RoadInstance = require("./RoadInstance")
local Settings = require("./Settings")
local StructureAssets = require("./StructureAssets")

local GENERATED_NAME = "EasyRoadStructure"
local EPSILON = 0.05
local MAX_MODULES = 2000
local MAX_PIERS = 1000

local StructureBuilder = {}

function StructureBuilder.DefaultData(): RoadInstance.StructureData
	return {
		Mode = "None",
		AssetId = nil,
		ModuleOffsetM = 0,
		AutoPillars = true,
		PillarSpacingM = 18,
		PillarWidthM = 1.8,
		PillarDepthM = 1.8,
		MaxPillarHeightM = 200,
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
	local folder = Instance.new("Folder")
	folder.Name = "Piers"
	folder.Parent = parent

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = raycastExclusions(road)
	-- "Ground" means the terrain below water, not the water surface.
	params.IgnoreWater = true

	local count = 0
	local station = spacing / 2
	while station < curve.Length - spacing * 0.15 and count < MAX_PIERS do
		local frame = curve:FrameAt(station)
		local top = curve:PosAt(station) + frame.UpVector * (data.ModuleOffsetM * scale)
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
				part.Color = Color3.fromRGB(126, 126, 126)
				part.Size = Vector3.new(width, height, depth)
				part.CFrame = flatFrameAt(Vector3.new(top.X, result.Position.Y + height / 2, top.Z), frame.LookVector)
				part:SetAttribute("RW_StationStuds", station)
				part:SetAttribute("RW_GroundPosition", result.Position)
				part.Parent = folder
			end
		end
		station += spacing
	end
	return count
end

function StructureBuilder.Render(
	road: Model,
	curve: PolyCurve.PolyCurve,
	data: RoadInstance.StructureData,
	settings: Settings.EasyRoadSettings
): (boolean, string)
	StructureBuilder.Clear(road)
	if data.Mode == "None" then
		return true, "Ground-level road; no generated structure."
	end

	local generated = makeGeneratedModel()
	local moduleCount = 0
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
	elseif data.Mode == "Tunnel" then
		generated:Destroy()
		return false, "Tunnel mode needs an imported Tunnel module."
	end

	local pierCount = if data.Mode == "Viaduct" then placePiers(generated, road, curve, data, settings) else 0
	generated:SetAttribute("RW_StructureMode", data.Mode)
	generated:SetAttribute("RW_ModuleCount", moduleCount)
	generated:SetAttribute("RW_PierCount", pierCount)
	generated.Parent = road

	if data.Mode == "Viaduct" then
		return true, string.format("Built %d modules and %d raycast piers.", moduleCount, pierCount)
	end
	return true, string.format("Built %d tunnel modules. Terrain excavation is intentionally separate.", moduleCount)
end

return StructureBuilder
