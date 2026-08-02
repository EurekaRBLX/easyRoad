--!strict
-- Regional Preference: region style, scale, superelevation, snapping, and
-- geometry quality. Docked on its own (see Keybinds for the other half of
-- what used to be one tabbed settings panel).

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RegionEditor = require("./RegionEditor")
local RegionStyles = require("../RegionStyles")
local RegionLibraryModule = require("../RegionLibrary")
local Settings = require("../Settings")
local StructureBuilder = require("../StructureBuilder")
local StructureMaterials = require("../StructureMaterials")
local Units = require("../Units")

type RegionLibrary = RegionLibraryModule.RegionLibrary

local materialOptions: { Components.DropdownOption } = {}
for _, entry in StructureMaterials.Entries do
	table.insert(materialOptions, { Id = entry.Id, Text = entry.Text })
end

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

local function FinishDefaults(props: {
	Label: string,
	ColorHex: string,
	Material: StructureMaterials.MaterialName,
	LayoutOrder: number,
	OnColorChanged: (color: Color3) -> (),
	OnMaterialChanged: (material: StructureMaterials.MaterialName) -> (),
})
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, {
		Layout = e("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
		Header = e(Components.Section, { Text = props.Label, LayoutOrder = 1 }),
		Material = e(LabeledRow, {
			Label = "Material",
			LayoutOrder = 2,
			children = {
				Dropdown = e(Components.Dropdown, {
					Options = materialOptions,
					SelectedId = props.Material,
					Grow = true,
					LayoutOrder = 2,
					OnSelected = function(id: string)
						props.OnMaterialChanged(StructureMaterials.Sanitize(id))
					end,
				}),
			},
		}),
		ColorLabel = e(Components.Label, { Text = "Colour", Dim = true, LayoutOrder = 3 }),
		Color = e(Components.ColorField, {
			Value = StructureBuilder.ColorFromHex(props.ColorHex),
			LayoutOrder = 4,
			OnChanged = props.OnColorChanged,
		}),
	})
end

local function RegionalPreferenceGui(props: {
	Settings: Settings.EasyRoadSettings,
	RegionLibrary: RegionLibrary,
	OnSettingsChanged: () -> (),
	OnClose: () -> (),
})
	local settings = props.Settings
	local regionLibrary = props.RegionLibrary
	local editingRegion, setEditingRegion = React.useState(nil :: RegionStyles.RegionStyle?)

	-- Display-unit conversions for the fields below (see Units.lua). Bounds
	-- convert with the value, or a field shown in mph/ft would be clamped by
	-- km/h/metre limits.
	local speedShown, speedMin, speedMax = Units.SpeedField(settings, settings.DesignSpeedKph, 10, 200)
	local runoffShown, runoffMin, runoffMax = Units.LengthField(settings, settings.SuperelevationRunoffM, 2, 30)

	local activeStyle = regionLibrary.Get(settings.RegionId)

	if editingRegion then
		local editing = editingRegion :: RegionStyles.RegionStyle
		return e(RegionEditor, {
			Style = editing,
			Settings = settings,
			OnChange = function(transform: (style: RegionStyles.RegionStyle) -> ())
				local copy = RegionStyles.Clone(editing)
				transform(copy)
				setEditingRegion(copy)
			end,
			OnSave = function()
				local toSave = RegionStyles.Clone(editing)
				if toSave.BuiltIn then
					-- Editing a built-in preset in place isn't possible - Save
					-- always creates a copy, matching the Road Editor's
					-- "editing a built-in road creates a copy" convention.
					toSave.Id = "user_region_" .. tostring(os.time())
					toSave.Name = toSave.Name .. " (Custom)"
				end
				toSave.BuiltIn = false
				regionLibrary.SaveUserRegion(toSave)
				settings.RegionId = toSave.Id
				setEditingRegion(nil)
				props.OnSettingsChanged()
			end,
			OnDelete = if not editing.BuiltIn
				then function()
					regionLibrary.DeleteUserRegion(editing.Id)
					if settings.RegionId == editing.Id then
						settings.RegionId = "UK"
					end
					setEditingRegion(nil)
					props.OnSettingsChanged()
				end
				else nil,
			OnCancel = function()
				setEditingRegion(nil)
			end,
		})
	end

	local regionOptions: { Components.DropdownOption } = {}
	for _, style in regionLibrary.GetAll() do
		table.insert(regionOptions, { Id = style.Id, Text = style.Name .. (if style.BuiltIn then "" else " (custom)") })
	end

	local superelevationOptions: { Components.DropdownOption } = {
		{ Id = "Auto", Text = "Auto (from speed + curvature)" },
		{ Id = "Manual", Text = "Manual angle" },
		{ Id = "Off", Text = "Off (flat roads)" },
	}

	local scrollProps = Components.ScrollBar()
	scrollProps.Size = UDim2.fromScale(1, 1)
	scrollProps.BackgroundColor3 = Theme.PANEL
	scrollProps.BorderSizePixel = 0
	scrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollProps.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollProps.ScrollingDirection = Enum.ScrollingDirection.Y

	-- Renders directly into the docked Studio sidebar panel - already a
	-- bordered container, so no glass card / corner radius of its own here,
	-- just a small inward indent so content doesn't touch the panel edges.
	return e("ScrollingFrame", scrollProps, {
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

		StyleSection = e(Components.Section, {
			Text = "Road Style",
			First = true,
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
		RegionActions = e(Components.Row, { LayoutOrder = 4 }, {
			Edit = e(Components.Button, {
				Text = if activeStyle.BuiltIn then "Customize This Region" else "Edit This Region",
				OnClick = function()
					setEditingRegion(RegionStyles.Clone(activeStyle))
				end,
				LayoutOrder = 1,
				Grow = true,
			}),
			New = e(Components.Button, {
				Text = "+ New Region",
				OnClick = function()
					local draft = RegionStyles.Clone(activeStyle)
					draft.Id = "user_region_" .. tostring(os.time())
					draft.Name = "New Region"
					draft.BuiltIn = false
					setEditingRegion(draft)
				end,
				LayoutOrder = 2,
				Grow = true,
			}),
		}),
		Scale = e(LabeledRow, {
			Label = "Studs per meter",
			LayoutOrder = 5,
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
			LayoutOrder = 6,
		}),
		Language = e(LabeledRow, {
			Label = "Terminology",
			LayoutOrder = 7,
			children = {
				Dropdown = e(Components.Dropdown, {
					Options = {
						{ Id = "British", Text = "British (Kerb, Pavement)" },
						{ Id = "American", Text = "American (Curb, Sidewalk)" },
					},
					SelectedId = settings.LanguageVariant,
					OnSelected = function(id: string)
						settings.LanguageVariant = id :: Settings.LanguageVariant
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
					Grow = true,
				}),
			},
		}),

		-- Display-only units. Storage stays metric (see Units.lua), so
		-- switching these never changes the geometry that gets built.
		SpeedUnit = e(LabeledRow, {
			Label = "Speed units",
			LayoutOrder = 8,
			children = {
				Dropdown = e(Components.Dropdown, {
					Options = {
						{ Id = "Kmh", Text = "km/h" },
						{ Id = "Mph", Text = "mph" },
					},
					SelectedId = settings.SpeedUnit,
					OnSelected = function(id: string)
						settings.SpeedUnit = id :: Settings.SpeedUnit
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
					Grow = true,
				}),
			},
		}),
		LengthUnit = e(LabeledRow, {
			Label = "Length units",
			LayoutOrder = 9,
			children = {
				Dropdown = e(Components.Dropdown, {
					Options = {
						{ Id = "Meters", Text = "Metres (m)" },
						{ Id = "Feet", Text = "Feet (ft)" },
					},
					SelectedId = settings.LengthUnit,
					OnSelected = function(id: string)
						settings.LengthUnit = id :: Settings.LengthUnit
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
					Grow = true,
				}),
			},
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
			Label = "Design speed (" .. Units.SpeedSuffix(settings) .. ")",
			LayoutOrder = 12,
			children = {
				Field = e(Components.NumberField, {
					Value = speedShown,
					Min = speedMin,
					Max = speedMax,
					OnChanged = function(value: number)
						settings.DesignSpeedKph = Units.SpeedToKph(settings, value)
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
		-- How gradually the bank ramps in/out of a curve, in real-world
		-- meters - a fixed stud constant used to make the transition feel
		-- more abrupt for anyone running a higher studs-per-meter scale
		-- than the ~3.571 default (reported live: "at 6.667stud=>1m ...
		-- it is more abrupt"). Shown regardless of Auto/Manual, since the
		-- runoff taper applies to both - only hidden when banking is Off
		-- entirely and there's nothing to transition.
		TransitionLength = settings.SuperelevationMode ~= "Off" and e(LabeledRow, {
			Label = "Transition length (" .. Units.LengthSuffix(settings) .. ")",
			LayoutOrder = 14,
			children = {
				Slider = e(Components.Slider, {
					Value = runoffShown,
					Min = runoffMin,
					Max = runoffMax,
					ValueSuffix = " " .. Units.LengthSuffix(settings),
					OnChanged = function(value: number)
						settings.SuperelevationRunoffM = Units.LengthToM(settings, value)
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

		StructureSection = e(Components.Section, {
			Text = "Procedural structures",
			LayoutOrder = 40,
		}),
		BaseFinish = e(FinishDefaults, {
			Label = "Structural base, piers, and caps",
			ColorHex = settings.StructureConcreteColorHex,
			Material = settings.StructureBaseMaterial,
			LayoutOrder = 41,
			OnColorChanged = function(color: Color3)
				settings.StructureConcreteColorHex = StructureBuilder.ColorToHex(color)
				props.OnSettingsChanged()
			end,
			OnMaterialChanged = function(material: StructureMaterials.MaterialName)
				settings.StructureBaseMaterial = material
				props.OnSettingsChanged()
			end,
		}),
		ViaductWallFinish = e(FinishDefaults, {
			Label = "Viaduct edge walls",
			ColorHex = settings.ViaductWallColorHex,
			Material = settings.ViaductWallMaterial,
			LayoutOrder = 42,
			OnColorChanged = function(color: Color3)
				settings.ViaductWallColorHex = StructureBuilder.ColorToHex(color)
				props.OnSettingsChanged()
			end,
			OnMaterialChanged = function(material: StructureMaterials.MaterialName)
				settings.ViaductWallMaterial = material
				props.OnSettingsChanged()
			end,
		}),
		TunnelWallFinish = e(FinishDefaults, {
			Label = "Tunnel side walls",
			ColorHex = settings.TunnelWallColorHex,
			Material = settings.TunnelWallMaterial,
			LayoutOrder = 43,
			OnColorChanged = function(color: Color3)
				settings.TunnelWallColorHex = StructureBuilder.ColorToHex(color)
				props.OnSettingsChanged()
			end,
			OnMaterialChanged = function(material: StructureMaterials.MaterialName)
				settings.TunnelWallMaterial = material
				props.OnSettingsChanged()
			end,
		}),
		TunnelRoofFinish = e(FinishDefaults, {
			Label = "Tunnel roof",
			ColorHex = settings.TunnelRoofColorHex,
			Material = settings.TunnelRoofMaterial,
			LayoutOrder = 44,
			OnColorChanged = function(color: Color3)
				settings.TunnelRoofColorHex = StructureBuilder.ColorToHex(color)
				props.OnSettingsChanged()
			end,
			OnMaterialChanged = function(material: StructureMaterials.MaterialName)
				settings.TunnelRoofMaterial = material
				props.OnSettingsChanged()
			end,
		}),
		StructureOverlap = e(LabeledRow, {
			Label = "Road overlap (m)",
			LayoutOrder = 45,
			children = {
				Field = e(Components.NumberField, {
					Value = settings.StructureInterfaceOverlapM,
					Min = 0,
					Max = 2,
					OnChanged = function(value: number)
						settings.StructureInterfaceOverlapM = value
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
				}),
			},
		}),
		ParapetGap = e(LabeledRow, {
			Label = "Viaduct parapet gap (m)",
			LayoutOrder = 46,
			children = {
				Field = e(Components.NumberField, {
					Value = settings.ViaductParapetGapM,
					Min = 0,
					Max = 5,
					OnChanged = function(value: number)
						settings.ViaductParapetGapM = value
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
				}),
			},
		}),
		TunnelClearance = e(LabeledRow, {
			Label = "Tunnel wall clearance (m)",
			LayoutOrder = 47,
			children = {
				Field = e(Components.NumberField, {
					Value = settings.TunnelWallClearanceM,
					Min = 0,
					Max = 10,
					OnChanged = function(value: number)
						settings.TunnelWallClearanceM = value
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
				}),
			},
		}),
		ElevatedMedian = e(Components.Checkbox, {
			Label = "Match structural base on viaduct medians",
			Checked = settings.ElevatedMedianConcrete,
			LayoutOrder = 48,
			OnToggled = function(checked: boolean)
				settings.ElevatedMedianConcrete = checked
				props.OnSettingsChanged()
			end,
		}),
		ParallelGap = e(LabeledRow, {
			Label = "Parallel roadway gap (m)",
			LayoutOrder = 49,
			children = {
				Field = e(Components.NumberField, {
					Value = settings.ParallelRoadwayGapM,
					Min = 0,
					Max = 50,
					OnChanged = function(value: number)
						settings.ParallelRoadwayGapM = value
						props.OnSettingsChanged()
					end,
					LayoutOrder = 2,
				}),
			},
		}),
		Close = e(Components.Button, {
			Text = "Close",
			OnClick = props.OnClose,
			LayoutOrder = 100,
		}),
	})
end

return RegionalPreferenceGui
