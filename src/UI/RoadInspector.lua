--!strict
-- Placed-road editing wrapper: binds the road designer to a RoadEditSession.
--
-- Select a placed road in the viewport (Studio's ordinary selection tool -
-- no need to activate easyRoad's build tool) and the designer appears at
-- the bottom of the viewport, editing that road's lanes, kerb rules, and
-- markings in place. Apply rebuilds just that model as one undo step.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RoadDesigner = require("./RoadDesigner")
local RoadProfile = require("../RoadProfile")
local RegionStyles = require("../RegionStyles")
local RoadEditSession = require("../RoadEditSession")
local Settings = require("../Settings")

local function RoadInspector(props: {
	PluginObj: Plugin,
	Session: RoadEditSession.RoadEditSession,
	RegionStyle: RegionStyles.RegionStyle,
	Settings: Settings.EasyRoadSettings,
})
	local session = props.Session
	local profile = session.GetProfile()
	if not profile then
		-- Selected a Road model, but it predates the attribute set the
		-- designer needs (placed by an older plugin version) - nothing to
		-- edit without a curve to rebuild from.
		return e("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, 0),
			Size = UDim2.new(0, 320, 0, 0),
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
			Header = e(Components.Section, { Text = "Selected Road", First = true, LayoutOrder = 1 }),
			Note = e(Components.Label, {
				Text = "This road was placed by an older version of easyRoad and can't "
					.. "be edited in place - delete and re-place it to use the designer.",
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

	local dirty = session.IsDirty()
	local actions: { RoadDesigner.DesignerAction } = {
		{
			Text = if dirty then "Apply to Road" else "Applied",
			Selected = dirty,
			OnClick = session.Apply,
		},
	}
	if dirty then
		table.insert(actions, { Text = "Revert", OnClick = session.Revert })
	end
	table.insert(actions, { Text = "Close", OnClick = session.Deselect })

	local isTransition = session.IsTransition()
	return e(RoadDesigner.Panel, {
		PluginObj = props.PluginObj,
		Profile = profile,
		Settings = props.Settings,
		RegionStyle = props.RegionStyle,
		Subtitle = if isTransition
			then "Transition road: lane editing is disabled, but kerb / colour / dash options apply to the whole road."
			else "Editing a placed road",
		ReadOnlyLanes = isTransition,
		OnChange = function(transform: (profile: RoadProfile.RoadProfile) -> ())
			local copy = RoadProfile.Clone(profile)
			transform(copy)
			session.SetProfile(copy)
		end,
		OnRename = function(name: string)
			local copy = RoadProfile.Clone(profile)
			copy.Name = name
			session.SetProfile(copy)
		end,
		Actions = actions,
	})
end

return RoadInspector
