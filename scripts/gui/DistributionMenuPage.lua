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
function DistributionMenuPage:update(dt)
    local sc = DistributionMenuPage:superClass()
    if sc.update ~= nil then sc.update(self, dt) end
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
