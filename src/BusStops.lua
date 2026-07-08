--!strict
-- Bus stop markers: point-and-click decorations on a placed road's
-- Sidewalk/Parking parts, added via the pie menu's "Edit Road Segment" ->
-- "Add Bus Stop" flow. Purely a marker (position + icon) parented under the
-- road model, not a cross-section change - the road's lane layout is
-- untouched. For a real physical pull-in bay (a cross-section change), see
-- RoadBuilder.BuildWithBay / the pie menu's separate "Add Bus Bay" flow.
-- (See TODO.md for the still-deferred marking "stretch" mechanic.)

local HttpService = game:GetService("HttpService")

local Icons = require("./UI/Icons")

local ATTRIBUTE = "RW_BusStops"
local MARKER_FOLDER_NAME = "EasyRoadBusStops"
local MARKER_NAME = "EasyRoadBusStop"

-- Which lane-component kinds a bus stop can be placed on.
local ELIGIBLE_TARGET: { [string]: boolean } = {
	Sidewalk = true,
	Parking = true,
}

local BusStops = {}

function BusStops.IsEligibleTarget(instance: Instance?): boolean
	return instance ~= nil and instance:IsA("BasePart") and ELIGIBLE_TARGET[instance.Name] == true
end

function BusStops.IsMarker(instance: Instance?): boolean
	return instance ~= nil and instance.Name == MARKER_NAME
end

function BusStops.Get(model: Model): { Vector3 }
	local raw = model:GetAttribute(ATTRIBUTE)
	if typeof(raw) ~= "string" then
		return {}
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or typeof(decoded) ~= "table" then
		return {}
	end
	local points: { Vector3 } = {}
	for _, entry in decoded :: { any } do
		if
			typeof(entry) == "table"
			and typeof(entry.X) == "number"
			and typeof(entry.Y) == "number"
			and typeof(entry.Z) == "number"
		then
			table.insert(points, Vector3.new(entry.X, entry.Y, entry.Z))
		end
	end
	return points
end

local function save(model: Model, points: { Vector3 })
	local encoded = {}
	for _, point in points do
		table.insert(encoded, { X = point.X, Y = point.Y, Z = point.Z })
	end
	model:SetAttribute(ATTRIBUTE, HttpService:JSONEncode(encoded))
end

-- (Re)builds the visible marker instances from the stored attribute. Cheap
-- enough to call after every add/remove instead of diffing.
function BusStops.Render(model: Model)
	local existing = model:FindFirstChild(MARKER_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local points = BusStops.Get(model)
	if #points == 0 then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = MARKER_FOLDER_NAME
	for _, point in points do
		local marker = Instance.new("Part")
		marker.Name = MARKER_NAME
		marker.Shape = Enum.PartType.Cylinder
		marker.Size = Vector3.new(0.3, 1.4, 1.4)
		marker.CFrame = CFrame.new(point) * CFrame.Angles(0, 0, math.rad(90))
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanTouch = false
		marker.CastShadow = false
		marker.Color = Color3.fromRGB(255, 196, 64)
		marker.Material = Enum.Material.Neon
		marker.Transparency = 0.15
		marker.Parent = folder

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Icon"
		billboard.Size = UDim2.fromOffset(26, 26)
		billboard.AlwaysOnTop = true
		billboard.Parent = marker

		local icon = Instance.new("ImageLabel")
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromScale(1, 1)
		icon.Image = Icons.BusStop
		icon.Parent = billboard
	end
	folder.Parent = model
end

function BusStops.Add(model: Model, position: Vector3)
	local points = BusStops.Get(model)
	table.insert(points, position)
	save(model, points)
	BusStops.Render(model)
end

-- Removes the stop nearest to `position` if it's within `radius`. Returns
-- whether one was removed (so the caller can distinguish "removed a stop"
-- from "clicked empty space").
function BusStops.RemoveNear(model: Model, position: Vector3, radius: number): boolean
	local points = BusStops.Get(model)
	local bestIndex: number? = nil
	local bestDistance = radius
	for index, point in points do
		local distance = (point - position).Magnitude
		if distance <= bestDistance then
			bestDistance = distance
			bestIndex = index
		end
	end
	if not bestIndex then
		return false
	end
	table.remove(points, bestIndex)
	save(model, points)
	BusStops.Render(model)
	return true
end

return BusStops
