-- ============================================================================
-- DistributionInputsDialog.lua  (Distribution Redux)
--
-- "Advanced Inputs" pop-up: governs what a building will accept ON THE WAY IN.
-- Opened from a receiving building (storage, husbandry or production). One row per
-- input product the building can hold, each offering:
--   Block / Allow    -- refuse this product entirely (or allow it again)
--   -  /  +          -- raise / lower this product's MAX % of the (pooled) capacity
--
-- POOLED vs INDIVIDUAL is shown explicitly. A pooled store (hay loft: hay + straw
-- share one slot pool; a husbandry's FOOD pool across grain/silage/etc; a multi-product
-- bulk tank) is where one product can starve another, so the max % there actually
-- reserves room and the shares must sum to <= 100%. Pooled products default to an even
-- split (250k pool / 2 products -> 50% -> 125,000 L each). Individual per-product tanks
-- (straw, water, a single-product silo) can't starve each other, so their max defaults
-- to 100% and is just a fine-tune.
--
-- The % is shown with its live litre equivalent ("50%  (125,000 L)") so the player
-- always sees the real number, and because it's a PERCENT it rides capacity changes
-- (a silo extension) with no re-tuning. Every edit goes through DistributionControlEvent.
-- ============================================================================

DistributionInputsDialog = {}
local Dlg_mt = Class(DistributionInputsDialog, MessageDialog)

local CAP_STEP = 5      -- percent per -/+ Max press
local TARGET_STEP = 5   -- percent per -/+ Target press

local function fillTypeTitle(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
        if ok and def ~= nil and def.title ~= nil then return def.title end
    end
    return tostring(ft)
end

local function fmtL(liters)
    liters = math.floor((liters or 0) + 0.5)
    -- thousands separators for readability
    local s = tostring(liters)
    local out, n = s:reverse():gsub("(%d%d%d)", "%1,")
    return out:reverse():gsub("^,", "")
end

function DistributionInputsDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or Dlg_mt)
    self.rows = {}
    self.rowIndex = 1
    return self
end

function DistributionInputsDialog:setup(asset)
    self.asset = asset
    self.rowIndex = 1
    self:rebuildRows()
end

function DistributionInputsDialog:rebuildRows()
    self.rows = {}
    self.poolLiters = nil
    if self.asset == nil or SmartDistribution == nil or SmartDistribution.receiverInputRows == nil then return end
    local rows, poolLiters = SmartDistribution.receiverInputRows(self.asset)
    self.rows = rows or {}
    self.poolLiters = poolLiters
    if self.rowIndex > #self.rows then self.rowIndex = math.max(1, #self.rows) end
end

function DistributionInputsDialog:onOpen()
    DistributionInputsDialog:superClass().onOpen(self)
    if self.inputList ~= nil then self.inputList:setDataSource(self); self.inputList:setDelegate(self) end
    self:refresh()
end

function DistributionInputsDialog:refresh()
    if self._refreshing then return end
    self._refreshing = true
    if self.inputList ~= nil then self.inputList:reloadData() end
    if self.dialogTitleElement ~= nil and self.asset ~= nil then
        local nm = (self.asset.getName ~= nil) and self.asset:getName() or "Building"
        self.dialogTitleElement:setText("Advanced Inputs - " .. tostring(nm))
    end
    if self.dialogTextElement ~= nil then
        if self.poolLiters ~= nil then
            -- show how much of the pool the current shares add up to (should stay <= 100%)
            local alloc = 0
            for _, r in ipairs(self.rows) do
                if r.pooled and not r.blocked then alloc = alloc + (r.pct or 0) end
            end
            self.dialogTextElement:setText(string.format("Pooled storage: %s L shared - %d%% allocated. Shares can't exceed 100%% together.", fmtL(self.poolLiters), alloc))
        else
            self.dialogTextElement:setText("Set each product's max, or block it. This building has individual per-product storage.")
        end
    end
    self:updateBlockLabel()
    self:updateBlockAllLabel()
    self._refreshing = false
end

-- ---- list data ------------------------------------------------------------
function DistributionInputsDialog:getNumberOfItemsInSection(list, section)
    return #self.rows
end

function DistributionInputsDialog:populateCellForItemInSection(list, section, index, cell)
    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end
    local r = self.rows[index]
    if r == nil then return end
    setc("name", r.readOnly and (r.name or "") or fillTypeTitle(r.ft))
    setc("kind", r.readOnly and "Internal" or (r.pooled and "Pooled" or "Individual"))
    setc("held", fmtL(r.held) .. " L")
    if r.readOnly then
        setc("cap", fmtL(r.maxLiters) .. " L")   -- capacity, informational
        setc("target", "-")
    elseif r.blocked then
        setc("cap", "BLOCKED")
        setc("target", "-")
    else
        setc("cap", string.format("%d%%  (%s L)", r.pct, fmtL(r.maxLiters)))
        if r.targetPct ~= nil then
            setc("target", string.format("%d%%  (%s L)", r.targetPct, fmtL(r.targetLiters or 0)))
        else
            setc("target", "Off")
        end
    end
    -- icon (hidden for the read-only internal row)
    local ic = cell:getAttribute("fillIcon")
    if ic ~= nil then
        if r.readOnly then
            if ic.setVisible ~= nil then ic:setVisible(false) end
        else
            if ic.setVisible ~= nil then ic:setVisible(true) end
            if ic.setImageFilename ~= nil and g_fillTypeManager ~= nil then
                local def = g_fillTypeManager:getFillTypeByIndex(r.ft)
                if def ~= nil and def.hudOverlayFilename ~= nil then ic:setImageFilename(def.hudOverlayFilename) end
            end
        end
    end
end

function DistributionInputsDialog:onListSelectionChanged(list, section, index)
    if self._refreshing then return end
    self.rowIndex = index
    self:updateBlockLabel()
end
function DistributionInputsDialog:onClickInputRow(element) end

function DistributionInputsDialog:selectedRow()
    return self.rows[self.rowIndex or 1]
end

-- Relabel the block button for the selected row: blocked -> "Allow", else "Block".
function DistributionInputsDialog:updateBlockLabel()
    if self.blockButton == nil or self.blockButton.setText == nil then return end
    local r = self:selectedRow()
    self.blockButton:setText((r ~= nil and r.blocked) and "Allow" or "Block")
end

-- ---- actions (all routed through the MP-safe control event) ----------------
function DistributionInputsDialog:rcvUid()
    if self.asset == nil or SmartDistribution.assetUid == nil then return nil end
    return SmartDistribution.assetUid(self.asset)
end

function DistributionInputsDialog:apply(act, ft, delta, flag)
    local uid = self:rcvUid()
    if uid == nil then return end
    if DistributionControlEvent ~= nil and DistributionControlEvent.send ~= nil then
        DistributionControlEvent.send(act, uid, ft, "", delta or 0, flag or false)
    end
    local keepFt = ft
    self:rebuildRows()
    for i, r in ipairs(self.rows) do if r.ft == keepFt then self.rowIndex = i; break end end
    self:refresh()
    if self.inputList ~= nil and self.inputList.setSelectedItem ~= nil then
        pcall(self.inputList.setSelectedItem, self.inputList, 1, self.rowIndex, true)
    end
end

function DistributionInputsDialog:onToggleBlock()
    local r = self:selectedRow()
    if r == nil or r.readOnly then return end
    local A = DistributionControlEvent.ACT
    self:apply(A.INPUT_BLOCK, r.ft, 0, not r.blocked)
end

-- Block or allow EVERY input product in one press. Direction follows what is on screen: anything still
-- allowed -> block the lot; nothing allowed -> allow the lot. Events are sent for the whole sweep and the
-- list is rebuilt once at the end rather than per row.
function DistributionInputsDialog:onToggleAllBlock()
    local uid = self:rcvUid()
    if uid == nil or #self.rows == 0 then return end
    if DistributionControlEvent == nil or DistributionControlEvent.send == nil then return end
    local anyAllowed = false
    for _, r in ipairs(self.rows) do if not r.blocked then anyAllowed = true; break end end
    local blockTarget = anyAllowed
    local A = DistributionControlEvent.ACT
    for _, r in ipairs(self.rows) do
        if r.blocked ~= blockTarget then
            DistributionControlEvent.send(A.INPUT_BLOCK, uid, r.ft, "", 0, blockTarget)
        end
    end
    self:rebuildRows()
    self:refresh()
    if self.inputList ~= nil and self.inputList.setSelectedItem ~= nil then
        pcall(self.inputList.setSelectedItem, self.inputList, 1, self.rowIndex, true)
    end
end

-- "Block All" while anything is still allowed, otherwise "Allow All".
function DistributionInputsDialog:updateBlockAllLabel()
    if self.blockAllButton == nil or self.blockAllButton.setText == nil then return end
    local anyAllowed = false
    for _, r in ipairs(self.rows) do if not r.blocked then anyAllowed = true; break end end
    self.blockAllButton:setText(anyAllowed and "Block All" or "Allow All")
end

-- Max-in (cap %) stepper, now a WRAPPING ring: steps by CAP_STEP and loops 0 <-> max. For an individual
-- product max is 100; for a pooled one it's the remaining headroom (100 - the other pooled products' caps),
-- so the shares still can't sum past 100%.
function DistributionInputsDialog:onCapDelta(dir)
    local r = self:selectedRow()
    if r == nil or r.blocked or r.readOnly then return end
    local maxPct = 100
    if r.pooled and SmartDistribution.inputCapPctHeadroom ~= nil then
        maxPct = math.max(0, math.min(100, SmartDistribution.inputCapPctHeadroom(self.asset, r.ft) or 100))
    end
    local pct = (r.pct or 0) + dir * CAP_STEP
    if pct > maxPct then pct = 0            -- wrap past the top
    elseif pct < 0 then pct = maxPct end    -- wrap past the bottom
    if pct == r.pct then return end
    self:apply(DistributionControlEvent.ACT.INPUT_CAP, r.ft, pct, false)
end
function DistributionInputsDialog:onCapDown() self:onCapDelta(-1) end
function DistributionInputsDialog:onCapUp()   self:onCapDelta( 1) end

-- Fill target stepper, as a WRAPPING ring: Off -> 0% -> 5% -> ... -> 100% -> Off. Off and 0% are distinct
-- (Off = default recipe/buffer demand; 0% = a real "keep empty" setpoint). dir = +1 (up) / -1 (down); it
-- wraps at both ends. The event carries the pct to set, or -1 to clear (Off).
function DistributionInputsDialog:onTargetDelta(dir)
    local r = self:selectedRow()
    if r == nil or r.readOnly or r.blocked then return end
    local n = 2 + math.floor(100 / TARGET_STEP)          -- ring positions: Off(0), 0%(1) .. 100%(n-1)
    local curIdx = (r.targetPct == nil) and 0 or (1 + math.floor((r.targetPct or 0) / TARGET_STEP))
    local newIdx = (curIdx + dir) % n
    if newIdx < 0 then newIdx = newIdx + n end            -- (defensive; Lua % is already non-negative here)
    local A = DistributionControlEvent.ACT
    if newIdx == 0 then
        self:apply(A.INPUT_TARGET, r.ft, -1, false)       -- Off (clear the target)
    else
        self:apply(A.INPUT_TARGET, r.ft, (newIdx - 1) * TARGET_STEP, false)
    end
end
function DistributionInputsDialog:onTargetDown() self:onTargetDelta(-1) end
function DistributionInputsDialog:onTargetUp()   self:onTargetDelta( 1) end

function DistributionInputsDialog:onClickBack()
    self:close()
    return false
end
