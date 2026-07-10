--!strict
-- A CS2-style contextual action menu: a handful of pill buttons scattered
-- around a world-space anchor point, NOT an actual wedge-sliced pie/radial
-- widget - matching the reference (hover a placed object, get "EDIT ALL
-- INSTANCES" / "PLACE MORE" / "USE AS TEMPLATE" / "CANCEL" as plain
-- rounded-rect buttons positioned above/left/right/below the object).
--
-- Tracks the camera every frame (RenderStepped) so the menu stays anchored
-- to the world position as the viewport moves; hides itself when that
-- point is behind the camera or off-screen.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")

export type PieMenuAction = {
	Text: string,
	OnClick: () -> (),
	Danger: boolean?,
}

local function PillButton(props: {
	Action: PieMenuAction,
	Primary: boolean,
	Offset: Vector2,
	SetGlobalHover: ((boolean) -> ())?,
})
	local hovered, setHovered = React.useState(false)
	local action = props.Action
	local color = if props.Primary then (if hovered then Theme.ACCENT_HOVER else Theme.SELECTED)
		elseif action.Danger then (if hovered then Theme.DANGER:Lerp(Theme.WHITE, 0.15) else Theme.DANGER)
		elseif hovered then Theme.BUTTON_HOVER
		else Theme.PANEL

	return e("TextButton", {
		Text = action.Text,
		TextColor3 = Theme.WHITE,
		Font = if props.Primary then Theme.FONT_BOLD else Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, props.Offset.X, 0, props.Offset.Y),
		Size = UDim2.new(0, 0, 0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = color,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		ZIndex = 2,
		[React.Event.Activated] = action.OnClick,
		[React.Event.MouseEnter] = function()
			setHovered(true)
			if props.SetGlobalHover then
				props.SetGlobalHover(true)
			end
		end,
		[React.Event.MouseLeave] = function()
			setHovered(false)
			if props.SetGlobalHover then
				props.SetGlobalHover(false)
			end
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(1, 0) }), -- Pill shape
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, 16),
			PaddingRight = UDim.new(0, 16),
		}),
		Stroke = e("UIStroke", {
			Color = Theme.GLASS_STROKE,
			Transparency = 0.8,
			Thickness = 1,
		}),
	})
end

-- Slot offsets (pixels of screen space) around the anchor, all on one
-- common ring radius - matches the reference layout (primary action up
-- top, two side actions, a cancel/dismiss action below) but as actual
-- points on a circle rather than ad-hoc pixel offsets with different
-- radii, so the pills visibly sit on the same ring instead of some
-- sticking out further than others.
local RING_RADIUS = 96
local function ringOffset(angleDegrees: number): Vector2
	local angle = math.rad(angleDegrees)
	-- 0 deg = straight up, increasing clockwise (screen space: +X right, +Y down)
	return Vector2.new(math.sin(angle), -math.cos(angle)) * RING_RADIUS
end
local OFFSETS = {
	Top = ringOffset(0),
	TopLeft = ringOffset(-45),
	TopRight = ringOffset(45),
	Left = ringOffset(-90),
	Right = ringOffset(90),
	Bottom = ringOffset(180),
}

local function PieMenu(props: {
	WorldPosition: Vector3,
	Top: PieMenuAction?,
	TopLeft: PieMenuAction?,
	TopRight: PieMenuAction?,
	Left: PieMenuAction?,
	Right: PieMenuAction?,
	Bottom: PieMenuAction?,
	SetGlobalHover: ((boolean) -> ())?,
})
	local screenPos, setScreenPos = React.useState(Vector2.new(0, 0))
	local onScreen, setOnScreen = React.useState(false)

	React.useEffect(function()
		local cn = RunService.RenderStepped:Connect(function()
			local camera = Workspace.CurrentCamera
			if not camera then
				setOnScreen(false)
				return
			end
			local point, visible = camera:WorldToViewportPoint(props.WorldPosition)
			setScreenPos(Vector2.new(point.X, point.Y))
			setOnScreen(visible and point.Z > 0)
		end)
		return function()
			cn:Disconnect()
		end
	end, { props.WorldPosition } :: { any })

	if not onScreen then
		return nil :: any
	end

	local children: { [string]: any } = {}
	if props.Top then
		children.Top = e(PillButton, {
			Action = props.Top :: PieMenuAction,
			Primary = true,
			Offset = OFFSETS.Top,
			SetGlobalHover = props.SetGlobalHover,
		})
	end
	if props.TopLeft then
		children.TopLeft = e(PillButton, {
			Action = props.TopLeft :: PieMenuAction,
			Primary = false,
			Offset = OFFSETS.TopLeft,
			SetGlobalHover = props.SetGlobalHover,
		})
	end
	if props.TopRight then
		children.TopRight = e(PillButton, {
			Action = props.TopRight :: PieMenuAction,
			Primary = false,
			Offset = OFFSETS.TopRight,
			SetGlobalHover = props.SetGlobalHover,
		})
	end
	if props.Left then
		children.Left = e(PillButton, {
			Action = props.Left :: PieMenuAction,
			Primary = false,
			Offset = OFFSETS.Left,
			SetGlobalHover = props.SetGlobalHover,
		})
	end
	if props.Right then
		children.Right = e(PillButton, {
			Action = props.Right :: PieMenuAction,
			Primary = false,
			Offset = OFFSETS.Right,
			SetGlobalHover = props.SetGlobalHover,
		})
	end
	if props.Bottom then
		children.Bottom = e(PillButton, {
			Action = props.Bottom :: PieMenuAction,
			Primary = false,
			Offset = OFFSETS.Bottom,
			SetGlobalHover = props.SetGlobalHover,
		})
	end

	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(screenPos.X, screenPos.Y),
		Size = UDim2.new(0, 0, 0, 0),
		BackgroundTransparency = 1,
	}, children)
end

return PieMenu
