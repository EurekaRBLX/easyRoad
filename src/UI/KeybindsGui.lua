--!strict
-- Keybinds: two separate, honest mechanisms, not one unified illusion.
--
-- KEYBOARD shortcuts go through Studio's own PluginAction + Customize
-- Shortcuts dialog (main.lua registers one PluginAction per action below) -
-- confirmed via live testing that this in-plugin panel receiving a keyboard
-- press reliably "does not work other than mouse click in the viewport."
-- Studio's own shortcut system doesn't route through UserInputService
-- inside a plugin GUI at all, which is exactly why it's reliable where a
-- custom capture listener here isn't. This panel can't display what key the
-- user assigned there either (no API to query a PluginAction's assigned
-- shortcut from a plugin), so it just names the action to search for.
--
-- MOUSE-BUTTON bindings (e.g. an extra cancel-placement button) CAN be
-- captured live from here, since `main.lua`'s InputBegan listener - gated on
-- `UserInputService.WindowFocused` firing first, so the click that refocuses
-- into the 3D viewport isn't itself bound - only ever receives mouse clicks
-- reliably. Each action's current bindings (built-in keyboard defaults that
-- work out of the box with zero setup, plus whatever mouse buttons have been
-- added) are listed with a Remove button; "+ Add mouse binding" arms
-- capture for a new one.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local KeybindsModule = require("../Keybinds")

-- PluginAction names registered in main.lua, matching KeybindsModule.Actions
-- 1:1 - shown so the user knows what to search for in Studio's Customize
-- Shortcuts dialog (File > Advanced > Customize Shortcuts, or right-click
-- any toolbar button) to change a KEYBOARD shortcut.
local ACTION_NAMES: { [string]: string } = {
	ElevationUp = "easyRoad: Raise Elevation",
	ElevationDown = "easyRoad: Lower Elevation",
	CancelPlacement = "easyRoad: Cancel Placement",
}

local function BindingRow(props: {
	Text: string,
	OnRemove: (() -> ())?,
	LayoutOrder: number,
})
	-- Components.Button only reads a fixed set of known props (Text, Icon,
	-- OnClick, Selected, Danger, LayoutOrder, Size, Grow) - it builds its
	-- own TextButton prop table rather than spreading arbitrary props
	-- through, so passing AnchorPoint/Position to it (an earlier version of
	-- this row did, to right-anchor Remove) is silently a no-op. Both ended
	-- up at the same default (0,0,0,0) position, stacking Remove directly
	-- on top of the label text instead of beside it. Using Components.Row's
	-- UIListLayout instead - the same left-to-right flow every other button
	-- row in this UI already uses - makes overlap impossible by
	-- construction.
	return e(Components.Row, { LayoutOrder = props.LayoutOrder }, {
		Label = e(Components.Label, { Text = props.Text, LayoutOrder = 1 }),
		Remove = props.OnRemove and e(Components.Button, {
			Text = "Remove",
			Danger = true,
			Size = UDim2.new(0, 74, 0, Theme.ROW_HEIGHT),
			LayoutOrder = 2,
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
		Text = if props.Capturing then "Cancel" else "+ Add mouse binding",
		Danger = props.Capturing,
		Size = UDim2.new(0, 150, 0, Theme.ROW_HEIGHT),
		OnClick = if props.Capturing then props.OnCancelCapture else props.OnStartCapture,
		LayoutOrder = order,
	})
	order += 1

	if props.Capturing then
		children["Hint"] = e(Components.Label, {
			Text = if props.CapturingReady
				then "Listening - click a mouse button in the 3D viewport..."
				else "Click anywhere in the 3D viewport to begin...",
			Dim = true,
			LayoutOrder = order,
		})
		order += 1
	end

	local actionName = ACTION_NAMES[props.ActionId]
	if actionName then
		children["KeyNote"] = e(Components.Label, {
			Text = "Keyboard shortcut: Studio's Customize Shortcuts, search \"" .. actionName .. '"',
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
		Text = "Mouse-button bindings can be added below. For keyboard shortcuts, use Studio's own "
			.. "Customize Shortcuts (right-click any toolbar button, or File > Advanced > Customize Shortcuts).",
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
