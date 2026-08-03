--!strict
--[[
	EasyAPI TopBarBridge
	====================

	Shared protocol so multiple easy* Studio plugins can show top mode bars
	without stacking on top of each other.

	Why this exists
	---------------
	easyRoad, easyRail, easyLight (and future siblings) each draw a glass
	pill at the top centre of the viewport. They are separate plugins with
	separate Luau VMs, so they cannot share a Lua table. They *can* share
	Instances under CoreGui. This module turns that into a tiny registry:

	  CoreGui
	    EasyAPI                  (Folder)
	      TopBarStack            (Folder)
	        easyRoad            (Folder)  attributes: OpenedAt, Height, ...
	        easyRail
	        easyLight

	Stacking rule
	-------------
	Slots are sorted by OpenedAt ascending (oldest first). The plugin that
	has been open the longest sits at the top of the viewport (BASE_Y).
	Newer plugins stack below it, each claiming its Height in pixels.

	When a plugin closes (or unloads), it destroys its slot; the remaining
	bars recompact automatically.

	Integration (copy this file into each plugin as src/EasyAPI/TopBarBridge.lua)
	---------------------------------------------------------------------------
	  local TopBarBridge = require("./EasyAPI/TopBarBridge")

	  local handle = TopBarBridge.register({
	      Id = "easyRoad",          -- unique across the easy* family
	      DisplayName = "easyRoad", -- optional, for debugging
	      Height = 50,              -- bar + gap claimed in the stack
	  })
	  local topOffset = handle:GetOffset()
	  handle:OnChanged(function(offset)
	      topOffset = offset
	      -- re-render TopBar with TopOffset = topOffset
	  end)

	  -- on plugin UI close / plugin.Unloading:
	  handle:Unregister()

	  -- TopBar uses: Position = UDim2.new(0.5, 0, 0, topOffset)

	Scalability
	-----------
	Any new easy* tool only needs this module and a unique Id. No central
	service process, no package manager, no version lock between plugins
	beyond ProtocolVersion (older/newer still stack if they share the same
	folder shape).

	Source of truth: https://github.com/gamesonrblx/easyAPI
	Vendored into each consumer so plugins stay independently installable.
]]

local CoreGui = game:GetService("CoreGui")

local PROTOCOL_VERSION = 1
local ROOT_NAME = "EasyAPI"
local STACK_NAME = "TopBarStack"
-- Matches the historical single-plugin bar position (TopBar Position.Y.Offset).
local BASE_Y = 8
-- 42px bar + ~8px breathing room before the next bar.
local DEFAULT_HEIGHT = 50

export type Registration = {
	Id: string,
	Height: number?,
	DisplayName: string?,
}

export type Handle = {
	GetOffset: (self: Handle) -> number,
	OnChanged: (self: Handle, callback: (offset: number) -> ()) -> (() -> ()),
	SetHeight: (self: Handle, height: number) -> (),
	Unregister: (self: Handle) -> (),
}

local function ensureStack(): Folder
	local root = CoreGui:FindFirstChild(ROOT_NAME)
	if not root then
		local created = Instance.new("Folder")
		created.Name = ROOT_NAME
		created:SetAttribute("ProtocolVersion", PROTOCOL_VERSION)
		created.Parent = CoreGui
		-- Another plugin may have won a simultaneous create.
		local winner = CoreGui:FindFirstChild(ROOT_NAME)
		if winner and winner ~= created then
			created:Destroy()
			root = winner
		else
			root = created
		end
	end

	local stack = root:FindFirstChild(STACK_NAME)
	if not stack then
		local created = Instance.new("Folder")
		created.Name = STACK_NAME
		created.Parent = root
		local winner = root:FindFirstChild(STACK_NAME)
		if winner and winner ~= created then
			created:Destroy()
			stack = winner
		else
			stack = created
		end
	end

	return stack :: Folder
end

local function slotHeight(slot: Instance): number
	local h = slot:GetAttribute("Height")
	if typeof(h) == "number" and h > 0 then
		return h
	end
	return DEFAULT_HEIGHT
end

local function collectSlots(stack: Folder): { Folder }
	local slots: { Folder } = {}
	for _, child in stack:GetChildren() do
		if child:IsA("Folder") and typeof(child:GetAttribute("OpenedAt")) == "number" then
			table.insert(slots, child)
		end
	end
	table.sort(slots, function(a, b)
		local aT = a:GetAttribute("OpenedAt") :: number
		local bT = b:GetAttribute("OpenedAt") :: number
		if aT == bT then
			-- Stable tie-break so layout does not flicker.
			return a.Name < b.Name
		end
		-- Oldest (longest open) first → top of viewport.
		return aT < bT
	end)
	return slots
end

local function computeOffset(stack: Folder, id: string): number
	local y = BASE_Y
	for _, slot in collectSlots(stack) do
		if slot.Name == id then
			return y
		end
		y += slotHeight(slot)
	end
	return BASE_Y
end

local function register(registration: Registration): Handle
	assert(type(registration.Id) == "string" and registration.Id ~= "", "TopBarBridge.register: Id is required")

	local id = registration.Id
	local stack = ensureStack()

	-- Re-registering the same Id replaces the old slot (e.g. hot reload).
	local existing = stack:FindFirstChild(id)
	if existing then
		existing:Destroy()
	end

	local slot = Instance.new("Folder")
	slot.Name = id
	slot:SetAttribute("OpenedAt", os.clock())
	slot:SetAttribute("Height", registration.Height or DEFAULT_HEIGHT)
	slot:SetAttribute("ProtocolVersion", PROTOCOL_VERSION)
	if registration.DisplayName then
		slot:SetAttribute("DisplayName", registration.DisplayName)
	end
	slot.Parent = stack

	local callbacks: { (number) -> () } = {}
	local connections: { RBXScriptConnection } = {}
	local attributeConnections: { [Instance]: { RBXScriptConnection } } = {}
	local alive = true
	local offset = computeOffset(stack, id)

	local function notify()
		if not alive then
			return
		end
		local nextOffset = computeOffset(stack, id)
		if nextOffset == offset then
			return
		end
		offset = nextOffset
		for _, callback in callbacks do
			task.spawn(callback, offset)
		end
	end

	local function unwatch(child: Instance)
		local list = attributeConnections[child]
		if list then
			for _, cn in list do
				cn:Disconnect()
			end
			attributeConnections[child] = nil
		end
	end

	local function watch(child: Instance)
		if not child:IsA("Folder") then
			return
		end
		unwatch(child)
		attributeConnections[child] = {
			child:GetAttributeChangedSignal("Height"):Connect(notify),
			child:GetAttributeChangedSignal("OpenedAt"):Connect(notify),
		}
	end

	for _, child in stack:GetChildren() do
		watch(child)
	end

	table.insert(connections, stack.ChildAdded:Connect(function(child)
		watch(child)
		notify()
	end))
	table.insert(connections, stack.ChildRemoved:Connect(function(child)
		unwatch(child)
		notify()
	end))

	local handle: Handle = {
		GetOffset = function(_self: Handle): number
			return offset
		end,

		OnChanged = function(_self: Handle, callback: (offset: number) -> ()): () -> ()
			table.insert(callbacks, callback)
			return function()
				local index = table.find(callbacks, callback)
				if index then
					table.remove(callbacks, index)
				end
			end
		end,

		SetHeight = function(_self: Handle, height: number)
			if alive and slot.Parent then
				slot:SetAttribute("Height", height)
			end
		end,

		Unregister = function(_self: Handle)
			if not alive then
				return
			end
			alive = false
			for _, cn in connections do
				cn:Disconnect()
			end
			table.clear(connections)
			local watched: { Instance } = {}
			for child in attributeConnections do
				table.insert(watched, child)
			end
			for _, child in watched do
				unwatch(child)
			end
			table.clear(callbacks)
			if slot.Parent then
				slot:Destroy()
			end
		end,
	}

	return handle
end

return {
	PROTOCOL_VERSION = PROTOCOL_VERSION,
	BASE_Y = BASE_Y,
	DEFAULT_HEIGHT = DEFAULT_HEIGHT,
	register = register,
}
