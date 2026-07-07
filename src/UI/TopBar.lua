--!strict
-- The top-of-viewport mode bar: industrial glassmorphism pill with the
-- three plugin functions, kept deliberately separate so each surface
-- serves one job (CS2-style):
--
--   Road Tools   - placement: compact tool panel bottom-left
--   Road Editor  - create / edit road types: full designer bottom bar
--   Settings     - grand settings (region profile, scale, banking, ...)
--                  docked in the Studio sidebar panel

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")

local function TopBar(props: {
	ToolsActive: boolean,
	EditorActive: boolean,
	SettingsOpen: boolean,
	OnTools: () -> (),
	OnEditor: () -> (),
	OnSettings: () -> (),
	OnHoverChanged: ((hovered: boolean) -> ())?,
})
	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.new(0, 0, 0, 42),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Theme.GLASS_BG,
		BackgroundTransparency = Theme.GLASS_TRANSPARENCY,
		BorderSizePixel = 0,
		[React.Event.MouseEnter] = function()
			if props.OnHoverChanged then
				(props.OnHoverChanged :: (hovered: boolean) -> ())(true)
			end
		end,
		[React.Event.MouseLeave] = function()
			if props.OnHoverChanged then
				(props.OnHoverChanged :: (hovered: boolean) -> ())(false)
			end
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
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 8),
		}),
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
			VerticalAlignment = Enum.VerticalAlignment.Center,
		}),
		Title = e("TextLabel", {
			Text = "easyRoad",
			TextColor3 = Theme.DIM,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			Font = Theme.FONT_BOLD,
			TextSize = Theme.TEXT_SIZE,
			LayoutOrder = 1,
		}),
		Tools = e(Components.Button, {
			Text = "Road Tools",
			Selected = props.ToolsActive,
			OnClick = props.OnTools,
			LayoutOrder = 2,
		}),
		Editor = e(Components.Button, {
			Text = "Road Editor",
			Selected = props.EditorActive,
			OnClick = props.OnEditor,
			LayoutOrder = 3,
		}),
		Settings = e(Components.Button, {
			Text = "Settings",
			Selected = props.SettingsOpen,
			OnClick = props.OnSettings,
			LayoutOrder = 4,
		}),
	})
end

return TopBar
