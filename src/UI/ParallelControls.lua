--!strict
-- Compact placement controls for building several carriageways from one
-- alignment. Basic enable/count/opposed-pair controls stay visible; spacing
-- and per-roadway reverse direction live behind Advanced.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Components = require("./Components")
local Theme = require("./Theme")

export type ParallelConfig = {
	Enabled: boolean,
	Count: number,
	GapM: number,
	OppositeDirections: boolean,
	ReverseByIndex: { boolean },
}

local function cloneConfig(config: ParallelConfig): ParallelConfig
	return {
		Enabled = config.Enabled,
		Count = config.Count,
		GapM = config.GapM,
		OppositeDirections = config.OppositeDirections,
		ReverseByIndex = table.clone(config.ReverseByIndex),
	}
end

local function ParallelControls(props: {
	Config: ParallelConfig,
	OnChange: (config: ParallelConfig) -> (),
	LayoutOrder: number?,
})
	local advancedOpen, setAdvancedOpen = React.useState(false)
	local config = props.Config
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
		Header = e(Components.Section, { Text = "Parallel roadways", LayoutOrder = 1 }),
		Enabled = e(Components.Checkbox, {
			Label = "Build parallel carriageways",
			Checked = config.Enabled,
			LayoutOrder = 2,
			OnToggled = function(checked: boolean)
				local copy = cloneConfig(config)
				copy.Enabled = checked
				props.OnChange(copy)
			end,
		}),
	}

	local order = 3
	if config.Enabled then
		children.Count = e(Components.Row, { LayoutOrder = order }, {
			Label = e(Components.Label, { Text = "Roadways", LayoutOrder = 1 }),
			Field = e(Components.NumberField, {
				Value = config.Count,
				Min = 2,
				Max = 16,
				Width = 62,
				LayoutOrder = 2,
				OnChanged = function(value: number)
					local copy = cloneConfig(config)
					copy.Count = math.clamp(math.floor(value), 2, 16)
					props.OnChange(copy)
				end,
			}),
		})
		order += 1
		if config.Count == 2 then
			children.Opposite = e(Components.Checkbox, {
				Label = "Opposite traffic directions",
				Checked = config.OppositeDirections,
				LayoutOrder = order,
				OnToggled = function(checked: boolean)
					local copy = cloneConfig(config)
					copy.OppositeDirections = checked
					props.OnChange(copy)
				end,
			})
			order += 1
		end
		children.Advanced = e(Components.Button, {
			Text = if advancedOpen then "Hide advanced parallel options" else "Edit advanced parallel options",
			Selected = advancedOpen,
			Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
			LayoutOrder = order,
			OnClick = function()
				setAdvancedOpen(not advancedOpen)
			end,
		})
		order += 1
		if advancedOpen then
			children.Gap = e(Components.Row, { LayoutOrder = order }, {
				Label = e(Components.Label, { Text = "Edge gap (m)", LayoutOrder = 1 }),
				Field = e(Components.NumberField, {
					Value = config.GapM,
					Min = 0,
					Max = 50,
					Width = 62,
					LayoutOrder = 2,
					OnChanged = function(value: number)
						local copy = cloneConfig(config)
						copy.GapM = math.max(value, 0)
						props.OnChange(copy)
					end,
				}),
			})
			order += 1
			if config.Count > 2 then
				for index = 1, config.Count do
					local roadwayIndex = index
					children["Reverse" .. index] = e(Components.Checkbox, {
						Label = string.format("Roadway %d runs in reverse", roadwayIndex),
						Checked = config.ReverseByIndex[roadwayIndex] == true,
						LayoutOrder = order,
						OnToggled = function(checked: boolean)
							local copy = cloneConfig(config)
							copy.ReverseByIndex[roadwayIndex] = checked
							props.OnChange(copy)
						end,
					})
					order += 1
				end
			end
		end
	end

	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
	}, children)
end

return ParallelControls
