--!strict
-- Keybinds: live "click + Add binding, then act in the 3D viewport" rebind
-- UI - each action as its own labeled list of bindings (one per row, a
-- Remove button on the right), not chips crammed onto one horizontal row -
-- the previous chips-in-a-row layout overflowed the docked panel's width
-- the moment an action had 2+ bindings with longer names ("Right Click",
-- "Middle Click").
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

local function BindingRow(props: {
	Text: string,
	OnRemove: (() -> ())?,
	LayoutOrder: number,
})
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, {
		Label = e("TextLabel", {
			Text = props.Text,
			TextColor3 = Theme.OFFWHITE,
			TextXAlignment = Enum.TextXAlignment.Left,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, if props.OnRemove then -78 else 0, 1, 0),
			Font = Theme.FONT,
			TextSize = Theme.TEXT_SIZE,
		}),
		Remove = props.OnRemove and e(Components.Button, {
			Text = "Remove",
			Danger = true,
			Size = UDim2.new(0, 74, 0, Theme.ROW_HEIGHT),
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			OnClick = props.OnRemove,
		}),
	})
end

local function ActionGroup(props: {
	ActionId: string,
	Label: string,
	Bindings: { string },
	First: boolean,
	Capturing: boolean,
	CapturingReady: boolean,
	OnStartCapture: () -> (),
	OnCancelCapture: () -> (),
	OnRemoveBinding: (index: number) -> (),
	LayoutOrder: number,
})
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 2),
		}),
		Header = e(Components.Section, { Text = props.Label, First = props.First, LayoutOrder = 1 }),
	}

	local order = 2
	for index, bound in props.Bindings do
		children["Binding" .. index] = e(BindingRow, {
			Text = KeybindsModule.Describe(bound),
			-- Always leave at least one binding so the action never becomes
			-- completely unreachable from within this panel.
			OnRemove = if #props.Bindings > 1
				then function()
					props.OnRemoveBinding(index)
				end
				else nil,
			LayoutOrder = order,
		})
		order += 1
	end

	children["Add"] = e(Components.Button, {
		Text = if props.Capturing then "Cancel" else "+ Add binding",
		Danger = props.Capturing,
		Size = UDim2.new(0, 130, 0, Theme.ROW_HEIGHT),
		OnClick = if props.Capturing then props.OnCancelCapture else props.OnStartCapture,
		LayoutOrder = order,
	})
	order += 1

	if props.Capturing then
		children["Hint"] = e(Components.Label, {
			Text = if props.CapturingReady
				then "Listening - press a key or click a mouse button in the 3D viewport..."
				else "Click anywhere in the 3D viewport to begin...",
			Dim = true,
			LayoutOrder = order,
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
	children.Hint = e(Components.Label, {
		Text = "Click Add, then click or press a key in the 3D viewport to bind it.",
		Dim = true,
		LayoutOrder = 1,
	})

	local order = 2
	for _, action in KeybindsModule.Actions do
		children["Group" .. order] = e(ActionGroup, {
			ActionId = action.Id,
			Label = action.Label,
			Bindings = props.Keybinds[action.Id] or KeybindsModule.Defaults[action.Id],
			First = order == 2,
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
