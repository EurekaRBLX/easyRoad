--!strict
-- A road library row's rendered cross-section icon: a small live 3D
-- ViewportFrame (its own WorldModel + Camera) showing a flat extrusion of
-- the profile, instead of plain text - CS2-style.

local HttpService = game:GetService("HttpService")

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local ProfileThumbnail = require("../Mesh/ProfileThumbnail")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")

local function RoadThumbnail(props: {
	Profile: RoadProfile.RoadProfile,
	RegionStyle: RegionStyles.RegionStyle,
	Settings: Settings.EasyRoadSettings,
	Size: UDim2?,
	LayoutOrder: number?,
})
	local viewportRef = React.useRef(nil :: ViewportFrame?)
	local profileKey = HttpService:JSONEncode(RoadProfile.Serialize(props.Profile))

	React.useEffect(function()
		local viewport = viewportRef.current
		if not viewport then
			return nil
		end

		local worldModel = Instance.new("WorldModel")
		worldModel.Parent = viewport

		local camera = Instance.new("Camera")
		camera.FieldOfView = 40
		camera.Parent = viewport
		viewport.CurrentCamera = camera

		local ok, model, cameraCFrame =
			pcall(ProfileThumbnail.Build, props.Profile, props.RegionStyle, props.Settings)
		if ok and model then
			model.Parent = worldModel
			camera.CFrame = cameraCFrame :: CFrame
		end

		return function()
			worldModel:Destroy()
			camera:Destroy()
		end
	end, { profileKey, props.RegionStyle.Id } :: { any })

	return e("ViewportFrame", {
		ref = viewportRef,
		Size = props.Size or UDim2.fromOffset(48, 40),
		BackgroundColor3 = Theme.FIELD,
		BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
		BorderSizePixel = 0,
		LayoutOrder = props.LayoutOrder,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
	})
end

return RoadThumbnail
