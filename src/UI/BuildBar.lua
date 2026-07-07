--!strict
-- The road tool panel: compact CS2-style placement panel (bottom-left of
-- the viewport) shown while placing roads.
--
-- Placement controls only - tool mode, which road to place, widen/narrow
-- transition target, banking, elevation and hints. Creating or editing
-- road types is the Road Editor's job (the full designer), and the grand
-- settings live in the docked sidebar panel, so this stays small like the
-- CS2 road tool box.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RoadDesigner = require("./RoadDesigner")
local RoadLibraryModule = require("../RoadLibrary")
local Settings = require("../Settings")

type RoadLibrary = RoadLibraryModule.RoadLibrary

local function BuildBar(props: {
	ToolMode: string,
	SetToolMode: (mode: string) -> (),
	Library: RoadLibrary,
	ProfileId: string?,
	SetProfileId: (id: string) -> (),
	EndProfileId: string?,
	SetEndProfileId: (id: string?) -> (),
	Settings: Settings.EasyRoadSettings,
	OnSettingsChanged: () -> (),
	Hint: string,
	Elevation: number,
	OnStop: () -> (),
})
	local profileOptions: { Components.DropdownOption } = {}
	for _, libraryProfile in props.Library.GetAll() do
		table.insert(profileOptions, { Id = libraryProfile.Id, Text = libraryProfile.Name })
	end
	local endProfileOptions: { Components.DropdownOption } = {
		{ Id = "__none", Text = "None (constant width)" },
	}
	for _, libraryProfile in props.Library.GetAll() do
		table.insert(endProfileOptions, { Id = libraryProfile.Id, Text = libraryProfile.Name })
	end

	local children: { [string]: any } = {}
	RoadDesigner.DecorateCard(children)
	children.Header = e(Components.Section, { Text = "Road Tool", LayoutOrder = 1 })
	children.Tools = e(Components.Row, { LayoutOrder = 2 }, {
		Straight = e(Components.Button, {
			Text = "Straight",
			Selected = props.ToolMode == "Straight",
			OnClick = function()
				props.SetToolMode("Straight")
			end,
			LayoutOrder = 1,
			Grow = true,
		}),
		Curve = e(Components.Button, {
			Text = "Curve",
			Selected = props.ToolMode == "Curve",
			OnClick = function()
				props.SetToolMode("Curve")
			end,
			LayoutOrder = 2,
			Grow = true,
		}),
		Freeform = e(Components.Button, {
			Text = "Free",
			Selected = props.ToolMode == "Freeform",
			OnClick = function()
				props.SetToolMode("Freeform")
			end,
			LayoutOrder = 3,
			Grow = true,
		}),
	})
	children.Profile = e(Components.Dropdown, {
		Options = profileOptions,
		SelectedId = props.ProfileId,
		Placeholder = "Pick a road...",
		OnSelected = props.SetProfileId,
		LayoutOrder = 3,
		Grow = true,
	})
	children.Transition = e(Components.Row, { LayoutOrder = 4 }, {
		Label = e(Components.Label, { Text = "Widen to", LayoutOrder = 1, Width = 60 }),
		Dropdown = e(Components.Dropdown, {
			Options = endProfileOptions,
			SelectedId = props.EndProfileId or "__none",
			OnSelected = function(id: string)
				props.SetEndProfileId(if id == "__none" then nil else id)
			end,
			LayoutOrder = 2,
			Grow = true,
		}),
	})
	children.BankToggle = e(Components.Checkbox, {
		Label = "Superelevation (banking)",
		Checked = props.Settings.SuperelevationMode ~= "Off",
		OnToggled = function(checked: boolean)
			props.Settings.SuperelevationMode = if checked then "Auto" else "Off"
			props.OnSettingsChanged()
		end,
		LayoutOrder = 5,
	})
	children.Speed = props.Settings.SuperelevationMode ~= "Off"
		and e(Components.Row, { LayoutOrder = 6 }, {
			Label = e(Components.Label, { Text = "Speed (km/h)", LayoutOrder = 1, Width = 90 }),
			Field = e(Components.NumberField, {
				Value = props.Settings.DesignSpeedKph,
				Min = 10,
				Max = 200,
				OnChanged = function(value: number)
					props.Settings.DesignSpeedKph = value
					props.OnSettingsChanged()
				end,
				LayoutOrder = 2,
			}),
		})
	children.Elevation = e(Components.Label, {
		Text = string.format("Elevation %+g studs (R / F)", props.Elevation),
		Dim = true,
		LayoutOrder = 7,
	})
	children.Hint = e("TextLabel", {
		Text = props.Hint,
		TextColor3 = Theme.DIM,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		LayoutOrder = 8,
	})
	children.Stop = e(Components.Button, {
		Text = "Stop Building",
		Danger = true,
		OnClick = props.OnStop,
		LayoutOrder = 9,
	})

	return e("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.GLASS_BG,
		BackgroundTransparency = Theme.GLASS_TRANSPARENCY,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(1, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
	}, children)
end

return BuildBar
