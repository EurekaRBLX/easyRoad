--!strict
-- The region library: built-in region presets (UK/HK/SG/EU/US/JP/AU) plus
-- user-created presets persisted in plugin settings - mirrors
-- RoadLibrary.lua's shape exactly, one level up (regions instead of roads).

local RegionStyles = require("./RegionStyles")

export type RegionLibrary = {
	GetAll: () -> { RegionStyles.RegionStyle },
	Get: (id: string) -> RegionStyles.RegionStyle,
	SaveUserRegion: (style: RegionStyles.RegionStyle) -> (),
	DeleteUserRegion: (id: string) -> (),
	SerializeUserRegions: () -> { { [string]: any } },
}

local function createRegionLibrary(rawUserRegions: { { [string]: any } }?): RegionLibrary
	local userRegions: { RegionStyles.RegionStyle } = {}

	if rawUserRegions then
		for _, raw in rawUserRegions do
			local style = RegionStyles.Deserialize(raw)
			if style then
				table.insert(userRegions, style)
			end
		end
	end

	local library = {} :: RegionLibrary

	function library.GetAll(): { RegionStyles.RegionStyle }
		local all = {}
		for _, style in RegionStyles.All do
			table.insert(all, style)
		end
		for _, style in userRegions do
			table.insert(all, style)
		end
		return all
	end

	function library.Get(id: string): RegionStyles.RegionStyle
		for _, style in RegionStyles.All do
			if style.Id == id then
				return style
			end
		end
		for _, style in userRegions do
			if style.Id == id then
				return style
			end
		end
		return RegionStyles.Get(id) -- Falls back to UK
	end

	function library.SaveUserRegion(style: RegionStyles.RegionStyle)
		style.BuiltIn = false
		for i, existing in userRegions do
			if existing.Id == style.Id then
				userRegions[i] = style
				return
			end
		end
		table.insert(userRegions, style)
	end

	function library.DeleteUserRegion(id: string)
		for i, existing in userRegions do
			if existing.Id == id then
				table.remove(userRegions, i)
				return
			end
		end
	end

	function library.SerializeUserRegions(): { { [string]: any } }
		local serialized = {}
		for _, style in userRegions do
			table.insert(serialized, RegionStyles.Serialize(style))
		end
		return serialized
	end

	return library
end

return createRegionLibrary
