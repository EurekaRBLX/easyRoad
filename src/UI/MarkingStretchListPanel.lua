--!strict
-- "Edit Lane Markings"'s own destination: lists a placed road's existing
-- marking stretches with a per-stretch Remove button. Deliberately NOT the
-- full RoadDesigner - a stretch is a road-local, spatial edit (see
-- RoadEditSession's Stretch Marking flow), not a whole-profile one, so a
-- full cross-section editor isn't the right place to just look at/manage
-- them. Confirm/Back live on the pie menu above this, same convention as
-- BayDraftPanel/MarkingStretchPanel.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local RoadDesigner = require("./RoadDesigner")
local Markings = require("../Mesh/Markings")

local LINE_TYPE_LABELS: { [string]: string } = {
	None = "No line",
	Solid = "Solid",
	Dashed = "Dashed",
	DoubleSolid = "Double solid",
	DoubleDashed = "Double dashed",
	SolidDash = "Solid/dash",
	DashSolid = "Dash/solid",
}

local function MarkingStretchListPanel(props: {
	Stretches: { Markings.MarkingStretch },
	OnRemove: (index: number) -> (),
})
	local children: { [string]: any } = {}
	RoadDesigner.DecorateCard(children)
	children.Header = e(Components.Section, { Text = "Marking Stretches", First = true, LayoutOrder = 1 })

	if #props.Stretches == 0 then
		children.Empty = e(Components.Label, {
			Text = "No marking stretches on this road yet - use Stretch Marking on the segment menu to add one.",
			Dim = true,
			LayoutOrder = 2,
		})
	else
		local order = 2
		for index, stretch in props.Stretches do
			order += 1
			children["Label" .. index] = e(Components.Label, {
				Text = string.format(
					"%d-%d studs (%s)",
					math.floor(stretch.FromStationStuds),
					math.floor(stretch.ToStationStuds),
					LINE_TYPE_LABELS[stretch.Line] or stretch.Line
				),
				LayoutOrder = order,
			})
			order += 1
			children["Remove" .. index] = e(Components.Button, {
				Text = "Remove",
				Danger = true,
				Size = UDim2.new(0, 90, 0, Theme.ROW_HEIGHT),
				LayoutOrder = order,
				OnClick = function()
					props.OnRemove(index)
				end,
			})
		end
	end

	local scrollProps = Components.ScrollBar()
	scrollProps.Size = UDim2.fromScale(1, 1)
	scrollProps.BackgroundColor3 = Theme.GLASS_BG
	scrollProps.BackgroundTransparency = Theme.GLASS_TRANSPARENCY
	scrollProps.BorderSizePixel = 0
	scrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollProps.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollProps.ScrollingDirection = Enum.ScrollingDirection.Y

	return e("ScrollingFrame", scrollProps, children)
end

return MarkingStretchListPanel
