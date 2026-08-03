--!strict
-- Compact, controlled editor for an already-built roundabout. All geometry
-- state and actions are supplied by RoundaboutEditSession through main.lua.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RoadDesigner = require("./RoadDesigner")

export type RoundaboutPanelProps = {
	ConnectedRoadCount: number,
	LegacyConnected: boolean,
	RadiusStuds: number,
	LaneCount: number,
	LaneWidthM: number,
	Markings: string?,
	Sidewalk: boolean?,
	Island: boolean?,
	MinimumRadiusStuds: number,
	SuggestedRadiusStuds: number,
	Status: string?,
	OnRadiusChanged: (value: number) -> (),
	OnLaneCountChanged: (value: number) -> (),
	OnLaneWidthChanged: (value: number) -> (),
	OnMarkingsChanged: (value: string?) -> (),
	OnSidewalkChanged: (value: boolean?) -> (),
	OnIslandChanged: (value: boolean?) -> (),
	OnRebuild: () -> (),
	OnPrintGeometry: () -> (),
	OnConvertToJunction: () -> (),
	OnDelete: () -> (),
}

local function paragraph(text: string, layoutOrder: number, warning: boolean?): React.ReactNode
	return e("TextLabel", {
		Text = text,
		TextColor3 = if warning then Theme.ACCENT else Theme.DIM,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = if warning then Theme.FONT_BOLD else Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		LayoutOrder = layoutOrder,
	})
end

local function staticValue(text: string, layoutOrder: number): React.ReactNode
	return e(Components.Label, {
		Text = text,
		Dim = true,
		Width = 154,
		LayoutOrder = layoutOrder,
	})
end

local function triStateId(value: boolean?): string
	if value == nil then
		return "Region"
	end
	return if value then "Yes" else "No"
end

local function triStateText(value: boolean?): string
	if value == nil then
		return "Region default"
	end
	return if value then "Yes" else "No"
end

local function markingsText(markings: string?): string
	if markings == "Continuous" then
		return "Continuous (dashed lanes)"
	elseif markings == "SolidLanes" then
		return "Solid lane dividers"
	elseif markings == "Turbo" then
		return "Turbo (spiral exits)"
	end
	return "Region default"
end

local function RoundaboutPanel(props: RoundaboutPanelProps)
	local readOnly = props.LegacyConnected
	local children: { [string]: any } = {}
	RoadDesigner.DecorateCard(children)

	children.Geometry = e(Components.Section, { Text = "Geometry", First = true, LayoutOrder = 1 })
	children.Approaches = paragraph(
		string.format(
			"%d connected approach%s",
			props.ConnectedRoadCount,
			if props.ConnectedRoadCount == 1 then "" else "es"
		),
		2
	)
	if readOnly then
		children.LegacyWarning = paragraph(
			"This older connected roundabout has no recoverable source topology, so it stays read-only. Recreate its junction once to use the editor safely.",
			3,
			true
		)
	end

	children.Radius = e(Components.Row, { LayoutOrder = 4 }, {
		Label = e(Components.Label, { Text = "Radius", Width = 92, LayoutOrder = 1 }),
		Field = if readOnly
			then staticValue(string.format("%g studs", props.RadiusStuds), 2)
			else e(Components.NumberField, {
				Value = props.RadiusStuds,
				Min = 1,
				Width = 64,
				OnChanged = props.OnRadiusChanged,
				LayoutOrder = 2,
			}),
		Unit = not readOnly and e(Components.Label, { Text = "studs", Dim = true, LayoutOrder = 3 }),
	})
	children.Lanes = e(Components.Row, { LayoutOrder = 5 }, {
		Label = e(Components.Label, { Text = "Circulating lanes", Width = 118, LayoutOrder = 1 }),
		Field = if readOnly
			then staticValue(tostring(props.LaneCount), 2)
			else e(Components.NumberField, {
				Value = props.LaneCount,
				Min = 1,
				Max = 6,
				Width = 56,
				OnChanged = props.OnLaneCountChanged,
				LayoutOrder = 2,
			}),
	})
	children.LaneWidth = e(Components.Row, { LayoutOrder = 6 }, {
		Label = e(Components.Label, { Text = "Lane width", Width = 92, LayoutOrder = 1 }),
		Field = if readOnly
			then staticValue(string.format("%g m", props.LaneWidthM), 2)
			else e(Components.NumberField, {
				Value = props.LaneWidthM,
				Min = 1,
				Max = 10,
				Width = 64,
				OnChanged = props.OnLaneWidthChanged,
				LayoutOrder = 2,
			}),
		Unit = not readOnly and e(Components.Label, { Text = "m", Dim = true, LayoutOrder = 3 }),
	})

	if props.MinimumRadiusStuds > 0 then
		local minimum = math.ceil(props.MinimumRadiusStuds * 10) / 10
		local suggested = math.ceil(props.SuggestedRadiusStuds * 10) / 10
		local warningText: string
		local warning = false
		if props.RadiusStuds < minimum then
			warning = true
			warningText = string.format(
				"Radius is below the %.1f-stud clearance guide. Suggested for these approaches: %.1f studs.",
				minimum,
				suggested
			)
		elseif suggested > 0 and props.RadiusStuds < suggested then
			warning = true
			warningText = string.format(
				"Tight geometry. Suggested radius: %.1f studs (clearance guide %.1f).",
				suggested,
				minimum
			)
		else
			warningText = string.format("Clearance guide %.1f studs; suggested %.1f.", minimum, suggested)
		end
		children.RadiusAdvice = paragraph(warningText, 7, warning)
	end

	children.Appearance = e(Components.Section, { Text = "Appearance", LayoutOrder = 10 })
	children.Markings = e(Components.Row, { LayoutOrder = 11 }, {
		Label = e(Components.Label, { Text = "Markings", Width = 92, LayoutOrder = 1 }),
		Field = if readOnly
			then staticValue(markingsText(props.Markings), 2)
			else e(Components.Dropdown, {
				Options = {
					{ Id = "Region", Text = "Region default" },
					{ Id = "Continuous", Text = "Continuous (dashed lanes)" },
					{ Id = "SolidLanes", Text = "Solid lane dividers" },
					{ Id = "Turbo", Text = "Turbo (spiral exits)" },
				},
				SelectedId = props.Markings or "Region",
				OnSelected = function(id: string)
					props.OnMarkingsChanged(if id == "Region" then nil else id)
				end,
				Grow = true,
				LayoutOrder = 2,
			}),
	})
	children.Pavement = e(Components.Row, { LayoutOrder = 12 }, {
		Label = e(Components.Label, { Text = "Pavement", Width = 92, LayoutOrder = 1 }),
		Field = if readOnly
			then staticValue(triStateText(props.Sidewalk), 2)
			else e(Components.Dropdown, {
				Options = {
					{ Id = "Region", Text = "Region default" },
					{ Id = "Yes", Text = "Yes" },
					{ Id = "No", Text = "No" },
				},
				SelectedId = triStateId(props.Sidewalk),
				OnSelected = function(id: string)
					props.OnSidewalkChanged(if id == "Region" then nil else id == "Yes")
				end,
				Grow = true,
				LayoutOrder = 2,
			}),
	})
	children.Island = e(Components.Row, { LayoutOrder = 13 }, {
		Label = e(Components.Label, { Text = "Island", Width = 92, LayoutOrder = 1 }),
		Field = if readOnly
			then staticValue(triStateText(props.Island), 2)
			else e(Components.Dropdown, {
				Options = {
					{ Id = "Region", Text = "Region default" },
					{ Id = "Yes", Text = "Yes" },
					{ Id = "No", Text = "No" },
				},
				SelectedId = triStateId(props.Island),
				OnSelected = function(id: string)
					props.OnIslandChanged(if id == "Region" then nil else id == "Yes")
				end,
				Grow = true,
				LayoutOrder = 2,
			}),
	})

	children.Actions = e(Components.Section, { Text = "Actions", LayoutOrder = 20 })
	if readOnly then
		children.LegacyAction =
			paragraph("No automatic migration is performed; proximity cannot reconstruct deleted source road data.", 21)
	else
		children.Rebuild = e(Components.Button, {
			Text = "Rebuild roundabout",
			Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
			OnClick = props.OnRebuild,
			LayoutOrder = 21,
		})
	end
	children.Print = e(Components.Button, {
		Text = "Print geometry to Output",
		Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
		OnClick = props.OnPrintGeometry,
		LayoutOrder = 22,
	})
	if not readOnly and props.ConnectedRoadCount > 0 then
		children.Convert = e(Components.Button, {
			Text = "Convert to junction",
			Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
			OnClick = props.OnConvertToJunction,
			LayoutOrder = 23,
		})
		children.ConvertHint = paragraph("Restores the connected approach node and removes the circulating ring.", 24)
	elseif not readOnly then
		children.Delete = e(Components.Button, {
			Text = "Delete roundabout",
			Danger = true,
			Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
			OnClick = props.OnDelete,
			LayoutOrder = 23,
		})
	end
	if props.Status then
		children.Status = paragraph(props.Status, 30, true)
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

return RoundaboutPanel
