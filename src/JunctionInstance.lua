--!strict
-- Reads and writes JunctionNode models: the shared point multiple roads
-- connect to, replacing pure positional coincidence with a real reference
-- (see docs/architecture.md). Follows RoadInstance.lua's convention: data lives
-- as attributes on the model itself.
--
-- A road references the junction it starts/ends at by Id (RW_StartJunctionId
-- / RW_EndJunctionId attributes on the Road model, see RoadInstance.lua) -
-- the junction itself doesn't keep a reverse list of its roads; that list is
-- derived by scanning the Roads folder for matching Ids (ConnectedRoads
-- below). Same "single source of truth, no dual bookkeeping to desync"
-- choice RoadInstance already makes for Bay/MarkingStretches/KerbStretches.

local HttpService = game:GetService("HttpService")

export type JunctionData = {
	Id: string,
	Position: Vector3,
	-- A Junction controller remains authoritative after conversion to a
	-- roundabout. Older controllers have no kind attribute and are ordinary
	-- intersections by definition.
	Kind: "Intersection" | "Roundabout",
	RoundaboutRadiusStuds: number?,
	RoundaboutLaneCount: number?,
	RoundaboutLaneWidthM: number?,
	-- Optional user overrides (node controller). nil = builder defaults.
	FilletRadiusM: number?,
	-- Per-roundabout override of the region's default circulating-lane marking
	-- style: "Continuous" | "Turbo". nil = follow the region.
	--
	-- Typed as a plain string, and validated against the local list below,
	-- rather than importing RegionStyles' union. This module is a leaf that
	-- everything else reads, and it does not otherwise depend on RegionStyles -
	-- worth keeping that way for one field.
	RoundaboutMarkings: string?,
	-- Per-roundabout overrides of the region's defaults. nil = follow region.
	RoundaboutSidewalk: boolean?,
	RoundaboutIsland: boolean?,
	PadMarginStuds: number?,
	-- Optional per-approach replacements for PadMarginStuds, keyed by the
	-- connected road ENDPOINT'S stable port id.  The junction still derives
	-- its approach list from roads; this map stores editing intent only.  A
	-- missing entry follows PadMarginStuds (or the builder default).
	ApproachSetbacksStuds: { [string]: number },
	-- Multinode v2 controller. Approaches are derived from connected roads;
	-- only editing intent lives here, avoiding a second topology list that can
	-- desynchronise. Legacy junctions read as linked with no overrides.
	LinkedCornerRadii: boolean,
	CornerRadiiM: { [string]: number },
}

local JunctionInstance = {}

local JUNCTIONS_FOLDER_NAME = "Junctions"
local ROADS_FOLDER_NAME = "Roads"

function JunctionInstance.IsJunction(instance: Instance?): boolean
	return instance ~= nil and instance:IsA("Model") and instance:GetAttribute("RW_Junction") == true
end

local function getJunctionsFolder(create: boolean): Folder?
	local existing = workspace:FindFirstChild(JUNCTIONS_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing :: Folder
	end
	if create then
		local folder = Instance.new("Folder")
		folder.Name = JUNCTIONS_FOLDER_NAME
		folder.Parent = workspace
		return folder
	end
	return nil
end

-- Finds an existing junction within radiusStuds of position, so repeated
-- snapping to the same physical point (e.g. a third road placed onto a
-- corner two others already share) reuses one node instead of stacking
-- duplicates on top of each other.
function JunctionInstance.FindNear(position: Vector3, radiusStuds: number): Model?
	local folder = getJunctionsFolder(false)
	if not folder then
		return nil
	end
	local best: Model? = nil
	local bestDistance = radiusStuds
	for _, child in folder:GetChildren() do
		if JunctionInstance.IsJunction(child) then
			local data = JunctionInstance.Read(child :: Model)
			local pos = if data and data.Kind ~= "Roundabout" then data.Position else nil
			if pos then
				local d = (pos - position).Magnitude
				if d < bestDistance then
					bestDistance = d
					best = child :: Model
				end
			end
		end
	end
	return best
end

function JunctionInstance.FindById(id: string): Model?
	local folder = getJunctionsFolder(false)
	if not folder then
		return nil
	end
	for _, child in folder:GetChildren() do
		if JunctionInstance.IsJunction(child) and child:GetAttribute("RW_JunctionId") == id then
			return child :: Model
		end
	end
	return nil
end

-- Creates a new, empty junction node (no fillet-pad geometry yet - see
-- JunctionBuilder.Rebuild, called separately once the roads referencing it
-- are stamped) at the given position and parents it.
function JunctionInstance.Create(position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "Junction"
	model:SetAttribute("RW_Junction", true)
	model:SetAttribute("RW_JunctionId", HttpService:GenerateGUID(false))
	model:SetAttribute("RW_Position", position)
	model:SetAttribute("RW_JunctionKind", "Intersection")
	model:SetAttribute("RW_MultiNodeVersion", 2)
	model:SetAttribute("RW_LinkedCornerRadii", true)
	model.Parent = getJunctionsFolder(true)
	return model
end

-- Kept in step with RegionStyles.RoundaboutMarkingStyles by hand; the two are
-- deliberately not coupled (see the JunctionData field note).
local ROUNDABOUT_MARKING_STYLES = { "Continuous", "SolidLanes", "Turbo" }

local function finiteNumber(value: any): number?
	if typeof(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return nil
end

local function positiveNumber(value: any): number?
	local number = finiteNumber(value)
	if number and number > 0 then
		return number
	end
	return nil
end

local function positiveInteger(value: any): number?
	local number = positiveNumber(value)
	if number and number == math.floor(number) then
		return number
	end
	return nil
end

function JunctionInstance.Read(model: Model): JunctionData?
	local id = model:GetAttribute("RW_JunctionId")
	local position = model:GetAttribute("RW_Position")
	if typeof(id) ~= "string" or typeof(position) ~= "Vector3" then
		return nil
	end
	local fillet = model:GetAttribute("RW_FilletRadiusM")
	local margin = model:GetAttribute("RW_PadMarginStuds")
	local kind = model:GetAttribute("RW_JunctionKind")
	local roundaboutRadius = model:GetAttribute("RW_RoundaboutRadiusStuds")
	local roundaboutLaneCount = model:GetAttribute("RW_RoundaboutLaneCount")
	local roundaboutLaneWidth = model:GetAttribute("RW_RoundaboutLaneWidthM")
	local markings = model:GetAttribute("RW_RoundaboutMarkings")
	local ringWalk = model:GetAttribute("RW_RoundaboutSidewalk")
	local ringIsland = model:GetAttribute("RW_RoundaboutIsland")
	local linked = model:GetAttribute("RW_LinkedCornerRadii")
	local approachSetbacks: { [string]: number } = {}
	local rawApproachSetbacks = model:GetAttribute("RW_ApproachSetbacksJson")
	if typeof(rawApproachSetbacks) == "string" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, rawApproachSetbacks)
		if ok and typeof(decoded) == "table" then
			for approachId, setback in decoded do
				local validSetback = finiteNumber(setback)
				if typeof(approachId) == "string" and approachId ~= "" and validSetback then
					approachSetbacks[approachId] = math.clamp(validSetback, 1, 40)
				end
			end
		end
	end
	local cornerRadii: { [string]: number } = {}
	local rawCornerRadii = model:GetAttribute("RW_CornerRadiiJson")
	if typeof(rawCornerRadii) == "string" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, rawCornerRadii)
		if ok and typeof(decoded) == "table" then
			for cornerId, radius in decoded do
				local validRadius = finiteNumber(radius)
				if typeof(cornerId) == "string" and validRadius then
					cornerRadii[cornerId] = math.clamp(validRadius, 0.5, 40)
				end
			end
		end
	end
	return {
		Id = id,
		Position = position,
		Kind = if kind == "Roundabout" then "Roundabout" else "Intersection",
		RoundaboutRadiusStuds = positiveNumber(roundaboutRadius),
		RoundaboutLaneCount = positiveInteger(roundaboutLaneCount),
		RoundaboutLaneWidthM = positiveNumber(roundaboutLaneWidth),
		FilletRadiusM = finiteNumber(fillet),
		PadMarginStuds = finiteNumber(margin),
		ApproachSetbacksStuds = approachSetbacks,
		RoundaboutMarkings = if typeof(markings) == "string" and table.find(ROUNDABOUT_MARKING_STYLES, markings)
			then markings
			else nil,
		RoundaboutSidewalk = if typeof(ringWalk) == "boolean" then ringWalk else nil,
		RoundaboutIsland = if typeof(ringIsland) == "boolean" then ringIsland else nil,
		LinkedCornerRadii = if typeof(linked) == "boolean" then linked else true,
		CornerRadiiM = cornerRadii,
	}
end

function JunctionInstance.SetPosition(model: Model, position: Vector3)
	model:SetAttribute("RW_Position", position)
end

function JunctionInstance.SetKind(model: Model, kind: "Intersection" | "Roundabout")
	assert(kind == "Intersection" or kind == "Roundabout", "invalid junction kind")
	model:SetAttribute("RW_JunctionKind", kind)
end

function JunctionInstance.SetRoundaboutGeometry(
	model: Model,
	radiusStuds: number,
	laneCount: number,
	laneWidthM: number
)
	assert(positiveNumber(radiusStuds) ~= nil, "roundabout radius must be a finite positive number")
	assert(positiveInteger(laneCount) ~= nil, "roundabout lane count must be a finite positive integer")
	assert(positiveNumber(laneWidthM) ~= nil, "roundabout lane width must be a finite positive number")
	model:SetAttribute("RW_RoundaboutRadiusStuds", radiusStuds)
	model:SetAttribute("RW_RoundaboutLaneCount", laneCount)
	model:SetAttribute("RW_RoundaboutLaneWidthM", laneWidthM)
end

function JunctionInstance.SetFilletRadiusM(model: Model, radiusM: number?)
	model:SetAttribute("RW_FilletRadiusM", radiusM)
end

function JunctionInstance.SetRoundaboutMarkings(model: Model, kind: string?)
	model:SetAttribute("RW_RoundaboutMarkings", kind)
end

function JunctionInstance.SetRoundaboutSidewalk(model: Model, enabled: boolean?)
	model:SetAttribute("RW_RoundaboutSidewalk", enabled)
end

function JunctionInstance.SetRoundaboutIsland(model: Model, enabled: boolean?)
	model:SetAttribute("RW_RoundaboutIsland", enabled)
end

function JunctionInstance.SetPadMarginStuds(model: Model, marginStuds: number?)
	model:SetAttribute("RW_PadMarginStuds", marginStuds)
end

-- Stores one approach's setback independently of the derived topology list.
-- Do not prune disconnected ids here: keeping the stable port key lets
-- undo/reconnect and roundabout -> junction restoration recover the user's
-- exact editing intent. nil explicitly returns this approach to the global
-- PadMarginStuds value.
function JunctionInstance.SetApproachSetbackStuds(model: Model, approachId: string, setbackStuds: number?)
	assert(approachId ~= "", "approach id must not be empty")
	local data = JunctionInstance.Read(model)
	local setbacks = if data then table.clone(data.ApproachSetbacksStuds) else {}
	if setbackStuds == nil then
		setbacks[approachId] = nil
	else
		local validSetback = finiteNumber(setbackStuds)
		assert(validSetback ~= nil, "approach setback must be a finite number")
		setbacks[approachId] = math.clamp(validSetback :: number, 1, 40)
	end
	model:SetAttribute("RW_ApproachSetbacksJson", if next(setbacks) then HttpService:JSONEncode(setbacks) else nil)
end

function JunctionInstance.SetLinkedCornerRadii(model: Model, linked: boolean)
	model:SetAttribute("RW_MultiNodeVersion", 2)
	model:SetAttribute("RW_LinkedCornerRadii", linked)
end

function JunctionInstance.SetCornerRadiusM(model: Model, cornerId: string, radiusM: number?)
	local data = JunctionInstance.Read(model)
	local radii = if data then table.clone(data.CornerRadiiM) else {}
	if radiusM == nil then
		radii[cornerId] = nil
	else
		radii[cornerId] = math.clamp(radiusM, 0.5, 40)
	end
	model:SetAttribute("RW_MultiNodeVersion", 2)
	model:SetAttribute("RW_CornerRadiiJson", if next(radii) then HttpService:JSONEncode(radii) else nil)
end

function JunctionInstance.Delete(model: Model)
	model:Destroy()
end

function JunctionInstance.GetAll(): { Model }
	local folder = getJunctionsFolder(false)
	if not folder then
		return {}
	end
	local all: { Model } = {}
	for _, child in folder:GetChildren() do
		if JunctionInstance.IsJunction(child) then
			table.insert(all, child :: Model)
		end
	end
	return all
end

-- Scans the Roads folder for every road whose start or end references this
-- junction Id - see this file's header for why this is derived rather than
-- stored redundantly on the junction itself.
function JunctionInstance.ConnectedRoads(id: string): { Model }
	local folder = workspace:FindFirstChild(ROADS_FOLDER_NAME)
	local roads: { Model } = {}
	if not folder then
		return roads
	end
	for _, child in folder:GetChildren() do
		if
			child:GetAttribute("RW_Road") == true
			and (child:GetAttribute("RW_StartJunctionId") == id or child:GetAttribute("RW_EndJunctionId") == id)
		then
			table.insert(roads, child :: Model)
		end
	end
	return roads
end

return JunctionInstance
