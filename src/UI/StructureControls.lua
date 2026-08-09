--!strict
-- Placed-road controls for imported rigid viaduct/tunnel modules and
-- terrain-projected viaduct piers. Kept out of RoadDesigner proper because
-- these settings belong to a road instance, not a reusable cross-section.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Components = require("./Components")
local Theme = require("./Theme")
local RoadInstance = require("../RoadInstance")
local Settings = require("../Settings")
local StructureAssets = require("../StructureAssets")
local StructureBuilder = require("../StructureBuilder")
local StructureMaterials = require("../StructureMaterials")
local Units = require("../Units")

local materialOptions: { Components.DropdownOption } = {}
for _, entry in StructureMaterials.Entries do
	table.insert(materialOptions, { Id = entry.Id, Text = entry.Text })
end

local function note(text: string, order: number)
	return e("TextLabel", {
		Text = text,
		TextColor3 = Theme.DIM,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = order,
	})
end

local function StructureControls(props: {
	Structure: RoadInstance.StructureData,
	Settings: Settings.EasyRoadSettings,
	Assets: { StructureAssets.AssetInfo },
	Status: string?,
	OnChange: (structure: RoadInstance.StructureData) -> (),
	LayoutOrder: number?,
})
	local structure = props.Structure
	local unit = Units.LengthSuffix(props.Settings)
	local function lengthLabel(label: string): string
		return label .. " (" .. unit .. ")"
	end
	local advancedOpen, setAdvancedOpen = React.useState(false)
	local function change(transform: (copy: RoadInstance.StructureData) -> ())
		local copy = StructureBuilder.CloneData(structure)
		transform(copy)
		props.OnChange(copy)
	end

	local modeOptions: { Components.DropdownOption } = {
		{ Id = "None", Text = "Ground level" },
		{ Id = "Viaduct", Text = "Elevated viaduct" },
		{ Id = "Tunnel", Text = "Tunnel (procedural / custom)" },
	}
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
		Header = e(Components.Section, { Text = "Structure", LayoutOrder = 1 }),
		Mode = e(Components.Row, { LayoutOrder = 2 }, {
			Label = e(Components.Label, { Text = "Mode", Width = 62, LayoutOrder = 1 }),
			Field = e(Components.Dropdown, {
				Options = modeOptions,
				SelectedId = structure.Mode,
				Grow = true,
				LayoutOrder = 2,
				OnSelected = function(id: string)
					change(function(copy)
						copy.Mode = id :: RoadInstance.StructureMode
						copy.AssetId = nil
					end)
				end,
			}),
		}),
	}

	local order = 3
	local function addFinishControls(
		key: string,
		title: string,
		colorHex: string,
		material: StructureMaterials.MaterialName,
		colorField: string,
		materialField: string
	)
		children[key .. "Section"] = e(Components.Section, { Text = title, LayoutOrder = order })
		order += 1
		children[key .. "Material"] = e(Components.Row, { LayoutOrder = order }, {
			Label = e(Components.Label, { Text = "Material", Width = 72, LayoutOrder = 1 }),
			Field = e(Components.Dropdown, {
				Options = materialOptions,
				SelectedId = material,
				Grow = true,
				LayoutOrder = 2,
				OnSelected = function(id: string)
					change(function(copy)
						(copy :: any)[materialField] = StructureMaterials.Sanitize(id)
					end)
				end,
			}),
		})
		order += 1
		children[key .. "ColorLabel"] = note("Colour", order)
		order += 1
		children[key .. "Color"] = e(Components.ColorField, {
			Value = StructureBuilder.ColorFromHex(colorHex),
			LayoutOrder = order,
			OnChanged = function(color: Color3)
				change(function(copy)
					(copy :: any)[colorField] = StructureBuilder.ColorToHex(color)
				end)
			end,
		})
		order += 1
	end

	if structure.Mode ~= "None" then
		local kind = structure.Mode :: StructureAssets.AssetKind
		local assetOptions: { Components.DropdownOption } = {
			{
				Id = "__none__",
				Text = if kind == "Viaduct" then "Procedural slab + parapets" else "Procedural arched tunnel",
			},
		}
		for _, asset in props.Assets do
			table.insert(assetOptions, {
				Id = asset.Id,
				Text = string.format("%s (%.1f studs)", asset.Name, asset.LengthStuds),
			})
		end
		children.Asset = e(Components.Row, { LayoutOrder = order }, {
			Label = e(Components.Label, { Text = "Module", Width = 62, LayoutOrder = 1 }),
			Field = e(Components.Dropdown, {
				Options = assetOptions,
				SelectedId = structure.AssetId or "__none__",
				Grow = true,
				LayoutOrder = 2,
				OnSelected = function(id: string)
					change(function(copy)
						copy.AssetId = if id == "__none__" then nil else id
					end)
				end,
			}),
		})
		order += 1
		children.ElevationHelp = note(
			"Import and manage custom Models from Road Assets. Set positive/negative Elevation for viaduct grades or sunken tunnel alignments.",
			order
		)
		order += 1
		children.AdvancedToggle = e(Components.Button, {
			Text = if advancedOpen then "Hide advanced structure options" else "Edit advanced structure options",
			Selected = advancedOpen,
			Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
			LayoutOrder = order,
			OnClick = function()
				setAdvancedOpen(not advancedOpen)
			end,
		})
		order += 1

		if advancedOpen then
			children.FitSection = e(Components.Section, { Text = "Position and fit", LayoutOrder = order })
			order += 1
			children.Offset = e(Components.Row, { LayoutOrder = order }, {
				Label = e(Components.Label, { Text = lengthLabel("Y offset"), LayoutOrder = 1 }),
				Field = e(Components.NumberField, {
					Value = Units.LengthFromM(props.Settings, structure.ModuleOffsetM),
					Width = 62,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						change(function(copy)
							copy.ModuleOffsetM = Units.LengthToM(props.Settings, value)
						end)
					end,
				}),
			})
			order += 1
			children.InterfaceOverlap = e(Components.Row, { LayoutOrder = order }, {
				Label = e(Components.Label, { Text = lengthLabel("Road overlap"), LayoutOrder = 1 }),
				Field = e(Components.NumberField, {
					Value = Units.LengthFromM(props.Settings, structure.InterfaceOverlapM),
					Min = Units.LengthFromM(props.Settings, 0),
					Width = 62,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						change(function(copy)
							copy.InterfaceOverlapM = Units.LengthToM(props.Settings, value)
						end)
					end,
				}),
			})
			order += 1

			if structure.AssetId then
				children.AssetAppearance = note(
					"Custom module materials and colours stay exactly as authored in the imported Roblox Model.",
					order
				)
				order += 1
			end

			if not structure.AssetId or kind == "Viaduct" then
				addFinishControls(
					"BaseFinish",
					if structure.AssetId then "Pier and cap finish" else "Structural base finish",
					structure.ConcreteColorHex,
					structure.BaseMaterial,
					"ConcreteColorHex",
					"BaseMaterial"
				)
			end
			if not structure.AssetId and kind == "Viaduct" then
				addFinishControls(
					"ViaductWallFinish",
					"Viaduct edge wall finish",
					structure.ViaductWallColorHex,
					structure.ViaductWallMaterial,
					"ViaductWallColorHex",
					"ViaductWallMaterial"
				)
			elseif not structure.AssetId and kind == "Tunnel" then
				addFinishControls(
					"TunnelWallFinish",
					"Tunnel side wall finish",
					structure.TunnelWallColorHex,
					structure.TunnelWallMaterial,
					"TunnelWallColorHex",
					"TunnelWallMaterial"
				)
				addFinishControls(
					"TunnelRoofFinish",
					"Tunnel roof finish",
					structure.TunnelRoofColorHex,
					structure.TunnelRoofMaterial,
					"TunnelRoofColorHex",
					"TunnelRoofMaterial"
				)
			end
		end

		if kind == "Viaduct" and advancedOpen then
			children.ViaductGeometrySection = e(Components.Section, {
				Text = "Viaduct geometry",
				LayoutOrder = order,
			})
			order += 1
			children.ParapetGap = e(Components.Row, { LayoutOrder = order }, {
				Label = e(Components.Label, { Text = lengthLabel("Parapet gap"), LayoutOrder = 1 }),
				Field = e(Components.NumberField, {
					Value = Units.LengthFromM(props.Settings, structure.ViaductParapetGapM),
					Min = Units.LengthFromM(props.Settings, 0),
					Width = 62,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						change(function(copy)
							copy.ViaductParapetGapM = Units.LengthToM(props.Settings, value)
						end)
					end,
				}),
			})
			order += 1
			children.ParapetHeight = e(Components.Row, { LayoutOrder = order }, {
				Label = e(Components.Label, { Text = lengthLabel("Parapet height"), LayoutOrder = 1 }),
				Field = e(Components.NumberField, {
					Value = Units.LengthFromM(props.Settings, structure.ViaductParapetHeightM),
					Min = Units.LengthFromM(props.Settings, 0.2),
					Max = Units.LengthFromM(props.Settings, 5),
					Width = 62,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						change(function(copy)
							copy.ViaductParapetHeightM = Units.LengthToM(props.Settings, value)
						end)
					end,
				}),
			})
			order += 1
			children.ConcreteMedian = e(Components.Checkbox, {
				Label = "Match structural base on elevated medians",
				Checked = structure.ConcreteMedian,
				LayoutOrder = order,
				OnToggled = function(checked: boolean)
					change(function(copy)
						copy.ConcreteMedian = checked
					end)
				end,
			})
			order += 1
			children.SupportSection = e(Components.Section, { Text = "Viaduct supports", LayoutOrder = order })
			order += 1
			children.Pillars = e(Components.Checkbox, {
				Label = "Auto-place piers by downward raycast",
				Checked = structure.AutoPillars,
				LayoutOrder = order,
				OnToggled = function(checked: boolean)
					change(function(copy)
						copy.AutoPillars = checked
					end)
				end,
			})
			order += 1
			if structure.AutoPillars then
				children.PillarLayout = e(Components.Row, { LayoutOrder = order }, {
					Label = e(Components.Label, { Text = "Layout", Width = 72, LayoutOrder = 1 }),
					Field = e(Components.Dropdown, {
						Options = {
							{ Id = "Single", Text = "Single centre pillar" },
							{ Id = "Twin", Text = "Twin pillars + cap beam" },
						},
						SelectedId = structure.PillarLayout,
						Grow = true,
						LayoutOrder = 2,
						OnSelected = function(id: string)
							change(function(copy)
								copy.PillarLayout = if id == "Twin" then "Twin" else "Single"
							end)
						end,
					}),
				})
				order += 1
				local fields = {
					{ Key = "PillarSpacingM", Label = "Spacing", Value = structure.PillarSpacingM, Min = 0.5 },
					{ Key = "PillarWidthM", Label = "Pillar width", Value = structure.PillarWidthM, Min = 0.1 },
					{ Key = "PillarDepthM", Label = "Pillar depth", Value = structure.PillarDepthM, Min = 0.1 },
					{ Key = "MaxPillarHeightM", Label = "Max drop", Value = structure.MaxPillarHeightM, Min = 0.5 },
				}
				if structure.PillarLayout == "Twin" then
					table.insert(fields, {
						Key = "PillarSeparationM",
						Label = "Pillar centres",
						Value = structure.PillarSeparationM,
						Min = 0.1,
					})
					table.insert(fields, {
						Key = "CapBeamWidthM",
						Label = "Cap width",
						Value = structure.CapBeamWidthM,
						Min = 0.1,
					})
					table.insert(fields, {
						Key = "CapBeamHeightM",
						Label = "Cap height",
						Value = structure.CapBeamHeightM,
						Min = 0.1,
					})
					table.insert(fields, {
						Key = "CapBeamDepthM",
						Label = "Cap depth",
						Value = structure.CapBeamDepthM,
						Min = 0.1,
					})
				end
				for _, field in fields do
					children[field.Key] = e(Components.Row, { LayoutOrder = order }, {
						Label = e(Components.Label, { Text = lengthLabel(field.Label), LayoutOrder = 1 }),
						Field = e(Components.NumberField, {
							Value = Units.LengthFromM(props.Settings, field.Value),
							Min = Units.LengthFromM(props.Settings, field.Min),
							Width = 62,
							LayoutOrder = 2,
							OnChanged = function(value: number)
								change(function(copy)
									(copy :: any)[field.Key] = Units.LengthToM(props.Settings, value)
								end)
							end,
						}),
					})
					order += 1
				end
			end
		elseif kind == "Tunnel" and advancedOpen then
			children.TunnelGeometrySection = e(Components.Section, {
				Text = "Tunnel geometry",
				LayoutOrder = order,
			})
			order += 1
			children.TunnelClearance = e(Components.Row, { LayoutOrder = order }, {
				Label = e(Components.Label, { Text = lengthLabel("Side clearance"), LayoutOrder = 1 }),
				Field = e(Components.NumberField, {
					Value = Units.LengthFromM(props.Settings, structure.TunnelWallClearanceM),
					Min = Units.LengthFromM(props.Settings, 0),
					Width = 62,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						change(function(copy)
							copy.TunnelWallClearanceM = Units.LengthToM(props.Settings, value)
						end)
					end,
				}),
			})
			order += 1
			children.TunnelVerticalClearance = e(Components.Row, { LayoutOrder = order }, {
				Label = e(Components.Label, { Text = lengthLabel("Vertical clearance"), LayoutOrder = 1 }),
				Field = e(Components.NumberField, {
					Value = Units.LengthFromM(props.Settings, structure.TunnelVerticalClearanceM),
					Min = Units.LengthFromM(props.Settings, 2),
					Max = Units.LengthFromM(props.Settings, 12),
					Width = 62,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						change(function(copy)
							copy.TunnelVerticalClearanceM = Units.LengthToM(props.Settings, value)
						end)
					end,
				}),
			})
			order += 1
			children.TunnelNote = note(
				"Without a custom module, EasyRoad generates a structural base, sidewalls, and segmented arched vault. Terrain excavation remains explicit.",
				order
			)
			order += 1
		end
	end

	if props.Status then
		children.Status = note(props.Status, order)
	end

	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, children)
end

return StructureControls
