--!strict
-- Game-owned library for rigid road and structure modules imported from Studio.
--
-- A user selects any Workspace Model, then imports it as a Ground, Viaduct,
-- or Tunnel module. The clone lives in
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

export type AssetKind = "Ground" | "Viaduct" | "Tunnel"
export type SocketMode = "Explicit" | "Automatic"
export type AssetInfo = {
	Id: string,
	Name: string,
	Kind: AssetKind,
	LengthStuds: number,
	WidthStuds: number,
	HeightStuds: number,
	DepthStuds: number,
	SocketMode: SocketMode,
	Warnings: string?,
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

local function hierarchySnapshot(root: Model): ({ Instance }, { [Instance]: boolean }, number)
	local instances: { Instance } = { root }
	local archivable: { [Instance]: boolean } = {}
	local basePartCount = 0
	for _, descendant in root:GetDescendants() do
		table.insert(instances, descendant)
		if descendant:IsA("BasePart") then
			basePartCount += 1
		end
	end
	for _, instance in instances do
		archivable[instance] = instance.Archivable
	end
	return instances, archivable, basePartCount
end

local function cloneHierarchyMatches(source: Instance, clone: Instance): boolean
	if source.ClassName ~= clone.ClassName or source.Name ~= clone.Name then
		return false
	end
	local sourceChildren = source:GetChildren()
	local cloneChildren = clone:GetChildren()
	if #sourceChildren ~= #cloneChildren then
		return false
	end
	for index, sourceChild in sourceChildren do
		if not cloneHierarchyMatches(sourceChild, cloneChildren[index]) then
			return false
		end
	end
	return true
end

-- Clone every descendant or return no Model at all. Instance:Clone silently
-- omits descendants whose own Archivable flag is false, which is unacceptable
-- for a rigid road module: losing one kerb/barrier/socket and then suppressing
-- the procedural road would turn a recoverable asset problem into missing
-- geometry. Temporarily enable the complete hierarchy, restore the source in
-- all outcomes, and deliberately keep the complete clone archivable so its
-- geometry survives saving the asset library and placed road to the place file.
function StructureAssets.CloneComplete(source: Model): (Model?, string?)
	local instances, authoredArchivable, expectedBaseParts = hierarchySnapshot(source)
	local cloneResult: Instance? = nil
	local okClone = pcall(function()
		for _, instance in instances do
			if not authoredArchivable[instance] then
				instance.Archivable = true
			end
		end
		cloneResult = source:Clone()
	end)
	for _, instance in instances do
		local authored = authoredArchivable[instance]
		if not authored then
			pcall(function()
				instance.Archivable = false
			end)
		end
	end

	local clone: Model? = if okClone and cloneResult and cloneResult:IsA("Model") then cloneResult else nil
	if not clone then
		return nil, "Roblox could not clone the complete selected Model."
	end

	local clonedBaseParts = 0
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			clonedBaseParts += 1
		end
	end
	if
		not cloneHierarchyMatches(source, clone :: Model)
		or #clone:GetDescendants() ~= #instances - 1
		or clonedBaseParts ~= expectedBaseParts
	then
		clone:Destroy()
		return nil, "Roblox omitted part of the selected Model hierarchy while cloning it."
	end
	return clone, nil
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

local function socketCount(model: Model, name: string): number
	local count = 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Attachment") and descendant.Name == name then
			count += 1
		end
	end
	return count
end

local function boundingDimensions(model: Model): (CFrame, Vector3)
	local frame, size = model:GetBoundingBox()
	return frame, size
end

local function socketBoundsExcess(boxFrame: CFrame, boxSize: Vector3, position: Vector3): number
	local localPosition = boxFrame:PointToObjectSpace(position)
	local half = boxSize / 2
	return math.max(
		math.abs(localPosition.X) - half.X,
		math.abs(localPosition.Y) - half.Y,
		math.abs(localPosition.Z) - half.Z,
		0
	)
end

-- Socket checks deliberately distinguish unsafe geometry from uncommon but
-- useful authoring. A portal may put a socket slightly outside its visible
-- bounds to create an overlap joint, so that is a warning. Duplicate sockets,
-- a single half-defined pair, overlapping endpoints, or sockets many model
-- widths away are errors because placement would otherwise be ambiguous.
local function validateSockets(
	model: Model,
	startSocket: Attachment,
	endSocket: Attachment,
	autoSockets: boolean
): ({ string }?, string?)
	local startPosition = startSocket.WorldPosition
	local endPosition = endSocket.WorldPosition
	local chord = endPosition - startPosition
	local length = chord.Magnitude
	if length < 0.1 then
		return nil, "EasyRoadStart and EasyRoadEnd must be at least 0.1 studs apart."
	end

	local warnings: { string } = {}
	local boxFrame, boxSize = boundingDimensions(model)
	local largestDimension = math.max(boxSize.X, boxSize.Y, boxSize.Z)
	local hardOutsideLimit = math.max(16, largestDimension * 2)
	local softOutsideLimit = math.max(0.5, length * 0.15)
	local startExcess = socketBoundsExcess(boxFrame, boxSize, startPosition)
	local endExcess = socketBoundsExcess(boxFrame, boxSize, endPosition)
	local worstExcess = math.max(startExcess, endExcess)
	if worstExcess > hardOutsideLimit then
		return nil,
			"A socket is far outside the Model bounds. Move EasyRoadStart/EasyRoadEnd back to the intended joints."
	elseif worstExcess > softOutsideLimit then
		table.insert(
			warnings,
			"Sockets extend outside the visible bounds; keep this only for a deliberate overlap joint"
		)
	end

	if not autoSockets then
		local axis = chord.Unit
		if startSocket.WorldCFrame.LookVector:Dot(axis) < 0.35 then
			table.insert(warnings, "EasyRoadStart does not look toward EasyRoadEnd; placement uses the socket chord")
		end
		if startSocket.WorldCFrame.UpVector:Dot(endSocket.WorldCFrame.UpVector) < 0 then
			table.insert(warnings, "Socket UpVectors face opposite directions; the Start UpVector controls module roll")
		end
	end
	return warnings, nil
end

local function infoFromModel(model: Model): AssetInfo?
	local id = model:GetAttribute("ER_AssetId")
	local kind = model:GetAttribute("ER_AssetKind")
	local length = model:GetAttribute("ER_ModuleLengthStuds")
	if
		typeof(id) ~= "string"
		or (kind ~= "Ground" and kind ~= "Viaduct" and kind ~= "Tunnel")
		or typeof(length) ~= "number"
	then
		return nil
	end
	local socketMode = model:GetAttribute("ER_SocketMode")
	if socketMode ~= "Explicit" and socketMode ~= "Automatic" then
		socketMode = if model:GetAttribute("ER_AutoSockets") == true then "Automatic" else "Explicit"
	end
	local rawWidth = model:GetAttribute("ER_BoundsWidthStuds")
	local rawHeight = model:GetAttribute("ER_BoundsHeightStuds")
	local rawDepth = model:GetAttribute("ER_BoundsDepthStuds")
	local width: number? = if typeof(rawWidth) == "number" then rawWidth else nil
	local height: number? = if typeof(rawHeight) == "number" then rawHeight else nil
	local depth: number? = if typeof(rawDepth) == "number" then rawDepth else nil
	local rawWarnings = model:GetAttribute("ER_AssetWarnings")
	local warningText: string? = if typeof(rawWarnings) == "string" and rawWarnings ~= "" then rawWarnings else nil

	-- New assets cache their import-time bounds, so listing a large library is
	-- metadata-only. Legacy/damaged entries may lack those attributes; keep that
	-- migration fallback protected because GetBoundingBox can reject a Model
	-- whose BaseParts were removed by a user editing ServerStorage directly.
	if width == nil or height == nil or depth == nil then
		local fallbackSize: Vector3? = nil
		local readable = pcall(function()
			local _, size = boundingDimensions(model)
			fallbackSize = size
		end)
		if readable and fallbackSize then
			local size = fallbackSize :: Vector3
			width = width or size.X
			height = height or size.Y
			depth = depth or size.Z
		else
			warningText = (if warningText then warningText .. "; " else "")
				.. "Stored Model bounds are unreadable; export or re-import the asset"
		end
	end
	return {
		Id = id,
		Name = model.Name,
		Kind = kind :: AssetKind,
		LengthStuds = length,
		WidthStuds = width or 0,
		HeightStuds = height or 0,
		DepthStuds = depth or 0,
		SocketMode = socketMode :: SocketMode,
		Warnings = warningText,
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

	local clone, cloneError = StructureAssets.CloneComplete(asset)
	if not clone then
		return nil, cloneError or "Roblox could not clone the selected road asset."
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

	local clone, cloneError = StructureAssets.CloneComplete(source)
	if not clone then
		return nil, cloneError or "Roblox could not clone the selected Model."
	end
	clone.Archivable = true
	if not hasBasePart(clone) then
		clone:Destroy()
		return nil, "The selected Model's BaseParts are not archivable."
	end
	local startCount = socketCount(clone, START_SOCKET)
	local endCount = socketCount(clone, END_SOCKET)
	if startCount > 1 or endCount > 1 then
		clone:Destroy()
		return nil, "Keep exactly one EasyRoadStart and one EasyRoadEnd Attachment in the Model."
	end
	if (startCount == 1) ~= (endCount == 1) then
		clone:Destroy()
		return nil, "Add both EasyRoadStart and EasyRoadEnd, or remove the lone socket to use automatic bounds."
	end

	local startSocket, endSocket, autoSockets = ensureSockets(clone)
	local warnings, socketError = validateSockets(clone, startSocket, endSocket, autoSockets)
	if socketError then
		clone:Destroy()
		return nil, socketError
	end
	local length = (endSocket.WorldPosition - startSocket.WorldPosition).Magnitude
	local _, bounds = boundingDimensions(clone)
	local warningText = if warnings and #warnings > 0 then table.concat(warnings, "; ") else nil

	local id = HttpService:GenerateGUID(false)
	clone:SetAttribute("ER_Asset", true)
	clone:SetAttribute("ER_AssetId", id)
	clone:SetAttribute("ER_AssetKind", kind)
	clone:SetAttribute("ER_ModuleLengthStuds", length)
	clone:SetAttribute("ER_AutoSockets", autoSockets)
	clone:SetAttribute("ER_SocketMode", if autoSockets then "Automatic" else "Explicit")
	clone:SetAttribute("ER_BoundsWidthStuds", bounds.X)
	clone:SetAttribute("ER_BoundsHeightStuds", bounds.Y)
	clone:SetAttribute("ER_BoundsDepthStuds", bounds.Z)
	clone:SetAttribute("ER_ModuleFit", "RigidRepeat")
	clone:SetAttribute("ER_AssetWarnings", warningText)
	local folder = assetsFolder(true)
	assert(folder, "EasyRoadAssets folder creation failed")
	clone.Parent = folder

	return {
		Id = id,
		Name = clone.Name,
		Kind = kind,
		LengthStuds = length,
		WidthStuds = bounds.X,
		HeightStuds = bounds.Y,
		DepthStuds = bounds.Z,
		SocketMode = if autoSockets then "Automatic" else "Explicit",
		Warnings = warningText,
	},
		(if autoSockets
			then "Imported with automatic bounding-box sockets; add EasyRoadStart/EasyRoadEnd Attachments for precise joints."
			else "Imported using EasyRoadStart/EasyRoadEnd Attachments.") .. (if warningText
			then " Warning: " .. warningText .. "."
			else "")
end

return StructureAssets
