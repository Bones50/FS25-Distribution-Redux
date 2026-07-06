-- ============================================================================
-- DistributionMenu.lua  (Distribution Redux)
-- The consolidated full-screen menu: a TabbedMenu with left-side tabs, one page
-- per area (Settings, Storage, Productions, Help). Mirrors the proven AutoDrive
-- ADSettings / EasyDevControls menu pattern:
--   - extends TabbedMenu
--   - onGuiSetupFinished -> setupPages(): registerPage + addPageTab + per-page
--     setMenuButtonInfo for each frame
--   - opened with g_gui:showGui("DistributionMenu"); closed with changeScreen(nil)
--
-- The page frame elements arrive as self.pageSettings / pageStorage /
-- pageProductions / pageHelp (the FrameReference ids in DistributionMenu.xml).
-- Tab icons use base-game UI slices (validated against AutoDrive/EDC usage).
-- ============================================================================

DistributionMenu = {}
local DistributionMenu_mt = Class(DistributionMenu, TabbedMenu)

function DistributionMenu.new(target, custom_mt)
    local self = TabbedMenu.new(target, custom_mt or DistributionMenu_mt)
    return self
end

function DistributionMenu:onGuiSetupFinished()
    DistributionMenu:superClass().onGuiSetupFinished(self)
    self:setupPages()
end

function DistributionMenu:setupPages()
    local always = function() return true end
    local backText = (g_i18n ~= nil and g_i18n:getText("button_back")) or "Back"
    local back = {
        inputAction = InputAction.MENU_BACK,
        text = backText,
        callback = self:makeSelfCallback(self.onClickBack),
        showWhenPaused = true,
    }

    local function btn(action, text, fn, role)
        return { inputAction = action, text = text, callback = fn, showWhenPaused = true, _role = role }
    end

    -- Storage-style footer actions, shared by Silos / Animal Husbandry (both are
    -- DistributionStoragePage instances). MENU_ACTIVATE (Space) is consumed by a focused list for
    -- row-activation, so footer actions use EXTRA_1/EXTRA_2/CANCEL, which lists don't swallow.
    local function storageButtonsFor(getPage)
        return {
            back,
            btn(InputAction.MENU_EXTRA_1, "Cycle Selected", function() local p = getPage(); if p ~= nil then p:onCycleSelected() end end),
            btn(InputAction.MENU_EXTRA_2, "Cycle All",      function() local p = getPage(); if p ~= nil then p:onCycleAll() end end),
            btn(InputAction.MENU_CANCEL,  "Sell Timing",    function() local p = getPage(); if p ~= nil then p:onSellTiming() end end, "sellTiming"),
        }
    end

    -- Productions page footer actions (operate on the selected building + line).
    local productionsButtons = {
        back,
        btn(InputAction.MENU_EXTRA_1, "Toggle Line",  function() if self.pageProductions ~= nil then self.pageProductions:onToggleLine() end end),
        btn(InputAction.MENU_EXTRA_2, "Cycle Output", function() if self.pageProductions ~= nil then self.pageProductions:onCycleOutput() end end),
        btn(InputAction.MENU_CANCEL,  "Sell Timing",  function() if self.pageProductions ~= nil then self.pageProductions:onSellTiming() end end, "sellTiming"),
    }

    -- a page shows only while its asset class is in the network (Settings toggles). nil/true -> show.
    local showSilos     = function() return DistributionSettings == nil or DistributionSettings.includeSilosSheds ~= false end
    local showHusbandry = function() return DistributionSettings == nil or DistributionSettings.includeHusbandry  ~= false end

    -- left-tab order: Productions, Silos, Animal Husbandry, User Guide, Settings
    -- { pageElement, tabIconSliceId, footerButtons, enablePredicate }
    -- Tab icons mirror the building-placement (construction) menu's category iconSliceIds,
    -- read off g_storeManager via sdIconProbe. Silos has no top-level construction category
    -- (it's a store sub-category under Buildings), so it uses the Buildings icon.
    local pages = {
        { self.pageProductions, "gui.icon_ingameMenu_productionChains", productionsButtons, always },
        { self.pageStorage,     "gui.icon_construction_buildings",      storageButtonsFor(function() return self.pageStorage end),   showSilos },
        { self.pageHusbandry,   "gui.icon_ingameMenu_animals",          storageButtonsFor(function() return self.pageHusbandry end), showHusbandry },
        { self.pageHelp,        "gui.icon_options_help2",               { back }, always },
        { self.pageSettings,    "gui.icon_options_generalSettings2",    { back }, always },
    }

    self.tabIndexByPage = {}
    for i, def in ipairs(pages) do
        local page, sliceId, buttons, pred = def[1], def[2], def[3], def[4]
        if page ~= nil then
            self:registerPage(page, i, pred or always)
            self:addPageTab(page, nil, nil, sliceId)
            self.tabIndexByPage[page] = i               -- for [ + gaze page jumps
            if page.setMenuButtonInfo ~= nil then
                page:setMenuButtonInfo(buttons)
            end
        end
    end

    self:rebuildTabList()
end

-- Close the menu (no unsaved-changes prompt: settings apply live).
function DistributionMenu:onClickBack()
    if g_gui ~= nil then
        g_gui:changeScreen(nil)
    end
    return true
end

-- On open, if [ + gaze stashed a target asset, jump to its tab and select it.
function DistributionMenu:onOpen()
    DistributionMenu:superClass().onOpen(self)
    pcall(function() self:rebuildTabList() end)         -- re-evaluate tab predicates against current Settings
    if self._focusAsset ~= nil then
        self:focusAsset()
    end
end

-- Switch to the tab matching the stashed asset's class and preselect the asset.
-- Uses the header selector (same path as the tab arrows) so the green highlight
-- stays in sync. _focusAsset / _focusClass are set by SmartDistribution.openMenuForAsset.
function DistributionMenu:focusAsset()
    local placeable = self._focusAsset
    local cls = self._focusClass
    self._focusAsset = nil
    self._focusClass = nil
    if placeable == nil then return end

    local page = self.pageStorage                       -- SILO / SHED
    if cls == "PRODUCTION" then page = self.pageProductions
    elseif cls == "HUSBANDRY" or cls == "HEAP" then page = self.pageHusbandry end   -- pits ride with husbandry
    if page == nil then return end

    local idx = self.tabIndexByPage ~= nil and self.tabIndexByPage[page] or nil
    if idx ~= nil and self.pageSelector ~= nil and self.pageSelector.setState ~= nil then
        pcall(function() self.pageSelector:setState(idx, true) end)   -- switch tab (content + highlight)
    end
    if page.selectPlaceable ~= nil then
        pcall(function() page:selectPlaceable(placeable) end)        -- preselect the gazed asset
    end
end
