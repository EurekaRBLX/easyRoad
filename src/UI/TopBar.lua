--!strict
-- The top-of-viewport mode bar: industrial glassmorphism pill with the
-- four plugin functions, kept deliberately separate so each surface
-- serves one job (CS2-style):
--
--   Road Tools   - placement: compact tool panel bottom-left
--   Road Editor  - create / edit road types: full designer bottom bar
--   Road Assets  - import / rename / remove custom structure Models
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
	AssetsActive: boolean,
	RegionalOpen: boolean,
	KeybindsOpen: boolean,
	SoftwareOpen: boolean,
	OnTools: () -> (),
	OnEditor: () -> (),
	OnAssets: () -> (),
	OnOpenRegional: () -> (),
	OnOpenKeybinds: () -> (),
	OnOpenSoftware: () -> (),
	OnHoverChanged: ((hovered: boolean) -> ())?,
})
	-- Settings has no single dock of its own any more - clicking it opens a
	-- small home menu to choose Regional Preference or Keybinds, each its
	-- own independently-toggled dock, instead of forcing both open/closed
	-- together (which used to stack them at the same default float
	-- position with no way to tell the second one was even there).
	local menuOpen, setMenuOpen = React.useState(false)
	local settingsSelected = props.RegionalOpen or props.KeybindsOpen or props.SoftwareOpen or menuOpen

	return e(React.Fragment, nil, {
		Bar = e("Frame", {
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
				TextColor3 = Theme.ACCENT,
				BackgroundTransparency = 1,
				Size = UDim2.new(0, 0, 1, 0),
				AutomaticSize = Enum.AutomaticSize.X,
				Font = Enum.Font.BuilderSansMedium,
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
			Assets = e(Components.Button, {
				Text = "Road Assets",
				Selected = props.AssetsActive,
				OnClick = props.OnAssets,
				LayoutOrder = 4,
			}),
			Settings = e(Components.Button, {
				Text = "Settings",
				Selected = settingsSelected,
				OnClick = function()
					setMenuOpen(not menuOpen)
				end,
				LayoutOrder = 5,
			}),
		}),
		-- Settings home menu: pick Regional Preference or Keybinds, each its
		-- own dock, opened one at a time instead of both together.
		SettingsMenu = menuOpen and e("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 56),
			Size = UDim2.new(0, 200, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = Theme.GLASS_BG,
			BackgroundTransparency = Theme.GLASS_TRANSPARENCY,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.CORNER_RADIUS) }),
			Stroke = e("UIStroke", {
				Color = Theme.GLASS_STROKE,
				Transparency = Theme.GLASS_STROKE_TRANSPARENCY,
				Thickness = 1,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}),
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
				PaddingTop = UDim.new(0, 8),
				PaddingBottom = UDim.new(0, 8),
			}),
			Layout = e("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			Regional = e(Components.Button, {
				Text = "Regional Preference",
				Selected = props.RegionalOpen,
				OnClick = function()
					setMenuOpen(false)
					props.OnOpenRegional()
				end,
				Size = UDim2.new(1, 0, 0, 32),
				LayoutOrder = 1,
			}),
			Keybinds = e(Components.Button, {
				Text = "Keybinds",
				Selected = props.KeybindsOpen,
				OnClick = function()
					setMenuOpen(false)
					props.OnOpenKeybinds()
				end,
				Size = UDim2.new(1, 0, 0, 32),
				LayoutOrder = 2,
			}),
			Software = e(Components.Button, {
				Text = "Software",
				Selected = props.SoftwareOpen,
				OnClick = function()
					setMenuOpen(false)
					props.OnOpenSoftware()
				end,
				Size = UDim2.new(1, 0, 0, 32),
				LayoutOrder = 3,
			}),
		}),
	})
end

return TopBar
