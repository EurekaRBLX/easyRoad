--!strict
-- Settings → Software: product identity and about copy.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local ProductLicense = require("../ProductLicense")

local function Line(props: {
	Text: string,
	Dim: boolean?,
	Accent: boolean?,
	Size: number?,
	LayoutOrder: number,
})
	return e("TextLabel", {
		Text = props.Text,
		TextColor3 = if props.Accent then Theme.ACCENT elseif props.Dim then Theme.DIM else Theme.OFFWHITE,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = if props.Accent then Enum.Font.BuilderSansMedium else Theme.FONT,
		TextSize = props.Size or (Theme.TEXT_SIZE - 2),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		LayoutOrder = props.LayoutOrder,
	})
end

local function SoftwareGui(props: {
	OnClose: () -> (),
	OnViewEula: (() -> ())?,
	OnRunSetup: (() -> ())?,
})
	local scrollProps = Components.ScrollBar()
	scrollProps.Size = UDim2.fromScale(1, 1)
	scrollProps.BackgroundColor3 = Theme.BACKGROUND
	scrollProps.BorderSizePixel = 0
	scrollProps.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollProps.ScrollingDirection = Enum.ScrollingDirection.Y

	return e("ScrollingFrame", scrollProps, {
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 10),
			PaddingTop = UDim.new(0, 10),
			PaddingBottom = UDim.new(0, 10),
		}),
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 8),
		}),
		Title = e("TextLabel", {
			Text = "Software",
			TextColor3 = Theme.ACCENT,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 24),
			Font = Enum.Font.BuilderSansMedium,
			TextSize = Theme.TEXT_SIZE,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 1,
		}),
		Brand = e(Line, {
			Text = "easyRoad",
			Accent = true,
			Size = Theme.TEXT_SIZE + 4,
			LayoutOrder = 2,
		}),
		Product = e(Line, {
			Text = "A product of Eureka · Build " .. ProductLicense.Build,
			LayoutOrder = 3,
		}),
		Dev = e(Line, {
			Text = "Developed by HR_Gameson0630",
			LayoutOrder = 4,
		}),
		For = e(Line, {
			Text = "Road design, junctions, markings, viaducts, and tunnels for Roblox Studio.",
			LayoutOrder = 5,
		}),
		Spacer = e("Frame", {
			Size = UDim2.new(1, 0, 0, 8),
			BackgroundTransparency = 1,
			LayoutOrder = 6,
		}),
		Rights = e(Line, {
			Text = "Copyright © Eureka 2026",
			Dim = true,
			LayoutOrder = 7,
		}),
		License = e(Line, {
			Text = "License: " .. ProductLicense.OssLicenseName .. " (GNU Affero GPL version 3).",
			Dim = true,
			LayoutOrder = 8,
		}),
		Source = e(Line, {
			Text = "Source code: " .. ProductLicense.SourceUrl,
			Dim = true,
			LayoutOrder = 9,
		}),
		Notices = e(Line, {
			Text = "The plugin package includes the full license and third-party notices. This software comes without warranty.",
			Dim = true,
			LayoutOrder = 10,
		}),
		Note = e(Line, {
			Text = "Works alongside easyLight for advanced signal control.",
			Dim = true,
			LayoutOrder = 11,
		}),
		RunSetup = props.OnRunSetup and e(Components.Button, {
			Text = "Run Quick Setup",
			Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
			LayoutOrder = 12,
			OnClick = props.OnRunSetup :: () -> (),
		}),
		Close = e(Components.Button, {
			Text = "Close",
			Size = UDim2.new(1, 0, 0, Theme.ROW_HEIGHT),
			LayoutOrder = 14,
			OnClick = props.OnClose,
		}),
	})
end

return SoftwareGui
