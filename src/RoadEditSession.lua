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
local PolyCurve = require("./Geometry/PolyCurve")
local Superelevation = require("./Geometry/Superelevation")
local StructureAssets = require("./StructureAssets")
local StructureBuilder = require("./StructureBuilder")

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
--   ViewingStretches - lists this road's existing marking stretches with a
--                  per-stretch Remove button - "Edit Lane Markings"'s own
--                  destination. Deliberately NOT the full Designer: that
--                  was the original behaviour ("Edit Lane Markings" was
--                  identical to "Edit on Road Builder", just the same
--                  designer under a different label), reported back as
--                  confusing now that a stretch is a road-local, spatial
--                  edit rather than a whole-profile one - a full
--                  cross-section editor isn't the right destination for
--                  "show me the stretches on this road."
--   PlacingKerbStretch - click any of the road's kerb lines (the outer
--                  edges, or an internal one bordering a median/raised
--                  component), then drag along the road to pick the
--                  free-form sub-range where its restriction (single/
--                  double yellow/none/no line) should be overridden. Same
--                  click-a-target-then-drag-a-range shape as marking
--                  stretches, targeting an EdgeIndex rather than a lane-
--                  boundary index - a click always resolves to whichever
--                  kerb-line EdgeIndex it landed nearest.
--   ConfirmingKerbStretch - adjust the dragged range/restriction before
--                  committing.
--   Designer     - the full RoadInspector designer
type Mode =
	"Menu"
	| "SegmentMenu"
	| "PlacingBay"
	| "ConfirmingBay"
	| "PlacingMarkingStretch"
	| "ConfirmingMarkingStretch"
	| "ViewingStretches"
	| "PlacingKerbStretch"
	| "ConfirmingKerbStretch"
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
	GetStructure: () -> RoadInstance.StructureData?,
	GetStructureAssets: (kind: StructureAssets.AssetKind?) -> { StructureAssets.AssetInfo },
	GetStructureStatus: () -> string?,
	IsTransition: () -> boolean,
	IsDirty: () -> boolean,
	SetProfile: (profile: RoadProfile.RoadProfile) -> (),
	SetStructure: (structure: RoadInstance.StructureData) -> (),
	Apply: () -> (),
	Revert: () -> (),
	Deselect: () -> (),
	-- Selecting a road first shows a contextual pie menu (Edit on Road Builder /
	-- Place More / Use as Template / Cancel); OpenEditor transitions from
	-- that menu into the full designer for this same road.
	IsShowingMenu: () -> boolean,
	OpenEditor: () -> (),
	GetAnchorWorldPosition: () -> Vector3?,
	GetContinuation: (fromEnd: "Start" | "End") -> Continuation?,
	-- "Edit Road Segment" second-level submenu (Add Bus Bay / Edit Lane
	-- Markings / Stretch Marking / Back).
	IsShowingSegmentMenu: () -> boolean,
	OpenSegmentMenu: () -> (),
	CloseSegmentMenu: () -> (),
	-- "Edit Lane Markings" - lists this road's stretches (see
	-- ViewingStretches above), not the full Designer.
	IsViewingStretches: () -> boolean,
	OpenStretchesView: () -> (),
	CloseStretchesView: () -> (),
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
	-- free-form along the road to override it (and, depending on
	-- selection mode, related boundaries) to a different line type over
	-- that sub-range.
	IsPlacingMarkingStretch: () -> boolean,
	-- All = the whole same-direction sibling run (default); Individual =
	-- just the clicked boundary; Select = an arbitrary set, built by
	-- plain (non-drag) clicks toggling membership before the range drag.
	GetMarkingStretchSelectionMode: () -> "All" | "Individual" | "Select",
	SetMarkingStretchSelectionMode: (mode: "All" | "Individual" | "Select") -> (),
	StartMarkingStretchPlacement: () -> (),
	CancelMarkingStretchPlacement: () -> (),
	IsConfirmingMarkingStretch: () -> boolean,
	GetMarkingStretchDraft: () -> Markings.MarkingStretch?,
	SetMarkingStretchDraftFrom: (studs: number) -> (),
	SetMarkingStretchDraftTo: (studs: number) -> (),
	SetMarkingStretchDraftLine: (line: RegionStyles.LineType) -> (),
	SetMarkingStretchDraftDashLength: (dashLengthM: number) -> (),
	SetMarkingStretchDraftDashGap: (dashGapM: number) -> (),
	ConfirmMarkingStretch: () -> (),
	GetMarkingStretches: () -> { Markings.MarkingStretch },
	ClearMarkingStretches: () -> (),
	RemoveMarkingStretch: (index: number) -> (),
	-- Kerb stretch: click the road's own left/right kerb line and drag
	-- free-form along the road to override its restriction over that
	-- sub-range - same shape as marking stretch, scoped to the road's two
	-- outermost edges instead of an arbitrary lane-boundary index set.
	IsPlacingKerbStretch: () -> boolean,
	StartKerbStretchPlacement: () -> (),
	CancelKerbStretchPlacement: () -> (),
	IsConfirmingKerbStretch: () -> boolean,
	GetKerbStretchDraft: () -> Markings.KerbStretch?,
	SetKerbStretchDraftFrom: (studs: number) -> (),
	SetKerbStretchDraftTo: (studs: number) -> (),
	SetKerbStretchDraftRestriction: (restriction: string) -> (),
	ConfirmKerbStretch: () -> (),
	GetKerbStretches: () -> { Markings.KerbStretch },
	ClearKerbStretches: () -> (),
	RemoveKerbStretch: (index: number) -> (),
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
	local editingStructure: RoadInstance.StructureData? = nil
	local structureStatus: string? = nil
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
	-- Which boundaries a drag applies to: "All" (the whole same-direction
	-- sibling run - the default), "Individual" (just the clicked
	-- boundary), or "Select" (an arbitrary, user-built set - see
	-- stretchSelectedIndices below, toggled by plain clicks while in this
	-- mode). Persists across separate stretch placements on the same road
	-- (a deliberate choice, unlike the toggle set below); reset only when
	-- a different road is selected.
	local stretchSelectionMode: "All" | "Individual" | "Select" = "All"
	-- The pending "Select" mode boundary set, built up by toggling clicks
	-- before the actual range-setting drag - cleared on every cancel/
	-- confirm/mode-switch, never carried between placements.
	local stretchSelectedIndices: { [number]: boolean } = {}
	local stretchSelectGhosts: { Part } = {}
	local kerbStretchConnections: { RBXScriptConnection } = {}
	local kerbStretchDraft: Markings.KerbStretch? = nil
	-- Click-drag-to-draw state, same convention as the lane stretch's.
	local kerbStretchDragStartStation: number? = nil
	local kerbStretchDragEdgeIndex: number? = nil
	local kerbStretchGhosts: { Part } = {}

	-- Frame at a station INCLUDING the same superelevation (bank) roll
	-- RoadBuilder.Build actually uses for the real geometry - a plain
	-- curve:FrameAt(s) (roll defaults to 0) drifts away from the true
	-- (tilted) road surface on a banked curve, more so the sharper the
	-- bend, which could put a ghost's flat local-Y offset either floating
	-- above the pavement or clipped inside it depending on how much bank
	-- is in effect at that station - reported live as a stretch ghost that
	-- "sometimes shows, sometimes not" specifically on curved sections.
	local function frameAtWithRoll(curve: PolyCurve.PolyCurve, s: number): CFrame
		return curve:FrameAt(s, Superelevation.RollAt(curve:CurvatureAt(s), settings, getStyle()))
	end

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

	local function clearStretchSelectGhosts()
		for _, ghost in stretchSelectGhosts do
			ghost:Destroy()
		end
		table.clear(stretchSelectGhosts)
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
		clearStretchSelectGhosts()
		stretchSelectedIndices = {}
		stretchDragStartStation = nil
		stretchDragComponentIndex = nil
		stretchDraft = nil
		mode = "SegmentMenu"
		changeSignal:Fire()
	end

	local function clearKerbStretchGhosts()
		for _, ghost in kerbStretchGhosts do
			ghost:Destroy()
		end
		table.clear(kerbStretchGhosts)
	end

	-- Cancels either step of kerb-stretch placement, same shape as
	-- stopMarkingStretchPlacement above.
	local function stopKerbStretchPlacement()
		if mode ~= "PlacingKerbStretch" and mode ~= "ConfirmingKerbStretch" then
			return
		end
		if mode == "PlacingKerbStretch" then
			plugin:Deactivate()
		end
		for _, connection in kerbStretchConnections do
			connection:Disconnect()
		end
		table.clear(kerbStretchConnections)
		clearKerbStretchGhosts()
		kerbStretchDragStartStation = nil
		kerbStretchDragEdgeIndex = nil
		kerbStretchDraft = nil
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
			if Markings.IsSameDirectionBoundary(components, i) and offsets[i] then
				local distance = math.abs(lateralOffsetM - offsets[i].Right)
				if distance < bestDistance then
					bestDistance = distance
					bestIndex = i
				end
			end
		end
		return bestIndex
	end

	-- The lateral offset (metres from centreline) of a given EdgeIndex -
	-- 0 and #components are the true outer edges, anything in between is
	-- the boundary between components[edgeIndex] and components[edgeIndex+1]
	-- (that boundary's Right offset and the next component's Left offset
	-- are the same physical position, so either works).
	local function kerbEdgeOffsetM(offsets: { { Left: number, Right: number } }, edgeIndex: number): number
		if edgeIndex <= 0 then
			return if offsets[1] then offsets[1].Left else 0
		elseif edgeIndex >= #offsets then
			return if offsets[#offsets] then offsets[#offsets].Right else 0
		end
		return offsets[edgeIndex].Right
	end

	-- Finds whichever of the road's genuine kerb-line edges (see
	-- Markings.KerbEdges) the click's lateral position lands nearest to -
	-- nil if the profile has none at all.
	local function resolveKerbEdgeFromHit(station: number, hitPosition: Vector3): number?
		if not originalData then
			return nil
		end
		local profile = editingProfile or originalData.ProfileStart
		local edges = Markings.KerbEdges(profile.Components)
		if #edges == 0 then
			return nil
		end
		local frame = originalData.Curve:FrameAt(station)
		local lateralOffsetM = (hitPosition - frame.Position):Dot(frame.RightVector) / settings.MetersToStuds
		local offsets = RoadProfile.ComponentOffsetsM(profile)
		local best: number? = nil
		local bestDistance = math.huge
		for _, edgeIndex in edges do
			local distance = math.abs(lateralOffsetM - kerbEdgeOffsetM(offsets, edgeIndex))
			if distance < bestDistance then
				bestDistance = distance
				best = edgeIndex
			end
		end
		return best
	end

	-- What a drag starting on clickedIndex will actually apply to, given
	-- the current selection mode - shared by the live drag-ghost preview
	-- and the final committed ComponentIndices, so the two can never
	-- disagree. "Select" mode falls back to just clickedIndex when nothing
	-- has been toggled yet, so a plain click-drag with no prior toggles
	-- behaves like "Individual".
	local function resolvePreviewIndices(clickedIndex: number): { number }
		local profile = (editingProfile or (originalData :: RoadInstance.RoadData).ProfileStart).Components
		if stretchSelectionMode == "All" then
			return Markings.SiblingBoundaries(profile, clickedIndex)
		elseif stretchSelectionMode == "Individual" then
			return { clickedIndex }
		end
		local indices = {}
		for index in stretchSelectedIndices do
			table.insert(indices, index)
		end
		if not table.find(indices, clickedIndex) then
			table.insert(indices, clickedIndex)
		end
		return indices
	end

	local GHOST_MAX_SEGMENTS = 8

	-- Builds ghost strips for `indices` between stations s0/s1, following
	-- the curve with a small, fixed number of straight facets instead of
	-- one long chord - a single chord directly connecting its two
	-- endpoints visibly cuts corners on an actual curve. This is only ever
	-- a live, ephemeral preview (never committed geometry), so a coarse
	-- facet chain is a deliberate accuracy/performance tradeoff: good
	-- enough to read as curve-following without redrawing a large number
	-- of Parts on every mouse-move. Shared by the active-drag range
	-- preview and the persistent "Select" mode toggle highlight below.
	local function buildGhostStrips(
		indices: { number },
		s0: number,
		s1: number,
		color: Color3,
		transparency: number,
		into: { Part }
	)
		if not selectedRoad or not originalData then
			return
		end
		local lo = math.min(s0, s1)
		local hi = math.max(s0, s1)
		if hi - lo < 1e-3 or #indices == 0 then
			return
		end
		local curve = originalData.Curve
		local profile = editingProfile or originalData.ProfileStart
		local offsets = RoadProfile.ComponentOffsetsM(profile)
		local scale = settings.MetersToStuds
		local style = getStyle()
		local y = 0.15 -- Flush with the ordinary deck marking height, not a kerb
		local width = math.max(style.MarkingWidthM * scale, 0.3)
		local segments = math.min(GHOST_MAX_SEGMENTS, math.max(1, math.floor((hi - lo) / 4)))
		for _, boundaryIndex in indices do
			local boundary = offsets[boundaryIndex]
			if boundary then
				local offsetStuds = boundary.Right * scale
				for i = 0, segments - 1 do
					local segLo = lo + (hi - lo) * (i / segments)
					local segHi = lo + (hi - lo) * ((i + 1) / segments)
					local frameA = frameAtWithRoll(curve, segLo)
					local frameB = frameAtWithRoll(curve, segHi)
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
						ghost.Color = color
						ghost.Transparency = transparency
						ghost.Size = Vector3.new(width, 0.2, segLength)
						ghost.CFrame = CFrame.lookAt((pA + pB) / 2, pB, frameA.UpVector)
						ghost.Parent = workspace
						table.insert(into, ghost)
					end
				end
			end
		end
	end

	local function updateStretchGhost(indices: { number }, s0: number, s1: number)
		clearStretchGhosts()
		buildGhostStrips(indices, s0, s1, getStyle().WhiteMarking, 0.2, stretchGhosts)
	end

	-- Persistent (not drag-bound) highlight for "Select" mode's pending
	-- toggle set, spanning the whole road so it stays visible before a
	-- range has even been chosen - a distinct amber colour from the
	-- white/style-coloured drag-range ghost above, so "selected but no
	-- range yet" reads differently from "this range is about to apply".
	local function updateSelectGhosts()
		clearStretchSelectGhosts()
		if not originalData then
			return
		end
		local indices = {}
		for index in stretchSelectedIndices do
			table.insert(indices, index)
		end
		buildGhostStrips(indices, 0, originalData.Curve.Length, Color3.fromRGB(255, 196, 64), 0.5, stretchSelectGhosts)
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
		updateStretchGhost(resolvePreviewIndices(stretchDragComponentIndex), stretchDragStartStation, currentStation)
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
		local clickedIndex = stretchDragComponentIndex

		if hi - lo < 1 then
			if stretchSelectionMode == "Select" then
				-- A plain click (no meaningful drag) in Select mode toggles
				-- this boundary's membership in the pending set instead of
				-- cancelling - the eventual range-setting drag can start
				-- from any boundary, selected or not (falls back to just
				-- that one via resolvePreviewIndices if nothing's toggled).
				if stretchSelectedIndices[clickedIndex] then
					stretchSelectedIndices[clickedIndex] = nil
				else
					stretchSelectedIndices[clickedIndex] = true
				end
				updateSelectGhosts()
			end
			-- Too short to be an intentional range drag either way - stay
			-- in PlacingMarkingStretch so a misclick doesn't abort the
			-- whole flow, matching how a near-zero bay drag is silently
			-- ignored rather than committed.
			stretchDragStartStation = nil
			stretchDragComponentIndex = nil
			clearStretchGhosts()
			changeSignal:Fire()
			return
		end

		-- Dash Length/Gap start pre-filled with the region's own current
		-- defaults (not nil) so the confirm panel's number fields always
		-- show a real, editable value instead of a blank/undefined one;
		-- untouched, they simply reproduce the region default exactly, same
		-- as leaving them nil would.
		local style = getStyle()
		stretchDraft = {
			ComponentIndices = resolvePreviewIndices(clickedIndex),
			FromStationStuds = lo,
			ToStationStuds = hi,
			Line = "Solid",
			DashLengthM = style.DashLengthM,
			DashGapM = style.DashGapM,
		}
		stretchDragStartStation = nil
		stretchDragComponentIndex = nil
		stretchSelectedIndices = {}
		clearStretchGhosts()
		clearStretchSelectGhosts()
		for _, connection in stretchConnections do
			connection:Disconnect()
		end
		table.clear(stretchConnections)
		plugin:Deactivate()
		mode = "ConfirmingMarkingStretch"
		changeSignal:Fire()
	end

	-- Ghost strip for a kerb-stretch drag preview, same curve-following
	-- facet-chain approach as buildGhostStrips above but for a single fixed
	-- lateral offset (the kerb line's own position, same convention the bus
	-- bay ghost's kerbOffsetM already uses) instead of a list of
	-- lane-boundary indices.
	local function buildKerbGhostStrips(
		edgeIndex: number,
		s0: number,
		s1: number,
		color: Color3,
		transparency: number,
		into: { Part }
	)
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
		local scale = settings.MetersToStuds
		local style = getStyle()
		local y = 0.15
		local width = math.max(style.MarkingWidthM * scale, 0.3)
		local offsetM = kerbEdgeOffsetM(offsets, edgeIndex)
		local offsetStuds = offsetM * scale
		local segments = math.min(GHOST_MAX_SEGMENTS, math.max(1, math.floor((hi - lo) / 4)))
		for i = 0, segments - 1 do
			local segLo = lo + (hi - lo) * (i / segments)
			local segHi = lo + (hi - lo) * ((i + 1) / segments)
			local frameA = frameAtWithRoll(curve, segLo)
			local frameB = frameAtWithRoll(curve, segHi)
			local pA = (frameA * CFrame.new(offsetStuds, y, 0)).Position
			local pB = (frameB * CFrame.new(offsetStuds, y, 0)).Position
			local segLength = (pB - pA).Magnitude
			if segLength > 1e-3 then
				local ghost = Instance.new("Part")
				ghost.Name = "EasyRoadKerbStretchGhost"
				ghost.Anchored = true
				ghost.CanCollide = false
				ghost.CanQuery = false
				ghost.CanTouch = false
				ghost.CastShadow = false
				ghost.Material = Enum.Material.Neon
				ghost.Color = color
				ghost.Transparency = transparency
				ghost.Size = Vector3.new(width, 0.2, segLength)
				ghost.CFrame = CFrame.lookAt((pA + pB) / 2, pB, frameA.UpVector)
				ghost.Parent = workspace
				table.insert(into, ghost)
			end
		end
	end

	local function updateKerbStretchGhost(edgeIndex: number, s0: number, s1: number)
		clearKerbStretchGhosts()
		buildKerbGhostStrips(edgeIndex, s0, s1, getStyle().YellowMarking, 0.2, kerbStretchGhosts)
	end

	local function onKerbStretchDragBegin()
		if mode ~= "PlacingKerbStretch" or not selectedRoad or not originalData then
			return
		end
		if uiState.Hovered then
			return
		end
		local station = originalData.Curve:ClosestS(mouse.Hit.Position)
		local edgeIndex = resolveKerbEdgeFromHit(station, mouse.Hit.Position)
		if not edgeIndex then
			return
		end
		kerbStretchDragStartStation = station
		kerbStretchDragEdgeIndex = edgeIndex
	end

	local function onKerbStretchDragMove()
		if
			mode ~= "PlacingKerbStretch"
			or not kerbStretchDragStartStation
			or not kerbStretchDragEdgeIndex
			or not originalData
		then
			return
		end
		local currentStation = originalData.Curve:ClosestS(mouse.Hit.Position)
		updateKerbStretchGhost(kerbStretchDragEdgeIndex, kerbStretchDragStartStation, currentStation)
	end

	local function onKerbStretchDragEnd()
		if
			mode ~= "PlacingKerbStretch"
			or not kerbStretchDragStartStation
			or not kerbStretchDragEdgeIndex
			or not originalData
		then
			return
		end
		local currentStation = originalData.Curve:ClosestS(mouse.Hit.Position)
		local lo = math.min(kerbStretchDragStartStation, currentStation)
		local hi = math.max(kerbStretchDragStartStation, currentStation)
		local edgeIndex = kerbStretchDragEdgeIndex

		if hi - lo < 1 then
			-- Too short to be an intentional range drag - stay in
			-- PlacingKerbStretch so a misclick doesn't abort the whole
			-- flow, matching the lane-stretch/bay tools' own near-zero-
			-- drag handling.
			kerbStretchDragStartStation = nil
			kerbStretchDragEdgeIndex = nil
			clearKerbStretchGhosts()
			changeSignal:Fire()
			return
		end

		-- Restriction starts at the road's own current whole-road
		-- KerbRestriction (editing FROM the current state, not an
		-- arbitrary fixed default) - adjustable in the confirm panel.
		local currentRestriction = (editingProfile or originalData.ProfileStart).KerbRestriction or "None"
		kerbStretchDraft = {
			EdgeIndex = edgeIndex,
			FromStationStuds = lo,
			ToStationStuds = hi,
			Restriction = currentRestriction,
		}
		kerbStretchDragStartStation = nil
		kerbStretchDragEdgeIndex = nil
		clearKerbStretchGhosts()
		for _, connection in kerbStretchConnections do
			connection:Disconnect()
		end
		table.clear(kerbStretchConnections)
		plugin:Deactivate()
		mode = "ConfirmingKerbStretch"
		changeSignal:Fire()
	end

	-- Rebuilds the selected road's geometry with the given marking/kerb
	-- stretches (replacing whatever was stamped before for BOTH - always
	-- pass the road's current list back unchanged for whichever one isn't
	-- being touched, or it gets silently wiped), then re-stamps everything -
	-- the same "clone-and-mutate, rebuild as one undo step" pattern
	-- session.Apply/ConfirmBay use, shared here since both the lane-stretch
	-- and kerb-stretch confirm/clear/remove actions need it.
	local function rebuildRoad(
		markingStretches: { Markings.MarkingStretch },
		kerbStretches: { Markings.KerbStretch },
		historyLabel: string
	)
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
			MarkingStretches = if #markingStretches > 0 then markingStretches else nil,
			KerbStretches = if #kerbStretches > 0 then kerbStretches else nil,
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
		RoadInstance.StampModel(road, data.Curve, editingProfile or data.ProfileStart, data.ProfileEnd)
		RoadInstance.StampBay(road, data.Bay)
		RoadInstance.StampMarkingStretches(road, markingStretches)
		RoadInstance.StampKerbStretches(road, kerbStretches)
		RoadInstance.StampStructure(road, data.Structure)
		StructureBuilder.Render(road, data.Curve, data.Structure or StructureBuilder.DefaultData(settings), settings)
		BusStops.Render(road)
		data.MarkingStretches = markingStretches
		data.KerbStretches = kerbStretches
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
		local frameA = frameAtWithRoll(curve, s0)
		local frameB = frameAtWithRoll(curve, s1)
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
		elseif mode == "PlacingKerbStretch" then
			stopKerbStretchPlacement()
		end
		selectedRoad = road
		originalData = if road then RoadInstance.Read(road) else nil
		editingProfile = if originalData then RoadProfile.Clone(originalData.ProfileStart) else nil
		editingStructure = if originalData and originalData.Structure
			then StructureBuilder.CloneData(originalData.Structure)
			else if originalData then StructureBuilder.DefaultData(settings) else nil
		structureStatus = nil
		bayStation = nil
		bayDraft = nil
		stretchDraft = nil
		stretchSelectionMode = "All"
		stretchSelectedIndices = {}
		kerbStretchDraft = nil
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
			elseif
				(mode == "PlacingKerbStretch" or mode == "ConfirmingKerbStretch")
				and Keybinds.Matches(settings.Keybinds.CancelPlacement, input)
			then
				stopKerbStretchPlacement()
			end
		end)
	)
	-- Defensive sweep: destroy any stray ghost Parts already sitting under
	-- workspace from a previous session (an interrupted drag whose cleanup
	-- path didn't run, an older plugin version's bug, ...) rather than
	-- relying purely on every code path getting cleanup exactly right.
	-- Cheap (runs once, at plugin load) and matches the ghost Parts' own
	-- naming exactly, so it can't touch anything else.
	for _, child in workspace:GetChildren() do
		if
			child.Name == "EasyRoadMarkingStretchGhost"
			or child.Name == "EasyRoadBayGhost"
			or child.Name == "EasyRoadKerbStretchGhost"
		then
			child:Destroy()
		end
	end

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

	function session.GetStructure(): RoadInstance.StructureData?
		return editingStructure
	end

	function session.GetStructureAssets(kind: StructureAssets.AssetKind?): { StructureAssets.AssetInfo }
		return StructureAssets.List(kind)
	end

	function session.GetStructureStatus(): string?
		return structureStatus
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
		if a ~= b then
			return true
		end
		local currentStructure = if editingStructure and editingStructure.Mode ~= "None"
			then editingStructure
			else StructureBuilder.DefaultData(settings)
		local storedStructure = originalData.Structure or StructureBuilder.DefaultData(settings)
		return HttpService:JSONEncode(currentStructure) ~= HttpService:JSONEncode(storedStructure)
	end

	function session.SetProfile(newProfile: RoadProfile.RoadProfile)
		editingProfile = newProfile
		changeSignal:Fire()
	end

	function session.SetStructure(structure: RoadInstance.StructureData)
		editingStructure = StructureBuilder.CloneData(structure)
		structureStatus = nil
		changeSignal:Fire()
	end

	function session.Apply()
		if not selectedRoad or not editingProfile or not editingStructure or not originalData then
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
			KerbStretches = if #originalData.KerbStretches > 0 then originalData.KerbStretches else nil,
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
		RoadInstance.StampModel(selectedRoad, originalData.Curve, editingProfile, originalData.ProfileEnd)
		RoadInstance.StampBay(selectedRoad, originalData.Bay)
		RoadInstance.StampMarkingStretches(selectedRoad, originalData.MarkingStretches)
		RoadInstance.StampKerbStretches(selectedRoad, originalData.KerbStretches)
		local appliedStructure = if editingStructure.Mode == "None"
			then nil
			else StructureBuilder.CloneData(editingStructure)
		RoadInstance.StampStructure(selectedRoad, appliedStructure)
		local _, renderMessage = StructureBuilder.Render(selectedRoad, originalData.Curve, editingStructure, settings)
		structureStatus = renderMessage
		BusStops.Render(selectedRoad)
		originalData = {
			Curve = originalData.Curve,
			ProfileStart = RoadProfile.Clone(editingProfile),
			ProfileEnd = originalData.ProfileEnd,
			Bay = originalData.Bay,
			MarkingStretches = originalData.MarkingStretches,
			KerbStretches = originalData.KerbStretches,
			Structure = appliedStructure,
			StartJunctionId = originalData.StartJunctionId,
			EndJunctionId = originalData.EndJunctionId,
		}
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end

	function session.Revert()
		editingProfile = if originalData then RoadProfile.Clone(originalData.ProfileStart) else nil
		editingStructure = if originalData and originalData.Structure
			then StructureBuilder.CloneData(originalData.Structure)
			else if originalData then StructureBuilder.DefaultData(settings) else nil
		structureStatus = nil
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

	function session.IsViewingStretches(): boolean
		return mode == "ViewingStretches"
	end

	function session.OpenStretchesView()
		if mode == "SegmentMenu" then
			mode = "ViewingStretches"
			changeSignal:Fire()
		end
	end

	function session.CloseStretchesView()
		if mode == "ViewingStretches" then
			mode = "SegmentMenu"
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
			KerbStretches = if #originalData.KerbStretches > 0 then originalData.KerbStretches else nil,
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
			originalData.Curve,
			editingProfile or originalData.ProfileStart,
			originalData.ProfileEnd
		)
		RoadInstance.StampBay(selectedRoad, bay)
		RoadInstance.StampMarkingStretches(selectedRoad, originalData.MarkingStretches)
		RoadInstance.StampKerbStretches(selectedRoad, originalData.KerbStretches)
		RoadInstance.StampStructure(selectedRoad, originalData.Structure)
		StructureBuilder.Render(
			selectedRoad,
			originalData.Curve,
			originalData.Structure or StructureBuilder.DefaultData(settings),
			settings
		)
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

	function session.GetMarkingStretchSelectionMode(): "All" | "Individual" | "Select"
		return stretchSelectionMode
	end

	function session.SetMarkingStretchSelectionMode(newMode: "All" | "Individual" | "Select")
		if stretchSelectionMode == newMode then
			return
		end
		stretchSelectionMode = newMode
		stretchSelectedIndices = {}
		clearStretchSelectGhosts()
		changeSignal:Fire()
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

	function session.SetMarkingStretchDraftDashLength(dashLengthM: number)
		if stretchDraft then
			stretchDraft.DashLengthM = math.max(dashLengthM, 0.1)
			changeSignal:Fire()
		end
	end

	function session.SetMarkingStretchDraftDashGap(dashGapM: number)
		if stretchDraft then
			stretchDraft.DashGapM = math.max(dashGapM, 0.1)
			changeSignal:Fire()
		end
	end

	local function intersectIndices(a: { number }, b: { number }): { number }
		local bSet: { [number]: boolean } = {}
		for _, i in b do
			bSet[i] = true
		end
		local result = {}
		for _, i in a do
			if bSet[i] then
				table.insert(result, i)
			end
		end
		return result
	end

	local function subtractIndices(a: { number }, b: { number }): { number }
		local bSet: { [number]: boolean } = {}
		for _, i in b do
			bSet[i] = true
		end
		local result = {}
		for _, i in a do
			if not bSet[i] then
				table.insert(result, i)
			end
		end
		return result
	end

	-- Splices newStretch into existing, overwriting any overlap on shared
	-- boundaries instead of layering both - two stretches covering the
	-- same physical section of the same lane would otherwise fight for
	-- the same markings there (both trying to draw at once). Only the
	-- genuinely overlapping (same boundary AND overlapping station range)
	-- portion of an existing stretch gets carved out: boundaries the new
	-- stretch doesn't touch, and ranges that don't actually overlap, are
	-- left completely alone - two stretches on different lanes, or two
	-- non-overlapping ranges on the same lane, still coexist normally.
	local function applyStretchOverwrite(
		existing: { Markings.MarkingStretch },
		newStretch: Markings.MarkingStretch
	): { Markings.MarkingStretch }
		local result: { Markings.MarkingStretch } = {}
		for _, e in existing do
			local shared = intersectIndices(e.ComponentIndices, newStretch.ComponentIndices)
			local overlaps = #shared > 0
				and e.FromStationStuds < newStretch.ToStationStuds
				and e.ToStationStuds > newStretch.FromStationStuds
			if not overlaps then
				table.insert(result, e)
			else
				local unshared = subtractIndices(e.ComponentIndices, shared)
				if #unshared > 0 then
					table.insert(result, {
						ComponentIndices = unshared,
						FromStationStuds = e.FromStationStuds,
						ToStationStuds = e.ToStationStuds,
						Line = e.Line,
						DashLengthM = e.DashLengthM,
						DashGapM = e.DashGapM,
					})
				end
				if e.FromStationStuds < newStretch.FromStationStuds then
					table.insert(result, {
						ComponentIndices = shared,
						FromStationStuds = e.FromStationStuds,
						ToStationStuds = newStretch.FromStationStuds,
						Line = e.Line,
						DashLengthM = e.DashLengthM,
						DashGapM = e.DashGapM,
					})
				end
				if e.ToStationStuds > newStretch.ToStationStuds then
					table.insert(result, {
						ComponentIndices = shared,
						FromStationStuds = newStretch.ToStationStuds,
						ToStationStuds = e.ToStationStuds,
						Line = e.Line,
						DashLengthM = e.DashLengthM,
						DashGapM = e.DashGapM,
					})
				end
			end
		end
		table.insert(result, newStretch)
		return result
	end

	function session.ConfirmMarkingStretch()
		if mode ~= "ConfirmingMarkingStretch" or not originalData or not stretchDraft then
			return
		end
		local stretches = applyStretchOverwrite(originalData.MarkingStretches, stretchDraft)
		stretchDraft = nil
		mode = "SegmentMenu"
		rebuildRoad(stretches, originalData.KerbStretches, "Stretch marking")
	end

	function session.GetMarkingStretches(): { Markings.MarkingStretch }
		return if originalData then originalData.MarkingStretches else {}
	end

	function session.ClearMarkingStretches()
		if not originalData or #originalData.MarkingStretches == 0 then
			return
		end
		rebuildRoad({}, originalData.KerbStretches, "Clear marking stretches")
	end

	-- Removes a single stretch by its position in GetMarkingStretches()'s
	-- own list (the designer's stretch-management rows pass this straight
	-- back) rather than by identity - the list is plain data round-tripped
	-- through JSON, so there's no stable identity to match on beyond index.
	function session.RemoveMarkingStretch(index: number)
		if not originalData or not originalData.MarkingStretches[index] then
			return
		end
		local stretches = table.clone(originalData.MarkingStretches)
		table.remove(stretches, index)
		rebuildRoad(stretches, originalData.KerbStretches, "Remove marking stretch")
	end

	function session.IsPlacingKerbStretch(): boolean
		return mode == "PlacingKerbStretch"
	end

	function session.StartKerbStretchPlacement()
		if mode ~= "SegmentMenu" or not selectedRoad then
			return
		end
		mode = "PlacingKerbStretch"
		plugin:Activate(true)
		table.insert(kerbStretchConnections, mouse.Button1Down:Connect(onKerbStretchDragBegin))
		table.insert(kerbStretchConnections, mouse.Move:Connect(onKerbStretchDragMove))
		table.insert(kerbStretchConnections, mouse.Button1Up:Connect(onKerbStretchDragEnd))
		changeSignal:Fire()
	end

	session.CancelKerbStretchPlacement = stopKerbStretchPlacement

	function session.IsConfirmingKerbStretch(): boolean
		return mode == "ConfirmingKerbStretch"
	end

	function session.GetKerbStretchDraft(): Markings.KerbStretch?
		return kerbStretchDraft
	end

	function session.SetKerbStretchDraftFrom(studs: number)
		if kerbStretchDraft then
			kerbStretchDraft.FromStationStuds = math.clamp(studs, 0, kerbStretchDraft.ToStationStuds - 1)
			changeSignal:Fire()
		end
	end

	function session.SetKerbStretchDraftTo(studs: number)
		if kerbStretchDraft and originalData then
			kerbStretchDraft.ToStationStuds =
				math.clamp(studs, kerbStretchDraft.FromStationStuds + 1, originalData.Curve.Length)
			changeSignal:Fire()
		end
	end

	function session.SetKerbStretchDraftRestriction(restriction: string)
		if kerbStretchDraft then
			kerbStretchDraft.Restriction = restriction
			changeSignal:Fire()
		end
	end

	-- Overwrites any existing kerb stretch on the SAME edge whose range
	-- overlaps the new one - each EdgeIndex is independent, so there's no
	-- boundary-intersection step like applyStretchOverwrite's (every
	-- stretch on a given edge always "shares" that edge); only the
	-- overlapping sub-range needs splitting/dropping.
	local function applyKerbStretchOverwrite(
		existing: { Markings.KerbStretch },
		newStretch: Markings.KerbStretch
	): { Markings.KerbStretch }
		local result: { Markings.KerbStretch } = {}
		for _, e in existing do
			local overlaps = e.EdgeIndex == newStretch.EdgeIndex
				and e.FromStationStuds < newStretch.ToStationStuds
				and e.ToStationStuds > newStretch.FromStationStuds
			if not overlaps then
				table.insert(result, e)
			else
				if e.FromStationStuds < newStretch.FromStationStuds then
					table.insert(result, {
						EdgeIndex = e.EdgeIndex,
						FromStationStuds = e.FromStationStuds,
						ToStationStuds = newStretch.FromStationStuds,
						Restriction = e.Restriction,
					})
				end
				if e.ToStationStuds > newStretch.ToStationStuds then
					table.insert(result, {
						EdgeIndex = e.EdgeIndex,
						FromStationStuds = newStretch.ToStationStuds,
						ToStationStuds = e.ToStationStuds,
						Restriction = e.Restriction,
					})
				end
			end
		end
		table.insert(result, newStretch)
		return result
	end

	function session.ConfirmKerbStretch()
		if mode ~= "ConfirmingKerbStretch" or not originalData or not kerbStretchDraft then
			return
		end
		local stretches = applyKerbStretchOverwrite(originalData.KerbStretches, kerbStretchDraft)
		kerbStretchDraft = nil
		mode = "SegmentMenu"
		rebuildRoad(originalData.MarkingStretches, stretches, "Stretch kerb marking")
	end

	function session.GetKerbStretches(): { Markings.KerbStretch }
		return if originalData then originalData.KerbStretches else {}
	end

	function session.ClearKerbStretches()
		if not originalData or #originalData.KerbStretches == 0 then
			return
		end
		rebuildRoad(originalData.MarkingStretches, {}, "Clear kerb stretches")
	end

	function session.RemoveKerbStretch(index: number)
		if not originalData or not originalData.KerbStretches[index] then
			return
		end
		local stretches = table.clone(originalData.KerbStretches)
		table.remove(stretches, index)
		rebuildRoad(originalData.MarkingStretches, stretches, "Remove kerb stretch")
	end

	function session.GetAnchorWorldPosition(): Vector3?
		if not originalData then
			return nil
		end
		local curve = originalData.Curve
		return curve:PosAt(curve.Length / 2)
	end

	-- "End" continues in the curve's own forward direction from its far tip
	-- (the original, only behaviour "Place More" had); "Start" continues
	-- from the near tip instead, in the OPPOSITE direction (the curve's
	-- tangent at station 0 points forward INTO the existing road, so a new
	-- segment built from there has to point the other way to extend the
	-- network outward rather than back over the road that's already there).
	function session.GetContinuation(fromEnd: "Start" | "End"): Continuation?
		if not originalData then
			return nil
		end
		local curve = originalData.Curve
		if fromEnd == "Start" then
			local profile = originalData.ProfileStart or originalData.ProfileEnd
			return {
				Position = curve:PosAt(0),
				Tangent = -curve:TangentAt(0),
				Profile = RoadProfile.Clone(profile),
			}
		end
		local profile = originalData.ProfileEnd or originalData.ProfileStart
		return {
			Position = curve:PosAt(curve.Length),
			Tangent = curve:TangentAt(curve.Length),
			Profile = RoadProfile.Clone(profile),
		}
	end

	function session.Destroy()
		if mode == "PlacingBay" or mode == "PlacingMarkingStretch" or mode == "PlacingKerbStretch" then
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
		clearStretchSelectGhosts()
		for _, connection in kerbStretchConnections do
			connection:Disconnect()
		end
		table.clear(kerbStretchConnections)
		clearKerbStretchGhosts()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		changeSignal:DisconnectAll()
	end

	return session
end

return createRoadEditSession
