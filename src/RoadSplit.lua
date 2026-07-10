--!strict
-- Splits an existing placed road into two independent roads at a given
-- station, inserting a JunctionNode at the cut - the mechanism behind
-- "draw a new road across an existing one and it connects there," not just
-- meeting at an already-placed endpoint (see JunctionInstance.lua /
-- JunctionBuilder.lua for the node/pad half of the junction feature).
--
-- v1 deliberately refuses to split a road that has a widen/narrow
-- transition (ProfileEnd set) or a bus bay - correctly remapping either
-- across an arbitrary cut point (interpolating the exact profile at the
-- split station, or deciding which piece keeps the bay) is real geometry
-- work, not attempted here. It also drops MarkingStretches/KerbStretches
-- rather than remapping their station ranges into each piece's own local
-- coordinate space - the same class of complexity already flagged for
-- marking stretches surviving a structural profile edit (see TODO.md).

local CurveSegment = require("./Geometry/CurveSegment")
local PolyCurve = require("./Geometry/PolyCurve")
local RoadBuilder = require("./Mesh/RoadBuilder")
local RoadInstance = require("./RoadInstance")
local JunctionInstance = require("./JunctionInstance")
local RegionStyles = require("./RegionStyles")
local Settings = require("./Settings")

local RoadSplit = {}

local MIN_PIECE_LENGTH_STUDS = 4

-- True if `road` is a plain, unmodified segment RoadSplit can safely cut -
-- no transition, no bay (see this file's header for why those are refused).
function RoadSplit.CanSplit(road: Model): boolean
	local data = RoadInstance.Read(road)
	if not data then
		return false
	end
	return data.ProfileEnd == nil and data.Bay == nil and #data.Curve.Segments == 1
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
	if not data or data.ProfileEnd ~= nil or data.Bay ~= nil or #data.Curve.Segments ~= 1 then
		return nil, nil, nil
	end
	local length = data.Curve.Length
	if stationStuds < MIN_PIECE_LENGTH_STUDS or stationStuds > length - MIN_PIECE_LENGTH_STUDS then
		return nil, nil, nil
	end

	local segment = data.Curve.Segments[1]
	local beforeSegment = CurveSegment.Sub(segment, 0, stationStuds)
	local afterSegment = CurveSegment.Sub(segment, stationStuds, length)
	local splitPos = CurveSegment.PosAtS(segment, stationStuds)

	local folder = road.Parent
	local beforeModel = RoadBuilder.Build({
		Curve = PolyCurve.new({ beforeSegment }),
		ProfileStart = data.ProfileStart,
		Style = style,
		Settings = settings,
		Preview = false,
	})
	local afterModel = RoadBuilder.Build({
		Curve = PolyCurve.new({ afterSegment }),
		ProfileStart = data.ProfileStart,
		Style = style,
		Settings = settings,
		Preview = false,
	})
	beforeModel.Parent = folder
	afterModel.Parent = folder

	local junctionModel = JunctionInstance.Create(splitPos)
	local junctionData = JunctionInstance.Read(junctionModel)
	if not junctionData then
		beforeModel:Destroy()
		afterModel:Destroy()
		return nil, nil, nil
	end

	-- Whatever the original road's own ends were connected to (if
	-- anything) carries over to whichever new piece now owns that end.
	RoadInstance.StampJunctions(beforeModel, data.StartJunctionId, junctionData.Id)
	RoadInstance.StampJunctions(afterModel, junctionData.Id, data.EndJunctionId)

	road:Destroy()

	return beforeModel, afterModel, junctionData.Id
end

return RoadSplit
