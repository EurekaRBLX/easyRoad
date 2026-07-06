-- EasyRoad loader
-- Creates the toolbar button + dock panel and lazy loads the main plugin
-- code on first activation.

local Signal = require(script.Parent.Packages.Signal)

local RIBBON_ICON = "rbxassetid://139521183742106"
local TOOLTIP = "Placing customizable roads with ease."

local buttonClicked = Signal.new()

local toolbar = plugin:CreateToolbar("easyRoad")
local button = toolbar:CreateButton("easyRoad", TOOLTIP, RIBBON_ICON, "easyRoad")
local clickCn = button.Click:Connect(function()
	buttonClicked:Fire()
end)
local function setButtonActive(active: boolean)
	button:SetActive(active)
end
plugin.Unloading:Connect(function()
	clickCn:Disconnect()
end)

-- Create the dockable panel
local params = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float,
	false, -- Is it initially enabled
	false, -- Override the previous state
	280, -- Default width
	420, -- Default height
	260, -- Minimum width
	320  -- Minimum height
)
local panel = plugin:CreateDockWidgetPluginGuiAsync("EasyRoadPanel", params)

local loaded = false
local function doInitialLoad()
	loaded = true
	require(script.Parent.Src.main)(plugin, panel, buttonClicked, setButtonActive)
end

-- Lazy load the main plugin on first click
local clickedCn = buttonClicked:Connect(function()
	if not loaded then
		doInitialLoad()
		-- Refire event now that the plugin is listening
		buttonClicked:Fire()
	end
end)

panel.Title = "easyRoad"
panel.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
if panel.Enabled then
	doInitialLoad()
end

plugin.Deactivation:Connect(function()
	clickedCn:Disconnect()
end)
