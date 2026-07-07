--!strict
-- EasyRoad main: wires the toolbar button, the top mode bar, the bottom
-- HUD surfaces, the docked settings sidebar, the road library, and the
-- placement/edit sessions together.
--
-- One glass top bar switches between the plugin's functions, CS2-style,
-- so each surface serves a single job:
--
--   Road Tools   - placement session; compact tool panel bottom-left
--   Road Editor  - create/edit road types; full designer bottom bar
--                  (properties | lane strip | modules palette)
--   Settings     - grand settings (region profile, scale, banking, ...)
--                  docked in the Studio sidebar panel
--
-- Selecting an already-placed road (outside of a build session) opens the
-- same designer bottom bar bound to that road, with Apply/Revert.

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
local RoadDesigner = require("./UI/RoadDesigner")
local RoadInspector = require("./UI/RoadInspector")
local BuildBar = require("./UI/BuildBar")
local TopBar = require("./UI/TopBar")
local SettingsGui = require("./UI/SettingsGui")
local Components = require("./UI/Components")

return function(
	plugin: Plugin,
	panel: DockWidgetPluginGui,
	buttonClicked: Signal.Signal<>,
	setButtonActive: (active: boolean) -> ()
)
	local settings = Settings.Load(plugin)
	local library = createRoadLibrary(RegionStyles.Get(settings.RegionId), settings.UserProfiles)

	-- Whether the plugin UI (top bar) is shown at all; toggled by the
	-- toolbar button.
	local pluginOpen = false

	local session: createRoadSession.RoadSession? = nil
	local sessionChangedCn: Signal.Connection? = nil

	-- Library road being edited in the Road Editor (a working copy; only
	-- written to the library when the user saves)
	local designProfile: RoadProfile.RoadProfile? = nil

	-- Shared with the session so HUD clicks don't also place road points
	local uiState: createRoadSession.UiState = { Hovered = false }

	local panelRoot: ReactRoblox.RootType? = nil
	local topRoot: ReactRoblox.RootType? = nil
	local topScreenGui: ScreenGui? = nil
	local bottomRoot: ReactRoblox.RootType? = nil
	local bottomScreenGui: ScreenGui? = nil

	local updateUI: () -> () = nil :: any

	local function getStyle(): RegionStyles.RegionStyle
		return RegionStyles.Get(settings.RegionId)
	end

	-- Selection-based road editing: always listening (independent of the
	-- build session) so clicking an already-placed road with Studio's
	-- ordinary selection shows the designer, no tool activation required.
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
		designProfile = nil -- Tools and Editor are exclusive modes
		local initialProfile = library.Get(settings.DefaultProfileId) or library.GetDefault()
		local newSession = createRoadSession(plugin, settings, getStyle, initialProfile, uiState)
		sessionChangedCn = newSession.ChangeSignal:Connect(function()
			updateUI()
		end)
		session = newSession
		updateUI()
	end

	local function stopSession()
		destroySession()
		updateUI()
	end

	local function openEditor()
		destroySession()
		plugin:Deactivate()
		local source = library.Get(settings.DefaultProfileId) or library.GetDefault()
		designProfile = RoadProfile.Clone(source)
		updateUI()
	end

	local function closeEditor()
		designProfile = nil
		updateUI()
	end

	local function newRoadTemplate(): RoadProfile.RoadProfile
		return {
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
		}
	end

	function updateUI()
		-- Top mode bar --------------------------------------------------------
		if pluginOpen then
			if not topRoot then
				local screen = Instance.new("ScreenGui")
				screen.Name = "EasyRoadTopBar"
				screen.ResetOnSpawn = false
				screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
				screen.IgnoreGuiInset = true
				screen.Parent = CoreGui
				topScreenGui = screen
				topRoot = ReactRoblox.createRoot(screen)
			end
			assert(topRoot):render(React.createElement(TopBar, {
				ToolsActive = session ~= nil,
				EditorActive = designProfile ~= nil,
				SettingsOpen = panel.Enabled,
				OnTools = function()
					if session then
						stopSession()
						plugin:Deactivate()
					else
						startSession()
					end
				end,
				OnEditor = function()
					if designProfile then
						closeEditor()
					else
						openEditor()
					end
				end,
				OnSettings = function()
					panel.Enabled = not panel.Enabled
				end,
				OnHoverChanged = function(hovered: boolean)
					uiState.Hovered = hovered
				end,
			}))
		else
			if topRoot then
				assert(topRoot):unmount()
				topRoot = nil
			end
			if topScreenGui then
				topScreenGui:Destroy()
				topScreenGui = nil
			end
		end

		-- Bottom HUD ----------------------------------------------------------
		-- One surface at a time: the Road Editor designer, the Road Tools
		-- panel, or the placed-road designer for the current selection.
		local bottomContent: any = nil
		local bottomFrameProps: { [string]: any } = nil :: any
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
				OnClick = closeEditor,
			})

			local pickerOptions: { Components.DropdownOption } = {}
			for _, libraryProfile in library.GetAll() do
				table.insert(pickerOptions, {
					Id = libraryProfile.Id,
					Text = libraryProfile.Name .. (if libraryProfile.BuiltIn then " (built-in)" else ""),
				})
			end

			bottomContent = React.createElement(RoadDesigner.Panel, {
				Profile = editing,
				RegionStyle = getStyle(),
				Subtitle = if editing.BuiltIn
					then "Built-in template — saving creates an editable copy."
					else nil,
				Picker = {
					Options = pickerOptions,
					SelectedId = if library.Get(editing.Id) then editing.Id else nil,
					OnPick = function(id: string)
						local profile = library.Get(id)
						if profile then
							designProfile = RoadProfile.Clone(profile)
							updateUI()
						end
					end,
					OnNew = function()
						designProfile = newRoadTemplate()
						updateUI()
					end,
				},
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
			bottomFrameProps = {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 12, 1, -12),
				Size = UDim2.new(1, -24, 0, 420),
			}
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
				Hint = currentSession.GetHint(),
				Elevation = currentSession.GetElevation(),
				AdjustElevation = function(delta: number)
					currentSession.AdjustElevation(delta)
				end,
				OnStop = function()
					stopSession()
					plugin:Deactivate()
				end,
			})
			bottomFrameProps = {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 12, 1, -12),
				Size = UDim2.new(0, 300, 0, 400),
			}
		elseif editSession.GetSelectedRoad() then
			bottomContent = React.createElement(RoadInspector, {
				Session = editSession,
				RegionStyle = getStyle(),
			})
			bottomFrameProps = {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 12, 1, -12),
				Size = UDim2.new(1, -24, 0, 420),
			}
		end

		if bottomContent then
			if not bottomRoot then
				local screen = Instance.new("ScreenGui")
				screen.Name = "EasyRoadHUD"
				screen.ResetOnSpawn = false
				screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
				screen.IgnoreGuiInset = true
				screen.Parent = CoreGui
				bottomScreenGui = screen
				bottomRoot = ReactRoblox.createRoot(screen)
			end
			bottomFrameProps.BackgroundTransparency = 1
			bottomFrameProps[React.Event.MouseEnter] = function()
				uiState.Hovered = true
			end
			bottomFrameProps[React.Event.MouseLeave] = function()
				uiState.Hovered = false
			end
			assert(bottomRoot):render(React.createElement("Frame", bottomFrameProps, {
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

		-- Docked settings sidebar ----------------------------------------------
		if panel.Enabled then
			if not panelRoot then
				panelRoot = ReactRoblox.createRoot(panel)
			end
			assert(panelRoot):render(React.createElement(SettingsGui, {
				Settings = settings,
				OnSettingsChanged = function()
					-- Region (or other grand settings) may have changed: rebuild
					-- the built-in road set to match and persist everything.
					library.SetStyle(getStyle())
					persist()
					updateUI()
				end,
				OnClose = function()
					panel.Enabled = false
				end,
			}))
		elseif panelRoot then
			panelRoot:unmount()
			panelRoot = nil
		end
	end

	local clickedCn = buttonClicked:Connect(function()
		pluginOpen = not pluginOpen
		if not pluginOpen then
			destroySession()
			designProfile = nil
			plugin:Deactivate()
		end
		setButtonActive(pluginOpen)
		updateUI()
	end)

	panel:GetPropertyChangedSignal("Enabled"):Connect(function()
		updateUI()
	end)

	-- Initial UI show in the case where the panel starts enabled
	updateUI()

	-- When the user switches to another Studio tool, stop placing (the top
	-- bar and other surfaces stay).
	plugin.Deactivation:Connect(function()
		stopSession()
	end)

	plugin.Unloading:Connect(function()
		destroySession()
		if panelRoot then
			panelRoot:unmount()
			panelRoot = nil
		end
		if topRoot then
			topRoot:unmount()
			topRoot = nil
		end
		if topScreenGui then
			topScreenGui:Destroy()
			topScreenGui = nil
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
