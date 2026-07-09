# EasyRoad — Shipped

A running log of what's been built, most recent first. Not user-facing;
internal planning only. See `TODO.md` for planned new features and
`KNOWN_ISSUES.md` for confirmed bugs.

## Diagonal-strip seams closed exactly with FillTriangle, not padded

- **Replaced the flat `WEDGE_WIDTH_PAD` width margin with an exact fix**,
  per the plan scoped after the padding attempt didn't fully close the
  gaps a user confirmed with a follow-up screenshot. The true shape
  between two stations of a transitioning (offset- and/or width-changing)
  strip is a quadrilateral whose two "width" edges generally aren't
  parallel - no single rigid `Part` can represent that exactly, so no
  amount of padding a rotated-rectangle approximation was ever going to
  fully close it. Both `RoadBuilder.Build`'s main transition loop and
  `BuildWithBay`'s pavement-shift overlay now split that true quad into
  two triangles (along the innerStart-outerEnd diagonal) and fill each
  exactly with `Mesh/FillTriangle.lua` - the same exact-fill helper the
  bay's own pull-in-lane taper already used. Adjacent intervals share
  their exact corner positions by construction (both computed from the
  same per-station offset/width data), so there's no gap or overlap
  regardless of how sharply the offset or width changes station to
  station - not an approximation tuned to look acceptable, but the exact
  shape. `WEDGE_WIDTH_PAD` is removed entirely, now dead code.
- Not verified in a live Studio session (this environment can't render
  Studio) - this is the second attempt at this exact defect, so it
  particularly warrants a real check, ideally against the same
  exaggerated-size bay the user already has queued up for testing.

## Gaps at diagonal-strip seams (the "wedge, not blocks" fix's own residual gap)

- **Fixed sliver gaps at the seams between diagonally-oriented strips**,
  visible on an exaggerated-size bay a user built specifically to make the
  defect easier to see. Each transitioning strip is rotated to follow its
  own local slope (see the earlier "wedge, not blocks" round in
  `SHIPPED.md`), but the slope keeps changing along a taper - consecutive
  strips' width-direction edges are perpendicular to slightly different
  angles even though their centerline endpoints connect exactly, fanning
  apart a little at every seam. Added a flat `WEDGE_WIDTH_PAD` (0.15 studs)
  to diagonally-oriented strips' width, same "flat safety margin" approach
  already used for the existing length padding - applies to both the
  general `RoadBuilder.Build` transition loop and `BuildWithBay`'s
  pavement-shift overlay.
- Not verified in a live Studio session (this environment can't render
  Studio) - a flat pad should cover the normal case (adaptive station
  stepping already bounds the per-interval angle change), but an
  extremely exaggerated taper might still show a hairline residual gap.

## Bay ghost preview no longer hidden behind the road's own sidewalk

- **Fixed the bay drag ghost rendering underneath (and getting visually
  hidden by) the road's own sidewalk.** It was positioned a flat 0.1 studs
  above the frame's base level - fine for a flat drive lane, but raised
  components (sidewalk/median) sit `curbHeight` above that, and regions
  with any real curb height had the ghost sitting *below* the opaque
  sidewalk surface, which then visually occluded it wherever they
  overlapped. Since `RoadBuilder.Build`'s raised-component math places a
  sidewalk's top surface at exactly `curbHeight` above the frame (not an
  approximation - `centerY + partHeight/2` reduces to exactly that), the
  ghost now sits at `style.CurbHeightM * scale + 0.15` instead of a flat
  `0.1`, guaranteed above every part of the road regardless of the
  region's curb height.
- Not verified in a live Studio session (this environment can't render
  Studio).

## Keybinds rebuilt on PluginAction - the real fix, not another patch

- **Replaced the custom "click + Add binding, press a key" capture UI with
  Roblox's native `plugin:CreatePluginAction`.** Three rounds of patches to
  the old capture mechanism (removing a stray `gameProcessed` check, then
  gating mouse clicks on panel hover) never fully fixed rebinding, because
  the root cause isn't fixable from inside a docked panel's own script at
  all: `UserInputService` is scoped to the main 3D viewport, and a
  `DockWidgetPluginGui` is a genuinely separate native window - once it has
  focus, further input (keyboard especially) doesn't reliably reach
  `UserInputService`. This is a documented Roblox Studio platform
  limitation (confirmed via several devforum threads), not a bug specific
  to this codebase.
  - `main.lua` now registers three `PluginAction`s (Raise/Lower Elevation,
    Cancel Placement) once at startup. Their `.Triggered` events route
    directly into whichever session is active (`session.AdjustElevation`/
    `session.CancelPlacement`, or `editSession.CancelBayPlacement` while
    placing/confirming a bay) - Studio's own native "Customize Shortcuts"
    dialog (right-click any toolbar, or File > Advanced > Customize
    Shortcuts) is what assigns the actual key, and that dialog isn't built
    on `UserInputService`, so it doesn't have this focus problem.
  - The hardcoded R/F/Escape/middle-click defaults in
    `createRoadSession.lua`/`RoadEditSession.lua`'s own live listeners are
    untouched and still work with zero setup for everyone - they were never
    actually broken (they only matter while the 3D viewport itself has
    focus, during active placement, which was always a UserInputService-
    friendly context). The PluginActions are purely an *additional* way to
    trigger the same three actions, via whatever key the user assigns.
  - `UI/KeybindsGui.lua` is now a read-only reference (the three defaults,
    plus the exact `PluginAction` names to search for in Customize
    Shortcuts) instead of an interactive capture UI - there's no more
    capture code left in a docked panel at all, so this bug class can't
    recur here again.
- Not verified in a live Studio session (this environment can't render
  Studio) - `CreatePluginAction`'s exact signature/behavior was confirmed
  against Roblox's own Creator Hub documentation, but the end-to-end flow
  (Customize Shortcuts actually finding and letting you bind these three
  actions) hasn't been checked hands-on.

## Pie-menu hover-trap breaking bay drag entirely

- **Fixed the bus bay drag being completely unusable** ("i simply cant draw
  the area"). Root cause: every pie-menu mode (Menu/SegmentMenu/PlacingBay/
  ConfirmingBay) swaps in a totally different set of `PillButton`s at the
  same world anchor. Clicking "Add Bus Bay" fires its `OnClick`, which
  switches the mode and re-renders the pie menu with a *different* set of
  pills - the "Add Bus Bay" pill itself unmounts immediately while the
  mouse is still sitting on it, and React destroying a hovered element
  never fires its own `MouseLeave`. `uiState.Hovered` (set by that pill's
  `MouseEnter`) got stuck `true` forever after, and `onBayDragBegin`'s
  "don't place through the HUD" guard silently blocked every subsequent
  viewport click - the third occurrence of this hover-trap class of bug in
  this codebase (see `KNOWN_ISSUES.md`). Fixed by resetting
  `uiState.Hovered` whenever the pie menu's rendered mode actually changes
  between renders, tracked via a `lastPieMenuMode` value in `main.lua`.
- Not verified in a live Studio session (this environment can't render
  Studio) - flagged as high-confidence given the mechanism is fully
  traceable in the code, unlike some other unverified entries.

## Bay side-of-drag, wedge-not-block tapers, keybind capture fix

- **Fixed the bus bay always appearing on the region's default driving
  side, ignoring which side the user actually dragged toward.**
  `BuildWithBay`/the drag ghost derived their "nearside" purely from
  `style.DriveOnLeft`, never from the drag itself - a user screenshot
  showed the bay rendering on the opposite side from where they dragged.
  `RoadInstance.BayData`/`RoadBuilder.BayPlacement`/`RoadEditSession.BayDraft`
  all gained a `Side: "Left" | "Right"` field, computed from the *signed*
  lateral component of the drag (`(currentHit - startHit):Dot(frame.RightVector)`)
  instead of the region setting - a bay can go on either side of a road
  regardless of which side traffic drives on.
- **Replaced axis-aligned staircase strips with diagonally-oriented ones**
  wherever a strip's offset shifts between two stations (an ordinary
  widen/narrow transition, or the bay's displaced-pavement overlay) - a
  user screenshot showed a visible staircase on the bay's shifted sidewalk.
  Previously every strip was built flat-and-square to the curve tangent,
  holding a constant offset for its whole length before the next strip
  stepped to a new one; now, whenever a component's center offset differs
  between its two stations, the strip is oriented via `CFrame.lookAt`
  between its own true endpoint positions instead - not a mathematically
  exact trapezoid (a `Part` still can't taper along its own length), but
  angled to follow the true taper rather than holding flat until a sudden
  step, which fine adaptive stepping should now read as smooth. Applies to
  both the general `RoadBuilder.Build` transition loop and `BuildWithBay`'s
  pavement-shift overlay; completely unaffected for the ordinary
  non-transitioning case (same construction as before when a component's
  offset doesn't change).
- **Fixed the Keybinds capture listener treating a click on its own Close
  button as the captured input.** `UserInputService.InputBegan` fires on
  mouse-*down*, before a clicked button's own `Activated` (mouse-*up*)
  runs - so clicking Close while a capture was pending had that same
  click's mouse-down captured and bound as "MouseButton1" a moment before
  Close's own effect (closing the dock) fired, which is what a user's "it
  detects my left click after i press close" report was describing.
  `KeybindsGui` now reports its own hover state up (`OnHoverChanged`,
  mirroring the `uiState.Hovered` pattern already used for the 3D viewport
  HUD), and `captureNextKeybind` ignores mouse-button input (but not
  keyboard keys, which have no such ambiguity) while the pointer is over
  the panel's own buttons.
- Not verified in a live Studio session (this environment can't render
  Studio).

## Bus bay overlap, drag reliability, bus stop consolidation

- **Fixed the bus bay overlapping the nearside pavement.** `BuildWithBay`
  previously overlaid the bay's asphalt outward of the kerb but never
  moved the sidewalk, which the base build still rendered at its original
  (raised) position - the two occupied the same footprint, so the raised
  sidewalk visibly floated above/through the new low bay asphalt.
  `RoadBuilder.Build` gained `ExcludeComponentIndices` (skips deck-strip
  Parts for specific component indices without touching anything else);
  `BuildWithBay` now builds the road in three pieces (normal / bay-
  affected with the nearside component excluded / normal) and overlays a
  new chain of small strips for the displaced pavement, its inner edge
  following the exact same straight-line ramp as the bay's own
  `FillTriangle` taper edge - the two boundaries are the same line by
  construction, so there's no gap and no overlap. See `KNOWN_ISSUES.md`
  for a remaining gap (kerb-restriction line markings don't follow the
  bulge yet).
- **Fixed bay drag placement registering unreliably** ("sometimes it just
  doesn't do anything"). `onBayDragBegin` required `mouse.Target` to land
  on the road itself to start the drag, but `onBayDragMove`/`onBayDragEnd`
  never had that requirement - a drag that started a pixel off the road's
  edge (baseplate showing through a thin gap, a grazing camera angle)
  silently failed to register at all, with no ghost, no feedback, nothing.
  Removed the requirement; the drag now always registers off
  `ClosestS(mouse.Hit.Position)` regardless of what was actually hit,
  matching how the rest of the gesture already worked.
- **Removed the standalone "Add Bus Stop" marker feature.** Per user
  feedback, a real bus bay already serves as a stop, so a separate
  marker-only mode was redundant. Removed the button, `PlacingBusStop`
  mode, and its click handler from `RoadEditSession`/`main.lua`; kept
  `BusStops.Render` in the Apply/ConfirmBay rebuild paths so any markers
  placed before this change keep rendering correctly - no data loss for
  existing roads, just no way to add new ones.
- **Hid "Add Bus Bay" for Highway-category roads** - real highways don't
  have bus bays, per user feedback ("not up to code").
- Not verified in a live Studio session (this environment can't render
  Studio) - the bay/pavement geometry fix in particular is substantial new
  slicing logic and warrants real testing.

## Icon-based category tabs

- **Category tabs (Streets/Avenues/Highways/Paths/Custom) are now live 3D
  icons instead of text**, fixing the truncation the user's screenshot
  showed ("Aven...", "Highw...", "Custo..."). New `Mesh/CategoryThumbnail.lua`
  reuses `ProfileThumbnail`'s existing 3/4 top-down camera technique against
  a fixed representative built-in profile per category (there's no single
  "shape" for a category itself) - Streets from the two-lane street, Avenues
  from the boulevard, Paths from the pedestrian path, Custom from the same
  generic template `main.lua`'s "+ New" starts from (no built-in exists for
  a user-only category). Highways additionally get a simple two-post
  overhead gantry overlay purely for the icon - EasyRoad has no real
  gantry/sign-structure feature to build from, so this is decorative only.
  `ProfileThumbnail.Build`'s camera-framing math is now exposed separately
  (`FrameCamera`) so the gantry overlay can re-frame after adding its own
  geometry instead of duplicating that math.
- A generated roundabout icon was part of the same request but deliberately
  **not** built this round - roundabouts aren't an implemented feature and
  there's no UI slot that would use a roundabout icon yet, so it would be
  orphaned geometry with no consumer. Left as a `TODO.md` note instead.
- Not verified in a live Studio session (this environment can't render
  Studio).

## Road Tools left-aligned, Road Library grid

- **Tool Mode is now left-aligned with padding** instead of sitting bottom-
  center as half of a shared wrapper - Studio has much less usable screen
  width than a dedicated game window, so CS2's own bottom-center layout
  doesn't translate directly (queued user feedback from a prior round).
  Road Library moved to be independently bottom-right-anchored (same 16px/
  12px padding) rather than positioned relative to Tool Mode, so the two
  panels no longer share one sized wrapper - each is now anchored straight
  to the screen. (Hover-tracking already lived on each panel individually
  after this round's placement-bug fix, so decoupling their positioning
  didn't reintroduce the hover-trap bug.)
- **Road Library tiles are now a real wrapping grid** (`UIGridLayout`,
  auto-column-count, vertical scroll for more rows), not a single
  horizontal scrolling strip - closer to CS2's own library grid.

## Fixed road placement, centerline-anchored curves, trapezoid bay, drag-to-draw bay

- **Critical: road placement was completely broken by last round's two-panel
  split.** `bottomFrameProps` for the Road Tools HUD wraps both new panels
  in one shared 612x430 box, and the generic hover-tracking `MouseEnter`/
  `MouseLeave` handlers were attached to that *whole* box - but the two
  actual panels only fill small corners of it (Road Library is 170px tall
  inside a 430px-tall column), leaving a large transparent dead zone in the
  lower-center of the screen that still counted as "hovering the HUD". That
  dead zone sits right where placement clicks land, so `uiState.Hovered`
  stayed `true` and `createRoadSession.onClick`'s "don't place through the
  HUD" guard silently swallowed essentially every placement click - the
  same class of bug as the earlier pie-menu full-screen hover trap, just
  reintroduced in a new spot. Fixed by tracking hover on the two inner
  panels (`ToolMode`/`RoadLibrary` frames) independently and OR-ing them
  into `uiState.Hovered`, instead of on their shared outer wrapper.
- **Reverted curve deck strips to centerline-anchored, removed
  `Settings.CurveAlignment` (Center/Inside/Outside) entirely.** The
  Inside/Outside anchored-edge construction (built two rounds ago) anchored
  one edge of each strip exactly to the curve while approximating the
  other - which turned out to be the actual cause of a reported "drift"
  where the road's visual centerline wandered off the originally-clicked
  path on sustained curves, since only one edge (never the centerline)
  tracked the true path. Combined with continuing wedge artifacts and holes
  under that scheme, reverted entirely rather than patched further: every
  deck strip is now always centered on the curve's true midpoint frame for
  its own interval (`curve:FrameAt(sMid, rollMid)`), both edges padded via
  the existing `curveMiterPad` formula. This can't drift, by construction -
  the strip's center is always an exact point on the curve. Also removed
  `WEDGE_GAP_THRESHOLD_STUDS` and the conditional wedge-fill path that went
  with the anchored-edge scheme.
- **Bus bay is now an actual trapezoid**, not a taper built from the general
  widen/narrow staircase-of-rectangles machinery. `RoadBuilder.BuildWithBay`
  no longer slices the curve into 5 sub-builds and threads a `Bay` profile
  component through the transition system (removed `RoadProfile.WithBay`
  entirely) - it now builds the base road normally with one plain `Build()`
  call, then overlays the bay as its own exact geometry: a flat rectangular
  "dwell" section at full bay width, plus one `FillTriangle` call at each
  end for the taper. Each taper is provably a single triangle, not a full
  quadrilateral - the narrow end of any taper has zero width by definition,
  so there's exactly one "pinch point", fillable exactly instead of
  approximated.
- **Bay placement is click-and-drag, not click-then-type.** Previously,
  clicking a single point on the road immediately committed a
  default-sized bay, with no way to see or adjust it before it existed.
  Now `RoadEditSession` tracks a `Button1Down` → `Move` → `Button1Up` drag:
  a live translucent ghost part shows the bay's footprint (length along the
  road, width from the kerb) while dragging, sized/positioned exactly like
  `BuildWithBay`'s own geometry, and releasing the drag hands off to the
  existing length/width fine-tune panel (`BayDraftPanel.lua`) before
  Add Bay commits it - matching how the user actually wants to draw a real
  bay's footprint by hand.
- Not verified in a live Studio session (this environment can't render
  Studio) - all four changes above are logic/geometry fixes that need real
  in-Studio testing, especially the placement-click fix given how critical
  it is.

## Two separate CS2-style boxes: Tool Mode + Road Library

- **Split into two independent floating panels side by side**, not one
  panel with everything stacked inside it - a screenshot from the user
  showed the CS2 reference is genuinely two separate boxes (Tool Mode on
  the left, Road Library on the right), which an earlier same-round attempt
  (one wider bar with an internal "Road Library" section) still didn't
  match. `BuildBar.lua` is now Tool Mode only (drawing mode, widen-to,
  banking, elevation, hint, stop button); the road picker moved to a new
  `UI/RoadLibraryPanel.lua`, rendered as its own bottom-right-anchored
  panel next to Tool Mode's bottom-left one.
- **`RoadLibraryPanel.lua`: Streets / Avenues / Highways / Paths / Custom
  category tabs above a horizontal strip of road tiles** (thumbnail over a
  small label, side-scrolling), replacing the old vertical thumbnail-row
  list - closer to CS2's horizontal tile strip than the previous round's
  kept-as-is vertical list. Categories are read straight off each
  `RoadProfile.Category` value already in the data model, in a fixed
  preferred order with any unrecognized category appended after.
- Both panels sit inside one shared invisible hover-tracking wrapper sized
  to their combined footprint (not the whole screen - the pie menu's
  earlier click-swallowing bug this round was a direct lesson in getting
  that scope wrong).

## Real bus bay geometry, gradient colour picker, drag-and-drop fix, locale toggle

- **Fixed the farEdgePad regression from last round** (sawtooth/serrated
  curve edges on widen/narrow roads) - see `KNOWN_ISSUES.md` for the full
  root-cause writeup. Removed entirely; deck strips are back to plain exact
  anchored width.
- **Real bus bay geometry**, not just marker stickers. What used to be
  called "Add Bus Bay" only ever placed small bus-stop icon markers
  (`BusStops.lua`) - a real bay (per the user's reference photo) is a
  physical pull-in carved into the road, which didn't exist at all. Now:
  - `Geometry/PolyCurve.lua` gained `Slice(s0, s1)` (a thin re-indexed view
    over a sub-range of an existing curve - no new segment data, delegates
    every query to the base curve plus an offset) and `ClosestS(point)` (a
    coarse-sample-then-refine numeric search for where a 3D click lands
    along the curve).
  - `RoadProfile.WithBay(profile, driveOnLeft, widthM)` inserts a Bay
    component next to the nearside kerb.
  - `Mesh/RoadBuilder.BuildWithBay(options, bay)` stitches 5 sub-builds
    (normal / taper-in / dwell / taper-out / normal) from `Curve:Slice()`
    ranges into one merged model, reusing the existing widen/narrow taper
    machinery for both tapers rather than inventing a new shape.
  - `RoadEditSession` gained a `PlacingBay` -> `ConfirmingBay` flow: click a
    point on the road, then adjust length/width (defaulting to a standard
    dwell length and one lane's width) in a small HUD panel
    (`UI/BayDraftPanel.lua`) before committing. Bay placement persists as a
    `RW_BayJson` attribute (`RoadInstance.StampBay`/read) so later edits via
    `RoadEditSession.Apply` rebuild through `BuildWithBay` instead of
    silently dropping the bay.
  - The old marker feature is renamed throughout (mode, functions, pie
    label) from "Bus Bay" to "Bus Stop" to stop misleading users about what
    it actually does; both now sit side by side in the segment pie menu.
  - Not verified in a live Studio session - this is substantial new
    geometry code and warrants real testing before being trusted.
- **Real gradient colour picker.** There's no Studio API to open the native
  color picker from a plugin (devforum's been asking since ~2016, never
  shipped), so `Components.ColorField` now includes its own: a saturation/
  value gradient square and a hue bar, built from plain Frames + UIGradient
  (no image asset needed), drag-to-pick via each square/bar's own
  InputBegan/InputChanged + `UserInputService:IsMouseButtonPressed` - plus
  the existing hex/Color3-text field and R/G/B number fields for precise
  entry.
- **Drag-and-drop from the Modules palette, real fix attempt.** Previous
  rounds' rewrites used `plugin:GetMouse()` polled on `RenderStepped`,
  reasoning that `UserInputService` is unreliable for Studio plugin GUIs -
  but that reasoning was borrowed from a different, unrelated bug
  (`DockWidgetPluginGui` panels marking input as `gameProcessed` while
  focused). This palette is a plain ScreenGui in CoreGui, not a docked
  panel, and `plugin:GetMouse()`'s `Button1Up` is a 3D-viewport/tool
  oriented event not guaranteed to fire reliably for a 2D GUI drag that
  never activates the plugin as a tool - which would explain drops never
  registering. Rewritten to use `UserInputService.InputChanged`/`InputEnded`
  instead, the same proven pattern this round's colour picker drag uses.
- **British/American English terminology toggle** (`Settings.LanguageVariant`,
  default British). New `Locale.lua` maps display-only term pairs (Kerb/Curb,
  Pavement/Sidewalk) - internal field/kind names are unchanged. Wired into
  the Kerb-lines rows, Region Editor's dimension/colour labels, with a
  dropdown in Regional Preference to switch it.

## Wedge scope-down, real click-swallowing bug, settings home, elevation editing

- **Wedge joints now only appear on genuinely sharp turns/superelevation.**
  `Mesh/RoadBuilder.lua`'s Inside/Outside curve joints used to insert a
  `FillTriangle` wedge at every curved joint, however gentle. Deck strips now
  widen slightly on their far (non-anchor) edge every interval (reusing the
  existing `curveMiterPad` formula, applied to width instead of length,
  anchor-side face held fixed so it doesn't disturb the exact anchor edge),
  and a wedge is only added at a joint if the true remaining gap
  (`WEDGE_GAP_THRESHOLD_STUDS = 0.5` studs) is still bigger than that padding
  could plausibly cover - i.e. only where a flat rectangle genuinely
  couldn't hide the defect.
- **Lane markings now anchor to true curve position at both of their own
  endpoints** (`placeMarkingSpan`), the same technique the deck's anchored
  strips already used, instead of a `curveMiterPad`-padded box centered on a
  midpoint frame plus a separate joint-patch part. Solid rails now meet
  exactly at every interior station with no patch needed, and align with
  whichever deck edge sits at the same lateral offset (previously the
  approximation used by markings and the exact anchor used by
  Inside/Outside deck strips could visibly disagree at a joint - this is
  what showed up as a lane marking not lining up with the road edge, and the
  patch could show up as an overlap).
- **Root cause found for "Bus Bay doesn't work" / "can't stretch a lane
  marking, it just opens Road Builder":** the pie menu's screen-covering
  wrapper `Frame` in `main.lua` had `MouseEnter`/`MouseLeave` wired to
  `uiState.Hovered` - since that frame spans the *entire* viewport (needed
  so the anchored pie menu can appear anywhere within it), the mouse
  "entered" it almost immediately whenever any pie menu showed (i.e.
  whenever a road was selected), latching `Hovered` true and never really
  clearing. `RoadEditSession.onBusBayClick`'s "don't place through the HUD"
  guard (`if uiState.Hovered then return end`) then swallowed essentially
  every click in the 3D viewport while a road was selected. Fixed by moving
  hover tracking onto each individual `PillButton` (`PieMenu.lua`'s new
  `SetGlobalHover` prop) instead of the full-screen wrapper. ("Edit Lane
  Markings" opening the full designer instead of a dedicated stretch
  interaction is separate and expected - that interaction was never built,
  see `TODO.md`.)
- **Pie menu pills now sit on one consistent ring.** The old per-slot pixel
  offsets (`Top`/`TopLeft`/`Left`/`Right`/`Bottom`) had different distances
  from the anchor (70-110px) - not actually on a circle, which is what read
  as "not all on the circumference." `PieMenu.lua` now generates every
  offset from a single `RING_RADIUS` and an angle.
- **Settings now has a home menu instead of forcing both docks open/closed
  together.** The Settings button used to toggle `regionalDock.Enabled` and
  `keybindsDock.Enabled` as one unit - both docks default to the same float
  position, so the second one opened was effectively invisible/unreachable
  behind the first, which was very likely why keybind capture still seemed
  broken even after the earlier `gameProcessed` fix (the user was probably
  never actually looking at the Keybinds dock). `TopBar.lua`'s Settings
  button now opens a small popover to choose "Regional Preference" or
  "Keybinds" - each its own independently-toggled dock.
- **Elevation is now directly editable** (`BuildBar.lua`'s elevation control
  is a `Components.NumberField`, wired through a new
  `createRoadSession.SetElevation`) instead of a read-only label, with no
  "+" prefix on positive values (only negatives show a sign). Added a CS2-
  style step-size field (`Settings.ElevationStepStuds`) right next to it, so
  how far each R/F press or arrow click moves no longer requires opening a
  separate settings dock.
- **Widen/narrow taper smoothed.** `transitionAlpha` used to be a flat 0
  followed by a linear ramp - a real slope discontinuity (kink) exactly
  where the taper zone begins, since the flat zone's derivative is 0 and the
  ramp's is a nonzero constant. Now smoothstepped (`3t^2 - 2t^3`), whose
  derivative is 0 at both ends, so the taper blends in and out with no
  visible bend. Station spacing inside a transition now also scales with
  how fast the width is changing (studs of width change per stud of length)
  instead of a flat 4-stud cap, so a short/steep taper still gets short
  enough strips to read as a smooth line rather than a staircase. (A fully
  exact wedge-trapezoid taper - each strip literally tapering across its own
  length instead of stepping between strips - is specified as a follow-up
  in `TODO.md` if this isn't enough on real testing.)
- **Colour fields are far more compact and take hex/Color3 text input.**
  `Components.ColorField` was a swatch plus 3 separate R/G/B number fields -
  wide enough (~300px) to overflow the settings dock's 260px minimum width,
  which is very likely what read as "doesn't render within the size
  constraint." Now a swatch plus one text field accepting either `#RRGGBB`
  or an `r, g, b` triplet, with the full R/G/B fields available by clicking
  the swatch to expand.
- **Section headers now have a divider and breathing room above them**
  (`Components.Section`), instead of blending straight into the previous
  section's last row - addresses "better separation between each section,"
  applied everywhere `Components.Section` is used (Regional Preference,
  Keybinds, Region Editor, Road Tool/Road Library, Road Editor).
- **Road Tool and Road Library are now visually two distinct groups** in
  `BuildBar.lua` (matching the CS2 reference screenshot), separated by
  `Components.Section`'s divider rather than sitting in one unbroken stack.

## Keybind capture bug + elevation hint + cancel default

- **Fixed: adding a new keybind silently did nothing.** Root cause:
  `main.lua`'s `captureNextKeybind` listened via
  `UserInputService.InputBegan` but bailed whenever `gameProcessed` was
  true - and Studio marks essentially all input as game-processed while a
  docked plugin panel has focus (so it doesn't also trigger 3D-viewport
  shortcuts), meaning the listener's callback returned immediately on
  every keypress/click during capture and nothing ever got added. Fixed
  by not checking `gameProcessed` for this specific listener - during an
  explicit "press a key or click..." capture, whatever the user just
  pressed IS the input we want, regardless of what else has focus. (Live
  R/F/Escape handling elsewhere, e.g. `createRoadSession.lua`, still
  checks `gameProcessed` correctly - that's a different, correct use of
  the same guard, for a different listener.)
- **Elevation hint now shows the user's actual configured keys**, not a
  hardcoded "(or R / F keys)" - `BuildBar.lua` reads
  `settings.Keybinds.ElevationUp`/`ElevationDown` through
  `Keybinds.Describe` so it updates automatically after a rebind.
- **Right-click is no longer a default for Cancel Placement.** It still
  works as Studio's own camera-orbit gesture and can still be added back
  manually via "+", but the shipped default is now just Escape and
  middle-click (the scroll-wheel button) - avoids a right-click meant to
  nudge the camera accidentally cancelling a placement.

## Superelevation + curved-section gap fixes

Both `Mesh/RoadBuilder.lua` bugs identified and fixed:

- **Superelevation inconsistency root cause found**: the runoff/smoothing
  window was a fixed `RUNOFF_LENGTH_STUDS` (40 studs) regardless of segment
  length, capped only at `length / 2`. For a short segment this meant the
  ramp-up and ramp-down taper zones could consume the *entire* road with no
  flat "full bank" middle ever reached, while a long segment of the same
  curve radius reached full target bank easily - so two curves that looked
  equally sharp banked to very different peak amounts purely because of
  their length. Fixed: both the `Superelevation.SmoothRolls` window and the
  end-of-segment taper now use `math.min(RUNOFF_LENGTH_STUDS, length * 0.3)`
  - proportional to the segment, always leaving at least a 40% flat middle
  zone, so short and long curves of the same radius now shape the same way.
- **Curved-section gaps root cause found**: the per-strip "miter" padding
  used `math.abs(centerOffset + width/2) * math.sin(turnAngle)`, clamped to
  `math.min(miter, chord * 2)`. That clamp silently truncated the needed
  padding whenever a component's lateral distance from the centerline was
  large relative to the (adaptively short) chord on a tight curve - exactly
  the case for wide roads (multi-lane avenues/highways) on anything but
  gentle curves, which is why gaps were visible. Replaced with a new
  `curveMiterPad` helper derived directly from arc length (a point offset
  `r` studs from the centerline traces `r * curvature * length` more arc
  than the centerline over the same span - the exact deficit a flat strip
  needs to make up) with no arbitrary clamp; applied using the larger of
  each component's two edge distances (not just the right edge) and using
  true arc length (`s1 - s0`) instead of the straight chord as the base
  span. Also applied to lane markings (`renderSolid`/`renderDashed`), which
  previously got a flat `0.05` stud pad with zero curvature awareness at
  all - markings are thin and high-contrast against the asphalt, so an
  un-mitered gap there was arguably the most visible instance of this bug.
- **Follow-up: verified the miter fix numerically, then closed the
  residual exactly instead of approximating it.** The user pointed at
  [stravant/roblox-gapfill](https://github.com/stravant/roblox-gapfill) (a
  real Studio plugin for closing gaps between arbitrary geometry, using
  `fillTriangle`-style wedge parts oriented via `CFrame.fromMatrix`, MIT
  licensed) and [stravant/roblox-redupe](https://github.com/stravant/roblox-redupe)
  (an array-duplication tool - read for completeness, not directly
  applicable here). Worked out the exact 2D geometry by hand for a
  circular-arc test case (17° turn per strip, 15-stud lateral offset -
  deliberately aggressive) first, to check whether the miter padding
  actually closes the gap or just approximates it: confirmed it closes it
  to within ~0.03-0.06 studs even in that extreme case (the padding
  extends each strip along its own straight tangent, which tracks the true
  curve closely but not exactly). A first pass closed that residual with
  another generously-sized approximation (a small block patch at each
  joint); the user then asked for GapFill's actual technique to be
  included properly, not just referenced - so `Mesh/FillTriangle.lua` now
  ports `fillTriangle` itself (the tricky part: the edge-reordering that
  avoids thin sliver wedges, and the exact `CFrame.fromMatrix` + Wedge
  construction), simplified for our case since we always know which way is
  down (a direct `downVector` argument, replacing the original tool's
  ambiguous `desiredSurfaceNormal`/reference-part heuristics, which exist
  because *its* fills are between arbitrary, not-necessarily-related
  geometry). `RoadBuilder.Build` now records each interval's `MidFrame` +
  per-component offsets/widths as it builds the main strips, then a second
  pass at every interior curve joint reconstructs each component's exact
  (unpadded) end corners on both sides, splits that quad into two
  triangles, and fills them with `FillTriangle` - an exact closure, not
  just a generous approximation, superseding the deck strips' block-patch
  pass. Solid markings still use the earlier (simpler, block-patch) fix
  rather than the new exact one - their miter-padding residual is already
  tiny and extending `FillTriangle` to markings/dashes would add real
  complexity for a mostly cosmetic, already-small discrepancy; revisit if
  it turns out to matter in practice.
- **Follow-up: Curve Alignment setting (Center/Inside/Outside), replacing
  approximation with exact construction on one edge.** The user asked
  about [Archimedes 3](https://devforum.roblox.com/t/introducing-archimedes-3-a-building-plugin/1610366),
  a popular Roblox building plugin with a Center/Inside/Outside path-
  alignment concept. Looked into it: Archimedes' modes pick which
  reference line an extruded shape follows (like choosing whether a wall
  hugs a room's inside, outside, or center line) - its "Outside" mode
  still leaves a gap at corners for the user to patch by hand, so it isn't
  a fancier gap-closing algorithm than what was already here. But the idea
  suggested a real improvement: instead of centering every strip on its
  own interval's tangent frame and *padding* to approximate closing the
  gap on both edges (today's `Center` mode, unchanged), a strip can be
  built by anchoring one specific edge directly to the true curve points
  at both of its station endpoints. Since adjacent intervals reference the
  literal same cached station frame (not two independent approximations),
  that edge becomes gap-free *by construction*, not by tuning a padding
  formula - only the opposite (residual) edge can still gap, and that gets
  closed exactly with `FillTriangle` (one triangle per joint per
  component, not the two-triangle quad Center mode's joint fill needs,
  since one corner of the gap collapses to the shared exact anchor point).
  Shipped as a new `Settings.CurveAlignment` field ("Center" | "Inside" |
  "Outside", default `Inside`), exposed as a dropdown in Regional
  Preference → Geometry. `Mesh/RoadBuilder.lua`'s deck-strip section now
  branches on it: `Center` is the untouched original approach; `Inside`/
  `Outside` use a new `anchoredStripCFrame` helper (built via
  `CFrame.lookAt` between the two true anchor-edge points, reusing Roblox's
  own frame-construction primitive rather than re-deriving a right-vector
  convention by hand, to sidestep a whole class of sign-error risk).
  Markings aren't threaded through `CurveAlignment` yet - they keep the
  existing miter-padding treatment regardless of the setting, matching the
  `FillTriangle` scope decision above.

## Custom region profiles

- **Users can now create and edit their own region presets**, not just pick
  from the seven built-ins.
  - `RegionStyles.lua` gained `BuiltIn: boolean` on the type (all seven
    built-ins flagged `true` via `makeStyle`), plus `Clone`/`Serialize`/
    `Deserialize` mirroring `RoadProfile.lua`'s pattern exactly - Color3
    fields serialize to a plain `{R, G, B}` (0-255) table, never a raw
    `Color3`, matching this codebase's settings-storage rule.
  - `Settings.UserRegions` (serialized user presets) mirrors `UserProfiles`;
    new `RegionLibrary.lua` mirrors `RoadLibrary.lua` exactly
    (`GetAll`/`Get`/`SaveUserRegion`/`DeleteUserRegion`/
    `SerializeUserRegions`). `main.lua`'s `getStyle()` now resolves through
    `regionLibrary.Get` instead of `RegionStyles.Get` directly, so every
    consumer (road building, previews, the designer, thumbnails) picks up
    custom regions with no other code aware anything changed.
  - New `UI/RegionEditor.lua` covers all ~25 fields grouped into sections
    (identity, traffic layout, dimensions, superelevation limits, the three
    marking specs with conditional dash length/gap, marking width/colours,
    seven surface colours) using the same clone-and-transform `OnChange`
    convention as `RoadDesigner`/`ProfileFields`. Two new shared inputs
    support it: `Components.TextField` and `Components.ColorField` (a
    swatch + R/G/B number fields - no gesture-based hue/saturation picker,
    just reliable typed input).
  - Wired into `RegionalPreferenceGui.lua`: "Customize This Region" (built-
    in - Save always creates a copy, same convention as editing a built-in
    road) / "Edit This Region" (already custom - edits in place) / "+ New
    Region" (clones the active style as a starting point) buttons above the
    region dropdown, which now lists user regions too (suffixed
    "(custom)"). The editor replaces the normal settings view while active
    (Save/Delete/Cancel), matching the Road Editor's designProfile-swap
    pattern.

## Road library thumbnails + "Edit Road Segment" (scoped)

- **Road library rows now render a live 3D cross-section thumbnail**
  instead of plain text, CS2-style. `Mesh/ProfileThumbnail.lua` calls the
  real `RoadBuilder.Build` with a short straight `PolyCurve` (no new
  extrusion algorithm needed, confirmed feasible per an earlier note) and
  returns a framing camera CFrame; `UI/RoadThumbnail.lua` renders that into
  a `ViewportFrame` (its own `WorldModel` + `Camera`, built/torn down in a
  `useEffect` keyed on the profile's serialized content + region style id).
  `RoadDesigner.RoadLibraryList`'s `Options` now carry the full
  `RoadProfile` (`LibraryOption` type) instead of just `{Id, Text}`, and
  every call site (`RoadDesigner.Panel`'s Created Roads tab, `BuildBar`'s
  road picker) threads `RegionStyle`/`Settings` down so the thumbnail can
  build. No pooling yet - acceptable for the current library sizes; flag if
  a long user library makes per-row live `ViewportFrame`s a real cost.
- **"Edit Road Segment" pie-menu submenu**, scoped down from the full
  original ask (see `TODO.md` for what's still deferred - the marking
  "stretch" interaction). The pie menu's top level gained a fifth pill
  (`PieMenu.lua`'s new `TopLeft` slot) - "Edit Road Segment" - opening a
  second-level submenu at the same world anchor: **Add Bus Bay** / **Edit
  Lane Markings** / **Back**. `RoadEditSession.lua`'s pie-menu state is now
  a 4-state machine (`Menu` / `SegmentMenu` / `PlacingBusBay` / `Designer`)
  instead of a boolean.
  - **Add Bus Bay** starts a click-to-place mode (`plugin:Activate` +
    `plugin:GetMouse()`, matching the established mouse-tracking
    convention): click a `Sidewalk`/`Parking` part on the selected road to
    drop a stop marker, click an existing marker to remove it, cancel-
    placement key returns to the submenu. New `BusStops.lua` module stores
    stops as a JSON attribute (`RW_BusStops`, mirroring the
    `RW_ProfileStartJson` pattern) and renders them as a billboard-icon
    marker folder under the road model; `RoadEditSession.Apply` re-renders
    them after a geometry rebuild since they'd otherwise be destroyed along
    with the old parts. This is a marker/decoration, not a cross-section
    change - the full "designate part of the roadway as a bus lane"
    geometry feature remains the existing `Bay` component kind, unchanged.
  - **Edit Lane Markings** opens the existing full designer (same as "Edit
    on Road Builder"), where a selected lane's marking can now also be set
    directly with number keys 1-4 (`RoadDesigner.lua`'s
    `NUMBER_KEY_TO_BOUNDARY`), alongside the existing dropdown.

## Keybinds, docked settings split, drag-and-drop take 3

- **Rebindable keybinds.** New `Keybinds.lua` module (action ids, default
  bindings, human-readable `Describe`, `CaptureLabel` for turning a live
  `InputObject` into a plain string, `Matches`/`Sanitize`). Settings now
  persist `Keybinds: {[actionId]: {string}}` (plain strings, e.g. `"R"`/
  `"MouseButton2"` - never raw `Enum`s, matching `RoadProfile`'s
  Kind-as-string convention) and a new `KeybindsGui.lua` lets each action
  have multiple bound inputs, each with its own "-" remove button and a
  shared "+ Add binding" that listens for the next key/click.
  `createRoadSession.lua` now reads `settings.Keybinds` instead of
  hardcoded R/F/Escape.
- **Settings split into two independent docks**, not tabs sharing one
  panel: "Regional Preference" (region/scale/superelevation/snapping/
  geometry - everything the old single settings page had minus keybinds)
  and "Keybinds", each its own `DockWidgetPluginGui` (`loader.server.lua`),
  toggled together from the top bar's Settings button.
- **Elevation height now remembered across sessions**
  (`Settings.LastElevationStuds`), instead of resetting to 0 every time a
  build session starts.
- **Scrollbar styling.** `Components.ScrollBar()` returns a shared
  grey-black, 50%-transparent scrollbar style
  (`Theme.SCROLLBAR_COLOR`/`_TRANSPARENCY`/`_THICKNESS`) applied to every
  `ScrollingFrame` in the plugin; every one of them also now forces
  `ScrollingDirection = Y` + a zeroed `CanvasSize.X` (the lane strip is the
  deliberate exception, staying horizontal) so nothing can drift
  sideways.
- **Drag-and-drop rewritten a third time**, now using `plugin:GetMouse()`
  polled on `RunService.RenderStepped` for position and `mouse.Button1Up`
  to end the drag - the pattern the user supplied from the devforum -
  instead of `UserInputService.InputChanged`/`InputEnded`, which is
  suspected unreliable for mouse tracking (as opposed to keyboard input,
  which already worked fine via `UserInputService.InputBegan`) over
  Studio's docked plugin GUIs in edit mode. The hover-based drop-target
  resolution (`MouseEnter`/`MouseLeave` on tiles/strip) from the previous
  rewrite is unchanged - only the begin/end/position tracking moved.
  `RoadDesigner.Panel`/`RoadInspector` now take a `PluginObj: Plugin` prop
  threaded down from `main.lua` so the hook can call `:GetMouse()`.
- **BuildBar tool buttons are icon-first**: the Straight/Curve/Free text
  label now only appears on hover (tooltip-style), matching the request to
  reduce visual weight when nothing's focused.
- **New elevation arrow icons** (`rbxassetid://6034818379` up /
  `6034818372` down) replace the unicode ↑/↓ glyphs on the elevation
  buttons; `Components.Button` gained an optional `Icon` prop to support
  this without a one-off button variant.
- **Road Editor's Top row**: Properties and Modules/Library are now
  independently anchored (`AnchorPoint`/`Position`, no shared horizontal
  `UIListLayout`) - Properties pinned to the left edge, Modules pinned to
  the right edge, so the gap opens in the middle instead of the two cards
  hugging each other with dead space only past the Palette.

## Real fixes from Studio testing (round after the pie menu)

- **Found and fixed the actual root cause of the recurring "Properties
  card too wide" bug.** `Components.Button`'s `Grow` option still set
  `AutomaticSize.X` alongside the `UIFlexItem` - combining "size exactly to
  text" with "share available row space" meant a row of Grow buttons with
  long labels ("Save as Copy", "Use as Template", ...) reported its full
  text width as its flex basis and could still overflow a fixed-width
  column. This is why the overflow kept coming back after earlier
  formatting fixes. Fixed: `Grow` now forces `AutomaticSize.None` and adds
  `TextTruncate`.
- **Lane strip is now centered**, not left-stuck with dead space on short
  roads.
- **Drag-and-drop rewritten again**, this time using plain hover tracking
  (`MouseEnter`/`MouseLeave` on tiles and the strip) instead of hit-testing
  a screen coordinate. The previous `GuiService:GetGuiObjectsAtPosition`
  attempt was still unreliable - plausibly because that API doesn't
  reliably see `CoreGui`-parented plugin UI in Studio's edit-mode context,
  which would explain "still just bugs." Hover events are the same
  mechanism every hover-highlight in this UI already uses successfully, so
  this version has much less room for a coordinate-space mismatch to hide
  in.
- **Settings split into tabs**: Regional Preference (everything that used
  to be the whole page) and a new Keybinds tab (currently informational -
  lists R/F for elevation and Esc/right-click/middle-click for cancel;
  not rebindable yet).
- **Middle-click also cancels placement**, alongside the existing Escape
  and right-click - right-click doubles as Studio's camera-orbit gesture,
  so a quick right-click meant to nudge the camera could cancel a
  placement unintentionally. Right-click was kept (not removed) since CS2
  users expect it; say the word if it should go. (Later removed from the
  default entirely - see the keybind round above.)
- **Pie menu rename**: the existing "open the full designer" action is now
  labelled "Edit on Road Builder" - "Edit Road Segment" is reserved for the
  new, not-yet-built feature described below.

## Pie menu (click a placed road)

The reference the user provided (a screenshot from a CS2-like game) clarified
that the "pie menu" isn't an actual wedge-sliced radial widget - it's a
handful of plain pill-shaped buttons scattered around the object (top/left/
right/bottom), which is much cheaper to build well in Roblox than a true
radial menu. Shipped this round:

- **`UI/PieMenu.lua`**: 4 fixed pill-button slots around a world-space
  anchor point, camera-tracked every frame via `WorldToViewportPoint` (its
  own `ScreenGui`, deliberately *not* `IgnoreGuiInset` - that convention
  matches `WorldToViewportPoint`'s coordinate space, whereas the bottom
  HUD's `ScreenGui` ignores the inset for the drag-ghost math; the two
  needed to differ). Hides itself when the anchor is off-screen or behind
  the camera.
- Selecting a placed road now shows this menu **first**, before the full
  designer: **Edit Road Segment** (opens today's `RoadInspector` designer,
  unchanged), **Place More** (starts a new build session seeded at this
  road's exact end position/tangent with its exact profile - via
  `createRoadSession`'s new optional `seed` parameter and
  `RoadEditSession.GetContinuation()` - no proximity re-snapping needed),
  **Use as Template** (clones this road's profile into a new user profile
  and opens the Road Editor with it pre-loaded), **Cancel** (deselects).
  `RoadEditSession` gained `IsShowingMenu`/`OpenEditor` to track which of
  the two states (menu vs. full designer) is current for the selected road.

**Not done yet at the time** (later partly built, see the rounds above):
hover-based (not click-based) triggering, the Road Editor's own
entry-point pie menu ("Edit existing" / "Create new empty" / "Place more"),
numeric-key shortcuts for marking selection, retractable side panels, and
the "stretch dash" marking style / bus stop placement mentioned alongside
"Edit Road Segment". Still unscoped (see `TODO.md`):

- **Hover** (rather than click-to-select) as the trigger needs new
  always-on mouse-hover raycast logic, distinct from the
  `Selection`-based approach `RoadEditSession` uses today - clicking was
  the tractable first step; hover is a separate follow-up.
- **Road Editor's own entry pie menu** and an empty-layout "Create new"
  (today's New still uses the 4-component starter template, not zero
  components) haven't been touched.
- **Retractable side panels** are UI polish on top of the current
  designer, not started.
- **"Stretch dash" marking style** isn't a `LineType` `Mesh/Markings.lua`
  understands yet.

## Foundational build (road designer, HUD, branding, inspector)

- **Bug-fix round: overflow, elevation, library placement, drag-and-drop.**
  - Fixed horizontal overflow in the Road Properties column: the dash
    length/gap row was packed too tightly for the fixed-width card and
    forced a horizontal scrollbar; split into two narrower rows
    (`ProfileFields.lua`). Road Tool panel's tool buttons now share row
    width evenly (`UIFlexItem`) instead of relying on auto-sized text width,
    removing the same risk there.
  - Elevation now has explicit up/down arrow buttons in the Road Tool
    panel (alongside R/F, which still works) - `createRoadSession.lua`
    exposes `AdjustElevation(delta)`, shared by both the keybinds and the
    new buttons.
  - The road picker moved out of the Road Properties card into its own
    "Created Roads" tab sharing the right-hand card with Modules
    (`RoadDesigner.PaletteOrLibraryCard`), matching CS2's AVAILABLE LANES /
    CREATED ROADS tab bar instead of living inside Properties.
  - Rewrote drag-and-drop to use `GuiService:GetGuiObjectsAtPosition` at
    drop time (walking ancestry for a named lane tile/strip) instead of
    comparing raw input coordinates against a cached `AbsolutePosition` +
    assumed tile width - the previous version had a real GuiInset/coordinate
    mismatch (ScreenGuis now also set `IgnoreGuiInset = true` so the drag
    ghost tracks the cursor precisely) and no longer depends on tile-size
    assumptions matching what's actually rendered.
  - Note: the logo image mentioned below was tried and reverted per
    follow-up feedback - the top bar is text-only again, styled in
    `BuilderSansMedium` and the brand orange.
- **Branding pass: brand orange + Builder Sans + logo.** Every button/
  checkbox/selected-state colour that used to be blue is now the easyRoad
  brand orange (#D98455, `Theme.ACCENT`/`SELECTED`/`ACCENT_HOVER`); UI text
  uses `Enum.Font.BuilderSans`/`BuilderSansBold` instead of SourceSans; the
  top bar shows the easyRoad logo (`rbxassetid://73102883268322`) next to
  the title.
- **Icon updates.** Bike (`117323310944439`) and Parking
  (`135215443300853`) module icons updated; new tool-mode icons for
  Straight/Curve/Freeform in the Road Tool panel (`80355330590276`/
  `90102359516465`/`112290052468250`). "Bus Bay" is removed from the
  Modules palette - see `TODO.md`'s Bus Lane entry, it moved to the
  per-instance road panel as "Bus Lane" with a new icon.
- **Discoverable lane marking control.** The per-lane boundary control (in
  the lane strip's selected-tile row) is now a labeled dropdown - "Solid -
  no lane change", "Solid | Dash - right may merge left", etc. - instead of
  an unlabeled glyph-cycling button, so the existing per-lane marking-type
  feature (already fully implemented in `Mesh/Markings.lua`) is actually
  discoverable. Global dash length/gap remain in Road Properties.
- **Road Editor layout overhaul.** `RoadDesigner.Panel` now matches the
  CS2 / easyRoad 2 reference layout: Road Properties (left) and Modules
  (right) are two full-height columns, with the lane strip ("Road Layout")
  pinned along the very bottom spanning the full width underneath both -
  instead of three cards crammed into one row that forced the properties
  column to scroll. The road picker in both the Road Editor and the Road
  Tool panel is now a scrollable library list (name, click to select, "+
  New Road") instead of a dropdown.
- **Drag-and-drop module insertion.** Palette tiles in the Road Editor can
  now be dragged onto the lane strip to insert at the drop position (press
  and drag past a small threshold; a plain click still inserts after the
  selected lane, unchanged). Implemented as a small shared controller in
  `RoadDesigner.lua` using `useState`/`useRef`/`useEffect` + a global
  `UserInputService` listener while dragging is active.
- **Settings panel indent.** The docked settings sidebar no longer draws
  its own glass card/corner (it's already inside a bordered Studio dock
  widget); content is now inset ~5px further from the panel edges.
- **Top mode bar + separated surfaces (CS2 architecture).** A glass top
  bar (`UI/TopBar.lua`) toggled by the toolbar button switches between the
  plugin's three functions so nothing is crammed into one surface:
  - *Road Tools* — placement session with a compact CS2-style tool panel
    bottom-left (`UI/BuildBar.lua`: tool mode, road picker, widen-to,
    banking, elevation, hints, stop) — like the CS2 road tool box.
  - *Road Editor* — the full designer bottom bar (properties | lane strip
    | modules palette) for creating/editing road types, now with a road
    picker + New button directly in the properties card
    (`RoadDesigner.Panel` `Picker` prop). Tools/Editor are exclusive modes.
  - *Settings* — the grand settings (region profile, scale, banking,
    snapping, geometry) live in the docked Studio sidebar panel.
  `UI/EasyRoadGui.lua` and `UI/LaneEditor.lua` (the old page-routed dock
  UI) are deleted. Selecting a placed road still opens the designer bound
  to that road, independent of the top bar.
- **CS2-style build bar; old right-side panel removed.** The floating
  right-anchored panel is gone. While placing roads, the bottom bar now
  shows [Road Tool card | live lane strip | Modules palette]: tool modes,
  road picker, transition target, banking + design speed, elevation and
  hints on the left; the ACTIVE road's cross-section as editable tiles in
  the middle (session-only tweaks, kept via "Save as New Road..."); module
  insertion on the right. `UI/RoadDesigner.lua` was split into reusable
  `LaneStripCard` / `PaletteCard` / `Panel` so build, library editing, and
  placed-road editing all share one strip implementation
  (`UI/BuildBar.lua` composes the build variant). Layout fixes for small
  logical viewports (high-DPI screens): the bottom bar spans the full
  width, fixed card widths shrunk (240 / flex / 140), section headers
  truncate instead of bleeding across cards. Glyph fixes: dropdown chevron
  and boundary/move/remove button labels now use ASCII-safe characters
  (Studio's SourceSans renders ▾ and box-drawing glyphs as tofu boxes).
  The dock panel still carries the legacy page UI as a secondary surface
  (also the nav to Settings / road picker).
- **CS2-style road designer (`UI/RoadDesigner.lua`).** The road
  configuration UI is now a wide bottom-of-viewport HUD with three glass
  cards, modelled on the CS2 road builder / easyRoad 2 reference: a lane
  strip (one tile per component — module icon, direction arrow ↑/↓, width;
  click to select, then edit width/direction/boundary or reorder/remove), a
  Modules palette (Lane / Pavement / Median / Shoulder / Bike / Parking /
  Bus Bay tiles using the reference icon set; click to insert after the
  selection), and a Road Properties card (name, kerb lines, kerb offset,
  line colour, dash spacing, action buttons). The same designer serves
  both the library editor (Edit Roads → pick a road → designer opens with
  Save/Delete/Close) and the placed-road inspector (select a placed road →
  designer opens with Apply/Revert/Close). The old vertical list editor
  and left-side inspector panel are gone; `UI/LaneEditor.lua` is now just
  the picker page, `UI/RoadInspector.lua` the session-binding wrapper, and
  `UI/ProfileFields.lua` the shared kerb/colour/dash rows.
- **Select a placed road → contextual edit panel.** Click any already-placed
  road in the viewport with Studio's ordinary selection tool (no need to
  activate easyRoad) and a left-anchored inspector HUD appears, editing that
  road's cross-section (kind/width/direction/boundary per component, with
  add/remove/reorder), kerb restriction, kerb line offset, marking colour,
  and dash spacing in place — "Apply to Road" rebuilds just that model as a
  single undo step. Placed roads now carry their full curve control points
  and serialized start/end profiles as attributes (`RW_CurveKind`/`RW_P0..P3`/
  `RW_ProfileStartJson`/`RW_ProfileEndJson` — see `RoadInstance.lua`), so a
  road with session-only tweaks (a widened lane, a swapped-in Bay) can be
  reopened and edited without needing the library profile it started from.
  Roads that transition between two profiles show a note and only expose the
  kerb/colour/dash rows (component-by-component editing across a transition
  is still Road Editor-only). Roads placed before this change lack the new
  attributes and show a "can't be edited in place" note in the inspector.
  New modules: `RoadInstance.lua`, `RoadEditSession.lua`,
  `UI/RoadInspector.lua`; `UI/ProfileFields.lua` factors the shared
  component/kerb/colour/dash rows out of `UI/LaneEditor.lua` so the road
  editor and the new inspector can't drift apart.
- Marking rule engine: full line vocabulary (solid/dashed/double/asymmetric
  merge), per-lane boundary rules, kerb restrictions (single/double
  yellow), region-forced marking colour, per-road dash spacing override.
- Kerb restriction lines now replace (not duplicate) the plain edge line at
  any roadway edge that meets a kerb — previously only worked for `Drive`
  lanes, so `Parking`/`Shoulder`/`Bay` never got a kerb line at all.
- **Bay** component kind (bus / taxi pull-in bay) — full kind support:
  region-configurable colour (`RegionStyle.BayColor`), material, icon
  fallback, generic editor support (it's just another entry in the kind
  dropdown, same as Parking/Shoulder).
- **Kerb line offset** choice per road: "Inset (default)" vs "Flush at
  edge" — exposed in the road editor next to Kerb lines / Line colour /
  Dash spacing.
- Live width tweaking in the build HUD ("Adjust Widths") with a
  session-only override and "Save as New Road..." to persist it.
- Viewport glass HUD, easyRoad branding (toolbar/icon/tooltip).
