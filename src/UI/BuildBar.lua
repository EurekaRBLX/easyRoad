--!strict
-- The build bar: CS2-style bottom-of-viewport UI shown while placing roads.
--
--   [ ROAD TOOL card ]  [ live lane strip of the active road ]  [ MODULES ]
--
-- The tool card holds tool mode (straight / curve / freeform), the road
-- picker, the widen/narrow transition target, banking, elevation and
-- placement hints. The lane strip edits the ACTIVE road live - session-only
-- tweaks that show up in the preview immediately and can be kept with
-- "Save as New Road...". This replaces the old right-side dock-style panel.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Components = require("./Components")
local RoadDesigner = require("./RoadDesigner")
local RoadProfile = require("../RoadProfile")
local RoadLibraryModule = require("../RoadLibrary")
local RegionStyles = require("../RegionStyles")
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
	Profile: RoadProfile.RoadProfile,
	OnChangeProfile: (transform: (profile: RoadProfile.RoadProfile) -> ()) -> (),
	SaveAsNew: () -> (),
	Hint: string,
	Elevation: number,
	RegionStyle: RegionStyles.RegionStyle,
	OnStop: () -> (),
})
	local profile = props.Profile
	local count = #profile.Components

	local selectedIndex, setSelectedIndex = React.useState(0)
	local sel: number? = if selectedIndex >= 1 and selectedIndex <= count then selectedIndex else nil

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

	-- Tool card ------------------------------------------------------------------
	local toolChildren: { [string]: any } = {}
	toolChildren.Header = e(Components.Section, { Text = "Road Tool", LayoutOrder = 1 })
	toolChildren.Tools = e(Components.Row, { LayoutOrder = 2 }, {
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
	toolChildren.Profile = e(Components.Dropdown, {
		Options = profileOptions,
		SelectedId = props.ProfileId,
		Placeholder = "Pick a road...",
		OnSelected = props.SetProfileId,
		LayoutOrder = 3,
		Grow = true,
	})
	toolChildren.Transition = e(Components.Row, { LayoutOrder = 4 }, {
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
	toolChildren.BankToggle = e(Components.Checkbox, {
		Label = "Superelevation (banking)",
		Checked = props.Settings.SuperelevationMode ~= "Off",
		OnToggled = function(checked: boolean)
			props.Settings.SuperelevationMode = if checked then "Auto" else "Off"
			props.OnSettingsChanged()
		end,
		LayoutOrder = 5,
	})
	toolChildren.Speed = props.Settings.SuperelevationMode ~= "Off"
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
	toolChildren.Elevation = e(Components.Label, {
		Text = string.format("Elevation %+g studs (R / F)", props.Elevation),
		Dim = true,
		LayoutOrder = 7,
	})
	toolChildren.Hint = e(Components.Label, {
		Text = props.Hint,
		Dim = true,
		LayoutOrder = 8,
	})
	toolChildren.SaveAsNew = e(Components.Button, {
		Text = "Save as New Road...",
		OnClick = props.SaveAsNew,
		LayoutOrder = 9,
	})
	toolChildren.Stop = e(Components.Button, {
		Text = "Stop Building",
		Danger = true,
		OnClick = props.OnStop,
		LayoutOrder = 10,
	})

	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 8),
		}),
		Tool = RoadDesigner.ScrollColumn(240, 1, toolChildren),
		StripCard = e(RoadDesigner.LaneStripCard, {
			Profile = profile,
			SelectedIndex = selectedIndex,
			OnSelect = setSelectedIndex,
			OnChange = props.OnChangeProfile,
			LayoutOrder = 2,
		}),
		Palette = e(RoadDesigner.PaletteCard, {
			OnInsert = function(kind: RoadProfile.ComponentKind)
				local at = if sel then (sel :: number) + 1 else count + 1
				props.OnChangeProfile(function(copy)
					table.insert(copy.Components, at, {
						Kind = kind,
						WidthM = RoadDesigner.DefaultWidthFor(kind, props.RegionStyle),
						Direction = if RoadProfile.IsDirectional(kind) then 1 else 0,
					})
				end)
				setSelectedIndex(at)
			end,
			LayoutOrder = 3,
		}),
	})
end

return BuildBar
