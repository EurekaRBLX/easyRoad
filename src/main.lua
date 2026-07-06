--!strict
-- EasyRoad main: wires the toolbar button, viewport HUD, dock panel,
-- settings, road library, placement session, and React UI together.
--
-- While a build session is active the UI renders as a glassmorphism HUD
-- inside the viewport (right-anchored); the dock panel keeps working as an
-- alternative surface when it is open.

local CoreGui = game:GetService("CoreGui")

local Packages = script.Parent.Parent.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)
local Signal = require(Packages.Signal)

local Settings = require("./Settings")
local RegionStyles = require("./RegionStyles")
local createRoadLibrary = require("./RoadLibrary")
local createRoadSession = require("./createRoadSession")
local EasyRoadGui = require("./UI/EasyRoadGui")

return function(
	plugin: Plugin,
	panel: DockWidgetPluginGui,
	buttonClicked: Signal.Signal<>,
	setButtonActive: (active: boolean) -> ()
)
	local settings = Settings.Load(plugin)
	local library = createRoadLibrary(RegionStyles.Get(settings.RegionId), settings.UserProfiles)

	local session: createRoadSession.RoadSession? = nil
	local sessionChangedCn: Signal.Connection? = nil

	-- Shared with the session so HUD clicks don't also place road points
	local uiState: createRoadSession.UiState = { Hovered = false }

	local panelRoot: ReactRoblox.RootType? = nil
	local hudRoot: ReactRoblox.RootType? = nil
	local hudScreenGui: ScreenGui? = nil

	local updateUI: () -> () = nil :: any

	local function getStyle(): RegionStyles.RegionStyle
		return RegionStyles.Get(settings.RegionId)
	end

	local function persist()
		settings.UserProfiles = library.SerializeUserProfiles()
		Settings.Save(plugin, settings)
	end

	local function destroySession()
		if session then
			session.Destroy()
			session = nil
		end
		if sessionChangedCn then
			sessionChangedCn:Disconnect()
			sessionChangedCn = nil
		end
		uiState.Hovered = false
	end

	local function startSession()
		if session then
			return
		end
		local initialProfile = library.Get(settings.DefaultProfileId) or library.GetDefault()
		local newSession = createRoadSession(plugin, settings, getStyle, initialProfile, uiState)
		sessionChangedCn = newSession.ChangeSignal:Connect(function()
			updateUI()
		end)
		session = newSession
		setButtonActive(true)
		updateUI()
	end

	local function stopSession()
		destroySession()
		setButtonActive(false)
		updateUI()
	end

	local function handleAction(action: string)
		if action == "activate" then
			startSession()
		elseif action == "close" then
			stopSession()
			plugin:Deactivate()
		else
			warn("Unknown EasyRoad action: " .. action)
		end
	end

	local function makeGuiProps(): { [string]: any }
		local currentSession = session
		return {
			Active = currentSession ~= nil,
			ToolMode = if currentSession then currentSession.GetToolMode() else "Curve",
			Hint = if currentSession then currentSession.GetHint() else "",
			Elevation = if currentSession then currentSession.GetElevation() else 0,
			ProfileId = if currentSession then currentSession.GetProfile().Id else settings.DefaultProfileId,
			EndProfileId = if currentSession and currentSession.GetEndProfile()
				then (currentSession.GetEndProfile() :: any).Id
				else nil,
			Library = library,
			Settings = settings,
			SetToolMode = function(mode: string)
				if currentSession then
					currentSession.SetToolMode(mode :: createRoadSession.ToolMode)
				end
			end,
			SetProfileId = function(id: string)
				local profile = library.Get(id)
				if profile then
					settings.DefaultProfileId = id
					if currentSession then
						currentSession.SetProfile(profile)
					end
					persist()
					updateUI()
				end
			end,
			SetEndProfileId = function(id: string?)
				if currentSession then
					currentSession.SetEndProfile(if id then library.Get(id) else nil)
				end
			end,
			HandleAction = handleAction,
			OnSettingsChanged = function()
				-- Region (or other grand settings) may have changed: rebuild
				-- the built-in road set to match and persist everything.
				library.SetStyle(getStyle())
				persist()
				updateUI()
			end,
			OnLibraryChanged = function()
				persist()
				updateUI()
			end,
		}
	end

	function updateUI()
		-- Viewport HUD: shown while a build session is active
		if session then
			if not hudRoot then
				local screen = Instance.new("ScreenGui")
				screen.Name = "EasyRoadHUD"
				screen.ResetOnSpawn = false
				screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
				screen.Parent = CoreGui
				hudScreenGui = screen
				hudRoot = ReactRoblox.createRoot(screen)
			end
			assert(hudRoot):render(React.createElement("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0),
				Size = UDim2.new(0, 300, 0.8, 0),
				BackgroundTransparency = 1,
				[React.Event.MouseEnter] = function()
					uiState.Hovered = true
				end,
				[React.Event.MouseLeave] = function()
					uiState.Hovered = false
				end,
			}, {
				Gui = React.createElement(EasyRoadGui, makeGuiProps()),
			}))
		else
			if hudRoot then
				assert(hudRoot):unmount()
				hudRoot = nil
			end
			if hudScreenGui then
				hudScreenGui:Destroy()
				hudScreenGui = nil
			end
		end

		-- Dock panel: alternative surface whenever it is open
		if panel.Enabled then
			if not panelRoot then
				panelRoot = ReactRoblox.createRoot(panel)
			end
			assert(panelRoot):render(React.createElement(EasyRoadGui, makeGuiProps()))
		elseif panelRoot then
			panelRoot:unmount()
			panelRoot = nil
		end
	end

	local clickedCn = buttonClicked:Connect(function()
		if session then
			stopSession()
			plugin:Deactivate()
		else
			startSession()
		end
	end)

	panel:GetPropertyChangedSignal("Enabled"):Connect(function()
		updateUI()
	end)

	-- Initial UI show in the case where the panel starts enabled
	updateUI()

	-- When the user selects a different tool, stop building
	plugin.Deactivation:Connect(function()
		stopSession()
	end)

	plugin.Unloading:Connect(function()
		destroySession()
		if panelRoot then
			panelRoot:unmount()
			panelRoot = nil
		end
		if hudRoot then
			hudRoot:unmount()
			hudRoot = nil
		end
		if hudScreenGui then
			hudScreenGui:Destroy()
			hudScreenGui = nil
		end
		persist()
		clickedCn:Disconnect()
	end)
end
