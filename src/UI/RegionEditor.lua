--!strict
-- Custom region profile editor: every RegionStyles.RegionStyle field,
-- grouped into sections - mirrors ProfileFields.lua's role for RoadProfile,
-- but for a region preset (traffic layout, dimensions, markings, colours,
-- superelevation limits) instead of a lane cross-section.
--
-- Presentation-only, same clone-and-transform convention as RoadDesigner:
-- everything operates on a RegionStyle via OnChange, the caller owns the
-- draft and persistence.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")
local Locale = require("../Locale")
local Units = require("../Units")

local LINE_TYPE_OPTIONS: { Components.DropdownOption } = {
	{ Id = "None", Text = "None" },
	{ Id = "Solid", Text = "Solid" },
	{ Id = "Dashed", Text = "Dashed" },
	{ Id = "DoubleSolid", Text = "Double solid" },
	{ Id = "DoubleDashed", Text = "Double dashed" },
	{ Id = "SolidDash", Text = "Solid | Dash" },
	{ Id = "DashSolid", Text = "Dash | Solid" },
}

local function isDashedLine(line: RegionStyles.LineType): boolean
	return line == "Dashed" or line == "DoubleDashed"
end

local function LabeledRow(props: {
	Label: string,
	LayoutOrder: number,
	children: { [string]: any },
})
	local children: { [string]: any } = {
		Label = e(Components.Label, { Text = props.Label, LayoutOrder = 1, Width = 130 }),
	}
	for key, child in props.children do
		children[key] = child
	end
	return e(Components.Row, { LayoutOrder = props.LayoutOrder }, children)
end

-- One CenterLine/LaneLine/EdgeLine row group: line style, colour, and (only
-- when dashed) dash length/gap - returns its built children plus the next
-- free LayoutOrder, same "build a dict, return the next order" pattern
-- KeybindsGui.lua's ActionSection uses.
local function MarkingFields(props: {
	Label: string,
	Spec: RegionStyles.MarkingSpec,
	Settings: Settings.EasyRoadSettings,
	StartOrder: number,
	OnChanged: (spec: RegionStyles.MarkingSpec) -> (),
}): ({ [string]: any }, number)
	local order = props.StartOrder
	local spec = props.Spec
	local children: { [string]: any } = {}

	local function patch(fields: { [string]: any })
		local merged: RegionStyles.MarkingSpec = {
			Line = spec.Line,
			Color = spec.Color,
			DashLengthM = spec.DashLengthM,
			DashGapM = spec.DashGapM,
		}
		for key, value in fields do
			(merged :: any)[key] = value
		end
		props.OnChanged(merged)
	end

	children["Header" .. order] = e(Components.Label, { Text = props.Label, Dim = true, LayoutOrder = order })
	order += 1

	children["Line" .. order] = e(LabeledRow, {
		Label = "Line style",
		LayoutOrder = order,
		children = {
			Dropdown = e(Components.Dropdown, {
				Options = LINE_TYPE_OPTIONS,
				SelectedId = spec.Line,
				OnSelected = function(id: string)
					patch({ Line = id :: RegionStyles.LineType })
				end,
				LayoutOrder = 2,
				Grow = true,
			}),
		},
	})
	order += 1

	children["Color" .. order] = e(LabeledRow, {
		Label = "Colour",
		LayoutOrder = order,
		children = {
			Field = e(Components.ColorField, {
				Value = spec.Color,
				OnChanged = function(color: Color3)
					patch({ Color = color })
				end,
				LayoutOrder = 2,
			}),
		},
	})
	order += 1

	if isDashedLine(spec.Line) then
		local dashLength, dashLengthMin, dashLengthMax =
			Units.LengthField(props.Settings, spec.DashLengthM or 2, 0.1, 20)
		children["DashLength" .. order] = e(LabeledRow, {
			Label = "Dash length (" .. Units.LengthSuffix(props.Settings) .. ")",
			LayoutOrder = order,
			children = {
				Field = e(Components.NumberField, {
					Value = dashLength,
					Min = dashLengthMin,
					Max = dashLengthMax,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						patch({ DashLengthM = Units.LengthToM(props.Settings, value) })
					end,
				}),
			},
		})
		order += 1
		local dashGap, dashGapMin, dashGapMax = Units.LengthField(props.Settings, spec.DashGapM or 4, 0.1, 20)
		children["DashGap" .. order] = e(LabeledRow, {
			Label = "Dash gap (" .. Units.LengthSuffix(props.Settings) .. ")",
			LayoutOrder = order,
			children = {
				Field = e(Components.NumberField, {
					Value = dashGap,
					Min = dashGapMin,
					Max = dashGapMax,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						patch({ DashGapM = Units.LengthToM(props.Settings, value) })
					end,
				}),
			},
		})
		order += 1
	end

	return children, order
end

local function RegionEditor(props: {
	Style: RegionStyles.RegionStyle,
	Settings: Settings.EasyRoadSettings,
	OnChange: (transform: (style: RegionStyles.RegionStyle) -> ()) -> (),
	OnSave: () -> (),
	OnDelete: (() -> ())?,
	OnCancel: () -> (),
})
	local style = props.Style

	local function set(key: string, value: any)
		props.OnChange(function(copy)
			(copy :: any)[key] = value
		end)
	end

	local children: { [string]: any } = {}
	local order = 1

	children.Header = e(Components.Section, { Text = "Region Preset", First = true, LayoutOrder = order })
	order += 1

	children.Name = e(LabeledRow, {
		Label = "Name",
		LayoutOrder = order,
		children = {
			Field = e(Components.TextField, {
				Value = style.Name,
				OnChanged = function(value: string)
					set("Name", value)
				end,
				LayoutOrder = 2,
			}),
		},
	})
	order += 1

	children.DriveSide = e(Components.Checkbox, {
		Label = "Drives on the left",
		Checked = style.DriveOnLeft,
		OnToggled = function(checked: boolean)
			set("DriveOnLeft", checked)
		end,
		LayoutOrder = order,
	})
	order += 1

	children.DimensionsSection = e(Components.Section, {
		Text = "Dimensions (" .. Units.LengthSuffix(props.Settings) .. ")",
		LayoutOrder = order,
	})
	order += 1

	local dimensionFields: { { Label: string, Key: string, Min: number, Max: number } } = {
		{ Label = "Lane width", Key = "DefaultLaneWidthM", Min = 1, Max = 8 },
		{ Label = Locale.Term(props.Settings, "PavementWidth"), Key = "SidewalkWidthM", Min = 0, Max = 6 },
		{ Label = "Shoulder width", Key = "ShoulderWidthM", Min = 0, Max = 6 },
		{ Label = "Median width", Key = "MedianWidthM", Min = 0, Max = 10 },
		{ Label = "Bike lane width", Key = "BikeLaneWidthM", Min = 0, Max = 4 },
		{ Label = "Parking lane width", Key = "ParkingLaneWidthM", Min = 0, Max = 5 },
		{ Label = Locale.Term(props.Settings, "KerbHeight"), Key = "CurbHeightM", Min = 0, Max = 0.5 },
	}
	for _, field in dimensionFields do
		local shown, shownMin, shownMax =
			Units.LengthField(props.Settings, (style :: any)[field.Key], field.Min, field.Max)
		children[field.Key] = e(LabeledRow, {
			Label = field.Label,
			LayoutOrder = order,
			children = {
				Field = e(Components.NumberField, {
					Value = shown,
					Min = shownMin,
					Max = shownMax,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						set(field.Key, Units.LengthToM(props.Settings, value))
					end,
				}),
			},
		})
		order += 1
	end

	children.RoundaboutSection = e(Components.Section, { Text = "Roundabouts", LayoutOrder = order })
	order += 1
	-- `~= false` rather than `== true`: nil means "never set", which reads as
	-- enabled, so a region predating these fields shows the behaviour it has.
	children.RoundaboutSidewalk = e(Components.Checkbox, {
		Label = "Ring has a pavement",
		Checked = style.RoundaboutSidewalk ~= false,
		LayoutOrder = order,
		OnToggled = function(value: boolean)
			set("RoundaboutSidewalk", value)
		end,
	})
	order += 1
	children.RoundaboutIsland = e(Components.Checkbox, {
		Label = "Raised centre island",
		Checked = style.RoundaboutIsland ~= false,
		LayoutOrder = order,
		OnToggled = function(value: boolean)
			set("RoundaboutIsland", value)
		end,
	})
	order += 1
	children.RoundaboutMarkings = e(LabeledRow, {
		Label = "Circulating lane markings",
		LayoutOrder = order,
		children = {
			Dropdown = e(Components.Dropdown, {
				Options = {
					{ Id = "Continuous", Text = "Continuous - dashed between lanes" },
					{ Id = "SolidLanes", Text = "Solid dividers between lanes" },
					{ Id = "Turbo", Text = "Turbo - lanes spiral out to the exits" },
				},
				-- nil reads as Continuous, so a region that predates this field
				-- shows the behaviour it actually has rather than an empty box.
				SelectedId = style.RoundaboutMarkings or "Continuous",
				OnSelected = function(id: string)
					set("RoundaboutMarkings", id :: RegionStyles.RoundaboutMarkingStyle)
				end,
				LayoutOrder = 2,
				Grow = true,
			}),
		},
	})
	order += 1

	children.SuperelevationSection = e(Components.Section, { Text = "Superelevation limits", LayoutOrder = order })
	order += 1
	children.MaxSuperelevation = e(LabeledRow, {
		Label = "Max cross slope (ratio)",
		LayoutOrder = order,
		children = {
			Field = e(Components.NumberField, {
				Value = style.MaxSuperelevation,
				Min = 0,
				Max = 0.15,
				LayoutOrder = 2,
				OnChanged = function(value: number)
					set("MaxSuperelevation", value)
				end,
			}),
		},
	})
	order += 1
	local designSpeed, designSpeedMin, designSpeedMax = Units.SpeedField(props.Settings, style.DesignSpeedKph, 10, 200)
	children.DesignSpeed = e(LabeledRow, {
		Label = "Design speed (" .. Units.SpeedSuffix(props.Settings) .. ")",
		LayoutOrder = order,
		children = {
			Field = e(Components.NumberField, {
				Value = designSpeed,
				Min = designSpeedMin,
				Max = designSpeedMax,
				LayoutOrder = 2,
				OnChanged = function(value: number)
					set("DesignSpeedKph", Units.SpeedToKph(props.Settings, value))
				end,
			}),
		},
	})
	order += 1

	children.MarkingsSection = e(Components.Section, { Text = "Markings", LayoutOrder = order })
	order += 1

	local centerFields, afterCenter = MarkingFields({
		Label = "Center line (opposing traffic)",
		Spec = style.CenterLine,
		Settings = props.Settings,
		StartOrder = order,
		OnChanged = function(spec: RegionStyles.MarkingSpec)
			set("CenterLine", spec)
		end,
	})
	for key, child in centerFields do
		children[key] = child
	end
	order = afterCenter

	local laneFields, afterLane = MarkingFields({
		Label = "Lane line (same-direction lanes)",
		Spec = style.LaneLine,
		Settings = props.Settings,
		StartOrder = order,
		OnChanged = function(spec: RegionStyles.MarkingSpec)
			set("LaneLine", spec)
		end,
	})
	for key, child in laneFields do
		children[key] = child
	end
	order = afterLane

	local edgeFields, afterEdge = MarkingFields({
		Label = "Edge line (roadway outer edge)",
		Spec = style.EdgeLine,
		Settings = props.Settings,
		StartOrder = order,
		OnChanged = function(spec: RegionStyles.MarkingSpec)
			set("EdgeLine", spec)
		end,
	})
	for key, child in edgeFields do
		children[key] = child
	end
	order = afterEdge

	local trafficLeftEdgeFields, afterTrafficLeftEdge = MarkingFields({
		Label = "Traffic-left edge line",
		Spec = style.TrafficLeftEdgeLine or style.EdgeLine,
		Settings = props.Settings,
		StartOrder = order,
		OnChanged = function(spec: RegionStyles.MarkingSpec)
			set("TrafficLeftEdgeLine", spec)
		end,
	})
	for key, child in trafficLeftEdgeFields do
		children["TrafficLeft" .. key] = child
	end
	order = afterTrafficLeftEdge

	children.MarkingWidth = e(LabeledRow, {
		Label = "Marking width (" .. Units.LengthSuffix(props.Settings) .. ")",
		LayoutOrder = order,
		children = {
			Field = e(Components.NumberField, {
				Value = Units.LengthFromM(props.Settings, style.MarkingWidthM),
				Min = Units.LengthFromM(props.Settings, 0.02),
				Max = Units.LengthFromM(props.Settings, 0.5),
				LayoutOrder = 2,
				OnChanged = function(value: number)
					set("MarkingWidthM", Units.LengthToM(props.Settings, value))
				end,
			}),
		},
	})
	order += 1
	children.FallbackDashLength = e(LabeledRow, {
		Label = "Fallback dash length (" .. Units.LengthSuffix(props.Settings) .. ")",
		LayoutOrder = order,
		children = {
			Field = e(Components.NumberField, {
				Value = Units.LengthFromM(props.Settings, style.DashLengthM),
				Min = Units.LengthFromM(props.Settings, 0.1),
				Max = Units.LengthFromM(props.Settings, 20),
				LayoutOrder = 2,
				OnChanged = function(value: number)
					set("DashLengthM", Units.LengthToM(props.Settings, value))
				end,
			}),
		},
	})
	order += 1
	children.FallbackDashGap = e(LabeledRow, {
		Label = "Fallback dash gap (" .. Units.LengthSuffix(props.Settings) .. ")",
		LayoutOrder = order,
		children = {
			Field = e(Components.NumberField, {
				Value = Units.LengthFromM(props.Settings, style.DashGapM),
				Min = Units.LengthFromM(props.Settings, 0.1),
				Max = Units.LengthFromM(props.Settings, 20),
				LayoutOrder = 2,
				OnChanged = function(value: number)
					set("DashGapM", Units.LengthToM(props.Settings, value))
				end,
			}),
		},
	})
	order += 1
	children.WhiteMarking = e(LabeledRow, {
		Label = "White marking colour",
		LayoutOrder = order,
		children = {
			Field = e(Components.ColorField, {
				Value = style.WhiteMarking,
				OnChanged = function(color: Color3)
					set("WhiteMarking", color)
				end,
				LayoutOrder = 2,
			}),
		},
	})
	order += 1
	children.YellowMarking = e(LabeledRow, {
		Label = "Yellow marking colour",
		LayoutOrder = order,
		children = {
			Field = e(Components.ColorField, {
				Value = style.YellowMarking,
				OnChanged = function(color: Color3)
					set("YellowMarking", color)
				end,
				LayoutOrder = 2,
			}),
		},
	})
	order += 1

	children.AppearanceSection = e(Components.Section, { Text = "Surface colours", LayoutOrder = order })
	order += 1

	local colorFields: { { Label: string, Key: string } } = {
		{ Label = "Asphalt", Key = "AsphaltColor" },
		{ Label = "Shoulder", Key = "ShoulderColor" },
		{ Label = Locale.Term(props.Settings, "Pavement"), Key = "SidewalkColor" },
		{ Label = Locale.Term(props.Settings, "Kerb"), Key = "CurbColor" },
		{ Label = "Median", Key = "MedianColor" },
		{ Label = "Bike lane", Key = "BikeLaneColor" },
		{ Label = "Bus/taxi bay", Key = "BayColor" },
	}
	for _, field in colorFields do
		children[field.Key] = e(LabeledRow, {
			Label = field.Label,
			LayoutOrder = order,
			children = {
				Field = e(Components.ColorField, {
					Value = (style :: any)[field.Key],
					OnChanged = function(color: Color3)
						set(field.Key, color)
					end,
					LayoutOrder = 2,
				}),
			},
		})
		order += 1
	end

	children.Actions = e(Components.Row, { LayoutOrder = 1000 }, {
		Save = e(Components.Button, {
			Text = if style.BuiltIn then "Save as Copy" else "Save",
			Selected = true,
			OnClick = props.OnSave,
			LayoutOrder = 1,
			Grow = true,
		}),
		Delete = props.OnDelete and e(Components.Button, {
			Text = "Delete",
			Danger = true,
			OnClick = props.OnDelete :: () -> (),
			LayoutOrder = 2,
			Grow = true,
		}),
		Cancel = e(Components.Button, {
			Text = "Cancel",
			OnClick = props.OnCancel,
			LayoutOrder = 3,
			Grow = true,
		}),
	})

	local scrollProps = Components.ScrollBar()
	scrollProps.Size = UDim2.fromScale(1, 1)
	scrollProps.BackgroundTransparency = 1
	scrollProps.BorderSizePixel = 0
	scrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollProps.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollProps.ScrollingDirection = Enum.ScrollingDirection.Y

	children.Layout = e("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 4),
	})

	return e("ScrollingFrame", scrollProps, children)
end

return RegionEditor
