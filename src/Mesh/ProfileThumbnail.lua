--!strict
-- Builds a small, flat (non-curved) extrusion of a RoadProfile suitable for
-- rendering into a ViewportFrame as a road-library thumbnail.
--
-- This is a straight-line call into the real RoadBuilder rather than a
-- separate render algorithm - confirmed feasible without new extrusion
-- logic (see TODO.md's "Road library icons" note): a straight PolyCurve of
-- a fixed short length produces exactly the deck strips + markings a real
-- road would have, just with no curvature to sample.

local CurveSegment = require("../Geometry/CurveSegment")
local PolyCurve = require("../Geometry/PolyCurve")
local RoadBuilder = require("./RoadBuilder")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")

local THUMBNAIL_LENGTH_STUDS = 14

local ProfileThumbnail = {}

-- Frames a model's current bounding box in the same 3/4 top-down angle used
-- throughout the plugin's live-3D icons (matches the angle strategy-game
-- road palette icons use - wide enough to read lane colours/markings
-- across the cross-section, with a hint of the length receding for
-- depth). Exposed separately so callers that add their own geometry on top
-- of a base extrusion (e.g. CategoryThumbnail's gantry overlay) can
-- re-frame after the fact instead of duplicating this math.
function ProfileThumbnail.FrameCamera(model: Model): CFrame
	local boundingCFrame, boundingSize = model:GetBoundingBox()
	local center = boundingCFrame.Position
	local horizontalExtent = math.max(boundingSize.X, boundingSize.Z, 1)
	local distance = horizontalExtent * 1.05 + 6 + boundingSize.Y * 0.5
	local eye = center + Vector3.new(0, distance * 0.85, distance * 0.9)
	return CFrame.lookAt(eye, center)
end

-- Returns the extruded Model plus a Camera CFrame that frames it via
-- FrameCamera above.
function ProfileThumbnail.Build(
	profile: RoadProfile.RoadProfile,
	style: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings
): (Model, CFrame)
	local segment = CurveSegment.Line(Vector3.new(0, 0, 0), Vector3.new(0, 0, -THUMBNAIL_LENGTH_STUDS))
	local curve = PolyCurve.new({ segment })
	local model = RoadBuilder.Build({
		Curve = curve,
		ProfileStart = profile,
		Style = style,
		Settings = settings,
		Preview = false,
	})
	model.Name = "RoadThumbnail"

	return model, ProfileThumbnail.FrameCamera(model)
end

return ProfileThumbnail
