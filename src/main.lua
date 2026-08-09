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
--   Road Assets  - import/manage reusable Roblox structure Models
--   Settings     - grand settings, as separate docks named by function
--                  (Regional Preference, Keybinds) rather than tabs in
--                  one panel - toggled together by the Settings button
--
-- Selecting an already-placed road (outside of a build session) opens the
-- same designer bottom bar bound to that road, with Apply/Revert.

local CoreGui = game:GetService("CoreGui")
local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")

local Packages = script.Parent.Parent.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)
local Signal = require(Packages.Signal)

local History = require("./History")
local Settings = require("./Settings")
local RegionStyles = require("./RegionStyles")
local RoadProfile = require("./RoadProfile")
local StructureAssets = require("./StructureAssets")
local createRoadLibrary = require("./RoadLibrary")
local createRegionLibrary = require("./RegionLibrary")
local createRoadSession = require("./createRoadSession")
local createRoadEditSession = require("./RoadEditSession")
local createJunctionEditSession = require("./JunctionEditSession")
local createRoundaboutEditSession = require("./RoundaboutEditSession")
local JunctionInstance = require("./JunctionInstance")
local RoundaboutInstance = require("./RoundaboutInstance")
local JunctionBuilder = require("./Mesh/JunctionBuilder")
local RoundaboutBuilder = require("./Mesh/RoundaboutBuilder")
local RoadDesigner = require("./UI/RoadDesigner")
local RoadAssetsPanel = require("./UI/RoadAssetsPanel")
local RoadInspector = require("./UI/RoadInspector")
local BuildBar = require("./UI/BuildBar")
local RoadLibraryPanel = require("./UI/RoadLibraryPanel")
local TopBar = require("./UI/TopBar")
local TopBarBridge = require("./EasyAPI/TopBarBridge")
local RegionalPreferenceGui = require("./UI/RegionalPreferenceGui")
local KeybindsGui = require("./UI/KeybindsGui")
local SoftwareGui = require("./UI/SoftwareGui")
local EulaOverlay = require("./UI/EulaOverlay")
local ProductLicense = require("./ProductLicense")
local Components = require("./UI/Components")
local PieMenu = require("./UI/PieMenu")
local BayDraftPanel = require("./UI/BayDraftPanel")
local MarkingStretchPanel = require("./UI/MarkingStretchPanel")
local MarkingStretchListPanel = require("./UI/MarkingStretchListPanel")
local MarkingSelectionModePod = require("./UI/MarkingSelectionModePod")
local KerbStretchPanel = require("./UI/KerbStretchPanel")
local JunctionPanel = require("./UI/JunctionPanel")
local RoundaboutPanel = require("./UI/RoundaboutPanel")

-- RoadDesigner reserves 190 px for the lane strip. At 360 px total the two
-- upper cards received only 162 px, less than the library's own 170 px list
-- before its tabs/padding, so both columns visibly overflowed into the strip.
local ROAD_DESIGNER_HEIGHT = 440

return function(
	plugin: Plugin,
	regionalDock: DockWidgetPluginGui,
	keybindsDock: DockWidgetPluginGui,
	softwareDock: DockWidgetPluginGui,
	buttonClicked: Signal.Signal<>,
	setButtonActive: (active: boolean) -> ()
)
	local settings = Settings.Load(plugin)
	local regionLibrary = createRegionLibrary(settings.UserRegions)
	local library = createRoadLibrary(regionLibrary.Get(settings.RegionId), settings.UserProfiles)

	-- Whether the plugin UI (top bar) is shown at all; toggled by the
	-- toolbar button.
	local pluginOpen = false
	local eulaReviewOpen = false
	local eulaRoot: ReactRoblox.RootType? = nil
	local eulaScreenGui: ScreenGui? = nil

	local function eulaIsAccepted(): boolean
		if not ProductLicense.RequiresEula() then
			return true
		end
		return plugin:GetSetting(ProductLicense.SettingAccepted) == true
			and plugin:GetSetting(ProductLicense.SettingVersion) == ProductLicense.EulaVersion
	end

	local function acceptEula()
		plugin:SetSetting(ProductLicense.SettingAccepted, true)
		plugin:SetSetting(ProductLicense.SettingVersion, ProductLicense.EulaVersion)
		eulaReviewOpen = false
	end

	local function rejectEula()
		plugin:SetSetting(ProductLicense.SettingAccepted, false)
		plugin:SetSetting(ProductLicense.SettingVersion, "")
		eulaReviewOpen = false
	end

	local function destroyEulaScreen()
		if eulaRoot then
			eulaRoot:unmount()
			eulaRoot = nil
		end
		if eulaScreenGui then
			eulaScreenGui:Destroy()
			eulaScreenGui = nil
		end
	end

	-- closePluginFromEula is defined after destroySession / UI roots so those
	-- locals are in scope (early def called nil destroySession on Disagree).

	local session: createRoadSession.RoadSession? = nil
	local sessionChangedCn: Signal.Connection? = nil

	-- Library road being edited in the Road Editor (a working copy; only
	-- written to the library when the user saves)
	local designProfile: RoadProfile.RoadProfile? = nil
	local assetManagerOpen = false
	local assetManagerSelectedId: string? = nil
	local assetManagerStatus: string? = nil
	local junctionRoundaboutStatus: string? = nil

	-- Shared with the session so HUD clicks don't also place road points
	local uiState: createRoadSession.UiState = { Hovered = false }
	-- The Road Tools bottom HUD is two separate small panels (see the
	-- "session" branch below), not one panel filling its whole shared
	-- wrapper - hover is tracked per-panel and OR'd together so that the
	-- large transparent dead space around them (e.g. above the shorter
	-- Road Library box) doesn't count as "hovering the HUD" and swallow
	-- viewport clicks meant for road placement.
	local toolModeHovered = false
	local roadLibraryHovered = false
	-- Tracks which pie-menu slot layout was last rendered (Menu/SegmentMenu/
	-- PlacingBay/ConfirmingBay) - see the pie-menu hover-reset comment below.
	local lastPieMenuMode: string? = nil

	local regionalRoot: ReactRoblox.RootType? = nil
	local keybindsRoot: ReactRoblox.RootType? = nil
	local softwareRoot: ReactRoblox.RootType? = nil
	local topRoot: ReactRoblox.RootType? = nil
	local topScreenGui: ScreenGui? = nil
	local bottomRoot: ReactRoblox.RootType? = nil
	local bottomScreenGui: ScreenGui? = nil
	local pieMenuRoot: ReactRoblox.RootType? = nil
	local pieMenuScreenGui: ScreenGui? = nil

	-- EasyAPI: stack this top bar under any longer-open easy* siblings.
	local topBarBridge: TopBarBridge.Handle? = nil
	local topBarOffset = TopBarBridge.BASE_Y
	local topBarBridgeDisconnect: (() -> ())? = nil

	local updateUI: () -> () = nil :: any

	local function releaseTopBarBridge()
		if topBarBridgeDisconnect then
			topBarBridgeDisconnect()
			topBarBridgeDisconnect = nil
		end
		if topBarBridge then
			topBarBridge:Unregister()
			topBarBridge = nil
		end
		topBarOffset = TopBarBridge.BASE_Y
	end

	local function ensureTopBarBridge()
		if topBarBridge then
			return
		end
		local handle = TopBarBridge.register({
			Id = "easyRoad",
			DisplayName = "easyRoad",
			Height = TopBarBridge.DEFAULT_HEIGHT,
		})
		topBarBridge = handle
		topBarOffset = handle:GetOffset()
		topBarBridgeDisconnect = handle:OnChanged(function(offset: number)
			if topBarOffset == offset then
				return
			end
			topBarOffset = offset
			task.defer(updateUI)
		end)
	end

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

	-- Same always-listening convention as editSession above, for
	-- JunctionNodes (see JunctionEditSession.lua) - a road and a junction
	-- are never selected by the same click, so the two sessions never need
	-- to coordinate with each other.
	local junctionEditSession = createJunctionEditSession(getStyle, settings)
	local junctionEditSessionChangedCn = junctionEditSession.ChangeSignal:Connect(function()
		junctionRoundaboutStatus = nil
		updateUI()
	end)

	-- Generated roundabouts are selectable owner Models in their own right.
	-- Their hidden Junction controller keeps exact road-end topology, while this
	-- session owns the visible ring's editor lifecycle and undo transactions.
	local roundaboutEditSession = createRoundaboutEditSession(getStyle, settings)
	local roundaboutEditSessionChangedCn = roundaboutEditSession.ChangeSignal:Connect(function()
		updateUI()
	end)

	-- Deleting a road (Studio's own Delete key, or anything else that
	-- removes it from the Roads folder) doesn't go through RoadEditSession
	-- or createRoadSession at all, so a junction it was connected to would
	-- otherwise keep a stale pad forever - fires just before the removal
	-- actually happens, while the road's attributes are still readable, and
	-- for either end it referenced: rebuilds that junction's pad against
	-- whatever's left connected, or removes the junction outright if this
	-- was its last road.
	local roadRemovingCn = workspace.DescendantRemoving:Connect(function(instance)
		-- A direct Explorer delete of a connected ring becomes an ordinary
		-- junction. In-place editor rebuilds destroy a temporary ring too, but in
		-- that case the stable selected owner still exists for the same controller
		-- and this branch deliberately does nothing.
		if instance:GetAttribute("RW_Roundabout") == true then
			local junctionId = instance:GetAttribute("RW_JunctionId")
			if typeof(junctionId) == "string" then
				local otherRing = false
				local folder = workspace:FindFirstChild("Roundabouts")
				if folder then
					for _, candidate in folder:GetChildren() do
						if
							candidate ~= instance
							and candidate:GetAttribute("RW_Roundabout") == true
							and candidate:GetAttribute("RW_JunctionId") == junctionId
						then
							otherRing = true
							break
						end
					end
				end
				local controller = JunctionInstance.FindById(junctionId)
				local controllerData = if controller then JunctionInstance.Read(controller) else nil
				local connectedRoads = JunctionInstance.ConnectedRoads(junctionId)
				-- A replacement build has another owner already. Conversion sets the
				-- kind first. Last-road cleanup has no connected roads. Only a direct
				-- Explorer delete reaches the conversion below.
				if
					not otherRing
					and controller
					and controllerData
					and controllerData.Kind == "Roundabout"
					and #connectedRoads == 1
				then
					local restored, message =
						RoundaboutBuilder.PrepareForRingRemoval(instance :: Model, getStyle(), settings)
					if not restored then
						-- DescendantRemoving cannot cancel the user's delete. If source
						-- restoration is impossible, prefer a visibly shortened standalone
						-- road over a hidden Roundabout controller with no selectable ring.
						local road = connectedRoads[1]
						local roadData = RoadInstance.Read(road)
						if roadData then
							RoadInstance.StampJunctions(
								road,
								if roadData.StartJunctionId == junctionId then nil else roadData.StartJunctionId,
								if roadData.EndJunctionId == junctionId then nil else roadData.EndJunctionId
							)
						end
						controller:Destroy()
						warn(
							"[EasyRoad] One-approach ring removal could not restore the road source: "
								.. tostring(message)
								.. " The road was safely detached at its current length; use Undo to recover the deleted ring."
						)
					end
				elseif
					not otherRing
					and controller
					and controllerData
					and controllerData.Kind == "Roundabout"
					and #connectedRoads > 1
				then
					JunctionInstance.SetKind(controller, "Intersection")
					JunctionBuilder.TrimApproaches(junctionId, getStyle(), settings)
					JunctionBuilder.Rebuild(junctionId, getStyle(), settings)
				end
			end
			task.defer(updateUI)
			return
		end

		if instance:GetAttribute("RW_Road") ~= true then
			return
		end
		local startId = instance:GetAttribute("RW_StartJunctionId")
		local endId = instance:GetAttribute("RW_EndJunctionId")
		-- DescendantRemoving fires while this Model is still queryable. Detach
		-- its topology first, then rebuild synchronously inside Studio's Delete
		-- history operation so Undo restores the road, controller and ring as one
		-- coherent state rather than restoring only the road a frame later.
		if typeof(startId) == "string" then
			instance:SetAttribute("RW_StartJunctionId", nil)
		end
		if typeof(endId) == "string" then
			instance:SetAttribute("RW_EndJunctionId", nil)
		end
		local seen: { [string]: boolean } = {}
		for _, value in { startId, endId } do
			if typeof(value) ~= "string" or seen[value] then
				continue
			end
			seen[value] = true
			local junctionId = value
			local junctionModel = JunctionInstance.FindById(junctionId)
			local junctionData = if junctionModel then JunctionInstance.Read(junctionModel) else nil
			if not junctionModel or not junctionData then
				continue
			end
			local remaining = #JunctionInstance.ConnectedRoads(junctionId)
			if remaining == 0 then
				local ring = RoundaboutInstance.FindByJunctionId(junctionId)
				if ring then
					ring:Destroy()
				end
				JunctionInstance.Delete(junctionModel)
			elseif junctionData.Kind == "Roundabout" then
				local ring = RoundaboutInstance.FindByJunctionId(junctionId)
				if ring then
					local ok, rebuilt, message = pcall(function()
						return RoundaboutBuilder.Rebuild(ring, getStyle(), settings)
					end)
					if not ok or not rebuilt then
						warn(
							"[EasyRoad] Roundabout rebuild after road deletion failed: "
								.. tostring(if ok then message else rebuilt)
						)
					end
				end
			else
				JunctionBuilder.Rebuild(junctionId, getStyle(), settings)
			end
		end
		task.defer(updateUI)
	end)

	local function persist()
		settings.UserProfiles = library.SerializeUserProfiles()
		settings.UserRegions = regionLibrary.SerializeUserRegions()
		Settings.Save(plugin, settings)
	end

	-- R/F/Escape/middle-click work out of the box with zero setup via each
	-- session's own live UserInputService listener, matched against
	-- Keybinds.Defaults (see createRoadSession.lua/RoadEditSession.lua) -
	-- that part was never broken. What WAS broken (three rounds running)
	-- was letting the user REBIND them: a custom "click + Add binding, then
	-- press a key" capture UI built inside the docked Keybinds panel can't
	-- work reliably, because UserInputService is scoped to the main 3D
	-- viewport - a DockWidgetPluginGui is a genuinely separate native
	-- window, and once it has focus, further keyboard input (and some
	-- mouse input) doesn't reliably reach UserInputService at all. This is
	-- a documented Roblox Studio platform limitation, not something fixable
	-- from within a docked panel's own script.
	--
	-- The actual supported mechanism for a rebindable plugin shortcut is
	-- PluginAction: Studio's own native "Customize Shortcuts" dialog
	-- (File > Advanced > Customize Shortcuts, or right-click any toolbar)
	-- assigns the key, and Triggered fires reliably regardless of what has
	-- focus, since it's Studio's own shortcut system, not built on
	-- UserInputService inside a plugin GUI. Registered once here as an
	-- ADDITIONAL way to trigger these three actions - the hardcoded R/F/
	-- Escape defaults keep working unconditionally alongside whatever the
	-- user assigns via Customize Shortcuts, so nothing regresses for anyone
	-- who never touches shortcut customization at all.
	local elevationUpAction = plugin:CreatePluginAction(
		"EasyRoadElevationUp",
		"easyRoad: Raise Elevation",
		"Raises the road being placed",
		"",
		true
	)
	local elevationDownAction = plugin:CreatePluginAction(
		"EasyRoadElevationDown",
		"easyRoad: Lower Elevation",
		"Lowers the road being placed",
		"",
		true
	)
	local cancelPlacementAction = plugin:CreatePluginAction(
		"EasyRoadCancelPlacement",
		"easyRoad: Cancel Placement",
		"Cancels the road or bus bay currently being placed",
		"",
		true
	)
	elevationUpAction.Triggered:Connect(function()
		if session then
			session.AdjustElevation(settings.ElevationStepStuds)
		end
	end)
	elevationDownAction.Triggered:Connect(function()
		if session then
			session.AdjustElevation(-settings.ElevationStepStuds)
		end
	end)
	cancelPlacementAction.Triggered:Connect(function()
		if session then
			session.CancelPlacement()
		elseif editSession.IsPlacingBay() or editSession.IsConfirmingBay() then
			editSession.CancelBayPlacement()
		elseif editSession.IsPlacingMarkingStretch() or editSession.IsConfirmingMarkingStretch() then
			editSession.CancelMarkingStretchPlacement()
		elseif editSession.IsPlacingKerbStretch() or editSession.IsConfirmingKerbStretch() then
			editSession.CancelKerbStretchPlacement()
		end
	end)

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
		toolModeHovered = false
		roadLibraryHovered = false
	end

	-- Disagree / close while EULA is up: clear accept, tear down session + UI.
	-- Must live after destroySession / topRoot / etc. so locals resolve (Luau).
	local function closePluginFromEula()
		rejectEula()
		pluginOpen = false
		destroySession()
		designProfile = nil
		assetManagerOpen = false
		plugin:Deactivate()
		setButtonActive(false)
		destroyEulaScreen()
		if topRoot then
			topRoot:unmount()
			topRoot = nil
		end
		if topScreenGui then
			topScreenGui:Destroy()
			topScreenGui = nil
		end
		releaseTopBarBridge()
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
		regionalDock.Enabled = false
		keybindsDock.Enabled = false
		softwareDock.Enabled = false
	end

	local function restoredLibraries(restored: Settings.EasyRoadSettings)
		local restoredRegions = createRegionLibrary(restored.UserRegions)
		local regionExists = false
		for _, style in restoredRegions.GetAll() do
			if style.Id == restored.RegionId then
				regionExists = true
				break
			end
		end
		if not regionExists then
			restored.RegionId = "UK"
		end

		local restoredRoads = createRoadLibrary(restoredRegions.Get(restored.RegionId), restored.UserProfiles)
		if not restoredRoads.Get(restored.DefaultProfileId) then
			restored.DefaultProfileId = restoredRoads.GetDefault().Id
		end
		-- Re-serialize once so malformed individual custom entries are dropped
		-- by their normal deserializers before anything is persisted.
		restored.UserRegions = restoredRegions.SerializeUserRegions()
		restored.UserProfiles = restoredRoads.SerializeUserProfiles()
		return restoredRegions, restoredRoads
	end

	local function validateRestoreData(json: string): (boolean, string)
		local restored, errorMessage = Settings.Import(json, HttpService)
		if not restored then
			return false, errorMessage
		end
		local _, restoredRoads = restoredLibraries(restored)
		local restoredProfiles = restoredRoads.SerializeUserProfiles()
		return true,
			string.format(
				"Valid backup: %d custom road%s and %d custom region%s. Click Restore now to replace current plugin data.",
				#restoredProfiles,
				if #restoredProfiles == 1 then "" else "s",
				#restored.UserRegions,
				if #restored.UserRegions == 1 then "" else "s"
			)
	end

	local function restoreData(json: string): (boolean, string)
		local restored, errorMessage = Settings.Import(json, HttpService)
		if not restored then
			return false, errorMessage
		end

		local restoredRegions, restoredRoads = restoredLibraries(restored)
		destroySession()
		designProfile = nil
		Settings.Replace(settings, restored)
		regionLibrary = restoredRegions
		library = restoredRoads
		persist()
		updateUI()
		return true, "Data restored. Settings and custom presets are active now."
	end

	-- profileOverride/seed power the pie menu's "Place More" action: continue
	-- building from an exact existing road's end, with its exact profile,
	-- rather than starting fresh with the default road.
	local function startSession(seed: createRoadSession.SessionSeed?, profileOverride: RoadProfile.RoadProfile?)
		if session then
			return
		end
		-- A bay/marking-stretch drag on a selected road activates its own
		-- plugin tool and holds mouse connections + ghost Parts in
		-- editSession's own state, independent of `session`/`designProfile`
		-- here - switching to a placement session without cancelling first
		-- left that tool active and its ghosts stranded in the workspace
		-- (never reached by anything that only resets `session`/
		-- `designProfile`, since editSession's own mode never got told to
		-- stop). Both are no-ops if no such drag is in progress.
		editSession.CancelBayPlacement()
		editSession.CancelMarkingStretchPlacement()
		editSession.CancelKerbStretchPlacement()
		designProfile = nil -- Tools and Editor are exclusive modes
		assetManagerOpen = false
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
		-- Same reasoning as startSession above: plugin:Deactivate() below
		-- only stops whatever tool is active, it doesn't reset editSession's
		-- own bay/stretch placement state (mode, mouse connections, ghost
		-- Parts) - without this, switching to the standalone road-type
		-- editor mid-drag left a stray ghost Part sitting in the workspace
		-- indefinitely (reported: a "EasyRoadMarkingStretchGhost" visible in
		-- the Explorer with nothing left placing it).
		editSession.CancelBayPlacement()
		editSession.CancelMarkingStretchPlacement()
		editSession.CancelKerbStretchPlacement()
		plugin:Deactivate()
		pluginOpen = true
		setButtonActive(true)
		assetManagerOpen = false
		local source = sourceProfile or library.Get(settings.DefaultProfileId) or library.GetDefault()
		designProfile = RoadProfile.Clone(source)
		updateUI()
	end

	local function closeEditor()
		designProfile = nil
		updateUI()
	end

	local function openAssetManager()
		destroySession()
		editSession.CancelBayPlacement()
		editSession.CancelMarkingStretchPlacement()
		editSession.CancelKerbStretchPlacement()
		plugin:Deactivate()
		designProfile = nil
		assetManagerOpen = true
		assetManagerStatus = nil
		pluginOpen = true
		setButtonActive(true)
		local assets = StructureAssets.List(nil)
		if not assetManagerSelectedId and #assets > 0 then
			assetManagerSelectedId = assets[1].Id
		end
		updateUI()
	end

	local function closeAssetManager()
		assetManagerOpen = false
		updateUI()
	end

	local function importRoadAsset(kind: StructureAssets.AssetKind)
		local source = StructureAssets.FindImportCandidate(Selection:Get(), nil)
		if not source then
			assetManagerStatus = "Select a Workspace Model containing at least one BasePart first."
			updateUI()
			return
		end
		local imported: StructureAssets.AssetInfo? = nil
		local message: string? = nil
		local _, historyFailure = History.Record("EasyRoadAssetImport", "Import road asset", function()
			imported, message = StructureAssets.Import(source, kind)
			return imported ~= nil
		end)
		if historyFailure then
			assetManagerStatus = historyFailure
			updateUI()
			return
		end
		if imported then
			assetManagerSelectedId = imported.Id
			assetManagerStatus = string.format("Imported %s as %s. %s", imported.Name, kind, message)
		else
			assetManagerStatus = message
		end
		updateUI()
	end

	local function renameRoadAsset(assetId: string, name: string)
		local ok = false
		local message: string? = nil
		local _, historyFailure = History.Record("EasyRoadAssetRename", "Rename road asset", function()
			ok, message = StructureAssets.Rename(assetId, name)
			return ok
		end)
		if historyFailure then
			message = historyFailure
		end
		assetManagerStatus = message
		updateUI()
	end

	local function exportRoadAsset(assetId: string)
		local exported: Model? = nil
		local message: string? = nil
		local _, historyFailure = History.Record("EasyRoadAssetExport", "Export road asset", function()
			exported, message = StructureAssets.ExportToWorkspace(assetId)
			return exported ~= nil
		end)
		if historyFailure then
			assetManagerStatus = historyFailure
		elseif exported then
			local selected, selectionFailure = pcall(function()
				Selection:Set({ exported :: Model })
			end)
			assetManagerStatus = if selected
				then message
				else string.format(
					"%s Studio could not select the exported Model: %s",
					message or "The road asset was exported.",
					tostring(selectionFailure)
				)
		else
			assetManagerStatus = message
		end
		updateUI()
	end

	local function deleteRoadAsset(assetId: string)
		local ok = false
		local message: string? = nil
		local _, historyFailure = History.Record("EasyRoadAssetDelete", "Delete road asset", function()
			ok, message = StructureAssets.Delete(assetId)
			return ok
		end)
		if historyFailure then
			message = historyFailure
		end
		if ok then
			assetManagerSelectedId = nil
		end
		assetManagerStatus = message
		updateUI()
	end

	local function newUserProfileId(): string
		return "user_" .. HttpService:GenerateGUID(false)
	end

	local function nextRoadCopyName(sourceName: string): string
		local used: { [string]: boolean } = {}
		for _, profile in library.GetAll() do
			used[profile.Name] = true
		end
		local base = sourceName .. " Copy"
		if not used[base] then
			return base
		end
		local suffix = 2
		while used[string.format("%s %d", base, suffix)] do
			suffix += 1
		end
		return string.format("%s %d", base, suffix)
	end

	local function duplicateRoadProfile(source: RoadProfile.RoadProfile): RoadProfile.RoadProfile
		local duplicate = RoadProfile.Clone(source)
		duplicate.Id = newUserProfileId()
		duplicate.Name = nextRoadCopyName(source.Name)
		duplicate.BuiltIn = false
		library.SaveUserProfile(duplicate)
		designProfile = duplicate
		persist()
		updateUI()
		return duplicate
	end

	local function newRoadTemplate(): RoadProfile.RoadProfile
		return {
			Id = newUserProfileId(),
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
		local commercial = ProductLicense.RequiresEula()
		local accepted = eulaIsAccepted()
		local gateEula = pluginOpen and commercial and not accepted
		local reviewEula = pluginOpen and commercial and eulaReviewOpen

		if gateEula or reviewEula then
			if not eulaRoot then
				local screen = Instance.new("ScreenGui")
				screen.Name = "EasyRoadEula"
				screen.ResetOnSpawn = false
				screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
				screen.DisplayOrder = 100
				screen.Parent = CoreGui
				eulaScreenGui = screen
				eulaRoot = ReactRoblox.createRoot(screen)
			end
			assert(eulaRoot):render(React.createElement(EulaOverlay, {
				OnAgree = function()
					acceptEula()
					updateUI()
				end,
				OnDisagree = function()
					closePluginFromEula()
					updateUI()
				end,
			}))
		else
			destroyEulaScreen()
		end

		if gateEula then
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
			regionalDock.Enabled = false
			keybindsDock.Enabled = false
			softwareDock.Enabled = false
			return
		end

		-- Top mode bar --------------------------------------------------------
		if pluginOpen then
			ensureTopBarBridge()
			if not topRoot then
				local screen = Instance.new("ScreenGui")
				screen.Name = "EasyRoadTopBar"
				screen.ResetOnSpawn = false
				screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
				screen.DisplayOrder = 10
				-- IgnoreGuiInset deliberately left OFF (default false) - see
				-- the EasyRoadHUD gui below for the full story; both HUD guis
				-- follow the same convention.
				screen.Parent = CoreGui
				topScreenGui = screen
				topRoot = ReactRoblox.createRoot(screen)
			end
			assert(topRoot):render(React.createElement(TopBar, {
				ToolsActive = session ~= nil,
				EditorActive = designProfile ~= nil,
				AssetsActive = assetManagerOpen,
				RegionalOpen = regionalDock.Enabled,
				KeybindsOpen = keybindsDock.Enabled,
				SoftwareOpen = softwareDock.Enabled,
				TopOffset = topBarOffset,
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
				OnAssets = function()
					if assetManagerOpen then
						closeAssetManager()
					else
						openAssetManager()
					end
				end,
				OnOpenSoftware = function()
					softwareDock.Enabled = not softwareDock.Enabled
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
			releaseTopBarBridge()
		end

		-- Bottom HUD ----------------------------------------------------------
		-- One surface at a time: the Road Editor designer, the Road Tools
		-- panel, or the placed-road designer for the current selection.
		local bottomContent: any = nil
		local bottomFrameProps: { [string]: any } = nil :: any
		-- Set true by the "session" branch, whose bottomContent is two
		-- separately-hover-tracked panels instead of one Frame filling the
		-- whole wrapper - see toolModeHovered/roadLibraryHovered above.
		local skipGenericHover = false
		if designProfile then
			local editing = designProfile :: RoadProfile.RoadProfile
			local actions: { RoadDesigner.DesignerAction } = {
				{
					Text = if editing.BuiltIn then "Duplicate road" else "Save",
					Selected = true,
					OnClick = function()
						if editing.BuiltIn then
							duplicateRoadProfile(editing)
							return
						end
						local toSave = RoadProfile.Clone(editing)
						toSave.BuiltIn = false
						library.SaveUserProfile(toSave)
						designProfile = toSave
						persist()
						updateUI()
					end,
				},
			}
			if not editing.BuiltIn then
				table.insert(actions, {
					Text = "Duplicate road",
					OnClick = function()
						duplicateRoadProfile(editing)
					end,
				})
			end
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
					then "Built-in template — duplicate it to create an editable road."
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
				Position = UDim2.new(0, 12, 1, -16),
				Size = UDim2.new(1, -24, 0, ROAD_DESIGNER_HEIGHT),
			}
		elseif assetManagerOpen then
			local assets = StructureAssets.List(nil)
			local selectedId = assetManagerSelectedId
			local selectedExists = false
			for _, asset in assets do
				if asset.Id == selectedId then
					selectedExists = true
					break
				end
			end
			if not selectedExists then
				selectedId = if #assets > 0 then assets[1].Id else nil
				assetManagerSelectedId = selectedId
			end
			bottomContent = React.createElement(RoadAssetsPanel, {
				Assets = assets,
				SelectedId = selectedId,
				Status = assetManagerStatus,
				UsageCount = if selectedId then StructureAssets.UsageCount(selectedId) else 0,
				OnSelect = function(id: string?)
					assetManagerSelectedId = id
					assetManagerStatus = nil
					updateUI()
				end,
				OnImport = importRoadAsset,
				OnExport = exportRoadAsset,
				OnRename = renameRoadAsset,
				OnDelete = deleteRoadAsset,
				OnClose = closeAssetManager,
			})
			bottomFrameProps = {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 12, 1, -16),
				Size = UDim2.new(0, 560, 0, 300),
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
			local placementStructure = currentSession.GetStructure()
			local placementStructureKind: StructureAssets.AssetKind? = if placementStructure.Mode == "Viaduct"
				then "Viaduct"
				elseif placementStructure.Mode == "Tunnel" then "Tunnel"
				else nil
			-- Two separate floating boxes, CS2-style, not one box with
			-- everything stacked on top of itself: Tool Mode left-aligned
			-- (Studio has much less usable width than a dedicated game
			-- window, so bottom-center doesn't work here) and Road Library
			-- bottom-right, each independently anchored to the screen with
			-- their own padding rather than positioned relative to a
			-- shared sub-box. Each is wrapped in its own positioning Frame
			-- (BuildBar/RoadLibraryPanel both fill whatever parent they're
			-- given via fromScale(1,1)). Hover is tracked per-panel (see
			-- toolModeHovered/roadLibraryHovered above), not on the
			-- now-full-screen outer wrapper, so the large gap between the
			-- two panels can't re-create the earlier hover-trap bug.
			skipGenericHover = true
			bottomContent = React.createElement(React.Fragment, nil, {
				ToolMode = React.createElement("Frame", {
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 16, 1, -40),
					Size = UDim2.new(0, 260, 0, 430),
					BackgroundTransparency = 1,
					[React.Event.MouseEnter] = function()
						toolModeHovered = true
						uiState.Hovered = true
					end,
					[React.Event.MouseLeave] = function()
						toolModeHovered = false
						uiState.Hovered = roadLibraryHovered
					end,
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
						Structure = placementStructure,
						StructureAssets = currentSession.GetStructureAssets(placementStructureKind),
						StructureStatus = currentSession.GetStructureStatus(),
						SetStructure = currentSession.SetStructure,
						Parallel = currentSession.GetParallel(),
						SetParallel = currentSession.SetParallel,
						RoundaboutRadius = currentSession.GetRoundaboutRadius(),
						SetRoundaboutRadius = function(value: number)
							currentSession.SetRoundaboutRadius(value)
						end,
						RoundaboutLaneCount = currentSession.GetRoundaboutLaneCount(),
						SetRoundaboutLaneCount = function(value: number)
							currentSession.SetRoundaboutLaneCount(value)
						end,
						RoundaboutLaneWidth = currentSession.GetRoundaboutLaneWidth(),
						SetRoundaboutLaneWidth = function(value: number)
							currentSession.SetRoundaboutLaneWidth(value)
						end,
						OnStop = function()
							stopSession()
							plugin:Deactivate()
						end,
					}),
				}),
				RoadLibrary = React.createElement("Frame", {
					AnchorPoint = Vector2.new(1, 1),
					Position = UDim2.new(1, -16, 1, -40),
					Size = UDim2.new(0, 340, 0, 260),
					BackgroundTransparency = 1,
					[React.Event.MouseEnter] = function()
						roadLibraryHovered = true
						uiState.Hovered = true
					end,
					[React.Event.MouseLeave] = function()
						roadLibraryHovered = false
						uiState.Hovered = toolModeHovered
					end,
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
			-- Full-screen wrapper: each inner panel positions itself
			-- relative to the actual screen edges (see above), not a
			-- shared sub-box. Safe against the hover-trap bug because this
			-- wrapper itself carries no hover handlers (skipGenericHover).
			bottomFrameProps = {
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.new(0, 0, 0, 0),
				Size = UDim2.new(1, 0, 1, 0),
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
					Position = UDim2.new(0, 12, 1, -40),
					Size = UDim2.new(0, 260, 0, 180),
				}
			end
		elseif editSession.GetSelectedRoad() and editSession.IsConfirmingMarkingStretch() then
			local draft = editSession.GetMarkingStretchDraft()
			if draft then
				bottomContent = React.createElement(MarkingStretchPanel, {
					FromStationStuds = draft.FromStationStuds,
					ToStationStuds = draft.ToStationStuds,
					Line = draft.Line,
					DashLengthM = draft.DashLengthM,
					DashGapM = draft.DashGapM,
					OnFromChanged = editSession.SetMarkingStretchDraftFrom,
					OnToChanged = editSession.SetMarkingStretchDraftTo,
					OnLineChanged = function(id: string)
						editSession.SetMarkingStretchDraftLine(id :: RegionStyles.LineType)
					end,
					OnDashLengthChanged = editSession.SetMarkingStretchDraftDashLength,
					OnDashGapChanged = editSession.SetMarkingStretchDraftDashGap,
				})
				bottomFrameProps = {
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 12, 1, -40),
					Size = UDim2.new(0, 280, 0, 300),
				}
			end
		elseif editSession.GetSelectedRoad() and editSession.IsPlacingMarkingStretch() then
			-- Full-screen wrapper so the pod can position itself
			-- bottom-center via its own AnchorPoint (same convention the
			-- placement session's ToolMode/RoadLibrary panels use) -
			-- skipGenericHover is required here for the same reason it is
			-- there: a full-screen wrapper's own MouseEnter would otherwise
			-- latch uiState.Hovered on any viewport hover at all, blocking
			-- every subsequent click. The pod reports its own small hover
			-- area directly instead.
			skipGenericHover = true
			bottomContent = React.createElement(MarkingSelectionModePod, {
				Mode = editSession.GetMarkingStretchSelectionMode(),
				OnModeChanged = function(newMode: string)
					editSession.SetMarkingStretchSelectionMode(newMode :: any)
				end,
				OnHoverChanged = function(hovered: boolean)
					uiState.Hovered = hovered
				end,
			})
			bottomFrameProps = {
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.new(0, 0, 0, 0),
				Size = UDim2.new(1, 0, 1, 0),
			}
		elseif editSession.GetSelectedRoad() and editSession.IsViewingStretches() then
			bottomContent = React.createElement(MarkingStretchListPanel, {
				Stretches = editSession.GetMarkingStretches(),
				OnRemove = editSession.RemoveMarkingStretch,
				KerbStretches = editSession.GetKerbStretches(),
				OnRemoveKerbStretch = editSession.RemoveKerbStretch,
			})
			bottomFrameProps = {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 12, 1, -40),
				Size = UDim2.new(0, 280, 0, 260),
			}
		elseif editSession.GetSelectedRoad() and editSession.IsConfirmingKerbStretch() then
			local draft = editSession.GetKerbStretchDraft()
			if draft then
				bottomContent = React.createElement(KerbStretchPanel, {
					FromStationStuds = draft.FromStationStuds,
					ToStationStuds = draft.ToStationStuds,
					Restriction = draft.Restriction,
					OnFromChanged = editSession.SetKerbStretchDraftFrom,
					OnToChanged = editSession.SetKerbStretchDraftTo,
					OnRestrictionChanged = editSession.SetKerbStretchDraftRestriction,
				})
				bottomFrameProps = {
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 12, 1, -40),
					Size = UDim2.new(0, 280, 0, 240),
				}
			end
		elseif
			editSession.GetSelectedRoad()
			and not editSession.IsShowingMenu()
			and not editSession.IsShowingSegmentMenu()
			and not editSession.IsPlacingBay()
			and not editSession.IsConfirmingBay()
			and not editSession.IsPlacingMarkingStretch()
			and not editSession.IsConfirmingMarkingStretch()
			and not editSession.IsViewingStretches()
			and not editSession.IsPlacingKerbStretch()
			and not editSession.IsConfirmingKerbStretch()
		then
			bottomContent = React.createElement(RoadInspector, {
				PluginObj = plugin,
				Session = editSession,
				RegionStyle = getStyle(),
				Settings = settings,
			})
			bottomFrameProps = {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 12, 1, -16),
				Size = UDim2.new(1, -24, 0, ROAD_DESIGNER_HEIGHT),
			}
		elseif roundaboutEditSession.GetSelectedRoundabout() then
			bottomContent = React.createElement(RoundaboutPanel, {
				ConnectedRoadCount = roundaboutEditSession.GetConnectedRoadCount(),
				LegacyConnected = roundaboutEditSession.IsLegacyConnected(),
				RadiusStuds = roundaboutEditSession.GetRadiusStuds(),
				LaneCount = roundaboutEditSession.GetLaneCount(),
				LaneWidthM = roundaboutEditSession.GetLaneWidthM(),
				Markings = roundaboutEditSession.GetMarkings(),
				Sidewalk = roundaboutEditSession.GetSidewalk(),
				Island = roundaboutEditSession.GetIsland(),
				MinimumRadiusStuds = roundaboutEditSession.GetMinimumRadiusStuds(),
				SuggestedRadiusStuds = roundaboutEditSession.GetSuggestedRadiusStuds(),
				Status = roundaboutEditSession.GetStatus(),
				OnRadiusChanged = roundaboutEditSession.SetRadiusStuds,
				OnLaneCountChanged = roundaboutEditSession.SetLaneCount,
				OnLaneWidthChanged = roundaboutEditSession.SetLaneWidthM,
				OnMarkingsChanged = roundaboutEditSession.SetMarkings,
				OnSidewalkChanged = roundaboutEditSession.SetSidewalk,
				OnIslandChanged = roundaboutEditSession.SetIsland,
				OnRebuild = roundaboutEditSession.RebuildSelected,
				OnPrintGeometry = roundaboutEditSession.PrintGeometry,
				OnConvertToJunction = roundaboutEditSession.ConvertToJunction,
				OnDelete = roundaboutEditSession.DeleteRoundabout,
			})
			bottomFrameProps = {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 12, 1, -40),
				Size = UDim2.new(0, 320, 0, 470),
			}
		elseif junctionEditSession.GetSelectedJunction() then
			local selectedJunction = junctionEditSession.GetSelectedJunction()
			local selectedJunctionData = if selectedJunction then JunctionInstance.Read(selectedJunction) else nil
			local selectedJunctionId = if selectedJunctionData then selectedJunctionData.Id else ""
			local suggestedRoundaboutLaneCount = 1
			if selectedJunctionData then
				local ok, value = pcall(RoundaboutBuilder.SuggestedLaneCount, selectedJunctionData.Id)
				if ok and typeof(value) == "number" then
					suggestedRoundaboutLaneCount = value
				else
					warn(
						"[EasyRoad] Roundabout lane suggestion failed; using one circulating lane: " .. tostring(value)
					)
				end
			end
			-- Both radius figures depend on the approaches meeting here AND on the
			-- ring's own lane settings, which live in the panel - so this is a
			-- callback it invokes with its current values rather than a number
			-- computed once with assumed ones.
			local function getRoundaboutRadii(laneCount: number, laneWidthM: number): (number, number)
				local junctionModel = junctionEditSession.GetSelectedJunction()
				if not junctionModel then
					return 0, 0
				end
				local junctionData = JunctionInstance.Read(junctionModel)
				if not junctionData then
					return 0, 0
				end
				local style = getStyle()
				-- Radius advice is secondary to the junction editor itself. A bad
				-- approach profile or a future calculator regression must not crash
				-- React and make the entire selected-junction panel disappear.
				local ok, radii = pcall(function(): { Minimum: number, Suggested: number }
					return {
						Minimum = RoundaboutBuilder.MinimumRadiusStuds(
							junctionData.Id,
							laneCount,
							laneWidthM,
							style,
							settings
						),
						Suggested = RoundaboutBuilder.SuggestedRadiusStuds(
							junctionData.Id,
							laneCount,
							laneWidthM,
							style,
							settings
						),
					}
				end)
				if not ok then
					warn(
						"[EasyRoad] Roundabout radius suggestion failed; junction editor remains available: "
							.. tostring(radii)
					)
					return 0, 0
				end
				local result = radii :: { Minimum: number, Suggested: number }
				return result.Minimum, result.Suggested
			end
			bottomContent = React.createElement(JunctionPanel, {
				JunctionId = selectedJunctionId,
				ConnectedRoadCount = junctionEditSession.GetConnectedRoadCount(),
				CornerCount = junctionEditSession.GetCornerCount(),
				FilletRadiusM = junctionEditSession.GetFilletRadiusM(),
				PadMarginStuds = junctionEditSession.GetPadMarginStuds(),
				ApproachSetbacks = junctionEditSession.GetApproachSetbacks(),
				LinkedCornerRadii = junctionEditSession.GetLinkedCornerRadii(),
				SelectedCornerLabel = junctionEditSession.GetSelectedCornerLabel(),
				SelectedCornerRadiusM = junctionEditSession.GetSelectedCornerRadiusM(),
				OnFilletRadiusChanged = junctionEditSession.SetFilletRadiusM,
				OnPadMarginChanged = junctionEditSession.SetPadMarginStuds,
				OnApproachSetbackChanged = function(approachId: string, value: number?)
					if value == nil then
						junctionEditSession.ResetApproachSetbackStuds(approachId)
					else
						junctionEditSession.SetApproachSetbackStuds(approachId, value)
					end
				end,
				OnLinkedCornerRadiiChanged = junctionEditSession.SetLinkedCornerRadii,
				OnSelectedCornerRadiusChanged = junctionEditSession.SetSelectedCornerRadiusM,
				OnRebuild = junctionEditSession.RebuildSelected,
				OnDelete = junctionEditSession.DeleteJunction,
				RoundaboutStatus = junctionRoundaboutStatus,
				SuggestedRoundaboutLaneCount = suggestedRoundaboutLaneCount,
				GetRoundaboutRadii = getRoundaboutRadii,
				OnDumpRoundabout = function(radiusStuds: number, laneCount: number, laneWidthM: number)
					local junctionModel = junctionEditSession.GetSelectedJunction()
					local junctionData = if junctionModel then JunctionInstance.Read(junctionModel) else nil
					if not junctionData then
						return
					end
					print(
						RoundaboutBuilder.DescribeJunction(
							junctionData.Id,
							radiusStuds,
							laneCount,
							laneWidthM,
							getStyle(),
							settings
						)
					)
				end,
				OnMakeRoundabout = function(
					radiusStuds: number,
					laneCount: number,
					laneWidthM: number,
					markings: string?,
					sidewalk: boolean?,
					island: boolean?
				)
					local junctionModel = junctionEditSession.GetSelectedJunction()
					if not junctionModel then
						return
					end
					local previousData = JunctionInstance.Read(junctionModel)
					if not previousData then
						junctionRoundaboutStatus = "The selected junction data could not be read."
						updateUI()
						return
					end
					local ring: Model? = nil
					local _, historyFailure = History.Record("EasyRoadEdit", "Make roundabout", function()
						-- Stamped BEFORE reading the junction back, because
						-- CreateAtJunction reads the override off the junction data.
						JunctionInstance.SetRoundaboutMarkings(junctionModel, markings)
						JunctionInstance.SetRoundaboutSidewalk(junctionModel, sidewalk)
						JunctionInstance.SetRoundaboutIsland(junctionModel, island)
						local junctionData = JunctionInstance.Read(junctionModel)
						if not junctionData then
							JunctionInstance.SetRoundaboutMarkings(junctionModel, previousData.RoundaboutMarkings)
							JunctionInstance.SetRoundaboutSidewalk(junctionModel, previousData.RoundaboutSidewalk)
							JunctionInstance.SetRoundaboutIsland(junctionModel, previousData.RoundaboutIsland)
							junctionRoundaboutStatus = "The selected junction data could not be read."
							return false
						end
						local success, built, buildMessage = pcall(function(): (Model?, string?)
							return RoundaboutBuilder.CreateAtJunction(
								junctionData.Id,
								radiusStuds,
								laneCount,
								laneWidthM,
								getStyle(),
								settings
							)
						end)
						ring = if success then built else nil
						if ring then
							junctionRoundaboutStatus = nil
							Selection:Set({ ring :: Model })
						else
							-- A failed build must not strand a hidden roundabout controller
							-- or partially trimmed approaches. Restore the ordinary junction
							-- from its preserved source curves and surface the real error.
							JunctionInstance.SetKind(junctionModel, "Intersection")
							if previousData then
								JunctionInstance.SetRoundaboutMarkings(junctionModel, previousData.RoundaboutMarkings)
								JunctionInstance.SetRoundaboutSidewalk(junctionModel, previousData.RoundaboutSidewalk)
								JunctionInstance.SetRoundaboutIsland(junctionModel, previousData.RoundaboutIsland)
							end
							JunctionBuilder.TrimApproaches(junctionData.Id, getStyle(), settings)
							JunctionBuilder.Rebuild(junctionData.Id, getStyle(), settings)
							junctionRoundaboutStatus = if success
								then (buildMessage or "Roundabout creation was rejected.")
								else ("Roundabout creation failed: " .. tostring(built))
							warn("[EasyRoad] " .. tostring(junctionRoundaboutStatus))
							updateUI()
						end
						return ring ~= nil
					end)
					if historyFailure then
						junctionRoundaboutStatus = historyFailure
						updateUI()
					end
				end,
			})
			bottomFrameProps = {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 12, 1, -40),
				Size = UDim2.new(0, 300, 0, 440),
			}
		end

		if bottomContent then
			if not bottomRoot then
				local screen = Instance.new("ScreenGui")
				screen.Name = "EasyRoadHUD"
				screen.ResetOnSpawn = false
				screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
				-- IgnoreGuiInset deliberately OFF (default false). With it ON,
				-- every bottom-anchored panel in this gui rendered well above
				-- the true viewport bottom in the user's Studio ("pushed
				-- upward" - reported live twice), consistent with the
				-- documented engine inconsistencies around IgnoreGuiInset and
				-- inset handling. The pie-menu ScreenGui below has never set
				-- the flag and is the one HUD surface that has always
				-- positioned correctly, so both HUD guis now follow its
				-- convention. An earlier attempt kept the flag and added
				-- GuiService:GetGuiInset() to the bottom margins instead -
				-- that didn't fix it (the reported inset isn't the quantity
				-- the broken codepath actually misplaces things by).
				screen.Parent = CoreGui
				bottomScreenGui = screen
				bottomRoot = ReactRoblox.createRoot(screen)
			end
			bottomFrameProps.BackgroundTransparency = 1
			if not skipGenericHover then
				bottomFrameProps[React.Event.MouseEnter] = function()
					uiState.Hovered = true
				end
				bottomFrameProps[React.Event.MouseLeave] = function()
					uiState.Hovered = false
				end
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
		-- second-level submenu (Add Bus Bay / Edit Lane Markings / Back) at
		-- the same anchor - a standalone marker-only "Add Bus Stop" used to
		-- live here too, removed since a real bus bay already serves as a
		-- stop (see SHIPPED.md). "Add Bus Bay" opens a click-drag-to-place
		-- mode for a point on the road, then a length/width panel (see the
		-- ConfirmingBay branch below) before committing the real
		-- carved-out geometry. Hidden entirely for Highway-category roads,
		-- which don't have bus bays in real life.
		-- Rendered in its own ScreenGui WITHOUT IgnoreGuiInset, matching
		-- WorldToViewportPoint's coordinate space (the bottom HUD's
		-- ScreenGui ignores the inset instead, for the drag-ghost math -
		-- the two need different conventions).
		local menuRoad = editSession.GetSelectedRoad()
		local showPieMenu = menuRoad ~= nil
			and not session
			and not designProfile
			and not assetManagerOpen
			and (
				editSession.IsShowingMenu()
				or editSession.IsShowingSegmentMenu()
				or editSession.IsPlacingBay()
				or editSession.IsConfirmingBay()
				or editSession.IsPlacingMarkingStretch()
				or editSession.IsConfirmingMarkingStretch()
				or editSession.IsViewingStretches()
				or editSession.IsPlacingKerbStretch()
				or editSession.IsConfirmingKerbStretch()
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

				-- Each pie-menu mode swaps in a completely different set of
				-- PillButtons at the same anchor - if the mouse is sitting on
				-- one when its OnClick fires (e.g. "Add Bus Bay"), that pill
				-- unmounts immediately as this mode switches, and React
				-- destroying it never fires its own MouseLeave. Without this
				-- reset, uiState.Hovered stayed stuck true from that pill's
				-- MouseEnter forever after, silently blocking every viewport
				-- click from then on - including every attempt to drag out
				-- a bay, which is exactly what this was reported as ("i
				-- simply cant draw the area").
				local pieMenuMode = if editSession.IsShowingMenu()
					then "Menu"
					elseif editSession.IsShowingSegmentMenu() then "SegmentMenu"
					elseif editSession.IsPlacingBay() then "PlacingBay"
					elseif editSession.IsConfirmingBay() then "ConfirmingBay"
					elseif editSession.IsPlacingMarkingStretch() then "PlacingMarkingStretch"
					elseif editSession.IsConfirmingMarkingStretch() then "ConfirmingMarkingStretch"
					elseif editSession.IsPlacingKerbStretch() then "PlacingKerbStretch"
					elseif editSession.IsConfirmingKerbStretch() then "ConfirmingKerbStretch"
					else "ViewingStretches"
				if pieMenuMode ~= lastPieMenuMode then
					lastPieMenuMode = pieMenuMode
					uiState.Hovered = false
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
						-- Two separate pills rather than one "Place More" -
						-- it used to always continue from the road's far end
						-- regardless of which end the user actually wanted
						-- to extend from.
						TopRight = {
							Text = "Place More (Start)",
							OnClick = function()
								local continuation = editSession.GetContinuation("Start")
								editSession.Deselect()
								if continuation then
									startSession({
										Position = continuation.Position,
										Tangent = continuation.Tangent,
									}, continuation.Profile)
								end
							end,
						},
						Left = {
							Text = "Place More (End)",
							OnClick = function()
								local continuation = editSession.GetContinuation("End")
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
					local profile = editSession.GetProfile()
					-- Highways do not offer bus bays, and the current bay overlay owns
					-- one constant cross-section rather than a widening transition.
					local canAddBay = (profile == nil or profile.Category ~= "Highways")
						and not editSession.IsTransition()
					local hasStretches = #editSession.GetMarkingStretches() > 0 or #editSession.GetKerbStretches() > 0
					pieMenuElement = React.createElement(PieMenu, {
						WorldPosition = anchor,
						SetGlobalHover = setGlobalHover,
						Top = if canAddBay
							then {
								Text = "Add Bus Bay",
								OnClick = function()
									editSession.StartBayPlacement()
								end,
							}
							else nil,
						-- Covers both stretch kinds in one action rather than a
						-- separate pill each - PieMenu's ring is already full
						-- (all six slots in use) once Stretch Kerb Marking
						-- joined Stretch Marking, and both underlying Clear
						-- calls are no-ops on an empty list anyway.
						TopLeft = if hasStretches
							then {
								Text = "Clear Stretches",
								OnClick = function()
									editSession.ClearMarkingStretches()
									editSession.ClearKerbStretches()
								end,
							}
							else nil,
						TopRight = {
							Text = "Stretch Kerb Marking",
							OnClick = function()
								editSession.StartKerbStretchPlacement()
							end,
						},
						Left = {
							Text = "Edit Lane Markings",
							OnClick = function()
								editSession.OpenStretchesView()
							end,
						},
						Right = {
							Text = "Stretch Marking",
							OnClick = function()
								editSession.StartMarkingStretchPlacement()
							end,
						},
						Bottom = {
							Text = "Back",
							OnClick = function()
								editSession.CloseSegmentMenu()
							end,
						},
					})
				elseif editSession.IsPlacingBay() then
					pieMenuElement = React.createElement(PieMenu, {
						WorldPosition = anchor,
						SetGlobalHover = setGlobalHover,
						Bottom = {
							Text = "Click and drag along the road to draw the bus bay (Esc to cancel)",
							OnClick = function()
								editSession.CancelBayPlacement()
							end,
						},
					})
				elseif editSession.IsConfirmingBay() then
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
				elseif editSession.IsPlacingMarkingStretch() then
					pieMenuElement = React.createElement(PieMenu, {
						WorldPosition = anchor,
						SetGlobalHover = setGlobalHover,
						Bottom = {
							Text = "Click a lane line, then drag along the road (Esc to cancel)",
							OnClick = function()
								editSession.CancelMarkingStretchPlacement()
							end,
						},
					})
				elseif editSession.IsConfirmingMarkingStretch() then
					-- Range/line-type panel is the bottom HUD below
					pieMenuElement = React.createElement(PieMenu, {
						WorldPosition = anchor,
						SetGlobalHover = setGlobalHover,
						Top = {
							Text = "Apply Stretch",
							OnClick = function()
								editSession.ConfirmMarkingStretch()
							end,
						},
						Bottom = {
							Text = "Cancel",
							OnClick = function()
								editSession.CancelMarkingStretchPlacement()
							end,
						},
					})
				elseif editSession.IsPlacingKerbStretch() then
					pieMenuElement = React.createElement(PieMenu, {
						WorldPosition = anchor,
						SetGlobalHover = setGlobalHover,
						Bottom = {
							Text = "Click the road's left or right kerb line, then drag along the road (Esc to cancel)",
							OnClick = function()
								editSession.CancelKerbStretchPlacement()
							end,
						},
					})
				elseif editSession.IsConfirmingKerbStretch() then
					-- Range/restriction panel is the bottom HUD below
					pieMenuElement = React.createElement(PieMenu, {
						WorldPosition = anchor,
						SetGlobalHover = setGlobalHover,
						Top = {
							Text = "Apply Stretch",
							OnClick = function()
								editSession.ConfirmKerbStretch()
							end,
						},
						Bottom = {
							Text = "Cancel",
							OnClick = function()
								editSession.CancelKerbStretchPlacement()
							end,
						},
					})
				else -- ViewingStretches: the stretch list is the bottom HUD below
					pieMenuElement = React.createElement(PieMenu, {
						WorldPosition = anchor,
						SetGlobalHover = setGlobalHover,
						Bottom = {
							Text = "Back",
							OnClick = function()
								editSession.CloseStretchesView()
							end,
						},
					})
				end

				-- Deliberately NOT tracking hover on this wrapping frame: it
				-- spans the whole screen (needed so the anchored pie menu
				-- can be positioned anywhere within it), so a MouseEnter
				-- here would fire almost immediately and latch
				-- uiState.Hovered permanently - which used to make the
				-- viewport's "don't place through the HUD" guard swallow
				-- every click while any pie menu was showing (i.e.
				-- whenever a road was selected). Each PillButton reports
				-- its own (correctly small) hover area via SetGlobalHover
				-- instead.
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
			lastPieMenuMode = nil
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
				OnBackupData = function(): string
					persist()
					return Settings.Export(settings, HttpService)
				end,
				OnValidateRestoreData = validateRestoreData,
				OnRestoreData = restoreData,
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
				OnClose = function()
					keybindsDock.Enabled = false
				end,
			}))
		elseif keybindsRoot then
			keybindsRoot:unmount()
			keybindsRoot = nil
		end

		if softwareDock.Enabled then
			if not softwareRoot then
				softwareRoot = ReactRoblox.createRoot(softwareDock)
			end
			assert(softwareRoot):render(React.createElement(SoftwareGui, {
				OnClose = function()
					softwareDock.Enabled = false
				end,
				OnViewEula = function()
					eulaReviewOpen = true
					updateUI()
				end,
			}))
		elseif softwareRoot then
			softwareRoot:unmount()
			softwareRoot = nil
		end
	end

	local clickedCn = buttonClicked:Connect(function()
		pluginOpen = not pluginOpen
		if not pluginOpen then
			eulaReviewOpen = false
			destroyEulaScreen()
			destroySession()
			designProfile = nil
			assetManagerOpen = false
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
	softwareDock:GetPropertyChangedSignal("Enabled"):Connect(function()
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
		if softwareRoot then
			softwareRoot:unmount()
			softwareRoot = nil
		end
		if topRoot then
			topRoot:unmount()
			topRoot = nil
		end
		if topScreenGui then
			topScreenGui:Destroy()
			topScreenGui = nil
		end
		releaseTopBarBridge()
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
		junctionEditSession.Destroy()
		junctionEditSessionChangedCn:Disconnect()
		roundaboutEditSession.Destroy()
		roundaboutEditSessionChangedCn:Disconnect()
		roadRemovingCn:Disconnect()
		persist()
		clickedCn:Disconnect()
		elevationUpAction:Destroy()
		elevationDownAction:Destroy()
		cancelPlacementAction:Destroy()
	end)
end
