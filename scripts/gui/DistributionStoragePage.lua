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

-- "<liters>  (<money>)" for the SOLD /mo column; money omitted when zero/unknown (e.g. MP clients)
local function soldWithMoney(liters, money)
    local base = fmt(liters)
    if money ~= nil and money > 0.5 and SmartDistribution ~= nil and SmartDistribution.formatMoneyShort ~= nil then
        return base .. "  (" .. SmartDistribution.formatMoneyShort(money) .. ")"
    end
    return base
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
    local pct = 100
    if SmartDistribution.inputCapPct ~= nil then
        local ok, v = pcall(SmartDistribution.inputCapPct, placeable, ft)
        if ok and type(v) == "number" then pct = v end
    end
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return cap * pct / 100
end

-- "12,345 L / 50,000 L" for an input row; drops the denominator when it can't be resolved.
local function heldOfMaxText(placeable, ft, held)
    local maxL = inputMaxLiters(placeable, ft)
    if maxL == nil then return fmt(held) .. " L" end
    return fmt(held) .. " L / " .. fmt(maxL) .. " L"
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
    self._scrollMap = { { "detailSlider", "detailList", 13 }, { "inputSlider", "inputList", 13 } }   -- hide the scrollbar track unless the list overflows its frame
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
    for _, ft in ipairs(ordered) do
        self.rows[#self.rows + 1] = { ft = ft, name = fillTypeTitle(ft) }
    end
end

function DistributionStoragePage:selectAsset(index)
    local a = self.assets[index]
    self.selectedAsset = a ~= nil and a.placeable or nil
    if self.assetTitleElement ~= nil then
        self.assetTitleElement:setText(a ~= nil and (a.name or ""):upper() or "")
    end
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
        local recv = (SmartDistribution.monthlyReceived ~= nil) and SmartDistribution.monthlyReceived(self.selectedAsset, row.ft) or 0
        local held = (SmartDistribution.assetHeld ~= nil) and SmartDistribution.assetHeld(self.selectedAsset, row.ft) or 0
        setc("recvText", fmt(recv))
        setc("heldText", heldOfMaxText(self.selectedAsset, row.ft, held))
        setStatusCell(cell, self.selectedAsset, row.ft)
        return
    end

    applyRowHighlight(cell, (self._focusRole or "output") ~= "input")
    setc("fillName", row.name)

    local held = (SmartDistribution.assetHeld ~= nil) and SmartDistribution.assetHeld(self.selectedAsset, row.ft) or 0
    local d, s, st, mo = 0, 0, 0, 0
    if SmartDistribution.monthlyStats ~= nil then
        d, s, st, mo = SmartDistribution.monthlyStats(self.selectedAsset, row.ft)
    end
    setc("heldText",  fmt(held))
    setc("distText",  fmt(d))
    setc("soldText",  soldWithMoney(s, mo))
    setc("storedText", fmt(st))

    local modeCell = cell:getAttribute("modeText")
    if modeCell ~= nil then
        local text = SmartDistribution.modeName(SmartDistribution.resolvedAssetMode(self.selectedAsset, row.ft))
        local timing = (SmartDistribution.sellTimingLabel ~= nil)
            and SmartDistribution.sellTimingLabel(self.selectedAsset, row.ft) or nil
        if timing ~= nil then text = text .. "  -  " .. timing end
        modeCell:setText(text)
    end
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
    return self.rows[self.detailIndex or 1]
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
    local showAdvancedOut = row ~= nil and row.ft ~= nil and self.selectedAsset ~= nil
        and SmartDistribution.modeConfigurable ~= nil
        and SmartDistribution.modeConfigurable(self.selectedAsset, row.ft)
    local showAdvancedIn = self.selectedAsset ~= nil and SmartDistribution.receiverInputFillTypes ~= nil
        and next(SmartDistribution.receiverInputFillTypes(self.selectedAsset)) ~= nil
    local vis = {}
    for _, b in ipairs(all) do
        if b._role == "sellTiming" then
            if label ~= nil then b.text = "Sell Timing: " .. label; vis[#vis + 1] = b end
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
    self._scrollMap = { { "inputSlider", "inputList", 5 }, { "outputSlider", "outputList", 6 } }
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
        for _, ft in ipairs(ins) do self.inputRows[#self.inputRows + 1] = { ft = ft, name = fillTypeTitle(ft) } end
    end
    if SmartDistribution.husbandryOutputSet ~= nil then
        local outs = {}
        for ft in pairs(SmartDistribution.husbandryOutputSet(asset)) do outs[#outs + 1] = ft end
        table.sort(outs)
        for _, ft in ipairs(outs) do self.outputRows[#self.outputRows + 1] = { ft = ft, name = fillTypeTitle(ft) } end
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
        applyRowHighlight(cell, (self._focusRole or "output") == "input")
        setIcon(row.ft); setc("fillName", row.name)
        local recv = (SmartDistribution.monthlyReceived ~= nil) and SmartDistribution.monthlyReceived(self.selectedAsset, row.ft) or 0
        local cons = (SmartDistribution.monthlyConsumed ~= nil) and SmartDistribution.monthlyConsumed(self.selectedAsset, row.ft) or 0
        local held = (SmartDistribution.husbandryInputHeld ~= nil) and SmartDistribution.husbandryInputHeld(self.selectedAsset, row.ft) or 0
        local cap  = (SmartDistribution.husbandryInputCapacity ~= nil) and SmartDistribution.husbandryInputCapacity(self.selectedAsset, row.ft) or 0
        setc("recvText", fmt(recv))
        setc("consumedText", fmt(cons))
        setc("heldText", heldOfMaxText(self.selectedAsset, row.ft, held))
        setStatusCell(cell, self.selectedAsset, row.ft)
    elseif list == self.outputList then
        local row = self.outputRows[index]; if row == nil then return end
        applyRowHighlight(cell, (self._focusRole or "output") ~= "input")
        setIcon(row.ft); setc("fillName", row.name)
        local prod = (SmartDistribution.monthlyProduced ~= nil) and SmartDistribution.monthlyProduced(self.selectedAsset, row.ft) or 0
        local d, s, st, mo = 0, 0, 0, 0
        if SmartDistribution.monthlyStats ~= nil then d, s, st, mo = SmartDistribution.monthlyStats(self.selectedAsset, row.ft) end
        local held = (SmartDistribution.assetHeld ~= nil) and SmartDistribution.assetHeld(self.selectedAsset, row.ft) or 0
        setc("prodText",   fmt(prod))
        setc("distText",   fmt(d))
        setc("storedText", fmt(st))
        setc("soldText",   soldWithMoney(s, mo))
        setc("heldText",   fmt(held))
        local modeCell = cell:getAttribute("modeText")
        if modeCell ~= nil then
            local text = SmartDistribution.modeName(SmartDistribution.resolvedAssetMode(self.selectedAsset, row.ft))
            local timing = (SmartDistribution.sellTimingLabel ~= nil)
                and SmartDistribution.sellTimingLabel(self.selectedAsset, row.ft) or nil
            if timing ~= nil then text = text .. "  -  " .. timing end
            modeCell:setText(text)
        end
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
    return self.outputRows[self.detailIndex or 1]
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
    for _, ft in ipairs(ordered) do
        self.rows[#self.rows + 1] = { ft = ft, name = fillTypeTitle(ft) }
    end
end

function DistributionMarketsPage:populateCellForItemInSection(list, section, index, cell)
    if list == self.assetList then
        return DistributionStoragePage.populateCellForItemInSection(self, list, section, index, cell)
    end
    local row = self.rows[index]
    if row == nil then return end
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
        local recv   = (SmartDistribution.monthlyReceived ~= nil) and SmartDistribution.monthlyReceived(self.selectedAsset, row.ft) or 0
        local buffer = (SmartDistribution.marketBufferOf ~= nil) and SmartDistribution.marketBufferOf(self.selectedAsset, row.ft) or 0
        setc("recvText", fmt(recv))
        setc("heldText", fmt(buffer))
        setStatusCell(cell, self.selectedAsset, row.ft)
        return
    end
    setc("fillName", row.name)
    local buffer = (SmartDistribution.marketBufferOf ~= nil) and SmartDistribution.marketBufferOf(self.selectedAsset, row.ft) or 0
    local recv   = (SmartDistribution.monthlyReceived ~= nil) and SmartDistribution.monthlyReceived(self.selectedAsset, row.ft) or 0
    local _, sold, _, mo = 0, 0, 0, 0
    if SmartDistribution.monthlyStats ~= nil then _, sold, _, mo = SmartDistribution.monthlyStats(self.selectedAsset, row.ft) end
    setc("heldText", fmt(buffer) .. " / " .. fmt((SmartDistribution.marketCap ~= nil and SmartDistribution.marketCap(self.selectedAsset)) or SmartDistribution.MARKET_CAP or 200000))
    setc("distText", fmt(recv))
    setc("soldText", soldWithMoney(sold, mo))
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
            -- markets are sell endpoints (no inputs): the Advanced button always means Advanced Outputs
            b.text = "Advanced Outputs"; vis[#vis + 1] = b
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
