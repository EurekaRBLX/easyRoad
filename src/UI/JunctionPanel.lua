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

local function JunctionPanel(
	props: {
		ConnectedRoadCount: number,
		FilletRadiusM: number,
		PadMarginStuds: number,
		OnFilletRadiusChanged: (value: number) -> (),
		OnPadMarginChanged: (value: number) -> (),
		OnRebuild: () -> (),
		OnDelete: () -> (),
		OnMakeRoundabout: (radiusStuds: number, laneCount: number, laneWidthM: number) -> (),
		-- Smallest radius the approaches meeting here physically fit into, and a
		-- comfortable suggestion above it. Both depend on the ring's own lane
		-- settings, which live here, so this is asked again as those change.
		GetRoundaboutRadii: (laneCount: number, laneWidthM: number) -> (number, number),
	}
)
	local laneCount, setLaneCount = React.useState(DEFAULT_LANE_COUNT)
	local laneWidthM, setLaneWidthM = React.useState(DEFAULT_LANE_WIDTH_M)
	local minimum, suggested = props.GetRoundaboutRadii(laneCount, laneWidthM)
	local radiusStuds, setRadiusStuds = React.useState(if suggested > 0 then suggested else DEFAULT_RADIUS_STUDS)
	local touched, setTouched = React.useState(false)

	-- Follow the suggestion while the user has not overridden it. Changing lane
	-- count or width changes what actually fits, and silently leaving a stale
	-- number in the box is how you end up building the tight version by
	-- accident.
	React.useEffect(function()
		if not touched and suggested > 0 and suggested ~= radiusStuds then
			setRadiusStuds(suggested)
		end
	end, { suggested, touched } :: { any })

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
				OnChanged = function(value: number)
					setTouched(true)
					setRadiusStuds(value)
				end,
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
		-- Say what the geometry needs and what was suggested, rather than
		-- silently correcting the number after the fact. A radius under the
		-- minimum cannot be built as asked - the mouths would overrun each other
		-- - so it gets grown, and the user should hear that before clicking.
		local hint = "Replaces this junction with a polar ring and trims approaches to the outer edge."
		if minimum > 0 then
			local floor = math.ceil(minimum)
			if radiusStuds < floor then
				hint = string.format(
					"These approaches need at least %d studs - %d will be grown to fit. Suggested: %d.",
					minimum,
					radiusStuds,
					suggested
				)
			else
				hint = string.format("Minimum for these approaches: %d studs. Suggested: %d.", minimum, suggested)
			end
		end
		children.RoundaboutHint = e(Components.Label, {
			Text = hint,
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
