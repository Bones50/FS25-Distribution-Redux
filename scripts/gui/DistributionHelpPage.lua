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

-- Heading sizes, as a multiple of the body size the profile resolves to: a main heading is TWICE the
-- body, a sub-heading one and a half times it.
--
-- These exceed the 27px row pitch (a 16px body gives a 32px main heading) and that is fine: text is only
-- clipped to its box in SCROLLING layout mode, which these cells do not use, so the glyphs simply reach
-- up into the blank row that always sits above a heading. Raising the row height instead would have
-- spaced every BODY line to match the tallest heading, which is the wrong trade for a wall of prose.
local HEAD_SCALE = { h1 = 1.4, h2 = 1.05 }

-- Word-wrap width for the body pane, in CHARACTERS (the wrap is character-based, not measured).
-- The text element is 1168px wide and the body renders at 16px, where the UI font averages roughly
-- 7.5px a character -- so the pane holds about 155 characters and 112 was filling barely two thirds of
-- it, leaving the reported blank third on the right.
--
-- The CEILING is not the pane edge but the engine's auto-shrink: TextElement reduces textSize in 5%
-- steps for any line too wide for its box, so a wrap set even slightly too generous does not overflow,
-- it silently renders scattered lines smaller than their neighbours. 150 leaves a small margin against
-- that. If any line ever does look undersized, lower this rather than hunting elsewhere.
local WRAP_COLS = 150

---THE PAGE KEY this tab strip registers under. Another mod adds its own guide
-- with SmartDistribution.registerPageTab("help", modName, label, { topics = ... }).
DistributionHelpPage.TAB_KEY = "help"

---DR's own tab is registered once, and FIRST, so it is always index 1 and the
-- page can never come up with no tabs at all.
local function ownTab()
    if SmartDistribution == nil or SmartDistribution.registerPageTab == nil then return end
    SmartDistribution.registerPageTab(DistributionHelpPage.TAB_KEY, "FS25_Distribution_Redux",
        SmartDistribution.l10n("dr_tab_distribution", "DISTRIBUTION"), { own = true })
end

---The tabs to draw, and their labels.
local function tabList()
    if SmartDistribution == nil or SmartDistribution.pageTabs == nil then return {} end
    return SmartDistribution.pageTabs(DistributionHelpPage.TAB_KEY)
end

---THE TOPICS OF WHICHEVER TAB IS ACTIVE.
--
-- This was the whole seam: every read went through one local, so pointing it at
-- the active tab is all that was needed to make a second guide possible. DR's own
-- tab reads DistributionHelpDialog.TOPICS as before; a registered tab supplies its
-- own `topics`, either as a table or as a function returning one (so a mod can
-- build its guide lazily rather than at registration time).
local function topics(page)
    local idx = (page ~= nil and page.currentTab) or 1
    local t = tabList()[idx]
    if t ~= nil and not (t.entry or {}).own then
        local src = (t.entry or {}).topics
        if type(src) == "function" then
            local ok, v = pcall(src)
            if ok and type(v) == "table" then return v end
            return {}
        end
        if type(src) == "table" then return src end
        return {}
    end
    return (DistributionHelpDialog ~= nil and DistributionHelpDialog.TOPICS) or {}
end

function DistributionHelpPage.new(target, custom_mt)
    local self = DistributionMenuPage.new(target, custom_mt or DistributionHelpPage_mt)
    self.pageName = "DISTREDUX_HELP"
    self.currentTopic = 1
    self.currentTab = 1
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
    self._scrollMap = { { "topicSlider", "topicList", 14 }, { "bodyListSlider", "bodyList", 25 } }
end

function DistributionHelpPage:selectTopic(index)
    local T = topics(self)
    if index == nil or T[index] == nil then return end
    self.currentTopic = index
    if DistributionHelpDialog ~= nil and DistributionHelpDialog.buildLines ~= nil then
        -- translated per paragraph; falls back to the English body key by key
        local body = (DistributionHelpDialog.localisedBody ~= nil)
                     and DistributionHelpDialog.localisedBody(T[index]) or T[index].body
        self.lines = DistributionHelpDialog.buildLines(body, WRAP_COLS) or {}
    end
    if self.bodyTitleElement ~= nil then
        local ttl = (DistributionHelpDialog.localisedTitle ~= nil)
                    and DistributionHelpDialog.localisedTitle(T[index]) or (T[index].title or "")
        self.bodyTitleElement:setText(ttl:upper())
    end
    if self.bodyList ~= nil then self.bodyList:reloadData() end
end

function DistributionHelpPage:onFrameOpen()
    DistributionHelpPage:superClass().onFrameOpen(self)
    -- Re-read helpGuide.txt on every open, so editing the text file and reopening this tab is enough --
    -- no restart. One small file read against a list rebuild that was happening anyway.
    if DistributionHelpDialog ~= nil and DistributionHelpDialog.reload ~= nil then
        pcall(DistributionHelpDialog.reload)
    end
    ownTab()
    self:refreshPageTabs()
    -- the file may now have fewer tabs than last time; keep the selection in range
    local n = #topics(self)
    if self.currentTopic == nil or self.currentTopic > n then self.currentTopic = 1 end
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
    if list == self.topicList then return #topics(self) end
    return #self.lines
end

function DistributionHelpPage:populateCellForItemInSection(list, section, index, cell)
    if list == self.topicList then
        local t = topics(self)[index]
        local nameCell = cell:getAttribute("topicName")
        if nameCell ~= nil and t ~= nil then
            nameCell:setText((DistributionHelpDialog.localisedTitle ~= nil)
                             and DistributionHelpDialog.localisedTitle(t) or (t.title or "?"))
        end
    else
        local row = self.lines[index]
        local lineCell = cell:getAttribute("bodyLine")
        if lineCell ~= nil and row ~= nil then
            local isHead = row.head == true

            -- BOLD IS A FIELD, NOT A SETTER. TextElement has no setTextBold -- it exposes `textBold` and
            -- reads it at draw time (the setTextBold(...) calls in the base source are the render API, a
            -- global, not a method). The old code here called lineCell:setTextBold(...) inside a pcall,
            -- so it failed silently on every row and headings were NEVER bold: they only stood out
            -- because they were force-upper-cased, and removing that left them identical to body text.
            -- Set BEFORE setText so its text-fitting measures the bold glyphs it will actually draw.
            lineCell.textBold = isHead
            lineCell:setText(row.text or "")
            -- Sub-headings are bold AND larger, the way the base game separates a heading from its body
            -- (its dialog body is 16px against a bold 24px title). Weight alone was doing all the work
            -- here, which is why the guide previously had to SHOUT its headings to make them stand out.
            --
            -- Scaled from the element's OWN resolved size rather than set in pixels: setTextSize takes
            -- normalized screen units, not the "16px" the profile is authored in, so a raw pixel number
            -- would be wildly wrong. Captured once per element, on first use.
            -- Set on BOTH branches, never just the heading one -- SmoothList RECYCLES cells, so a size
            -- left applied would leak onto whatever body line reused that row (the same trap the
            -- Overview's colour cells already had to fix).
            -- SIZE. Read the base from `defaultTextSize`, not `textSize`: setText RESETS textSize to
            -- defaultTextSize on every call and the auto-fit shrinks textSize for a line too long for its
            -- box, so capturing textSize could bank an already-shrunk value and compound it. Applied
            -- AFTER setText for the same reason -- setText would otherwise wipe it.
            if lineCell.setTextSize ~= nil then
                if lineCell._sdBaseTextSize == nil then
                    lineCell._sdBaseTextSize = lineCell.defaultTextSize or lineCell.textSize
                end
                local base = lineCell._sdBaseTextSize
                if base ~= nil then
                    -- level is "h1" / "h2" / nil; the `or (isHead and h1)` keeps a row carrying only the
                    -- old boolean rendering as a main heading
                    local scale = HEAD_SCALE[row.level] or (isHead and HEAD_SCALE.h1) or 1
                    -- defaultTextSize is written TOO, not just textSize, and that is what makes the size
                    -- stick. setText resets `textSize = defaultTextSize` on every call, so any later
                    -- re-setText (a relayout, a scroll repopulate) silently reverted the heading to body
                    -- size -- while textBold, being a plain field, survived. That asymmetry is exactly
                    -- the "it went bold but never got bigger" symptom.
                    pcall(function()
                        lineCell.defaultTextSize = base * scale
                        lineCell:setTextSize(base * scale)
                    end)
                end
            end

            -- COLOUR. Headings go white against the body's lighter grey (SDBodyCell is
            -- $preset_fs25_colorMainLight), which is the third signal after weight and size. The profile
            -- colour is captured once and restored on every non-heading row -- cells are RECYCLED, so
            -- setting white without ever setting it back would bleed onto the body lines that follow.
            if lineCell.setTextColor ~= nil then
                if lineCell._sdBaseColor == nil and type(lineCell.textColor) == "table" then
                    local c = lineCell.textColor
                    lineCell._sdBaseColor = { c[1], c[2], c[3], c[4] }
                end
                local c = lineCell._sdBaseColor
                pcall(function()
                    if isHead then lineCell:setTextColor(1, 1, 1, 1)
                    elseif c ~= nil then lineCell:setTextColor(c[1], c[2], c[3], c[4]) end
                end)
            end
        end
    end
end

---Paint the strip from the registry.
function DistributionHelpPage:refreshPageTabs()
    local list, labels = tabList(), {}
    for i, t in ipairs(list) do labels[i] = t.label end
    if self.currentTab == nil or self.currentTab > #list then self.currentTab = 1 end
    if SmartDistribution ~= nil and SmartDistribution.drawPageTabs ~= nil then
        SmartDistribution.drawPageTabs(self, labels, self.currentTab)
    end
end

---Switch guide. The topic selection is reset rather than carried across, because
-- topic 4 of DR's guide has nothing to do with topic 4 of anyone else's.
function DistributionHelpPage:selectPageTab(i)
    if i == nil or i == self.currentTab then return end
    if tabList()[i] == nil then return end
    self.currentTab   = i
    self.currentTopic = 1
    self:refreshPageTabs()
    if self.topicList ~= nil then self.topicList:reloadData() end
    self:selectTopic(1)
end

function DistributionHelpPage:onPageTab1() self:selectPageTab(1) end
function DistributionHelpPage:onPageTab2() self:selectPageTab(2) end
function DistributionHelpPage:onPageTab3() self:selectPageTab(3) end
function DistributionHelpPage:onPageTab4() self:selectPageTab(4) end

function DistributionHelpPage:onListSelectionChanged(list, section, index)
    if list == self.topicList then self:selectTopic(index) end
end

function DistributionHelpPage:onClickTopic(element) end
function DistributionHelpPage:onClickBodyRow(element) end
