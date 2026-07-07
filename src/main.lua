--!strict
-- EasyRoad main: wires the toolbar button, bottom HUD, dock panel,
-- settings, road library, placement session, and React UI together.
--
-- All viewport UI lives in ONE bottom-anchored CS2-style bar: the build
-- bar while placing roads, the road designer when editing a library road,
-- and the placed-road inspector when a road is selected. The dock panel
-- keeps working as an alternative surface when it is open.

local CoreGui = game:GetService("CoreGui")

local Packages = script.Parent.Parent.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)
local Signal = require(Packages.Signal)

local Settings = require("./Settings")
local RegionStyles = require("./RegionStyles")
local RoadProfile = require("./RoadProfile")
local createRoadLibrary = require("./RoadLibrary")
local createRoadSession = require("./createRoadSession")
local createRoadEditSession = require("./RoadEditSession")
local EasyRoadGui = require("./UI/EasyRoadGui")
local RoadDesigner = require("./UI/RoadDesigner")
local RoadInspector = require("./UI/RoadInspector")
local BuildBar = require("./UI/BuildBar")

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
	local bottomRoot: ReactRoblox.RootType? = nil
	local bottomScreenGui: ScreenGui? = nil

	-- Library road being edited in the bottom designer HUD (a working copy;
	-- only written to the library when the user saves)
	local designProfile: RoadProfile.RoadProfile? = nil

	local updateUI: () -> () = nil :: any

	local function getStyle(): RegionStyles.RegionStyle
		return RegionStyles.Get(settings.RegionId)
	end

	-- Selection-based road editing: always listening (independent of the
	-- build session) so clicking an already-placed road with Studio's
	-- ordinary selection shows the inspector, no tool activation required.
	local editSession = createRoadEditSession(plugin, settings, getStyle)
	local editSessionChangedCn = editSession.ChangeSignal:Connect(function()
		updateUI()
	end)

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
			-- The full active profile (which may carry session-only width
			-- tweaks) so the build HUD can list and edit component widths
			-- without touching the saved library road.
			ActiveProfile = if currentSession then currentSession.GetProfile() else nil,
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
			-- Session-only width tweak: clones the active profile, edits one
			-- component's width, and feeds it straight to the session. Does
			-- NOT touch the saved library road unless explicitly saved.
			AdjustComponentWidth = function(index: number, widthM: number)
				if not currentSession then
					return
				end
				local clone = RoadProfile.Clone(currentSession.GetProfile())
				local component = clone.Components[index]
				if not component then
					return
				end
				component.WidthM = math.max(widthM, 0.1)
				currentSession.SetProfile(clone)
				updateUI()
			end,
			SaveActiveProfileAsNew = function()
				if not currentSession then
					return
				end
				local clone = RoadProfile.Clone(currentSession.GetProfile())
				clone.Id = "user_" .. tostring(os.time())
				clone.Name = clone.Name .. " (Modified)"
				clone.Category = "Custom"
				clone.BuiltIn = false
				library.SaveUserProfile(clone)
				settings.DefaultProfileId = clone.Id
				currentSession.SetProfile(clone)
				persist()
				updateUI()
			end,
			HandleAction = handleAction,
			OpenDesigner = function(profile: RoadProfile.RoadProfile)
				designProfile = profile
				updateUI()
			end,
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
		-- Bottom HUD: the CS2-style lane strip bar. Priority order:
		--   1. a library road open in the designer,
		--   2. the build bar while placing roads,
		--   3. the placed road currently selected.
		local bottomContent: any = nil
		if designProfile then
			local editing = designProfile :: RoadProfile.RoadProfile
			local actions: { RoadDesigner.DesignerAction } = {
				{
					Text = if editing.BuiltIn then "Save as Copy" else "Save",
					Selected = true,
					OnClick = function()
						local toSave = RoadProfile.Clone(editing)
						if editing.BuiltIn then
							toSave.Id = "user_" .. tostring(os.time())
							toSave.Name = editing.Name .. " (Custom)"
							toSave.Category = "Custom"
						end
						toSave.BuiltIn = false
						library.SaveUserProfile(toSave)
						designProfile = toSave
						persist()
						updateUI()
					end,
				},
			}
			if not editing.BuiltIn and library.Get(editing.Id) ~= nil then
				table.insert(actions, {
					Text = "Delete",
					Danger = true,
					OnClick = function()
						library.DeleteUserProfile(editing.Id)
						designProfile = nil
						persist()
						updateUI()
					end,
				})
			end
			table.insert(actions, {
				Text = "Close",
				OnClick = function()
					designProfile = nil
					updateUI()
				end,
			})
			bottomContent = React.createElement(RoadDesigner.Panel, {
				Profile = editing,
				RegionStyle = getStyle(),
				Subtitle = if editing.BuiltIn
					then "Built-in template — saving creates an editable copy."
					else nil,
				OnChange = function(transform: (profile: RoadProfile.RoadProfile) -> ())
					local copy = RoadProfile.Clone(editing)
					transform(copy)
					designProfile = copy
					updateUI()
				end,
				OnRename = function(name: string)
					local copy = RoadProfile.Clone(editing)
					copy.Name = name
					designProfile = copy
					updateUI()
				end,
				Actions = actions,
			})
		elseif session then
			local currentSession = session :: createRoadSession.RoadSession
			bottomContent = React.createElement(BuildBar, {
				ToolMode = currentSession.GetToolMode(),
				SetToolMode = function(mode: string)
					currentSession.SetToolMode(mode :: createRoadSession.ToolMode)
				end,
				Library = library,
				ProfileId = currentSession.GetProfile().Id,
				SetProfileId = function(id: string)
					local profile = library.Get(id)
					if profile then
						settings.DefaultProfileId = id
						currentSession.SetProfile(profile)
						persist()
						updateUI()
					end
				end,
				EndProfileId = if currentSession.GetEndProfile()
					then (currentSession.GetEndProfile() :: RoadProfile.RoadProfile).Id
					else nil,
				SetEndProfileId = function(id: string?)
					currentSession.SetEndProfile(if id then library.Get(id) else nil)
				end,
				Settings = settings,
				OnSettingsChanged = function()
					library.SetStyle(getStyle())
					persist()
					updateUI()
				end,
				Profile = currentSession.GetProfile(),
				OnChangeProfile = function(transform: (profile: RoadProfile.RoadProfile) -> ())
					local clone = RoadProfile.Clone(currentSession.GetProfile())
					transform(clone)
					currentSession.SetProfile(clone)
					updateUI()
				end,
				SaveAsNew = function()
					local clone = RoadProfile.Clone(currentSession.GetProfile())
					clone.Id = "user_" .. tostring(os.time())
					clone.Name = clone.Name .. " (Modified)"
					clone.Category = "Custom"
					clone.BuiltIn = false
					library.SaveUserProfile(clone)
					settings.DefaultProfileId = clone.Id
					currentSession.SetProfile(clone)
					persist()
					updateUI()
				end,
				Hint = currentSession.GetHint(),
				Elevation = currentSession.GetElevation(),
				RegionStyle = getStyle(),
				OnStop = function()
					stopSession()
					plugin:Deactivate()
				end,
			})
		elseif editSession.GetSelectedRoad() then
			bottomContent = React.createElement(RoadInspector, {
				Session = editSession,
				RegionStyle = getStyle(),
			})
		end

		if bottomContent then
			if not bottomRoot then
				local screen = Instance.new("ScreenGui")
				screen.Name = "EasyRoadDesignerHUD"
				screen.ResetOnSpawn = false
				screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
				screen.Parent = CoreGui
				bottomScreenGui = screen
				bottomRoot = ReactRoblox.createRoot(screen)
			end
			assert(bottomRoot):render(React.createElement("Frame", {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 12, 1, -12),
				Size = UDim2.new(1, -24, 0, 260),
				BackgroundTransparency = 1,
				[React.Event.MouseEnter] = function()
					uiState.Hovered = true
				end,
				[React.Event.MouseLeave] = function()
					uiState.Hovered = false
				end,
			}, {
				Gui = bottomContent,
			}))
		else
			if bottomRoot then
				assert(bottomRoot):unmount()
				bottomRoot = nil
			end
			if bottomScreenGui then
				bottomScreenGui:Destroy()
				bottomScreenGui = nil
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
		if bottomRoot then
			bottomRoot:unmount()
			bottomRoot = nil
		end
		if bottomScreenGui then
			bottomScreenGui:Destroy()
			bottomScreenGui = nil
		end
		editSession.Destroy()
		editSessionChangedCn:Disconnect()
		persist()
		clickedCn:Disconnect()
	end)
end
