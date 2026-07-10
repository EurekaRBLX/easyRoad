--!strict
-- Keybinds: keyboard shortcuts for the plugin's actions.
--
-- The built-in defaults below always work with zero setup (each session's
-- own live listener matches them while the 3D viewport has focus, which is
-- the only time they're relevant). Custom KEYBOARD shortcuts go through
-- Studio's own PluginAction system - `main.lua` registers one PluginAction
-- per action, and Studio's native Customize Shortcuts dialog assigns keys
-- to them reliably regardless of focus, because it's Studio's own shortcut
-- system rather than anything built on UserInputService inside a plugin
-- GUI. Confirmed live: input capture from inside this plugin "does not
-- work other than mouse click in the viewport," so an in-panel
-- press-a-key-to-bind flow is a dead end by platform limitation (four
-- attempts across this project's history, including a WindowFocused-gated
-- one, all hit the same wall). There's also no API to QUERY what shortcut
-- the user assigned to a PluginAction, so this panel lists the action
-- names to search for rather than pretending to show live values.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local KeybindsModule = require("../Keybinds")

-- PluginAction names registered in main.lua, matching KeybindsModule.Actions
-- 1:1 - what to search for in Studio's Customize Shortcuts dialog.
local ACTION_NAMES: { [string]: string } = {
	ElevationUp = "easyRoad: Raise Elevation",
	ElevationDown = "easyRoad: Lower Elevation",
	CancelPlacement = "easyRoad: Cancel Placement",
}

local function ActionGroup(props: {
	ActionId: string,
	Label: string,
	Bindings: { string },
	First: boolean,
	LayoutOrder: number,
})
	local described = {}
	for _, bound in props.Bindings do
		table.insert(described, KeybindsModule.Describe(bound))
	end
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 2),
		}),
		Header = e(Components.Section, { Text = props.Label, First = props.First, LayoutOrder = 1 }),
		Defaults = e(Components.Row, { LayoutOrder = 2 }, {
			Label = e(Components.Label, { Text = "Built-in", LayoutOrder = 1, Width = 90 }),
			Value = e(Components.Label, { Text = table.concat(described, " / "), LayoutOrder = 2 }),
		}),
	}
	local actionName = ACTION_NAMES[props.ActionId]
	if actionName then
		children.ActionName = e(Components.Row, { LayoutOrder = 3 }, {
			Label = e(Components.Label, { Text = "Rebindable as", Dim = true, LayoutOrder = 1, Width = 90 }),
			Value = e(Components.Label, { Text = actionName, Dim = true, LayoutOrder = 2 }),
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
	OnClose: () -> (),
})
	local children: { [string]: any } = {}
	children.Hint = e(Components.Label, {
		Text = "The built-in keys always work during placement. To add or change a keyboard shortcut, use "
			.. "Studio's Customize Shortcuts (right-click any toolbar button, or File > Advanced > "
			.. "Customize Shortcuts) and search for the action names below.",
		Dim = true,
		LayoutOrder = 1,
	})

	local order = 2
	for _, action in KeybindsModule.Actions do
		children["Group" .. order] = e(ActionGroup, {
			ActionId = action.Id,
			Label = action.Label,
			Bindings = KeybindsModule.Defaults[action.Id],
			First = order == 2,
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
