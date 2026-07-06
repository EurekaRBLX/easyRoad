--!strict
-- The road editor: create and configure custom road profiles.
--
-- Pick an existing road (built-in roads act as starting templates), then
-- edit its cross-section component by component: kind, width, and traffic
-- direction, with reordering and add/remove. Saving a built-in road creates
-- an editable user copy; user roads save in place and persist in plugin
-- settings.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local Icons = require("./Icons")
local RoadProfile = require("../RoadProfile")
local RoadLibraryModule = require("../RoadLibrary")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")

type RoadLibrary = RoadLibraryModule.RoadLibrary

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

local function LaneEditor(props: {
	Library: RoadLibrary,
	Settings: Settings.EasyRoadSettings,
	OnLibraryChanged: () -> (),
	OnClose: () -> (),
})
	local library = props.Library
	local regionStyle = RegionStyles.Get(props.Settings.RegionId)
	-- false = nothing selected (React state can't reliably hold nil)
	local editing: RoadProfile.RoadProfile | false, setEditing = React.useState(
		false :: RoadProfile.RoadProfile | false
	)

	local profileOptions: { Components.DropdownOption } = {}
	for _, profile in library.GetAll() do
		table.insert(profileOptions, {
			Id = profile.Id,
			Text = profile.Name .. (if profile.BuiltIn then " (built-in)" else ""),
		})
	end

	local function updateEditing(transform: (profile: RoadProfile.RoadProfile) -> ())
		if not editing then
			return
		end
		local copy = RoadProfile.Clone(editing)
		transform(copy)
		setEditing(copy)
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
		Header = e(Components.Section, {
			Text = "Road Editor",
			LayoutOrder = 1,
		}),
		Picker = e(Components.Row, {
			LayoutOrder = 2,
		}, {
			Dropdown = e(Components.Dropdown, {
				Options = profileOptions,
				SelectedId = if editing then editing.Id else nil,
				Placeholder = "Pick a road to edit...",
				OnSelected = function(id: string)
					local profile = library.Get(id)
					if profile then
						setEditing(RoadProfile.Clone(profile))
					end
				end,
				LayoutOrder = 1,
				Grow = true,
			}),
			New = e(Components.Button, {
				Text = "New",
				OnClick = function()
					setEditing({
						Id = "user_" .. tostring(os.time()),
						Name = "New Road",
						Category = "Custom",
						BuiltIn = false,
						Components = {
							{ Kind = "Sidewalk" :: RoadProfile.ComponentKind, WidthM = 2, Direction = 0 },
							{ Kind = "Drive" :: RoadProfile.ComponentKind, WidthM = 3.5, Direction = -1 },
							{ Kind = "Drive" :: RoadProfile.ComponentKind, WidthM = 3.5, Direction = 1 },
							{ Kind = "Sidewalk" :: RoadProfile.ComponentKind, WidthM = 2, Direction = 0 },
						},
					})
				end,
				LayoutOrder = 2,
			}),
		}),
	}

	if editing then
		local profile = editing

		children.NameRow = e(Components.Row, {
			LayoutOrder = 3,
		}, {
			Label = e(Components.Label, {
				Text = "Name",
				LayoutOrder = 1,
				Width = 56,
			}),
			NameBox = e("TextBox", {
				Text = profile.Name,
				TextColor3 = Theme.WHITE,
				BackgroundColor3 = Theme.FIELD,
				Size = UDim2.new(0, 140, 0, Theme.ROW_HEIGHT),
				Font = Theme.FONT,
				TextSize = Theme.TEXT_SIZE,
				ClearTextOnFocus = false,
				LayoutOrder = 2,
				[React.Event.FocusLost] = function(object: TextBox)
					if object.Text ~= "" then
						updateEditing(function(copy)
							copy.Name = object.Text
						end)
					end
				end,
			}, {
				Corner = e("UICorner", {
					CornerRadius = UDim.new(0, 4),
				}),
			}),
		})

		children.ColumnHint = e(Components.Label, {
			Text = "Components (left → right) — kind, width (m), direction, right boundary line",
			Dim = true,
			LayoutOrder = 4,
		})

		for index, component in profile.Components do
			children["Component" .. index] = e(ComponentRow, {
				Component = component,
				Index = index,
				Count = #profile.Components,
				LayoutOrder = 4 + index,
				OnChanged = function(newComponent: RoadProfile.ProfileComponent)
					updateEditing(function(copy)
						copy.Components[index] = newComponent
					end)
				end,
				OnMove = function(delta: number)
					updateEditing(function(copy)
						local moved = table.remove(copy.Components, index) :: RoadProfile.ProfileComponent
						table.insert(copy.Components, index + delta, moved)
					end)
				end,
				OnRemove = function()
					updateEditing(function(copy)
						table.remove(copy.Components, index)
					end)
				end,
			})
		end

		local afterComponents = 5 + #profile.Components

		children.AddComponent = e(Components.Button, {
			Text = "+ Add Component",
			OnClick = function()
				updateEditing(function(copy)
					table.insert(copy.Components, {
						Kind = "Drive" :: RoadProfile.ComponentKind,
						WidthM = 3.5,
						Direction = 1,
					})
				end)
			end,
			LayoutOrder = afterComponents,
		})

		children.TotalWidth = e(Components.Label, {
			Text = string.format("Total width: %.1f m", RoadProfile.TotalWidthM(profile)),
			Dim = true,
			LayoutOrder = afterComponents + 1,
		})

		children.KerbRow = e(Components.Row, {
			LayoutOrder = afterComponents + 2,
		}, {
			Label = e(Components.Label, {
				Text = "Kerb lines",
				LayoutOrder = 1,
				Width = 80,
			}),
			Dropdown = e(Components.Dropdown, {
				Options = {
					{ Id = "None", Text = "No restriction" },
					{ Id = "SingleYellow", Text = "Single yellow (no parking)" },
					{ Id = "DoubleYellow", Text = "Double yellow (no parking)" },
				},
				SelectedId = profile.KerbRestriction or "None",
				OnSelected = function(id: string)
					updateEditing(function(copy)
						copy.KerbRestriction = if id == "None" then nil else id
					end)
				end,
				LayoutOrder = 2,
				Grow = true,
			}),
		})

		children.KerbIndentRow = e(Components.Row, {
			LayoutOrder = afterComponents + 3,
		}, {
			Label = e(Components.Label, {
				Text = "Kerb line offset",
				LayoutOrder = 1,
				Width = 80,
			}),
			Dropdown = e(Components.Dropdown, {
				Options = {
					{ Id = "Inset", Text = "Inset (default)" },
					{ Id = "Flush", Text = "Flush at edge" },
				},
				SelectedId = if profile.KerbIndent == false then "Flush" else "Inset",
				OnSelected = function(id: string)
					updateEditing(function(copy)
						copy.KerbIndent = if id == "Flush" then false else nil
					end)
				end,
				LayoutOrder = 2,
				Grow = true,
			}),
		})

		children.ColourRow = e(Components.Row, {
			LayoutOrder = afterComponents + 4,
		}, {
			Label = e(Components.Label, {
				Text = "Line colour",
				LayoutOrder = 1,
				Width = 80,
			}),
			Dropdown = e(Components.Dropdown, {
				Options = {
					{ Id = "Auto", Text = "Auto (region)" },
					{ Id = "White", Text = "White" },
					{ Id = "Yellow", Text = "Yellow" },
				},
				SelectedId = profile.MarkingColor or "Auto",
				OnSelected = function(id: string)
					updateEditing(function(copy)
						copy.MarkingColor = if id == "Auto" then nil else id
					end)
				end,
				LayoutOrder = 2,
				Grow = true,
			}),
		})

		children.DashRow = e(Components.Row, {
			LayoutOrder = afterComponents + 5,
		}, {
			Label = e(Components.Label, {
				Text = "Dash spacing",
				LayoutOrder = 1,
				Width = 80,
			}),
			LengthLabel = e(Components.Label, {
				Text = "len(m)",
				Dim = true,
				LayoutOrder = 2,
			}),
			LengthField = e(Components.NumberField, {
				Value = profile.MarkingDashLengthM or regionStyle.DashLengthM,
				Min = 0.25,
				Max = 20,
				OnChanged = function(value: number)
					updateEditing(function(copy)
						copy.MarkingDashLengthM = value
					end)
				end,
				LayoutOrder = 3,
			}),
			GapLabel = e(Components.Label, {
				Text = "gap(m)",
				Dim = true,
				LayoutOrder = 4,
			}),
			GapField = e(Components.NumberField, {
				Value = profile.MarkingDashGapM or regionStyle.DashGapM,
				Min = 0.25,
				Max = 30,
				OnChanged = function(value: number)
					updateEditing(function(copy)
						copy.MarkingDashGapM = value
					end)
				end,
				LayoutOrder = 5,
			}),
			Reset = (profile.MarkingDashLengthM ~= nil or profile.MarkingDashGapM ~= nil) and e(Components.Button, {
				Text = "Reset",
				OnClick = function()
					updateEditing(function(copy)
						copy.MarkingDashLengthM = nil
						copy.MarkingDashGapM = nil
					end)
				end,
				LayoutOrder = 6,
			}),
		})

		children.Actions = e(Components.Row, {
			LayoutOrder = afterComponents + 6,
		}, {
			Save = e(Components.Button, {
				Text = if profile.BuiltIn then "Save as Copy" else "Save",
				Selected = true,
				OnClick = function()
					local toSave = RoadProfile.Clone(profile)
					if profile.BuiltIn then
						toSave.Id = "user_" .. tostring(os.time())
						toSave.Name = profile.Name .. " (Custom)"
						toSave.Category = "Custom"
					end
					toSave.BuiltIn = false
					library.SaveUserProfile(toSave)
					setEditing(toSave)
					props.OnLibraryChanged()
				end,
				LayoutOrder = 1,
			}),
			Delete = (not profile.BuiltIn and library.Get(profile.Id) ~= nil) and e(Components.Button, {
				Text = "Delete",
				Danger = true,
				OnClick = function()
					library.DeleteUserProfile(profile.Id)
					setEditing(false :: RoadProfile.RoadProfile | false)
					props.OnLibraryChanged()
				end,
				LayoutOrder = 2,
			}),
		})
	end

	children.Close = e(Components.Button, {
		Text = "Back",
		OnClick = props.OnClose,
		LayoutOrder = 100,
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

return LaneEditor
