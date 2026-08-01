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
local Markings = require("./Mesh/Markings")

export type BayData = {
	StationStuds: number,
	LengthStuds: number,
	WidthM: number,
	-- Which side of the road (looking along the direction of travel from
	-- the curve's start) the bay was dragged toward - determines which
	-- edge's pavement gets displaced, independent of the region's
	-- DriveOnLeft setting (a bay can be drawn on either side regardless of
	-- which side traffic normally drives on).
	Side: "Left" | "Right",
}

export type StructureMode = "None" | "Viaduct" | "Tunnel"

export type StructureData = {
	Mode: StructureMode,
	-- References a Model in ServerStorage/EasyRoadAssets. Viaduct mode can
	-- omit one and use the procedural road itself as the deck; tunnels omit
	-- one to use EasyRoad's procedural concrete shell.
	AssetId: string?,
	ModuleOffsetM: number,
	AutoPillars: boolean,
	PillarSpacingM: number,
	PillarWidthM: number,
	PillarDepthM: number,
	MaxPillarHeightM: number,
	-- Procedural structure appearance/fit. Stored per road so changing the
	-- global defaults never restyles an already-placed viaduct or tunnel.
	ConcreteColorHex: string,
	InterfaceOverlapM: number,
	ViaductParapetGapM: number,
	TunnelWallClearanceM: number,
	ConcreteMedian: boolean,
}

export type RoadData = {
	-- Stable identity used by junction approach ports. Older placed roads are
	-- assigned one lazily the first time a multinode junction reads them.
	Id: string,
	StartPortId: string,
	EndPortId: string,
	Curve: PolyCurve.PolyCurve,
	ProfileStart: RoadProfile.RoadProfile,
	ProfileEnd: RoadProfile.RoadProfile?,
	Bay: BayData?,
	MarkingStretches: { Markings.MarkingStretch },
	KerbStretches: { Markings.KerbStretch },
	Structure: StructureData?,
	-- Ids of the JunctionNode (see JunctionInstance.lua) this road's start/
	-- end connects to, if any - nil means a free (unconnected) end.
	StartJunctionId: string?,
	EndJunctionId: string?,
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
	curve: PolyCurve.PolyCurve,
	profileStart: RoadProfile.RoadProfile,
	profileEnd: RoadProfile.RoadProfile?
)
	model:SetAttribute("RW_Road", true)
	if typeof(model:GetAttribute("RW_RoadId")) ~= "string" then
		model:SetAttribute("RW_RoadId", HttpService:GenerateGUID(false))
	end
	if typeof(model:GetAttribute("RW_StartPortId")) ~= "string" then
		model:SetAttribute("RW_StartPortId", HttpService:GenerateGUID(false))
	end
	if typeof(model:GetAttribute("RW_EndPortId")) ~= "string" then
		model:SetAttribute("RW_EndPortId", HttpService:GenerateGUID(false))
	end
	local serializedSegments = {}
	for _, segment in curve.Segments do
		local function point(value: Vector3?): { number }?
			return if value then { value.X, value.Y, value.Z } else nil
		end
		table.insert(serializedSegments, {
			Kind = segment.Kind,
			P0 = point(segment.P0),
			P1 = point(segment.P1),
			P2 = point(segment.P2),
			P3 = point(segment.P3),
		})
	end
	model:SetAttribute("RW_CurveJson", HttpService:JSONEncode(serializedSegments))
	-- Preserve the original single-segment attributes for compatibility with
	-- existing places and external scripts that inspect them directly.
	local legacy = if #curve.Segments == 1 then curve.Segments[1] else nil
	model:SetAttribute("RW_CurveKind", if legacy then legacy.Kind else "Poly")
	model:SetAttribute("RW_P0", if legacy then legacy.P0 else nil)
	model:SetAttribute("RW_P1", if legacy then legacy.P1 else nil)
	model:SetAttribute("RW_P2", if legacy then legacy.P2 else nil)
	model:SetAttribute("RW_P3", if legacy then legacy.P3 else nil)
	model:SetAttribute("RW_ProfileStartJson", HttpService:JSONEncode(RoadProfile.Serialize(profileStart)))
	model:SetAttribute(
		"RW_ProfileEndJson",
		if profileEnd then HttpService:JSONEncode(RoadProfile.Serialize(profileEnd)) else nil
	)
	model:SetAttribute("RW_ProfileStartId", profileStart.Id)
	model:SetAttribute("RW_ProfileEndId", if profileEnd then profileEnd.Id else profileStart.Id)
	-- Cheap Vector3 reads for endpoint-snap lookups elsewhere (no JSON decode)
	model:SetAttribute("RW_StartPos", curve:PosAt(0))
	model:SetAttribute("RW_EndPos", curve:PosAt(curve.Length))
	model:SetAttribute("RW_StartTan", curve:TangentAt(0))
	model:SetAttribute("RW_EndTan", curve:TangentAt(curve.Length))
end

-- Returns a persistent road id, migrating roads stamped before RW_RoadId was
-- introduced. Junction approach/corner ids are derived from this value, so a
-- rebuild never renumbers the controls merely because angular order changed.
function RoadInstance.EnsureId(model: Model): string
	local existing = model:GetAttribute("RW_RoadId")
	if typeof(existing) == "string" then
		return existing
	end
	local id = HttpService:GenerateGUID(false)
	model:SetAttribute("RW_RoadId", id)
	return id
end

function RoadInstance.EnsurePortIds(model: Model): (string, string)
	local startId = model:GetAttribute("RW_StartPortId")
	local endId = model:GetAttribute("RW_EndPortId")
	if typeof(startId) ~= "string" then
		startId = HttpService:GenerateGUID(false)
		model:SetAttribute("RW_StartPortId", startId)
	end
	if typeof(endId) ~= "string" then
		endId = HttpService:GenerateGUID(false)
		model:SetAttribute("RW_EndPortId", endId)
	end
	return startId, endId
end

-- Used by RoadSplit: the first and last replacement pieces retain the
-- original outer endpoint identities, while fresh internal cut ends keep the
-- ids generated by RoadBuilder. Corner overrides at remote junctions survive.
function RoadInstance.PreserveOuterPortIds(model: Model, startPortId: string?, endPortId: string?)
	if startPortId then
		model:SetAttribute("RW_StartPortId", startPortId)
	end
	if endPortId then
		model:SetAttribute("RW_EndPortId", endPortId)
	end
end

-- Junction connectivity is stamped separately (rather than folded into
-- StampModel) since it's optional and set independently at each end - one
-- end might snap to an existing junction while the other stays free, or a
-- road placed before this feature existed has neither yet. nil clears an
-- end back to unconnected (e.g. if the junction it referenced is deleted).
function RoadInstance.StampJunctions(model: Model, startJunctionId: string?, endJunctionId: string?)
	model:SetAttribute("RW_StartJunctionId", startJunctionId)
	model:SetAttribute("RW_EndJunctionId", endJunctionId)
end

-- Bus bay placement is stamped separately (rather than folded into
-- StampModel) since it's optional and only ever set/read by
-- RoadEditSession, not by the initial placement flow.
function RoadInstance.StampBay(model: Model, bay: BayData?)
	model:SetAttribute("RW_BayJson", if bay then HttpService:JSONEncode(bay) else nil)
end

function RoadInstance.StampStructure(model: Model, structure: StructureData?)
	model:SetAttribute(
		"RW_StructureJson",
		if structure and structure.Mode ~= "None" then HttpService:JSONEncode(structure) else nil
	)
end

local function structureFromModel(model: Model): StructureData?
	local raw = model:GetAttribute("RW_StructureJson")
	if typeof(raw) ~= "string" then
		return nil
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or typeof(decoded) ~= "table" or (decoded.Mode ~= "Viaduct" and decoded.Mode ~= "Tunnel") then
		return nil
	end
	return {
		Mode = decoded.Mode :: StructureMode,
		AssetId = if typeof(decoded.AssetId) == "string" then decoded.AssetId else nil,
		ModuleOffsetM = if typeof(decoded.ModuleOffsetM) == "number" then decoded.ModuleOffsetM else 0,
		AutoPillars = if typeof(decoded.AutoPillars) == "boolean" then decoded.AutoPillars else true,
		PillarSpacingM = if typeof(decoded.PillarSpacingM) == "number"
			then math.max(decoded.PillarSpacingM, 0.1)
			else 18,
		PillarWidthM = if typeof(decoded.PillarWidthM) == "number"
			then math.max(decoded.PillarWidthM, 0.1)
			else 1.8,
		PillarDepthM = if typeof(decoded.PillarDepthM) == "number"
			then math.max(decoded.PillarDepthM, 0.1)
			else 1.8,
		MaxPillarHeightM = if typeof(decoded.MaxPillarHeightM) == "number"
			then math.max(decoded.MaxPillarHeightM, 0.1)
			else 200,
		ConcreteColorHex = if typeof(decoded.ConcreteColorHex) == "string"
			then decoded.ConcreteColorHex
			else "#696B70",
		InterfaceOverlapM = if typeof(decoded.InterfaceOverlapM) == "number"
			then math.max(decoded.InterfaceOverlapM, 0)
			else 0.2,
		ViaductParapetGapM = if typeof(decoded.ViaductParapetGapM) == "number"
			then math.max(decoded.ViaductParapetGapM, 0)
			else 0,
		TunnelWallClearanceM = if typeof(decoded.TunnelWallClearanceM) == "number"
			then math.max(decoded.TunnelWallClearanceM, 0)
			else 0.75,
		ConcreteMedian = if typeof(decoded.ConcreteMedian) == "boolean" then decoded.ConcreteMedian else true,
	}
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
		-- Bays stamped before the Side field existed default to Right -
		-- an arbitrary but harmless fallback (they'll just need re-dragging
		-- if that's the wrong side, same as before this fix existed at all).
		Side = if decoded.Side == "Left" then "Left" else "Right",
	}
end

-- Marking stretches are stamped separately (rather than folded into
-- StampModel), same reasoning as StampBay - optional, only ever set/read by
-- RoadEditSession's marking-stretch mode.
function RoadInstance.StampMarkingStretches(model: Model, stretches: { Markings.MarkingStretch })
	model:SetAttribute("RW_MarkingStretchesJson", if #stretches > 0 then HttpService:JSONEncode(stretches) else nil)
end

local function stretchesFromModel(model: Model): { Markings.MarkingStretch }
	local raw = model:GetAttribute("RW_MarkingStretchesJson")
	if typeof(raw) ~= "string" then
		return {}
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or typeof(decoded) ~= "table" then
		return {}
	end
	local stretches: { Markings.MarkingStretch } = {}
	for _, entry in decoded :: { any } do
		if
			typeof(entry) == "table"
			and typeof(entry.ComponentIndices) == "table"
			and typeof(entry.FromStationStuds) == "number"
			and typeof(entry.ToStationStuds) == "number"
			and typeof(entry.Line) == "string"
		then
			local indices: { number } = {}
			for _, index in entry.ComponentIndices :: { any } do
				if typeof(index) == "number" then
					table.insert(indices, index)
				end
			end
			if #indices > 0 then
				table.insert(stretches, {
					ComponentIndices = indices,
					FromStationStuds = entry.FromStationStuds,
					ToStationStuds = entry.ToStationStuds,
					Line = entry.Line :: any,
					DashLengthM = if typeof(entry.DashLengthM) == "number" then entry.DashLengthM else nil,
					DashGapM = if typeof(entry.DashGapM) == "number" then entry.DashGapM else nil,
				})
			end
		end
	end
	return stretches
end

-- Kerb stretches, same stamped-separately convention as marking stretches
-- above.
function RoadInstance.StampKerbStretches(model: Model, stretches: { Markings.KerbStretch })
	model:SetAttribute("RW_KerbStretchesJson", if #stretches > 0 then HttpService:JSONEncode(stretches) else nil)
end

local function kerbStretchesFromModel(model: Model): { Markings.KerbStretch }
	local raw = model:GetAttribute("RW_KerbStretchesJson")
	if typeof(raw) ~= "string" then
		return {}
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or typeof(decoded) ~= "table" then
		return {}
	end
	local stretches: { Markings.KerbStretch } = {}
	for _, entry in decoded :: { any } do
		if
			typeof(entry) == "table"
			and typeof(entry.EdgeIndex) == "number"
			and typeof(entry.FromStationStuds) == "number"
			and typeof(entry.ToStationStuds) == "number"
			and typeof(entry.Restriction) == "string"
		then
			table.insert(stretches, {
				EdgeIndex = entry.EdgeIndex,
				FromStationStuds = entry.FromStationStuds,
				ToStationStuds = entry.ToStationStuds,
				Restriction = entry.Restriction,
			})
		end
	end
	return stretches
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

local function pointFromJson(raw: any): Vector3?
	if
		type(raw) ~= "table"
		or typeof(raw[1]) ~= "number"
		or typeof(raw[2]) ~= "number"
		or typeof(raw[3]) ~= "number"
	then
		return nil
	end
	return Vector3.new(raw[1], raw[2], raw[3])
end

local function curveFromModel(model: Model): PolyCurve.PolyCurve?
	local raw = model:GetAttribute("RW_CurveJson")
	if typeof(raw) == "string" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok and type(decoded) == "table" then
			local segments: { CurveSegment.Segment } = {}
			for _, entry in decoded do
				if type(entry) ~= "table" then
					return nil
				end
				local p0 = pointFromJson(entry.P0)
				local p1 = pointFromJson(entry.P1)
				if not p0 or not p1 then
					return nil
				end
				if entry.Kind == "Line" then
					table.insert(segments, CurveSegment.Line(p0, p1))
				elseif entry.Kind == "Quadratic" then
					local p2 = pointFromJson(entry.P2)
					if not p2 then
						return nil
					end
					table.insert(segments, CurveSegment.Quadratic(p0, p1, p2))
				elseif entry.Kind == "Cubic" then
					local p2 = pointFromJson(entry.P2)
					local p3 = pointFromJson(entry.P3)
					if not p2 or not p3 then
						return nil
					end
					table.insert(segments, CurveSegment.Cubic(p0, p1, p2, p3))
				else
					return nil
				end
			end
			if #segments > 0 then
				return PolyCurve.new(segments)
			end
		end
	end
	local legacy = segmentFromModel(model)
	return if legacy then PolyCurve.new({ legacy }) else nil
end

-- Reconstructs the full curve + profile data from a placed model's
-- attributes. Returns nil if the model predates this attribute set (older
-- placed roads only carry RW_StartPos/RW_EndPos, not curve control points).
function RoadInstance.Read(model: Model): RoadData?
	local curve = curveFromModel(model)
	if not curve then
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
	local startJunctionId = model:GetAttribute("RW_StartJunctionId")
	local endJunctionId = model:GetAttribute("RW_EndJunctionId")
	local startPortId, endPortId = RoadInstance.EnsurePortIds(model)
	return {
		Id = RoadInstance.EnsureId(model),
		StartPortId = startPortId,
		EndPortId = endPortId,
		Curve = curve,
		ProfileStart = profileStart,
		ProfileEnd = profileEnd,
		Bay = bayFromModel(model),
		MarkingStretches = stretchesFromModel(model),
		KerbStretches = kerbStretchesFromModel(model),
		Structure = structureFromModel(model),
		StartJunctionId = if typeof(startJunctionId) == "string" then startJunctionId else nil,
		EndJunctionId = if typeof(endJunctionId) == "string" then endJunctionId else nil,
	}
end

return RoadInstance
