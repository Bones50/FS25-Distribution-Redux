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

-- integer liters with thousands separators
local function fmt(n)
    n = math.floor((n or 0) + 0.5)
    local s = tostring(n)
    local k
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
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

    -- 1) inputs: aggregated per fill type
    local inSeen = {}
    for _, line in ipairs(lines) do
        for _, i in ipairs(line.inputs or {}) do
            if not inSeen[i.ft] then
                inSeen[i.ft] = true
                self.inputs[#self.inputs + 1] = { ft = i.ft, name = i.name, held = i.held or 0, capacity = i.capacity }
            end
        end
    end
    for _, i in ipairs(self.inputs) do
        i.received = (SmartDistribution.monthlyReceived ~= nil) and SmartDistribution.monthlyReceived(p, i.ft) or 0
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

    -- 3) outputs: one row per distinct output fill type (first occurrence carries held/cap/name)
    local ftSeen = {}
    for _, line in ipairs(lines) do
        for _, o in ipairs(line.outputs or {}) do
            if not ftSeen[o.ft] then
                ftSeen[o.ft] = true
                local d, s, st = 0, 0, 0
                if SmartDistribution.monthlyStats ~= nil then d, s, st = SmartDistribution.monthlyStats(p, o.ft) end
                self.outputs[#self.outputs + 1] = {
                    ft = o.ft, name = o.name, held = o.held or 0, capacity = o.capacity,
                    dist = d, sold = s, storedMo = st,
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
        setc("assetName", a.name or "?")
        if SmartDistribution.setAssetIcon ~= nil then SmartDistribution.setAssetIcon(cell, a.placeable) end
        return
    end

    if list == self.inputList then
        local inp = self.inputs[index]
        if inp == nil then return end
        setc("name", inp.name)
        setc("received", fmt(inp.received))
        setc("amount", amountText(inp.held, inp.capacity))
        setc("percent", percentText(inp.held, inp.capacity))
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
    setc("name", o.name)
    setc("distr", fmt(o.dist))
    setc("storedCyc", fmt(o.storedMo))
    setc("sold", fmt(o.sold))
    setc("amount", amountText(o.held, o.capacity))
    local method = o.modeName or "-"
    if o.sellTiming ~= nil then method = method .. " - " .. o.sellTiming end
    setc("method", method)
    setIcon(cell, o.ft)
end

function DistributionProductionsPage:onListSelectionChanged(list, section, index)
    if list == self.assetList then
        self:selectAsset(index)
    elseif list == self.lineList then
        self.lineIndex = index
    elseif list == self.outputList then
        self.outputIndex = index
        self:updateSellTimingButton()
    end
    -- inputList selection is ignored (display-only)
end

function DistributionProductionsPage:onClickAsset(element) end
function DistributionProductionsPage:onClickLineRow(element) end
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

-- reflect the selected OUTPUT's sell timing on the footer button
function DistributionProductionsPage:updateSellTimingButton()
    if self.menuButtonInfo == nil then return end
    local o = self:selectedOutput()
    local label = o ~= nil and o.sellTiming or nil
    for _, b in ipairs(self.menuButtonInfo) do
        if b._role == "sellTiming" then
            b.text = (label ~= nil) and ("Sell Timing: " .. label) or "Sell Timing"
        end
    end
    if self.setMenuButtonInfoDirty ~= nil then self:setMenuButtonInfoDirty() end
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
