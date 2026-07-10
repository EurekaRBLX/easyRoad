--!strict
-- Per-lane connection graph at a junction - the data-model half of the
-- CS2-style "lane connector" feature from TODO.md's Phase 3, plus a thin
-- mock Traffic Light API sharing the same graph.
--
-- v0 / reserved API surface, not a built feature: ComputeConnections below
-- is a real, live computation (every incoming lane paired with every
-- outgoing lane on a DIFFERENT connected road - no turn classification,
-- no filtering of physically-impossible pairs), but nothing calls it yet -
-- there's no drag-based UI to view or edit connections, and nothing is
-- persisted (a LaneConnection references roads by live Model, not a
-- stable Id, so it only makes sense freshly computed, not saved). Signal
-- phases are even thinner: DefaultPhases just proves the shape a future
-- traffic-light plugin would consume (all connections green at once), not
-- a real phase-grouping algorithm (which would need to reason about which
-- turns conflict - unbuilt).

local RoadInstance = require("./RoadInstance")
local RoadProfile = require("./RoadProfile")

export type LaneConnection = {
	FromRoad: Model,
	FromComponentIndex: number,
	ToRoad: Model,
	ToComponentIndex: number,
}

export type SignalPhase = {
	Name: string,
	DurationSeconds: number,
	AllowedConnections: { LaneConnection },
}

local JunctionLanes = {}

type LaneEnd = {
	Road: Model,
	ComponentIndex: number,
}

-- Every directional (Drive) lane on `road`'s end at this junction, split
-- into those flowing INTO the junction (incoming) and those flowing OUT
-- of it (outgoing) - a component is incoming if its own traffic direction
-- carries it toward station 0 (connected via Start, Direction == -1) or
-- toward the far end (connected via End, Direction == 1); outgoing is the
-- opposite of each.
local function laneEndsForRoad(road: Model, junctionId: string): ({ LaneEnd }, { LaneEnd })
	local incoming: { LaneEnd } = {}
	local outgoing: { LaneEnd } = {}
	local data = RoadInstance.Read(road)
	if not data then
		return incoming, outgoing
	end
	local atStart = data.StartJunctionId == junctionId
	local atEnd = data.EndJunctionId == junctionId
	if not atStart and not atEnd then
		return incoming, outgoing
	end
	local profile = if atEnd then (data.ProfileEnd or data.ProfileStart) else data.ProfileStart
	for index, component in profile.Components do
		if not RoadProfile.IsDirectional(component.Kind) or component.Direction == 0 then
			continue
		end
		local isIncoming = (atStart and component.Direction == -1) or (atEnd and component.Direction == 1)
		local entry: LaneEnd = { Road = road, ComponentIndex = index }
		if isIncoming then
			table.insert(incoming, entry)
		else
			table.insert(outgoing, entry)
		end
	end
	return incoming, outgoing
end

-- Every incoming lane across `roads`, paired with every outgoing lane on a
-- DIFFERENT road (no same-road pairing - a lane can't connect back into
-- its own road at the same junction) - the full theoretical connection
-- set, not yet narrowed to physically sensible turns (that needs knowing
-- each road's angular position around the junction, which JunctionBuilder
-- already computes for its own fillet polygon - a natural place to share
-- logic with once this is actually consumed by something).
function JunctionLanes.ComputeConnections(junctionId: string, roads: { Model }): { LaneConnection }
	local connections: { LaneConnection } = {}
	local allIncoming: { LaneEnd } = {}
	local allOutgoing: { LaneEnd } = {}
	for _, road in roads do
		local incoming, outgoing = laneEndsForRoad(road, junctionId)
		for _, entry in incoming do
			table.insert(allIncoming, entry)
		end
		for _, entry in outgoing do
			table.insert(allOutgoing, entry)
		end
	end
	for _, from in allIncoming do
		for _, to in allOutgoing do
			if from.Road ~= to.Road then
				table.insert(connections, {
					FromRoad = from.Road,
					FromComponentIndex = from.ComponentIndex,
					ToRoad = to.Road,
					ToComponentIndex = to.ComponentIndex,
				})
			end
		end
	end
	return connections
end

-- Mock: a single phase allowing every computed connection at once - proves
-- the SignalPhase shape a future traffic-light plugin would consume, not a
-- real conflict-aware phase-grouping algorithm.
function JunctionLanes.DefaultPhases(connections: { LaneConnection }): { SignalPhase }
	return {
		{ Name = "All", DurationSeconds = 30, AllowedConnections = connections },
	}
end

return JunctionLanes
