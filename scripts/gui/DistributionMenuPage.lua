-- ============================================================================
-- DistributionMenuPage.lua  (Distribution Redux)
-- Shared base for the consolidated menu's pages. Extends TabbedMenuFrameElement
-- (the same base AutoDrive's settings pages and EasyDevControls' frames use), so
-- each page slots into the DistributionMenu (TabbedMenu) paging system and gets
-- proper footer buttons via setMenuButtonInfo.
--
-- Phase A: pages are placeholders (header + a note). Phase B fills each with the
-- content reproduced from the current popups (settings rows, help topics, the
-- storage/production lists + per-asset detail).
-- ============================================================================

DistributionMenuPage = {}
local DistributionMenuPage_mt = Class(DistributionMenuPage, TabbedMenuFrameElement)

function DistributionMenuPage.new(target, custom_mt)
    local self = TabbedMenuFrameElement.new(target, custom_mt or DistributionMenuPage_mt)
    self.pageName = "DISTREDUX_PAGE"
    return self
end

-- Per-page footer buttons. The menu also assigns Back/Next/Prev defaults, but a
-- page can override its own set in initialize(); Phase A just keeps Back.
function DistributionMenuPage:initialize()
    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK,
        text = (g_i18n ~= nil and g_i18n:getText("button_back")) or "Back",
    }
    self.menuButtonInfo = { self.backButtonInfo }
end

function DistributionMenuPage:onFrameOpen()
    DistributionMenuPage:superClass().onFrameOpen(self)
    self:setMenuButtonInfoDirty()

    self:setSoundSuppressed(true)
    if self.boxLayout ~= nil then
        FocusManager:setFocus(self.boxLayout)
    end
    self:setSoundSuppressed(false)
end

function DistributionMenuPage:onFrameClose()
    DistributionMenuPage:superClass().onFrameClose(self)
end

-- Capture the full footer button list when the menu assigns it, so pages can rebuild a FILTERED copy
-- (e.g. drop the Sell Timing button when the selected output isn't a sell mode) in updateSellTimingButton.
function DistributionMenuPage:setMenuButtonInfo(buttons)
    self._allButtons = buttons
    DistributionMenuPage:superClass().setMenuButtonInfo(self, buttons)
end

-- Re-assign the footer at runtime. Goes through the canonical (base-game) setMenuButtonInfo so the menu
-- actually re-registers/rebuilds the footer -- setting self.menuButtonInfo directly does NOT. We bypass
-- our own override above so _allButtons keeps the FULL set for the next toggle. Pages call this from
-- their updateSellTimingButton with the already-filtered list.
function DistributionMenuPage:applyFooterButtons(vis)
    DistributionMenuPage:superClass().setMenuButtonInfo(self, vis)
    if self.setMenuButtonInfoDirty ~= nil then self:setMenuButtonInfoDirty() end
end

-- Hide each list's scrollbar TRACK (fs25_listSliderBox) whenever that list has no overflow. A list
-- needs the bar only when its item count exceeds the whole rows that fit in its frame. Each page sets
-- self._scrollMap = { { sliderId, listId, rowsThatFit }, ... } in onGuiSetupFinished; this runs for all.
-- Real-time number refresh. A page opts in by setting self._realtimeLists = { "inputList", "detailList" }
-- (the lists whose CELLS show live figures -- never the asset-picker list). Every REALTIME_REFRESH_MS the
-- open page re-reads those cells so held / distributed / sold track the game without a tab-switch. Cheap:
-- it is the same SmoothList:reloadData the page already runs on a selection change, just throttled to ~2 Hz,
-- and the selected row is preserved so it never fights the player's navigation. Note the distribution
-- figures themselves only change on the hourly pass; between hours this mainly keeps held-litres live.
DistributionMenuPage.REALTIME_REFRESH_MS = 500

-- ---- adaptive backoff -------------------------------------------------------
-- The "Menu refresh rate" setting cannot be the whole answer to a farm too big to refresh, because it sits
-- BEHIND the menu: a player whose menu is unusable cannot reach the control that would make it usable.
-- Defaulting the setting to Manual would dodge that, but at the cost of every NORMAL farm silently showing
-- stale figures, which most players would read as the mod being broken.
--
-- So the menu measures itself instead and paces its own refreshes to what the farm can actually afford. A
-- normal farm never leaves the rate the player chose; a pathological one settles within a few refreshes at
-- a pace it can sustain, with no setting to find. The chosen rate is a FLOOR -- this only ever stretches
-- the interval, never tightens it past what was asked for.
--
-- Class-level, not per-page, because it is a property of the FARM: what the Overview learns the building
-- tabs should not have to re-learn by hitching again.
-- The rule is a DUTY CYCLE, not a threshold: never spend more than 1/REFRESH_DUTY of wall-clock time
-- refreshing. So the interval is proportional to what a refresh actually costs, which is what makes the
-- response proportionate -- a 140 ms refresh stretches to ~2.8 s and stays usefully live, where a
-- doubling-on-threshold scheme jumped it straight to the cap and made the figures needlessly stale. A
-- genuinely pathological 4 s refresh lands on the MAX_INTERVAL cap, i.e. effectively manual.
--
-- The cost is SMOOTHED, so one unlucky frame (a GC pause, a stutter from elsewhere) cannot pin the
-- interval; it decays back within a few refreshes.
DistributionMenuPage.REFRESH_DUTY  = 20      -- at most 1/20th (5%) of the time spent refreshing
DistributionMenuPage.MAX_INTERVAL  = 60      -- never stretch beyond a minute
DistributionMenuPage.COST_SMOOTH   = 0.5     -- weight of the newest sample
DistributionMenuPage._refreshCost  = 0

function DistributionMenuPage.resetRefreshPacing()
    DistributionMenuPage._refreshCost = 0
end

function DistributionMenuPage.noteRefreshCost(sec)
    if type(sec) ~= "number" or sec < 0 then return end
    local s = DistributionMenuPage.COST_SMOOTH
    DistributionMenuPage._refreshCost = (DistributionMenuPage._refreshCost or 0) * (1 - s) + sec * s
end

-- Seconds between background refreshes, from the "Menu refresh rate" setting; nil means "do not refresh on
-- a timer at all" (Manual only). The setting exists because this cost scales with the farm: re-populating
-- the number cells re-reads live held / capacity / link status for every visible row, and on the Overview it
-- re-enumerates the whole network. Falls back to the old hardcoded rate when the setting is unavailable, so
-- nothing depends on load order.
function DistributionMenuPage.refreshSeconds()
    local g = (SmartDistribution ~= nil and SmartDistribution.settings ~= nil)
        and SmartDistribution.settings.global or nil
    local v = g ~= nil and g.menuRefresh or nil
    if type(v) ~= "number" then v = DistributionMenuPage.REALTIME_REFRESH_MS / 1000 end
    if v < 0 then return nil end                       -- manual only: there is nothing to pace
    -- the player's rate is a FLOOR, never a ceiling: this only ever stretches the interval, so choosing
    -- Live on a farm that can afford it still gets Live
    local want = (DistributionMenuPage._refreshCost or 0) * DistributionMenuPage.REFRESH_DUTY
    if want < v then want = v end
    if want > DistributionMenuPage.MAX_INTERVAL then want = DistributionMenuPage.MAX_INTERVAL end
    return want
end

-- ---- shared Hour / Month / Year selector ------------------------------------
-- The building tabs (Silos, Animal Husbandry, Markets, Productions) each carry a `periodOption`
-- MultiTextOption that rescopes their RECEIVED / CONSUMED / PRODUCED / DISTRIBUTED figures, exactly like
-- the Overview tab's. The windows are DR's own: a cycle is an hour, a month is 24 of them.
-- Lives on the base page so all four share one implementation; pages without the widget just no-op.
DistributionMenuPage.PERIODS       = { "hour", "month", "year" }
-- English fallbacks. The live labels are built per call by periodLabels(), because l10n is
-- not necessarily up when this chunk loads.
DistributionMenuPage.PERIOD_LABELS = { "Cycle (hour)", "Month", "Year" }
DistributionMenuPage.PERIOD_KEYS   = { "dr_period_hourLong", "dr_period_month", "dr_period_year" }
function DistributionMenuPage.periodLabels()
    if SmartDistribution == nil or SmartDistribution.l10n == nil then return DistributionMenuPage.PERIOD_LABELS end
    local out = {}
    for i, fb in ipairs(DistributionMenuPage.PERIOD_LABELS) do
        out[i] = SmartDistribution.l10n(DistributionMenuPage.PERIOD_KEYS[i], fb)
    end
    return out
end

function DistributionMenuPage:initPeriodOption()
    self.periodIndex = self.periodIndex or 2          -- default Month: what these columns showed before
    local opt = self.periodOption
    if opt == nil or opt.setTexts == nil then return end
    opt:setTexts(DistributionMenuPage.periodLabels())
    if opt.setState ~= nil then pcall(function() opt:setState(self.periodIndex) end) end
end

function DistributionMenuPage:currentWindow()
    return DistributionMenuPage.PERIODS[self.periodIndex or 2] or "month"
end

-- Figures for one (product) of the selected building over the chosen window. Always returns a full
-- table, so callers never have to nil-check a field.
function DistributionMenuPage:windowStats(ft)
    if SmartDistribution == nil or SmartDistribution.assetWindowStats == nil or self.selectedAsset == nil then
        return {}
    end
    local ok, e = pcall(SmartDistribution.assetWindowStats, self.selectedAsset, ft, self:currentWindow())
    return (ok and type(e) == "table") and e or {}
end

function DistributionMenuPage:onPeriodChanged(state)
    local opt = self.periodOption
    if type(state) ~= "number" and opt ~= nil and opt.getState ~= nil then state = opt:getState() end
    if type(state) == "number" and state >= 1 and state <= #DistributionMenuPage.PERIODS then
        self.periodIndex = state
    end
    -- pages cache their row figures in different places; rebuilding is what each already does on a
    -- selection change, so reuse that path where it exists and always repaint the lists
    if self.rebuildRealtimeData ~= nil then pcall(function() self:rebuildRealtimeData() end) end
    for _, name in ipairs(self._realtimeLists or {}) do
        local list = self[name]
        if list ~= nil and list.reloadData ~= nil then pcall(function() list:reloadData() end) end
    end
end

function DistributionMenuPage:refreshRealtimeLists()
    local names = self._realtimeLists
    if names == nil or self._focusing then return end   -- _focusing: a selection event is mid-flight; skip
    -- Timed as ONE unit: the row rebuild and the cell repopulate are both part of what a refresh costs the
    -- frame, and it is the total the player feels. Two getTimeSec reads, so the measurement is free.
    local _t0 = (getTimeSec ~= nil) and getTimeSec() or nil
    -- Pages that CACHE their row figures (e.g. Productions stores received/produced/sold in row objects it
    -- builds on selection) recompute them here; pages whose populate reads live (e.g. Storage) need nothing.
    if self.rebuildRealtimeData ~= nil then pcall(function() self:rebuildRealtimeData() end) end
    -- reloadData re-runs populateCellForItemInSection for the visible cells and keeps the selected index for
    -- an unchanged row count -- which holds here, since a refresh never changes WHICH products an asset has.
    -- BUT reloadData ALSO synchronously re-fires each list's onListSelectionChanged (see _focusOn's recursion
    -- note), and that handler calls _focusOn -> FocusManager:setFocus. Left unguarded, the refresh yanks
    -- keyboard focus onto whichever list is reloaded LAST every ~500 ms, overriding the row the player picked
    -- (input<->output oscillation). Hold the _focusing guard across the whole reload so those re-fired
    -- handlers no-op on focus (every page's _focusOn early-returns while _focusing) and the player's selection
    -- is left exactly where they put it.
    self._focusing = true
    for i = 1, #names do
        local list = self[names[i]]
        if list ~= nil and list.reloadData ~= nil then
            pcall(function() list:reloadData() end)
        end
    end
    self._focusing = false
    if _t0 ~= nil then DistributionMenuPage.noteRefreshCost(getTimeSec() - _t0) end
end

function DistributionMenuPage:update(dt)
    local sc = DistributionMenuPage:superClass()
    if sc.update ~= nil then sc.update(self, dt) end

    -- throttled real-time refresh of the open page's number lists. Wall-clock (getTimeSec, real seconds) so
    -- it is immune to whatever units dt is in.
    -- A production's cached v-mode was just re-derived (the server's uid map or a replayed override landed
    -- mid-join, see invalidateSeededVModes). Repaint NOW rather than waiting out the refresh interval --
    -- and do it even under "Manual only", because this is not a stale FIGURE, it is a stale MODE, and
    -- pressing Cycle Output against it would step from the wrong value and write that back to the server.
    if self._realtimeLists ~= nil and SmartDistribution ~= nil then
        local ep = SmartDistribution._vmodeEpoch or 0
        if self._vmodeEpochSeen ~= ep then
            self._vmodeEpochSeen = ep
            self._rtLast = (getTimeSec ~= nil) and getTimeSec() or self._rtLast   -- also restarts the throttle
            pcall(function() self:refreshRealtimeLists() end)
        end
    end

    local every = DistributionMenuPage.refreshSeconds()      -- nil = Manual only: no background refresh
    if self._realtimeLists ~= nil and every ~= nil then
        local now = (getTimeSec ~= nil) and getTimeSec() or nil
        if now ~= nil then
            if self._rtLast == nil or (now - self._rtLast) >= every then
                self._rtLast = now
                pcall(function() self:refreshRealtimeLists() end)
            end
        else
            -- no clock: fall back to accumulating dt (assumes dt in ms)
            self._rtAccum = (self._rtAccum or 0) + (dt or 0)
            if self._rtAccum >= every * 1000 then
                self._rtAccum = 0
                pcall(function() self:refreshRealtimeLists() end)
            end
        end
    end

    local map = self._scrollMap
    if map == nil or self.getNumberOfItemsInSection == nil then return end
    for i = 1, #map do
        local e = map[i]
        local slider, list = self[e[1]], self[e[2]]
        if slider ~= nil and slider.parent ~= nil and list ~= nil then
            slider.parent:setVisible(self:getNumberOfItemsInSection(list, 1) > e[3])
        end
    end
end
