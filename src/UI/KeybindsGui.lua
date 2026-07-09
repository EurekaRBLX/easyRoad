--!strict
-- Keybinds: live "click + Add binding, then act in the 3D viewport" rebind
-- UI, plus per-action remove buttons.
--
-- Earlier rounds tried capturing the very next InputBegan the instant "Add
-- binding" was clicked, reasoning that's equivalent to a normal key-capture
-- field - but a DockWidgetPluginGui is a genuinely separate native window,
-- and while it has focus, input doesn't reliably reach UserInputService at
-- all (a documented Studio platform limitation, confirmed across several
-- rounds of this exact bug recurring). Capture now happens in `main.lua`
-- (the only place that can hold a persistent UserInputService connection
-- independent of this panel's own lifetime) and is gated on
-- `UserInputService.WindowFocused` firing first - i.e. the user must
-- actually click (or otherwise refocus) into the 3D viewport before the
-- NEXT input is treated as the binding, so the refocusing click itself
-- doesn't get bound as "MouseButton1" by accident. This panel is purely
-- presentational: it shows current bindings, an Add/Cancel button per
-- action, and a small hint once capture is armed/listening.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local KeybindsModule = require("../Keybinds")

local function BindingChip(props: {
	Text: string,
	OnRemove: (() -> ())?,
	LayoutOrder: number,
})
	return e("Frame", {
		BackgroundColor3 = Theme.FIELD,
		BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
		Size = UDim2.new(0, 0, 0, Theme.ROW_HEIGHT - 4),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = props.LayoutOrder,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 4),
		}),
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 2),
		}),
		Label = e("TextLabel", {
			Text = props.Text,
			TextColor3 = Theme.OFFWHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			Font = Theme.FONT,
			TextSize = Theme.TEXT_SIZE,
			LayoutOrder = 1,
		}),
		Remove = props.OnRemove and e("TextButton", {
			Text = "\u{2715}",
			TextColor3 = Theme.DIM,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 18, 1, 0),
			Font = Theme.FONT,
			TextSize = 12,
			LayoutOrder = 2,
			[React.Event.Activated] = props.OnRemove,
		}),
	})
end

local function ActionRow(props: {
	ActionId: string,
	Label: string,
	Bindings: { string },
	Capturing: boolean,
	CapturingReady: boolean,
	OnStartCapture: () -> (),
	OnCancelCapture: () -> (),
	OnRemoveBinding: (index: number) -> (),
	LayoutOrder: number,
})
	local chips: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
			VerticalAlignment = Enum.VerticalAlignment.Center,
		}),
	}
	for index, bound in props.Bindings do
		chips["Chip" .. index] = e(BindingChip, {
			Text = KeybindsModule.Describe(bound),
			-- Always leave at least one binding so the action never becomes
			-- completely unreachable from within this panel.
			OnRemove = if #props.Bindings > 1
				then function()
					props.OnRemoveBinding(index)
				end
				else nil,
			LayoutOrder = index,
		})
	end
	chips["Add"] = e(Components.Button, {
		Text = if props.Capturing then "Cancel" else "+ Add",
		Danger = props.Capturing,
		OnClick = if props.Capturing then props.OnCancelCapture else props.OnStartCapture,
		LayoutOrder = #props.Bindings + 1,
	})

	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 2),
		}),
		Header = e(Components.Row, { LayoutOrder = 1 }, {
			Label = e(Components.Label, { Text = props.Label, LayoutOrder = 1, Width = 130 }),
			Chips = e("Frame", {
				Size = UDim2.new(1, -134, 0, Theme.ROW_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 2,
			}, chips),
		}),
	}
	if props.Capturing then
		children.Hint = e(Components.Label, {
			Text = if props.CapturingReady
				then "Listening - press a key or click a mouse button in the 3D viewport..."
				else "Click anywhere in the 3D viewport to begin...",
			Dim = true,
			LayoutOrder = 2,
		})
	end

	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, children)
end

local function KeybindsGui(props: {
	Keybinds: KeybindsModule.KeybindMap,
	CapturingAction: string?,
	CapturingReady: boolean,
	OnStartCapture: (actionId: string) -> (),
	OnCancelCapture: () -> (),
	OnRemoveBinding: (actionId: string, index: number) -> (),
	OnClose: () -> (),
})
	local children: { [string]: any } = {}
	children.Section = e(Components.Section, { Text = "Keybinds", First = true, LayoutOrder = 1 })
	children.Hint = e(Components.Label, {
		Text = "Click Add, then click or press a key in the 3D viewport to bind it.",
		Dim = true,
		LayoutOrder = 2,
	})

	local order = 3
	for _, action in KeybindsModule.Actions do
		children["Row" .. order] = e(ActionRow, {
			ActionId = action.Id,
			Label = action.Label,
			Bindings = props.Keybinds[action.Id] or KeybindsModule.Defaults[action.Id],
			Capturing = props.CapturingAction == action.Id,
			CapturingReady = props.CapturingReady,
			OnStartCapture = function()
				props.OnStartCapture(action.Id)
			end,
			OnCancelCapture = props.OnCancelCapture,
			OnRemoveBinding = function(index: number)
				props.OnRemoveBinding(action.Id, index)
			end,
			LayoutOrder = order,
		})
		order += 1
	end

	children.Close = e(Components.Button, {
		Text = "Close",
		OnClick = props.OnClose,
		LayoutOrder = 100,
	})

	local scrollProps = Components.ScrollBar()
	scrollProps.Size = UDim2.fromScale(1, 1)
	scrollProps.BackgroundColor3 = Theme.PANEL
	scrollProps.BorderSizePixel = 0
	scrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollProps.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollProps.ScrollingDirection = Enum.ScrollingDirection.Y

	children.Layout = e("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 8),
	})
	children.Padding = e("UIPadding", {
		PaddingLeft = UDim.new(0, Theme.PADDING + 5),
		PaddingRight = UDim.new(0, Theme.PADDING + 5),
		PaddingTop = UDim.new(0, Theme.PADDING + 5),
		PaddingBottom = UDim.new(0, Theme.PADDING + 5),
	})

	return e("ScrollingFrame", scrollProps, children)
end

return KeybindsGui
