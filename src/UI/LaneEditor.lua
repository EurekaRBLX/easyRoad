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
local ProfileFields = require("./ProfileFields")
local RoadProfile = require("../RoadProfile")
local RoadLibraryModule = require("../RoadLibrary")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")

type RoadLibrary = RoadLibraryModule.RoadLibrary

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

		local afterFields = ProfileFields.Insert(children, profile, regionStyle, 4, updateEditing)

		children.Actions = e(Components.Row, {
			LayoutOrder = afterFields,
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
