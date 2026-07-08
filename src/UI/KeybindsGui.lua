--!strict
-- Keybinds: read-only reference for the plugin's few hardcoded default
-- shortcuts, plus how to add or change one.
--
-- This used to be a live "click + Add binding, then press a key" capture
-- UI, but that can't work reliably from inside a docked plugin panel:
-- UserInputService is scoped to the main 3D viewport, and a
-- DockWidgetPluginGui is a genuinely separate native window - once it has
-- focus, further input doesn't reliably reach UserInputService at all
-- (a documented Roblox Studio platform limitation, confirmed across
-- several rounds of this exact bug recurring). The defaults below still
-- work out of the box with zero setup (each session's own live listener
-- matches them directly, unaffected by this since it only matters while
-- the 3D viewport itself has focus, during active placement). Rebinding
-- now goes through Studio's own native, reliable mechanism instead:
-- PluginAction + Customize Shortcuts.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local KeybindsModule = require("../Keybinds")

local ACTION_NAMES: { [string]: string } = {
	ElevationUp = "easyRoad: Raise Elevation",
	ElevationDown = "easyRoad: Lower Elevation",
	CancelPlacement = "easyRoad: Cancel Placement",
}

local function DefaultRow(props: {
	Label: string,
	Bindings: { string },
	LayoutOrder: number,
})
	local described = {}
	for _, bound in props.Bindings do
		table.insert(described, KeybindsModule.Describe(bound))
	end
	return e(Components.Row, { LayoutOrder = props.LayoutOrder }, {
		Label = e(Components.Label, { Text = props.Label, LayoutOrder = 1, Width = 140 }),
		Value = e(Components.Label, { Text = table.concat(described, " / "), Dim = true, LayoutOrder = 2 }),
	})
end

local function KeybindsGui(props: {
	OnClose: () -> (),
})
	local children: { [string]: any } = {}
	children.Section = e(Components.Section, { Text = "Keybinds", First = true, LayoutOrder = 1 })

	local order = 2
	for _, action in KeybindsModule.Actions do
		children["Row" .. order] = e(DefaultRow, {
			Label = action.Label,
			Bindings = KeybindsModule.Defaults[action.Id],
			LayoutOrder = order,
		})
		order += 1
	end

	children["Note" .. order] = e(Components.Label, {
		Text = "These defaults always work, no setup needed. To add or change a shortcut, use Studio's own "
			.. "Customize Shortcuts (right-click any toolbar button, or File > Advanced > Customize Shortcuts) "
			.. "and search for one of these action names:",
		Dim = true,
		LayoutOrder = order,
	})
	order += 1

	for _, action in KeybindsModule.Actions do
		local name = ACTION_NAMES[action.Id]
		if name then
			children["ActionName" .. order] = e(Components.Label, {
				Text = "\u{2022} " .. name,
				LayoutOrder = order,
			})
			order += 1
		end
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
		Padding = UDim.new(0, 4),
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
