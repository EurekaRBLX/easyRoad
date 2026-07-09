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
	-- Longitudinal render range in studs (RoadBuilder's own station space,
	-- NOT meters - matches RoadInstance.BayData's StationStuds convention).
	-- nil/nil means the whole segment, same as before this field existed;
	-- set by a "stretch" override below to restrict this particular line
	-- to a sub-range (used to splice a different line type - e.g. a solid
	-- no-lane-change line - into part of an otherwise-continuous boundary).
	FromStationStuds: number?,
	ToStationStuds: number?,
}

export type MarkingOptions = {
	KerbRestriction: string?, -- "None" | "SingleYellow" | "DoubleYellow" | "NoLine"
	MarkingColor: string?, -- "Auto" | "White" | "Yellow" (centre/lane lines)
	DashLengthM: number?, -- Override dash geometry for every dashed line on this road
	DashGapM: number?,
	KerbIndent: boolean?, -- true/nil = inset from the kerb, false = flush at the plain edge-line spot
	MarkingStretches: { MarkingStretch }?,
}

-- A user-placed override on a same-direction lane boundary's marking over
-- part of the road's length (e.g. a dashed lane line forced solid
-- approaching a junction) - see RoadEditSession's PlacingMarkingStretch/
-- ConfirmingMarkingStretch modes for how these are captured.
--
-- ComponentIndex identifies ANY ONE same-direction Drive/Drive boundary in
-- the "sibling run" this override targets (the boundary between
-- components[ComponentIndex] and components[ComponentIndex + 1]) - siblings
-- are resolved below to every internal boundary of that same contiguous,
-- same-direction run, so dragging one lane's line stretches all of them
-- together, matching how real multi-lane no-lane-change zones read. A
-- separate same-direction run elsewhere in the cross-section (e.g. the
-- opposing carriageway on a divided road) is a different sibling group and
-- unaffected by this entry.
export type MarkingStretch = {
	ComponentIndex: number,
	FromStationStuds: number,
	ToStationStuds: number,
	Line: RegionStyles.LineType,
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
	local dashLengthOverride = if options then options.DashLengthM else nil
	local dashGapOverride = if options then options.DashGapM else nil

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
			DashLengthM = dashLengthOverride or spec.DashLengthM or style.DashLengthM,
			DashGapM = dashGapOverride or spec.DashGapM or style.DashGapM,
		})
	end

	local function addLine(
		offsetStart: number,
		offsetEnd: number,
		lineType: RegionStyles.LineType,
		color: Color3,
		dashLengthM: number?,
		dashGapM: number?,
		fromStationStuds: number?,
		toStationStuds: number?
	)
		if lineType == "None" then
			return
		end
		table.insert(lines, {
			OffsetStartM = offsetStart,
			OffsetEndM = offsetEnd,
			Line = lineType,
			Color = color,
			DashLengthM = dashLengthOverride or dashLengthM or style.DashLengthM,
			DashGapM = dashGapOverride or dashGapM or style.DashGapM,
			FromStationStuds = fromStationStuds,
			ToStationStuds = toStationStuds,
		})
	end

	-- Every same-direction Drive/Drive boundary index (1-based, between
	-- componentsStart[i] and [i + 1]) that a lane-changing rule can apply
	-- to - mirrors exactly the condition the boundary loop below uses to
	-- pick the "same-direction boundary" branch, computed up front so
	-- sibling runs (see below) can be resolved before that loop runs.
	local isSameDirBoundary: { [number]: boolean } = {}
	for i = 1, n - 1 do
		local a, b = componentsStart[i], componentsStart[i + 1]
		isSameDirBoundary[i] = a.Kind == "Drive"
			and b.Kind == "Drive"
			and not (a.Direction ~= 0 and b.Direction ~= 0 and a.Direction ~= b.Direction)
	end

	-- Maps every same-direction boundary index to every other boundary
	-- index in its own contiguous run - a run breaks wherever the
	-- direction changes or a non-Drive component interrupts it. A
	-- MarkingStretch naming any one boundary in a run applies to every
	-- member of that run, which is what makes dragging one lane's marking
	-- stretch its same-direction siblings together.
	local siblingsOf: { [number]: { number } } = {}
	do
		local runStart: number? = nil
		local function closeRun(runEnd: number)
			if not runStart then
				return
			end
			local members = {}
			for j = runStart, runEnd do
				table.insert(members, j)
			end
			for _, j in members do
				siblingsOf[j] = members
			end
			runStart = nil
		end
		for i = 1, n - 1 do
			if isSameDirBoundary[i] then
				if not runStart then
					runStart = i
				end
			else
				closeRun(i - 1)
			end
		end
		closeRun(n - 1)
	end

	local stretchByBoundary: { [number]: MarkingStretch } = {}
	if options and options.MarkingStretches then
		for _, stretch in options.MarkingStretches :: { MarkingStretch } do
			local siblings = siblingsOf[stretch.ComponentIndex]
			if siblings then
				for _, j in siblings do
					stretchByBoundary[j] = stretch
				end
			end
		end
	end

	-- Emits a same-direction lane boundary's line, splicing in a
	-- MarkingStretch override (if this boundary is a member of one) as a
	-- middle sub-range with the base line type resuming on either side.
	-- Always emits the "before"/"after" pieces even when the override sits
	-- flush against one end of the segment - RoadBuilder's own station
	-- clipping renders nothing for a degenerate (empty) sub-range, so this
	-- is safe without extra edge-case branching here.
	local function emitBoundaryLine(
		boundaryIndex: number,
		offsetStart: number,
		offsetEnd: number,
		lineType: RegionStyles.LineType,
		color: Color3,
		dashLengthM: number?,
		dashGapM: number?
	)
		local stretch = stretchByBoundary[boundaryIndex]
		if not stretch then
			addLine(offsetStart, offsetEnd, lineType, color, dashLengthM, dashGapM)
			return
		end
		addLine(offsetStart, offsetEnd, lineType, color, dashLengthM, dashGapM, nil, stretch.FromStationStuds)
		addLine(
			offsetStart,
			offsetEnd,
			stretch.Line,
			trafficLineColor(style.WhiteMarking),
			nil,
			nil,
			stretch.FromStationStuds,
			stretch.ToStationStuds
		)
		addLine(offsetStart, offsetEnd, lineType, color, dashLengthM, dashGapM, stretch.ToStationStuds, nil)
	end

	-- Kerb (no parking / no stopping) lines: painted just inside a roadway
	-- edge that meets a kerb - a raised component or the edge of the road.
	local kerbLineType: RegionStyles.LineType? = nil
	if kerbRestriction == "SingleYellow" then
		kerbLineType = "Solid"
	elseif kerbRestriction == "DoubleYellow" then
		kerbLineType = "DoubleSolid"
	end
	local kerbIndent = if options then options.KerbIndent else nil
	local kerbInset = if kerbIndent == false then inset else style.MarkingWidthM * 2.5

	for i = 1, n do
		local component = componentsStart[i]
		local isRoadway = RoadProfile.IsRoadway(component.Kind)
		local nextComponent = componentsStart[i + 1]
		local nextIsRoadway = nextComponent and RoadProfile.IsRoadway(nextComponent.Kind)
		local previousComponent = componentsStart[i - 1]
		local previousIsRoadway = previousComponent and RoadProfile.IsRoadway(previousComponent.Kind)

		if isRoadway then
			local leftIsKerb = previousComponent == nil or RoadProfile.IsRaised(previousComponent.Kind)
			local rightIsKerb = nextComponent == nil or RoadProfile.IsRaised(nextComponent.Kind)

			-- Left edge of a roadway run: kerb restriction line REPLACES the
			-- plain region edge line (they occupy the same physical spot -
			-- a no-parking line already marks the roadway edge). Applies to
			-- any roadway kind at the outer edge (Drive, Parking, Bay, ...) -
			-- kerb lines matter most exactly where parking/bay lanes meet
			-- the kerb. "NoLine" suppresses both entirely at a genuine kerb
			-- boundary (leftIsKerb/rightIsKerb) - "None" ("No restriction")
			-- still falls back to the plain edge line, since that's a
			-- separate concept (no *parking* restriction, not no marking at
			-- all); a non-kerb roadway edge (e.g. a median boundary) always
			-- keeps its plain edge line regardless of KerbRestriction.
			if not previousIsRoadway then
				if kerbLineType and leftIsKerb then
					addLine(
						startOffsets[i].Left + kerbInset,
						endOffsets[i].Left + kerbInset,
						kerbLineType,
						style.YellowMarking
					)
				elseif kerbRestriction == "NoLine" and leftIsKerb then
					-- no marking at all
				else
					addSpec(
						startOffsets[i].Left + inset,
						endOffsets[i].Left + inset,
						style.EdgeLine,
						style.EdgeLine.Color
					)
				end
			end
			-- Right edge of a roadway run: same rule
			if not nextIsRoadway then
				if kerbLineType and rightIsKerb then
					addLine(
						startOffsets[i].Right - kerbInset,
						endOffsets[i].Right - kerbInset,
						kerbLineType,
						style.YellowMarking
					)
				elseif kerbRestriction == "NoLine" and rightIsKerb then
					-- no marking at all
				else
					addSpec(
						startOffsets[i].Right - inset,
						endOffsets[i].Right - inset,
						style.EdgeLine,
						style.EdgeLine.Color
					)
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
					addSpec(boundaryStart, boundaryEnd, style.CenterLine, trafficLineColor(style.CenterLine.Color))
				else
					-- Same-direction boundary: apply the component's rule
					local rule = a.RightBoundary
					if rule ~= nil and rule ~= "Auto" then
						emitBoundaryLine(
							i,
							boundaryStart,
							boundaryEnd,
							rule :: RegionStyles.LineType,
							trafficLineColor(style.WhiteMarking),
							style.LaneLine.DashLengthM,
							style.LaneLine.DashGapM
						)
					else
						emitBoundaryLine(
							i,
							boundaryStart,
							boundaryEnd,
							style.LaneLine.Line,
							trafficLineColor(style.LaneLine.Color),
							style.LaneLine.DashLengthM,
							style.LaneLine.DashGapM
						)
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
