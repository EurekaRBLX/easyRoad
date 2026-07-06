--!strict
-- The road library: built-in road profiles (regenerated from the active
-- region style so they always match the grand settings) plus user-created
-- profiles persisted in plugin settings.

local RoadProfile = require("./RoadProfile")
local RegionStyles = require("./RegionStyles")

export type RoadLibrary = {
	GetAll: () -> { RoadProfile.RoadProfile },
	Get: (id: string) -> RoadProfile.RoadProfile?,
	GetDefault: () -> RoadProfile.RoadProfile,
	SaveUserProfile: (profile: RoadProfile.RoadProfile) -> (),
	DeleteUserProfile: (id: string) -> (),
	SetStyle: (style: RegionStyles.RegionStyle) -> (),
	SerializeUserProfiles: () -> { { [string]: any } },
}

local function createRoadLibrary(
	style: RegionStyles.RegionStyle,
	rawUserProfiles: { { [string]: any } }?
): RoadLibrary
	local currentStyle = style
	local builtIn = RoadProfile.BuiltInProfiles(currentStyle)
	local userProfiles: { RoadProfile.RoadProfile } = {}

	if rawUserProfiles then
		for _, raw in rawUserProfiles do
			local profile = RoadProfile.Deserialize(raw)
			if profile then
				table.insert(userProfiles, profile)
			end
		end
	end

	local library = {} :: RoadLibrary

	function library.GetAll(): { RoadProfile.RoadProfile }
		local all = {}
		for _, profile in builtIn do
			table.insert(all, profile)
		end
		for _, profile in userProfiles do
			table.insert(all, profile)
		end
		return all
	end

	function library.Get(id: string): RoadProfile.RoadProfile?
		for _, profile in builtIn do
			if profile.Id == id then
				return profile
			end
		end
		for _, profile in userProfiles do
			if profile.Id == id then
				return profile
			end
		end
		return nil
	end

	function library.GetDefault(): RoadProfile.RoadProfile
		return builtIn[1]
	end

	function library.SaveUserProfile(profile: RoadProfile.RoadProfile)
		profile.BuiltIn = false
		for i, existing in userProfiles do
			if existing.Id == profile.Id then
				userProfiles[i] = profile
				return
			end
		end
		table.insert(userProfiles, profile)
	end

	function library.DeleteUserProfile(id: string)
		for i, existing in userProfiles do
			if existing.Id == id then
				table.remove(userProfiles, i)
				return
			end
		end
	end

	-- Called when the region style changes in the grand settings: built-in
	-- roads are regenerated with the new region's dimensions and layout.
	function library.SetStyle(newStyle: RegionStyles.RegionStyle)
		currentStyle = newStyle
		builtIn = RoadProfile.BuiltInProfiles(newStyle)
	end

	function library.SerializeUserProfiles(): { { [string]: any } }
		local serialized = {}
		for _, profile in userProfiles do
			table.insert(serialized, RoadProfile.Serialize(profile))
		end
		return serialized
	end

	return library
end

return createRoadLibrary
