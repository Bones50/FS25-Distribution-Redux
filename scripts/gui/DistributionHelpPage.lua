-- ============================================================================
-- DistributionHelpPage.lua  (Distribution Redux) -- Help tab
-- Two-pane user guide: left = topic list (TOC), right = the selected topic's
-- word-wrapped body. Reuses the content and wrapping from the existing help
-- dialog (DistributionHelpDialog.TOPICS / .buildLines), so there's one source
-- of truth for the guide text. Same SmoothList delegate pattern (two lists told
-- apart by identity) the dialog already uses successfully.
-- ============================================================================

DistributionHelpPage = {}
local DistributionHelpPage_mt = Class(DistributionHelpPage, DistributionMenuPage)

local function topics()
    return (DistributionHelpDialog ~= nil and DistributionHelpDialog.TOPICS) or {}
end

function DistributionHelpPage.new(target, custom_mt)
    local self = DistributionMenuPage.new(target, custom_mt or DistributionHelpPage_mt)
    self.pageName = "DISTREDUX_HELP"
    self.currentTopic = 1
    self.lines = {}
    return self
end

function DistributionHelpPage:onGuiSetupFinished()
    DistributionHelpPage:superClass().onGuiSetupFinished(self)
    if self.topicList ~= nil then
        self.topicList:setDataSource(self)
        self.topicList:setDelegate(self)
    end
    if self.bodyList ~= nil then
        self.bodyList:setDataSource(self)
        self.bodyList:setDelegate(self)
    end
end

function DistributionHelpPage:selectTopic(index)
    local T = topics()
    if index == nil or T[index] == nil then return end
    self.currentTopic = index
    if DistributionHelpDialog ~= nil and DistributionHelpDialog.buildLines ~= nil then
        self.lines = DistributionHelpDialog.buildLines(T[index].body, 112) or {}
    end
    if self.bodyTitleElement ~= nil then
        self.bodyTitleElement:setText((T[index].title or ""):upper())
    end
    if self.bodyList ~= nil then self.bodyList:reloadData() end
end

function DistributionHelpPage:onFrameOpen()
    DistributionHelpPage:superClass().onFrameOpen(self)
    if self.topicList ~= nil then self.topicList:reloadData() end
    self:selectTopic(self.currentTopic or 1)

    self:setSoundSuppressed(true)
    if self.topicList ~= nil then
        FocusManager:setFocus(self.topicList)
        if self.topicList.setSelectedIndex ~= nil then
            pcall(function() self.topicList:setSelectedIndex(self.currentTopic or 1) end)
        end
    end
    self:setSoundSuppressed(false)
end

-- ---- SmoothList delegate (two lists, told apart by identity) ----------------
function DistributionHelpPage:getNumberOfItemsInSection(list, section)
    if list == self.topicList then return #topics() end
    return #self.lines
end

function DistributionHelpPage:populateCellForItemInSection(list, section, index, cell)
    if list == self.topicList then
        local t = topics()[index]
        local nameCell = cell:getAttribute("topicName")
        if nameCell ~= nil and t ~= nil then nameCell:setText(t.title or "?") end
    else
        local row = self.lines[index]
        local lineCell = cell:getAttribute("bodyLine")
        if lineCell ~= nil and row ~= nil then
            lineCell:setText(row.text or "")
            if lineCell.setTextBold ~= nil then
                pcall(function() lineCell:setTextBold(row.head == true) end)
            end
        end
    end
end

function DistributionHelpPage:onListSelectionChanged(list, section, index)
    if list == self.topicList then self:selectTopic(index) end
end

function DistributionHelpPage:onClickTopic(element) end
function DistributionHelpPage:onClickBodyRow(element) end
