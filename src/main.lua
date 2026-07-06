--!strict
-- EasyRoad main: wires the toolbar button, dock panel, settings, road
-- library, placement session, and React UI together.

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

	local reactRoot: ReactRoblox.RootType? = nil

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
	end

	local function startSession()
		if session then
			return
		end
		local initialProfile = library.Get(settings.DefaultProfileId) or library.GetDefault()
		local newSession = createRoadSession(plugin, settings, getStyle, initialProfile)
		sessionChangedCn = newSession.ChangeSignal:Connect(function()
			updateUI()
		end)
		session = newSession
		setButtonActive(true)
		panel.Enabled = true
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

	function updateUI()
		if not panel.Enabled then
			if reactRoot then
				reactRoot:unmount()
				reactRoot = nil
			end
			return
		end
		if not reactRoot then
			reactRoot = ReactRoblox.createRoot(panel)
		end
		local currentSession = session
		assert(reactRoot):render(React.createElement(EasyRoadGui, {
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
		}))
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
		if reactRoot then
			reactRoot:unmount()
			reactRoot = nil
		end
		persist()
		clickedCn:Disconnect()
	end)
end
