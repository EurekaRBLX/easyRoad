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

export type ComponentKind = "Drive" | "Sidewalk" | "Median" | "Shoulder" | "Bike" | "Parking"

export type ProfileComponent = {
	Kind: ComponentKind,
	WidthM: number,
	Direction: number, -- +1 forward, -1 backward, 0 = not directional
}

export type RoadProfile = {
	Id: string,
	Name: string,
	Category: string,
	BuiltIn: boolean,
	Components: { ProfileComponent },
}

local ComponentKinds: { ComponentKind } = {
	"Drive" :: ComponentKind,
	"Sidewalk" :: ComponentKind,
	"Median" :: ComponentKind,
	"Shoulder" :: ComponentKind,
	"Bike" :: ComponentKind,
	"Parking" :: ComponentKind,
}

local RoadProfile = {}

RoadProfile.ComponentKinds = ComponentKinds

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
}

function RoadProfile.IsDirectional(kind: ComponentKind): boolean
	return DIRECTIONAL[kind] == true
end

function RoadProfile.IsRoadway(kind: ComponentKind): boolean
	return ROADWAY[kind] == true
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
		})
	end
	return {
		Id = profile.Id,
		Name = profile.Name,
		Category = profile.Category,
		BuiltIn = profile.BuiltIn,
		Components = components,
	}
end

-- Match two profiles for a widening / narrowing transition segment.
--
-- Returns two component lists of equal length. Where one profile has a
-- component that the other lacks, a zero-width copy is inserted into the
-- shorter one so that the extra lanes taper in or out smoothly along the
-- transition. Components are matched greedily from both outer edges inward
-- (the natural case: adding/dropping lanes happens in the middle of the
-- roadway, sidewalks and shoulders stay put at the edges).
function RoadProfile.MatchForTransition(
	a: RoadProfile,
	b: RoadProfile
): ({ ProfileComponent }, { ProfileComponent })
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
	while right < (na - left) and right < (nb - left)
		and ca[na - right].Kind == cb[nb - right].Kind do
		right += 1
	end

	local function zeroOf(component: ProfileComponent): ProfileComponent
		return { Kind = component.Kind, WidthM = 0, Direction = component.Direction }
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

function RoadProfile.Serialize(profile: RoadProfile): { [string]: any }
	local components = {}
	for _, component in profile.Components do
		table.insert(components, {
			Kind = component.Kind,
			WidthM = component.WidthM,
			Direction = component.Direction,
		})
	end
	return {
		Id = profile.Id,
		Name = profile.Name,
		Category = profile.Category,
		Components = components,
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
		table.insert(components, {
			Kind = rawComponent.Kind :: ComponentKind,
			WidthM = rawComponent.WidthM,
			Direction = if typeof(rawComponent.Direction) == "number" then rawComponent.Direction else 0,
		})
	end
	return {
		Id = raw.Id,
		Name = if typeof(raw.Name) == "string" then raw.Name else raw.Id,
		Category = if typeof(raw.Category) == "string" then raw.Category else "Custom",
		BuiltIn = false,
		Components = components,
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

	local function twoWay(componentsLeftHalf: { ProfileComponent }, middle: { ProfileComponent }, mirror: boolean): { ProfileComponent }
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

	return {
		{
			Id = "builtin_two_lane",
			Name = "Two-Lane Street",
			Category = "Streets",
			BuiltIn = true,
			Components = twoWay(
				{ sidewalk(style.SidewalkWidthM), drive(lane, back) },
				{},
				true
			),
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
			Components = twoWay(
				{ sidewalk(style.SidewalkWidthM), bike(style.BikeLaneWidthM, back), drive(lane, back), drive(lane, back) },
				{ median(style.MedianWidthM) },
				true
			),
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
