--!strict
-- HUD when a JunctionNode is selected: connection info, node controller
-- (fillet / setback), rebuild, roundabout convert, delete.
-- Viewport handles (centre, mouth bars) live in JunctionEditSession.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RoadDesigner = require("./RoadDesigner")

local DEFAULT_RADIUS_STUDS = 30
local DEFAULT_LANE_COUNT = 1
local DEFAULT_LANE_WIDTH_M = 3.65

local function JunctionPanel(props: {
	ConnectedRoadCount: number,
	FilletRadiusM: number,
	PadMarginStuds: number,
	OnFilletRadiusChanged: (value: number) -> (),
	OnPadMarginChanged: (value: number) -> (),
	OnRebuild: () -> (),
	OnDelete: () -> (),
	OnMakeRoundabout: (radiusStuds: number, laneCount: number, laneWidthM: number) -> (),
})
	local radiusStuds, setRadiusStuds = React.useState(DEFAULT_RADIUS_STUDS)
	local laneCount, setLaneCount = React.useState(DEFAULT_LANE_COUNT)
	local laneWidthM, setLaneWidthM = React.useState(DEFAULT_LANE_WIDTH_M)

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
	children.HandleHint = e(Components.Label, {
		Text = "Yellow ball = move node. Red bars = approach mouths. Cyan balls = curb corners.",
		Dim = true,
		LayoutOrder = 3,
	})

	children.NodeSection = e(Components.Section, { Text = "Node controller", LayoutOrder = 4 })
	children.FilletRow = e(Components.Row, { LayoutOrder = 5 }, {
		Label = e(Components.Label, { Text = "Corner radius", LayoutOrder = 1, Width = 90 }),
		Field = e(Components.NumberField, {
			Value = props.FilletRadiusM,
			Min = 0.5,
			Max = 40,
			OnChanged = props.OnFilletRadiusChanged,
			LayoutOrder = 2,
		}),
		Unit = e(Components.Label, { Text = "m", Dim = true, LayoutOrder = 3 }),
	})
	children.SetbackRow = e(Components.Row, { LayoutOrder = 6 }, {
		Label = e(Components.Label, { Text = "Setback", LayoutOrder = 1, Width = 90 }),
		Field = e(Components.NumberField, {
			Value = props.PadMarginStuds,
			Min = 1,
			Max = 40,
			OnChanged = props.OnPadMarginChanged,
			LayoutOrder = 2,
		}),
		Unit = e(Components.Label, { Text = "studs", Dim = true, LayoutOrder = 3 }),
	})
	children.Rebuild = e(Components.Button, {
		Text = "Rebuild junction",
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		LayoutOrder = 7,
		OnClick = props.OnRebuild,
	})

	children.Delete = e(Components.Button, {
		Text = "Delete Junction",
		Danger = true,
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		LayoutOrder = 8,
		OnClick = props.OnDelete,
	})
	children.Hint = e(Components.Label, {
		Text = "Unlinks the roads meeting here — doesn't delete them.",
		Dim = true,
		LayoutOrder = 9,
	})

	if props.ConnectedRoadCount >= 3 then
		children.RoundaboutSection = e(Components.Section, { Text = "Roundabout", LayoutOrder = 10 })
		children.RoundaboutRadius = e(Components.Row, { LayoutOrder = 11 }, {
			Label = e(Components.Label, { Text = "Radius", LayoutOrder = 1, Width = 60 }),
			Field = e(Components.NumberField, {
				Value = radiusStuds,
				Min = 5,
				OnChanged = setRadiusStuds,
				LayoutOrder = 2,
			}),
			Unit = e(Components.Label, { Text = "studs", Dim = true, LayoutOrder = 3 }),
		})
		children.RoundaboutLaneCount = e(Components.Row, { LayoutOrder = 12 }, {
			Label = e(Components.Label, { Text = "Lanes", LayoutOrder = 1, Width = 60 }),
			Field = e(Components.NumberField, {
				Value = laneCount,
				Min = 1,
				Max = 6,
				OnChanged = function(value: number)
					setLaneCount(math.floor(value))
				end,
				LayoutOrder = 2,
			}),
		})
		children.RoundaboutLaneWidth = e(Components.Row, { LayoutOrder = 13 }, {
			Label = e(Components.Label, { Text = "Lane width", LayoutOrder = 1, Width = 60 }),
			Field = e(Components.NumberField, {
				Value = laneWidthM,
				Min = 1,
				OnChanged = setLaneWidthM,
				LayoutOrder = 2,
			}),
			Unit = e(Components.Label, { Text = "meters", Dim = true, LayoutOrder = 3 }),
		})
		children.MakeRoundabout = e(Components.Button, {
			Text = "Make Roundabout",
			Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
			LayoutOrder = 14,
			OnClick = function()
				props.OnMakeRoundabout(radiusStuds, laneCount, laneWidthM)
			end,
		})
		children.RoundaboutHint = e(Components.Label, {
			Text = "Replaces this junction with a polar ring and trims approaches to the outer edge.",
			Dim = true,
			LayoutOrder = 15,
		})
	end

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
