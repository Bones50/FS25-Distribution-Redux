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
    -- CYCLE OUTPUT IS GONE, and the in-row arrows are why: every output row carries a pair (5.64), so a
    -- footer entry that steps the SELECTED row was doing the same job one step further from the thing it
    -- acts on. Removing it frees a slot, which is what lets both Advanced buttons be shown.
    --
    -- IT TOOK THE `x` KEY WITH IT. That key was MENU_EXTRA_1's binding, not a raw key, so it dies with
    -- the button -- and `z` (backward) is read raw at the menu and would have survived alone, leaving a
    -- documented pair half working. `x` is now read raw beside it (see keyEvent), so both still step the
    -- selected row and the on-page hint stays true.
    --
    -- TWO EXPLICIT ADVANCED BUTTONS replace the single contextual one. That button dispatched on
    -- _focusRole -- which list you last touched -- and the merged Silos / Markets table has only ONE
    -- list, so there was nothing left to infer the direction from. Naming both is also simply clearer on
    -- Animal Husbandry, which keeps its two lists.
    -- MENU_ACCEPT is free on these pages (Productions already uses it for its own Advanced button), so
    -- this fits without stealing MENU_ACTIVATE, which a focused list swallows for row activation.
    local function storageButtonsFor(getPage)
        return {
            back,
            btn(InputAction.MENU_EXTRA_2, SmartDistribution.l10n("dr_btn_advIn", "Adv Inputs"),
                function() local p = getPage(); if p ~= nil and p.onAdvancedInputs ~= nil then p:onAdvancedInputs() end end, "advancedIn"),
            btn(InputAction.MENU_ACCEPT,  SmartDistribution.l10n("dr_btn_advOut", "Adv Outputs"),
                function() local p = getPage(); if p ~= nil and p.onAdvanced ~= nil then p:onAdvanced() end end, "advancedOut"),
            btn(InputAction.MENU_CANCEL,  SmartDistribution.l10n("dr_btn_sellTiming", "Sell Timing"), function() local p = getPage(); if p ~= nil then p:onSellTimingOrSpawn() end end, "sellTiming"),
        }
    end

    -- Productions footer: 4 action slots. The single "Advanced" button is CONTEXTUAL like the other tabs
    -- (Advanced Inputs when an input row has focus, Advanced Outputs when an output row has focus). Sell
    -- Timing shows only for sell-mode / Hold-Internal outputs; it shares no slot now that Advanced is one.
    local productionsButtons = {
        back,
        btn(InputAction.MENU_EXTRA_2, SmartDistribution.l10n("dr_btn_toggleLine", "Toggle Line"), function() local p = self.pageProductions; if p ~= nil and p.onToggleLine ~= nil then p:onToggleLine() end end),
        btn(InputAction.MENU_ACCEPT,  SmartDistribution.l10n("dr_btn_advanced", "Advanced"), function() local p = self.pageProductions; if p ~= nil and p.onAdvancedContextual ~= nil then p:onAdvancedContextual() end end, "advanced"),
        btn(InputAction.MENU_CANCEL,  SmartDistribution.l10n("dr_btn_sellTiming", "Sell Timing"), function() local p = self.pageProductions; if p ~= nil then p:onSellTimingOrSpawn() end end, "sellTiming"),
    }

    -- ANIMAL HUSBANDRY MATCHES PRODUCTIONS, minus Toggle Line (which is a production-line control and has
    -- no husbandry equivalent). Both pages keep TWO lists -- a pen's inputs are feed and its outputs are
    -- milk / manure / eggs, genuinely different products -- so the single CONTEXTUAL Advanced button has
    -- a direction to infer from and is the right control for them.
    --
    -- It previously used storageButtonsFor, which was rewritten for the MERGED Silos / Markets table: one
    -- row there carries both directions, so a contextual button had nothing left to dispatch on and had
    -- to become two explicit ones. Husbandry inherited that purely by sharing the list, and the reason
    -- for the change never applied to it. Reported 2026-08-26.
    local husbandryButtons = {
        back,
        btn(InputAction.MENU_ACCEPT,  SmartDistribution.l10n("dr_btn_advanced", "Advanced"),
            function() local p = self.pageHusbandry; if p ~= nil and p.onAdvancedContextual ~= nil then p:onAdvancedContextual() end end, "advanced"),
        btn(InputAction.MENU_CANCEL,  SmartDistribution.l10n("dr_btn_sellTiming", "Sell Timing"),
            function() local p = self.pageHusbandry; if p ~= nil then p:onSellTimingOrSpawn() end end, "sellTiming"),
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
        { self.pageHusbandry,   "gui.icon_ingameMenu_animals",          husbandryButtons, showHusbandry },
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


-- ============================================================================
-- THE DISTRIBUTION GROUP
--
-- Productions, Storage, Animal Husbandry and Markets lose their own left icons and become TOP TABS
-- under a single one. Nothing about those pages changes: they stay registered, keep their classes,
-- their XML, their footers and their onFrameOpen, and stay reachable by goToPage. What changes is
-- which rows the LEFT LIST draws.
--
-- THE SEAM IS rebuildTabList, AND IT HAD TO BE. The obvious route -- disabling a page so its tab
-- disappears -- is closed: PagingElement:updatePageMapping drops a disabled page from pageMapping
-- AND force-resets off it when it is current, so it becomes unreachable. Filtering the list instead
-- leaves the pages fully navigable and is a change to presentation alone.
--
-- getNumberOfItemsInSection is overridden ALONGSIDE it, defensively: that method is not in the
-- readable part of TabbedMenu (35% blank), so whether the row count comes from #enabledPages cannot
-- be proven by reading -- and an absence there proves nothing (CLAUDE.md 8.1). Answering it
-- ourselves means the count and the rows cannot disagree whatever the base does.
-- ============================================================================

---The four pages, in tab order. Nil-safe: a page the layout did not provide is simply skipped.
function DistributionMenu:groupPages()
    return {
        { self.pageProductions, "dr_tab_productions", "PRODUCTIONS" },
        { self.pageStorage,     "dr_tab_storage",     "STORAGE"     },
        { self.pageHusbandry,   "dr_tab_husbandry",   "HUSBANDRY"   },
        { self.pageMarkets,     "dr_tab_markets",     "MARKETS"     },
    }
end

function DistributionMenu:isGroupPage(page)
    if page == nil or SmartDistribution == nil or SmartDistribution.MENU_V2 ~= true then return false end
    for _, d in ipairs(self:groupPages()) do
        if d[1] ~= nil and d[1] == page then return true end
    end
    return false
end

---The row the group occupies in the left list: the FIRST member, which is Productions and is the
-- only one of the four with no enable predicate, so it is always there to stand for the group.
function DistributionMenu:groupRepresentative()
    return self.pageProductions
end

---Rebuild the group's tab registry from the pages that are currently ENABLED.
--
-- Driven from rebuildTabList, which is where the enable predicates are re-evaluated (a Settings
-- change calls it), so a farm with no market loses the Markets tab at the same moment it would have
-- lost the left icon. Registered fresh each time rather than patched, because the registry is the
-- only record of the order and rebuilding it is cheaper than reasoning about what moved.
function DistributionMenu:rebuildGroupTabs()
    if SmartDistribution == nil or SmartDistribution.registerPageTab == nil then return end
    local key = SmartDistribution.GROUP_TAB_KEY
    for _, d in ipairs(self:groupPages()) do
        if SmartDistribution.unregisterPageTab ~= nil then
            SmartDistribution.unregisterPageTab(key, "dr:" .. d[2])
        end
    end
    if SmartDistribution.MENU_V2 ~= true then return end
    for _, d in ipairs(self:groupPages()) do
        local page = d[1]
        -- ENABLED means the same thing the left list means by it, read from the paging element
        -- rather than re-evaluating the predicate here -- two answers to one question is how they
        -- come to disagree (5.27 / 5.28).
        if page ~= nil and self:pageIsEnabled(page) then
            -- own = true keeps all four ahead of any foreign tab, and registerPageTab inserts after
            -- the LAST own entry so they hold the order they are registered in.
            -- The modName is a REGISTRY key for de-duplication, never anything on screen.
            SmartDistribution.registerPageTab(key, "dr:" .. d[2],
                SmartDistribution.l10n(d[2], d[3]), { own = true, page = page })
        end
    end
end

function DistributionMenu:pageIsEnabled(page)
    if self.pagingElement == nil then return true end
    local ok, res = pcall(function()
        local id = self.pagingElement:getPageIdByElement(page)
        return not self.pagingElement:getIsPageDisabled(id)
    end)
    return (ok and res) and true or false
end

---Filter the left list, then rebuild the group's tabs from what survived.
function DistributionMenu:rebuildTabList()
    DistributionMenu:superClass().rebuildTabList(self)
    if SmartDistribution == nil or SmartDistribution.MENU_V2 ~= true then return end

    -- FILTER AND ORDER IN ONE PASS. The left list is presentation only now -- the paging
    -- element still holds every page, in registration order -- so ordering it here costs
    -- nothing and touches nothing. That is what makes this possible at all: 5.66 records
    -- that inserting a page at a POSITION leaves the tab strip and the paging element in
    -- different orders, so the page list must stay append-only and the ROW list is where
    -- an order belongs.
    --
    --   [the group] [any other mod's pages] [Overview] [User Guide] [Settings]
    --
    -- A dependent mod's page sits directly under the group rather than after DR's own
    -- trailing utility pages, which is where a reader looks for it: Overview, Guide and
    -- Settings are the things you go to LAST, and they read as the bottom of the list.
    -- Each bucket keeps the order enabledPages gave it, which is DR's registration order.
    local rep = self:groupRepresentative()
    local tail = {}
    for _, p in ipairs({ self.pageOverview, self.pageHelp, self.pageSettings }) do
        if p ~= nil then tail[p] = true end
    end

    local group, foreign, last = {}, {}, {}
    for _, page in ipairs(self.enabledPages or {}) do
        if self:isGroupPage(page) then
            -- every member is dropped EXCEPT the one standing for the group
            if page == rep then group[#group + 1] = page end
        elseif tail[page] then
            last[#last + 1] = page
        else
            foreign[#foreign + 1] = page
        end
    end

    local kept = {}
    for _, bucket in ipairs({ group, foreign, last }) do
        for _, page in ipairs(bucket) do kept[#kept + 1] = page end
    end
    self.enabledPages = kept

    -- THE GROUP'S OWN ICON. A FILE rather than a base-game slice, so it goes through the same
    -- path Animal Redux's tab icon takes (5.94): setPageTabIcon stores it in _tabIconFiles,
    -- and the populate prefers a file over a slice. Resolved against the mod directory here
    -- because a GUI profile cannot name a mod's own file (5.80) and the constant is a
    -- relative path, not something the engine could find on its own.
    local tab = (self.pageTabs or {})[rep]
    if tab ~= nil and SmartDistribution.GROUP_TAB_ICON ~= nil then
        -- SET DIRECTLY, NEVER THROUGH setPageTabIcon. That function rebuilds the tab list, and
        -- this IS the tab list rebuild -- so calling it here re-entered rebuildTabList with no
        -- guard, recursing until Lua ran out of C stack. The pcall swallowed the overflow, and
        -- every level repopulated the list and reloaded the icon PNG: ~130 disk loads per menu
        -- open, found in a player's log (6.44). The list is already being rebuilt, so the table
        -- write is all that is needed.
        self._tabIconFiles = self._tabIconFiles or {}
        self._tabIconFiles[rep] = (SmartDistribution.modDir or "") .. SmartDistribution.GROUP_TAB_ICON
        self:pinTabIconRecord(rep)
        -- CLICKING THE GROUP ROW RETURNS WHERE YOU WERE. The inherited callback always goes to the
        -- representative, so with four members you would lose your place every time you stepped out
        -- to the Overview and back. Wrapped once (_drGrouped), because rebuildTabList runs again on
        -- every settings change and wrapping a wrapper would nest without bound.
        if not tab._drGrouped then
            tab._drGrouped = true
            local inherited = tab.onClickCallback
            tab.onClickCallback = function(...)
                local last = self._groupLast
                if last ~= nil and self:isGroupPage(last) and self:pageIsEnabled(last)
                   and last ~= self.currentPage then
                    return self:goToPage(last)
                end
                if inherited ~= nil then return inherited(...) end
            end
        end
    end

    self:rebuildGroupTabs()

    if self.pagingTabList ~= nil then
        pcall(function() self.pagingTabList:reloadData() end)
        pcall(function() self.pagingTabList:setSelectedIndex(self:listIndexOf(self.currentPage)) end)
    end
end

---Which LEFT ROW a page shows up as. A group member answers with the group's row, which is what
-- keeps the highlight on it while you move about inside the group.
function DistributionMenu:listIndexOf(page)
    if page == nil then return self.currentPageListIndex or 1 end
    local want = self:isGroupPage(page) and self:groupRepresentative() or page
    for i, p in ipairs(self.enabledPages or {}) do
        if p == want then return i end
    end
    return 1
end

---The row count, answered from the same list the rows are drawn from. See the note above on why
-- this is overridden rather than left to the base.
function DistributionMenu:getNumberOfItemsInSection(list, section)
    if list == self.pagingTabList and SmartDistribution ~= nil and SmartDistribution.MENU_V2 == true then
        return #(self.enabledPages or {})
    end
    return DistributionMenu:superClass().getNumberOfItemsInSection(self, list, section)
end

---After a page change, put the left highlight on the row that page actually appears as.
--
-- The base sets it from the PAGING MAPPING index, which counts every enabled page including the
-- three members that have no row of their own -- so without this the highlight lands on whatever
-- row happens to share that number.
function DistributionMenu:onPageChange(pageIndex, pageMappingIndex, element, skipTabVisualUpdate)
    DistributionMenu:superClass().onPageChange(self, pageIndex, pageMappingIndex, element, skipTabVisualUpdate)
    if SmartDistribution == nil or SmartDistribution.MENU_V2 ~= true then return end
    if self:isGroupPage(self.currentPage) then self._groupLast = self.currentPage end
    if not skipTabVisualUpdate and self.pagingTabList ~= nil then
        pcall(function() self.pagingTabList:setSelectedIndex(self:listIndexOf(self.currentPage)) end)
    end
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
    -- `x` is read raw HERE now, not as an input action: its footer button (Cycle Output) was removed, and
    -- an action with no button has no binding. `z` was always raw. Both go through the same modifier
    -- guard, which tests the ctrl/alt/shift BITS -- every menu key press arrives with modifier = 4096, a
    -- Num Lock bit, so `modifier == 0` would reject everything (5.64, and it cost two builds).
    -- THE KEYS ARE NOW THE ONLY KEYBOARD ROUTE, on every page. "Cycle Output" was a footer entry that
    -- stepped the SELECTED row -- the same job the in-row arrows do, one step further from the thing it
    -- acts on -- so it is gone from Productions and Animal Husbandry as well (2026-08-26). The player
    -- steps the mode by clicking an arrow, or with `x` / `z` on the selected row.
    --
    -- That also removes the double-step hazard the BINDS_CYCLE_ACTION flag guarded: `x` IS MENU_EXTRA_1's
    -- binding, so while a page carried that button the key fired the action AND this handler. With no
    -- page binding it, the flag has nothing left to exclude and is gone with the buttons.
    if isDown and Input ~= nil and Input.KEY_x ~= nil and sym == Input.KEY_x
       and not realModifierHeld(modifier) then
        local p = self.currentPage
        if p ~= nil and p.MODE_KEYS_ENABLED ~= false and p.onCycleSelected ~= nil then
            p:onCycleSelected()
            return true
        end
    end
    if isDown and Input ~= nil and Input.KEY_z ~= nil and sym == Input.KEY_z
       and not realModifierHeld(modifier) then                         -- never swallow Ctrl+Z etc.
        local p = self.currentPage
        if p ~= nil and p.MODE_KEYS_ENABLED ~= false and p.onCycleSelectedBack ~= nil then
            p:onCycleSelectedBack()
            return true
        end
    end

    -- A / D STEP THE PAGE TAB STRIP, the way Q / E already step the LEFT icon list
    -- (MENU_PAGE_PREV / MENU_PAGE_NEXT are bound to those two in the base game's own
    -- keyboard defaults). So the two axes of navigation have neighbouring keys and the
    -- same shape, and the on-screen "< A" / "D >" hints at each end of the strip are
    -- what tell the player so.
    --
    -- A AND D ARE FREE IN A MENU, checked rather than assumed: the base defaults bind
    -- them only to AXIS_MOVE_SIDE_PLAYER, AXIS_MOVE_SIDE_VEHICLE, AXIS_MAP_SCROLL_LEFT_RIGHT
    -- and AXIS_CRANE_SUPPORT, every one of them a gameplay context that is not active here.
    --
    -- HANDLED AT THE MENU for the same reason z / x are: Gui:keyEvent dispatches to
    -- g_gui.currentListener and its target only, never down to a frame, so a keyEvent
    -- override on a PAGE is not reliably reached (5.64). The page supplies pageTabKey(),
    -- so one handler serves every tabbed page and no page knows about the keys.
    local step = nil
    if isDown and Input ~= nil and not realModifierHeld(modifier) then
        if Input.KEY_a ~= nil and sym == Input.KEY_a then step = -1
        elseif Input.KEY_d ~= nil and sym == Input.KEY_d then step = 1 end
    end
    if step ~= nil then
        local p = self.currentPage
        -- THE PAGE STEPS ITS OWN TABS. Asked duck-typed, so ANY page in this menu can answer,
        -- including one belonging to another mod: DR's pages inherit a default that drives the
        -- shared registry, and a mod with a tab strip of its own implements the method however it
        -- likes. Without this the keys would work on DR's pages and do nothing on a mod's, which
        -- is exactly the inconsistency a shared menu should not have.
        --
        -- pcall'd because this is third-party code reached from a key press: a throw here would
        -- propagate out of keyEvent.
        if p ~= nil and type(p.stepPageTabBy) == "function" then
            local okStep, moved = pcall(p.stepPageTabBy, p, step)
            -- Only claims the key if a tab ACTUALLY moved. A page with no strip on screen leaves
            -- A / D alone, so they never become keys that silently do nothing somewhere else.
            if okStep and moved == true then return true end
        end
    end

    return DistributionMenu:superClass().keyEvent(self, unicode, sym, modifier, isDown, eventUsed)
end

---A SECOND ICON IN THE CORNER OF ONE TAB.
--
-- WHY THIS OVERRIDE EXISTS AT ALL. A tab carries ONE icon slice
-- (TabbedMenu:addPageTab's fourth argument), and the base game's icons live as
-- SLICES inside dataS.gar -- so two of them cannot be merged into a file, and the
-- only way to show both is to draw both. This is the place that can.
--
-- IT IS PRECISELY SCOPED BY CONSTRUCTION, not by a guard. SmoothListElement takes
-- its data source from #listDataSource, defaulting to the element's TARGET; the
-- tab list in DistributionMenu.xml declares none, so its data source is this MENU
-- and this method serves the TAB LIST AND NOTHING ELSE. Every other list in the
-- mod sits inside a page and is populated by that page. So this is not the global
-- class hook 5.62 warns about -- no other menu in the game is touched.
--
-- WRITTEN AS A POST-STEP. The inherited populate runs FIRST and unchanged, so a
-- tab with no badge is byte-identical to before and a failure here can only cost
-- the badge, never the icon or the tab.
--
-- THE BASE IMPLEMENTATION IS STRIPPED FROM THE SDK SOURCE (8.1) -- there is not
-- one surviving populateCellForItemInSection anywhere in it, so the cell's own
-- structure could not be read. That is why the badge element is declared in the
-- ListItem template in OUR XML and only LOOKED UP here: creating an element blind
-- would be guessing at a profile and an anchor, while looking one up by name
-- either finds it or does nothing.
function DistributionMenu:populateCellForItemInSection(list, section, index, cell)
    DistributionMenu:superClass().populateCellForItemInSection(self, list, section, index, cell)
    if cell == nil then return end

    -- CELLS ARE RECYCLED, so this must CLEAR as well as set -- otherwise the badge
    -- follows whichever tab happens to reuse that cell, the same trap 5.7 and 5.57
    -- hit with colours and the notice row.
    local badge = nil
    if cell.getDescendantByName ~= nil then
        local ok, el = pcall(cell.getDescendantByName, cell, "tabBadge")
        if ok then badge = el end
    end
    if badge == nil then
        -- SAY SO ONCE. The template is ours, so a miss means the ListItem changed
        -- or the cell is not the element we think it is; without this the feature
        -- just silently does nothing, which is the hardest failure to diagnose.
        if not DistributionMenu._badgeWarned then
            DistributionMenu._badgeWarned = true
            print("[SmartDistribution] tab badge: no 'tabBadge' in the tab cell; badges disabled")
        end
        return
    end

    -- enabledPages is what rebuildTabList hands the list, in list order, so the
    -- row index selects the page directly.
    local page = (self.enabledPages or {})[index]
    local slice = page ~= nil and (self._tabBadges or {})[page] or nil
    -- A CUSTOM ICON SUPERSEDES THE BADGE. The badge exists for a page that is about two things
    -- and has only one stock slice to say so; a picture drawn for the page says both by itself,
    -- and wearing a corner badge as well would be saying it twice. This also lets a caller pass
    -- both unconditionally: an older menu with no icon support falls back to slice-plus-badge
    -- with no version test anywhere.
    local iconFile = page ~= nil and (self._tabIconFiles or {})[page] or nil
    if iconFile ~= nil then slice = nil end
    if slice ~= nil and badge.setImageSlice ~= nil then
        pcall(badge.setImageSlice, badge, nil, slice)
        badge:setVisible(true)
    else
        badge:setVisible(false)
    end

    -- ---- the tab's own icon ------------------------------------------------------------------
    -- BOTH BRANCHES ARE EXPLICIT, and that is deliberate. Cells are RECYCLED, so a file left on a
    -- cell would follow whichever tab reuses it -- and restoring the stock look is not "clear it",
    -- it is re-applying the slice the page was registered with. Whether the super call above
    -- re-applies it cannot be read (populateCellForItemInSection is stripped from the shipped
    -- source, 5.86), so this does not depend on it either way.
    local btn = nil
    if cell.getDescendantByName ~= nil then
        local ok, el = pcall(cell.getDescendantByName, cell, "tabButton")
        if ok then btn = el end
    end
    if btn ~= nil then
        if iconFile ~= nil and btn.setImageFilename ~= nil then
            pcall(btn.setImageFilename, btn, nil, iconFile)
            -- THE UVs MUST BE RESET TO THE WHOLE TEXTURE, and this was the whole bug: the
            -- button's icon overlay still carries the UV window of the ATLAS SLICE it was
            -- registered with, and setImageFilename does not touch it. createOverlay only swaps
            -- the image handle, deleteOverlay never looks at uvs, and loadOverlay sets
            -- DEFAULT_UVS only when uvs is nil. So a standalone picture was sampled through a
            -- small sub-rectangle of the atlas and stretched across the tab -- which renders as a
            -- washed out smear rather than as nothing, and THAT is the tell that the file was
            -- loading correctly all along.
            -- The base game states this exact case at MapOverlayGenerator.lua:602: "default crop
            -- type icons are separate files, use full texture".
            -- CLONED, never assigned by reference: DEFAULT_UVS is a shared global and Overlay.lua
            -- clones it for that reason. No literal fallback either -- its assignment is in the
            -- stripped part of the source, so a guessed UV set would fail looking exactly like the
            -- bug being fixed.
            if btn.setImageUVs ~= nil and Overlay ~= nil and Overlay.DEFAULT_UVS ~= nil then
                local uvs = (table.clone ~= nil) and table.clone(Overlay.DEFAULT_UVS)
                            or Overlay.DEFAULT_UVS
                pcall(btn.setImageUVs, btn, nil, uvs)
            end
        else
            local base = page ~= nil and (self._tabIconSlices or {})[page] or nil
            if base ~= nil and btn.setImageSlice ~= nil then
                pcall(btn.setImageSlice, btn, nil, base)
            end
        end
    end
end

---Give a page its own icon FILE instead of an atlas slice, or clear it with nil.
--
-- WHY A FILE AT ALL: a tab icon is normally `iconSliceId` on the button, and the atlas lives in
-- dataS.gar, so a mod cannot add a slice to it. The runtime setter is the only way in -- an
-- `imageFilename` attribute in a layout cannot name a file a mod ships either (5.80).
--
-- The picture must be WHITE LINE ART ON TRANSPARENCY, because the profile tints it: the tab
-- carries three different icon colours for normal, focused and selected. A picture with a solid
-- background renders as a tile, not an icon.
function DistributionMenu:setPageTabIcon(page, filename)
    if page == nil then return end
    self._tabIconFiles = self._tabIconFiles or {}
    -- Unchanged means nothing to rebuild. A rebuild repopulates every tab cell, so rebuilding for
    -- a no-op is not free (6.44).
    if self._tabIconFiles[page] == filename then return end
    self._tabIconFiles[page] = filename
    self:pinTabIconRecord(page)
    if self.rebuildTabList ~= nil then pcall(self.rebuildTabList, self) end
end

---Make the base tab RECORD agree with the icon file we paint, so the two stop fighting.
--
-- The inherited populate re-applies the icon from `self.pageTabs[page]` on EVERY populate. While
-- that record still named the atlas slice, each populate put the slice back and ours then put the
-- PNG back -- so the filename changed every time and GuiOverlay.createOverlay, which skips the
-- load only when the filename is unchanged (GuiOverlay.lua:292), reloaded the PNG from disk each
-- time. Writing the file onto the record means both sides set the same file and the reload is
-- skipped. The original slice is remembered on the record, so clearing the file puts it back.
function DistributionMenu:pinTabIconRecord(page)
    local tab = (self.pageTabs or {})[page]
    if tab == nil then return end
    local file = (self._tabIconFiles or {})[page]
    if file ~= nil then
        if not tab._drPinned then
            tab._drPinned = true
            tab._drOrigSlice, tab._drOrigFile, tab._drOrigUVs = tab.iconSliceId, tab.iconFilename, tab.iconUVs
        end
        tab.iconSliceId  = nil
        tab.iconFilename = file
        if Overlay ~= nil and Overlay.DEFAULT_UVS ~= nil then
            tab.iconUVs = (table.clone ~= nil) and table.clone(Overlay.DEFAULT_UVS) or Overlay.DEFAULT_UVS
        end
    elseif tab._drPinned then
        tab._drPinned = nil
        tab.iconSliceId, tab.iconFilename, tab.iconUVs = tab._drOrigSlice, tab._drOrigFile, tab._drOrigUVs
    end
end

---Give a page a corner badge, or clear it with nil. Applied on the next tab
-- rebuild; safe to call before the tab exists.
function DistributionMenu:setPageTabBadge(page, sliceId)
    if page == nil then return end
    self._tabBadges = self._tabBadges or {}
    self._tabBadges[page] = sliceId
    if self.rebuildTabList ~= nil then pcall(self.rebuildTabList, self) end
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
