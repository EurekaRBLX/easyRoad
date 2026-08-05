--!strict
-- Full-viewport EULA gate: fills Studio viewport, RGB(30,30,30), Builder Sans.
-- Body uses measured CanvasSize. Agree disabled until scroll reaches bottom.
-- Scroll-hint sits in a reserved strip between the canvas and the footer
-- (not overlaid on the ScrollingFrame, which was hiding it until re-layout).

local TextService = game:GetService("TextService")
local RunService = game:GetService("RunService")

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
local HINT_H = 20
local GAP = 12
local SCROLL_INNER_PAD = 28
local TEXT_SIZE = 14
local FOOTER_BOTTOM = 12
local LINKS_ABOVE_BUTTONS = 8
local HINT_ABOVE_LINKS = 6
-- Footer block from bottom of viewport (buttons + links + hint strip + gaps)
local FOOTER_H = FOOTER_BOTTOM + BTN_H + LINKS_ABOVE_BUTTONS + LINKS_H + HINT_ABOVE_LINKS + HINT_H + 4
local HEADER_H = PAD + TITLE_H + GAP + META_H + GAP
local SCROLL_BOTTOM_SLACK = 32

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
	-- Prefer AbsoluteCanvasSize once layout has applied CanvasSize.
	local canvas = scroll.AbsoluteCanvasSize.Y
	if canvas < 1 then
		canvas = scroll.CanvasSize.Y.Offset
	end
	if window <= 1 then
		return false
	end
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

	React.useEffect(function()
		local scroll = scrollRef.current
		if not scroll then
			return nil
		end

		local function refreshCanAgree()
			local s = scrollRef.current
			if not s then
				setCanAgree(false)
				return
			end
			setCanAgree(isScrolledToBottom(s))
		end

		local function remeasure()
			local w = scroll.AbsoluteSize.X
			if w >= 40 then
				setCanvasH(measureBodyHeight(w))
			end
		end

		remeasure()
		refreshCanAgree()

		local connections: { RBXScriptConnection } = {
			scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
				remeasure()
				task.defer(refreshCanAgree)
			end),
			scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(refreshCanAgree),
			scroll:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(refreshCanAgree),
			scroll:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(refreshCanAgree),
		}

		-- A few frames after mount so CanvasSize / window size are real.
		local frames = 0
		local hb = RunService.Heartbeat:Connect(function()
			frames += 1
			if frames == 1 or frames == 3 or frames == 8 then
				remeasure()
			end
			refreshCanAgree()
			if frames >= 12 then
				hb:Disconnect()
			end
		end)

		return function()
			for _, c in connections do
				c:Disconnect()
			end
			if hb.Connected then
				hb:Disconnect()
			end
		end
	end, {})

	-- After canvas height prop updates, re-check once layout applies.
	React.useEffect(function()
		task.defer(function()
			local s = scrollRef.current
			if s then
				setCanAgree(isScrolledToBottom(s))
			end
		end)
		return nil
	end, { canvasH })

	local hintY = FOOTER_BOTTOM + BTN_H + LINKS_ABOVE_BUTTONS + LINKS_H + HINT_ABOVE_LINKS

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
			-- Leave room for hint strip + links + buttons (never draw over hint).
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

		-- Dedicated strip BETWEEN scroll canvas and footer links (always reserved).
		ScrollHint = e("TextLabel", {
			Text = if canAgree then "" else "Scroll to the bottom of the EULA to enable Agree.",
			TextColor3 = Theme.WARNING,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, PAD, 1, -hintY),
			Size = UDim2.new(1, -PAD * 2, 0, HINT_H),
			Font = Theme.FONT,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Center,
			ZIndex = 103,
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
