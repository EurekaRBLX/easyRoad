--!strict
-- Road cross-section profiles.
--
-- A RoadProfile describes the cross-section of a road as an ordered list of
-- components from left to right (looking along the direction of travel from
-- the start of the road towards the end). Each component has a kind (drive
-- lane, sidewalk, median, ...), a width in meters, and for traffic-carrying
-- kinds a direction (+1 = with the road, -1 = against it).
--
-- Profiles are pure data and fully JSON-serializable so that user-created
-- roads can be persisted in plugin settings.

local RegionStyles = require("./RegionStyles")
local RoadSurfaceMaterials = require("./RoadSurfaceMaterials")

export type ComponentKind = "Drive" | "Sidewalk" | "Median" | "Shoulder" | "Bike" | "Parking" | "Bay"

-- Marking rule for the boundary on the RIGHT side of a lane. It applies to
-- both ordinary lane lines and the centre line between opposing Drive lanes;
-- "Auto" defers to the appropriate region lane/centre style.
export type BoundaryRule = "Auto" | "None" | "Solid" | "DoubleSolid" | "SolidDash" | "DashSolid"

export type ProfileComponent = {
	Kind: ComponentKind,
	WidthM: number,
	Direction: number, -- +1 forward, -1 backward, 0 = not directional
	RightBoundary: BoundaryRule?, -- nil = Auto
}

export type SurfaceOverride = {
	Material: RoadSurfaceMaterials.MaterialName?,
	Color: Color3?,
}

export type RoadProfile = {
	Id: string,
	Name: string,
	Category: string,
	BuiltIn: boolean,
	Components: { ProfileComponent },
	-- Kerb (no parking/stopping) lines: "None" | "SingleYellow" | "DoubleYellow"
	-- | "NoLine" - "None" still draws the plain edge line (no *parking*
	-- restriction is a separate concept from no marking at all); "NoLine"
	-- suppresses any line at the kerb boundary entirely.
	KerbRestriction: string?,
	-- Force centre/lane line colour: "Auto" | "White" | "Yellow"
	MarkingColor: string?,
	-- Override dash geometry for every dashed line on this road; nil = region default
	MarkingDashLengthM: number?,
	MarkingDashGapM: number?,
	-- Kerb line lateral offset: nil/true = inset (default), false = flush
	-- against the plain edge-line position.
	KerbIndent: boolean?,
	-- Optional reusable finish overrides. Missing kinds/fields inherit the
	-- active region and built-in material defaults.
	SurfaceOverrides: { [ComponentKind]: SurfaceOverride }?,
}

local ComponentKinds: { ComponentKind } = {
	"Drive" :: ComponentKind,
	"Sidewalk" :: ComponentKind,
	"Median" :: ComponentKind,
	"Shoulder" :: ComponentKind,
	"Bike" :: ComponentKind,
	"Parking" :: ComponentKind,
	"Bay" :: ComponentKind, -- Bus / taxi pull-in bay
}

local BoundaryRules: { BoundaryRule } = {
	"Auto" :: BoundaryRule,
	-- Draw no line at this boundary at all. Markings.addLine already returns
	-- early on the "None" LineType, so nothing downstream needs to know about
	-- it. Used by the turbo ring, which suppresses the automatic lane lines and
	-- lays its own spiralling ones instead.
	"None" :: BoundaryRule,
	"Solid" :: BoundaryRule,
	"DoubleSolid" :: BoundaryRule,
	"SolidDash" :: BoundaryRule,
	"DashSolid" :: BoundaryRule,
}

local COMPONENT_KIND_SET: { [string]: boolean } = {}
for _, kind in ComponentKinds do
	COMPONENT_KIND_SET[kind] = true
end

local RoadProfile = {}

RoadProfile.ComponentKinds = ComponentKinds
RoadProfile.BoundaryRules = BoundaryRules

-- Kinds which carry directional traffic
local DIRECTIONAL: { [string]: boolean } = {
	Drive = true,
	Bike = true,
}

-- Kinds which are part of the paved roadway (used for marking + curb logic)
local ROADWAY: { [string]: boolean } = {
	Drive = true,
	Bike = true,
	Parking = true,
	Shoulder = true,
	Bay = true,
}

function RoadProfile.IsDirectional(kind: ComponentKind): boolean
	return DIRECTIONAL[kind] == true
end

function RoadProfile.IsRoadway(kind: ComponentKind): boolean
	return ROADWAY[kind] == true
end

-- Maximum number of motor-vehicle lanes carried by one carriageway in this
-- cross-section.  Only positive-width Drive components count: shoulders,
-- pavement, medians, cycle lanes, parking and bays must never make a
-- roundabout wider by masquerading as circulating lanes.
--
-- A Median starts a new carriageway.  Within an undivided carriageway the two
-- direction signs are counted independently (2+2 therefore suggests 2, not
-- 4).  Old/custom profiles whose Drive components are undirected still get a
-- useful answer: their undirected run is counted as one carriageway rather
-- than being halved into two fictional directions.
function RoadProfile.MaxMotorLanesPerCarriageway(profile: RoadProfile): number
	local maximum = 0
	local forward = 0
	local backward = 0
	local undirected = 0

	local function flush()
		maximum = math.max(maximum, forward, backward, undirected)
		forward = 0
		backward = 0
		undirected = 0
	end

	for _, component in profile.Components do
		if component.Kind == "Median" then
			flush()
		elseif component.Kind == "Drive" and component.WidthM > 1e-6 then
			if component.Direction > 0 then
				forward += 1
			elseif component.Direction < 0 then
				backward += 1
			else
				undirected += 1
			end
		end
	end
	flush()
	return maximum
end

-- Sidewalks (and medians) sit on top of a curb, raised above the roadway
function RoadProfile.IsRaised(kind: ComponentKind): boolean
	return kind == "Sidewalk" or kind == "Median"
end

function RoadProfile.TotalWidthM(profile: RoadProfile): number
	local total = 0
	for _, component in profile.Components do
		total += component.WidthM
	end
	return total
end

-- Returns for each component its {left, right} lateral offset in meters,
-- centered so that the profile midline is at offset zero.
function RoadProfile.ComponentOffsetsM(profile: RoadProfile): { { Left: number, Right: number } }
	local total = RoadProfile.TotalWidthM(profile)
	local offsets = {}
	local x = -total / 2
	for _, component in profile.Components do
		table.insert(offsets, { Left = x, Right = x + component.WidthM })
		x += component.WidthM
	end
	return offsets
end

function RoadProfile.Clone(profile: RoadProfile): RoadProfile
	local components = {}
	for _, component in profile.Components do
		table.insert(components, {
			Kind = component.Kind,
			WidthM = component.WidthM,
			Direction = component.Direction,
			RightBoundary = component.RightBoundary,
		})
	end
	local surfaceOverrides: { [ComponentKind]: SurfaceOverride }? = nil
	if profile.SurfaceOverrides then
		surfaceOverrides = {}
		for kind, override in profile.SurfaceOverrides do
			if COMPONENT_KIND_SET[kind] then
				(surfaceOverrides :: { [ComponentKind]: SurfaceOverride })[kind] = {
					Material = RoadSurfaceMaterials.Sanitize(override.Material),
					Color = if typeof(override.Color) == "Color3" then override.Color else nil,
				}
			end
		end
	end
	return {
		Id = profile.Id,
		Name = profile.Name,
		Category = profile.Category,
		BuiltIn = profile.BuiltIn,
		Components = components,
		KerbRestriction = profile.KerbRestriction,
		MarkingColor = profile.MarkingColor,
		MarkingDashLengthM = profile.MarkingDashLengthM,
		MarkingDashGapM = profile.MarkingDashGapM,
		KerbIndent = profile.KerbIndent,
		SurfaceOverrides = surfaceOverrides,
	}
end

-- Re-express a profile for a curve whose station direction has been reversed.
-- Looking along the reversed curve swaps physical left/right, and traffic that
-- was travelling toward the old start now travels with the new curve. Merely
-- cloning the old profile therefore breaks asymmetric handoffs (for example a
-- one-way highway's narrow inner shoulder jumps to the outer edge).
--
-- RightBoundary belongs to the component on the LEFT of a boundary. After the
-- component order is reversed, that owner is the old component immediately to
-- the right, so take the preceding old component's rule. Directional compound
-- lines also exchange their physical stripe sides.
function RoadProfile.Reverse(profile: RoadProfile): RoadProfile
	local reversed = RoadProfile.Clone(profile)
	local source = profile.Components
	local components: { ProfileComponent } = table.create(#source)

	local function mirroredBoundary(rule: BoundaryRule?): BoundaryRule?
		if rule == "SolidDash" then
			return "DashSolid"
		elseif rule == "DashSolid" then
			return "SolidDash"
		end
		return rule
	end

	for oldIndex = #source, 1, -1 do
		local component = source[oldIndex]
		table.insert(components, {
			Kind = component.Kind,
			WidthM = component.WidthM,
			Direction = -component.Direction,
			RightBoundary = if oldIndex > 1 then mirroredBoundary(source[oldIndex - 1].RightBoundary) else nil,
		})
	end
	reversed.Components = components
	return reversed
end

-- Match two profiles for a widening / narrowing transition segment.
--
-- Returns two component lists of equal length. Where one profile has a
-- component that the other lacks, a zero-width copy is inserted into the
-- shorter one so that the extra lanes taper in or out smoothly along the
-- transition. Components are matched greedily from both outer edges inward
-- (the natural case: adding/dropping lanes happens in the middle of the
-- roadway, sidewalks and shoulders stay put at the edges).
function RoadProfile.MatchForTransition(a: RoadProfile, b: RoadProfile): ({ ProfileComponent }, { ProfileComponent })
	local ca = a.Components
	local cb = b.Components
	local na, nb = #ca, #cb

	-- Match from the left edge
	local left = 0
	while left < na and left < nb and ca[left + 1].Kind == cb[left + 1].Kind do
		left += 1
	end
	-- Match from the right edge (without overlapping the left match)
	local right = 0
	while right < (na - left) and right < (nb - left) and ca[na - right].Kind == cb[nb - right].Kind do
		right += 1
	end

	local function zeroOf(component: ProfileComponent): ProfileComponent
		return {
			Kind = component.Kind,
			WidthM = 0,
			Direction = component.Direction,
			RightBoundary = component.RightBoundary,
		}
	end

	local outA: { ProfileComponent } = {}
	local outB: { ProfileComponent } = {}
	for i = 1, left do
		table.insert(outA, ca[i])
		table.insert(outB, cb[i])
	end
	-- Middle chunk: pair what exists, pad the shorter with zero-width copies
	local midA = na - left - right
	local midB = nb - left - right
	local mid = math.max(midA, midB)
	for i = 1, mid do
		if i <= midA then
			table.insert(outA, ca[left + i])
		else
			table.insert(outA, zeroOf(cb[left + i]))
		end
		if i <= midB then
			table.insert(outB, cb[left + i])
		else
			table.insert(outB, zeroOf(ca[left + i]))
		end
	end
	for i = right - 1, 0, -1 do
		table.insert(outA, ca[na - i])
		table.insert(outB, cb[nb - i])
	end
	return outA, outB
end

-- Serialization (component tables are already plain data, but go through an
-- explicit whitelist so bad data can never end up in plugin settings)

local function serializeColor(color: Color3): { [string]: number }
	return {
		R = math.round(color.R * 255),
		G = math.round(color.G * 255),
		B = math.round(color.B * 255),
	}
end

local function deserializeColor(raw: any): Color3?
	if
		typeof(raw) ~= "table"
		or typeof(raw.R) ~= "number"
		or typeof(raw.G) ~= "number"
		or typeof(raw.B) ~= "number"
	then
		return nil
	end
	return Color3.fromRGB(
		math.round(math.clamp(raw.R, 0, 255)),
		math.round(math.clamp(raw.G, 0, 255)),
		math.round(math.clamp(raw.B, 0, 255))
	)
end

function RoadProfile.Serialize(profile: RoadProfile): { [string]: any }
	local components = {}
	for _, component in profile.Components do
		table.insert(components, {
			Kind = component.Kind,
			WidthM = component.WidthM,
			Direction = component.Direction,
			RightBoundary = component.RightBoundary,
		})
	end
	local surfaceOverrides: { [string]: any }? = nil
	if profile.SurfaceOverrides then
		surfaceOverrides = {}
		for kind, override in profile.SurfaceOverrides do
			local material = if COMPONENT_KIND_SET[kind] then RoadSurfaceMaterials.Sanitize(override.Material) else nil
			local color = if typeof(override.Color) == "Color3" then override.Color else nil
			if COMPONENT_KIND_SET[kind] and (material or color) then
				(surfaceOverrides :: { [string]: any })[kind] = {
					Material = material,
					Color = if color then serializeColor(color) else nil,
				}
			end
		end
	end
	return {
		Id = profile.Id,
		Name = profile.Name,
		Category = profile.Category,
		Components = components,
		KerbRestriction = profile.KerbRestriction,
		MarkingColor = profile.MarkingColor,
		MarkingDashLengthM = profile.MarkingDashLengthM,
		MarkingDashGapM = profile.MarkingDashGapM,
		KerbIndent = profile.KerbIndent,
		SurfaceOverrides = surfaceOverrides,
	}
end

function RoadProfile.Deserialize(raw: { [string]: any }): RoadProfile?
	if typeof(raw) ~= "table" or typeof(raw.Id) ~= "string" or typeof(raw.Components) ~= "table" then
		return nil
	end
	local components: { ProfileComponent } = {}
	for _, rawComponent in raw.Components :: { any } do
		if typeof(rawComponent.Kind) ~= "string" or typeof(rawComponent.WidthM) ~= "number" then
			return nil
		end
		if not table.find(ComponentKinds, rawComponent.Kind) then
			return nil
		end
		local rightBoundary: BoundaryRule? = nil
		if typeof(rawComponent.RightBoundary) == "string" and table.find(BoundaryRules, rawComponent.RightBoundary) then
			rightBoundary = rawComponent.RightBoundary :: BoundaryRule
		end
		table.insert(components, {
			Kind = rawComponent.Kind :: ComponentKind,
			WidthM = rawComponent.WidthM,
			Direction = if typeof(rawComponent.Direction) == "number" then rawComponent.Direction else 0,
			RightBoundary = rightBoundary,
		})
	end
	local surfaceOverrides: { [ComponentKind]: SurfaceOverride }? = nil
	if typeof(raw.SurfaceOverrides) == "table" then
		for rawKind, rawOverride in raw.SurfaceOverrides :: { [any]: any } do
			if
				typeof(rawKind) == "string"
				and table.find(ComponentKinds, rawKind)
				and typeof(rawOverride) == "table"
			then
				local material = RoadSurfaceMaterials.Sanitize(rawOverride.Material)
				local color = deserializeColor(rawOverride.Color)
				if material or color then
					if not surfaceOverrides then
						surfaceOverrides = {}
					end
					(surfaceOverrides :: { [ComponentKind]: SurfaceOverride })[rawKind :: ComponentKind] = {
						Material = material,
						Color = color,
					}
				end
			end
		end
	end
	return {
		Id = raw.Id,
		Name = if typeof(raw.Name) == "string" then raw.Name else raw.Id,
		Category = if typeof(raw.Category) == "string" then raw.Category else "Custom",
		BuiltIn = false,
		Components = components,
		KerbRestriction = if typeof(raw.KerbRestriction) == "string" then raw.KerbRestriction else nil,
		MarkingColor = if typeof(raw.MarkingColor) == "string" then raw.MarkingColor else nil,
		MarkingDashLengthM = if typeof(raw.MarkingDashLengthM) == "number" then raw.MarkingDashLengthM else nil,
		MarkingDashGapM = if typeof(raw.MarkingDashGapM) == "number" then raw.MarkingDashGapM else nil,
		KerbIndent = if typeof(raw.KerbIndent) == "boolean" then raw.KerbIndent else nil,
		SurfaceOverrides = surfaceOverrides,
	}
end

-- Built-in profile construction ----------------------------------------------

local function drive(widthM: number, direction: number): ProfileComponent
	return { Kind = "Drive" :: ComponentKind, WidthM = widthM, Direction = direction }
end
local function sidewalk(widthM: number): ProfileComponent
	return { Kind = "Sidewalk" :: ComponentKind, WidthM = widthM, Direction = 0 }
end
local function median(widthM: number): ProfileComponent
	return { Kind = "Median" :: ComponentKind, WidthM = widthM, Direction = 0 }
end
local function shoulder(widthM: number): ProfileComponent
	return { Kind = "Shoulder" :: ComponentKind, WidthM = widthM, Direction = 0 }
end
local function bike(widthM: number, direction: number): ProfileComponent
	return { Kind = "Bike" :: ComponentKind, WidthM = widthM, Direction = direction }
end
local function parking(widthM: number): ProfileComponent
	return { Kind = "Parking" :: ComponentKind, WidthM = widthM, Direction = 0 }
end

-- Build the default road set for a region. For right-hand traffic the
-- forward direction lanes go on the right half of the profile; for left-hand
-- traffic they go on the left half.
function RoadProfile.BuiltInProfiles(style: RegionStyles.RegionStyle): { RoadProfile }
	local lane = style.DefaultLaneWidthM
	-- Direction of the near-side (right for RHT, left for LHT) half
	local fwd = 1
	local back = -1

	local function twoWay(
		componentsLeftHalf: { ProfileComponent },
		middle: { ProfileComponent },
		mirror: boolean
	): { ProfileComponent }
		-- componentsLeftHalf is specified for right-hand traffic (oncoming on
		-- the left). For left-hand traffic regions, flip the direction signs.
		local result: { ProfileComponent } = {}
		local flip = if style.DriveOnLeft then -1 else 1
		for _, component in componentsLeftHalf do
			table.insert(result, {
				Kind = component.Kind,
				WidthM = component.WidthM,
				Direction = component.Direction * flip,
			})
		end
		for _, component in middle do
			table.insert(result, component)
		end
		if mirror then
			for i = #componentsLeftHalf, 1, -1 do
				local component = componentsLeftHalf[i]
				table.insert(result, {
					Kind = component.Kind,
					WidthM = component.WidthM,
					Direction = -component.Direction * flip,
				})
			end
		end
		return result
	end

	local function oneWayHighway(laneCount: number): { ProfileComponent }
		local innerShoulder = shoulder(math.max(style.ShoulderWidthM * 0.4, 0.8))
		local outerShoulder = shoulder(style.ShoulderWidthM)
		local components: { ProfileComponent } = {}
		table.insert(components, if style.DriveOnLeft then outerShoulder else innerShoulder)
		for _ = 1, laneCount do
			table.insert(components, drive(lane, fwd))
		end
		table.insert(components, if style.DriveOnLeft then innerShoulder else outerShoulder)
		return components
	end

	return {
		{
			Id = "builtin_two_lane",
			Name = "Two-Lane Street",
			Category = "Streets",
			BuiltIn = true,
			Components = twoWay({ sidewalk(style.SidewalkWidthM), drive(lane, back) }, {}, true),
		},
		{
			Id = "builtin_one_way",
			Name = "One-Way Street",
			Category = "Streets",
			BuiltIn = true,
			Components = {
				sidewalk(style.SidewalkWidthM),
				parking(style.ParkingLaneWidthM),
				drive(lane, fwd),
				drive(lane, fwd),
				sidewalk(style.SidewalkWidthM),
			},
		},
		{
			Id = "builtin_four_lane",
			Name = "Four-Lane Avenue",
			Category = "Avenues",
			BuiltIn = true,
			Components = twoWay(
				{ sidewalk(style.SidewalkWidthM), drive(lane, back), drive(lane, back) },
				{ median(style.MedianWidthM) },
				true
			),
		},
		{
			Id = "builtin_boulevard",
			Name = "Boulevard + Bike Lanes",
			Category = "Avenues",
			BuiltIn = true,
			Components = twoWay({
				sidewalk(style.SidewalkWidthM),
				bike(style.BikeLaneWidthM, back),
				drive(lane, back),
				drive(lane, back),
			}, { median(style.MedianWidthM) }, true),
		},
		{
			Id = "builtin_highway_oneway_1",
			Name = "One-Way Highway 1 Lane",
			Category = "Highways",
			BuiltIn = true,
			Components = oneWayHighway(1),
			KerbRestriction = "NoLine",
		},
		{
			Id = "builtin_highway_oneway_2",
			Name = "One-Way Highway 2 Lanes",
			Category = "Highways",
			BuiltIn = true,
			Components = oneWayHighway(2),
			KerbRestriction = "NoLine",
		},
		{
			Id = "builtin_highway_oneway_3",
			Name = "One-Way Highway 3 Lanes",
			Category = "Highways",
			BuiltIn = true,
			Components = oneWayHighway(3),
			KerbRestriction = "NoLine",
		},
		{
			Id = "builtin_highway_oneway_4",
			Name = "One-Way Highway 4 Lanes",
			Category = "Highways",
			BuiltIn = true,
			Components = oneWayHighway(4),
			KerbRestriction = "NoLine",
		},
		{
			Id = "builtin_highway_oneway_5",
			Name = "One-Way Highway 5 Lanes",
			Category = "Highways",
			BuiltIn = true,
			Components = oneWayHighway(5),
			KerbRestriction = "NoLine",
		},
		{
			Id = "builtin_highway",
			Name = "Highway 2x2",
			Category = "Highways",
			BuiltIn = true,
			Components = twoWay(
				{ shoulder(style.ShoulderWidthM), drive(lane, back), drive(lane, back) },
				{ median(style.MedianWidthM * 1.5) },
				true
			),
			-- Real motorway shoulders aren't marked with a kerb/edge line the
			-- way an ordinary street's kerb is - requested explicitly, off by
			-- default for highways (still toggleable per-road in the editor).
			KerbRestriction = "NoLine",
		},
		{
			Id = "builtin_highway_3",
			Name = "Highway 3x3",
			Category = "Highways",
			BuiltIn = true,
			Components = twoWay(
				{ shoulder(style.ShoulderWidthM), drive(lane, back), drive(lane, back), drive(lane, back) },
				{ median(style.MedianWidthM * 1.5) },
				true
			),
			KerbRestriction = "NoLine",
		},
		{
			Id = "builtin_path",
			Name = "Pedestrian Path",
			Category = "Paths",
			BuiltIn = true,
			Components = {
				sidewalk(style.SidewalkWidthM * 1.5),
			},
		},
	}
end

return RoadProfile
