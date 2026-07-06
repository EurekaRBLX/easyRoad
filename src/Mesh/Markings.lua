--!strict
-- Lane marking layout.
--
-- Given a (transition-matched) pair of component lists, produce the set of
-- longitudinal marking lines to paint on the roadway:
--   * Between opposing Drive lanes  -> center line (region style, e.g. double
--     solid yellow in the US, dashed white in the UK)
--   * Between same-direction Drive lanes -> lane line (usually dashed white)
--   * Between a Drive lane and a Bike/Parking lane -> solid lane line
--   * At the outer edges of a contiguous roadway run -> edge line
--
-- Because component widths can differ at the two ends of a transition
-- segment, every line stores a start offset and an end offset (meters from
-- profile centerline); the builder lerps between them along the road.

local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")

export type MarkingLine = {
	OffsetStartM: number, -- Lateral offset at s=0 (meters from centerline)
	OffsetEndM: number, -- Lateral offset at s=Length
	Spec: RegionStyles.MarkingSpec,
}

local Markings = {}

local function offsetsFor(components: { RoadProfile.ProfileComponent }): { { Left: number, Right: number } }
	local total = 0
	for _, component in components do
		total += component.WidthM
	end
	local out = {}
	local x = -total / 2
	for _, component in components do
		table.insert(out, { Left = x, Right = x + component.WidthM })
		x += component.WidthM
	end
	return out
end

-- componentsStart and componentsEnd must have equal length (as produced by
-- RoadProfile.MatchForTransition; for non-transition roads pass the same
-- list twice).
function Markings.Compute(
	componentsStart: { RoadProfile.ProfileComponent },
	componentsEnd: { RoadProfile.ProfileComponent },
	style: RegionStyles.RegionStyle
): { MarkingLine }
	local n = #componentsStart
	assert(#componentsEnd == n, "Transition profiles must be matched")

	local startOffsets = offsetsFor(componentsStart)
	local endOffsets = offsetsFor(componentsEnd)
	local lines: { MarkingLine } = {}

	local inset = style.MarkingWidthM * 1.5

	local function addLine(offsetStart: number, offsetEnd: number, spec: RegionStyles.MarkingSpec)
		if spec.Pattern == "None" then
			return
		end
		table.insert(lines, {
			OffsetStartM = offsetStart,
			OffsetEndM = offsetEnd,
			Spec = spec,
		})
	end

	for i = 1, n do
		local component = componentsStart[i]
		local isRoadway = RoadProfile.IsRoadway(component.Kind)
		local nextComponent = componentsStart[i + 1]
		local nextIsRoadway = nextComponent and RoadProfile.IsRoadway(nextComponent.Kind)

		if isRoadway then
			-- Edge line at the left edge of a roadway run
			local previousComponent = componentsStart[i - 1]
			local previousIsRoadway = previousComponent and RoadProfile.IsRoadway(previousComponent.Kind)
			if not previousIsRoadway and component.Kind == "Drive" then
				addLine(startOffsets[i].Left + inset, endOffsets[i].Left + inset, style.EdgeLine)
			end
			-- Edge line at the right edge of a roadway run
			if not nextIsRoadway and component.Kind == "Drive" then
				addLine(startOffsets[i].Right - inset, endOffsets[i].Right - inset, style.EdgeLine)
			end
		end

		-- Boundary between this component and the next
		if nextComponent and isRoadway and nextIsRoadway then
			local boundaryStart = startOffsets[i].Right
			local boundaryEnd = endOffsets[i].Right
			local a, b = component, nextComponent
			if a.Kind == "Drive" and b.Kind == "Drive" then
				if a.Direction ~= 0 and b.Direction ~= 0 and a.Direction ~= b.Direction then
					addLine(boundaryStart, boundaryEnd, style.CenterLine)
				else
					addLine(boundaryStart, boundaryEnd, style.LaneLine)
				end
			elseif (a.Kind == "Drive") ~= (b.Kind == "Drive") then
				-- Drive next to bike/parking/shoulder: solid separator
				addLine(boundaryStart, boundaryEnd, {
					Pattern = "Solid" :: RegionStyles.MarkingPattern,
					Color = style.EdgeLine.Color,
				})
			end
		end
	end

	return lines
end

return Markings
