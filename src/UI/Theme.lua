local Theme = {}

-- Match easyRail / easyLight Software dock (darker than old Studio gray).
Theme.BACKGROUND = Color3.fromRGB(35, 35, 35)
Theme.PANEL = Color3.fromRGB(38, 38, 38)
Theme.FIELD = Color3.fromRGB(30, 30, 30)
Theme.WHITE = Color3.fromRGB(255, 255, 255)
Theme.OFFWHITE = Color3.new(0.8, 0.8, 0.8)
Theme.DIM = Color3.fromRGB(160, 160, 160)
-- easyRoad brand orange (#D98455)
Theme.ACCENT = Color3.fromRGB(217, 132, 85)
Theme.ACCENT_HOVER = Color3.fromRGB(227, 163, 128)
Theme.DANGER = Color3.fromRGB(196, 43, 28)
Theme.WARNING = Color3.fromRGB(239, 184, 56)
Theme.SELECTED = Color3.fromRGB(217, 132, 85)
Theme.BUTTON = Color3.fromRGB(60, 60, 60)
Theme.BUTTON_HOVER = Color3.fromRGB(75, 75, 75)

Theme.TEXT_SIZE = 16
Theme.HEADER_TEXT_SIZE = 14
Theme.FONT = Enum.Font.BuilderSans
Theme.FONT_BOLD = Enum.Font.BuilderSansBold
Theme.FONT_MONO = Enum.Font.RobotoMono

Theme.ROW_HEIGHT = 26
Theme.PADDING = 8

-- Industrial glassmorphism: Roblox UI has no backdrop blur, so glass is
-- approximated with translucent near-black cards, thin bright strokes,
-- and rounded corners.
Theme.GLASS_BG = Color3.fromRGB(16, 18, 22)
Theme.GLASS_TRANSPARENCY = 0.2
Theme.GLASS_ELEMENT_TRANSPARENCY = 0.35
Theme.GLASS_STROKE = Color3.fromRGB(255, 255, 255)
Theme.GLASS_STROKE_TRANSPARENCY = 0.72
Theme.CORNER_RADIUS = 10

-- Scrollbar: a soft grey-black bar, not a blunt fully-opaque one, so
-- scrolling reads as an affordance rather than a UI element competing for
-- attention.
Theme.SCROLLBAR_COLOR = Color3.fromRGB(90, 90, 96)
Theme.SCROLLBAR_TRANSPARENCY = 0.5
Theme.SCROLLBAR_THICKNESS = 5

return Theme
