--!strict
-- Dedicated import/management surface for literal Roblox road/structure
-- Models. Placement and placed-road inspectors only choose an existing asset;
-- ownership operations live here so building remains focused on alignment.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Components = require("./Components")
local RoadDesigner = require("./RoadDesigner")
local StructureAssets = require("../StructureAssets")
local Theme = require("./Theme")

local function paragraph(text: string, order: number)
	return e("TextLabel", {
		Text = text,
		TextColor3 = Theme.DIM,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = Theme.FONT,
		TextSize = Theme.TEXT_SIZE,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = order,
	})
end

local function RoadAssetsPanel(props: {
	Assets: { StructureAssets.AssetInfo },
	SelectedId: string?,
	Status: string?,
	UsageCount: number,
	OnSelect: (id: string?) -> (),
	OnImport: (kind: StructureAssets.AssetKind) -> (),
	OnExport: (id: string) -> (),
	OnRename: (id: string, name: string) -> (),
	OnDelete: (id: string) -> (),
	OnClose: () -> (),
})
	local selected: StructureAssets.AssetInfo? = nil
	local options: { Components.DropdownOption } = {}
	for _, asset in props.Assets do
		table.insert(options, {
			Id = asset.Id,
			Text = string.format("%s  |  %s", asset.Name, asset.Kind),
		})
		if asset.Id == props.SelectedId then
			selected = asset
		end
	end

	local children: { [string]: any } = {}
	RoadDesigner.DecorateCard(children)
	children.Header = e(Components.Section, { Text = "Import / Manage Road Assets", First = true, LayoutOrder = 1 })
	children.Help = paragraph(
		"Select a Workspace Model, then choose how EasyRoad should use it. Ground road modules replace the generated surface; viaduct and tunnel modules accompany their matching structure mode.",
		2
	)
	children.ImportGround = e(Components.Button, {
		Text = "Import Selection as Ground Road",
		LayoutOrder = 3,
		OnClick = function()
			props.OnImport("Ground")
		end,
	})
	children.ImportStructure = e(Components.Row, { LayoutOrder = 4 }, {
		Viaduct = e(Components.Button, {
			Text = "Import Selection as Viaduct",
			Grow = true,
			LayoutOrder = 1,
			OnClick = function()
				props.OnImport("Viaduct")
			end,
		}),
		Tunnel = e(Components.Button, {
			Text = "Import Selection as Tunnel",
			Grow = true,
			LayoutOrder = 2,
			OnClick = function()
				props.OnImport("Tunnel")
			end,
		}),
	})
	children.Library = e(Components.Section, { Text = "Asset Library", LayoutOrder = 5 })

	if #options > 0 then
		children.Picker = e(Components.Row, { LayoutOrder = 6 }, {
			Label = e(Components.Label, { Text = "Asset", Width = 54, LayoutOrder = 1 }),
			Field = e(Components.Dropdown, {
				Options = options,
				SelectedId = if selected then selected.Id else options[1].Id,
				Grow = true,
				LayoutOrder = 2,
				OnSelected = function(id: string)
					props.OnSelect(id)
				end,
			}),
		})
	else
		children.Empty = paragraph("No custom road assets imported yet.", 6)
	end

	local exportId = if selected then selected.Id else nil
	children.Export = e(Components.Button, {
		Text = "Export Selected Asset to Workspace",
		Disabled = exportId == nil,
		LayoutOrder = 10,
		OnClick = function()
			if exportId then
				props.OnExport(exportId)
			end
		end,
	})

	if selected then
		local asset = selected :: StructureAssets.AssetInfo
		children.Name = e(Components.Row, { LayoutOrder = 7 }, {
			Label = e(Components.Label, { Text = "Name", Width = 54, LayoutOrder = 1 }),
			Field = e(Components.TextField, {
				Value = asset.Name,
				Width = 430,
				LayoutOrder = 2,
				OnChanged = function(name: string)
					props.OnRename(asset.Id, name)
				end,
			}),
		})
		children.Meta = paragraph(
			string.format(
				"%s  |  %.1f stud socket chord  |  %.1f x %.1f x %.1f stud bounds  |  %s sockets  |  used by %d placed road%s",
				if asset.Kind == "Ground" then "Ground road module" else asset.Kind .. " module",
				asset.LengthStuds,
				asset.WidthStuds,
				asset.HeightStuds,
				asset.DepthStuds,
				asset.SocketMode:lower(),
				props.UsageCount,
				if props.UsageCount == 1 then "" else "s"
			),
			8
		)
		if asset.Warnings then
			children.Warning = e("TextLabel", {
				Text = "Check: " .. asset.Warnings,
				TextColor3 = Theme.WARNING,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Font = Theme.FONT,
				TextSize = Theme.TEXT_SIZE,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = 9,
			})
		end
		children.Delete = e(Components.Button, {
			Text = "Delete Selected Asset",
			Danger = true,
			LayoutOrder = 11,
			OnClick = function()
				props.OnDelete(asset.Id)
			end,
		})
	end

	if props.Status then
		children.Status = paragraph(props.Status, 12)
	end
	children.Close = e(Components.Button, {
		Text = "Close",
		LayoutOrder = 13,
		OnClick = props.OnClose,
	})

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

return RoadAssetsPanel
