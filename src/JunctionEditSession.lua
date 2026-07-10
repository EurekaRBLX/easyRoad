--!strict
-- Selection-based junction editing: select an already-placed JunctionNode
-- with Studio's ordinary Selection (clicking its pad in the viewport or the
-- Explorer) to see how many roads meet there and delete it if wanted.
--
-- Mirrors RoadEditSession's own Selection-service-driven pattern
-- (loadSelection there), but deliberately its own small module rather than
-- folded into RoadEditSession, which is already a large, road-specific
-- state machine - a junction and a road are never selected by the same
-- click (they live under separate top-level folders), so there's no
-- interaction between the two to coordinate.

local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Packages = script.Parent.Parent.Packages
local Signal = require(Packages.Signal)

local JunctionInstance = require("./JunctionInstance")
local RoadInstance = require("./RoadInstance")

export type JunctionEditSession = {
	ChangeSignal: Signal.Signal<>,
	GetSelectedJunction: () -> Model?,
	GetConnectedRoadCount: () -> number,
	DeleteJunction: () -> (),
	Destroy: () -> (),
}

local function createJunctionEditSession(): JunctionEditSession
	local changeSignal = Signal.new()
	local selectedJunction: Model? = nil

	local function loadSelection()
		local junction: Model? = nil
		for _, instance in Selection:Get() do
			local current: Instance? = instance
			while current do
				if JunctionInstance.IsJunction(current) then
					junction = current :: Model
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
		changeSignal:Fire()
	end

	local connections: { RBXScriptConnection } = {}
	table.insert(connections, Selection.SelectionChanged:Connect(loadSelection))

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

	-- Removes the junction itself and clears the reference on every road
	-- that pointed to it (back to a free, unconnected end - same as before
	-- they were ever joined) - doesn't touch the roads' own geometry.
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
		JunctionInstance.Delete(selectedJunction)
		selectedJunction = nil
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
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

return createJunctionEditSession
