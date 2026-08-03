--!strict
-- Preserves the untrimmed source segment for a placed road. Junction and
-- roundabout builders may shorten the rendered curve at an approach, but all
-- later edits must keep using the original source so a changed setback can
-- lengthen the road again instead of compounding previous trims.

local CurveSegment = require("./Geometry/CurveSegment")

local RoadSource = {}

function RoadSource.ReadSegment(road: Model): CurveSegment.Segment?
	local kind = road:GetAttribute("RW_SourceKind")
	local p0 = road:GetAttribute("RW_SourceP0")
	local p1 = road:GetAttribute("RW_SourceP1")
	if typeof(kind) ~= "string" or typeof(p0) ~= "Vector3" or typeof(p1) ~= "Vector3" then
		return nil
	end

	local p2 = road:GetAttribute("RW_SourceP2")
	local p3 = road:GetAttribute("RW_SourceP3")
	if kind == "Line" then
		return CurveSegment.Line(p0, p1)
	elseif kind == "Quadratic" and typeof(p2) == "Vector3" then
		return CurveSegment.Quadratic(p0, p1, p2)
	elseif kind == "Cubic" and typeof(p2) == "Vector3" and typeof(p3) == "Vector3" then
		return CurveSegment.Cubic(p0, p1, p2, p3)
	end
	return nil
end

function RoadSource.WriteSegment(road: Model, segment: CurveSegment.Segment)
	road:SetAttribute("RW_SourceKind", segment.Kind)
	road:SetAttribute("RW_SourceP0", segment.P0)
	road:SetAttribute("RW_SourceP1", segment.P1)
	road:SetAttribute("RW_SourceP2", segment.P2)
	road:SetAttribute("RW_SourceP3", segment.P3)
end

-- Short aliases keep call sites terse while the explicit names document the
-- unit stored by this module for builders that share the public helper.
RoadSource.Read = RoadSource.ReadSegment
RoadSource.Write = RoadSource.WriteSegment

return RoadSource
