--!strict
-- Full-viewport EULA gate: fills Studio viewport, RGB(30,30,30), Builder Sans.
-- Body uses measured CanvasSize. Agree disabled until scroll reaches bottom.
-- Footer is a stacked block (hint → links → buttons) with solid BG so
-- link/scroll text cannot paint over the scroll-to-agree hint.
--
-- Perf: never React-setState during scroll. CanvasPosition only does cheap
-- math against cached sizes and mutates Agree/hint instances directly.
-- Reading Absolute* every scroll tick re-layouts the huge TextLabel.

local TextService = game:GetService("TextService")

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Theme = require("./Theme")
local ProductLicense = require("../ProductLicense")

local BG = Color3.fromRGB(30, 30, 30)
local SECTION = Color3.fromRGB(24, 24, 24)
local BTN_H = 32
local PAD = 24
local TITLE_H = 32
local META_H = 18
local LINKS_H = 48
local HINT_H = 18
local GAP = 12
local SCROLL_INNER_PAD = 28
local TEXT_SIZE = 14
local FOOTER_BOTTOM = 12
local FOOTER_STACK_PAD = 6
-- Stacked footer: hint → links → buttons (no absolute Y overlap).
local FOOTER_INNER_H = HINT_H + FOOTER_STACK_PAD + LINKS_H + FOOTER_STACK_PAD + BTN_H
local FOOTER_H = FOOTER_BOTTOM + FOOTER_INNER_H + 8
local HEADER_H = PAD + TITLE_H + GAP + META_H + GAP
local SCROLL_BOTTOM_SLACK = 32
local HINT_TEXT = "Scroll to the bottom of the EULA to enable Agree."

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

local function EulaOverlay(props: {
	OnAgree: () -> (),
	OnDisagree: () -> (),
	AgreeLabel: string?,
	DisagreeLabel: string?,
})
	local scrollRef = React.useRef(nil :: ScrollingFrame?)
	local agreeRef = React.useRef(nil :: TextButton?)
	local hintRef = React.useRef(nil :: TextLabel?)
	local canvasH, setCanvasH = React.useState(1600)
	-- Imperative gate — updated without React re-renders while scrolling.
	local canAgreeRef = React.useRef(false)
	local canvasHRef = React.useRef(1600)
	local windowHRef = React.useRef(0)
	local lastWidthRef = React.useRef(0)

	local function applyCanAgree(next: boolean)
		if canAgreeRef.current == next then
			return
		end
		canAgreeRef.current = next
		local agree = agreeRef.current
		if agree then
			agree.Active = next
			agree.AutoButtonColor = next
			agree.BackgroundColor3 = if next then Theme.SELECTED else Theme.BUTTON
			agree.BackgroundTransparency = if next then 0.1 else 0.45
		end
		local hint = hintRef.current
		if hint then
			hint.Text = if next then "" else HINT_TEXT
		end
	end

	local function isScrolledToBottom(scroll: ScrollingFrame): boolean
		-- Prefer cached sizes — Absolute* during CanvasPosition forces layout.
		local window = windowHRef.current
		if window <= 1 then
			window = scroll.AbsoluteWindowSize.Y
			windowHRef.current = window
		end
		local canvas = canvasHRef.current
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

	local function refreshCanAgree()
		local s = scrollRef.current
		if not s then
			applyCanAgree(false)
			return
		end
		applyCanAgree(isScrolledToBottom(s))
	end

	React.useEffect(function()
		local scroll = scrollRef.current
		if not scroll then
			return nil
		end

		local function remeasure()
			local w = scroll.AbsoluteSize.X
			if w < 40 then
				return
			end
			-- Skip work if width unchanged (AbsoluteSize can fire for Y-only).
			if math.abs(w - lastWidthRef.current) < 1 then
				windowHRef.current = scroll.AbsoluteWindowSize.Y
				refreshCanAgree()
				return
			end
			lastWidthRef.current = w
			windowHRef.current = scroll.AbsoluteWindowSize.Y
			local h = measureBodyHeight(w)
			canvasHRef.current = h
			setCanvasH(function(prev)
				if prev == h then
					return prev
				end
				return h
			end)
			refreshCanAgree()
		end

		local connections: { RBXScriptConnection } = {
			scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(remeasure),
			-- Cheap path only — no Absolute* reads, no React setState.
			scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(refreshCanAgree),
		}

		-- One deferred pass after mount so AbsoluteSize/window are real.
		task.defer(remeasure)
		task.delay(0.1, remeasure)

		return function()
			for _, c in connections do
				c:Disconnect()
			end
		end
	end, {})

	-- Keep canvas height ref + window size in sync after React applies CanvasSize.
	React.useEffect(function()
		canvasHRef.current = canvasH
		task.defer(function()
			local s = scrollRef.current
			if s then
				windowHRef.current = s.AbsoluteWindowSize.Y
				refreshCanAgree()
			end
		end)
		return nil
	end, { canvasH })

	-- React re-renders (e.g. canvas height) reset Agree/hint props — re-assert gate.
	React.useEffect(function()
		local next = canAgreeRef.current
		local agree = agreeRef.current
		if agree then
			agree.Active = next
			agree.AutoButtonColor = next
			agree.BackgroundColor3 = if next then Theme.SELECTED else Theme.BUTTON
			agree.BackgroundTransparency = if next then 0.1 else 0.45
		end
		local hint = hintRef.current
		if hint then
			hint.Text = if next then "" else HINT_TEXT
		end
		return nil
	end)


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

		Footer = e("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, PAD, 1, -FOOTER_BOTTOM),
			Size = UDim2.new(1, -PAD * 2, 0, FOOTER_INNER_H),
			BackgroundColor3 = BG,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			ZIndex = 103,
		}, {
			Layout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				VerticalAlignment = Enum.VerticalAlignment.Top,
				Padding = UDim.new(0, FOOTER_STACK_PAD),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			ScrollHint = e("TextLabel", {
				ref = hintRef,
				Text = HINT_TEXT,
				TextColor3 = Theme.WARNING,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, HINT_H),
				Font = Theme.FONT,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Center,
				TextTruncate = Enum.TextTruncate.AtEnd,
				LayoutOrder = 1,
				ZIndex = 104,
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
				Size = UDim2.new(1, 0, 0, LINKS_H),
				Font = Theme.FONT,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.AtEnd,
				LayoutOrder = 2,
				ZIndex = 104,
			}),
			Actions = e("Frame", {
				Size = UDim2.new(1, 0, 0, BTN_H),
				BackgroundTransparency = 1,
				LayoutOrder = 3,
				ZIndex = 104,
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
					ZIndex = 105,
					[React.Event.Activated] = props.OnDisagree,
				}, {
					Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
				}),
				Agree = e("TextButton", {
					ref = agreeRef,
					Text = props.AgreeLabel or "Agree",
					TextColor3 = Theme.WHITE,
					Font = Theme.FONT,
					TextSize = Theme.TEXT_SIZE,
					BackgroundColor3 = Theme.BUTTON,
					BackgroundTransparency = 0.45,
					BorderSizePixel = 0,
					AutoButtonColor = false,
					Active = false,
					Size = UDim2.new(0, 110, 0, BTN_H),
					LayoutOrder = 2,
					ZIndex = 105,
					[React.Event.Activated] = function()
						if canAgreeRef.current then
							props.OnAgree()
						end
					end,
				}, {
					Corner = e("UICorner", { CornerRadius = UDim.new(0, 4) }),
				}),
			}),
		}),
	})
end

return EulaOverlay
