--!strict
-- The interactive road placement session.
--
-- Cities: Skylines style click-to-place flow:
--   * Straight tool: click start, click end
--   * Curve tool:    click start, click guide (tangent control), click end
--   * Freeform tool: click start, click two controls, click end
--
-- When the start point snaps to the endpoint of an existing road, the start
-- tangent is locked for a smooth continuation and the tools need one fewer
-- guide click. After committing a road, placement chains: the next road
-- starts at the end of the one just placed with its tangent locked.
--
-- Keyboard: R / F raise and lower the placement elevation (rebindable),
-- Escape or middle-click cancels the current placement (and then the
-- chain) - also rebindable, see Keybinds.lua.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Packages = script.Parent.Parent.Packages
local Signal = require(Packages.Signal)

local CurveSegment = require("./Geometry/CurveSegment")
local PolyCurve = require("./Geometry/PolyCurve")
local Fitting = require("./Geometry/Fitting")
local RoadBuilder = require("./Mesh/RoadBuilder")
local JunctionBuilder = require("./Mesh/JunctionBuilder")
local RoundaboutBuilder = require("./Mesh/RoundaboutBuilder")
local RoadProfile = require("./RoadProfile")
local RoadInstance = require("./RoadInstance")
local RoadSplit = require("./RoadSplit")
local JunctionInstance = require("./JunctionInstance")
local RegionStyles = require("./RegionStyles")
local Settings = require("./Settings")
local Keybinds = require("./Keybinds")

-- "Roundabout" is a single-click placement (centre point only, no curve) -
-- drops a standalone ring straight from Road Tools instead of requiring an
-- existing junction to already exist and be selected first (the only way
-- to build one before this). Any road drawn to cross it afterwards still
-- won't auto-connect to it (see RoundaboutBuilder.lua's header - the ring
-- isn't wired into the junction/split data model yet), same limitation the
-- junction-panel "Make Roundabout" flow already has.
export type ToolMode = "Straight" | "Curve" | "Freeform" | "Roundabout"

export type RoadSession = {
	ChangeSignal: Signal.Signal<>,
	SetToolMode: (mode: ToolMode) -> (),
	GetToolMode: () -> ToolMode,
	SetProfile: (profile: RoadProfile.RoadProfile) -> (),
	GetProfile: () -> RoadProfile.RoadProfile,
	SetEndProfile: (profile: RoadProfile.RoadProfile?) -> (),
	GetEndProfile: () -> RoadProfile.RoadProfile?,
	GetElevation: () -> number,
	AdjustElevation: (delta: number) -> (),
	SetElevation: (value: number) -> (),
	GetRoundaboutRadius: () -> number,
	SetRoundaboutRadius: (value: number) -> (),
	GetRoundaboutLaneCount: () -> number,
	SetRoundaboutLaneCount: (value: number) -> (),
	GetRoundaboutLaneWidth: () -> number,
	SetRoundaboutLaneWidth: (value: number) -> (),
	GetHint: () -> string,
	GetPointCount: () -> number,
	CancelPlacement: () -> (),
	Destroy: () -> (),
}

local ROADS_FOLDER_NAME = "Roads"
local PREVIEW_REBUILD_INTERVAL = 0.05

export type UiState = {
	Hovered: boolean,
}

-- Continues from an exact existing point/tangent (e.g. "Place More" on an
-- already-placed road) instead of starting a fresh placement from scratch -
-- the same state the session is already in right after committing a road.
export type SessionSeed = {
	Position: Vector3,
	Tangent: Vector3,
}

local function createRoadSession(
	plugin: Plugin,
	settings: Settings.EasyRoadSettings,
	getStyle: () -> RegionStyles.RegionStyle,
	initialProfile: RoadProfile.RoadProfile,
	uiState: UiState?,
	seed: SessionSeed?
): RoadSession
	local changeSignal = Signal.new()

	local toolMode: ToolMode = "Curve"
	local profile = initialProfile
	local endProfile: RoadProfile.RoadProfile? = nil

	local points: { Vector3 } = if seed then { seed.Position } else {}
	local lockedTangent: Vector3? = if seed then seed.Tangent else nil
	local hoverPos: Vector3? = nil
	-- The raw ground point (pre grid-snap, pre elevation) from the last
	-- mouse-move raycast - kept so adjustElevation/setElevation can rebuild
	-- hoverPos immediately using the CURRENT elevation without waiting for
	-- another mouse-move event, which only fires on actual cursor motion
	-- (typing a new value into the elevation textbox, or pressing R/F while
	-- the mouse sits still, doesn't move the mouse).
	local lastGroundPos: Vector3? = nil
	-- Remembers where the user left off instead of always resetting to
	-- ground level on a fresh session.
	local elevation = settings.LastElevationStuds

	-- Config for the "Roundabout" tool mode's single-click placement -
	-- same defaults JunctionPanel's "Make Roundabout" fields start at.
	local roundaboutRadiusStuds = 30
	local roundaboutLaneCount = 1
	local roundaboutLaneWidthM = 3.65

	local previewModel: Model? = nil
	local markerFolder: Folder? = nil
	local previewDirty = false
	local lastPreviewTime = 0

	local connections: { RBXScriptConnection } = {}

	plugin:Activate(true)
	local mouse = plugin:GetMouse()

	-- Ground picking -------------------------------------------------------------

	local function getRoadsFolder(create: boolean): Folder?
		local existing = workspace:FindFirstChild(ROADS_FOLDER_NAME)
		if existing and existing:IsA("Folder") then
			return existing
		end
		if create then
			local folder = Instance.new("Folder")
			folder.Name = ROADS_FOLDER_NAME
			folder.Parent = workspace
			return folder
		end
		return nil
	end

	-- Ground-picking deliberately ignores existing roads/junctions (crossing
	-- over one is allowed by default, not something to route around) - the
	-- old behaviour of hitting an existing road's own deck instead of the
	-- terrain beneath it made a new placement silently "stack" on top of
	-- whatever it crossed. Mid-network crossings are now handled properly
	-- by the junction/split system (see RoadSplit.lua), and elevation is
	-- already an explicit, separate control (R/F keys, the elevation
	-- field) for the cases that genuinely want a different height.
	local function raycastGround(): Vector3?
		local unitRay = mouse.UnitRay
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local excluded: { Instance } = {}
		if previewModel then
			table.insert(excluded, previewModel)
		end
		if markerFolder then
			table.insert(excluded, markerFolder)
		end
		local roadsFolder = getRoadsFolder(false)
		if roadsFolder then
			table.insert(excluded, roadsFolder)
		end
		local junctionsFolder = workspace:FindFirstChild("Junctions")
		if junctionsFolder then
			table.insert(excluded, junctionsFolder)
		end
		params.FilterDescendantsInstances = excluded
		local result = workspace:Raycast(unitRay.Origin, unitRay.Direction * 10000, params)
		if result then
			return result.Position
		end
		-- Fall back to intersecting the Y=0 plane
		local origin = unitRay.Origin
		local direction = unitRay.Direction
		if math.abs(direction.Y) < 1e-6 then
			return nil
		end
		local t = -origin.Y / direction.Y
		if t < 0 or t > 10000 then
			return nil
		end
		return origin + direction * t
	end

	local function findEndpointSnap(pos: Vector3): (Vector3?, Vector3?)
		if not settings.SnapToRoad then
			return nil, nil
		end
		local folder = getRoadsFolder(false)
		if not folder then
			return nil, nil
		end
		local bestDistance = settings.SnapRadiusStuds
		local bestPos: Vector3? = nil
		local bestTangent: Vector3? = nil
		for _, child in folder:GetChildren() do
			if child:GetAttribute("RW_Road") ~= true then
				continue
			end
			local startPos = child:GetAttribute("RW_StartPos") :: Vector3?
			local endPos = child:GetAttribute("RW_EndPos") :: Vector3?
			local startTan = child:GetAttribute("RW_StartTan") :: Vector3?
			local endTan = child:GetAttribute("RW_EndTan") :: Vector3?
			if endPos and endTan then
				local d = (endPos - pos).Magnitude
				if d < bestDistance then
					bestDistance = d
					bestPos = endPos
					bestTangent = endTan -- Outgoing continuation direction
				end
			end
			if startPos and startTan then
				local d = (startPos - pos).Magnitude
				if d < bestDistance then
					bestDistance = d
					bestPos = startPos
					bestTangent = -startTan -- Continue backwards out of the start
				end
			end
		end
		return bestPos, bestTangent
	end

	-- Finds an existing road (other than `exclude`) whose start or end lies
	-- within snap radius of `pos` - used after committing a new road to
	-- decide whether its own start/end should be linked into a JunctionNode.
	-- A separate, simpler pass from findEndpointSnap above (which only
	-- guides the click position/tangent while still placing): this one runs
	-- after the fact and doesn't care about tangents, just "is there another
	-- road's endpoint right here" - so it applies uniformly regardless of
	-- whether the new road's point got there via a click-time snap or a
	-- chained/seeded continuation.
	local function findConnectableEndpoint(pos: Vector3, exclude: Model): (Model?, ("Start" | "End")?)
		if not settings.SnapToRoad then
			return nil, nil
		end
		local folder = getRoadsFolder(false)
		if not folder then
			return nil, nil
		end
		local bestDistance = settings.SnapRadiusStuds
		local bestModel: Model? = nil
		local bestEnd: ("Start" | "End")? = nil
		for _, child in folder:GetChildren() do
			if child == exclude or child:GetAttribute("RW_Road") ~= true then
				continue
			end
			local startPos = child:GetAttribute("RW_StartPos") :: Vector3?
			local endPos = child:GetAttribute("RW_EndPos") :: Vector3?
			if startPos then
				local d = (startPos - pos).Magnitude
				if d < bestDistance then
					bestDistance = d
					bestModel = child :: Model
					bestEnd = "Start"
				end
			end
			if endPos then
				local d = (endPos - pos).Magnitude
				if d < bestDistance then
					bestDistance = d
					bestModel = child :: Model
					bestEnd = "End"
				end
			end
		end
		return bestModel, bestEnd
	end

	-- Stamps `junctionId` onto just one end of `m`, reading its current
	-- attributes fresh so the OTHER end's existing link (if any) is
	-- preserved rather than clobbered - shared by connectAt and the
	-- mid-span split path below, both of which only ever touch one end at
	-- a time even when called more than once for the same model.
	local function stampEndJunction(m: Model, whichEnd: "Start" | "End", junctionId: string)
		local data = RoadInstance.Read(m)
		local startId = if whichEnd == "Start" then junctionId elseif data then data.StartJunctionId else nil
		local endId = if whichEnd == "End" then junctionId elseif data then data.EndJunctionId else nil
		RoadInstance.StampJunctions(m, startId, endId)
	end

	-- Links `model`'s given end (and, if provided, `otherModel`'s
	-- `otherEnd`) to whatever JunctionNode already sits at `pos`, reusing
	-- one within snap radius so repeated connections at the same corner
	-- don't stack duplicate nodes, creating a fresh one otherwise - then
	-- rebuilds that junction's pad.
	local function connectAt(
		pos: Vector3,
		model: Model,
		modelEnd: "Start" | "End",
		otherModel: Model?,
		otherEnd: ("Start" | "End")?
	)
		local junctionModel = JunctionInstance.FindNear(pos, settings.SnapRadiusStuds) or JunctionInstance.Create(pos)
		local junctionData = JunctionInstance.Read(junctionModel)
		if not junctionData then
			return
		end
		stampEndJunction(model, modelEnd, junctionData.Id)
		if otherModel and otherEnd then
			stampEndJunction(otherModel, otherEnd, junctionData.Id)
		end
		JunctionBuilder.Rebuild(junctionData.Id, getStyle(), settings)
	end

	-- Finds the closest point on any OTHER splittable road's curve to
	-- `pos`, within a tolerance that scales with that road's own width (so
	-- clicking anywhere on its visible pavement counts as "connect here,"
	-- not just within a fixed small radius of its exact centerline) - the
	-- fallback when neither endpoint matched (findConnectableEndpoint
	-- above), so a new road drawn crossing an existing one mid-span can
	-- still connect to it instead of silently overlapping with no
	-- relationship at all.
	local function findMidSpanMatch(pos: Vector3, exclude: Model): (Model?, number?)
		if not settings.SnapToRoad then
			return nil, nil
		end
		local folder = getRoadsFolder(false)
		if not folder then
			return nil, nil
		end
		local best: Model? = nil
		local bestStation: number? = nil
		local bestDistance = math.huge
		for _, child in folder:GetChildren() do
			if child == exclude or child:GetAttribute("RW_Road") ~= true then
				continue
			end
			if not RoadSplit.CanSplit(child) then
				continue
			end
			local data = RoadInstance.Read(child)
			if not data then
				continue
			end
			local station = data.Curve:ClosestS(pos)
			local distance = (data.Curve:PosAt(station) - pos).Magnitude
			local tolerance = RoadProfile.TotalWidthM(data.ProfileStart) / 2 * settings.MetersToStuds
				+ settings.SnapRadiusStuds
			if distance < tolerance and distance < bestDistance then
				bestDistance = distance
				best = child :: Model
				bestStation = station
			end
		end
		return best, bestStation
	end

	-- Splits `road` at `station` and links `model`'s given end to the fresh
	-- junction created there - the mid-span counterpart of connectAt above.
	local function connectAtSplit(road: Model, station: number, model: Model, modelEnd: "Start" | "End")
		local _, _, junctionId = RoadSplit.SplitAt(road, station, getStyle(), settings)
		if not junctionId then
			return
		end
		stampEndJunction(model, modelEnd, junctionId)
		JunctionBuilder.Rebuild(junctionId, getStyle(), settings)
	end

	local function applyGridSnap(pos: Vector3): Vector3
		if not settings.SnapToGrid or settings.GridSizeStuds <= 0 then
			return pos
		end
		local grid = settings.GridSizeStuds
		return Vector3.new(
			math.round(pos.X / grid) * grid,
			pos.Y,
			math.round(pos.Z / grid) * grid
		)
	end

	-- Recomputes hoverPos from the last known ground point using whatever
	-- elevation is current right now - shared by the mouse-move handler and
	-- by adjustElevation/setElevation below, so a height change is visible
	-- immediately instead of only on the next physical mouse movement.
	local function refreshHoverPos()
		local ground = lastGroundPos
		if not ground then
			return
		end
		if #points == 0 then
			local snapPos = findEndpointSnap(ground)
			hoverPos = snapPos or (applyGridSnap(ground) + Vector3.new(0, elevation, 0))
		else
			hoverPos = applyGridSnap(ground) + Vector3.new(0, elevation, 0)
		end
		previewDirty = true
	end

	-- Shared by the R/F keys and the build bar's up/down elevation buttons:
	-- whichever point is placed next gets whatever elevation is current at
	-- the moment it's clicked.
	local function adjustElevation(delta: number)
		elevation += delta
		settings.LastElevationStuds = elevation
		refreshHoverPos()
		changeSignal:Fire()
	end

	-- Direct entry from the build bar's elevation textbox (typing a height
	-- instead of nudging it by ElevationStepStuds).
	local function setElevation(value: number)
		elevation = value
		settings.LastElevationStuds = elevation
		refreshHoverPos()
		changeSignal:Fire()
	end

	local function pickPoint(): (Vector3?, Vector3?)
		local ground = raycastGround()
		if not ground then
			return nil, nil
		end
		-- Endpoint snapping only applies to the first point of a placement
		if #points == 0 then
			local snapPos, snapTangent = findEndpointSnap(ground)
			if snapPos then
				return snapPos, snapTangent
			end
		end
		local snapped = applyGridSnap(ground)
		return snapped + Vector3.new(0, elevation, 0), nil
	end

	-- Curve construction -----------------------------------------------------------

	local function clicksNeeded(): number
		local base = if toolMode == "Straight"
			then 2
			elseif toolMode == "Curve" then 3
			elseif toolMode == "Freeform" then 4
			else 1 -- Roundabout: a single centre click, handled separately in onClick
		if lockedTangent and toolMode ~= "Straight" and toolMode ~= "Roundabout" then
			return base - 1
		end
		return base
	end

	-- Build the segment from placed points plus an optional pending point
	local function buildSegment(pending: Vector3?): CurveSegment.Segment?
		local pts = table.clone(points)
		if pending then
			table.insert(pts, pending)
		end
		if #pts < 2 then
			return nil
		end
		local tangent = lockedTangent

		if toolMode == "Straight" then
			if tangent then
				return Fitting.StraightFromTangent(pts[1], tangent, pts[#pts])
			end
			return Fitting.Straight(pts[1], pts[2])
		elseif toolMode == "Curve" then
			if tangent then
				return Fitting.CurveFromTangent(pts[1], tangent, pts[2])
			end
			if #pts >= 3 then
				return Fitting.Curve(pts[1], pts[2], pts[3])
			end
			-- Only start + guide so far: preview a straight toward the guide
			return Fitting.Straight(pts[1], pts[2])
		else -- Freeform
			if tangent then
				if #pts >= 3 then
					local control1 = pts[1] + tangent.Unit * ((pts[3] - pts[1]).Magnitude / 3)
					return Fitting.Freeform(pts[1], control1, pts[2], pts[3])
				end
				return Fitting.CurveFromTangent(pts[1], tangent, pts[2])
			end
			if #pts >= 4 then
				return Fitting.Freeform(pts[1], pts[2], pts[3], pts[4])
			elseif #pts == 3 then
				return Fitting.Curve(pts[1], pts[2], pts[3])
			end
			return Fitting.Straight(pts[1], pts[2])
		end
	end

	-- Preview ------------------------------------------------------------------------

	local function destroyPreview()
		if previewModel then
			previewModel:Destroy()
			previewModel = nil
		end
	end

	local function updateMarkers()
		if markerFolder then
			markerFolder:Destroy()
			markerFolder = nil
		end
		if #points == 0 then
			return
		end
		local folder = Instance.new("Folder")
		folder.Name = "EasyRoadMarkers"
		folder.Archivable = false
		for _, point in points do
			local marker = Instance.new("Part")
			marker.Shape = Enum.PartType.Ball
			marker.Size = Vector3.new(2, 2, 2)
			marker.Color = Color3.fromRGB(0, 162, 255)
			marker.Material = Enum.Material.Neon
			marker.Anchored = true
			marker.CanCollide = false
			marker.CanQuery = false
			marker.CanTouch = false
			marker.Position = point
			marker.Parent = folder
		end
		folder.Parent = workspace
		markerFolder = folder
	end

	local function rebuildPreview()
		local segment = buildSegment(hoverPos)
		if not segment then
			destroyPreview()
			return
		end
		-- Build the replacement BEFORE destroying the old ghost: no flicker
		-- between rebuilds, and if the build errors on degenerate geometry
		-- the previous preview stays on screen instead of vanishing.
		local ok, model = pcall(RoadBuilder.Build, {
			Curve = PolyCurve.new({ segment }),
			ProfileStart = profile,
			ProfileEnd = endProfile,
			Style = getStyle(),
			Settings = settings,
			Preview = true,
		})
		if not ok then
			return
		end
		destroyPreview()
		model.Archivable = false
		model.Parent = workspace
		previewModel = model
	end

	-- Commit ---------------------------------------------------------------------------

	local function commitRoad(segment: CurveSegment.Segment)
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadPlace", "Place road")
		local curve = PolyCurve.new({ segment })
		local model = RoadBuilder.Build({
			Curve = curve,
			ProfileStart = profile,
			ProfileEnd = endProfile,
			Style = getStyle(),
			Settings = settings,
			Preview = false,
		})
		model.Parent = getRoadsFolder(true)

		local startPos = curve:PosAt(0)
		local endPos = curve:PosAt(curve.Length)
		local otherAtStart, otherStartEnd = findConnectableEndpoint(startPos, model)
		if otherAtStart then
			connectAt(startPos, model, "Start", otherAtStart, otherStartEnd)
		else
			local midRoad, midStation = findMidSpanMatch(startPos, model)
			if midRoad and midStation then
				connectAtSplit(midRoad, midStation, model, "Start")
			end
		end
		local otherAtEnd, otherEndEnd = findConnectableEndpoint(endPos, model)
		if otherAtEnd then
			connectAt(endPos, model, "End", otherAtEnd, otherEndEnd)
		else
			local midRoad, midStation = findMidSpanMatch(endPos, model)
			if midRoad and midStation then
				connectAtSplit(midRoad, midStation, model, "End")
			end
		end

		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end

		-- Chain: continue building from the end of the road just placed. A
		-- transition segment arrives at its end profile, so the chain
		-- continues with that profile.
		if endProfile then
			profile = endProfile
			endProfile = nil
		end
		points = { curve:PosAt(curve.Length) }
		lockedTangent = curve:TangentAt(curve.Length)
		updateMarkers()
		previewDirty = true
		changeSignal:Fire()
	end

	-- Places a standalone roundabout ring centred at `center` (ground click,
	-- grid-snapped, elevated) using the current radius/lane config - no
	-- multi-click curve fitting involved, unlike the other tool modes.
	local function commitRoundabout(center: Vector3)
		local recording = ChangeHistoryService:TryBeginRecording("EasyRoadPlace", "Place roundabout")
		RoundaboutBuilder.Create(
			center,
			roundaboutRadiusStuds,
			roundaboutLaneCount,
			roundaboutLaneWidthM,
			getStyle(),
			settings
		)
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		changeSignal:Fire()
	end

	-- Input handling ----------------------------------------------------------------------

	local function onClick()
		-- Clicks on the viewport HUD must not also place road points
		if uiState and uiState.Hovered then
			return
		end
		if toolMode == "Roundabout" then
			-- A roundabout's centre point isn't a road endpoint, so this
			-- deliberately bypasses pickPoint's findEndpointSnap - just
			-- ground/grid/elevation, the same as any other new point.
			local ground = raycastGround()
			if not ground then
				return
			end
			commitRoundabout(applyGridSnap(ground) + Vector3.new(0, elevation, 0))
			return
		end
		local point, snapTangent = pickPoint()
		if not point then
			return
		end
		if #points == 0 and snapTangent then
			lockedTangent = snapTangent
		end
		table.insert(points, point)
		updateMarkers()

		if #points >= clicksNeeded() then
			local segment = buildSegment(nil)
			if segment and segment.Length > 1 then
				commitRoad(segment)
			else
				-- Degenerate (double click in place): drop the last point
				table.remove(points)
			end
		end
		previewDirty = true
		changeSignal:Fire()
	end

	local function cancelPlacement()
		points = {}
		lockedTangent = nil
		updateMarkers()
		destroyPreview()
		previewDirty = false
		changeSignal:Fire()
	end

	table.insert(connections, mouse.Button1Down:Connect(onClick))
	table.insert(connections, mouse.Move:Connect(function()
		local ground = raycastGround()
		if ground then
			lastGroundPos = ground
			refreshHoverPos()
		end
	end))

	-- Rebindable via the Keybinds settings dock (src/Keybinds.lua); each
	-- action can have multiple bound inputs (Cancel Placement defaults to
	-- Escape and middle-click - right-click is deliberately not a default
	-- since it also doubles as Studio's camera-orbit gesture, but can be
	-- added manually).
	table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		local binds = settings.Keybinds
		if Keybinds.Matches(binds.ElevationUp, input) then
			adjustElevation(settings.ElevationStepStuds)
		elseif Keybinds.Matches(binds.ElevationDown, input) then
			adjustElevation(-settings.ElevationStepStuds)
		elseif Keybinds.Matches(binds.CancelPlacement, input) then
			cancelPlacement()
		end
	end))

	table.insert(connections, RunService.Heartbeat:Connect(function()
		if not previewDirty then
			return
		end
		local now = os.clock()
		if now - lastPreviewTime < PREVIEW_REBUILD_INTERVAL then
			return
		end
		lastPreviewTime = now
		previewDirty = false
		if #points > 0 then
			rebuildPreview()
		else
			destroyPreview()
		end
	end))

	-- Public interface ---------------------------------------------------------------------

	local session = {} :: RoadSession
	session.ChangeSignal = changeSignal

	function session.SetToolMode(mode: ToolMode)
		if toolMode ~= mode then
			toolMode = mode
			-- Keep the start point (and locked tangent) but drop guide points,
			-- since their meaning differs between tools.
			if #points > 1 then
				points = { points[1] }
			end
			updateMarkers()
			previewDirty = true
			changeSignal:Fire()
		end
	end

	function session.GetToolMode(): ToolMode
		return toolMode
	end

	function session.SetProfile(newProfile: RoadProfile.RoadProfile)
		profile = newProfile
		previewDirty = true
		changeSignal:Fire()
	end

	function session.GetProfile(): RoadProfile.RoadProfile
		return profile
	end

	function session.SetEndProfile(newProfile: RoadProfile.RoadProfile?)
		endProfile = newProfile
		previewDirty = true
		changeSignal:Fire()
	end

	function session.GetEndProfile(): RoadProfile.RoadProfile?
		return endProfile
	end

	function session.GetElevation(): number
		return elevation
	end

	session.AdjustElevation = adjustElevation
	session.SetElevation = setElevation

	function session.GetRoundaboutRadius(): number
		return roundaboutRadiusStuds
	end
	function session.SetRoundaboutRadius(value: number)
		roundaboutRadiusStuds = value
		changeSignal:Fire()
	end
	function session.GetRoundaboutLaneCount(): number
		return roundaboutLaneCount
	end
	function session.SetRoundaboutLaneCount(value: number)
		roundaboutLaneCount = value
		changeSignal:Fire()
	end
	function session.GetRoundaboutLaneWidth(): number
		return roundaboutLaneWidthM
	end
	function session.SetRoundaboutLaneWidth(value: number)
		roundaboutLaneWidthM = value
		changeSignal:Fire()
	end

	function session.GetPointCount(): number
		return #points
	end

	function session.GetHint(): string
		if toolMode == "Roundabout" then
			return "Click to place the roundabout's centre"
		end
		local count = #points
		local needed = clicksNeeded()
		if count == 0 then
			return "Click to place the start point (snaps to existing road ends)"
		elseif count == needed - 1 then
			return "Click to place the end point"
		else
			return "Click to place a guide point"
		end
	end

	session.CancelPlacement = cancelPlacement

	function session.Destroy()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		destroyPreview()
		if markerFolder then
			markerFolder:Destroy()
			markerFolder = nil
		end
		changeSignal:DisconnectAll()
	end

	if seed then
		updateMarkers()
		previewDirty = true
	end

	return session
end

return createRoadSession
