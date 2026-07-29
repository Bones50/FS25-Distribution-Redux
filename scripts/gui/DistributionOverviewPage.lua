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

-- integer liters with thousands separators; a plain dash for nothing, so a busy table stays readable
local function fmt(n)
    n = math.floor((n or 0) + 0.5)
    if n == 0 then return "-" end
    local s = tostring(n)
    local k
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
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
    local base = fmt(liters)
    if revenue ~= nil and revenue > 0.5 and SmartDistribution ~= nil and SmartDistribution.formatMoneyShort ~= nil then
        return base .. "  (" .. SmartDistribution.formatMoneyShort(revenue) .. ")"
    end
    return base
end

-- "1,234  (2,000)" -- the actual, then what the recipe says to expect over the same window. Expectation
-- is nil for anything without a recipe (silos, husbandry), and those read as a bare figure.
local function withExpected(actual, expected)
    if expected == nil or expected < 0.5 then return fmt(actual) end
    -- an explicit "0" rather than fmt's dash: against a stated target, "produced nothing" is the point
    local a = math.floor((actual or 0) + 0.5)
    return (a == 0 and "0" or fmt(actual)) .. "  (" .. fmt(expected) .. ")"
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
    local text = (h == 0 and "0" or fmt(shown)) .. " L"
    if capacity ~= nil then text = text .. " (" .. fmt(capacity) .. " L)" end
    if pallets > 0 then
        text = text .. " + " .. fmt(pallets) .. " L (" .. tostring(count) .. "p)"
    end
    return text
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
    local chainFt = nil
    if self.filterMode == FILTER_CHAIN then
        self:updateFilterValues(self:buildFilterValues(nil))
        chainFt = (self.filterValue ~= nil) and (self.chainFtByName or {})[self.filterValue] or nil
    end

    local all = nil
    if SmartDistribution ~= nil and SmartDistribution.overviewRows ~= nil then
        local ok, r = pcall(SmartDistribution.overviewRows, self:currentWindow(), self.grouped, chainFt)
        if ok and type(r) == "table" then all = r end
    end
    all = all or {}

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
    self._lastRebuild = (getTimeSec ~= nil) and getTimeSec() or nil
end

-- Called by the base page's 2 Hz refresh; the enumeration itself is throttled to REBUILD_SEC, and the
-- list reload that follows re-renders from the cached rows.
function DistributionOverviewPage:rebuildRealtimeData()
    local now = (getTimeSec ~= nil) and getTimeSec() or nil
    if now ~= nil and self._lastRebuild ~= nil and (now - self._lastRebuild) < REBUILD_SEC then return end
    self:rebuildRows()
end

function DistributionOverviewPage:onFrameOpen()
    DistributionOverviewPage:superClass().onFrameOpen(self)
    self._realtimeLists = { "statsList" }
    local function syncState(opt, state)
        if opt ~= nil and opt.setState ~= nil then pcall(function() opt:setState(state) end) end
    end
    syncState(self.periodOption,     self.periodIndex)
    syncState(self.filterModeOption, self.filterMode)
    syncState(self.groupOption,      self.grouped and 2 or 1)
    self:rebuildRows()
    if self.statsList ~= nil then self.statsList:reloadData() end

    self:setSoundSuppressed(true)
    if self.statsList ~= nil then
        FocusManager:setFocus(self.statsList)
    end
    self:setSoundSuppressed(false)
end

-- ---- selectors -------------------------------------------------------------
-- MultiTextOption passes the new state, but not on every path, so fall back to reading the widget.
local function stateOf(opt, state, count)
    if type(state) ~= "number" and opt ~= nil and opt.getState ~= nil then state = opt:getState() end
    if type(state) == "number" and state >= 1 and state <= count then return state end
    return nil
end

function DistributionOverviewPage:applySelectorChange()
    self:rebuildRows()
    if self.statsList ~= nil then self.statsList:reloadData() end
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
    if list == self.statsList then return #self.rows end
    return 0
end

function DistributionOverviewPage:populateCellForItemInSection(list, section, index, cell)
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
    setc("receivedText",    fmt(r.received))
    setc("loadedText",      fmt(r.loaded))
    setc("consumedText",    withExpected(r.consumed, r.consumedExpected))
    setc("unloadedText",    fmt(r.unloaded))
    setc("heldText",        withCapacity(r))
    setc("producedText",    withExpected(r.produced, r.producedExpected))
    setc("distributedText", fmt(r.distributed))
    setc("storedText",      fmt(r.stored))
    setc("soldText",        soldWithMoney(r.sold, r.money))
    setc("costText",        money(r.cost))
    setPerformanceColor(cell, "consumedText", r.consumed, r.consumedExpected)
    setPerformanceColor(cell, "producedText", r.produced, r.producedExpected)
    setIcon(cell, "assetIcon",   r.assetIcon)
    setIcon(cell, "productIcon", r.productIcon)
end

function DistributionOverviewPage:onListSelectionChanged(list, section, index) end
function DistributionOverviewPage:onClickStatsRow(element) end
