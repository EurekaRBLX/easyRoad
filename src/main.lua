--!strict
-- EasyRoad main: wires the toolbar button, the top mode bar, the bottom
-- HUD surfaces, the two settings docks, the road library, and the
-- placement/edit sessions together.
--
-- One glass top bar switches between the plugin's functions, CS2-style,
-- so each surface serves a single job:
--
--   Road Tools   - placement session; compact tool panel bottom-left
--   Road Editor  - create/edit road types; full designer bottom bar
--                  (properties | lane strip | modules palette)
--   Settings     - grand settings, as separate docks named by function
--                  (Regional Preference, Keybinds) rather than tabs in
--                  one panel - toggled together by the Settings button
--
-- Selecting an already-placed road (outside of a build session) opens the
-- same designer bottom bar bound to that road, with Apply/Revert.

local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local Packages = script.Parent.Parent.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)
local Signal = require(Packages.Signal)

local Settings = require("./Settings")
local RegionStyles = require("./RegionStyles")
local RoadProfile = require("./RoadProfile")
local KeybindsModule = require("./Keybinds")
local createRoadLibrary = require("./RoadLibrary")
local createRegionLibrary = require("./RegionLibrary")
local createRoadSession = require("./createRoadSession")
local createRoadEditSession = require("./RoadEditSession")
local RoadDesigner = require("./UI/RoadDesigner")
local RoadInspector = require("./UI/RoadInspector")
local BuildBar = require("./UI/BuildBar")
local RoadLibraryPanel = require("./UI/RoadLibraryPanel")
local TopBar = require("./UI/TopBar")
local RegionalPreferenceGui = require("./UI/RegionalPreferenceGui")
local KeybindsGui = require("./UI/KeybindsGui")
local Components = require("./UI/Components")
local PieMenu = require("./UI/PieMenu")
local BayDraftPanel = require("./UI/BayDraftPanel")

return function(
	plugin: Plugin,
	regionalDock: DockWidgetPluginGui,
	keybindsDock: DockWidgetPluginGui,
	buttonClicked: Signal.Signal<>,
	setButtonActive: (active: boolean) -> ()
)
	local settings = Settings.Load(plugin)
	local regionLibrary = createRegionLibrary(settings.UserRegions)
	local library = createRoadLibrary(regionLibrary.Get(settings.RegionId), settings.UserProfiles)

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

	local regionalRoot: ReactRoblox.RootType? = nil
	local keybindsRoot: ReactRoblox.RootType? = nil
	local topRoot: ReactRoblox.RootType? = nil
	local topScreenGui: ScreenGui? = nil
	local bottomRoot: ReactRoblox.RootType? = nil
	local bottomScreenGui: ScreenGui? = nil
	local pieMenuRoot: ReactRoblox.RootType? = nil
	local pieMenuScreenGui: ScreenGui? = nil

	local updateUI: () -> () = nil :: any

	local function getStyle(): RegionStyles.RegionStyle
		return regionLibrary.Get(settings.RegionId)
	end

	-- Selection-based road editing: always listening (independent of the
	-- build session) so clicking an already-placed road with Studio's
	-- ordinary selection shows the designer, no tool activation required.
	local editSession = createRoadEditSession(plugin, settings, getStyle, uiState)
	local editSessionChangedCn = editSession.ChangeSignal:Connect(function()
		updateUI()
	end)

	local function persist()
		settings.UserProfiles = library.SerializeUserProfiles()
		settings.UserRegions = regionLibrary.SerializeUserRegions()
		Settings.Save(plugin, settings)
	end

	-- Keybinds settings dock: listens for the next key/click and reports it
	-- back, so "+  Add binding" can capture whatever the user presses.
	-- Deliberately does NOT check gameProcessed - Studio marks essentially
	-- all input as "game processed" while a docked plugin panel has focus
	-- (so it doesn't also trigger 3D-viewport shortcuts), which is exactly
	-- why R/F/Escape's own live listener (createRoadSession.lua) checks it
	-- but this one must not: during an explicit capture, whatever the user
	-- just pressed IS the input we want, regardless of what else has
	-- focus. Skipping this check was the reason capturing silently never
	-- registered anything.
	local function captureNextKeybind(onCaptured: (label: string) -> ())
		local connection: RBXScriptConnection? = nil
		connection = UserInputService.InputBegan:Connect(function(input)
			local label = KeybindsModule.CaptureLabel(input)
			if label then
				if connection then
					connection:Disconnect()
				end
				onCaptured(label)
			end
		end)
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

	-- profileOverride/seed power the pie menu's "Place More" action: continue
	-- building from an exact existing road's end, with its exact profile,
	-- rather than starting fresh with the default road.
	local function startSession(seed: createRoadSession.SessionSeed?, profileOverride: RoadProfile.RoadProfile?)
		if session then
			return
		end
		designProfile = nil -- Tools and Editor are exclusive modes
		pluginOpen = true
		setButtonActive(true)
		local initialProfile = profileOverride or library.Get(settings.DefaultProfileId) or library.GetDefault()
		local newSession = createRoadSession(plugin, settings, getStyle, initialProfile, uiState, seed)
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

	local function openEditor(sourceProfile: RoadProfile.RoadProfile?)
		destroySession()
		plugin:Deactivate()
		pluginOpen = true
		setButtonActive(true)
		local source = sourceProfile or library.Get(settings.DefaultProfileId) or library.GetDefault()
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
				RegionalOpen = regionalDock.Enabled,
				KeybindsOpen = keybindsDock.Enabled,
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
				-- Settings are separate docks, named by function, rather than
				-- tabs in one panel - opened one at a time from the Settings
				-- home menu instead of both together (which used to stack
				-- both docks at the same default float position, making the
				-- second one impossible to find).
				OnOpenRegional = function()
					regionalDock.Enabled = not regionalDock.Enabled
				end,
				OnOpenKeybinds = function()
					keybindsDock.Enabled = not keybindsDock.Enabled
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

			local pickerOptions: { RoadDesigner.LibraryOption } = {}
			for _, libraryProfile in library.GetAll() do
				table.insert(pickerOptions, {
					Id = libraryProfile.Id,
					Text = libraryProfile.Name .. (if libraryProfile.BuiltIn then " (built-in)" else ""),
					Profile = libraryProfile,
				})
			end

			bottomContent = React.createElement(RoadDesigner.Panel, {
				PluginObj = plugin,
				Profile = editing,
				RegionStyle = getStyle(),
				Settings = settings,
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
			local function setProfileId(id: string)
				local profile = library.Get(id)
				if profile then
					settings.DefaultProfileId = id
					currentSession.SetProfile(profile)
					persist()
					updateUI()
				end
			end
			-- Two separate floating boxes side by side, CS2-style, not one
			-- box with everything stacked on top of itself: Tool Mode
			-- (bottom-left) and Road Library (bottom-right), each wrapped
			-- in its own positioning Frame (BuildBar/RoadLibraryPanel both
			-- fill whatever parent they're given via fromScale(1,1)), both
			-- bottom-aligned within a shared invisible wrapper so
			-- hover-tracking (below) stays scoped to roughly their combined
			-- visible footprint instead of the whole screen.
			bottomContent = React.createElement(React.Fragment, nil, {
				ToolMode = React.createElement("Frame", {
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 0, 1, 0),
					Size = UDim2.new(0, 260, 0, 430),
					BackgroundTransparency = 1,
				}, {
					Inner = React.createElement(BuildBar, {
						ToolMode = currentSession.GetToolMode(),
						SetToolMode = function(mode: string)
							currentSession.SetToolMode(mode :: createRoadSession.ToolMode)
						end,
						Library = library,
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
						SetElevation = function(value: number)
							currentSession.SetElevation(value)
						end,
						OnStop = function()
							stopSession()
							plugin:Deactivate()
						end,
					}),
				}),
				RoadLibrary = React.createElement("Frame", {
					AnchorPoint = Vector2.new(1, 1),
					Position = UDim2.new(1, 0, 1, 0),
					Size = UDim2.new(0, 340, 0, 170),
					BackgroundTransparency = 1,
				}, {
					Inner = React.createElement(RoadLibraryPanel, {
						Library = library,
						RegionStyle = getStyle(),
						Settings = settings,
						ProfileId = currentSession.GetProfile().Id,
						SetProfileId = setProfileId,
					}),
				}),
			})
			bottomFrameProps = {
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, -12),
				Size = UDim2.new(0, 612, 0, 430),
			}
		elseif editSession.GetSelectedRoad() and editSession.IsConfirmingBay() then
			local draft = editSession.GetBayDraft()
			if draft then
				bottomContent = React.createElement(BayDraftPanel, {
					LengthStuds = draft.LengthStuds,
					WidthM = draft.WidthM,
					OnLengthChanged = editSession.SetBayDraftLength,
					OnWidthChanged = editSession.SetBayDraftWidth,
				})
				bottomFrameProps = {
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 12, 1, -12),
					Size = UDim2.new(0, 260, 0, 180),
				}
			end
		elseif
			editSession.GetSelectedRoad()
			and not editSession.IsShowingMenu()
			and not editSession.IsShowingSegmentMenu()
			and not editSession.IsPlacingBusStop()
			and not editSession.IsPlacingBay()
			and not editSession.IsConfirmingBay()
		then
			bottomContent = React.createElement(RoadInspector, {
				PluginObj = plugin,
				Session = editSession,
				RegionStyle = getStyle(),
				Settings = settings,
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

		-- Pie menu -------------------------------------------------------------
		-- Shown the moment a placed road is selected, before the full
		-- designer: Edit on Road Builder / Edit Road Segment / Place More /
		-- Use as Template / Cancel, CS2-style. "Edit Road Segment" opens a
		-- second-level submenu (Add Bus Stop / Add Bus Bay / Edit Lane
		-- Markings / Back) at the same anchor. "Add Bus Stop" opens a
		-- click-to-place mode for a marker; "Add Bus Bay" opens a
		-- click-to-place mode for a point on the road, then a length/width
		-- panel (see the ConfirmingBay branch below) before committing the
		-- real carved-out geometry.
		-- Rendered in its own ScreenGui WITHOUT IgnoreGuiInset, matching
		-- WorldToViewportPoint's coordinate space (the bottom HUD's
		-- ScreenGui ignores the inset instead, for the drag-ghost math -
		-- the two need different conventions).
		local menuRoad = editSession.GetSelectedRoad()
		local showPieMenu = menuRoad ~= nil
			and not session
			and not designProfile
			and (
				editSession.IsShowingMenu()
				or editSession.IsShowingSegmentMenu()
				or editSession.IsPlacingBusStop()
				or editSession.IsPlacingBay()
				or editSession.IsConfirmingBay()
			)
		if showPieMenu then
			local anchor = editSession.GetAnchorWorldPosition()
			if anchor then
				if not pieMenuRoot then
					local screen = Instance.new("ScreenGui")
					screen.Name = "EasyRoadPieMenu"
					screen.ResetOnSpawn = false
					screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
					screen.Parent = CoreGui
					pieMenuScreenGui = screen
					pieMenuRoot = ReactRoblox.createRoot(screen)
				end

				local function setGlobalHover(hovered: boolean)
					uiState.Hovered = hovered
				end

				local pieMenuElement: any
				if editSession.IsShowingMenu() then
					pieMenuElement = React.createElement(PieMenu, {
						WorldPosition = anchor,
						SetGlobalHover = setGlobalHover,
						Top = {
							Text = "Edit on Road Builder",
							OnClick = function()
								editSession.OpenEditor()
							end,
						},
						TopLeft = {
							Text = "Edit Road Segment",
							OnClick = function()
								editSession.OpenSegmentMenu()
							end,
						},
						Left = {
							Text = "Place More",
							OnClick = function()
								local continuation = editSession.GetContinuation()
								editSession.Deselect()
								if continuation then
									startSession({
										Position = continuation.Position,
										Tangent = continuation.Tangent,
									}, continuation.Profile)
								end
							end,
						},
						Right = {
							Text = "Use as Template",
							OnClick = function()
								local profile = editSession.GetProfile()
								editSession.Deselect()
								if profile then
									local clone = RoadProfile.Clone(profile)
									clone.Id = "user_" .. tostring(os.time())
									clone.Name = clone.Name .. " (Custom)"
									clone.Category = "Custom"
									clone.BuiltIn = false
									openEditor(clone)
								end
							end,
						},
						Bottom = {
							Text = "Cancel",
							OnClick = function()
								editSession.Deselect()
							end,
						},
					})
				elseif editSession.IsShowingSegmentMenu() then
					pieMenuElement = React.createElement(PieMenu, {
						WorldPosition = anchor,
						SetGlobalHover = setGlobalHover,
						Top = {
							Text = "Add Bus Stop",
							OnClick = function()
								editSession.StartBusStopPlacement()
							end,
						},
						TopLeft = {
							Text = "Add Bus Bay",
							OnClick = function()
								editSession.StartBayPlacement()
							end,
						},
						Left = {
							Text = "Edit Lane Markings",
							OnClick = function()
								-- Number keys 1-4 set a selected lane's marking
								-- directly once inside the designer.
								editSession.OpenEditor()
							end,
						},
						Bottom = {
							Text = "Back",
							OnClick = function()
								editSession.CloseSegmentMenu()
							end,
						},
					})
				elseif editSession.IsPlacingBusStop() then
					pieMenuElement = React.createElement(PieMenu, {
						WorldPosition = anchor,
						SetGlobalHover = setGlobalHover,
						Bottom = {
							Text = "Done (click a sidewalk/parking part to add, an existing stop to remove)",
							OnClick = function()
								editSession.StopBusStopPlacement()
							end,
						},
					})
				elseif editSession.IsPlacingBay() then
					pieMenuElement = React.createElement(PieMenu, {
						WorldPosition = anchor,
						SetGlobalHover = setGlobalHover,
						Bottom = {
							Text = "Click a point on the road for the bus bay (Esc to cancel)",
							OnClick = function()
								editSession.CancelBayPlacement()
							end,
						},
					})
				else -- ConfirmingBay: length/width panel is the bottom HUD below
					pieMenuElement = React.createElement(PieMenu, {
						WorldPosition = anchor,
						SetGlobalHover = setGlobalHover,
						Top = {
							Text = "Add Bay",
							OnClick = function()
								editSession.ConfirmBay()
							end,
						},
						Bottom = {
							Text = "Cancel",
							OnClick = function()
								editSession.CancelBayPlacement()
							end,
						},
					})
				end

				-- Deliberately NOT tracking hover on this wrapping frame: it
				-- spans the whole screen (needed so the anchored pie menu
				-- can be positioned anywhere within it), so a MouseEnter
				-- here would fire almost immediately and latch
				-- uiState.Hovered permanently - which used to make
				-- onBusStopClick's "don't place through the HUD" guard
				-- swallow every viewport click while any pie menu was
				-- showing (i.e. whenever a road was selected). Each
				-- PillButton reports its own (correctly small) hover area
				-- via SetGlobalHover instead.
				assert(pieMenuRoot):render(React.createElement("Frame", {
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
				}, {
					Gui = pieMenuElement,
				}))
			end
		else
			if pieMenuRoot then
				assert(pieMenuRoot):unmount()
				pieMenuRoot = nil
			end
			if pieMenuScreenGui then
				pieMenuScreenGui:Destroy()
				pieMenuScreenGui = nil
			end
		end

		-- Docked settings sidebars: separate docks, named by function --------
		local function onSettingsChanged()
			-- Region (or other grand settings) may have changed: rebuild the
			-- built-in road set to match and persist everything.
			library.SetStyle(getStyle())
			persist()
			updateUI()
		end

		if regionalDock.Enabled then
			if not regionalRoot then
				regionalRoot = ReactRoblox.createRoot(regionalDock)
			end
			assert(regionalRoot):render(React.createElement(RegionalPreferenceGui, {
				Settings = settings,
				RegionLibrary = regionLibrary,
				OnSettingsChanged = onSettingsChanged,
				OnClose = function()
					regionalDock.Enabled = false
				end,
			}))
		elseif regionalRoot then
			regionalRoot:unmount()
			regionalRoot = nil
		end

		if keybindsDock.Enabled then
			if not keybindsRoot then
				keybindsRoot = ReactRoblox.createRoot(keybindsDock)
			end
			assert(keybindsRoot):render(React.createElement(KeybindsGui, {
				Settings = settings,
				OnSettingsChanged = function()
					persist()
					updateUI()
				end,
				OnCapture = function(_actionId: string, onCaptured: (label: string) -> ())
					captureNextKeybind(onCaptured)
				end,
				OnClose = function()
					keybindsDock.Enabled = false
				end,
			}))
		elseif keybindsRoot then
			keybindsRoot:unmount()
			keybindsRoot = nil
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

	regionalDock:GetPropertyChangedSignal("Enabled"):Connect(function()
		updateUI()
	end)
	keybindsDock:GetPropertyChangedSignal("Enabled"):Connect(function()
		updateUI()
	end)

	-- Initial UI show in the case where a dock starts enabled
	updateUI()

	-- When the user switches to another Studio tool, stop placing (the top
	-- bar and other surfaces stay).
	plugin.Deactivation:Connect(function()
		stopSession()
	end)

	plugin.Unloading:Connect(function()
		destroySession()
		if regionalRoot then
			regionalRoot:unmount()
			regionalRoot = nil
		end
		if keybindsRoot then
			keybindsRoot:unmount()
			keybindsRoot = nil
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
		if pieMenuRoot then
			pieMenuRoot:unmount()
			pieMenuRoot = nil
		end
		if pieMenuScreenGui then
			pieMenuScreenGui:Destroy()
			pieMenuScreenGui = nil
		end
		editSession.Destroy()
		editSessionChangedCn:Disconnect()
		persist()
		clickedCn:Disconnect()
	end)
end
