--!strict
-- Full-viewport first-run setup. This component deliberately owns only the
-- temporary draft and navigation; the plugin entry point decides when to show
-- it, how to persist completion, and how each preset maps onto Settings.

local Plugin = script.Parent.Parent.Parent
local Packages = Plugin.Packages

local React = require(Packages.React)
local e = React.createElement

local Components = require("./Components")
local Theme = require("./Theme")

export type LanguageVariant = "British" | "American"
export type DriveSideOverride = "Region" | "Left" | "Right"
export type UnitsPreset = "Roblox" | "Metric" | "Imperial"

export type RegionOption = {
	Id: string,
	Text: string,
	Description: string?,
}

export type SetupResult = {
	RegionId: string,
	LanguageVariant: LanguageVariant,
	DriveSideOverride: DriveSideOverride,
	UnitsPreset: UnitsPreset,
}

export type SetupWizardProps = {
	RegionOptions: { RegionOption },
	InitialValues: SetupResult?,
	OnComplete: (result: SetupResult) -> (),
	OnSkip: () -> (),
	ProductName: string?,
}

local BACKGROUND = Color3.fromRGB(30, 30, 30)
local SECTION = Color3.fromRGB(24, 24, 24)
local SHELL_MAX_WIDTH = 900
local SHELL_MAX_HEIGHT = 720
local OUTER_PAD = 24
local HEADER_HEIGHT = 60
local PROGRESS_HEIGHT = 42
local FOOTER_HEIGHT = 60
local CONTENT_PAD = 28
local CONTENT_BORDER_INSET = 2
local CHOICE_HEIGHT = 68

local STEP_NAMES = {
	"Welcome",
	"Region",
	"Terminology",
	"Traffic side",
	"Units",
	"Enjoy",
}
local TOTAL_STEPS = #STEP_NAMES

local function copyResult(result: SetupResult): SetupResult
	return {
		RegionId = result.RegionId,
		LanguageVariant = result.LanguageVariant,
		DriveSideOverride = result.DriveSideOverride,
		UnitsPreset = result.UnitsPreset,
	}
end

local function initialResult(props: SetupWizardProps): SetupResult
	if props.InitialValues then
		return copyResult(props.InitialValues)
	end
	local firstRegion = props.RegionOptions[1]
	return {
		RegionId = if firstRegion then firstRegion.Id else "",
		LanguageVariant = "British",
		DriveSideOverride = "Region",
		UnitsPreset = "Metric",
	}
end

local function regionText(options: { RegionOption }, selectedId: string): string
	for _, option in options do
		if option.Id == selectedId then
			return option.Text
		end
	end
	return "No region selected"
end

local function regionDescription(options: { RegionOption }, selectedId: string): string?
	for _, option in options do
		if option.Id == selectedId then
			return option.Description
		end
	end
	return nil
end

local function hasRegion(options: { RegionOption }, selectedId: string): boolean
	for _, option in options do
		if option.Id == selectedId then
			return true
		end
	end
	return false
end

local function ChoiceButton(props: {
	Title: string,
	Detail: string,
	Selected: boolean,
	OnClick: () -> (),
	LayoutOrder: number,
})
	local hovered, setHovered = React.useState(false)
	local selected = props.Selected
	local background = if selected
		then Theme.ACCENT:Lerp(SECTION, 0.72)
		else if hovered then Theme.BUTTON_HOVER else Theme.FIELD

	return e("TextButton", {
		Text = "",
		Size = UDim2.new(1, 0, 0, CHOICE_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = background,
		BackgroundTransparency = if selected then 0.05 else Theme.GLASS_ELEMENT_TRANSPARENCY,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		LayoutOrder = props.LayoutOrder,
		Selectable = true,
		[React.Event.Activated] = props.OnClick,
		[React.Event.MouseEnter] = function()
			setHovered(true)
		end,
		[React.Event.MouseLeave] = function()
			setHovered(false)
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 6) }),
		MinimumSize = e("UISizeConstraint", {
			MinSize = Vector2.new(0, CHOICE_HEIGHT),
		}),
		Stroke = e("UIStroke", {
			Color = if selected then Theme.ACCENT else Theme.GLASS_STROKE,
			Transparency = if selected then 0.15 else 0.78,
			Thickness = 1,
		}),
		Indicator = e("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 16, 0.5, 0),
			Size = UDim2.fromOffset(18, 18),
			BackgroundColor3 = if selected then Theme.ACCENT else Theme.FIELD,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(1, 0) }),
			Stroke = e("UIStroke", {
				Color = if selected then Theme.ACCENT_HOVER else Theme.DIM,
				Transparency = if selected then 0 else 0.25,
				Thickness = 1,
			}),
			Dot = selected and e("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(8, 8),
				BackgroundColor3 = Theme.WHITE,
				BorderSizePixel = 0,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(1, 0) }),
			}),
		}),
		Content = e("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 48, 0, 10),
			Size = UDim2.new(1, -62, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
		}, {
			Layout = e("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 3),
			}),
			BottomPadding = e("UIPadding", {
				PaddingBottom = UDim.new(0, 10),
			}),
			Title = e("TextLabel", {
				Text = props.Title,
				TextColor3 = Theme.WHITE,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Font = Theme.FONT_BOLD,
				TextSize = 16,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Center,
				TextWrapped = true,
				LayoutOrder = 1,
			}),
			Detail = e("TextLabel", {
				Text = props.Detail,
				TextColor3 = Theme.OFFWHITE,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Font = Theme.FONT,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
				LayoutOrder = 2,
			}),
		}),
	})
end

local function StepPage(props: {
	Title: string,
	Body: string,
	TitleAccent: boolean?,
	children: { [string]: any }?,
})
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 12),
		}),
		Title = e("TextLabel", {
			Text = props.Title,
			TextColor3 = if props.TitleAccent then Theme.ACCENT else Theme.WHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 38),
			AutomaticSize = Enum.AutomaticSize.Y,
			Font = Theme.FONT_BOLD,
			TextSize = if props.TitleAccent then 30 else 26,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Center,
			TextWrapped = true,
			LayoutOrder = 1,
		}),
		Body = e("TextLabel", {
			Text = props.Body,
			TextColor3 = Theme.OFFWHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Font = Theme.FONT,
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			LayoutOrder = 2,
		}),
	}
	if props.children then
		for key, child in props.children do
			children[key] = child
		end
	end

	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, children)
end

local function ChoiceList(props: {
	children: { [string]: any }?,
})
	local listChildren: { [string]: any } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 8),
		}),
	}
	if props.children then
		for key, child in props.children do
			listChildren[key] = child
		end
	end
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 3,
	}, listChildren)
end

local function SummaryRow(props: {
	Label: string,
	Value: string,
	LayoutOrder: number,
})
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, 46),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.FIELD,
		BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
		BorderSizePixel = 0,
		LayoutOrder = props.LayoutOrder,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 5) }),
		MinimumSize = e("UISizeConstraint", {
			MinSize = Vector2.new(0, 46),
		}),
		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
			PaddingTop = UDim.new(0, 4),
			PaddingBottom = UDim.new(0, 5),
		}),
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Label = e("TextLabel", {
			Text = props.Label,
			TextColor3 = Theme.DIM,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Font = Theme.FONT,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			LayoutOrder = 1,
		}),
		Value = e("TextLabel", {
			Text = props.Value,
			TextColor3 = Theme.WHITE,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Font = Theme.FONT_BOLD,
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			LayoutOrder = 2,
		}),
	})
end

local function SetupWizard(props: SetupWizardProps)
	local currentStep, setCurrentStep = React.useState(1)
	local values, setValues = React.useState(initialResult(props))
	local scrollRef = React.useRef(nil :: ScrollingFrame?)

	React.useEffect(function()
		local scroll = scrollRef.current
		if scroll then
			scroll.CanvasPosition = Vector2.zero
		end
		return nil
	end, { currentStep })

	local selectedRegionText = regionText(props.RegionOptions, values.RegionId)
	local selectedRegionDescription = regionDescription(props.RegionOptions, values.RegionId)
	local regionIsValid = hasRegion(props.RegionOptions, values.RegionId)

	local function updateRegion(regionId: string)
		setValues(function(previous: SetupResult): SetupResult
			return {
				RegionId = regionId,
				LanguageVariant = previous.LanguageVariant,
				DriveSideOverride = previous.DriveSideOverride,
				UnitsPreset = previous.UnitsPreset,
			}
		end)
	end

	local function updateLanguage(language: LanguageVariant)
		setValues(function(previous: SetupResult): SetupResult
			return {
				RegionId = previous.RegionId,
				LanguageVariant = language,
				DriveSideOverride = previous.DriveSideOverride,
				UnitsPreset = previous.UnitsPreset,
			}
		end)
	end

	local function updateDriveSide(driveSide: DriveSideOverride)
		setValues(function(previous: SetupResult): SetupResult
			return {
				RegionId = previous.RegionId,
				LanguageVariant = previous.LanguageVariant,
				DriveSideOverride = driveSide,
				UnitsPreset = previous.UnitsPreset,
			}
		end)
	end

	local function updateUnits(units: UnitsPreset)
		setValues(function(previous: SetupResult): SetupResult
			return {
				RegionId = previous.RegionId,
				LanguageVariant = previous.LanguageVariant,
				DriveSideOverride = previous.DriveSideOverride,
				UnitsPreset = units,
			}
		end)
	end

	local page: any
	if currentStep == 1 then
		page = e(StepPage, {
			Title = "Set up " .. (props.ProductName or "easyRoad"),
			Body = "Choose the defaults that match the roads you build. It takes less than a minute, and every setting stays editable later.",
		}, {
			Scope = e("TextLabel", {
				Text = "You will set your regional standard, terminology, traffic side, and display units.",
				TextColor3 = Theme.DIM,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Font = Theme.FONT,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
				LayoutOrder = 3,
			}),
		})
	elseif currentStep == 2 then
		page = e(StepPage, {
			Title = "Where are you building?",
			Body = "Your regional standard sets road dimensions, markings, materials, and other practical defaults.",
		}, {
			RegionField = e("Frame", {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 3,
			}, {
				Layout = e("UIListLayout", {
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 6),
				}),
				Label = e("TextLabel", {
					Text = "Regional standard",
					TextColor3 = Theme.DIM,
					BackgroundTransparency = 1,
					Size = UDim2.new(1, 0, 0, 20),
					Font = Theme.FONT_BOLD,
					TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextWrapped = true,
					LayoutOrder = 1,
				}),
				DropdownRow = e("Frame", {
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					LayoutOrder = 2,
				}, {
					Layout = e("UIListLayout", {
						FillDirection = Enum.FillDirection.Horizontal,
						SortOrder = Enum.SortOrder.LayoutOrder,
					}),
					Dropdown = e(Components.Dropdown, {
						Options = props.RegionOptions,
						SelectedId = values.RegionId,
						Placeholder = "Choose a region",
						OnSelected = updateRegion,
						Grow = true,
						MaxVisibleOptions = 6,
					}),
				}),
				Description = e("TextLabel", {
					Text = selectedRegionDescription or ("Selected: " .. selectedRegionText),
					TextColor3 = Theme.OFFWHITE,
					BackgroundTransparency = 1,
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					Font = Theme.FONT,
					TextSize = 14,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Top,
					TextWrapped = true,
					LayoutOrder = 3,
				}),
			}),
		})
	elseif currentStep == 3 then
		page = e(StepPage, {
			Title = "Which terminology feels natural?",
			Body = "This changes labels in the interface, not the roads themselves.",
		}, {
			Choices = e(ChoiceList, {}, {
				British = e(ChoiceButton, {
					Title = "British English",
					Detail = "Kerb, pavement, and central reservation.",
					Selected = values.LanguageVariant == "British",
					OnClick = function()
						updateLanguage("British")
					end,
					LayoutOrder = 1,
				}),
				American = e(ChoiceButton, {
					Title = "American English",
					Detail = "Curb, sidewalk, and median.",
					Selected = values.LanguageVariant == "American",
					OnClick = function()
						updateLanguage("American")
					end,
					LayoutOrder = 2,
				}),
			}),
		})
	elseif currentStep == 4 then
		page = e(StepPage, {
			Title = "Which side should traffic use?",
			Body = "Follow the selected region, or override it for a custom project.",
		}, {
			Choices = e(ChoiceList, {}, {
				Region = e(ChoiceButton, {
					Title = "Follow regional standard",
					Detail = "Use the traffic side defined by " .. selectedRegionText .. ".",
					Selected = values.DriveSideOverride == "Region",
					OnClick = function()
						updateDriveSide("Region")
					end,
					LayoutOrder = 1,
				}),
				Left = e(ChoiceButton, {
					Title = "Drive on the left",
					Detail = "Override the selected region for left-hand traffic.",
					Selected = values.DriveSideOverride == "Left",
					OnClick = function()
						updateDriveSide("Left")
					end,
					LayoutOrder = 2,
				}),
				Right = e(ChoiceButton, {
					Title = "Drive on the right",
					Detail = "Override the selected region for right-hand traffic.",
					Selected = values.DriveSideOverride == "Right",
					OnClick = function()
						updateDriveSide("Right")
					end,
					LayoutOrder = 3,
				}),
			}),
		})
	elseif currentStep == 5 then
		page = e(StepPage, {
			Title = "How should measurements appear?",
			Body = "Road data stays consistent internally; this preset controls the units shown while you work.",
		}, {
			Choices = e(ChoiceList, {}, {
				Roblox = e(ChoiceButton, {
					Title = "Roblox",
					Detail = "Studs for distance and studs per second for speed.",
					Selected = values.UnitsPreset == "Roblox",
					OnClick = function()
						updateUnits("Roblox")
					end,
					LayoutOrder = 1,
				}),
				Metric = e(ChoiceButton, {
					Title = "Metric",
					Detail = "Metres for distance and kilometres per hour for speed.",
					Selected = values.UnitsPreset == "Metric",
					OnClick = function()
						updateUnits("Metric")
					end,
					LayoutOrder = 2,
				}),
				Imperial = e(ChoiceButton, {
					Title = "Imperial",
					Detail = "Feet for distance and miles per hour for speed.",
					Selected = values.UnitsPreset == "Imperial",
					OnClick = function()
						updateUnits("Imperial")
					end,
					LayoutOrder = 3,
				}),
			}),
		})
	else
		local driveSideText = if values.DriveSideOverride == "Region"
			then "Follow " .. selectedRegionText
			else if values.DriveSideOverride == "Left" then "Left-hand traffic" else "Right-hand traffic"
		page = e(StepPage, {
			Title = "Enjoy!",
			Body = (props.ProductName or "easyRoad")
				.. " is ready for the way you build. You can change these choices later in Settings > Regional Preference.",
			TitleAccent = true,
		}, {
			Summary = e("Frame", {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 3,
			}, {
				Layout = e("UIListLayout", {
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 6),
				}),
				Region = e(SummaryRow, {
					Label = "Regional standard",
					Value = selectedRegionText,
					LayoutOrder = 1,
				}),
				Language = e(SummaryRow, {
					Label = "Terminology",
					Value = values.LanguageVariant .. " English",
					LayoutOrder = 2,
				}),
				Traffic = e(SummaryRow, {
					Label = "Traffic side",
					Value = driveSideText,
					LayoutOrder = 3,
				}),
				Units = e(SummaryRow, {
					Label = "Display units",
					Value = values.UnitsPreset,
					LayoutOrder = 4,
				}),
			}),
		})
	end

	local progress = currentStep / TOTAL_STEPS
	local continueDisabled = currentStep == 2 and not regionIsValid
	local continueText = if currentStep == TOTAL_STEPS then "Finish" else "Continue"

	local scrollProps = Components.ScrollBar()
	scrollProps.ref = scrollRef
	scrollProps.Position = UDim2.fromOffset(1, 1)
	scrollProps.Size = UDim2.new(1, -2, 1, -2)
	scrollProps.BackgroundColor3 = SECTION
	scrollProps.BackgroundTransparency = 1
	scrollProps.BorderSizePixel = 0
	scrollProps.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollProps.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollProps.ScrollingDirection = Enum.ScrollingDirection.Y
	scrollProps.Active = true
	scrollProps.ClipsDescendants = true

	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = BACKGROUND,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Active = true,
		ZIndex = 100,
	}, {
		Shell = e("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -OUTER_PAD * 2, 1, -OUTER_PAD * 2),
			BackgroundTransparency = 1,
			ZIndex = 101,
		}, {
			Constraint = e("UISizeConstraint", {
				MaxSize = Vector2.new(SHELL_MAX_WIDTH, SHELL_MAX_HEIGHT),
			}),
			Header = e("Frame", {
				Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
				BackgroundTransparency = 1,
				ZIndex = 102,
			}, {
				Product = e("TextLabel", {
					Text = props.ProductName or "easyRoad",
					TextColor3 = Theme.ACCENT,
					BackgroundTransparency = 1,
					Position = UDim2.new(0, 0, 0, 4),
					Size = UDim2.new(1, -128, 0, 24),
					Font = Theme.FONT_BOLD,
					TextSize = 20,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextWrapped = true,
					ZIndex = 103,
				}),
				Context = e("TextLabel", {
					Text = "Quick setup",
					TextColor3 = Theme.DIM,
					BackgroundTransparency = 1,
					Position = UDim2.new(0, 0, 0, 31),
					Size = UDim2.new(1, -128, 0, 18),
					Font = Theme.FONT,
					TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextWrapped = true,
					ZIndex = 103,
				}),
				Skip = currentStep < TOTAL_STEPS and e("Frame", {
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, 0, 0, 8),
					Size = UDim2.new(0, 118, 0, 32),
					BackgroundTransparency = 1,
					ZIndex = 103,
				}, {
					Button = e(Components.Button, {
						Text = "Skip setup",
						OnClick = props.OnSkip,
						Size = UDim2.fromScale(1, 1),
					}),
				}),
			}),
			Progress = e("Frame", {
				Position = UDim2.new(0, 0, 0, HEADER_HEIGHT),
				Size = UDim2.new(1, 0, 0, PROGRESS_HEIGHT),
				BackgroundTransparency = 1,
				ZIndex = 102,
			}, {
				Label = e("TextLabel", {
					Text = string.format("Step %d of %d - %s", currentStep, TOTAL_STEPS, STEP_NAMES[currentStep]),
					TextColor3 = Theme.OFFWHITE,
					BackgroundTransparency = 1,
					Size = UDim2.new(1, 0, 0, 20),
					Font = Theme.FONT,
					TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextWrapped = true,
					ZIndex = 103,
				}),
				Track = e("Frame", {
					Position = UDim2.new(0, 0, 0, 26),
					Size = UDim2.new(1, 0, 0, 6),
					BackgroundColor3 = Theme.FIELD,
					BackgroundTransparency = Theme.GLASS_ELEMENT_TRANSPARENCY,
					BorderSizePixel = 0,
					ClipsDescendants = true,
					ZIndex = 103,
				}, {
					Corner = e("UICorner", { CornerRadius = UDim.new(1, 0) }),
					Fill = e("Frame", {
						Size = UDim2.new(progress, 0, 1, 0),
						BackgroundColor3 = Theme.ACCENT,
						BorderSizePixel = 0,
						ZIndex = 104,
					}, {
						Corner = e("UICorner", { CornerRadius = UDim.new(1, 0) }),
					}),
				}),
			}),
			ContentCard = e("Frame", {
				Position = UDim2.new(
					0,
					CONTENT_BORDER_INSET,
					0,
					HEADER_HEIGHT + PROGRESS_HEIGHT + CONTENT_BORDER_INSET
				),
				Size = UDim2.new(
					1,
					-CONTENT_BORDER_INSET * 2,
					1,
					-(HEADER_HEIGHT + PROGRESS_HEIGHT + FOOTER_HEIGHT + CONTENT_BORDER_INSET * 2)
				),
				BackgroundColor3 = SECTION,
				BackgroundTransparency = 0,
				BorderSizePixel = 0,
				ZIndex = 102,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0, 8) }),
				Stroke = e("UIStroke", {
					Color = Theme.GLASS_STROKE,
					Transparency = Theme.GLASS_STROKE_TRANSPARENCY,
					Thickness = 1,
				}),
				Content = e("ScrollingFrame", scrollProps, {
					Corner = e("UICorner", { CornerRadius = UDim.new(0, 7) }),
					Padding = e("UIPadding", {
						PaddingLeft = UDim.new(0, CONTENT_PAD),
						PaddingRight = UDim.new(0, CONTENT_PAD),
						PaddingTop = UDim.new(0, CONTENT_PAD),
						PaddingBottom = UDim.new(0, CONTENT_PAD),
					}),
					Layout = e("UIListLayout", {
						SortOrder = Enum.SortOrder.LayoutOrder,
					}),
					Page = page,
				}),
			}),
			Footer = e("Frame", {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 0, 1, 0),
				Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT),
				BackgroundColor3 = BACKGROUND,
				BackgroundTransparency = 0,
				BorderSizePixel = 0,
				ZIndex = 102,
			}, {
				Actions = e("Frame", {
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.new(0, 0, 0.5, 0),
					Size = UDim2.new(1, 0, 0, 34),
					BackgroundTransparency = 1,
					ZIndex = 103,
				}, {
					Layout = e("UIListLayout", {
						FillDirection = Enum.FillDirection.Horizontal,
						HorizontalAlignment = Enum.HorizontalAlignment.Right,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						SortOrder = Enum.SortOrder.LayoutOrder,
						Padding = UDim.new(0, 8),
					}),
					Back = e(Components.Button, {
						Text = "Back",
						OnClick = function()
							setCurrentStep(math.max(1, currentStep - 1))
						end,
						Disabled = currentStep == 1,
						LayoutOrder = 1,
						Grow = true,
					}),
					Continue = e(Components.Button, {
						Text = continueText,
						OnClick = function()
							if currentStep == TOTAL_STEPS then
								props.OnComplete(copyResult(values))
							else
								setCurrentStep(math.min(TOTAL_STEPS, currentStep + 1))
							end
						end,
						Selected = true,
						Disabled = continueDisabled,
						LayoutOrder = 2,
						Grow = true,
					}),
				}),
			}),
		}),
	})
end

return SetupWizard
