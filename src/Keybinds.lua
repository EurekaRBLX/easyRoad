--!strict
-- Rebindable keybinds: each action can have multiple bound inputs (e.g.
-- Cancel Placement defaults to Escape, right-click, AND middle-click).
--
-- Bindings are stored as plain strings (KeyCode names like "R", or the
-- sentinels "MouseButton1"/"MouseButton2"/"MouseButton3") rather than Enum
-- values, matching this codebase's existing pattern of keeping anything
-- that touches plugin settings storage as plain serializable data (see
-- RoadProfile's Kind strings).

export type ActionId = "ElevationUp" | "ElevationDown" | "CancelPlacement"

export type KeybindMap = { [string]: { string } }

local Keybinds = {}

local ACTIONS: { { Id: ActionId, Label: string } } = {
	{ Id = "ElevationUp" :: ActionId, Label = "Raise elevation" },
	{ Id = "ElevationDown" :: ActionId, Label = "Lower elevation" },
	{ Id = "CancelPlacement" :: ActionId, Label = "Cancel placement" },
}

local DEFAULTS: KeybindMap = {
	ElevationUp = { "R" },
	ElevationDown = { "F" },
	CancelPlacement = { "Escape", "MouseButton2", "MouseButton3" },
}

Keybinds.Actions = ACTIONS
Keybinds.Defaults = DEFAULTS

-- Human-readable label for a bound input string.
function Keybinds.Describe(bound: string): string
	if bound == "MouseButton1" then
		return "Left Click"
	elseif bound == "MouseButton2" then
		return "Right Click"
	elseif bound == "MouseButton3" then
		return "Middle Click"
	end
	return bound
end

-- Converts a live InputObject into its bound-input string form, or nil if
-- it's not a bindable input (e.g. mouse movement).
function Keybinds.CaptureLabel(input: InputObject): string?
	if input.UserInputType == Enum.UserInputType.Keyboard then
		return input.KeyCode.Name
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		return "MouseButton1"
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		return "MouseButton2"
	elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
		return "MouseButton3"
	end
	return nil
end

-- True if an InputObject matches any of an action's bound inputs.
function Keybinds.Matches(bindings: { string }?, input: InputObject): boolean
	if not bindings then
		return false
	end
	local label = Keybinds.CaptureLabel(input)
	if not label then
		return false
	end
	return table.find(bindings, label) ~= nil
end

function Keybinds.Sanitize(raw: any): KeybindMap
	local result: KeybindMap = {}
	for _, action in Keybinds.Actions do
		local rawList = if typeof(raw) == "table" then raw[action.Id] else nil
		local list: { string } = {}
		if typeof(rawList) == "table" then
			for _, value in rawList :: { any } do
				if typeof(value) == "string" then
					table.insert(list, value)
				end
			end
		end
		if #list == 0 then
			list = table.clone(Keybinds.Defaults[action.Id])
		end
		result[action.Id] = list
	end
	return result
end

return Keybinds
