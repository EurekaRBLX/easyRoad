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

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Packages = script.Parent.Parent.Packages
local Signal = require(Packages.Signal)

local History = require("./History")
local CurveSegment = require("./Geometry/CurveSegment")
local PolyCurve = require("./Geometry/PolyCurve")
local CurveIntersections = require("./Geometry/CurveIntersections")
local Fitting = require("./Geometry/Fitting")
local RoadBuilder = require("./Mesh/RoadBuilder")
local JunctionBuilder = require("./Mesh/JunctionBuilder")
local RoundaboutBuilder = require("./Mesh/RoundaboutBuilder")
local RoadProfile = require("./RoadProfile")
local RoadInstance = require("./RoadInstance")
local StructureAssets = require("./StructureAssets")
local StructureBuilder = require("./StructureBuilder")
local RoadSplit = require("./RoadSplit")
local JunctionInstance = require("./JunctionInstance")
local RegionStyles = require("./RegionStyles")
local Settings = require("./Settings")
local Keybinds = require("./Keybinds")
local Superelevation = require("./Geometry/Superelevation")

-- "Roundabout" is a single-click placement (centre point only, no curve) -
-- drops a standalone ring straight from Road Tools instead of requiring an
-- existing junction to already exist and be selected first. Roads can snap
-- onto a placed ring's outer rim (RoundaboutBuilder.FindNear) and attach as
-- spokes via ConnectRoad after commit.
export type ToolMode = "Straight" | "Curve" | "Freeform" | "Roundabout"

export type ParallelConfig = {
	Enabled: boolean,
	Count: number,
	GapM: number,
	OppositeDirections: boolean,
	ReverseByIndex: { boolean },
}

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
	GetStructure: () -> RoadInstance.StructureData,
	SetStructure: (structure: RoadInstance.StructureData) -> (),
	GetStructureAssets: (kind: StructureAssets.AssetKind?) -> { StructureAssets.AssetInfo },
	GetStructureStatus: () -> string?,
	GetParallel: () -> ParallelConfig,
	SetParallel: (config: ParallelConfig) -> (),
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
local MIN_AT_GRADE_SEPARATION_STUDS = 2

export type UiState = {
	Hovered: boolean,
}

type CrossingCandidate = {
	Road: Model,
	NewStation: number,
	RoadStation: number,
	Position: Vector3,
	CanCreate: boolean,
	Reason: string?,
}

type PreparedCrossing = {
	Candidate: CrossingCandidate,
	JunctionId: string,
	JunctionModel: Model,
}

-- A magnetic placement point and the centreline identity it belongs to are
-- deliberately separate. Left/right roadway-edge snapping moves the visible
-- endpoint laterally, but a split or junction must still be made at the
-- target road's real centreline station.
type SnapMatch = {
	Kind: "RoadEndpoint" | "RoadMidSpan" | "Junction" | "Roundabout",
	Position: Vector3,
	TopologyPosition: Vector3,
	Tangent: Vector3?,
	Road: Model?,
	RoadEnd: ("Start" | "End")?,
	Station: number?,
	Junction: Model?,
	Ring: Model?,
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
	local pointSnapMatches: { [number]: SnapMatch } = {}
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
	-- Structure mode is part of the live placement tool, not something the
	-- user must discover after placing and reopening a road. It persists for
	-- the whole chain so consecutive viaduct/tunnel segments match.
	local structure = StructureBuilder.DefaultData(settings)
	local structureStatus: string? = nil
	local parallel: ParallelConfig = {
		Enabled = false,
		Count = 2,
		GapM = settings.ParallelRoadwayGapM,
		OppositeDirections = true,
		ReverseByIndex = {},
	}

	local function cloneParallel(config: ParallelConfig): ParallelConfig
		return {
			Enabled = config.Enabled,
			Count = math.clamp(math.floor(config.Count), 2, 16),
			GapM = math.max(config.GapM, 0),
			OppositeDirections = config.OppositeDirections,
			ReverseByIndex = table.clone(config.ReverseByIndex),
		}
	end

	type ParallelPlacement = {
		Curve: PolyCurve.PolyCurve,
		Index: number,
		OffsetM: number,
		Reverse: boolean,
	}

	local function parallelPlacements(segment: CurveSegment.Segment): { ParallelPlacement }
		if not parallel.Enabled then
			return { { Curve = PolyCurve.new({ segment }), Index = 1, OffsetM = 0, Reverse = false } }
		end
		local count = math.clamp(math.floor(parallel.Count), 2, 16)
		local widthM = RoadProfile.TotalWidthM(profile)
		if endProfile then
			widthM = math.max(widthM, RoadProfile.TotalWidthM(endProfile :: RoadProfile.RoadProfile))
		end
		local spacingM = widthM + math.max(parallel.GapM, 0)
		local style = getStyle()
		local forwardIndex = if style.DriveOnLeft then 1 else count
		local placements: { ParallelPlacement } = {}
		for index = 1, count do
			local offsetM = (index - (count + 1) / 2) * spacingM
			local offsetSegments = CurveSegment.OffsetMany(segment, offsetM * settings.MetersToStuds)
			local reverse = if count == 2 and parallel.OppositeDirections
				then index ~= forwardIndex
				else parallel.ReverseByIndex[index] == true
			if reverse then
				local reversed: { CurveSegment.Segment } = {}
				for segmentIndex = #offsetSegments, 1, -1 do
					table.insert(reversed, CurveSegment.Reverse(offsetSegments[segmentIndex]))
				end
				offsetSegments = reversed
			end
			table.insert(placements, {
				Curve = PolyCurve.new(offsetSegments),
				Index = index,
				OffsetM = offsetM,
				Reverse = reverse,
			})
		end
		return placements
	end

	local function placementProfiles(placement: ParallelPlacement): (RoadProfile.RoadProfile, RoadProfile.RoadProfile?)
		if placement.Reverse and endProfile then
			return endProfile :: RoadProfile.RoadProfile, profile
		end
		return profile, endProfile
	end

	-- Config for the "Roundabout" tool mode's single-click placement -
	-- same defaults JunctionPanel's "Make Roundabout" fields start at.
	local roundaboutRadiusStuds = 30
	local roundaboutLaneCount = 1
	local roundaboutLaneWidthM = 3.65

	local previewModel: Model? = nil
	local markerFolder: Folder? = nil
	local crossingMarkerFolder: Folder? = nil
	local hoverSnapPos: Vector3? = nil
	local previewValidCrossingCount = 0
	local previewBlockedCrossingCount = 0
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

	local function isAtGrade(a: Vector3, b: Vector3): boolean
		return math.abs(a.Y - b.Y) <= math.max(MIN_AT_GRADE_SEPARATION_STUDS, settings.RoadThicknessStuds * 2)
	end

	-- Ground-picking deliberately ignores existing roads/junctions/roundabouts
	-- (crossing over one is allowed by default, not something to route around)
	-- - the old behaviour of hitting an existing road's own deck instead of
	-- the terrain beneath it made a new placement silently "stack" on top of
	-- whatever it crossed. Roundabouts lived in their own workspace folder
	-- and were missed by the first version of this exclude list, so a click
	-- over a ring hit the ring deck (CanQuery=true) and placed at deck Y
	-- instead of the user's set elevation - reported live as "road over the
	-- roundabout." Mid-network crossings are handled by the junction/split
	-- system (and roundabout ConnectRoad); elevation is an explicit control
	-- (R/F, elevation field) for cases that genuinely want a different height.
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
		if crossingMarkerFolder then
			table.insert(excluded, crossingMarkerFolder)
		end
		local roadsFolder = getRoadsFolder(false)
		if roadsFolder then
			table.insert(excluded, roadsFolder)
		end
		local junctionsFolder = workspace:FindFirstChild("Junctions")
		if junctionsFolder then
			table.insert(excluded, junctionsFolder)
		end
		local roundaboutsFolder = workspace:FindFirstChild("Roundabouts")
		if roundaboutsFolder then
			table.insert(excluded, roundaboutsFolder)
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

	-- Finds an existing junction whose PAD footprint (not just its centre
	-- point) is within snap radius of `pos`. JunctionInstance.FindNear
	-- measures from the centre alone, but a wide avenue's pad radius (half
	-- the road width + setback margin) is much larger than the snap radius -
	-- a click at the pad's visible EDGE, the natural place to start a new
	-- approach from, sat well outside a centre-only search and never
	-- matched. Matching against centre distance minus the junction's own
	-- real pad radius fixes that for any road width.
	local function findJunctionNear(pos: Vector3): Model?
		if not settings.SnapToRoad then
			return nil
		end
		for _, junctionModel in JunctionInstance.GetAll() do
			local junctionData = JunctionInstance.Read(junctionModel)
			if junctionData and junctionData.Kind ~= "Roundabout" then
				local padRadius = JunctionBuilder.PadRadiusStuds(junctionData.Id, settings) or 0
				if
					isAtGrade(junctionData.Position, pos)
					and (junctionData.Position - pos).Magnitude <= settings.SnapRadiusStuds + padRadius
				then
					return junctionModel
				end
			end
		end
		return nil
	end

	local function roadwayEdgeOffsetsM(profile: RoadProfile.RoadProfile): (number, number)
		local offsets = RoadProfile.ComponentOffsetsM(profile)
		if #offsets == 0 then
			return 0, 0
		end
		local firstRoadway: number? = nil
		local lastRoadway: number? = nil
		for index, component in profile.Components do
			if RoadProfile.IsRoadway(component.Kind) then
				firstRoadway = firstRoadway or index
				lastRoadway = index
			end
		end
		if not firstRoadway or not lastRoadway then
			return offsets[1].Left, offsets[#offsets].Right
		end
		return offsets[firstRoadway].Left, offsets[lastRoadway].Right
	end

	-- Returns the visible magnetic point for one centreline station. Profile
	-- offsets use the road's own stored start -> end orientation, matching the
	-- Road Editor's left-to-right component order. The banked frame keeps an
	-- edge snap on the actual elevated deck instead of floating beside it.
	local function roadSnapPosition(data: RoadInstance.RoadData, station: number): Vector3
		local centre = data.Curve:PosAt(station)
		if settings.SnapReference == "Centre" then
			return centre
		end
		local profile = if data.ProfileEnd and station >= data.Curve.Length - 1e-4
			then data.ProfileEnd :: RoadProfile.RoadProfile
			else data.ProfileStart
		local leftM, rightM = roadwayEdgeOffsetsM(profile)
		local offsetM = if settings.SnapReference == "LeftRoadwayEdge" then leftM else rightM
		-- RoadBuilder tapers every segment's bank to zero at both endpoints so
		-- chained roads meet without a height step. Apply the same runoff envelope
		-- here; using the raw curvature roll put an edge snap above/below the real
		-- deck at a curved endpoint. RoadBuilder additionally smooths sampled roll
		-- noise, but this continuous envelope preserves the exact endpoint contract
		-- and the intended bank through the body of the road.
		local roll = Superelevation.RollAt(data.Curve:CurvatureAt(station), settings, getStyle())
		local runoffStuds = math.min(settings.SuperelevationRunoffM * settings.MetersToStuds, data.Curve.Length * 0.3)
		if runoffStuds > 1e-3 then
			local taper = math.min(1, station / runoffStuds, (data.Curve.Length - station) / runoffStuds)
			roll *= math.max(taper, 0)
		end
		local frame = data.Curve:FrameAt(station, roll)
		return (frame * CFrame.new(offsetM * settings.MetersToStuds, 0, 0)).Position
	end

	local function findEndpointSnap(pos: Vector3): SnapMatch?
		if not settings.SnapToRoad then
			return nil
		end
		local bestDistance = settings.SnapRadiusStuds
		local best: SnapMatch? = nil
		local folder = getRoadsFolder(false)
		if folder then
			for _, child in folder:GetChildren() do
				if child:GetAttribute("RW_Road") ~= true then
					continue
				end
				local road = child :: Model
				local data = RoadInstance.Read(road)
				if not data then
					continue
				end
				local endStation = data.Curve.Length
				local endTopologyPos = data.Curve:PosAt(endStation)
				local endPos = roadSnapPosition(data, endStation)
				local endTan = data.Curve:TangentAt(endStation)
				do
					local d = (endPos - pos).Magnitude
					if isAtGrade(endPos, pos) and d < bestDistance then
						bestDistance = d
						best = {
							Kind = "RoadEndpoint",
							Position = endPos,
							TopologyPosition = endTopologyPos,
							Tangent = endTan, -- Outgoing continuation direction
							Road = road,
							RoadEnd = "End",
							Station = endStation,
						}
					end
				end
				do
					local startTopologyPos = data.Curve:PosAt(0)
					local startPos = roadSnapPosition(data, 0)
					local startTan = data.Curve:TangentAt(0)
					local d = (startPos - pos).Magnitude
					if isAtGrade(startPos, pos) and d < bestDistance then
						bestDistance = d
						best = {
							Kind = "RoadEndpoint",
							Position = startPos,
							TopologyPosition = startTopologyPos,
							Tangent = -startTan, -- Continue backwards out of the start
							Road = road,
							RoadEnd = "Start",
							Station = 0,
						}
					end
				end
			end
		end
		-- Also snap toward an existing JunctionNode's own centre - not just
		-- its connected roads' endpoints. TrimApproaches always pulls every
		-- connected road's real endpoint back to the pad boundary now, so on
		-- an already-built intersection there's no road endpoint sitting at
		-- the centre any more for a new road to snap onto. Matched against
		-- the pad's whole footprint (findJunctionNear), not just a small
		-- radius around the centre - clicking anywhere on the visible pad
		-- counts as "attach here". No single tangent makes sense for a
		-- junction with more than one road already meeting there, so this
		-- leaves the tangent unlocked (nil) - the placement tools already
		-- treat a nil tangent as "no guide point saved, free to aim."
		if not best then
			local junctionModel = findJunctionNear(pos)
			if junctionModel then
				local junctionData = JunctionInstance.Read(junctionModel)
				if junctionData then
					best = {
						Kind = "Junction",
						Position = junctionData.Position,
						TopologyPosition = junctionData.Position,
						Tangent = nil,
						Junction = junctionModel,
					}
				end
			end
		end
		-- Snap onto a placed roundabout's outer rim (rings stamp RW_Center /
		-- RW_OuterRadius and are not RW_Road, so the loop above never sees
		-- them). Attach point is on the outer pavement edge; outward tangent
		-- lets the tool chain a new spoke away from the ring.
		if not best then
			local ring, attachPos, outward = RoundaboutBuilder.FindNear(pos, settings.SnapRadiusStuds)
			if attachPos and outward then
				-- Attach on the ring's own deck height (center.Y stamped at
				-- create time), not ground+elevation - stacking on the ring
				-- was the old bug; snapping TO the ring should meet it flush.
				best = {
					Kind = "Roundabout",
					Position = attachPos,
					TopologyPosition = attachPos,
					Tangent = outward,
					Ring = ring,
				}
			end
		end
		return best
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
				if isAtGrade(startPos, pos) and d < bestDistance then
					bestDistance = d
					bestModel = child :: Model
					bestEnd = "Start"
				end
			end
			if endPos then
				local d = (endPos - pos).Magnitude
				if isAtGrade(endPos, pos) and d < bestDistance then
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
		otherEnd: ("Start" | "End")?,
		knownJunction: Model?
	)
		-- Reuse the junction the other road's end is ALREADY linked to before
		-- searching by position: approaches get trimmed back to the pad
		-- boundary (JunctionBuilder.TrimApproaches), so a trimmed end sits a
		-- road-half-width away from its junction's centre - farther than the
		-- position search radius - and treating it as unlinked would stamp a
		-- fresh junction over the existing link, silently disconnecting the
		-- road from its real junction. `knownJunction` (a junction the
		-- caller already located, e.g. via the pad-footprint search) takes
		-- the same precedence over the narrow centre-point search below,
		-- which could easily miss a wide pad's junction and mint a
		-- duplicate node right next to the real one.
		local existingJunctionModel: Model? = nil
		if otherModel and otherEnd then
			local otherData = RoadInstance.Read(otherModel)
			local existingId = if otherData
				then (if otherEnd == "Start" then otherData.StartJunctionId else otherData.EndJunctionId)
				else nil
			if existingId then
				existingJunctionModel = JunctionInstance.FindById(existingId)
			end
		end
		local junctionModel = existingJunctionModel
			or knownJunction
			or JunctionInstance.FindNear(pos, settings.SnapRadiusStuds)
			or JunctionInstance.Create(pos)
		local junctionData = JunctionInstance.Read(junctionModel)
		if not junctionData then
			return
		end
		stampEndJunction(model, modelEnd, junctionData.Id)
		if otherModel and otherEnd then
			stampEndJunction(otherModel, otherEnd, junctionData.Id)
		end
		JunctionBuilder.TrimApproaches(junctionData.Id, getStyle(), settings)
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
	local function findMidSpanMatch(pos: Vector3, exclude: Model?): SnapMatch?
		if not settings.SnapToRoad then
			return nil
		end
		local folder = getRoadsFolder(false)
		if not folder then
			return nil
		end
		local best: SnapMatch? = nil
		local bestDistance = math.huge
		for _, child in folder:GetChildren() do
			if (exclude and child == exclude) or child:GetAttribute("RW_Road") ~= true then
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
			-- ClosestS searches the centreline. On a tight curve the closest
			-- point of an offset roadway edge can be at a slightly different
			-- station, so refine against the actual selected lateral reference.
			if settings.SnapReference ~= "Centre" then
				local window = math.max(data.Curve.Length / 40, settings.SnapRadiusStuds * 2)
				for _ = 1, 8 do
					local lo = math.max(0, station - window)
					local hi = math.min(data.Curve.Length, station + window)
					local localBestStation = station
					local localBestDistance = (roadSnapPosition(data, station) - pos).Magnitude
					for sample = 0, 8 do
						local candidate = lo + (hi - lo) * sample / 8
						local candidateDistance = (roadSnapPosition(data, candidate) - pos).Magnitude
						if candidateDistance < localBestDistance then
							localBestDistance = candidateDistance
							localBestStation = candidate
						end
					end
					station = localBestStation
					window /= 2
				end
			end
			local topologyPosition = data.Curve:PosAt(station)
			local snapPosition = roadSnapPosition(data, station)
			local distance = (snapPosition - pos).Magnitude
			local tolerance = if settings.SnapReference == "Centre"
				then RoadProfile.TotalWidthM(data.ProfileStart) / 2 * settings.MetersToStuds + settings.SnapRadiusStuds
				else settings.SnapRadiusStuds
			if isAtGrade(snapPosition, pos) and distance < tolerance and distance < bestDistance then
				bestDistance = distance
				best = {
					Kind = "RoadMidSpan",
					Position = snapPosition,
					TopologyPosition = topologyPosition,
					Tangent = nil,
					Road = child :: Model,
					Station = station,
				}
			end
		end
		return best
	end

	-- Splits `road` at `station` and links `model`'s given end to the fresh
	-- junction created there - the mid-span counterpart of connectAt above.
	local function connectAtSplit(road: Model, station: number, model: Model, modelEnd: "Start" | "End"): boolean
		local _, _, junctionId = RoadSplit.SplitAt(road, station, getStyle(), settings)
		if not junctionId then
			return false
		end
		stampEndJunction(model, modelEnd, junctionId)
		JunctionBuilder.TrimApproaches(junctionId, getStyle(), settings)
		JunctionBuilder.Rebuild(junctionId, getStyle(), settings)
		return true
	end

	-- Finds real interior curve/curve crossings for the pending road. Unlike
	-- findMidSpanMatch (an endpoint landing near a road), these candidates
	-- cover a road whose start AND end both continue past the crossing: a
	-- genuine X. Crossings at a different deck height are silently treated
	-- as grade-separated; geometrically valid but unsupported cuts remain in
	-- the result as red preview markers with a reason.
	local function findCurveCrossings(newCurve: PolyCurve.PolyCurve): { CrossingCandidate }
		if not settings.SnapToRoad then
			return {}
		end
		local folder = getRoadsFolder(false)
		if not folder then
			return {}
		end
		local minimumPiece = RoadSplit.MinimumPieceLengthStuds()
		local maximumVerticalSeparation = math.max(MIN_AT_GRADE_SEPARATION_STUDS, settings.RoadThicknessStuds * 2)
		local newRoadBlockReason = if endProfile ~= nil
			then "Widening/narrowing roads cannot be split at a crossing yet"
			elseif #newCurve.Segments > 1 then "Curved parallel roadways cannot be split at a crossing yet"
			else nil
		local candidates: { CrossingCandidate } = {}
		for _, child in folder:GetChildren() do
			if child:GetAttribute("RW_Road") ~= true then
				continue
			end
			local road = child :: Model
			local data = RoadInstance.Read(road)
			if not data then
				continue
			end
			for _, intersection in CurveIntersections.Find(newCurve, data.Curve) do
				-- A crossing at the pending road's own endpoint is handled by
				-- the existing endpoint/mid-span connection path, which also
				-- supplies the magnetic final-point snap.
				if intersection.StationA < minimumPiece or intersection.StationA > newCurve.Length - minimumPiece then
					continue
				end
				if intersection.VerticalSeparation > maximumVerticalSeparation then
					continue
				end
				local reason = newRoadBlockReason
				if not reason then
					reason = RoadSplit.SplitBlockReason(road)
				end
				if
					not reason
					and (
						intersection.StationB < minimumPiece
						or intersection.StationB > data.Curve.Length - minimumPiece
					)
				then
					reason = "Crossing is too close to the existing road's end"
				end
				table.insert(candidates, {
					Road = road,
					NewStation = intersection.StationA,
					RoadStation = intersection.StationB,
					Position = intersection.Position,
					CanCreate = reason == nil,
					Reason = reason,
				})
			end
		end
		table.sort(candidates, function(a, b)
			return a.NewStation < b.NewStation
		end)

		-- A four-stud piece is the smallest RoadSplit can build. If two raw
		-- crossings would create something shorter, keep the first candidate
		-- and show the other as blocked instead of letting commit partially
		-- mutate one of the roads.
		local acceptedNewStations: { number } = {}
		local acceptedRoadStations: { [Model]: { number } } = {}
		for _, candidate in candidates do
			if not candidate.CanCreate then
				continue
			end
			local tooClose = false
			for _, station in acceptedNewStations do
				if math.abs(candidate.NewStation - station) < minimumPiece then
					tooClose = true
					break
				end
			end
			local roadStations = acceptedRoadStations[candidate.Road] or {}
			if not tooClose then
				for _, station in roadStations do
					if math.abs(candidate.RoadStation - station) < minimumPiece then
						tooClose = true
						break
					end
				end
			end
			if tooClose then
				candidate.CanCreate = false
				candidate.Reason = "Crossings are too close together to split safely"
			else
				table.insert(acceptedNewStations, candidate.NewStation)
				table.insert(roadStations, candidate.RoadStation)
				acceptedRoadStations[candidate.Road] = roadStations
			end
		end
		return candidates
	end

	local function applyGridSnap(pos: Vector3): Vector3
		if not settings.SnapToGrid or settings.GridSizeStuds <= 0 then
			return pos
		end
		local grid = settings.GridSizeStuds
		return Vector3.new(math.round(pos.X / grid) * grid, pos.Y, math.round(pos.Z / grid) * grid)
	end

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

	-- Magnetic start/end snapping shared by hover and click. The old flow
	-- only snapped the first point; a final click near a road was connected
	-- after commit without the preview ever moving onto the centreline, so
	-- it felt like snapping had not happened even when metadata linked.
	local function placementPointFromGround(ground: Vector3): (Vector3, Vector3?, boolean, SnapMatch?)
		local unsnapped = applyGridSnap(ground) + Vector3.new(0, elevation, 0)
		local isStart = #points == 0
		local isEnd = #points == clicksNeeded() - 1
		if not isStart and not isEnd then
			return unsnapped, nil, false, nil
		end
		local endpointMatch = findEndpointSnap(unsnapped)
		if endpointMatch then
			return endpointMatch.Position, if isStart then endpointMatch.Tangent else nil, true, endpointMatch
		end
		if isEnd then
			local midSpanMatch = findMidSpanMatch(unsnapped, nil)
			if midSpanMatch then
				return midSpanMatch.Position, nil, true, midSpanMatch
			end
		end
		return unsnapped, nil, false, nil
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
		local position, _, snapped = placementPointFromGround(ground)
		hoverPos = position
		hoverSnapPos = if snapped then position else nil
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

	local function pickPoint(): (Vector3?, Vector3?, SnapMatch?)
		local ground = raycastGround()
		if not ground then
			return nil, nil, nil
		end
		local position, tangent, snapped, snapMatch = placementPointFromGround(ground)
		hoverSnapPos = if snapped then position else nil
		return position, tangent, snapMatch
	end

	-- Curve construction -----------------------------------------------------------

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

	local function destroyCrossingMarkers()
		if crossingMarkerFolder then
			crossingMarkerFolder:Destroy()
			crossingMarkerFolder = nil
		end
	end

	local function setPreviewCrossingStatus(validCount: number, blockedCount: number)
		if validCount ~= previewValidCrossingCount or blockedCount ~= previewBlockedCrossingCount then
			previewValidCrossingCount = validCount
			previewBlockedCrossingCount = blockedCount
			changeSignal:Fire()
		end
	end

	local function addPreviewMarker(folder: Folder, position: Vector3, color: Color3, text: string)
		local marker = Instance.new("Part")
		marker.Name = "IntersectionMarker"
		marker.Shape = Enum.PartType.Ball
		marker.Size = Vector3.new(2.8, 2.8, 2.8)
		marker.Color = color
		marker.Material = Enum.Material.Neon
		marker.Transparency = 0.08
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.Position = position + Vector3.new(0, 1.4, 0)
		marker.Parent = folder

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Label"
		billboard.AlwaysOnTop = true
		billboard.Size = UDim2.new(0, 260, 0, 34)
		billboard.StudsOffset = Vector3.new(0, 2.2, 0)
		billboard.Parent = marker
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = Color3.fromRGB(20, 24, 31)
		label.BackgroundTransparency = 0.18
		label.BorderSizePixel = 0
		label.Font = Enum.Font.GothamBold
		label.Text = text
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextSize = 14
		label.TextWrapped = true
		label.Parent = billboard
	end

	local function updateCrossingMarkers(candidates: { CrossingCandidate })
		local validCount = 0
		local blockedCount = 0
		for _, candidate in candidates do
			if candidate.CanCreate then
				validCount += 1
			else
				blockedCount += 1
			end
		end
		setPreviewCrossingStatus(validCount, blockedCount)

		local folder: Folder? = nil
		if #candidates > 0 or hoverSnapPos then
			folder = Instance.new("Folder")
			folder.Name = "EasyRoadIntersectionMarkers"
			folder.Archivable = false
			if hoverSnapPos then
				addPreviewMarker(folder, hoverSnapPos, Color3.fromRGB(0, 190, 255), "SNAPPED")
			end
			for _, candidate in candidates do
				if candidate.CanCreate then
					addPreviewMarker(folder, candidate.Position, Color3.fromRGB(55, 220, 125), "X INTERSECTION")
				else
					addPreviewMarker(
						folder,
						candidate.Position,
						Color3.fromRGB(255, 91, 91),
						candidate.Reason or "CANNOT SPLIT"
					)
				end
			end
			folder.Parent = workspace
		end
		destroyCrossingMarkers()
		crossingMarkerFolder = folder
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
			updateCrossingMarkers({})
			return
		end
		local placements = parallelPlacements(segment)
		local crossingPlacement = placements[1]
		for _, placement in placements do
			if not placement.Reverse then
				crossingPlacement = placement
				break
			end
		end
		local crossings = if #points == clicksNeeded() - 1 then findCurveCrossings(crossingPlacement.Curve) else {}
		updateCrossingMarkers(crossings)
		-- Build the replacement BEFORE destroying the old ghost: no flicker
		-- between rebuilds, and if the build errors on degenerate geometry
		-- the previous preview stays on screen instead of vanishing.
		local ok, model = pcall(function()
			if #placements == 1 then
				local previewStart, previewEnd = placementProfiles(placements[1])
				return RoadBuilder.Build({
					Curve = placements[1].Curve,
					ProfileStart = previewStart,
					ProfileEnd = previewEnd,
					Style = getStyle(),
					Settings = settings,
					Preview = true,
				})
			end
			local container = Instance.new("Model")
			container.Name = "ParallelRoadPreview"
			for _, placement in placements do
				local previewStart, previewEnd = placementProfiles(placement)
				local roadPreview = RoadBuilder.Build({
					Curve = placement.Curve,
					ProfileStart = previewStart,
					ProfileEnd = previewEnd,
					Style = getStyle(),
					Settings = settings,
					Preview = true,
				})
				roadPreview.Name = string.format("Roadway_%02d", placement.Index)
				roadPreview.Parent = container
			end
			return container
		end)
		if not ok then
			return
		end
		destroyPreview()
		model.Archivable = false
		model.Parent = workspace
		previewModel = model
	end

	-- Commit ---------------------------------------------------------------------------

	local function placeRoad(segment: CurveSegment.Segment)
		local startSnapMatch = pointSnapMatches[1]
		local endSnapMatch = pointSnapMatches[#points]
		local corridorCurve = PolyCurve.new({ segment })
		local placements = parallelPlacements(segment)
		local primaryPlacement = placements[1]
		for _, placement in placements do
			if not placement.Reverse then
				primaryPlacement = placement
				break
			end
		end
		local curve = primaryPlacement.Curve
		local crossingCandidates = findCurveCrossings(curve)
		local primaryProfileStart, primaryProfileEnd = placementProfiles(primaryPlacement)
		local model = RoadBuilder.Build({
			Curve = curve,
			ProfileStart = primaryProfileStart,
			ProfileEnd = primaryProfileEnd,
			Style = getStyle(),
			Settings = settings,
			Preview = false,
		})
		model.Parent = getRoadsFolder(true)
		local parallelGroupId = if #placements > 1 then HttpService:GenerateGUID(false) else nil
		local function stampParallel(target: Model, placement: ParallelPlacement)
			if not parallelGroupId then
				return
			end
			target:SetAttribute("RW_ParallelGroupId", parallelGroupId)
			target:SetAttribute("RW_ParallelIndex", placement.Index)
			target:SetAttribute("RW_ParallelCount", #placements)
			target:SetAttribute("RW_ParallelOffsetM", placement.OffsetM)
			target:SetAttribute("RW_ParallelReverse", placement.Reverse)
		end
		stampParallel(model, primaryPlacement)
		local appliedStructure = if structure.Mode == "None" then nil else StructureBuilder.CloneData(structure)
		RoadInstance.StampStructure(model, appliedStructure)
		local _, renderMessage = StructureBuilder.Render(model, curve, structure, settings)
		structureStatus = renderMessage

		-- Build every true interior crossing around one shared node. Existing
		-- roads are grouped so a curve crossed more than once is replaced in
		-- one SplitMany call, and the new road is split at all of its accepted
		-- crossings in the same operation.
		local prepared: { PreparedCrossing } = {}
		local newCuts: { RoadSplit.SplitCut } = {}
		local cutsByRoad: { [Model]: { RoadSplit.SplitCut } } = {}
		for _, candidate in crossingCandidates do
			if not candidate.CanCreate then
				continue
			end
			local junctionModel = JunctionInstance.Create(candidate.Position)
			local junctionData = JunctionInstance.Read(junctionModel)
			if not junctionData then
				junctionModel:Destroy()
				continue
			end
			table.insert(prepared, {
				Candidate = candidate,
				JunctionId = junctionData.Id,
				JunctionModel = junctionModel,
			})
			table.insert(newCuts, {
				StationStuds = candidate.NewStation,
				JunctionId = junctionData.Id,
			})
			local roadCuts = cutsByRoad[candidate.Road] or {}
			table.insert(roadCuts, {
				StationStuds = candidate.RoadStation,
				JunctionId = junctionData.Id,
			})
			cutsByRoad[candidate.Road] = roadCuts
		end

		local canSplitAll = #prepared > 0 and RoadSplit.CanSplitAtMany(model, newCuts)
		if canSplitAll then
			for road, cuts in cutsByRoad do
				if not RoadSplit.CanSplitAtMany(road, cuts) then
					canSplitAll = false
					break
				end
			end
		end
		local placedPieces: { Model } = { model }
		if canSplitAll then
			for road, cuts in cutsByRoad do
				RoadSplit.SplitMany(road, cuts, getStyle(), settings)
			end
			placedPieces = RoadSplit.SplitMany(model, newCuts, getStyle(), settings) or { model }
		else
			for _, crossing in prepared do
				crossing.JunctionModel:Destroy()
			end
			table.clear(prepared)
		end
		for _, piece in placedPieces do
			stampParallel(piece, primaryPlacement)
		end

		-- Links `model`'s `whichEnd` at `pos` to whatever it should connect
		-- to there: an existing road's endpoint first (findConnectableEndpoint),
		-- then an existing JUNCTION whose pad footprint covers `pos`
		-- (findJunctionNear), then a mid-span crossing (findMidSpanMatch).
		--
		-- The junction check runs BEFORE the mid-span check, deliberately -
		-- an earlier version had it last, and near an already-built
		-- intersection it was unreachable: every trimmed approach's own
		-- curve passes within findMidSpanMatch's width-scaled tolerance of
		-- a click near the pad, so the mid-span branch matched a station
		-- right at that approach's cut end and returned unconditionally -
		-- and RoadSplit then declined the degenerate near-end split, so the
		-- whole connection silently died without ever reaching the junction
		-- fallback. That was the real reason "can't add a new road to an
		-- intersection" survived the previous fix.
		local function connectEnd(targetModel: Model, pos: Vector3, whichEnd: "Start" | "End", snapMatch: SnapMatch?)
			-- A lateral snap can be farther than SnapRadiusStuds from the target
			-- centreline, so proximity rediscovery is not reliable. Use the exact
			-- target captured on click and connect at its true centreline station.
			if snapMatch then
				if
					snapMatch.Kind == "RoadEndpoint"
					and snapMatch.Road
					and snapMatch.Road.Parent
					and snapMatch.RoadEnd
				then
					connectAt(snapMatch.TopologyPosition, targetModel, whichEnd, snapMatch.Road, snapMatch.RoadEnd)
					return
				elseif
					snapMatch.Kind == "RoadMidSpan"
					and snapMatch.Road
					and snapMatch.Road.Parent
					and snapMatch.Station
				then
					if connectAtSplit(snapMatch.Road, snapMatch.Station, targetModel, whichEnd) then
						return
					end
				elseif snapMatch.Kind == "Junction" and snapMatch.Junction and snapMatch.Junction.Parent then
					connectAt(snapMatch.TopologyPosition, targetModel, whichEnd, nil, nil, snapMatch.Junction)
					return
				elseif snapMatch.Kind == "Roundabout" and snapMatch.Ring and snapMatch.Ring.Parent then
					local connected, message =
						RoundaboutBuilder.ConnectRoad(snapMatch.Ring, targetModel, getStyle(), settings)
					if not connected then
						structureStatus = message or "Could not connect the road to the roundabout."
						warn("[EasyRoad] " .. structureStatus)
					end
					return
				end
			end
			local otherModel, otherEnd = findConnectableEndpoint(pos, targetModel)
			if otherModel then
				connectAt(pos, targetModel, whichEnd, otherModel, otherEnd)
				return
			end
			local junctionModel = findJunctionNear(pos)
			if junctionModel then
				connectAt(pos, targetModel, whichEnd, nil, nil, junctionModel)
				return
			end
			-- Attach as a new spoke on a placed roundabout (rebuilds the ring
			-- with RoadBuilder curve feeders for every nearby road including this one).
			local ring = RoundaboutBuilder.FindNear(pos, settings.SnapRadiusStuds)
			if ring then
				local connected, message = RoundaboutBuilder.ConnectRoad(ring, targetModel, getStyle(), settings)
				if not connected then
					structureStatus = message or "Could not connect the road to the roundabout."
					warn("[EasyRoad] " .. structureStatus)
				end
				return
			end
			local midSpanMatch = findMidSpanMatch(pos, targetModel)
			if midSpanMatch and midSpanMatch.Road and midSpanMatch.Station then
				connectAtSplit(midSpanMatch.Road, midSpanMatch.Station, targetModel, whichEnd)
			end
		end

		local startPos = curve:PosAt(0)
		local endPos = curve:PosAt(curve.Length)
		connectEnd(placedPieces[1], startPos, "Start", startSnapMatch)
		connectEnd(placedPieces[#placedPieces], endPos, "End", endSnapMatch)

		-- Endpoint connections above may change the width of a crossing's
		-- neighbouring approach. Trim and rebuild only after every road and
		-- outer endpoint has its final junction ids.
		for _, crossing in prepared do
			JunctionBuilder.TrimApproaches(crossing.JunctionId, getStyle(), settings)
			JunctionBuilder.Rebuild(crossing.JunctionId, getStyle(), settings)
		end

		-- Secondary carriageways intentionally do not auto-split/connect against
		-- the primary or each other. They are full, editable Road models with
		-- their own direction metadata and physically meet the next chained
		-- parallel set; automatic multi-road junction synthesis is a separate,
		-- more complex operation than parallel alignment placement.
		for _, placement in placements do
			if placement == primaryPlacement then
				continue
			end
			local secondaryCurve = placement.Curve
			local secondaryStart, secondaryEnd = placementProfiles(placement)
			local secondary = RoadBuilder.Build({
				Curve = secondaryCurve,
				ProfileStart = secondaryStart,
				ProfileEnd = secondaryEnd,
				Style = getStyle(),
				Settings = settings,
				Preview = false,
			})
			secondary.Name = string.format("ParallelRoad_%02d", placement.Index)
			secondary.Parent = getRoadsFolder(true)
			RoadInstance.StampStructure(secondary, appliedStructure)
			StructureBuilder.Render(secondary, secondaryCurve, structure, settings)
			stampParallel(secondary, placement)
		end
		if #placements > 1 then
			structureStatus = string.format("Placed %d parallel roadways. %s", #placements, renderMessage)
		end

		-- Chain: continue building from the end of the road just placed. A
		-- transition segment arrives at its end profile, so the chain
		-- continues with that profile.
		if endProfile then
			profile = endProfile
			endProfile = nil
		end
		points = { corridorCurve:PosAt(corridorCurve.Length) }
		pointSnapMatches = {}
		lockedTangent = corridorCurve:TangentAt(corridorCurve.Length)
		hoverSnapPos = nil
		destroyCrossingMarkers()
		setPreviewCrossingStatus(0, 0)
		updateMarkers()
		previewDirty = true
		changeSignal:Fire()
	end

	local function commitRoad(segment: CurveSegment.Segment)
		local changed, message = History.Record("EasyRoadPlace", "Place road", function()
			placeRoad(segment)
			return true
		end)
		if not changed and message then
			structureStatus = message
			changeSignal:Fire()
		end
	end

	-- Places a standalone roundabout ring centred at `center` (ground click,
	-- grid-snapped, elevated) using the current radius/lane config - no
	-- multi-click curve fitting involved, unlike the other tool modes.
	local function placeRoundabout(center: Vector3): boolean
		-- Place, then auto-connect any roads already near the drop point (so a
		-- roundabout dropped onto existing roads wires them up with feeders
		-- instead of leaving a bare ring). No nearby roads -> just the ring.
		local ring, message = RoundaboutBuilder.Place(
			center,
			roundaboutRadiusStuds,
			roundaboutLaneCount,
			roundaboutLaneWidthM,
			getStyle(),
			settings
		)
		if message then
			structureStatus = message
			warn("[EasyRoad] " .. message)
		end
		changeSignal:Fire()
		return ring ~= nil
	end

	local function commitRoundabout(center: Vector3)
		local changed, message = History.Record("EasyRoadPlace", "Place roundabout", function()
			return placeRoundabout(center)
		end)
		if not changed and message then
			structureStatus = message
			changeSignal:Fire()
		end
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
		local point, snapTangent, snapMatch = pickPoint()
		if not point then
			return
		end
		if #points == 0 and snapTangent then
			lockedTangent = snapTangent
		end
		table.insert(points, point)
		if snapMatch then
			pointSnapMatches[#points] = snapMatch
		end
		hoverSnapPos = nil
		updateMarkers()

		if #points >= clicksNeeded() then
			local segment = buildSegment(nil)
			if segment and segment.Length > 1 then
				commitRoad(segment)
			else
				-- Degenerate (double click in place): drop the last point
				table.remove(points)
				pointSnapMatches[#points + 1] = nil
			end
		end
		previewDirty = true
		changeSignal:Fire()
	end

	local function cancelPlacement()
		points = {}
		pointSnapMatches = {}
		lockedTangent = nil
		hoverSnapPos = nil
		updateMarkers()
		destroyPreview()
		destroyCrossingMarkers()
		setPreviewCrossingStatus(0, 0)
		previewDirty = false
		changeSignal:Fire()
	end

	table.insert(connections, mouse.Button1Down:Connect(onClick))
	table.insert(
		connections,
		mouse.Move:Connect(function()
			local ground = raycastGround()
			if ground then
				lastGroundPos = ground
				refreshHoverPos()
			end
		end)
	)

	-- Rebindable via the Keybinds settings dock (src/Keybinds.lua); each
	-- action can have multiple bound inputs (Cancel Placement defaults to
	-- Escape and middle-click - right-click is deliberately not a default
	-- since it also doubles as Studio's camera-orbit gesture, but can be
	-- added manually).
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
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
		end)
	)

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function()
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
				destroyCrossingMarkers()
				setPreviewCrossingStatus(0, 0)
			end
		end)
	)

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
				local firstSnapMatch = pointSnapMatches[1]
				pointSnapMatches = if firstSnapMatch then { firstSnapMatch } else {}
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

	function session.GetStructure(): RoadInstance.StructureData
		return structure
	end

	function session.SetStructure(newStructure: RoadInstance.StructureData)
		structure = StructureBuilder.CloneData(newStructure)
		structureStatus = if structure.Mode == "None"
			then "Ground mode selected."
			elseif structure.Mode == "Viaduct" then "New roads will generate viaduct supports when placed."
			else "New roads will generate a tunnel shell when placed."
		changeSignal:Fire()
	end

	function session.GetStructureAssets(kind: StructureAssets.AssetKind?): { StructureAssets.AssetInfo }
		return StructureAssets.List(kind)
	end

	function session.GetStructureStatus(): string?
		return structureStatus
	end

	function session.GetParallel(): ParallelConfig
		return cloneParallel(parallel)
	end

	function session.SetParallel(config: ParallelConfig)
		parallel = cloneParallel(config)
		settings.ParallelRoadwayGapM = parallel.GapM
		previewDirty = true
		changeSignal:Fire()
	end

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
		if previewBlockedCrossingCount > 0 then
			return string.format(
				"%d crossing%s cannot be split - see the red marker%s",
				previewBlockedCrossingCount,
				if previewBlockedCrossingCount == 1 then "" else "s",
				if previewBlockedCrossingCount == 1 then "" else "s"
			)
		elseif previewValidCrossingCount > 0 then
			return string.format(
				"Click to place - %d X intersection%s will be created",
				previewValidCrossingCount,
				if previewValidCrossingCount == 1 then "" else "s"
			)
		end
		local count = #points
		local needed = clicksNeeded()
		if count == 0 then
			return "Click to place the start point (snaps to existing road ends)"
		elseif count == needed - 1 then
			if lockedTangent and toolMode ~= "Straight" then
				-- One fewer click than usual: the start point snapped onto
				-- an existing road's own end, so its tangent is already
				-- known and there's no separate guide point to place - only
				-- called out explicitly here because it otherwise reads as
				-- "the guide-point step just vanished" (reported live as a
				-- bug). Turn off "Snap to existing road" in Road Tools to
				-- always get the full guide-point click.
				return "Start snapped to an existing road end - click to place the end point (no separate guide point needed)"
			end
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
		destroyCrossingMarkers()
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
