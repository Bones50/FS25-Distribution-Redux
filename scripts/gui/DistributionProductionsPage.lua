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

-- integer liters with thousands separators
local function fmt(n)
    n = math.floor((n or 0) + 0.5)
    local s = tostring(n)
    local k
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
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
local NOTICE_CELLS = { "name", "amount", "remainingText", "received", "consumed", "produced", "distr",
                       "method", "statusText", "status", "prodMo" }

local function renderNoticeRow(cell, hidden, what)
    local icon = cell:getAttribute("fillIcon")
    if icon ~= nil and icon.setVisible ~= nil then icon:setVisible(false) end
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
    if SmartDistribution.inputCapPct ~= nil then
        local okP, v = pcall(SmartDistribution.inputCapPct, placeable, ft)
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

-- The verdict is painted on the HELD cell -- "amount" on this page -- rather than on the figure it was
-- derived from, so FREE STORAGE stays plain white. Same maths, moved one column left. Cells are RECYCLED by
-- SmoothList, so BOTH the nil path and the plain cell must actively reset the colour or a row inherits the
-- previous row's.
local function setRemainingCell(cell, remaining, capacity)
    local c = cell:getAttribute("remainingText")
    if c ~= nil then
        if c.setText ~= nil then c:setText(remaining ~= nil and fmtV(remaining) or "-") end
        if c.setTextColor ~= nil then c:setTextColor(1, 1, 1, 1) end
    end
    local h = cell:getAttribute("amount")
    if h == nil or h.setTextColor == nil then return end
    local COL = (SmartDistribution ~= nil and SmartDistribution.LINK_COLOR) or {}
    local col = nil
    if remaining ~= nil and capacity ~= nil and capacity > 0 then
        if remaining <= 0.5 then col = COL.BLOCKED
        elseif remaining <= capacity * 0.10 then col = COL.IDLE
        else col = COL.ACTIVE end
    end
    if col ~= nil then h:setTextColor(col[1], col[2], col[3], col[4]) else h:setTextColor(1, 1, 1, 1) end
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
    local st  = uid ~= nil and SmartDistribution.inputLinkStatus(uid, ft, window) or nil
    if c.setText ~= nil then c:setText(st ~= nil and ((SmartDistribution.LINK_LABEL or {})[st] or "") or "") end
    local col = st ~= nil and (SmartDistribution.LINK_COLOR or {})[st] or nil
    if col ~= nil and c.setTextColor ~= nil then c:setTextColor(col[1], col[2], col[3], col[4]) end
end

-- OUTGOING (source-side) status for an output row: Active (Sending) / Active (Idle) / Blocked, same colours.
local function setOutputStatusCell(cell, placeable, ft, window, role)
    local c = cell:getAttribute("statusText")
    if c == nil then return end
    local st = (placeable ~= nil and ft ~= nil and SmartDistribution ~= nil and SmartDistribution.outputLinkStatus ~= nil)
        and SmartDistribution.outputLinkStatus(placeable, ft, window, role) or nil
    if c.setText ~= nil then c:setText(st ~= nil and ((SmartDistribution.OUT_LINK_LABEL or {})[st] or "") or "") end
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

local function setIcon(cell, ft)
    local iconCell = cell:getAttribute("fillIcon")
    if iconCell == nil then return end
    local file = fillIconFile(ft)
    if file ~= nil and file ~= "" and iconCell.setImageFilename ~= nil then
        iconCell:setImageFilename(file)
        if iconCell.setVisible ~= nil then iconCell:setVisible(true) end
    elseif iconCell.setVisible ~= nil then
        iconCell:setVisible(false)
    end
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
    self._scrollMap = { { "inputSlider", "inputList", 3 }, { "lineSlider", "lineList", 3 }, { "outputSlider", "outputList", 6 } }
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
end

-- Build the three right-pane sections for the selected building:
--   inputs  : aggregated per fill type (held + storage + RECEIVED /mo)
--   lines   : one row per production line (outputs (inputs) label, status, PROD /mo)
--   outputs : one row per distinct output fill type (DISTR/STORED/SOLD /mo, storage, method)
function DistributionProductionsPage:buildSections()
    self.inputs, self.lines, self.outputs = {}, {}, {}
    local p = self.selectedAsset
    if p == nil or SmartDistribution == nil or SmartDistribution.productionLines == nil then return end
    local lines = SmartDistribution.productionLines(p) or {}

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

    -- 2) lines: one row per production line, labelled "<outputs> (<inputs>)"
    for _, line in ipairs(lines) do
        local outNames, oSeen = {}, {}
        for _, o in ipairs(line.outputs or {}) do
            if not oSeen[o.ft] then oSeen[o.ft] = true; outNames[#outNames + 1] = o.name end
        end
        local inNames = {}
        for _, i in ipairs(line.inputs or {}) do inNames[#inNames + 1] = i.name end
        local outStr = table.concat(outNames, " + ")
        local inStr  = table.concat(inNames, " + ")
        local label  = outStr
        if label == "" then label = line.name or string.format(SmartDistribution.l10n("dr_label_line", "Line %d"), #self.lines + 1) end
        if inStr ~= "" then label = label .. " (" .. inStr .. ")" end
        -- representative monthly production = first output's per-month amount
        local perMonth = 0
        if line.outputs ~= nil and line.outputs[1] ~= nil then perMonth = line.outputs[1].perMonth or 0 end
        self.lines[#self.lines + 1] = {
            id = line.id, name = label, status = line.status, enabled = line.enabled, perMonth = perMonth,
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
        -- "619 L / 50,000 L (50%)": held, the ceiling the Advanced Inputs percentage sets, and that
        -- percentage. Same form as the other tabs' input lists. Falls back to the raw buffer if unresolved.
        local maxL, pct = inputMaxLiters(self.selectedAsset, inp.ft)
        setc("amount", maxL ~= nil
            and (fmtV(inp.held) .. " / " .. fmtV(maxL) .. (pct ~= nil and string.format(" (%d%%)", pct) or ""))
            or amountText(inp.held, inp.capacity))
        setRemainingCell(cell, inputRemaining(self.selectedAsset, inp.ft), maxL)
        setStatusCell(cell, self.selectedAsset, inp.ft, self:currentWindow(), self.selectedRole)
        setIcon(cell, inp.ft)
        return
    end

    if list == self.lineList then
        local ln = self.lines[index]
        if ln == nil then return end
        setc("name", ln.name)
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
    setc("amount", amountText(o.held, o.capacity) .. palletPart(o.heldPalletLitres, o.heldPallets))
    -- REMAINING for an output is a straight capacity - held. o.capacity is the production BUFFER's, which
    -- is what the amount cell brackets, so the two figures describe the same tank.
    setRemainingCell(cell,
        (type(o.capacity) == "number" and o.capacity > 0) and math.max(0, o.capacity - (o.held or 0)) or nil,
        o.capacity)
    local method = o.modeName or "-"
    if o.sellTiming ~= nil then method = method .. " - " .. o.sellTiming end
    setc("method", method)
    setOutputStatusCell(cell, self.selectedAsset, o.ft, self:currentWindow(), self.selectedRole)
    setIcon(cell, o.ft)
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
