-- EasyRoad loader
-- Creates the toolbar button + dock panel and lazy loads the main plugin
-- code on first activation.

local Signal = require(script.Parent.Packages.Signal)

local RIBBON_ICON = "rbxassetid://0" -- TODO: Upload a real icon for release
local TOOLTIP = "Activate the EasyRoad road building tool, opening the road placement panel."

local buttonClicked = Signal.new()

local toolbar = plugin:CreateToolbar("EasyRoad")
local button = toolbar:CreateButton("openEasyRoad", TOOLTIP, RIBBON_ICON, "EasyRoad")
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

panel.Title = "EasyRoad"
panel.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
if panel.Enabled then
	doInitialLoad()
end

plugin.Deactivation:Connect(function()
	clickedCn:Disconnect()
end)
