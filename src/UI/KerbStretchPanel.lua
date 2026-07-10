--!strict
-- Small HUD shown after dragging out a kerb-stretch range: adjust the
-- station range (studs, from the drag) and the override restriction before
-- committing. Confirm/Cancel live on the pie menu above this, not here -
-- same convention as MarkingStretchPanel/BayDraftPanel.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RoadDesigner = require("./RoadDesigner")

local RESTRICTION_OPTIONS = {
	{ Id = "None", Text = "No restriction" },
	{ Id = "SingleYellow", Text = "Single yellow (no parking)" },
	{ Id = "DoubleYellow", Text = "Double yellow (no parking)" },
	{ Id = "NoLine", Text = "No line at all" },
}

local function KerbStretchPanel(props: {
	FromStationStuds: number,
	ToStationStuds: number,
	Restriction: string,
	OnFromChanged: (value: number) -> (),
	OnToChanged: (value: number) -> (),
	OnRestrictionChanged: (id: string) -> (),
})
	local children: { [string]: any } = {}
	RoadDesigner.DecorateCard(children)
	children.Header = e(Components.Section, { Text = "Stretch Kerb Marking", First = true, LayoutOrder = 1 })
	children.From = e(Components.Row, { LayoutOrder = 2 }, {
		Label = e(Components.Label, { Text = "From", LayoutOrder = 1, Width = 60 }),
		Field = e(Components.NumberField, {
			Value = props.FromStationStuds,
			Min = 0,
			OnChanged = props.OnFromChanged,
			LayoutOrder = 2,
		}),
		Unit = e(Components.Label, { Text = "studs", Dim = true, LayoutOrder = 3 }),
	})
	children.To = e(Components.Row, { LayoutOrder = 3 }, {
		Label = e(Components.Label, { Text = "To", LayoutOrder = 1, Width = 60 }),
		Field = e(Components.NumberField, {
			Value = props.ToStationStuds,
			Min = 0,
			OnChanged = props.OnToChanged,
			LayoutOrder = 2,
		}),
		Unit = e(Components.Label, { Text = "studs", Dim = true, LayoutOrder = 3 }),
	})
	children.Restriction = e(Components.Row, { LayoutOrder = 4 }, {
		Label = e(Components.Label, { Text = "Restriction", LayoutOrder = 1, Width = 78 }),
		Field = e(Components.Dropdown, {
			Options = RESTRICTION_OPTIONS,
			SelectedId = props.Restriction,
			OnSelected = props.OnRestrictionChanged,
			LayoutOrder = 2,
			Grow = true,
		}),
	})
	children.Hint = e(Components.Label, {
		Text = "Overrides this kerb line only. Apply Stretch above to accept.",
		Dim = true,
		LayoutOrder = 5,
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

return KerbStretchPanel
