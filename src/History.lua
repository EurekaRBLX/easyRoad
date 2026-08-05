--!strict
-- One safe ChangeHistoryService boundary for every persistent EasyRoad action.
--
-- Roblox only allows one active recording per plugin. TryBeginRecording returns
-- nil when an earlier action was not finished; mutating anyway makes later work
-- fall into the same undo stream. Record therefore refuses to run the action
-- unless Studio granted a recording, and it always finishes recordings even
-- when the action raises. Runtime failures are committed deliberately: a partly
-- mutated DataModel must retain an Undo recovery point instead of becoming an
-- unrecorded change.

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local History = {}

export type Action = () -> boolean

function History.Record(name: string, displayName: string, action: Action): (boolean, string?)
	local recording = ChangeHistoryService:TryBeginRecording(name, displayName)
	if not recording then
		local message = string.format(
			"Could not start '%s' because an earlier EasyRoad undo recording is still active. Reload EasyRoad, then try again.",
			displayName
		)
		warn("[EasyRoad] " .. message)
		return false, message
	end

	local changed = false
	local ok, failure = xpcall(function()
		changed = action()
	end, debug.traceback)

	-- On a runtime failure, commit whatever was already changed so Ctrl+Z is a
	-- recovery point. A clean no-op/preflight rejection is cancelled instead.
	local operation = if ok and not changed
		then Enum.FinishRecordingOperation.Cancel
		else Enum.FinishRecordingOperation.Commit
	local finished, finishFailure = pcall(function()
		ChangeHistoryService:FinishRecording(recording, operation)
	end)
	if not finished then
		local message = string.format("Could not finish '%s': %s", displayName, tostring(finishFailure))
		warn("[EasyRoad] " .. message)
		return false, message
	end

	if not ok then
		local message = string.format("%s failed: %s", displayName, tostring(failure))
		warn("[EasyRoad] " .. message)
		return false, message
	end
	return changed, nil
end

return History
