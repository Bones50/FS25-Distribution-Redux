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
-- (rolling 24-cycle). Engine seams: productionLines, monthlyStats/Received,
-- cycleProductionOutput, setProductionLineEnabled, applyAssetSellTiming.
-- ============================================================================

DistributionProductionsPage = {}
local DistributionProductionsPage_mt = Class(DistributionProductionsPage, DistributionMenuPage)

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

-- "<liters>  (<money>)" for the SOLD /mo column; money omitted when zero/unknown
local function soldWithMoney(liters, money)
    local base = fmt(liters)
    if money ~= nil and money > 0.5 and SmartDistribution ~= nil and SmartDistribution.formatMoneyShort ~= nil then
        return base .. "  (" .. SmartDistribution.formatMoneyShort(money) .. ")"
    end
    return base
end

-- "held L / cap L" (or just "held L" when capacity is unknown)
local function amountText(held, cap)
    if cap ~= nil and cap > 0 then return fmt(held) .. " L / " .. fmt(cap) .. " L" end
    return fmt(held) .. " L"
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
    local pct = 100
    if SmartDistribution.inputCapPct ~= nil then
        local okP, v = pcall(SmartDistribution.inputCapPct, placeable, ft)
        if okP and type(v) == "number" then pct = v end
    end
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return cap * pct / 100
end

-- Distribution status of an input row (Active (Receiving) / Active (Idle) / Blocked). The label set is
-- shared in SmartDistribution so every building category reads identically.
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

-- OUTGOING (source-side) status for an output row: Active (Sending) / Active (Idle) / Blocked, same colours.
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
    self._scrollMap = { { "inputSlider", "inputList", 5 }, { "lineSlider", "lineList", 5 }, { "outputSlider", "outputList", 6 } }
end

function DistributionProductionsPage:rebuildAssets()
    self.assets = {}
    if SmartDistribution == nil or SmartDistribution.enumerateConfigurableAssets == nil then return end
    for _, a in ipairs(SmartDistribution.enumerateConfigurableAssets()) do
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
            if not inSeen[i.ft] and (activeIn[i.ft] or (i.held or 0) > 0) then
                inSeen[i.ft] = true
                self.inputs[#self.inputs + 1] = { ft = i.ft, name = i.name, held = i.held or 0, capacity = i.capacity }
            end
        end
    end
    for _, i in ipairs(self.inputs) do
        i.received = (SmartDistribution.monthlyReceived ~= nil) and SmartDistribution.monthlyReceived(p, i.ft) or 0
        i.consumed = (SmartDistribution.monthlyConsumed ~= nil) and SmartDistribution.monthlyConsumed(p, i.ft) or 0
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
        if label == "" then label = line.name or ("Line " .. tostring(#self.lines + 1)) end
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
            if not ftSeen[o.ft] and (activeOut[o.ft] or (o.held or 0) > 0) then
                ftSeen[o.ft] = true
                local d, s, st, mo = 0, 0, 0, 0
                if SmartDistribution.monthlyStats ~= nil then d, s, st, mo = SmartDistribution.monthlyStats(p, o.ft) end
                self.outputs[#self.outputs + 1] = {
                    ft = o.ft, name = o.name, held = o.held or 0, capacity = o.capacity,
                    dist = d, sold = s, storedMo = st, money = mo,
                    produced = (SmartDistribution.monthlyProduced ~= nil) and SmartDistribution.monthlyProduced(p, o.ft) or 0,
                    modeName = o.modeName,
                    sellTiming = (SmartDistribution.sellTimingLabel ~= nil) and SmartDistribution.sellTimingLabel(p, o.ft) or nil,
                }
            end
        end
    end
end

function DistributionProductionsPage:selectAsset(index)
    local a = self.assets[index]
    self.selectedAsset = a ~= nil and a.placeable or nil
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

function DistributionProductionsPage:onFrameOpen()
    DistributionProductionsPage:superClass().onFrameOpen(self)
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
        applyRowHighlight(cell, (self._focusRole or "output") == "input")
        setc("name", inp.name)
        setc("received", fmt(inp.received))
        setc("consumed", fmt(inp.consumed))
        -- capacity shown is the Advanced Inputs %-adjusted max; fall back to the raw buffer if unresolved
        local maxL = inputMaxLiters(self.selectedAsset, inp.ft)
        setc("amount", maxL ~= nil and (fmt(inp.held) .. " L / " .. fmt(maxL) .. " L")
                                    or amountText(inp.held, inp.capacity))
        setStatusCell(cell, self.selectedAsset, inp.ft)
        setIcon(cell, inp.ft)
        return
    end

    if list == self.lineList then
        local ln = self.lines[index]
        if ln == nil then return end
        setc("name", ln.name)
        setc("status", ln.status or "")
        setc("prodMo", ln.enabled and fmt(ln.perMonth) or "")   -- PROD /mo only while the line is ON
        return
    end

    -- outputList
    local o = self.outputs[index]
    if o == nil then return end
    applyRowHighlight(cell, (self._focusRole or "output") ~= "input")
    setc("name", o.name)
    setc("produced", fmt(o.produced))
    setc("distr", fmt(o.dist))
    setc("storedCyc", fmt(o.storedMo))
    setc("sold", soldWithMoney(o.sold, o.money))
    setc("amount", amountText(o.held, o.capacity))
    local method = o.modeName or "-"
    if o.sellTiming ~= nil then method = method .. " - " .. o.sellTiming end
    setc("method", method)
    setOutputStatusCell(cell, self.selectedAsset, o.ft)
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
    return self.outputs[self.outputIndex or 1]
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
        and SmartDistribution.modeConfigurable(self.selectedAsset, o.ft)
    -- Advanced Inputs applies whenever the production has at least one input product to cap/block.
    local showAdvancedIn = adv and self.selectedAsset ~= nil and SmartDistribution.receiverInputFillTypes ~= nil
        and next(SmartDistribution.receiverInputFillTypes(self.selectedAsset)) ~= nil
    -- Single CONTEXTUAL Advanced button: input focus -> Advanced Inputs, else Advanced Outputs.
    local focus = self._focusRole or "output"
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


-- footer "Advanced Outputs": granular routing for the SELECTED output (demands / stores / markets per its mode)
function DistributionProductionsPage:onAdvanced()
    if self.selectedAsset == nil or SmartDistribution.openAdvancedDialog == nil then return end
    local o = self:selectedOutput()
    if o == nil or o.ft == nil then return end
    SmartDistribution.openAdvancedDialog(self.selectedAsset, o.ft)
end

-- footer "Advanced Inputs": receiver-side block + per-product max %% for this production's inputs
function DistributionProductionsPage:onAdvancedInputs()
    if self.selectedAsset == nil or SmartDistribution.openInputsDialog == nil then return end
    SmartDistribution.openInputsDialog(self.selectedAsset)
end

-- Sell Timing: flip best-price/immediate for the selected OUTPUT (if it's a sell mode).
function DistributionProductionsPage:onSellTiming()
    local o = self:selectedOutput()
    if o == nil or o.ft == nil or self.selectedAsset == nil then return end
    if SmartDistribution.sellTimingLabel == nil
        or SmartDistribution.sellTimingLabel(self.selectedAsset, o.ft) == nil then return end
    local mode = SmartDistribution.resolvedAssetMode(self.selectedAsset, o.ft)
    local target = not SmartDistribution.resolveBestPrice(self.selectedAsset, o.ft, mode)
    SmartDistribution.applyAssetSellTiming(self.selectedAsset, o.ft, target)
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
    if SmartDistribution.openSpawnDialog ~= nil and SmartDistribution.openSpawnDialog(asset, ft, function(option, n)
            if DistributionSpawnEvent ~= nil and DistributionSpawnEvent.request ~= nil then
                SmartDistribution._spawnCompleteCb = function() pcall(function() page:refreshSections() end) end
                DistributionSpawnEvent.request(asset, ft, n)
            end
        end) then
        return
    end
    -- fallback (dialog unavailable): spawn one directly
    if DistributionSpawnEvent ~= nil and DistributionSpawnEvent.request ~= nil then
        SmartDistribution._spawnCompleteCb = function() pcall(function() page:refreshSections() end) end
        DistributionSpawnEvent.request(asset, ft, count or 1)
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
