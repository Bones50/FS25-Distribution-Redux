-- =============================================================================
-- ProductionDistributeSell.lua
-- =============================================================================
-- Adds two production output modes, "Distribute + Sell" and "Distribute + Store",
-- selectable from the vanilla production screen's existing output toggle.
--
--   * Click detection: the production frame reads getOutputDistributionMode(ft)
--     and immediately calls setOutputDistributionMode(ft, next, nil). We treat a
--     set as a user click when the immediately-preceding get was for the same
--     (pp, ft). Savegame load calls set with no preceding get -> absolute write.
--   * Each click advances a 4-state virtual mode and writes the real vanilla flag:
--         KEEP -> 0,  DISTRIBUTE -> AUTO_DELIVER,
--         SELL -> STORE + MODE.SELL (mod sells at best price) for priced goods, or
--                 DIRECT_SELL for price-less outputs (e.g. grid electricity/methane),
--         DISTRIBUTE+SELL -> AUTO_DELIVER (+ engine override MODE.DISTRIBUTE_SELL).
--     DISTRIBUTE+SELL uses the AUTO_DELIVER flag so the base engine distributes
--     the surplus; the remainder is sold in our own hourly pass (HOOK 3).
--   * The 4th mode is labelled in the production output list through the frame's
--     populateCellForItemInSection (the row's "activity" cell).
--   * State lives in the engine override (MODE.DISTRIBUTE_SELL), so it persists
--     across save/reload and is inert if this file is removed.
--
-- Remove the feature: delete this file + its <sourceFile> line in modDesc.xml.
-- Multiplayer-safe: the vanilla mode event only carries the 3 base states, so the
-- extended modes are synced with our own ProductionOutputModeEvent (below).
-- =============================================================================

local SD = SmartDistribution
if SD == nil then
    print("[ProductionDistributeSell] SmartDistribution not present; feature disabled.")
    return
end
if ProductionPoint == nil or ProductionPoint.setOutputDistributionMode == nil
   or ProductionPoint.getOutputDistributionMode == nil then
    print("[ProductionDistributeSell] ProductionPoint API missing; feature disabled.")
    return
end

SD.PRODUCTION_DISTSELL_ENABLED = true

local function dbg(fmt, ...)
    if SD.debug then print("[ProductionDistributeSell] " .. string.format(fmt, ...)) end
end

local KEEP, DISTRIBUTE, SELL, DISTSELL, DISTSTORE, STORE = 0, 1, 2, 3, 4, 5

local function vanillaModes()
    local OM = ProductionPoint.OUTPUT_MODE or {}
    -- "store" = the output mode that retains output at the production and materialises it as
    -- pallets (for palletised goods). Use the engine's named value; fall back to 0 (legacy).
    local store = OM.STORE or OM.KEEP or 0
    return store, OM.AUTO_DELIVER, OM.DIRECT_SELL
end

local origGet = ProductionPoint.getOutputDistributionMode
local origSet = ProductionPoint.setOutputDistributionMode

local function placeableOf(pp) return pp ~= nil and pp.owningPlaceable or nil end

local function uidOf(pl)
    if pl == nil then return nil end
    if pl.uniqueId ~= nil then return pl.uniqueId end
    if pl.getUniqueId ~= nil then
        local ok, u = pcall(pl.getUniqueId, pl)
        if ok and u ~= nil then return u end
    end
    return "node:" .. tostring(pl.rootNode)
end

local function isDistSell(pp, ft)
    local pl = placeableOf(pp)
    if pl == nil or SD.getAssetMode == nil then return false end
    return SD.getAssetMode(uidOf(pl), ft) == SD.MODE.DISTRIBUTE_SELL
end

local function isDistStore(pp, ft)
    local pl = placeableOf(pp)
    if pl == nil or SD.getAssetMode == nil then return false end
    return SD.getAssetMode(uidOf(pl), ft) == SD.MODE.DISTRIBUTE_STORE
end

local function isStore(pp, ft)
    local pl = placeableOf(pp)
    if pl == nil or SD.getAssetMode == nil then return false end
    return SD.getAssetMode(uidOf(pl), ft) == SD.MODE.STORE
end

local function isSell(pp, ft)
    local pl = placeableOf(pp)
    if pl == nil or SD.getAssetMode == nil then return false end
    return SD.getAssetMode(uidOf(pl), ft) == SD.MODE.SELL
end

-- per-productionPoint / per-fillType virtual mode (weak so it GCs with the world)
local VTAB = setmetatable({}, { __mode = "k" })

local function seedV(pp, ft)
    -- explicit per-output mod override wins (these persist + sync): Store / Distribute+Store /
    -- Distribute+Sell / Sell / Hold / Distribute that the player set on this building.
    local pl  = placeableOf(pp)
    local raw = (pl ~= nil and SD.getAssetMode ~= nil) and SD.getAssetMode(uidOf(pl), ft) or SD.MODE.INHERIT
    if raw == SD.MODE.STORE then return STORE end
    if raw == SD.MODE.DISTRIBUTE_STORE then return DISTSTORE end
    if raw == SD.MODE.DISTRIBUTE_SELL then return DISTSELL end
    if raw == SD.MODE.SELL then return SELL end
    if raw == SD.MODE.HOLD then return KEEP end
    if raw == SD.MODE.DISTRIBUTE then return DISTRIBUTE end
    -- no explicit choice (INHERIT): honour an engine flag the base game restored on load...
    local _, auto, sell = vanillaModes()
    local cur = origGet(pp, ft)
    if cur == auto then return DISTRIBUTE end
    if cur == sell then return SELL end
    -- ...otherwise follow the mod's resolved default, so an output left on the global "Distribute"
    -- default is shown (and treated) as Distribute -- keeping this label in step with the distributor.
    if pl ~= nil and SD.resolvedAssetMode ~= nil then
        local m = SD.resolvedAssetMode(pl, ft)
        if m == SD.MODE.DISTRIBUTE or m == SD.MODE.DISTRIBUTE_SELL or m == SD.MODE.DISTRIBUTE_STORE then
            return DISTRIBUTE
        end
    end
    return KEEP
end

local function getV(pp, ft)
    local t = VTAB[pp]
    if t ~= nil and t[ft] ~= nil then return t[ft] end
    local v = seedV(pp, ft)
    VTAB[pp] = t or {}
    VTAB[pp][ft] = v
    return v
end

local function setV(pp, ft, v)
    VTAB[pp] = VTAB[pp] or {}
    VTAB[pp][ft] = v
end

-- Biogas grid outputs (electricity / methane) are sellDirectly: the engine sells them the instant
-- they're produced and does NOT register them as distributable/storable outputs, so calling the
-- vanilla setOutputDistributionMode/setOutputDistribution on them throws "is not an output fillType".
-- We detect them (scanning the production definitions once per point) to skip that engine write.
local SELLDIRECT_CACHE = setmetatable({}, { __mode = "k" })   -- pp -> { [ft] = true } for sellDirectly outputs
local function isSellDirectlyOutput(pp, ft)
    if pp == nil or ft == nil then return false end
    local c = SELLDIRECT_CACHE[pp]
    if c == nil then
        c = {}
        if type(pp.productions) == "table" then
            for _, prod in ipairs(pp.productions) do
                for _, o in ipairs(prod.outputs or {}) do
                    if o.sellDirectly and o.type ~= nil then c[o.type] = true end
                end
            end
        end
        SELLDIRECT_CACHE[pp] = c
    end
    return c[ft] == true
end

-- apply a virtual state on THIS machine only: refresh the cache, set the vanilla
-- output flag, and set the mod override -- all with noEventSend, so this never
-- emits a network event. Callers fire ProductionOutputModeEvent to sync peers.
local function applyVLocal(pp, ft, v)
    setV(pp, ft, v)
    -- sellDirectly outputs (biogas electricity / methane) reject every vanilla distribution mode;
    -- skip the engine write + the (meaningless) mod override. Their income is booked by
    -- SmartDistribution.sellDirectProduction regardless of mode; we keep the cached virtual state
    -- above so the production-menu label stays consistent.
    if isSellDirectlyOutput(pp, ft) then return end
    local store, auto, sell = vanillaModes()
    local pl = placeableOf(pp)
    local M  = SD.MODE
    if v == DISTSELL then
        origSet(pp, ft, auto, true)
        if pl ~= nil then SD.applyAssetMode(pl, ft, M.DISTRIBUTE_SELL, true) end
    elseif v == DISTSTORE then
        origSet(pp, ft, store, true)                            -- STORE so the production spawns its output as pallets;
        if pl ~= nil then SD.applyAssetMode(pl, ft, M.DISTRIBUTE_STORE, true) end  -- phase 1 distributes from them, palletPhase stores the remainder
    elseif v == STORE then
        origSet(pp, ft, store, true)                            -- vanilla STORE so output accumulates / spawns pallets;
        if pl ~= nil then SD.applyAssetMode(pl, ft, M.STORE, true) end  -- engine STORE: no distribute, storePhase/palletPhase moves it all to storage
    elseif v == SELL then
        -- The mod's HOOK 3 pass can only sell outputs that have a market price (it
        -- prices via economyManager:getPricePerLiter and skips price-0 items). So:
        --   priced goods    -> hold in storage + engine MODE.SELL, sold at best price;
        --   price-less goods -> base-game direct sell (e.g. grid electricity / methane),
        --                       so they still sell exactly as they did before.
        local econ = g_currentMission ~= nil and g_currentMission.economyManager or nil
        local hasPrice = false
        if econ ~= nil and econ.getPricePerLiter ~= nil then
            local ok, p = pcall(econ.getPricePerLiter, econ, ft)
            hasPrice = ok and type(p) == "number" and p > 0
        end
        if hasPrice then
            origSet(pp, ft, store, true)
            if pl ~= nil then SD.applyAssetMode(pl, ft, M.SELL, true) end
        else
            origSet(pp, ft, sell, true)
            if pl ~= nil then SD.applyAssetMode(pl, ft, M.INHERIT, true) end
        end
    else
        local flag = (v == DISTRIBUTE) and auto or store
        origSet(pp, ft, flag, true)
        -- Record the base-state choice in the mod's OWN table so the resolver can tell Hold from
        -- Distribute (the engine auto-deliver flag alone cannot, and an output left on the global
        -- Distribute default must be usable as a source). Both persist (save skips only INHERIT) and
        -- sync exactly as before -- this only changes the stored value, not the engine flag above.
        if pl ~= nil then SD.applyAssetMode(pl, ft, (v == DISTRIBUTE) and M.DISTRIBUTE or M.HOLD, true) end
    end
end

local function isMP()
    return g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil
       and g_currentMission.missionDynamicInfo.isMultiplayer == true
end

-- ---- multiplayer sync ------------------------------------------------------
-- The vanilla output-mode event only carries the 3 base states, so the extended
-- modes (Distribute+Sell / Distribute+Store) can't ride it. This event carries the
-- full 5-state virtual mode for one (production, fillType); on every peer run()
-- re-applies it locally (vanilla flag + mod override), so the server -- which runs
-- the hourly distribute/store/sell pass -- and all clients stay in agreement.
-- Mirrors DistributionModeEvent; registered with InitEventClass below so it serializes over the net.
ProductionOutputModeEvent = {}
local POME_mt = Class(ProductionOutputModeEvent, Event)
-- REQUIRED: register the event's network id, else a client's send is silently undeliverable and
-- only the host's local change would apply (the multiplayer mode-change bug).
InitEventClass(ProductionOutputModeEvent, "ProductionOutputModeEvent")
ProductionOutputModeEvent.VSTATE_NUM_BITS = 3   -- virtual states 0..4 fit in 3 bits

function ProductionOutputModeEvent.emptyNew()
    return Event.new(POME_mt)
end

function ProductionOutputModeEvent.new(placeable, fillTypeIndex, vstate)
    local self = ProductionOutputModeEvent.emptyNew()
    self.placeable = placeable
    self.fillTypeIndex = fillTypeIndex
    self.vstate = vstate
    return self
end

function ProductionOutputModeEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteUIntN(streamId, self.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
    streamWriteUIntN(streamId, self.vstate, ProductionOutputModeEvent.VSTATE_NUM_BITS)
end

function ProductionOutputModeEvent:readStream(streamId, connection)
    self.placeable = NetworkUtil.readNodeObject(streamId)
    self.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
    self.vstate = streamReadUIntN(streamId, ProductionOutputModeEvent.VSTATE_NUM_BITS)
    self:run(connection)
end

function ProductionOutputModeEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection)        -- server relays to the other clients
    end
    local pl = self.placeable
    local pp = (pl ~= nil and pl.spec_productionPoint ~= nil) and pl.spec_productionPoint.productionPoint or nil
    if pp ~= nil then
        applyVLocal(pp, self.fillTypeIndex, self.vstate)        -- local apply only; never re-emits
    end
end

function ProductionOutputModeEvent.sendEvent(placeable, fillTypeIndex, vstate)
    if placeable == nil then return end
    if g_server ~= nil then
        g_server:broadcastEvent(ProductionOutputModeEvent.new(placeable, fillTypeIndex, vstate))
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(ProductionOutputModeEvent.new(placeable, fillTypeIndex, vstate))
    end
end

-- ---- shared cycle + public API --------------------------------------------
-- One step of the 5-state virtual mode, applied locally and synced in MP. This
-- is the SINGLE seam both the production-screen click (HOOK 1) and the Distribution
-- dialog drive, so the two surfaces always agree.
local VLABEL = { [KEEP]="Hold", [DISTRIBUTE]="Distribute", [SELL]="Sell",
                 [DISTSELL]="Distribute + Sell", [DISTSTORE]="Distribute + Store", [STORE]="Store" }
local function cycleVirtual(pp, ft)
    local nv = (getV(pp, ft) + 1) % 6
    applyVLocal(pp, ft, nv)                              -- apply on this machine immediately
    if isMP() then                                      -- and sync the rest of the session
        ProductionOutputModeEvent.sendEvent(placeableOf(pp), ft, nv)
    end
    return nv
end

-- exposed for DistributionSiloDialog (production assets): read + cycle the same mode.
function SD.productionOutputVMode(pp, ft) return getV(pp, ft) end
function SD.productionOutputVModeName(v) return VLABEL[v] or ("mode" .. tostring(v)) end
function SD.cycleProductionOutputMode(pp, ft) return cycleVirtual(pp, ft) end

-- set an output to a SPECIFIC virtual mode (not just the next one), applied
-- locally and synced in MP. Backs "cycle all"-style unify operations.
local function setVirtual(pp, ft, v)
    applyVLocal(pp, ft, v)
    if isMP() then ProductionOutputModeEvent.sendEvent(placeableOf(pp), ft, v) end
    return v
end
function SD.setProductionOutputMode(pp, ft, v) return setVirtual(pp, ft, v) end

-- HOOK 1: detect the user's output-toggle click and drive the 5-step cycle.
-- The get-before-set adjacency is the click signal; loads set without a get.
local pPp, pFt = nil, nil

ProductionPoint.getOutputDistributionMode = function(self, ft, ...)
    local r = origGet(self, ft, ...)
    pPp, pFt = self, ft
    return r
end

ProductionPoint.setOutputDistributionMode = function(self, ft, mode, noEventSend, ...)
    local cpp, cft = pPp, pFt
    pPp, pFt = nil, nil                              -- consume
    if SD.PRODUCTION_DISTSELL_ENABLED and cpp == self and cft == ft then
        cycleVirtual(self, ft)                           -- same seam as the dialog
        return
    end
    if isSellDirectlyOutput(self, ft) then               -- engine rejects mode-set on sellDirectly outputs (load restore, etc.)
        if VTAB[self] ~= nil then VTAB[self][ft] = nil end
        return
    end
    local r = origSet(self, ft, mode, noEventSend, ...)  -- absolute write (load, etc.)
    if VTAB[self] ~= nil then VTAB[self][ft] = nil end    -- re-seed on next interaction
    return r
end

-- HOOK 2: label the 4th mode in the production menu's output list.
-- Vanilla populate runs first and labels our output "Distributing" (real flag is
-- AUTO_DELIVER); we replace the row's "activity" text.
if InGameMenuProductionFrame ~= nil and InGameMenuProductionFrame.populateCellForItemInSection ~= nil then
    local function distSellCellLabel(self, list, section, index, cell)
        if not SD.PRODUCTION_DISTSELL_ENABLED then return end
        if cell == nil or list ~= self.productsList then return end
        if self.getSelectedProduction == nil then return end
        local _, pp = self:getSelectedProduction()
        if pp == nil or pp.sortedProductions == nil then return end
        local production = pp.sortedProductions[index]
        if production == nil then return end
        local ft = production.primaryProductFillType
        if ft ~= nil then
            local activity = cell:getAttribute("activity")
            if activity ~= nil then
                local nm = VLABEL[getV(pp, ft)]   -- our mode label for every output (Hold / Distribute / Sell / ... / Store)
                if nm ~= nil then activity:setText(nm) end
            end
        end
    end
    InGameMenuProductionFrame.populateCellForItemInSection =
        Utils.appendedFunction(InGameMenuProductionFrame.populateCellForItemInSection, distSellCellLabel)
else
    dbg("InGameMenuProductionFrame.populateCellForItemInSection missing; in-menu label disabled.")
end

-- A biogas plant is a production with sellDirectly grid outputs (electricity / methane). Its non-grid
-- byproduct (digestate) is sold by HOOK 3 below; book that income under the biogas-plant finance
-- category (INCOME_BGA -> "Biogas income"), alongside the plant's grid power, rather than generic
-- product sales. Cached per production point.
local BIOGAS_CACHE = setmetatable({}, { __mode = "k" })
local function isBiogasPlant(pp)
    if pp == nil then return false end
    local c = BIOGAS_CACHE[pp]
    if c ~= nil then return c end
    local r = false
    if type(pp.productions) == "table" then
        for _, prod in ipairs(pp.productions) do
            for _, o in ipairs(prod.outputs or {}) do
                if o.sellDirectly then r = true; break end
            end
            if r then break end
        end
    end
    BIOGAS_CACHE[pp] = r
    return r
end

-- HOOK 3: after the base engine distributes, sell the remaining surplus of
-- Distribute+Sell outputs in the same hourly pass (appended after the engine's).
local function sellRemainder(manager)
    if not SD.PRODUCTION_DISTSELL_ENABLED or SD.dryRun then return end
    if g_currentMission == nil then return end
    if not g_currentMission:getIsServer() then return end   -- selling is server-authoritative; a
    -- client running this would addMoney + zero the storage locally and desync from the host.
    local econ = g_currentMission.economyManager
    if econ == nil or econ.getPricePerLiter == nil then return end
    local excluded = (SD.settings and SD.settings.global and SD.settings.global.excludedFillTypes) or {}
    for _, farmTable in pairs(manager.farmIds or {}) do
        for _, pp in ipairs(farmTable.productionPoints or {}) do
            if pp.storage ~= nil and pp.outputFillTypeIds ~= nil then
                local farmId = (pp.getOwnerFarmId ~= nil and pp:getOwnerFarmId())
                            or (pp.owningPlaceable ~= nil and pp.owningPlaceable.ownerFarmId) or 1
                for ft in pairs(pp.outputFillTypeIds) do
                    local sellMode = nil
                    if not excluded[ft] then
                        if isDistSell(pp, ft) then sellMode = SD.MODE.DISTRIBUTE_SELL
                        elseif isSell(pp, ft) then sellMode = SD.MODE.SELL end   -- plain Sell: mod sells the whole output at best price
                    end
                    if sellMode ~= nil then
                        local level = pp.storage.getFillLevel ~= nil and pp.storage:getFillLevel(ft) or 0
                        if level > 0 then
                            -- best-price: hold for the seasonal peak, releasing only enough to keep
                            -- the output storage from filling (same gate as silos). DISTRIBUTE_SELL
                            -- sells the post-distribution surplus; SELL sells the whole output.
                            local sell = level
                            local pl = placeableOf(pp)
                            if pl ~= nil and SD.bestPriceSellAmount ~= nil then
                                sell = SD.bestPriceSellAmount(pl, ft, sellMode, pp.storage, level, level)
                            end
                            local unit  = econ:getPricePerLiter(ft) or 0
                            local price = sell > 0 and unit or 0
                            local ftName = (g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeNameByIndex ~= nil)
                                           and g_fillTypeManager:getFillTypeNameByIndex(ft) or tostring(ft)
                            local plName = (pl ~= nil and pl.getName ~= nil) and pl:getName() or "?"
                            if price > 0 then
                                -- biogas-plant byproduct (digestate) books as Biogas income, not product sales
                                local mt = MoneyType ~= nil and (MoneyType.SOLD_PRODUCTS or MoneyType.OTHER) or nil
                                if MoneyType ~= nil and MoneyType.INCOME_BGA ~= nil and isBiogasPlant(pp) then
                                    mt = MoneyType.INCOME_BGA
                                end
                                if SD._applyMoney ~= nil then
                                    SD._applyMoney(sell * price, farmId, mt)   -- silent + tallied into the per-cycle summary
                                else
                                    g_currentMission:addMoney(sell * price, farmId, mt, true, false)
                                end
                                pp.storage:setFillLevel(level - sell, ft)
                                if SD.recordCycleStat ~= nil then SD.recordCycleStat(pl, ft, "sold", sell) end
                                dbg("prod-sell %d %s @ %.4f = %d  [%s]", sell, ftName, unit, math.floor(sell * unit + 0.5), plName)
                            elseif unit <= 0 then
                                dbg("prod-skip %s: no market price; %d L stays in plant  [%s]", ftName, level, plName)
                            else
                                dbg("prod-hold %s: best-price holding %d L (price %.4f)  [%s]", ftName, level, unit, plName)
                            end
                        end
                    end
                end
            end
        end
    end
end

if ProductionChainManager ~= nil and ProductionChainManager.hourChanged ~= nil then
    ProductionChainManager.hourChanged =
        Utils.appendedFunction(ProductionChainManager.hourChanged, sellRemainder)
    -- Flush the per-cycle money summary AFTER this surplus-sell pass, as its own appended step so it
    -- runs unconditionally (independent of sellRemainder's early-outs), in the SAME hourly tick the
    -- money was applied. On clients the tally is empty (the hourly pass is server-only) so it's a no-op.
    ProductionChainManager.hourChanged =
        Utils.appendedFunction(ProductionChainManager.hourChanged, function(_)
            if SD.flushCycleSummary ~= nil then SD.flushCycleSummary() end
        end)
else
    dbg("ProductionChainManager.hourChanged missing; remainder-sell disabled.")
end

dbg("loaded - output modes 'Distribute + Sell' and 'Distribute + Store' active.")
