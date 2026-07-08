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
--   SegmentMenu  - "Edit Road Segment" submenu (Add Bus Stop / Add Bus Bay /
--                  Edit Lane Markings / Back)
--   PlacingBusStop - click-to-place mode for a bus STOP marker (a decal/sign,
--                  no cross-section change): click a Sidewalk/Parking part
--                  on the selected road to add one, click an existing one to
--                  remove it, cancel-placement key returns to SegmentMenu.
--   PlacingBay   - click-to-place mode for a real bus BAY (a physical
--                  pull-in carved into the road's cross-section): click a
--                  point on the selected road to choose where.
--   ConfirmingBay - after a bay point is chosen, adjust its length/width
--                  (defaults: a standard dwell length, one lane's width)
--                  before committing the geometry rebuild.
--   Designer     - the full RoadInspector designer
type Mode = "Menu" | "SegmentMenu" | "PlacingBusStop" | "PlacingBay" | "ConfirmingBay" | "Designer"

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
	-- "Edit Road Segment" second-level submenu (Add Bus Stop / Add Bus Bay /
	-- Edit Lane Markings / Back).
	IsShowingSegmentMenu: () -> boolean,
	OpenSegmentMenu: () -> (),
	CloseSegmentMenu: () -> (),
	-- Bus stop marker click-to-place mode.
	IsPlacingBusStop: () -> boolean,
	StartBusStopPlacement: () -> (),
	StopBusStopPlacement: () -> (),
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
	local busStopConnections: { RBXScriptConnection } = {}
	local bayConnections: { RBXScriptConnection } = {}
	local bayStation: number? = nil -- Chosen point along the curve, set by StartBayPlacement's click
	local bayDraft: BayDraft? = nil

	local function stopBusStopPlacement()
		if mode ~= "PlacingBusStop" then
			return
		end
		mode = "SegmentMenu"
		plugin:Deactivate()
		for _, connection in busStopConnections do
			connection:Disconnect()
		end
		table.clear(busStopConnections)
		changeSignal:Fire()
	end

	local function onBusStopClick()
		if mode ~= "PlacingBusStop" or not selectedRoad then
			return
		end
		-- Clicks on the pie menu's own "Done" pill must not also place/
		-- remove a stop underneath it (same guard createRoadSession uses
		-- for its HUD).
		if uiState.Hovered then
			return
		end
		local target = mouse.Target
		if not target or not target:IsDescendantOf(selectedRoad) then
			return
		end
		if BusStops.IsMarker(target) then
			BusStops.RemoveNear(selectedRoad, mouse.Hit.Position, 3)
			changeSignal:Fire()
		elseif BusStops.IsEligibleTarget(target) then
			BusStops.Add(selectedRoad, mouse.Hit.Position)
			changeSignal:Fire()
		end
	end

	-- Cancels either step of bay placement: before a point is chosen
	-- (PlacingBay, still listening for a click) or after (ConfirmingBay,
	-- adjusting length/width) - both just return to SegmentMenu with
	-- nothing committed.
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
		bayStation = nil
		bayDraft = nil
		mode = "SegmentMenu"
		changeSignal:Fire()
	end

	-- Default width is a lane's width (the road's own first Drive component
	-- if it has one, else the region's default), default length is a
	-- standard dwell length - both adjustable in the ConfirmingBay step,
	-- and pressing Enter/confirming immediately accepts these as-is.
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

	local function onBayPointClick()
		if mode ~= "PlacingBay" or not selectedRoad or not originalData then
			return
		end
		if uiState.Hovered then
			return
		end
		local target = mouse.Target
		if not target or not target:IsDescendantOf(selectedRoad) then
			return
		end
		bayStation = originalData.Curve:ClosestS(mouse.Hit.Position)
		bayDraft = defaultBayDraft()
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
		if mode == "PlacingBusStop" then
			stopBusStopPlacement()
		elseif mode == "PlacingBay" then
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
			if mode == "PlacingBusStop" and Keybinds.Matches(settings.Keybinds.CancelPlacement, input) then
				stopBusStopPlacement()
			elseif
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

	function session.IsPlacingBusStop(): boolean
		return mode == "PlacingBusStop"
	end

	function session.StartBusStopPlacement()
		if mode ~= "SegmentMenu" or not selectedRoad then
			return
		end
		mode = "PlacingBusStop"
		plugin:Activate(true)
		table.insert(busStopConnections, mouse.Button1Down:Connect(onBusStopClick))
		changeSignal:Fire()
	end

	session.StopBusStopPlacement = stopBusStopPlacement

	function session.IsPlacingBay(): boolean
		return mode == "PlacingBay"
	end

	function session.StartBayPlacement()
		if mode ~= "SegmentMenu" or not selectedRoad then
			return
		end
		mode = "PlacingBay"
		plugin:Activate(true)
		table.insert(bayConnections, mouse.Button1Down:Connect(onBayPointClick))
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
		if mode == "PlacingBusStop" or mode == "PlacingBay" then
			plugin:Deactivate()
		end
		for _, connection in busStopConnections do
			connection:Disconnect()
		end
		table.clear(busStopConnections)
		for _, connection in bayConnections do
			connection:Disconnect()
		end
		table.clear(bayConnections)
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		changeSignal:DisconnectAll()
	end

	return session
end

return createRoadEditSession
