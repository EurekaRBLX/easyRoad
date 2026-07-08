--!strict
-- The road designer: Cities: Skylines 2-style road configuration UI.
--
-- Ships building blocks plus a ready-made panel:
--
--   RoadDesigner.LaneStripCard   - the cross-section as a row of tiles
--                                  (module icon, direction arrow, width;
--                                  click to select, then edit width /
--                                  direction / marking, reorder, remove)
--   RoadDesigner.RoadLibraryList - scrollable road picker (rendered
--                                  cross-section thumbnail + name) used
--                                  instead of a plain dropdown
--   RoadDesigner.Panel           - Road Properties (left, full height) and
--                                  a right card (right, full height) as two
--                                  tall columns, with the lane strip pinned
--                                  along the very bottom spanning full width
--                                  - matches the CS2 / easyRoad 2 reference
--                                  layout. The right card is "Modules" alone,
--                                  or - when a road picker is supplied -
--                                  Modules and "Created Roads" as two tabs
--                                  sharing the card, matching CS2's AVAILABLE
--                                  LANES / CREATED ROADS tab bar. Used by the
--                                  road library editor and the placed-road
--                                  inspector.
--
-- Presentation-only: everything operates on a RoadProfile via OnChange
-- (clone-and-transform), with the caller supplying action buttons.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local ProfileFields = require("./ProfileFields")
local Icons = require("./Icons")
local RoadThumbnail = require("./RoadThumbnail")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")

export type DesignerAction = {
	Text: string,
	Selected: boolean?,
	Danger: boolean?,
	OnClick: () -> (),
}

local STRIP_HEIGHT = 140
local TILE_WIDTH = 58

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

-- Number-key shortcuts for the selected lane's marking, so it can be set
-- without reaching for the dropdown (per the "Edit Lane Markings" ask -
-- Auto has no key since it's a fallback, not a marking to jump to).
local NUMBER_KEY_TO_BOUNDARY: { [Enum.KeyCode]: RoadProfile.BoundaryRule } = {
	[Enum.KeyCode.One] = "Solid" :: RoadProfile.BoundaryRule,
	[Enum.KeyCode.Two] = "DoubleSolid" :: RoadProfile.BoundaryRule,
	[Enum.KeyCode.Three] = "SolidDash" :: RoadProfile.BoundaryRule,
	[Enum.KeyCode.Four] = "DashSolid" :: RoadProfile.BoundaryRule,
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
	local scrollProps = Components.ScrollBar()
	scrollProps.Size = UDim2.new(0, width, 1, 0)
	scrollProps.BackgroundColor3 = Theme.GLASS_BG
	scrollProps.BackgroundTransparency = Theme.GLASS_TRANSPARENCY
	scrollProps.BorderSizePixel = 0
	scrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollProps.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollProps.ScrollingDirection = Enum.ScrollingDirection.Y
	scrollProps.LayoutOrder = layoutOrder
	return e("ScrollingFrame", scrollProps, children)
end

-- Road library list ----------------------------------------------------------------
-- A scrollable road picker (rendered cross-section thumbnail + name, click
-- to select) used instead of a plain dropdown, closer to CS2's "Created
-- Roads" library list.

export type LibraryOption = {
	Id: string,
	Text: string,
	Profile: RoadProfile.RoadProfile,
}

local THUMBNAIL_ROW_HEIGHT = 44

local function RoadLibraryRow(props: {
	Text: string,
	Selected: boolean,
	OnClick: () -> (),
	Thumbnail: {
		Profile: RoadProfile.RoadProfile,
		RegionStyle: RegionStyles.RegionStyle,
		Settings: Settings.EasyRoadSettings,
	}?,
	LayoutOrder: number,
})
	local hovered, setHovered = React.useState(false)
	local thumb = props.Thumbnail
	return e("TextButton", {
		Text = if thumb then "" else "  " .. props.Text,
		TextColor3 = Theme.WHITE,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		BackgroundColor3 = if props.Selected then Theme.SELECTED elseif hovered then Theme.BUTTON_HOVER else Theme.FIELD,
		BackgroundTransparency = if props.Selected then 0.1 else Theme.GLASS_ELEMENT_TRANSPARENCY,
		Size = UDim2.new(1, 0, 0, if thumb then THUMBNAIL_ROW_HEIGHT else Theme.ROW_HEIGHT),
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
		Layout = thumb and e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 6),
		}),
		Padding = thumb and e("UIPadding", {
			PaddingLeft = UDim.new(0, 4),
			PaddingRight = UDim.new(0, 4),
		}),
		Thumb = thumb and e(RoadThumbnail, {
			Profile = thumb.Profile,
			RegionStyle = thumb.RegionStyle,
			Settings = thumb.Settings,
			Size = UDim2.fromOffset(56, THUMBNAIL_ROW_HEIGHT - 8),
			LayoutOrder = 1,
		}),
		Label = thumb and e("TextLabel", {
			Text = props.Text,
			TextColor3 = Theme.WHITE,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -62, 1, 0),
			Font = Theme.FONT,
			TextSize = Theme.TEXT_SIZE,
			LayoutOrder = 2,
		}),
	})
end

local function RoadLibraryList(props: {
	Options: { LibraryOption },
	SelectedId: string?,
	OnPick: (id: string) -> (),
	OnNew: (() -> ())?,
	RegionStyle: RegionStyles.RegionStyle?,
	Settings: Settings.EasyRoadSettings?,
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
			Thumbnail = if props.RegionStyle and props.Settings
				then {
					Profile = option.Profile,
					RegionStyle = props.RegionStyle :: RegionStyles.RegionStyle,
					Settings = props.Settings :: Settings.EasyRoadSettings,
				}
				else nil,
			LayoutOrder = index,
		})
	end

	local listScrollProps = Components.ScrollBar()
	listScrollProps.Size = UDim2.new(1, 0, 0, props.Height or 140)
	listScrollProps.BackgroundColor3 = Theme.FIELD
	listScrollProps.BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY
	listScrollProps.BorderSizePixel = 0
	listScrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
	listScrollProps.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listScrollProps.ScrollingDirection = Enum.ScrollingDirection.Y
	listScrollProps.LayoutOrder = 1

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
		List = e("ScrollingFrame", listScrollProps, rows),
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
	Index: number,
	Selected: boolean,
	ReadOnly: boolean,
	OnClick: () -> (),
	OnHoverChanged: ((index: number, hovered: boolean) -> ())?,
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
		[React.Event.MouseEnter] = function()
			if props.OnHoverChanged then
				(props.OnHoverChanged :: (index: number, hovered: boolean) -> ())(props.Index, true)
			end
		end,
		[React.Event.MouseLeave] = function()
			if props.OnHoverChanged then
				(props.OnHoverChanged :: (index: number, hovered: boolean) -> ())(props.Index, false)
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
	OnTileHoverChanged: ((index: number, hovered: boolean) -> ())?,
	OnStripHoverChanged: ((hovered: boolean) -> ())?,
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

	-- Number keys 1-4 set the selected lane's right-side marking directly,
	-- matching the dropdown's options minus Auto - only live while a lane
	-- with a marking to set (not the last one) is selected.
	React.useEffect(function()
		if readOnly or not sel or (sel :: number) >= count then
			return nil
		end
		local cn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed then
				return
			end
			local rule = NUMBER_KEY_TO_BOUNDARY[input.KeyCode]
			if rule then
				changeSelected(function(component)
					return {
						Kind = component.Kind,
						WidthM = component.WidthM,
						Direction = component.Direction,
						RightBoundary = rule,
					}
				end)
			end
		end)
		return function()
			cn:Disconnect()
		end
	end, { sel, readOnly, count } :: { any })

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
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
		}),
	}
	for index, component in profile.Components do
		tiles["Tile" .. index] = e(LaneTile, {
			Component = component,
			Index = index,
			Selected = sel == index,
			ReadOnly = readOnly,
			OnClick = function()
				props.OnSelect(if props.SelectedIndex == index then 0 else index)
			end,
			OnHoverChanged = props.OnTileHoverChanged,
			LayoutOrder = index,
		})
	end
	local stripScrollProps = Components.ScrollBar()
	stripScrollProps.Size = UDim2.new(1, 0, 0, 78)
	stripScrollProps.BackgroundTransparency = 1
	stripScrollProps.BorderSizePixel = 0
	stripScrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
	stripScrollProps.AutomaticCanvasSize = Enum.AutomaticSize.X
	stripScrollProps.ScrollingDirection = Enum.ScrollingDirection.X -- Deliberate exception: this strip scrolls horizontally
	stripScrollProps.LayoutOrder = 2
	stripScrollProps[React.Event.MouseEnter] = function()
		if props.OnStripHoverChanged then
			(props.OnStripHoverChanged :: (hovered: boolean) -> ())(true)
		end
	end
	stripScrollProps[React.Event.MouseLeave] = function()
		if props.OnStripHoverChanged then
			(props.OnStripHoverChanged :: (hovered: boolean) -> ())(false)
		end
	end
	children.Strip = e("ScrollingFrame", stripScrollProps, tiles)

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
	OnDragStart: ((kind: RoadProfile.ComponentKind, label: string) -> ())?,
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
				(props.OnDragStart :: any)(props.Kind, props.Label)
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
-- Drag-and-drop controller ----------------------------------------------------------
-- Shared by Panel: press-and-drag a module tile past a small threshold to
-- pick it up (a plain click still inserts via OnInsert as before); dropping
-- over the lane strip inserts the module at the nearest tile position.
--
-- Drop resolution is done via plain MouseEnter/MouseLeave hover tracking on
-- the lane tiles and the strip itself (LaneStripCard's OnTileHoverChanged /
-- OnStripHoverChanged), not by hit-testing a screen coordinate - the
-- previous version tried both a manual AbsolutePosition/tile-width formula
-- and GuiService:GetGuiObjectsAtPosition, and neither reliably matched
-- what's actually on screen in Studio's plugin/edit-mode GUI context.
-- Hover events are the same mechanism every button's hover-highlight in
-- this UI already relies on, so they're known to work here.

type DragPayload = { Kind: RoadProfile.ComponentKind, Label: string }

-- Mouse tracking during drag uses plugin:GetMouse() polled on RenderStepped
-- rather than UserInputService - the latter is unreliable for tracking mouse
-- position/buttons over Studio's docked plugin GUIs in edit mode.
local function useLaneDrag(pluginObj: Plugin, onInsertAt: (index: number, kind: RoadProfile.ComponentKind) -> ())
	local dragging, setDragging = React.useState(nil :: DragPayload?)
	local dragPos, setDragPos = React.useState(Vector2.new(0, 0))
	local movedPastThreshold = React.useRef(false)
	local hoveredTile = React.useRef(0) -- 0 = no tile hovered
	local hoveredStrip = React.useRef(false)

	React.useEffect(function()
		if not dragging then
			return nil
		end
		movedPastThreshold.current = false
		local mouse = pluginObj:GetMouse()
		local startPos = Vector2.new(mouse.X, mouse.Y)

		local stepCn = RunService.RenderStepped:Connect(function()
			local pos = Vector2.new(mouse.X, mouse.Y)
			if (pos - startPos).Magnitude > 6 then
				movedPastThreshold.current = true
			end
			setDragPos(pos)
		end)

		local function finishDrag()
			if movedPastThreshold.current then
				local payload = dragging
				if payload then
					if hoveredTile.current > 0 then
						onInsertAt(hoveredTile.current, payload.Kind)
					elseif hoveredStrip.current then
						onInsertAt(math.huge, payload.Kind) -- Caller clamps to the end
					end
				end
			end
			setDragging(nil)
		end
		local upCn = mouse.Button1Up:Connect(finishDrag)

		return function()
			stepCn:Disconnect()
			upCn:Disconnect()
		end
	end, { dragging } :: { any })

	return {
		Dragging = if movedPastThreshold.current then dragging else nil,
		DragPos = dragPos,
		BeginDrag = function(kind: RoadProfile.ComponentKind, label: string)
			local mouse = pluginObj:GetMouse()
			setDragPos(Vector2.new(mouse.X, mouse.Y))
			setDragging({ Kind = kind, Label = label })
		end,
		OnTileHoverChanged = function(index: number, hovered: boolean)
			if hovered then
				hoveredTile.current = index
			elseif hoveredTile.current == index then
				hoveredTile.current = 0
			end
		end,
		OnStripHoverChanged = function(hovered: boolean)
			hoveredStrip.current = hovered
			if not hovered then
				hoveredTile.current = 0
			end
		end,
	}
end

-- Full designer panel ---------------------------------------------------------------

export type PanelPicker = {
	Options: { LibraryOption },
	SelectedId: string?,
	OnPick: (id: string) -> (),
	OnNew: (() -> ())?,
}

-- The right-hand card: Modules and (when a road picker is supplied) a
-- "Created Roads" library, as two tabs sharing one card - matching CS2's
-- AVAILABLE LANES / CREATED ROADS tab bar, instead of the road picker
-- living inside the Properties card.
local function PaletteOrLibraryCard(props: {
	Picker: PanelPicker?,
	RegionStyle: RegionStyles.RegionStyle,
	Settings: Settings.EasyRoadSettings,
	OnInsert: (kind: RoadProfile.ComponentKind) -> (),
	OnDragStart: ((kind: RoadProfile.ComponentKind, label: string) -> ())?,
	Width: number?,
	AlignRight: boolean?,
	LayoutOrder: number,
})
	local activeTab: "Modules" | "Library", setActiveTab = React.useState("Modules" :: "Modules" | "Library")

	local children: { [string]: any } = {}
	decorateCard(children)

	if props.Picker then
		children.Tabs = e(Components.Row, { LayoutOrder = 1 }, {
			ModulesTab = e(Components.Button, {
				Text = "Modules",
				Selected = activeTab == "Modules",
				OnClick = function()
					setActiveTab("Modules")
				end,
				LayoutOrder = 1,
				Grow = true,
			}),
			LibraryTab = e(Components.Button, {
				Text = "Created Roads",
				Selected = activeTab == "Library",
				OnClick = function()
					setActiveTab("Library")
				end,
				LayoutOrder = 2,
				Grow = true,
			}),
		})
	else
		children.Header = e(Components.Section, { Text = "Modules", LayoutOrder = 1 })
	end

	if activeTab == "Library" and props.Picker then
		local picker = props.Picker :: PanelPicker
		children.Library = e(RoadLibraryList, {
			Options = picker.Options,
			SelectedId = picker.SelectedId,
			OnPick = picker.OnPick,
			OnNew = picker.OnNew,
			RegionStyle = props.RegionStyle,
			Settings = props.Settings,
			Height = 170,
			LayoutOrder = 2,
		})
	else
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
		local gridScrollProps = Components.ScrollBar()
		gridScrollProps.Size = UDim2.new(1, 0, 1, -28)
		gridScrollProps.BackgroundTransparency = 1
		gridScrollProps.BorderSizePixel = 0
		gridScrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
		gridScrollProps.AutomaticCanvasSize = Enum.AutomaticSize.Y
		gridScrollProps.ScrollingDirection = Enum.ScrollingDirection.Y
		gridScrollProps.LayoutOrder = 2
		children.Grid = e("ScrollingFrame", gridScrollProps, grid)
	end

	local frameProps = cardProps()
	frameProps.Size = UDim2.new(0, props.Width or 220, 1, 0)
	frameProps.LayoutOrder = props.LayoutOrder
	if props.AlignRight then
		frameProps.AnchorPoint = Vector2.new(1, 0)
		frameProps.Position = UDim2.new(1, 0, 0, 0)
	end
	return e("Frame", frameProps, children)
end

local function Panel(props: {
	PluginObj: Plugin,
	Profile: RoadProfile.RoadProfile,
	RegionStyle: RegionStyles.RegionStyle,
	Settings: Settings.EasyRoadSettings,
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

	local drag = useLaneDrag(props.PluginObj, insertKind)

	-- Properties card
	local propertiesChildren: { [string]: any } = {}
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
		-- Properties pinned to the left edge, Modules/Library pinned to the
		-- right edge - independently anchored (no shared list layout) so the
		-- gap opens up in the middle instead of hugging the Properties card.
		Top = e("Frame", {
			Size = UDim2.new(1, 0, 1, -(STRIP_HEIGHT + 8)),
			BackgroundTransparency = 1,
			LayoutOrder = 1,
		}, {
			Properties = scrollColumn(240, 1, propertiesChildren),
			Palette = not readOnly and e(PaletteOrLibraryCard, {
				Picker = props.Picker,
				RegionStyle = props.RegionStyle,
				Settings = props.Settings,
				Width = 220,
				AlignRight = true,
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
			OnTileHoverChanged = drag.OnTileHoverChanged,
			OnStripHoverChanged = drag.OnStripHoverChanged,
			LayoutOrder = 2,
		}),
		Ghost = ghost,
	})
end

local RoadDesigner = {
	Panel = Panel,
	LaneStripCard = LaneStripCard,
	RoadLibraryList = RoadLibraryList,
	ScrollColumn = scrollColumn,
	DecorateCard = decorateCard,
	DefaultWidthFor = defaultWidthFor,
}

return RoadDesigner
