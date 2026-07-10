--!strict
-- Reads and writes JunctionNode models: the shared point multiple roads
-- connect to, replacing pure positional coincidence with a real reference
-- (see TODO.md's "Junctions & intersections" section for the design this
-- implements). Follows RoadInstance.lua's own convention - all data lives
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
			local pos = child:GetAttribute("RW_Position") :: Vector3?
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
	model.Parent = getJunctionsFolder(true)
	return model
end

function JunctionInstance.Read(model: Model): JunctionData?
	local id = model:GetAttribute("RW_JunctionId")
	local position = model:GetAttribute("RW_Position")
	if typeof(id) ~= "string" or typeof(position) ~= "Vector3" then
		return nil
	end
	return { Id = id, Position = position }
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
