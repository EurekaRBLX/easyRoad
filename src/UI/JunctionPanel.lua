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
		CornerCount: number,
		FilletRadiusM: number,
		PadMarginStuds: number,
		LinkedCornerRadii: boolean,
		SelectedCornerLabel: string?,
		SelectedCornerRadiusM: number?,
		RoundaboutStatus: string?,
		OnFilletRadiusChanged: (value: number) -> (),
		OnPadMarginChanged: (value: number) -> (),
		OnLinkedCornerRadiiChanged: (linked: boolean) -> (),
		OnSelectedCornerRadiusChanged: (value: number) -> (),
		OnRebuild: () -> (),
		OnDelete: () -> (),
		OnMakeRoundabout: (
			radiusStuds: number,
			laneCount: number,
			laneWidthM: number,
			markings: string?,
			sidewalk: boolean?,
			island: boolean?
		) -> (),
		-- Smallest radius the approaches meeting here physically fit into, and a
		-- comfortable suggestion above it. Both depend on the ring's own lane
		-- settings, which live here, so this is asked again as those change.
		GetRoundaboutRadii: (laneCount: number, laneWidthM: number) -> (number, number),
		-- Prints every number the roundabout would be built from, without
		-- building it, so the shipped geometry can be diffed against the
		-- headless preview in tools/preview.
		OnDumpRoundabout: (radiusStuds: number, laneCount: number, laneWidthM: number) -> (),
	}
)
	local laneCount, setLaneCount = React.useState(DEFAULT_LANE_COUNT)
	local laneWidthM, setLaneWidthM = React.useState(DEFAULT_LANE_WIDTH_M)
	local minimum, suggested = props.GetRoundaboutRadii(laneCount, laneWidthM)
	local radiusStuds, setRadiusStuds = React.useState(if suggested > 0 then suggested else DEFAULT_RADIUS_STUDS)
	-- nil means "follow the region's default", which is why this is not a
	-- boolean: the panel has to be able to say "not overridden" as well as
	-- which of the two styles was picked.
	local markings, setMarkings = React.useState(nil :: string?)
	-- Same tri-state as markings: nil follows the region, so the panel can say
	-- "not overridden" as well as yes or no.
	local ringWalk, setRingWalk = React.useState(nil :: boolean?)
	local ringIsland, setRingIsland = React.useState(nil :: boolean?)
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
			"%d approach port%s / %d corner node%s",
			props.ConnectedRoadCount,
			if props.ConnectedRoadCount == 1 then "" else "s",
			props.CornerCount,
			if props.CornerCount == 1 then "" else "s"
		),
		Dim = true,
		LayoutOrder = 2,
	})
	children.HandleHint = e(Components.Label, {
		Text = "Yellow = owner node. Red = approach ports. Click a cyan corner to edit its radius.",
		Dim = true,
		LayoutOrder = 3,
	})

	children.NodeSection = e(Components.Section, { Text = "Node controller", LayoutOrder = 4 })
	children.LinkRadii = e(Components.Checkbox, {
		Label = "Link all corner radii",
		Checked = props.LinkedCornerRadii,
		OnToggled = props.OnLinkedCornerRadiiChanged,
		LayoutOrder = 5,
	})
	children.FilletRow = e(Components.Row, { LayoutOrder = 6 }, {
		Label = e(Components.Label, {
			Text = if props.LinkedCornerRadii then "All radii" else "Default radius",
			LayoutOrder = 1,
			Width = 104,
		}),
		Field = e(Components.NumberField, {
			Value = props.FilletRadiusM,
			Min = 0.5,
			Max = 40,
			OnChanged = props.OnFilletRadiusChanged,
			LayoutOrder = 2,
		}),
		Unit = e(Components.Label, { Text = "m", Dim = true, LayoutOrder = 3 }),
	})
	if not props.LinkedCornerRadii then
		if props.SelectedCornerRadiusM and props.SelectedCornerLabel then
			children.SelectedCorner = e(Components.Row, { LayoutOrder = 7 }, {
				Label = e(Components.Label, { Text = props.SelectedCornerLabel, LayoutOrder = 1, Width = 104 }),
				Field = e(Components.NumberField, {
					Value = props.SelectedCornerRadiusM,
					Min = 0.5,
					Max = 40,
					OnChanged = props.OnSelectedCornerRadiusChanged,
					LayoutOrder = 2,
				}),
				Unit = e(Components.Label, { Text = "m", Dim = true, LayoutOrder = 3 }),
			})
		else
			children.SelectedCornerHint = e(Components.Label, {
				Text = "Click a cyan corner handle to choose its override.",
				Dim = true,
				LayoutOrder = 7,
			})
		end
	end
	children.SetbackRow = e(Components.Row, { LayoutOrder = 8 }, {
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
		LayoutOrder = 9,
		OnClick = props.OnRebuild,
	})

	children.Delete = e(Components.Button, {
		Text = "Delete Junction",
		Danger = true,
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		LayoutOrder = 10,
		OnClick = props.OnDelete,
	})
	children.Hint = e(Components.Label, {
		Text = "Unlinks the roads meeting here — doesn't delete them.",
		Dim = true,
		LayoutOrder = 11,
	})

	if props.ConnectedRoadCount >= 3 then
		children.RoundaboutSection = e(Components.Section, { Text = "Roundabout", LayoutOrder = 20 })
		children.RoundaboutRadius = e(Components.Row, { LayoutOrder = 21 }, {
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
		children.RoundaboutLaneCount = e(Components.Row, { LayoutOrder = 22 }, {
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
		children.RoundaboutLaneWidth = e(Components.Row, { LayoutOrder = 23 }, {
			Label = e(Components.Label, { Text = "Lane width", LayoutOrder = 1, Width = 60 }),
			Field = e(Components.NumberField, {
				Value = laneWidthM,
				Min = 1,
				OnChanged = setLaneWidthM,
				LayoutOrder = 2,
			}),
			Unit = e(Components.Label, { Text = "meters", Dim = true, LayoutOrder = 3 }),
		})
		children.RoundaboutMarkings = e(Components.Row, { LayoutOrder = 24 }, {
			Label = e(Components.Label, { Text = "Markings", LayoutOrder = 1, Width = 60 }),
			Field = e(Components.Dropdown, {
				Options = {
					{ Id = "Region", Text = "Region default" },
					{ Id = "Continuous", Text = "Continuous (dashed lanes)" },
					{ Id = "SolidLanes", Text = "Solid lane dividers" },
					{ Id = "Turbo", Text = "Turbo (spiral to the exits)" },
				},
				SelectedId = markings or "Region",
				OnSelected = function(id: string)
					setMarkings(if id == "Region" then nil else id)
				end,
				LayoutOrder = 2,
				Grow = true,
			}),
		})
		children.RoundaboutSidewalk = e(Components.Row, { LayoutOrder = 25 }, {
			Label = e(Components.Label, { Text = "Pavement", LayoutOrder = 1, Width = 60 }),
			Field = e(Components.Dropdown, {
				Options = {
					{ Id = "Region", Text = "Region default" },
					{ Id = "Yes", Text = "Yes" },
					{ Id = "No", Text = "No" },
				},
				SelectedId = if ringWalk == nil then "Region" elseif ringWalk then "Yes" else "No",
				OnSelected = function(id: string)
					setRingWalk(if id == "Region" then nil else id == "Yes")
				end,
				LayoutOrder = 2,
				Grow = true,
			}),
		})
		children.RoundaboutIsland = e(Components.Row, { LayoutOrder = 26 }, {
			Label = e(Components.Label, { Text = "Island", LayoutOrder = 1, Width = 60 }),
			Field = e(Components.Dropdown, {
				Options = {
					{ Id = "Region", Text = "Region default" },
					{ Id = "Yes", Text = "Yes" },
					{ Id = "No", Text = "No" },
				},
				SelectedId = if ringIsland == nil then "Region" elseif ringIsland then "Yes" else "No",
				OnSelected = function(id: string)
					setRingIsland(if id == "Region" then nil else id == "Yes")
				end,
				LayoutOrder = 2,
				Grow = true,
			}),
		})
		children.MakeRoundabout = e(Components.Button, {
			Text = "Make Roundabout",
			Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
			LayoutOrder = 27,
			OnClick = function()
				props.OnMakeRoundabout(radiusStuds, laneCount, laneWidthM, markings, ringWalk, ringIsland)
			end,
		})
		-- The radius is built AS ASKED, including below the recommendation.
		-- Say what the geometry wants and what a tight ring will look like, so
		-- the choice is informed - rather than silently overriding the number
		-- the user typed, which is what this used to do.
		local hint = "Replaces this junction with a polar ring and trims approaches to the outer edge."
		if minimum > 0 then
			local floor = math.ceil(minimum)
			if radiusStuds < floor then
				hint = string.format(
					"%d studs is below the %d these approaches want. It will build, but the entry and exit"
						.. " will crowd and the splitter islands will pinch. Suggested: %d.",
					radiusStuds,
					floor,
					suggested
				)
			else
				hint = string.format(
					"Recommended minimum for these approaches: %d studs. Suggested: %d.",
					floor,
					suggested
				)
			end
		end
		children.RoundaboutDump = e(Components.Button, {
			Text = "Print geometry to Output",
			Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
			LayoutOrder = 28,
			OnClick = function()
				props.OnDumpRoundabout(radiusStuds, laneCount, laneWidthM)
			end,
		})
		children.RoundaboutHint = e(Components.Label, {
			Text = hint,
			Dim = true,
			LayoutOrder = 29,
		})
		if props.RoundaboutStatus then
			children.RoundaboutStatus = e(Components.Label, {
				Text = props.RoundaboutStatus,
				TextColor3 = Theme.ACCENT,
				TextWrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				BackgroundTransparency = 1,
				LayoutOrder = 30,
			})
		end
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
