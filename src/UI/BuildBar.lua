--!strict
-- The tool mode panel: compact CS2-style placement panel, one of two
-- separate floating boxes shown side by side while placing roads (the
-- other is RoadLibraryPanel.lua, which road to place) - matching the CS2
-- reference layout, not one box with everything stacked on top of itself.
--
-- Placement controls only - tool mode, widen/narrow transition target,
-- banking, elevation and hints. Which road to place lives in
-- RoadLibraryPanel; creating or editing road types is the Road Editor's
-- job (the full designer); the grand settings live in the docked sidebar
-- panel.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RoadDesigner = require("./RoadDesigner")
local RoadLibraryModule = require("../RoadLibrary")
local Settings = require("../Settings")
local Units = require("../Units")
local Keybinds = require("../Keybinds")
local RoadInstance = require("../RoadInstance")
local StructureAssets = require("../StructureAssets")
local StructureControls = require("./StructureControls")

local function keyHint(bindings: { string }): string
	local labels = {}
	for _, bound in bindings do
		table.insert(labels, Keybinds.Describe(bound))
	end
	return table.concat(labels, "/")
end

type RoadLibrary = RoadLibraryModule.RoadLibrary

local TOOL_ICONS: { [string]: string } = {
	Straight = "rbxassetid://80355330590276",
	Curve = "rbxassetid://90102359516465",
	Freeform = "rbxassetid://112290052468250",
}

local function ToolButton(props: {
	Mode: string,
	Label: string,
	Selected: boolean,
	OnClick: () -> (),
	LayoutOrder: number,
})
	local hovered, setHovered = React.useState(false)
	local color = if props.Selected
		then (if hovered then Theme.ACCENT_HOVER else Theme.SELECTED)
		elseif hovered then Theme.BUTTON_HOVER
		else Theme.BUTTON

	-- Fixed-share width (not auto-sized to text) so three of these always
	-- fit the tool card's fixed width without spilling past its edge.
	return e("TextButton", {
		Text = "",
		BackgroundColor3 = color,
		BackgroundTransparency = if props.Selected then 0.1 else Theme.GLASS_ELEMENT_TRANSPARENCY,
		Size = UDim2.new(0, 0, 0, 52),
		LayoutOrder = props.LayoutOrder,
		[React.Event.Activated] = props.OnClick,
		[React.Event.MouseEnter] = function()
			setHovered(true)
		end,
		[React.Event.MouseLeave] = function()
			setHovered(false)
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 6) }),
		Flex = e("UIFlexItem", { FlexMode = Enum.UIFlexMode.Grow }),
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 1),
		}),
		Icon = e("ImageLabel", {
			Image = TOOL_ICONS[props.Mode] or "",
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 26, 0, 26),
			ScaleType = Enum.ScaleType.Fit,
			LayoutOrder = 1,
		}),
		-- Label only shows on hover, tooltip-style, so the icon alone
		-- identifies the tool the rest of the time.
		Label = hovered and e("TextLabel", {
			Text = props.Label,
			TextColor3 = Theme.WHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 14),
			Font = Theme.FONT,
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = 2,
		}),
	})
end

local function BuildBar(props: {
	ToolMode: string,
	SetToolMode: (mode: string) -> (),
	Library: RoadLibrary,
	EndProfileId: string?,
	SetEndProfileId: (id: string?) -> (),
	Settings: Settings.EasyRoadSettings,
	OnSettingsChanged: () -> (),
	Hint: string,
	Elevation: number,
	AdjustElevation: (delta: number) -> (),
	SetElevation: (value: number) -> (),
	Structure: RoadInstance.StructureData,
	StructureAssets: { StructureAssets.AssetInfo },
	StructureStatus: string?,
	SetStructure: (structure: RoadInstance.StructureData) -> (),
	RoundaboutRadius: number,
	SetRoundaboutRadius: (value: number) -> (),
	RoundaboutLaneCount: number,
	SetRoundaboutLaneCount: (value: number) -> (),
	RoundaboutLaneWidth: number,
	SetRoundaboutLaneWidth: (value: number) -> (),
	OnStop: () -> (),
})
	local endProfileOptions: { Components.DropdownOption } = {
		{ Id = "__none", Text = "None (constant width)" },
	}
	for _, libraryProfile in props.Library.GetAll() do
		table.insert(endProfileOptions, { Id = libraryProfile.Id, Text = libraryProfile.Name })
	end

	local children: { [string]: any } = {}
	RoadDesigner.DecorateCard(children)
	children.Header = e(Components.Section, { Text = "Road Tool", First = true, LayoutOrder = 1 })
	children.Tools = e(Components.Row, { LayoutOrder = 2 }, {
		Straight = e(ToolButton, {
			Mode = "Straight",
			Label = "Straight",
			Selected = props.ToolMode == "Straight",
			OnClick = function()
				props.SetToolMode("Straight")
			end,
			LayoutOrder = 1,
		}),
		Curve = e(ToolButton, {
			Mode = "Curve",
			Label = "Curve",
			Selected = props.ToolMode == "Curve",
			OnClick = function()
				props.SetToolMode("Curve")
			end,
			LayoutOrder = 2,
		}),
		Freeform = e(ToolButton, {
			Mode = "Freeform",
			Label = "Free",
			Selected = props.ToolMode == "Freeform",
			OnClick = function()
				props.SetToolMode("Freeform")
			end,
			LayoutOrder = 3,
		}),
		Roundabout = e(ToolButton, {
			Mode = "Roundabout",
			Label = "Roundabout",
			Selected = props.ToolMode == "Roundabout",
			OnClick = function()
				props.SetToolMode("Roundabout")
			end,
			LayoutOrder = 4,
		}),
	})
	if props.ToolMode == "Roundabout" then
		children.RoundaboutRadius = e(Components.Row, { LayoutOrder = 3 }, {
			Label = e(Components.Label, { Text = "Radius", LayoutOrder = 1, Width = 60 }),
			Field = e(Components.NumberField, {
				Value = props.RoundaboutRadius,
				Min = 5,
				OnChanged = props.SetRoundaboutRadius,
				LayoutOrder = 2,
			}),
			Unit = e(Components.Label, { Text = "studs", Dim = true, LayoutOrder = 3 }),
		})
		children.RoundaboutLaneCount = e(Components.Row, { LayoutOrder = 4 }, {
			Label = e(Components.Label, { Text = "Lanes", LayoutOrder = 1, Width = 60 }),
			Field = e(Components.NumberField, {
				Value = props.RoundaboutLaneCount,
				Min = 1,
				Max = 6,
				OnChanged = function(value: number)
					props.SetRoundaboutLaneCount(math.floor(value))
				end,
				LayoutOrder = 2,
			}),
		})
		children.RoundaboutLaneWidth = e(Components.Row, { LayoutOrder = 5 }, {
			Label = e(Components.Label, { Text = "Lane width", LayoutOrder = 1, Width = 60 }),
			Field = e(Components.NumberField, {
				Value = Units.LengthFromM(props.Settings, props.RoundaboutLaneWidth),
				Min = Units.LengthFromM(props.Settings, 1),
				OnChanged = function(value: number)
					props.SetRoundaboutLaneWidth(Units.LengthToM(props.Settings, value))
				end,
				LayoutOrder = 2,
			}),
			Unit = e(Components.Label, {
				Text = Units.LengthSuffix(props.Settings),
				Dim = true,
				LayoutOrder = 3,
			}),
		})
		children.RoundaboutEntryCurve = e(Components.Checkbox, {
			Label = "Deflected entries / exits",
			Checked = props.Settings.RoundaboutEntryCurve,
			OnToggled = function(checked: boolean)
				props.Settings.RoundaboutEntryCurve = checked
				props.OnSettingsChanged()
			end,
			LayoutOrder = 5,
		})
	end
	children.SnapToRoadToggle = e(Components.Checkbox, {
		Label = "Snap to existing road",
		Checked = props.Settings.SnapToRoad,
		OnToggled = function(checked: boolean)
			props.Settings.SnapToRoad = checked
			props.OnSettingsChanged()
		end,
		LayoutOrder = 6,
	})
	children.SnapToGridToggle = e(Components.Checkbox, {
		Label = "Snap to grid",
		Checked = props.Settings.SnapToGrid,
		OnToggled = function(checked: boolean)
			props.Settings.SnapToGrid = checked
			props.OnSettingsChanged()
		end,
		LayoutOrder = 7,
	})
	children.Transition = e(Components.Row, { LayoutOrder = 8 }, {
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
		LayoutOrder = 9,
	})
	local speedShown, speedMin, speedMax = Units.SpeedField(props.Settings, props.Settings.DesignSpeedKph, 10, 200)
	children.Speed = props.Settings.SuperelevationMode ~= "Off"
		and e(Components.Row, { LayoutOrder = 10 }, {
			Label = e(Components.Label, {
				Text = "Speed (" .. Units.SpeedSuffix(props.Settings) .. ")",
				LayoutOrder = 1,
				Width = 90,
			}),
			Field = e(Components.NumberField, {
				Value = speedShown,
				Min = speedMin,
				Max = speedMax,
				OnChanged = function(value: number)
					props.Settings.DesignSpeedKph = Units.SpeedToKph(props.Settings, value)
					props.OnSettingsChanged()
				end,
				LayoutOrder = 2,
			}),
		})
	-- Same setting Regional Preference's Superelevation section exposes -
	-- surfaced here too so the transition feel can be dialled in while
	-- actually placing roads, without leaving the tool for a settings dock.
	-- Named distinctly from children.Transition above (the "Widen to" row) -
	-- both used the same key at one point, which silently dropped whichever
	-- rendered second from the panel entirely.
	local runoffShown, runoffMin, runoffMax =
		Units.LengthField(props.Settings, props.Settings.SuperelevationRunoffM, 2, 30)
	children.BankTransition = props.Settings.SuperelevationMode ~= "Off"
		and e(Components.Row, { LayoutOrder = 11 }, {
			Label = e(Components.Label, {
				Text = "Transition (" .. Units.LengthSuffix(props.Settings) .. ")",
				LayoutOrder = 1,
				Width = 90,
			}),
			Slider = e(Components.Slider, {
				Value = runoffShown,
				Min = runoffMin,
				Max = runoffMax,
				ValueSuffix = " " .. Units.LengthSuffix(props.Settings),
				OnChanged = function(value: number)
					props.Settings.SuperelevationRunoffM = Units.LengthToM(props.Settings, value)
					props.OnSettingsChanged()
				end,
				LayoutOrder = 2,
			}),
		})
	children.Elevation = e(Components.Row, { LayoutOrder = 12 }, {
		Label = e(Components.Label, { Text = "Elevation", LayoutOrder = 1, Width = 64 }),
		Down = e(Components.Button, {
			Text = "",
			Icon = "rbxassetid://6034818372",
			OnClick = function()
				props.AdjustElevation(-props.Settings.ElevationStepStuds)
			end,
			LayoutOrder = 2,
			Size = UDim2.new(0, 26, 0, Theme.ROW_HEIGHT),
		}),
		-- Directly editable (type a height, no "+" prefix on positive values
		-- - only negative elevations show a sign) rather than a read-only
		-- label, so setting an exact height doesn't require nudging by
		-- ElevationStepStuds one click at a time.
		Value = e(Components.NumberField, {
			Value = props.Elevation,
			Width = 56,
			OnChanged = props.SetElevation,
			LayoutOrder = 3,
		}),
		Unit = e(Components.Label, { Text = "studs", Dim = true, LayoutOrder = 4 }),
		Up = e(Components.Button, {
			Text = "",
			Icon = "rbxassetid://6034818379",
			OnClick = function()
				props.AdjustElevation(props.Settings.ElevationStepStuds)
			end,
			LayoutOrder = 5,
			Size = UDim2.new(0, 26, 0, Theme.ROW_HEIGHT),
		}),
	})
	-- CS2-style step adjustment: how far each R/F press or arrow click
	-- moves the elevation, editable right next to the elevation control
	-- instead of buried in a separate settings dock.
	children.ElevationStep = e(Components.Row, { LayoutOrder = 13 }, {
		Label = e(Components.Label, { Text = "Step", Dim = true, LayoutOrder = 1, Width = 64 }),
		Field = e(Components.NumberField, {
			Value = props.Settings.ElevationStepStuds,
			Min = 0.1,
			Width = 56,
			OnChanged = function(value: number)
				props.Settings.ElevationStepStuds = value
				props.OnSettingsChanged()
			end,
			LayoutOrder = 2,
		}),
		Unit = e(Components.Label, { Text = "studs / press", Dim = true, LayoutOrder = 3 }),
	})
	children.ElevationHint = e(Components.Label, {
		Text = string.format(
			"(or %s / %s keys)",
			keyHint(props.Settings.Keybinds.ElevationUp),
			keyHint(props.Settings.Keybinds.ElevationDown)
		),
		Dim = true,
		LayoutOrder = 14,
	})
	-- Keep the mode visible directly below the tool picker. This is the main
	-- placement workflow, so hiding it below every snapping/banking/elevation
	-- option would recreate the discoverability failure of the old inspector-
	-- only implementation. Roundabouts do not use RoadInstance structures.
	children.Structure = props.ToolMode ~= "Roundabout" and e(StructureControls, {
		Structure = props.Structure,
		Assets = props.StructureAssets,
		Status = props.StructureStatus,
		OnChange = props.SetStructure,
		LayoutOrder = 3,
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
		LayoutOrder = 16,
	})
	children.Stop = e(Components.Button, {
		Text = "Stop Building",
		Danger = true,
		OnClick = props.OnStop,
		LayoutOrder = 17,
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

return BuildBar
