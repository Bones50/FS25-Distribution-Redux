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
    -- row-activation, so footer actions use EXTRA_1/CANCEL, which lists don't swallow.
    -- NOTE: there is deliberately no "Cycle All": endpoints are per (building, product), so one product
    -- can have a valid market/consumer while another does not, and a single building-wide mode could not
    -- honour both. Cycling the selected output only is unambiguous.
    -- THE FOOTER IS DELIBERATELY UNCHANGED. A "cycle backward" entry was added here and then removed on
    -- request: the footer is full, and the backward step is handled by a raw key on the page instead
    -- (see DistributionStoragePage:keyEvent), with an on-page hint naming both keys.
    local function storageButtonsFor(getPage)
        return {
            back,
            btn(InputAction.MENU_EXTRA_1, SmartDistribution.l10n("dr_btn_cycleOutput", "Cycle Output"), function() local p = getPage(); if p ~= nil then p:onCycleSelected() end end),
            btn(InputAction.MENU_EXTRA_2, SmartDistribution.l10n("dr_btn_advanced", "Advanced"), function() local p = getPage(); if p ~= nil and p.onAdvancedContextual ~= nil then p:onAdvancedContextual() end end, "advanced"),
            btn(InputAction.MENU_CANCEL,  SmartDistribution.l10n("dr_btn_sellTiming", "Sell Timing"), function() local p = getPage(); if p ~= nil then p:onSellTimingOrSpawn() end end, "sellTiming"),
        }
    end

    -- Productions footer: 4 action slots. The single "Advanced" button is CONTEXTUAL like the other tabs
    -- (Advanced Inputs when an input row has focus, Advanced Outputs when an output row has focus). Sell
    -- Timing shows only for sell-mode / Hold-Internal outputs; it shares no slot now that Advanced is one.
    local productionsButtons = {
        back,
        btn(InputAction.MENU_EXTRA_1, SmartDistribution.l10n("dr_btn_cycleOutput", "Cycle Output"), function() local p = self.pageProductions; if p ~= nil then p:onCycleSelected() end end),
        btn(InputAction.MENU_EXTRA_2, SmartDistribution.l10n("dr_btn_toggleLine", "Toggle Line"), function() local p = self.pageProductions; if p ~= nil and p.onToggleLine ~= nil then p:onToggleLine() end end),
        btn(InputAction.MENU_ACCEPT,  SmartDistribution.l10n("dr_btn_advanced", "Advanced"), function() local p = self.pageProductions; if p ~= nil and p.onAdvancedContextual ~= nil then p:onAdvancedContextual() end end, "advanced"),
        btn(InputAction.MENU_CANCEL,  SmartDistribution.l10n("dr_btn_sellTiming", "Sell Timing"), function() local p = self.pageProductions; if p ~= nil then p:onSellTimingOrSpawn() end end, "sellTiming"),
    }

    -- a page shows only while its asset class is in the network (Settings toggles). nil/true -> show.
    local showSilos     = function() return DistributionSettings == nil or DistributionSettings.includeSilosSheds ~= false end
    local showHusbandry = function() return DistributionSettings == nil or DistributionSettings.includeHusbandry  ~= false end
    local showMarkets   = function() return (DistributionSettings == nil or DistributionSettings.includeMarkets ~= false) and SmartDistribution ~= nil and SmartDistribution.hasAnyMarket ~= nil and SmartDistribution.hasAnyMarket() end

    -- Markets uses the same footer as the other tabs.
    local marketButtons = storageButtonsFor(function() return self.pageMarkets end)

    -- left-tab order: Productions, Silos, Animal Husbandry, Markets, Overview, User Guide, Settings
    -- { pageElement, tabIconSliceId, footerButtons, enablePredicate }
    -- Tab icons mirror the building-placement (construction) menu's category iconSliceIds,
    -- read off g_storeManager via sdIconProbe. Silos has no top-level construction category
    -- (it's a store sub-category under Buildings), so it uses the Buildings icon.
    -- Overview is read-only (a whole-network figures table), so it carries Back alone.
    local pages = {
        { self.pageProductions, "gui.icon_ingameMenu_productionChains", productionsButtons, always },
        { self.pageStorage,     "gui.icon_construction_buildings",      storageButtonsFor(function() return self.pageStorage end),   showSilos },
        { self.pageHusbandry,   "gui.icon_ingameMenu_animals",          storageButtonsFor(function() return self.pageHusbandry end), showHusbandry },
        { self.pageMarkets,     "gui.icon_ingameMenu_prices",           marketButtons, showMarkets },
        -- Overview carries one action beside Back: swap the flow figures for the Advanced Inputs / Outputs
        -- settings behind the same rows. The label flips with the view (updateViewButton).
        -- Refresh re-enumerates the network on demand. It is what makes the "Manual only" menu refresh rate
        -- usable on a large farm, and is a harmless no-op-ish extra at every other rate.
        { self.pageOverview,    "gui.icon_ingameMenu_statistics",
            { back, btn(InputAction.MENU_EXTRA_1, SmartDistribution.l10n("dr_btn_showSettings", "Show Settings"),
                function() local p = self.pageOverview; if p ~= nil and p.onToggleSettingsView ~= nil then p:onToggleSettingsView() end end,
                "viewToggle"),
              btn(InputAction.MENU_EXTRA_2, SmartDistribution.l10n("dr_btn_refresh", "Refresh"),
                function() local p = self.pageOverview; if p ~= nil and p.onRefresh ~= nil then p:onRefresh() end end) },
            always },
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
-- Z steps the SELECTED output's mode BACKWARD (X steps it forward via the existing footer action).
--
-- HANDLED HERE, AT THE MENU, and that is the fix for the first attempt doing nothing. Gui:keyEvent
-- dispatches to g_gui.currentListener and to currentListener.target only -- it does not walk down to a
-- frame itself -- so a keyEvent override on the PAGE class is not reliably reached. This screen IS the
-- currentListener, so it always is. TabbedMenu tracks the live page as self.currentPage.
--
-- The page-level overrides are KEPT as well and cannot double-step: the superclass call below
-- propagates down the element tree first, and if a page handled the key it returns true, so this
-- returns early without acting again.
--
-- MODE_KEYS_ENABLED is how the Markets page opts out -- its MODE column is the market timing enum,
-- not the asset mode ring.
-- Is a MEANINGFUL modifier held (ctrl / alt / shift / meta), as opposed to a lock bit?
--
-- MEASURED, and it is why the first two attempts at this key did nothing: the guard was
-- `modifier == 0`, but a menu key press arrives with **modifier = 4096** permanently set -- a lock
-- bit (Num Lock), not a held key. `x` arrives with the same 4096 and only works because its input
-- action never looks at modifiers. So the test has to be on the bits that MATTER, not on the whole
-- value being zero.
--
-- The mask is assembled from whichever constants this build actually defines: only MOD_LCTRL and
-- MOD_LMETA appear anywhere in the shipped source, so the rest are plausible but unconfirmed names
-- (8.1) and a nil must not break the test. If none resolve, the mask is 0 and this reports "no
-- modifier", which fails toward the key WORKING rather than being silently dead again.
local MOD_NAMES = { "MOD_LCTRL", "MOD_RCTRL", "MOD_LALT", "MOD_RALT",
                    "MOD_LSHIFT", "MOD_RSHIFT", "MOD_LMETA", "MOD_RMETA" }

local function realModifierHeld(modifier)
    if modifier == nil or modifier == 0 then return false end
    if Input == nil or bit32 == nil then return false end
    local mask = 0
    for i = 1, #MOD_NAMES do
        local v = Input[MOD_NAMES[i]]
        if type(v) == "number" then mask = bit32.bor(mask, v) end
    end
    if mask == 0 then return false end
    return bit32.band(modifier, mask) > 0
end

-- THE KEY IS CLAIMED BEFORE THE SUPERCLASS RUNS, and that ordering is the fix for the previous
-- attempt. It used to defer to the superclass first and bail on `if used`, so anything in the element
-- tree that swallowed the key (a focused SmoothList handles its own key navigation) silently
-- pre-empted this. Acting first also guarantees no double-step: the page-level keyEvent overrides can
-- no longer see Z, because this returns before propagation.
function DistributionMenu:keyEvent(unicode, sym, modifier, isDown, eventUsed)
    if isDown and Input ~= nil and Input.KEY_z ~= nil and sym == Input.KEY_z
       and not realModifierHeld(modifier) then                         -- never swallow Ctrl+Z etc.
        local p = self.currentPage
        if p ~= nil and p.MODE_KEYS_ENABLED ~= false and p.onCycleSelectedBack ~= nil then
            p:onCycleSelectedBack()
            return true
        end
    end

    return DistributionMenu:superClass().keyEvent(self, unicode, sym, modifier, isDown, eventUsed)
end

function DistributionMenu:onClickBack()
    if g_gui ~= nil then
        g_gui:changeScreen(nil)
    end
    return true
end

-- On open, if [ + gaze stashed a target asset, jump to its tab and select it.
-- MULTIPLAYER CLIENT: the server's uid map (DistributionUidMapEvent) is sent at JOIN, so a building
-- placed since then has no entry and every uid-keyed read and write for it would silently miss --
-- the same failure the map exists to fix, just for a newer building. Re-ask whenever the placeable
-- count has moved. Cheap, bounded, and self-limiting: the reply is the full state replay, which is
-- idempotent (it only ever writes values the server already holds), and the player has to open this
-- menu to configure a new building anyway.
DistributionMenu._uidMapCount = nil

function DistributionMenu.refreshServerUids()
    if g_currentMission == nil or g_currentMission.getIsServer == nil then return end
    if g_currentMission:getIsServer() then return end                    -- host owns the ids already
    if DistributionStateRequestEvent == nil or DistributionStateRequestEvent.sendToServer == nil then return end
    local ps = g_currentMission.placeableSystem
    local n  = (ps ~= nil and ps.placeables ~= nil) and #ps.placeables or 0
    if n == DistributionMenu._uidMapCount then return end
    DistributionMenu._uidMapCount = n
    DistributionStateRequestEvent.sendToServer()
end

function DistributionMenu:onOpen()
    DistributionMenu:superClass().onOpen(self)
    pcall(function() self:rebuildTabList() end)         -- re-evaluate tab predicates against current Settings
    pcall(function() DistributionMenu.refreshServerUids() end)
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
    elseif cls == "HUSBANDRY" or cls == "HEAP" then page = self.pageHusbandry
    elseif cls == "MARKET" then page = self.pageMarkets end   -- pits ride with husbandry
    if page == nil then return end

    local idx = self.tabIndexByPage ~= nil and self.tabIndexByPage[page] or nil
    if idx ~= nil and self.pageSelector ~= nil and self.pageSelector.setState ~= nil then
        pcall(function() self.pageSelector:setState(idx, true) end)   -- switch tab (content + highlight)
    end
    if page.selectPlaceable ~= nil then
        pcall(function() page:selectPlaceable(placeable, cls) end)   -- preselect the gazed asset (its primary role)
    end
end
