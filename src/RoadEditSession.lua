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

local Packages = script.Parent.Parent.Packages
local Signal = require(Packages.Signal)

local RoadInstance = require("./RoadInstance")
local RoadBuilder = require("./Mesh/RoadBuilder")
local RoadProfile = require("./RoadProfile")
local RegionStyles = require("./RegionStyles")
local Settings = require("./Settings")

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
	-- Selecting a road first shows a contextual pie menu (Edit Road Segment /
	-- Place More / Use as Template / Cancel); OpenEditor transitions from
	-- that menu into the full designer for this same road.
	IsShowingMenu: () -> boolean,
	OpenEditor: () -> (),
	GetAnchorWorldPosition: () -> Vector3?,
	GetContinuation: () -> Continuation?,
	Destroy: () -> (),
}

local function createRoadEditSession(
	plugin: Plugin,
	settings: Settings.EasyRoadSettings,
	getStyle: () -> RegionStyles.RegionStyle
): RoadEditSession
	local changeSignal = Signal.new()

	local selectedRoad: Model? = nil
	local originalData: RoadInstance.RoadData? = nil
	local editingProfile: RoadProfile.RoadProfile? = nil -- Local staged clone of ProfileStart
	local showingMenu = false -- true = pie menu, false = full designer

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
		selectedRoad = road
		originalData = if road then RoadInstance.Read(road) else nil
		editingProfile = if originalData then RoadProfile.Clone(originalData.ProfileStart) else nil
		showingMenu = road ~= nil
		changeSignal:Fire()
	end

	local connections: { RBXScriptConnection } = {}
	table.insert(connections, Selection.SelectionChanged:Connect(loadSelection))
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
		for _, child in selectedRoad:GetChildren() do
			child:Destroy()
		end
		for _, child in built:GetChildren() do
			child.Parent = selectedRoad
		end
		built:Destroy()
		RoadInstance.StampModel(selectedRoad, originalData.Curve.Segments[1], editingProfile, originalData.ProfileEnd)
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
		return showingMenu
	end

	function session.OpenEditor()
		showingMenu = false
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
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		changeSignal:DisconnectAll()
	end

	return session
end

return createRoadEditSession
