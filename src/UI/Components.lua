--!strict
-- Small shared React widgets for the EasyRoad UI: buttons, labeled rows,
-- number fields, checkboxes, dropdowns, and section headers.

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

function Components.Section(props: {
	Text: string,
	LayoutOrder: number?,
})
	return e("TextLabel", {
		Text = string.upper(props.Text),
		TextColor3 = Theme.DIM,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		Font = Theme.FONT_BOLD,
		TextSize = Theme.HEADER_TEXT_SIZE,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = props.LayoutOrder,
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

-- Colour field: a swatch preview plus R/G/B (0-255) number fields - no
-- gesture-based hue/saturation picker, just reliable typed input.

function Components.ColorField(props: {
	Value: Color3,
	OnChanged: (value: Color3) -> (),
	LayoutOrder: number?,
})
	local r = math.round(props.Value.R * 255)
	local g = math.round(props.Value.G * 255)
	local b = math.round(props.Value.B * 255)

	return e(Components.Row, { LayoutOrder = props.LayoutOrder }, {
		Swatch = e("Frame", {
			Size = UDim2.new(0, 22, 0, Theme.ROW_HEIGHT),
			BackgroundColor3 = props.Value,
			LayoutOrder = 1,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
			Stroke = e("UIStroke", {
				Color = Theme.GLASS_STROKE,
				Transparency = 0.6,
				Thickness = 1,
			}),
		}),
		R = e(Components.NumberField, {
			Value = r,
			Min = 0,
			Max = 255,
			Width = 44,
			LayoutOrder = 2,
			OnChanged = function(value: number)
				props.OnChanged(Color3.fromRGB(math.round(value), g, b))
			end,
		}),
		G = e(Components.NumberField, {
			Value = g,
			Min = 0,
			Max = 255,
			Width = 44,
			LayoutOrder = 3,
			OnChanged = function(value: number)
				props.OnChanged(Color3.fromRGB(r, math.round(value), b))
			end,
		}),
		B = e(Components.NumberField, {
			Value = b,
			Min = 0,
			Max = 255,
			Width = 44,
			LayoutOrder = 4,
			OnChanged = function(value: number)
				props.OnChanged(Color3.fromRGB(r, g, math.round(value)))
			end,
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
