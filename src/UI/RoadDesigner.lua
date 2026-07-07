--!strict
-- The road designer: Cities: Skylines 2-style road configuration UI.
--
-- Renders as a wide bottom-of-viewport HUD with three glass cards:
--
--   [ ROAD PROPERTIES ]  [ ROAD CONFIGURATION (lane strip) ]  [ MODULES ]
--
-- The lane strip shows the cross-section as a row of tiles (module icon,
-- direction arrow, width) exactly like the reference easyRoad 2 / CS2
-- bottom bars; click a tile to select it and edit its width / direction /
-- boundary, click a module in the palette to insert a new lane after the
-- selection. The properties card carries the road name, kerb rules,
-- marking colour, and dash spacing.
--
-- Presentation-only: operates on a RoadProfile via OnChange (clone-and-
-- transform), with the caller supplying the action buttons (Save / Apply /
-- Close / ...), so the same designer serves both the road library editor
-- and the placed-road inspector.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local ProfileFields = require("./ProfileFields")
local Icons = require("./Icons")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")

export type DesignerAction = {
	Text: string,
	Selected: boolean?,
	Danger: boolean?,
	OnClick: () -> (),
}

-- Palette entries: every placeable module, with Commonwealth-flavoured
-- display names (Sidewalk reads as "Pavement", matching the reference kit).
local PALETTE: { { Kind: RoadProfile.ComponentKind, Label: string } } = {
	{ Kind = "Drive" :: RoadProfile.ComponentKind, Label = "Lane" },
	{ Kind = "Sidewalk" :: RoadProfile.ComponentKind, Label = "Pavement" },
	{ Kind = "Median" :: RoadProfile.ComponentKind, Label = "Median" },
	{ Kind = "Shoulder" :: RoadProfile.ComponentKind, Label = "Shoulder" },
	{ Kind = "Bike" :: RoadProfile.ComponentKind, Label = "Bike" },
	{ Kind = "Parking" :: RoadProfile.ComponentKind, Label = "Parking" },
	{ Kind = "Bay" :: RoadProfile.ComponentKind, Label = "Bus Bay" },
}

local KIND_LABEL: { [string]: string } = {}
for _, entry in PALETTE do
	KIND_LABEL[entry.Kind] = entry.Label
end

local BOUNDARY_LABELS: { [string]: string } = {
	Auto = "\u{2506}", -- dashed bar
	Solid = "\u{2502}",
	DoubleSolid = "\u{2551}",
	SolidDash = "\u{2502}\u{254C}",
	DashSolid = "\u{254C}\u{2502}",
}

local function defaultWidthFor(kind: RoadProfile.ComponentKind, style: RegionStyles.RegionStyle): number
	if kind == "Drive" then
		return style.DefaultLaneWidthM
	elseif kind == "Sidewalk" then
		return style.SidewalkWidthM
	elseif kind == "Median" then
		return style.MedianWidthM
	elseif kind == "Shoulder" then
		return style.ShoulderWidthM
	elseif kind == "Bike" then
		return style.BikeLaneWidthM
	elseif kind == "Parking" then
		return style.ParkingLaneWidthM
	end
	return 3 -- Bay: UK bus bay standard ~3.0 m
end

local function arrowFor(direction: number): string
	if direction > 0 then
		return "\u{2191}" -- up arrow: with the road
	elseif direction < 0 then
		return "\u{2193}" -- down arrow: against it
	end
	return "\u{2014}"
end

-- One tile in the lane strip
local function LaneTile(props: {
	Component: RoadProfile.ProfileComponent,
	Selected: boolean,
	ReadOnly: boolean,
	OnClick: () -> (),
	LayoutOrder: number,
})
	local component = props.Component
	return e("TextButton", {
		Text = "",
		BackgroundColor3 = if props.Selected then Theme.SELECTED else Theme.FIELD,
		BackgroundTransparency = if props.Selected then 0.15 else Theme.GLASS_ELEMENT_TRANSPARENCY,
		Size = UDim2.new(0, 58, 1, 0),
		AutoButtonColor = not props.ReadOnly,
		LayoutOrder = props.LayoutOrder,
		[React.Event.Activated] = function()
			if not props.ReadOnly then
				props.OnClick()
			end
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 6) }),
		Stroke = props.Selected and e("UIStroke", {
			Color = Theme.ACCENT_HOVER,
			Thickness = 2,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 2),
		}),
		Icon = e("ImageLabel", {
			Image = Icons.ForKind[component.Kind] or Icons.Lane,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 34, 0, 34),
			ScaleType = Enum.ScaleType.Fit,
			LayoutOrder = 1,
		}),
		Arrow = e("TextLabel", {
			Text = arrowFor(component.Direction),
			TextColor3 = Theme.WHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 16),
			Font = Theme.FONT_BOLD,
			TextSize = 16,
			LayoutOrder = 2,
		}),
		WidthText = e("TextLabel", {
			Text = string.format("%g m", component.WidthM),
			TextColor3 = Theme.OFFWHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 14),
			Font = Theme.FONT_MONO,
			TextSize = 13,
			LayoutOrder = 3,
		}),
		KindText = e("TextLabel", {
			Text = KIND_LABEL[component.Kind] or component.Kind,
			TextColor3 = Theme.DIM,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -2, 0, 12),
			Font = Theme.FONT,
			TextSize = 11,
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = 4,
		}),
	})
end

-- One tile in the module palette
local function ModuleTile(props: {
	Kind: RoadProfile.ComponentKind,
	Label: string,
	OnClick: () -> (),
	LayoutOrder: number,
})
	return e("TextButton", {
		Text = "",
		BackgroundColor3 = Theme.FIELD,
		BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
		LayoutOrder = props.LayoutOrder,
		[React.Event.Activated] = props.OnClick,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 6) }),
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 2),
		}),
		Icon = e("ImageLabel", {
			Image = Icons.ForKind[props.Kind] or Icons.Lane,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 30, 0, 30),
			ScaleType = Enum.ScaleType.Fit,
			LayoutOrder = 1,
		}),
		Label = e("TextLabel", {
			Text = props.Label,
			TextColor3 = Theme.OFFWHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -2, 0, 12),
			Font = Theme.FONT,
			TextSize = 11,
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = 2,
		}),
	})
end

-- Glass card wrapper
local function cardProps(): { [string]: any }
	return {
		BackgroundColor3 = Theme.GLASS_BG,
		BackgroundTransparency = Theme.GLASS_TRANSPARENCY,
		BorderSizePixel = 0,
	}
end

local function cardDecoration(children: { [string]: any })
	children.Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.CORNER_RADIUS) })
	children.Stroke = e("UIStroke", {
		Color = Theme.GLASS_STROKE,
		Transparency = Theme.GLASS_STROKE_TRANSPARENCY,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
	children.Padding = e("UIPadding", {
		PaddingLeft = UDim.new(0, Theme.PADDING),
		PaddingRight = UDim.new(0, Theme.PADDING),
		PaddingTop = UDim.new(0, Theme.PADDING),
		PaddingBottom = UDim.new(0, Theme.PADDING),
	})
	children.Layout = e("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 4),
	})
end

local function RoadDesigner(props: {
	Profile: RoadProfile.RoadProfile,
	RegionStyle: RegionStyles.RegionStyle,
	OnChange: (transform: (profile: RoadProfile.RoadProfile) -> ()) -> (),
	OnRename: ((name: string) -> ())?,
	Subtitle: string?,
	ReadOnlyLanes: boolean?,
	Actions: { DesignerAction },
})
	local profile = props.Profile
	local readOnly = props.ReadOnlyLanes == true
	local count = #profile.Components

	local selectedIndex, setSelectedIndex = React.useState(0)
	local sel: number? = if selectedIndex >= 1 and selectedIndex <= count then selectedIndex else nil
	local selected: RoadProfile.ProfileComponent? = if sel then profile.Components[sel :: number] else nil

	local function changeSelected(patch: (component: RoadProfile.ProfileComponent) -> RoadProfile.ProfileComponent)
		local index = sel
		if not index then
			return
		end
		props.OnChange(function(copy)
			local component = copy.Components[index :: number]
			if component then
				copy.Components[index :: number] = patch(component)
			end
		end)
	end

	local function insertKind(kind: RoadProfile.ComponentKind)
		local at = if sel then (sel :: number) + 1 else count + 1
		props.OnChange(function(copy)
			table.insert(copy.Components, at, {
				Kind = kind,
				WidthM = defaultWidthFor(kind, props.RegionStyle),
				Direction = if RoadProfile.IsDirectional(kind) then 1 else 0,
			})
		end)
		setSelectedIndex(at)
	end

	-- Properties card -----------------------------------------------------------
	local propertiesChildren: { [string]: any } = {}
	cardDecoration(propertiesChildren)
	propertiesChildren.Header = e(Components.Section, { Text = "Road Properties", LayoutOrder = 1 })
	if props.OnRename then
		propertiesChildren.NameRow = e(Components.Row, { LayoutOrder = 2 }, {
			Label = e(Components.Label, { Text = "Name", LayoutOrder = 1, Width = 44 }),
			NameBox = e("TextBox", {
				Text = profile.Name,
				TextColor3 = Theme.WHITE,
				BackgroundColor3 = Theme.FIELD,
				BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
				Size = UDim2.new(1, -52, 0, Theme.ROW_HEIGHT),
				Font = Theme.FONT,
				TextSize = Theme.TEXT_SIZE,
				ClearTextOnFocus = false,
				LayoutOrder = 2,
				[React.Event.FocusLost] = function(object: TextBox)
					if object.Text ~= "" and props.OnRename then
						(props.OnRename :: (name: string) -> ())(object.Text)
					end
				end,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
			}),
		})
	else
		propertiesChildren.NameLabel = e(Components.Label, {
			Text = profile.Name,
			LayoutOrder = 2,
		})
	end
	if props.Subtitle then
		propertiesChildren.Subtitle = e(Components.Label, {
			Text = props.Subtitle,
			Dim = true,
			LayoutOrder = 3,
		})
	end
	local afterOptions =
		ProfileFields.InsertMarkingOptions(propertiesChildren, profile, props.RegionStyle, 4, props.OnChange)
	local actionButtons: { [string]: any } = {}
	for index, action in props.Actions do
		actionButtons["Action" .. index] = e(Components.Button, {
			Text = action.Text,
			Selected = action.Selected,
			Danger = action.Danger,
			OnClick = action.OnClick,
			LayoutOrder = index,
			Grow = true,
		})
	end
	propertiesChildren.Actions = e(Components.Row, { LayoutOrder = afterOptions }, actionButtons)

	-- Lane strip card ------------------------------------------------------------
	local stripChildren: { [string]: any } = {}
	cardDecoration(stripChildren)
	stripChildren.Header = e(Components.Section, {
		Text = string.format("Road Configuration — %.1f m", RoadProfile.TotalWidthM(profile)),
		LayoutOrder = 1,
	})

	local tiles: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
	}
	for index, component in profile.Components do
		tiles["Tile" .. index] = e(LaneTile, {
			Component = component,
			Selected = sel == index,
			ReadOnly = readOnly,
			OnClick = function()
				setSelectedIndex(if selectedIndex == index then 0 else index)
			end,
			LayoutOrder = index,
		})
	end
	stripChildren.Strip = e("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, 122),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 4,
		LayoutOrder = 2,
	}, tiles)

	if readOnly then
		stripChildren.Controls = e(Components.Label, {
			Text = "Lane-by-lane editing is disabled for transition roads.",
			Dim = true,
			LayoutOrder = 3,
		})
	elseif selected then
		local selectedComponent = selected :: RoadProfile.ProfileComponent
		stripChildren.Controls = e(Components.Row, { LayoutOrder = 3 }, {
			KindLabel = e(Components.Label, {
				Text = KIND_LABEL[selectedComponent.Kind] or selectedComponent.Kind,
				LayoutOrder = 1,
				Width = 64,
			}),
			WidthField = e(Components.NumberField, {
				Value = selectedComponent.WidthM,
				Min = 0.1,
				Max = 30,
				OnChanged = function(value: number)
					changeSelected(function(component)
						return {
							Kind = component.Kind,
							WidthM = value,
							Direction = component.Direction,
							RightBoundary = component.RightBoundary,
						}
					end)
				end,
				LayoutOrder = 2,
				Width = 52,
			}),
			Direction = e(Components.Button, {
				Text = arrowFor(selectedComponent.Direction),
				OnClick = function()
					if RoadProfile.IsDirectional(selectedComponent.Kind) then
						changeSelected(function(component)
							return {
								Kind = component.Kind,
								WidthM = component.WidthM,
								Direction = if component.Direction >= 0 then -1 else 1,
								RightBoundary = component.RightBoundary,
							}
						end)
					end
				end,
				LayoutOrder = 3,
				Size = UDim2.new(0, 30, 0, Theme.ROW_HEIGHT),
			}),
			Boundary = (sel :: number) < count and e(Components.Button, {
				Text = BOUNDARY_LABELS[selectedComponent.RightBoundary or "Auto"] or BOUNDARY_LABELS.Auto,
				OnClick = function()
					local rules = RoadProfile.BoundaryRules
					local current = selectedComponent.RightBoundary or "Auto"
					local index = table.find(rules, current) or 1
					local nextRule = rules[(index % #rules) + 1]
					changeSelected(function(component)
						return {
							Kind = component.Kind,
							WidthM = component.WidthM,
							Direction = component.Direction,
							RightBoundary = if nextRule == "Auto" then nil else nextRule,
						}
					end)
				end,
				LayoutOrder = 4,
				Size = UDim2.new(0, 36, 0, Theme.ROW_HEIGHT),
			}),
			MoveLeft = e(Components.Button, {
				Text = "\u{25C0}",
				OnClick = function()
					local index = sel :: number
					if index > 1 then
						props.OnChange(function(copy)
							local moved = table.remove(copy.Components, index) :: RoadProfile.ProfileComponent
							table.insert(copy.Components, index - 1, moved)
						end)
						setSelectedIndex(index - 1)
					end
				end,
				LayoutOrder = 5,
				Size = UDim2.new(0, 26, 0, Theme.ROW_HEIGHT),
			}),
			MoveRight = e(Components.Button, {
				Text = "\u{25B6}",
				OnClick = function()
					local index = sel :: number
					if index < count then
						props.OnChange(function(copy)
							local moved = table.remove(copy.Components, index) :: RoadProfile.ProfileComponent
							table.insert(copy.Components, index + 1, moved)
						end)
						setSelectedIndex(index + 1)
					end
				end,
				LayoutOrder = 6,
				Size = UDim2.new(0, 26, 0, Theme.ROW_HEIGHT),
			}),
			Remove = e(Components.Button, {
				Text = "\u{2715}",
				Danger = true,
				OnClick = function()
					local index = sel :: number
					props.OnChange(function(copy)
						table.remove(copy.Components, index)
					end)
					setSelectedIndex(0)
				end,
				LayoutOrder = 7,
				Size = UDim2.new(0, 26, 0, Theme.ROW_HEIGHT),
			}),
		})
	else
		stripChildren.Controls = e(Components.Label, {
			Text = "Select a lane tile to edit it, or add modules from the palette.",
			Dim = true,
			LayoutOrder = 3,
		})
	end

	-- Module palette card ----------------------------------------------------------
	local paletteChildren: { [string]: any } = {}
	cardDecoration(paletteChildren)
	paletteChildren.Header = e(Components.Section, { Text = "Modules", LayoutOrder = 1 })
	local grid: { [string]: any } = {
		Layout = e("UIGridLayout", {
			CellSize = UDim2.new(0, 52, 0, 56),
			CellPadding = UDim2.new(0, 4, 0, 4),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for index, entry in PALETTE do
		grid["Module" .. index] = e(ModuleTile, {
			Kind = entry.Kind,
			Label = entry.Label,
			OnClick = function()
				insertKind(entry.Kind)
			end,
			LayoutOrder = index,
		})
	end
	paletteChildren.Grid = e("Frame", {
		Size = UDim2.new(1, 0, 1, -24),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
	}, grid)

	-- Assemble ------------------------------------------------------------------------
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 8),
		}),
		Properties = e("ScrollingFrame", {
			Size = UDim2.new(0, 260, 1, 0),
			BackgroundColor3 = Theme.GLASS_BG,
			BackgroundTransparency = Theme.GLASS_TRANSPARENCY,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(1, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollBarThickness = 4,
			LayoutOrder = 1,
		}, propertiesChildren),
		StripCard = (function()
			local frameProps = cardProps()
			frameProps.Size = UDim2.new(0, 0, 1, 0)
			frameProps.LayoutOrder = 2
			stripChildren.Flex = e("UIFlexItem", { FlexMode = Enum.UIFlexMode.Grow })
			return e("Frame", frameProps, stripChildren)
		end)(),
		PaletteCard = not readOnly and (function()
			local frameProps = cardProps()
			frameProps.Size = UDim2.new(0, 188, 1, 0)
			frameProps.LayoutOrder = 3
			return e("Frame", frameProps, paletteChildren)
		end)(),
	})
end

return RoadDesigner
