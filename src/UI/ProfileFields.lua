--!strict
-- Shared profile-level marking option rows: kerb restriction, kerb offset,
-- marking colour, and dash spacing.
--
-- Used by the road designer for both library roads and placed-road
-- editing, so the two stay in lockstep instead of drifting apart.
-- (Component-list editing lives in RoadDesigner's lane strip.)

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Components = require("./Components")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local Settings = require("../Settings")
local Locale = require("../Locale")
local Units = require("../Units")

local ProfileFields = {}

-- Kerb restriction / kerb offset / marking colour / dash spacing rows. These
-- apply to the whole road regardless of transitions (RoadBuilder always
-- reads them from ProfileStart), so they're usable even when the component
-- list itself isn't editable. Appends into `children` (a React children
-- dict) starting at `startOrder` and returns the next unused LayoutOrder.
function ProfileFields.InsertMarkingOptions(
	children: { [string]: any },
	profile: RoadProfile.RoadProfile,
	regionStyle: RegionStyles.RegionStyle,
	settings: Settings.EasyRoadSettings,
	startOrder: number,
	onChange: (transform: (profile: RoadProfile.RoadProfile) -> ()) -> ()
): number
	local order = startOrder

	children["PF_KerbRow"] = e(Components.Row, {
		LayoutOrder = order,
	}, {
		Label = e(Components.Label, { Text = Locale.Term(settings, "KerbLines"), LayoutOrder = 1, Width = 80 }),
		Dropdown = e(Components.Dropdown, {
			Options = {
				{ Id = "None", Text = "No restriction" },
				{ Id = "SingleYellow", Text = "Single yellow (no parking)" },
				{ Id = "DoubleYellow", Text = "Double yellow (no parking)" },
				{ Id = "NoLine", Text = "No line at all" },
			},
			SelectedId = profile.KerbRestriction or "None",
			OnSelected = function(id: string)
				onChange(function(copy)
					copy.KerbRestriction = if id == "None" then nil else id
				end)
			end,
			LayoutOrder = 2,
			Grow = true,
		}),
	})
	order += 1

	children["PF_KerbIndentRow"] = e(Components.Row, {
		LayoutOrder = order,
	}, {
		Label = e(Components.Label, { Text = Locale.Term(settings, "KerbLineOffset"), LayoutOrder = 1, Width = 80 }),
		Dropdown = e(Components.Dropdown, {
			Options = {
				{ Id = "Inset", Text = "Inset (default)" },
				{ Id = "Flush", Text = "Flush at edge" },
			},
			SelectedId = if profile.KerbIndent == false then "Flush" else "Inset",
			OnSelected = function(id: string)
				onChange(function(copy)
					copy.KerbIndent = if id == "Flush" then false else nil
				end)
			end,
			LayoutOrder = 2,
			Grow = true,
		}),
	})
	order += 1

	children["PF_ColourRow"] = e(Components.Row, {
		LayoutOrder = order,
	}, {
		Label = e(Components.Label, { Text = "Line colour", LayoutOrder = 1, Width = 80 }),
		Dropdown = e(Components.Dropdown, {
			Options = {
				{ Id = "Auto", Text = "Auto (region)" },
				{ Id = "White", Text = "White" },
				{ Id = "Yellow", Text = "Yellow" },
			},
			SelectedId = profile.MarkingColor or "Auto",
			OnSelected = function(id: string)
				onChange(function(copy)
					copy.MarkingColor = if id == "Auto" then nil else id
				end)
			end,
			LayoutOrder = 2,
			Grow = true,
		}),
	})
	order += 1

	-- Split across two narrow rows (rather than one packed row) so this
	-- fits inside a fixed-width column without spilling past its edge and
	-- forcing a horizontal scrollbar.
	children["PF_DashLengthRow"] = e(Components.Row, {
		LayoutOrder = order,
	}, {
		Label = e(Components.Label, {
			Text = "Dash length (" .. Units.LengthSuffix(settings) .. ")",
			LayoutOrder = 1,
			Width = 100,
		}),
		Field = e(Components.NumberField, {
			Value = Units.LengthFromM(settings, profile.MarkingDashLengthM or regionStyle.DashLengthM),
			Min = Units.LengthFromM(settings, 0.25),
			Max = Units.LengthFromM(settings, 20),
			OnChanged = function(value: number)
				onChange(function(copy)
					copy.MarkingDashLengthM = Units.LengthToM(settings, value)
				end)
			end,
			LayoutOrder = 2,
			Width = 48,
		}),
	})
	order += 1

	children["PF_DashGapRow"] = e(Components.Row, {
		LayoutOrder = order,
	}, {
		Label = e(Components.Label, {
			Text = "Dash gap (" .. Units.LengthSuffix(settings) .. ")",
			LayoutOrder = 1,
			Width = 100,
		}),
		Field = e(Components.NumberField, {
			Value = Units.LengthFromM(settings, profile.MarkingDashGapM or regionStyle.DashGapM),
			Min = Units.LengthFromM(settings, 0.25),
			Max = Units.LengthFromM(settings, 30),
			OnChanged = function(value: number)
				onChange(function(copy)
					copy.MarkingDashGapM = Units.LengthToM(settings, value)
				end)
			end,
			LayoutOrder = 2,
			Width = 48,
		}),
		Reset = (profile.MarkingDashLengthM ~= nil or profile.MarkingDashGapM ~= nil) and e(Components.Button, {
			Text = "Reset",
			OnClick = function()
				onChange(function(copy)
					copy.MarkingDashLengthM = nil
					copy.MarkingDashGapM = nil
				end)
			end,
			LayoutOrder = 3,
		}),
	})
	order += 1

	return order
end

return ProfileFields
