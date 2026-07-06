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
