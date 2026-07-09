--!strict
-- Small shared React widgets for the EasyRoad UI: buttons, labeled rows,
-- number fields, checkboxes, dropdowns, and section headers.

local UserInputService = game:GetService("UserInputService")

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")

local Components = {}

-- Common cosmetic ScrollingFrame properties: a soft, low-contrast scrollbar
-- instead of a blunt fully-opaque one. Does NOT set ScrollingDirection or
-- CanvasSize - callers must still pick those explicitly (most should be
-- vertical-only with CanvasSize.X pinned to 0; the horizontal lane strip is
-- a deliberate exception). Merge into a ScrollingFrame's own prop table,
-- e.g. `local props = Components.ScrollBar(); props.Size = ...`.
function Components.ScrollBar(): { [string]: any }
	return {
		ScrollBarImageColor3 = Theme.SCROLLBAR_COLOR,
		ScrollBarImageTransparency = Theme.SCROLLBAR_TRANSPARENCY,
		ScrollBarThickness = Theme.SCROLLBAR_THICKNESS,
	}
end

-- Section header --------------------------------------------------------------

-- Extra breathing room above each section header (beyond the list's normal
-- row spacing) so a long field list actually reads as separate grouped
-- sections instead of one uninterrupted, cramped stack - plus a faint
-- divider line, matching the same treatment BuildBar uses between its tool
-- and library groups.
function Components.Section(props: {
	Text: string,
	LayoutOrder: number?,
	First: boolean?,
})
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, {
		Layout = e("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
		Divider = not props.First and e("Frame", {
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = Theme.GLASS_STROKE,
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
			LayoutOrder = 1,
		}),
		Label = e("TextLabel", {
			Text = string.upper(props.Text),
			TextColor3 = Theme.DIM,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 20),
			Font = Theme.FONT_BOLD,
			TextSize = Theme.HEADER_TEXT_SIZE,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = 2,
		}),
	})
end

-- Button ------------------------------------------------------------------------

function Components.Button(props: {
	Text: string,
	Icon: string?, -- When set, replaces the text with a centered icon image
	OnClick: () -> (),
	Selected: boolean?,
	Danger: boolean?,
	LayoutOrder: number?,
	Size: UDim2?,
	Grow: boolean?,
})
	local hovered, setHovered = React.useState(false)

	local color = Theme.BUTTON
	if props.Selected then
		color = if hovered then Theme.ACCENT_HOVER else Theme.SELECTED
	elseif props.Danger then
		color = if hovered then Theme.DANGER:Lerp(Theme.WHITE, 0.15) else Theme.DANGER
	elseif hovered then
		color = Theme.BUTTON_HOVER
	end

	-- Grow must win over auto-sizing-to-text: combining AutomaticSize.X with
	-- a UIFlexItem made the button report its full text width as its flex
	-- basis, so a row of Grow buttons with long labels ("Save as Copy",
	-- "Use as Template", ...) could still overflow a fixed-width column
	-- instead of actually sharing the row's available width.
	return e("TextButton", {
		Text = if props.Icon then "" else props.Text,
		TextColor3 = Theme.WHITE,
		BackgroundColor3 = color,
		BackgroundTransparency = if props.Selected or props.Danger then 0.1 else Theme.GLASS_ELEMENT_TRANSPARENCY,
		Size = props.Size or UDim2.new(0, 0, 0, Theme.ROW_HEIGHT),
		AutomaticSize = if props.Size or props.Grow then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		LayoutOrder = props.LayoutOrder,
		[React.Event.Activated] = function()
			props.OnClick()
		end,
		[React.Event.MouseEnter] = function()
			setHovered(true)
		end,
		[React.Event.MouseLeave] = function()
			setHovered(false)
		end,
	}, {
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
		}),
		Flex = props.Grow and e("UIFlexItem", {
			FlexMode = Enum.UIFlexMode.Grow,
		}),
		Icon = props.Icon and e("ImageLabel", {
			Image = props.Icon,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(0, 16, 0, 16),
			ScaleType = Enum.ScaleType.Fit,
		}),
	})
end

-- Horizontal row of children ------------------------------------------------------

function Components.Row(props: {
	LayoutOrder: number?,
	children: { [string]: any }?,
})
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
			VerticalAlignment = Enum.VerticalAlignment.Center,
		}),
	}
	if props.children then
		for key, child in props.children do
			children[key] = child
		end
	end
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, children)
end

-- Label ----------------------------------------------------------------------------

function Components.Label(props: {
	Text: string,
	LayoutOrder: number?,
	Dim: boolean?,
	Width: number?,
})
	return e("TextLabel", {
		Text = props.Text,
		TextColor3 = if props.Dim then Theme.DIM else Theme.OFFWHITE,
		BackgroundTransparency = 1,
		Size = if props.Width
			then UDim2.new(0, props.Width, 0, Theme.ROW_HEIGHT)
			else UDim2.new(0, 0, 0, Theme.ROW_HEIGHT),
		AutomaticSize = if props.Width then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		Font = Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = props.LayoutOrder,
	})
end

-- Number field -----------------------------------------------------------------------

function Components.NumberField(props: {
	Value: number,
	OnChanged: (value: number) -> (),
	LayoutOrder: number?,
	Width: number?,
	Min: number?,
	Max: number?,
})
	local displayText = string.format("%g", props.Value)

	return e("TextBox", {
		Text = displayText,
		TextColor3 = Theme.WHITE,
		BackgroundColor3 = Theme.FIELD,
		BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
		Size = UDim2.new(0, props.Width or 56, 0, Theme.ROW_HEIGHT),
		Font = Theme.FONT_MONO,
		TextSize = Theme.TEXT_SIZE,
		ClearTextOnFocus = false,
		LayoutOrder = props.LayoutOrder,
		[React.Event.FocusLost] = function(object: TextBox)
			local value = tonumber(object.Text)
			if value then
				if props.Min then
					value = math.max(value, props.Min)
				end
				if props.Max then
					value = math.min(value, props.Max)
				end
				props.OnChanged(value)
				object.Text = string.format("%g", value)
			else
				object.Text = displayText
			end
		end,
	}, {
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
	})
end

-- Text field -----------------------------------------------------------------------

function Components.TextField(props: {
	Value: string,
	OnChanged: (value: string) -> (),
	LayoutOrder: number?,
	Width: number?,
})
	return e("TextBox", {
		Text = props.Value,
		TextColor3 = Theme.WHITE,
		BackgroundColor3 = Theme.FIELD,
		BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
		Size = if props.Width then UDim2.new(0, props.Width, 0, Theme.ROW_HEIGHT) else UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		Font = Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ClearTextOnFocus = false,
		LayoutOrder = props.LayoutOrder,
		[React.Event.FocusLost] = function(object: TextBox)
			if object.Text ~= "" then
				props.OnChanged(object.Text)
			else
				object.Text = props.Value
			end
		end,
	}, {
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
	})
end

-- Colour field: a swatch preview plus one compact text field that accepts
-- either a hex code ("#RRGGBB" / "RRGGBB") or a Color3-style "r, g, b"
-- triplet (0-255 each) - much narrower than 3 separate R/G/B number fields,
-- which alone were wide enough to overflow a docked panel's minimum width.
-- Clicking the swatch expands a real gradient hue/saturation/value picker
-- (there's no Studio API to open the native color picker from a plugin -
-- devforum has been asking since ~2016 and it's never shipped - so this is
-- our own, built from Frames + UIGradient, no image asset needed) plus
-- R/G/B number fields for precise entry.

local function parseColorText(text: string): Color3?
	local hex = text:match("^#?(%x%x%x%x%x%x)$")
	if hex then
		local r = tonumber(hex:sub(1, 2), 16)
		local g = tonumber(hex:sub(3, 4), 16)
		local b = tonumber(hex:sub(5, 6), 16)
		if r and g and b then
			return Color3.fromRGB(r, g, b)
		end
	end
	local r, g, b = text:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
	if r then
		return Color3.fromRGB(
			math.clamp(tonumber(r) :: number, 0, 255),
			math.clamp(tonumber(g) :: number, 0, 255),
			math.clamp(tonumber(b) :: number, 0, 255)
		)
	end
	return nil
end

local function colorToHex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.round(color.R * 255),
		math.round(color.G * 255),
		math.round(color.B * 255)
	)
end

-- Saturation/value gradient square for a fixed hue: white->this hue left to
-- right (saturation), transparent->black top to bottom (value), stacked as
-- two UIGradient overlays over a plain hue-coloured background - the
-- standard way to build an HSV square out of plain Frames with no image
-- asset. Drag-to-pick via the frame's own InputBegan/InputChanged (so it
-- only continues tracking while the cursor stays over the square, no
-- global mouse capture - a deliberate simplification given this plugin
-- otherwise avoids 3D-viewport-style input capture for 2D UI).
local function SVSquare(props: {
	Hue: number,
	Saturation: number,
	Value: number,
	OnChanged: (saturation: number, value: number) -> (),
})
	local function updateFromInput(rbx: Frame, input: InputObject)
		local size = rbx.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then
			return
		end
		local pos = rbx.AbsolutePosition
		local s = math.clamp((input.Position.X - pos.X) / size.X, 0, 1)
		local v = 1 - math.clamp((input.Position.Y - pos.Y) / size.Y, 0, 1)
		props.OnChanged(s, v)
	end

	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 140),
		BackgroundColor3 = Color3.fromHSV(props.Hue, 1, 1),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		[React.Event.InputBegan] = function(rbx: Frame, input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				updateFromInput(rbx, input)
			end
		end,
		[React.Event.InputChanged] = function(rbx: Frame, input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseMovement
				and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
			then
				updateFromInput(rbx, input)
			end
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
		-- Two alpha-blended overlays stacked on the pure-hue background
		-- aren't order-independent (compositing white-then-black gives a
		-- different result than black-then-white at the same point), and
		-- these are sibling Frames with no LayoutOrder to lean on - their
		-- table keys are plain Lua hash keys, so relying on write order in
		-- the constructor isn't safe. Explicit ZIndex pins Value (black,
		-- must win at the bottom edge so it reads as true black regardless
		-- of how saturated that column is) above Saturation (white).
		Saturation = e("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.WHITE,
			BorderSizePixel = 0,
			ZIndex = 1,
		}, {
			Gradient = e("UIGradient", {
				Color = ColorSequence.new(Theme.WHITE),
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(1, 1),
				}),
			}),
		}),
		Value = e("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BorderSizePixel = 0,
			ZIndex = 2,
		}, {
			Gradient = e("UIGradient", {
				Color = ColorSequence.new(Color3.new(0, 0, 0)),
				Rotation = 90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(1, 0),
				}),
			}),
		}),
		Cursor = e("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(props.Saturation, 0, 1 - props.Value, 0),
			Size = UDim2.new(0, 10, 0, 10),
			BackgroundColor3 = Color3.fromHSV(props.Hue, props.Saturation, props.Value),
			BorderSizePixel = 0,
			ZIndex = 3,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(1, 0) }),
			Stroke = e("UIStroke", { Color = Theme.WHITE, Thickness = 2 }),
		}),
	})
end

-- Rainbow hue slider, same drag-within-bounds convention as SVSquare.
local HUE_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 1, 1)),
	ColorSequenceKeypoint.new(1 / 6, Color3.fromHSV(1 / 6, 1, 1)),
	ColorSequenceKeypoint.new(2 / 6, Color3.fromHSV(2 / 6, 1, 1)),
	ColorSequenceKeypoint.new(3 / 6, Color3.fromHSV(3 / 6, 1, 1)),
	ColorSequenceKeypoint.new(4 / 6, Color3.fromHSV(4 / 6, 1, 1)),
	ColorSequenceKeypoint.new(5 / 6, Color3.fromHSV(5 / 6, 1, 1)),
	ColorSequenceKeypoint.new(1, Color3.fromHSV(1, 1, 1)),
})

local function HueBar(props: {
	Hue: number,
	OnChanged: (hue: number) -> (),
})
	local function updateFromInput(rbx: Frame, input: InputObject)
		local size = rbx.AbsoluteSize
		if size.X <= 0 then
			return
		end
		local pos = rbx.AbsolutePosition
		props.OnChanged(math.clamp((input.Position.X - pos.X) / size.X, 0, 1))
	end

	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundColor3 = Theme.WHITE,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		[React.Event.InputBegan] = function(rbx: Frame, input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				updateFromInput(rbx, input)
			end
		end,
		[React.Event.InputChanged] = function(rbx: Frame, input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseMovement
				and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
			then
				updateFromInput(rbx, input)
			end
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
		Gradient = e("UIGradient", { Color = HUE_GRADIENT }),
		Cursor = e("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(props.Hue, 0, 0.5, 0),
			Size = UDim2.new(0, 4, 1, 4),
			BackgroundColor3 = Theme.WHITE,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, {
			Stroke = e("UIStroke", { Color = Color3.new(0, 0, 0), Transparency = 0.4, Thickness = 1 }),
		}),
	})
end

function Components.ColorField(props: {
	Value: Color3,
	OnChanged: (value: Color3) -> (),
	LayoutOrder: number?,
})
	local expanded, setExpanded = React.useState(false)
	local r = math.round(props.Value.R * 255)
	local g = math.round(props.Value.G * 255)
	local b = math.round(props.Value.B * 255)
	local hue, sat, val = props.Value:ToHSV()

	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, {
		Layout = e("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
		Main = e(Components.Row, { LayoutOrder = 1 }, {
			Swatch = e("TextButton", {
				Text = "",
				Size = UDim2.new(0, 22, 0, Theme.ROW_HEIGHT),
				BackgroundColor3 = props.Value,
				LayoutOrder = 1,
				[React.Event.Activated] = function()
					setExpanded(not expanded)
				end,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
				Stroke = e("UIStroke", {
					Color = Theme.GLASS_STROKE,
					Transparency = 0.6,
					Thickness = 1,
				}),
			}),
			Hex = e(Components.TextField, {
				Value = colorToHex(props.Value),
				Width = 90,
				LayoutOrder = 2,
				OnChanged = function(text: string)
					local color = parseColorText(text)
					if color then
						props.OnChanged(color)
					end
				end,
			}),
		}),
		Expanded = expanded and e("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 2,
		}, {
			Layout = e("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
			SV = e(SVSquare, {
				Hue = hue,
				Saturation = sat,
				Value = val,
				LayoutOrder = 1,
				OnChanged = function(newSat: number, newVal: number)
					props.OnChanged(Color3.fromHSV(hue, newSat, newVal))
				end,
			}),
			HueBar = e(HueBar, {
				Hue = hue,
				LayoutOrder = 2,
				OnChanged = function(newHue: number)
					props.OnChanged(Color3.fromHSV(newHue, sat, val))
				end,
			}),
			RGB = e(Components.Row, { LayoutOrder = 3 }, {
				R = e(Components.NumberField, {
					Value = r,
					Min = 0,
					Max = 255,
					Width = 44,
					LayoutOrder = 1,
					OnChanged = function(value: number)
						props.OnChanged(Color3.fromRGB(math.round(value), g, b))
					end,
				}),
				G = e(Components.NumberField, {
					Value = g,
					Min = 0,
					Max = 255,
					Width = 44,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						props.OnChanged(Color3.fromRGB(r, math.round(value), b))
					end,
				}),
				B = e(Components.NumberField, {
					Value = b,
					Min = 0,
					Max = 255,
					Width = 44,
					LayoutOrder = 3,
					OnChanged = function(value: number)
						props.OnChanged(Color3.fromRGB(r, g, math.round(value)))
					end,
				}),
			}),
		}),
	})
end

-- Checkbox ------------------------------------------------------------------------------

function Components.Checkbox(props: {
	Label: string,
	Checked: boolean,
	OnToggled: (checked: boolean) -> (),
	LayoutOrder: number?,
})
	return e("TextButton", {
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		LayoutOrder = props.LayoutOrder,
		[React.Event.Activated] = function()
			props.OnToggled(not props.Checked)
		end,
	}, {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
			VerticalAlignment = Enum.VerticalAlignment.Center,
		}),
		Box = e("Frame", {
			Size = UDim2.new(0, 16, 0, 16),
			BackgroundColor3 = if props.Checked then Theme.ACCENT else Theme.FIELD,
			LayoutOrder = 1,
		}, {
			Corner = e("UICorner", {
				CornerRadius = UDim.new(0, 3),
			}),
			Check = props.Checked and e("TextLabel", {
				Text = "✓",
				TextColor3 = Theme.WHITE,
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				Font = Theme.FONT_BOLD,
				TextSize = 14,
			}),
		}),
		Label = e("TextLabel", {
			Text = props.Label,
			TextColor3 = Theme.OFFWHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 0, 0, Theme.ROW_HEIGHT),
			AutomaticSize = Enum.AutomaticSize.X,
			Font = Theme.FONT,
			TextSize = Theme.TEXT_SIZE,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 2,
		}),
	})
end

-- Dropdown --------------------------------------------------------------------------------
-- A simple expanding dropdown. Options are {Id, Text} pairs.

export type DropdownOption = {
	Id: string,
	Text: string,
}

function Components.Dropdown(props: {
	Options: { DropdownOption },
	SelectedId: string?,
	OnSelected: (id: string) -> (),
	Placeholder: string?,
	LayoutOrder: number?,
	Grow: boolean?,
})
	local open, setOpen = React.useState(false)

	local selectedText = props.Placeholder or "Select..."
	for _, option in props.Options do
		if option.Id == props.SelectedId then
			selectedText = option.Text
			break
		end
	end

	local optionElements: { [string]: any } = {
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	if open then
		for index, option in props.Options do
			optionElements["Option" .. index] = e("TextButton", {
				Text = option.Text,
				TextColor3 = Theme.WHITE,
				BackgroundColor3 = if option.Id == props.SelectedId then Theme.SELECTED else Theme.PANEL,
				Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT - 4),
				Font = Theme.FONT,
				TextSize = Theme.TEXT_SIZE,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = index,
				ZIndex = 10,
				[React.Event.Activated] = function()
					setOpen(false)
					props.OnSelected(option.Id)
				end,
			}, {
				Padding = e("UIPadding", {
					PaddingLeft = UDim.new(0, 8),
				}),
			})
		end
	end

	return e("Frame", {
		Size = UDim2.new(if props.Grow then 1 else 0, if props.Grow then 0 else 140, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		ZIndex = if open then 10 else 1,
	}, {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Flex = props.Grow and e("UIFlexItem", {
			FlexMode = Enum.UIFlexMode.Grow,
		}),
		-- Chevron is a plain down arrow: Studio's SourceSans lacks the small
		-- triangle glyphs and renders them as tofu boxes.
		Header = e("TextButton", {
			Text = selectedText .. "  \u{2193}",
			TextColor3 = Theme.WHITE,
			BackgroundColor3 = Theme.FIELD,
			BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
			Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
			Font = Theme.FONT,
			TextSize = Theme.TEXT_SIZE,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = 1,
			[React.Event.Activated] = function()
				setOpen(not open)
			end,
		}, {
			Corner = e("UICorner", {
				CornerRadius = UDim.new(0, 4),
			}),
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
			}),
		}),
		Options = open and e("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = Theme.PANEL,
			LayoutOrder = 2,
			ZIndex = 10,
		}, optionElements),
	})
end

return Components
