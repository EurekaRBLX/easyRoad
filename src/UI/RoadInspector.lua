--!strict
-- Contextual panel for an already-placed road.
--
-- Select a placed road in the viewport (Studio's ordinary selection tool -
-- no need to activate easyRoad's build tool) and this panel appears,
-- letting you retouch its cross-section, kerb rules, and markings without
-- deleting and re-placing it.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local ProfileFields = require("./ProfileFields")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local RoadEditSession = require("../RoadEditSession")

local function RoadInspector(props: {
	Session: RoadEditSession.RoadEditSession,
	RegionStyle: RegionStyles.RegionStyle,
})
	local session = props.Session
	local profile = session.GetProfile()
	if not profile then
		-- Selected a Road model, but it predates the attribute set this
		-- inspector needs (placed by an older plugin version) - nothing to
		-- edit here without a curve to rebuild from.
		return e("Frame", {
			Size = UDim2.fromScale(1, 1),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = Theme.GLASS_BG,
			BackgroundTransparency = Theme.GLASS_TRANSPARENCY,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.CORNER_RADIUS) }),
			Stroke = e("UIStroke", {
				Color = Theme.GLASS_STROKE,
				Transparency = Theme.GLASS_STROKE_TRANSPARENCY,
				Thickness = 1,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}),
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, Theme.PADDING),
				PaddingRight = UDim.new(0, Theme.PADDING),
				PaddingTop = UDim.new(0, Theme.PADDING),
				PaddingBottom = UDim.new(0, Theme.PADDING),
			}),
			Layout = e("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),
			Header = e(Components.Section, { Text = "Selected Road", LayoutOrder = 1 }),
			Note = e(Components.Label, {
				Text = "This road was placed by an older version of easyRoad and can't "
					.. "be edited in place - delete and re-place it to use the inspector.",
				Dim = true,
				LayoutOrder = 2,
			}),
			Close = e(Components.Button, {
				Text = "Close",
				OnClick = session.Deselect,
				LayoutOrder = 3,
			}),
		})
	end

	local function updateProfile(transform: (profile: RoadProfile.RoadProfile) -> ())
		local copy = RoadProfile.Clone(profile)
		transform(copy)
		session.SetProfile(copy)
	end

	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, Theme.PADDING),
			PaddingRight = UDim.new(0, Theme.PADDING),
			PaddingTop = UDim.new(0, Theme.PADDING),
			PaddingBottom = UDim.new(0, Theme.PADDING),
		}),
		Header = e(Components.Section, {
			Text = "Selected Road",
			LayoutOrder = 1,
		}),
		NameLabel = e(Components.Label, {
			Text = profile.Name,
			Dim = true,
			LayoutOrder = 2,
		}),
	}

	local nextOrder = 3
	local isTransition = session.IsTransition()
	if isTransition then
		children.TransitionNote = e(Components.Label, {
			Text = "This road transitions between two profiles - lane-by-lane editing "
				.. "isn't supported here yet. Kerb lines / colour / dash spacing below "
				.. "still apply to the whole road.",
			Dim = true,
			LayoutOrder = nextOrder,
		})
		nextOrder += 1
		nextOrder = ProfileFields.InsertMarkingOptions(children, profile, props.RegionStyle, nextOrder, updateProfile)
	else
		nextOrder = ProfileFields.Insert(children, profile, props.RegionStyle, nextOrder, updateProfile)
	end

	local dirty = session.IsDirty()
	children.Actions = e(Components.Row, {
		LayoutOrder = nextOrder,
	}, {
		Apply = e(Components.Button, {
			Text = if dirty then "Apply to Road" else "Applied",
			Selected = dirty,
			OnClick = session.Apply,
			LayoutOrder = 1,
		}),
		Revert = dirty and e(Components.Button, {
			Text = "Revert",
			OnClick = session.Revert,
			LayoutOrder = 2,
		}),
		Deselect = e(Components.Button, {
			Text = "Close",
			OnClick = session.Deselect,
			LayoutOrder = 3,
		}),
	})

	children.Corner = e("UICorner", {
		CornerRadius = UDim.new(0, Theme.CORNER_RADIUS),
	})
	children.Stroke = e("UIStroke", {
		Color = Theme.GLASS_STROKE,
		Transparency = Theme.GLASS_STROKE_TRANSPARENCY,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})

	return e("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.GLASS_BG,
		BackgroundTransparency = Theme.GLASS_TRANSPARENCY,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(1, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
	}, children)
end

return RoadInspector
