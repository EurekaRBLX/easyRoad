--!strict
-- Full-viewport EULA gate: fills Studio viewport, RGB(30,30,30), Builder Sans.
-- Body uses measured CanvasSize. Agree stays disabled until scroll reaches bottom.

local TextService = game:GetService("TextService")

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local Components = require("./Components")
local ProductLicense = require("../ProductLicense")

local BG = Color3.fromRGB(30, 30, 30)
local SECTION = Color3.fromRGB(24, 24, 24)
local BTN_H = 32
local PAD = 24
local TITLE_H = 32
local META_H = 18
local LINKS_H = 52
local GAP = 12
local SCROLL_INNER_PAD = 28
local TEXT_SIZE = 14
local FOOTER_BOTTOM = 12
local LINKS_ABOVE_BUTTONS = 8
local FOOTER_H = FOOTER_BOTTOM + BTN_H + LINKS_ABOVE_BUTTONS + LINKS_H + 8
local HEADER_H = PAD + TITLE_H + GAP + META_H + GAP
-- Pixels from bottom that count as “fully scrolled”.
local SCROLL_BOTTOM_SLACK = 24

local function measureBodyHeight(widthPx: number): number
	local textWidth = math.max(widthPx - SCROLL_INNER_PAD, 80)
	local ok, size = pcall(function()
		return TextService:GetTextSize(
			ProductLicense.EulaBody,
			TEXT_SIZE,
			Enum.Font.BuilderSans,
			Vector2.new(textWidth, 200000)
		)
	end)
	if ok and typeof(size) == "Vector2" then
		return math.ceil(size.Y) + 48
	end
	local approxCharsPerLine = math.max(textWidth / 7, 20)
	local lines = math.ceil(#ProductLicense.EulaBody / approxCharsPerLine)
	return math.max(1200, lines * 20)
end

local function isScrolledToBottom(scroll: ScrollingFrame): boolean
	local window = scroll.AbsoluteWindowSize.Y
	local canvas = scroll.CanvasSize.Y.Offset
	if window <= 0 then
		return false
	end
	-- Content fits without scrolling → treat as fully read.
	if canvas <= window + SCROLL_BOTTOM_SLACK then
		return true
	end
	local maxY = canvas - window
	return scroll.CanvasPosition.Y >= maxY - SCROLL_BOTTOM_SLACK
end

local function EulaOverlay(props: {
	OnAgree: () -> (),
	OnDisagree: () -> (),
	AgreeLabel: string?,
	DisagreeLabel: string?,
})
	local scrollRef = React.useRef(nil :: ScrollingFrame?)
	local canvasH, setCanvasH = React.useState(1600)
	local canAgree, setCanAgree = React.useState(false)

	local function refreshCanAgree()
		local scroll = scrollRef.current
		if not scroll then
			setCanAgree(false)
			return
		end
		setCanAgree(isScrolledToBottom(scroll))
	end

	React.useEffect(function()
		local scroll = scrollRef.current
		if not scroll then
			return nil
		end
		local function remeasure()
			local w = scroll.AbsoluteSize.X
			if w >= 40 then
				setCanvasH(measureBodyHeight(w))
			end
			-- Defer check until CanvasSize prop applies.
			task.defer(refreshCanAgree)
		end
		remeasure()
		local sizeCn = scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(remeasure)
		local posCn = scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(refreshCanAgree)
		task.defer(remeasure)
		task.delay(0.05, remeasure)
		task.delay(0.2, remeasure)
		return function()
			sizeCn:Disconnect()
			posCn:Disconnect()
		end
	end, { canvasH })

	-- Re-check when canvas height updates (content taller than window).
	React.useEffect(function()
		task.defer(refreshCanAgree)
		return nil
	end, { canvasH })

	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = BG,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		ZIndex = 100,
	}, {
		Title = e("TextLabel", {
			Text = ProductLicense.EulaTitle,
			TextColor3 = Theme.ACCENT,
			BackgroundTransparency = 1,
			Position = UDim2.new(0, PAD, 0, PAD),
			Size = UDim2.new(1, -PAD * 2, 0, TITLE_H),
			Font = Enum.Font.BuilderSansMedium,
			TextSize = 22,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 101,
		}),
		Meta = e("TextLabel", {
			Text = string.format(
				"Early access · Build %s · EULA v%s",
				ProductLicense.Build,
				ProductLicense.EulaVersion
			),
			TextColor3 = Theme.DIM,
			BackgroundTransparency = 1,
			Position = UDim2.new(0, PAD, 0, PAD + TITLE_H + GAP),
			Size = UDim2.new(1, -PAD * 2, 0, META_H),
			Font = Theme.FONT,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 101,
		}),

		Scroll = e("ScrollingFrame", {
			ref = scrollRef,
			Position = UDim2.new(0, PAD, 0, HEADER_H),
			Size = UDim2.new(1, -PAD * 2, 1, -(HEADER_H + FOOTER_H)),
			BackgroundColor3 = SECTION,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			ScrollBarThickness = 8,
			ScrollBarImageColor3 = Theme.SCROLLBAR_COLOR,
			AutomaticCanvasSize = Enum.AutomaticSize.None,
			CanvasSize = UDim2.new(0, 0, 0, canvasH),
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ClipsDescendants = true,
			Active = true,
			ZIndex = 101,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0, 6) }),
			Pad = e("UIPadding", {
				PaddingLeft = UDim.new(0, 14),
				PaddingRight = UDim.new(0, 14),
				PaddingTop = UDim.new(0, 12),
				PaddingBottom = UDim.new(0, 24),
			}),
			Body = e("TextLabel", {
				Text = ProductLicense.EulaBody,
				TextColor3 = Theme.OFFWHITE,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -8, 0, math.max(canvasH - 36, 100)),
				Font = Theme.FONT,
				TextSize = TEXT_SIZE,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
				ZIndex = 102,
			}),
		}),

		ScrollHint = not canAgree and e("TextLabel", {
			Text = "Scroll to the bottom of the EULA to enable Agree.",
			TextColor3 = Theme.WARNING,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, PAD, 1, -(FOOTER_BOTTOM + BTN_H + LINKS_ABOVE_BUTTONS + LINKS_H + 4)),
			Size = UDim2.new(1, -PAD * 2, 0, 16),
			Font = Theme.FONT,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 101,
		}),

		Links = e("TextLabel", {
			Text = string.format(
				"Eureka Terms: %s\nPrivacy: %s\nDiscord: %s",
				ProductLicense.TermsUrl,
				ProductLicense.PrivacyUrl,
				ProductLicense.DiscordUrl
			),
			TextColor3 = Theme.DIM,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, PAD, 1, -(FOOTER_BOTTOM + BTN_H + LINKS_ABOVE_BUTTONS)),
			Size = UDim2.new(1, -PAD * 2, 0, LINKS_H),
			Font = Theme.FONT,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Bottom,
			TextWrapped = true,
			ZIndex = 101,
		}),

		Actions = e("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, PAD, 1, -FOOTER_BOTTOM),
			Size = UDim2.new(1, -PAD * 2, 0, BTN_H),
			BackgroundTransparency = 1,
			ZIndex = 101,
		}, {
			Layout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 8),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Disagree = e("TextButton", {
				Text = props.DisagreeLabel or "Disagree",
				TextColor3 = Theme.WHITE,
				Font = Theme.FONT,
				TextSize = Theme.TEXT_SIZE,
				BackgroundColor3 = SECTION,
				BackgroundTransparency = 0,
				BorderSizePixel = 0,
				AutoButtonColor = true,
				Size = UDim2.new(0, 110, 0, BTN_H),
				LayoutOrder = 1,
				ZIndex = 102,
				[React.Event.Activated] = props.OnDisagree,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
			}),
			Agree = e("TextButton", {
				Text = props.AgreeLabel or "Agree",
				TextColor3 = Theme.WHITE,
				Font = Theme.FONT,
				TextSize = Theme.TEXT_SIZE,
				BackgroundColor3 = if canAgree then Theme.SELECTED else Theme.BUTTON,
				BackgroundTransparency = if canAgree then 0.1 else 0.45,
				BorderSizePixel = 0,
				AutoButtonColor = canAgree,
				Active = canAgree,
				Size = UDim2.new(0, 110, 0, BTN_H),
				LayoutOrder = 2,
				ZIndex = 102,
				[React.Event.Activated] = function()
					if canAgree then
						props.OnAgree()
					end
				end,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
			}),
		}),
	})
end

return EulaOverlay
