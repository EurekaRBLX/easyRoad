--!strict
-- Settings > Backups: portable JSON backup and guarded restore for plugin
-- preferences plus custom road and region presets.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")

local function BackupsGui(props: {
	OnBackupData: () -> string,
	OnValidateRestoreData: (json: string) -> (boolean, string),
	OnRestoreData: (json: string) -> (boolean, string),
	OnClose: () -> (),
})
	local transferMode, setTransferMode = React.useState(nil :: ("Backup" | "Restore")?)
	local transferText, setTransferText = React.useState("")
	local transferStatus, setTransferStatus = React.useState("")
	local transferStatusIsError, setTransferStatusIsError = React.useState(false)
	local restoreReady, setRestoreReady = React.useState(false)
	local transferBoxRef = React.useRef(nil :: TextBox?)

	local function focusTransferText(selectAll: boolean)
		local box = transferBoxRef.current
		if not box then
			return
		end
		box:CaptureFocus()
		if selectAll then
			box.CursorPosition = 1
			box.SelectionStart = #box.Text + 1
		end
	end

	React.useEffect(function()
		if transferMode then
			focusTransferText(transferMode == "Backup")
		end
		return nil
	end, { transferMode } :: { any })

	local scrollProps = Components.ScrollBar()
	scrollProps.Size = UDim2.fromScale(1, 1)
	scrollProps.BackgroundColor3 = Theme.PANEL
	scrollProps.BorderSizePixel = 0
	scrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollProps.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollProps.ScrollingDirection = Enum.ScrollingDirection.Y

	return e("ScrollingFrame", scrollProps, {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, Theme.PADDING + 5),
			PaddingRight = UDim.new(0, Theme.PADDING + 5),
			PaddingTop = UDim.new(0, Theme.PADDING + 5),
			PaddingBottom = UDim.new(0, Theme.PADDING + 5),
		}),
		Header = e(Components.Section, {
			Text = "Backups",
			First = true,
			LayoutOrder = 1,
		}),
		Description = e("TextLabel", {
			Text = "Back up plugin settings and custom road/region presets as JSON. Placed roads already live in this place and are not included.",
			TextColor3 = Theme.DIM,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextWrapped = true,
			Font = Theme.FONT,
			TextSize = Theme.TEXT_SIZE,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			LayoutOrder = 2,
		}),
		DataActions = e(Components.Row, { LayoutOrder = 3 }, {
			Backup = e(Components.Button, {
				Text = "Back up data",
				OnClick = function()
					setTransferText(props.OnBackupData())
					setTransferStatus("JSON selected - press Ctrl+C to copy it.")
					setTransferStatusIsError(false)
					setRestoreReady(false)
					setTransferMode("Backup")
				end,
				Selected = transferMode == "Backup",
				LayoutOrder = 1,
				Grow = true,
			}),
			Restore = e(Components.Button, {
				Text = "Restore data",
				OnClick = function()
					setTransferText("")
					setTransferStatus("Paste a backup, then validate it before restoring.")
					setTransferStatusIsError(false)
					setRestoreReady(false)
					setTransferMode("Restore")
				end,
				Selected = transferMode == "Restore",
				LayoutOrder = 2,
				Grow = true,
			}),
		}),
		Transfer = transferMode and e("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 4,
		}, {
			Layout = e("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 6),
			}),
			Json = e("TextBox", {
				ref = transferBoxRef,
				Text = transferText,
				PlaceholderText = if transferMode == "Restore" then "Paste easyRoad backup JSON here" else "",
				TextColor3 = Theme.OFFWHITE,
				PlaceholderColor3 = Theme.DIM,
				BackgroundColor3 = Theme.FIELD,
				BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
				Size = UDim2.new(1, 0, 0, 160),
				ClearTextOnFocus = false,
				MultiLine = true,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Font = Theme.FONT_MONO,
				TextSize = 13,
				LayoutOrder = 1,
				[React.Change.Text] = function(object: TextBox)
					setTransferText(object.Text)
					if transferMode == "Restore" then
						setRestoreReady(false)
					end
				end,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
				Padding = e("UIPadding", {
					PaddingLeft = UDim.new(0, 8),
					PaddingRight = UDim.new(0, 8),
					PaddingTop = UDim.new(0, 6),
					PaddingBottom = UDim.new(0, 6),
				}),
			}),
			Status = e("TextLabel", {
				Text = transferStatus,
				TextColor3 = if transferStatusIsError then Theme.DANGER else Theme.DIM,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				Font = Theme.FONT,
				TextSize = Theme.TEXT_SIZE,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = 2,
			}),
			BackupActions = transferMode == "Backup" and e(Components.Row, { LayoutOrder = 3 }, {
				Select = e(Components.Button, {
					Text = "Select JSON",
					OnClick = function()
						focusTransferText(true)
					end,
					LayoutOrder = 1,
					Grow = true,
				}),
				Done = e(Components.Button, {
					Text = "Done",
					OnClick = function()
						setTransferMode(nil)
					end,
					LayoutOrder = 2,
					Grow = true,
				}),
			}),
			RestoreActions = transferMode == "Restore" and e(Components.Row, { LayoutOrder = 3 }, {
				Validate = e(Components.Button, {
					Text = if restoreReady then "Validated" else "Validate backup",
					Selected = restoreReady,
					OnClick = function()
						local valid, message = props.OnValidateRestoreData(transferText)
						setRestoreReady(valid)
						setTransferStatus(message)
						setTransferStatusIsError(not valid)
					end,
					LayoutOrder = 1,
					Grow = true,
				}),
				Confirm = restoreReady and e(Components.Button, {
					Text = "Restore now",
					Danger = true,
					OnClick = function()
						local restored, message = props.OnRestoreData(transferText)
						setRestoreReady(false)
						setTransferStatus(message)
						setTransferStatusIsError(not restored)
					end,
					LayoutOrder = 2,
					Grow = true,
				}),
			}),
		}),
		Close = e(Components.Button, {
			Text = "Close",
			OnClick = props.OnClose,
			LayoutOrder = 100,
		}),
	})
end

return BackupsGui
