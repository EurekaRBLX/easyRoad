--!strict
-- Small HUD shown after dragging out a marking-stretch range: adjust the
-- station range (studs, from the drag) and the override line type before
-- committing. Confirm/Cancel live on the pie menu above this, not here -
-- same convention as BayDraftPanel.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RoadDesigner = require("./RoadDesigner")
local Settings = require("../Settings")
local Units = require("../Units")

local LINE_OPTIONS = {
	{ Id = "Solid", Text = "Solid" },
	{ Id = "DoubleSolid", Text = "Double solid" },
	{ Id = "Dashed", Text = "Dashed" },
	{ Id = "DoubleDashed", Text = "Double dashed" },
	{ Id = "SolidDash", Text = "Solid / dash" },
	{ Id = "DashSolid", Text = "Dash / solid" },
}

-- Line types with an actual dashed component - only these make the Dash
-- length/gap fields below meaningful (a value stored on the other types
-- is simply never read by Markings.lua's renderer).
local LINE_HAS_DASH: { [string]: boolean } = {
	Dashed = true,
	DoubleDashed = true,
	SolidDash = true,
	DashSolid = true,
}

local function MarkingStretchPanel(props: {
	Settings: Settings.EasyRoadSettings,
	FromStationStuds: number,
	ToStationStuds: number,
	Line: string,
	DashLengthM: number,
	DashGapM: number,
	OnFromChanged: (value: number) -> (),
	OnToChanged: (value: number) -> (),
	OnLineChanged: (id: string) -> (),
	OnDashLengthChanged: (value: number) -> (),
	OnDashGapChanged: (value: number) -> (),
})
	local children: { [string]: any } = {}
	RoadDesigner.DecorateCard(children)
	children.Header = e(Components.Section, { Text = "Stretch Marking", First = true, LayoutOrder = 1 })
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
	children.Line = e(Components.Row, { LayoutOrder = 4 }, {
		Label = e(Components.Label, { Text = "Line", LayoutOrder = 1, Width = 60 }),
		Field = e(Components.Dropdown, {
			Options = LINE_OPTIONS,
			SelectedId = props.Line,
			OnSelected = props.OnLineChanged,
			LayoutOrder = 2,
			Grow = true,
		}),
	})
	if LINE_HAS_DASH[props.Line] then
		children.DashLength = e(Components.Row, { LayoutOrder = 5 }, {
			Label = e(Components.Label, { Text = "Dash length", LayoutOrder = 1, Width = 90 }),
			Field = e(Components.NumberField, {
				Value = Units.LengthFromM(props.Settings, props.DashLengthM),
				Min = Units.LengthFromM(props.Settings, 0.1),
				Max = Units.LengthFromM(props.Settings, 20),
				OnChanged = function(value: number)
					props.OnDashLengthChanged(Units.LengthToM(props.Settings, value))
				end,
				LayoutOrder = 2,
			}),
			Unit = e(Components.Label, { Text = Units.LengthSuffix(props.Settings), Dim = true, LayoutOrder = 3 }),
		})
		children.DashGap = e(Components.Row, { LayoutOrder = 6 }, {
			Label = e(Components.Label, { Text = "Dash gap", LayoutOrder = 1, Width = 90 }),
			Field = e(Components.NumberField, {
				Value = Units.LengthFromM(props.Settings, props.DashGapM),
				Min = Units.LengthFromM(props.Settings, 0.1),
				Max = Units.LengthFromM(props.Settings, 20),
				OnChanged = function(value: number)
					props.OnDashGapChanged(Units.LengthToM(props.Settings, value))
				end,
				LayoutOrder = 2,
			}),
			Unit = e(Components.Label, { Text = Units.LengthSuffix(props.Settings), Dim = true, LayoutOrder = 3 }),
		})
	end
	children.Hint = e(Components.Label, {
		Text = "Applies to every same-direction lane boundary together. Apply Stretch above to accept.",
		Dim = true,
		LayoutOrder = 7,
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

return MarkingStretchPanel
