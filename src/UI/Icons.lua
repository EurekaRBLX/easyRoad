--!strict
-- Icon asset registry.
--
-- Module icons follow the British-standard module kit from the easyRoad
-- reference environment. Add new ids here rather than inlining them in
-- components so the whole icon set can be swapped or audited in one place.

local Icons = {
	Lane = "rbxassetid://94938412112676",
	Median = "rbxassetid://120501958565449",
	Shoulder = "rbxassetid://125978730755092",
	Sidewalk = "rbxassetid://102169083647798", -- Pavement / walkway
	Bike = "rbxassetid://117323310944439",
	Parking = "rbxassetid://135215443300853",
	-- Not surfaced in the palette yet - reserved for the future per-instance
	-- "click a placed road" panel (see TODO.md). BusLane replaces the old
	-- Bay/"Bus Bay" module concept; BusStop is a future decoration icon.
	BusLane = "rbxassetid://86439959503324",
	BusStop = "rbxassetid://97224093362859",
}

-- Best icon for each cross-section component kind
Icons.ForKind = {
	Drive = Icons.Lane,
	Bike = Icons.Bike,
	Parking = Icons.Parking,
	Bay = Icons.BusLane,
	Median = Icons.Median,
	Shoulder = Icons.Shoulder,
	Sidewalk = Icons.Sidewalk,
} :: { [string]: string }

return Icons
