--!strict
-- Small HUD shown when a placed JunctionNode is selected (Studio's ordinary
-- Selection, same convention as RoadInspector for a selected road): how
-- many roads meet here, and a way to remove the junction itself (which
-- just unlinks the roads - see JunctionEditSession.DeleteJunction - not
-- delete them).

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RoadDesigner = require("./RoadDesigner")

local function JunctionPanel(props: {
	ConnectedRoadCount: number,
	OnDelete: () -> (),
})
	local children: { [string]: any } = {}
	RoadDesigner.DecorateCard(children)
	children.Header = e(Components.Section, { Text = "Junction", First = true, LayoutOrder = 1 })
	children.Info = e(Components.Label, {
		Text = string.format(
			"%d road%s connected",
			props.ConnectedRoadCount,
			if props.ConnectedRoadCount == 1 then "" else "s"
		),
		Dim = true,
		LayoutOrder = 2,
	})
	children.Delete = e(Components.Button, {
		Text = "Delete Junction",
		Danger = true,
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		LayoutOrder = 3,
		OnClick = props.OnDelete,
	})
	children.Hint = e(Components.Label, {
		Text = "Unlinks the roads meeting here - doesn't delete them.",
		Dim = true,
		LayoutOrder = 4,
	})

	local scrollProps = Components.ScrollBar()
	scrollProps.Size = UDim2.fromScale(1, 1)
	scrollProps.BackgroundColor3 = Theme.GLASS_BG
	scrollProps.BackgroundTransparency = Theme.GLASS_TRANSPARENCY
	scrollProps.BorderSizePixel = 0
	scrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollProps.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollProps.ScrollingDirection = Enum.ScrollingDirection.Y

	return e("ScrollingFrame", scrollProps, children)
end

return JunctionPanel
