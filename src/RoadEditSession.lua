--!strict
-- Post-placement road editing: select an already-placed Road model with
-- Studio's ordinary Selection (clicking it in the viewport or the Explorer -
-- no need to activate the build tool) and edit its cross-section, kerb
-- rules, and markings in place.
--
-- Edits are staged locally (clone-and-mutate, same pattern as the road
-- editor page) and only rebuild the model's geometry - as a single undo
-- step - when the user applies the change.

local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local Packages = script.Parent.Parent.Packages
local Signal = require(Packages.Signal)

local RoadInstance = require("./RoadInstance")
local RoadBuilder = require("./Mesh/RoadBuilder")
local RoadProfile = require("./RoadProfile")
local RegionStyles = require("./RegionStyles")
local Settings = require("./Settings")
local Keybinds = require("./Keybinds")
local BusStops = require("./BusStops")

-- Pie-menu state machine for a selected road:
--   Menu         - top-level pills (Edit on Road Builder / Place More / ...)
--   SegmentMenu  - "Edit Road Segment" submenu (Add Bus Bay / Edit Lane
--                  Markings / Back). A standalone marker-only "Add Bus
--                  Stop" mode used to live here too - removed since a real
--                  bus bay already serves as a stop; BusStops.Render below
--                  still re-renders any markers stamped before that change
--                  so existing roads aren't affected.
--   PlacingBay   - click-drag-to-draw mode for a real bus BAY (a physical
--                  pull-in carved into the road's cross-section).
--   ConfirmingBay - after a bay's drawn, adjust its length/width (defaults:
--                  the dragged size) before committing the geometry rebuild.
--   Designer     - the full RoadInspector designer
type Mode = "Menu" | "SegmentMenu" | "PlacingBay" | "ConfirmingBay" | "Designer"

export type BayDraft = {
	LengthStuds: number,
	WidthM: number,
}

-- Seed data for continuing a build session from this road's end (the
-- "Place More" pie-menu action) - the exact same shape createRoadSession's
-- SessionSeed expects, plus which profile to start the continuation with.
export type Continuation = {
	Position: Vector3,
	Tangent: Vector3,
	Profile: RoadProfile.RoadProfile,
}

export type RoadEditSession = {
	ChangeSignal: Signal.Signal<>,
	GetSelectedRoad: () -> Model?,
	GetProfile: () -> RoadProfile.RoadProfile?,
	GetEndProfile: () -> RoadProfile.RoadProfile?,
	IsTransition: () -> boolean,
	IsDirty: () -> boolean,
	SetProfile: (profile: RoadProfile.RoadProfile) -> (),
	Apply: () -> (),
	Revert: () -> (),
	Deselect: () -> (),
	-- Selecting a road first shows a contextual pie menu (Edit on Road Builder /
	-- Place More / Use as Template / Cancel); OpenEditor transitions from
	-- that menu into the full designer for this same road.
	IsShowingMenu: () -> boolean,
	OpenEditor: () -> (),
	GetAnchorWorldPosition: () -> Vector3?,
	GetContinuation: () -> Continuation?,
	-- "Edit Road Segment" second-level submenu (Add Bus Bay / Edit Lane
	-- Markings / Back).
	IsShowingSegmentMenu: () -> boolean,
	OpenSegmentMenu: () -> (),
	CloseSegmentMenu: () -> (),
	-- Real bus bay: click a point on the road, then adjust length/width.
	IsPlacingBay: () -> boolean,
	StartBayPlacement: () -> (),
	CancelBayPlacement: () -> (),
	IsConfirmingBay: () -> boolean,
	GetBayDraft: () -> BayDraft?,
	SetBayDraftLength: (lengthStuds: number) -> (),
	SetBayDraftWidth: (widthM: number) -> (),
	ConfirmBay: () -> (),
	Destroy: () -> (),
}

local function createRoadEditSession(
	plugin: Plugin,
	settings: Settings.EasyRoadSettings,
	getStyle: () -> RegionStyles.RegionStyle,
	uiState: { Hovered: boolean }
): RoadEditSession
	local changeSignal = Signal.new()

	local selectedRoad: Model? = nil
	local originalData: RoadInstance.RoadData? = nil
	local editingProfile: RoadProfile.RoadProfile? = nil -- Local staged clone of ProfileStart
	local mode: Mode = "Menu"
	local mouse = plugin:GetMouse()
	local bayConnections: { RBXScriptConnection } = {}
	local bayStation: number? = nil -- Chosen placement station, set once the drag finishes
	local bayDraft: BayDraft? = nil
	-- Click-drag-to-draw state: set on mouse down, cleared once the drag
	-- finishes (mouse up) or is cancelled.
	local bayDragStartStation: number? = nil
	local bayDragStartHit: Vector3? = nil
	local bayGhost: Part? = nil

	-- Cancels either step of bay placement: before a drag is drawn
	-- (PlacingBay, still listening for a click-drag) or after
	-- (ConfirmingBay, adjusting length/width) - both just return to
	-- SegmentMenu with nothing committed.
	local function stopBayPlacement()
		if mode ~= "PlacingBay" and mode ~= "ConfirmingBay" then
			return
		end
		if mode == "PlacingBay" then
			plugin:Deactivate()
		end
		for _, connection in bayConnections do
			connection:Disconnect()
		end
		table.clear(bayConnections)
		if bayGhost then
			bayGhost:Destroy()
			bayGhost = nil
		end
		bayDragStartStation = nil
		bayStation = nil
		bayDraft = nil
		mode = "SegmentMenu"
		changeSignal:Fire()
	end

	-- Default width is a lane's width (the road's own first Drive component
	-- if it has one, else the region's default) - only used as a fallback
	-- if a click without dragging skips straight to confirming (Enter
	-- immediately accepts it, per the "press Enter to skip" ask).
	local function defaultBayDraft(): BayDraft
		local scale = settings.MetersToStuds
		local laneWidthM = getStyle().DefaultLaneWidthM
		if editingProfile then
			for _, component in editingProfile.Components do
				if component.Kind == "Drive" then
					laneWidthM = component.WidthM
					break
				end
			end
		end
		return {
			LengthStuds = 20 * scale,
			WidthM = laneWidthM,
		}
	end

	-- Turns a drag from (startStation, startHit) to the current mouse hit
	-- into a length (along the road) / width (perpendicular, away from the
	-- start point - the user drags outward from the sidewalk) pair. The
	-- station midpoint between the drag's two ends is the bay's placement
	-- station.
	local function bayDraftFromDrag(
		startStation: number,
		startHit: Vector3,
		currentStation: number,
		currentHit: Vector3
	): BayDraft
		local lengthStuds = math.abs(currentStation - startStation)
		local frame = (originalData :: RoadInstance.RoadData).Curve:FrameAt(startStation)
		local widthStuds = math.abs((currentHit - startHit):Dot(frame.RightVector))
		local scale = settings.MetersToStuds
		return {
			LengthStuds = math.max(lengthStuds, 1),
			WidthM = math.max(widthStuds / scale, 0.5),
		}
	end

	local function updateBayGhost(startStation: number, currentStation: number, widthM: number)
		if not selectedRoad or not originalData then
			return
		end
		local curve = originalData.Curve
		local s0 = math.min(startStation, currentStation)
		local s1 = math.max(startStation, currentStation)
		if s1 - s0 < 1e-3 then
			if bayGhost then
				bayGhost.Size = Vector3.new(0, 0, 0)
			end
			return
		end
		local scale = settings.MetersToStuds
		local widthStuds = math.max(widthM * scale, 0.1)
		local style = getStyle()
		local outward = if style.DriveOnLeft then -1 else 1
		local offsets = RoadProfile.ComponentOffsetsM(editingProfile or originalData.ProfileStart)
		local kerbOffsetM = if style.DriveOnLeft
			then (if offsets[1] then offsets[1].Right else 0)
			else (if offsets[#offsets] then offsets[#offsets].Left else 0)
		local kerbOffset = kerbOffsetM * scale
		local outerOffset = kerbOffset + outward * widthStuds
		local frameA = curve:FrameAt(s0)
		local frameB = curve:FrameAt(s1)
		local centerOffset = (kerbOffset + outerOffset) / 2
		local pA = (frameA * CFrame.new(centerOffset, 0.1, 0)).Position
		local pB = (frameB * CFrame.new(centerOffset, 0.1, 0)).Position
		local segLength = (pB - pA).Magnitude
		if segLength < 1e-3 then
			return
		end
		if not bayGhost then
			local ghost = Instance.new("Part")
			ghost.Name = "EasyRoadBayGhost"
			ghost.Anchored = true
			ghost.CanCollide = false
			ghost.CanQuery = false
			ghost.CanTouch = false
			ghost.CastShadow = false
			ghost.Material = Enum.Material.Neon
			ghost.Color = style.BayColor
			ghost.Transparency = 0.4
			ghost.Parent = workspace
			bayGhost = ghost
		end
		local ghost = bayGhost :: Part
		ghost.Color = style.BayColor
		ghost.Size = Vector3.new(widthStuds, 0.2, segLength)
		ghost.CFrame = CFrame.lookAt((pA + pB) / 2, pB, frameA.UpVector)
	end

	-- Click-drag-to-draw: mouse down on the road starts the drag (recording
	-- where along the curve and how far laterally); moving the mouse while
	-- held updates a live ghost indicator; releasing finishes the drag and
	-- moves to ConfirmingBay with the dragged length/width as the initial
	-- draft (still adjustable there, and pressing Enter/Add Bay immediately
	-- accepts it as-is).
	local function onBayDragBegin()
		if mode ~= "PlacingBay" or not selectedRoad or not originalData then
			return
		end
		if uiState.Hovered then
			return
		end
		-- Deliberately not requiring mouse.Target to land on the road itself -
		-- the user is drawing a rectangle that starts on the road but is
		-- dragged outward past its edge, and
		-- a drag that starts a pixel off the road (baseplate showing
		-- through a thin gap, camera angle grazing the edge, ...) used to
		-- silently drop the whole gesture, since onBayDragMove/End already
		-- only need bayDragStartStation to be set. ClosestS always finds
		-- the nearest station on the curve regardless of what was actually
		-- hit, so a click anywhere in the viewport near the road registers.
		bayDragStartStation = originalData.Curve:ClosestS(mouse.Hit.Position)
		bayDragStartHit = mouse.Hit.Position
	end

	local function onBayDragMove()
		if mode ~= "PlacingBay" or not bayDragStartStation or not bayDragStartHit or not originalData then
			return
		end
		local currentStation = originalData.Curve:ClosestS(mouse.Hit.Position)
		local draft = bayDraftFromDrag(bayDragStartStation, bayDragStartHit, currentStation, mouse.Hit.Position)
		updateBayGhost(bayDragStartStation, currentStation, draft.WidthM)
	end

	local function onBayDragEnd()
		if mode ~= "PlacingBay" or not bayDragStartStation or not bayDragStartHit or not originalData then
			return
		end
		local currentStation = originalData.Curve:ClosestS(mouse.Hit.Position)
		local draft = bayDraftFromDrag(bayDragStartStation, bayDragStartHit, currentStation, mouse.Hit.Position)
		bayStation = (bayDragStartStation + currentStation) / 2
		bayDraft = draft
		bayDragStartStation = nil
		bayDragStartHit = nil
		if bayGhost then
			bayGhost:Destroy()
			bayGhost = nil
		end
		for _, connection in bayConnections do
			connection:Disconnect()
		end
		table.clear(bayConnections)
		plugin:Deactivate()
		mode = "ConfirmingBay"
		changeSignal:Fire()
	end

	local function loadSelection()
		local road: Model? = nil
		for _, instance in Selection:Get() do
			road = RoadInstance.FindRoad(instance)
			if road then
				break
			end
		end
		if road == selectedRoad then
			return
		end
		if mode == "PlacingBay" then
			stopBayPlacement()
		end
		selectedRoad = road
		originalData = if road then RoadInstance.Read(road) else nil
		editingProfile = if originalData then RoadProfile.Clone(originalData.ProfileStart) else nil
		bayStation = nil
		bayDraft = nil
		mode = "Menu"
		changeSignal:Fire()
	end

	local connections: { RBXScriptConnection } = {}
	table.insert(connections, Selection.SelectionChanged:Connect(loadSelection))
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then
				return
			end
			if
				(mode == "PlacingBay" or mode == "ConfirmingBay")
				and Keybinds.Matches(settings.Keybinds.CancelPlacement, input)
			then
				stopBayPlacement()
			end
		end)
	)
	loadSelection()

	local session = {} :: RoadEditSession
	session.ChangeSignal = changeSignal

	function session.GetSelectedRoad(): Model?
		return selectedRoad
	end

	function session.GetProfile(): RoadProfile.RoadProfile?
		return editingProfile
	end

	function session.GetEndProfile(): RoadProfile.RoadProfile?
		return if originalData then originalData.ProfileEnd else nil
	end

	function session.IsTransition(): boolean
		local endProfile = if originalData then originalData.ProfileEnd else nil
		return originalData ~= nil and endProfile ~= nil and endProfile.Id ~= originalData.ProfileStart.Id
	end

	function session.IsDirty(): boolean
		if not editingProfile or not originalData then
			return false
		end
		local a = HttpService:JSONEncode(RoadProfile.Serialize(editingProfile))
		local b = HttpService:JSONEncode(RoadProfile.Serialize(originalData.ProfileStart))
		return a ~= b
	end

	function session.SetProfile(newProfile: RoadProfile.RoadProfile)
		editingProfile = newProfile
		changeSignal:Fire()
	end

	function session.Apply()
		if not selectedRoad or not editingProfile or not originalData then
			return
		end
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadEdit", "Edit road")
		local buildOptions = {
			Curve = originalData.Curve,
			ProfileStart = editingProfile,
			ProfileEnd = originalData.ProfileEnd,
			Style = getStyle(),
			Settings = settings,
			Preview = false,
		}
		-- If this road has a bus bay, rebuild it through the bay-aware
		-- builder instead - otherwise an unrelated edit here (colour, kerb
		-- rule, ...) would silently wipe the bay's carved-out geometry.
		local built = if originalData.Bay
			then RoadBuilder.BuildWithBay(buildOptions, {
				StationStuds = originalData.Bay.StationStuds,
				LengthStuds = originalData.Bay.LengthStuds,
				WidthM = originalData.Bay.WidthM,
			})
			else RoadBuilder.Build(buildOptions)
		-- Bus stop markers are stored as an attribute (survives the rebuild)
		-- but rendered as children of the model, so they'd otherwise be
		-- wiped along with the old geometry - re-render them from the
		-- attribute once the new geometry is in place.
		for _, child in selectedRoad:GetChildren() do
			child:Destroy()
		end
		for _, child in built:GetChildren() do
			child.Parent = selectedRoad
		end
		built:Destroy()
		RoadInstance.StampModel(selectedRoad, originalData.Curve.Segments[1], editingProfile, originalData.ProfileEnd)
		RoadInstance.StampBay(selectedRoad, originalData.Bay)
		BusStops.Render(selectedRoad)
		originalData = {
			Curve = originalData.Curve,
			ProfileStart = RoadProfile.Clone(editingProfile),
			ProfileEnd = originalData.ProfileEnd,
			Bay = originalData.Bay,
		}
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end

	function session.Revert()
		editingProfile = if originalData then RoadProfile.Clone(originalData.ProfileStart) else nil
		changeSignal:Fire()
	end

	function session.Deselect()
		Selection:Set({})
	end

	function session.IsShowingMenu(): boolean
		return mode == "Menu"
	end

	function session.OpenEditor()
		mode = "Designer"
		changeSignal:Fire()
	end

	function session.IsShowingSegmentMenu(): boolean
		return mode == "SegmentMenu"
	end

	function session.OpenSegmentMenu()
		if mode == "Menu" then
			mode = "SegmentMenu"
			changeSignal:Fire()
		end
	end

	function session.CloseSegmentMenu()
		if mode == "SegmentMenu" then
			mode = "Menu"
			changeSignal:Fire()
		end
	end

	function session.IsPlacingBay(): boolean
		return mode == "PlacingBay"
	end

	function session.StartBayPlacement()
		if mode ~= "SegmentMenu" or not selectedRoad then
			return
		end
		mode = "PlacingBay"
		plugin:Activate(true)
		table.insert(bayConnections, mouse.Button1Down:Connect(onBayDragBegin))
		table.insert(bayConnections, mouse.Move:Connect(onBayDragMove))
		table.insert(bayConnections, mouse.Button1Up:Connect(onBayDragEnd))
		changeSignal:Fire()
	end

	session.CancelBayPlacement = stopBayPlacement

	function session.IsConfirmingBay(): boolean
		return mode == "ConfirmingBay"
	end

	function session.GetBayDraft(): BayDraft?
		return bayDraft
	end

	function session.SetBayDraftLength(lengthStuds: number)
		if bayDraft then
			bayDraft.LengthStuds = math.max(lengthStuds, 1)
			changeSignal:Fire()
		end
	end

	function session.SetBayDraftWidth(widthM: number)
		if bayDraft then
			bayDraft.WidthM = math.max(widthM, 0.5)
			changeSignal:Fire()
		end
	end

	function session.ConfirmBay()
		if mode ~= "ConfirmingBay" or not selectedRoad or not originalData or not bayDraft or not bayStation then
			return
		end
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadEdit", "Add bus bay")
		local bay: RoadInstance.BayData = {
			StationStuds = bayStation,
			LengthStuds = bayDraft.LengthStuds,
			WidthM = bayDraft.WidthM,
		}
		local built = RoadBuilder.BuildWithBay({
			Curve = originalData.Curve,
			ProfileStart = editingProfile or originalData.ProfileStart,
			ProfileEnd = originalData.ProfileEnd,
			Style = getStyle(),
			Settings = settings,
			Preview = false,
		}, bay)
		for _, child in selectedRoad:GetChildren() do
			child:Destroy()
		end
		for _, child in built:GetChildren() do
			child.Parent = selectedRoad
		end
		built:Destroy()
		RoadInstance.StampModel(
			selectedRoad,
			originalData.Curve.Segments[1],
			editingProfile or originalData.ProfileStart,
			originalData.ProfileEnd
		)
		RoadInstance.StampBay(selectedRoad, bay)
		BusStops.Render(selectedRoad)
		originalData.Bay = bay
		bayStation = nil
		bayDraft = nil
		mode = "SegmentMenu"
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end

	function session.GetAnchorWorldPosition(): Vector3?
		if not originalData then
			return nil
		end
		local curve = originalData.Curve
		return curve:PosAt(curve.Length / 2)
	end

	function session.GetContinuation(): Continuation?
		if not originalData then
			return nil
		end
		local curve = originalData.Curve
		local profile = originalData.ProfileEnd or originalData.ProfileStart
		return {
			Position = curve:PosAt(curve.Length),
			Tangent = curve:TangentAt(curve.Length),
			Profile = RoadProfile.Clone(profile),
		}
	end

	function session.Destroy()
		if mode == "PlacingBay" then
			plugin:Deactivate()
		end
		for _, connection in bayConnections do
			connection:Disconnect()
		end
		table.clear(bayConnections)
		if bayGhost then
			bayGhost:Destroy()
			bayGhost = nil
		end
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		changeSignal:DisconnectAll()
	end

	return session
end

return createRoadEditSession
