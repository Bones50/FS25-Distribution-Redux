-- ============================================================================
-- DistributionSettingsPage.lua  (Distribution Redux) -- Settings tab
-- Reproduces the global settings (the same rows currently injected into the
-- game's options page) as in-frame left/right selectors. Reuses the existing
-- engine logic verbatim:
--   - DistributionSettings.SETTINGS  : definitions (label/tooltip/values/strings)
--   - DistributionSettings.getStateIndex(id) : current selector index
--   - DistributionControls:onMenuOptionChanged(state, element) : apply+save+sync
-- Each selector's XML id is the setting key, so onMenuOptionChanged resolves it.
-- ============================================================================

DistributionSettingsPage = {}
local DistributionSettingsPage_mt = Class(DistributionSettingsPage, DistributionMenuPage)

function DistributionSettingsPage.new(target, custom_mt)
    local self = DistributionMenuPage.new(target, custom_mt or DistributionSettingsPage_mt)
    self.pageName = "DISTREDUX_SETTINGS"
    self.settingElements = {}   -- id -> MultiTextOption element
    self.isEvenRow = false
    return self
end

-- onCreate (per row container): subtle alternating tint, matching the base look
function DistributionSettingsPage:onCreateSettingRow(element)
    local pal = (InGameMenuSettingsFrame ~= nil) and InGameMenuSettingsFrame.COLOR_ALTERNATING or nil
    if pal ~= nil and pal[self.isEvenRow] ~= nil and element.setImageColor ~= nil then
        element:setImageColor(nil, table.unpack(pal[self.isEvenRow]))
    end
    self.isEvenRow = not self.isEvenRow
end

-- onCreate (per selector): id == setting key; register it
function DistributionSettingsPage:onCreateSetting(element)
    if element ~= nil and element.id ~= nil and element.id ~= "" then
        self.settingElements[element.id] = element
    end
end

function DistributionSettingsPage:onGuiSetupFinished()
    DistributionSettingsPage:superClass().onGuiSetupFinished(self)
    if DistributionSettings == nil then return end
    -- Resolve each selector by setting key. self[id] is auto-exposed from the XML
    -- id attribute (reliable); settingElements (from onCreate) is a fallback.
    for id, def in pairs(DistributionSettings.SETTINGS) do
        local element = self.settingElements[id] or self[id]
        if element ~= nil and element.setTexts ~= nil then
            self.settingElements[id] = element
            -- Value labels come from l10n by CONVENTION: entry N of def.strings is key
            -- "dr_set_<id>_vN". Convention rather than a parallel array of keys so the two
            -- can never drift apart -- a misaligned array would relabel options silently,
            -- and the option ORDER is load-bearing (it indexes def.values, and the INDEX is
            -- what the save file and the multiplayer settings event carry, not the label).
            -- def.strings stays the English fallback, so with no translation installed this
            -- produces byte-identical text to before.
            -- The row's TITLE and TOOLTIP are not set here: they live in the XML as
            -- $l10n_dr_set_<id> / _tt and the engine resolves them at load.
            local labels = def.strings
            if SmartDistribution ~= nil and SmartDistribution.l10n ~= nil then
                labels = {}
                for i = 1, #def.strings do
                    labels[i] = SmartDistribution.l10n(string.format("dr_set_%s_v%d", id, i), def.strings[i])
                end
            end
            element:setTexts(labels)
            if DistributionSettings._optionById ~= nil then
                DistributionSettings._optionById[id] = element
            end
        end
    end
end

function DistributionSettingsPage:onFrameOpen()
    DistributionSettingsPage:superClass().onFrameOpen(self)
    if DistributionSettings == nil or DistributionSettings.getStateIndex == nil then return end
    for id, element in pairs(self.settingElements) do
        if element.setState ~= nil then
            pcall(function() element:setState(DistributionSettings.getStateIndex(id)) end)
        end
    end
end

-- onClick from a selector: hand off to the shared apply/save/MP-sync logic.
function DistributionSettingsPage:onOptionChanged(state, element)
    if DistributionControls ~= nil and DistributionControls.onMenuOptionChanged ~= nil then
        DistributionControls:onMenuOptionChanged(state, element)
    end
end
