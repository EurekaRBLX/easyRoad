--!strict
-- The main EasyRoad panel: tool selection, road selection, transition
-- (widening/narrowing) target, elevation readout and placement hints, with
-- navigation into the road editor and the grand settings.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local Icons = require("./Icons")
local LaneEditor = require("./LaneEditor")
local SettingsGui = require("./SettingsGui")
local Settings = require("../Settings")
local RoadProfile = require("../RoadProfile")
local RoadLibraryModule = require("../RoadLibrary")

type RoadLibrary = RoadLibraryModule.RoadLibrary

export type Page = "build" | "editor" | "settings"

local function BuildPage(props: {
	Active: boolean,
	ToolMode: string,
	Hint: string,
	Elevation: number,
	ProfileId: string?,
	ActiveProfile: RoadProfile.RoadProfile?,
	EndProfileId: string?,
	Library: RoadLibrary,
	Settings: Settings.EasyRoadSettings,
	SetToolMode: (mode: string) -> (),
	SetProfileId: (id: string) -> (),
	SetEndProfileId: (id: string?) -> (),
	AdjustComponentWidth: (index: number, widthM: number) -> (),
	SaveActiveProfileAsNew: () -> (),
	HandleAction: (action: string) -> (),
	OpenPage: (page: Page) -> (),
	OnSettingsChanged: () -> (),
})
	local profileOptions: { Components.DropdownOption } = {}
	for _, profile in props.Library.GetAll() do
		table.insert(profileOptions, { Id = profile.Id, Text = profile.Name })
	end
	local endProfileOptions: { Components.DropdownOption } = {
		{ Id = "__none", Text = "None (constant width)" },
	}
	for _, profile in props.Library.GetAll() do
		table.insert(endProfileOptions, { Id = profile.Id, Text = profile.Name })
	end

	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, Theme.PADDING),
			PaddingRight = UDim.new(0, Theme.PADDING),
			PaddingTop = UDim.new(0, Theme.PADDING),
			PaddingBottom = UDim.new(0, Theme.PADDING),
		}),
	}

	if not props.Active then
		children.Inactive = e(Components.Label, {
			Text = "Press the easyRoad toolbar button to start building.",
			LayoutOrder = 1,
		})
		children.Activate = e(Components.Button, {
			Text = "Start Building",
			Selected = true,
			OnClick = function()
				props.HandleAction("activate")
			end,
			LayoutOrder = 2,
		})
	else
		children.ToolSection = e(Components.Section, {
			Text = "Tool",
			LayoutOrder = 1,
		})
		children.Tools = e(Components.Row, {
			LayoutOrder = 2,
		}, {
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
				Text = "Freeform",
				Selected = props.ToolMode == "Freeform",
				OnClick = function()
					props.SetToolMode("Freeform")
				end,
				LayoutOrder = 3,
				Grow = true,
			}),
		})

		children.RoadSection = e(Components.Section, {
			Text = "Road",
			LayoutOrder = 3,
		})
		children.Profile = e(Components.Dropdown, {
			Options = profileOptions,
			SelectedId = props.ProfileId,
			Placeholder = "Pick a road...",
			OnSelected = props.SetProfileId,
			LayoutOrder = 4,
			Grow = true,
		})
		children.TransitionLabel = e(Components.Label, {
			Text = "Widen / narrow to (transition):",
			Dim = true,
			LayoutOrder = 5,
		})
		children.EndProfile = e(Components.Dropdown, {
			Options = endProfileOptions,
			SelectedId = props.EndProfileId or "__none",
			OnSelected = function(id: string)
				props.SetEndProfileId(if id == "__none" then nil else id)
			end,
			LayoutOrder = 6,
			Grow = true,
		})

		if props.ActiveProfile then
			local activeProfile = props.ActiveProfile
			children.WidthsSection = e(Components.Section, {
				Text = "Adjust Widths",
				LayoutOrder = 7,
			})
			for index, component in activeProfile.Components do
				children["Width" .. index] = e(Components.Row, {
					LayoutOrder = 7 + index,
				}, {
					Icon = e("ImageLabel", {
						Image = Icons.ForKind[component.Kind] or Icons.Lane,
						BackgroundTransparency = 1,
						Size = UDim2.new(0, 20, 0, 20),
						ScaleType = Enum.ScaleType.Fit,
						LayoutOrder = 1,
					}),
					Label = e(Components.Label, {
						Text = component.Kind
							.. (if component.Direction > 0 then " →" elseif component.Direction < 0 then " ←" else ""),
						LayoutOrder = 2,
					}),
					Field = e(Components.NumberField, {
						Value = component.WidthM,
						Min = 0.1,
						Max = 30,
						OnChanged = function(value: number)
							props.AdjustComponentWidth(index, value)
						end,
						LayoutOrder = 3,
					}),
				})
			end
			children.SaveAsNewRoad = e(Components.Button, {
				Text = "Save as New Road...",
				OnClick = props.SaveActiveProfileAsNew,
				LayoutOrder = 8 + #activeProfile.Components,
			})
		end

		children.BankToggle = e(Components.Checkbox, {
			Label = "Superelevation (banking)",
			Checked = props.Settings.SuperelevationMode ~= "Off",
			OnToggled = function(checked: boolean)
				props.Settings.SuperelevationMode = if checked then "Auto" else "Off"
				props.OnSettingsChanged()
			end,
			LayoutOrder = 50,
		})
		children.DesignSpeed = props.Settings.SuperelevationMode ~= "Off" and e(Components.Row, {
			LayoutOrder = 51,
		}, {
			Label = e(Components.Label, {
				Text = "Design speed (km/h)",
				LayoutOrder = 1,
			}),
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

		children.StatusSection = e(Components.Section, {
			Text = "Placement",
			LayoutOrder = 52,
		})
		children.Hint = e("TextLabel", {
			Text = props.Hint,
			TextColor3 = Theme.OFFWHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Font = Theme.FONT,
			TextSize = Theme.TEXT_SIZE,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			LayoutOrder = 53,
		})
		children.Elevation = e(Components.Label, {
			Text = string.format("Elevation: %+g studs  (R / F to change)", props.Elevation),
			Dim = true,
			LayoutOrder = 54,
		})
		children.Keys = e(Components.Label, {
			Text = "Right-click / Esc: cancel placement",
			Dim = true,
			LayoutOrder = 55,
		})
		children.Stop = e(Components.Button, {
			Text = "Stop Building",
			Danger = true,
			OnClick = function()
				props.HandleAction("close")
			end,
			LayoutOrder = 56,
		})
	end

	children.NavSection = e(Components.Section, {
		Text = "Configure",
		LayoutOrder = 60,
	})
	children.Nav = e(Components.Row, {
		LayoutOrder = 61,
	}, {
		Editor = e(Components.Button, {
			Text = "Edit Roads...",
			OnClick = function()
				props.OpenPage("editor")
			end,
			LayoutOrder = 1,
			Grow = true,
		}),
		Settings = e(Components.Button, {
			Text = "Settings...",
			OnClick = function()
				props.OpenPage("settings")
			end,
			LayoutOrder = 2,
			Grow = true,
		}),
	})

	children.Corner = e("UICorner", {
		CornerRadius = UDim.new(0, Theme.CORNER_RADIUS),
	})
	children.Stroke = e("UIStroke", {
		Color = Theme.GLASS_STROKE,
		Transparency = Theme.GLASS_STROKE_TRANSPARENCY,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
	return e("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.GLASS_BG,
		BackgroundTransparency = Theme.GLASS_TRANSPARENCY,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(1, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
	}, children)
end

local function EasyRoadGui(props: {
	Active: boolean,
	ToolMode: string,
	Hint: string,
	Elevation: number,
	ProfileId: string?,
	ActiveProfile: RoadProfile.RoadProfile?,
	EndProfileId: string?,
	Library: RoadLibrary,
	Settings: Settings.EasyRoadSettings,
	SetToolMode: (mode: string) -> (),
	SetProfileId: (id: string) -> (),
	SetEndProfileId: (id: string?) -> (),
	AdjustComponentWidth: (index: number, widthM: number) -> (),
	SaveActiveProfileAsNew: () -> (),
	HandleAction: (action: string) -> (),
	OpenDesigner: (profile: RoadProfile.RoadProfile) -> (),
	OnSettingsChanged: () -> (),
	OnLibraryChanged: () -> (),
})
	local page: Page, setPage = React.useState("build" :: Page)

	if page == "editor" then
		return e(LaneEditor, {
			Library = props.Library,
			OpenDesigner = props.OpenDesigner,
			OnClose = function()
				setPage("build" :: Page)
			end,
		})
	elseif page == "settings" then
		return e(SettingsGui, {
			Settings = props.Settings,
			OnSettingsChanged = props.OnSettingsChanged,
			OnClose = function()
				setPage("build" :: Page)
			end,
		})
	end

	return e(BuildPage, {
		Active = props.Active,
		ToolMode = props.ToolMode,
		Hint = props.Hint,
		Elevation = props.Elevation,
		ProfileId = props.ProfileId,
		ActiveProfile = props.ActiveProfile,
		EndProfileId = props.EndProfileId,
		Library = props.Library,
		Settings = props.Settings,
		SetToolMode = props.SetToolMode,
		SetProfileId = props.SetProfileId,
		SetEndProfileId = props.SetEndProfileId,
		AdjustComponentWidth = props.AdjustComponentWidth,
		SaveActiveProfileAsNew = props.SaveActiveProfileAsNew,
		HandleAction = props.HandleAction,
		OpenPage = function(newPage: Page)
			setPage(newPage)
		end,
		OnSettingsChanged = props.OnSettingsChanged,
	})
end

return EasyRoadGui
