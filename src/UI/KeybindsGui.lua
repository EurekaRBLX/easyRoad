--!strict
-- Keybinds: rebindable inputs, docked on its own. Each action can have
-- multiple bound inputs; "+" starts listening for the next key/click to
-- add, each bound input has its own "-" to remove it.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local KeybindsModule = require("../Keybinds")
local Settings = require("../Settings")

local function BindingRow(props: {
	Label: string,
	OnRemove: () -> (),
	LayoutOrder: number,
})
	return e(Components.Row, { LayoutOrder = props.LayoutOrder }, {
		Label = e(Components.Label, { Text = props.Label, LayoutOrder = 1, Width = 140 }),
		Remove = e(Components.Button, {
			Text = "-",
			Danger = true,
			OnClick = props.OnRemove,
			LayoutOrder = 2,
			Size = UDim2.new(0, 26, 0, Theme.ROW_HEIGHT),
		}),
	})
end

local function ActionSection(props: {
	Label: string,
	Bindings: { string },
	Capturing: boolean,
	OnAdd: () -> (),
	OnRemove: (label: string) -> (),
	StartOrder: number,
})
	local order = props.StartOrder
	local children: { [string]: any } = {}

	children["Header" .. order] = e(Components.Label, {
		Text = props.Label,
		LayoutOrder = order,
	})
	order += 1

	for _, label in props.Bindings do
		children["Bind" .. order] = e(BindingRow, {
			Label = KeybindsModule.Describe(label),
			OnRemove = function()
				props.OnRemove(label)
			end,
			LayoutOrder = order,
		})
		order += 1
	end

	children["Add" .. order] = e(Components.Button, {
		Text = if props.Capturing then "Press a key or click..." else "+ Add binding",
		Selected = props.Capturing,
		OnClick = props.OnAdd,
		LayoutOrder = order,
	})
	order += 1

	return children, order
end

local function KeybindsGui(props: {
	Settings: Settings.EasyRoadSettings,
	OnSettingsChanged: () -> (),
	OnCapture: (actionId: string, onCaptured: (label: string) -> ()) -> (),
	OnClose: () -> (),
})
	local capturingAction, setCapturingAction = React.useState(nil :: string?)

	local function addBinding(actionId: string)
		setCapturingAction(actionId)
		props.OnCapture(actionId, function(label: string)
			setCapturingAction(nil)
			local bindings = props.Settings.Keybinds[actionId]
			if not table.find(bindings, label) then
				table.insert(bindings, label)
			end
			props.OnSettingsChanged()
		end)
	end

	local function removeBinding(actionId: string, label: string)
		local bindings = props.Settings.Keybinds[actionId]
		local index = table.find(bindings, label)
		if index then
			table.remove(bindings, index)
		end
		props.OnSettingsChanged()
	end

	local children: { [string]: any } = {}
	children.Section = e(Components.Section, { Text = "Keybinds", First = true, LayoutOrder = 1 })
	local order = 2
	for _, action in KeybindsModule.Actions do
		local sectionChildren, nextOrder = ActionSection({
			Label = action.Label,
			Bindings = props.Settings.Keybinds[action.Id],
			Capturing = capturingAction == action.Id,
			OnAdd = function()
				addBinding(action.Id)
			end,
			OnRemove = function(label: string)
				removeBinding(action.Id, label)
			end,
			StartOrder = order,
		})
		for key, child in sectionChildren do
			children[key] = child
		end
		order = nextOrder
	end
	children.Note = e(Components.Label, {
		Text = "Right-click isn't a Cancel Placement default since it also orbits the camera in Studio - add it "
			.. "manually with + if you'd still like it.",
		Dim = true,
		LayoutOrder = order,
	})
	order += 1
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
