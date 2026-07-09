--!strict
-- Small "pod" shown only while placing a marking stretch: choose which
-- boundaries a drag applies to - All (the whole same-direction sibling
-- run), Individual (just the clicked boundary), or Select (click boundaries
-- one at a time to build a custom set, then drag any of them to set the
-- range). See RoadEditSession's stretchSelectionMode for the behaviour
-- each mode actually drives.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")

local MODES = { "All", "Individual", "Select" }

local function MarkingSelectionModePod(
	props: {
		Mode: string,
		OnModeChanged: (mode: string) -> (),
		-- Its parent wrapper Frame in main.lua spans the whole screen (so
		-- this pod can position itself bottom-center via AnchorPoint),
		-- which means that wrapper deliberately skips the generic hover
		-- tracking used elsewhere - hovering anywhere in the 3D viewport
		-- would otherwise latch uiState.Hovered permanently, the exact
		-- hover-trap bug fixed earlier this session for the placement
		-- session's own full-screen wrapper. This pod reports its own
		-- (correctly small) hover area here instead, same convention as
		-- PieMenu's PillButtons.
		OnHoverChanged: (hovered: boolean) -> (),
	}
)
	local buttons: { [string]: any } = {}
	for index, mode in MODES do
		buttons[mode] = e(Components.Button, {
			Text = mode,
			Selected = props.Mode == mode,
			Grow = true,
			LayoutOrder = index,
			OnClick = function()
				props.OnModeChanged(mode)
			end,
		})
	end

	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.new(0, 280, 0, Theme.ROW_HEIGHT + Theme.PADDING * 2),
		BackgroundColor3 = Theme.GLASS_BG,
		BackgroundTransparency = Theme.GLASS_TRANSPARENCY,
		BorderSizePixel = 0,
		[React.Event.MouseEnter] = function()
			props.OnHoverChanged(true)
		end,
		[React.Event.MouseLeave] = function()
			props.OnHoverChanged(false)
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.CORNER_RADIUS) }),
		Stroke = e("UIStroke", {
			Color = Theme.GLASS_STROKE,
			Transparency = Theme.GLASS_STROKE_TRANSPARENCY,
			Thickness = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, Theme.PADDING),
			PaddingRight = UDim.new(0, Theme.PADDING),
			PaddingTop = UDim.new(0, Theme.PADDING),
			PaddingBottom = UDim.new(0, Theme.PADDING),
		}),
		Row = e(Components.Row, {}, buttons),
	})
end

return MarkingSelectionModePod
