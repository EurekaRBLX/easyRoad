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
	end
	return style.AsphaltColor
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
	rolls = Superelevation.SmoothRolls(rolls, stations, RUNOFF_LENGTH_STUDS)
	-- Superelevation is per-segment: taper the bank to zero at both ends of
	-- the segment (runoff) so chained segments always meet flush at joints
	-- with no height step between the two bodies.
	local runoff = math.min(RUNOFF_LENGTH_STUDS, length / 2)
	if runoff > 1e-3 then
		for i, s in stations do
			local taper = math.min(1, s / runoff, (length - s) / runoff)
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

		local chord = (frames[i + 1].Position - frames[i].Position).Magnitude
		-- Extra length to miter gaps that open up on the outside of curves
		local turnAngle = math.acos(math.clamp(headingDot, -1, 1))

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
			-- components (sidewalk/median) stand a curb height above it.
			-- Alternating strips drop by a sub-visible epsilon so overlapping
			-- neighbor strips never z-fight.
			local centerY = (if raised then (curbHeight - thickness) / 2 else -thickness / 2)
				- (i % 2) * 0.004

			local miter = math.abs(centerOffset + width / 2) * math.sin(turnAngle)
			miter = math.min(miter, chord * 2)
			local partLength = chord + miter + 0.02

			local part = makePart(preview)
			part.Name = kind
			part.Material = MATERIAL_BY_KIND[kind] or Enum.Material.Asphalt
			part.Color = colorForKind(kind, style)
			part.Size = Vector3.new(width, partHeight, partLength)
			part.CFrame = midFrame * CFrame.new(centerOffset, centerY, 0)
			part.Parent = model
		end
	end

	-- Markings -------------------------------------------------------------------
	if settings.AutoMarkings then
		local lines = Markings.Compute(componentsStart, componentsEnd, style)
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
			local pattern = line.Spec.Pattern
			local color = line.Spec.Color

			local function offsetAt(s: number): number
				return offset0 + (offset1 - offset0) * transitionAlpha(s)
			end

			if pattern == "Solid" or pattern == "DoubleSolid" then
				for i = 1, stationCount - 1 do
					local s0 = stations[i]
					local s1 = stations[i + 1]
					local sMid = (s0 + s1) / 2
					local partLength = (s1 - s0) + 0.05
					if pattern == "DoubleSolid" then
						local separation = markingWidth * 0.9
						placeMarkingPart(sMid, partLength, offsetAt(sMid) - separation, color, i)
						placeMarkingPart(sMid, partLength, offsetAt(sMid) + separation, color, i)
					else
						placeMarkingPart(sMid, partLength, offsetAt(sMid), color, i)
					end
				end
			elseif pattern == "Dashed" then
				local dashLength = style.DashLengthM * scale
				local gapLength = style.DashGapM * scale
				local s = gapLength / 2
				local dashIndex = 0
				while s + dashLength < length do
					local sMid = s + dashLength / 2
					placeMarkingPart(sMid, dashLength, offsetAt(sMid), color, dashIndex)
					dashIndex += 1
					s += dashLength + gapLength
				end
			end
		end
	end

	-- Metadata for endpoint snapping and later editing ---------------------------
	model:SetAttribute("RW_Road", true)
	model:SetAttribute("RW_StartPos", curve:PosAt(0))
	model:SetAttribute("RW_EndPos", curve:PosAt(length))
	model:SetAttribute("RW_StartTan", curve:TangentAt(0))
	model:SetAttribute("RW_EndTan", curve:TangentAt(length))
	model:SetAttribute("RW_ProfileStartId", options.ProfileStart.Id)
	model:SetAttribute("RW_ProfileEndId",
		if options.ProfileEnd then options.ProfileEnd.Id else options.ProfileStart.Id)

	return model
end

return RoadBuilder
