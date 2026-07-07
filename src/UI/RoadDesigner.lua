--!strict
-- The road designer: Cities: Skylines 2-style road configuration UI.
--
-- Ships three building blocks plus a ready-made panel:
--
--   RoadDesigner.LaneStripCard  - the cross-section as a row of tiles
--                                 (module icon, direction arrow, width;
--                                 click to select, then edit width /
--                                 direction / boundary, reorder, remove)
--   RoadDesigner.PaletteCard    - "Available Modules" tile grid; click a
--                                 module to insert it into the road
--   RoadDesigner.Panel          - [properties | lane strip | palette] in a
--                                 wide bottom-of-viewport row, used by the
--                                 road library editor and the placed-road
--                                 inspector
--
-- The build bar composes the same strip + palette with a tool card instead
-- of the properties card, so building and editing look and feel identical.
--
-- Presentation-only: everything operates on a RoadProfile via OnChange
-- (clone-and-transform), with the caller supplying action buttons.

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

local LEFT_CARD_WIDTH = 240
local PALETTE_WIDTH = 140

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

-- ASCII-safe labels: Studio's SourceSans renders the box-drawing glyphs as
-- tofu boxes, so the boundary rule cycle uses plain characters.
local BOUNDARY_LABELS: { [string]: string } = {
	Auto = "- -",
	Solid = "|",
	DoubleSolid = "||",
	SolidDash = "|:",
	DashSolid = ":|",
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
		return "\u{2191}" -- with the road
	elseif direction < 0 then
		return "\u{2193}" -- against it
	end
	return "-"
end

-- Glass card scaffolding --------------------------------------------------------

local function cardProps(): { [string]: any }
	return {
		BackgroundColor3 = Theme.GLASS_BG,
		BackgroundTransparency = Theme.GLASS_TRANSPARENCY,
		BorderSizePixel = 0,
	}
end

local function decorateCard(children: { [string]: any })
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

-- A glass vertical scrolling column (left card slot)
local function scrollColumn(width: number, layoutOrder: number, children: { [string]: any })
	decorateCard(children)
	return e("ScrollingFrame", {
		Size = UDim2.new(0, width, 1, 0),
		BackgroundColor3 = Theme.GLASS_BG,
		BackgroundTransparency = Theme.GLASS_TRANSPARENCY,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(1, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		LayoutOrder = layoutOrder,
	}, children)
end

-- Lane strip ---------------------------------------------------------------------

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

-- The lane strip card: header, tile strip, and (when a tile is selected)
-- the edit controls for that lane. Grows to fill the row (UIFlexItem).
local function LaneStripCard(props: {
	Profile: RoadProfile.RoadProfile,
	ReadOnly: boolean?,
	SelectedIndex: number, -- 0 = none
	OnSelect: (index: number) -> (), -- 0 clears
	OnChange: (transform: (profile: RoadProfile.RoadProfile) -> ()) -> (),
	LayoutOrder: number,
})
	local profile = props.Profile
	local readOnly = props.ReadOnly == true
	local count = #profile.Components
	local sel: number? = if props.SelectedIndex >= 1 and props.SelectedIndex <= count then props.SelectedIndex else nil
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

	local children: { [string]: any } = {}
	decorateCard(children)
	children.Flex = e("UIFlexItem", { FlexMode = Enum.UIFlexMode.Grow })
	children.Header = e(Components.Section, {
		Text = string.format("Road Layout - %.1f m", RoadProfile.TotalWidthM(profile)),
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
				props.OnSelect(if props.SelectedIndex == index then 0 else index)
			end,
			LayoutOrder = index,
		})
	end
	children.Strip = e("ScrollingFrame", {
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
		children.Controls = e(Components.Label, {
			Text = "Lane editing is disabled for transition roads.",
			Dim = true,
			LayoutOrder = 3,
		})
	elseif selected then
		local selectedComponent = selected :: RoadProfile.ProfileComponent
		children.Controls = e(Components.Row, { LayoutOrder = 3 }, {
			KindLabel = e(Components.Label, {
				Text = KIND_LABEL[selectedComponent.Kind] or selectedComponent.Kind,
				LayoutOrder = 1,
				Width = 62,
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
				Text = "<",
				OnClick = function()
					local index = sel :: number
					if index > 1 then
						props.OnChange(function(copy)
							local moved = table.remove(copy.Components, index) :: RoadProfile.ProfileComponent
							table.insert(copy.Components, index - 1, moved)
						end)
						props.OnSelect(index - 1)
					end
				end,
				LayoutOrder = 5,
				Size = UDim2.new(0, 26, 0, Theme.ROW_HEIGHT),
			}),
			MoveRight = e(Components.Button, {
				Text = ">",
				OnClick = function()
					local index = sel :: number
					if index < count then
						props.OnChange(function(copy)
							local moved = table.remove(copy.Components, index) :: RoadProfile.ProfileComponent
							table.insert(copy.Components, index + 1, moved)
						end)
						props.OnSelect(index + 1)
					end
				end,
				LayoutOrder = 6,
				Size = UDim2.new(0, 26, 0, Theme.ROW_HEIGHT),
			}),
			Remove = e(Components.Button, {
				Text = "X",
				Danger = true,
				OnClick = function()
					local index = sel :: number
					props.OnChange(function(copy)
						table.remove(copy.Components, index)
					end)
					props.OnSelect(0)
				end,
				LayoutOrder = 7,
				Size = UDim2.new(0, 26, 0, Theme.ROW_HEIGHT),
			}),
		})
	else
		children.Controls = e(Components.Label, {
			Text = "Click a lane tile to edit it; add modules from the palette.",
			Dim = true,
			LayoutOrder = 3,
		})
	end

	local frameProps = cardProps()
	frameProps.Size = UDim2.new(0, 0, 1, 0)
	frameProps.LayoutOrder = props.LayoutOrder
	return e("Frame", frameProps, children)
end

-- Module palette -------------------------------------------------------------------

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
			Size = UDim2.new(0, 26, 0, 26),
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

-- The module palette card: click a module to insert it into the road.
local function PaletteCard(props: {
	OnInsert: (kind: RoadProfile.ComponentKind) -> (),
	LayoutOrder: number,
})
	local children: { [string]: any } = {}
	decorateCard(children)
	children.Header = e(Components.Section, { Text = "Modules", LayoutOrder = 1 })

	local grid: { [string]: any } = {
		Layout = e("UIGridLayout", {
			CellSize = UDim2.new(0, 50, 0, 52),
			CellPadding = UDim2.new(0, 4, 0, 4),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for index, entry in PALETTE do
		grid["Module" .. index] = e(ModuleTile, {
			Kind = entry.Kind,
			Label = entry.Label,
			OnClick = function()
				props.OnInsert(entry.Kind)
			end,
			LayoutOrder = index,
		})
	end
	children.Grid = e("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, -28),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		LayoutOrder = 2,
	}, grid)

	local frameProps = cardProps()
	frameProps.Size = UDim2.new(0, PALETTE_WIDTH, 1, 0)
	frameProps.LayoutOrder = props.LayoutOrder
	return e("Frame", frameProps, children)
end

-- Full designer panel ---------------------------------------------------------------

export type PanelPicker = {
	Options: { Components.DropdownOption },
	SelectedId: string?,
	OnPick: (id: string) -> (),
	OnNew: (() -> ())?,
}

local function Panel(props: {
	Profile: RoadProfile.RoadProfile,
	RegionStyle: RegionStyles.RegionStyle,
	OnChange: (transform: (profile: RoadProfile.RoadProfile) -> ()) -> (),
	OnRename: ((name: string) -> ())?,
	Subtitle: string?,
	ReadOnlyLanes: boolean?,
	Picker: PanelPicker?, -- Road switcher shown atop the properties card
	Actions: { DesignerAction },
})
	local profile = props.Profile
	local readOnly = props.ReadOnlyLanes == true
	local count = #profile.Components

	local selectedIndex, setSelectedIndex = React.useState(0)
	local sel: number? = if selectedIndex >= 1 and selectedIndex <= count then selectedIndex else nil

	-- Properties card
	local propertiesChildren: { [string]: any } = {}
	propertiesChildren.Header = e(Components.Section, { Text = "Road Properties", LayoutOrder = 1 })
	if props.Picker then
		local picker = props.Picker :: PanelPicker
		propertiesChildren.PickerRow = e(Components.Row, { LayoutOrder = 2 }, {
			Dropdown = e(Components.Dropdown, {
				Options = picker.Options,
				SelectedId = picker.SelectedId,
				Placeholder = "Pick a road...",
				OnSelected = picker.OnPick,
				LayoutOrder = 1,
				Grow = true,
			}),
			New = picker.OnNew and e(Components.Button, {
				Text = "New",
				OnClick = picker.OnNew :: () -> (),
				LayoutOrder = 2,
			}),
		})
	end
	if props.OnRename then
		propertiesChildren.NameRow = e(Components.Row, { LayoutOrder = 3 }, {
			Label = e(Components.Label, { Text = "Name", LayoutOrder = 1, Width = 44 }),
			NameBox = e("TextBox", {
				Text = profile.Name,
				TextColor3 = Theme.WHITE,
				BackgroundColor3 = Theme.FIELD,
				BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
				Size = UDim2.new(1, -52, 0, Theme.ROW_HEIGHT),
				Font = Theme.FONT,
				TextSize = Theme.TEXT_SIZE,
				TextTruncate = Enum.TextTruncate.AtEnd,
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
			LayoutOrder = 3,
		})
	end
	if props.Subtitle then
		propertiesChildren.Subtitle = e(Components.Label, {
			Text = props.Subtitle,
			Dim = true,
			LayoutOrder = 4,
		})
	end
	local afterOptions =
		ProfileFields.InsertMarkingOptions(propertiesChildren, profile, props.RegionStyle, 5, props.OnChange)
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

	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 8),
		}),
		Properties = scrollColumn(LEFT_CARD_WIDTH, 1, propertiesChildren),
		StripCard = e(LaneStripCard, {
			Profile = profile,
			ReadOnly = readOnly,
			SelectedIndex = selectedIndex,
			OnSelect = setSelectedIndex,
			OnChange = props.OnChange,
			LayoutOrder = 2,
		}),
		Palette = not readOnly and e(PaletteCard, {
			OnInsert = function(kind: RoadProfile.ComponentKind)
				local at = if sel then (sel :: number) + 1 else count + 1
				props.OnChange(function(copy)
					table.insert(copy.Components, at, {
						Kind = kind,
						WidthM = defaultWidthFor(kind, props.RegionStyle),
						Direction = if RoadProfile.IsDirectional(kind) then 1 else 0,
					})
				end)
				setSelectedIndex(at)
			end,
			LayoutOrder = 3,
		}),
	})
end

local RoadDesigner = {
	Panel = Panel,
	LaneStripCard = LaneStripCard,
	PaletteCard = PaletteCard,
	ScrollColumn = scrollColumn,
	DecorateCard = decorateCard,
	DefaultWidthFor = defaultWidthFor,
}

return RoadDesigner
