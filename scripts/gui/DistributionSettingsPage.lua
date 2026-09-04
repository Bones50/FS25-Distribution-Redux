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
    self.settingElements = {}
    self.currentTab = 1   -- id -> MultiTextOption element
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
                    local s = SmartDistribution.l10n(string.format("dr_set_%s_v%d", id, i), def.strings[i])
                    -- A MONEY-VALUED setting carries a "%s" and the AMOUNT is formatted by the GAME, so
                    -- the player sees their own currency. FS25 takes the currency from the SAVEGAME, not
                    -- the language, so baking a symbol into any translation would be wrong even for an
                    -- English player using euros. Reported 2026-08-27 against "$10 /h".
                    -- pcall'd and guarded on the "%s" actually being there: a translation that drops the
                    -- placeholder then shows the unsubstituted string rather than throwing mid-populate.
                    if def.money and def.values ~= nil and def.values[i] ~= nil and s:find("%%s") then
                        local amount = tostring(def.values[i])
                        if SmartDistribution.formatMoney ~= nil then
                            local ok, m = pcall(SmartDistribution.formatMoney, def.values[i])
                            if ok and type(m) == "string" and m ~= "" then amount = m end
                        end
                        local ok2, out = pcall(string.format, s, amount)
                        if ok2 and type(out) == "string" then s = out end
                    end
                    labels[i] = s
                end
            end
            element:setTexts(labels)
            if DistributionSettings._optionById ~= nil then
                DistributionSettings._optionById[id] = element
            end
        end
    end
end

---THE PAGE KEY this tab strip registers under. Another mod adds its own settings
-- with SmartDistribution.registerPageTab("settings", modName, label, entry).
--
-- DELIBERATELY NO CONTENT PROTOCOL YET. DR's settings rows are hand authored in
-- gui/DistributionSettingsPage.xml, one block per setting, resolved by element id
-- (5.41) -- so a foreign mod cannot add rows to this page and would have to bring
-- its own. What the right shape is depends on what AR's settings turn out to look
-- like, and inventing the contract before there is a caller is how it gets
-- invented wrong. The strip, the registry and the switching are here; the entry
-- table is passed through untouched for whoever fills it.
DistributionSettingsPage.TAB_KEY = "settings"

local function ownTab()
    if SmartDistribution == nil or SmartDistribution.registerPageTab == nil then return end
    SmartDistribution.registerPageTab(DistributionSettingsPage.TAB_KEY, "FS25_Distribution_Redux",
        SmartDistribution.l10n("dr_tab_distribution", "DISTRIBUTION"), { own = true })
end

local function tabList()
    if SmartDistribution == nil or SmartDistribution.pageTabs == nil then return {} end
    return SmartDistribution.pageTabs(DistributionSettingsPage.TAB_KEY)
end

---HOW MANY EXTENSION ROWS the layout declares. Unused slots are HIDDEN rather
-- than repositioned, the same rule PAGE_TAB_MAX follows for the strip above.
-- Published on SmartDistribution so the API validator and this page agree about
-- the cap without either owning a second copy of the number.
DistributionSettingsPage.EXT_ROW_MAX = 12
if SmartDistribution ~= nil then
    SmartDistribution.PAGE_SETTING_ROW_MAX = DistributionSettingsPage.EXT_ROW_MAX
end

---The four elements of extension row `i`. Resolved by the XML id, which the
-- engine auto-exposes on the page, with getDescendantByName as the fallback for
-- a build where that exposure does not happen. Cached, because this is asked per
-- row per page open and the tree does not change after load.
--
-- A LOCAL FUNCTION DECLARED ABOVE ITS FIRST USE. A local referenced before its
-- declaration parses clean and resolves to a nil GLOBAL, throwing only when
-- reached -- which inside a GUI populate aborts the render and shows as an empty
-- page, a symptom nothing like its cause (5.44 / 5.57).
local function extRow(self, i)
    self._extRows = self._extRows or {}
    local cached = self._extRows[i]
    if cached ~= nil then return cached end

    local function byName(n)
        local e = self[n]
        if e == nil and self.boxLayout ~= nil and self.boxLayout.getDescendantByName ~= nil then
            local ok, found = pcall(self.boxLayout.getDescendantByName, self.boxLayout, n)
            if ok then e = found end
        end
        return e
    end

    local rec = {
        row     = byName("drExtRow"   .. i),
        option  = byName("drExtOpt"   .. i),
        tooltip = byName("drExtTip"   .. i),
        title   = byName("drExtTitle" .. i),
    }
    self._extRows[i] = rec
    return rec
end

---Draw one provider's settings into the generic rows, and hide the rest.
--
-- EVERY FIELD IS SET ON EVERY VISIBLE ROW AND THE UNUSED ROWS ARE ACTIVELY
-- HIDDEN. These slots are reused by whichever tab is showing, so a row left with
-- the previous provider's title, or a stale tooltip under a new label, is the
-- same recycling trap SmoothList cells have produced here twice (5.7 colours,
-- 5.57 the notice row).
function DistributionSettingsPage:renderExtRows(rows)
    rows = rows or {}
    local pal = (InGameMenuSettingsFrame ~= nil) and InGameMenuSettingsFrame.COLOR_ALTERNATING or nil
    self._extDefs = rows

    for i = 1, DistributionSettingsPage.EXT_ROW_MAX do
        local rec, def = extRow(self, i), rows[i]
        local show = def ~= nil

        if rec.row ~= nil then
            if rec.row.setVisible ~= nil then rec.row:setVisible(show) end
            -- BANDED FROM THIS TAB'S FIRST ROW, not continuing DR's. The tint is
            -- applied here rather than from an onCreate so a foreign tab always
            -- starts its alternation at row 1 however many rows DR itself has.
            if show and pal ~= nil and rec.row.setImageColor ~= nil then
                local even = (i % 2 == 0)
                if pal[even] ~= nil then
                    pcall(rec.row.setImageColor, rec.row, nil, table.unpack(pal[even]))
                end
            end
        end
        if rec.option ~= nil and rec.option.setVisible ~= nil then rec.option:setVisible(show) end
        if rec.title ~= nil and rec.title.setVisible ~= nil then rec.title:setVisible(show) end

        if show then
            if rec.title ~= nil and rec.title.setText ~= nil then rec.title:setText(def.title) end
            if rec.tooltip ~= nil then
                -- An empty tooltip is BLANKED, never left holding the last
                -- provider's sentence.
                if rec.tooltip.setText ~= nil then rec.tooltip:setText(def.tooltip or "") end
                if rec.tooltip.setVisible ~= nil then rec.tooltip:setVisible(def.tooltip ~= nil) end
            end
            if rec.option ~= nil then
                -- The element carries its own row number, because ONE callback is
                -- shared by all twelve selectors and the click gives us nothing
                -- else to identify which was pressed (5.64 established the same
                -- for the in-row mode arrows).
                rec.option.drExtRow = i
                if rec.option.setTexts ~= nil then rec.option:setTexts(def.strings) end
                if rec.option.setState ~= nil then
                    local state = 1
                    if def.get ~= nil then
                        local ok, v = pcall(def.get)
                        if ok and type(v) == "number" and v >= 1 and v <= #def.strings then
                            state = math.floor(v)
                        elseif not ok then
                            if SmartDistribution ~= nil
                               and SmartDistribution.noteSettingsTabThrow ~= nil then
                                SmartDistribution.noteSettingsTabThrow(def.owner, v)
                            end
                        end
                    end
                    -- NO SECOND ARGUMENT. MultiTextOptionElement:setState(state,
                    -- forceEvent) RAISES the click callback when forceEvent is
                    -- true -- the opposite of the "apply this quietly" it reads
                    -- like. Passing true here sent every redraw back through
                    -- onExtOptionChanged -> the provider's set -> a redraw, which
                    -- is an unbounded loop: reported in game as a C STACK OVERFLOW,
                    -- three of them, which struck the provider out and made its
                    -- rows vanish. DR's own settings call setState with one
                    -- argument, which is what this now matches.
                    pcall(rec.option.setState, rec.option, state)
                end
            end
        end
    end
end

---The rows the ACTIVE tab wants, or nil when the active tab is DR's own.
function DistributionSettingsPage:activeExtRows()
    local t = tabList()[self.currentTab]
    local entry = t ~= nil and t.entry or nil
    if entry == nil or entry.own == true then return nil end
    local owner = entry.settingsOwner or (t ~= nil and t.modName or nil)
    if owner == nil or SmartDistribution == nil
       or SmartDistribution.settingsTabRows == nil then
        return {}
    end
    local ok, rows = pcall(SmartDistribution.settingsTabRows, owner)
    return (ok and type(rows) == "table") and rows or {}
end

---Paint the strip from the registry, then show whichever set of rows belongs to
-- the active tab.
function DistributionSettingsPage:refreshPageTabs()
    local list, labels = tabList(), {}
    for i, t in ipairs(list) do labels[i] = t.label end
    if self.currentTab == nil or self.currentTab > #list then self.currentTab = 1 end
    if SmartDistribution ~= nil and SmartDistribution.drawPageTabs ~= nil then
        SmartDistribution.drawPageTabs(self, labels, self.currentTab)
    end

    -- DR's own rows are visible only on DR's own tab, and a foreign tab's rows
    -- only on its own. Both sets live in the SAME ScrollingLayout so that one
    -- slider serves them, which is why the switch is per element rather than one
    -- setVisible on a whole layout.
    local ext = self:activeExtRows()
    if self.boxLayout ~= nil then
        for _, child in ipairs(self.boxLayout.elements or {}) do
            -- DR's own rows are every child that is NOT one of the generic slots.
            local id = child.id
            local isExt = (type(id) == "string" and id:sub(1, 8) == "drExtRow")
            if not isExt and child.setVisible ~= nil then
                child:setVisible(ext == nil)
            end
        end
    end
    self:renderExtRows(ext)

    -- RE-FLOW, or the surviving rows keep the gaps the hidden ones left.
    -- invalidateLayout() with no argument means ignoreVisibility is false, and
    -- BoxLayoutElement:getIsElementIncluded then excludes an invisible child
    -- (read from source, BoxLayoutElement.lua:305).
    if self.boxLayout ~= nil and self.boxLayout.invalidateLayout ~= nil then
        pcall(self.boxLayout.invalidateLayout, self.boxLayout)
    end
    -- AFTER the re-flow, so the rows just made visible have real geometry to
    -- measure. This is what covers a tab switch.
    self:clampVisibleTooltips()
end

---A player moved one of the generic selectors. Hand it back to whoever owns it.
--
-- PROVIDER CODE, SO IT IS PCALL'D. A setter that throws must not abort the
-- populate, and one that throws three times is struck out for the session rather
-- than breaking this page every time it is opened.
function DistributionSettingsPage:onExtOptionChanged(state, element)
    local i = element ~= nil and element.drExtRow or nil
    local def = i ~= nil and (self._extDefs or {})[i] or nil
    if def == nil or def.set == nil then return end

    local ok, err = pcall(def.set, state)
    if not ok then
        if SmartDistribution ~= nil and SmartDistribution.noteSettingsTabThrow ~= nil then
            SmartDistribution.noteSettingsTabThrow(def.owner, err)
        end
    end
    -- RE-READ AFTERWARDS. A provider may refuse the change (a confirmation the
    -- player declined) or may change another row as a consequence, and the
    -- selector must then show what is actually stored rather than what was
    -- clicked. Re-reading is also what puts a refused selector back where it was.
    self:renderExtRows(self:activeExtRows())
end

function DistributionSettingsPage:selectPageTab(i)
    if i == nil or i == self.currentTab then return end
    local t = tabList()[i]
    if t == nil then return end
    local prev = tabList()[self.currentTab]
    self.currentTab = i
    -- Tell the OUTGOING and INCOMING owners, so a mod can show and hide its own
    -- elements without DR knowing anything about them.
    if prev ~= nil and type((prev.entry or {}).onHide) == "function" then
        pcall(prev.entry.onHide, self)
    end
    if type((t.entry or {}).onShow) == "function" then pcall(t.entry.onShow, self) end
    self:refreshPageTabs()
end

function DistributionSettingsPage:onPageTab1() self:selectPageTab(1) end
function DistributionSettingsPage:onPageTab2() self:selectPageTab(2) end
function DistributionSettingsPage:onPageTab3() self:selectPageTab(3) end
function DistributionSettingsPage:onPageTab4() self:selectPageTab(4) end

---The base game's setting tooltip is `anchorTopRight`, 580px wide at +650px --
-- geometry tuned for its OWN settings screen. In DR's page that box runs past the
-- ScrollingLayout's right edge and is CLIPPED there, which is why every line came
-- out cut at the same x, mid word.
--
-- IT IS MOVED, NOT SHRUNK, and the first attempt got that backwards. Clamping the
-- WIDTH to `limitX - left` is wrong whenever the box STARTS near the right edge,
-- which is exactly this case: it left a sliver a few px wide and the hints
-- disappeared altogether. The box fits comfortably in the gap beside the settings
-- rows; it simply begins too far right. So slide it left by the overrun.
--
-- `GuiElement:move(dx, dy)` is a relative translate, which avoids having to know
-- how `position` composes with anchorTopRight at all.
--
-- MEASURED, NOT NUMBERED. `position` is scaled UNCONDITIONALLY by the 6.15
-- widening hook (getNormalizedScreenValues has no name or profile exclusion,
-- unlike size), while the BASE profile's 650px loads outside that window and is
-- not scaled -- so a literal offset written here is widened on an ultrawide and
-- not on 16:9, and no single value is right for both.
--
-- IDEMPOTENT: after the move the right edge is inside the limit, so the next open
-- computes no overrun and moves nothing.
local TOOLTIP_PROFILE = "fs25_multiTextOptionTooltip"
local TOOLTIP_MARGIN  = 0.004   -- normalised; a hair of clearance off the edge
local TOOLTIP_MIN_W   = 0.10    -- never shrink below this: an invisible hint is
                                -- worse than a clipped one, which is the bug this
                                -- guard exists to make impossible.

---How many tooltips the last pass moved, and how many REFUSED to move. Reported
-- once per session so a build where neither mechanism works says so in the log
-- rather than looking like the clamp was never reached.
local TOOLTIPS_MOVED, TOOLTIPS_STUCK = 0, 0

local function clampTooltips(el, leftX, limitX)
    if el == nil or type(el.elements) ~= "table" then return end
    for _, child in ipairs(el.elements) do
        -- NO VISIBILITY TEST, and the version that had one was a mistake worth
        -- recording. It looked prudent -- "do not measure a hidden row" -- and it
        -- turned the whole function off, because the base game keeps a settings
        -- tooltip HIDDEN until its row is focused or hovered, so at the moment this
        -- runs there is nothing visible to find.
        --
        -- Hidden geometry is also perfectly good here, which is what makes the
        -- guard unnecessary as well as harmful: setVisible only sets a flag
        -- (GuiElement.lua:1185) and updateAbsolutePosition does not consult it at
        -- all (:1049). A hidden ROW is excluded from the layout FLOW, but this flow
        -- is vertical -- it moves rows in Y and never in X -- and X is the only
        -- axis being clamped.
        if child.profile == TOOLTIP_PROFILE
           and type(child.absPosition) == "table" and type(child.absSize) == "table" then
            local w       = child.absSize[1]
            local overrun = (child.absPosition[1] + w) - (limitX - TOOLTIP_MARGIN)
            if overrun > 0 then
                -- do not slide it past the left edge of the list
                local room  = child.absPosition[1] - leftX
                local dx    = -math.min(overrun, math.max(room, 0))
                local was   = child.absPosition[1]

                -- MOVE, THEN CHECK IT TOOK -- do not assume it did. GuiElement:move
                -- adds to `position` and calls updateAbsolutePosition, which rebuilds
                -- absPosition from `anchorDeltas` and only recomputes those when the
                -- list is EMPTY (:1050). updateAnchorDeltas is stripped from the
                -- shipped source (6.15 records the same), so whether a move survives
                -- that rebuild cannot be established by reading -- and this function
                -- has now twice looked correct and changed nothing on screen.
                if child.move ~= nil then pcall(child.move, child, dx, 0) end

                -- setAbsolutePosition writes absPosition DIRECTLY and cascades the
                -- same delta to children (:1140), so it does not depend on the
                -- anchor maths at all. Used only when the move demonstrably did not
                -- land, so on a build where move works this is dead weight and
                -- nothing changes.
                if math.abs(child.absPosition[1] - was) < 1e-9 and child.setAbsolutePosition ~= nil then
                    pcall(child.setAbsolutePosition, child, was + dx, child.absPosition[2])
                end
                TOOLTIPS_MOVED = TOOLTIPS_MOVED + 1
                if math.abs(child.absPosition[1] - was) < 1e-9 then
                    TOOLTIPS_STUCK = TOOLTIPS_STUCK + 1
                end
            end
            -- Only if it STILL cannot fit -- i.e. the box is wider than the whole
            -- span -- give up width, and never below the floor.
            local span = (limitX - TOOLTIP_MARGIN) - leftX
            if w > span and span > TOOLTIP_MIN_W and child.setSize ~= nil then
                pcall(child.setSize, child, span, nil)
            end
        end
        clampTooltips(child, leftX, limitX)
    end
end

function DistributionSettingsPage:onFrameOpen()
    DistributionSettingsPage:superClass().onFrameOpen(self)
    -- THE LIVE PAGE, so a provider whose setting resolves LATER (a confirmation
    -- the player answers after the click returned) can ask for a redraw. Held on
    -- SmartDistribution rather than handed to the provider, so nobody outside
    -- this file gets a reference to the page itself.
    if SmartDistribution ~= nil then SmartDistribution._settingsPage = self end
    ownTab()
    self:refreshPageTabs()
    -- refreshPageTabs above already clamped whichever rows it made visible; this is
    -- the belt for a page opened without a tab change ever happening.
    self:clampVisibleTooltips()
    if DistributionSettings == nil or DistributionSettings.getStateIndex == nil then return end
    for id, element in pairs(self.settingElements) do
        if element.setState ~= nil then
            pcall(function() element:setState(DistributionSettings.getStateIndex(id)) end)
        end
    end
end

---Re-seat every VISIBLE tooltip inside the list it is drawn in.
--
-- THE LIMIT IS THE ScrollingLayout'S OWN RIGHT EDGE, and that is not arbitrary:
-- ScrollingLayoutElement sets `clipping = true`, and GuiElement:getClipArea clips
-- in X as well as Y (`clipX2 = min(clipX2, absPosition[1] + absSize[1])`). So a
-- tooltip extending past that edge is CUT THERE, whatever room is left on the
-- screen beyond it.
--
-- Measured against the 3440x1440 report to be sure, because the screenshot looks
-- at first like the text is running off the SCREEN: the settings slider sits at
-- roughly x=3196 of 3441 (it is anchored just outside the layout), and the hint's
-- text stops at about 3148 -- the layout's edge, with 250px of screen still to its
-- right. Clamping to 1.0 would therefore have moved nothing useful and left the
-- text cut in exactly the same place.
--
-- THE ACTUAL BUG WAS THE TRIGGER, not the limit: this ran only from onFrameOpen,
-- and the two tabs' rows share ONE layout with only one set visible at a time --
-- so rows revealed by a TAB SWITCH were never measured at all. That is why the
-- Animal Redux hints were cut and DR's own were not.
--
-- IDEMPOTENT, so running it on every switch is free: after the move the right edge
-- is inside the limit and the next pass computes no overrun.
function DistributionSettingsPage:clampVisibleTooltips()
    local box = self.boxLayout
    if box == nil or type(box.absPosition) ~= "table" or type(box.absSize) ~= "table" then return end
    TOOLTIPS_MOVED, TOOLTIPS_STUCK = 0, 0
    clampTooltips(box, box.absPosition[1], box.absPosition[1] + box.absSize[1])

    -- SAYS WHAT IT DID, ONCE PER SESSION, and unconditionally -- a player cannot be
    -- talked through enabling a debug flag (5.63), and this has now been reported
    -- twice as "still not fixed" with nothing in the log either way. The three
    -- outcomes it distinguishes are exactly the three that look identical on
    -- screen: never reached, reached but found nothing, found them and could not
    -- move them.
    if not DistributionSettingsPage._tipReported then
        DistributionSettingsPage._tipReported = true
        print(string.format(
            "[SmartDistribution] settings tooltips: %d overran and were moved, %d could not be moved "
            .. "(list x %.4f..%.4f)",
            TOOLTIPS_MOVED, TOOLTIPS_STUCK,
            box.absPosition[1], box.absPosition[1] + box.absSize[1]))
    end
end

-- onClick from a selector: hand off to the shared apply/save/MP-sync logic.
function DistributionSettingsPage:onOptionChanged(state, element)
    if DistributionControls ~= nil and DistributionControls.onMenuOptionChanged ~= nil then
        DistributionControls:onMenuOptionChanged(state, element)
    end
end

---Redraw the extension rows of whichever settings page is open. Safe to call at
-- any time and from anywhere: it does nothing when the page has never been built
-- or the active tab is DR's own.
--
-- THIS EXISTS FOR THE ASYNCHRONOUS CASE. DR re-reads a provider's rows straight
-- after a set, which covers a setter that decides immediately. A setter that
-- raises a confirmation dialog answers LATER, by which time that re-read has been
-- and gone showing the un-answered value -- so the provider needs a way to say
-- "now".
function SmartDistribution.refreshSettingsRows()
    local page = SmartDistribution._settingsPage
    if page == nil or page.renderExtRows == nil or page.activeExtRows == nil then return false end
    local ok = pcall(function() page:renderExtRows(page:activeExtRows()) end)
    return ok
end
