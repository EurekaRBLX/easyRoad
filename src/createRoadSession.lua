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
-- Keyboard: R / F raise and lower the placement elevation, Escape or
-- right-click cancels the current placement (and then the chain).

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Packages = script.Parent.Parent.Packages
local Signal = require(Packages.Signal)

local CurveSegment = require("./Geometry/CurveSegment")
local PolyCurve = require("./Geometry/PolyCurve")
local Fitting = require("./Geometry/Fitting")
local RoadBuilder = require("./Mesh/RoadBuilder")
local RoadProfile = require("./RoadProfile")
local RegionStyles = require("./RegionStyles")
local Settings = require("./Settings")

export type ToolMode = "Straight" | "Curve" | "Freeform"

export type RoadSession = {
	ChangeSignal: Signal.Signal<>,
	SetToolMode: (mode: ToolMode) -> (),
	GetToolMode: () -> ToolMode,
	SetProfile: (profile: RoadProfile.RoadProfile) -> (),
	GetProfile: () -> RoadProfile.RoadProfile,
	SetEndProfile: (profile: RoadProfile.RoadProfile?) -> (),
	GetEndProfile: () -> RoadProfile.RoadProfile?,
	GetElevation: () -> number,
	GetHint: () -> string,
	GetPointCount: () -> number,
	CancelPlacement: () -> (),
	Destroy: () -> (),
}

local ROADS_FOLDER_NAME = "Roads"
local PREVIEW_REBUILD_INTERVAL = 0.05

local function createRoadSession(
	plugin: Plugin,
	settings: Settings.EasyRoadSettings,
	getStyle: () -> RegionStyles.RegionStyle,
	initialProfile: RoadProfile.RoadProfile
): RoadSession
	local changeSignal = Signal.new()

	local toolMode: ToolMode = "Curve"
	local profile = initialProfile
	local endProfile: RoadProfile.RoadProfile? = nil

	local points: { Vector3 } = {}
	local lockedTangent: Vector3? = nil
	local hoverPos: Vector3? = nil
	local elevation = 0

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
		local base = if toolMode == "Straight" then 2
			elseif toolMode == "Curve" then 3
			else 4
		if lockedTangent and toolMode ~= "Straight" then
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

	-- Input handling ----------------------------------------------------------------------

	local function onClick()
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
	table.insert(connections, mouse.Button2Down:Connect(cancelPlacement))
	table.insert(connections, mouse.Move:Connect(function()
		local ground = raycastGround()
		if ground then
			if #points == 0 then
				local snapPos = findEndpointSnap(ground)
				hoverPos = snapPos or (applyGridSnap(ground) + Vector3.new(0, elevation, 0))
			else
				hoverPos = applyGridSnap(ground) + Vector3.new(0, elevation, 0)
			end
			previewDirty = true
		end
	end))

	table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.R then
			elevation += settings.ElevationStepStuds
			previewDirty = true
			changeSignal:Fire()
		elseif input.KeyCode == Enum.KeyCode.F then
			elevation -= settings.ElevationStepStuds
			previewDirty = true
			changeSignal:Fire()
		elseif input.KeyCode == Enum.KeyCode.Escape then
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

	function session.GetPointCount(): number
		return #points
	end

	function session.GetHint(): string
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

	return session
end

return createRoadSession
