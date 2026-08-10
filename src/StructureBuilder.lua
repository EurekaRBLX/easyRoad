--!strict
-- Repeats imported rigid Models along a placed road. Ground assets replace the
-- ordinary generated cross-section after a successful module build. Without a
-- custom asset it builds a concrete viaduct deck/parapets or a tunnel base/walls/arched vault;
-- viaduct piers are projected vertically down to Terrain/world parts.

local Workspace = game:GetService("Workspace")

local PolyCurve = require("./Geometry/PolyCurve")
local Superelevation = require("./Geometry/Superelevation")
local createRegionLibrary = require("./RegionLibrary")
local RoadInstance = require("./RoadInstance")
local RoadProfile = require("./RoadProfile")
local Settings = require("./Settings")
local StructureAssets = require("./StructureAssets")
local StructureMaterials = require("./StructureMaterials")

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
		PillarLayout = "Single",
		PillarSeparationM = 6,
		CapBeamWidthM = 9,
		CapBeamHeightM = 1,
		CapBeamDepthM = 2.2,
		ConcreteColorHex = if settings then settings.StructureConcreteColorHex else DEFAULT_CONCRETE_HEX,
		BaseMaterial = if settings then settings.StructureBaseMaterial else "Concrete",
		ViaductWallColorHex = if settings then settings.ViaductWallColorHex else DEFAULT_CONCRETE_HEX,
		ViaductWallMaterial = if settings then settings.ViaductWallMaterial else "Concrete",
		TunnelWallColorHex = if settings then settings.TunnelWallColorHex else DEFAULT_CONCRETE_HEX,
		TunnelWallMaterial = if settings then settings.TunnelWallMaterial else "Concrete",
		TunnelRoofColorHex = if settings then settings.TunnelRoofColorHex else DEFAULT_CONCRETE_HEX,
		TunnelRoofMaterial = if settings then settings.TunnelRoofMaterial else "Concrete",
		InterfaceOverlapM = if settings then settings.StructureInterfaceOverlapM else 0.2,
		ViaductParapetGapM = if settings then settings.ViaductParapetGapM else 0,
		ViaductParapetHeightM = if settings then settings.ViaductParapetHeightM else 1.2,
		TunnelWallClearanceM = if settings then settings.TunnelWallClearanceM else 0.75,
		TunnelVerticalClearanceM = if settings then settings.TunnelVerticalClearanceM else 6,
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
		PillarLayout = data.PillarLayout,
		PillarSeparationM = data.PillarSeparationM,
		CapBeamWidthM = data.CapBeamWidthM,
		CapBeamHeightM = data.CapBeamHeightM,
		CapBeamDepthM = data.CapBeamDepthM,
		ConcreteColorHex = data.ConcreteColorHex,
		BaseMaterial = data.BaseMaterial,
		ViaductWallColorHex = data.ViaductWallColorHex,
		ViaductWallMaterial = data.ViaductWallMaterial,
		TunnelWallColorHex = data.TunnelWallColorHex,
		TunnelWallMaterial = data.TunnelWallMaterial,
		TunnelRoofColorHex = data.TunnelRoofColorHex,
		TunnelRoofMaterial = data.TunnelRoofMaterial,
		InterfaceOverlapM = data.InterfaceOverlapM,
		ViaductParapetGapM = data.ViaductParapetGapM,
		ViaductParapetHeightM = data.ViaductParapetHeightM,
		TunnelWallClearanceM = data.TunnelWallClearanceM,
		TunnelVerticalClearanceM = data.TunnelVerticalClearanceM,
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

-- Structural geometry shares the road's local bank instead of following an
-- unrolled centreline beneath it. The runoff envelope matches RoadBuilder's
-- endpoint contract, so a viaduct/tunnel returns to zero roll wherever the
-- road does and chained pieces still meet flush.
local function buildRollProfile(
	curve: PolyCurve.PolyCurve,
	settings: Settings.EasyRoadSettings
): Superelevation.RollProfile
	local style = createRegionLibrary(settings.UserRegions).Get(settings.RegionId)
	return Superelevation.BuildProfile(curve.Length, function(station)
		return curve:CurvatureAt(station)
	end, settings, style)
end

local function makeBankedFrameAt(
	curve: PolyCurve.PolyCurve,
	settings: Settings.EasyRoadSettings,
	existingProfile: Superelevation.RollProfile?
): (number) -> CFrame
	local rollProfile = existingProfile or buildRollProfile(curve, settings)
	return function(station: number): CFrame
		local roll = Superelevation.RollAtProfile(rollProfile, station)
		return curve:FrameAt(station, roll)
	end
end

-- Finds the next station whose straight chord from `startStation` matches the
-- rigid module's socket length. On a curve this is slightly farther than one
-- module of arc length, which is exactly what prevents socket gaps.
local function advanceByChord(
	length: number,
	positionAt: (number) -> Vector3,
	startStation: number,
	chordLength: number
): number
	if startStation >= length then
		return length
	end
	local startPos = positionAt(startStation)
	local lo = startStation
	local hi = math.min(length, startStation + chordLength * 1.25 + 2)
	while hi < length and (positionAt(hi) - startPos).Magnitude < chordLength do
		hi = math.min(length, startStation + (hi - startStation) * 1.75)
	end
	if (positionAt(hi) - startPos).Magnitude < chordLength then
		return length
	end
	for _ = 1, 28 do
		local mid = (lo + hi) / 2
		if (positionAt(mid) - startPos).Magnitude < chordLength then
			lo = mid
		else
			hi = mid
		end
	end
	return hi
end

local function retreatByChord(positionAt: (number) -> Vector3, endStation: number, chordLength: number): number
	local endPos = positionAt(endStation)
	local lo = math.max(0, endStation - chordLength * 1.75 - 2)
	local hi = endStation
	while lo > 0 and (endPos - positionAt(lo)).Magnitude < chordLength do
		lo = math.max(0, endStation - (endStation - lo) * 1.75)
	end
	if (endPos - positionAt(lo)).Magnitude < chordLength then
		return 0
	end
	for _ = 1, 28 do
		local mid = (lo + hi) / 2
		if (endPos - positionAt(mid)).Magnitude > chordLength then
			lo = mid
		else
			hi = mid
		end
	end
	return hi
end

local function moduleRanges(length: number, positionAt: (number) -> Vector3, moduleLength: number): { { number } }
	local ranges: { { number } } = {}
	if length < EPSILON then
		return ranges
	end
	if (positionAt(length) - positionAt(0)).Magnitude < moduleLength and length < moduleLength * 1.1 then
		return { { 0, length } }
	end
	local station = 0
	while station < length - EPSILON and #ranges < MAX_MODULES do
		local nextStation = advanceByChord(length, positionAt, station, moduleLength)
		if nextStation <= station + EPSILON then
			break
		end
		if nextStation >= length - EPSILON then
			local lastStart = retreatByChord(positionAt, length, moduleLength)
			local previousStart = if #ranges > 0 then ranges[#ranges][1] else -math.huge
			if lastStart > previousStart + EPSILON then
				table.insert(ranges, { lastStart, length })
			elseif #ranges == 0 then
				table.insert(ranges, { 0, length })
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
	road: Model,
	curve: PolyCurve.PolyCurve,
	template: Model,
	offsetStuds: number,
	settings: Settings.EasyRoadSettings
): (number, string?, string?)
	local startSocket = StructureAssets.FindSocket(template, "EasyRoadStart")
	local endSocket = StructureAssets.FindSocket(template, "EasyRoadEnd")
	if not startSocket or not endSocket then
		return 0, "The stored asset is missing EasyRoadStart/EasyRoadEnd sockets. Re-import it.", nil
	end
	local sourceStart = startSocket.WorldPosition
	local sourceEnd = endSocket.WorldPosition
	local moduleLength = (sourceEnd - sourceStart).Magnitude
	if moduleLength < 0.1 then
		return 0, "The stored asset's sockets overlap.", nil
	end
	local sourceFrame = safeLookAt(sourceStart, sourceEnd, startSocket.WorldCFrame.UpVector)
	local pivotRelative = sourceFrame:ToObjectSpace(template:GetPivot())
	local roadData = RoadInstance.Read(road)
	local bankedFrameAt = makeBankedFrameAt(curve, settings)
	local function targetPositionAt(station: number): Vector3
		local frame = bankedFrameAt(station)
		local profileOffsetStuds = if roadData
			then RoadInstance.ProfileOffsetAtStationM(roadData, station, settings.MetersToStuds) * settings.MetersToStuds
			else 0
		return curve:PosAt(station) + frame.RightVector * profileOffsetStuds + frame.UpVector * offsetStuds
	end
	local ranges = moduleRanges(curve.Length, targetPositionAt, moduleLength)
	if #ranges == 0 or math.abs(ranges[#ranges][2] - curve.Length) > EPSILON then
		return 0,
			string.format(
				"This alignment needs more than %d rigid modules. Use a longer source module or shorter road.",
				MAX_MODULES
			),
			nil
	end
	local modules = Instance.new("Folder")
	modules.Name = "Modules"
	modules.Parent = parent

	for index, range in ranges do
		local s0, s1 = range[1], range[2]
		local p0, p1 = targetPositionAt(s0), targetPositionAt(s1)
		local middleFrame = bankedFrameAt((s0 + s1) / 2)
		local targetFrame = safeLookAt(p0, p1, middleFrame.UpVector)
		local clone, cloneError = StructureAssets.CloneComplete(template)
		if not clone then
			modules:Destroy()
			return 0,
				(cloneError or "Roblox could not clone the complete stored road asset.") .. " Export and re-import it.",
				nil
		end
		clone.Name = string.format("Module_%04d", index)
		clone:SetAttribute("RW_AssetId", template:GetAttribute("ER_AssetId"))
		clone:SetAttribute("RW_ModuleIndex", index)
		clone:SetAttribute("RW_ModuleStationStartStuds", s0)
		clone:SetAttribute("RW_ModuleStationEndStuds", s1)
		local partCount = 0
		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("BasePart") then
				partCount += 1
				descendant.Anchored = true
			elseif descendant:IsA("BaseScript") then
				-- Importing literal geometry must not multiply and execute a source
				-- Model's scripts once per tiled module. ModuleScripts remain
				-- available as data but do not execute on their own.
				descendant.Enabled = false
			end
		end
		if partCount == 0 then
			clone:Destroy()
			modules:Destroy()
			return 0, "The stored road asset no longer contains clonable BaseParts. Re-import it.", nil
		end
		clone:PivotTo(targetFrame * pivotRelative)
		clone.Parent = modules
	end
	local endpointChord = (targetPositionAt(curve.Length) - targetPositionAt(0)).Magnitude
	local fitWarning = if #ranges == 1 and endpointChord + 0.05 < moduleLength
		then "The road is shorter than one rigid module, so the module extends beyond an endpoint."
		else nil
	return #ranges, nil, fitWarning
end

-- RoadBuilder emits the editable cross-section as direct BasePart children.
-- A custom Ground asset owns the visible and physical surface instead. Only
-- remove those Parts after every custom module cloned successfully, so a
-- missing/deleted/bad asset safely leaves the ordinary generated road intact.
local function suppressGeneratedRoadSurface(road: Model): number
	local removed = 0
	for _, child in road:GetChildren() do
		if child:IsA("BasePart") then
			removed += 1
			child:Destroy()
		end
	end
	return removed
end

local function hasGeneratedRoadSurface(road: Model): boolean
	for _, child in road:GetChildren() do
		if child:IsA("BasePart") and typeof(child:GetAttribute("RW_ComponentStartIndex")) == "number" then
			return true
		end
	end
	return false
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

-- Keep the broad central base visually below the asphalt. The deeper structural
-- silhouette belongs at the edges (viaduct fascia/parapets and tunnel walls),
-- where extending downward cannot cover the road surface.
local STRUCTURE_SURFACE_CLEARANCE_STUDS = 0.08
local PROCEDURAL_AXIAL_OVERLAP_STUDS = 0.16
local STRUCTURE_EDGE_CLEARANCE_STUDS = 0.08
-- Leave half the seating clearance for curvature/chord approximation and
-- floating-point noise instead of spending the entire allowance on bank twist.
local STRUCTURE_BANK_MISMATCH_BUDGET_STUDS = STRUCTURE_SURFACE_CLEARANCE_STUDS * 0.5

type StructureStationRange = { number }

local function firstStationAfter(stations: { number }, station: number): number
	local low = 1
	local high = #stations + 1
	while low < high do
		local middle = math.floor((low + high) / 2)
		if stations[middle] <= station then
			low = middle + 1
		else
			high = middle
		end
	end
	return low
end

local function needsBankRefinement(
	profile: Superelevation.RollProfile,
	s0: number,
	s1: number,
	farEdgeOffset: number
): boolean
	local mid = (s0 + s1) / 2
	local midSin = math.sin(Superelevation.RollAtProfile(profile, mid))
	local function exceedsBudget(station: number): boolean
		local sampleSin = math.sin(Superelevation.RollAtProfile(profile, station))
		return farEdgeOffset * math.abs(sampleSin - midSin) > STRUCTURE_BANK_MISMATCH_BUDGET_STUDS
	end
	if exceedsBudget(s0) or exceedsBudget(s1) then
		return true
	end

	-- RollAtProfile is linear between canonical controls. Superelevation stays
	-- inside the monotonic range of sin(), so the extrema relative to this
	-- segment's midpoint bank occur at an endpoint or at one of those controls.
	-- Checking all controls inside the range therefore gives a real far-edge
	-- error bound; fixed quarter probes could miss a narrow S-curve peak.
	local stationIndex = firstStationAfter(profile.Stations, s0)
	while stationIndex <= #profile.Stations and profile.Stations[stationIndex] < s1 do
		if exceedsBudget(profile.Stations[stationIndex]) then
			return true
		end
		stationIndex += 1
	end
	return false
end

-- Starts from the existing equal-length procedural ranges, then bisects only
-- the ranges whose rigid midpoint-bank box would miss the canonical bank at
-- the far edge. Refinement happens in breadth-wise passes so one transition
-- cannot consume the entire Part budget before the opposite runoff is tested.
local function refinedStructureRanges(
	length: number,
	step: number,
	farEdgeOffset: number,
	profile: Superelevation.RollProfile,
	maximumSegments: number
): ({ StructureStationRange }, boolean)
	local initialCount = math.min(maximumSegments, math.max(1, math.ceil(length / step)))
	local ranges: { StructureStationRange } = table.create(initialCount)
	for index = 1, initialCount do
		table.insert(ranges, { length * (index - 1) / initialCount, length * index / initialCount })
	end

	local refinementCapped = false
	while true do
		local needsSplit: { [number]: boolean } = {}
		local splitCount = 0
		for index, range in ranges do
			local s0, s1 = range[1], range[2]
			if s1 - s0 > 1e-6 and needsBankRefinement(profile, s0, s1, farEdgeOffset) then
				needsSplit[index] = true
				splitCount += 1
			end
		end
		if splitCount == 0 then
			break
		end

		local availableSplits = maximumSegments - #ranges
		if availableSplits <= 0 then
			refinementCapped = true
			break
		end
		local nextRanges: { StructureStationRange } = table.create(#ranges + math.min(splitCount, availableSplits))
		local usedSplits = 0
		for index, range in ranges do
			if needsSplit[index] and usedSplits < availableSplits then
				local mid = (range[1] + range[2]) / 2
				table.insert(nextRanges, { range[1], mid })
				table.insert(nextRanges, { mid, range[2] })
				usedSplits += 1
			else
				if needsSplit[index] then
					refinementCapped = true
				end
				table.insert(nextRanges, range)
			end
		end
		ranges = nextRanges
	end
	return ranges, refinementCapped
end

local function centralBaseThickness(scale: number): number
	return math.max(0.2 * scale, 0.65)
end

local function viaductFasciaDepth(scale: number): number
	return math.max(0.55 * scale, 1.5)
end

local function safeInterfaceOverlap(
	requestedM: number,
	scale: number,
	roadThickness: number,
	baseThickness: number
): number
	return math.min(
		requestedM * scale,
		baseThickness * 0.9,
		math.max(roadThickness - STRUCTURE_SURFACE_CLEARANCE_STUDS, 0)
	)
end

local function proceduralDepth(curve: PolyCurve.PolyCurve, s0: number, s1: number, halfWidth: number): number
	local nominalLength = s1 - s0
	local curvature = math.abs(curve:CurvatureAt((s0 + s1) / 2))
	-- Match RoadBuilder's outside-edge coverage principle: a wide wall/deck
	-- traces a longer arc than the centreline. Arc length also covers vertical
	-- grades better than sizing from the shorter endpoint chord.
	return nominalLength + halfWidth * curvature * nominalLength + PROCEDURAL_AXIAL_OVERLAP_STUDS
end

-- A parapet does not follow the centreline chord: on a bend its own lateral
-- offset has a different chord and heading. Extending every parapet by the
-- centreline's outside-edge allowance lets its inboard end swing across the
-- road surface. Build each parapet between its own offset endpoints instead.
-- The small overlap closes rectangular joints without a multi-stud overhang.
local function offsetSegmentFrame(
	curve: PolyCurve.PolyCurve,
	bankedFrameAt: (number) -> CFrame,
	s0: number,
	s1: number,
	lateralOffset: number,
	verticalOffset: number
): (CFrame, number)
	local startFrame = bankedFrameAt(s0)
	local endFrame = bankedFrameAt(s1)
	local startPosition = curve:PosAt(s0)
		+ startFrame.RightVector * lateralOffset
		+ startFrame.UpVector * verticalOffset
	local endPosition = curve:PosAt(s1) + endFrame.RightVector * lateralOffset + endFrame.UpVector * verticalOffset
	local preferredUp = startFrame.UpVector + endFrame.UpVector
	if preferredUp.Magnitude < 1e-6 then
		preferredUp = bankedFrameAt((s0 + s1) / 2).UpVector
	end
	local frame = safeLookAt((startPosition + endPosition) / 2, endPosition, preferredUp)
	return frame, (endPosition - startPosition).Magnitude + PROCEDURAL_AXIAL_OVERLAP_STUDS
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
	local twin = data.PillarLayout == "Twin"
	local separation = math.max(data.PillarSeparationM * scale, width)
	local capHeight = math.max(data.CapBeamHeightM * scale, 0.2)
	local capDepth = math.max(data.CapBeamDepthM * scale, depth)
	local capWidth = math.max(data.CapBeamWidthM * scale, separation + width)
	local exposedBaseDepth = centralBaseThickness(scale)
	local interfaceOverlap =
		safeInterfaceOverlap(data.InterfaceOverlapM, scale, settings.RoadThicknessStuds, exposedBaseDepth)
	-- Interface overlap is additional embedment, not a subtraction from the
	-- visible deck. Keeping it separate guarantees a real structural slab below
	-- the asphalt even at the default 0.2 m overlap.
	local baseThickness = exposedBaseDepth + interfaceOverlap
	local concreteColor = StructureBuilder.ColorFromHex(data.ConcreteColorHex)
	local baseMaterial = StructureMaterials.Resolve(data.BaseMaterial)
	local folder = Instance.new("Folder")
	folder.Name = "Piers"
	folder.Parent = parent
	local bankedFrameAt = makeBankedFrameAt(curve, settings)
	local roadData = RoadInstance.Read(road)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = raycastExclusions(road)
	-- "Ground" means the terrain below water, not the water surface.
	params.IgnoreWater = true

	-- Distribute the supports evenly and always try one support on a short
	-- elevated span. The old spacing/2 loop produced zero piers whenever a
	-- road was shorter than roughly half the configured spacing, which made
	-- a perfectly valid short viaduct look like a floating road.
	local maxStations = if twin then math.floor(MAX_PIERS / 2) else MAX_PIERS
	local targetCount = math.min(maxStations, math.max(1, math.floor(curve.Length / spacing)))
	local count = 0
	for index = 1, targetCount do
		local station = curve.Length * index / (targetCount + 1)
		local frame = bankedFrameAt(station)
		local profileOffsetStuds = if roadData
			then RoadInstance.ProfileOffsetAtStationM(roadData, station, scale) * scale
			else 0
		local top = curve:PosAt(station)
			+ frame.RightVector * profileOffsetStuds
			+ frame.UpVector
				* (data.ModuleOffsetM * scale - settings.RoadThicknessStuds + interfaceOverlap - baseThickness)
		local supportFrame = flatFrameAt(top, frame.LookVector)
		local columnTopY = top.Y - (if twin then capHeight else 0)
		local lateralOffsets = if twin then { -separation / 2, separation / 2 } else { 0 }
		local columnHits: { { LateralOffset: number, GroundPosition: Vector3, Height: number } } = {}
		for _, lateralOffset in lateralOffsets do
			local projected = top + supportFrame.RightVector * lateralOffset
			local result = Workspace:Raycast(
				Vector3.new(projected.X, top.Y + 2, projected.Z),
				Vector3.new(0, -(maxDrop + 2), 0),
				params
			)
			if result then
				local height = columnTopY - result.Position.Y
				-- At ground level the ray immediately hits the terrain; no decorative
				-- stub is emitted. A real viaduct support needs visible clearance.
				if height > 0.5 then
					table.insert(columnHits, {
						LateralOffset = lateralOffset,
						GroundPosition = result.Position,
						Height = height,
					})
				end
			end
		end
		-- A twin station is atomic: if either projection has no usable ground,
		-- omit the whole bent rather than leaving one column under a two-column cap.
		local requiredColumns = if twin then 2 else 1
		if #columnHits == requiredColumns then
			for columnIndex, hit in columnHits do
				count += 1
				local projected = top + supportFrame.RightVector * hit.LateralOffset
				local part = Instance.new("Part")
				part.Name = if twin
					then string.format("Pier_%04d_%s", index, if columnIndex == 1 then "Left" else "Right")
					else string.format("Pier_%04d", count)
				part.Anchored = true
				part.Material = baseMaterial
				part.Color = concreteColor
				part.Size = Vector3.new(width, hit.Height, depth)
				part.CFrame = flatFrameAt(
					Vector3.new(projected.X, hit.GroundPosition.Y + hit.Height / 2, projected.Z),
					frame.LookVector
				)
				part:SetAttribute("RW_StationStuds", station)
				part:SetAttribute("RW_GroundPosition", hit.GroundPosition)
				part:SetAttribute("RW_PillarLayout", data.PillarLayout)
				part.Parent = folder
			end
		end
		if twin and #columnHits == requiredColumns then
			local cap = Instance.new("Part")
			cap.Name = string.format("CapBeam_%04d", index)
			cap.Anchored = true
			cap.Material = baseMaterial
			cap.Color = concreteColor
			cap.Size = Vector3.new(capWidth, capHeight, capDepth)
			cap.CFrame = supportFrame * CFrame.new(0, -capHeight / 2, 0)
			cap:SetAttribute("RW_StationStuds", station)
			cap:SetAttribute("RW_PillarLayout", "Twin")
			cap.Parent = folder
		end
	end
	return count
end

-- Full lateral envelope occupied by both endpoint profiles. Procedural shells
-- remain constant-width today, but their centre must follow an edge-anchored
-- widening instead of silently staying centred on the authored curve.
local function roadEnvelopeStuds(road: Model, settings: Settings.EasyRoadSettings): (number, number)
	local roadData = RoadInstance.Read(road)
	if not roadData then
		return 10 * settings.MetersToStuds, 0
	end
	local startWidthM = RoadProfile.TotalWidthM(roadData.ProfileStart)
	local endWidthM = RoadProfile.TotalWidthM(roadData.ProfileEnd or roadData.ProfileStart)
	local leftM = math.min(-startWidthM / 2 + roadData.ProfileOffsetStartM, -endWidthM / 2 + roadData.ProfileOffsetEndM)
	local rightM = math.max(startWidthM / 2 + roadData.ProfileOffsetStartM, endWidthM / 2 + roadData.ProfileOffsetEndM)
	local scale = settings.MetersToStuds
	return math.max((rightM - leftM) * scale, 4), (leftM + rightM) / 2 * scale
end

local function makeStructurePart(
	name: string,
	size: Vector3,
	frame: CFrame,
	color: Color3,
	material: Enum.Material,
	parent: Folder
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = true
	part.CanTouch = true
	part.CanQuery = true
	part.CastShadow = true
	part.Material = material
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
	local roadWidth, roadCenterOffset = roadEnvelopeStuds(road, settings)
	local concreteColor = StructureBuilder.ColorFromHex(data.ConcreteColorHex)
	local baseMaterial = StructureMaterials.Resolve(data.BaseMaterial)
	local wallColor = StructureBuilder.ColorFromHex(data.ViaductWallColorHex)
	local wallMaterial = StructureMaterials.Resolve(data.ViaductWallMaterial)
	local parapetGap = data.ViaductParapetGapM * scale
	local exposedBaseDepth = centralBaseThickness(scale)
	local fasciaDepth = viaductFasciaDepth(scale)
	local interfaceOverlap =
		safeInterfaceOverlap(data.InterfaceOverlapM, scale, settings.RoadThicknessStuds, exposedBaseDepth)
	local baseThickness = exposedBaseDepth + interfaceOverlap
	local barrierThickness = math.max(0.35 * scale, 0.8)
	local barrierHeight = math.max(data.ViaductParapetHeightM * scale, 0.2 * scale)
	-- Even a configured zero gap means tangent contact, not overlap. Keep a
	-- hairline structural clearance so rectangular joints on a tight bend stay
	-- wholly outside the generated road envelope.
	local barrierCenter = roadWidth / 2 + parapetGap + STRUCTURE_EDGE_CLEARANCE_STUDS + barrierThickness / 2
	-- The slab meets the parapet's inner face. Extending it through to the outer
	-- face hides the downward fascia and can visibly protrude beyond it.
	local deckHalfWidth = barrierCenter - barrierThickness / 2
	local deckWidth = deckHalfWidth * 2
	local deckMaxOffset = math.abs(roadCenterOffset) + deckHalfWidth
	local offset = data.ModuleOffsetM * scale
	local step = math.max(settings.MaxSegmentLengthStuds, 4)
	local maximumSegments = math.floor(MAX_PROCEDURAL_PARTS / 3)
	local rollProfile = buildRollProfile(curve, settings)
	local stationRanges, refinementCapped = refinedStructureRanges(
		curve.Length,
		step,
		math.abs(roadCenterOffset) + barrierCenter + barrierThickness / 2,
		rollProfile,
		maximumSegments
	)
	local folder = Instance.new("Folder")
	folder.Name = "ProceduralViaduct"
	folder:SetAttribute("RW_ProceduralViaduct", true)
	folder:SetAttribute("RW_BankRefinementCapped", refinementCapped)
	folder:SetAttribute("RW_BankMismatchBudgetStuds", STRUCTURE_BANK_MISMATCH_BUDGET_STUDS)
	folder.Parent = parent
	local bankedFrameAt = makeBankedFrameAt(curve, settings, rollProfile)

	local partCount = 0
	for index, range in stationRanges do
		local s0, s1 = range[1], range[2]
		local p0 = curve:PosAt(s0)
		local p1 = curve:PosAt(s1)
		local chord = (p1 - p0).Magnitude
		if chord < EPSILON then
			continue
		end
		local middle = (p0 + p1) * 0.5
		local roadFrame = bankedFrameAt((s0 + s1) * 0.5)
		local frame = safeLookAt(middle, middle + (p1 - p0), roadFrame.UpVector)
		frame = frame + roadFrame.UpVector * offset
		local depth = proceduralDepth(curve, s0, s1, deckMaxOffset)
		local baseTopY = -settings.RoadThicknessStuds + interfaceOverlap
		local baseY = baseTopY - baseThickness / 2
		local barrierBottom = baseTopY - fasciaDepth
		local fullBarrierHeight = barrierHeight - barrierBottom
		local barrierY = (barrierHeight + barrierBottom) / 2

		makeStructurePart(
			string.format("DeckSlab_%04d", index),
			Vector3.new(deckWidth, baseThickness, depth),
			frame * CFrame.new(roadCenterOffset, baseY, 0),
			concreteColor,
			baseMaterial,
			folder
		)
		for _, side in { -1, 1 } do
			local barrierFrame, barrierDepth = offsetSegmentFrame(
				curve,
				bankedFrameAt,
				s0,
				s1,
				roadCenterOffset + side * barrierCenter,
				offset + barrierY
			)
			makeStructurePart(
				string.format("Parapet_%s_%04d", if side < 0 then "Left" else "Right", index),
				Vector3.new(barrierThickness, fullBarrierHeight, barrierDepth),
				barrierFrame,
				wallColor,
				wallMaterial,
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
	local roadWidth, roadCenterOffset = roadEnvelopeStuds(road, settings)
	local concreteColor = StructureBuilder.ColorFromHex(data.ConcreteColorHex)
	local baseMaterial = StructureMaterials.Resolve(data.BaseMaterial)
	local wallColor = StructureBuilder.ColorFromHex(data.TunnelWallColorHex)
	local wallMaterial = StructureMaterials.Resolve(data.TunnelWallMaterial)
	local roofColor = StructureBuilder.ColorFromHex(data.TunnelRoofColorHex)
	local roofMaterial = StructureMaterials.Resolve(data.TunnelRoofMaterial)
	local sideClearance = data.TunnelWallClearanceM * scale
	local thickness = math.max(0.35 * scale, 0.5)
	local baseThickness = centralBaseThickness(scale)
	local interfaceOverlap =
		safeInterfaceOverlap(data.InterfaceOverlapM, scale, settings.RoadThicknessStuds, baseThickness)
	local innerHalfWidth = roadWidth / 2 + sideClearance
	local outerWidth = innerHalfWidth * 2 + thickness * 2
	local wallTop = math.max(data.TunnelVerticalClearanceM * scale, 2 * scale)
	local roofRise = math.max(2.5 * scale, innerHalfWidth * 0.22)
	local offset = data.ModuleOffsetM * scale
	local step = math.max(settings.MaxSegmentLengthStuds, 4)
	local partsPerSegment = TUNNEL_ARCH_SEGMENTS + 3
	local maximumSegments = math.floor(MAX_PROCEDURAL_PARTS / partsPerSegment)
	local rollProfile = buildRollProfile(curve, settings)
	local stationRanges, refinementCapped = refinedStructureRanges(
		curve.Length,
		step,
		math.abs(roadCenterOffset) + outerWidth / 2,
		rollProfile,
		maximumSegments
	)
	local folder = Instance.new("Folder")
	folder.Name = "ProceduralTunnel"
	folder:SetAttribute("RW_ProceduralTunnel", true)
	folder:SetAttribute("RW_BankRefinementCapped", refinementCapped)
	folder:SetAttribute("RW_BankMismatchBudgetStuds", STRUCTURE_BANK_MISMATCH_BUDGET_STUDS)
	folder.Parent = parent
	local bankedFrameAt = makeBankedFrameAt(curve, settings, rollProfile)

	local partCount = 0
	for index, range in stationRanges do
		local s0, s1 = range[1], range[2]
		local p0 = curve:PosAt(s0)
		local p1 = curve:PosAt(s1)
		local chord = (p1 - p0).Magnitude
		if chord < EPSILON then
			continue
		end
		local middle = (p0 + p1) * 0.5
		local roadFrame = bankedFrameAt((s0 + s1) * 0.5)
		local frame = safeLookAt(middle, middle + (p1 - p0), roadFrame.UpVector)
		frame = frame + roadFrame.UpVector * offset
		local depth = proceduralDepth(curve, s0, s1, math.abs(roadCenterOffset) + outerWidth / 2)
		local floorTop = -settings.RoadThicknessStuds + interfaceOverlap
		local wallBottom = floorTop - thickness
		local fullWallHeight = wallTop - wallBottom
		local wallY = (wallTop + wallBottom) / 2

		makeStructurePart(
			string.format("Base_%04d", index),
			Vector3.new(outerWidth, baseThickness, depth),
			frame * CFrame.new(roadCenterOffset, floorTop - baseThickness / 2, 0),
			concreteColor,
			baseMaterial,
			folder
		)
		makeStructurePart(
			string.format("WallLeft_%04d", index),
			Vector3.new(thickness, fullWallHeight, depth),
			frame * CFrame.new(roadCenterOffset - innerHalfWidth - thickness / 2, wallY, 0),
			wallColor,
			wallMaterial,
			folder
		)
		makeStructurePart(
			string.format("WallRight_%04d", index),
			Vector3.new(thickness, fullWallHeight, depth),
			frame * CFrame.new(roadCenterOffset + innerHalfWidth + thickness / 2, wallY, 0),
			wallColor,
			wallMaterial,
			folder
		)
		for archIndex = 1, TUNNEL_ARCH_SEGMENTS do
			local theta0 = math.pi * (archIndex - 1) / TUNNEL_ARCH_SEGMENTS
			local theta1 = math.pi * archIndex / TUNNEL_ARCH_SEGMENTS
			local x0 = -innerHalfWidth * math.cos(theta0)
			local y0 = wallTop + roofRise * math.sin(theta0)
			local x1 = -innerHalfWidth * math.cos(theta1)
			local y1 = wallTop + roofRise * math.sin(theta1)
			local panelWidth = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2) + 0.08
			local panelAngle = math.atan2(y1 - y0, x1 - x0)
			makeStructurePart(
				string.format("Vault_%02d_%04d", archIndex, index),
				Vector3.new(panelWidth, thickness, depth),
				frame * CFrame.new(roadCenterOffset + (x0 + x1) / 2, (y0 + y1) / 2, 0) * CFrame.Angles(0, 0, panelAngle),
				roofColor,
				roofMaterial,
				folder
			)
		end
		partCount += partsPerSegment
	end
	return partCount
end

local function restyleElevatedMedian(road: Model, enabled: boolean, baseColor: Color3, baseMaterial: Enum.Material)
	for _, child in road:GetChildren() do
		if not child:IsA("BasePart") or child.Name ~= "Median" then
			continue
		end
		local part = child :: BasePart
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
			part.Material = baseMaterial
			part.Color = baseColor
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
	local baseMaterial = StructureMaterials.Resolve(data.BaseMaterial)
	local existingStructure = road:FindFirstChild(GENERATED_NAME)
	local existingMode = if existingStructure then existingStructure:GetAttribute("RW_StructureMode") else nil
	local proceduralSurfacePresent = hasGeneratedRoadSurface(road)
	if data.Mode == "None" then
		if existingMode == "Ground" and not proceduralSurfacePresent then
			return false,
				"Rebuild the procedural road surface before removing its custom Ground module; the existing road was kept visible."
		end
		restyleElevatedMedian(road, false, concreteColor, baseMaterial)
		StructureBuilder.Clear(road)
		return true, "Ground-level road; no generated structure."
	end
	if data.Mode ~= "Ground" and existingMode == "Ground" and not proceduralSurfacePresent then
		return false,
			"Rebuild the procedural road surface before changing away from a custom Ground module; the existing road was kept visible."
	end
	if data.Mode == "Ground" and not data.AssetId then
		return false,
			if existingMode == "Ground" and not proceduralSurfacePresent
				then "Choose an imported Ground road module. The existing custom road was kept as a safe fallback."
				else "Choose an imported Ground road module. The procedural road was kept as a safe fallback."
	end

	local generated = makeGeneratedModel()
	local moduleCount = 0
	local proceduralPartCount = 0
	local moduleFitWarning: string? = nil
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
		local count, err, fitWarning =
			placeModules(generated, road, curve, asset, data.ModuleOffsetM * settings.MetersToStuds, settings)
		if err then
			generated:Destroy()
			return false, err
		end
		moduleCount = count
		moduleFitWarning = fitWarning
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

	-- Commit only after the complete replacement exists. Keep the previous
	-- structure and/or procedural surface visible through every validation and
	-- clone failure above. Parenting the pending replacement before suppressing
	-- Ground Parts also prevents a failed Parent assignment from blanking a road.
	generated.Name = GENERATED_NAME .. "_Pending"
	local parented = pcall(function()
		generated.Parent = road
	end)
	if not parented then
		generated:Destroy()
		return false, "Roblox could not attach the completed structure; the existing road was kept visible."
	end
	restyleElevatedMedian(road, data.Mode == "Viaduct" and data.ConcreteMedian, concreteColor, baseMaterial)
	local suppressedSurfacePartCount = if data.Mode == "Ground" then suppressGeneratedRoadSurface(road) else 0
	generated:SetAttribute("RW_SuppressedSurfacePartCount", suppressedSurfacePartCount)
	if existingStructure and existingStructure.Parent then
		existingStructure:Destroy()
	end
	generated.Name = GENERATED_NAME

	if data.Mode == "Ground" then
		return true,
			string.format(
				"Built %d rigid custom ground-road modules and replaced %d procedural surface parts.%s",
				moduleCount,
				suppressedSurfacePartCount,
				if moduleFitWarning then " " .. moduleFitWarning else ""
			)
	end
	if data.Mode == "Viaduct" then
		if data.AssetId then
			return true,
				string.format(
					"Built %d custom viaduct modules and %d raycast piers.%s",
					moduleCount,
					pierCount,
					if moduleFitWarning then " " .. moduleFitWarning else ""
				)
		end
		return true,
			string.format(
				"Built a procedural viaduct deck and parapets with %d parts and %d raycast piers.",
				proceduralPartCount,
				pierCount
			)
	end
	if data.AssetId then
		return true,
			string.format(
				"Built %d custom tunnel modules. Terrain excavation is explicit.%s",
				moduleCount,
				if moduleFitWarning then " " .. moduleFitWarning else ""
			)
	end
	return true,
		string.format(
			"Built a procedural tunnel base, walls, and arched vault with %d parts. Terrain excavation is explicit.",
			proceduralPartCount
		)
end

return StructureBuilder
