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
}

-- Best icon for each cross-section component kind
Icons.ForKind = {
	Drive = Icons.Lane,
	Bike = Icons.Lane,
	Parking = Icons.Lane,
	Median = Icons.Median,
	Shoulder = Icons.Shoulder,
	Sidewalk = Icons.Sidewalk,
} :: { [string]: string }

return Icons
