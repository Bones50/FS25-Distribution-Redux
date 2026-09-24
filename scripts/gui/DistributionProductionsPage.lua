-- ============================================================================
-- DistributionProductionsPage.lua  (Distribution Redux) -- Productions tab
-- Master-detail, split into a left building list + a right pane with THREE
-- stacked sections:
--   left  list (assetList)  : production buildings you can configure
--   right 1 (inputList)     : INCOMING MATERIALS -- INPUT | RECEIVED /mo | STORAGE  (display only)
--   right 2 (lineList)      : PRODUCTION LINES   -- LINE (outputs (inputs)) | STATUS | PROD /mo
--                             (selectable; Toggle Line turns the selected line on/off; PROD /mo
--                              is shown only while the line is ON)
--   right 3 (outputList)    : OUTGOING PRODUCTS  -- OUTPUT | DISTR/mo | STORED/mo | SOLD/mo |
--                             STORAGE | METHOD   (selectable; Cycle Output / Sell Timing act on it)
-- Footer (real keys via setMenuButtonInfo): Toggle Line (acts on the LINE list),
-- Cycle Output + Sell Timing (act on the OUTPUT list). All figures are MONTHLY
-- (scoped by the page's Hour / Month / Year selector). Engine seams: productionLines, assetWindowStats,
-- cycleProductionOutput, setProductionLineEnabled, applyAssetSellTiming.
-- ============================================================================

DistributionProductionsPage = {}
local DistributionProductionsPage_mt = Class(DistributionProductionsPage, DistributionMenuPage)

---A member of the DISTRIBUTION GROUP: one left icon, these four as top tabs.
-- Animal Husbandry and Markets are subclasses of this one and inherit it, which is why
-- there are four tabs and only two declarations.
DistributionProductionsPage.GROUP_MEMBER = true

-- A row counts as "holding something" only when the HELD cell would actually SAY so.
-- SmartDistribution.formatVolume renders litres as math.floor(v + 0.5), so anything below 0.5 L
-- prints "0 L" -- while the row-inclusion tests further down used a bare `> 0`. A few hundredths of a
-- litre of residue in pp.storage therefore kept a switched-off line's product on screen showing 0 L.
-- Flicking a line on and straight back off is the reliable way to leave that residue, which is exactly
-- how it was reported; setting the output to Sell Immediate "fixed" it only because the next cycle
-- drained the buffer to a true zero.
-- Tied to the FORMATTER's own rounding rather than being a taste-chosen epsilon: the rule is "no row
-- the display would render as 0 L", so if the volume convention changes this has to move with it or
-- the two will silently disagree again.
local HELD_VISIBLE_MIN = 0.5

-- Suppress the built-in row highlight on whichever of the input / output lists is NOT active, so only one
-- list shows a selection at a time. Row elements carry a `hideSelection` flag; set it on the inactive
-- list's rows. See the twin helper in DistributionStoragePage.lua.
local function applyRowHighlight(cell, active)
    if cell == nil then return end
    cell.hideSelection = not active
    if not active and cell.setSelected ~= nil then pcall(function() cell:setSelected(false) end) end
end

-- THE one number formatter on this page: thousands separated by a SPACE (not a comma, which reads as
-- a decimal point in most of the languages this mod ships in), with `decimals` decimal places. Only the
-- integer part is grouped. decimals = 0 rounds to a whole number.
local function fmtNum(n, decimals)
    local s
    if (decimals or 0) > 0 then
        s = string.format("%." .. decimals .. "f", n or 0)
    else
        s = tostring(math.floor((n or 0) + 0.5))
    end
    local int, dec = s:match("^(-?%d+)(.*)$")
    if int == nil then return s end
    local k
    repeat int, k = int:gsub("^(-?%d+)(%d%d%d)", "%1 %2") until k == 0
    return int .. dec
end

-- integer liters with thousands separators
local function fmt(n)
    return fmtNum(n, 0)
end

-- EVERY litre figure on this page goes through here; it delegates to SmartDistribution.formatVolume so
-- the whole mod switches to kilolitres in one place (up to 999 L in litres, above that kL with the
-- extraneous zeros dropped). It carries the UNIT itself -- do not append " L" to it.
local function fmtV(n)
    if SmartDistribution ~= nil and SmartDistribution.formatVolume ~= nil then
        local ok, s = pcall(SmartDistribution.formatVolume, n or 0)
        if ok and type(s) == "string" then return s end
    end
    return fmt(n) .. " L"
end

-- ---- BLOCKED-PRODUCT NOTICE (twin of the DistributionStoragePage helpers; keep the two in step) -------
local NOTICE_CELLS = { "name", "amount", "received", "consumed", "produced", "distr",
                       "method", "statusText", "status", "prodMo",
                       "barHeld", "barCap" }

local function renderNoticeRow(cell, hidden, what)
    local icon = cell:getAttribute("fillIcon")
    if icon ~= nil and icon.setVisible ~= nil then icon:setVisible(false) end
    -- ...and the BAR. Cells are RECYCLED, so without this the notice row keeps whatever bar the product
    -- row that last used this slot drew. Its two LABELS need no special case -- they are in NOTICE_CELLS
    -- with every other text cell.
    -- the track AND the pallet chip, which is a sibling of barBg and so is not hidden with it
    if SmartDistribution.hideStorageBar ~= nil then
        SmartDistribution.hideStorageBar(cell)
    else
        local bar = cell:getAttribute("barBg")
        if bar ~= nil and bar.setVisible ~= nil then bar:setVisible(false) end
    end
    -- SmoothList RECYCLES cells: clear every column or this row inherits the last product row in the slot
    for _, k in ipairs(NOTICE_CELLS) do
        local c = cell:getAttribute(k)
        if c ~= nil then
            if c.setText ~= nil then c:setText("") end
            if c.setTextColor ~= nil then c:setTextColor(1, 1, 1, 1) end
        end
    end
    local n = cell:getAttribute("noticeText")
    if n == nil then return end
    if n.setVisible ~= nil then n:setVisible(true) end
    if n.setText ~= nil then
        -- see the twin in DistributionStoragePage: whole-sentence singular/plural keys
        local key = (hidden == 1) and "dr_notice_blockedInput" or "dr_notice_blockedInputs"
        local fb  = (hidden == 1) and "+%d input blocked (See Advanced Inputs)"
                                   or "+%d inputs blocked (See Advanced Inputs)"
        n:setText(string.format(SmartDistribution.l10n(key, fb), hidden))
    end
    local COL = (SmartDistribution ~= nil and SmartDistribution.LINK_COLOR) or {}
    local col = COL.IDLE or { 0.95, 0.65, 0.20, 1 }
    if n.setTextColor ~= nil then n:setTextColor(col[1], col[2], col[3], col[4] or 1) end
end

local function hideNoticeRow(cell)
    local n = cell:getAttribute("noticeText")
    if n ~= nil and n.setVisible ~= nil then n:setVisible(false) end
end

-- ---- in-row mode arrows ------------------------------------------------------------------------
-- Own copies of the StoragePage helpers, which is the established pattern for this file (CLAUDE.md 4):
-- the two pages already duplicate setStatusCell / inputMaxLiters / percentText. Change both together.
-- See DistributionStoragePage for the full reasoning -- in short, the onClick callback is SHARED by
-- every cloned row, so the product has to be stashed on the element populate is holding, and the
-- arrows must be hidden ACTIVELY on the notice row because SmoothList recycles cells.
local MODE_ARROWS = { "modePrev", "modeNext" }

local function setModeArrows(cell, ft)
    for i = 1, #MODE_ARROWS do
        local b = cell:getAttribute(MODE_ARROWS[i])
        if b ~= nil then
            b.sdFillType = ft
            if b.setVisible ~= nil then b:setVisible(ft ~= nil) end
        end
    end
end

local function clickedArrow(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "table" and v.sdFillType ~= nil then return v end
    end
    return nil
end

-- Drop blocked-and-empty products from an already-built row list and append the count as a final row.
-- Takes the RECORDS (not bare fill types) because this page carries held / capacity / flow on each.
local function filterBlockedRows(asset, rows, role)
    if asset == nil or SmartDistribution == nil or SmartDistribution.visibleProducts == nil then return rows end
    local fts = {}
    for _, r in ipairs(rows) do fts[#fts + 1] = r.ft end
    local keep, hidden = SmartDistribution.visibleProducts(asset, fts, role)
    if hidden <= 0 then return rows end
    local ok = {}
    for _, ft in ipairs(keep) do ok[ft] = true end
    local out = {}
    for _, r in ipairs(rows) do if ok[r.ft] then out[#out + 1] = r end end
    out[#out + 1] = { notice = hidden }
    return out
end

-- Does this building hold ANY of ft, by the mod's ONE canonical test? Used as the final escape on the
-- row-inclusion tests below, so a product with stock is never hidden merely because its line is off.
-- Deliberately the shared SmartDistribution.productHeldAny rather than a local reading of pp.storage:
-- this page and the blocked-hiding filter were asking the same question two different ways and getting
-- two different answers, which is what let a greenhouse's switched-off product disappear while its own
-- HELD column plainly showed both buffer and pallets.
local function heldAny(p, ft)
    if p == nil or ft == nil or SmartDistribution == nil or SmartDistribution.productHeldAny == nil then return 0 end
    local ok, v = pcall(SmartDistribution.productHeldAny, p, ft)
    if ok and type(v) == "number" then return v end
    return 0
end

-- "<liters>  (<money>)" for the SOLD /mo column; money omitted when zero/unknown
local function soldWithMoney(liters, money)
    local base = fmtV(liters)
    if money ~= nil and money > 0.5 and SmartDistribution ~= nil and SmartDistribution.formatMoneyShort ~= nil then
        return base .. "  (" .. SmartDistribution.formatMoneyShort(money) .. ")"
    end
    return base
end

-- "450 L (5,000 L)" (or just "450 L" when capacity is unknown). Bracket, not "/", so every held figure in
-- the mod reads the same way: the amount, then what it can hold beside it, then any pallets.
local function amountText(held, cap)
    if cap ~= nil and cap > 0 then return fmtV(held) .. " (" .. fmtV(cap) .. ")" end
    return fmtV(held)
end

-- " + 5,000 L (5p)" for whole pallets standing on this production's own pad, matching the Animal Husbandry
-- and Overview tabs. productionLines() reports held from pp.storage ALONE, so without this a bakery holding
-- five bread pallets read as its buffer only and understated by the entire pad. It is appended AFTER the
-- capacity bracket rather than folded into the leading figure, because the capacity here is the BUFFER's --
-- the pad has no capacity in that sense, so "450 L (5,000 L) + 5,000 L (5p)" keeps the bracket meaning what
-- it says. Counted as OBJECTS, never litres/1000: a part-filled pallet is one pallet on the pad, not zero.
-- Empty for bulk outputs, so rows that never palletize are unchanged.
local function palletPart(litres, count)
    if (litres or 0) <= 0 then return "" end
    return " + " .. fmtV(litres) .. " (" .. tostring(count or 0) .. "p)"
end

local function percentText(held, cap)
    if cap ~= nil and cap > 0 then return string.format("%d%%", math.floor((held / cap) * 100 + 0.5)) end
    return ""
end

-- How much of this input the production will actually take: its buffer AFTER the Advanced Inputs
-- percentage is applied, so the figure here matches what that dialog reserves. Blocked -> 0. Returns nil
-- when it can't be resolved, letting the caller fall back to the raw capacity the row already carries.
-- (Twin of the helper in DistributionStoragePage.lua.)
local function inputMaxLiters(placeable, ft)
    if placeable == nil or ft == nil or SmartDistribution == nil then return nil end
    local uid = (SmartDistribution.assetUid ~= nil) and SmartDistribution.assetUid(placeable) or nil
    if uid ~= nil and SmartDistribution.isInputBlocked ~= nil and SmartDistribution.isInputBlocked(uid, ft) then
        return 0
    end
    if SmartDistribution.inputProductCapacity == nil then return nil end
    local ok, cap = pcall(SmartDistribution.inputProductCapacity, placeable, ft)
    if not ok or type(cap) ~= "number" or cap <= 0 or cap >= math.huge then return nil end
    -- pooled storage resolves elastically against what it really holds (twin of the StoragePage helper)
    -- MAX is the CAP: this product's percentage of the buffer, matching the Advanced Inputs dialog's MAX IN.
    -- It used to return inputEffectiveMaxLiters, the elastic "what could still fit given what the others
    -- hold", which bore no relation to the percentage the player set. (Twin of the StoragePage helper.)
    local pct = 100
    if SmartDistribution.inputCapLiters ~= nil then
        local okP, v = pcall(SmartDistribution.inputCapLiters, placeable, ft)
        if okP and type(v) == "number" then pct = v end
    end
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return cap * pct / 100, pct
end

-- ---- FREE STORAGE (twins of the DistributionStoragePage helpers; keep the two in step) --------------
-- inputs  -> inputAcceptableLiters, the figure the allocator clamps deliveries to and the Advanced Inputs
--            dialog shows as AVAILABLE
-- outputs -> a straight capacity - held
-- red when nothing is left (or overfilled), orange at 10% or less, green otherwise.
local function inputRemaining(placeable, ft)
    if placeable == nil or ft == nil or SmartDistribution == nil then return nil end
    if SmartDistribution.inputAcceptableLiters == nil then return nil end
    local ok, v = pcall(SmartDistribution.inputAcceptableLiters, placeable, ft)
    if not ok or type(v) ~= "number" or v ~= v or v < 0 or v >= math.huge then return nil end
    return v
end


-- Distribution status of an input row (Active (Receiving) / Active (Idle) / Blocked). The label set is
-- shared in SmartDistribution so every building category reads identically.
local function inputStatusLabel(placeable, ft, window, role)
    if placeable == nil or ft == nil or SmartDistribution == nil then return "" end
    if SmartDistribution.inputLinkStatus == nil or SmartDistribution.assetUid == nil then return "" end
    -- the ROLE's key, so a pallet-store row answers for itself and not for the building
    local uid = SmartDistribution.settingUid ~= nil and SmartDistribution.settingUid(placeable, ft, role)
                or SmartDistribution.assetUid(placeable)
    if uid == nil then return "" end
    local st = SmartDistribution.inputLinkStatus(uid, ft, window)
    return (SmartDistribution.LINK_LABEL or {})[st] or ""
end

-- write the status into a row cell AND colour it: green feeding, orange idle, red blocked
local function setStatusCell(cell, placeable, ft, window, role)
    local c = cell:getAttribute("statusText")
    if c == nil then return end
    if placeable == nil or ft == nil or SmartDistribution == nil or SmartDistribution.inputLinkStatus == nil
       or SmartDistribution.assetUid == nil then
        if c.setText ~= nil then c:setText("") end
        return
    end
    local uid = SmartDistribution.assetUid(placeable)
    -- A product BLOCKED on the Advanced Inputs page is refused at the door, whatever the source-side link
    -- says, so it must read "Blocked" here too -- otherwise the main list still shows it as receiving.
    if uid ~= nil and SmartDistribution.isInputBlocked ~= nil and SmartDistribution.isInputBlocked(uid, ft) then
        if c.setText ~= nil then c:setText(SmartDistribution.l10n("dr_label_blocked", "Blocked")) end
        local bc = (SmartDistribution.LINK_COLOR or {}).BLOCKED
        if bc ~= nil and c.setTextColor ~= nil then c:setTextColor(bc[1], bc[2], bc[3], bc[4]) end
        return
    end
    local st   = uid ~= nil and SmartDistribution.inputLinkStatus(uid, ft, window) or nil
    local base = (st ~= nil) and ((SmartDistribution.LINK_LABEL or {})[st] or "") or ""
    -- "N of M buildings are feeding me this" -- appended exactly the way the OUTPUT side already appends
    -- its destination count (setOutputStatusCell / outputDestCountText), so both directions read alike.
    -- Suppressed on a blocked row and where nothing on the farm could supply it; see the engine function.
    -- This is the twin of DistributionStoragePage's setStatusCell (CLAUDE.md 4): change both together.
    local suffix, feeding = "", nil
    if base ~= "" and uid ~= nil and SmartDistribution.inputSourceCountText ~= nil then
        suffix, feeding = SmartDistribution.inputSourceCountText(uid, ft, st)
        suffix = suffix or ""
    end
    if c.setText ~= nil then c:setText(base .. suffix) end
    -- RED WHEN NOTHING IS FEEDING while something could -- the silent-stall signal 5.37 added DEST for.
    -- It OUTRANKS the status word's own colour, ACTIVE included: on a Month window a row can read
    -- "Active (Receiving) (0/3)" because something arrived this month and nothing this pass, and the
    -- count is the half worth acting on. feeding is nil whenever no count is shown, so this cannot fire
    -- on a row that has no ratio to report.
    local col = st ~= nil and (SmartDistribution.LINK_COLOR or {})[st] or nil
    -- RED ONLY ON A ROW THAT IS NOT ALREADY ACTIVE. Red means "something could feed me and nothing is",
    -- which is a claim DR itself contradicts when the status word beside it reads Active (Receiving) --
    -- and the two are answered on DIFFERENT TIME BASES, so they legitimately disagree: the word can come
    -- from the selected WINDOW's ledger while the count is the last completed pass only (the only
    -- per-source data that exists). Reported 2026-08-27 as "Active (Receiving)" painted red at 0/2.
    -- An idle row with sources standing by still goes red, which is the stall this was added to surface.
    if feeding == 0 and st ~= "ACTIVE" then col = (SmartDistribution.LINK_COLOR or {}).BLOCKED end
    -- Cells are RECYCLED by SmoothList, so the colour is written on EVERY path rather than left to
    -- inherit the previous row's (the 5.7 / 5.57 trap) -- which matters more now one of them is red.
    if c.setTextColor ~= nil then
        if col ~= nil then c:setTextColor(col[1], col[2], col[3], col[4])
        else c:setTextColor(1, 1, 1, 1) end
    end
end

-- OUTGOING (source-side) status for an output row: Active (Sending) / Active (Idle) / Blocked, same colours.
local function setOutputStatusCell(cell, placeable, ft, window, role)
    local c = cell:getAttribute("statusText")
    if c == nil then return end
    local st = (placeable ~= nil and ft ~= nil and SmartDistribution ~= nil and SmartDistribution.outputLinkStatus ~= nil)
        and SmartDistribution.outputLinkStatus(placeable, ft, window, role) or nil
    if c.setText ~= nil then
        local base = (st ~= nil) and ((SmartDistribution.OUT_LINK_LABEL or {})[st] or "") or ""
        local suffix = (base ~= "" and SmartDistribution.outputDestCountText ~= nil)
            and (SmartDistribution.outputDestCountText(placeable, ft, role, st) or "") or ""
        c:setText(base .. suffix)
    end
    local col = st ~= nil and (SmartDistribution.LINK_COLOR or {})[st] or nil
    if col ~= nil and c.setTextColor ~= nil then c:setTextColor(col[1], col[2], col[3], col[4])
    elseif c.setTextColor ~= nil then c:setTextColor(1, 1, 1, 1) end
end

-- fill-type icon (base game hud overlay) -- same approach as the Silos/Husbandry page
local function fillIconFile(ft)
    if g_fillTypeManager == nil or g_fillTypeManager.getFillTypeByIndex == nil then return nil end
    local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
    if ok and def ~= nil then return def.hudOverlayFilename or def.hudOverlayFilenameSmall end
    return nil
end

local function fillTypeTitle(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
        if ok and def ~= nil and def.title ~= nil then return def.title end
    end
    return tostring(ft)
end

-- ----- ICON TOOLTIPS -----------------------------------------------------------------------------
-- The implementation is SmartDistribution's since step 3 of the routing graph, so two pages cannot
-- drift apart (6.18). These are thin aliases: the ~20 call sites below are untouched.
local function setIconTooltip(el, label) return SmartDistribution.setIconTooltip(el, label) end
local function updateHoverTooltip(dt)    return SmartDistribution.updateHoverTooltip(dt) end
-- ========================== end ICON TOOLTIPS ======================================

-- The "+N blocked" notice row has no product name, so alphabetical sorting would float it to the top.
-- It is a footer, not a product: move it back to the end. Tolerates several (there is only ever one).
local function keepNoticeLast(rows)
    if rows == nil then return rows end
    local kept, notices = {}, {}
    for i = 1, #rows do
        if rows[i] ~= nil and rows[i].notice ~= nil then notices[#notices + 1] = rows[i]
        else kept[#kept + 1] = rows[i] end
    end
    if #notices == 0 then return rows end
    for i = 1, #notices do kept[#kept + 1] = notices[i] end
    for i = 1, #kept do rows[i] = kept[i] end
    return rows
end

-- ============================ PRODUCTION LINE ICON STRIP ============================
-- A production line row reads as products, not prose:
--     <amount>x [input icon] ... -->  <amount>x [output icon] ...
-- The amounts come straight from the line RECIPE (prod.inputs/outputs -> amount), so modded
-- productions, modded fill types and modded lines all work with no special case. A missing or
-- non-numeric amount hides the number and keeps the icon; a fill type with no icon file is skipped
-- whole (number included) and the strip closes up behind it.
--
-- The "-->" sits on a FIXED axis so every row on the page lines up under the one above it: inputs are
-- stacked leftwards from the axis, outputs rightwards from it. The input window is exactly
-- LINE_IN_WINDOW_SLOTS columns wide -- a line with more inputs scrolls inside that window instead of
-- shrinking (see the scroll section below), so an icon never changes size between rows.
-- 15, WHICH IS THE REAL CEILING RATHER THAN A ROUND NUMBER: measured across every production
-- line in the base game and all installed mods (2,470 of them), the longest recipe is the Fed
-- Produktions Pack's pizza at 15 inputs, with ice cream and ready meal at 13. At 12 those three
-- lost ingredients SILENTLY -- usableIconSlots simply stops at the limit, so the row showed
-- twelve icons and said nothing about the rest.
-- Unused slots cost nothing: they are hidden, and the strip's window is 6 columns whatever the
-- cap is, so the scroll behaviour is unchanged.
local MAX_LINE_INPUT_ICONS = 15
local MAX_LINE_OUTPUT_ICONS = 8
-- TEN, up from five, because the AXIS MOVED RIGHT (2026-09-21) and the room had to go somewhere.
-- The earlier note here weighed five slots against six and concluded that moving the axis was the
-- expensive option because it meant re-cutting STATUS and TARGET/MO. It does NOT: the right end of
-- the output block is unchanged (528 + 148 == 296 + 380), so only the SPLIT moved and those two
-- columns never had to be touched. What the old split actually cost was ~250px of every row held
-- open for outputs a single icon could never use, and 95% of lines have exactly one output.
-- The window is bounded by the throughput glyph at the row's left edge (6..54): ten columns put
-- winL at 528 - 16 - 440 = 72, clear of it, and eleven would land on 28 and collide.
-- Measured across every production line in the base game and all installed mods, overflow (and so
-- scrolling) was 10.3% at five slots and 7.1% at six; at ten it is a small fraction of that.
local LINE_IN_WINDOW_SLOTS = 10    -- inputs visible at once; a longer list scrolls inside the window
local LINE_SCROLL_SPEED_PX = 30    -- strip travel speed (reference px per second)
local LINE_SCROLL_PAUSE = 1.2      -- hold at both ends of the ping-pong travel (seconds)
local LINE_ICON_W_PX = 24          -- product icon width (matches the XML slots)
local LINE_COL_PITCH_PX = 44       -- FIXED per-item column width: icon + room for the amount + gap
local LINE_ARROW_PAD_PX = 16       -- clearance kept on both sides of the "-->"
local LINE_UNIT_BASE_PX = 86       -- inIcon1 -> inIcon2 spacing in the XML (derives the pixel unit)
local LINE_AXIS_PX = 528           -- the "-->" axis (matches XML inArrow and the column header)
-- OUTPUTS GET THREE COLUMNS AND NO MORE (author, 2026-09-21): 3 x LINE_COL_PITCH_PX = 132, plus the
-- arrow pad. Beyond three the block SHRINKS rather than overflowing, and the floor is reachable now
-- where 5.92a recorded it as dead: at seven outputs (the largest recipe measured anywhere) the scale
-- clamps to LINE_MIN_SCALE and the block ends at ~710, still clear of STATUS at 726.
local LINE_OUT_AVAIL_PX = 148      -- room for the output block right of the arrow (3 columns + pad)
local LINE_MIN_SCALE = 0.5         -- outputs never shrink below this
local NUM_FIT = 0.96               -- share of its column an amount may occupy before it shrinks

-- The strip MOVES its icons, so an icon's current x is no longer the grid position the XML gave it.
-- Remember the XML x on first use and always measure from that -- otherwise the pixel unit below
-- shrinks a little on every populate and the whole strip eventually walks off the row.
local function slotBaseX(el)
    if el == nil or el.position == nil then return nil end
    if el.drBaseX == nil then el.drBaseX = el.position[1] end
    return el.drBaseX
end

-- Layout reference pixels -> normalized GUI space, derived from two static XML slots
-- (inIcon1/inIcon2, LINE_UNIT_BASE_PX apart), so it holds for 16:9, 16:10, ultrawide and low
-- resolutions with no hardcoded screen constant. Also returns the x of the ROW origin (px 0), which
-- every other position on the row -- the arrow axis included -- is measured from.
local function linePixelUnit(cell)
    local ax = slotBaseX(cell:getAttribute("inIcon1"))
    local bx = slotBaseX(cell:getAttribute("inIcon2"))
    if ax == nil or bx == nil then return nil end
    local d = bx - ax
    if d <= 0 then return nil end
    local unit = d / LINE_UNIT_BASE_PX
    return unit, ax - 44 * unit   -- inIcon1 sits 44px from the row's left edge in the XML
end

-- Amount per cycle -> the text drawn under the icon ("10x"). Whole numbers carry no decimals, values
-- below 1 (and untidy values below 10) carry one.
local function lineAmountText(v)
    if type(v) ~= "number" or v ~= v or v <= 0 then return nil end
    local decimals = 0
    if v < 1 then decimals = 1
    elseif v < 10 and math.abs(v - math.floor(v + 0.5)) > 0.05 then decimals = 1 end
    return fmtNum(v, decimals) .. "×"
end

-- The REAL rendered width of a string: the engine's getTextWidth(size, text) answers in normalized
-- space for an already normalized font size. Should a game version not expose it, fall back to a
-- character-count estimate -- never to an error.
local textWidthCache = {}
local function measureTextWidth(text, size)
    if text == nil or text == "" or type(size) ~= "number" or size <= 0 then return 0 end
    local key = tostring(size) .. "|" .. text
    local cached = textWidthCache[key]
    if cached ~= nil then return cached end
    local w
    if getTextWidth ~= nil then
        local ok, res = pcall(getTextWidth, size, text)
        if ok and type(res) == "number" and res > 0 then w = res end
    end
    if w == nil then
        -- fallback: UTF-8 aware character count * an average glyph width
        local n = 0
        for _ in string.gmatch(text, "[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
        w = n * size * 0.55
    end
    if #textWidthCache > 4000 then textWidthCache = {} end
    textWidthCache[key] = w
    return w
end

-- DISPLAY ORDER of the strip (left to right): alphabetical in the player's own language, keyed through
-- DistributionSort.key so diacritics collate correctly (cs/pl/sv/de/...), with a lowercase name as the
-- fallback key. The amount travels WITH its icon: the pairs (ft + amount) are sorted together, so no
-- number can end up beside the wrong icon. Recipe data is untouched -- this sorts a throwaway copy.
local function sortedLineIcons(fts, amounts, names)
    local pairsList = {}
    for i = 1, #(fts or {}) do
        local ft = fts[i]
        -- 1) the name straight from the recipe (already localized, same text as the lists on the left),
        -- 2) else the fill type title, 3) else at least its index -- never nil.
        local nm = names ~= nil and names[i] or nil
        if type(nm) ~= "string" or nm == "" then nm = fillTypeTitle(ft) end
        if type(nm) ~= "string" then nm = tostring(nm) end
        local key = nm:lower()
        if DistributionSort ~= nil and DistributionSort.key ~= nil then
            local ok, k = pcall(DistributionSort.key, nm)
            if ok and type(k) == "string" then key = k end
        end
        pairsList[#pairsList + 1] = {
            ft = ft, amount = amounts ~= nil and amounts[i] or nil,
            name = nm, key = key, low = nm:lower(), i = i,
        }
    end

    table.sort(pairsList, function(a, b)
        if a.key ~= b.key then return a.key < b.key end
        if a.low ~= b.low then return a.low < b.low end
        return a.i < b.i
    end)
    local outFtsSorted, outAmtsSorted, outNamesSorted = {}, {}, {}
    for i = 1, #pairsList do
        outFtsSorted[i] = pairsList[i].ft
        outAmtsSorted[i] = pairsList[i].amount
        outNamesSorted[i] = pairsList[i].name
    end
    return outFtsSorted, outAmtsSorted, outNamesSorted
end

-- Drawable strip items: an icon (required), the optional amount text and the localized product name
-- carried along for the hover tooltip -- all three from the same index.
local function usableIconSlots(fts, amounts, names, limit)
    local slots = {}
    for i = 1, #(fts or {}) do
        if #slots >= limit then break end
        local file = fillIconFile(fts[i])
        if file ~= nil and file ~= "" then
            slots[#slots + 1] = {
                file = file,
                num = lineAmountText(amounts ~= nil and amounts[i] or nil),
                label = names ~= nil and names[i] or nil,
            }
        end
    end
    return slots
end

local function setSlotScale(el, s)
    if el == nil then return end
    if el.setSize ~= nil and el.size ~= nil then
        if el.drBaseSize == nil then el.drBaseSize = { el.size[1], el.size[2] } end
        el:setSize(el.drBaseSize[1] * s, el.drBaseSize[2] * s)
    end
    if el.setTextSize ~= nil and el.textSize ~= nil then
        if el.drBaseTextSize == nil then el.drBaseTextSize = el.textSize end
        pcall(el.setTextSize, el, el.drBaseTextSize * s)
    end
end

local function baseTextSize(el, fallback)
    if el == nil then return fallback end
    return el.drBaseTextSize or el.textSize or fallback
end

-- Place one strip item: icon on top, amount BELOW it, both centred on the same column axis. Every item
-- occupies one fixed-width column, so icons and numbers line up across rows however long the number is.
-- Returns the item width in normalized space.
local function placeItem(cell, numName, iconName, x, unit, s, slot, numW, clipL, clipR)
    local iconW = LINE_ICON_W_PX * s * unit
    local num = numName ~= nil and cell:getAttribute(numName) or nil
    local icon = iconName ~= nil and cell:getAttribute(iconName) or nil

    if slot == nil then
        if num ~= nil and num.setVisible ~= nil then num:setVisible(false) end
        if icon ~= nil and icon.setVisible ~= nil then icon:setVisible(false) end
        return 0
    end

    local hasNum = slot.num ~= nil and numW ~= nil and numW > 0
    local itemW = LINE_COL_PITCH_PX * s * unit
    local centerX = x + itemW * 0.5

    -- A NUMBER NEVER OUTGROWS ITS COLUMN. The column is a fixed pitch and the number is centred
    -- in it, so a long amount would spill into the neighbours on both sides -- and the amounts
    -- are raw counts, which get long: measured across every production line in the base game and
    -- all installed mods, the p99 is 100,000 and the largest 2,000,000, which is ten characters
    -- once grouped. numW is already measured for the block arithmetic; this is the one place that
    -- also USES it, shrinking just that number rather than the whole row.
    local numScale = s
    if hasNum and numW > itemW * NUM_FIT then
        numScale = s * (itemW * NUM_FIT) / numW
    end

    -- SCROLLING STRIP: an item that would fall even partly outside the window is hidden whole, so
    -- nothing ever bleeds across the arrow axis or past the column's left edge.
    if clipL ~= nil and clipR ~= nil then
        local eps = itemW * 0.02
        if x < clipL - eps or (x + itemW) > clipR + eps then
            if num ~= nil and num.setVisible ~= nil then num:setVisible(false) end
            if icon ~= nil and icon.setVisible ~= nil then icon:setVisible(false) end
            return itemW
        end
    end

    if num ~= nil and num.setVisible ~= nil then
        if hasNum then
            setSlotScale(num, numScale)
            if num.setPosition ~= nil and num.position ~= nil and num.size ~= nil then
                -- the text box is centre-aligned, so centring the box centres the number
                num:setPosition(centerX - num.size[1] * 0.5, num.position[2])
            end
            if num.setText ~= nil then num:setText(slot.num) end
            num:setVisible(true)
        else
            num:setVisible(false)
        end
    end

    if icon ~= nil and icon.setVisible ~= nil then
        setSlotScale(icon, s)
        if icon.setPosition ~= nil and icon.position ~= nil then
            icon:setPosition(centerX - iconW * 0.5, icon.position[2])
        end
        if icon.setImageFilename ~= nil then icon:setImageFilename(slot.file) end
        icon:setVisible(true)
        setIconTooltip(icon, slot.label)
    end

    return itemW, true
end

-- A "+" ON THE BOUNDARY between two products. Shown only when BOTH its neighbours were drawn,
-- so a strip that is scrolled part way out of its window can never end on a dangling "+".
-- Centred on the boundary from its own MEASURED width, so the space either side of the glyph is
-- equal -- positioning a centre-aligned box would leave the gap before it larger than the gap
-- after, which is what a fixed box did on the first attempt at this row.
local function placeSep(cell, name, boundaryX, unit, visible)
    local el = name ~= nil and cell:getAttribute(name) or nil
    if el == nil or el.setVisible == nil then return end
    if not visible then el:setVisible(false); return end
    setSlotScale(el, 1)
    local w = measureTextWidth(el.text or "+", baseTextSize(el, 0.018))
    if el.setPosition ~= nil and el.position ~= nil then
        el:setPosition(boundaryX - w * 0.5, el.position[2])
    end
    el:setVisible(true)
end

-- ----- PING-PONG INPUT STRIP -------------------------------------------------------------------
-- The input window is exactly LINE_IN_WINDOW_SLOTS columns wide. A line with more inputs slides its
-- strip inside that window, out and back again like a moving banner -- nothing shrinks and nothing is
-- dropped, the icons simply take turns. Every row reads the same wall-clock timer, so the rows move in
-- step rather than jittering against each other. The registry is weak-keyed so recycled list cells
-- cannot keep a row alive.
local scrollCells = setmetatable({}, { __mode = "k" })

local function lineScrollOffset(overflow, unit)
    if overflow == nil or overflow <= 0 then return 0 end
    local travelPx = overflow / math.max(unit or 1, 1e-6)
    local travelT = travelPx / LINE_SCROLL_SPEED_PX
    if travelT <= 0 then return 0 end
    local now = (getTimeSec ~= nil) and getTimeSec() or 0
    local period = 2 * (travelT + LINE_SCROLL_PAUSE)
    local t = now % period
    if t < LINE_SCROLL_PAUSE then return 0 end
    t = t - LINE_SCROLL_PAUSE
    if t < travelT then return overflow * (t / travelT) end
    t = t - travelT
    if t < LINE_SCROLL_PAUSE then return overflow end
    t = t - LINE_SCROLL_PAUSE
    return overflow * math.max(0, 1 - t / travelT)
end

-- Draw the input strip at the current scroll phase. Called when a row is populated and then every
-- frame -- it only moves / hides elements that already exist, a row is never rebuilt.
local function applyInputStrip(cell, ctx)
    if cell == nil or ctx == nil then return end
    local offset = lineScrollOffset(ctx.overflow, ctx.unit)
    local clipL, clipR = nil, nil
    if ctx.overflow > 0 then clipL, clipR = ctx.winL, ctx.winR end
    local x = ctx.startX - offset
    local prevDrawn = false
    for i = 1, MAX_LINE_INPUT_ICONS do
        local slot = ctx.slots[i]
        local w, drawn = placeItem(cell, "inNum" .. i, "inIcon" .. i, x, ctx.unit, ctx.scale, slot,
                                   slot ~= nil and ctx.widths[i] or nil, clipL, clipR)
        if i > 1 then
            -- the boundary between product i-1 and product i IS this item's left edge
            placeSep(cell, "inSep" .. (i - 1), x, ctx.unit,
                     slot ~= nil and prevDrawn and drawn == true)
        end
        if slot ~= nil then x = x + w; prevDrawn = (drawn == true) else prevDrawn = false end
    end
end

-- Advance every registered row by one frame.
local function tickLineScroll()
    for cell, ctx in pairs(scrollCells) do
        applyInputStrip(cell, ctx)
    end
end

-- THE WHOLE STRIP, aligned on the arrow axis:
--    [inputs stacked right up to the arrow]  "-->"  [outputs growing rightwards]
-- THE THROUGHPUT GLYPH: does this production point run its active lines in PARALLEL (each at its own
-- rated speed) or in SERIES (one budget shared between them)? DR has known this since 5.28 --
-- sharesThroughput reads pp.sharedThroughputCapacity and throughputShare divides the demand by it -- and
-- it has never been visible anywhere in the UI, which makes a halved CONSUMED (EXP.) figure look like a
-- bug. 5.28 records that costing an entire evening chasing a farm fault that did not exist.
--
-- A PROPERTY OF THE BUILDING, NOT THE LINE, so every line row of one production shows the same glyph.
-- That is deliberate: the row is where a player looks at a line, and the answer is what governs THAT
-- line's rate. It is resolved ONCE per rebuild (self._sharedThroughput) rather than per row.
--
-- Nothing is invented when DR cannot tell: sharesThroughput returns false for a modded point exposing no
-- recognisable flag, and DR then sums the lines (the pre-5.28 behaviour). The glyph shows PARALLEL there
-- because that is genuinely what DR is doing -- it reports DR's own model, not a claim about the building.
--
-- Declared BEFORE its caller. A `local function` further down the file parses clean and resolves to a nil
-- GLOBAL at call time, which inside a populate aborts the row mid-render and shows as an EMPTY LIST --
-- nothing like its cause (5.44 / 5.57, and it has been within one edit of shipping twice).
-- shipped art, resolved once against the mod folder. setImageFilename is the only route -- an
-- imageFilename in the XML cannot name a mod file (5.80).
local LINE_ICON_PARALLEL = (SmartDistribution.modDir or "") .. "gui/icon_throughput_parallel.png"
local LINE_ICON_SERIES   = (SmartDistribution.modDir or "") .. "gui/icon_throughput_series.png"

local function setLineThroughputIcon(cell, shared)
    if cell == nil or cell.getAttribute == nil then return end
    local box = cell:getAttribute("thruIcon")
    if box == nil or box.setImageFilename == nil then return end
    local series = (shared == true)
    -- if/else, not `a and b or c`: this codebase has been bitten twice by that collapse (5.44, 5.46c),
    -- and cells are RECYCLED by SmoothList, so the file is set EVERY populate rather than only when it
    -- changes -- otherwise a row inherits the previous line's glyph (the trap 5.7 and 5.57 both hit).
    local file, tip
    if series then
        file = LINE_ICON_SERIES
        tip  = SmartDistribution.l10n("dr_tip_series", "Series - these lines share one throughput budget")
    else
        file = LINE_ICON_PARALLEL
        tip  = SmartDistribution.l10n("dr_tip_parallel", "Parallel - each line runs at its own full rate")
    end
    box:setImageFilename(file)
    if box.setVisible ~= nil then box:setVisible(true) end
    setIconTooltip(box, tip)
end

-- The arrow always sits on LINE_AXIS_PX, which is what keeps the rows aligned under each other.
-- Inputs never shrink (the window is a fixed column count and a longer list scrolls); the output
-- block shrinks on its own only when it would otherwise reach the STATUS column.
local function setLineInputIcons(cell, fts, outFts, amts, outAmts, names, outNames)
    -- alphabetical left to right in the player's language, inputs and outputs ordered independently
    local sFts, sAmts, sNames = sortedLineIcons(fts, amts, names)
    local sOutFts, sOutAmts, sOutNames = sortedLineIcons(outFts, outAmts, outNames)
    local inSlots = usableIconSlots(sFts, sAmts, sNames, MAX_LINE_INPUT_ICONS)
    local outSlots = usableIconSlots(sOutFts, sOutAmts, sOutNames, MAX_LINE_OUTPUT_ICONS)
    local unit, rowX = linePixelUnit(cell)
    if unit == nil then unit = 1 end
    rowX = rowX or 0

    local numSize = baseTextSize(cell:getAttribute("inNum1"), 0.011)
    local arrowEl = cell:getAttribute("inArrow")
    local arrowSize = baseTextSize(arrowEl, 0.015)
    local arrowText = (arrowEl ~= nil and arrowEl.text ~= nil and arrowEl.text ~= "") and arrowEl.text or "-->"
    local arrowW = measureTextWidth(arrowText, arrowSize)
    local axisX = rowX + LINE_AXIS_PX * unit

    -- width of one block (and of each amount text in it) at a given scale
    local function blockWidth(slots, s)
        local widths = {}
        for i = 1, #slots do
            widths[i] = slots[i].num ~= nil and measureTextWidth(slots[i].num, numSize * s) or 0
        end
        return #slots * LINE_COL_PITCH_PX * s * unit, widths
    end

    local function fitBlock(slots, availPx)
        local s = 1
        local total = blockWidth(slots, 1)
        local avail = availPx * unit
        if total > avail and total > 0 then
            s = math.max(LINE_MIN_SCALE, avail / total)
        end
        local w, widths = blockWidth(slots, s)
        return s, w, widths
    end

    -- INPUTS: fixed window of LINE_IN_WINDOW_SLOTS columns, ending LINE_ARROW_PAD_PX short of the axis
    local winR = axisX - LINE_ARROW_PAD_PX * unit
    local winW = LINE_IN_WINDOW_SLOTS * LINE_COL_PITCH_PX * unit
    local winL = winR - winW
    local inW, inWidths = blockWidth(inSlots, 1)
    local overflow = math.max(0, inW - winW)
    -- everything fits: flush right against the arrow. Overflowing: start at the left edge and scroll.
    local ctx = {
        slots = inSlots, widths = inWidths, unit = unit, scale = 1,
        winL = winL, winR = winR, overflow = overflow,
        startX = (overflow > 0) and winL or (winR - inW),
    }
    scrollCells[cell] = (overflow > 0) and ctx or nil
    applyInputStrip(cell, ctx)

    -- ARROW: always on the axis, so the rows stay aligned
    if arrowEl ~= nil and arrowEl.setVisible ~= nil then
        setSlotScale(arrowEl, 1)
        if arrowEl.setPosition ~= nil and arrowEl.position ~= nil then
            arrowEl:setPosition(axisX, arrowEl.position[2])
        end
        arrowEl:setVisible(true)
    end

    -- OUTPUTS: start behind the arrow and grow rightwards
    local outScale, _, outWidths = fitBlock(outSlots, LINE_OUT_AVAIL_PX - LINE_ARROW_PAD_PX)
    local x = axisX + arrowW + LINE_ARROW_PAD_PX * unit
    local prevOut = false
    for i = 1, MAX_LINE_OUTPUT_ICONS do
        local slot = outSlots[i]
        local w, drawn = placeItem(cell, "outNum" .. i, "outIcon" .. i, x, unit, outScale, slot,
                                   slot ~= nil and outWidths[i] or nil)
        if i > 1 then
            placeSep(cell, "outSep" .. (i - 1), x, unit,
                     slot ~= nil and prevOut and drawn == true)
        end
        if slot ~= nil then x = x + w; prevOut = (drawn == true) else prevOut = false end
    end
end
-- ========================== end PRODUCTION LINE ICON STRIP =========================

local function setIcon(cell, ft, label)
    local iconCell = cell:getAttribute("fillIcon")
    if iconCell == nil then return end
    local file = fillIconFile(ft)
    if file ~= nil and file ~= "" and iconCell.setImageFilename ~= nil then
        iconCell:setImageFilename(file)
        if iconCell.setVisible ~= nil then iconCell:setVisible(true) end
        -- hover tooltip: the row's own localized product name, else the fill type title
        if type(label) ~= "string" or label == "" then label = fillTypeTitle(ft) end
        setIconTooltip(iconCell, label)
    elseif iconCell.setVisible ~= nil then
        iconCell:setVisible(false)
        setIconTooltip(iconCell, nil)
    end
end

-- A LABEL PER PRODUCTION LINE, and a guarantee that no two lines on one building read alike.
--
-- The label is normally DERIVED from the products -- "<outputs> (<inputs>)" -- which is more useful in a
-- distribution mod than the line's own name, because it says what the line moves. But two lines can
-- differ only in AMOUNTS: a mod ships a single-batch line and a double-batch variant over the same
-- inputs and the same outputs, and the derived label is then identical for both. Reported 2026-08-26
-- against a fishing pack whose young-trout and young-salmon lines each have a "( *2)" twin: "the ( *2)
-- are not shown in DR, so you can not see what production line you actually have active."
--
-- The distinguishing text is in the line's OWN name, which the game builds from the #name and #params
-- attributes (ProductionPoint.registerXMLPaths: "Optional parameters formatted into #name"). DR already
-- carries it as line.name and was using it only when a line had no outputs at all.
--
-- SO: derive as before, and fall back to the declared name ONLY where the derived label would be
-- ambiguous. A building whose lines are already distinct is completely unaffected -- which is most of
-- them, including the Carpathian fish farm, whose two trout lines differ by an input (Fish Food) and so
-- never collide. If the declared names are identical too, the lines are numbered rather than left
-- indistinguishable: a label that cannot tell you which line is which has failed at its one job.
local function lineLabels(lines)
    local parts, derived = {}, {}
    for i, line in ipairs(lines) do
        local outNames, oSeen = {}, {}
        for _, o in ipairs(line.outputs or {}) do
            if not oSeen[o.ft] then oSeen[o.ft] = true; outNames[#outNames + 1] = o.name end
        end
        local inNames = {}
        for _, inp in ipairs(line.inputs or {}) do inNames[#inNames + 1] = inp.name end
        -- the products inside a derived label read in the same alphabetical order as the input and
        -- output LISTS above them, in the player's language (display text only; line data untouched)
        if DistributionSort ~= nil then
            DistributionSort.sortStrings(outNames)
            DistributionSort.sortStrings(inNames)
        end
        local head = table.concat(outNames, " + ")
        if head == "" then head = line.name or "" end
        if head == "" then head = string.format(SmartDistribution.l10n("dr_label_line", "Line %d"), i) end
        local tail = table.concat(inNames, " + ")
        parts[i] = { head = head, tail = tail }
        local key = head .. "|" .. tail
        derived[key] = (derived[key] or 0) + 1
    end

    -- Substitute the declared name ONLY where it actually resolves the ambiguity. If the colliding lines
    -- share a declared name too, it resolves nothing and using it would throw away the product info for
    -- no gain ("Batch (Wheat)" tells you less than "Flour (Wheat)"), so the derived label stands and the
    -- numbering below does the work instead.
    local resolves = {}
    for i, line in ipairs(lines) do
        local key = parts[i].head .. "|" .. parts[i].tail
        if (derived[key] or 0) > 1 then
            local g = resolves[key]
            if g == nil then g = { names = {}, ok = true }; resolves[key] = g end
            local nm = (type(line.name) == "string" and line.name ~= "") and line.name or nil
            if nm == nil or g.names[nm] then g.ok = false else g.names[nm] = true end
        end
    end

    local labels, seen = {}, {}
    for i, line in ipairs(lines) do
        local pt   = parts[i]
        local key  = pt.head .. "|" .. pt.tail
        local head = pt.head
        local g    = resolves[key]
        if g ~= nil and g.ok then
            head = line.name                     -- ambiguous, and the declared names tell them apart
        end
        labels[i] = (pt.tail ~= "") and (head .. " (" .. pt.tail .. ")") or head
        seen[labels[i]] = (seen[labels[i]] or 0) + 1
    end
    -- last resort: identical declared names too, so number every member of the colliding group
    local n = {}
    for i = 1, #labels do
        if (seen[labels[i]] or 0) > 1 then
            n[labels[i]] = (n[labels[i]] or 0) + 1
            labels[i] = string.format("%s #%d", labels[i], n[labels[i]])
        end
    end
    return labels
end

function DistributionProductionsPage.new(target, custom_mt)
    local self = DistributionMenuPage.new(target, custom_mt or DistributionProductionsPage_mt)
    self.pageName = "DISTREDUX_PRODUCTIONS"
    self.assets = {}            -- { { placeable, name, class }, ... }
    self.inputs = {}            -- aggregated input rows for the selected building
    self.lines = {}             -- one row per production line
    self.outputs = {}           -- one row per distinct output fill type
    self.selectedAsset = nil
    self.lineIndex = 1
    self.outputIndex = 1
    return self
end

function DistributionProductionsPage:onGuiSetupFinished()
    DistributionProductionsPage:superClass().onGuiSetupFinished(self)
    self:initPeriodOption()   -- Hour / Month / Year selector for every figure on this page
    if self.assetList ~= nil then
        self.assetList:setDataSource(self)
        self.assetList:setDelegate(self)
    end
    -- production lines: selectable (Toggle Line acts on the selected row)
    if self.lineList ~= nil then
        self.lineList:setDataSource(self)
        self.lineList:setDelegate(self)
    end
    -- outputs: selectable (Cycle Output / Sell Timing act on the selected row)
    if self.outputList ~= nil then
        self.outputList:setDataSource(self)
        self.outputList:setDelegate(self)
    end
    -- inputs are information-only: data source (to render rows) but NO delegate (no selection)
    if self.inputList ~= nil then
        self.inputList:setDataSource(self)
    end
    -- rows that fit each frame at the 42px SDListItemStats pitch (152/42 = 3, 277/42 = 6)
    self._scrollMap = { { "inputSlider", "inputList", 3 }, { "lineSlider", "lineList", 4 }, { "outputSlider", "outputList", 6 } }
end

function DistributionProductionsPage:rebuildAssets()
    self.assets = {}
    if SmartDistribution == nil or SmartDistribution.enumerateConfigurableAssets == nil then return end
    for _, a in ipairs(SmartDistribution.enumerateConfigurableAssets()) do
        -- A pass-through store keeps a PRODUCTION role of its own when it still has a genuine line (the
        -- DriveIn's SILAGE -> SILAGE_ADDITIVE), so it arrives here as an ordinary role row -- no special
        -- case needed. This replaces the tab-level test that stood in for roles before they existed.
        if a.class == "PRODUCTION" then
            self.assets[#self.assets + 1] = a
        end
    end
    -- alphabetical by the displayed building name, roleUid as the stable second key (see DistributionSort)
    if DistributionSort ~= nil then
        DistributionSort.sort(self.assets,
            function(a) return a.name or a.baseName or a.origName end,
            function(a) return a.roleUid end)
    end
end

-- Build the three right-pane sections for the selected building:
--   inputs  : aggregated per fill type (held + storage + RECEIVED /mo)
--   lines   : one row per production line (outputs (inputs) label, status, PROD /mo)
--   outputs : one row per distinct output fill type (DISTR/STORED/SOLD /mo, storage, method)
function DistributionProductionsPage:buildSections()
    self.inputs, self.lines, self.outputs = {}, {}, {}
    local p = self.selectedAsset
    self._sharedThroughput = nil
    if p == nil or SmartDistribution == nil or SmartDistribution.productionLines == nil then return end
    local lines = SmartDistribution.productionLines(p) or {}
    -- PER BUILDING, resolved once here rather than per row: sharesThroughput walks the production point's
    -- fields looking for the shared-capacity flag, and the answer is identical for every line of it.
    if SmartDistribution.sharesThroughput ~= nil and SmartDistribution.productionPointOf ~= nil then
        self._sharedThroughput = SmartDistribution.sharesThroughput(SmartDistribution.productionPointOf(p))
    end

    -- Which fill types belong to an ENABLED line (input side / output side). A row is only worth showing
    -- if some enabled line uses it OR there is stock of it -- an input/output tied only to disabled lines
    -- with an empty buffer is noise. "Enabled" (not strictly "Running") keeps rows stable for a line the
    -- player has switched on but which is momentarily idle (starved / output full).
    local activeIn, activeOut = {}, {}
    for _, line in ipairs(lines) do
        if line.enabled then
            for _, i in ipairs(line.inputs or {})  do activeIn[i.ft]  = true end
            for _, o in ipairs(line.outputs or {}) do activeOut[o.ft] = true end
        end
    end

    -- 1) inputs: aggregated per fill type (shown only if an enabled line needs it, or there's stock)
    local inSeen = {}
    for _, line in ipairs(lines) do
        for _, i in ipairs(line.inputs or {}) do
            -- same escape as the outputs below, and it matters more here: i.held is the pp.storage buffer
            -- alone, so feedstock sitting in a folded extension (a greenhouse's water tank, 5.29c) or in
            -- a pooled/market basis read as nothing at all once the line using it was switched off.
            if not inSeen[i.ft] and (activeIn[i.ft] or (i.held or 0) >= HELD_VISIBLE_MIN
                                     or heldAny(p, i.ft) >= HELD_VISIBLE_MIN) then
                inSeen[i.ft] = true
                self.inputs[#self.inputs + 1] = { ft = i.ft, name = i.name, held = i.held or 0, capacity = i.capacity }
            end
        end
    end
    for _, i in ipairs(self.inputs) do
        local e = self:windowStats(i.ft)          -- scoped by the page's Hour / Month / Year selector
        i.received = e.received or 0
        i.consumed = e.consumed or 0
    end

    -- 2) lines: one row per production line, labelled "<outputs> (<inputs>)" -- and disambiguated by the
    -- line's own declared name where two lines would otherwise read alike. See lineLabels.
    local labels = lineLabels(lines)
    for li, line in ipairs(lines) do
        local label = labels[li]
        -- representative monthly production = first output's per-month amount
        local perMonth = 0
        if line.outputs ~= nil and line.outputs[1] ~= nil then perMonth = line.outputs[1].perMonth or 0 end
        -- INPUT FILL TYPES OF THIS LINE, in the same alphabetical order as the label and the inputs
        -- list, for the icon strip drawn in front of the line name. Deduplicated, taken from the line's
        -- OWN recipe (never hardcoded), and simply empty for a line that declares no inputs.
        local inFts, inSeenFt, inAmtByFt, inNameByFt = {}, {}, {}, {}
        for _, i in ipairs(line.inputs or {}) do
            if i.ft ~= nil then
                if not inSeenFt[i.ft] then
                    inSeenFt[i.ft] = true
                    inFts[#inFts + 1] = i.ft
                end
                -- RECIPE NAME: already localized; the strip orders its icons alphabetically by it.
                if type(i.name) == "string" and i.name ~= "" then inNameByFt[i.ft] = i.name end
                -- AMOUNT PER CYCLE from the line's recipe; repeated entries of one fill type add up.
                -- A modded line with no numeric "amount" simply gets no number, but keeps its icon.
                if type(i.amount) == "number" then
                    inAmtByFt[i.ft] = (inAmtByFt[i.ft] or 0) + i.amount
                end
            end
        end
        if DistributionSort ~= nil then
            DistributionSort.sortFillTypes(inFts, function(ft) return fillTypeTitle(ft) end)
        end
        -- OUTPUT FILL TYPES OF THIS LINE, deduplicated, alphabetical in the player's language, for the
        -- "= <product>" icon(s) drawn after the input strip. Taken from the line's own recipe.
        local outFts, outSeenFt, outAmtByFt, outNameByFt = {}, {}, {}, {}
        for _, o in ipairs(line.outputs or {}) do
            if o.ft ~= nil then
                if not outSeenFt[o.ft] then
                    outSeenFt[o.ft] = true
                    outFts[#outFts + 1] = o.ft
                end
                if type(o.name) == "string" and o.name ~= "" then outNameByFt[o.ft] = o.name end
                if type(o.amount) == "number" then
                    outAmtByFt[o.ft] = (outAmtByFt[o.ft] or 0) + o.amount
                end
            end
        end
        if DistributionSort ~= nil then
            DistributionSort.sortFillTypes(outFts, function(ft) return fillTypeTitle(ft) end)
        end
        -- amounts and names collected AFTER the sort, so each number stays with its own icon
        local inAmts, outAmts, inNames, outNames = {}, {}, {}, {}
        for k = 1, #inFts do inAmts[k] = inAmtByFt[inFts[k]]; inNames[k] = inNameByFt[inFts[k]] end
        for k = 1, #outFts do outAmts[k] = outAmtByFt[outFts[k]]; outNames[k] = outNameByFt[outFts[k]] end
        self.lines[#self.lines + 1] = {
            id = line.id, name = label, status = line.status, enabled = line.enabled, perMonth = perMonth,
            inputFts = inFts, outputFts = outFts, inputAmounts = inAmts, outputAmounts = outAmts,
            inputNames = inNames, outputNames = outNames,
        }


    end

    -- 3) outputs: one row per distinct output fill type (shown only if an enabled line makes it, or there
    -- is stock). First occurrence carries held/cap/name.
    local ftSeen = {}
    for _, line in ipairs(lines) do
        for _, o in ipairs(line.outputs or {}) do
            -- Pallets standing on this building's own pad. o.held is the pp.storage buffer ALONE, so
            -- without this a bakery holding five bread pallets understated by the whole pad -- and a row
            -- whose line is off with an empty buffer was dropped entirely, hiding the pallets outright.
            -- Ownership is resolved inside palletLitresOf, so a neighbour's pallets are never counted.
            -- Only evaluated for a fill type not already placed, since it scans world vehicles.
            local pallets, palletLitres = 0, 0
            if not ftSeen[o.ft] then
                -- one memoised scan for both figures; the pair used to be two full vehicle-list walks
                if SmartDistribution.padSnapshot ~= nil then
                    local ok, litres, count = pcall(SmartDistribution.padSnapshot, p, o.ft)
                    if ok and type(litres) == "number" then palletLitres = litres end
                    if ok and type(count)  == "number" then pallets = count end
                else
                    if SmartDistribution.palletCountOf ~= nil then
                        local ok, v = pcall(SmartDistribution.palletCountOf, p, o.ft)
                        if ok and type(v) == "number" then pallets = v end
                    end
                    if SmartDistribution.palletLitresOf ~= nil then
                        local ok, v = pcall(SmartDistribution.palletLitresOf, p, o.ft)
                        if ok and type(v) == "number" then palletLitres = v end
                    end
                end
            end
            -- heldAny LAST, so it is only paid for a row that would otherwise be DROPPED -- the two cheap
            -- terms above answer for the overwhelming majority and short-circuit it away. It is the wider
            -- test (market buffer, shed, extension, pad), and o.held/pallets alone let a switched-off
            -- greenhouse product vanish while its own HELD column showed buffer AND pallets.
            -- `pallets` deliberately keeps a bare > 0: it counts physical pallet OBJECTS, not litres,
            -- so one standing on the pad always earns a row however little is in it.
            if not ftSeen[o.ft] and (activeOut[o.ft] or (o.held or 0) >= HELD_VISIBLE_MIN or pallets > 0
                                     or heldAny(p, o.ft) >= HELD_VISIBLE_MIN) then
                ftSeen[o.ft] = true
                local e = self:windowStats(o.ft)          -- scoped by the page's Hour / Month / Year selector
                self.outputs[#self.outputs + 1] = {
                    ft = o.ft, name = o.name, held = o.held or 0, capacity = o.capacity,
                    heldPallets = pallets, heldPalletLitres = palletLitres,
                    -- one DISTRIBUTED figure: distributed + stored/moved + sold. The split lives on Overview.
                    outTotal = (e.dist or 0) + (e.stored or 0) + (e.sold or 0),
                    sold = e.sold or 0, money = e.money or 0,
                    produced = e.produced or 0,
                    modeName = o.modeName,
                    sellTiming = (SmartDistribution.sellTimingLabel ~= nil) and SmartDistribution.sellTimingLabel(p, o.ft, nil, self.selectedRole) or nil,
                }
            end
        end
    end

    -- blocked-and-empty products are dropped and counted (Advanced routing only; see visibleProducts)
    -- INPUTS ARE LINKED, OUTPUTS ARE THE PRODUCTION'S. A genuine line's input is one pool of stock the
    -- silo and the production share, so it is addressed by the SILO's key (nil role) on both tabs --
    -- block it here and it is blocked there, which is the honest description of one tank. The OUTPUT is
    -- the production's alone and shows on this tab only, so it keeps its own key.
    self.inputs  = filterBlockedRows(p, self.inputs, self:inputRole())
    self.outputs = filterBlockedRows(p, self.outputs, self.selectedRole)

    -- DISPLAY ORDER ONLY (see DistributionSort): each of the three tables is alphabetical by the name
    -- the player reads, in the active language. Lines keep their id, so Toggle Line still acts on the
    -- line the row names; outputs keep their ft, so Cycle Output / Sell Timing are unaffected. The
    -- "+N blocked" notice row carries no name and is pushed back to the end afterwards.
    if DistributionSort ~= nil then
        DistributionSort.sort(self.inputs)
        DistributionSort.sort(self.outputs)
        DistributionSort.sort(self.lines, function(l) return l.name end, function(l) return l.id end)
        keepNoticeLast(self.inputs)
        keepNoticeLast(self.outputs)
    end
end

-- The role an INPUT row is addressed by. nil -- i.e. the primary, the silo -- whenever this building
-- shares its tank, so a genuine line's input is ONE setting seen from two tabs: block it on the silo and
-- it is blocked here. An ordinary production has nothing to share with, so it keeps its own role.
function DistributionProductionsPage:inputRole()
    local p = self.selectedAsset
    if p ~= nil and SmartDistribution ~= nil and SmartDistribution.treatPassThroughAsStore ~= nil
       and SmartDistribution.treatPassThroughAsStore(p) then
        return nil
    end
    return self.selectedRole
end

function DistributionProductionsPage:selectAsset(index)
    local a = self.assets[index]
    self.selectedAsset = a ~= nil and a.placeable or nil
    -- WHICH HALF this row is. It was never set here, so filterBlockedRows below asked with nil -- i.e.
    -- the PRIMARY role -- and a pass-through's production rows were filtered by the SILO's input blocks.
    -- The Storage page has tracked this since roles landed; this page was missed.
    self.selectedRole = a ~= nil and a.role or nil
    if self.assetTitleElement ~= nil then
        self.assetTitleElement:setText(a ~= nil and (a.name or ""):upper() or "")
    end
    self:buildSections()
    self.lineIndex = 1
    self.outputIndex = 1
    if self.inputList ~= nil then self.inputList:reloadData() end
    if self.lineList ~= nil then
        self.lineList:reloadData()
        if self.lineList.setSelectedIndex ~= nil then pcall(function() self.lineList:setSelectedIndex(1) end) end
    end
    if self.outputList ~= nil then
        self.outputList:reloadData()
        if self.outputList.setSelectedIndex ~= nil then pcall(function() self.outputList:setSelectedIndex(1) end) end
    end
    self:updateSellTimingButton()
end

-- Called by the base 2 Hz refresh: this page caches received/produced/sold/held in row objects (built in
-- buildSections), so recompute them from live data before the base reloads the cells. Does NOT touch the
-- selected line/output index -- buildSections only rebuilds the row arrays, and reloadData keeps selection
-- for an unchanged row count.
function DistributionProductionsPage:rebuildRealtimeData()
    if self.selectedAsset ~= nil and self.buildSections ~= nil then self:buildSections() end
end

function DistributionProductionsPage:onFrameOpen()
    DistributionProductionsPage:superClass().onFrameOpen(self)
    self:resetPeriodToCycle()
    self._realtimeLists = { "inputList", "outputList" }   -- 2 Hz live-refresh of the number rows (not the asset picker)
    self:rebuildAssets()
    if self.assetList ~= nil then self.assetList:reloadData() end
    self:selectAsset(1)

    -- keep the info-only Inputs list out of keyboard focus navigation (display only)
    if self.inputList ~= nil and FocusManager ~= nil and FocusManager.removeElement ~= nil then
        pcall(function() FocusManager:removeElement(self.inputList) end)
    end

    self:setSoundSuppressed(true)
    if self.assetList ~= nil then
        FocusManager:setFocus(self.assetList)
        if self.assetList.setSelectedIndex ~= nil then
            pcall(function() self.assetList:setSelectedIndex(1) end)
        end
    end
    self:setSoundSuppressed(false)
end

-- One shared frame tick driving the ping-pong scroll of the overflowing input strips. It only moves /
-- hides elements that already exist -- no row is rebuilt, so it costs next to nothing.
function DistributionProductionsPage:update(dt)
    DistributionProductionsPage:superClass().update(self, dt)
    pcall(tickLineScroll)
    pcall(updateHoverTooltip, dt)
end

-- The tooltip is drawn AFTER the frame, so it sits on top of the rows. The base draw takes clipping
-- arguments in some game versions, so they are passed straight through.
function DistributionProductionsPage:draw(...)
    DistributionProductionsPage:superClass().draw(self, ...)
    SmartDistribution.drawHoverTooltip()
end

function DistributionProductionsPage:onFrameClose()
    SmartDistribution.clearHoverTooltip()
    DistributionProductionsPage:superClass().onFrameClose(self)
end

-- ---- SmoothList delegate (four lists, told apart by identity) ---------------
function DistributionProductionsPage:getNumberOfItemsInSection(list, section)
    if list == self.assetList  then return #self.assets end
    if list == self.inputList  then return #self.inputs end
    if list == self.lineList   then return #self.lines end
    if list == self.outputList then return #self.outputs end
    return 0
end

function DistributionProductionsPage:populateCellForItemInSection(list, section, index, cell)
    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end

    if list == self.assetList then
        local a = self.assets[index]
        if a == nil then return end
        -- renamed buildings show the player's name, with the original store name as a secondary reference
        setc("assetName", a.name or "?")
        setc("assetOrigName", a.origName or "")
        if SmartDistribution.setAssetIcon ~= nil then SmartDistribution.setAssetIcon(cell, a.placeable) end
        return
    end

    if list == self.inputList then
        local inp = self.inputs[index]
        if inp == nil then return end
        if inp.notice ~= nil then renderNoticeRow(cell, inp.notice, "inputs"); return end
        hideNoticeRow(cell)
        applyRowHighlight(cell, (self._focusRole or "output") == "input")
        setc("name", inp.name)
        setc("received", fmtV(inp.received))
        setc("consumed", fmtV(inp.consumed))
        -- The BAR replaces the held/max text and the free-storage cell: green for what is held, red for
        -- what other products are taking, grey for what is left, with the MAX and TARGET marks. Inputs
        -- get those two because a fill target only binds where the receiver PULLS (fillTargetApplies) --
        -- a production line asks for what it needs, so "fill to 60%" is a real instruction here.
        if SmartDistribution.drawStorageBar ~= nil then
            SmartDistribution.drawStorageBar(cell, self.selectedAsset, inp.ft, self.selectedRole, "input")
        end
        setStatusCell(cell, self.selectedAsset, inp.ft, self:currentWindow(), self.selectedRole)
        setIcon(cell, inp.ft, inp.name)
        return
    end

    if list == self.lineList then
        local ln = self.lines[index]
        if ln == nil then return end
        setc("name", ln.name)
        setLineThroughputIcon(cell, self._sharedThroughput)
        setLineInputIcons(cell, ln.inputFts, ln.outputFts, ln.inputAmounts, ln.outputAmounts,
                          ln.inputNames, ln.outputNames)

        setc("status", ln.status or "")
        setc("prodMo", ln.enabled and fmtV(ln.perMonth) or "")   -- PROD /mo only while the line is ON
        return
    end

    -- outputList
    local o = self.outputs[index]
    if o == nil then return end
    if o.notice ~= nil then renderNoticeRow(cell, o.notice, "outputs"); setModeArrows(cell, nil); return end
    hideNoticeRow(cell)
    setModeArrows(cell, o.ft)                          -- in-row mode arrows
    applyRowHighlight(cell, (self._focusRole or "output") ~= "input")
    setc("name", o.name)
    setc("produced", fmtV(o.produced))
    -- one column now: everything that left, with the sale value in brackets when any of it sold
    setc("distr", soldWithMoney(o.outTotal, o.sold > 0.5 and o.money or nil))
    -- The BAR replaces the amount text and the free-storage cell. An OUTPUT gets the RESERVE mark and
    -- not max/target: a reserve is a floor the building keeps back, while a max or a target means nothing
    -- on something the building is trying to get RID of.
    --
    -- HELD IS HANDED IN, not re-derived. o.held is the buffer and o.heldPalletLitres the pad, and this
    -- page is the thing that knows the difference -- outputBarValues taking its own reading would create
    -- a second basis for one quantity, which this codebase has paid for repeatedly (5.27 / 5.28 / 5.54c).
    if SmartDistribution.drawStorageBar ~= nil then
        SmartDistribution.drawStorageBar(cell, self.selectedAsset, o.ft, self.selectedRole, "output",
                                         (o.held or 0) + (o.heldPalletLitres or 0))
    end
    local method = o.modeName or "-"
    if o.sellTiming ~= nil then method = method .. " - " .. o.sellTiming end
    setc("method", method)
    setOutputStatusCell(cell, self.selectedAsset, o.ft, self:currentWindow(), self.selectedRole)
    setIcon(cell, o.ft, o.name)
end

function DistributionProductionsPage:onListSelectionChanged(list, section, index)
    if list == self.assetList then
        self:selectAsset(index)
    elseif list == self.lineList then
        self.lineIndex = index
    elseif list == self.outputList then
        self.outputIndex = index
        self:_focusOn("output")
        self:updateSellTimingButton()
    elseif list == self.inputList then
        self.inputIndex = index
        self:_focusOn("input")
        self:updateSellTimingButton()
    end
end

-- selecting an input row switches the footer's Advanced button to the input (Advanced Inputs) context.
function DistributionProductionsPage:onInputSelectionChanged(list, section, index)
    self.inputIndex = index
    self:_focusOn("input")
    self:updateSellTimingButton()
end
function DistributionProductionsPage:onClickInputRow(element) end

-- Only ONE of the input / output lists should be the active selection at a time. Move keyboard focus to
-- the list the player just touched so its highlight reads as current and the other recedes.
function DistributionProductionsPage:_focusOn(role)
    if self._focusing then return end
    self._focusing = true
    self._focusRole = role
    local keep = (role == "input") and self.inputList or self.outputList
    if keep ~= nil and FocusManager ~= nil and FocusManager.setFocus ~= nil then
        pcall(function() FocusManager:setFocus(keep) end)
    end
    if self.inputList ~= nil then self.inputList:reloadData() end
    if self.outputList ~= nil then self.outputList:reloadData() end
    self._focusing = false
end

function DistributionProductionsPage:onClickAsset(element) end
function DistributionProductionsPage:onClickLineRow(element) end   -- intentionally no-op: clicking a line only HIGHLIGHTS it; the Toggle Line button is the sole on/off
function DistributionProductionsPage:onClickOutputRow(element) end

-- ---- footer actions --------------------------------------------------------
function DistributionProductionsPage:selectedLine()
    return self.lines[self.lineIndex or 1]
end

function DistributionProductionsPage:selectedOutput()
    local o = self.outputs[self.outputIndex or 1]
    -- the "+N blocked" row is a message, not a product: footer actions must see it as no selection
    if o ~= nil and o.notice ~= nil then return nil end
    return o
end

-- rebuild rows after a change, keeping both selections highlighted
function DistributionProductionsPage:refreshSections()
    local li = self.lineIndex or 1
    local oi = self.outputIndex or 1
    self:buildSections()
    if self.inputList ~= nil then self.inputList:reloadData() end
    if self.lineList ~= nil then
        self.lineList:reloadData()
        if self.lineList.setSelectedIndex ~= nil and li > 0 then
            pcall(function() self.lineList:setSelectedIndex(li) end)
        end
    end
    if self.outputList ~= nil then
        self.outputList:reloadData()
        if self.outputList.setSelectedIndex ~= nil and oi > 0 then
            pcall(function() self.outputList:setSelectedIndex(oi) end)
        end
    end
    self:updateSellTimingButton()
end

-- reflect the selected OUTPUT's sell timing on the footer button; drop the button when not a sell mode
function DistributionProductionsPage:updateSellTimingButton()
    local all = self._allButtons
    if all == nil then return end
    local o = self:selectedOutput()
    local label = o ~= nil and o.sellTiming or nil
    -- Shared CANCEL slot: "Spawn Pallets" for a Hold Internal output holding at least one full pallet's
    -- worth, else "Sell Timing" for a sell output, else hidden. The two never apply together. The
    -- palletSpawnReady gate hides the button below one pallet's worth (matches the husbandry + vanilla menus).
    local spawnReady = o ~= nil and o.ft ~= nil and self.selectedAsset ~= nil
        and SmartDistribution.palletSpawnReady ~= nil
        and SmartDistribution.palletSpawnReady(self.selectedAsset, o.ft)
    -- Advanced routing master switch (Settings): off hides both Advanced buttons entirely.
    local adv = SmartDistribution.advancedEnabled == nil or SmartDistribution.advancedEnabled()
    -- Advanced only applies to a configurable output (distribute / store / market, incl. combos).
    local showAdvancedOut = adv and o ~= nil and o.ft ~= nil and self.selectedAsset ~= nil
        and SmartDistribution.modeConfigurable ~= nil
        and SmartDistribution.modeConfigurable(self.selectedAsset, o.ft, self.selectedRole)
    -- Advanced Inputs applies whenever the production has at least one input product to cap/block.
    local showAdvancedIn = adv and self.selectedAsset ~= nil and SmartDistribution.receiverInputFillTypes ~= nil
        and next(SmartDistribution.receiverInputFillTypes(self.selectedAsset)) ~= nil
    -- Single CONTEXTUAL Advanced button: input focus -> Advanced Inputs, else Advanced Outputs.
    local focus = self._focusRole or "output"
    local vis = {}
    for _, b in ipairs(all) do
        if b._role == "sellTiming" then
            if spawnReady then b.text = SmartDistribution.l10n("dr_title_spawnPallets", "Spawn Pallets"); vis[#vis + 1] = b
            elseif label ~= nil then b.text = string.format(SmartDistribution.l10n("dr_btn_sellTimingValue", "Sell Timing: %s"), label); vis[#vis + 1] = b end
        elseif b._role == "advanced" then
            if focus == "input" then
                if showAdvancedIn then b.text = SmartDistribution.l10n("dr_title_advancedInputs", "Advanced Inputs"); vis[#vis + 1] = b end
            else
                if showAdvancedOut then b.text = SmartDistribution.l10n("dr_btn_advancedOutputs", "Advanced Outputs"); vis[#vis + 1] = b end
            end
        else
            vis[#vis + 1] = b
        end
    end
    self:applyFooterButtons(vis)
end

-- The footer's single Advanced button dispatches by which list last had focus.
function DistributionProductionsPage:onAdvancedContextual()
    if (self._focusRole or "output") == "input" then
        if self.onAdvancedInputs ~= nil then self:onAdvancedInputs() end
    else
        if self.onAdvanced ~= nil then self:onAdvanced() end
    end
end

-- Toggle Line: enable/disable the production line selected in the LINE list.
function DistributionProductionsPage:onToggleLine()
    local ln = self:selectedLine()
    if ln == nil or ln.id == nil or self.selectedAsset == nil then return end
    if SmartDistribution.setProductionLineEnabled ~= nil then
        SmartDistribution.setProductionLineEnabled(self.selectedAsset, ln.id, not ln.enabled)
    end
    self:refreshSections()
end

-- Cycle Output: cycle the distribution mode of the OUTPUT selected in the OUTPUT list.
function DistributionProductionsPage:onCycleOutput()
    local o = self:selectedOutput()
    if o == nil or o.ft == nil or self.selectedAsset == nil then return end
    if SmartDistribution.cycleProductionOutput ~= nil then
        SmartDistribution.cycleProductionOutput(self.selectedAsset, o.ft)
    end
    self:refreshSections()
end

-- Standard footer: "Cycle Output" cycles the selected output's mode (matches the other tabs).
function DistributionProductionsPage:onCycleSelected()
    self:onCycleOutput()
end


-- The same step the other way, on the selected output.
function DistributionProductionsPage:onCycleSelectedBack()
    local o = self:selectedOutput()
    if o == nil or o.ft == nil or self.selectedAsset == nil then return end
    if SmartDistribution.cycleProductionOutputBack == nil then return end
    SmartDistribution.cycleProductionOutputBack(self.selectedAsset, o.ft)
    self:refreshSections()
end

-- In-row arrows: step this output's v-mode either way without touching the selection. A production
-- runs on the VIRTUAL mode ring (ProductionDistributeSell), not the asset MODE enum, so this cannot
-- share the StoragePage implementation -- only the arrow plumbing is common.
function DistributionProductionsPage:onModePrev(...) self:stepRowMode(-1, ...) end
function DistributionProductionsPage:onModeNext(...) self:stepRowMode( 1, ...) end

function DistributionProductionsPage:stepRowMode(dir, ...)
    local el = clickedArrow(...)
    local ft = (el ~= nil) and el.sdFillType or nil
    if ft == nil or self.selectedAsset == nil then return end
    if dir < 0 then
        if SmartDistribution.cycleProductionOutputBack == nil then return end
        SmartDistribution.cycleProductionOutputBack(self.selectedAsset, ft)
    else
        if SmartDistribution.cycleProductionOutput == nil then return end
        SmartDistribution.cycleProductionOutput(self.selectedAsset, ft)
    end
    self:refreshSections()
end


-- footer "Advanced Outputs": granular routing for the SELECTED output (demands / stores / markets per its mode)
function DistributionProductionsPage:onAdvanced()
    if self.selectedAsset == nil or SmartDistribution.openAdvancedDialog == nil then return end
    local o = self:selectedOutput()
    if o == nil or o.ft == nil then return end
    SmartDistribution.openAdvancedDialog(self.selectedAsset, o.ft, self.selectedRole)
end

-- footer "Advanced Inputs": receiver-side block + per-product max %% for this production's inputs
function DistributionProductionsPage:onAdvancedInputs()
    if self.selectedAsset == nil or SmartDistribution.openInputsDialog == nil then return end
    SmartDistribution.openInputsDialog(self.selectedAsset, self.selectedRole)
end

-- Sell Timing: flip best-price/immediate for the selected OUTPUT (if it's a sell mode).
function DistributionProductionsPage:onSellTiming()
    local o = self:selectedOutput()
    if o == nil or o.ft == nil or self.selectedAsset == nil then return end
    if SmartDistribution.sellTimingLabel == nil
        or SmartDistribution.sellTimingLabel(self.selectedAsset, o.ft, nil, self.selectedRole) == nil then return end
    local mode = SmartDistribution.resolvedAssetMode(self.selectedAsset, o.ft)
    local target = not SmartDistribution.resolveBestPrice(self.selectedAsset, o.ft, mode, self.selectedRole)
    SmartDistribution.applyAssetSellTiming(self.selectedAsset, o.ft, target, false, self.selectedRole)
    self:refreshSections()
end

-- The CANCEL footer slot dispatches to Spawn (a Hold Internal output) or Sell Timing (a sell output).
function DistributionProductionsPage:onSellTimingOrSpawn()
    local o = self:selectedOutput()
    if o == nil or o.ft == nil or self.selectedAsset == nil then return end
    if SmartDistribution.palletSpawnReady ~= nil and SmartDistribution.palletSpawnReady(self.selectedAsset, o.ft) then
        self:onSpawn()
    else
        self:onSellTiming()
    end
end

-- Spawn `count` pallet(s) of the selected Hold Internal output from its held stock (MP-safe via the event:
-- host/SP spawns directly, a client asks the server; the pallet then syncs like any world object). We set a
-- completion hook so this page's displayed volume refreshes as each pallet fills, without reopening the UI.
function DistributionProductionsPage:onSpawn(count)
    local o = self:selectedOutput()
    if o == nil or o.ft == nil or self.selectedAsset == nil then return end
    local page, asset, ft = self, self.selectedAsset, o.ft
    -- open the pop-up; its confirm callback issues the (MP-safe) spawn request for the chosen count
    if SmartDistribution.openSpawnDialog ~= nil and SmartDistribution.openSpawnDialog(asset, ft, function(option, n, liters)
            if DistributionSpawnEvent ~= nil and DistributionSpawnEvent.request ~= nil then
                SmartDistribution._spawnCompleteCb = function() pcall(function() page:refreshSections() end) end
                -- option carries the pallet TYPE the player picked; liters is the exact total requested
                DistributionSpawnEvent.request(asset, ft, n, option ~= nil and option.filename or nil, liters)
            end
        end) then
        return
    end
    -- fallback (dialog unavailable): spawn one directly
    if DistributionSpawnEvent ~= nil and DistributionSpawnEvent.request ~= nil then
        SmartDistribution._spawnCompleteCb = function() pcall(function() page:refreshSections() end) end
        DistributionSpawnEvent.request(asset, ft, count or 1)   -- fallback: default type, fill each pallet
    end
end

-- [ + gaze entry: jump the building list to a specific placeable and select it.
function DistributionProductionsPage:selectPlaceable(placeable)
    if placeable == nil then return end
    self:rebuildAssets()
    if self.assetList ~= nil then self.assetList:reloadData() end
    local target = 1
    for i, a in ipairs(self.assets) do
        if a.placeable == placeable then target = i; break end
    end
    self:selectAsset(target)
    self:setSoundSuppressed(true)
    if self.assetList ~= nil then
        if self.assetList.setSelectedIndex ~= nil then
            pcall(function() self.assetList:setSelectedIndex(target) end)
        end
        pcall(function() FocusManager:setFocus(self.assetList) end)
    end
    self:setSoundSuppressed(false)
end
