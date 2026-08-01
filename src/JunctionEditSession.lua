--!strict
-- Selection-based junction editing + CivilArc-style node controller:
-- select a JunctionNode (pad click / Explorer) to show mouth markers and a
-- centre handle. Drag the centre to re-seat the node; panel sliders adjust
-- fillet radius and pad setback, then rebuild.

local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local UserInputService = game:GetService("UserInputService")

local Packages = script.Parent.Parent.Packages
local Signal = require(Packages.Signal)

local JunctionInstance = require("./JunctionInstance")
local JunctionBuilder = require("./Mesh/JunctionBuilder")
local RoadInstance = require("./RoadInstance")
local RegionStyles = require("./RegionStyles")
local Settings = require("./Settings")

export type JunctionEditSession = {
	ChangeSignal: Signal.Signal<>,
	GetSelectedJunction: () -> Model?,
	GetConnectedRoadCount: () -> number,
	GetSelectedJunctionPosition: () -> Vector3?,
	GetFilletRadiusM: () -> number,
	GetPadMarginStuds: () -> number,
	GetCornerCount: () -> number,
	GetLinkedCornerRadii: () -> boolean,
	GetSelectedCornerLabel: () -> string?,
	GetSelectedCornerRadiusM: () -> number?,
	SetFilletRadiusM: (value: number) -> (),
	SetPadMarginStuds: (value: number) -> (),
	SetLinkedCornerRadii: (linked: boolean) -> (),
	SetSelectedCornerRadiusM: (value: number) -> (),
	RebuildSelected: () -> (),
	DeleteJunction: () -> (),
	Destroy: () -> (),
}

local HANDLES_FOLDER_NAME = "EasyRoadJunctionHandles"
local CENTER_HANDLE_NAME = "CenterHandle"
local MOUTH_PREFIX = "Mouth_"

local function createJunctionEditSession(
	getStyle: () -> RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): JunctionEditSession
	local changeSignal = Signal.new()
	local selectedJunction: Model? = nil
	local handlesFolder: Folder? = nil
	local selectedCornerId: string? = nil
	local draggingCenter = false
	local dragPlaneY = 0
	local connections: { RBXScriptConnection } = {}

	local function clearHandles()
		if handlesFolder then
			handlesFolder:Destroy()
			handlesFolder = nil
		end
		draggingCenter = false
	end

	local function makeHandlePart(name: string, size: Vector3, color: Color3, shape: Enum.PartType?): Part
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = true
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = color
		part.Transparency = 0.25
		part.Size = size
		if shape then
			part.Shape = shape
		end
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		return part
	end

	local function refreshHandles()
		clearHandles()
		if not selectedJunction then
			return
		end
		local data = JunctionInstance.Read(selectedJunction)
		if not data then
			return
		end
		local layout = JunctionBuilder.GetLayout(data.Id, settings)
		if not layout then
			return
		end
		if selectedCornerId then
			local stillExists = false
			for _, corner in layout.Corners do
				if corner.Id == selectedCornerId then
					stillExists = true
					break
				end
			end
			if not stillExists then
				selectedCornerId = nil
			end
		end

		local folder = Instance.new("Folder")
		folder.Name = HANDLES_FOLDER_NAME
		folder.Parent = workspace
		handlesFolder = folder

		-- Centre node (draggable) — CivilArc-style primary control.
		local center = makeHandlePart(CENTER_HANDLE_NAME, Vector3.new(2.2, 2.2, 2.2), Color3.fromRGB(255, 200, 40), Enum.PartType.Ball)
		center.CFrame = CFrame.new(layout.Center + Vector3.new(0, 1.2, 0))
		center.Parent = folder

		-- Mouth markers: red bar across each approach cut (CivilArc corner line).
		for i, mouth in layout.Mouths do
			local left, right = mouth.Left, mouth.Right
			local mid = (left + right) * 0.5
			local len = (right - left).Magnitude
			if len > 0.1 then
				local bar = makeHandlePart(MOUTH_PREFIX .. i, Vector3.new(0.25, 0.25, len), Color3.fromRGB(255, 70, 70))
				bar.CFrame = CFrame.lookAt(mid + Vector3.new(0, 0.4, 0), right + Vector3.new(0, 0.4, 0))
				bar.Parent = folder
				local dotL = makeHandlePart(MOUTH_PREFIX .. i .. "_L", Vector3.new(0.7, 0.7, 0.7), Color3.fromRGB(255, 255, 255), Enum.PartType.Ball)
				dotL.CFrame = CFrame.new(left + Vector3.new(0, 0.5, 0))
				dotL.Parent = folder
				local dotR = makeHandlePart(MOUTH_PREFIX .. i .. "_R", Vector3.new(0.7, 0.7, 0.7), Color3.fromRGB(255, 255, 255), Enum.PartType.Ball)
				dotR.CFrame = CFrame.new(right + Vector3.new(0, 0.5, 0))
				dotR.Parent = folder
			end
		end

		-- Corner mid markers (cyan) — show which spans get curb returns.
		for i, corner in layout.Corners do
			local selected = corner.Id == selectedCornerId
			local size = if selected then 1.55 else 1.1
			local color = if selected then Color3.fromRGB(255, 165, 55) else Color3.fromRGB(80, 200, 255)
			local c = makeHandlePart("Corner_" .. i, Vector3.new(size, size, size), color, Enum.PartType.Ball)
			c:SetAttribute("RW_CornerId", corner.Id)
			c.CFrame = CFrame.new(corner.Mid + Vector3.new(0, 0.9, 0))
			c.Parent = folder
		end
	end

	local function rebuildSelected()
		if not selectedJunction then
			return
		end
		local data = JunctionInstance.Read(selectedJunction)
		if not data then
			return
		end
		local style = getStyle()
		JunctionBuilder.TrimApproaches(data.Id, style, settings)
		JunctionBuilder.Rebuild(data.Id, style, settings)
		refreshHandles()
		changeSignal:Fire()
	end

	local function loadSelection()
		local junction: Model? = nil
		for _, instance in Selection:Get() do
			local current: Instance? = instance
			while current do
				if JunctionInstance.IsJunction(current) then
					junction = current :: Model
					break
				end
				-- Also treat our handles as selecting the junction.
				if current.Name == HANDLES_FOLDER_NAME or (current.Parent and current.Parent.Name == HANDLES_FOLDER_NAME) then
					junction = selectedJunction
					break
				end
				current = current.Parent
			end
			if junction then
				break
			end
		end
		if junction == selectedJunction then
			return
		end
		selectedJunction = junction
		selectedCornerId = nil
		refreshHandles()
		changeSignal:Fire()
	end

	local function hitHandle(): BasePart?
		local camera = workspace.CurrentCamera
		if not camera or not handlesFolder then
			return nil
		end
		local mouse = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { handlesFolder }
		local result = workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
		return if result and result.Instance:IsA("BasePart") then result.Instance else nil
	end

	local function groundPointFromMouse(): Vector3?
		local camera = workspace.CurrentCamera
		if not camera then
			return nil
		end
		local mouse = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
		if math.abs(ray.Direction.Y) < 1e-6 then
			return nil
		end
		local t = (dragPlaneY - ray.Origin.Y) / ray.Direction.Y
		if t < 0 then
			return nil
		end
		local p = ray.Origin + ray.Direction * t
		return Vector3.new(p.X, dragPlaneY, p.Z)
	end

	table.insert(connections, Selection.SelectionChanged:Connect(loadSelection))

	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed or not selectedJunction then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				local handle = hitHandle()
				if handle and handle.Name == CENTER_HANDLE_NAME then
					local data = JunctionInstance.Read(selectedJunction)
					if data then
						draggingCenter = true
						dragPlaneY = data.Position.Y
					end
				elseif handle then
					local cornerId = handle:GetAttribute("RW_CornerId")
					if typeof(cornerId) == "string" then
						selectedCornerId = cornerId
						refreshHandles()
						changeSignal:Fire()
					end
				end
			end
		end)
	)

	table.insert(
		connections,
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 and draggingCenter then
				draggingCenter = false
				rebuildSelected()
			end
		end)
	)

	table.insert(
		connections,
		UserInputService.InputChanged:Connect(function(input)
			if not draggingCenter or not selectedJunction then
				return
			end
			if input.UserInputType ~= Enum.UserInputType.MouseMovement then
				return
			end
			local pos = groundPointFromMouse()
			if not pos then
				return
			end
			JunctionInstance.SetPosition(selectedJunction, pos)
			if handlesFolder then
				local centerPart = handlesFolder:FindFirstChild(CENTER_HANDLE_NAME)
				if centerPart and centerPart:IsA("BasePart") then
					centerPart.CFrame = CFrame.new(pos + Vector3.new(0, 1.2, 0))
				end
			end
		end)
	)

	local session = {} :: JunctionEditSession
	session.ChangeSignal = changeSignal

	function session.GetSelectedJunction(): Model?
		return selectedJunction
	end

	function session.GetConnectedRoadCount(): number
		if not selectedJunction then
			return 0
		end
		local data = JunctionInstance.Read(selectedJunction)
		if not data then
			return 0
		end
		return #JunctionInstance.ConnectedRoads(data.Id)
	end

	function session.GetSelectedJunctionPosition(): Vector3?
		if not selectedJunction then
			return nil
		end
		local data = JunctionInstance.Read(selectedJunction)
		return if data then data.Position else nil
	end

	function session.GetFilletRadiusM(): number
		if not selectedJunction then
			return 6
		end
		local data = JunctionInstance.Read(selectedJunction)
		return if data and data.FilletRadiusM then data.FilletRadiusM else 6
	end

	function session.GetPadMarginStuds(): number
		if not selectedJunction then
			return 6
		end
		local data = JunctionInstance.Read(selectedJunction)
		return if data and data.PadMarginStuds then data.PadMarginStuds else 6
	end

	local function selectedLayout(): JunctionBuilder.JunctionLayout?
		if not selectedJunction then
			return nil
		end
		local data = JunctionInstance.Read(selectedJunction)
		return if data then JunctionBuilder.GetLayout(data.Id, settings) else nil
	end

	function session.GetCornerCount(): number
		local layout = selectedLayout()
		return if layout then #layout.Corners else 0
	end

	function session.GetLinkedCornerRadii(): boolean
		if not selectedJunction then
			return true
		end
		local data = JunctionInstance.Read(selectedJunction)
		return if data then data.LinkedCornerRadii else true
	end

	function session.GetSelectedCornerLabel(): string?
		local layout = selectedLayout()
		if not layout or not selectedCornerId then
			return nil
		end
		for index, corner in layout.Corners do
			if corner.Id == selectedCornerId then
				return string.format("Corner %d of %d", index, #layout.Corners)
			end
		end
		return nil
	end

	function session.GetSelectedCornerRadiusM(): number?
		local layout = selectedLayout()
		if not layout or not selectedCornerId then
			return nil
		end
		for _, corner in layout.Corners do
			if corner.Id == selectedCornerId then
				return corner.RadiusM
			end
		end
		return nil
	end

	function session.SetFilletRadiusM(value: number)
		if not selectedJunction then
			return
		end
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadEdit", "Junction fillet radius")
		JunctionInstance.SetFilletRadiusM(selectedJunction, math.clamp(value, 0.5, 40))
		rebuildSelected()
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
	end

	function session.SetPadMarginStuds(value: number)
		if not selectedJunction then
			return
		end
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadEdit", "Junction setback")
		JunctionInstance.SetPadMarginStuds(selectedJunction, math.clamp(value, 1, 40))
		rebuildSelected()
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
	end

	function session.SetLinkedCornerRadii(linked: boolean)
		if not selectedJunction then
			return
		end
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadEdit", "Link junction corner radii")
		JunctionInstance.SetLinkedCornerRadii(selectedJunction, linked)
		if not linked and not selectedCornerId then
			local layout = selectedLayout()
			if layout and layout.Corners[1] then
				selectedCornerId = layout.Corners[1].Id
			end
		end
		rebuildSelected()
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
	end

	function session.SetSelectedCornerRadiusM(value: number)
		if not selectedJunction or not selectedCornerId then
			return
		end
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadEdit", "Junction corner radius")
		JunctionInstance.SetCornerRadiusM(selectedJunction, selectedCornerId, value)
		rebuildSelected()
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
	end

	function session.RebuildSelected()
		if not selectedJunction then
			return
		end
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadEdit", "Rebuild junction")
		rebuildSelected()
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
	end

	function session.DeleteJunction()
		if not selectedJunction then
			return
		end
		local data = JunctionInstance.Read(selectedJunction)
		if not data then
			return
		end
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadEdit", "Delete junction")
		for _, road in JunctionInstance.ConnectedRoads(data.Id) do
			local roadData = RoadInstance.Read(road)
			local startId = if roadData and roadData.StartJunctionId ~= data.Id then roadData.StartJunctionId else nil
			local endId = if roadData and roadData.EndJunctionId ~= data.Id then roadData.EndJunctionId else nil
			RoadInstance.StampJunctions(road, startId, endId)
		end
		clearHandles()
		JunctionInstance.Delete(selectedJunction)
		selectedJunction = nil
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end

	function session.Destroy()
		clearHandles()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		changeSignal:DisconnectAll()
	end

	loadSelection()
	return session
end

return createJunctionEditSession
