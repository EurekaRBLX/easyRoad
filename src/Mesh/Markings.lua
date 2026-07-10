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
	KerbStretches: { KerbStretch }?,
}

-- A user-placed override on one or more same-direction lane boundaries'
-- markings over part of the road's length (e.g. a dashed lane line forced
-- solid approaching a junction) - see RoadEditSession's
-- PlacingMarkingStretch/ConfirmingMarkingStretch modes for how these are
-- captured, including the All/Individual/Select boundary-selection modes
-- that decide what ComponentIndices ends up holding.
--
-- ComponentIndices is any set of same-direction Drive/Drive boundary
-- indices (each between components[i] and components[i + 1]) - not
-- necessarily a whole contiguous run, since Select mode can pick an
-- arbitrary subset. Each listed index gets its own independent override;
-- a boundary can also appear in more than one MarkingStretch (see
-- Markings.Compute's stretchByBoundary, which is keyed per boundary as a
-- list, not a single value).
export type MarkingStretch = {
	ComponentIndices: { number },
	FromStationStuds: number,
	ToStationStuds: number,
	Line: RegionStyles.LineType,
	-- Optional per-stretch dash rhythm override, independent of the
	-- region's own DashLengthM/DashGapM (or the whole-road DashLengthM/
	-- DashGapM override) - nil falls back to those exactly like any other
	-- dashed line. Only meaningful when Line has a dashed component
	-- (Dashed/DoubleDashed/SolidDash/DashSolid); harmless (simply unused)
	-- otherwise.
	DashLengthM: number?,
	DashGapM: number?,
}

-- A user-placed override on ONE of the road's kerb-restriction lines over
-- part of the road's length (e.g. double yellow everywhere except a short
-- loading-bay stretch marked "None") - see RoadEditSession's
-- PlacingKerbStretch/ConfirmingKerbStretch modes.
--
-- EdgeIndex identifies WHICH kerb line, using the same "boundary index"
-- numbering `RoadProfile.ComponentOffsetsM` implies: 0 = the road's true
-- left edge (before components[1]), i (1 <= i < #components) = the
-- boundary between components[i] and components[i+1], #components = the
-- road's true right edge. A profile can have more than two kerb lines
-- (e.g. either side of an internal median splitting two carriageways) -
-- every one of them is a valid, independently overridable EdgeIndex, not
-- just the outermost two.
export type KerbStretch = {
	EdgeIndex: number,
	FromStationStuds: number,
	ToStationStuds: number,
	Restriction: string, -- "None" | "SingleYellow" | "DoubleYellow" | "NoLine"
}

local Markings = {}

-- Every same-direction Drive/Drive boundary index (1-based, between
-- components[i] and [i + 1]) in the road - mirrors exactly the condition
-- the boundary loop in Compute uses to pick the "same-direction boundary"
-- branch, since only those boundaries are valid stretch targets.
local function sameDirBoundaries(components: { RoadProfile.ProfileComponent }): { [number]: boolean }
	local isSameDirBoundary: { [number]: boolean } = {}
	for i = 1, #components - 1 do
		local a, b = components[i], components[i + 1]
		isSameDirBoundary[i] = a.Kind == "Drive"
			and b.Kind == "Drive"
			and not (a.Direction ~= 0 and b.Direction ~= 0 and a.Direction ~= b.Direction)
	end
	return isSameDirBoundary
end

-- Whether componentIndex is a valid same-direction Drive/Drive boundary at
-- all - the basic membership test both "All"/"Individual" clicks and
-- "Select" mode's toggling need before adding an index to a MarkingStretch.
function Markings.IsSameDirectionBoundary(components: { RoadProfile.ProfileComponent }, componentIndex: number): boolean
	return sameDirBoundaries(components)[componentIndex] == true
end

-- Every boundary index in componentIndex's own contiguous same-direction
-- run (including componentIndex itself) - a run breaks wherever the
-- direction changes or a non-Drive component interrupts it. Empty if
-- componentIndex isn't a same-direction Drive/Drive boundary at all. Used
-- for the "All" selection mode (and its drag-ghost preview) - "Individual"
-- and "Select" build their own ComponentIndices sets directly instead.
function Markings.SiblingBoundaries(components: { RoadProfile.ProfileComponent }, componentIndex: number): { number }
	local isSameDirBoundary = sameDirBoundaries(components)
	if not isSameDirBoundary[componentIndex] then
		return {}
	end
	local lo, hi = componentIndex, componentIndex
	while isSameDirBoundary[lo - 1] do
		lo -= 1
	end
	while isSameDirBoundary[hi + 1] do
		hi += 1
	end
	local members = {}
	for j = lo, hi do
		table.insert(members, j)
	end
	return members
end

-- Every EdgeIndex where Compute's render loop would actually paint a kerb-
-- restriction line (or suppress a plain edge line for "NoLine") - i.e.
-- every valid KerbStretch target on this profile, not just the road's two
-- outermost edges. Mirrors EXACTLY the leftIsKerb/rightIsKerb condition
-- the render loop below uses, for every roadway component's run, not only
-- the first/last one - shared so a click can't target a "kerb" that
-- doesn't really exist, and so a profile with an internal median (giving
-- it more than two kerb lines) can have every one of them selected.
function Markings.KerbEdges(components: { RoadProfile.ProfileComponent }): { number }
	local edges: { number } = {}
	for i = 1, #components do
		if RoadProfile.IsRoadway(components[i].Kind) then
			local previousComponent = components[i - 1]
			local previousIsRoadway = previousComponent ~= nil and RoadProfile.IsRoadway(previousComponent.Kind)
			if not previousIsRoadway then
				local leftIsKerb = previousComponent == nil or RoadProfile.IsRaised(previousComponent.Kind)
				if leftIsKerb then
					table.insert(edges, i - 1)
				end
			end
			local nextComponent = components[i + 1]
			local nextIsRoadway = nextComponent ~= nil and RoadProfile.IsRoadway(nextComponent.Kind)
			if not nextIsRoadway then
				local rightIsKerb = nextComponent == nil or RoadProfile.IsRaised(nextComponent.Kind)
				if rightIsKerb then
					table.insert(edges, i)
				end
			end
		end
	end
	return edges
end

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

	-- A MarkingStretch applies independently to every boundary listed in
	-- its own ComponentIndices (however that set was built - the whole
	-- sibling run, one lane, or an arbitrary hand-picked selection, see the
	-- type's own doc comment). A boundary can carry more than one stretch
	-- (e.g. solid approaching two separate junctions on the same lane
	-- pair) - each MarkingStretch is independent, never merged or replaced
	-- by another one on the same boundary. Indices that no longer resolve
	-- to a valid same-direction boundary (e.g. after a structural profile
	-- edit) are silently skipped rather than erroring.
	local stretchByBoundary: { [number]: { MarkingStretch } } = {}
	if options and options.MarkingStretches then
		for _, stretch in options.MarkingStretches :: { MarkingStretch } do
			for _, j in stretch.ComponentIndices do
				if Markings.IsSameDirectionBoundary(componentsStart, j) then
					if not stretchByBoundary[j] then
						stretchByBoundary[j] = {}
					end
					table.insert(stretchByBoundary[j], stretch)
				end
			end
		end
	end

	-- Emits a same-direction lane boundary's line, splicing in every
	-- MarkingStretch that targets this boundary (sorted by station) as its
	-- own middle sub-range, with the base line type resuming between and
	-- around them. Always emits the "before"/"between"/"after" pieces even
	-- when an override sits flush against a segment end or another
	-- stretch - RoadBuilder's own station clipping renders nothing for a
	-- degenerate (empty) sub-range, so this is safe without extra
	-- edge-case branching here. Overlapping stretches on the same boundary
	-- aren't validated against each other - a malformed overlap just
	-- produces a degenerate (empty or negative) "between" piece, which
	-- clips away harmlessly rather than crashing.
	local function emitBoundaryLine(
		boundaryIndex: number,
		offsetStart: number,
		offsetEnd: number,
		lineType: RegionStyles.LineType,
		color: Color3,
		dashLengthM: number?,
		dashGapM: number?
	)
		local stretches = stretchByBoundary[boundaryIndex]
		if not stretches or #stretches == 0 then
			addLine(offsetStart, offsetEnd, lineType, color, dashLengthM, dashGapM)
			return
		end
		local sorted = table.clone(stretches)
		table.sort(sorted, function(a, b)
			return a.FromStationStuds < b.FromStationStuds
		end)
		local cursor: number? = nil
		for _, stretch in sorted do
			addLine(offsetStart, offsetEnd, lineType, color, dashLengthM, dashGapM, cursor, stretch.FromStationStuds)
			addLine(
				offsetStart,
				offsetEnd,
				stretch.Line,
				trafficLineColor(style.WhiteMarking),
				stretch.DashLengthM,
				stretch.DashGapM,
				stretch.FromStationStuds,
				stretch.ToStationStuds
			)
			cursor = stretch.ToStationStuds
		end
		addLine(offsetStart, offsetEnd, lineType, color, dashLengthM, dashGapM, cursor, nil)
	end

	-- Kerb (no parking / no stopping) lines: painted just inside a roadway
	-- edge that meets a kerb - a raised component or the edge of the road.
	local kerbIndent = if options then options.KerbIndent else nil
	local kerbInset = if kerbIndent == false then inset else style.MarkingWidthM * 2.5

	local function kerbLineTypeFor(restriction: string?): RegionStyles.LineType?
		if restriction == "SingleYellow" then
			return "Solid"
		elseif restriction == "DoubleYellow" then
			return "DoubleSolid"
		end
		return nil
	end

	local kerbStretchesByEdge: { [number]: { KerbStretch } } = {}
	if options and options.KerbStretches then
		for _, stretch in options.KerbStretches :: { KerbStretch } do
			local list = kerbStretchesByEdge[stretch.EdgeIndex]
			if not list then
				list = {}
				kerbStretchesByEdge[stretch.EdgeIndex] = list
			end
			table.insert(list, stretch)
		end
	end

	-- Emits one piece of a kerb-adjacent roadway edge for a given effective
	-- restriction value - either the yellow kerb-restriction line (at
	-- kerbInset), nothing at all ("NoLine"), or the plain region edge line
	-- (at inset) - exactly the same three-way choice the un-spliced code
	-- below always made, just parameterized so a KerbStretch's own
	-- Restriction can pick a DIFFERENT one for its own sub-range.
	local function emitKerbEdge(
		plainOffsetStart: number,
		plainOffsetEnd: number,
		kerbOffsetStart: number,
		kerbOffsetEnd: number,
		fromStationStuds: number?,
		toStationStuds: number?,
		restriction: string?
	)
		local lineType = kerbLineTypeFor(restriction)
		if lineType then
			addLine(
				kerbOffsetStart,
				kerbOffsetEnd,
				lineType,
				style.YellowMarking,
				nil,
				nil,
				fromStationStuds,
				toStationStuds
			)
		elseif restriction == "NoLine" then
			-- no marking at all
		else
			addLine(
				plainOffsetStart,
				plainOffsetEnd,
				style.EdgeLine.Line,
				style.EdgeLine.Color,
				style.EdgeLine.DashLengthM,
				style.EdgeLine.DashGapM,
				fromStationStuds,
				toStationStuds
			)
		end
	end

	-- Emits a kerb-adjacent roadway edge at the given EdgeIndex, splicing
	-- any KerbStretches targeting it (sorted by station) exactly like
	-- emitBoundaryLine splices lane-boundary stretches: before/stretch/
	-- between/stretch/.../after, each piece independently picking its own
	-- line type and offset from its own effective restriction (the
	-- whole-road KerbRestriction outside any stretch, the stretch's own
	-- Restriction inside one). Degenerates to exactly the single unspliced
	-- call below when there are no stretches for this edge.
	local function emitKerbEdgeAt(
		edgeIndex: number,
		plainOffsetStart: number,
		plainOffsetEnd: number,
		kerbOffsetStart: number,
		kerbOffsetEnd: number
	)
		local stretches = kerbStretchesByEdge[edgeIndex]
		if not stretches or #stretches == 0 then
			emitKerbEdge(plainOffsetStart, plainOffsetEnd, kerbOffsetStart, kerbOffsetEnd, nil, nil, kerbRestriction)
			return
		end
		local sorted = table.clone(stretches)
		table.sort(sorted, function(a, b)
			return a.FromStationStuds < b.FromStationStuds
		end)
		local cursor: number? = nil
		for _, stretch in sorted do
			emitKerbEdge(
				plainOffsetStart,
				plainOffsetEnd,
				kerbOffsetStart,
				kerbOffsetEnd,
				cursor,
				stretch.FromStationStuds,
				kerbRestriction
			)
			emitKerbEdge(
				plainOffsetStart,
				plainOffsetEnd,
				kerbOffsetStart,
				kerbOffsetEnd,
				stretch.FromStationStuds,
				stretch.ToStationStuds,
				stretch.Restriction
			)
			cursor = stretch.ToStationStuds
		end
		emitKerbEdge(plainOffsetStart, plainOffsetEnd, kerbOffsetStart, kerbOffsetEnd, cursor, nil, kerbRestriction)
	end

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
				if leftIsKerb then
					emitKerbEdgeAt(
						i - 1,
						startOffsets[i].Left + inset,
						endOffsets[i].Left + inset,
						startOffsets[i].Left + kerbInset,
						endOffsets[i].Left + kerbInset
					)
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
				if rightIsKerb then
					emitKerbEdgeAt(
						i,
						startOffsets[i].Right - inset,
						endOffsets[i].Right - inset,
						startOffsets[i].Right - kerbInset,
						endOffsets[i].Right - kerbInset
					)
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
