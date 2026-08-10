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
-- work, not attempted here. Junction- and roundabout-trimmed roads without
-- those features ARE safe to split: SplitMany cuts the visible window while
-- partitioning the preserved untrimmed source at the matching source station.
-- Such roads remain restorable at their original outer node after the cut.

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
local SOURCE_WINDOW_EPSILON_STUDS = 1e-3
local SOURCE_HINT_TOLERANCE_STUDS = 1

-- These attributes describe the placed road's corridor membership rather than
-- generated geometry. A split turns one carriageway into multiple consecutive
-- Models, but every piece still belongs to the same parallel roadway.
local PRESERVED_RW_ATTRIBUTES: { [string]: boolean } = {
	RW_ParallelGroupId = true,
	RW_ParallelIndex = true,
	RW_ParallelCount = true,
	RW_ParallelOffsetM = true,
	RW_ParallelReverse = true,
}

export type SplitCut = {
	StationStuds: number,
	JunctionId: string,
}

function RoadSplit.MinimumPieceLengthStuds(): number
	return MIN_PIECE_LENGTH_STUDS
end

local function hasUnsupportedProfileOffsetWarp(data: RoadInstance.RoadData): boolean
	-- A profile transition is already rejected below. Keep the same safety
	-- boundary for externally-authored constant-profile roads whose profile
	-- centre nevertheless moves across the segment: splitting would restart the
	-- smoothstep on every piece and visibly change the original alignment.
	return data.ProfileEnd == nil and math.abs(data.ProfileOffsetEndM - data.ProfileOffsetStartM) > 1e-6
end

local function hasUnsupportedStructure(data: RoadInstance.RoadData): boolean
	-- Every split piece currently starts custom-module tiling and procedural
	-- pier distribution from its own station zero.  Splitting a structured road
	-- would therefore overlap/rephase Ground modules and can duplicate viaduct
	-- supports around the new node.  CrossSection snapping remains available
	-- because it never mutates the target; automatic topology must wait until a
	-- durable structure phase/source-station offset is part of RoadData.
	return data.Structure ~= nil and (data.Structure :: RoadInstance.StructureData).Mode ~= "None"
end

local function activeSourceWindow(
	road: Model,
	data: RoadInstance.RoadData
): (CurveSegment.Segment?, PolyCurve.PolyCurve?)
	local source = RoadSource.ReadSegment(road)
	if not source then
		return nil, nil
	end
	local sourceCurve = PolyCurve.new({ source })
	local active = math.abs(sourceCurve.Length - data.Curve.Length) > 1e-3
		or (sourceCurve:PosAt(0) - data.Curve:PosAt(0)).Magnitude > 1e-3
		or (sourceCurve:PosAt(sourceCurve.Length) - data.Curve:PosAt(data.Curve.Length)).Magnitude > 1e-3
	return if active then source else nil, if active then sourceCurve else nil
end

-- True if `road` is a plain, unmodified segment RoadSplit can safely cut -
-- no transition, no bay (see this file's header for why those are refused).
function RoadSplit.CanSplit(road: Model): boolean
	local data = RoadInstance.Read(road)
	if not data then
		return false
	end
	return data.ProfileEnd == nil
		and not hasUnsupportedProfileOffsetWarp(data)
		and not hasUnsupportedStructure(data)
		and data.Bay == nil
		and #data.MarkingStretches == 0
		and #data.KerbStretches == 0
		and #BusStops.Get(road) == 0
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
	elseif hasUnsupportedProfileOffsetWarp(data) then
		return "Roads with a changing profile-centre offset cannot be split yet"
	elseif hasUnsupportedStructure(data) then
		return "Roads with custom or procedural structures cannot be split yet"
	elseif data.Bay ~= nil then
		return "Roads with bus bays cannot be split yet"
	elseif #data.MarkingStretches > 0 or #data.KerbStretches > 0 then
		return "Roads with marking or kerb stretches cannot be split yet"
	elseif #BusStops.Get(road) > 0 then
		return "Roads with bus stops cannot be split yet"
	elseif #data.Curve.Segments ~= 1 then
		return "Multi-segment roads cannot be split yet"
	end
	return nil
end

-- Refine a source station around the expected branch. CurveSegment.Sub builds
-- a fresh 64-sample arc table, so adding visible arc lengths to a source origin
-- is a useful branch hint but is not exact on a strong cubic. Projecting the
-- physical cut point closes that drift while the bounded search prevents a
-- self-crossing source from jumping to its other branch.
local function projectSourceStationNear(
	sourceCurve: PolyCurve.PolyCurve,
	point: Vector3,
	expectedStation: number,
	minimumStation: number,
	maximumStation: number
): number
	minimumStation = math.clamp(minimumStation, 0, sourceCurve.Length)
	maximumStation = math.clamp(maximumStation, minimumStation, sourceCurve.Length)
	if maximumStation - minimumStation <= SOURCE_WINDOW_EPSILON_STUDS then
		return minimumStation
	end

	local radius = math.max(sourceCurve.Length / 32, 4)
	local low = math.max(minimumStation, expectedStation - radius)
	local high = math.min(maximumStation, expectedStation + radius)
	if high - low <= SOURCE_WINDOW_EPSILON_STUDS then
		low, high = minimumStation, maximumStation
	end
	local bestStation = math.clamp(expectedStation, low, high)
	local bestDistance = (sourceCurve:PosAt(bestStation) - point).Magnitude
	local window = high - low
	for _ = 1, 10 do
		local searchLow = math.max(low, bestStation - window)
		local searchHigh = math.min(high, bestStation + window)
		for sample = 0, 12 do
			local station = searchLow + (searchHigh - searchLow) * sample / 12
			local distance = (sourceCurve:PosAt(station) - point).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				bestStation = station
			end
		end
		window = math.max((searchHigh - searchLow) / 6, SOURCE_WINDOW_EPSILON_STUDS)
	end
	return math.clamp(bestStation, minimumStation, maximumStation)
end

local function visibleSourceOrigin(road: Model, data: RoadInstance.RoadData, sourceCurve: PolyCurve.PolyCurve): number
	local visibleStart = data.Curve:PosAt(0)
	local stored = road:GetAttribute("RW_FeatureSourceOffsetStuds")
	if
		typeof(stored) == "number"
		and stored == stored
		and stored > -SOURCE_WINDOW_EPSILON_STUDS
		and stored < sourceCurve.Length + SOURCE_WINDOW_EPSILON_STUDS
		and (sourceCurve:PosAt(math.clamp(stored, 0, sourceCurve.Length)) - visibleStart).Magnitude
			<= SOURCE_HINT_TOLERANCE_STUDS
	then
		return math.clamp(stored, 0, sourceCurve.Length)
	end
	return sourceCurve:ClosestS(visibleStart)
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
	local sourceSegment, sourceCurve = activeSourceWindow(road, data)
	local preservedAttributes: { [string]: any } = {}
	for name, value in road:GetAttributes() do
		-- EasyRoad owns every RW_ attribute; copying any of those across would
		-- overwrite the freshly built piece's curve endpoints, tangents, profile,
		-- topology ids, or source window. Preserve user/plugin attributes plus
		-- the explicit EasyRoad corridor-membership whitelist above.
		if string.sub(name, 1, 3) ~= "RW_" or PRESERVED_RW_ATTRIBUTES[name] then
			preservedAttributes[name] = value
		end
	end
	local stations: { number } = table.create(#sorted + 2)
	table.insert(stations, 0)
	for _, cut in sorted do
		table.insert(stations, cut.StationStuds)
	end
	table.insert(stations, data.Curve.Length)
	-- A rendered approach may be only a window of its durable source because a
	-- junction or roundabout owns the geometry at one or both ends.  Partition
	-- that source at positions corresponding to the visible cuts, while still
	-- building each replacement from the same visible window it had before.
	-- This is what lets a mid-span snap coexist with an already-connected outer
	-- end: the old node can later expand/retrim its piece from the retained source
	-- instead of losing the hidden section permanently.
	local sourceStations: { number }? = nil
	local visibleSourceStations: { number }? = nil
	if sourceSegment and sourceCurve then
		sourceStations = table.create(#stations)
		visibleSourceStations = table.create(#stations)
		local visibleSourceStart = visibleSourceOrigin(road, data, sourceCurve)
		local visibleSourceEnd = projectSourceStationNear(
			sourceCurve,
			data.Curve:PosAt(data.Curve.Length),
			visibleSourceStart + data.Curve.Length,
			visibleSourceStart,
			sourceCurve.Length
		)
		table.insert(visibleSourceStations, visibleSourceStart)
		local previousVisibleStation = visibleSourceStart
		for index = 2, #stations - 1 do
			local projected = projectSourceStationNear(
				sourceCurve,
				data.Curve:PosAt(stations[index]),
				visibleSourceStart + stations[index],
				previousVisibleStation + SOURCE_WINDOW_EPSILON_STUDS,
				visibleSourceEnd - SOURCE_WINDOW_EPSILON_STUDS
			)
			table.insert(visibleSourceStations, projected)
			previousVisibleStation = projected
		end
		table.insert(visibleSourceStations, visibleSourceEnd)

		table.insert(sourceStations, 0)
		for index = 2, #stations - 1 do
			table.insert(sourceStations, visibleSourceStations[index])
		end
		table.insert(sourceStations, sourceCurve.Length)
	end

	-- Build every replacement before mutating the original so a construction
	-- error cannot leave only half of a road in the workspace.
	local pieces: { Model } = {}
	for index = 1, #stations - 1 do
		local pieceSegment = CurveSegment.Sub(segment, stations[index], stations[index + 1])
		local pieceSourceSegment = if sourceSegment and sourceStations
			then CurveSegment.Sub(sourceSegment, sourceStations[index], sourceStations[index + 1])
			else pieceSegment
		local pieceCurve = PolyCurve.new({ pieceSegment })
		local piece = RoadBuilder.Build({
			Curve = pieceCurve,
			ProfileStart = data.ProfileStart,
			TransitionAnchor = data.TransitionAnchor,
			ProfileOffsetStartM = data.ProfileOffsetStartM,
			ProfileOffsetEndM = data.ProfileOffsetEndM,
			Style = style,
			Settings = settings,
			Preview = false,
		})
		piece.Name = road.Name
		for name, value in preservedAttributes do
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
		RoadSource.WriteSegment(piece, pieceSourceSegment)
		local visiblePieceSourceStart = if visibleSourceStations then visibleSourceStations[index] else stations[index]
		local pieceSourceStart = if sourceStations then sourceStations[index] else stations[index]
		piece:SetAttribute("RW_FeatureSourceOffsetStuds", math.max(0, visiblePieceSourceStart - pieceSourceStart))
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
	settings: Settings.EasyRoadSettings,
	junctionPosition: Vector3?
): (Model?, Model?, string?)
	local data = RoadInstance.Read(road)
	if not data or not RoadSplit.CanSplitAt(road, stationStuds) then
		return nil, nil, nil
	end
	-- Centre snapping can target a persisted profile-centre offset rather than
	-- the authored curve itself. Callers may provide that physical join point;
	-- ordinary callers retain the historical curve-position behaviour.
	local splitPos = junctionPosition or data.Curve:PosAt(stationStuds)
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
