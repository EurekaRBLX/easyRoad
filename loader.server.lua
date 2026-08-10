-- EasyRoad loader
-- Creates the toolbar button + dock panels and lazy loads the main plugin
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

-- Settings are a few separate docks, named by function, rather than one
-- panel with internal tabs - each is independently dockable/movable.
local function createDock(id: string, title: string, width: number?, height: number?): DockWidgetPluginGui
	local params = DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Float,
		false, -- Is it initially enabled
		false, -- Override the previous state
		width or 280, -- Default width
		height or 420, -- Default height
		260, -- Minimum width
		320 -- Minimum height
	)
	local dock = plugin:CreateDockWidgetPluginGuiAsync(id, params)
	dock.Title = title
	dock.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	return dock
end

local regionalDock = createDock("EasyRoadRegionalDock", "easyRoad - Regional Preference")
local keybindsDock = createDock("EasyRoadKeybindsDock", "easyRoad - Keybinds")
local softwareDock = createDock("EasyRoadSoftwareDock", "easyRoad - Software")
local backupsDock = createDock("EasyRoadBackupsDock", "easyRoad - Backups", 320, 520)

local loaded = false
local function doInitialLoad()
	loaded = true
	require(script.Parent.Src.main)(
		plugin,
		regionalDock,
		keybindsDock,
		softwareDock,
		backupsDock,
		buttonClicked,
		setButtonActive
	)
end

-- Lazy load the main plugin on first click
local clickedCn = buttonClicked:Connect(function()
	if not loaded then
		doInitialLoad()
		-- Refire event now that the plugin is listening
		buttonClicked:Fire()
	end
end)

if regionalDock.Enabled or keybindsDock.Enabled or softwareDock.Enabled or backupsDock.Enabled then
	doInitialLoad()
end

plugin.Deactivation:Connect(function()
	clickedCn:Disconnect()
end)
