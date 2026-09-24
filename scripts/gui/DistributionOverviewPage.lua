-- ============================================================================
-- DistributionOverviewPage.lua  (Distribution Redux) -- Overview tab
-- A single flat table across the WHOLE network: one row per (building, product),
-- with the building's shop image + the product's icon, then
--   Received | Loaded | Consumed | Unloaded | Held | Produced | Distributed |
--   Stored/Moved | Sold | Distr. Cost
-- Within each building the products are listed INPUTS first, then outputs -- the
-- order product actually flows through it.
-- Received / Distributed are what Distribution Redux moved; Loaded / Unloaded are
-- their manual counterparts -- product put in or taken out by anything that is not
-- DR (player trailer, bale, AI helper, another mod).
--
-- Consumed and Produced also carry the recipe's EXPECTED figure for the same window
-- in brackets: green on or above target, orange within 5% of it, red below that.
-- Only productions have a recipe, so silo / husbandry rows show a bare figure in
-- white rather than an invented target.
--
-- Four selectors sit above the table: what to Filter by (nothing / building /
-- product / end product) and which one to Show, the Timescale, and Grouping --
-- which collapses buildings of the same type into one summed row labelled
-- "Bakery x2". "End product" shows the whole supply chain feeding one product,
-- deepest ingredient first (see SmartDistribution.overviewRows' chainFt).
--
-- The product name carries what the product is to THAT building -- "(In)", "(Out)"
-- or "(In/Out)", the last being both a silo's stock and a recipe fill type that is
-- consumed and produced by the same plant.
-- A timescale selector at the top rescopes every flow column at once:
--   Hour  -> the last completed hourly distribution pass
--   Month -> the rolling 24-cycle window (what the /mo columns on the other tabs show)
--   Year  -> the rolling 12-month ring kept by DistributionStats.lua
-- HELD is deliberately NOT rescoped: it is a stock, not a flow, so it always reads
-- what the building is holding right now.
--
-- The page is a thin view: SmartDistribution.overviewRows(window) does the work
-- (engine-side, so it is identical for a multiplayer client reading the server's
-- pushed aggregates). Rows are cached and rebuilt on a ~1s throttle -- the list
-- re-renders at the base page's 2 Hz, but the enumeration behind it is the
-- expensive part and does not need to run that often.
-- ============================================================================

DistributionOverviewPage = {}
local DistributionOverviewPage_mt = Class(DistributionOverviewPage, DistributionMenuPage)

local PERIODS       = { "hour", "month", "year" }
local PERIOD_LABELS = { "Hour", "Month", "Year" }   -- English fallbacks, see localised() below
local PERIOD_KEYS   = { "dr_period_hour", "dr_period_month", "dr_period_year" }
local FILTER_LABELS = { "Nothing (show all)", "Building", "Product", "End product (full chain)" }
local FILTER_KEYS   = { "dr_filter_nothing", "dr_filter_building", "dr_filter_product", "dr_filter_endProduct" }
local FILTER_CHAIN  = 4   -- the chain mode's index, referenced in a few places below
local GROUP_LABELS  = { "Off (one row per building)", "On (combine same building type)" }
local GROUP_KEYS    = { "dr_group_off", "dr_group_on" }
-- Resolved per call rather than baked into the tables above: l10n is not necessarily up when this
-- chunk loads. Declared HERE, above every use (CLAUDE.md 5.44 / 5.57).
local function localised(labels, keys)
    if SmartDistribution == nil or SmartDistribution.l10n == nil then return labels end
    local out = {}
    for i, fb in ipairs(labels) do out[i] = SmartDistribution.l10n(keys[i], fb) end
    return out
end
local REBUILD_SEC   = 2.0     -- how often the row set is re-enumerated while the tab is open

-- ---- OPEN / SCROLL PROFILING ----------------------------------------------
-- Reported 2026-08-05: on a large farm the Overview takes "a good while" to appear in the SETTINGS view,
-- and stays slow with Menu refresh rate on Manual only -- because onFrameOpen rebuilds unconditionally and
-- the refresh dial only governs the PERIODIC rebuild. Speed-scrolling the whole list was reported at ~30 s.
--
-- sdStress measures SmartDistribution.overviewRows, which on a 25-building save is 40.9 ms for 210 rows --
-- nowhere near "a good while". But it does NOT cover the rest of the open: rebuildRows also builds the
-- "Show" filter list around that call, then reloadData repopulates the list, then focus is set. So the
-- measured part is only one of four, and the reported farm is ~4x the buildings AND more products each,
-- against a cost that is O(rows x placeables) -- it grows on both axes at once.
--
-- These two lines split the open into its phases and time the cell populate separately, so the next report
-- names the phase instead of us guessing at it a fifth time.
--
-- NOT gated on SmartDistribution.debug: it prints only when something is genuinely slow, so a player who
-- hits this produces the diagnostic without being talked through enabling anything. Silent otherwise.
local PROFILE_OPEN_MS = 150    -- print the open breakdown when it costs more than this
local PROFILE_POP_MS  = 500    -- print the populate summary once this much cell time has accumulated
local PROFILE_POP_MAX = 10     -- ...at most this many times a session, so a long scroll cannot flood the log
local function nowMs()
    return (getTimeSec ~= nil) and (getTimeSec() * 1000) or nil
end

-- integer liters with thousands separators; a plain dash for nothing, so a busy table stays readable
local function fmt(n)
    n = math.floor((n or 0) + 0.5)
    if n == 0 then return "-" end
    local s = tostring(n)
    local k
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
end

-- A volume WITH its unit, via SmartDistribution.formatVolume -- the mod's single litres/kilolitres rule
-- (up to 999 L in litres, above that kL with the extraneous zeros dropped). Always a real figure, "0 L"
-- included: a HELD or REMAINING cell holding nothing must say so. Do not append " L" to it.
local function fmtV(n)
    if SmartDistribution ~= nil and SmartDistribution.formatVolume ~= nil then
        local ok, s = pcall(SmartDistribution.formatVolume, n or 0)
        if ok and type(s) == "string" then return s end
    end
    return fmt(n) .. " L"
end

-- The same, but keeping THIS page's dash-for-nothing convention, which the FLOW columns depend on: a table
-- this wide is only scannable because an hour with no movement reads as "-" rather than a wall of zeros
-- (5.7 drops such rows entirely for the same reason). Held / capacity / remaining deliberately do NOT use
-- this -- there, zero is a fact about the building rather than an absence of activity.
local function flowV(n)
    if n == nil or math.abs(n) < 0.5 then return "-" end
    return fmtV(n)
end

-- a compact currency figure ("$1.2k"), or a dash for nothing
local function money(v)
    if v == nil or v < 0.5 then return "-" end
    if SmartDistribution ~= nil and SmartDistribution.formatMoneyShort ~= nil then
        local ok, s = pcall(SmartDistribution.formatMoneyShort, v)
        if ok and type(s) == "string" then return s end
    end
    return fmt(v)
end

-- "12,345  ($1.2k)" for the SOLD column; money is dropped when zero or unavailable (MP clients)
local function soldWithMoney(liters, revenue)
    local base = flowV(liters)
    if revenue ~= nil and revenue > 0.5 and SmartDistribution ~= nil and SmartDistribution.formatMoneyShort ~= nil then
        return base .. "  (" .. SmartDistribution.formatMoneyShort(revenue) .. ")"
    end
    return base
end

-- "1,234  (2,000)" -- the actual, then what the recipe says to expect over the same window. Expectation
-- is nil for anything without a recipe (silos, husbandry), and those read as a bare figure.
local function withExpected(actual, expected)
    if expected == nil or expected < 0.5 then return flowV(actual) end
    -- an explicit "0" rather than fmt's dash: against a stated target, "produced nothing" is the point
    local a = math.floor((actual or 0) + 0.5)
    return (a == 0 and fmtV(0) or fmtV(actual)) .. "  (" .. fmtV(expected) .. ")"
end

-- ---- THE STORAGE BAR -------------------------------------------------------------------------------
-- Replaces the HELD (MAX) and FREE STORAGE text columns with the widget the building tabs already carry
-- (5.69 / 5.80), in the same band those two occupied: this product GREEN, whatever else is sharing the
-- tank RED behind it, the configured "Max in" ceiling as an ORANGE line, and the litres and share written
-- underneath. The red band and the orange line are what FREE STORAGE used to spell out in figures.
--
-- ONE IMPLEMENTATION, IN SmartDistribution, called from all four pages. Copying it here is the 6.18 trap
-- -- a three-mark widget with a clamp per mark and SmoothList cell recycling is the wrong thing to keep
-- two of, and it is exactly why 5.69 promoted it out of a GUI file in the first place.
--
-- SIDE FOLLOWS THE ROW'S IN/OUT TAG, exactly as the old held text did: an input gets the MAX and TARGET
-- marks, an output the RESERVE, and an (In/Out) silo all three -- it takes the input form because that is
-- the side carrying a settable percentage. A row with NO tag (the flow view keeps one that survives on
-- ledger history alone) takes the output form, which is the branch withCapacity used to give it.
--
-- ROLE IS THE BUILDING ROLE, recovered from the row's own role uid -- NOT the in/out tag. They are
-- different things, and conflating them is what produced `uid#in` keys nothing ever writes (the bug
-- settingsFor records having had to fix). nil for a single-role building, which is every ordinary one.
--
-- HELD IS HANDED IN on the output side and NOT re-derived, the rule every other caller follows
-- (5.27 / 5.28 / 5.54c). roleHeld first so a multi-role building's held and its capacity are read off the
-- SAME half -- outputBarValues scopes the total by role, so a placeable-wide held beside it could read
-- past 100% (the 5.80 shape). It returns nil for a single-role building, where the row's own figure --
-- buffer plus pad, the same basis the Productions tab passes -- stands.
local function setStorageBar(cell, r, grouped)
    if SmartDistribution == nil or SmartDistribution.drawStorageBar == nil then return end
    local function hide()
        if SmartDistribution.hideStorageBar ~= nil then SmartDistribution.hideStorageBar(cell) end
    end
    if r == nil or r.placeable == nil or r.ft == nil then return hide() end

    local side
    if     r.role == "In"     then side = "input"
    elseif r.role == "In/Out" then side = "both"
    else                           side = "output" end

    -- A GROUP HAS NO SINGLE TANK. "Bakery x2" sums its members' flows, so a bar resolved from ONE of
    -- them would sit beside summed columns describing something else. The row already carries the summed
    -- figures (groupRows adds capacity, heldInternal and the pallet count across the group), so they are
    -- handed over rather than guessed at.
    --   held is the INTERNAL total, which keeps it on the same basis as the summed capacity and means a
    --   group of productions can never read past 100% the way 5.80 records for a single one.
    --   No red band and no marks: "what else is in this tank", a ceiling, a target and a reserve are all
    --   per building, and a summed one would be a figure DR cannot justify (5.45b: understate, never
    --   invent). noMaxMark is what suppresses the ceiling line, which is otherwise drawn even when unset.
    -- nil capacity -> no track at all, which is what the old cell did with it: show what is held and
    -- refuse to invent a denominator (5.21).
    if grouped then
        local total = r.capacity
        if type(total) ~= "number" or total <= 0 then return hide() end
        return SmartDistribution.drawStorageBar(cell, r.placeable, r.ft, nil, side, nil, {
            total   = total,
            held    = math.max(0, r.heldInternal or r.held or 0),
            others  = 0, capL = nil, pct = 100, blocked = false,
            target  = nil, reserve = nil, noMaxMark = true,
            pallets = r.heldPallets or 0, palletCount = r.heldPalletCount or 0,
        })
    end

    local brole = (SmartDistribution.roleOfUid ~= nil) and SmartDistribution.roleOfUid(r.uid) or nil
    local held = nil
    if side == "output" then
        if brole ~= nil and SmartDistribution.roleHeld ~= nil then
            held = SmartDistribution.roleHeld(r.placeable, r.ft, brole)
        end
        if held == nil then held = r.held or 0 end
    end
    SmartDistribution.drawStorageBar(cell, r.placeable, r.ft, brole, side, held)
end

-- MET_TARGET: within 1% counts as MET, not a near miss -- a plant running at 14,390 against 14,400 is on
-- target, and painting a rounding-level shortfall orange reads as a warning that isn't there.
-- NEAR_TARGET: below that but within 5% is a genuine near miss, visibly different from a stall.
local MET_TARGET  = 0.99
local NEAR_TARGET = 0.95

-- Green at or above MET_TARGET, orange down to NEAR_TARGET, red below. Cells are RECYCLED by SmoothList
-- as it scrolls, so the no-expectation case must actively reset to white -- otherwise a row inherits the
-- colour of whatever row last used that cell.
local function setPerformanceColor(cell, name, actual, expected)
    local c = cell:getAttribute(name)
    if c == nil or c.setTextColor == nil then return end
    if expected == nil or expected < 0.5 then
        c:setTextColor(1, 1, 1, 1)
        return
    end
    local col = (SmartDistribution ~= nil and SmartDistribution.LINK_COLOR or {})
    local rgba
    if actual + 0.5 >= expected * MET_TARGET then  rgba = col.ACTIVE       -- green: on target
    elseif actual >= expected * NEAR_TARGET then   rgba = col.IDLE         -- orange: within 5%
    else                                           rgba = col.BLOCKED end  -- red: genuinely short
    if rgba ~= nil then c:setTextColor(rgba[1], rgba[2], rgba[3], rgba[4]) end
end

local function setIcon(cell, attrName, file)
    local iconCell = cell:getAttribute(attrName)
    if iconCell == nil then return end
    if file ~= nil and file ~= "" and iconCell.setImageFilename ~= nil then
        iconCell:setImageFilename(file)
        if iconCell.setVisible ~= nil then iconCell:setVisible(true) end
    elseif iconCell.setVisible ~= nil then
        iconCell:setVisible(false)
    end
end

function DistributionOverviewPage.new(target, custom_mt)
    local self = DistributionMenuPage.new(target, custom_mt or DistributionOverviewPage_mt)
    self.pageName = "DISTREDUX_OVERVIEW"
    self.rows = {}
    self.periodIndex = 2          -- default: Month, matching the /mo columns on the other tabs
    self.filterMode  = 1          -- 1 = All buildings, 2 = by building, 3 = by product
    self.filterValue = nil        -- the CHOSEN name, kept as a string rather than an index: the option
                                  -- list is rebuilt every couple of seconds and indices would drift
    self.filterValues = {}
    self.chainFtByName = {}       -- End product mode: display name -> fill-type index
    self.grouped = false
    return self
end

function DistributionOverviewPage:onGuiSetupFinished()
    DistributionOverviewPage:superClass().onGuiSetupFinished(self)
    if self.statsList ~= nil then
        self.statsList:setDataSource(self)
        self.statsList:setDelegate(self)
    end
    if self.settingsList ~= nil then
        self.settingsList:setDataSource(self)
        self.settingsList:setDelegate(self)
    end
    local function initOption(opt, texts, state)
        if opt == nil or opt.setTexts == nil then return end
        opt:setTexts(texts)
        if opt.setState ~= nil then pcall(function() opt:setState(state) end) end
    end
    initOption(self.periodOption,     localised(PERIOD_LABELS, PERIOD_KEYS), self.periodIndex)
    initOption(self.filterModeOption, localised(FILTER_LABELS, FILTER_KEYS), self.filterMode)
    initOption(self.groupOption,      localised(GROUP_LABELS, GROUP_KEYS),  self.grouped and 2 or 1)
    initOption(self.filterValueOption, { "-" }, 1)
    self._scrollMap = { { "statsSlider", "statsList", 14 } }   -- 626px / 42px pitch = 14 whole rows; bar shows past that
end

function DistributionOverviewPage:currentWindow()
    return PERIODS[self.periodIndex] or "month"
end

-- The value each row is filtered on for the current mode (nil when not filtering).
function DistributionOverviewPage:filterKeyOf(row)
    if self.filterMode == 2 then return row.assetName end
    if self.filterMode == 3 then return row.product end
    return nil
end

-- The "Show" list for the current mode. Building / Product read it off the table itself; End product
-- reads the farm's producible OUTPUTS instead, because that filter narrows the table and deriving its
-- own list from the filtered rows would collapse it to just the chain it is already showing.
function DistributionOverviewPage:buildFilterValues(all)
    local values, seen = {}, {}
    if self.filterMode == FILTER_CHAIN then
        self.chainFtByName = {}
        local list = (SmartDistribution ~= nil and SmartDistribution.producibleProducts ~= nil)
            and SmartDistribution.producibleProducts() or {}
        for _, e in ipairs(list) do
            if e.name ~= nil and not seen[e.name] then
                seen[e.name] = true
                values[#values + 1] = e.name
                self.chainFtByName[e.name] = e.ft
            end
        end
    else
        for _, r in ipairs(all or {}) do
            local k = self:filterKeyOf(r)
            if k ~= nil and not seen[k] then seen[k] = true; values[#values + 1] = k end
        end
        -- LOCALISED, not a byte compare: table.sort on strings orders by byte, which puts an
        -- accented or non-Latin building or product name outside the alphabet the player reads in.
        if DistributionSort ~= nil and DistributionSort.sortStrings ~= nil then
            DistributionSort.sortStrings(values)
        else
            table.sort(values)
        end
    end
    return values, seen
end

-- Push a "Show" list onto the widget, keeping the player's choice pointed at the same NAME across
-- rebuilds. Only touches setTexts when the list really changed -- reassigning it on every 2 s refresh
-- would fight the player mid-click.
function DistributionOverviewPage:updateFilterValues(values, seen)
    if #values == 0 then values = { "-" } end

    if self.filterValue == nil or not seen[self.filterValue] then
        self.filterValue = (self.filterMode == 1) and nil or values[1]
    end

    local joined = table.concat(values, "\0")
    if joined ~= self._filterValuesJoined then
        self._filterValuesJoined = joined
        self.filterValues = values
        if self.filterValueOption ~= nil and self.filterValueOption.setTexts ~= nil then
            self.filterValueOption:setTexts(values)
        end
    end
    -- keep the widget pointing at the chosen name
    local idx = 1
    for i, v in ipairs(self.filterValues) do if v == self.filterValue then idx = i; break end end
    if self.filterValueOption ~= nil and self.filterValueOption.setState ~= nil then
        pcall(function() self.filterValueOption:setState(idx) end)
    end
end

-- Re-enumerate the whole network, then narrow to the current filter.
function DistributionOverviewPage:rebuildRows()
    -- The chain filter is resolved FIRST: the engine tags the rows as it builds them, so it needs the
    -- product up front, and its option list does not come from the rows anyway.
    -- phase timings, read by onFrameOpen's breakdown (nil when there is no clock)
    local tf0 = nowMs()
    self._profFilter, self._profEnum = 0, 0

    local chainFt = nil
    if self.filterMode == FILTER_CHAIN then
        self:updateFilterValues(self:buildFilterValues(nil))
        chainFt = (self.filterValue ~= nil) and (self.chainFtByName or {})[self.filterValue] or nil
    end
    if tf0 ~= nil then self._profFilter = nowMs() - tf0 end

    local all = nil
    local te0 = nowMs()
    if SmartDistribution ~= nil and SmartDistribution.overviewRows ~= nil then
        local ok, r = pcall(SmartDistribution.overviewRows, self:currentWindow(), self.grouped, chainFt,
                            self:settingsViewOn())
        if ok and type(r) == "table" then all = r end
    end
    if te0 ~= nil then self._profEnum = nowMs() - te0 end
    all = all or {}
    self._profAll = #all

    local tf1 = nowMs()
    if self.filterMode == FILTER_CHAIN then
        if chainFt == nil then
            self.rows = all                     -- nothing producible to pick: show everything, not a blank table
        else
            local kept = {}
            for _, r in ipairs(all) do if r.inChain then kept[#kept + 1] = r end end
            self.rows = kept
        end
    else
        self:updateFilterValues(self:buildFilterValues(all))
        if self.filterMode == 1 or self.filterValue == nil then
            self.rows = all
        else
            local kept = {}
            for _, r in ipairs(all) do
                if self:filterKeyOf(r) == self.filterValue then kept[#kept + 1] = r end
            end
            self.rows = kept
        end
    end
    -- the post-enumeration filter pass belongs with the pre-enumeration one: both are "Show" list work
    if tf1 ~= nil then self._profFilter = (self._profFilter or 0) + (nowMs() - tf1) end
    self._lastRebuild = (getTimeSec ~= nil) and getTimeSec() or nil
end

-- Called by the base page's refresh; the enumeration itself is throttled and the list reload that follows
-- re-renders from the cached rows.
--
-- This is the single most expensive thing DR does with the menu open -- it walks every enrolled building x
-- every product it can hold -- so it follows the "Menu refresh rate" setting rather than a fixed interval,
-- and Manual only stops it entirely (onRefresh, and every selector change, still rebuild on demand).
-- REBUILD_SEC remains the floor: the base page can tick faster than the enumeration is worth repeating.
function DistributionOverviewPage:rebuildRealtimeData()
    local every = DistributionMenuPage.refreshSeconds()
    if every == nil then return end                       -- Manual only
    if every < REBUILD_SEC then every = REBUILD_SEC end
    local now = (getTimeSec ~= nil) and getTimeSec() or nil
    if now ~= nil and self._lastRebuild ~= nil and (now - self._lastRebuild) < every then return end
    self:rebuildRows()
end

-- Footer "Refresh": re-enumerate now. The point of Manual only, and harmless at any other rate.
function DistributionOverviewPage:onRefresh()
    self:applySelectorChange()
end


-- ---- PAGE TABS -------------------------------------------------------------------------------------
-- The Overview keeps its own left icon and carries a strip of its own, so a mod with a network-wide
-- view of its own has somewhere to put it. DR's own tab is registered by this page, on every frame
-- open, and registerPageTab pins an `own` entry to slot 1 whatever order registrations arrive in --
-- a dependent mod registers at MISSION LOAD, far earlier than a page's first open (5.88).
--
-- WITH NO SECOND TAB THIS PAGE IS UNCHANGED. PAGE_TAB_MIN suppresses a strip of one, drawPageTabs
-- gives the header band back to the title, and every branch below takes its own-tab path.
DistributionOverviewPage.TAB_KEY = "overview"

local function tabList()
    if SmartDistribution == nil or SmartDistribution.pageTabs == nil then return {} end
    return SmartDistribution.pageTabs(DistributionOverviewPage.TAB_KEY)
end

local function activeEntry(page)
    local t = tabList()[(page ~= nil and page.currentTab) or 1]
    return (t ~= nil) and t.entry or nil
end

---Is DR's own tab the one showing? True when nothing is registered at all, which is what
-- keeps a stock install on every existing code path.
function DistributionOverviewPage:ownTabActive()
    local e = activeEntry(self)
    return e == nil or e.own == true
end

---Show whichever page furniture belongs to the active tab.
--
-- EVERY ELEMENT IS SET ON EVERY PATH, never left to a default: this runs again on each tab change
-- and each frame open, so an element hidden once and not re-shown would stay hidden for the session.
function DistributionOverviewPage:applyTabContent()
    local own = self:ownTabActive()
    local on  = self:settingsViewOn()
    local function vis(el, show) if el ~= nil and el.setVisible ~= nil then el:setVisible(show) end end

    vis(self.ovFilterRow, own); vis(self.ovShowRow,  own)
    vis(self.ovPeriodRow, own); vis(self.ovGroupRow, own)
    vis(self.flowHeaderRow,     own and not on)
    vis(self.flowListBox,       own and not on)
    vis(self.settingsHeaderRow, own and on)
    vis(self.settingsListBox,   own and on)

    -- The foreign tab's stand-in. The TEXT is the registering mod's, already localised, because DR
    -- cannot resolve another mod's l10n namespace (5.60). A tab that supplies none simply shows an
    -- empty page rather than DR inventing a caption for it.
    local e  = activeEntry(self)
    local ph = self.ovPlaceholder
    local txt = (not own) and type(e) == "table" and type(e.placeholder) == "string" and e.placeholder or nil
    if ph ~= nil then
        if ph.setText ~= nil then ph:setText(txt or "") end
        vis(ph, txt ~= nil and txt ~= "")
    end

    -- A HIDDEN TABLE MUST NOT BE RE-ENUMERATED. The 2 Hz refresh re-reads every visible cell, and on
    -- a large farm that is the most expensive thing this page does (5.46 / 5.52) -- paying it for a
    -- list nobody can see would be the worst kind of cost.
    self._realtimeLists = own and { on and "settingsList" or "statsList" } or {}
    self:updateViewButton()
end

---Paint the strip, then apply the active tab. DR's own tab is (re)registered first so the page can
-- never come up with no tabs at all.
function DistributionOverviewPage:refreshPageTabs()
    if SmartDistribution ~= nil and SmartDistribution.registerPageTab ~= nil then
        -- The literal, as the other two tabbed pages use it. It is the REGISTRY key for
        -- de-duplication, not anything the player sees, and `entry.own` (not the name) is
        -- what pins DR's tab to slot 1 -- a name is what a player changes by renaming the zip.
        SmartDistribution.registerPageTab(DistributionOverviewPage.TAB_KEY, "FS25_Distribution_Redux",
            SmartDistribution.l10n("dr_tab_distribution", "DISTRIBUTION"), { own = true })
    end
    local list, labels = tabList(), {}
    for i, t in ipairs(list) do labels[i] = t.label end
    if self.currentTab == nil or self.currentTab > #list then self.currentTab = 1 end
    if SmartDistribution ~= nil and SmartDistribution.drawPageTabs ~= nil then
        SmartDistribution.drawPageTabs(self, labels, self.currentTab)
    end
    self:applyTabContent()
end

---Switch tab. The outgoing and incoming owners are told, so a mod can reveal and hide elements of
-- its own without DR knowing anything about them -- the same contract the settings page offers.
function DistributionOverviewPage:selectPageTab(i)
    if i == nil or i == self.currentTab then return end
    local t = tabList()[i]
    if t == nil then return end
    local prev = tabList()[self.currentTab]
    self.currentTab = i
    if prev ~= nil and type((prev.entry or {}).onHide) == "function" then pcall(prev.entry.onHide, self) end
    if type((t.entry or {}).onShow) == "function" then pcall(t.entry.onShow, self) end
    self:refreshPageTabs()
end

function DistributionOverviewPage:onPageTab1() self:selectPageTab(1) end
function DistributionOverviewPage:onPageTab2() self:selectPageTab(2) end
function DistributionOverviewPage:onPageTab3() self:selectPageTab(3) end
function DistributionOverviewPage:onPageTab4() self:selectPageTab(4) end
function DistributionOverviewPage:onPageTab5() self:selectPageTab(5) end
function DistributionOverviewPage:onPageTab6() self:selectPageTab(6) end

function DistributionOverviewPage:pageTabKey() return DistributionOverviewPage.TAB_KEY end
function DistributionOverviewPage:onPageTabPrev() SmartDistribution.stepPageTab(self, DistributionOverviewPage.TAB_KEY, -1) end
function DistributionOverviewPage:onPageTabNext() SmartDistribution.stepPageTab(self, DistributionOverviewPage.TAB_KEY,  1) end

function DistributionOverviewPage:onFrameOpen()
    DistributionOverviewPage:superClass().onFrameOpen(self)
    -- OPENS ON CYCLE, like every other tab. Set before the syncState block below picks
    -- the widgets up, so the selector and the columns agree on the way in.
    self.periodIndex = 1
    -- the view survives leaving and re-entering the tab, so everything here follows it rather than statsList
    local on = self:settingsViewOn()
    self._realtimeLists = { on and "settingsList" or "statsList" }
    local function syncState(opt, state)
        if opt ~= nil and opt.setState ~= nil then pcall(function() opt:setState(state) end) end
    end
    syncState(self.periodOption,     self.periodIndex)
    syncState(self.filterModeOption, self.filterMode)
    syncState(self.groupOption,      self.grouped and 2 or 1)
    -- The strip decides what is on screen now, not just the flow/settings view: on a foreign tab
    -- none of this page's own furniture shows at all. refreshPageTabs ends by calling
    -- applyTabContent, which covers the four elements this block used to set plus the selector rows,
    -- the placeholder, the realtime list set and the footer.
    self:refreshPageTabs()
    -- The COLD first enumeration, timed as its own sample: memos are empty and this is the most expensive
    -- refresh the tab will ever do, so it is what should decide the backoff -- otherwise a farm big enough
    -- to hitch would hitch at least twice before the menu noticed. Not overlapped with the periodic timing
    -- in refreshRealtimeLists, which measures a different call.
    -- REUSE ROWS THAT ARE STILL FRESH instead of re-enumerating on every tab switch.
    --
    -- onFrameOpen used to rebuild unconditionally, which is why "Menu refresh rate = Manual only" did not
    -- help the reported case at all: that setting governs the PERIODIC rebuild, and leaving the tab and
    -- coming back went straight past it. On a large farm that is a full O(rows x placeables) enumeration
    -- per tab switch.
    --
    -- Fresh means "younger than the refresh interval the player chose". Under Manual only there is no
    -- interval, so rows stay valid until they press Refresh -- which is exactly what that setting promises.
    -- A selector change still rebuilds on demand (applySelectorChange), so this only ever skips work the
    -- player has not asked to be redone.
    local every = DistributionMenuPage.refreshSeconds()
    local age   = (self._lastRebuild ~= nil and getTimeSec ~= nil) and (getTimeSec() - self._lastRebuild) or nil
    local fresh = (self.rows ~= nil) and (age ~= nil) and (every == nil or age < math.max(every, REBUILD_SEC))

    local t0 = (getTimeSec ~= nil) and getTimeSec() or nil
    if not fresh then
        self:rebuildRows()
        if t0 ~= nil then DistributionMenuPage.noteRefreshCost(getTimeSec() - t0) end
    end
    local tRebuild = (t0 ~= nil) and ((getTimeSec() - t0) * 1000) or nil

    local tR0  = nowMs()
    local list = self:activeList()
    if list ~= nil then list:reloadData() end
    local tReload = (tR0 ~= nil) and (nowMs() - tR0) or nil

    local tF0 = nowMs()
    self:setSoundSuppressed(true)
    if list ~= nil then
        FocusManager:setFocus(list)
    end
    self:setSoundSuppressed(false)
    local tFocus = (tF0 ~= nil) and (nowMs() - tF0) or nil

    -- WHERE DID THE OPEN GO? One line, printed only when the open was actually slow (or under debug), so a
    -- player who hits this produces the breakdown without being walked through enabling anything.
    --   enumerate = SmartDistribution.overviewRows -- the part sdStress already measures
    --   filters   = building the "Show" dropdown around it -- NOT covered by sdStress
    --   reload    = SmoothList rebuilding + populating cells
    --   focus     = FocusManager over the list
    -- The rows= pair is "kept after filtering / total enumerated", because a filter can make the visible
    -- list small while the work behind it stays large.
    if tRebuild ~= nil then
        local total = tRebuild + (tReload or 0) + (tFocus or 0)
        if total >= PROFILE_OPEN_MS or (SmartDistribution ~= nil and SmartDistribution.debug) then
            print(string.format(
                "[SmartDistribution] Overview open (%s): rows=%d/%d  TOTAL %.0f ms  = enumerate %.0f + filters %.0f + reload %.0f + focus %.0f",
                on and "settings" or "flow", #(self.rows or {}), self._profAll or -1,
                total, self._profEnum or 0, self._profFilter or 0, tReload or 0, tFocus or 0))
        end
    end
end

-- ---- selectors -------------------------------------------------------------
-- MultiTextOption passes the new state, but not on every path, so fall back to reading the widget.
local function stateOf(opt, state, count)
    if type(state) ~= "number" and opt ~= nil and opt.getState ~= nil then state = opt:getState() end
    if type(state) == "number" and state >= 1 and state <= count then return state end
    return nil
end

-- the list currently on screen; every reload goes through this so the two views cannot drift apart
function DistributionOverviewPage:activeList()
    if self:settingsViewOn() then return self.settingsList end
    return self.statsList
end

function DistributionOverviewPage:applySelectorChange()
    self:rebuildRows()
    local l = self:activeList()
    if l ~= nil then l:reloadData() end
end

function DistributionOverviewPage:onPeriodChanged(state)
    self.periodIndex = stateOf(self.periodOption, state, #PERIODS) or self.periodIndex
    self:applySelectorChange()
end

function DistributionOverviewPage:onFilterModeChanged(state)
    local s = stateOf(self.filterModeOption, state, #FILTER_LABELS)
    if s ~= nil and s ~= self.filterMode then
        self.filterMode = s
        self.filterValue = nil            -- the previous choice belongs to the other list
        self._filterValuesJoined = nil    -- force the "Show" list to be rebuilt for the new mode
    end
    self:applySelectorChange()
end

function DistributionOverviewPage:onFilterValueChanged(state)
    local s = stateOf(self.filterValueOption, state, #(self.filterValues or {}))
    if s ~= nil then self.filterValue = self.filterValues[s] end
    self:applySelectorChange()
end

function DistributionOverviewPage:onGroupChanged(state)
    -- Grouping is forced off in the settings view: settings are per building, and a summed "Bakery x2" row
    -- has no single cap, reserve or destination count to show. Snap the widget back rather than accept it.
    if self:settingsViewOn() then
        if self.groupOption ~= nil and self.groupOption.setState ~= nil then
            pcall(function() self.groupOption:setState(1) end)
        end
        return
    end
    local s = stateOf(self.groupOption, state, #GROUP_LABELS)
    if s ~= nil then
        local on = (s == 2)
        if on ~= self.grouped then
            self.grouped = on
            -- grouping renames buildings ("Bakery" -> "Bakery x2"), so a building filter no longer matches
            if self.filterMode == 2 then self.filterValue = nil end
            self._filterValuesJoined = nil
        end
    end
    self:applySelectorChange()
end

-- ---- SmoothList data source / delegate -------------------------------------
function DistributionOverviewPage:getNumberOfItemsInSection(list, section)
    if list == self.statsList or list == self.settingsList then return #self.rows end
    return 0
end

function DistributionOverviewPage:populateCellForItemInSection(list, section, index, cell)
    if list == self.settingsList then
        -- SCROLL COST. SmoothList calls this per VISIBLE cell, so it runs on every reload AND continuously
        -- while scrolling -- speed-scrolling the whole list was reported at ~30 s. Accumulated rather than
        -- printed per cell, and self-limiting (PROFILE_POP_MAX lines a session) so a long scroll cannot
        -- flood the log. ms/cell is the number that matters: multiply it by the row count for what a full
        -- pass over the list costs.
        local tp0 = nowMs()
        if tp0 == nil then return self:populateSettingsCell(index, cell) end
        local r = self:populateSettingsCell(index, cell)
        self._popMs = (self._popMs or 0) + (nowMs() - tp0)
        self._popN  = (self._popN or 0) + 1
        if self._popMs >= PROFILE_POP_MS and (self._popLines or 0) < PROFILE_POP_MAX then
            self._popLines = (self._popLines or 0) + 1
            print(string.format(
                "[SmartDistribution] Overview settings populate: %d cells in %.0f ms (%.2f ms/cell, %d rows in list)",
                self._popN, self._popMs, self._popMs / math.max(1, self._popN), #(self.rows or {})))
            self._popMs, self._popN = 0, 0
        end
        return r
    end
    if list ~= self.statsList then return end
    local r = self.rows[index]
    if r == nil then return end
    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end
    setc("assetName",       r.assetName or "?")
    -- "Wheat (In/Out)" -- what the product is to THIS building
    setc("productName",     (r.product or "?") .. (r.role ~= nil and (" (" .. (SmartDistribution.roleDisplay(r.role) or r.role) .. ")") or ""))
    setc("receivedText",    flowV(r.received))
    setc("loadedText",      flowV(r.loaded))
    setc("consumedText",    withExpected(r.consumed, r.consumedExpected))
    setc("unloadedText",    flowV(r.unloaded))
    -- THE BAR, in place of the HELD (MAX) and FREE STORAGE cells. Every path inside it sets or actively
    -- hides each of its parts, which is not optional here: SmoothList RECYCLES cells, so a segment or a
    -- mark left over from the previous row would report another building's tank (the trap 5.7 hit with
    -- colours and 5.57 with the notice row).
    setStorageBar(cell, r, self.grouped)
    setc("producedText",    withExpected(r.produced, r.producedExpected))
    setc("distributedText", flowV(r.distributed))
    setc("storedText",      flowV(r.stored))
    setc("soldText",        soldWithMoney(r.sold, r.money))
    setc("costText",        money(r.cost))
    setPerformanceColor(cell, "consumedText", r.consumed, r.consumedExpected)
    setPerformanceColor(cell, "producedText", r.produced, r.producedExpected)
    setIcon(cell, "assetIcon",   r.assetIcon)
    setIcon(cell, "productIcon", r.productIcon)
end

-- ---- row double-click: jump to that building's own tab ---------------------
-- SmoothList has no double-click event, so it is assembled from the two callbacks it does give: selection
-- tracks WHICH row, and a second click on that same row inside DOUBLE_CLICK_SEC is the gesture. Clicking a
-- row that is already selected does not re-fire onSelectionChanged, which is exactly why the index is
-- remembered from the selection callback rather than read back off the widget at click time.
local DOUBLE_CLICK_SEC = 0.4

function DistributionOverviewPage:onListSelectionChanged(list, section, index)
    self._selIndex = index
end

-- Identity, not list position: the table re-enumerates every 2 s and rows can reorder or drop between the
-- two clicks, which would otherwise land the gesture on whatever building slid into that index.
local function rowKey(r)
    if r == nil then return nil end
    return tostring(r.uid) .. "|" .. tostring(r.ft)
end

function DistributionOverviewPage:onClickStatsRow(element)
    local idx = self._selIndex
    if idx == nil then return end
    local key = rowKey(self.rows[idx])
    if key == nil then return end
    local now = (getTimeSec ~= nil) and getTimeSec() or nil
    if now ~= nil and self._lastClickKey == key and self._lastClickTime ~= nil
       and (now - self._lastClickTime) <= DOUBLE_CLICK_SEC then
        self._lastClickKey, self._lastClickTime = nil, nil      -- consume it, so a third click is a fresh first
        self:openRowBuilding(idx)
        return
    end
    self._lastClickKey, self._lastClickTime = key, now
end

-- Reuses the same path [ + gaze uses to open the menu on a building, so tab choice per asset class
-- (production / silo / husbandry / heap / market) and the green tab highlight are handled in one place.
function DistributionOverviewPage:openRowBuilding(index)
    local r = self.rows[index]
    local p = r ~= nil and r.placeable or nil
    if p == nil or SmartDistribution == nil or SmartDistribution.jumpMenuToAsset == nil then return end
    pcall(SmartDistribution.jumpMenuToAsset, p)
end

-- ---- settings view ---------------------------------------------------------
-- The same rows with the flow figures swapped for the Advanced Inputs / Outputs configuration behind them.
-- Row parity is deliberate (asked for): toggling must not change WHICH rows are listed, so every filter
-- carries across untouched and the inclusion rule is shared. Grouping is the one exception -- settings are
-- per building and "Bakery x2" has no single answer -- so it is forced off here and RESTORED on the way back.

-- Held vs the effective Max in. Orange from CAP_NEAR, red at or over the cap: "nearing the set cap".
local CAP_NEAR = 0.90
local CAP_FULL = 1.00

-- Short status words. The building tabs have room for "Active (Receiving)"; a 140px column does not, and
-- the header already says IN / OUT, so the qualifier carries no information here.
-- Lazy lookup so the call sites (IN_WORD[st]) are untouched and resolution happens at display time.
local IN_WORD  = setmetatable({}, { __index = function(_, k)
    if k == "ACTIVE"  then return SmartDistribution.l10n("dr_statusShort_receiving", "Receiving") end
    if k == "IDLE"    then return SmartDistribution.l10n("dr_statusShort_idle",      "Idle")      end
    if k == "BLOCKED" then return SmartDistribution.l10n("dr_statusShort_blocked",   "Blocked")   end
end })
local OUT_WORD = setmetatable({}, { __index = function(_, k)
    if k == "ACTIVE"  then return SmartDistribution.l10n("dr_statusShort_sending", "Sending") end
    if k == "IDLE"    then return SmartDistribution.l10n("dr_statusShort_idle",    "Idle")    end
    if k == "BLOCKED" then return SmartDistribution.l10n("dr_statusShort_blocked", "Blocked") end
end })

local function setCellColor(cell, name, rgba)
    local c = cell:getAttribute(name)
    if c == nil or c.setTextColor == nil then return end
    -- SmoothList RECYCLES cells, so the uncoloured case must actively reset to white or a row inherits the
    -- colour of whatever row last used that cell (the bug 5.7 already had to fix once on this page).
    if rgba == nil then c:setTextColor(1, 1, 1, 1) else c:setTextColor(rgba[1], rgba[2], rgba[3], rgba[4]) end
end

function DistributionOverviewPage:settingsViewOn()
    return self._settingsView == true
end

function DistributionOverviewPage:onToggleSettingsView()
    local on = not self:settingsViewOn()
    self._settingsView = on
    if on then
        self._groupedBeforeSettings = self.grouped
        if self.grouped then
            self.grouped = false
            if self.filterMode == 2 then self.filterValue = nil end   -- grouping renamed buildings; undo that
            self._filterValuesJoined = nil
        end
    elseif self._groupedBeforeSettings then
        self.grouped = true
        if self.filterMode == 2 then self.filterValue = nil end
        self._filterValuesJoined = nil
    end
    if self.groupOption ~= nil then
        if self.groupOption.setDisabled ~= nil then pcall(function() self.groupOption:setDisabled(on) end) end
        if self.groupOption.setState ~= nil then pcall(function() self.groupOption:setState(self.grouped and 2 or 1) end) end
    end
    self._scrollMap = { { on and "settingsSlider" or "statsSlider", on and "settingsList" or "statsList", 14 } }
    -- ONE PLACE decides what is visible and which lists refresh, so the view toggle and the tab
    -- switch cannot come to disagree about it. It sets _realtimeLists and the footer too.
    self:applyTabContent()
    self:applySelectorChange()
end

-- Flip the footer label if the base page exposes the storage-page button plumbing; harmless no-op if not.
function DistributionOverviewPage:updateViewButton()
    local all = self._allButtons
    if all == nil or self.applyFooterButtons == nil then return end
    -- ON A FOREIGN TAB, BACK IS THE ONLY ACTION LEFT. "Show Settings" and "Refresh" both act on
    -- this page's own table, which is not on screen -- a button that visibly does nothing is worse
    -- than no button, and the footer is the one place a player looks for what a page can do.
    local own = self:ownTabActive()
    local vis = {}
    for _, b in ipairs(all) do
        if b._role == "viewToggle" then
            b.text = self:settingsViewOn() and SmartDistribution.l10n("dr_btn_showFlows", "Show Flows")
                                            or SmartDistribution.l10n("dr_btn_showSettings", "Show Settings")
        end
        if own or b.inputAction == InputAction.MENU_BACK then vis[#vis + 1] = b end
    end
    self:applyFooterButtons(vis)
end

function DistributionOverviewPage:populateSettingsCell(index, cell)
    local r = self.rows[index]
    if r == nil then return end
    -- resolved on first display, then cached on the row -- see SmartDistribution.rowSettings
    local s = (SmartDistribution ~= nil and SmartDistribution.rowSettings ~= nil)
        and (SmartDistribution.rowSettings(r, self:currentWindow()) or {}) or (r.settings or {})
    local col = (SmartDistribution ~= nil and SmartDistribution.LINK_COLOR) or {}
    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end
    setc("assetName",   r.assetName or "?")
    setc("productName", (r.product or "?") .. (r.role ~= nil and (" (" .. (SmartDistribution.roleDisplay(r.role) or r.role) .. ")") or ""))

    -- ---- input side
    if s.isIn then
        -- same wording as the Advanced Inputs dialog's own TYPE cell (Pooled / Individual), so the two
        -- screens describe a building's storage identically
        setc("typeText", s.blocked and SmartDistribution.l10n("dr_type_blocked", "BLOCKED")
            or (s.pooled and SmartDistribution.l10n("dr_type_pooled", "Pooled") or SmartDistribution.l10n("dr_type_individual", "Individual")))
        setCellColor(cell, "typeText", s.blocked and col.BLOCKED or nil)
        -- LITRES, since 2026-09-22: the setting IS litres now, so a percentage here would be a
        -- second unit for one number. A `*` still marks DR's own default rather than a figure the
        -- player set (5.37).
        setc("maxInText", s.blocked and fmtV(0)
             or ((s.capL ~= nil) and (fmtV(s.capL) .. (s.explicit and "" or "*")) or "-"))
        -- held of the effective ceiling, with the fill % that drives the highlight
        local held = (type(s.inHeld) == "number") and fmtV(s.inHeld) or "-"
        if type(s.fillRatio) == "number" then
            held = held .. string.format("  (%d%%)", math.floor(s.fillRatio * 100 + 0.5))
        end
        setc("heldOfMaxText", held)
        local capCol = nil
        if s.blocked then capCol = col.BLOCKED
        elseif type(s.fillRatio) == "number" then
            if s.fillRatio >= CAP_FULL then capCol = col.BLOCKED         -- at or over the cap: nothing more gets in
            elseif s.fillRatio >= CAP_NEAR then capCol = col.IDLE end    -- nearing it
        end
        setCellColor(cell, "heldOfMaxText", capCol)
        setc("fillTargetText", (s.targetL2 ~= nil) and fmtV(s.targetL2) or "-")
        local st = s.inStatus
        setc("inStatusText", (st ~= nil and IN_WORD[st]) or "-")
        setCellColor(cell, "inStatusText", st ~= nil and col[st] or nil)
    else
        setc("typeText", "-"); setc("maxInText", "-"); setc("heldOfMaxText", "-")
        setc("fillTargetText", "-"); setc("inStatusText", "-")
        setCellColor(cell, "typeText", nil); setCellColor(cell, "heldOfMaxText", nil)
        setCellColor(cell, "inStatusText", nil)
    end

    -- ---- output side
    if s.isOut then
        setc("outModeText", s.mode or "-")
        setc("reserveText", (type(s.reserve) == "number" and s.reserve > 0) and fmtV(s.reserve) or "-")
        setCellColor(cell, "reserveText", (type(s.reserve) == "number" and s.reserve > 0) and col.IDLE or nil)
        setc("priorityText", ((s.ranked or 0) > 0)
        and string.format(SmartDistribution.l10n("dr_priority_ranked", "Ranked (%d)"), s.ranked)
        or SmartDistribution.l10n("dr_priority_distance", "Distance"))
        -- "3/5" active destinations. Red at 0 of some -- configured to send, nowhere left to send it, which
        -- is exactly the silent stall that is otherwise invisible on this page.
        local dt, da = s.destTotal, s.destActive
        if type(dt) == "number" and dt > 0 then
            setc("destText", string.format("%d/%d", da or 0, dt))
            setCellColor(cell, "destText", ((da or 0) == 0) and col.BLOCKED or ((da or 0) < dt and col.IDLE or nil))
        else
            -- no routable destination at all for the current mode (Hold, or nothing in reach accepts it)
            setc("destText", (s.outStatus ~= nil) and "none" or "-")
            setCellColor(cell, "destText", (s.outStatus ~= nil) and col.BLOCKED or nil)
        end
        local st = s.outStatus
        setc("outStatusText", (st ~= nil and OUT_WORD[st]) or "-")
        setCellColor(cell, "outStatusText", st ~= nil and col[st] or nil)
        -- "1/4" production lines ON of the lines that make this product. Same colour language as DEST:
        -- red when NONE are on (the building cannot make it at all, however healthy it looks), orange
        -- when only some are. A building with no production lines shows a dash.
        local lt, lo = s.lineTotal, s.lineOn
        if type(lt) == "number" and lt > 0 then
            setc("prodLinesText", string.format("%d/%d", lo or 0, lt))
            setCellColor(cell, "prodLinesText", ((lo or 0) == 0) and col.BLOCKED or ((lo or 0) < lt and col.IDLE or nil))
        else
            setc("prodLinesText", "-")
            setCellColor(cell, "prodLinesText", nil)
        end
    else
        setc("outModeText", "-")
        setc("reserveText", "-"); setc("priorityText", "-"); setc("destText", "-"); setc("outStatusText", "-")
        setc("prodLinesText", "-")
        setCellColor(cell, "reserveText", nil); setCellColor(cell, "destText", nil)
        setCellColor(cell, "outStatusText", nil); setCellColor(cell, "prodLinesText", nil)
    end

    setIcon(cell, "assetIcon",   r.assetIcon)
    setIcon(cell, "productIcon", r.productIcon)
end
