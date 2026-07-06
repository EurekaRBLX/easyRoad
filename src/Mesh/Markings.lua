--!strict
-- Lane marking layout: the marking RULE engine.
--
-- Given a (transition-matched) pair of component lists plus the profile's
-- marking options, produce the set of longitudinal lines to paint:
--
--   * Opposing Drive lanes        -> region centre line
--   * Same-direction Drive lanes  -> region lane line, unless the left
--     component carries a boundary rule override:
--       "Solid"       single solid white  - no lane changing
--       "DoubleSolid" double solid white  - strictly no lane changing
--       "SolidDash"   solid on the left, dashes on the right: traffic on
--                     the RIGHT of the boundary may cross (merge left),
--                     traffic on the left may not
--       "DashSolid"   the mirror case
--   * Drive next to Bike/Parking/Shoulder -> solid separator
--   * Roadway outer edges         -> region edge line
--   * Kerb restrictions (UK/HK/SG): single or double yellow lines painted
--     just inside any roadway edge that meets a kerb (raised component or
--     the edge of the road) - the no-parking / no-stopping vocabulary
--
-- The profile may also force all centre/lane lines white or yellow.
--
-- Because component widths can differ at the two ends of a transition
-- segment, every line stores a start offset and an end offset (meters from
-- profile centerline); the builder lerps between them along the road.

local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")

export type MarkingLine = {
	OffsetStartM: number, -- Lateral offset at s=0 (meters from centerline)
	OffsetEndM: number, -- Lateral offset at s=Length
	Line: RegionStyles.LineType,
	Color: Color3,
	DashLengthM: number,
	DashGapM: number,
}

export type MarkingOptions = {
	KerbRestriction: string?, -- "None" | "SingleYellow" | "DoubleYellow"
	MarkingColor: string?, -- "Auto" | "White" | "Yellow" (centre/lane lines)
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
	style: RegionStyles.RegionStyle,
	options: MarkingOptions?
): { MarkingLine }
	local n = #componentsStart
	assert(#componentsEnd == n, "Transition profiles must be matched")

	local kerbRestriction = if options then options.KerbRestriction else nil
	local colorOverride = if options then options.MarkingColor else nil

	local startOffsets = offsetsFor(componentsStart)
	local endOffsets = offsetsFor(componentsEnd)
	local lines: { MarkingLine } = {}

	local inset = style.MarkingWidthM * 1.5

	-- Colour override applies to centre and lane lines only; kerb lines are
	-- always yellow, edge lines keep their spec colour.
	local function trafficLineColor(specColor: Color3): Color3
		if colorOverride == "White" then
			return style.WhiteMarking
		elseif colorOverride == "Yellow" then
			return style.YellowMarking
		end
		return specColor
	end

	local function addSpec(offsetStart: number, offsetEnd: number, spec: RegionStyles.MarkingSpec, color: Color3)
		if spec.Line == "None" then
			return
		end
		table.insert(lines, {
			OffsetStartM = offsetStart,
			OffsetEndM = offsetEnd,
			Line = spec.Line,
			Color = color,
			DashLengthM = spec.DashLengthM or style.DashLengthM,
			DashGapM = spec.DashGapM or style.DashGapM,
		})
	end

	local function addLine(
		offsetStart: number,
		offsetEnd: number,
		lineType: RegionStyles.LineType,
		color: Color3,
		dashLengthM: number?,
		dashGapM: number?
	)
		if lineType == "None" then
			return
		end
		table.insert(lines, {
			OffsetStartM = offsetStart,
			OffsetEndM = offsetEnd,
			Line = lineType,
			Color = color,
			DashLengthM = dashLengthM or style.DashLengthM,
			DashGapM = dashGapM or style.DashGapM,
		})
	end

	-- Kerb (no parking / no stopping) lines: painted just inside a roadway
	-- edge that meets a kerb - a raised component or the edge of the road.
	local kerbLineType: RegionStyles.LineType? = nil
	if kerbRestriction == "SingleYellow" then
		kerbLineType = "Solid"
	elseif kerbRestriction == "DoubleYellow" then
		kerbLineType = "DoubleSolid"
	end
	local kerbInset = style.MarkingWidthM * 2.5

	for i = 1, n do
		local component = componentsStart[i]
		local isRoadway = RoadProfile.IsRoadway(component.Kind)
		local nextComponent = componentsStart[i + 1]
		local nextIsRoadway = nextComponent and RoadProfile.IsRoadway(nextComponent.Kind)
		local previousComponent = componentsStart[i - 1]
		local previousIsRoadway = previousComponent and RoadProfile.IsRoadway(previousComponent.Kind)

		if isRoadway then
			-- Edge line at the left edge of a roadway run
			if not previousIsRoadway and component.Kind == "Drive" then
				addSpec(startOffsets[i].Left + inset, endOffsets[i].Left + inset,
					style.EdgeLine, style.EdgeLine.Color)
			end
			-- Edge line at the right edge of a roadway run
			if not nextIsRoadway and component.Kind == "Drive" then
				addSpec(startOffsets[i].Right - inset, endOffsets[i].Right - inset,
					style.EdgeLine, style.EdgeLine.Color)
			end

			-- Kerb restriction lines at roadway edges that meet a kerb
			if kerbLineType then
				local leftIsKerb = previousComponent == nil
					or RoadProfile.IsRaised(previousComponent.Kind)
				local rightIsKerb = nextComponent == nil
					or RoadProfile.IsRaised(nextComponent.Kind)
				if leftIsKerb then
					addLine(startOffsets[i].Left + kerbInset, endOffsets[i].Left + kerbInset,
						kerbLineType, style.YellowMarking)
				end
				if rightIsKerb then
					addLine(startOffsets[i].Right - kerbInset, endOffsets[i].Right - kerbInset,
						kerbLineType, style.YellowMarking)
				end
			end
		end

		-- Boundary between this component and the next
		if nextComponent and isRoadway and nextIsRoadway then
			local boundaryStart = startOffsets[i].Right
			local boundaryEnd = endOffsets[i].Right
			local a, b = component, nextComponent
			if a.Kind == "Drive" and b.Kind == "Drive" then
				if a.Direction ~= 0 and b.Direction ~= 0 and a.Direction ~= b.Direction then
					addSpec(boundaryStart, boundaryEnd,
						style.CenterLine, trafficLineColor(style.CenterLine.Color))
				else
					-- Same-direction boundary: apply the component's rule
					local rule = a.RightBoundary
					if rule ~= nil and rule ~= "Auto" then
						addLine(boundaryStart, boundaryEnd,
							rule :: RegionStyles.LineType,
							trafficLineColor(style.WhiteMarking),
							style.LaneLine.DashLengthM, style.LaneLine.DashGapM)
					else
						addSpec(boundaryStart, boundaryEnd,
							style.LaneLine, trafficLineColor(style.LaneLine.Color))
					end
				end
			elseif (a.Kind == "Drive") ~= (b.Kind == "Drive") then
				-- Drive next to bike/parking/shoulder: solid separator
				addLine(boundaryStart, boundaryEnd, "Solid", style.EdgeLine.Color)
			end
		end
	end

	return lines
end

return Markings
