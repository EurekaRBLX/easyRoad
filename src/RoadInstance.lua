--!strict
-- Reads and writes the full data needed to reconstruct a placed Road model,
-- stored as attributes on the model itself.
--
-- This is what makes "select a placed road, edit it" possible: the model
-- carries its own curve control points and full (serialized) start/end
-- profiles, not just library profile IDs. A profile applied to a placed
-- road may carry session-only tweaks (a widened lane, a swapped-in Bay)
-- that were never saved to the library, so an ID lookup alone wouldn't be
-- enough to reconstruct it later.

local HttpService = game:GetService("HttpService")

local CurveSegment = require("./Geometry/CurveSegment")
local PolyCurve = require("./Geometry/PolyCurve")
local RoadProfile = require("./RoadProfile")

export type BayData = {
	StationStuds: number,
	LengthStuds: number,
	WidthM: number,
}

export type RoadData = {
	Curve: PolyCurve.PolyCurve,
	ProfileStart: RoadProfile.RoadProfile,
	ProfileEnd: RoadProfile.RoadProfile?,
	Bay: BayData?,
}

local RoadInstance = {}

function RoadInstance.IsRoad(instance: Instance?): boolean
	return instance ~= nil and instance:IsA("Model") and instance:GetAttribute("RW_Road") == true
end

-- Walk up from any clicked/selected instance (a lane part, a marking strip)
-- to the enclosing Road model, if any.
function RoadInstance.FindRoad(instance: Instance?): Model?
	local current = instance
	while current do
		if RoadInstance.IsRoad(current) then
			return current :: Model
		end
		current = current.Parent
	end
	return nil
end

-- Stamps a model with everything needed to fully reconstruct it later.
function RoadInstance.StampModel(
	model: Model,
	segment: CurveSegment.Segment,
	profileStart: RoadProfile.RoadProfile,
	profileEnd: RoadProfile.RoadProfile?
)
	model:SetAttribute("RW_Road", true)
	model:SetAttribute("RW_CurveKind", segment.Kind)
	model:SetAttribute("RW_P0", segment.P0)
	model:SetAttribute("RW_P1", segment.P1)
	model:SetAttribute("RW_P2", segment.P2)
	model:SetAttribute("RW_P3", segment.P3)
	model:SetAttribute("RW_ProfileStartJson", HttpService:JSONEncode(RoadProfile.Serialize(profileStart)))
	model:SetAttribute(
		"RW_ProfileEndJson",
		if profileEnd then HttpService:JSONEncode(RoadProfile.Serialize(profileEnd)) else nil
	)
	model:SetAttribute("RW_ProfileStartId", profileStart.Id)
	model:SetAttribute("RW_ProfileEndId", if profileEnd then profileEnd.Id else profileStart.Id)
	-- Cheap Vector3 reads for endpoint-snap lookups elsewhere (no JSON decode)
	model:SetAttribute("RW_StartPos", segment.P0)
	model:SetAttribute("RW_EndPos", CurveSegment.PosAtS(segment, segment.Length))
	model:SetAttribute("RW_StartTan", CurveSegment.TangentAtS(segment, 0))
	model:SetAttribute("RW_EndTan", CurveSegment.TangentAtS(segment, segment.Length))
end

-- Bus bay placement is stamped separately (rather than folded into
-- StampModel) since it's optional and only ever set/read by
-- RoadEditSession, not by the initial placement flow.
function RoadInstance.StampBay(model: Model, bay: BayData?)
	model:SetAttribute("RW_BayJson", if bay then HttpService:JSONEncode(bay) else nil)
end

local function bayFromModel(model: Model): BayData?
	local raw = model:GetAttribute("RW_BayJson")
	if typeof(raw) ~= "string" then
		return nil
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or typeof(decoded) ~= "table" then
		return nil
	end
	if
		typeof(decoded.StationStuds) ~= "number"
		or typeof(decoded.LengthStuds) ~= "number"
		or typeof(decoded.WidthM) ~= "number"
	then
		return nil
	end
	return {
		StationStuds = decoded.StationStuds,
		LengthStuds = decoded.LengthStuds,
		WidthM = decoded.WidthM,
	}
end

local function segmentFromModel(model: Model): CurveSegment.Segment?
	local kind = model:GetAttribute("RW_CurveKind")
	local p0 = model:GetAttribute("RW_P0")
	local p1 = model:GetAttribute("RW_P1")
	if typeof(kind) ~= "string" or typeof(p0) ~= "Vector3" or typeof(p1) ~= "Vector3" then
		return nil
	end
	if kind == "Line" then
		return CurveSegment.Line(p0, p1)
	elseif kind == "Quadratic" then
		local p2 = model:GetAttribute("RW_P2")
		if typeof(p2) ~= "Vector3" then
			return nil
		end
		return CurveSegment.Quadratic(p0, p1, p2)
	elseif kind == "Cubic" then
		local p2 = model:GetAttribute("RW_P2")
		local p3 = model:GetAttribute("RW_P3")
		if typeof(p2) ~= "Vector3" or typeof(p3) ~= "Vector3" then
			return nil
		end
		return CurveSegment.Cubic(p0, p1, p2, p3)
	end
	return nil
end

-- Reconstructs the full curve + profile data from a placed model's
-- attributes. Returns nil if the model predates this attribute set (older
-- placed roads only carry RW_StartPos/RW_EndPos, not curve control points).
function RoadInstance.Read(model: Model): RoadData?
	local segment = segmentFromModel(model)
	if not segment then
		return nil
	end
	local startJson = model:GetAttribute("RW_ProfileStartJson")
	if typeof(startJson) ~= "string" then
		return nil
	end
	local ok, startRaw = pcall(HttpService.JSONDecode, HttpService, startJson)
	if not ok then
		return nil
	end
	local profileStart = RoadProfile.Deserialize(startRaw)
	if not profileStart then
		return nil
	end
	local profileEnd: RoadProfile.RoadProfile? = nil
	local endJson = model:GetAttribute("RW_ProfileEndJson")
	if typeof(endJson) == "string" then
		local okEnd, endRaw = pcall(HttpService.JSONDecode, HttpService, endJson)
		if okEnd then
			profileEnd = RoadProfile.Deserialize(endRaw)
		end
	end
	return {
		Curve = PolyCurve.new({ segment }),
		ProfileStart = profileStart,
		ProfileEnd = profileEnd,
		Bay = bayFromModel(model),
	}
end

return RoadInstance
