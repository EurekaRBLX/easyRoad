--!strict
-- Splits an existing placed road into two independent roads at a given
-- station, inserting a JunctionNode at the cut - the mechanism behind
-- "draw a new road across an existing one and it connects there," not just
-- meeting at an already-placed endpoint (see JunctionInstance.lua /
-- JunctionBuilder.lua for the node/pad half of the junction feature).
--
-- v1 deliberately refuses to split a road that has a widen/narrow
-- transition (ProfileEnd set), a bus bay, or source-window features - correctly remapping either
-- across an arbitrary cut point (interpolating the exact profile at the
-- split station, or deciding which piece keeps the bay) is real geometry
-- work, not attempted here. Such roads are rejected with a visible reason;
-- they are never split while silently dropping marking/kerb ranges or stops.

local CurveSegment = require("./Geometry/CurveSegment")
local PolyCurve = require("./Geometry/PolyCurve")
local RoadBuilder = require("./Mesh/RoadBuilder")
local RoadInstance = require("./RoadInstance")
local JunctionInstance = require("./JunctionInstance")
local RegionStyles = require("./RegionStyles")
local Settings = require("./Settings")
local StructureBuilder = require("./StructureBuilder")
local BusStops = require("./BusStops")
local RoadSource = require("./RoadSource")

local RoadSplit = {}

local MIN_PIECE_LENGTH_STUDS = 4

export type SplitCut = {
	StationStuds: number,
	JunctionId: string,
}

function RoadSplit.MinimumPieceLengthStuds(): number
	return MIN_PIECE_LENGTH_STUDS
end

local function hasActiveSourceWindow(road: Model, data: RoadInstance.RoadData): boolean
	local source = RoadSource.ReadSegment(road)
	if not source then
		return false
	end
	local sourceCurve = PolyCurve.new({ source })
	return math.abs(sourceCurve.Length - data.Curve.Length) > 1e-3
		or (sourceCurve:PosAt(0) - data.Curve:PosAt(0)).Magnitude > 1e-3
		or (sourceCurve:PosAt(sourceCurve.Length) - data.Curve:PosAt(data.Curve.Length)).Magnitude > 1e-3
end

local function connectedToRoundabout(data: RoadInstance.RoadData): boolean
	for _, junctionId in { data.StartJunctionId, data.EndJunctionId } do
		if junctionId then
			local controller = JunctionInstance.FindById(junctionId)
			local controllerData = if controller then JunctionInstance.Read(controller) else nil
			if controllerData and controllerData.Kind == "Roundabout" then
				return true
			end
		end
	end
	return false
end

-- True if `road` is a plain, unmodified segment RoadSplit can safely cut -
-- no transition, no bay (see this file's header for why those are refused).
function RoadSplit.CanSplit(road: Model): boolean
	local data = RoadInstance.Read(road)
	if not data then
		return false
	end
	return data.ProfileEnd == nil
		and data.Bay == nil
		and #data.MarkingStretches == 0
		and #data.KerbStretches == 0
		and #BusStops.Get(road) == 0
		and not hasActiveSourceWindow(road, data)
		and not connectedToRoundabout(data)
		and #data.Curve.Segments == 1
end

-- Human-readable reason used by the placement preview when a crossing is
-- geometrically real but cannot be turned into a node without losing road
-- data. nil means the road is splittable.
function RoadSplit.SplitBlockReason(road: Model): string?
	local data = RoadInstance.Read(road)
	if not data then
		return "Road is missing editable curve data"
	elseif data.ProfileEnd ~= nil then
		return "Widening/narrowing roads cannot be split yet"
	elseif data.Bay ~= nil then
		return "Roads with bus bays cannot be split yet"
	elseif #data.MarkingStretches > 0 or #data.KerbStretches > 0 then
		return "Roads with marking or kerb stretches cannot be split yet"
	elseif #BusStops.Get(road) > 0 then
		return "Roads with bus stops cannot be split yet"
	elseif hasActiveSourceWindow(road, data) then
		return "Roads currently trimmed by a junction or roundabout cannot be split yet"
	elseif connectedToRoundabout(data) then
		return "Roundabout approaches cannot be split while connected"
	elseif #data.Curve.Segments ~= 1 then
		return "Multi-segment roads cannot be split yet"
	end
	return nil
end

local function sortedCutsForLength(length: number, cuts: { SplitCut }): { SplitCut }?
	if #cuts == 0 then
		return nil
	end
	local sorted: { SplitCut } = table.clone(cuts)
	table.sort(sorted, function(a, b)
		return a.StationStuds < b.StationStuds
	end)
	local previousStation = 0
	for _, cut in sorted do
		if
			cut.JunctionId == ""
			or cut.StationStuds < MIN_PIECE_LENGTH_STUDS
			or cut.StationStuds > length - MIN_PIECE_LENGTH_STUDS
			or cut.StationStuds - previousStation < MIN_PIECE_LENGTH_STUDS
		then
			return nil
		end
		previousStation = cut.StationStuds
	end
	if length - previousStation < MIN_PIECE_LENGTH_STUDS then
		return nil
	end
	return sorted
end

function RoadSplit.CanSplitAt(road: Model, stationStuds: number): boolean
	local data = RoadInstance.Read(road)
	if not data or not RoadSplit.CanSplit(road) then
		return false
	end
	return sortedCutsForLength(data.Curve.Length, {
		{ StationStuds = stationStuds, JunctionId = "candidate" },
	}) ~= nil
end

function RoadSplit.CanSplitAtMany(road: Model, cuts: { SplitCut }): boolean
	local data = RoadInstance.Read(road)
	if not data or not RoadSplit.CanSplit(road) then
		return false
	end
	return sortedCutsForLength(data.Curve.Length, cuts) ~= nil
end

-- Replaces one plain road with N+1 pieces, all cut positions referencing
-- caller-provided junction ids. This is the shared primitive required for
-- a true X intersection: the existing road and the newly placed road are
-- both split against the SAME JunctionNode instead of each SplitAt call
-- manufacturing an unrelated node at the same position.
function RoadSplit.SplitMany(
	road: Model,
	cuts: { SplitCut },
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): { Model }?
	local data = RoadInstance.Read(road)
	if not data or not RoadSplit.CanSplit(road) then
		return nil
	end
	local sorted = sortedCutsForLength(data.Curve.Length, cuts)
	if not sorted then
		return nil
	end

	local segment = data.Curve.Segments[1]
	local customAttributes: { [string]: any } = {}
	for name, value in road:GetAttributes() do
		-- EasyRoad owns every RW_ attribute; copying any of those across would
		-- overwrite the freshly built piece's curve endpoints, tangents, profile,
		-- topology ids, or source window. Preserve user/plugin attributes only.
		if string.sub(name, 1, 3) ~= "RW_" then
			customAttributes[name] = value
		end
	end
	local stations: { number } = table.create(#sorted + 2)
	table.insert(stations, 0)
	for _, cut in sorted do
		table.insert(stations, cut.StationStuds)
	end
	table.insert(stations, data.Curve.Length)

	-- Build every replacement before mutating the original so a construction
	-- error cannot leave only half of a road in the workspace.
	local pieces: { Model } = {}
	for index = 1, #stations - 1 do
		local pieceSegment = CurveSegment.Sub(segment, stations[index], stations[index + 1])
		local pieceCurve = PolyCurve.new({ pieceSegment })
		local piece = RoadBuilder.Build({
			Curve = pieceCurve,
			ProfileStart = data.ProfileStart,
			Style = style,
			Settings = settings,
			Preview = false,
		})
		piece.Name = road.Name
		for name, value in customAttributes do
			piece:SetAttribute(name, value)
		end
		local startJunctionId = if index == 1 then data.StartJunctionId else sorted[index - 1].JunctionId
		local endJunctionId = if index > #sorted then data.EndJunctionId else sorted[index].JunctionId
		RoadInstance.StampJunctions(piece, startJunctionId, endJunctionId)
		RoadInstance.PreserveOuterPortIds(
			piece,
			if index == 1 then data.StartPortId else nil,
			if index > #sorted then data.EndPortId else nil
		)
		RoadInstance.StampStructure(piece, data.Structure)
		RoadSource.WriteSegment(piece, pieceSegment)
		piece:SetAttribute("RW_FeatureSourceOffsetStuds", 0)
		StructureBuilder.Render(piece, pieceCurve, data.Structure or StructureBuilder.DefaultData(settings), settings)
		table.insert(pieces, piece)
	end

	local folder = road.Parent
	for _, piece in pieces do
		piece.Parent = folder
	end
	road:Destroy()
	return pieces
end

function RoadSplit.SplitAtJunction(
	road: Model,
	stationStuds: number,
	junctionId: string,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): (Model?, Model?)
	local pieces = RoadSplit.SplitMany(road, {
		{ StationStuds = stationStuds, JunctionId = junctionId },
	}, style, settings)
	if not pieces then
		return nil, nil
	end
	return pieces[1], pieces[2]
end

-- Splits `road` at `stationStuds` along its curve, replacing it with two
-- new road Models parented into the same folder and destroying the
-- original. Returns the two new models (before, after) plus the Id of a
-- fresh JunctionNode created at the cut, or (nil, nil, nil) if the road
-- can't be split (see CanSplit) or the station is too close to either end
-- to produce two meaningful pieces.
function RoadSplit.SplitAt(
	road: Model,
	stationStuds: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): (Model?, Model?, string?)
	local data = RoadInstance.Read(road)
	if not data or not RoadSplit.CanSplitAt(road, stationStuds) then
		return nil, nil, nil
	end
	local splitPos = data.Curve:PosAt(stationStuds)
	local junctionModel = JunctionInstance.Create(splitPos)
	local junctionData = JunctionInstance.Read(junctionModel)
	if not junctionData then
		junctionModel:Destroy()
		return nil, nil, nil
	end

	local beforeModel, afterModel = RoadSplit.SplitAtJunction(road, stationStuds, junctionData.Id, style, settings)
	if not beforeModel or not afterModel then
		junctionModel:Destroy()
		return nil, nil, nil
	end
	return beforeModel, afterModel, junctionData.Id
end

return RoadSplit
