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
local StructureAssets = require("../StructureAssets")
local StructureBuilder = require("../StructureBuilder")

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
	Assets: { StructureAssets.AssetInfo },
	Status: string?,
	OnChange: (structure: RoadInstance.StructureData) -> (),
	LayoutOrder: number?,
})
	local structure = props.Structure
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
			children.ColorLabel = note("Procedural concrete colour", order)
			order += 1
			children.Color = e(Components.ColorField, {
				Value = StructureBuilder.ColorFromHex(structure.ConcreteColorHex),
				LayoutOrder = order,
				OnChanged = function(color: Color3)
					change(function(copy)
						copy.ConcreteColorHex = StructureBuilder.ColorToHex(color)
					end)
				end,
			})
			order += 1
			children.Offset = e(Components.Row, { LayoutOrder = order }, {
				Label = e(Components.Label, { Text = "Y offset (m)", LayoutOrder = 1 }),
				Field = e(Components.NumberField, {
					Value = structure.ModuleOffsetM,
					Width = 62,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						change(function(copy)
							copy.ModuleOffsetM = value
						end)
					end,
				}),
			})
			order += 1
			children.InterfaceOverlap = e(Components.Row, { LayoutOrder = order }, {
				Label = e(Components.Label, { Text = "Road overlap (m)", LayoutOrder = 1 }),
				Field = e(Components.NumberField, {
					Value = structure.InterfaceOverlapM,
					Min = 0,
					Width = 62,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						change(function(copy)
							copy.InterfaceOverlapM = value
						end)
					end,
				}),
			})
			order += 1
		end

		if kind == "Viaduct" and advancedOpen then
			children.ParapetGap = e(Components.Row, { LayoutOrder = order }, {
				Label = e(Components.Label, { Text = "Parapet gap (m)", LayoutOrder = 1 }),
				Field = e(Components.NumberField, {
					Value = structure.ViaductParapetGapM,
					Min = 0,
					Width = 62,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						change(function(copy)
							copy.ViaductParapetGapM = value
						end)
					end,
				}),
			})
			order += 1
			children.ConcreteMedian = e(Components.Checkbox, {
				Label = "Use concrete for elevated medians",
				Checked = structure.ConcreteMedian,
				LayoutOrder = order,
				OnToggled = function(checked: boolean)
					change(function(copy)
						copy.ConcreteMedian = checked
					end)
				end,
			})
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
				local fields = {
					{ Key = "PillarSpacingM", Label = "Spacing (m)", Value = structure.PillarSpacingM, Min = 0.5 },
					{ Key = "PillarWidthM", Label = "Width (m)", Value = structure.PillarWidthM, Min = 0.1 },
					{ Key = "PillarDepthM", Label = "Depth (m)", Value = structure.PillarDepthM, Min = 0.1 },
					{ Key = "MaxPillarHeightM", Label = "Max drop (m)", Value = structure.MaxPillarHeightM, Min = 0.5 },
				}
				for _, field in fields do
					children[field.Key] = e(Components.Row, { LayoutOrder = order }, {
						Label = e(Components.Label, { Text = field.Label, LayoutOrder = 1 }),
						Field = e(Components.NumberField, {
							Value = field.Value,
							Min = field.Min,
							Width = 62,
							LayoutOrder = 2,
							OnChanged = function(value: number)
								change(function(copy)
									(copy :: any)[field.Key] = value
								end)
							end,
						}),
					})
					order += 1
				end
			end
		elseif kind == "Tunnel" and advancedOpen then
			children.TunnelClearance = e(Components.Row, { LayoutOrder = order }, {
				Label = e(Components.Label, { Text = "Wall clearance (m)", LayoutOrder = 1 }),
				Field = e(Components.NumberField, {
					Value = structure.TunnelWallClearanceM,
					Min = 0,
					Width = 62,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						change(function(copy)
							copy.TunnelWallClearanceM = value
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
