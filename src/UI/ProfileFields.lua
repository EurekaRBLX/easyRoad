--!strict
-- Shared cross-section editing rows: component list (kind/width/direction/
-- boundary) plus kerb restriction, kerb offset, marking colour, and dash
-- spacing rows.
--
-- Used by both the road-editor page (editing a library RoadProfile) and the
-- placed-road inspector (editing a single placed road's profile in place),
-- so the two stay in lockstep instead of drifting apart.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local Icons = require("./Icons")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")

local BOUNDARY_LABELS: { [string]: string } = {
	Auto = "\u{2506}", -- dashed bar
	Solid = "\u{2502}",
	DoubleSolid = "\u{2551}",
	SolidDash = "\u{2502}\u{254C}",
	DashSolid = "\u{254C}\u{2502}",
}

local function directionLabel(direction: number): string
	if direction > 0 then
		return "→"
	elseif direction < 0 then
		return "←"
	else
		return "—"
	end
end

local function ComponentRow(props: {
	Component: RoadProfile.ProfileComponent,
	Index: number,
	Count: number,
	LayoutOrder: number,
	OnChanged: (component: RoadProfile.ProfileComponent) -> (),
	OnMove: (delta: number) -> (),
	OnRemove: () -> (),
})
	local component = props.Component

	local kindOptions: { Components.DropdownOption } = {}
	for _, kind in RoadProfile.ComponentKinds do
		table.insert(kindOptions, { Id = kind, Text = kind })
	end

	return e(Components.Row, {
		LayoutOrder = props.LayoutOrder,
	}, {
		Icon = e("ImageLabel", {
			Image = Icons.ForKind[component.Kind] or Icons.Lane,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 26, 0, 26),
			ScaleType = Enum.ScaleType.Fit,
			LayoutOrder = 0,
		}),
		Kind = e(Components.Dropdown, {
			Options = kindOptions,
			SelectedId = component.Kind,
			OnSelected = function(id: string)
				props.OnChanged({
					Kind = id :: RoadProfile.ComponentKind,
					WidthM = component.WidthM,
					Direction = if RoadProfile.IsDirectional(id :: RoadProfile.ComponentKind)
						then (if component.Direction == 0 then 1 else component.Direction)
						else 0,
					RightBoundary = component.RightBoundary,
				})
			end,
			LayoutOrder = 1,
			Grow = true,
		}),
		Width = e(Components.NumberField, {
			Value = component.WidthM,
			Min = 0.1,
			Max = 30,
			OnChanged = function(value: number)
				props.OnChanged({
					Kind = component.Kind,
					WidthM = value,
					Direction = component.Direction,
					RightBoundary = component.RightBoundary,
				})
			end,
			LayoutOrder = 2,
			Width = 48,
		}),
		Direction = e(Components.Button, {
			Text = directionLabel(component.Direction),
			OnClick = function()
				if RoadProfile.IsDirectional(component.Kind) then
					props.OnChanged({
						Kind = component.Kind,
						WidthM = component.WidthM,
						Direction = if component.Direction >= 0 then -1 else 1,
						RightBoundary = component.RightBoundary,
					})
				end
			end,
			LayoutOrder = 3,
			Size = UDim2.new(0, 28, 0, Theme.ROW_HEIGHT),
		}),
		MoveUp = e(Components.Button, {
			Text = "▲",
			OnClick = function()
				if props.Index > 1 then
					props.OnMove(-1)
				end
			end,
			LayoutOrder = 4,
			Size = UDim2.new(0, 24, 0, Theme.ROW_HEIGHT),
		}),
		MoveDown = e(Components.Button, {
			Text = "▼",
			OnClick = function()
				if props.Index < props.Count then
					props.OnMove(1)
				end
			end,
			LayoutOrder = 5,
			Size = UDim2.new(0, 24, 0, Theme.ROW_HEIGHT),
		}),
		Boundary = props.Index < props.Count and e(Components.Button, {
			Text = BOUNDARY_LABELS[component.RightBoundary or "Auto"] or BOUNDARY_LABELS.Auto,
			OnClick = function()
				local rules = RoadProfile.BoundaryRules
				local current = component.RightBoundary or "Auto"
				local index = table.find(rules, current) or 1
				local nextRule = rules[(index % #rules) + 1]
				props.OnChanged({
					Kind = component.Kind,
					WidthM = component.WidthM,
					Direction = component.Direction,
					RightBoundary = if nextRule == "Auto" then nil else nextRule,
				})
			end,
			LayoutOrder = 6,
			Size = UDim2.new(0, 34, 0, Theme.ROW_HEIGHT),
		}),
		Remove = e(Components.Button, {
			Text = "✕",
			Danger = true,
			OnClick = props.OnRemove,
			LayoutOrder = 7,
			Size = UDim2.new(0, 24, 0, Theme.ROW_HEIGHT),
		}),
	})
end

local ProfileFields = {}

-- Kerb restriction / kerb offset / marking colour / dash spacing rows. These
-- apply to the whole road regardless of transitions (RoadBuilder always
-- reads them from ProfileStart), so they're split out on their own to be
-- usable even when the component list itself isn't editable.
function ProfileFields.InsertMarkingOptions(
	children: { [string]: any },
	profile: RoadProfile.RoadProfile,
	regionStyle: RegionStyles.RegionStyle,
	startOrder: number,
	onChange: (transform: (profile: RoadProfile.RoadProfile) -> ()) -> ()
): number
	local order = startOrder

	children["PF_KerbRow"] = e(Components.Row, {
		LayoutOrder = order,
	}, {
		Label = e(Components.Label, { Text = "Kerb lines", LayoutOrder = 1, Width = 80 }),
		Dropdown = e(Components.Dropdown, {
			Options = {
				{ Id = "None", Text = "No restriction" },
				{ Id = "SingleYellow", Text = "Single yellow (no parking)" },
				{ Id = "DoubleYellow", Text = "Double yellow (no parking)" },
			},
			SelectedId = profile.KerbRestriction or "None",
			OnSelected = function(id: string)
				onChange(function(copy)
					copy.KerbRestriction = if id == "None" then nil else id
				end)
			end,
			LayoutOrder = 2,
			Grow = true,
		}),
	})
	order += 1

	children["PF_KerbIndentRow"] = e(Components.Row, {
		LayoutOrder = order,
	}, {
		Label = e(Components.Label, { Text = "Kerb line offset", LayoutOrder = 1, Width = 80 }),
		Dropdown = e(Components.Dropdown, {
			Options = {
				{ Id = "Inset", Text = "Inset (default)" },
				{ Id = "Flush", Text = "Flush at edge" },
			},
			SelectedId = if profile.KerbIndent == false then "Flush" else "Inset",
			OnSelected = function(id: string)
				onChange(function(copy)
					copy.KerbIndent = if id == "Flush" then false else nil
				end)
			end,
			LayoutOrder = 2,
			Grow = true,
		}),
	})
	order += 1

	children["PF_ColourRow"] = e(Components.Row, {
		LayoutOrder = order,
	}, {
		Label = e(Components.Label, { Text = "Line colour", LayoutOrder = 1, Width = 80 }),
		Dropdown = e(Components.Dropdown, {
			Options = {
				{ Id = "Auto", Text = "Auto (region)" },
				{ Id = "White", Text = "White" },
				{ Id = "Yellow", Text = "Yellow" },
			},
			SelectedId = profile.MarkingColor or "Auto",
			OnSelected = function(id: string)
				onChange(function(copy)
					copy.MarkingColor = if id == "Auto" then nil else id
				end)
			end,
			LayoutOrder = 2,
			Grow = true,
		}),
	})
	order += 1

	children["PF_DashRow"] = e(Components.Row, {
		LayoutOrder = order,
	}, {
		Label = e(Components.Label, { Text = "Dash spacing", LayoutOrder = 1, Width = 80 }),
		LengthLabel = e(Components.Label, { Text = "len(m)", Dim = true, LayoutOrder = 2 }),
		LengthField = e(Components.NumberField, {
			Value = profile.MarkingDashLengthM or regionStyle.DashLengthM,
			Min = 0.25,
			Max = 20,
			OnChanged = function(value: number)
				onChange(function(copy)
					copy.MarkingDashLengthM = value
				end)
			end,
			LayoutOrder = 3,
		}),
		GapLabel = e(Components.Label, { Text = "gap(m)", Dim = true, LayoutOrder = 4 }),
		GapField = e(Components.NumberField, {
			Value = profile.MarkingDashGapM or regionStyle.DashGapM,
			Min = 0.25,
			Max = 30,
			OnChanged = function(value: number)
				onChange(function(copy)
					copy.MarkingDashGapM = value
				end)
			end,
			LayoutOrder = 5,
		}),
		Reset = (profile.MarkingDashLengthM ~= nil or profile.MarkingDashGapM ~= nil) and e(Components.Button, {
			Text = "Reset",
			OnClick = function()
				onChange(function(copy)
					copy.MarkingDashLengthM = nil
					copy.MarkingDashGapM = nil
				end)
			end,
			LayoutOrder = 6,
		}),
	})
	order += 1

	return order
end

-- Full editing block: component list (kind/width/direction/boundary, with
-- add/remove/reorder) followed by the marking option rows above. Appends
-- into `children` (a React children dict) starting at `startOrder` and
-- returns the next unused LayoutOrder so the caller can place more rows
-- after this block.
function ProfileFields.Insert(
	children: { [string]: any },
	profile: RoadProfile.RoadProfile,
	regionStyle: RegionStyles.RegionStyle,
	startOrder: number,
	onChange: (transform: (profile: RoadProfile.RoadProfile) -> ()) -> ()
): number
	local order = startOrder

	children["PF_ColumnHint"] = e(Components.Label, {
		Text = "Components (left → right) — kind, width (m), direction, right boundary line",
		Dim = true,
		LayoutOrder = order,
	})
	order += 1

	for index, component in profile.Components do
		children["PF_Component" .. index] = e(ComponentRow, {
			Component = component,
			Index = index,
			Count = #profile.Components,
			LayoutOrder = order,
			OnChanged = function(newComponent: RoadProfile.ProfileComponent)
				onChange(function(copy)
					copy.Components[index] = newComponent
				end)
			end,
			OnMove = function(delta: number)
				onChange(function(copy)
					local moved = table.remove(copy.Components, index) :: RoadProfile.ProfileComponent
					table.insert(copy.Components, index + delta, moved)
				end)
			end,
			OnRemove = function()
				onChange(function(copy)
					table.remove(copy.Components, index)
				end)
			end,
		})
		order += 1
	end

	children["PF_AddComponent"] = e(Components.Button, {
		Text = "+ Add Component",
		OnClick = function()
			onChange(function(copy)
				table.insert(copy.Components, {
					Kind = "Drive" :: RoadProfile.ComponentKind,
					WidthM = 3.5,
					Direction = 1,
				})
			end)
		end,
		LayoutOrder = order,
	})
	order += 1

	children["PF_TotalWidth"] = e(Components.Label, {
		Text = string.format("Total width: %.1f m", RoadProfile.TotalWidthM(profile)),
		Dim = true,
		LayoutOrder = order,
	})
	order += 1

	return ProfileFields.InsertMarkingOptions(children, profile, regionStyle, order, onChange)
end

return ProfileFields
