--!strict
-- Small HUD shown after clicking a point on a road to place a bus bay:
-- adjust the bay's length/width (defaults: a standard dwell length, one
-- lane's width) before committing. Confirm/Cancel live on the pie menu
-- above this, not here.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RoadDesigner = require("./RoadDesigner")

local function BayDraftPanel(props: {
	LengthStuds: number,
	WidthM: number,
	OnLengthChanged: (value: number) -> (),
	OnWidthChanged: (value: number) -> (),
})
	local children: { [string]: any } = {}
	RoadDesigner.DecorateCard(children)
	children.Header = e(Components.Section, { Text = "Bus Bay", First = true, LayoutOrder = 1 })
	children.Length = e(Components.Row, { LayoutOrder = 2 }, {
		Label = e(Components.Label, { Text = "Length", LayoutOrder = 1, Width = 60 }),
		Field = e(Components.NumberField, {
			Value = props.LengthStuds,
			Min = 1,
			OnChanged = props.OnLengthChanged,
			LayoutOrder = 2,
		}),
		Unit = e(Components.Label, { Text = "studs", Dim = true, LayoutOrder = 3 }),
	})
	children.Width = e(Components.Row, { LayoutOrder = 3 }, {
		Label = e(Components.Label, { Text = "Width", LayoutOrder = 1, Width = 60 }),
		Field = e(Components.NumberField, {
			Value = props.WidthM,
			Min = 0.5,
			OnChanged = props.OnWidthChanged,
			LayoutOrder = 2,
		}),
		Unit = e(Components.Label, { Text = "meters", Dim = true, LayoutOrder = 3 }),
	})
	children.Hint = e(Components.Label, {
		Text = "From your drag - fine-tune here, or Add Bay above to accept as-is.",
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

return BayDraftPanel
