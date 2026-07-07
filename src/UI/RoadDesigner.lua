--!strict
-- The road designer: Cities: Skylines 2-style road configuration UI.
--
-- Ships building blocks plus a ready-made panel:
--
--   RoadDesigner.LaneStripCard   - the cross-section as a row of tiles
--                                  (module icon, direction arrow, width;
--                                  click to select, then edit width /
--                                  direction / marking, reorder, remove)
--   RoadDesigner.PaletteCard     - "Available Modules" tile grid, nearly
--                                  full height; click OR drag a module onto
--                                  the lane strip to insert it
--   RoadDesigner.RoadLibraryList - scrollable road picker (name + category)
--                                  used instead of a plain dropdown
--   RoadDesigner.Panel           - Road Properties (left, full height) and
--                                  Modules (right, full height) as two tall
--                                  columns, with the lane strip pinned along
--                                  the very bottom spanning full width -
--                                  matches the CS2 / easyRoad 2 reference
--                                  layout. Used by the road library editor
--                                  and the placed-road inspector.
--
-- Presentation-only: everything operates on a RoadProfile via OnChange
-- (clone-and-transform), with the caller supplying action buttons.

local UserInputService = game:GetService("UserInputService")

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

local STRIP_HEIGHT = 140
local TILE_WIDTH = 58
local TILE_STEP = TILE_WIDTH + 4 -- Tile width + Strip's tile padding

-- Palette entries: every placeable module, with Commonwealth-flavoured
-- display names (Sidewalk reads as "Pavement", matching the reference kit).
-- Bay ("Bus Lane") is deliberately NOT offered here - see TODO.md: it's
-- moving to the future per-instance "click a placed road" panel instead of
-- the general module palette.
local PALETTE: { { Kind: RoadProfile.ComponentKind, Label: string } } = {
	{ Kind = "Drive" :: RoadProfile.ComponentKind, Label = "Lane" },
	{ Kind = "Sidewalk" :: RoadProfile.ComponentKind, Label = "Pavement" },
	{ Kind = "Median" :: RoadProfile.ComponentKind, Label = "Median" },
	{ Kind = "Shoulder" :: RoadProfile.ComponentKind, Label = "Shoulder" },
	{ Kind = "Bike" :: RoadProfile.ComponentKind, Label = "Bike" },
	{ Kind = "Parking" :: RoadProfile.ComponentKind, Label = "Parking" },
}

-- Includes Bay so existing profiles/placed roads that already contain a Bay
-- lane still render a sensible label/icon in the lane strip.
local KIND_LABEL: { [string]: string } = { Bay = "Bus Lane" }
for _, entry in PALETTE do
	KIND_LABEL[entry.Kind] = entry.Label
end

-- Lane marking (boundary) options, in human-readable terms, matching the
-- LineType vocabulary in Mesh/Markings.lua.
local BOUNDARY_OPTIONS: { Components.DropdownOption } = {
	{ Id = "Auto", Text = "Auto (region default)" },
	{ Id = "Solid", Text = "Solid - no lane change" },
	{ Id = "DoubleSolid", Text = "Double solid - no lane change" },
	{ Id = "SolidDash", Text = "Solid | Dash - right may merge left" },
	{ Id = "DashSolid", Text = "Dash | Solid - left may merge right" },
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

-- Road library list ----------------------------------------------------------------
-- A scrollable road picker (name + click to select) used instead of a plain
-- dropdown, closer to CS2's "Created Roads" library list.

local function RoadLibraryRow(props: {
	Text: string,
	Selected: boolean,
	OnClick: () -> (),
	LayoutOrder: number,
})
	local hovered, setHovered = React.useState(false)
	return e("TextButton", {
		Text = "  " .. props.Text,
		TextColor3 = Theme.WHITE,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		BackgroundColor3 = if props.Selected then Theme.SELECTED elseif hovered then Theme.BUTTON_HOVER else Theme.FIELD,
		BackgroundTransparency = if props.Selected then 0.1 else Theme.GLASS_ELEMENT_TRANSPARENCY,
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		Font = Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		LayoutOrder = props.LayoutOrder,
		[React.Event.Activated] = props.OnClick,
		[React.Event.MouseEnter] = function()
			setHovered(true)
		end,
		[React.Event.MouseLeave] = function()
			setHovered(false)
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
	})
end

local function RoadLibraryList(props: {
	Options: { Components.DropdownOption },
	SelectedId: string?,
	OnPick: (id: string) -> (),
	OnNew: (() -> ())?,
	Height: number?,
	LayoutOrder: number?,
})
	local rows: { [string]: any } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 2),
		}),
	}
	for index, option in props.Options do
		rows["Row" .. index] = e(RoadLibraryRow, {
			Text = option.Text,
			Selected = option.Id == props.SelectedId,
			OnClick = function()
				props.OnPick(option.Id)
			end,
			LayoutOrder = index,
		})
	end

	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
		List = e("ScrollingFrame", {
			Size = UDim2.new(1, 0, 0, props.Height or 140),
			BackgroundColor3 = Theme.FIELD,
			BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollBarThickness = 4,
			LayoutOrder = 1,
		}, rows),
		New = props.OnNew and e(Components.Button, {
			Text = "+ New Road",
			OnClick = props.OnNew :: () -> (),
			LayoutOrder = 2,
		}),
	})
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
		Size = UDim2.new(0, TILE_WIDTH, 1, 0),
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
-- the edit controls for that lane. Pinned full-width along the bottom.
local function LaneStripCard(props: {
	Profile: RoadProfile.RoadProfile,
	ReadOnly: boolean?,
	SelectedIndex: number, -- 0 = none
	OnSelect: (index: number) -> (), -- 0 clears
	OnChange: (transform: (profile: RoadProfile.RoadProfile) -> ()) -> (),
	StripRef: { current: ScrollingFrame? }?,
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
		ref = props.StripRef,
		Size = UDim2.new(1, 0, 0, 78),
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
				LayoutOrder = 4,
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
				LayoutOrder = 5,
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
				LayoutOrder = 6,
				Size = UDim2.new(0, 26, 0, Theme.ROW_HEIGHT),
			}),
		})
		-- Lane marking is split onto its own row: a distinct concern from
		-- width/direction/reorder, and needs room for a readable label.
		if (sel :: number) < count then
			children.Marking = e(Components.Row, { LayoutOrder = 4 }, {
				Label = e(Components.Label, { Text = "Lane marking", LayoutOrder = 1, Width = 90 }),
				Dropdown = e(Components.Dropdown, {
					Options = BOUNDARY_OPTIONS,
					SelectedId = selectedComponent.RightBoundary or "Auto",
					OnSelected = function(id: string)
						changeSelected(function(component)
							return {
								Kind = component.Kind,
								WidthM = component.WidthM,
								Direction = component.Direction,
								RightBoundary = if id == "Auto" then nil else (id :: RoadProfile.BoundaryRule),
							}
						end)
					end,
					LayoutOrder = 2,
					Grow = true,
				}),
			})
		end
	else
		children.Controls = e(Components.Label, {
			Text = "Click a lane tile to edit it; click or drag modules from the palette.",
			Dim = true,
			LayoutOrder = 3,
		})
	end

	local frameProps = cardProps()
	frameProps.Size = UDim2.new(1, 0, 0, STRIP_HEIGHT)
	frameProps.LayoutOrder = props.LayoutOrder
	return e("Frame", frameProps, children)
end

-- Module palette -------------------------------------------------------------------

local function ModuleTile(props: {
	Kind: RoadProfile.ComponentKind,
	Label: string,
	OnClick: () -> (),
	OnDragStart: ((kind: RoadProfile.ComponentKind, label: string, pos: Vector2) -> ())?,
	LayoutOrder: number,
})
	return e("TextButton", {
		Text = "",
		BackgroundColor3 = Theme.FIELD,
		BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
		LayoutOrder = props.LayoutOrder,
		[React.Event.Activated] = props.OnClick,
		[React.Event.InputBegan] = function(_, input: InputObject)
			if
				props.OnDragStart
				and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
			then
				(props.OnDragStart :: any)(props.Kind, props.Label, Vector2.new(input.Position.X, input.Position.Y))
			end
		end,
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

-- The module palette card: click OR drag a module to insert it into the
-- road. Nearly full height, matching the CS2 / easyRoad 2 reference.
local function PaletteCard(props: {
	OnInsert: (kind: RoadProfile.ComponentKind) -> (),
	OnDragStart: ((kind: RoadProfile.ComponentKind, label: string, pos: Vector2) -> ())?,
	Width: number?,
	LayoutOrder: number,
})
	local children: { [string]: any } = {}
	decorateCard(children)
	children.Header = e(Components.Section, { Text = "Modules", LayoutOrder = 1 })

	local grid: { [string]: any } = {
		Layout = e("UIGridLayout", {
			CellSize = UDim2.new(0, 56, 0, 58),
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
			OnDragStart = props.OnDragStart,
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
	frameProps.Size = UDim2.new(0, props.Width or 190, 1, 0)
	frameProps.LayoutOrder = props.LayoutOrder
	return e("Frame", frameProps, children)
end

-- Drag-and-drop controller ----------------------------------------------------------
-- Shared by Panel: press-and-drag a module tile past a small threshold to
-- pick it up (a plain click still inserts via OnInsert as before); dropping
-- over the lane strip inserts the module at the nearest tile position.

type DragPayload = { Kind: RoadProfile.ComponentKind, Label: string }

local function useLaneDrag(onInsertAt: (index: number, kind: RoadProfile.ComponentKind) -> ())
	local dragging, setDragging = React.useState(nil :: DragPayload?)
	local dragPos, setDragPos = React.useState(Vector2.new(0, 0))
	local startPos = React.useRef(Vector2.new(0, 0))
	local movedPastThreshold = React.useRef(false)
	local stripRef = React.useRef(nil :: ScrollingFrame?)

	React.useEffect(function()
		if not dragging then
			return nil
		end
		movedPastThreshold.current = false
		local moveCn = UserInputService.InputChanged:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				local pos = Vector2.new(input.Position.X, input.Position.Y)
				if (pos - startPos.current).Magnitude > 6 then
					movedPastThreshold.current = true
				end
				setDragPos(pos)
			end
		end)
		local endCn = UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				if movedPastThreshold.current then
					local strip = stripRef.current
					local payload = dragging
					if strip and payload then
						local absPos = strip.AbsolutePosition
						local absSize = strip.AbsoluteSize
						local mouse = Vector2.new(input.Position.X, input.Position.Y)
						if
							mouse.X >= absPos.X - 20
							and mouse.X <= absPos.X + absSize.X + 20
							and mouse.Y >= absPos.Y - 60
							and mouse.Y <= absPos.Y + absSize.Y + 60
						then
							local relX = mouse.X - absPos.X + strip.CanvasPosition.X
							local index = math.floor(relX / TILE_STEP) + 1
							onInsertAt(index, payload.Kind)
						end
					end
				end
				setDragging(nil)
			end
		end)
		return function()
			moveCn:Disconnect()
			endCn:Disconnect()
		end
	end, { dragging } :: { any })

	return {
		Dragging = if movedPastThreshold.current then dragging else nil,
		DragPos = dragPos,
		StripRef = stripRef,
		BeginDrag = function(kind: RoadProfile.ComponentKind, label: string, pos: Vector2)
			startPos.current = pos
			setDragPos(pos)
			setDragging({ Kind = kind, Label = label })
		end,
	}
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
	local rootRef = React.useRef(nil :: Frame?)

	local function insertKind(kind: RoadProfile.ComponentKind, atIndex: number?)
		local at = if atIndex then math.clamp(atIndex, 1, count + 1)
			elseif sel then (sel :: number) + 1
			else count + 1
		props.OnChange(function(copy)
			table.insert(copy.Components, at, {
				Kind = kind,
				WidthM = defaultWidthFor(kind, props.RegionStyle),
				Direction = if RoadProfile.IsDirectional(kind) then 1 else 0,
			})
		end)
		setSelectedIndex(at)
	end

	local drag = useLaneDrag(insertKind)

	-- Properties card
	local propertiesChildren: { [string]: any } = {}
	propertiesChildren.Header = e(Components.Section, { Text = "Road Properties", LayoutOrder = 1 })
	if props.Picker then
		local picker = props.Picker :: PanelPicker
		propertiesChildren.PickerSection = e(Components.Label, { Text = "Road library", Dim = true, LayoutOrder = 2 })
		propertiesChildren.PickerList = e(RoadLibraryList, {
			Options = picker.Options,
			SelectedId = picker.SelectedId,
			OnPick = picker.OnPick,
			OnNew = picker.OnNew,
			Height = 120,
			LayoutOrder = 3,
		})
	end
	if props.OnRename then
		propertiesChildren.NameRow = e(Components.Row, { LayoutOrder = 4 }, {
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
			LayoutOrder = 4,
		})
	end
	if props.Subtitle then
		propertiesChildren.Subtitle = e(Components.Label, {
			Text = props.Subtitle,
			Dim = true,
			LayoutOrder = 5,
		})
	end
	local afterOptions =
		ProfileFields.InsertMarkingOptions(propertiesChildren, profile, props.RegionStyle, 6, props.OnChange)
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

	-- Drag ghost: follows the cursor while a module tile is being dragged.
	-- Positioned relative to the panel's own root frame (a ref, so it may be
	-- nil for one frame at the very start of a drag).
	local ghost = nil
	if drag.Dragging and rootRef.current then
		local rootAbs = (rootRef.current :: Frame).AbsolutePosition
		local dragging = drag.Dragging :: DragPayload
		ghost = e("Frame", {
			ZIndex = 50,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(drag.DragPos.X - rootAbs.X, drag.DragPos.Y - rootAbs.Y),
			Size = UDim2.new(0, 50, 0, 52),
			BackgroundColor3 = Theme.SELECTED,
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, 6) }),
			Icon = e("ImageLabel", {
				Image = Icons.ForKind[dragging.Kind] or Icons.Lane,
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.4, 0),
				Size = UDim2.new(0, 28, 0, 28),
				ScaleType = Enum.ScaleType.Fit,
			}),
		})
	end

	return e("Frame", {
		ref = rootRef,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 8),
		}),
		Top = e("Frame", {
			Size = UDim2.new(1, 0, 1, -(STRIP_HEIGHT + 8)),
			BackgroundTransparency = 1,
			LayoutOrder = 1,
		}, {
			Layout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 8),
			}),
			Properties = scrollColumn(240, 1, propertiesChildren),
			Palette = not readOnly and e(PaletteCard, {
				Width = 220,
				OnInsert = function(kind: RoadProfile.ComponentKind)
					insertKind(kind, nil)
				end,
				OnDragStart = drag.BeginDrag,
				LayoutOrder = 2,
			}),
		}),
		StripCard = e(LaneStripCard, {
			Profile = profile,
			ReadOnly = readOnly,
			SelectedIndex = selectedIndex,
			OnSelect = setSelectedIndex,
			OnChange = props.OnChange,
			StripRef = drag.StripRef,
			LayoutOrder = 2,
		}),
		Ghost = ghost,
	})
end

local RoadDesigner = {
	Panel = Panel,
	LaneStripCard = LaneStripCard,
	PaletteCard = PaletteCard,
	RoadLibraryList = RoadLibraryList,
	ScrollColumn = scrollColumn,
	DecorateCard = decorateCard,
	DefaultWidthFor = defaultWidthFor,
}

return RoadDesigner
