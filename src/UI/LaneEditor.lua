--!strict
-- The road editor page: pick (or create) a road, which opens it in the
-- road designer - the CS2-style lane strip HUD at the bottom of the
-- viewport. Built-in roads act as starting templates and save as copies.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RoadProfile = require("../RoadProfile")
local RoadLibraryModule = require("../RoadLibrary")

type RoadLibrary = RoadLibraryModule.RoadLibrary

local function LaneEditor(props: {
	Library: RoadLibrary,
	OpenDesigner: (profile: RoadProfile.RoadProfile) -> (),
	OnClose: () -> (),
})
	local library = props.Library

	local profileOptions: { Components.DropdownOption } = {}
	for _, profile in library.GetAll() do
		table.insert(profileOptions, {
			Id = profile.Id,
			Text = profile.Name .. (if profile.BuiltIn then " (built-in)" else ""),
		})
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
		Hint = e(Components.Label, {
			Text = "Picking a road opens the designer at the bottom of the viewport.",
			Dim = true,
			LayoutOrder = 2,
		}),
		Picker = e(Components.Row, {
			LayoutOrder = 3,
		}, {
			Dropdown = e(Components.Dropdown, {
				Options = profileOptions,
				SelectedId = nil,
				Placeholder = "Pick a road to edit...",
				OnSelected = function(id: string)
					local profile = library.Get(id)
					if profile then
						props.OpenDesigner(RoadProfile.Clone(profile))
					end
				end,
				LayoutOrder = 1,
				Grow = true,
			}),
			New = e(Components.Button, {
				Text = "New",
				OnClick = function()
					props.OpenDesigner({
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
		Close = e(Components.Button, {
			Text = "Back",
			OnClick = props.OnClose,
			LayoutOrder = 100,
		}),
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, Theme.CORNER_RADIUS),
		}),
		Stroke = e("UIStroke", {
			Color = Theme.GLASS_STROKE,
			Transparency = Theme.GLASS_STROKE_TRANSPARENCY,
			Thickness = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
	}

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
