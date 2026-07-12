--!strict
-- RoadBuilder: turns a PolyCurve + RoadProfile(s) + RegionStyle into actual
-- geometry (a Model of anchored Parts).
--
-- The cross-section is extruded along the curve in adaptive intervals:
-- short intervals where curvature is high, long ones on straights. Each
-- interval places one part per profile component plus marking parts.
-- Superelevation is applied as a roll of the whole cross-section frame,
-- smoothed along the curve to approximate runoff transitions.
--
-- Lane widening/narrowing: pass ProfileEnd different from ProfileStart and
-- component widths (and therefore marking positions) interpolate linearly
-- from one end of the segment to the other.

local PolyCurve = require("../Geometry/PolyCurve")
local Superelevation = require("../Geometry/Superelevation")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")
local Markings = require("./Markings")
local RoadInstance = require("../RoadInstance")
local FillTriangle = require("./FillTriangle")

export type BuildOptions = {
	Curve: PolyCurve.PolyCurve,
	ProfileStart: RoadProfile.RoadProfile,
	ProfileEnd: RoadProfile.RoadProfile?, -- Widening/narrowing transition target
	Style: RegionStyles.RegionStyle,
	Settings: Settings.EasyRoadSettings,
	Preview: boolean?,
	-- Skips deck-strip Parts for these 1-based component indices (offsets/
	-- widths are still computed normally, so nothing else shifts) - used by
	-- BuildWithBay to omit the nearside pavement over a bay's footprint so
	-- its own shifted-outward replacement can be overlaid without doubling
	-- geometry or overlapping the bay's own pull-in lane.
	ExcludeComponentIndices: { number }?,
	-- User-placed partial-length marking overrides (see RoadEditSession's
	-- marking-stretch mode) - passed straight through to Markings.Compute.
	MarkingStretches: { Markings.MarkingStretch }?,
	-- Same idea for the road's own left/right kerb-restriction line (see
	-- RoadEditSession's kerb-stretch mode) - also passed straight through.
	KerbStretches: { Markings.KerbStretch }?,
}

local MARKING_THICKNESS = 0.05
local MARKING_LIFT = 0.03 -- Center height of marking parts above the deck surface
local CHORD_TOLERANCE = 0.1 -- Max chord deviation (studs) used for adaptive stepping
local PREVIEW_CHORD_TOLERANCE = 0.35
local MIN_STEP = 0.75
local MAX_TURN_PER_STEP = 0.3 -- Radians of heading change allowed per strip
local MAX_ROLL_PER_STEP = 0.02 -- Radians of superelevation (bank) change allowed per strip
local ROLL_WEDGE_EPSILON = 1e-4 -- Roll change (radians) per strip above which a flat box would visibly kink

local MATERIAL_BY_KIND: { [string]: Enum.Material } = {
	Drive = Enum.Material.Asphalt,
	Shoulder = Enum.Material.Asphalt,
	Bike = Enum.Material.Asphalt,
	Parking = Enum.Material.Asphalt,
	Bay = Enum.Material.Asphalt,
	Sidewalk = Enum.Material.Concrete,
	Median = Enum.Material.Grass,
}

local RoadBuilder = {}

local function colorForKind(kind: RoadProfile.ComponentKind, style: RegionStyles.RegionStyle): Color3
	if kind == "Drive" then
		return style.AsphaltColor
	elseif kind == "Shoulder" then
		return style.ShoulderColor
	elseif kind == "Sidewalk" then
		return style.SidewalkColor
	elseif kind == "Median" then
		return style.MedianColor
	elseif kind == "Bike" then
		return style.BikeLaneColor
	elseif kind == "Parking" then
		return style.AsphaltColor:Lerp(Color3.new(0, 0, 0), 0.15)
	elseif kind == "Bay" then
		return style.BayColor
	end
	return style.AsphaltColor
end

-- Extra length (Center-alignment mode) or extra width (Inside/Outside
-- alignment's far-edge pad) a flat strip needs so it still overlaps its
-- neighbor through a curve instead of leaving a gap on the outside of the
-- turn, for a strip centered/anchored at `sMid`-ish and `lateralOffset`
-- studs from the centerline.
--
-- Derived directly from arc length rather than an angle-between-frames
-- approximation: at radius R = 1/curvature, a point offset by r traces
-- (R+r)*angle while the centerline traces R*angle over the same turn - a
-- difference of r*angle = r*curvature*nominalLength. The same defect size
-- shows up whether you absorb it as extra length (Center mode, both edges
-- float) or extra width (Inside/Outside mode, far edge only - see
-- farEdgePad below); this helper just computes the magnitude, callers
-- decide which axis to apply it to. Markings don't use this any more -
-- they anchor both of their own endpoints directly to true curve
-- positions instead (see placeMarkingSpan), which closes joints exactly
-- rather than approximating.
local function curveMiterPad(
	curve: PolyCurve.PolyCurve,
	sMid: number,
	lateralOffset: number,
	nominalLength: number
): number
	local k = math.abs(curve:CurvatureAt(sMid))
	if k < 1e-6 then
		return 0
	end
	return math.abs(lateralOffset) * k * nominalLength
end

local function makePart(preview: boolean): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	-- Nothing in this codebase listens for .Touched on any road part
	-- (checked - no `.Touched` usage anywhere), so this is a free perf win
	-- unconditionally, for real placed roads too, not just previews.
	-- CanQuery stays at the engine default (true) for real parts though,
	-- unlike preview - createRoadSession.lua's ground raycast and
	-- RoadEditSession's bay-drag positioning both need to actually hit an
	-- existing placed road's own Parts to work correctly (continuing a
	-- road across another's surface, finding the closest station under the
	-- cursor while dragging a bay); CanQuery=false would make roads
	-- invisible to those raycasts.
	part.CanTouch = false
	if preview then
		part.Transparency = 0.55
		part.CanCollide = false
		part.CanQuery = false
	end
	return part
end

-- Build the list of sample stations (distances along the curve). Adaptive:
-- steps shrink where curvature is high so strips follow the curve closely.
--
-- `maxOffsetStuds` (default 0) is the widest lateral offset any edge of the
-- cross-section sits from the centerline (e.g. half the road's total
-- width). The step formula below is derived from the CENTERLINE's own
-- curvature, but a wide cross-section's concave-side edge (the inside of a
-- turn - a kerb line, sidewalk edge, whatever's farthest from the bend)
-- rides a tighter effective radius than the centerline: offset that edge
-- by `d` toward the inside of a bend of radius R and its own radius is
-- `R - d`, i.e. curvature `k / (1 - d*k)`. Spacing stations purely by
-- centerline curvature under-subdivides that edge on any sufficiently
-- tight bend with any real cross-section width - it reads as a smooth
-- centerline with a visibly faceted (straight-line) kerb/sidewalk edge
-- just inside it, worst on a roundabout ring or a tight junction spoke
-- where both the radius is small and the cross-section is wide.
local function buildStations(
	curve: PolyCurve.PolyCurve,
	maxStep: number,
	tolerance: number,
	maxOffsetStuds: number?
): { number }
	local offset = maxOffsetStuds or 0
	local stations = { 0 }
	local s = 0
	local length = curve.Length
	while s < length do
		local k = math.abs(curve:CurvatureAt(s))
		local step = maxStep
		if k > 1e-6 then
			-- Effective curvature of the worst-case (concave-side) offset
			-- edge - floored denominator so a radius tighter than the
			-- offset itself (the edge would otherwise overlap the curve's
			-- own center) still yields a large-but-finite curvature instead
			-- of blowing up, forcing maximal subdivision rather than erroring.
			local kEff = k / math.max(0.05, 1 - offset * k)
			-- Chord deviation of an arc: d = R - sqrt(R^2 - (c/2)^2) ~= c^2 k / 8
			step = math.min(maxStep, math.sqrt(8 * tolerance / kEff))
			-- Also bound the heading change per strip so tight curves can
			-- never fold a single strip through a large angle
			step = math.min(step, MAX_TURN_PER_STEP / kEff)
		end
		step = math.max(step, MIN_STEP)
		s = math.min(s + step, length)
		table.insert(stations, s)
	end
	-- Merge a tiny final sliver into the previous station
	local n = #stations
	if n > 2 and (stations[n] - stations[n - 1]) < MIN_STEP * 0.5 then
		table.remove(stations, n - 1)
	end
	return stations
end

function RoadBuilder.Build(options: BuildOptions): Model
	local curve = options.Curve
	local style = options.Style
	local settings = options.Settings
	local preview = options.Preview == true
	local scale = settings.MetersToStuds
	local thickness = settings.RoadThicknessStuds
	local curbHeight = style.CurbHeightM * scale

	-- Match profiles for transitions
	local componentsStart: { RoadProfile.ProfileComponent }
	local componentsEnd: { RoadProfile.ProfileComponent }
	if options.ProfileEnd and options.ProfileEnd.Id ~= options.ProfileStart.Id then
		componentsStart, componentsEnd = RoadProfile.MatchForTransition(options.ProfileStart, options.ProfileEnd)
	else
		componentsStart = options.ProfileStart.Components
		componentsEnd = options.ProfileStart.Components
	end
	local componentCount = #componentsStart

	local excludedComponents: { [number]: boolean } = {}
	if options.ExcludeComponentIndices then
		for _, index in options.ExcludeComponentIndices :: { number } do
			excludedComponents[index] = true
		end
	end

	local model = Instance.new("Model")
	model.Name = if preview then "RoadPreview" else "Road"

	local length = curve.Length
	if length < 1e-3 then
		return model
	end

	local isTransition = options.ProfileEnd ~= nil
		and (options.ProfileEnd :: RoadProfile.RoadProfile).Id ~= options.ProfileStart.Id

	-- Widening/narrowing happens over a standard taper at the END of the
	-- segment (UK practice: taper length proportional to the width change),
	-- not stretched across the whole road.
	local taperLength = length
	if isTransition then
		local widthDeltaStuds = math.abs(
			RoadProfile.TotalWidthM(options.ProfileStart)
				- RoadProfile.TotalWidthM(options.ProfileEnd :: RoadProfile.RoadProfile)
		) * scale
		taperLength = math.clamp(widthDeltaStuds * 15, 20, length)
	end
	-- 0 before the taper begins, then 0 -> 1 across the taper zone.
	-- Smoothstepped (3t^2 - 2t^3) rather than a plain linear ramp: a linear
	-- ramp has a derivative of 0 in the flat zone before it and a nonzero
	-- constant slope the instant the taper starts, i.e. a sharp kink in the
	-- width (and marking offset) right at that station - visually a sudden
	-- bend rather than a clean taper. Smoothstep's derivative is exactly 0
	-- at both t=0 and t=1, so the flat zone blends into the ramp and the
	-- ramp blends into the final width with no kink at either end.
	local function transitionAlpha(s: number): number
		local t: number
		if not isTransition then
			t = math.clamp(s / length, 0, 1)
		else
			t = math.clamp((s - (length - taperLength)) / taperLength, 0, 1)
		end
		return t * t * (3 - 2 * t)
	end

	local maxStep = if preview then settings.PreviewMaxSegmentLengthStuds else settings.MaxSegmentLengthStuds
	if isTransition then
		-- Widening/narrowing tapers read much better with short strips - and
		-- since each strip's width is constant along its own length (a Part
		-- can't taper), the width change between one strip and the next
		-- always shows up as a small step on the non-anchor edge. Bounding
		-- how much total width change happens per strip (rather than a flat
		-- 4-stud cap regardless of how steep the taper is) keeps that step
		-- small enough to read as a smooth line instead of a staircase even
		-- on a short, steep taper.
		local widthDeltaStuds = math.abs(
			RoadProfile.TotalWidthM(options.ProfileStart)
				- RoadProfile.TotalWidthM(options.ProfileEnd :: RoadProfile.RoadProfile)
		) * scale
		local changeRate = if taperLength > 1e-3 then widthDeltaStuds / taperLength else 0
		local maxStepForTaper = if changeRate > 1e-3 then 0.4 / changeRate else 4
		maxStep = math.min(maxStep, 4, math.max(maxStepForTaper, MIN_STEP))
	end
	local tolerance = if preview then PREVIEW_CHORD_TOLERANCE else CHORD_TOLERANCE
	local maxOffsetStuds = math.max(
		RoadProfile.TotalWidthM(options.ProfileStart),
		RoadProfile.TotalWidthM(options.ProfileEnd or options.ProfileStart)
	) / 2 * scale
	local stations = buildStations(curve, maxStep, tolerance, maxOffsetStuds)

	-- Per-station data ---------------------------------------------------------
	-- Both the curvature-noise smoothing window and the end-of-segment
	-- runoff taper below scale with this segment's own length (capped at
	-- settings.SuperelevationRunoffM converted to studs) instead of always
	-- using a fixed stud constant - otherwise a short segment gets
	-- disproportionately eaten by the taper (or over-smoothed) compared to
	-- a long one, so two curves of the same radius but different lengths
	-- would bank to visibly different peak amounts. Capping at 30% of
	-- length on each end always leaves at least a 40% flat "full bank"
	-- middle zone, so short curves scale the same way long ones do instead
	-- of being dominated by the absolute constant. Converting the runoff
	-- distance from a user-configurable REAL-WORLD meters setting (not a
	-- bare stud constant) means the transition covers the same real-world
	-- distance regardless of a user's own studs-per-meter scale - a fixed
	-- stud value made the same transition feel more abrupt for anyone
	-- running a higher studs-per-meter ratio than the ~3.571 default.
	local runoffLengthStuds = settings.SuperelevationRunoffM * settings.MetersToStuds
	local runoffLength = math.min(runoffLengthStuds, length * 0.3)

	local function computeRolls(stationList: { number }): { number }
		local computed = table.create(#stationList)
		for i, s in stationList do
			computed[i] = Superelevation.RollAt(curve:CurvatureAt(s), settings, style)
		end
		computed = Superelevation.SmoothRolls(computed, stationList, runoffLength)
		-- Superelevation is per-segment: taper the bank to zero at both ends
		-- of the segment (runoff) so chained segments always meet flush at
		-- joints with no height step between the two bodies.
		if runoffLength > 1e-3 then
			for i, s in stationList do
				local taper = math.min(1, s / runoffLength, (length - s) / runoffLength)
				computed[i] *= math.max(taper, 0)
			end
		end
		return computed
	end

	local rolls = computeRolls(stations)

	-- Piecewise-linear lookup into an arbitrary (sValues, values) sample
	-- pair, used below to resample the already-smoothed coarse roll curve
	-- at newly-inserted refinement stations.
	local function interpolateAt(sValues: { number }, values: { number }, s: number): number
		local n = #sValues
		if s <= sValues[1] then
			return values[1]
		end
		for i = 1, n - 1 do
			if s <= sValues[i + 1] then
				local span = sValues[i + 1] - sValues[i]
				local f = if span > 1e-9 then (s - sValues[i]) / span else 0
				return values[i] + (values[i + 1] - values[i]) * f
			end
		end
		return values[n]
	end

	-- The station grid above is spaced purely by lateral curvature (chord
	-- tolerance / heading change per strip) - it has no idea the bank angle
	-- (roll) can also change quickly across a span the curve itself
	-- considers "straight enough": most obviously the deliberate runoff
	-- ramp to zero bank at both ends of every segment, but also wherever
	-- SmoothRolls' box filter smears bank in from a nearby curve onto an
	-- otherwise-flat run. Each deck strip is a single rigid, flat Part
	-- though - a strip that twists continuously along its own length is a
	-- non-planar ruled surface, not something FillTriangle's flat wedges
	-- (or any single rigid Part) can represent exactly - so an under-
	-- subdivided roll transition shows up as a visible kink at the strip
	-- seam instead of a smooth twist. Insert extra stations wherever the
	-- roll step between neighbours is too large, then recompute rolls once
	-- over the final, denser grid - the same mitigation curvature already
	-- gets via MAX_TURN_PER_STEP, just driven by bank angle instead.
	local refined = { stations[1] }
	for i = 1, #stations - 1 do
		local s0, s1 = stations[i], stations[i + 1]
		local rollDelta = math.abs(rolls[i + 1] - rolls[i])
		local subdivisions = math.min(8, math.ceil(rollDelta / MAX_ROLL_PER_STEP))
		for j = 1, subdivisions - 1 do
			local s = s0 + (s1 - s0) * (j / subdivisions)
			if s - refined[#refined] >= MIN_STEP * 0.5 then
				table.insert(refined, s)
			end
		end
		table.insert(refined, s1)
	end
	if #refined > #stations then
		-- Resample the coarse grid's already-smoothed roll curve at the new
		-- refinement stations, rather than recomputing SmoothRolls from
		-- scratch on this denser, unevenly-spaced grid: SmoothRolls' box
		-- filter is a plain per-sample average (not arc-length-weighted),
		-- so it's biased toward whichever part of a smoothing window
		-- happens to have more samples - once refinement makes density
		-- jump sharply in some spots but not others, re-deriving the
		-- average on that uneven grid shifted non-smoothly as the window
		-- slid across the density boundary, producing small oscillations
		-- in the roll curve. Dashed markings sample rollAt() at arbitrary
		-- intermediate points (not station-anchored), so they visibly
		-- picked up on that now-non-smooth curve as a "wobble" along
		-- otherwise-straight dashes on superelevated curves; solid lines
		-- and deck strips anchor exactly to station points and barely
		-- showed it. Interpolating the coarse curve instead is
		-- mathematically consistent by construction - same curve, just
		-- resampled - so it can't introduce new oscillation.
		local coarseStations = stations
		local coarseRolls = rolls
		local resampled = table.create(#refined)
		for i, s in refined do
			resampled[i] = interpolateAt(coarseStations, coarseRolls, s)
		end
		stations = refined
		rolls = resampled
	end
	local stationCount = #stations

	local frames: { CFrame } = table.create(stationCount)
	for i, s in stations do
		frames[i] = curve:FrameAt(s, rolls[i])
	end

	-- Interpolated component widths and lateral offsets (studs) per station
	local stationWidths: { { number } } = table.create(stationCount)
	local stationOffsets: { { number } } = table.create(stationCount) -- Left edge offset per component
	for i, s in stations do
		local u = transitionAlpha(s)
		local widths = table.create(componentCount)
		local total = 0
		for c = 1, componentCount do
			local w0 = componentsStart[c].WidthM
			local w1 = componentsEnd[c].WidthM
			local w = (w0 + (w1 - w0) * u) * scale
			widths[c] = w
			total += w
		end
		local offsets = table.create(componentCount)
		local x = -total / 2
		for c = 1, componentCount do
			offsets[c] = x
			x += widths[c]
		end
		stationWidths[i] = widths
		stationOffsets[i] = offsets
	end

	-- Deck strips ---------------------------------------------------------------
	-- Always centerline-symmetric: each strip is centered on the tangent
	-- frame at its own interval's true midpoint (an exact point on the
	-- curve, not an approximation), both edges padded via curveMiterPad to
	-- close the resulting curve gap. This was previously an "Inside"/
	-- "Outside" anchored-edge alternative (deliberately keeping one lane
	-- edge exact via a shared station point, closing the other edge's
	-- residual gap with an exact FillTriangle wedge) - removed after this
	-- didn't hold up in practice: the far/residual edge's fixes
	-- (width-padding, then a curvature-gated wedge) kept trading one
	-- visible defect for another (sawtooth, then still-visible gaps), and
	-- anchoring a single edge instead of the centerline is what made the
	-- whole road visually drift off the clicked path on a sustained curve
	-- - by definition, only one edge tracked the true path exactly, so a
	-- wide cross-section's centerline (what the user actually clicked)
	-- could wander from it. Centerline-anchoring avoids that entirely:
	-- every strip's own center is placed directly on the curve, so the
	-- road can never drift from the path regardless of curve length or
	-- cross-section width. No FillTriangle wedges are used for curve
	-- joints any more - see BuildWithBay below for where wedges are still
	-- useful (an actually-abrupt shape, not a curve-following one).
	for i = 1, stationCount - 1 do
		local s0 = stations[i]
		local s1 = stations[i + 1]
		local sMid = (s0 + s1) / 2
		local rollMid = (rolls[i] + rolls[i + 1]) / 2
		local midFrame = curve:FrameAt(sMid, rollMid)

		-- Guard against degenerate geometry (folded curves / cusps):
		-- skip intervals where the heading reverses or the frame went
		-- non-finite rather than emitting strips fanned across the fold.
		local headingDot = frames[i].LookVector:Dot(frames[i + 1].LookVector)
		local midPos = midFrame.Position
		if headingDot < 0 or midPos.X ~= midPos.X or midPos.Y ~= midPos.Y or midPos.Z ~= midPos.Z then
			continue
		end

		-- The nominal span is the arc length (s1 - s0), not the
		-- straight chord between frame positions - chord is always
		-- <= arc length on a curve, so sizing off it alone under-covers
		-- even the centerline before any lateral miter padding.
		local nominalLength = s1 - s0
		-- How much the bank angle (roll) itself changes across this
		-- interval - see the wedge-vs-box branch below, which uses this to
		-- decide whether a flat box (constant tilt) would visibly kink
		-- against its neighbour.
		local rollDelta = math.abs(rolls[i + 1] - rolls[i])

		for c = 1, componentCount do
			if excludedComponents[c] then
				continue
			end
			local w0 = stationWidths[i][c]
			local w1 = stationWidths[i + 1][c]
			local width = (w0 + w1) / 2
			if width < 0.05 then
				continue
			end
			local centerOffset0 = stationOffsets[i][c] + w0 / 2
			local centerOffset1 = stationOffsets[i + 1][c] + w1 / 2
			local centerOffset = (centerOffset0 + centerOffset1) / 2

			local kind = componentsStart[c].Kind
			local raised = RoadProfile.IsRaised(kind)
			local partHeight = if raised then thickness + curbHeight else thickness
			-- Deck (roadway) top surface sits at frame level; raised
			-- components (sidewalk/median) stand a curb height above
			-- it. Alternating strips drop by a sub-visible epsilon so
			-- overlapping neighbor strips never z-fight.
			local centerY = (if raised then (curbHeight - thickness) / 2 else -thickness / 2) - (i % 2) * 0.004

			local edgeDistance = math.max(math.abs(centerOffset - width / 2), math.abs(centerOffset + width / 2))
			local miter = curveMiterPad(curve, sMid, edgeDistance, nominalLength)
			-- A slightly larger flat safety margin than before (was 0.02) -
			-- uniform across every strip regardless of curvature, so it
			-- can't reproduce the curvature-scaled sawtooth the old
			-- far-edge pad caused; just a little extra overlap insurance
			-- against any remaining sliver of a gap.
			local padding = miter + 0.08

			local function makeTransitionPart(): Part
				local part = makePart(preview)
				part.Name = kind
				part.Material = MATERIAL_BY_KIND[kind] or Enum.Material.Asphalt
				part.Color = colorForKind(kind, style)
				return part
			end

			-- Wedge, not a block: when this component's own center offset
			-- moves between the two stations (a widen/narrow transition, or
			-- an offset shift caused by a neighboring component changing
			-- width), the true shape between the two stations is a
			-- quadrilateral (its two "width" edges generally aren't
			-- parallel), not a rectangle - no single rigid Part can
			-- represent that exactly, and approximating it with a rotated
			-- rectangle (an earlier attempt) left sliver gaps at the seams
			-- between strips, since two adjacent rotated rectangles' width
			-- edges are perpendicular to two different local slope angles.
			-- Filled exactly instead: split the true quad into two
			-- triangles along its innerStart-outerEnd diagonal and fill
			-- each with FillTriangle (the same exact-fill helper the bay's
			-- own taper already uses). Adjacent intervals share their
			-- exact end/start corner positions by construction (both
			-- computed from the same per-station offset/width data), so
			-- there's no gap or overlap regardless of how sharply the
			-- offset or width changes station to station.
			--
			-- The same branch also covers a superelevation (roll) change
			-- between the two stations, even when the offset/width don't
			-- move at all: frames[i] and frames[i+1] already carry each
			-- station's own exact roll, so innerStart/outerStart (frames[i])
			-- and innerEnd/outerEnd (frames[i+1]) are already correctly
			-- tilted - the flat-box "else" branch below instead collapses
			-- the whole interval to one constant tilt (the two rolls
			-- averaged), which is exact nowhere and visibly kinks against a
			-- neighbouring strip that averaged a different pair. A
			-- continuously twisting deck between two different rolls is a
			-- non-planar ruled surface, so this still can't be exactly flat
			-- - but anchoring every strip's corners to the true per-station
			-- roll (rather than a rigid, uniformly-tilted box) means
			-- adjacent strips always share an exact edge with no gap, same
			-- as the lateral case, and the residual twist is a small,
			-- imperceptible facet instead of an averaging error. Strips
			-- that are neither transitioning nor banking (the ordinary
			-- case for most flat, straight road) are unaffected - same
			-- plain rectangle construction as before.
			if math.abs(centerOffset1 - centerOffset0) > 1e-4 or rollDelta > ROLL_WEDGE_EPSILON then
				local topY = if raised then curbHeight else 0
				local innerStart = (frames[i] * CFrame.new(centerOffset0 - w0 / 2, topY, 0)).Position
				local outerStart = (frames[i] * CFrame.new(centerOffset0 + w0 / 2, topY, 0)).Position
				local innerEnd = (frames[i + 1] * CFrame.new(centerOffset1 - w1 / 2, topY, 0)).Position
				local outerEnd = (frames[i + 1] * CFrame.new(centerOffset1 + w1 / 2, topY, 0)).Position
				local downVector = -midFrame.UpVector
				FillTriangle(innerStart, outerStart, outerEnd, partHeight, downVector, makeTransitionPart, model)
				FillTriangle(innerStart, outerEnd, innerEnd, partHeight, downVector, makeTransitionPart, model)
			else
				local part = makeTransitionPart()
				part.Size = Vector3.new(width, partHeight, nominalLength + padding)
				part.CFrame = midFrame * CFrame.new(centerOffset, centerY, 0)
				part.Parent = model
			end
		end
	end

	-- Markings -------------------------------------------------------------------
	if settings.AutoMarkings then
		local lines = Markings.Compute(componentsStart, componentsEnd, style, {
			KerbRestriction = options.ProfileStart.KerbRestriction,
			MarkingColor = options.ProfileStart.MarkingColor,
			DashLengthM = options.ProfileStart.MarkingDashLengthM,
			DashGapM = options.ProfileStart.MarkingDashGapM,
			MarkingStretches = options.MarkingStretches,
			KerbStretches = options.KerbStretches,
			KerbIndent = options.ProfileStart.KerbIndent,
		})
		local markingWidth = style.MarkingWidthM * scale

		-- Interpolates the roll (superelevation) already computed per
		-- station at an arbitrary distance s between them.
		local function rollAt(s: number): number
			for i = 1, stationCount - 1 do
				if s <= stations[i + 1] then
					local span = stations[i + 1] - stations[i]
					local f = if span > 1e-9 then (s - stations[i]) / span else 0
					return rolls[i] + (rolls[i + 1] - rolls[i]) * f
				end
			end
			return rolls[stationCount]
		end

		-- Anchors a marking segment directly to the true curve position at
		-- both of its own endpoints (s0/offset0, s1/offset1) - the same
		-- construction the deck's anchored strips use, just without an
		-- anchorSign edge offset, since a marking's own centerline (not one
		-- of its lateral edges) is what needs to be exact. Adjacent
		-- segments that share an endpoint (every interior station, for
		-- solid lines) therefore meet with zero gap and no separate joint
		-- patch, and align exactly with whichever deck edge sits at the
		-- same offset - no curveMiterPad approximation involved.
		local function placeMarkingSpan(
			s0: number,
			s1: number,
			offset0: number,
			offset1: number,
			extraLength: number,
			color: Color3,
			altIndex: number
		)
			local y = MARKING_LIFT + (altIndex % 2) * 0.004
			local frame0 = curve:FrameAt(s0, rollAt(s0))
			local frame1 = curve:FrameAt(s1, rollAt(s1))
			local p0 = (frame0 * CFrame.new(offset0, y, 0)).Position
			local p1 = (frame1 * CFrame.new(offset1, y, 0)).Position
			local segLength = (p1 - p0).Magnitude
			if segLength < 1e-4 then
				return
			end
			local forward = (p1 - p0).Unit
			local mid = (p0 + p1) / 2
			local part = makePart(preview)
			part.Name = "Marking"
			part.Material = Enum.Material.SmoothPlastic
			part.Color = color
			part.Size = Vector3.new(markingWidth, MARKING_THICKNESS, segLength + extraLength)
			part.CFrame = CFrame.lookAt(mid, mid + forward, frame1.UpVector)
			part.Parent = model
		end

		for _, line in lines do
			local offset0 = line.OffsetStartM * scale
			local offset1 = line.OffsetEndM * scale
			local color = line.Color
			local separation = markingWidth * 0.9

			local function offsetAt(s: number): number
				return offset0 + (offset1 - offset0) * transitionAlpha(s)
			end

			-- A "stretch" override (see Markings.emitBoundaryLine) restricts
			-- a line to a station sub-range instead of the whole segment;
			-- nil on either end means unbounded that way, matching the
			-- normal (unstretched) case. Degenerate/empty ranges (e.g. the
			-- "before" piece when the override starts right at s=0) simply
			-- render nothing below rather than needing special-casing here.
			local loS = line.FromStationStuds or 0
			local hiS = line.ToStationStuds or length

			-- Each compound line type is one or two rails, each rail either
			-- solid or dashed. lateral = rail offset from the boundary line.
			-- Solid rails anchor to the exact station grid, so neighboring
			-- segments share an endpoint and meet with no gap or overlap -
			-- no separate joint patch needed.
			local function renderSolid(lateral: number)
				for i = 1, stationCount - 1 do
					local s0 = stations[i]
					local s1 = stations[i + 1]
					if s1 <= loS or s0 >= hiS then
						continue
					end
					s0 = math.max(s0, loS)
					s1 = math.min(s1, hiS)
					placeMarkingSpan(s0, s1, offsetAt(s0) + lateral, offsetAt(s1) + lateral, 0.02, color, i)
				end
			end

			local function renderDashed(lateral: number)
				local dashLength = line.DashLengthM * scale
				local gapLength = line.DashGapM * scale
				local s = gapLength / 2
				local dashIndex = 0
				while s + dashLength < math.min(length, hiS) do
					if s >= loS then
						local s0 = s
						local s1 = s + dashLength
						placeMarkingSpan(s0, s1, offsetAt(s0) + lateral, offsetAt(s1) + lateral, 0, color, dashIndex)
						dashIndex += 1
					end
					s += dashLength + gapLength
				end
			end

			local lineType = line.Line
			if lineType == "Solid" then
				renderSolid(0)
			elseif lineType == "Dashed" then
				renderDashed(0)
			elseif lineType == "DoubleSolid" then
				renderSolid(-separation)
				renderSolid(separation)
			elseif lineType == "DoubleDashed" then
				renderDashed(-separation)
				renderDashed(separation)
			elseif lineType == "SolidDash" then
				-- Solid on the left of the boundary, dashes on the right:
				-- right-hand traffic may cross, left-hand may not
				renderSolid(-separation)
				renderDashed(separation)
			elseif lineType == "DashSolid" then
				renderDashed(-separation)
				renderSolid(separation)
			end
		end
	end

	-- Metadata for endpoint snapping and later editing ---------------------------
	-- Single-segment curves (every road placed by the current session) get
	-- the full curve + profile stamp so they can be reopened and edited
	-- later; multi-segment curves (not produced anywhere yet) fall back to
	-- just the endpoint/tangent data used for snapping.
	if #curve.Segments == 1 then
		RoadInstance.StampModel(model, curve.Segments[1], options.ProfileStart, options.ProfileEnd)
	else
		model:SetAttribute("RW_Road", true)
		model:SetAttribute("RW_StartPos", curve:PosAt(0))
		model:SetAttribute("RW_EndPos", curve:PosAt(length))
		model:SetAttribute("RW_StartTan", curve:TangentAt(0))
		model:SetAttribute("RW_EndTan", curve:TangentAt(length))
		model:SetAttribute("RW_ProfileStartId", options.ProfileStart.Id)
		model:SetAttribute(
			"RW_ProfileEndId",
			if options.ProfileEnd then options.ProfileEnd.Id else options.ProfileStart.Id
		)
	end

	return model
end

export type BayPlacement = {
	StationStuds: number, -- Center of the bay along the curve
	LengthStuds: number, -- Length of the flat "dwell" section (excludes tapers)
	WidthM: number, -- Bay lane width in meters
	Side: "Left" | "Right", -- Which side of the road the bay was dragged toward
}

-- Builds the road with a bus/taxi bay carved into its nearside pavement:
-- the roadway (drive lanes, median, ...) is built for the full length
-- unchanged, the bay's own pull-in lane is an exact trapezoid (a flat
-- "dwell" rectangle plus two triangle tapers - each really a single
-- triangle, since a taper's narrow end has zero width - via FillTriangle,
-- not the general widen/narrow machinery's staircase-of-rectangles), and
-- the nearside pavement (sidewalk/verge) is genuinely displaced outward
-- over the bay's footprint rather than left in place: left in place, it
-- would sit raised directly over the new low bay asphalt, which is exactly
-- the overlap a bay reported. The nearside component is excluded from the
-- base build across the bay's footprint (RoadBuilder.Build's new
-- ExcludeComponentIndices) and rebuilt shifted outward as its own chain of
-- small strips, its inner edge following the exact same linear ramp as the
-- bay's own FillTriangle taper edge - the two share one boundary line by
-- construction, so there is no gap and no overlap between them.
function RoadBuilder.BuildWithBay(options: BuildOptions, bay: BayPlacement): Model
	local curve = options.Curve
	local settings = options.Settings
	local style = options.Style
	local baseProfile = options.ProfileStart
	local scale = settings.MetersToStuds
	local thickness = settings.RoadThicknessStuds
	local curbHeight = style.CurbHeightM * scale
	local preview = options.Preview == true
	local length = curve.Length

	if length < 1e-3 then
		return RoadBuilder.Build(options)
	end

	-- Nearside kerb offset (studs from centerline): the edge the bay was
	-- actually dragged towards (bay.Side - see RoadEditSession's
	-- bayDraftFromDrag), not assumed from the region's driving side - a bay
	-- can be drawn on either side of the road regardless of which side
	-- traffic normally drives on. The nearside component itself (usually
	-- the sidewalk) is whichever one sits at that same edge.
	local componentOffsetsM = RoadProfile.ComponentOffsetsM(baseProfile)
	local totalWidthStuds = RoadProfile.TotalWidthM(baseProfile) * scale
	local outward: number
	local kerbOffset: number
	local nearsideIndex: number
	if bay.Side == "Left" then
		outward = -1
		kerbOffset = if componentOffsetsM[1] then componentOffsetsM[1].Right * scale else -totalWidthStuds / 2
		nearsideIndex = 1
	else
		outward = 1
		local n = #componentOffsetsM
		kerbOffset = if componentOffsetsM[n] then componentOffsetsM[n].Left * scale else totalWidthStuds / 2
		nearsideIndex = n
	end
	local nearsideComponent = baseProfile.Components[nearsideIndex]
	local bayWidthStuds = bay.WidthM * scale
	local bayOffset = kerbOffset + outward * bayWidthStuds

	local half = math.max(bay.LengthStuds, 0) / 2
	local dwellStart = math.clamp(bay.StationStuds - half, 0, length)
	local dwellEnd = math.clamp(bay.StationStuds + half, 0, length)
	-- Taper length scales with how much width is being added, same
	-- underlying idea as a widen/narrow taper, just a much shorter/steeper
	-- default rate since a bay is a small local feature, not a highway-wide
	-- lane change.
	local taperLength = math.clamp(bayWidthStuds * 3, 8, math.max(bay.LengthStuds, 8))
	local taperInStart = math.clamp(dwellStart - taperLength, 0, dwellStart)
	local taperOutEnd = math.clamp(dwellEnd + taperLength, dwellEnd, length)

	if taperOutEnd - taperInStart < 1e-3 or not nearsideComponent then
		return RoadBuilder.Build(options)
	end

	-- MarkingStretches are captured in the whole road's own station space,
	-- but each slice below is its own PolyCurve with station 0 at the
	-- slice's start (see PolyCurve.Slice) - remap into that local space and
	-- drop anything that doesn't overlap this particular slice at all.
	local function stretchesForSlice(sliceStart: number, sliceEnd: number): { Markings.MarkingStretch }?
		if not options.MarkingStretches then
			return nil
		end
		local remapped = {}
		for _, stretch in options.MarkingStretches :: { Markings.MarkingStretch } do
			local from = math.max(stretch.FromStationStuds, sliceStart)
			local to = math.min(stretch.ToStationStuds, sliceEnd)
			if to > from then
				table.insert(remapped, {
					ComponentIndices = stretch.ComponentIndices,
					FromStationStuds = from - sliceStart,
					ToStationStuds = to - sliceStart,
					Line = stretch.Line,
					DashLengthM = stretch.DashLengthM,
					DashGapM = stretch.DashGapM,
				})
			end
		end
		return if #remapped > 0 then remapped else nil
	end

	-- Same remapping as stretchesForSlice above, for KerbStretches - no
	-- ComponentIndices to carry through (EdgeIndex is stable across
	-- slices, unlike a lane boundary's index), just the station clip/
	-- offset.
	local function kerbStretchesForSlice(sliceStart: number, sliceEnd: number): { Markings.KerbStretch }?
		if not options.KerbStretches then
			return nil
		end
		local remapped = {}
		for _, stretch in options.KerbStretches :: { Markings.KerbStretch } do
			local from = math.max(stretch.FromStationStuds, sliceStart)
			local to = math.min(stretch.ToStationStuds, sliceEnd)
			if to > from then
				table.insert(remapped, {
					EdgeIndex = stretch.EdgeIndex,
					FromStationStuds = from - sliceStart,
					ToStationStuds = to - sliceStart,
					Restriction = stretch.Restriction,
				})
			end
		end
		return if #remapped > 0 then remapped else nil
	end

	-- Base road: the unaffected zones build normally; the bay's footprint
	-- excludes the nearside component (rebuilt below, shifted outward) so
	-- its original position doesn't coexist with the new one.
	local model = Instance.new("Model")
	model.Name = if preview then "RoadPreview" else "Road"
	local function mergeIn(built: Model)
		for _, child in built:GetChildren() do
			child.Parent = model
		end
		built:Destroy()
	end
	if taperInStart > 1e-3 then
		mergeIn(RoadBuilder.Build({
			Curve = curve:Slice(0, taperInStart),
			ProfileStart = baseProfile,
			ProfileEnd = options.ProfileEnd,
			Style = style,
			Settings = settings,
			Preview = preview,
			MarkingStretches = stretchesForSlice(0, taperInStart),
			KerbStretches = kerbStretchesForSlice(0, taperInStart),
		}))
	end
	mergeIn(RoadBuilder.Build({
		Curve = curve:Slice(taperInStart, taperOutEnd),
		ProfileStart = baseProfile,
		Style = style,
		Settings = settings,
		Preview = preview,
		ExcludeComponentIndices = { nearsideIndex },
		MarkingStretches = stretchesForSlice(taperInStart, taperOutEnd),
		KerbStretches = kerbStretchesForSlice(taperInStart, taperOutEnd),
	}))
	if length - taperOutEnd > 1e-3 then
		mergeIn(RoadBuilder.Build({
			Curve = curve:Slice(taperOutEnd, length),
			ProfileStart = baseProfile,
			ProfileEnd = options.ProfileEnd,
			Style = style,
			Settings = settings,
			Preview = preview,
			MarkingStretches = stretchesForSlice(taperOutEnd, length),
			KerbStretches = kerbStretchesForSlice(taperOutEnd, length),
		}))
	end

	local partHeight = thickness

	local function frameAt(s: number): CFrame
		return curve:FrameAt(s, Superelevation.RollAt(curve:CurvatureAt(s), settings, style))
	end

	local function makeBayPart(): Part
		local part = makePart(preview)
		part.Name = "Bay"
		part.Material = Enum.Material.Asphalt
		part.Color = style.BayColor
		return part
	end

	-- 0 outside the bay's footprint, ramping 0->1 across each taper and flat
	-- 1 through the dwell - shared by both the bay's own asphalt below and
	-- the displaced nearside pavement further down, so their common
	-- boundary (the bay's outer edge / the pavement's inner edge) is always
	-- exactly the same line at every station.
	local function bayAlphaAt(s: number): number
		if s <= taperInStart then
			return 0
		elseif s < dwellStart then
			local span = dwellStart - taperInStart
			return if span > 1e-6 then (s - taperInStart) / span else 1
		elseif s <= dwellEnd then
			return 1
		elseif s < taperOutEnd then
			local span = taperOutEnd - dwellEnd
			return if span > 1e-6 then 1 - (s - dwellEnd) / span else 0
		end
		return 0
	end

	-- Bay asphalt (dwell + both tapers): a chain of small, curve-following
	-- intervals, not one flat dwell rectangle plus two single-triangle
	-- tapers. The single-part version anchored the bay's inner edge
	-- (kerbOffset) to only the 2-4 station points bounding the dwell/
	-- tapers, so on an actual curve that inner edge was a straight chord
	-- while the base road's own edge at that same nominal offset (built by
	-- the normal Build call just outside ExcludeComponentIndices, with its
	-- usual fine adaptive stations) kept following the true curve - the
	-- chord-vs-arc mismatch showed up as a visible sliver gap on curved
	-- bays. Same adaptive-station + FillTriangle technique the nearside
	-- pavement shift loop and the main deck loop's transition strips use
	-- closes it exactly: every small interval's own corners sit on the
	-- true curve.
	-- Station density here is driven purely by curvature tolerance (the
	-- same formula the rest of the road uses), not an extra width-change
	-- cap: unlike the main loop's widen/narrow taper (a smoothstepped
	-- ramp, which genuinely needs short strips to approximate its curved
	-- profile with straight chords), bayAlphaAt is a plain linear ramp, so
	-- a single FillTriangle interval already represents it exactly on a
	-- straight road - no benefit to chopping it up further, only more
	-- wedge parts for no visual gain. A tight curve still subdivides
	-- fully, since that's governed by buildStations' own curvature check.
	local baySlice = curve:Slice(taperInStart, taperOutEnd)
	if baySlice.Length > 1e-3 then
		local bayStations = buildStations(baySlice, settings.MaxSegmentLengthStuds, CHORD_TOLERANCE)
		for i = 1, #bayStations - 1 do
			local s0 = taperInStart + bayStations[i]
			local s1 = taperInStart + bayStations[i + 1]
			local outerOffset0 = kerbOffset + outward * bayWidthStuds * bayAlphaAt(s0)
			local outerOffset1 = kerbOffset + outward * bayWidthStuds * bayAlphaAt(s1)
			if math.abs(outerOffset0 - kerbOffset) < 1e-4 and math.abs(outerOffset1 - kerbOffset) < 1e-4 then
				continue
			end
			local sMid = (s0 + s1) / 2
			local midFrame = frameAt(sMid)
			local nominalLength = s1 - s0

			if math.abs(outerOffset1 - outerOffset0) > 1e-4 then
				local innerStart = (frameAt(s0) * CFrame.new(kerbOffset, 0, 0)).Position
				local outerStart = (frameAt(s0) * CFrame.new(outerOffset0, 0, 0)).Position
				local innerEnd = (frameAt(s1) * CFrame.new(kerbOffset, 0, 0)).Position
				local outerEnd = (frameAt(s1) * CFrame.new(outerOffset1, 0, 0)).Position
				local downVector = -midFrame.UpVector
				FillTriangle(innerStart, outerStart, outerEnd, partHeight, downVector, makeBayPart, model)
				FillTriangle(innerStart, outerEnd, innerEnd, partHeight, downVector, makeBayPart, model)
			else
				local width = math.abs(outerOffset0 - kerbOffset)
				local centerOffset = (kerbOffset + outerOffset0) / 2
				local edgeDistance = math.max(math.abs(centerOffset - width / 2), math.abs(centerOffset + width / 2))
				local miter = curveMiterPad(curve, sMid, edgeDistance, nominalLength)
				local padding = miter + 0.08
				local part = makeBayPart()
				part.Size = Vector3.new(width, partHeight, nominalLength + padding)
				part.CFrame = midFrame * CFrame.new(centerOffset, -partHeight / 2, 0)
				part.Parent = model
			end
		end
	end

	-- Nearside pavement, displaced outward over the bay's footprint: its
	-- inner edge follows the exact same ramp (0 at taperInStart/
	-- taperOutEnd, full bayWidthStuds through the dwell, via the shared
	-- bayAlphaAt above) as the bay's own outer edge, so the two boundaries
	-- are literally the same line at every station - no gap, no overlap.
	-- Built as a chain of small, diagonally-oriented strips across adaptive
	-- stations (the same technique the main deck-strip loop uses for
	-- ordinary offset changes), since a strip that shifts sideways along
	-- its own length is a parallelogram in plan - not exactly representable
	-- by any single rigid Part, but angling each small strip to its own
	-- true endpoints (instead of holding flat-and-square until the next
	-- station) gets close enough that fine adaptive stepping reads as a
	-- smooth slope.
	local nearsideWidthStuds = nearsideComponent.WidthM * scale
	local nearsideKind = nearsideComponent.Kind
	local nearsideRaised = RoadProfile.IsRaised(nearsideKind)
	local nearsidePartHeight = if nearsideRaised then thickness + curbHeight else thickness
	local nearsideCenterY = if nearsideRaised then (curbHeight - thickness) / 2 else -thickness / 2

	-- Same reasoning as the bay asphalt loop above: bayAlphaAt is a linear
	-- ramp, so FillTriangle is already exact per interval regardless of
	-- size - subdivision only needs to track curvature, not width-change
	-- rate, so no extra cap here either.
	local shiftSlice = curve:Slice(taperInStart, taperOutEnd)
	if shiftSlice.Length > 1e-3 then
		local shiftStations = buildStations(shiftSlice, settings.MaxSegmentLengthStuds, CHORD_TOLERANCE)
		for i = 1, #shiftStations - 1 do
			local s0 = taperInStart + shiftStations[i]
			local s1 = taperInStart + shiftStations[i + 1]
			local sMid = (s0 + s1) / 2
			local midFrame = frameAt(sMid)
			local centerOffset0 = kerbOffset
				+ outward * bayWidthStuds * bayAlphaAt(s0)
				+ outward * nearsideWidthStuds / 2
			local centerOffset1 = kerbOffset
				+ outward * bayWidthStuds * bayAlphaAt(s1)
				+ outward * nearsideWidthStuds / 2
			local centerOffset = (centerOffset0 + centerOffset1) / 2
			local nominalLength = s1 - s0
			local edgeDistance = math.max(
				math.abs(centerOffset - nearsideWidthStuds / 2),
				math.abs(centerOffset + nearsideWidthStuds / 2)
			)
			local miter = curveMiterPad(curve, sMid, edgeDistance, nominalLength)
			local padding = miter + 0.08

			local function makeNearsidePart(): Part
				local part = makePart(preview)
				part.Name = nearsideKind
				part.Material = MATERIAL_BY_KIND[nearsideKind] or Enum.Material.Concrete
				part.Color = colorForKind(nearsideKind, style)
				return part
			end

			-- Wedge, not a block - filled exactly with FillTriangle, same
			-- as the matching case in the main deck-strip loop above (see
			-- its comment for the full reasoning): the true shape between
			-- two stations here is a shifting-offset quad (a parallelogram,
			-- since this component's own width is constant - only its
			-- offset moves), not representable by a single rigid Part.
			-- Split into two triangles along the innerStart-outerEnd
			-- diagonal instead of approximating with a rotated rectangle
			-- (an earlier attempt left sliver gaps at the seams).
			if math.abs(centerOffset1 - centerOffset0) > 1e-4 then
				local topY = if nearsideRaised then curbHeight else 0
				local half = nearsideWidthStuds / 2
				local innerStart = (frameAt(s0) * CFrame.new(centerOffset0 - half, topY, 0)).Position
				local outerStart = (frameAt(s0) * CFrame.new(centerOffset0 + half, topY, 0)).Position
				local innerEnd = (frameAt(s1) * CFrame.new(centerOffset1 - half, topY, 0)).Position
				local outerEnd = (frameAt(s1) * CFrame.new(centerOffset1 + half, topY, 0)).Position
				local downVector = -midFrame.UpVector
				FillTriangle(innerStart, outerStart, outerEnd, nearsidePartHeight, downVector, makeNearsidePart, model)
				FillTriangle(innerStart, outerEnd, innerEnd, nearsidePartHeight, downVector, makeNearsidePart, model)
			else
				local part = makeNearsidePart()
				part.Size = Vector3.new(nearsideWidthStuds, nearsidePartHeight, nominalLength + padding)
				part.CFrame = midFrame * CFrame.new(centerOffset, nearsideCenterY, 0)
				part.Parent = model
			end
		end
	end

	return model
end

return RoadBuilder
