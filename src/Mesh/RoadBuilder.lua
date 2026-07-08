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
}

local MARKING_THICKNESS = 0.05
local MARKING_LIFT = 0.03 -- Center height of marking parts above the deck surface
local CHORD_TOLERANCE = 0.1 -- Max chord deviation (studs) used for adaptive stepping
local PREVIEW_CHORD_TOLERANCE = 0.35
local MIN_STEP = 0.75
local MAX_TURN_PER_STEP = 0.3 -- Radians of heading change allowed per strip
local RUNOFF_LENGTH_STUDS = 40 -- Superelevation smoothing window
-- A joint's residual (non-anchor) gap only gets an actual wedge part when it's
-- bigger than this - below it, simply widening the strips on their far side
-- (see farEdgePad below) already hides the defect, so most curves need no
-- wedge at all, only genuinely sharp turns / high-superelevation joints do.
local WEDGE_GAP_THRESHOLD_STUDS = 0.5

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
local function curveMiterPad(curve: PolyCurve.PolyCurve, sMid: number, lateralOffset: number, nominalLength: number): number
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
	if preview then
		part.Transparency = 0.55
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end
	return part
end

-- Build the list of sample stations (distances along the curve). Adaptive:
-- steps shrink where curvature is high so strips follow the curve closely.
local function buildStations(
	curve: PolyCurve.PolyCurve,
	maxStep: number,
	tolerance: number
): { number }
	local stations = { 0 }
	local s = 0
	local length = curve.Length
	while s < length do
		local k = math.abs(curve:CurvatureAt(s))
		local step = maxStep
		if k > 1e-6 then
			-- Chord deviation of an arc: d = R - sqrt(R^2 - (c/2)^2) ~= c^2 k / 8
			step = math.min(maxStep, math.sqrt(8 * tolerance / k))
			-- Also bound the heading change per strip so tight curves can
			-- never fold a single strip through a large angle
			step = math.min(step, MAX_TURN_PER_STEP / k)
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
		componentsStart, componentsEnd = RoadProfile.MatchForTransition(
			options.ProfileStart, options.ProfileEnd)
	else
		componentsStart = options.ProfileStart.Components
		componentsEnd = options.ProfileStart.Components
	end
	local componentCount = #componentsStart

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
			RoadProfile.TotalWidthM(options.ProfileStart) - RoadProfile.TotalWidthM(options.ProfileEnd :: RoadProfile.RoadProfile)
		) * scale
		local changeRate = if taperLength > 1e-3 then widthDeltaStuds / taperLength else 0
		local maxStepForTaper = if changeRate > 1e-3 then 0.4 / changeRate else 4
		maxStep = math.min(maxStep, 4, math.max(maxStepForTaper, MIN_STEP))
	end
	local tolerance = if preview then PREVIEW_CHORD_TOLERANCE else CHORD_TOLERANCE
	local stations = buildStations(curve, maxStep, tolerance)
	local stationCount = #stations

	-- Per-station data ---------------------------------------------------------
	local rolls = table.create(stationCount)
	for i, s in stations do
		rolls[i] = Superelevation.RollAt(curve:CurvatureAt(s), settings, style)
	end
	-- Both the curvature-noise smoothing window and the end-of-segment
	-- runoff taper below scale with this segment's own length (capped at
	-- RUNOFF_LENGTH_STUDS) instead of always using a fixed 40 studs -
	-- otherwise a short segment gets disproportionately eaten by the taper
	-- (or over-smoothed) compared to a long one, so two curves of the same
	-- radius but different lengths would bank to visibly different peak
	-- amounts. Capping at 30% of length on each end always leaves at least
	-- a 40% flat "full bank" middle zone, so short curves scale the same
	-- way long ones do instead of being dominated by the absolute constant.
	local runoffLength = math.min(RUNOFF_LENGTH_STUDS, length * 0.3)
	rolls = Superelevation.SmoothRolls(rolls, stations, runoffLength)
	-- Superelevation is per-segment: taper the bank to zero at both ends of
	-- the segment (runoff) so chained segments always meet flush at joints
	-- with no height step between the two bodies.
	if runoffLength > 1e-3 then
		for i, s in stations do
			local taper = math.min(1, s / runoffLength, (length - s) / runoffLength)
			rolls[i] *= math.max(taper, 0)
		end
	end

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
	-- CurveAlignment picks which reference each strip is built from, same
	-- concept as the Archimedes plugin's Center/Inside/Outside path
	-- alignment:
	--   Center (anchorSign = 0)  - today's original approach: each strip is
	--     centered on the tangent frame at its own interval midpoint, both
	--     edges are approximate, padded via curveMiterPad to mostly close
	--     the gap on either side.
	--   Inside/Outside (anchorSign = -1 / +1) - each strip's anchor edge
	--     (left for Inside, right for Outside) is built directly from the
	--     TRUE curve position at both of its station endpoints - since
	--     adjacent intervals share the exact same station point (the same
	--     cached `frames[i]` entry, not recomputed), that edge is gap-free
	--     by construction, no padding approximation needed. Only the
	--     opposite (residual) edge can still show a gap, closed exactly
	--     with FillTriangle.lua instead of approximated.
	local anchorSign = if settings.CurveAlignment == "Inside" then -1
		elseif settings.CurveAlignment == "Outside" then 1
		else 0

	if anchorSign == 0 then
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

			for c = 1, componentCount do
				local w0 = stationWidths[i][c]
				local w1 = stationWidths[i + 1][c]
				local width = (w0 + w1) / 2
				if width < 0.05 then
					continue
				end
				local centerOffset = (
					stationOffsets[i][c] + w0 / 2 +
					stationOffsets[i + 1][c] + w1 / 2
				) / 2

				local kind = componentsStart[c].Kind
				local raised = RoadProfile.IsRaised(kind)
				local partHeight = if raised then thickness + curbHeight else thickness
				-- Deck (roadway) top surface sits at frame level; raised
				-- components (sidewalk/median) stand a curb height above
				-- it. Alternating strips drop by a sub-visible epsilon so
				-- overlapping neighbor strips never z-fight.
				local centerY = (if raised then (curbHeight - thickness) / 2 else -thickness / 2)
					- (i % 2) * 0.004

				local edgeDistance = math.max(math.abs(centerOffset - width / 2), math.abs(centerOffset + width / 2))
				local miter = curveMiterPad(curve, sMid, edgeDistance, nominalLength)
				local partLength = nominalLength + miter + 0.02

				local part = makePart(preview)
				part.Name = kind
				part.Material = MATERIAL_BY_KIND[kind] or Enum.Material.Asphalt
				part.Color = colorForKind(kind, style)
				part.Size = Vector3.new(width, partHeight, partLength)
				part.CFrame = midFrame * CFrame.new(centerOffset, centerY, 0)
				part.Parent = model
			end
		end
	else
		-- Builds the CFrame for a strip spanning stationA to stationB,
		-- anchored so that its anchorSign edge sits exactly on the true
		-- curve position (offsetA/offsetB) at both ends - no padding, no
		-- approximation. Returns nil if the span is degenerate.
		local function anchoredStripCFrame(
			stationA: number,
			stationB: number,
			offsetA: number,
			offsetB: number,
			topY: number,
			width: number,
			partHeight: number
		): (CFrame?, number)
			local p0 = (frames[stationA] * CFrame.new(offsetA, topY, 0)).Position
			local p1 = (frames[stationB] * CFrame.new(offsetB, topY, 0)).Position
			local segLength = (p1 - p0).Magnitude
			if segLength < 1e-4 then
				return nil, 0
			end
			local forward = (p1 - p0).Unit
			local up = frames[stationA].UpVector
			local mid = (p0 + p1) / 2
			local lookCF = CFrame.lookAt(mid, mid + forward, up)
			local stripCF = lookCF * CFrame.new(-anchorSign * width / 2, -partHeight / 2, 0)
			return stripCF, segLength
		end

		local function anchorOffsetAt(stationIndex: number, c: number): number
			if anchorSign > 0 then
				return stationOffsets[stationIndex][c] + stationWidths[stationIndex][c]
			end
			return stationOffsets[stationIndex][c]
		end

		-- NOTE: strips are built at their plain, exact anchored width, no
		-- far-edge padding. An earlier version widened the far (non-anchor)
		-- edge using curveMiterPad's r*k*L formula reinterpreted as a width
		-- pad instead of a length pad - that formula was derived for length
		-- padding specifically and doesn't carry over to width correctly,
		-- and visibly over-widened strips into a sawtooth/serrated edge on
		-- curves instead of fixing anything. Removed; the far edge's small
		-- residual gap on gentle curves is left alone (imperceptible), and
		-- only genuinely sharp joints get an exact FillTriangle wedge below.
		for i = 1, stationCount - 1 do
			local headingDot = frames[i].LookVector:Dot(frames[i + 1].LookVector)
			if headingDot < 0 then
				continue
			end

			for c = 1, componentCount do
				local width = (stationWidths[i][c] + stationWidths[i + 1][c]) / 2
				if width < 0.05 then
					continue
				end
				local kind = componentsStart[c].Kind
				local raised = RoadProfile.IsRaised(kind)
				local partHeight = if raised then thickness + curbHeight else thickness
				local topY = (if raised then (curbHeight - thickness) / 2 else -thickness / 2) + partHeight / 2

				local stripCF, segLength =
					anchoredStripCFrame(i, i + 1, anchorOffsetAt(i, c), anchorOffsetAt(i + 1, c), topY, width, partHeight)
				if not stripCF then
					continue
				end

				local part = makePart(preview)
				part.Name = kind
				part.Material = MATERIAL_BY_KIND[kind] or Enum.Material.Asphalt
				part.Color = colorForKind(kind, style)
				part.Size = Vector3.new(width, partHeight, segLength)
				part.CFrame = stripCF
				part.Parent = model
			end
		end

		-- Curve joint fills: with the far edge now padded above, only
		-- genuinely sharp turns or high-superelevation joints still leave a
		-- gap big enough to need an actual wedge - everything gentler is
		-- already covered by the widened strips, so most joints add no
		-- extra part at all. Since the anchor edge is an exact shared point
		-- at this joint (not two independent approximations like Center
		-- mode has on both sides), any remaining gap is a single triangle,
		-- not a quad.
		for i = 2, stationCount - 1 do
			local k = math.abs(curve:CurvatureAt(stations[i]))
			if k < 1e-6 then
				continue
			end
			-- Same fold/cusp guard the strip-building loop uses - skip a
			-- joint if either neighboring interval's heading reversed
			-- (matches that interval having been skipped as a strip too).
			if
				frames[i - 1].LookVector:Dot(frames[i].LookVector) < 0
				or frames[i].LookVector:Dot(frames[i + 1].LookVector) < 0
			then
				continue
			end
			local downVector = -frames[i].UpVector

			for c = 1, componentCount do
				local widthA = (stationWidths[i - 1][c] + stationWidths[i][c]) / 2
				local widthB = (stationWidths[i][c] + stationWidths[i + 1][c]) / 2
				if widthA < 0.05 or widthB < 0.05 then
					continue
				end
				local kind = componentsStart[c].Kind
				local raised = RoadProfile.IsRaised(kind)
				local partHeight = if raised then thickness + curbHeight else thickness
				local topY = (if raised then (curbHeight - thickness) / 2 else -thickness / 2) + partHeight / 2

				local anchorOffsetI = anchorOffsetAt(i, c)
				local stripCFA, segLengthA = anchoredStripCFrame(
					i - 1, i, anchorOffsetAt(i - 1, c), anchorOffsetI, topY, widthA, partHeight
				)
				local stripCFB, segLengthB = anchoredStripCFrame(
					i, i + 1, anchorOffsetI, anchorOffsetAt(i + 1, c), topY, widthB, partHeight
				)
				if not stripCFA or not stripCFB then
					continue
				end

				local anchorPoint = (frames[i] * CFrame.new(anchorOffsetI, topY, 0)).Position
				local residualFarA =
					(stripCFA * CFrame.new(-anchorSign * widthA / 2, partHeight / 2, segLengthA / 2)).Position
				local residualNearB =
					(stripCFB * CFrame.new(-anchorSign * widthB / 2, partHeight / 2, -segLengthB / 2)).Position

				-- The far-side pad above already widens both strips towards
				-- each other, so the true remaining defect is smaller than
				-- the raw corner distance - only worth an actual wedge part
				-- once it's still bigger than the padding could plausibly
				-- absorb.
				local gapDistance = (residualFarA - residualNearB).Magnitude
				if gapDistance < WEDGE_GAP_THRESHOLD_STUDS then
					continue
				end

				local function makeWedgePart(): Part
					local part = makePart(preview)
					part.Name = kind
					part.Material = MATERIAL_BY_KIND[kind] or Enum.Material.Asphalt
					part.Color = colorForKind(kind, style)
					return part
				end

				FillTriangle(anchorPoint, residualFarA, residualNearB, partHeight, downVector, makeWedgePart, model)
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

			-- Each compound line type is one or two rails, each rail either
			-- solid or dashed. lateral = rail offset from the boundary line.
			-- Solid rails anchor to the exact station grid, so neighboring
			-- segments share an endpoint and meet with no gap or overlap -
			-- no separate joint patch needed.
			local function renderSolid(lateral: number)
				for i = 1, stationCount - 1 do
					local s0 = stations[i]
					local s1 = stations[i + 1]
					placeMarkingSpan(s0, s1, offsetAt(s0) + lateral, offsetAt(s1) + lateral, 0.02, color, i)
				end
			end

			local function renderDashed(lateral: number)
				local dashLength = line.DashLengthM * scale
				local gapLength = line.DashGapM * scale
				local s = gapLength / 2
				local dashIndex = 0
				while s + dashLength < length do
					local s0 = s
					local s1 = s + dashLength
					placeMarkingSpan(s0, s1, offsetAt(s0) + lateral, offsetAt(s1) + lateral, 0, color, dashIndex)
					dashIndex += 1
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
		model:SetAttribute("RW_ProfileEndId",
			if options.ProfileEnd then options.ProfileEnd.Id else options.ProfileStart.Id)
	end

	return model
end

export type BayPlacement = {
	StationStuds: number, -- Center of the bay along the curve
	LengthStuds: number, -- Length of the flat "dwell" section (excludes tapers)
	WidthM: number, -- Bay lane width in meters
}

-- Builds a road with a bus/taxi bay carved into it at one point: a taper
-- in (normal profile -> normal+Bay), a flat dwell at full bay width, and a
-- taper back out, stitched from 5 separate RoadBuilder.Build calls on
-- Curve:Slice() sub-ranges of the same curve - reusing the existing
-- widen/narrow taper machinery for the two tapers rather than inventing a
-- new one, since a bay taper and a widen/narrow taper are the same shape.
-- The bay doesn't combine with an options.ProfileEnd transition in this
-- version (bays are placed on already-built, non-transitioning roads).
function RoadBuilder.BuildWithBay(options: BuildOptions, bay: BayPlacement): Model
	local curve = options.Curve
	local settings = options.Settings
	local baseProfile = options.ProfileStart
	local length = curve.Length

	local model = Instance.new("Model")
	model.Name = if options.Preview then "RoadPreview" else "Road"
	if length < 1e-3 then
		return model
	end

	local bayProfile = RoadProfile.WithBay(baseProfile, options.Style.DriveOnLeft, bay.WidthM)
	local widthDeltaStuds = bay.WidthM * settings.MetersToStuds
	local taperLength = math.clamp(widthDeltaStuds * 15, 20, math.max(bay.LengthStuds, 20))

	local half = math.max(bay.LengthStuds, 0) / 2
	local dwellStart = math.clamp(bay.StationStuds - half, 0, length)
	local dwellEnd = math.clamp(bay.StationStuds + half, 0, length)
	local taperInStart = math.clamp(dwellStart - taperLength, 0, dwellStart)
	local taperOutEnd = math.clamp(dwellEnd + taperLength, dwellEnd, length)

	local function appendPiece(piece: Model)
		for _, child in piece:GetChildren() do
			child.Parent = model
		end
		piece:Destroy()
	end

	local function buildRange(s0: number, s1: number, profileStart: RoadProfile.RoadProfile, profileEnd: RoadProfile.RoadProfile?)
		if s1 - s0 < 1e-3 then
			return
		end
		appendPiece(RoadBuilder.Build({
			Curve = curve:Slice(s0, s1),
			ProfileStart = profileStart,
			ProfileEnd = profileEnd,
			Style = options.Style,
			Settings = settings,
			Preview = options.Preview,
		}))
	end

	buildRange(0, taperInStart, baseProfile, nil)
	buildRange(taperInStart, dwellStart, baseProfile, bayProfile)
	buildRange(dwellStart, dwellEnd, bayProfile, nil)
	buildRange(dwellEnd, taperOutEnd, bayProfile, baseProfile)
	buildRange(taperOutEnd, length, baseProfile, nil)

	if #curve.Segments == 1 then
		RoadInstance.StampModel(model, curve.Segments[1], baseProfile, options.ProfileEnd)
	end

	return model
end

return RoadBuilder
