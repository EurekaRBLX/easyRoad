--!strict
-- The grand settings panel, docked in the Studio sidebar. Tabbed:
--   Regional Preference - region style, scale, superelevation, snapping,
--                          geometry quality (everything that used to be the
--                          whole page)
--   Keybinds             - what the placement keys currently do (not yet
--                          rebindable - see TODO.md)

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")

type SettingsTab = "Regional" | "Keybinds"

local function LabeledRow(props: {
	Label: string,
	LayoutOrder: number,
	children: { [string]: any },
})
	local children: { [string]: any } = {
		Label = e(Components.Label, {
			Text = props.Label,
			LayoutOrder = 1,
			Width = 120,
		}),
	}
	for key, child in props.children do
		children[key] = child
	end
	return e(Components.Row, {
		LayoutOrder = props.LayoutOrder,
	}, children)
end

local function KeybindRow(props: {
	Action: string,
	Keys: string,
	LayoutOrder: number,
})
	return e(Components.Row, { LayoutOrder = props.LayoutOrder }, {
		Action = e(Components.Label, { Text = props.Action, LayoutOrder = 1, Width = 150 }),
		Keys = e(Components.Label, { Text = props.Keys, Dim = true, LayoutOrder = 2 }),
	})
end

local function RegionalPreferencePage(props: {
	Settings: Settings.EasyRoadSettings,
	OnSettingsChanged: () -> (),
	LayoutOrder: number,
})
	local settings = props.Settings

	local regionOptions: { Components.DropdownOption } = {}
	for _, style in RegionStyles.All do
		table.insert(regionOptions, { Id = style.Id, Text = style.Name })
	end

	local superelevationOptions: { Components.DropdownOption } = {
		{ Id = "Auto", Text = "Auto (from speed + curvature)" },
		{ Id = "Manual", Text = "Manual angle" },
		{ Id = "Off", Text = "Off (flat roads)" },
	}

	local activeStyle = RegionStyles.Get(settings.RegionId)

	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),

		StyleSection = e(Components.Section, {
			Text = "Road Style",
			LayoutOrder = 1,
		}),
		Region = e(LabeledRow, {
			Label = "Region",
			LayoutOrder = 2,
			children = {
				Dropdown = e(Components.Dropdown, {
					Options = regionOptions,
					SelectedId = settings.RegionId,
					OnSelected = function(id: string)
						settings.RegionId = id
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
					Grow = true,
				}),
			},
		}),
		RegionInfo = e(Components.Label, {
			Text = string.format(
				"Drives on the %s • %.2fm lanes • %s center line",
				if activeStyle.DriveOnLeft then "left" else "right",
				activeStyle.DefaultLaneWidthM,
				string.lower(activeStyle.CenterLine.Line)
			),
			Dim = true,
			LayoutOrder = 3,
		}),
		Scale = e(LabeledRow, {
			Label = "Studs per meter",
			LayoutOrder = 4,
			children = {
				Field = e(Components.NumberField, {
					Value = settings.MetersToStuds,
					Min = 0.5,
					Max = 20,
					OnChanged = function(value: number)
						settings.MetersToStuds = value
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
				}),
			},
		}),
		Markings = e(Components.Checkbox, {
			Label = "Paint lane markings",
			Checked = settings.AutoMarkings,
			OnToggled = function(checked: boolean)
				settings.AutoMarkings = checked
				props.OnSettingsChanged()
			end,
			LayoutOrder = 5,
		}),

		BankSection = e(Components.Section, {
			Text = "Superelevation (Banking)",
			LayoutOrder = 10,
		}),
		BankMode = e(LabeledRow, {
			Label = "Mode",
			LayoutOrder = 11,
			children = {
				Dropdown = e(Components.Dropdown, {
					Options = superelevationOptions,
					SelectedId = settings.SuperelevationMode,
					OnSelected = function(id: string)
						settings.SuperelevationMode = id :: Settings.SuperelevationMode
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
					Grow = true,
				}),
			},
		}),
		DesignSpeed = settings.SuperelevationMode == "Auto" and e(LabeledRow, {
			Label = "Design speed (km/h)",
			LayoutOrder = 12,
			children = {
				Field = e(Components.NumberField, {
					Value = settings.DesignSpeedKph,
					Min = 10,
					Max = 200,
					OnChanged = function(value: number)
						settings.DesignSpeedKph = value
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
				}),
			},
		}),
		ManualBank = settings.SuperelevationMode == "Manual" and e(LabeledRow, {
			Label = "Bank angle (deg)",
			LayoutOrder = 13,
			children = {
				Field = e(Components.NumberField, {
					Value = settings.ManualBankDeg,
					Min = 0,
					Max = 30,
					OnChanged = function(value: number)
						settings.ManualBankDeg = value
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
				}),
			},
		}),

		PlacementSection = e(Components.Section, {
			Text = "Placement",
			LayoutOrder = 20,
		}),
		SnapRadius = e(LabeledRow, {
			Label = "Snap radius (studs)",
			LayoutOrder = 21,
			children = {
				Field = e(Components.NumberField, {
					Value = settings.SnapRadiusStuds,
					Min = 0,
					Max = 64,
					OnChanged = function(value: number)
						settings.SnapRadiusStuds = value
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
				}),
			},
		}),
		SnapToGrid = e(Components.Checkbox, {
			Label = "Snap to grid",
			Checked = settings.SnapToGrid,
			OnToggled = function(checked: boolean)
				settings.SnapToGrid = checked
				props.OnSettingsChanged()
			end,
			LayoutOrder = 22,
		}),
		GridSize = settings.SnapToGrid and e(LabeledRow, {
			Label = "Grid size (studs)",
			LayoutOrder = 23,
			children = {
				Field = e(Components.NumberField, {
					Value = settings.GridSizeStuds,
					Min = 0.5,
					Max = 64,
					OnChanged = function(value: number)
						settings.GridSizeStuds = value
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
				}),
			},
		}),
		ElevationStep = e(LabeledRow, {
			Label = "Elevation step (studs)",
			LayoutOrder = 24,
			children = {
				Field = e(Components.NumberField, {
					Value = settings.ElevationStepStuds,
					Min = 0.25,
					Max = 32,
					OnChanged = function(value: number)
						settings.ElevationStepStuds = value
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
				}),
			},
		}),

		QualitySection = e(Components.Section, {
			Text = "Geometry",
			LayoutOrder = 30,
		}),
		Thickness = e(LabeledRow, {
			Label = "Road thickness (studs)",
			LayoutOrder = 31,
			children = {
				Field = e(Components.NumberField, {
					Value = settings.RoadThicknessStuds,
					Min = 0.1,
					Max = 16,
					OnChanged = function(value: number)
						settings.RoadThicknessStuds = value
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
				}),
			},
		}),
		SegmentLength = e(LabeledRow, {
			Label = "Max segment (studs)",
			LayoutOrder = 32,
			children = {
				Field = e(Components.NumberField, {
					Value = settings.MaxSegmentLengthStuds,
					Min = 2,
					Max = 64,
					OnChanged = function(value: number)
						settings.MaxSegmentLengthStuds = value
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
				}),
			},
		}),
	})
end

local function KeybindsPage(props: { LayoutOrder: number })
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
		Section = e(Components.Section, { Text = "Placement", LayoutOrder = 1 }),
		Elevation = e(KeybindRow, { Action = "Raise / lower elevation", Keys = "R / F", LayoutOrder = 2 }),
		Cancel = e(KeybindRow, {
			Action = "Cancel placement",
			Keys = "Esc, right-click, or middle-click",
			LayoutOrder = 3,
		}),
		Note = e(Components.Label, {
			Text = "Right-click also orbits the camera in Studio - middle-click "
				.. "cancels without that conflict. Rebindable keys aren't in yet.",
			Dim = true,
			LayoutOrder = 4,
		}),
	})
end

local function SettingsGui(props: {
	Settings: Settings.EasyRoadSettings,
	OnSettingsChanged: () -> (),
	OnClose: () -> (),
})
	local tab: SettingsTab, setTab = React.useState("Regional" :: SettingsTab)

	-- Renders directly into the docked Studio sidebar panel - already a
	-- bordered container, so no glass card / corner radius of its own here,
	-- just a small inward indent so content doesn't touch the panel edges.
	return e("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.PANEL,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(1, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
	}, {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, Theme.PADDING + 5),
			PaddingRight = UDim.new(0, Theme.PADDING + 5),
			PaddingTop = UDim.new(0, Theme.PADDING + 5),
			PaddingBottom = UDim.new(0, Theme.PADDING + 5),
		}),
		Tabs = e(Components.Row, { LayoutOrder = 1 }, {
			Regional = e(Components.Button, {
				Text = "Regional Preference",
				Selected = tab == "Regional",
				OnClick = function()
					setTab("Regional")
				end,
				LayoutOrder = 1,
				Grow = true,
			}),
			Keybinds = e(Components.Button, {
				Text = "Keybinds",
				Selected = tab == "Keybinds",
				OnClick = function()
					setTab("Keybinds")
				end,
				LayoutOrder = 2,
				Grow = true,
			}),
		}),
		Page = if tab == "Regional"
			then e(RegionalPreferencePage, {
				Settings = props.Settings,
				OnSettingsChanged = props.OnSettingsChanged,
				LayoutOrder = 2,
			})
			else e(KeybindsPage, { LayoutOrder = 2 }),
		Close = e(Components.Button, {
			Text = "Close",
			OnClick = props.OnClose,
			LayoutOrder = 100,
		}),
	})
end

return SettingsGui
