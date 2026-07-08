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

-- Extra length a flat strip centered at `sMid`, offset `lateralOffset`
-- studs from the centerline, needs so it still overlaps its neighbor
-- through a curve instead of leaving a wedge-shaped gap on the outside of
-- the turn (or, for markings, a visible break in the line).
--
-- Derived directly from arc length rather than an angle-between-frames
-- approximation: at radius R = 1/curvature, a point offset by r traces
-- (R+r)*angle while the centerline traces R*angle over the same turn - a
-- difference of r*angle = r*curvature*nominalLength. Applying this equally
-- means every part - deck strip or marking, whatever length it spans -
-- gets the correct padding for its own lateral offset and curvature at its
-- own position, with no dependency on how that part's span happens to
-- align with station stepping.
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
	-- 0 before the taper begins, then 0 -> 1 across the taper zone
	local function transitionAlpha(s: number): number
		if not isTransition then
			return math.clamp(s / length, 0, 1)
		end
		return math.clamp((s - (length - taperLength)) / taperLength, 0, 1)
	end

	local maxStep = if preview then settings.PreviewMaxSegmentLengthStuds else settings.MaxSegmentLengthStuds
	if isTransition then
		-- Widening/narrowing tapers read much better with short strips
		maxStep = math.min(maxStep, 4)
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
	-- Recorded per interval (MidFrame + each component's centerOffset/width)
	-- so the curve joint fill pass below can rebuild each strip's exact
	-- corner points afterwards without recomputing/duplicating this data.
	type Interval = {
		MidFrame: CFrame,
		HalfLength: number,
		Offsets: { number },
		Widths: { number },
	}
	local intervals: { Interval? } = table.create(stationCount - 1)

	for i = 1, stationCount - 1 do
		local s0 = stations[i]
		local s1 = stations[i + 1]
		local sMid = (s0 + s1) / 2
		local rollMid = (rolls[i] + rolls[i + 1]) / 2
		local midFrame = curve:FrameAt(sMid, rollMid)

		-- Guard against degenerate geometry (folded curves / cusps): skip
		-- intervals where the heading reverses or the frame went non-finite
		-- rather than emitting strips fanned across the fold.
		local headingDot = frames[i].LookVector:Dot(frames[i + 1].LookVector)
		local midPos = midFrame.Position
		if headingDot < 0 or midPos.X ~= midPos.X or midPos.Y ~= midPos.Y or midPos.Z ~= midPos.Z then
			continue
		end

		-- The nominal span is the arc length (s1 - s0), not the straight
		-- chord between frame positions - chord is always <= arc length on
		-- a curve, so sizing off it alone under-covers even the centerline
		-- before any lateral miter padding is added.
		local nominalLength = s1 - s0
		local interval = { MidFrame = midFrame, HalfLength = nominalLength / 2, Offsets = {}, Widths = {} }
		intervals[i] = interval

		for c = 1, componentCount do
			local w0 = stationWidths[i][c]
			local w1 = stationWidths[i + 1][c]
			local width = (w0 + w1) / 2
			interval.Widths[c] = width
			if width < 0.05 then
				continue
			end
			local centerOffset = (
				stationOffsets[i][c] + w0 / 2 +
				stationOffsets[i + 1][c] + w1 / 2
			) / 2
			interval.Offsets[c] = centerOffset

			local kind = componentsStart[c].Kind
			local raised = RoadProfile.IsRaised(kind)
			local partHeight = if raised then thickness + curbHeight else thickness
			-- Deck (roadway) top surface sits at frame level; raised
			-- components (sidewalk/median) stand a curb height above it.
			-- Alternating strips drop by a sub-visible epsilon so overlapping
			-- neighbor strips never z-fight.
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

	-- Curve joint fills -----------------------------------------------------------
	-- The miter padding above closes the vast majority of a curved strip's
	-- gap (verified: <0.1 stud residual even at a 17-degree turn with a
	-- 15-stud lateral offset), but it works by extending each strip along
	-- its own straight tangent, which tracks the true curve closely but not
	-- exactly - a small residual wedge-shaped gap can remain. Close it
	-- exactly (not just approximately) with FillTriangle.lua, adapted from
	-- stravant/roblox-gapfill: each interior joint's residual gap, per
	-- component, is the quad between that component's two (unpadded) strip
	-- end corners on either side of the joint - split into two triangles
	-- and filled with Wedge parts precisely, instead of approximated with
	-- another padded box.
	for i = 2, stationCount - 1 do
		local k = math.abs(curve:CurvatureAt(stations[i]))
		if k < 1e-6 then
			continue
		end
		local intervalA = intervals[i - 1]
		local intervalB = intervals[i]
		if not intervalA or not intervalB then
			continue
		end
		local downVector = -frames[i].UpVector

		for c = 1, componentCount do
			local widthA = intervalA.Widths[c]
			local widthB = intervalB.Widths[c]
			if not widthA or not widthB or widthA < 0.05 or widthB < 0.05 then
				continue
			end
			local offsetA = intervalA.Offsets[c]
			local offsetB = intervalB.Offsets[c]

			local kind = componentsStart[c].Kind
			local raised = RoadProfile.IsRaised(kind)
			local partHeight = if raised then thickness + curbHeight else thickness
			local baseY = if raised then (curbHeight - thickness) / 2 else -thickness / 2
			-- Same alternating z-fight epsilon each interval's own strip
			-- used, so the fill's plane matches both neighbors closely; the
			-- top surface (not the strip's vertical center) is what the
			-- triangle should sit on, since depth extrudes downward from it.
			local topYA = baseY - ((i - 1) % 2) * 0.004 + partHeight / 2
			local topYB = baseY - (i % 2) * 0.004 + partHeight / 2

			local al = (intervalA.MidFrame * CFrame.new(offsetA - widthA / 2, topYA, intervalA.HalfLength)).Position
			local ar = (intervalA.MidFrame * CFrame.new(offsetA + widthA / 2, topYA, intervalA.HalfLength)).Position
			local bl = (intervalB.MidFrame * CFrame.new(offsetB - widthB / 2, topYB, -intervalB.HalfLength)).Position
			local br = (intervalB.MidFrame * CFrame.new(offsetB + widthB / 2, topYB, -intervalB.HalfLength)).Position

			local function makeWedgePart(): Part
				local part = makePart(preview)
				part.Name = kind
				part.Material = MATERIAL_BY_KIND[kind] or Enum.Material.Asphalt
				part.Color = colorForKind(kind, style)
				return part
			end

			FillTriangle(al, ar, br, partHeight, downVector, makeWedgePart, model)
			FillTriangle(al, br, bl, partHeight, downVector, makeWedgePart, model)
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

		local function placeMarkingPart(
			sMid: number,
			partLength: number,
			offsetStuds: number,
			color: Color3,
			altIndex: number
		)
			-- Recompute roll at this s by interpolating station rolls
			local rollMid = 0
			for i = 1, stationCount - 1 do
				if sMid <= stations[i + 1] then
					local span = stations[i + 1] - stations[i]
					local f = if span > 1e-9 then (sMid - stations[i]) / span else 0
					rollMid = rolls[i] + (rolls[i + 1] - rolls[i]) * f
					break
				end
			end
			local frame = curve:FrameAt(sMid, rollMid)
			local part = makePart(preview)
			part.Name = "Marking"
			part.Material = Enum.Material.SmoothPlastic
			part.Color = color
			part.Size = Vector3.new(markingWidth, MARKING_THICKNESS, partLength)
			part.CFrame = frame * CFrame.new(offsetStuds, MARKING_LIFT + (altIndex % 2) * 0.004, 0)
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
			-- Markings are thin and high-contrast against the asphalt, so an
			-- un-mitered gap on a curve is even more visible here than on a
			-- deck strip - same curveMiterPad helper, evaluated at each
			-- marking segment's own position/offset regardless of whether it
			-- lines up with station stepping (dashes rarely do).
			local function renderSolid(lateral: number)
				for i = 1, stationCount - 1 do
					local s0 = stations[i]
					local s1 = stations[i + 1]
					local sMid = (s0 + s1) / 2
					local offset = offsetAt(sMid) + lateral
					local nominalLength = s1 - s0
					local miter = curveMiterPad(curve, sMid, offset, nominalLength)
					placeMarkingPart(sMid, nominalLength + miter + 0.05, offset, color, i)
				end
				-- Same small joint patches as the deck strips, at each
				-- interior station - a solid line is meant to read as
				-- continuous, so its residual gap (thin + high-contrast
				-- against the asphalt) is worth the extra bit of insurance.
				-- Dashes are deliberately discontinuous, so they don't get
				-- this treatment.
				for i = 2, stationCount - 1 do
					local s = stations[i]
					local k = math.abs(curve:CurvatureAt(s))
					if k < 1e-6 then
						continue
					end
					local offset = offsetAt(s) + lateral
					local patchLength = math.max(0.15, math.abs(offset) * k * 6)
					placeMarkingPart(s, patchLength, offset, color, i)
				end
			end

			local function renderDashed(lateral: number)
				local dashLength = line.DashLengthM * scale
				local gapLength = line.DashGapM * scale
				local s = gapLength / 2
				local dashIndex = 0
				while s + dashLength < length do
					local sMid = s + dashLength / 2
					local offset = offsetAt(sMid) + lateral
					local miter = curveMiterPad(curve, sMid, offset, dashLength)
					placeMarkingPart(sMid, dashLength + miter, offset, color, dashIndex)
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

return RoadBuilder
