--!strict
-- Reads and writes the durable editor metadata carried by a generated
-- roundabout model.  The live, selectable ring stays in workspace.Roundabouts;
-- a controller junction (when present) owns topology while this model mirrors
-- the geometry and per-ring visual overrides needed by the roundabout editor.

export type RoundaboutData = {
	Center: Vector3,
	RadiusStuds: number,
	OuterRadiusStuds: number,
	LaneCount: number,
	LaneWidthM: number,
	JunctionId: string?,
	Markings: string?,
	Sidewalk: boolean?,
	Island: boolean?,
	LegacyConnected: boolean,
}

local RoundaboutInstance = {}

local ROUNDABOUTS_FOLDER_NAME = "Roundabouts"
local MARKING_STYLES = { "Continuous", "SolidLanes", "Turbo" }

local function finitePositive(value: any): number?
	if typeof(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge or value <= 0 then
		return nil
	end
	return value
end

function RoundaboutInstance.IsRoundabout(instance: Instance?): boolean
	return instance ~= nil and instance:IsA("Model") and instance:GetAttribute("RW_Roundabout") == true
end

-- Walk up from any clicked lane, marking, arm or island Part to the selectable
-- owner model.  Roundabout arms are nested Models, so a direct parent check is
-- not sufficient here.
function RoundaboutInstance.FindRoundabout(instance: Instance?): Model?
	local current = instance
	while current do
		if RoundaboutInstance.IsRoundabout(current) then
			return current :: Model
		end
		current = current.Parent
	end
	return nil
end

function RoundaboutInstance.FindByJunctionId(junctionId: string): Model?
	local folder = workspace:FindFirstChild(ROUNDABOUTS_FOLDER_NAME)
	if not folder then
		return nil
	end
	for _, child in folder:GetChildren() do
		if RoundaboutInstance.IsRoundabout(child) and child:GetAttribute("RW_JunctionId") == junctionId then
			return child :: Model
		end
	end
	return nil
end

function RoundaboutInstance.Read(model: Model): RoundaboutData?
	if not RoundaboutInstance.IsRoundabout(model) then
		return nil
	end
	local center = model:GetAttribute("RW_Center")
	local radius = model:GetAttribute("RW_RingRadius")
	local outerRadius = model:GetAttribute("RW_OuterRadius")
	local laneCount = model:GetAttribute("RW_LaneCount")
	local laneWidth = model:GetAttribute("RW_LaneWidthM")
	local validRadius = finitePositive(radius)
	local validOuterRadius = finitePositive(outerRadius)
	local validLaneCount = finitePositive(laneCount)
	local validLaneWidth = finitePositive(laneWidth)
	if
		typeof(center) ~= "Vector3"
		or not validRadius
		or not validOuterRadius
		or not validLaneCount
		or not validLaneWidth
	then
		return nil
	end

	local junctionId = model:GetAttribute("RW_JunctionId")
	local markings = model:GetAttribute("RW_RoundaboutMarkings")
	local sidewalk = model:GetAttribute("RW_RoundaboutSidewalk")
	local island = model:GetAttribute("RW_RoundaboutIsland")
	local explicitLegacy = model:GetAttribute("RW_LegacyConnected")
	-- Rings created before controller retention have no junction id.  Connected
	-- legacy rings can still be identified without a proximity scan because
	-- their generated feeder Models are owned by the ring itself.  A bare old
	-- ring has no RoundaboutArm descendant and remains safely editable as a
	-- standalone ring.
	local inferredLegacy = typeof(junctionId) ~= "string" and model:FindFirstChild("RoundaboutArm", true) ~= nil

	return {
		Center = center,
		RadiusStuds = validRadius,
		OuterRadiusStuds = validOuterRadius,
		LaneCount = math.max(1, math.floor(validLaneCount)),
		LaneWidthM = validLaneWidth,
		JunctionId = if typeof(junctionId) == "string" then junctionId else nil,
		Markings = if typeof(markings) == "string" and table.find(MARKING_STYLES, markings) then markings else nil,
		Sidewalk = if typeof(sidewalk) == "boolean" then sidewalk else nil,
		Island = if typeof(island) == "boolean" then island else nil,
		LegacyConnected = if typeof(explicitLegacy) == "boolean" then explicitLegacy else inferredLegacy,
	}
end

-- Editor-facing geometry setter.  Center belongs to placement and outer radius
-- is derived from the selected profile/style, so Rebuild is the only code that
-- updates those two values.
function RoundaboutInstance.SetGeometry(model: Model, radiusStuds: number, laneCount: number, laneWidthM: number)
	assert(finitePositive(radiusStuds), "roundabout radius must be a finite positive number")
	assert(finitePositive(laneCount), "roundabout lane count must be a finite positive number")
	assert(finitePositive(laneWidthM), "roundabout lane width must be a finite positive number")
	model:SetAttribute("RW_RingRadius", radiusStuds)
	model:SetAttribute("RW_LaneCount", math.max(1, math.floor(laneCount)))
	model:SetAttribute("RW_LaneWidthM", laneWidthM)
end

function RoundaboutInstance.SetMarkings(model: Model, markings: string?)
	model:SetAttribute("RW_RoundaboutMarkings", markings)
end

function RoundaboutInstance.SetSidewalk(model: Model, enabled: boolean?)
	model:SetAttribute("RW_RoundaboutSidewalk", enabled)
end

function RoundaboutInstance.SetIsland(model: Model, enabled: boolean?)
	model:SetAttribute("RW_RoundaboutIsland", enabled)
end

return RoundaboutInstance
