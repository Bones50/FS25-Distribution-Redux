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

function DistributionMenuPage:refreshRealtimeLists()
    local names = self._realtimeLists
    if names == nil or self._focusing then return end   -- _focusing: a selection event is mid-flight; skip
    -- Pages that CACHE their row figures (e.g. Productions stores received/produced/sold in row objects it
    -- builds on selection) recompute them here; pages whose populate reads live (e.g. Storage) need nothing.
    if self.rebuildRealtimeData ~= nil then pcall(function() self:rebuildRealtimeData() end) end
    -- reloadData re-runs populateCellForItemInSection for the visible cells and keeps the selected index for
    -- an unchanged row count -- which holds here, since a refresh never changes WHICH products an asset has.
    for i = 1, #names do
        local list = self[names[i]]
        if list ~= nil and list.reloadData ~= nil then
            pcall(function() list:reloadData() end)
        end
    end
end

function DistributionMenuPage:update(dt)
    local sc = DistributionMenuPage:superClass()
    if sc.update ~= nil then sc.update(self, dt) end

    -- throttled real-time refresh of the open page's number lists. Wall-clock (getTimeSec, real seconds) so
    -- it is immune to whatever units dt is in.
    if self._realtimeLists ~= nil then
        local now = (getTimeSec ~= nil) and getTimeSec() or nil
        if now ~= nil then
            if self._rtLast == nil or (now - self._rtLast) >= (DistributionMenuPage.REALTIME_REFRESH_MS / 1000) then
                self._rtLast = now
                pcall(function() self:refreshRealtimeLists() end)
            end
        else
            -- no clock: fall back to accumulating dt (assumes dt in ms)
            self._rtAccum = (self._rtAccum or 0) + (dt or 0)
            if self._rtAccum >= DistributionMenuPage.REALTIME_REFRESH_MS then
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
