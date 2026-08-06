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
local PERIOD_LABELS = { "Hour", "Month", "Year" }
local FILTER_LABELS = { "Nothing (show all)", "Building", "Product", "End product (full chain)" }
local FILTER_CHAIN  = 4   -- the chain mode's index, referenced in a few places below
local GROUP_LABELS  = { "Off (one row per building)", "On (combine same building type)" }
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
    return (a == 0 and "0 L" or fmtV(actual)) .. "  (" .. fmtV(expected) .. ")"
end

-- "12,345 +2p  (50,000)" -- what is held, then how much room there is for it. For a product the building
-- RECEIVES that room is the Advanced Inputs "Max in" figure, not the raw tank, so a capped or blocked
-- input reads honestly. nil capacity (unresolvable) falls back to the held figure alone.
--
-- A production's output lives in two places at once: its internal buffer and whole pallets on its own
-- spawner. The leading figure is the INTERNAL litres and "+Np" is the pallets standing on the pad, so it
-- is obvious where the stock actually is. Pallets moved off the pad are no longer this building's and
-- drop out of both. Only shown when there is something on the spawner, so bulk rows are unchanged.
-- A COOP or SHEEP BARN has no separate buffer to split off (assetHeld already reports the pallet litres
-- as its held figure, and heldPallets is 0 for it), so there the leading number IS the pallet litres and
-- "+Np" says how many pallets those litres are spread across. Same reading either way: total, then pads.
local function withCapacity(row)
    local held, capacity = row.held, row.capacity
    -- the COUNT drives the "(Np)" tag, not litres/1000: pallet capacity differs by fill type, and a
    -- part-filled pallet is one pallet standing on the pad, not zero
    local count   = row.heldPalletCount or 0
    local pallets = row.heldPallets or 0
    local shown   = (pallets > 0) and (row.heldInternal or 0) or held
    local h = math.floor((shown or 0) + 0.5)
    -- "473 L (55,000 L) + 3,000 L (3p)". The capacity bracket belongs directly BESIDE the figure it
    -- qualifies -- trailing it after the pad part gave two bracketed groups in a row
    -- ("473 L + 3,000 L (3p)  (6,000)") which read as though the last one qualified the pallets.
    local text = (h == 0) and "0 L" or fmtV(shown)
    -- Match the building tabs exactly: an INPUT row reads "held / max (pct%)", an output "held (max)".
    -- A row that is both (a silo) takes the input form, because that is the side carrying a settable
    -- percentage -- the litres are identical either way, so the figures still agree with the OUTGOING list.
    if capacity ~= nil then
        if row.role == "In" or row.role == "In/Out" then
            local pct = nil
            if SmartDistribution ~= nil and SmartDistribution.inputCapPct ~= nil and row.placeable ~= nil then
                local ok, v = pcall(SmartDistribution.inputCapPct, row.placeable, row.ft)
                if ok and type(v) == "number" then pct = math.max(0, math.min(100, math.floor(v + 0.5))) end
            end
            text = text .. " / " .. fmtV(capacity)
            if pct ~= nil then text = text .. string.format(" (%d%%)", pct) end
        else
            text = text .. " (" .. fmtV(capacity) .. ")"
        end
    end
    if pallets > 0 then
        text = text .. " + " .. fmtV(pallets) .. " (" .. tostring(count) .. "p)"
    end
    return text
end

-- REMAINING, shared by the Overview and every building tab: how much more will fit, colour-coded.
--   red    -- nothing left (or overfilled): this product cannot take any more
--   orange -- 10% or less of its ceiling still free
--   green  -- room to spare
-- nil capacity means nothing to measure against, so the cell shows a dash in the default colour rather
-- than an invented judgement. Cells are RECYCLED by SmoothList, so every path MUST set a colour or a row
-- inherits whatever the previous row left there (the bug 5.7 already had to fix once on this page).
local function remainingText(remaining)
    if remaining == nil then return "-" end
    return fmtV(remaining)
end
local function remainingColor(remaining, capacity)
    local C = (SmartDistribution ~= nil and SmartDistribution.LINK_COLOR) or {}
    if remaining == nil or capacity == nil or capacity <= 0 then return nil end
    if remaining <= 0.5 then return C.BLOCKED end                    -- full, or over
    if remaining <= capacity * 0.10 then return C.IDLE end           -- nearly full
    return C.ACTIVE
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
    initOption(self.periodOption,     PERIOD_LABELS, self.periodIndex)
    initOption(self.filterModeOption, FILTER_LABELS, self.filterMode)
    initOption(self.groupOption,      GROUP_LABELS,  self.grouped and 2 or 1)
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
        table.sort(values)
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

function DistributionOverviewPage:onFrameOpen()
    DistributionOverviewPage:superClass().onFrameOpen(self)
    -- the view survives leaving and re-entering the tab, so everything here follows it rather than statsList
    local on = self:settingsViewOn()
    self._realtimeLists = { on and "settingsList" or "statsList" }
    local function syncState(opt, state)
        if opt ~= nil and opt.setState ~= nil then pcall(function() opt:setState(state) end) end
    end
    syncState(self.periodOption,     self.periodIndex)
    syncState(self.filterModeOption, self.filterMode)
    syncState(self.groupOption,      self.grouped and 2 or 1)
    local function vis(el, show) if el ~= nil and el.setVisible ~= nil then el:setVisible(show) end end
    vis(self.flowHeaderRow,     not on)
    vis(self.flowListBox,       not on)
    vis(self.settingsHeaderRow, on)
    vis(self.settingsListBox,   on)
    self:updateViewButton()
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
    setc("productName",     (r.product or "?") .. (r.role ~= nil and (" (" .. r.role .. ")") or ""))
    setc("receivedText",    flowV(r.received))
    setc("loadedText",      flowV(r.loaded))
    setc("consumedText",    withExpected(r.consumed, r.consumedExpected))
    setc("unloadedText",    flowV(r.unloaded))
    setc("heldText",        withCapacity(r))
    setc("remainingText",   remainingText(r.remaining))
    -- colour must be set on EVERY path (including the nil case), or a recycled cell keeps the last row's
    local rc = cell:getAttribute("remainingText")
    if rc ~= nil and rc.setTextColor ~= nil then
        local col = remainingColor(r.remaining, r.capacity)
        if col ~= nil then rc:setTextColor(col[1], col[2], col[3], col[4])
        else rc:setTextColor(1, 1, 1, 1) end
    end
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
local IN_WORD  = { ACTIVE = "Receiving", IDLE = "Idle", BLOCKED = "Blocked" }
local OUT_WORD = { ACTIVE = "Sending",   IDLE = "Idle", BLOCKED = "Blocked" }

local function setCellColor(cell, name, rgba)
    local c = cell:getAttribute(name)
    if c == nil or c.setTextColor == nil then return end
    -- SmoothList RECYCLES cells, so the uncoloured case must actively reset to white or a row inherits the
    -- colour of whatever row last used that cell (the bug 5.7 already had to fix once on this page).
    if rgba == nil then c:setTextColor(1, 1, 1, 1) else c:setTextColor(rgba[1], rgba[2], rgba[3], rgba[4]) end
end

local function pctText(pct, liters, explicit)
    if type(pct) ~= "number" then return "-" end
    local t = string.format("%d%%", math.floor(pct + 0.5))
    if type(liters) == "number" and liters > 0 and liters < math.huge then t = t .. "  " .. fmtV(liters) end
    if not explicit then t = t .. " *" end          -- * = auto (DR's default share), not a value you set
    return t
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
    local function vis(el, show) if el ~= nil and el.setVisible ~= nil then el:setVisible(show) end end
    vis(self.flowHeaderRow,     not on)
    vis(self.flowListBox,       not on)
    vis(self.settingsHeaderRow, on)
    vis(self.settingsListBox,   on)
    if self.groupOption ~= nil then
        if self.groupOption.setDisabled ~= nil then pcall(function() self.groupOption:setDisabled(on) end) end
        if self.groupOption.setState ~= nil then pcall(function() self.groupOption:setState(self.grouped and 2 or 1) end) end
    end
    self._realtimeLists = { on and "settingsList" or "statsList" }
    self._scrollMap = { { on and "settingsSlider" or "statsSlider", on and "settingsList" or "statsList", 14 } }
    self:updateViewButton()
    self:applySelectorChange()
end

-- Flip the footer label if the base page exposes the storage-page button plumbing; harmless no-op if not.
function DistributionOverviewPage:updateViewButton()
    local all = self._allButtons
    if all == nil or self.applyFooterButtons == nil then return end
    local vis = {}
    for _, b in ipairs(all) do
        if b._role == "viewToggle" then
            b.text = self:settingsViewOn() and "Show Flows" or "Show Settings"
        end
        vis[#vis + 1] = b
    end
    self:applyFooterButtons(vis)
end

function DistributionOverviewPage:populateSettingsCell(index, cell)
    local r = self.rows[index]
    if r == nil then return end
    -- resolved on first display, then cached on the row -- see SmartDistribution.rowSettings
    local s = (SmartDistribution ~= nil and SmartDistribution.rowSettings ~= nil)
        and (SmartDistribution.rowSettings(r) or {}) or (r.settings or {})
    local col = (SmartDistribution ~= nil and SmartDistribution.LINK_COLOR) or {}
    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end
    setc("assetName",   r.assetName or "?")
    setc("productName", (r.product or "?") .. (r.role ~= nil and (" (" .. r.role .. ")") or ""))

    -- ---- input side
    if s.isIn then
        -- same wording as the Advanced Inputs dialog's own TYPE cell (Pooled / Individual), so the two
        -- screens describe a building's storage identically
        setc("typeText", s.blocked and "BLOCKED" or (s.pooled and "Pooled" or "Individual"))
        setCellColor(cell, "typeText", s.blocked and col.BLOCKED or nil)
        setc("maxInText", s.blocked and "0 L" or pctText(s.pct, s.maxL, s.explicit))
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
        setc("fillTargetText", (s.targetPct ~= nil) and pctText(s.targetPct, s.targetL, true) or "-")
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
        setc("priorityText", ((s.ranked or 0) > 0) and string.format("Ranked (%d)", s.ranked) or "Distance")
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
