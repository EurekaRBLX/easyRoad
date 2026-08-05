--!strict
-- Selection-driven editing for built roundabouts. The session owns no UI:
-- selecting a ring (or any of its descendants) is enough to open the editor,
-- while every edit is rebuilt and recorded as one Studio undo operation.

local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Packages = script.Parent.Parent.Packages
local Signal = require(Packages.Signal)

local History = require("./History")
local RoundaboutInstance = require("./RoundaboutInstance")
local RoundaboutBuilder = require("./Mesh/RoundaboutBuilder")
local JunctionInstance = require("./JunctionInstance")
local RegionStyles = require("./RegionStyles")
local Settings = require("./Settings")

export type RoundaboutEditSession = {
	ChangeSignal: Signal.Signal<>,
	GetSelectedRoundabout: () -> Model?,
	GetConnectedRoadCount: () -> number,
	IsLegacyConnected: () -> boolean,
	GetRadiusStuds: () -> number,
	GetLaneCount: () -> number,
	GetLaneWidthM: () -> number,
	GetMarkings: () -> string?,
	GetSidewalk: () -> boolean?,
	GetIsland: () -> boolean?,
	GetStatus: () -> string?,
	GetMinimumRadiusStuds: () -> number,
	GetSuggestedRadiusStuds: () -> number,
	SetRadiusStuds: (value: number) -> (),
	SetLaneCount: (value: number) -> (),
	SetLaneWidthM: (value: number) -> (),
	SetMarkings: (value: string?) -> (),
	SetSidewalk: (value: boolean?) -> (),
	SetIsland: (value: boolean?) -> (),
	RebuildSelected: () -> (),
	ConvertToJunction: () -> (),
	DeleteRoundabout: () -> (),
	PrintGeometry: () -> (),
	Destroy: () -> (),
}

local HANDLES_FOLDER_NAME = "EasyRoadRoundaboutHandles"

local function createRoundaboutEditSession(
	getStyle: () -> RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): RoundaboutEditSession
	local changeSignal = Signal.new()
	local selectedRoundabout: Model? = nil
	local status: string? = nil
	local connections: { RBXScriptConnection } = {}
	local destroyed = false

	local function selectedData()
		return if selectedRoundabout then RoundaboutInstance.Read(selectedRoundabout) else nil
	end

	local function setStatus(message: string?)
		status = message
		changeSignal:Fire()
	end

	local function roundaboutFromSelection(instance: Instance): Model?
		local current: Instance? = instance
		while current do
			if RoundaboutInstance.IsRoundabout(current) then
				return current :: Model
			end
			if JunctionInstance.IsJunction(current) then
				local controller = current :: Model
				local controllerData = JunctionInstance.Read(controller)
				if controllerData and controllerData.Kind == "Roundabout" then
					return RoundaboutInstance.FindByJunctionId(controllerData.Id)
				end
			end
			-- A future radius handle may live here. Selecting it must not close
			-- the owner panel or replace the edited ring with a helper Part.
			if
				current.Name == HANDLES_FOLDER_NAME or (current.Parent and current.Parent.Name == HANDLES_FOLDER_NAME)
			then
				return selectedRoundabout
			end
			current = current.Parent
		end
		return RoundaboutInstance.FindRoundabout(instance)
	end

	local function loadSelection(force: boolean?)
		if destroyed then
			return
		end
		local nextRoundabout: Model? = nil
		for _, instance in Selection:Get() do
			nextRoundabout = roundaboutFromSelection(instance)
			if nextRoundabout then
				break
			end
		end
		if nextRoundabout == selectedRoundabout and not force then
			return
		end
		selectedRoundabout = nextRoundabout
		status = nil
		changeSignal:Fire()
	end

	local function normalizeSelection(model: Model?)
		selectedRoundabout = model
		if model then
			Selection:Set({ model })
		else
			Selection:Set({})
		end
	end

	local function connectedRoadCount(): number
		local data = selectedData()
		if not data then
			return 0
		end
		if data.JunctionId then
			return #JunctionInstance.ConnectedRoads(data.JunctionId)
		end
		if data.LegacyConnected and selectedRoundabout then
			-- A generated mouth owns one entry and one exit arm. Older rings have
			-- no retained controller to query, so the paired arms are their only
			-- durable approach count for the read-only legacy display.
			local armCount = 0
			for _, descendant in selectedRoundabout:GetDescendants() do
				if descendant:IsA("Model") and descendant.Name == "RoundaboutArm" then
					armCount += 1
				end
			end
			return math.floor(armCount / 2)
		end
		return 0
	end

	local function canEdit(): boolean
		local data = selectedData()
		if not data then
			setStatus("The selected roundabout could not be read.")
			return false
		end
		if data.LegacyConnected then
			setStatus(
				"Legacy connected roundabouts are read-only; recreate the junction once to use the editor safely."
			)
			return false
		end
		return true
	end

	local function rebuild(statusMessage: string): (boolean, boolean)
		local model = selectedRoundabout
		if not model then
			return false, false
		end
		local ok, rebuilt, message = pcall(function()
			return RoundaboutBuilder.Rebuild(model, getStyle(), settings)
		end)
		if not ok then
			setStatus("Roundabout rebuild failed: " .. tostring(rebuilt))
			return false, true
		end
		if not rebuilt then
			setStatus(message or "Roundabout rebuild failed.")
			return false, false
		end
		normalizeSelection(rebuilt)
		status = message or statusMessage
		changeSignal:Fire()
		return true, false
	end

	local function editGeometry(label: string, mutate: (Model, any) -> (), value: any)
		local model = selectedRoundabout
		if not model or not canEdit() then
			return
		end
		local before = selectedData()
		if not before then
			return
		end
		local editFailure: string? = nil
		local rebuilt = false
		local changed, historyFailure = History.Record("EasyRoadRoundaboutEdit", label, function()
			local ok, err = pcall(function()
				mutate(model, value)
			end)
			if not ok then
				RoundaboutInstance.SetGeometry(model, before.RadiusStuds, before.LaneCount, before.LaneWidthM)
				RoundaboutInstance.SetMarkings(model, before.Markings)
				RoundaboutInstance.SetSidewalk(model, before.Sidewalk)
				RoundaboutInstance.SetIsland(model, before.Island)
				editFailure = "Roundabout edit failed: " .. tostring(err)
				return false
			end
			local runtimeFailed = false
			rebuilt, runtimeFailed = rebuild("Roundabout updated.")
			if not rebuilt and not runtimeFailed then
				-- CreateAtJunction preflights every connected approach before touching
				-- topology. A normal rejection therefore rolls back the proposed owner
				-- attributes as well, keeping metadata and visible geometry in sync.
				RoundaboutInstance.SetGeometry(model, before.RadiusStuds, before.LaneCount, before.LaneWidthM)
				RoundaboutInstance.SetMarkings(model, before.Markings)
				RoundaboutInstance.SetSidewalk(model, before.Sidewalk)
				RoundaboutInstance.SetIsland(model, before.Island)
			end
			-- Runtime failures may occur after mutation begins. History.Record commits
			-- that partial state so Undo remains a recovery point.
			return rebuilt or runtimeFailed
		end)
		if editFailure then
			setStatus(editFailure)
		elseif historyFailure then
			setStatus(historyFailure)
		elseif not changed or not rebuilt then
			changeSignal:Fire()
		end
	end

	local function setGeometry(radiusStuds: number, laneCount: number, laneWidthM: number)
		local model = selectedRoundabout
		if not model then
			return
		end
		RoundaboutInstance.SetGeometry(model, radiusStuds, laneCount, laneWidthM)
	end

	table.insert(
		connections,
		Selection.SelectionChanged:Connect(function()
			loadSelection(false)
		end)
	)

	-- Undo/redo can restore a destroyed model or replace its generated
	-- descendants without producing a useful owner-level selection change.
	-- Defer until Studio has completed the history operation, then re-read.
	local function afterHistoryChange()
		task.defer(function()
			loadSelection(true)
		end)
	end
	table.insert(connections, ChangeHistoryService.OnUndo:Connect(afterHistoryChange))
	table.insert(connections, ChangeHistoryService.OnRedo:Connect(afterHistoryChange))

	local session = {} :: RoundaboutEditSession
	session.ChangeSignal = changeSignal

	function session.GetSelectedRoundabout(): Model?
		return selectedRoundabout
	end

	function session.GetConnectedRoadCount(): number
		return connectedRoadCount()
	end

	function session.IsLegacyConnected(): boolean
		local data = selectedData()
		return if data then data.LegacyConnected else false
	end

	function session.GetRadiusStuds(): number
		local data = selectedData()
		return if data then data.RadiusStuds else 30
	end

	function session.GetLaneCount(): number
		local data = selectedData()
		return if data then data.LaneCount else 1
	end

	function session.GetLaneWidthM(): number
		local data = selectedData()
		return if data then data.LaneWidthM else 3.65
	end

	function session.GetMarkings(): string?
		local data = selectedData()
		return if data then data.Markings else nil
	end

	function session.GetSidewalk(): boolean?
		local data = selectedData()
		return if data then data.Sidewalk else nil
	end

	function session.GetIsland(): boolean?
		local data = selectedData()
		return if data then data.Island else nil
	end

	function session.GetStatus(): string?
		return status
	end

	function session.GetMinimumRadiusStuds(): number
		local data = selectedData()
		if not data then
			return 0
		end
		local ok, value = pcall(function()
			return RoundaboutBuilder.MinimumRadiusStuds(
				data.JunctionId or "",
				data.LaneCount,
				data.LaneWidthM,
				getStyle(),
				settings
			)
		end)
		return if ok then value else 0
	end

	function session.GetSuggestedRadiusStuds(): number
		local data = selectedData()
		if not data then
			return 0
		end
		local ok, value = pcall(function()
			return RoundaboutBuilder.SuggestedRadiusStuds(
				data.JunctionId or "",
				data.LaneCount,
				data.LaneWidthM,
				getStyle(),
				settings
			)
		end)
		return if ok then value else 0
	end

	function session.SetRadiusStuds(value: number)
		local data = selectedData()
		if not data then
			return
		end
		editGeometry("Roundabout radius", function(_model, radius)
			setGeometry(math.max(1, radius), data.LaneCount, data.LaneWidthM)
		end, value)
	end

	function session.SetLaneCount(value: number)
		local data = selectedData()
		if not data then
			return
		end
		editGeometry("Roundabout circulating lanes", function(_model, count)
			setGeometry(data.RadiusStuds, math.clamp(math.floor(count + 0.5), 1, 6), data.LaneWidthM)
		end, value)
	end

	function session.SetLaneWidthM(value: number)
		local data = selectedData()
		if not data then
			return
		end
		editGeometry("Roundabout lane width", function(_model, width)
			setGeometry(data.RadiusStuds, data.LaneCount, math.clamp(width, 1, 10))
		end, value)
	end

	function session.SetMarkings(value: string?)
		editGeometry("Roundabout markings", function(model, selected)
			RoundaboutInstance.SetMarkings(model, selected)
		end, value)
	end

	function session.SetSidewalk(value: boolean?)
		editGeometry("Roundabout pavement", function(model, selected)
			RoundaboutInstance.SetSidewalk(model, selected)
		end, value)
	end

	function session.SetIsland(value: boolean?)
		editGeometry("Roundabout island", function(model, selected)
			RoundaboutInstance.SetIsland(model, selected)
		end, value)
	end

	function session.RebuildSelected()
		if not selectedRoundabout or not canEdit() then
			return
		end
		local historyChanged, historyFailure = History.Record("EasyRoadRoundaboutEdit", "Rebuild roundabout", function()
			local changed, runtimeFailed = rebuild("Roundabout rebuilt.")
			return changed or runtimeFailed
		end)
		if not historyChanged and historyFailure then
			setStatus(historyFailure)
		end
	end

	function session.ConvertToJunction()
		local model = selectedRoundabout
		if not model then
			return
		end
		if session.IsLegacyConnected() then
			setStatus(
				"Legacy connected roundabouts cannot be converted safely because their original road sources are unavailable."
			)
			return
		end
		local junction: Model? = nil
		local conversionMessage: string? = nil
		local changed, historyFailure = History.Record(
			"EasyRoadRoundaboutEdit",
			"Convert roundabout to junction",
			function()
				junction, conversionMessage = RoundaboutBuilder.ConvertToJunction(model, getStyle(), settings)
				return junction ~= nil
			end
		)
		if historyFailure then
			setStatus(historyFailure)
			return
		end
		if not changed or not junction then
			setStatus(conversionMessage or "Roundabout conversion failed.")
			return
		end
		selectedRoundabout = nil
		Selection:Set({ junction :: Model })
		status = conversionMessage
		changeSignal:Fire()
	end

	function session.DeleteRoundabout()
		local model = selectedRoundabout
		if not model then
			return
		end
		if connectedRoadCount() > 0 or session.IsLegacyConnected() then
			setStatus("Connected roundabouts must be converted to a junction instead of deleted.")
			return
		end
		local changed, historyFailure = History.Record("EasyRoadRoundaboutEdit", "Delete roundabout", function()
			local data = selectedData()
			if data and data.JunctionId then
				local controller = JunctionInstance.FindById(data.JunctionId)
				if controller and #JunctionInstance.ConnectedRoads(data.JunctionId) == 0 then
					controller:Destroy()
				end
			end
			model:Destroy()
			selectedRoundabout = nil
			Selection:Set({})
			return true
		end)
		if not changed and historyFailure then
			setStatus(historyFailure)
			return
		end
		status = nil
		changeSignal:Fire()
	end

	function session.PrintGeometry()
		local data = selectedData()
		if not data then
			return
		end
		if data.JunctionId then
			local ok, description = pcall(function()
				return RoundaboutBuilder.DescribeJunction(
					data.JunctionId :: string,
					data.RadiusStuds,
					data.LaneCount,
					data.LaneWidthM,
					getStyle(),
					settings
				)
			end)
			if not ok then
				setStatus("Could not print roundabout geometry: " .. tostring(description))
				return
			end
			print(description)
		else
			print(
				string.format(
					"=== standalone roundabout ===\ncenter=(%.3f, %.3f, %.3f) radius=%.3f outer=%.3f lanes=%d laneWidthM=%.3f",
					data.Center.X,
					data.Center.Y,
					data.Center.Z,
					data.RadiusStuds,
					data.OuterRadiusStuds,
					data.LaneCount,
					data.LaneWidthM
				)
			)
		end
		setStatus("Roundabout geometry printed to Output.")
	end

	function session.Destroy()
		destroyed = true
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		changeSignal:DisconnectAll()
	end

	loadSelection(true)
	return session
end

return createRoundaboutEditSession
