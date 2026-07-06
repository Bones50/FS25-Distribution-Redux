-- ============================================================================
-- DistributionStoragePage.lua  (Distribution Redux) -- Storage tab
-- Master-detail reproduction of the manager + Asset (silo) dialog:
--   left  list (assetList)  : silos / barns / sheds / heaps you can configure
--   right list (detailList) : the selected building's per-product rows
--                             (icon / held / distr / sold / stored / mode+timing)
-- Footer buttons (real keys via the menu's setMenuButtonInfo): Cycle Selected,
-- Cycle All, Sell Timing. All actions reuse the existing engine seams, so this
-- is a new view over the same logic the popup uses.
-- ============================================================================

DistributionStoragePage = {}
local DistributionStoragePage_mt = Class(DistributionStoragePage, DistributionMenuPage)

local STORAGE_CLASSES = { SILO = "Silo", HUSBANDRY = "Barn", SHED = "Storage", HEAP = "Pit" }

-- integer liters with thousands separators
local function fmt(n)
    n = math.floor((n or 0) + 0.5)
    local s = tostring(n)
    local k
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
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

function DistributionStoragePage.new(target, custom_mt)
    local self = DistributionMenuPage.new(target, custom_mt or DistributionStoragePage_mt)
    self.pageName = "DISTREDUX_STORAGE"
    self.classFilter = { SILO = true, SHED = true }   -- Silos tab (default); subclasses override
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
    if self.detailList ~= nil then
        self.detailList:reloadData()
        if self.detailList.setSelectedIndex ~= nil then
            pcall(function() self.detailList:setSelectedIndex(1) end)
        end
    end
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
    return #self.rows
end

function DistributionStoragePage:populateCellForItemInSection(list, section, index, cell)
    if list == self.assetList then
        local a = self.assets[index]
        if a == nil then return end
        local nameCell = cell:getAttribute("assetName")
        if nameCell ~= nil then nameCell:setText(a.name or "?") end
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

    setc("fillName", row.name)

    local held = (SmartDistribution.assetHeld ~= nil) and SmartDistribution.assetHeld(self.selectedAsset, row.ft) or 0
    local d, s, st = 0, 0, 0
    if SmartDistribution.monthlyStats ~= nil then
        d, s, st = SmartDistribution.monthlyStats(self.selectedAsset, row.ft)
    end
    setc("heldText",  fmt(held))
    setc("distText",  fmt(d))
    setc("soldText",  fmt(s))
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
        self:updateSellTimingButton()
    end
end

function DistributionStoragePage:onClickAsset(element) end
function DistributionStoragePage:onClickDetailRow(element) end

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

-- reflect the selected product's sell timing on the footer button (like the old popup)
function DistributionStoragePage:updateSellTimingButton()
    if self.menuButtonInfo == nil then return end
    local label = self:currentSellTimingLabel()
    for _, b in ipairs(self.menuButtonInfo) do
        if b._role == "sellTiming" then
            b.text = (label ~= nil) and ("Sell Timing: " .. label) or "Sell Timing"
        end
    end
    if self.setMenuButtonInfoDirty ~= nil then self:setMenuButtonInfoDirty() end
end

function DistributionStoragePage:onCycleSelected()
    local row = self:selectedDetailRow()
    if row == nil or self.selectedAsset == nil then return end
    local cur = SmartDistribution.resolvedAssetMode(self.selectedAsset, row.ft)
    local nxt = (SmartDistribution.cycleNextForAsset and SmartDistribution.cycleNextForAsset(self.selectedAsset, cur))
                or SmartDistribution.cycleNext(cur)
    SmartDistribution.applyAssetMode(self.selectedAsset, row.ft, nxt)
    if self.detailList ~= nil then self.detailList:reloadData() end
    self:updateSellTimingButton()
end

function DistributionStoragePage:onCycleAll()
    if self.selectedAsset == nil or SmartDistribution.cycleAssetMode == nil then return end
    SmartDistribution.cycleAssetMode(self.selectedAsset)
    if self.detailList ~= nil then self.detailList:reloadData() end
    self:updateSellTimingButton()
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
    self.classFilter = { HUSBANDRY = true, HEAP = true }   -- barns + manure / slurry pits (pits ride with husbandry)
    return self
end
