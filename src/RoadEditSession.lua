--!strict
-- Post-placement road editing: select an already-placed Road model with
-- Studio's ordinary Selection (clicking it in the viewport or the Explorer -
-- no need to activate the build tool) and edit its cross-section, kerb
-- rules, and markings in place.
--
-- Edits are staged locally (clone-and-mutate, same pattern as the road
-- editor page) and only rebuild the model's geometry - as a single undo
-- step - when the user applies the change.

local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local Packages = script.Parent.Parent.Packages
local Signal = require(Packages.Signal)

local RoadInstance = require("./RoadInstance")
local RoadBuilder = require("./Mesh/RoadBuilder")
local RoadProfile = require("./RoadProfile")
local RegionStyles = require("./RegionStyles")
local Settings = require("./Settings")
local Keybinds = require("./Keybinds")
local BusStops = require("./BusStops")
local Markings = require("./Mesh/Markings")

-- Pie-menu state machine for a selected road:
--   Menu         - top-level pills (Edit on Road Builder / Place More / ...)
--   SegmentMenu  - "Edit Road Segment" submenu (Add Bus Bay / Edit Lane
--                  Markings / Stretch Marking / Back). A standalone
--                  marker-only "Add Bus Stop" mode used to live here too -
--                  removed since a real bus bay already serves as a stop;
--                  BusStops.Render below still re-renders any markers
--                  stamped before that change so existing roads aren't
--                  affected.
--   PlacingBay   - click-drag-to-draw mode for a real bus BAY (a physical
--                  pull-in carved into the road's cross-section).
--   ConfirmingBay - after a bay's drawn, adjust its length/width (defaults:
--                  the dragged size) before committing the geometry rebuild.
--   PlacingMarkingStretch - click a same-direction lane boundary, then drag
--                  along the road to pick the free-form sub-range where its
--                  marking (and every same-direction sibling boundary's)
--                  should be overridden to a different line type.
--   ConfirmingMarkingStretch - adjust the dragged range/line type before
--                  committing.
--   Designer     - the full RoadInspector designer
type Mode =
	"Menu"
	| "SegmentMenu"
	| "PlacingBay"
	| "ConfirmingBay"
	| "PlacingMarkingStretch"
	| "ConfirmingMarkingStretch"
	| "Designer"

export type BayDraft = {
	LengthStuds: number,
	WidthM: number,
	Side: "Left" | "Right",
}

-- Seed data for continuing a build session from this road's end (the
-- "Place More" pie-menu action) - the exact same shape createRoadSession's
-- SessionSeed expects, plus which profile to start the continuation with.
export type Continuation = {
	Position: Vector3,
	Tangent: Vector3,
	Profile: RoadProfile.RoadProfile,
}

export type RoadEditSession = {
	ChangeSignal: Signal.Signal<>,
	GetSelectedRoad: () -> Model?,
	GetProfile: () -> RoadProfile.RoadProfile?,
	GetEndProfile: () -> RoadProfile.RoadProfile?,
	IsTransition: () -> boolean,
	IsDirty: () -> boolean,
	SetProfile: (profile: RoadProfile.RoadProfile) -> (),
	Apply: () -> (),
	Revert: () -> (),
	Deselect: () -> (),
	-- Selecting a road first shows a contextual pie menu (Edit on Road Builder /
	-- Place More / Use as Template / Cancel); OpenEditor transitions from
	-- that menu into the full designer for this same road.
	IsShowingMenu: () -> boolean,
	OpenEditor: () -> (),
	GetAnchorWorldPosition: () -> Vector3?,
	GetContinuation: () -> Continuation?,
	-- "Edit Road Segment" second-level submenu (Add Bus Bay / Edit Lane
	-- Markings / Back).
	IsShowingSegmentMenu: () -> boolean,
	OpenSegmentMenu: () -> (),
	CloseSegmentMenu: () -> (),
	-- Real bus bay: click a point on the road, then adjust length/width.
	IsPlacingBay: () -> boolean,
	StartBayPlacement: () -> (),
	CancelBayPlacement: () -> (),
	IsConfirmingBay: () -> boolean,
	GetBayDraft: () -> BayDraft?,
	SetBayDraftLength: (lengthStuds: number) -> (),
	SetBayDraftWidth: (widthM: number) -> (),
	ConfirmBay: () -> (),
	-- Marking stretch: click a same-direction lane boundary and drag
	-- free-form along the road to override it (and its siblings) to a
	-- different line type over that sub-range.
	IsPlacingMarkingStretch: () -> boolean,
	StartMarkingStretchPlacement: () -> (),
	CancelMarkingStretchPlacement: () -> (),
	IsConfirmingMarkingStretch: () -> boolean,
	GetMarkingStretchDraft: () -> Markings.MarkingStretch?,
	SetMarkingStretchDraftFrom: (studs: number) -> (),
	SetMarkingStretchDraftTo: (studs: number) -> (),
	SetMarkingStretchDraftLine: (line: RegionStyles.LineType) -> (),
	ConfirmMarkingStretch: () -> (),
	GetMarkingStretches: () -> { Markings.MarkingStretch },
	ClearMarkingStretches: () -> (),
	Destroy: () -> (),
}

local function createRoadEditSession(
	plugin: Plugin,
	settings: Settings.EasyRoadSettings,
	getStyle: () -> RegionStyles.RegionStyle,
	uiState: { Hovered: boolean }
): RoadEditSession
	local changeSignal = Signal.new()

	local selectedRoad: Model? = nil
	local originalData: RoadInstance.RoadData? = nil
	local editingProfile: RoadProfile.RoadProfile? = nil -- Local staged clone of ProfileStart
	local mode: Mode = "Menu"
	local mouse = plugin:GetMouse()
	local bayConnections: { RBXScriptConnection } = {}
	local bayStation: number? = nil -- Chosen placement station, set once the drag finishes
	local bayDraft: BayDraft? = nil
	-- Click-drag-to-draw state: set on mouse down, cleared once the drag
	-- finishes (mouse up) or is cancelled.
	local bayDragStartStation: number? = nil
	local bayDragStartHit: Vector3? = nil
	local bayGhost: Part? = nil
	local stretchConnections: { RBXScriptConnection } = {}
	local stretchDraft: Markings.MarkingStretch? = nil
	-- Click-drag-to-draw state, same convention as the bay's: set on mouse
	-- down, cleared once the drag finishes or is cancelled.
	local stretchDragStartStation: number? = nil
	local stretchDragComponentIndex: number? = nil
	local stretchGhosts: { Part } = {}

	-- Cancels either step of bay placement: before a drag is drawn
	-- (PlacingBay, still listening for a click-drag) or after
	-- (ConfirmingBay, adjusting length/width) - both just return to
	-- SegmentMenu with nothing committed.
	local function stopBayPlacement()
		if mode ~= "PlacingBay" and mode ~= "ConfirmingBay" then
			return
		end
		if mode == "PlacingBay" then
			plugin:Deactivate()
		end
		for _, connection in bayConnections do
			connection:Disconnect()
		end
		table.clear(bayConnections)
		if bayGhost then
			bayGhost:Destroy()
			bayGhost = nil
		end
		bayDragStartStation = nil
		bayStation = nil
		bayDraft = nil
		mode = "SegmentMenu"
		changeSignal:Fire()
	end

	local function clearStretchGhosts()
		for _, ghost in stretchGhosts do
			ghost:Destroy()
		end
		table.clear(stretchGhosts)
	end

	-- Cancels either step of marking-stretch placement, same shape as
	-- stopBayPlacement above.
	local function stopMarkingStretchPlacement()
		if mode ~= "PlacingMarkingStretch" and mode ~= "ConfirmingMarkingStretch" then
			return
		end
		if mode == "PlacingMarkingStretch" then
			plugin:Deactivate()
		end
		for _, connection in stretchConnections do
			connection:Disconnect()
		end
		table.clear(stretchConnections)
		clearStretchGhosts()
		stretchDragStartStation = nil
		stretchDragComponentIndex = nil
		stretchDraft = nil
		mode = "SegmentMenu"
		changeSignal:Fire()
	end

	-- Finds the same-direction Drive/Drive boundary nearest the click's
	-- lateral position - mirrors exactly the condition Markings.lua uses to
	-- decide a boundary is a lane-changing rule candidate at all (kerb/edge
	-- lines and opposing-direction center lines aren't valid stretch
	-- targets), so a click always resolves to something Markings.Compute
	-- will actually recognise as a member of a sibling run.
	local function resolveComponentIndexFromHit(station: number, hitPosition: Vector3): number?
		if not originalData then
			return nil
		end
		local profile = editingProfile or originalData.ProfileStart
		local frame = originalData.Curve:FrameAt(station)
		local lateralOffsetM = (hitPosition - frame.Position):Dot(frame.RightVector) / settings.MetersToStuds
		local offsets = RoadProfile.ComponentOffsetsM(profile)
		local components = profile.Components
		local bestIndex: number? = nil
		local bestDistance = math.huge
		for i = 1, #components - 1 do
			if #Markings.SiblingBoundaries(components, i) > 0 and offsets[i] then
				local distance = math.abs(lateralOffsetM - offsets[i].Right)
				if distance < bestDistance then
					bestDistance = distance
					bestIndex = i
				end
			end
		end
		return bestIndex
	end

	-- Draws one ghost strip per boundary in the clicked lane's sibling run
	-- (see Markings.SiblingBoundaries) - every boundary the committed
	-- geometry will actually stretch together, not just the one that was
	-- clicked, so the live preview matches what Apply actually does.
	-- Rebuilt from scratch each call rather than reused/resized: the
	-- sibling count only changes if a different boundary is clicked, which
	-- always starts a fresh drag anyway, and this only runs on mouse-move
	-- while dragging, not every frame.
	local function updateStretchGhost(componentIndex: number, s0: number, s1: number)
		clearStretchGhosts()
		if not selectedRoad or not originalData then
			return
		end
		local lo = math.min(s0, s1)
		local hi = math.max(s0, s1)
		if hi - lo < 1e-3 then
			return
		end
		local curve = originalData.Curve
		local profile = editingProfile or originalData.ProfileStart
		local offsets = RoadProfile.ComponentOffsetsM(profile)
		local siblings = Markings.SiblingBoundaries(profile.Components, componentIndex)
		if #siblings == 0 then
			return
		end
		local scale = settings.MetersToStuds
		local style = getStyle()
		local y = 0.15 -- Flush with the ordinary deck marking height, not a kerb
		local frameA = curve:FrameAt(lo)
		local frameB = curve:FrameAt(hi)
		local width = math.max(style.MarkingWidthM * scale, 0.3)
		for _, boundaryIndex in siblings do
			local boundary = offsets[boundaryIndex]
			if boundary then
				local offsetStuds = boundary.Right * scale
				local pA = (frameA * CFrame.new(offsetStuds, y, 0)).Position
				local pB = (frameB * CFrame.new(offsetStuds, y, 0)).Position
				local segLength = (pB - pA).Magnitude
				if segLength > 1e-3 then
					local ghost = Instance.new("Part")
					ghost.Name = "EasyRoadMarkingStretchGhost"
					ghost.Anchored = true
					ghost.CanCollide = false
					ghost.CanQuery = false
					ghost.CanTouch = false
					ghost.CastShadow = false
					ghost.Material = Enum.Material.Neon
					ghost.Color = style.WhiteMarking
					ghost.Transparency = 0.2
					ghost.Size = Vector3.new(width, 0.2, segLength)
					ghost.CFrame = CFrame.lookAt((pA + pB) / 2, pB, frameA.UpVector)
					ghost.Parent = workspace
					table.insert(stretchGhosts, ghost)
				end
			end
		end
	end

	local function onStretchDragBegin()
		if mode ~= "PlacingMarkingStretch" or not selectedRoad or not originalData then
			return
		end
		if uiState.Hovered then
			return
		end
		local station = originalData.Curve:ClosestS(mouse.Hit.Position)
		local componentIndex = resolveComponentIndexFromHit(station, mouse.Hit.Position)
		if not componentIndex then
			return
		end
		stretchDragStartStation = station
		stretchDragComponentIndex = componentIndex
	end

	local function onStretchDragMove()
		if
			mode ~= "PlacingMarkingStretch"
			or not stretchDragStartStation
			or not stretchDragComponentIndex
			or not originalData
		then
			return
		end
		local currentStation = originalData.Curve:ClosestS(mouse.Hit.Position)
		updateStretchGhost(stretchDragComponentIndex, stretchDragStartStation, currentStation)
	end

	local function onStretchDragEnd()
		if
			mode ~= "PlacingMarkingStretch"
			or not stretchDragStartStation
			or not stretchDragComponentIndex
			or not originalData
		then
			return
		end
		local currentStation = originalData.Curve:ClosestS(mouse.Hit.Position)
		local lo = math.min(stretchDragStartStation, currentStation)
		local hi = math.max(stretchDragStartStation, currentStation)
		if hi - lo < 1 then
			-- Too short to be an intentional drag - stay in PlacingMarkingStretch
			-- so a misclick doesn't abort the whole flow, matching how a
			-- near-zero bay drag is silently ignored rather than committed.
			stretchDragStartStation = nil
			stretchDragComponentIndex = nil
			clearStretchGhosts()
			return
		end
		stretchDraft = {
			ComponentIndex = stretchDragComponentIndex,
			FromStationStuds = lo,
			ToStationStuds = hi,
			Line = "Solid",
		}
		stretchDragStartStation = nil
		stretchDragComponentIndex = nil
		clearStretchGhosts()
		for _, connection in stretchConnections do
			connection:Disconnect()
		end
		table.clear(stretchConnections)
		plugin:Deactivate()
		mode = "ConfirmingMarkingStretch"
		changeSignal:Fire()
	end

	-- Rebuilds the selected road's geometry with the given marking
	-- stretches (replacing whatever was stamped before), then re-stamps
	-- everything - the same "clone-and-mutate, rebuild as one undo step"
	-- pattern session.Apply/ConfirmBay use, shared here since
	-- ConfirmMarkingStretch and ClearMarkingStretches both need it.
	local function rebuildWithMarkingStretches(stretches: { Markings.MarkingStretch }, historyLabel: string)
		if not selectedRoad or not originalData then
			return
		end
		local road = selectedRoad
		local data = originalData
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadEdit", historyLabel)
		local buildOptions = {
			Curve = data.Curve,
			ProfileStart = editingProfile or data.ProfileStart,
			ProfileEnd = data.ProfileEnd,
			Style = getStyle(),
			Settings = settings,
			Preview = false,
			MarkingStretches = if #stretches > 0 then stretches else nil,
		}
		local built = if data.Bay
			then RoadBuilder.BuildWithBay(buildOptions, {
				StationStuds = data.Bay.StationStuds,
				LengthStuds = data.Bay.LengthStuds,
				WidthM = data.Bay.WidthM,
				Side = data.Bay.Side,
			})
			else RoadBuilder.Build(buildOptions)
		for _, child in road:GetChildren() do
			child:Destroy()
		end
		for _, child in built:GetChildren() do
			child.Parent = road
		end
		built:Destroy()
		RoadInstance.StampModel(road, data.Curve.Segments[1], editingProfile or data.ProfileStart, data.ProfileEnd)
		RoadInstance.StampBay(road, data.Bay)
		RoadInstance.StampMarkingStretches(road, stretches)
		BusStops.Render(road)
		data.MarkingStretches = stretches
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end

	-- Turns a drag from (startStation, startHit) to the current mouse hit
	-- into a length (along the road) / width (perpendicular, away from the
	-- start point - the user drags outward from the sidewalk) pair, plus
	-- which side of the road the drag went towards. The station midpoint
	-- between the drag's two ends is the bay's placement station.
	local function bayDraftFromDrag(
		startStation: number,
		startHit: Vector3,
		currentStation: number,
		currentHit: Vector3
	): BayDraft
		local lengthStuds = math.abs(currentStation - startStation)
		local frame = (originalData :: RoadInstance.RoadData).Curve:FrameAt(startStation)
		-- Signed, not absolute: positive = dragged toward the frame's right
		-- (RoadProfile's positive-offset side), negative = left - this is
		-- what actually determines which side the bay ends up on, not the
		-- region's DriveOnLeft setting (a bay can go on either side).
		local signedWidthStuds = (currentHit - startHit):Dot(frame.RightVector)
		local scale = settings.MetersToStuds
		return {
			LengthStuds = math.max(lengthStuds, 1),
			WidthM = math.max(math.abs(signedWidthStuds) / scale, 0.5),
			Side = if signedWidthStuds < 0 then "Left" else "Right",
		}
	end

	local function updateBayGhost(startStation: number, currentStation: number, widthM: number, side: "Left" | "Right")
		if not selectedRoad or not originalData then
			return
		end
		local curve = originalData.Curve
		local s0 = math.min(startStation, currentStation)
		local s1 = math.max(startStation, currentStation)
		if s1 - s0 < 1e-3 then
			if bayGhost then
				bayGhost.Size = Vector3.new(0, 0, 0)
			end
			return
		end
		local scale = settings.MetersToStuds
		local widthStuds = math.max(widthM * scale, 0.1)
		local style = getStyle()
		local outward = if side == "Left" then -1 else 1
		local offsets = RoadProfile.ComponentOffsetsM(editingProfile or originalData.ProfileStart)
		local kerbOffsetM = if side == "Left"
			then (if offsets[1] then offsets[1].Right else 0)
			else (if offsets[#offsets] then offsets[#offsets].Left else 0)
		local kerbOffset = kerbOffsetM * scale
		local outerOffset = kerbOffset + outward * widthStuds
		local frameA = curve:FrameAt(s0)
		local frameB = curve:FrameAt(s1)
		local centerOffset = (kerbOffset + outerOffset) / 2
		-- Sits exactly at the road's own highest surface (a raised
		-- sidewalk/median's top is always exactly `curbHeight` above the
		-- frame - see RoadBuilder.Build's raised-component centerY/height
		-- math) plus a small margin, instead of a flat 0.1 studs - a flat
		-- offset used to sit *below* the sidewalk whenever curbHeight was
		-- taller than that, so the (opaque, solid) sidewalk visually hid
		-- the ghost anywhere they overlapped instead of the ghost reading
		-- as an indicator on top of the road.
		local ghostY = style.CurbHeightM * scale + 0.15
		local pA = (frameA * CFrame.new(centerOffset, ghostY, 0)).Position
		local pB = (frameB * CFrame.new(centerOffset, ghostY, 0)).Position
		local segLength = (pB - pA).Magnitude
		if segLength < 1e-3 then
			return
		end
		if not bayGhost then
			local ghost = Instance.new("Part")
			ghost.Name = "EasyRoadBayGhost"
			ghost.Anchored = true
			ghost.CanCollide = false
			ghost.CanQuery = false
			ghost.CanTouch = false
			ghost.CastShadow = false
			ghost.Material = Enum.Material.Neon
			ghost.Color = style.BayColor
			ghost.Transparency = 0.4
			ghost.Parent = workspace
			bayGhost = ghost
		end
		local ghost = bayGhost :: Part
		ghost.Color = style.BayColor
		ghost.Size = Vector3.new(widthStuds, 0.2, segLength)
		ghost.CFrame = CFrame.lookAt((pA + pB) / 2, pB, frameA.UpVector)
	end

	-- Click-drag-to-draw: mouse down on the road starts the drag (recording
	-- where along the curve and how far laterally); moving the mouse while
	-- held updates a live ghost indicator; releasing finishes the drag and
	-- moves to ConfirmingBay with the dragged length/width as the initial
	-- draft (still adjustable there, and pressing Enter/Add Bay immediately
	-- accepts it as-is).
	local function onBayDragBegin()
		if mode ~= "PlacingBay" or not selectedRoad or not originalData then
			return
		end
		if uiState.Hovered then
			return
		end
		-- Deliberately not requiring mouse.Target to land on the road itself -
		-- the user is drawing a rectangle that starts on the road but is
		-- dragged outward past its edge, and
		-- a drag that starts a pixel off the road (baseplate showing
		-- through a thin gap, camera angle grazing the edge, ...) used to
		-- silently drop the whole gesture, since onBayDragMove/End already
		-- only need bayDragStartStation to be set. ClosestS always finds
		-- the nearest station on the curve regardless of what was actually
		-- hit, so a click anywhere in the viewport near the road registers.
		bayDragStartStation = originalData.Curve:ClosestS(mouse.Hit.Position)
		bayDragStartHit = mouse.Hit.Position
	end

	local function onBayDragMove()
		if mode ~= "PlacingBay" or not bayDragStartStation or not bayDragStartHit or not originalData then
			return
		end
		local currentStation = originalData.Curve:ClosestS(mouse.Hit.Position)
		local draft = bayDraftFromDrag(bayDragStartStation, bayDragStartHit, currentStation, mouse.Hit.Position)
		updateBayGhost(bayDragStartStation, currentStation, draft.WidthM, draft.Side)
	end

	local function onBayDragEnd()
		if mode ~= "PlacingBay" or not bayDragStartStation or not bayDragStartHit or not originalData then
			return
		end
		local currentStation = originalData.Curve:ClosestS(mouse.Hit.Position)
		local draft = bayDraftFromDrag(bayDragStartStation, bayDragStartHit, currentStation, mouse.Hit.Position)
		bayStation = (bayDragStartStation + currentStation) / 2
		bayDraft = draft
		bayDragStartStation = nil
		bayDragStartHit = nil
		if bayGhost then
			bayGhost:Destroy()
			bayGhost = nil
		end
		for _, connection in bayConnections do
			connection:Disconnect()
		end
		table.clear(bayConnections)
		plugin:Deactivate()
		mode = "ConfirmingBay"
		changeSignal:Fire()
	end

	local function loadSelection()
		local road: Model? = nil
		for _, instance in Selection:Get() do
			road = RoadInstance.FindRoad(instance)
			if road then
				break
			end
		end
		if road == selectedRoad then
			return
		end
		if mode == "PlacingBay" then
			stopBayPlacement()
		elseif mode == "PlacingMarkingStretch" then
			stopMarkingStretchPlacement()
		end
		selectedRoad = road
		originalData = if road then RoadInstance.Read(road) else nil
		editingProfile = if originalData then RoadProfile.Clone(originalData.ProfileStart) else nil
		bayStation = nil
		bayDraft = nil
		stretchDraft = nil
		mode = "Menu"
		changeSignal:Fire()
	end

	local connections: { RBXScriptConnection } = {}
	table.insert(connections, Selection.SelectionChanged:Connect(loadSelection))
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then
				return
			end
			if
				(mode == "PlacingBay" or mode == "ConfirmingBay")
				and Keybinds.Matches(settings.Keybinds.CancelPlacement, input)
			then
				stopBayPlacement()
			elseif
				(mode == "PlacingMarkingStretch" or mode == "ConfirmingMarkingStretch")
				and Keybinds.Matches(settings.Keybinds.CancelPlacement, input)
			then
				stopMarkingStretchPlacement()
			end
		end)
	)
	loadSelection()

	local session = {} :: RoadEditSession
	session.ChangeSignal = changeSignal

	function session.GetSelectedRoad(): Model?
		return selectedRoad
	end

	function session.GetProfile(): RoadProfile.RoadProfile?
		return editingProfile
	end

	function session.GetEndProfile(): RoadProfile.RoadProfile?
		return if originalData then originalData.ProfileEnd else nil
	end

	function session.IsTransition(): boolean
		local endProfile = if originalData then originalData.ProfileEnd else nil
		return originalData ~= nil and endProfile ~= nil and endProfile.Id ~= originalData.ProfileStart.Id
	end

	function session.IsDirty(): boolean
		if not editingProfile or not originalData then
			return false
		end
		local a = HttpService:JSONEncode(RoadProfile.Serialize(editingProfile))
		local b = HttpService:JSONEncode(RoadProfile.Serialize(originalData.ProfileStart))
		return a ~= b
	end

	function session.SetProfile(newProfile: RoadProfile.RoadProfile)
		editingProfile = newProfile
		changeSignal:Fire()
	end

	function session.Apply()
		if not selectedRoad or not editingProfile or not originalData then
			return
		end
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadEdit", "Edit road")
		-- Note: MarkingStretches reference boundaries by component index: an
		-- edit here that reorders/removes cross-section components (not
		-- just tweaks an existing one) can leave a stretch pointing at the
		-- wrong boundary. Accepted as a known v1 limitation rather than
		-- solved now - Markings.lua simply drops a stretch whose
		-- ComponentIndex no longer resolves to a same-direction boundary.
		local buildOptions = {
			Curve = originalData.Curve,
			ProfileStart = editingProfile,
			ProfileEnd = originalData.ProfileEnd,
			Style = getStyle(),
			Settings = settings,
			Preview = false,
			MarkingStretches = if #originalData.MarkingStretches > 0 then originalData.MarkingStretches else nil,
		}
		-- If this road has a bus bay, rebuild it through the bay-aware
		-- builder instead - otherwise an unrelated edit here (colour, kerb
		-- rule, ...) would silently wipe the bay's carved-out geometry.
		local built = if originalData.Bay
			then RoadBuilder.BuildWithBay(buildOptions, {
				StationStuds = originalData.Bay.StationStuds,
				LengthStuds = originalData.Bay.LengthStuds,
				WidthM = originalData.Bay.WidthM,
				Side = originalData.Bay.Side,
			})
			else RoadBuilder.Build(buildOptions)
		-- Bus stop markers are stored as an attribute (survives the rebuild)
		-- but rendered as children of the model, so they'd otherwise be
		-- wiped along with the old geometry - re-render them from the
		-- attribute once the new geometry is in place.
		for _, child in selectedRoad:GetChildren() do
			child:Destroy()
		end
		for _, child in built:GetChildren() do
			child.Parent = selectedRoad
		end
		built:Destroy()
		RoadInstance.StampModel(selectedRoad, originalData.Curve.Segments[1], editingProfile, originalData.ProfileEnd)
		RoadInstance.StampBay(selectedRoad, originalData.Bay)
		RoadInstance.StampMarkingStretches(selectedRoad, originalData.MarkingStretches)
		BusStops.Render(selectedRoad)
		originalData = {
			Curve = originalData.Curve,
			ProfileStart = RoadProfile.Clone(editingProfile),
			ProfileEnd = originalData.ProfileEnd,
			Bay = originalData.Bay,
			MarkingStretches = originalData.MarkingStretches,
		}
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end

	function session.Revert()
		editingProfile = if originalData then RoadProfile.Clone(originalData.ProfileStart) else nil
		changeSignal:Fire()
	end

	function session.Deselect()
		Selection:Set({})
	end

	function session.IsShowingMenu(): boolean
		return mode == "Menu"
	end

	function session.OpenEditor()
		mode = "Designer"
		changeSignal:Fire()
	end

	function session.IsShowingSegmentMenu(): boolean
		return mode == "SegmentMenu"
	end

	function session.OpenSegmentMenu()
		if mode == "Menu" then
			mode = "SegmentMenu"
			changeSignal:Fire()
		end
	end

	function session.CloseSegmentMenu()
		if mode == "SegmentMenu" then
			mode = "Menu"
			changeSignal:Fire()
		end
	end

	function session.IsPlacingBay(): boolean
		return mode == "PlacingBay"
	end

	function session.StartBayPlacement()
		if mode ~= "SegmentMenu" or not selectedRoad then
			return
		end
		mode = "PlacingBay"
		plugin:Activate(true)
		table.insert(bayConnections, mouse.Button1Down:Connect(onBayDragBegin))
		table.insert(bayConnections, mouse.Move:Connect(onBayDragMove))
		table.insert(bayConnections, mouse.Button1Up:Connect(onBayDragEnd))
		changeSignal:Fire()
	end

	session.CancelBayPlacement = stopBayPlacement

	function session.IsConfirmingBay(): boolean
		return mode == "ConfirmingBay"
	end

	function session.GetBayDraft(): BayDraft?
		return bayDraft
	end

	function session.SetBayDraftLength(lengthStuds: number)
		if bayDraft then
			bayDraft.LengthStuds = math.max(lengthStuds, 1)
			changeSignal:Fire()
		end
	end

	function session.SetBayDraftWidth(widthM: number)
		if bayDraft then
			bayDraft.WidthM = math.max(widthM, 0.5)
			changeSignal:Fire()
		end
	end

	function session.ConfirmBay()
		if mode ~= "ConfirmingBay" or not selectedRoad or not originalData or not bayDraft or not bayStation then
			return
		end
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadEdit", "Add bus bay")
		local bay: RoadInstance.BayData = {
			StationStuds = bayStation,
			LengthStuds = bayDraft.LengthStuds,
			WidthM = bayDraft.WidthM,
			Side = bayDraft.Side,
		}
		local built = RoadBuilder.BuildWithBay({
			Curve = originalData.Curve,
			ProfileStart = editingProfile or originalData.ProfileStart,
			ProfileEnd = originalData.ProfileEnd,
			Style = getStyle(),
			Settings = settings,
			Preview = false,
			MarkingStretches = if #originalData.MarkingStretches > 0 then originalData.MarkingStretches else nil,
		}, bay)
		for _, child in selectedRoad:GetChildren() do
			child:Destroy()
		end
		for _, child in built:GetChildren() do
			child.Parent = selectedRoad
		end
		built:Destroy()
		RoadInstance.StampModel(
			selectedRoad,
			originalData.Curve.Segments[1],
			editingProfile or originalData.ProfileStart,
			originalData.ProfileEnd
		)
		RoadInstance.StampBay(selectedRoad, bay)
		RoadInstance.StampMarkingStretches(selectedRoad, originalData.MarkingStretches)
		BusStops.Render(selectedRoad)
		originalData.Bay = bay
		bayStation = nil
		bayDraft = nil
		mode = "SegmentMenu"
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end

	function session.IsPlacingMarkingStretch(): boolean
		return mode == "PlacingMarkingStretch"
	end

	function session.StartMarkingStretchPlacement()
		if mode ~= "SegmentMenu" or not selectedRoad then
			return
		end
		mode = "PlacingMarkingStretch"
		plugin:Activate(true)
		table.insert(stretchConnections, mouse.Button1Down:Connect(onStretchDragBegin))
		table.insert(stretchConnections, mouse.Move:Connect(onStretchDragMove))
		table.insert(stretchConnections, mouse.Button1Up:Connect(onStretchDragEnd))
		changeSignal:Fire()
	end

	session.CancelMarkingStretchPlacement = stopMarkingStretchPlacement

	function session.IsConfirmingMarkingStretch(): boolean
		return mode == "ConfirmingMarkingStretch"
	end

	function session.GetMarkingStretchDraft(): Markings.MarkingStretch?
		return stretchDraft
	end

	function session.SetMarkingStretchDraftFrom(studs: number)
		if stretchDraft then
			stretchDraft.FromStationStuds = math.clamp(studs, 0, stretchDraft.ToStationStuds - 1)
			changeSignal:Fire()
		end
	end

	function session.SetMarkingStretchDraftTo(studs: number)
		if stretchDraft and originalData then
			stretchDraft.ToStationStuds =
				math.clamp(studs, stretchDraft.FromStationStuds + 1, originalData.Curve.Length)
			changeSignal:Fire()
		end
	end

	function session.SetMarkingStretchDraftLine(line: RegionStyles.LineType)
		if stretchDraft then
			stretchDraft.Line = line
			changeSignal:Fire()
		end
	end

	function session.ConfirmMarkingStretch()
		if mode ~= "ConfirmingMarkingStretch" or not originalData or not stretchDraft then
			return
		end
		local stretches = {}
		for _, existing in originalData.MarkingStretches do
			if existing.ComponentIndex ~= stretchDraft.ComponentIndex then
				table.insert(stretches, existing)
			end
		end
		table.insert(stretches, stretchDraft)
		stretchDraft = nil
		mode = "SegmentMenu"
		rebuildWithMarkingStretches(stretches, "Stretch marking")
	end

	function session.GetMarkingStretches(): { Markings.MarkingStretch }
		return if originalData then originalData.MarkingStretches else {}
	end

	function session.ClearMarkingStretches()
		if not originalData or #originalData.MarkingStretches == 0 then
			return
		end
		rebuildWithMarkingStretches({}, "Clear marking stretches")
	end

	function session.GetAnchorWorldPosition(): Vector3?
		if not originalData then
			return nil
		end
		local curve = originalData.Curve
		return curve:PosAt(curve.Length / 2)
	end

	function session.GetContinuation(): Continuation?
		if not originalData then
			return nil
		end
		local curve = originalData.Curve
		local profile = originalData.ProfileEnd or originalData.ProfileStart
		return {
			Position = curve:PosAt(curve.Length),
			Tangent = curve:TangentAt(curve.Length),
			Profile = RoadProfile.Clone(profile),
		}
	end

	function session.Destroy()
		if mode == "PlacingBay" or mode == "PlacingMarkingStretch" then
			plugin:Deactivate()
		end
		for _, connection in bayConnections do
			connection:Disconnect()
		end
		table.clear(bayConnections)
		if bayGhost then
			bayGhost:Destroy()
			bayGhost = nil
		end
		for _, connection in stretchConnections do
			connection:Disconnect()
		end
		table.clear(stretchConnections)
		clearStretchGhosts()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		changeSignal:DisconnectAll()
	end

	return session
end

return createRoadEditSession
