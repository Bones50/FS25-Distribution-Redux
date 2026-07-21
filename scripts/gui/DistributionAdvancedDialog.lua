-- ============================================================================
-- DistributionAdvancedDialog.lua  (Distribution Redux)
--
-- "Advanced" pop-up: granular routing for ONE selected output of a building.
--
-- Opened for the output highlighted in the page (its fill type is passed to
-- setup), and only offered when that output's mode routes somewhere the player
-- can configure (SmartDistribution.modeConfigurable).
--
-- TWO lists side by side:
--   left  = DEMANDS   (buildings that consume the product)
--   right = STORAGE or MARKETS, per the mode
-- Every destination row (demand, store or market) supports the SAME two actions:
--   Priority  -- rank it (first press appends, later presses move it)
--   Block/Activate -- block or unblock this output -> destination edge
-- Which lists are populated depends on the mode:
--   Distribute alone          -> demands only
--   Store / Move To            -> storage only (right)
--   Market Supply              -> markets only (right)
--   Distribute + Store/Move To -> demands (left) + storage (right)
--   Distribute + Market        -> demands (left) + markets (right)
--
-- Move To differs from Store ONLY in its default: its storage destinations start
-- BLOCKED (seeded when the output enters the mode), so nothing moves until the
-- player deliberately activates targets -- the loop-safe default.
--
-- SELECTION IS MUTUALLY EXCLUSIVE across the two lists: selecting in one clears
-- the other, so exactly one row is ever highlighted and the action buttons always
-- have a single unambiguous target. Every edit goes through DistributionControlEvent.
-- ============================================================================

DistributionAdvancedDialog = {}
local Dlg_mt = Class(DistributionAdvancedDialog, MessageDialog)

local function fmtDist(d)
    if d == nil then return "" end
    return string.format("%dm", math.floor(d + 0.5))
end

local function fillTypeTitle(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
        if ok and def ~= nil and def.title ~= nil then return def.title end
    end
    return tostring(ft)
end

function DistributionAdvancedDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or Dlg_mt)
    self.demands = {}       -- left list rows
    self.rights  = {}       -- right list rows (stores OR markets)
    self.activeList = nil   -- "DEMAND" or the right kind ("STORE"/"MARKET") -- whichever holds the selection
    self.demandIndex, self.rightIndex = 1, 1
    return self
end

function DistributionAdvancedDialog:setup(asset, ft)
    self.asset = asset
    self.ft = ft
    self.demandIndex, self.rightIndex = 1, 1
    self.activeList = nil
    self:resolveOutput()
    self:rebuildRows()
end

-- Resolve the selected output's mode + which destination kinds it routes to. Productions carry the
-- parallel VIRTUAL mode; everything else uses the generic asset mode.
function DistributionAdvancedDialog:resolveOutput()
    self.outName, self.modeName = fillTypeTitle(self.ft), ""
    self.showDemands, self.rightKind = false, nil
    self.isMoveTo = false                      -- only Move To can close a routing ring
    local a, ft = self.asset, self.ft
    if a == nil or ft == nil or SmartDistribution == nil then return end

    local pp = SmartDistribution.productionPointOf ~= nil and SmartDistribution.productionPointOf(a) or nil
    if pp ~= nil then
        local v  = SmartDistribution.productionOutputVMode ~= nil and SmartDistribution.productionOutputVMode(pp, ft) or nil
        self.modeName = (v ~= nil and SmartDistribution.productionOutputVModeName ~= nil)
            and SmartDistribution.productionOutputVModeName(v) or ""
        -- virtual: 1 DISTRIBUTE, 3 DIST+SELL, 4 DIST+STORE, 5 STORE, 6 TRANSFER(market), 7 DIST+MARKET
        self.showDemands = (v == 1 or v == 3 or v == 4 or v == 7)
        if v == 4 or v == 5 then self.rightKind = "STORE"
        elseif v == 6 or v == 7 then self.rightKind = "MARKET" end
    else
        local m = SmartDistribution.resolvedAssetMode(a, ft)
        local M = SmartDistribution.MODE
        self.modeName = SmartDistribution.modeName(m)
        self.showDemands = (SmartDistribution.modeDistributes ~= nil) and SmartDistribution.modeDistributes(m) or false
        self.isMoveTo = (m == M.STORE_TO or m == M.DISTRIBUTE_STORE_TO)
        if m == M.STORE or m == M.DISTRIBUTE_STORE or m == M.STORE_TO or m == M.DISTRIBUTE_STORE_TO then
            self.rightKind = "STORE"
        elseif m == M.TRANSFER_MARKET or m == M.DISTRIBUTE_MARKET then
            self.rightKind = "MARKET"
        end
    end
end

function DistributionAdvancedDialog:rebuildRows()
    self.demands, self.rights = {}, {}
    local a, ft = self.asset, self.ft
    if a == nil or ft == nil or SmartDistribution == nil or SmartDistribution.outputDestinations == nil then return end
    if self.showDemands then
        self.demands = SmartDistribution.outputDestinations(a, ft, true, false, false)
    end
    if self.rightKind == "STORE" then
        self.rights = SmartDistribution.outputDestinations(a, ft, false, true, false)
    elseif self.rightKind == "MARKET" then
        self.rights = SmartDistribution.outputDestinations(a, ft, false, false, true)
    end
    -- LOOPBACK TEST: with Move To selected, an ACTIVE storage destination that can send this product back
    -- to us -- directly (A->B->A) or round any longer ring (A->B->C->A) -- would shuttle stock forever and
    -- bill a distribution cost every cycle while moving nothing on net.  Mark it rather than let the
    -- player activate a route that silently does that.  The graph is walked once, not once per row.
    if self.isMoveTo and self.rightKind == "STORE" and #self.rights > 0
       and SmartDistribution.moveToCreatesLoop ~= nil and SmartDistribution.assetUid ~= nil then
        local srcUid = SmartDistribution.assetUid(a)
        if srcUid ~= nil then
            local edges = (SmartDistribution.moveToActiveEdges ~= nil)
                and SmartDistribution.moveToActiveEdges(ft) or nil
            for _, d in ipairs(self.rights) do
                if not d.blocked and d.uid ~= nil
                   and SmartDistribution.moveToCreatesLoop(srcUid, ft, d.uid, edges) then
                    d.statusLabel = "Active - Invalid"
                    d.status      = "INVALID"
                end
            end
            local lc = SmartDistribution.LINK_COLOR
            if type(lc) == "table" and lc.INVALID == nil then lc.INVALID = { 0.90, 0.25, 0.20, 1 } end
        end
    end
    if self.demandIndex > #self.demands then self.demandIndex = math.max(1, #self.demands) end
    if self.rightIndex  > #self.rights  then self.rightIndex  = math.max(1, #self.rights)  end
    -- default the active list if nothing chosen yet: demands if present, else the right list
    if self.activeList == nil then
        if #self.demands > 0 then self.activeList = "DEMAND"
        elseif #self.rights > 0 then self.activeList = self.rightKind end
    end
end

function DistributionAdvancedDialog:onOpen()
    DistributionAdvancedDialog:superClass().onOpen(self)
    if self.demandList ~= nil then self.demandList:setDataSource(self); self.demandList:setDelegate(self) end
    if self.rightList  ~= nil then self.rightList:setDataSource(self);  self.rightList:setDelegate(self)  end
    self:refresh()
end

function DistributionAdvancedDialog:refresh()
    if self._refreshing then return end
    self._refreshing = true
    if self.demandList ~= nil then self.demandList:reloadData() end
    if self.rightList  ~= nil then self.rightList:reloadData() end
    if self.dialogTitleElement ~= nil and self.asset ~= nil then
        local nm = (self.asset.getName ~= nil) and self.asset:getName() or "Building"
        self.dialogTitleElement:setText("Advanced - " .. tostring(nm))
    end
    if self.dialogTextElement ~= nil then
        local line = string.format("%s  (%s)", tostring(self.outName), tostring(self.modeName))
        -- A transient notice (e.g. a refused loopback activation) is shown HERE, inside the dialog.
        -- g_currentMission:showBlinkingWarning draws behind an open menu, so it stays invisible until
        -- every window is closed -- useless for feedback on a button press.
        if self._notice ~= nil and self._notice ~= "" then line = line .. "     " .. self._notice end
        self.dialogTextElement:setText(line)
    end
    if self.rightHeaderElement ~= nil then
        self.rightHeaderElement:setText(self.rightKind == "MARKET" and "MARKETS" or "STORAGE")
    end
    self:updateToggleLabel()
    self:updateToggleAllLabel()
    self._refreshing = false
end

-- ---- list data ------------------------------------------------------------
function DistributionAdvancedDialog:getNumberOfItemsInSection(list, section)
    if list == self.demandList then return #self.demands end
    if list == self.rightList  then return #self.rights end
    return 0
end

function DistributionAdvancedDialog:populateCellForItemInSection(list, section, index, cell)
    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end
    local d = (list == self.demandList) and self.demands[index] or self.rights[index]
    if d == nil then return end
    setc("name",   d.name)
    setc("dist",   fmtDist(d.dist))
    setc("rank",   d.rank ~= nil and ("#" .. tostring(d.rank)) or "-")
    setc("status", d.statusLabel)
    local sc = cell:getAttribute("status")
    local col = (SmartDistribution.LINK_COLOR or {})[d.status]
    if sc ~= nil and col ~= nil and sc.setTextColor ~= nil then sc:setTextColor(col[1], col[2], col[3], col[4]) end
end

-- Mutually-exclusive selection: selecting in one list clears the other, so only one row is ever
-- highlighted and the buttons always act on that single selection.
function DistributionAdvancedDialog:onListSelectionChanged(list, section, index)
    if self._refreshing then return end
    self._notice = nil                      -- any pending message is stale once the selection moves
    if list == self.demandList then
        self.demandIndex = index
        self.activeList = "DEMAND"
        if self.rightList ~= nil and self.rightList.setSelectedItem ~= nil then
            self._refreshing = true
            pcall(self.rightList.setSelectedItem, self.rightList, 1, 0, false)   -- clear right selection
            self._refreshing = false
        end
    elseif list == self.rightList then
        self.rightIndex = index
        self.activeList = self.rightKind
        if self.demandList ~= nil and self.demandList.setSelectedItem ~= nil then
            self._refreshing = true
            pcall(self.demandList.setSelectedItem, self.demandList, 1, 0, false)  -- clear left selection
            self._refreshing = false
        end
    end
    self:updateToggleLabel()
end
function DistributionAdvancedDialog:onClickDemandRow(element) end
function DistributionAdvancedDialog:onClickRightRow(element) end

-- Relabel the Block/Activate button for the selected row. One uniform action for every destination
-- kind: if the edge is currently blocked the button says "Activate" (unblock), else "Block".
function DistributionAdvancedDialog:updateToggleLabel()
    if self.toggleButton == nil or self.toggleButton.setText == nil then return end
    local r = self:selectedRow()
    local label = "Toggle"
    if r ~= nil then
        label = r.blocked and "Activate" or "Block"
    end
    self.toggleButton:setText(label)
end

-- ---- actions (all routed through the MP-safe control event) ----------------
-- The single selected row + its owning list.
function DistributionAdvancedDialog:selectedRow()
    if self.asset == nil then return nil end
    local srcUid = SmartDistribution.assetUid(self.asset)
    if srcUid == nil then return nil end
    if self.activeList == "DEMAND" then
        return self.demands[self.demandIndex], "DEMAND", srcUid, self.demandList
    elseif self.activeList ~= nil then
        return self.rights[self.rightIndex], self.activeList, srcUid, self.rightList
    end
    return nil
end

-- Apply an edit, rebuild, and keep the highlight on the same row (ranking moves it).
function DistributionAdvancedDialog:sendControl(act, a, ft, b, delta, flag, whichList, keepUid)
    if DistributionControlEvent ~= nil and DistributionControlEvent.send ~= nil then
        DistributionControlEvent.send(act, a, ft, b, delta or 0, flag or false)
    end
    self:rebuildRows()
    if keepUid ~= nil then
        local rows = (whichList == self.demandList) and self.demands or self.rights
        for i, r in ipairs(rows) do
            if r.uid == keepUid then
                if whichList == self.demandList then self.demandIndex = i else self.rightIndex = i end
                break
            end
        end
    end
    self:refresh()
    if whichList ~= nil and whichList.setSelectedItem ~= nil then
        local idx = (whichList == self.demandList) and self.demandIndex or self.rightIndex
        pcall(whichList.setSelectedItem, whichList, 1, idx, true)
    end
end

function DistributionAdvancedDialog:onMove(delta)
    local r, _, srcUid, whichList = self:selectedRow()
    if r == nil then return end
    local A = DistributionControlEvent.ACT
    -- Same for every destination kind: first Priority press ranks it (append), later presses move it.
    if r.rank == nil then self:sendControl(A.PRIO_TOGGLE, srcUid, self.ft, r.uid, 0, false, whichList, r.uid)
    else self:sendControl(A.PRIO_MOVE, srcUid, self.ft, r.uid, delta, false, whichList, r.uid) end
end
function DistributionAdvancedDialog:onMoveUp()   self:onMove(-1) end
function DistributionAdvancedDialog:onMoveDown() self:onMove( 1) end

-- Block / activate the output -> destination edge, uniformly for demands, stores and markets.
function DistributionAdvancedDialog:onToggle()
    local r, _, srcUid, whichList = self:selectedRow()
    if r == nil then return end
    -- LOOPBACK GUARD: refuse to ACTIVATE a route that would send this product back to where it started,
    -- directly (A->B->A) or round any longer ring (A->B->C->A). Activating is the r.blocked == true case,
    -- since the toggle clears the block. Blocking an existing loop is always allowed -- that is the cure.
    if r.blocked and self.isMoveTo and r.uid ~= nil
       and SmartDistribution.moveToCreatesLoop ~= nil
       and SmartDistribution.moveToCreatesLoop(srcUid, self.ft, r.uid) then
        self._notice = string.format("Cannot activate %s - it would loop the product back here.", tostring(r.name))
        self:refresh()
        return
    end
    self._notice = nil
    local A = DistributionControlEvent.ACT
    self:sendControl(A.BLOCK, srcUid, self.ft, r.uid, 0, not r.blocked, whichList, r.uid)
end

-- Block or activate EVERY destination in one press, across both lists. Direction is decided by what is
-- on screen: if anything is still active it blocks them all, otherwise it activates them all. Activation
-- still honours the loopback guard -- any destination that would close a ring is left blocked and the
-- count is reported in the notice line rather than silently skipped.
function DistributionAdvancedDialog:onToggleAll()
    if self.asset == nil or SmartDistribution.assetUid == nil then return end
    if DistributionControlEvent == nil or DistributionControlEvent.send == nil then return end
    local srcUid = SmartDistribution.assetUid(self.asset)
    if srcUid == nil then return end
    local rows = {}
    for _, r in ipairs(self.demands) do rows[#rows + 1] = r end
    for _, r in ipairs(self.rights)  do rows[#rows + 1] = r end
    if #rows == 0 then return end
    local anyActive = false
    for _, r in ipairs(rows) do if not r.blocked then anyActive = true; break end end
    local blockTarget = anyActive     -- something active -> block everything; nothing active -> activate
    local A, skipped = DistributionControlEvent.ACT, 0
    -- one graph snapshot for the whole sweep: every edge we add shares this source, so adding them
    -- cannot create a NEW return path, and the snapshot stays valid for the pass.
    local edges = nil
    if not blockTarget and self.isMoveTo and SmartDistribution.moveToActiveEdges ~= nil then
        edges = SmartDistribution.moveToActiveEdges(self.ft)
    end
    for _, r in ipairs(rows) do
        if r.uid ~= nil and r.blocked ~= blockTarget then
            local skip = false
            if not blockTarget and self.isMoveTo and SmartDistribution.moveToCreatesLoop ~= nil
               and SmartDistribution.moveToCreatesLoop(srcUid, self.ft, r.uid, edges) then
                skip = true
                skipped = skipped + 1
            end
            if not skip then
                DistributionControlEvent.send(A.BLOCK, srcUid, self.ft, r.uid, 0, blockTarget)
            end
        end
    end
    if skipped > 0 then
        self._notice = string.format("%d destination(s) left blocked - they would loop the product back here.", skipped)
    else
        self._notice = nil
    end
    self:rebuildRows()
    self:refresh()
end

-- "Block All" while anything is still active, otherwise "Activate All".
function DistributionAdvancedDialog:updateToggleAllLabel()
    if self.toggleAllButton == nil or self.toggleAllButton.setText == nil then return end
    local anyActive = false
    for _, r in ipairs(self.demands) do if not r.blocked then anyActive = true; break end end
    if not anyActive then
        for _, r in ipairs(self.rights) do if not r.blocked then anyActive = true; break end end
    end
    self.toggleAllButton:setText(anyActive and "Block All" or "Activate All")
end

function DistributionAdvancedDialog:onClear()
    local r, kind, srcUid, whichList = self:selectedRow()
    if r == nil then return end
    local A = DistributionControlEvent.ACT
    self:sendControl(A.PRIO_CLEAR, srcUid, self.ft, "", 0, false, whichList, r.uid)
end

function DistributionAdvancedDialog:onClickBack()
    self:close()
    return false
end
