-- ============================================================================
-- DistributionBiogasPage.lua  (Distribution Redux) -- the BIOGAS tab (CLAUDE.md 5.122)
--
-- Everywhere else a Pumps & Hoses biogas plant is ONE building (5.121 B): the fermenter's row speaks
-- for the bunker, the CHP, the tank and the torch together. That is right for routing and impossible to
-- read, so this tab takes the plant apart again. A selector picks the plant, the left list shows every
-- building in it, and each building is drawn with the template its type already has:
--
--   fermenter, CHP              -> the PRODUCTIONS page  (DistributionBiogasProductionPage)
--   feed bunker, tank, torch    -> the STORAGE page      (DistributionBiogasStoragePage)
--
-- TWO PAGES BEHIND ONE TAB. Both are real subclasses of the existing pages with their own layouts
-- (generated copies, tools/genbiogasxml.py), so every column, bar and figure is the existing code. They
-- share one selection (SmartDistribution._biogas): clicking a building of the other kind moves to the
-- other page with that building selected, so the pair behaves as one tab. The tab registry carries the
-- storage page as the production page's ALIAS, so the strip and the left list treat both as BIOGAS.
--
-- EACH BUILDING SHOWS ITS OWN STORAGE AND ITS OWN FLOWS. Every data call these pages make runs inside
-- SmartDistribution.withPlantLocal, which stops the fermenter folding its members' storages in and points
-- its figures at its own ledger key. The flows themselves are the per-piece ledger (flushPlantFlows).
--
-- MODES ON THREE BUILDINGS (5.123), everything else read only:
--   * the FERMENTER: its outputs' real modes (digestate on the normal ring; methane
--     on the production ring plus "Distribute across biogas plant", 5.124)
--   * the CHP: its electricity, Sell / Distribute + Sell, as on any biogas plant
--   * the liquid manure TANK: the full storage ring -- it is a source of its own now
-- The feed bunker and the torch carry no mode; their arrows are hidden and every action is a no-op.
-- The footer carries Back and "Plant overview", the routing graph drawn with the plant's buildings
-- in its middle column (DistributionRoutingDialog, plant view).
-- ============================================================================

DistributionBiogasProductionPage = {}
local DistributionBiogasProductionPage_mt = Class(DistributionBiogasProductionPage, DistributionProductionsPage)
DistributionBiogasStoragePage = {}
local DistributionBiogasStoragePage_mt = Class(DistributionBiogasStoragePage, DistributionStoragePage)

-- The one selection both pages share: which plant, and which of its buildings.
SmartDistribution._biogas = SmartDistribution._biogas or { root = nil, piece = nil }

function DistributionBiogasProductionPage.new(target, custom_mt)
    local self = DistributionProductionsPage.new(target, custom_mt or DistributionBiogasProductionPage_mt)
    self.pageName = "DISTREDUX_BIOGAS"
    return self
end

function DistributionBiogasStoragePage.new(target, custom_mt)
    local self = DistributionStoragePage.new(target, custom_mt or DistributionBiogasStoragePage_mt)
    self.pageName = "DISTREDUX_BIOGAS_STORAGE"
    self.classFilter = {}
    return self
end

-- ---- shared helpers ---------------------------------------------------------

local function l10n(key, fb)
    return (SmartDistribution.l10n ~= nil) and SmartDistribution.l10n(key, fb) or fb
end

-- The plant still selected, or the first one on the map. A plant that was sold falls back cleanly.
local function resolvePlant()
    local st = SmartDistribution._biogas
    local plants = SmartDistribution.biogasPlants()
    for _, r in ipairs(plants) do
        if r == st.root then return r, plants end
    end
    st.root = plants[1]
    st.piece = st.root
    return st.root, plants
end

-- "BGA (1) : Fermenter 20m" -> "Fermenter 20m": the plant's name is already on the selector above.
local function pieceName(p, root)
    local n = nil
    if p ~= nil and p.getName ~= nil then
        local ok, v = pcall(p.getName, p)
        if ok and type(v) == "string" and v ~= "" then n = v end
    end
    n = n or "?"
    local rn = SmartDistribution.plantDisplayName(root)
    if type(rn) == "string" and rn ~= "" and n:sub(1, #rn) == rn then
        local rest = n:sub(#rn + 1):gsub("^%s*:?%s*", "")
        if rest ~= "" then n = rest end
    end
    return n
end

local function pageOfKind(kind)
    local menu = SmartDistribution._menu
    if menu == nil then return nil end
    if kind == "PRODUCTION" then return menu.pageBiogas end
    return menu.pageBiogasStorage
end

local function goToKind(kind)
    local menu, target = SmartDistribution._menu, pageOfKind(kind)
    if menu ~= nil and target ~= nil and menu.goToPage ~= nil then pcall(menu.goToPage, menu, target) end
end

local function setText(cell, name, text)
    local c = cell ~= nil and cell.getAttribute ~= nil and cell:getAttribute(name) or nil
    if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    return c
end

local function setWhite(c)
    if c ~= nil and c.setTextColor ~= nil then c:setTextColor(1, 1, 1, 1) end
end

local function isMember(p)
    return p ~= nil and SmartDistribution.isPlantMember(p)
end

local function isTorch(p)
    return p ~= nil and SmartDistribution.plantType(p) == SmartDistribution.PLANT_TYPE.TORCH
end

-- Which buildings carry a mode on this tab (5.123).
local function configurable(p)
    if p == nil then return false end
    return SmartDistribution.isPlantRoot(p) or SmartDistribution.isPlantChp(p)
        or SmartDistribution.isPlantSourceMember(p)
end

local function hideArrows(cell)
    for _, n in ipairs({ "modePrev", "modeNext" }) do
        local b = cell ~= nil and cell.getAttribute ~= nil and cell:getAttribute(n) or nil
        if b ~= nil then
            b.sdFillType = nil
            if b.setVisible ~= nil then b:setVisible(false) end
        end
    end
end

local function methaneFt()
    if g_fillTypeManager == nil or g_fillTypeManager.getFillTypeIndexByName == nil then return nil end
    return g_fillTypeManager:getFillTypeIndexByName("METHANE")
end

local function fillTitle(ft)
    if g_fillTypeManager ~= nil and ft ~= nil then
        local t = g_fillTypeManager:getFillTypeByIndex(ft)
        if t ~= nil and t.title ~= nil then return t.title end
    end
    return "?"
end

-- The fermenter's methane, what the torch watches: level, capacity, and the level it lights at.
function SmartDistribution.torchReading(torch)
    local ft = methaneFt()
    local root = SmartDistribution.plantRootOf(torch)
    local pp = root ~= nil and SmartDistribution.productionPointOf(root) or nil
    local held, cap = 0, 0
    if ft ~= nil and pp ~= nil and pp.storage ~= nil then
        local s = pp.storage
        held = (type(s.fillLevels) == "table" and s.fillLevels[ft]) or 0
        if type(s.capacities) == "table" and s.capacities[ft] ~= nil then
            cap = s.capacities[ft]
        elseif s.getCapacity ~= nil then
            local ok, c = pcall(s.getCapacity, s, ft)
            if ok and type(c) == "number" then cap = c end
        end
    end
    -- the torch's OWN light level, not the out-of-reach one "Biogas plant only" parks it at (5.123)
    local pct = SmartDistribution.torchBasePct(SmartDistribution.torchSpec(torch))
    return held, cap, cap * pct, pct, ft
end

-- ---- behaviour both pages share, installed onto each class ------------------

local function install(cls, base, kind)
    cls.BIOGAS_KIND = kind
    cls.MODE_KEYS_ENABLED = true      -- z / x step the selected row, on the buildings that carry a mode

    -- Every data call runs with the plant-local view raised (each building's own storage + flows).
    local function localCall(fn, self, ...)
        if fn == nil then return nil end
        return SmartDistribution.withPlantLocal(fn, self, ...)
    end

    function cls:rebuildAssets()
        self.assets = {}
        local root = resolvePlant()
        self._plantRoot = root
        local st = SmartDistribution._biogas
        local want, firstOfKind = nil, nil
        for _, p in ipairs(SmartDistribution.plantPieces(root)) do
            local a = {
                placeable = p, class = SmartDistribution.plantPieceKind(p), role = nil,
                name = pieceName(p, root), origName = SmartDistribution.plantTypeLabel(p),
            }
            a.baseName = a.name
            self.assets[#self.assets + 1] = a
            if a.class == kind then
                firstOfKind = firstOfKind or #self.assets
                if p == st.piece then want = #self.assets end
            end
        end
        -- the row to open on: the shared selection when it is this page's kind, else this kind's first
        self._openIndex = want or firstOfKind or 1
    end

    -- THE STUCK ARROW. A MultiTextOption remembers that its arrow is held (isLeft/RightButtonPressed)
    -- from the mouse DOWN and only clears it when it sees the mouse UP. Changing plant can switch to the
    -- OTHER page before the button comes up, so this page's selector never sees the release -- and its
    -- update() then keeps "holding" the arrow: every time the page became active again it stepped to the
    -- next plant on its own (traced 2026-10-19: "plantChanged state=2" 1 ms after every storage open,
    -- dragging BGA (1) back to BGA (2), which has no torch). Release it by hand.
    function cls:releasePlantOption()
        local opt = self.plantOption
        if opt == nil then return end
        opt.isLeftButtonPressed, opt.isRightButtonPressed = false, false
        opt.wasContinuousTrigger = false
        opt.delayTime = math.huge
        for _, b in ipairs({ opt.leftButtonElement, opt.rightButtonElement }) do
            if b ~= nil and b.setPressed ~= nil then pcall(b.setPressed, b, false) end
        end
        if opt.releaseInput ~= nil then pcall(opt.releaseInput, opt) end
    end

    function cls:refreshPlantOption()
        local opt = self.plantOption
        if opt == nil then return end
        self:releasePlantOption()
        local root, plants = resolvePlant()
        local texts, cur = {}, 1
        for i, r in ipairs(plants) do
            texts[i] = SmartDistribution.plantDisplayName(r)
            if r == root then cur = i end
        end
        if #texts == 0 then texts[1] = "-" end
        local key = table.concat(texts, "\n")
        if key ~= self._plantTextsKey and opt.setTexts ~= nil then
            self._plantTextsKey = key
            pcall(opt.setTexts, opt, texts)
        end
        -- ONE argument: a truthy second one RAISES the click callback, and this is called from that
        -- callback's own path -- an unbounded loop (5.88)
        if opt.setState ~= nil then pcall(function() opt:setState(cur) end) end
    end

    -- MultiTextOption raises (state, element), the state FIRST (5.107a)
    function cls:onPlantChanged(state)
        local opt = self.plantOption
        if type(state) ~= "number" and opt ~= nil and opt.getState ~= nil then state = opt:getState() end
        local _, plants = resolvePlant()
        local r = type(state) == "number" and plants[state] or nil
        if r == nil then return end
        local st = SmartDistribution._biogas
        st.root, st.piece = r, r                       -- a new plant opens on its fermenter
        if kind ~= SmartDistribution.plantPieceKind(r) then
            self:releasePlantOption()          -- the page is about to leave under a held mouse button
            goToKind(SmartDistribution.plantPieceKind(r))
            return
        end
        self:rebuildAssets()
        if self.assetList ~= nil then self.assetList:reloadData() end
        self:syncListTo(self._openIndex)
        self:selectAsset(self._openIndex)
    end

    function cls:syncListTo(index)
        if self.assetList == nil or self.assetList.setSelectedItem == nil then return end
        self._syncing = true
        pcall(self.assetList.setSelectedItem, self.assetList, 1, index or 1)
        -- a list that was hidden when its data reloaded parks its OLD index here and re-applies it on
        -- open, raising a selection change for a row that is no longer the shown one
        self.assetList.setNextOpenIndex = nil
        self.assetList.setNextOpenSectionIndex = nil
        self._syncing = false
    end

    function cls:selectAsset(index)
        if self._syncing then return end
        if self._opening then index = self._openIndex or index end
        local a = self.assets[index]
        -- A row this page cannot draw: do NOTHING here. The page switch happens on the CLICK
        -- (onAssetListClick). A selection change is not proof of a click -- the list also raises one
        -- when it reloads, when it gains focus and when it reopens, each time with whatever index it
        -- last held. That index is often a row of the other kind, so switching here sent the player
        -- back and forth and a building took two or three clicks to land on.
        if a ~= nil and a.class ~= kind then return end
        if a ~= nil then SmartDistribution._biogas.piece = a.placeable end
        localCall(base.selectAsset, self, index)
    end

    -- The list's own onClick (raised AFTER the selection lands, and also for a row already selected):
    -- the one place a building of the other kind moves to the other page, which opens on it.
    function cls:onAssetListClick(list, section, index)
        if list ~= self.assetList then return end
        local a = self.assets[index]
        if a == nil or a.class == kind then return end
        SmartDistribution._biogas.piece = a.placeable
        goToKind(a.class)
    end

    function cls:onFrameOpen()
        self._opening = true
        local ok, err = pcall(localCall, base.onFrameOpen, self)
        self._opening = false
        if not ok then print("[SmartDistribution] biogas page open failed: " .. tostring(err)) end
        self:refreshPlantOption()
        self:syncListTo(self._openIndex)
        self:updateSellTimingButton()
    end

    function cls:populateCellForItemInSection(list, section, index, cell)
        localCall(base.populateCellForItemInSection, self, list, section, index, cell)
        local ok, err = pcall(self.afterPopulate, self, list, index, cell)
        if not ok and SmartDistribution.debug then print("[SmartDistribution] biogas populate: " .. tostring(err)) end
    end

    if base.rebuildRealtimeData ~= nil then
        function cls:rebuildRealtimeData() localCall(base.rebuildRealtimeData, self) end
    end
    if base.buildDetailRows ~= nil then
        function cls:buildDetailRows()
            if isTorch(self.selectedAsset) then
                local ft = methaneFt()
                self.rows = {}
                if ft ~= nil then self.rows[1] = { ft = ft, name = fillTitle(ft), torch = true } end
                return
            end
            localCall(base.buildDetailRows, self)
        end
    end

    -- MODES: only on a building that carries one; inside the plant-local view like every other call
    local function gated(name)
        local fn = base[name]
        cls[name] = function(self, ...)
            if fn == nil or not configurable(self.selectedAsset) then return end
            return localCall(fn, self, ...)
        end
    end
    for _, name in ipairs({ "stepRowMode", "onCycleSelected", "onCycleSelectedBack", "onCycleOutput" }) do
        gated(name)
    end
    function cls:onModePrev(...) self:stepRowMode(-1, ...) end
    function cls:onModeNext(...) self:stepRowMode( 1, ...) end

    -- everything else stays read only; the Advanced buttons open the plant overview instead
    local noop = function() end
    for _, name in ipairs({ "onSellTiming", "onSellTimingOrSpawn", "onSpawn" }) do
        cls[name] = noop
    end
    -- TOGGLE LINE on the fermenter and the CHP, exactly as on the Productions tab (the line state is
    -- the player's, 5.65); nothing to toggle on the storage page
    local function hasLines(p)
        return p ~= nil and kind == "PRODUCTION" and SmartDistribution.productionPointOf(p) ~= nil
    end
    function cls:onToggleLine()
        if not hasLines(self.selectedAsset) or base.onToggleLine == nil then return end
        return localCall(base.onToggleLine, self)
    end
    function cls:onPlantOverview()
        local p = self.selectedAsset
        if SmartDistribution.openPlantOverview ~= nil then SmartDistribution.openPlantOverview(p) end
    end
    cls.onAdvanced           = cls.onPlantOverview
    cls.onAdvancedInputs     = cls.onPlantOverview
    cls.onAdvancedContextual = cls.onPlantOverview
    -- THE BURNER SWITCH (5.124): one per plant, shown only where the plant has a gas torch. It is the
    -- last resort in every methane mode -- whatever is left in the fermenter above the light level burns.
    function cls:selectedPlantRoot()
        local p = self.selectedAsset
        local root = p ~= nil and SmartDistribution.plantRootOf(p) or nil
        return root or SmartDistribution._biogas.root
    end
    function cls:onToggleBurner()
        local root = self:selectedPlantRoot()
        if root == nil or not SmartDistribution.plantHasTorch(root) then return end
        SmartDistribution.setPlantBurner(root, not SmartDistribution.plantBurnerOn(root))
        self:updateSellTimingButton()
        if self.rebuildRealtimeData ~= nil then pcall(self.rebuildRealtimeData, self) end
    end
    function cls:updateSellTimingButton()
        if self._allButtons == nil then return end
        local root = self:selectedPlantRoot()
        local vis = {}
        for _, b in ipairs(self._allButtons) do
            if b._role == "burner" then
                if root ~= nil and SmartDistribution.plantHasTorch(root) then
                    b.text = SmartDistribution.plantBurnerOn(root)
                        and l10n("dr_btn_burnerOn", "Burner: On") or l10n("dr_btn_burnerOff", "Burner: Off")
                    vis[#vis + 1] = b
                end
            elseif b._role == "toggleLine" then
                if hasLines(self.selectedAsset) then vis[#vis + 1] = b end
            else
                vis[#vis + 1] = b
            end
        end
        self:applyFooterButtons(vis)
    end
end

install(DistributionBiogasProductionPage, DistributionProductionsPage, "PRODUCTION")
install(DistributionBiogasStoragePage,    DistributionStoragePage,     "STORAGE")

-- ---- page-specific finishing, after the inherited populate ------------------

local PLANT_LABEL_KEY, PLANT_LABEL_FB = "dr_mode_plantInternal", "Biogas plant"

-- Productions template: the fermenter keeps its real mode and statuses (they are the plant's); a
-- member's mode cell names the plant and its link status is blanked -- a link status is a property of a
-- DR building, and a member is not one.
function DistributionBiogasProductionPage:afterPopulate(list, index, cell)
    if list == self.assetList then return end
    local p = self.selectedAsset
    if not isMember(p) then return end
    -- the CHP's electricity carries its real mode and status (5.123); its methane input is the plant's
    if list ~= self.outputList then setWhite(setText(cell, "statusText", "-")) end
end

-- Storage template: the list's type column is the plant role instead of Silo / Pit; a member's mode
-- cell names the plant; the torch row is drawn from the fermenter's methane.
function DistributionBiogasStoragePage:afterPopulate(list, index, cell)
    if list == self.assetList then
        local a = self.assets[index]
        if a ~= nil then setText(cell, "assetType", "") end
        return
    end
    local row = self.rows[index]
    if row == nil or row.notice ~= nil then return end
    local p = self.selectedAsset
    -- the TANK is a DR building of its own (5.123): its mode, its arrows and its statuses are all real
    if SmartDistribution.isPlantSourceMember(p) then return end
    hideArrows(cell)
    setText(cell, "statusSep", "")
    setText(cell, "statusOut", "")
    setWhite(setText(cell, "statusIn", "-"))
    if row.torch then
        local held, cap, thr, pct, ft = SmartDistribution.torchReading(p)
        setText(cell, "typeText", "")
        setText(cell, "recvText", "-")
        setText(cell, "distText", "-")
        -- the bar is the FERMENTER's methane, with the orange mark where the torch lights
        SmartDistribution.drawStorageBar(cell, p, ft, nil, "input", nil,
            { held = held, total = cap, others = 0, capL = thr })
        local off = SmartDistribution.torchDisabled(p)
        local burning = not off and cap > 0 and held >= thr
        local txt
        if off then txt = l10n("dr_torch_off", "Off - burner switched off")
        elseif burning then txt = l10n("dr_torch_burning", "Burning")
        else txt = string.format(l10n("dr_torch_idle", "Idle - lights above %d%%"), math.floor(pct * 100 + 0.5)) end
        local m = setText(cell, "modeText", txt)
        if m ~= nil and m.setTextColor ~= nil then
            if burning then m:setTextColor(0.95, 0.65, 0.20, 1) else m:setTextColor(1, 1, 1, 1) end
        end
        return
    end
    if isMember(p) then
        setWhite(setText(cell, "modeText", l10n(PLANT_LABEL_KEY, PLANT_LABEL_FB)))
    end
end

-- ---- the tab's enable predicate -----------------------------------------------
-- Only Pumps & Hoses plants (assembled from pieces). A bought single-placeable biogas plant has no
-- sandbox root, so a farm without the DLC's plants never sees the tab.
function SmartDistribution.hasBiogasPlants()
    return SmartDistribution.biogasPlants ~= nil and #SmartDistribution.biogasPlants() > 0
end
