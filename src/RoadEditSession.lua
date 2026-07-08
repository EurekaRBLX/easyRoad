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
--                  Markings / Back)
--   PlacingBusBay - click-to-place mode: click a Sidewalk/Parking part on
--                  the selected road to add a stop, click an existing stop
--                  to remove it, cancel-placement key returns to SegmentMenu
--   Designer     - the full RoadInspector designer
type Mode = "Menu" | "SegmentMenu" | "PlacingBusBay" | "Designer"

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
	-- Markings / Back) and the bus-bay click-to-place mode it opens into.
	IsShowingSegmentMenu: () -> boolean,
	OpenSegmentMenu: () -> (),
	CloseSegmentMenu: () -> (),
	IsPlacingBusBay: () -> boolean,
	StartBusBayPlacement: () -> (),
	StopBusBayPlacement: () -> (),
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
	local busBayConnections: { RBXScriptConnection } = {}

	local function stopBusBayPlacement()
		if mode ~= "PlacingBusBay" then
			return
		end
		mode = "SegmentMenu"
		plugin:Deactivate()
		for _, connection in busBayConnections do
			connection:Disconnect()
		end
		table.clear(busBayConnections)
		changeSignal:Fire()
	end

	local function onBusBayClick()
		if mode ~= "PlacingBusBay" or not selectedRoad then
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
		if mode == "PlacingBusBay" then
			stopBusBayPlacement()
		end
		selectedRoad = road
		originalData = if road then RoadInstance.Read(road) else nil
		editingProfile = if originalData then RoadProfile.Clone(originalData.ProfileStart) else nil
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
			if mode == "PlacingBusBay" and Keybinds.Matches(settings.Keybinds.CancelPlacement, input) then
				stopBusBayPlacement()
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
		local built = RoadBuilder.Build({
			Curve = originalData.Curve,
			ProfileStart = editingProfile,
			ProfileEnd = originalData.ProfileEnd,
			Style = getStyle(),
			Settings = settings,
			Preview = false,
		})
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
		BusStops.Render(selectedRoad)
		originalData = {
			Curve = originalData.Curve,
			ProfileStart = RoadProfile.Clone(editingProfile),
			ProfileEnd = originalData.ProfileEnd,
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

	function session.IsPlacingBusBay(): boolean
		return mode == "PlacingBusBay"
	end

	function session.StartBusBayPlacement()
		if mode ~= "SegmentMenu" or not selectedRoad then
			return
		end
		mode = "PlacingBusBay"
		plugin:Activate(true)
		table.insert(busBayConnections, mouse.Button1Down:Connect(onBusBayClick))
		changeSignal:Fire()
	end

	session.StopBusBayPlacement = stopBusBayPlacement

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
		if mode == "PlacingBusBay" then
			plugin:Deactivate()
		end
		for _, connection in busBayConnections do
			connection:Disconnect()
		end
		table.clear(busBayConnections)
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		changeSignal:DisconnectAll()
	end

	return session
end

return createRoadEditSession
