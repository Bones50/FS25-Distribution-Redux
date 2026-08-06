-- ============================================================================
-- DistributionStoragePage.lua  (Distribution Redux) -- Storage tab
-- Master-detail reproduction of the manager + Asset (silo) dialog:
--   left  list (assetList)  : silos / barns / sheds / heaps you can configure
--   right list (detailList) : the selected building's per-product rows
--                             (icon / held / distr / sold / stored / mode+timing)
-- Footer buttons (real keys via the menu's setMenuButtonInfo): Cycle Output,
-- Sell Timing. All actions reuse the existing engine seams, so this
-- is a new view over the same logic the popup uses.
-- ============================================================================

DistributionStoragePage = {}
local DistributionStoragePage_mt = Class(DistributionStoragePage, DistributionMenuPage)

local STORAGE_CLASSES = { SILO = "Silo", HUSBANDRY = "Barn", SHED = "Storage", HEAP = "Pit", MARKET = "Market" }

-- The input list and the output/detail list each keep their own selected row, and FS25 draws the
-- selection highlight on a row regardless of which list has focus -- so both look selected at once. Each
-- row element carries a `hideSelection` flag (its own built-in way to suppress the highlight); we set it
-- on rows of the list that is NOT active so only the active list shows a highlight. active == true means
-- "this list currently owns focus".
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

-- EVERY litre figure on this page goes through here, and here delegates to SmartDistribution.formatVolume
-- so the whole mod switches to kilolitres in one place: up to 999 L reads in litres, anything above reads
-- in kL with the extraneous zeros dropped (600,000 L -> "600 kL", 123,123 L -> "123.123 kL"). It carries
-- the UNIT itself -- do not append " L" to it. `fmt` above survives for things that are not volumes.
local function fmtV(n)
    if SmartDistribution ~= nil and SmartDistribution.formatVolume ~= nil then
        local ok, s = pcall(SmartDistribution.formatVolume, n or 0)
        if ok and type(s) == "string" then return s end
    end
    return fmt(n) .. " L"
end

-- ---- BLOCKED-PRODUCT NOTICE ------------------------------------------------
-- With Advanced routing ON, a blocked product the building is not holding is dropped from these lists
-- (SmartDistribution.visibleProducts) and the count comes back as one final row, so a shortened table
-- always explains itself rather than quietly losing rows. The row carries `notice` and NO `ft`, and every
-- accessor that reaches for a product treats it as absent -- see selectedDetailRow.
local NOTICE_CELLS = { "fillName", "name", "heldText", "amount", "remainingText", "recvText", "received",
                       "consumedText", "consumed", "prodText", "produced", "distText", "distr",
                       "modeText", "method", "statusText", "status" }

local function renderNoticeRow(cell, hidden, what)
    local icon = cell:getAttribute("fillIcon")
    if icon ~= nil and icon.setVisible ~= nil then icon:setVisible(false) end
    -- SmoothList RECYCLES cells, so every column must be actively cleared or this row inherits whatever
    -- the product row that last used the slot left behind -- the trap 5.7 already hit with colours.
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
        local word = what
        if hidden == 1 then word = word:sub(1, #word - 1) end        -- "1 input", not "1 inputs"
        n:setText(string.format("+%d %s blocked (See Advanced Inputs)", hidden, word))
    end
    local COL = (SmartDistribution ~= nil and SmartDistribution.LINK_COLOR) or {}
    local col = COL.IDLE or { 0.95, 0.65, 0.20, 1 }
    if n.setTextColor ~= nil then n:setTextColor(col[1], col[2], col[3], col[4] or 1) end
end

-- ...and every NORMAL row has to hide the overlay again, for that same recycling reason
local function hideNoticeRow(cell)
    local n = cell:getAttribute("noticeText")
    if n ~= nil and n.setVisible ~= nil then n:setVisible(false) end
end

-- "<liters>  (<money>)" for the SOLD /mo column; money omitted when zero/unknown (e.g. MP clients)
local function soldWithMoney(liters, money)
    local base = fmtV(liters)
    if money ~= nil and money > 0.5 and SmartDistribution ~= nil and SmartDistribution.formatMoneyShort ~= nil then
        return base .. "  (" .. SmartDistribution.formatMoneyShort(money) .. ")"
    end
    return base
end

-- Everything that LEFT the building over the window, as one figure: distributed + stored/moved + sold,
-- with the sale value in brackets when any of it sold. The three-way split now lives on the Overview tab,
-- which is where these pages point the player for detail.
local function outTotalText(e)
    if type(e) ~= "table" then return fmtV(0) end
    return soldWithMoney((e.dist or 0) + (e.stored or 0) + (e.sold or 0), e.money)
end

-- "473 L + 3,000 L (3p)" -- the internal buffer, then what stands on the pad, matching the Productions and
-- Overview tabs. A pen's stock lives in BOTH places at once and the split is the useful information: one
-- lump could not say whether the eggs were still buffering or already on pallets, and the figure used to
-- change meaning with the mode (473 under Hold Internal, 3,473 under anything else) because assetHeld
-- switched basis. assetHeld is now always the full stock, and this splits it back out for display.
-- Pallets are counted as OBJECTS by palletCountOf, never litres/1000 -- a part-filled pallet is one pallet
-- standing on the pad, not zero. Falls back to the plain total for anything that spawns no pallets, so
-- milk / manure / slurry rows are unchanged.
local function heldWithPallets(placeable, ft, held)
    if placeable == nil or ft == nil or SmartDistribution == nil then return fmtV(held) end
    -- one memoised pad scan for both figures rather than two full vehicle-list walks per row per refresh
    local pallets, n = 0, 0
    if SmartDistribution.padSnapshot ~= nil then
        local ok, litres, count = pcall(SmartDistribution.padSnapshot, placeable, ft)
        if ok and type(litres) == "number" then pallets = litres end
        if ok and type(count)  == "number" then n = count end
    else
        if SmartDistribution.palletLitresOf ~= nil then
            local ok, v = pcall(SmartDistribution.palletLitresOf, placeable, ft)
            if ok and type(v) == "number" then pallets = v end
        end
        if pallets > 0 and SmartDistribution.palletCountOf ~= nil then
            local ok, v = pcall(SmartDistribution.palletCountOf, placeable, ft)
            if ok and type(v) == "number" then n = v end
        end
    end
    local internal = math.max(0, (held or 0) - pallets)
    local text = fmtV(internal)
    -- capacity sits directly beside the figure it qualifies, not trailing after the pad part
    if SmartDistribution.outputCapacityTotal ~= nil then
        local ok, c = pcall(SmartDistribution.outputCapacityTotal, placeable, ft)
        if ok and type(c) == "number" and c > 0 and c < math.huge then
            text = text .. " (" .. fmtV(c) .. ")"
        end
    end
    if pallets > 0 then text = text .. " + " .. fmtV(pallets) .. " (" .. tostring(n) .. "p)" end
    return text
end

local function fillIconFile(ft)
    if g_fillTypeManager == nil or g_fillTypeManager.getFillTypeByIndex == nil then return nil end
    local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
    if ok and def ~= nil then
        return def.hudOverlayFilename or def.hudOverlayFilenameSmall
    end
    return nil
end

local function fillTypeTitle(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local def = g_fillTypeManager:getFillTypeByIndex(ft)
        if def ~= nil and def.title ~= nil then return def.title end
    end
    return tostring(ft)
end
-- Build the product rows for one list, dropping blocked-and-empty products and appending the notice.
-- Shared by all three classes in this file so the rule cannot drift between the tabs.
local function buildProductRows(asset, ordered)
    local rows, hidden = {}, 0
    if SmartDistribution ~= nil and SmartDistribution.visibleProducts ~= nil then
        ordered, hidden = SmartDistribution.visibleProducts(asset, ordered)
    end
    for _, ft in ipairs(ordered) do rows[#rows + 1] = { ft = ft, name = fillTypeTitle(ft) } end
    if hidden > 0 then rows[#rows + 1] = { notice = hidden } end
    return rows
end


-- How much of this product the building will actually take: its storage AFTER the Advanced Inputs
-- percentage is applied, so the figure on the main list matches the one the dialog reserves. A pooled
-- store reports the shared pool times this product's share; an individual tank reports its own capacity.
-- Blocked -> 0 (it will accept nothing). Returns nil when capacity can't be resolved, so the caller can
-- fall back to showing the held figure alone rather than inventing a denominator.
local function inputMaxLiters(placeable, ft)
    if placeable == nil or ft == nil or SmartDistribution == nil then return nil end
    local uid = (SmartDistribution.assetUid ~= nil) and SmartDistribution.assetUid(placeable) or nil
    if uid ~= nil and SmartDistribution.isInputBlocked ~= nil and SmartDistribution.isInputBlocked(uid, ft) then
        return 0
    end
    local cap = nil
    if SmartDistribution.inputProductCapacity ~= nil then
        local ok, c = pcall(SmartDistribution.inputProductCapacity, placeable, ft)
        if ok and type(c) == "number" then cap = c end
    end
    if (cap == nil or cap <= 0) and SmartDistribution.husbandryInputCapacity ~= nil then
        local ok, c = pcall(SmartDistribution.husbandryInputCapacity, placeable, ft)
        if ok and type(c) == "number" then cap = c end
    end
    if cap == nil or cap <= 0 or cap >= math.huge then return nil end
    -- MAX means the CAP: this product's percentage of the building's capacity, matching the Advanced Inputs
    -- dialog's own MAX IN column exactly. It used to return inputEffectiveMaxLiters -- the ELASTIC "what
    -- could still fit given what the others hold" -- which made the figure shrink as neighbours filled up
    -- and had no relationship to the percentage the player had set. That elastic number is still shown, as
    -- AVAILABLE in the dialog, where it is labelled honestly.
    local pct = 100
    if SmartDistribution.inputCapPct ~= nil then
        local ok, v = pcall(SmartDistribution.inputCapPct, placeable, ft)
        if ok and type(v) == "number" then pct = v end
    end
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return cap * pct / 100, pct
end

-- "619 L / 50,000 L (50%)" for an input row: what is there, the most that may go in, and the percentage
-- that ceiling comes from. Drops the tail when capacity cannot be resolved rather than inventing one.
local function heldOfMaxText(placeable, ft, held)
    local maxL, pct = inputMaxLiters(placeable, ft)
    if maxL == nil then return fmtV(held) end
    local s = fmtV(held) .. " / " .. fmtV(maxL)
    if pct ~= nil then s = s .. string.format(" (%d%%)", pct) end
    return s
end

-- ---- REMAINING ------------------------------------------------------------
-- How much more will fit, and the colour that says how comfortable that is.
--   inputs  -> inputAcceptableLiters: the very figure the allocator clamps every delivery to, and the same
--              one the Advanced Inputs dialog shows as AVAILABLE, so the three can never disagree
--   outputs -> a straight capacity - held
-- Colour: red when nothing is left (or it is overfilled), orange at 10% or less of the ceiling, green
-- otherwise. nil capacity means there is nothing to judge against, so the cell shows a dash in the default
-- colour rather than inventing a verdict.
local function inputRemaining(placeable, ft)
    if placeable == nil or ft == nil or SmartDistribution == nil then return nil end
    if SmartDistribution.inputAcceptableLiters == nil then return nil end
    local ok, v = pcall(SmartDistribution.inputAcceptableLiters, placeable, ft)
    if not ok or type(v) ~= "number" or v ~= v or v < 0 or v >= math.huge then return nil end
    return v
end

local function outputRemaining(placeable, ft, held)
    if placeable == nil or ft == nil or SmartDistribution == nil then return nil, nil end
    if SmartDistribution.outputCapacityTotal == nil then return nil, nil end
    local ok, c = pcall(SmartDistribution.outputCapacityTotal, placeable, ft)
    if not ok or type(c) ~= "number" or c <= 0 or c >= math.huge then return nil, nil end
    return math.max(0, c - (held or 0)), c
end

-- Writes the figure AND the colour. Cells are RECYCLED by SmoothList, so the nil path must actively reset
-- to white or the row inherits whatever colour the previous row left in that cell.
local function setRemainingCell(cell, remaining, capacity)
    local c = cell:getAttribute("remainingText")
    if c == nil then return end
    if c.setText ~= nil then c:setText(remaining ~= nil and fmtV(remaining) or "-") end
    if c.setTextColor == nil then return end
    local COL = (SmartDistribution ~= nil and SmartDistribution.LINK_COLOR) or {}
    local col = nil
    if remaining ~= nil and capacity ~= nil and capacity > 0 then
        if remaining <= 0.5 then col = COL.BLOCKED
        elseif remaining <= capacity * 0.10 then col = COL.IDLE
        else col = COL.ACTIVE end
    end
    if col ~= nil then c:setTextColor(col[1], col[2], col[3], col[4]) else c:setTextColor(1, 1, 1, 1) end
end

-- Distribution status of an input row (Active (Receiving) / Active (Idle) / Blocked). Shared by every
-- building category -- silos, storages, productions, animal pens and markets resolve a link the same way.
local function inputStatusLabel(placeable, ft)
    if placeable == nil or ft == nil or SmartDistribution == nil then return "" end
    if SmartDistribution.inputLinkStatus == nil or SmartDistribution.assetUid == nil then return "" end
    local uid = SmartDistribution.assetUid(placeable)
    if uid == nil then return "" end
    local st = SmartDistribution.inputLinkStatus(uid, ft)
    return (SmartDistribution.LINK_LABEL or {})[st] or ""
end

-- write the status into a row cell AND colour it: green feeding, orange idle, red blocked
local function setStatusCell(cell, placeable, ft)
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
        if c.setText ~= nil then c:setText("Blocked") end
        local bc = (SmartDistribution.LINK_COLOR or {}).BLOCKED
        if bc ~= nil and c.setTextColor ~= nil then c:setTextColor(bc[1], bc[2], bc[3], bc[4]) end
        return
    end
    local st  = uid ~= nil and SmartDistribution.inputLinkStatus(uid, ft) or nil
    if c.setText ~= nil then c:setText(st ~= nil and ((SmartDistribution.LINK_LABEL or {})[st] or "") or "") end
    local col = st ~= nil and (SmartDistribution.LINK_COLOR or {})[st] or nil
    if col ~= nil and c.setTextColor ~= nil then c:setTextColor(col[1], col[2], col[3], col[4]) end
end

-- OUTGOING (source-side) status into a row's statusText cell + the same green/orange/red colours:
-- Active (Sending) when it moved product last cycle, Active (Idle) when configured but nothing moved,
-- Blocked when every routable destination is blocked. Blank for Hold / non-sending modes.
local function setOutputStatusCell(cell, placeable, ft)
    local c = cell:getAttribute("statusText")
    if c == nil then return end
    local st = (placeable ~= nil and ft ~= nil and SmartDistribution ~= nil and SmartDistribution.outputLinkStatus ~= nil)
        and SmartDistribution.outputLinkStatus(placeable, ft) or nil
    if c.setText ~= nil then c:setText(st ~= nil and ((SmartDistribution.OUT_LINK_LABEL or {})[st] or "") or "") end
    local col = st ~= nil and (SmartDistribution.LINK_COLOR or {})[st] or nil
    if col ~= nil and c.setTextColor ~= nil then c:setTextColor(col[1], col[2], col[3], col[4])
    elseif c.setTextColor ~= nil then c:setTextColor(1, 1, 1, 1) end
end

function DistributionStoragePage.new(target, custom_mt)
    local self = DistributionMenuPage.new(target, custom_mt or DistributionStoragePage_mt)
    self.pageName = "DISTREDUX_STORAGE"
    self.classFilter = { SILO = true, SHED = true, HEAP = true }   -- Silos / Storage tab: silos, sheds, and manure heaps / slurry pits (all are storage)
    self.assets = {}     -- { { placeable, name, class }, ... }
    self.rows = {}       -- detail rows for the selected asset: { { ft, name }, ... }
    self.selectedAsset = nil
    self.detailIndex = 1
    return self
end

function DistributionStoragePage:onGuiSetupFinished()
    DistributionStoragePage:superClass().onGuiSetupFinished(self)
    self:initPeriodOption()   -- Hour / Month / Year selector; inherited by the Husbandry + Markets layouts
    if self.assetList ~= nil then
        self.assetList:setDataSource(self)
        self.assetList:setDelegate(self)
    end
    if self.detailList ~= nil then
        self.detailList:setDataSource(self)
        self.detailList:setDelegate(self)
    end
    if self.inputList ~= nil then
        self.inputList:setDataSource(self)
        self.inputList:setDelegate(self)
    end
    -- rows that fit each frame at the 42px SDListItemStats pitch (340/42 = 8, 280/42 = 6); this only
    -- hides the scrollbar track when the list does NOT overflow its frame
    self._scrollMap = { { "detailSlider", "detailList", 8 }, { "inputSlider", "inputList", 6 } }
end

-- which configurable assets belong on this tab
function DistributionStoragePage:rebuildAssets()
    self.assets = {}
    if SmartDistribution == nil or SmartDistribution.enumerateConfigurableAssets == nil then return end
    local allow = self.classFilter or {}
    for _, a in ipairs(SmartDistribution.enumerateConfigurableAssets()) do
        if allow[a.class] then
            self.assets[#self.assets + 1] = a
        end
    end
end

function DistributionStoragePage:buildDetailRows()
    self.rows = {}
    local asset = self.selectedAsset
    local lister = SmartDistribution ~= nil and (SmartDistribution.assetMenuFillTypes or SmartDistribution.assetFillTypes or SmartDistribution.siloFillTypes) or nil
    if asset == nil or lister == nil then return end
    local fts = lister(asset)
    local ordered = {}
    for ft in pairs(fts) do ordered[#ordered + 1] = ft end
    table.sort(ordered)
    self.rows = buildProductRows(asset, ordered)
end

function DistributionStoragePage:selectAsset(index)
    local a = self.assets[index]
    self.selectedAsset = a ~= nil and a.placeable or nil
    if self.assetTitleElement ~= nil then
        self.assetTitleElement:setText(a ~= nil and (a.name or ""):upper() or "")
    end
    -- A bunker silo has NO input side at all, so the whole INCOMING block is hidden for one rather than
    -- shown empty. DR can never deposit into a terrain heap (no sanctioned fill-level API, see the bunker
    -- section in SmartDistribution.lua), so an incoming table here would advertise something that cannot
    -- happen. Header and list are hidden together; nil-guarded because the subclasses that inherit this
    -- selectAsset (Markets) use their own layout and have neither element.
    -- NOTE the block is absolutely positioned, so the outgoing table below does NOT move up into the gap.
    local noInputs = self.selectedAsset ~= nil and SmartDistribution ~= nil
        and SmartDistribution.isBunkerSiloPlaceable ~= nil
        and SmartDistribution.isBunkerSiloPlaceable(self.selectedAsset)
    if self.inputHeaderRow ~= nil and self.inputHeaderRow.setVisible ~= nil then
        self.inputHeaderRow:setVisible(not noInputs)
    end
    if self.inputPanel ~= nil and self.inputPanel.setVisible ~= nil then
        self.inputPanel:setVisible(not noInputs)
    end
    -- keep the contextual footer on the output side; the input list cannot be focused while hidden
    if noInputs then self._focusRole = "output" end
    self:buildDetailRows()
    self.detailIndex = 1
    self.inputIndex = 1
    if self.detailList ~= nil then
        self.detailList:reloadData()
        if self.detailList.setSelectedIndex ~= nil then
            pcall(function() self.detailList:setSelectedIndex(1) end)
        end
    end
    if self.inputList ~= nil then self.inputList:reloadData() end
    self:updateSellTimingButton()
end

function DistributionStoragePage:onFrameOpen()
    DistributionStoragePage:superClass().onFrameOpen(self)
    self._realtimeLists = { "inputList", "detailList" }   -- 2 Hz live-refresh of the number rows (not the asset picker)
    self:rebuildAssets()
    if self.assetList ~= nil then self.assetList:reloadData() end
    self:selectAsset(1)

    self:setSoundSuppressed(true)
    if self.assetList ~= nil then
        FocusManager:setFocus(self.assetList)
        if self.assetList.setSelectedIndex ~= nil then
            pcall(function() self.assetList:setSelectedIndex(1) end)
        end
    end
    self:setSoundSuppressed(false)
end

-- ---- SmoothList delegate (two lists, told apart by identity) ----------------
function DistributionStoragePage:getNumberOfItemsInSection(list, section)
    if list == self.assetList then return #self.assets end
    return #self.rows            -- inputList and detailList show the same products (incoming vs outgoing view)
end

function DistributionStoragePage:populateCellForItemInSection(list, section, index, cell)
    if list == self.assetList then
        local a = self.assets[index]
        if a == nil then return end
        local nameCell = cell:getAttribute("assetName")
        if nameCell ~= nil then nameCell:setText(a.name or "?") end
        -- renamed buildings show the player's name, with the original store name as a secondary label
        local origCell = cell:getAttribute("assetOrigName")
        if origCell ~= nil then origCell:setText(a.origName or "") end
        local typeCell = cell:getAttribute("assetType")
        if typeCell ~= nil then typeCell:setText(STORAGE_CLASSES[a.class] or a.class or "") end
        if SmartDistribution.setAssetIcon ~= nil then SmartDistribution.setAssetIcon(cell, a.placeable) end
        return
    end

    -- detail row
    local row = self.rows[index]
    if row == nil then return end
    if row.notice ~= nil then
        renderNoticeRow(cell, row.notice, (list == self.inputList) and "inputs" or "outputs")
        return
    end
    hideNoticeRow(cell)

    local iconCell = cell:getAttribute("fillIcon")
    if iconCell ~= nil then
        local file = fillIconFile(row.ft)
        if file ~= nil and file ~= "" and iconCell.setImageFilename ~= nil then
            iconCell:setImageFilename(file)
            iconCell:setVisible(true)
        else
            iconCell:setVisible(false)
        end
    end

    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end

    -- INCOMING view: the same products, shown as what flows in (received / held / distribution status)
    if list == self.inputList then
        applyRowHighlight(cell, (self._focusRole or "output") == "input")
        setc("fillName", row.name)
        local e = self:windowStats(row.ft)
        local held = (SmartDistribution.assetHeld ~= nil) and SmartDistribution.assetHeld(self.selectedAsset, row.ft) or 0
        setc("recvText", fmtV(e.received))
        setc("heldText", heldOfMaxText(self.selectedAsset, row.ft, held))
        setRemainingCell(cell, inputRemaining(self.selectedAsset, row.ft), inputMaxLiters(self.selectedAsset, row.ft))
        setStatusCell(cell, self.selectedAsset, row.ft)
        return
    end

    applyRowHighlight(cell, (self._focusRole or "output") ~= "input")
    setc("fillName", row.name)

    local held = (SmartDistribution.assetHeld ~= nil) and SmartDistribution.assetHeld(self.selectedAsset, row.ft) or 0
    setc("heldText", heldWithPallets(self.selectedAsset, row.ft, held))
    setRemainingCell(cell, outputRemaining(self.selectedAsset, row.ft, held))
    setc("distText", outTotalText(self:windowStats(row.ft)))

    local modeCell = cell:getAttribute("modeText")
    if modeCell ~= nil then
        -- palletizable flag passed so a pallet output reads "Hold Pallets" rather than a bare "Hold",
        -- matching the Productions tab for the same pair of modes
        local pal = (SmartDistribution.holdLabelFlag ~= nil)
            and SmartDistribution.holdLabelFlag(self.selectedAsset, row.ft) or false
        local text = SmartDistribution.modeName(SmartDistribution.resolvedAssetMode(self.selectedAsset, row.ft), pal)
        local timing = (SmartDistribution.sellTimingLabel ~= nil)
            and SmartDistribution.sellTimingLabel(self.selectedAsset, row.ft) or nil
        if timing ~= nil then text = text .. "  -  " .. timing end
        modeCell:setText(text)
    end
    setOutputStatusCell(cell, self.selectedAsset, row.ft)
end

function DistributionStoragePage:onListSelectionChanged(list, section, index)
    if list == self.assetList then
        self:selectAsset(index)
    elseif list == self.detailList then
        self.detailIndex = index
        self:_focusOn("output")
        self:updateSellTimingButton()
    elseif list == self.inputList then
        self.inputIndex = index
        self:_focusOn("input")
        self:updateSellTimingButton()
    end
end

function DistributionStoragePage:onClickAsset(element) end
function DistributionStoragePage:onClickDetailRow(element) end

-- selecting an input row switches the footer's Advanced button to the input (Advanced Inputs) context.
function DistributionStoragePage:onInputSelectionChanged(list, section, index)
    self.inputIndex = index
    self:_focusOn("input")
    self:updateSellTimingButton()
end
function DistributionStoragePage:onClickInputRow(element) end

-- Only ONE of the input / output(detail) lists should be the active selection at a time. Move keyboard
-- focus to the list the player just touched: FocusManager gives the focused list the active highlight and
-- the other list's row recedes, so a single selection reads as current. _focusRole drives the footer.
function DistributionStoragePage:_focusOn(role)
    if self._focusing then return end   -- reloadData below can re-enter selection events; guard against recursion
    self._focusing = true
    self._focusRole = role
    local keep = (role == "input") and self.inputList or self.detailList
    if keep ~= nil and FocusManager ~= nil and FocusManager.setFocus ~= nil then
        pcall(function() FocusManager:setFocus(keep) end)
    end
    -- repaint both lists so the highlight suppression (applyRowHighlight) reflects the new active list
    if self.inputList ~= nil then self.inputList:reloadData() end
    if self.detailList ~= nil then self.detailList:reloadData() end
    self._focusing = false
end

-- ---- footer actions (wired from the menu's setMenuButtonInfo) ---------------
function DistributionStoragePage:selectedDetailRow()
    local r = self.rows[self.detailIndex or 1]
    -- the "+N blocked" row is a message, not a product: every footer action (cycle mode, sell timing,
    -- Advanced) must see it as no selection at all rather than acting on a nil fill type
    if r ~= nil and r.notice ~= nil then return nil end
    return r
end

-- current best-price/immediate label of the selected product (nil if not a sell mode)
function DistributionStoragePage:currentSellTimingLabel()
    local row = self:selectedDetailRow()
    if row == nil or self.selectedAsset == nil or SmartDistribution.sellTimingLabel == nil then return nil end
    return SmartDistribution.sellTimingLabel(self.selectedAsset, row.ft)
end

-- rebuild the footer button list, showing the Sell Timing button ONLY when the selected output is a
-- sell mode (Sell / Distribute + Sell); otherwise it's dropped from the list entirely.
function DistributionStoragePage:updateSellTimingButton()
    local all = self._allButtons
    if all == nil then return end
    local label = self:currentSellTimingLabel()
    -- The single "Advanced" button is CONTEXTUAL: it acts on whichever list last had focus. With an input
    -- row focused it becomes "Advanced Inputs"; with an output/detail row focused it's "Advanced Outputs".
    local focus = self._focusRole or "output"
    local row = self:selectedDetailRow()
    -- Advanced routing master switch (Settings): off hides both Advanced buttons entirely.
    local adv = SmartDistribution.advancedEnabled == nil or SmartDistribution.advancedEnabled()
    -- NOTE markets never reach this function: DistributionMarketsPage overrides updateSellTimingButton and
    -- decides its own footer (Advanced Inputs only). Do not add a market case here -- it would be dead code.
    local showAdvancedOut = adv and row ~= nil and row.ft ~= nil and self.selectedAsset ~= nil
        and SmartDistribution.modeConfigurable ~= nil
        and SmartDistribution.modeConfigurable(self.selectedAsset, row.ft)
    local showAdvancedIn = adv and self.selectedAsset ~= nil and SmartDistribution.receiverInputFillTypes ~= nil
        and next(SmartDistribution.receiverInputFillTypes(self.selectedAsset)) ~= nil
    -- Shared CANCEL slot: "Spawn Pallets" for a Hold Internal pallet output holding at least one pallet's
    -- worth (coops / sheep), else "Sell Timing" for a sell output, else hidden. The two never overlap.
    local spawnReady = row ~= nil and row.ft ~= nil and self.selectedAsset ~= nil
        and SmartDistribution.palletSpawnReady ~= nil
        and SmartDistribution.palletSpawnReady(self.selectedAsset, row.ft)
    local vis = {}
    for _, b in ipairs(all) do
        if b._role == "sellTiming" then
            if spawnReady then b.text = "Spawn Pallets"; vis[#vis + 1] = b
            elseif label ~= nil then b.text = "Sell Timing: " .. label; vis[#vis + 1] = b end
        elseif b._role == "advanced" then
            if focus == "input" then
                if showAdvancedIn then b.text = "Advanced Inputs"; vis[#vis + 1] = b end
            else
                if showAdvancedOut then b.text = "Advanced Outputs"; vis[#vis + 1] = b end
            end
        else
            vis[#vis + 1] = b
        end
    end
    self:applyFooterButtons(vis)
end

-- The footer's single Advanced button dispatches by which list last had focus.
function DistributionStoragePage:onAdvancedContextual()
    if (self._focusRole or "output") == "input" then
        if self.onAdvancedInputs ~= nil then self:onAdvancedInputs() end
    else
        if self.onAdvanced ~= nil then self:onAdvanced() end
    end
end

function DistributionStoragePage:onCycleSelected()
    local row = self:selectedDetailRow()
    if row == nil or self.selectedAsset == nil then return end
    local cur = SmartDistribution.resolvedAssetMode(self.selectedAsset, row.ft)
    local nxt = (SmartDistribution.cycleNextForAsset and SmartDistribution.cycleNextForAsset(self.selectedAsset, cur, row.ft))
                or SmartDistribution.cycleNext(cur)
    SmartDistribution.applyAssetMode(self.selectedAsset, row.ft, nxt)
    if self.detailList ~= nil then self.detailList:reloadData() end
    self:updateSellTimingButton()
end

-- footer "Advanced Outputs": granular routing for this building (rank demands, block one, pick stores)
function DistributionStoragePage:onAdvanced()
    if self.selectedAsset == nil or SmartDistribution.openAdvancedDialog == nil then return end
    local row = self:selectedDetailRow()
    if row == nil or row.ft == nil then return end
    SmartDistribution.openAdvancedDialog(self.selectedAsset, row.ft)
end

-- footer "Advanced Inputs": receiver-side block + per-product max %% for this building
function DistributionStoragePage:onAdvancedInputs()
    if self.selectedAsset == nil or SmartDistribution.openInputsDialog == nil then return end
    SmartDistribution.openInputsDialog(self.selectedAsset)
end

function DistributionStoragePage:onSellTiming()
    local row = self:selectedDetailRow()
    if row == nil or self.selectedAsset == nil or SmartDistribution.toggleSellTiming == nil then return end
    if not SmartDistribution.toggleSellTiming(self.selectedAsset, row.ft) then return end
    if self.detailList ~= nil then self.detailList:reloadData() end
    self:updateSellTimingButton()
end

-- The shared CANCEL footer slot dispatches to Spawn (a ready Hold Internal pallet output) or Sell Timing.
function DistributionStoragePage:onSellTimingOrSpawn()
    local row = self:selectedDetailRow()
    if row == nil or row.ft == nil or self.selectedAsset == nil then return end
    if SmartDistribution.palletSpawnReady ~= nil and SmartDistribution.palletSpawnReady(self.selectedAsset, row.ft) then
        self:onSpawn()
    else
        self:onSellTiming()
    end
end

-- Spawn `count` pallet(s) of the selected Hold Internal output from its internal buffer (MP-safe via the
-- event). Opens the shared count pop-up; the completion hook refreshes this page as each pallet fills.
function DistributionStoragePage:onSpawn(count)
    local row = self:selectedDetailRow()
    if row == nil or row.ft == nil or self.selectedAsset == nil then return end
    local page, asset, ft = self, self.selectedAsset, row.ft
    local function refreshHook()
        SmartDistribution._spawnCompleteCb = function()
            pcall(function()
                -- the husbandry layout has no detailList (inputs/outputs are split lists); reload whatever exists
                if page.detailList ~= nil then page.detailList:reloadData() end
                if page.outputList ~= nil then page.outputList:reloadData() end
                page:updateSellTimingButton()
            end)
        end
    end
    if SmartDistribution.openSpawnDialog ~= nil and SmartDistribution.openSpawnDialog(asset, ft, function(_, n)
            if DistributionSpawnEvent ~= nil and DistributionSpawnEvent.request ~= nil then
                refreshHook()
                DistributionSpawnEvent.request(asset, ft, n)
            end
        end) then
        return
    end
    if DistributionSpawnEvent ~= nil and DistributionSpawnEvent.request ~= nil then
        refreshHook()
        DistributionSpawnEvent.request(asset, ft, count or 1)
    end
end

-- [ + gaze entry: jump the building list to a specific placeable and select it
-- (called right after this tab is switched to, so the list is already populated).
function DistributionStoragePage:selectPlaceable(placeable)
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

-- ---- tab variants: the same master-detail page, filtered to one asset class --
-- Animal Husbandry tab (barns / pens / coops + beehive honey spawners).
DistributionAnimalHusbandryPage = {}
local DistributionAnimalHusbandryPage_mt = Class(DistributionAnimalHusbandryPage, DistributionStoragePage)
function DistributionAnimalHusbandryPage.new(target, custom_mt)
    local self = DistributionStoragePage.new(target, custom_mt or DistributionAnimalHusbandryPage_mt)
    self.pageName = "DISTREDUX_HUSBANDRY"
    self.classFilter = { HUSBANDRY = true }   -- barns / pens only (manure heaps + slurry pits are storage -> Silos tab)
    self.inputRows = {}
    self.outputRows = {}
    return self
end

-- two detail lists: INPUTS (demand) on top, OUTPUTS on the bottom.
function DistributionAnimalHusbandryPage:onGuiSetupFinished()
    DistributionStoragePage.onGuiSetupFinished(self)   -- sets up assetList (this layout has no detailList)
    if self.inputList ~= nil then
        self.inputList:setDataSource(self); self.inputList:setDelegate(self)
    end
    if self.outputList ~= nil then
        self.outputList:setDataSource(self); self.outputList:setDelegate(self)
    end
    -- rows that fit each frame at the 42px SDListItemStats pitch (280/42 = 6, 340/42 = 8)
    self._scrollMap = { { "inputSlider", "inputList", 6 }, { "outputSlider", "outputList", 8 } }
end

-- This layout's output rows live in outputList (there is no detailList), so the inherited onFrameOpen's
-- realtime set { inputList, detailList } never refreshes the output side -- husbandry distributed/sold/held
-- would sit stale between selections. Re-point the realtime set at outputList after super runs. Output cells
-- read all figures live in populateCellForItemInSection, so a plain reloadData refreshes them; no
-- rebuildRealtimeData needed. Safe from focus-stealing now that refreshRealtimeLists holds the _focusing guard.
function DistributionAnimalHusbandryPage:onFrameOpen()
    DistributionStoragePage.onFrameOpen(self)
    self._realtimeLists = { "inputList", "outputList" }
end

function DistributionAnimalHusbandryPage:buildDetailRows()
    self.inputRows = {}
    self.outputRows = {}
    local asset = self.selectedAsset
    if asset == nil or SmartDistribution == nil then return end
    if SmartDistribution.husbandryInputFillTypes ~= nil then
        local ins = {}
        for ft in pairs(SmartDistribution.husbandryInputFillTypes(asset)) do ins[#ins + 1] = ft end
        table.sort(ins)
        self.inputRows = buildProductRows(asset, ins)
    end
    if SmartDistribution.husbandryOutputSet ~= nil then
        local outs = {}
        for ft in pairs(SmartDistribution.husbandryOutputSet(asset)) do outs[#outs + 1] = ft end
        table.sort(outs)
        self.outputRows = buildProductRows(asset, outs)
    end
end

function DistributionAnimalHusbandryPage:selectAsset(index)
    local a = self.assets[index]
    self.selectedAsset = a ~= nil and a.placeable or nil
    if self.assetTitleElement ~= nil then
        self.assetTitleElement:setText(a ~= nil and (a.name or ""):upper() or "")
    end
    self:buildDetailRows()
    self.detailIndex = 1
    if self.inputList ~= nil then self.inputList:reloadData() end
    if self.outputList ~= nil then self.outputList:reloadData() end
    self:updateSellTimingButton()
end

function DistributionAnimalHusbandryPage:getNumberOfItemsInSection(list, section)
    if list == self.assetList then return #self.assets end
    if list == self.inputList then return #self.inputRows end
    if list == self.outputList then return #self.outputRows end
    return 0
end

function DistributionAnimalHusbandryPage:populateCellForItemInSection(list, section, index, cell)
    if list == self.assetList then
        return DistributionStoragePage.populateCellForItemInSection(self, list, section, index, cell)
    end
    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end
    local function setIcon(ft)
        local ic = cell:getAttribute("fillIcon")
        if ic == nil then return end
        local file = fillIconFile(ft)
        if file ~= nil and file ~= "" and ic.setImageFilename ~= nil then
            ic:setImageFilename(file); ic:setVisible(true)
        else
            ic:setVisible(false)
        end
    end

    if list == self.inputList then
        local row = self.inputRows[index]; if row == nil then return end
        if row.notice ~= nil then renderNoticeRow(cell, row.notice, "inputs"); return end
        hideNoticeRow(cell)
        applyRowHighlight(cell, (self._focusRole or "output") == "input")
        setIcon(row.ft); setc("fillName", row.name)
        local e = self:windowStats(row.ft)
        local held = (SmartDistribution.husbandryInputHeld ~= nil) and SmartDistribution.husbandryInputHeld(self.selectedAsset, row.ft) or 0
        setc("recvText", fmtV(e.received))
        setc("consumedText", fmtV(e.consumed))
        setc("heldText", heldOfMaxText(self.selectedAsset, row.ft, held))
        setRemainingCell(cell, inputRemaining(self.selectedAsset, row.ft), inputMaxLiters(self.selectedAsset, row.ft))
        setStatusCell(cell, self.selectedAsset, row.ft)
    elseif list == self.outputList then
        local row = self.outputRows[index]; if row == nil then return end
        if row.notice ~= nil then renderNoticeRow(cell, row.notice, "outputs"); return end
        hideNoticeRow(cell)
        applyRowHighlight(cell, (self._focusRole or "output") ~= "input")
        setIcon(row.ft); setc("fillName", row.name)
        local e = self:windowStats(row.ft)
        local held = (SmartDistribution.assetHeld ~= nil) and SmartDistribution.assetHeld(self.selectedAsset, row.ft) or 0
        setc("prodText", fmtV(e.produced))
        setc("distText", outTotalText(e))
        setc("heldText", heldWithPallets(self.selectedAsset, row.ft, held))
        setRemainingCell(cell, outputRemaining(self.selectedAsset, row.ft, held))
        local modeCell = cell:getAttribute("modeText")
        if modeCell ~= nil then
            -- palletizable flag passed so a pallet output reads "Hold Pallets" rather than a bare "Hold",
        -- matching the Productions tab for the same pair of modes
        local pal = (SmartDistribution.holdLabelFlag ~= nil)
            and SmartDistribution.holdLabelFlag(self.selectedAsset, row.ft) or false
        local text = SmartDistribution.modeName(SmartDistribution.resolvedAssetMode(self.selectedAsset, row.ft), pal)
            local timing = (SmartDistribution.sellTimingLabel ~= nil)
                and SmartDistribution.sellTimingLabel(self.selectedAsset, row.ft) or nil
            if timing ~= nil then text = text .. "  -  " .. timing end
            modeCell:setText(text)
        end
        setOutputStatusCell(cell, self.selectedAsset, row.ft)
    end
end

function DistributionAnimalHusbandryPage:onListSelectionChanged(list, section, index)
    if list == self.assetList then
        self:selectAsset(index)
    elseif list == self.outputList then
        self.detailIndex = index   -- outputs carry the sell mode; the footer acts on the selected output
        self:_focusOn("output")
        self:updateSellTimingButton()
    elseif list == self.inputList then
        self.inputIndex = index
        self:_focusOn("input")
        self:updateSellTimingButton()
    end
end

-- selecting an input row switches the footer's Advanced button to the input (Advanced Inputs) context.
function DistributionAnimalHusbandryPage:onInputSelectionChanged(list, section, index)
    self.inputIndex = index
    self:_focusOn("input")
    self:updateSellTimingButton()
end

-- husbandry's output side is outputList (not detailList), so it needs its own focus swap.
function DistributionAnimalHusbandryPage:_focusOn(role)
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

function DistributionAnimalHusbandryPage:onClickInputRow(element) end
function DistributionAnimalHusbandryPage:onClickOutputRow(element) end

-- footer mode / sell-timing actions operate on the selected OUTPUT row (inputs are demand-only)
function DistributionAnimalHusbandryPage:selectedDetailRow()
    local r = self.outputRows[self.detailIndex or 1]
    if r ~= nil and r.notice ~= nil then return nil end
    return r
end

-- the base footer handlers reload self.detailList (absent in this layout); refresh the output list instead
function DistributionAnimalHusbandryPage:onCycleSelected()
    DistributionStoragePage.onCycleSelected(self)
    if self.outputList ~= nil then self.outputList:reloadData() end
end
function DistributionAnimalHusbandryPage:onSellTiming()
    DistributionStoragePage.onSellTiming(self)
    if self.outputList ~= nil then self.outputList:reloadData() end
end

-- ---- Markets tab: owned sell points (kiosks / farmers markets) --------------
-- Same master-detail shell, but the detail list shows each accepted item's buffer,
-- distributed-in and sold /mo, and the mode is locked to Sell with a per-market
-- Immediate / Best-price timing toggle (footer "Timing").
DistributionMarketsPage = {}
local DistributionMarketsPage_mt = Class(DistributionMarketsPage, DistributionStoragePage)
function DistributionMarketsPage.new(target, custom_mt)
    local self = DistributionStoragePage.new(target, custom_mt or DistributionMarketsPage_mt)
    self.pageName = "DISTREDUX_MARKETS"
    self.classFilter = { MARKET = true }
    return self
end

function DistributionMarketsPage:buildDetailRows()
    self.rows = {}
    local asset = self.selectedAsset
    if asset == nil or SmartDistribution == nil or SmartDistribution.marketMenuFillTypes == nil then return end
    local ordered = {}
    for ft in pairs(SmartDistribution.marketMenuFillTypes(asset)) do ordered[#ordered + 1] = ft end
    table.sort(ordered)
    self.rows = buildProductRows(asset, ordered)
end

function DistributionMarketsPage:populateCellForItemInSection(list, section, index, cell)
    if list == self.assetList then
        return DistributionStoragePage.populateCellForItemInSection(self, list, section, index, cell)
    end
    local row = self.rows[index]
    if row == nil then return end
    if row.notice ~= nil then
        renderNoticeRow(cell, row.notice, (list == self.inputList) and "inputs" or "outputs")
        return
    end
    hideNoticeRow(cell)
    local iconCell = cell:getAttribute("fillIcon")
    if iconCell ~= nil then
        local file = fillIconFile(row.ft)
        if file ~= nil and file ~= "" and iconCell.setImageFilename ~= nil then
            iconCell:setImageFilename(file); iconCell:setVisible(true)
        else
            iconCell:setVisible(false)
        end
    end
    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end
    -- INCOMING view: what the market is receiving, with the distribution link status
    if list == self.inputList then
        setc("fillName", row.name)
        local e = self:windowStats(row.ft)
        local buffer = (SmartDistribution.marketBufferOf ~= nil) and SmartDistribution.marketBufferOf(self.selectedAsset, row.ft) or 0
        setc("recvText", fmtV(e.received))
        -- was the bare held figure, with no ceiling beside it -- the one input list in the mod that did not
        -- say what it could take. A market resolves through inputProductCapacity -> marketCap like any other
        -- receiver (5.36), so the shared helper works here and the column now matches every other tab.
        setc("heldText", heldOfMaxText(self.selectedAsset, row.ft, buffer))
        setRemainingCell(cell, inputRemaining(self.selectedAsset, row.ft), inputMaxLiters(self.selectedAsset, row.ft))
        setStatusCell(cell, self.selectedAsset, row.ft)
        return
    end
    setc("fillName", row.name)
    local buffer = (SmartDistribution.marketBufferOf ~= nil) and SmartDistribution.marketBufferOf(self.selectedAsset, row.ft) or 0
    -- HELD (MAX), the same bracket form every other OUTGOING list uses -- this was the last "a / b" ratio left
    setc("heldText", fmtV(buffer) .. " ("
        .. fmtV((SmartDistribution.marketCap ~= nil and SmartDistribution.marketCap(self.selectedAsset))
               or SmartDistribution.MARKET_CAP or 200000) .. ")")
    setc("distText", outTotalText(self:windowStats(row.ft)))
    local modeCell = cell:getAttribute("modeText")
    if modeCell ~= nil then
        modeCell:setText((SmartDistribution.marketProductLabel ~= nil)
            and SmartDistribution.marketProductLabel(self.selectedAsset, row.ft) or "Sell  -  Immediate")
    end
end

-- footer "Change Output": toggle the selected product between Sell and Hold
function DistributionMarketsPage:onCycleSelected()
    local row = self:selectedDetailRow()
    if self.selectedAsset == nil or row == nil or SmartDistribution.marketToggleOutput == nil then return end
    SmartDistribution.marketToggleOutput(self.selectedAsset, row.ft)
    if self.detailList ~= nil then self.detailList:reloadData() end
    self:updateTimingButton()
end

-- footer "Sell Type": toggle the selected product between Immediate and Best price
function DistributionMarketsPage:onSellTiming()
    local row = self:selectedDetailRow()
    if self.selectedAsset == nil or row == nil or SmartDistribution.marketToggleSellType == nil then return end
    SmartDistribution.marketToggleSellType(self.selectedAsset, row.ft)
    if self.detailList ~= nil then self.detailList:reloadData() end
    self:updateTimingButton()
end

-- reflect the selected product's sell type on the footer "Sell Type" button
function DistributionMarketsPage:updateTimingButton()
    local all = self._allButtons
    if all == nil then return end
    local row = self:selectedDetailRow()
    local label = (self.selectedAsset ~= nil and row ~= nil and SmartDistribution.marketSellTypeLabel ~= nil)
        and SmartDistribution.marketSellTypeLabel(self.selectedAsset, row.ft) or nil
    local vis = {}
    for _, b in ipairs(all) do
        if b._role == "sellTiming" then
            if label ~= nil then b.text = "Sell Timing: " .. label; vis[#vis + 1] = b end   -- hidden while the product is Held
        elseif b._role == "advanced" then
            -- A market is the exact OPPOSITE of what this used to say ("sell endpoints (no inputs)"): its
            -- buffer never feeds the network back (5.7), so there is no outgoing routing to arrange, while
            -- every source on the farm delivers INTO it. So the Advanced button always means Advanced
            -- Inputs here -- unconditionally, not contextually, since there is no output side to switch to.
            -- Hidden when the Advanced routing master switch (Settings) is off, or when the market resolves
            -- no input fill types at all.
            local advOK = SmartDistribution.advancedEnabled == nil or SmartDistribution.advancedEnabled()
            local hasIn = self.selectedAsset ~= nil and SmartDistribution.receiverInputFillTypes ~= nil
                and next(SmartDistribution.receiverInputFillTypes(self.selectedAsset)) ~= nil
            if advOK and hasIn then
                b.text = "Advanced Inputs"; vis[#vis + 1] = b
            end
        else
            vis[#vis + 1] = b
        end
    end
    self:applyFooterButtons(vis)
end
-- selectAsset() (inherited) calls updateSellTimingButton; route it to our button refresh
function DistributionMarketsPage:updateSellTimingButton()
    self:updateTimingButton()
end

-- The inherited handler dispatches on _focusRole (input list vs output list). A market has only one
-- meaningful destination for that button, so send it straight there rather than depending on which list
-- the player happened to touch last.
function DistributionMarketsPage:onAdvancedContextual()
    if self.onAdvancedInputs ~= nil then self:onAdvancedInputs() end
end
