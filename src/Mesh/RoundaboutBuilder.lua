--!strict
-- Generates a roundabout: a closed, single-lane, one-way ring road built
-- from 4 cubic-Bezier quarter-arcs approximating a true circle (the
-- standard "k = 0.5522847498" construction, ~0.03% max radial error) -
-- reuses RoadBuilder.Build completely unmodified, since a closed ring is
-- mechanically just an ordinary road whose curve happens to start and end
-- at the same physical point; every station/curvature/marking query
-- PolyCurve exposes already works across multiple segments, only the
-- single-segment persistence shortcut in RoadBuilder.Build's own stamping
-- step doesn't apply here (handled below).
--
-- v0 / rough, per TODO.md's phased plan - deliberately doesn't attempt to
-- merge each spoke road at a junction into the ring (no splicing, no
-- shared lane geometry at the approach points - there will be a visible
-- seam where each spoke's pavement meets the ring). Only single-lane
-- roundabouts are supported; multi-lane/turbo variants are unbuilt. The
-- ring is NOT stamped RW_Road (so it isn't picked up by RoadEditSession's
-- selection UI, endpoint-snapping, or the mid-span split scan, none of
-- which are built to handle a closed multi-segment curve yet) and isn't
-- linked into the junction's Start/EndJunctionId model (its seam point
-- generally isn't at the junction centre, so that model doesn't fit) -
-- there is currently no in-plugin way to select, edit, or delete a placed
-- ring; delete it via the Explorer.

local CurveSegment = require("../Geometry/CurveSegment")
local PolyCurve = require("../Geometry/PolyCurve")
local RoadBuilder = require("./RoadBuilder")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")

local RoundaboutBuilder = {}

local ROUNDABOUTS_FOLDER_NAME = "Roundabouts"
local BEZIER_CIRCLE_K = 0.5522847498307936

-- True circulates clockwise (viewed from above, +Y up) for DriveOnLeft
-- regions, counter-clockwise otherwise - not yet verified against real
-- regional roundabout convention (only reasoned through, never checked
-- live in Studio); flip the ternary below if it reads backwards once
-- tested.
local function circleSegments(center: Vector3, radiusStuds: number, driveOnLeft: boolean): { CurveSegment.Segment }
	local sign = if driveOnLeft then -1 else 1
	local function pointAt(angle: number): Vector3
		return center + Vector3.new(math.cos(angle) * radiusStuds, 0, math.sin(angle) * radiusStuds)
	end
	local function tangentAt(angle: number): Vector3
		return Vector3.new(-math.sin(angle), 0, math.cos(angle)) * sign
	end
	local handleLength = radiusStuds * BEZIER_CIRCLE_K
	local segments: { CurveSegment.Segment } = {}
	for i = 0, 3 do
		local a0 = sign * (i / 4) * (2 * math.pi)
		local a1 = sign * ((i + 1) / 4) * (2 * math.pi)
		local p0 = pointAt(a0)
		local p3 = pointAt(a1)
		local p1 = p0 + tangentAt(a0) * handleLength
		local p2 = p3 - tangentAt(a1) * handleLength
		table.insert(segments, CurveSegment.Cubic(p0, p1, p2, p3))
	end
	return segments
end

local function getRoundaboutsFolder(): Folder
	local existing = workspace:FindFirstChild(ROUNDABOUTS_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing :: Folder
	end
	local folder = Instance.new("Folder")
	folder.Name = ROUNDABOUTS_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

-- Builds and parents a single-lane one-way roundabout ring of `radiusStuds`
-- centred at `center`.
function RoundaboutBuilder.Create(
	center: Vector3,
	radiusStuds: number,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): Model
	local curve = PolyCurve.new(circleSegments(center, radiusStuds, style.DriveOnLeft))
	local profile: RoadProfile.RoadProfile = {
		Id = "roundabout_ring",
		Name = "Roundabout",
		Category = "Custom",
		BuiltIn = false,
		Components = {
			{ Kind = "Drive", WidthM = style.DefaultLaneWidthM, Direction = 1 },
		},
	}
	local model = RoadBuilder.Build({
		Curve = curve,
		ProfileStart = profile,
		Style = style,
		Settings = settings,
		Preview = false,
	})
	-- RoadBuilder.Build's multi-segment fallback stamps RW_Road (for
	-- endpoint-snapping) since it doesn't yet know this curve is closed -
	-- clear it so nothing (endpoint snapping, mid-span split, the
	-- selection-based road editor) mistakes this ring for an ordinary,
	-- splittable, single-segment road.
	model:SetAttribute("RW_Road", nil)
	model:SetAttribute("RW_Roundabout", true)
	model.Name = "Roundabout"
	model.Parent = getRoundaboutsFolder()
	return model
end

return RoundaboutBuilder
