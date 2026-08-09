--!strict
-- Game-owned library for rigid road structure modules imported from Studio.
--
-- A user Ctrl-selects a placed EasyRoad road plus any workspace Model, then
-- imports that Model as either a Viaduct or Tunnel module. The clone lives in
-- ServerStorage/EasyRoadAssets so it remains editable and saved with the place
-- without rendering an extra copy in the world.
--
-- Preferred socket contract:
--   EasyRoadStart  Attachment at the module's start, looking along the module
--   EasyRoadEnd    Attachment at the module's end
--
-- Models without sockets remain useful: the importer creates them at the
-- oriented bounding box's +/-Z faces. Explicit sockets are still recommended
-- for asymmetric decks, tunnel portals, and deliberate overlap joints.

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

export type AssetKind = "Viaduct" | "Tunnel"
export type AssetInfo = {
	Id: string,
	Name: string,
	Kind: AssetKind,
	LengthStuds: number,
}

local FOLDER_NAME = "EasyRoadAssets"
local START_SOCKET = "EasyRoadStart"
local END_SOCKET = "EasyRoadEnd"

local StructureAssets = {}

local function hasBasePart(model: Model): boolean
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			return true
		end
	end
	return false
end

local function assetsFolder(create: boolean): Folder?
	local existing = ServerStorage:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if not create then
		return nil
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder:SetAttribute("ER_AssetLibrary", true)
	folder.Parent = ServerStorage
	return folder
end

function StructureAssets.GetFolder(create: boolean): Folder?
	return assetsFolder(create)
end

function StructureAssets.FindSocket(model: Model, name: string): Attachment?
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Attachment") and descendant.Name == name then
			return descendant
		end
	end
	return nil
end

local function ensureSockets(model: Model): (Attachment, Attachment, boolean)
	local startSocket = StructureAssets.FindSocket(model, START_SOCKET)
	local endSocket = StructureAssets.FindSocket(model, END_SOCKET)
	if startSocket and endSocket then
		return startSocket, endSocket, false
	end

	local boxFrame, boxSize = model:GetBoundingBox()
	local socketPart = Instance.new("Part")
	socketPart.Name = "EasyRoadSockets"
	socketPart.Size = Vector3.new(0.1, 0.1, 0.1)
	socketPart.CFrame = boxFrame
	socketPart.Transparency = 1
	socketPart.Anchored = true
	socketPart.CanCollide = false
	socketPart.CanQuery = false
	socketPart.CanTouch = false
	socketPart.CastShadow = false
	socketPart.Parent = model

	-- Roblox CFrames look down local -Z, so +Z is the start face and -Z is
	-- the end face for a conventional forward-facing module.
	if not startSocket then
		local generated = Instance.new("Attachment")
		generated.Name = START_SOCKET
		generated.CFrame = CFrame.new(0, 0, boxSize.Z / 2)
		generated:SetAttribute("ER_AutoSocket", true)
		generated.Parent = socketPart
		startSocket = generated
	end
	if not endSocket then
		local generated = Instance.new("Attachment")
		generated.Name = END_SOCKET
		generated.CFrame = CFrame.new(0, 0, -boxSize.Z / 2)
		generated:SetAttribute("ER_AutoSocket", true)
		generated.Parent = socketPart
		endSocket = generated
	end
	return startSocket :: Attachment, endSocket :: Attachment, true
end

local function infoFromModel(model: Model): AssetInfo?
	local id = model:GetAttribute("ER_AssetId")
	local kind = model:GetAttribute("ER_AssetKind")
	local length = model:GetAttribute("ER_ModuleLengthStuds")
	if typeof(id) ~= "string" or (kind ~= "Viaduct" and kind ~= "Tunnel") or typeof(length) ~= "number" then
		return nil
	end
	return {
		Id = id,
		Name = model.Name,
		Kind = kind :: AssetKind,
		LengthStuds = length,
	}
end

function StructureAssets.List(kind: AssetKind?): { AssetInfo }
	local result: { AssetInfo } = {}
	local folder = assetsFolder(false)
	if not folder then
		return result
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			local info = infoFromModel(child)
			if info and (kind == nil or info.Kind == kind) then
				table.insert(result, info)
			end
		end
	end
	table.sort(result, function(a, b)
		if a.Name == b.Name then
			return a.Id < b.Id
		end
		return a.Name:lower() < b.Name:lower()
	end)
	return result
end

function StructureAssets.Get(assetId: string): Model?
	local folder = assetsFolder(false)
	if not folder then
		return nil
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("ER_AssetId") == assetId then
			return child
		end
	end
	return nil
end

function StructureAssets.UsageCount(assetId: string): number
	local count = 0
	for _, descendant in workspace:GetDescendants() do
		if not descendant:IsA("Model") or descendant:GetAttribute("RW_Road") ~= true then
			continue
		end
		local raw = descendant:GetAttribute("RW_StructureJson")
		if typeof(raw) ~= "string" then
			continue
		end
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok and typeof(decoded) == "table" and decoded.AssetId == assetId then
			count += 1
		end
	end
	return count
end

local function uniqueWorkspaceName(requestedName: string): string
	if not workspace:FindFirstChild(requestedName) then
		return requestedName
	end

	local base = requestedName .. " Export"
	if not workspace:FindFirstChild(base) then
		return base
	end

	local suffix = 2
	while workspace:FindFirstChild(string.format("%s %d", base, suffix)) do
		suffix += 1
	end
	return string.format("%s %d", base, suffix)
end

-- Creates an editable Workspace copy without changing the stored library
-- Model. Its ER_AssetId and other metadata are deliberately preserved: the
-- clone is an exported copy of that asset, while List() continues to read only
-- ServerStorage/EasyRoadAssets and UsageCount() continues to count only roads.
function StructureAssets.ExportToWorkspace(assetId: string): (Model?, string)
	local asset = StructureAssets.Get(assetId)
	if not asset then
		return nil, "That road asset no longer exists."
	end

	-- Library Models are normally archivable, but users can edit them directly
	-- in ServerStorage. Temporarily permit cloning and restore their setting so
	-- exporting never modifies the stored asset's final state.
	local wasArchivable = asset.Archivable
	asset.Archivable = true
	local okClone, cloneResult = pcall(function()
		return asset:Clone()
	end)
	asset.Archivable = wasArchivable

	local clone: Model? = if okClone and cloneResult and cloneResult:IsA("Model") then cloneResult else nil
	if not clone then
		return nil, "Roblox could not clone the selected road asset."
	end

	clone.Name = uniqueWorkspaceName(asset.Name)
	clone.Parent = workspace
	return clone, string.format("Exported %s to Workspace.", clone.Name)
end

function StructureAssets.Rename(assetId: string, requestedName: string): (boolean, string)
	local asset = StructureAssets.Get(assetId)
	if not asset then
		return false, "That road asset no longer exists."
	end
	local name = requestedName:match("^%s*(.-)%s*$") or ""
	if name == "" then
		return false, "Asset name cannot be empty."
	end
	asset.Name = name
	return true, "Renamed road asset to " .. name .. "."
end

function StructureAssets.Delete(assetId: string): (boolean, string)
	local asset = StructureAssets.Get(assetId)
	if not asset then
		return false, "That road asset no longer exists."
	end
	local uses = StructureAssets.UsageCount(assetId)
	if uses > 0 then
		return false,
			string.format(
				"This asset is used by %d placed road%s. Change those roads before deleting it.",
				uses,
				if uses == 1 then "" else "s"
			)
	end
	local name = asset.Name
	asset:Destroy()
	return true, "Deleted road asset " .. name .. "."
end

-- Finds a source Model in a multi-selection containing the selected road too.
-- A selected BasePart inside a Model is accepted; its nearest Model ancestor is
-- used. Generated road/structure descendants and already-imported assets are
-- deliberately ignored.
function StructureAssets.FindImportCandidate(selection: { Instance }, selectedRoad: Model?): Model?
	local folder = assetsFolder(false)
	for _, instance in selection do
		local candidate: Model? = nil
		if instance:IsA("Model") then
			candidate = instance
		else
			local ancestor = instance:FindFirstAncestorOfClass("Model")
			if ancestor and ancestor:IsA("Model") then
				candidate = ancestor
			end
		end
		if not candidate then
			continue
		end
		if candidate == selectedRoad or (selectedRoad and candidate:IsDescendantOf(selectedRoad)) then
			continue
		end
		if candidate:GetAttribute("RW_Road") == true or candidate:GetAttribute("RW_StructureGenerated") == true then
			continue
		end
		if folder and candidate:IsDescendantOf(folder) then
			continue
		end
		return candidate
	end
	return nil
end

function StructureAssets.Import(source: Model, kind: AssetKind): (AssetInfo?, string)
	if not hasBasePart(source) then
		return nil, "The selected Model has no BaseParts."
	end

	-- Clone() returns nil for an unarchivable source. Preserve the user's flag.
	local wasArchivable = source.Archivable
	source.Archivable = true
	local okClone, cloneResult = pcall(function()
		return source:Clone()
	end)
	source.Archivable = wasArchivable
	local clone: Model? = if okClone and cloneResult and cloneResult:IsA("Model") then cloneResult else nil
	if not clone then
		return nil, "Roblox could not clone the selected Model."
	end
	clone.Archivable = true
	if not hasBasePart(clone) then
		clone:Destroy()
		return nil, "The selected Model's BaseParts are not archivable."
	end

	local startSocket, endSocket, autoSockets = ensureSockets(clone)
	local length = (endSocket.WorldPosition - startSocket.WorldPosition).Magnitude
	if length < 0.1 then
		clone:Destroy()
		return nil, "EasyRoadStart and EasyRoadEnd must be at least 0.1 studs apart."
	end

	local id = HttpService:GenerateGUID(false)
	clone:SetAttribute("ER_Asset", true)
	clone:SetAttribute("ER_AssetId", id)
	clone:SetAttribute("ER_AssetKind", kind)
	clone:SetAttribute("ER_ModuleLengthStuds", length)
	clone:SetAttribute("ER_AutoSockets", autoSockets)
	local folder = assetsFolder(true)
	assert(folder, "EasyRoadAssets folder creation failed")
	clone.Parent = folder

	return {
		Id = id,
		Name = clone.Name,
		Kind = kind,
		LengthStuds = length,
	},
		if autoSockets
			then "Imported with automatic bounding-box sockets; add EasyRoadStart/EasyRoadEnd Attachments for precise joints."
			else "Imported using EasyRoadStart/EasyRoadEnd Attachments."
end

return StructureAssets
