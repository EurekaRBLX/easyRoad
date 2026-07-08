--!strict
-- The road library panel: category tabs (Streets / Avenues / Highways /
-- Paths / Custom) above a horizontal strip of road tiles - a separate
-- floating panel from ToolModePanel, matching the CS2 reference layout
-- (two distinct boxes side by side, not one box with everything stacked).

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RoadThumbnail = require("./RoadThumbnail")
local RoadLibraryModule = require("../RoadLibrary")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")

type RoadLibrary = RoadLibraryModule.RoadLibrary

local TILE_WIDTH = 64
local TILE_HEIGHT = 78

local function LibraryTile(props: {
	Profile: RoadProfile.RoadProfile,
	RegionStyle: RegionStyles.RegionStyle,
	Settings: Settings.EasyRoadSettings,
	Selected: boolean,
	OnClick: () -> (),
	LayoutOrder: number,
})
	local hovered, setHovered = React.useState(false)
	local color = if props.Selected then (if hovered then Theme.ACCENT_HOVER else Theme.SELECTED)
		elseif hovered then Theme.BUTTON_HOVER
		else Theme.FIELD

	return e("TextButton", {
		Text = "",
		Size = UDim2.new(0, TILE_WIDTH, 0, TILE_HEIGHT),
		BackgroundColor3 = color,
		BackgroundTransparency = if props.Selected then 0.1 else Theme.GLASS_ELEMENT_TRANSPARENCY,
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
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, 2),
		}),
		Padding = e("UIPadding", {
			PaddingTop = UDim.new(0, 4),
			PaddingLeft = UDim.new(0, 3),
			PaddingRight = UDim.new(0, 3),
		}),
		Thumb = e(RoadThumbnail, {
			Profile = props.Profile,
			RegionStyle = props.RegionStyle,
			Settings = props.Settings,
			Size = UDim2.new(1, 0, 0, 40),
			LayoutOrder = 1,
		}),
		Label = e("TextLabel", {
			Text = props.Profile.Name,
			TextColor3 = Theme.OFFWHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 24),
			Font = Theme.FONT,
			TextSize = 11,
			TextWrapped = true,
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = 2,
		}),
	})
end

-- Preferred category tab order - anything not listed here (a region-specific
-- extra, say) is appended after in whatever order it's first seen.
local CATEGORY_ORDER = { "Streets", "Avenues", "Highways", "Paths", "Custom" }

local function RoadLibraryPanel(props: {
	Library: RoadLibrary,
	RegionStyle: RegionStyles.RegionStyle,
	Settings: Settings.EasyRoadSettings,
	ProfileId: string?,
	SetProfileId: (id: string) -> (),
})
	local allProfiles = props.Library.GetAll()

	local categories: { string } = {}
	local seenCategory: { [string]: boolean } = {}
	for _, orderedCategory in CATEGORY_ORDER do
		for _, libraryProfile in allProfiles do
			if libraryProfile.Category == orderedCategory and not seenCategory[orderedCategory] then
				seenCategory[orderedCategory] = true
				table.insert(categories, orderedCategory)
			end
		end
	end
	for _, libraryProfile in allProfiles do
		if not seenCategory[libraryProfile.Category] then
			seenCategory[libraryProfile.Category] = true
			table.insert(categories, libraryProfile.Category)
		end
	end

	local activeCategory, setActiveCategory = React.useState(categories[1] or "Streets")
	if not table.find(categories, activeCategory) and categories[1] then
		-- Selected road's category changed out from under us (e.g. region
		-- switch) - fall back to the first tab instead of showing nothing.
		activeCategory = categories[1]
	end

	local categoryTabs: { [string]: any } = {}
	for index, category in categories do
		categoryTabs[category] = e(Components.Button, {
			Text = category,
			Selected = category == activeCategory,
			OnClick = function()
				setActiveCategory(category)
			end,
			LayoutOrder = index,
			Grow = true,
		})
	end

	local tiles: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
	}
	local tileIndex = 0
	for _, libraryProfile in allProfiles do
		if libraryProfile.Category == activeCategory then
			tileIndex += 1
			tiles["Tile" .. tileIndex] = e(LibraryTile, {
				Profile = libraryProfile,
				RegionStyle = props.RegionStyle,
				Settings = props.Settings,
				Selected = props.ProfileId == libraryProfile.Id,
				OnClick = function()
					props.SetProfileId(libraryProfile.Id)
				end,
				LayoutOrder = tileIndex,
			})
		end
	end

	local stripScrollProps = Components.ScrollBar()
	stripScrollProps.Size = UDim2.new(1, 0, 0, TILE_HEIGHT + 12)
	stripScrollProps.BackgroundTransparency = 1
	stripScrollProps.BorderSizePixel = 0
	stripScrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
	stripScrollProps.AutomaticCanvasSize = Enum.AutomaticSize.X
	stripScrollProps.ScrollingDirection = Enum.ScrollingDirection.X -- Deliberate exception: this strip scrolls horizontally
	stripScrollProps.LayoutOrder = 2

	local children: { [string]: any } = {}
	children.Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.CORNER_RADIUS) })
	children.Stroke = e("UIStroke", {
		Color = Theme.GLASS_STROKE,
		Transparency = Theme.GLASS_STROKE_TRANSPARENCY,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
	children.Padding = e("UIPadding", {
		PaddingLeft = UDim.new(0, Theme.PADDING),
		PaddingRight = UDim.new(0, Theme.PADDING),
		PaddingTop = UDim.new(0, Theme.PADDING),
		PaddingBottom = UDim.new(0, Theme.PADDING),
	})
	children.Layout = e("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 6),
	})
	children.Header = e(Components.Section, { Text = "Road Library", First = true, LayoutOrder = 1 })
	children.CategoryTabs = e(Components.Row, { LayoutOrder = 2 }, categoryTabs)
	children.Tiles = e("ScrollingFrame", stripScrollProps, tiles)

	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.GLASS_BG,
		BackgroundTransparency = Theme.GLASS_TRANSPARENCY,
		BorderSizePixel = 0,
	}, children)
end

return RoadLibraryPanel
