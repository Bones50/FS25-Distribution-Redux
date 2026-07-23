-- ============================================================================
-- FS25_Smart_Distribution  /  SmartDistribution.lua
--
-- Demand-driven, proximity-aware replacement for vanilla production
-- distribution, built on a tiered settings model:
--
--   L1 master            - on => our engine runs and suppresses vanilla;
--                          off => mod inert, vanilla (incl. its merge) restored.
--   L2 global defaults   - participation (ALL / VANILLA_ONLY / NONE),
--                          reach (PROXIMITY / FARM_WIDE), default behaviour mode,
--                          radius, bufferHours, sell enable/reserve, exclusions.
--   L3 per asset class   - SILO / PRODUCTION / HUSBANDRY / ... override L2.
--   L4 per asset+filltype- a specific placeable's fill type overrides its class.
--
-- A mode resolves bottom-up: L4 -> L3 -> L2. Logic only ever READS the resolved
-- value; the future settings UI only ever WRITES these tables.
--
-- Each hourly pass is two phases, in order:
--   1. DISTRIBUTE - feed every ACTIVE production what its enabled recipes need,
--                   demand-capped to bufferHours, pulled from enrolled sources
--                   whose mode allows it and that are within reach.
--   2. SELL       - sell remainders for SELL / DISTRIBUTE_SELL assets. Selling
--                   runs after distribution so it can never sell stock a
--                   production still needed.
--
-- Suppression (vanilla hourly pass + silo-extension merge) is gated on master
-- AT CALL TIME, so toggling the mod on/off never leaves the broken vanilla
-- proximity merge half-restored.
-- ============================================================================

SmartDistribution = {}
SmartDistribution.MOD_NAME = g_currentModName

local INF = math.huge

-- ---- enums -----------------------------------------------------------------
local MODE = { INHERIT = 0, HOLD = 1, DISTRIBUTE = 2, DISTRIBUTE_SELL = 3, SELL = 4, DISTRIBUTE_STORE = 5, STORE = 6, TRANSFER_MARKET = 7, DISTRIBUTE_MARKET = 8, HOLD_INTERNAL = 9, STORE_TO = 10, DISTRIBUTE_STORE_TO = 11 }
local REACH = { INHERIT = 0, PROXIMITY = 1, FARM_WIDE = 2 }
local PART  = { ALL = 1, VANILLA_ONLY = 2, NONE = 3 }
SmartDistribution.MODE, SmartDistribution.REACH, SmartDistribution.PARTICIPATION = MODE, REACH, PART

-- ---- settings model --------------------------------------------------------
local S = {
    master = true,
    global = {
        participation     = PART.ALL,
        reach             = REACH.PROXIMITY,
        includeHusbandry  = true,              -- Settings: include animal husbandry (barns/coops/beehives) in the network
        includeSilosSheds = true,              -- Settings: include silos + pallet storage sheds in the network
        includeMarkets    = true,              -- Settings: include markets / kiosks in the network
        advancedRoutingEnabled = true,         -- Settings: master switch for Advanced Outputs (source blocks/priority) + Advanced Inputs (input blocks/caps). Off -> pure distance-based
        mode              = MODE.DISTRIBUTE,   -- default behaviour for sources
        radius            = 50,                -- metres, used when reach == PROXIMITY
        bufferHours       = 2,                 -- hours of feedstock kept at a consumer
        sellEnabled       = true,              -- global safety switch for all selling
        sellReserve       = 0,                 -- litres kept in a source before selling surplus
        bestPriceEnabled  = true,              -- master: hold Sell/Distribute+Sell surplus for its seasonal price peak
        bestPriceDefault  = true,              -- default per-output timing when unset (true = best price, false = immediate)
        seasonalReserveEnabled = false,        -- hold ~a crop-year of feedstock back from Distribute+Sell (crops only)
        seasonalFallbackMonths = 13,           -- months to cover before a crop's harvest window is learned (worst case: player skips to 2nd harvest month)
        seasonalHarvestMinInflow = 5000,       -- litres: an unexplained crop inflow >= this between cycles is treated as a harvest
        distCostEnabled   = true,              -- charge a per-hour cost for each active distribution link
        distCostBase      = 10,                -- $/hour at or below distCostThreshold metres
        distCostThreshold = 50,                -- metres; cost/hr = base * max(1, dist/threshold)
        feedHusbandryEnabled = true,           -- master: auto-feed enrolled husbandry inputs (food + straw) from sources
        feedStrawEnabled     = true,           -- sub-switch: include straw bedding (requires feedHusbandryEnabled)
        waterSupplyEnabled   = true,           -- auto-supply WATER to items that consume it (productions), billed by distance to nearest water source
        includeUnowned    = false,             -- (reserved) enrol unowned/contract assets
        excludedFillTypes = {},                -- [ftIndex] = true, never auto-distribute/sell
    },
    classes = {
        -- ["SILO"]   = { reach = REACH.FARM_WIDE, mode = MODE.DISTRIBUTE },
        -- ["PALLET"] = { reach = REACH.PROXIMITY },
    },
    assets = {},   -- [uid] = { [ftIndex] = MODE }
    sellTiming = {},   -- [uid] = { [ftIndex] = bool }  best-price (true) / immediate (false); absent = follow global default
    inflow = {},   -- [uid] = { [ftIndex] = { last=, rate= } } rolling per-cycle inflow for best-price release sizing (not persisted)
    harvestMonths = {},   -- [ftIndex] = { month, ... } learned harvest window per crop (server-side)
}
SmartDistribution.settings = S

-- mod directory (valid during script load) - used to locate GUI files at runtime
SmartDistribution.modDir = g_currentModDirectory or ""

-- cross-cutting toggles
SmartDistribution.debug  = true
SmartDistribution.dryRun = false
SmartDistribution._prodThruDebug = true   -- TEMP: dump production throughput math (remove after)
-- Reproduce vanilla's sellDirectly-output income (biogas electric charge + methane): our full
-- suppression of the vanilla hourly pass would otherwise drop it.  Verified in-game (electric 0.35/l,
-- methane 0.45/l; digestate income is not doubled, confirming vanilla no longer pays this under the
-- mod).  Kept as a kill-switch; on by default.
SmartDistribution.sellDirectEnabled = true

-- ---- pre-mission default preset (the settings menu overrides this on load) --
-- Global preset: "RANGE" | "PROXIMITY" | "BASE_GAME" | "NONE"
local PRESET = "RANGE"
local function applyPreset(name)
    local g = S.global
    if     name == "RANGE"     then g.participation = PART.ALL;          g.reach = REACH.FARM_WIDE
    elseif name == "PROXIMITY" then g.participation = PART.ALL;          g.reach = REACH.PROXIMITY
    elseif name == "BASE_GAME" then g.participation = PART.VANILLA_ONLY; g.reach = REACH.PROXIMITY
    elseif name == "NONE"      then g.participation = PART.NONE;         g.reach = REACH.PROXIMITY
    end
end
applyPreset(PRESET)
-- exposed so the global settings screen (DistributionSettings.lua) can drive the
-- preset; the TEMP default above is the pre-mission fallback until settings load.
SmartDistribution.applyGlobalPreset = applyPreset
SmartDistribution.PRESET_NAMES = { "RANGE", "PROXIMITY", "BASE_GAME", "NONE" }

-- ---- logging ---------------------------------------------------------------
local function log(fmt, ...)
    if SmartDistribution.debug then
        print("[SmartDistribution] " .. string.format(fmt, ...))
    end
end

local function placeableName(p)
    if p == nil then return "?" end
    if p.getName ~= nil then
        local ok, n = pcall(p.getName, p)
        if ok and n ~= nil and n ~= "" then return n end
    end
    return "placeable#" .. tostring(p.rootNode or "?")
end

-- The building's ORIGINAL (store) name, ignoring any custom name the player set in the construction menu.
-- getName() already returns the custom name when one is set, so this is the secondary/reference label.
-- Returns nil when it matches the displayed name (i.e. the building has not been renamed).
function SmartDistribution.placeableStoreName(p)
    if p == nil then return nil end
    local n
    if g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil and p.configFileName ~= nil then
        local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, p.configFileName)
        if ok and item ~= nil and item.name ~= nil and item.name ~= "" then n = item.name end
    end
    if n == nil and p.configFileNameClean ~= nil then n = tostring(p.configFileNameClean) end
    return n
end

-- The original name, but only when the player has actually renamed the building (else nil).
function SmartDistribution.placeableRenamedFrom(p)
    if p == nil then return nil end
    local custom = p.nameCustom
    if custom == nil or custom == "" then return nil end     -- not renamed -> nothing secondary to show
    local store = SmartDistribution.placeableStoreName(p)
    if store == nil or store == custom then return nil end
    return store
end

local function fillTypeName(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeNameByIndex ~= nil then
        local n = g_fillTypeManager:getFillTypeNameByIndex(ft)
        if n ~= nil then return n end
    end
    return "ft" .. tostring(ft)
end

-- ---- storage level helpers (production Storage AND raw silo/husbandry) ------
local function getLevel(storage, ft)
    if storage == nil then return 0 end
    if storage.fillLevels ~= nil then return storage.fillLevels[ft] or 0 end
    if storage.getFillLevel ~= nil then return storage:getFillLevel(ft) or 0 end
    return 0
end

local function getFree(storage, ft)
    if storage == nil then return 0 end
    if storage.getFreeCapacity ~= nil then return storage:getFreeCapacity(ft) or 0 end
    local cap = 0
    if storage.capacities ~= nil and storage.capacities[ft] ~= nil then
        cap = storage.capacities[ft]
    elseif storage.getCapacity ~= nil then
        cap = storage:getCapacity(ft) or 0
    end
    if cap <= 0 then return INF end
    return math.max(0, cap - getLevel(storage, ft))
end

-- absolute per-fillType capacity of a storage (nil if unknown). For UI fill bars.
local function storageCapacity(storage, ft)
    if storage == nil then return nil end
    if storage.capacities ~= nil and storage.capacities[ft] ~= nil then return storage.capacities[ft] end
    if storage.getCapacity ~= nil then
        local ok, c = pcall(storage.getCapacity, storage, ft)
        if ok and type(c) == "number" and c > 0 then return c end
    end
    return nil
end

local function setLevel(storage, ft, level, farmId, delta)
    if storage.setFillLevel ~= nil then
        storage:setFillLevel(level, ft)                 -- [CONFIRMED] (level, fillType)
    elseif storage.addFillLevel ~= nil and delta ~= nil then
        storage:addFillLevel(farmId, ft, delta)         -- husbandry/silo signature
    elseif storage.fillLevels ~= nil then
        storage.fillLevels[ft] = level
    end
end

-- ---- production-point helper ----------------------------------------------
local function getProductionPoint(placeable)
    if placeable == nil then return nil end
    if placeable.spec_productionPoint ~= nil then
        return placeable.spec_productionPoint.productionPoint
    end
    return nil
end

-- ---- constrain silo-extension merge to real STORAGE SILOS -------------------
-- Gated on S.master at CALL TIME: while the mod is active an extension may only
-- ever pool into a storage silo; switched off it falls through to vanilla.  A
-- station qualifies only if its owner is a PlaceableSilo that is not a husbandry
-- or a production -- so a slurry/grain extension attaches to an actual storage
-- tank/silo (e.g. the liquid-manure baseTank, itself type="silo"), never a barn,
-- and with no such silo in range it attaches to nothing and stays inert.
local function isStorageSiloStation(station)
    if station == nil then return false end
    local owner = station.owningPlaceable
    if owner == nil then return false end
    if owner.spec_silo == nil then return false end
    if owner.spec_husbandry ~= nil then return false end
    if getProductionPoint(owner) ~= nil then return false end
    return true
end

-- parent storage placeable -> set of extension Storages attached to it, captured at
-- attach time (in the addTargetStorage/addSourceStorage hooks below) so distribution
-- treats an extension purely as extra capacity on its parent silo, never its own asset.
local EXT_BY_PARENT = setmetatable({}, { __mode = "k" })
local function recordExtensionParent(station, storage)
    local owner = station ~= nil and station.owningPlaceable or nil
    if owner == nil or storage == nil then return end
    -- never record the silo's OWN storages (base slurry storages are themselves flagged isExtension)
    local silo = owner.spec_silo
    if silo ~= nil and silo.storages ~= nil then
        for _, s in ipairs(silo.storages) do if s == storage then return end end
    end
    local set = EXT_BY_PARENT[owner]
    if set == nil then set = {}; EXT_BY_PARENT[owner] = set end
    set[storage] = true
end
local function parentExtensionStorages(p)
    local out = {}
    local set = p ~= nil and EXT_BY_PARENT[p] or nil
    if set == nil then return out end
    -- exclude the silo's OWN storages (base slurry storages are flagged isExtension too); done at read
    -- time so it is robust regardless of the order in which storages were added at load.
    local own = {}
    if p.spec_silo ~= nil and p.spec_silo.storages ~= nil then
        for _, s in ipairs(p.spec_silo.storages) do own[s] = true end
    end
    for s in pairs(set) do
        if not own[s] then out[#out + 1] = s end
    end
    return out
end

local function keepOnlyStorageSiloStations(list)
    if type(list) ~= "table" then return list end
    if not S.master then return list end
    local out = {}
    for _, st in ipairs(list) do
        if isStorageSiloStation(st) then out[#out + 1] = st end
    end
    return out
end

local function installExtensionBlock()
    local installed = {}

    if ProductionPoint ~= nil and ProductionPoint.findStorageExtensions ~= nil then
        local orig = ProductionPoint.findStorageExtensions
        ProductionPoint.findStorageExtensions = function(self, ...)
            if S.master then return end          -- suppress while active
            return orig(self, ...)
        end
        installed[#installed + 1] = "findStorageExtensions"
    end
    if StorageSystem ~= nil and StorageSystem.getExtendableUnloadingStationsInRange ~= nil then
        local orig = StorageSystem.getExtendableUnloadingStationsInRange
        StorageSystem.getExtendableUnloadingStationsInRange = function(self, ...)
            return keepOnlyStorageSiloStations(orig(self, ...))
        end
        installed[#installed + 1] = "getExtendableUnloadingStationsInRange"
    end
    if StorageSystem ~= nil and StorageSystem.getExtendableLoadingStationsInRange ~= nil then
        local orig = StorageSystem.getExtendableLoadingStationsInRange
        StorageSystem.getExtendableLoadingStationsInRange = function(self, ...)
            return keepOnlyStorageSiloStations(orig(self, ...))
        end
        installed[#installed + 1] = "getExtendableLoadingStationsInRange"
    end
    if UnloadingStation ~= nil and UnloadingStation.addTargetStorage ~= nil then
        local orig = UnloadingStation.addTargetStorage
        UnloadingStation.addTargetStorage = function(self, storage, ...)
            -- A PASTURE never links to a manure heap or slurry pit: refuse the attach so the heap stays
            -- free to bind to the nearest real barn instead. Water troughs / bale feeders still attach.
            if S.master and storage ~= nil and self ~= nil
               and SmartDistribution.isGrazingPasture(self.owningPlaceable)
               and SmartDistribution.storageHoldsManure(storage) then
                return
            end
            -- A standalone silo never becomes an extension of a neighbouring silo (no proximity pooling).
            if S.master and SmartDistribution.blocksSiloSelfExtension(self, storage) then return end
            -- Fold an extension's capacity into its parent ONLY when the parent is a storage silo (DR's
            -- extension model). For any other station -- a husbandry/pasture water or food tank, a
            -- production tank -- let the attach proceed normally so the base game (and mods like Grazing
            -- Pasture) see the storage; we just don't record it as a DR-folded extension.
            if S.master and storage ~= nil and storage.isExtension == true and isStorageSiloStation(self) then
                recordExtensionParent(self, storage)                -- pool the extension into that silo
            end
            return orig(self, storage, ...)
        end
    end
    if LoadingStation ~= nil and LoadingStation.addSourceStorage ~= nil then
        local orig = LoadingStation.addSourceStorage
        LoadingStation.addSourceStorage = function(self, storage, ...)
            if S.master and storage ~= nil and self ~= nil
               and SmartDistribution.isGrazingPasture(self.owningPlaceable)
               and SmartDistribution.storageHoldsManure(storage) then
                return                                             -- pastures never source from manure heaps/pits
            end
            if S.master and SmartDistribution.blocksSiloSelfExtension(self, storage) then return end
            if S.master and storage ~= nil and storage.isExtension == true and isStorageSiloStation(self) then
                recordExtensionParent(self, storage)
            end
            return orig(self, storage, ...)
        end
    end

    log("extension block installed (call-time gated on master): " .. table.concat(installed, ", "))
end
installExtensionBlock()

-- ---- husbandry / raw storage helpers ---------------------------------------
-- known husbandry output fill types by NAME (manure family); cached once.
local OUTPUT_NAMED = nil
local function outputNamedSet()
    if OUTPUT_NAMED == nil then
        OUTPUT_NAMED = {}
        if g_fillTypeManager ~= nil then
            for _, name in ipairs({ "MANURE", "LIQUIDMANURE", "SLURRY" }) do
                local idx = g_fillTypeManager:getFillTypeIndexByName(name)
                if idx ~= nil then OUTPUT_NAMED[idx] = true end
            end
        end
    end
    return OUTPUT_NAMED
end

-- A barn / animal pen.  NOTE: a standalone manure heap is deliberately NOT treated as a husbandry
-- building -- it gets its own HEAP class so it is configured + distributed as its OWN separate
-- storage, not lumped in with the pen.  A heap attached to a real barn still counts via spec_husbandry.
local function isHusbandryBuilding(p)
    return p.spec_husbandry ~= nil or p.spec_husbandryLiquidManure ~= nil or
           p.spec_husbandryMilk ~= nil
end

-- Is this one of the FS25_GrazingPasture mod's pastures?  This must NOT be inferred from base-game
-- structure: spec_husbandryMeadow is present on vanilla barns with an outdoor area too (Cow Barn (large)
-- has it), and both a vanilla barn and a pasture declare MANURE with capacity 0 -- so neither the meadow
-- spec nor the storage shape can tell them apart.  We therefore ask the pasture mod itself when it is
-- loaded, and fall back to its placeable type names.  Guarded throughout, so DR behaves normally when the
-- pasture mod is absent (returns false -> every husbandry is treated as an ordinary barn).
-- (A SmartDistribution.* field, not a top-level local, to respect the 200-local main-chunk ceiling.)
function SmartDistribution.isGrazingPasture(p)
    if p == nil then return false end
    -- FS25 gives each mod its own Lua environment, so DR cannot see PastureFeedOverride and cannot rely on
    -- the pasture mod's own API.  Structural test instead, verified against sdManureProbe output:
    --   Cow Barn (large)     -> spec_husbandryMeadow yes, spec_husbandryLiquidManure YES                 -> normal barn
    --   Grazing Pasture      -> spec_husbandryMeadow yes, spec_husbandryLiquidManure NO,  no pallets     -> pasture
    --   Chicken coop         -> spec_husbandryMeadow yes, spec_husbandryLiquidManure NO,  spec_husbandryPallets YES (EGG) -> normal barn
    --   Chicken shed / silos -> no meadow spec                                                           -> normal
    -- A grazing pasture (cow/sheep/horse from FS25_GrazingPasture) is a pure grazing area: no slurry AND
    -- no pallet output.  A chicken coop shares the meadow + no-slurry shape but emits EGG pallets, so it
    -- must NOT be treated as a pasture -- exclude any pallet-spawner husbandry here (spec_husbandryPallets
    -- / spec_beehivePalletSpawner).  Type names are kept as a secondary match in case the structural test
    -- ever misses; all known pastures also match by name below.
    if p.spec_husbandryMeadow ~= nil and p.spec_husbandryLiquidManure == nil
       and p.spec_husbandryPallets == nil and p.spec_beehivePalletSpawner == nil then return true end
    local tn = p.typeName
    if type(tn) == "string" then
        if tn == "baseHusbandryPasture" or tn == "cowHusbandryPastureFeed"
           or tn == "sheepHusbandryFeed" or tn == "horseHusbandryPastureFeed" then return true end
    end
    return false
end

-- Does this storage carry manure / slurry?  Used to keep manure heaps and slurry pits away from pastures
-- while still letting their water troughs and bale feeders attach normally.
-- (A SmartDistribution.* field, not a top-level local, to respect the 200-local main-chunk ceiling.)
function SmartDistribution.storageHoldsManure(storage)
    if storage == nil or g_fillTypeManager == nil then return false end
    local mft = g_fillTypeManager:getFillTypeIndexByName("MANURE")
    local sft = g_fillTypeManager:getFillTypeIndexByName("LIQUIDMANURE")
    if type(storage.fillTypes) == "table" then
        if (mft ~= nil and storage.fillTypes[mft]) or (sft ~= nil and storage.fillTypes[sft]) then return true end
    end
    if type(storage.capacities) == "table" then
        if (mft ~= nil and storage.capacities[mft] ~= nil) or (sft ~= nil and storage.capacities[sft] ~= nil) then return true end
    end
    if storage.fillTypeIndex ~= nil and (storage.fillTypeIndex == mft or storage.fillTypeIndex == sft) then return true end
    return false
end

-- Build-menu categories whose placeables are pure capacity extensions (no stock of their own). Anything
-- listed here may fold into a neighbouring silo; every other silo keeps its stock separate. Lower-case.
-- Add to this list if your game/mods use a different category name -- the refusal is logged with the
-- category it saw, so an unrecognised one is easy to spot with SmartDistribution.debug on.
SmartDistribution.extensionStoreCategories = {
    ["siloextensions"]    = true,
    ["siloextension"]     = true,
    ["storageextensions"] = true,
    ["storageextension"]  = true,
    ["extensions"]        = true,
    ["extension"]         = true,
}

-- Build-menu (store) category of a placeable, lower-cased; nil when it cannot be resolved.
function SmartDistribution.storeCategoryName(p)
    if p == nil or g_storeManager == nil or p.configFileName == nil then return nil end
    local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, p.configFileName)
    if not ok or item == nil then return nil end
    local c = item.categoryName or item.category
    if type(c) == "string" and c ~= "" then return string.lower(c) end
    return nil
end

-- Which placeable owns this storage?  A Storage does not reliably carry a back-reference, so fall back to
-- scanning the placeable system for the silo that lists it.  Returns nil when it cannot be resolved.
-- (A SmartDistribution.* field, not a top-level local, to respect the 200-local main-chunk ceiling.)
function SmartDistribution.storageOwnerPlaceable(storage)
    if storage == nil then return nil end
    if storage.owningPlaceable ~= nil then return storage.owningPlaceable end
    if storage.owner ~= nil and storage.owner.spec_silo ~= nil then return storage.owner end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil or ps.placeables == nil then return nil end
    for _, p in ipairs(ps.placeables) do
        local silo = p.spec_silo
        if silo ~= nil and silo.storages ~= nil then
            for _, s in ipairs(silo.storages) do
                if s == storage then return p end
            end
        end
    end
    return nil
end

-- Stop two SEPARATE silos merging into one shared pool just because they were built close together.
-- Vanilla lets any storage flagged isExtension bind to a station in range, so a normal silo dropped beside
-- another silo folds into it.  Only a placeable whose BUILD MENU CATEGORY says it is an extension may do
-- that; a silo that is a working store in its own right keeps its stock separate.
-- Scope is deliberately narrow: this only ever policies silo -> silo attachment.  Husbandry / pasture
-- stations are untouched, so pasture water troughs and bale feeders still attach normally.
-- Returns true when this attach must be refused.
-- (A SmartDistribution.* field, not a top-level local, to respect the 200-local main-chunk ceiling.)
function SmartDistribution.blocksSiloSelfExtension(station, storage)
    if station == nil or storage == nil then return false end
    if not isStorageSiloStation(station) then return false end   -- only silo <- silo pooling is policed
    local target = station.owningPlaceable
    local owner  = SmartDistribution.storageOwnerPlaceable(storage)
    local cat    = owner ~= nil and SmartDistribution.storeCategoryName(owner) or nil
    -- one line per silo-to-silo attach so an unexpected category / unresolved owner is visible in the log
    log("silo attach: target='%s' owner='%s' isExtension=%s category=%s",
        placeableName(target), owner ~= nil and placeableName(owner) or "<unresolved>",
        tostring(storage.isExtension), tostring(cat))
    if target == nil or owner == nil then return false end
    if owner == target then return false end          -- a silo's own storage on its own station: always fine
    if owner.spec_silo == nil then return false end   -- not a silo placeable: leave it alone
    if cat ~= nil and SmartDistribution.extensionStoreCategories[cat] then return false end   -- real extension
    if cat == nil then
        -- category unreadable: fall back to structure (capacity-only placeable == genuine extension)
        local silo = owner.spec_silo
        if silo.loadingStation == nil and silo.unloadingStation == nil then return false end
    end
    log("silo pooling refused: '%s' (category %s) will not extend '%s'",
        placeableName(owner), tostring(cat), placeableName(target))
    return true
end

-- ---- Move To loopback test --------------------------------------------------
-- A Move To chain must never return a product to where it started.  A->B->A, or any longer ring such as
-- A->B->C->A, shuttles the same stock back and forth forever and bills a distribution cost every cycle
-- while moving nothing on net.  These two helpers answer that question over the CURRENT graph.
--
-- Every ACTIVE (unblocked) Move To edge for one fill type, as edges[srcUid][destUid] = true.  Only assets
-- actually in a Move To mode contribute edges -- a plain Store destination is a dead end and cannot close
-- a ring.  Self-contained: the uid -> asset mapping is derived from the placeable system, so no lookup
-- table has to be maintained anywhere else.
-- (SmartDistribution.* fields, not top-level locals, to respect the 200-local main-chunk ceiling.)
function SmartDistribution.moveToActiveEdges(ft)
    local edges = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil or ps.placeables == nil or ft == nil then return edges end
    if SmartDistribution.assetUid == nil or SmartDistribution.resolvedAssetMode == nil
       or SmartDistribution.outputDestinations == nil then return edges end
    local M = SmartDistribution.MODE
    for _, p in ipairs(ps.placeables) do
        local uid = SmartDistribution.assetUid(p)
        if uid ~= nil then
            local okM, m = pcall(SmartDistribution.resolvedAssetMode, p, ft)
            if okM and (m == M.STORE_TO or m == M.DISTRIBUTE_STORE_TO) then
                local okD, rows = pcall(SmartDistribution.outputDestinations, p, ft, false, true, false)
                if okD and type(rows) == "table" then
                    local set = edges[uid]
                    if set == nil then set = {}; edges[uid] = set end
                    for _, d in ipairs(rows) do
                        if d ~= nil and d.uid ~= nil and not d.blocked then set[d.uid] = true end
                    end
                end
            end
        end
    end
    return edges
end

-- Does routing srcUid's ft to destUid close a ring?  True when destUid can reach srcUid again by following
-- active Move To edges to any depth.  Pass a prebuilt `edges` table when testing several destinations at
-- once so the graph is only walked together, not rebuilt per row.  The visited set makes a malformed or
-- already-looping graph terminate rather than spin.
function SmartDistribution.moveToCreatesLoop(srcUid, ft, destUid, edges)
    if srcUid == nil or destUid == nil then return false end
    if destUid == srcUid then return true end                  -- straight back into itself
    edges = edges or SmartDistribution.moveToActiveEdges(ft)
    local seen, stack = {}, { destUid }
    while #stack > 0 do
        local cur = table.remove(stack)
        if cur == srcUid then return true end
        if not seen[cur] then
            seen[cur] = true
            local nxt = edges[cur]
            if nxt ~= nil then
                for u in pairs(nxt) do
                    if u == srcUid then return true end
                    if not seen[u] then stack[#stack + 1] = u end
                end
            end
        end
    end
    return false
end

-- Effective per-hour consumption of a husbandry INPUT ("food" | "water" | "straw").  Normal barns publish
-- this on the spec (fs.litersPerHour / ws.litersPerHour / ss.inputLitersPerHour).  GRAZING PASTURES leave
-- it at 0 -- their animals eat from meadow foliage, so the trough advertises no rate -- which would make
-- our feed/straw/water phases skip them.  To feed a pasture like any other husbandry we fall back to the
-- animals themselves: sum each cluster's per-day input curve x head count / 24.  Self-contained (reads the
-- base animalSystem), so it needs no dependency on the pasture mod.  Returns 0 when nothing is known.
function SmartDistribution.husbandryAnimalRate(p, inputKey)
    if p == nil or p.getClusters == nil then return 0 end
    local m = g_currentMission
    local asys = m ~= nil and m.animalSystem or nil
    if asys == nil or asys.getSubTypeByIndex == nil then return 0 end
    local okC, clusters = pcall(p.getClusters, p)
    if not okC or type(clusters) ~= "table" then return 0 end
    local rate = 0
    for _, cluster in ipairs(clusters) do
        local sti = cluster.getSubTypeIndex ~= nil and cluster:getSubTypeIndex() or cluster.subTypeIndex
        local subType = sti ~= nil and asys:getSubTypeByIndex(sti) or nil
        local curve = subType ~= nil and subType.input ~= nil and subType.input[inputKey] or nil
        if curve ~= nil and curve.get ~= nil and cluster.getAge ~= nil and cluster.getNumAnimals ~= nil then
            local okA, perDay = pcall(function() return curve:get(cluster:getAge()) end)
            if okA and type(perDay) == "number" then
                rate = rate + perDay * (cluster:getNumAnimals() or 0) / 24
            end
        end
    end
    return rate
end

-- The rate a feed/straw/water phase should plan against: the spec's own published rate, or -- when that's
-- 0 (a grazing pasture) -- the animal-derived rate above.
function SmartDistribution.husbandryInputRate(p, specRate, inputKey)
    if specRate ~= nil and specRate > 0 then return specRate end
    return SmartDistribution.husbandryAnimalRate(p, inputKey)
end

-- A beehive HONEY spawner (PlaceableBeehivePalletSpawner) is a standalone placeable -- separate from
-- the hive itself -- with no husbandry/storage spec and no interaction trigger.  It accumulates honey
-- (spec_beehivePalletSpawner.pendingLiters) and spawns HONEY pallets (spec.fillType == HONEY) as loose
-- world vehicles, which the pallet world-union (position + owner farm + fill type) already picks up.
local function isBeehiveSpawner(p)
    return p ~= nil and p.spec_beehivePalletSpawner ~= nil
end
-- a "pallet-spawner asset" emits its product as physical pallets: coops/sheep (spec_husbandryPallets,
-- a tracked set) OR beehive honey spawners (spec_beehivePalletSpawner, loose pallets).  Both are driven
-- off the same pallet primitives below.
local function isPalletSpawnerAsset(p)
    if p == nil then return false end
    if p.spec_husbandryPallets ~= nil or p.spec_beehivePalletSpawner ~= nil then return true end
    local pp = getProductionPoint(p)            -- a production whose output spawns pallets
    return pp ~= nil and pp.palletSpawner ~= nil
end
-- a fill type emits as physical pallets when it has a pallet file (e.g. FLOUR, PLANKS, FURNITURE).
local function isPalletizedFillType(ft)
    local m = g_fillTypeManager
    local def = m ~= nil and m.indexToFillType ~= nil and m.indexToFillType[ft] or nil
    return def ~= nil and def.palletFilename ~= nil
end

-- the pallet fill types a production emits. We do NOT trust PalletSpawner.fillTypeToSpawnPlaces:
-- most base-game productions use generic spawn places, leaving that table empty -- the real
-- signal is the production's own palletized outputs (across all of its production lines).
local function productionPalletFillTypes(pp)
    local out, seen = {}, {}
    local function add(ft)
        if ft ~= nil and not seen[ft] then seen[ft] = true; out[#out + 1] = ft end
    end
    if pp.palletSpawner ~= nil and type(pp.palletSpawner.fillTypeToSpawnPlaces) == "table" then
        for ft in pairs(pp.palletSpawner.fillTypeToSpawnPlaces) do add(ft) end
    end
    local function scan(list)
        if type(list) ~= "table" then return end
        for _, prod in ipairs(list) do
            for _, o in ipairs(prod.outputs or {}) do
                if isPalletizedFillType(o.type) then add(o.type) end
            end
        end
    end
    scan(pp.productions)         -- all defined lines (covers paused/inactive lines with leftover pallets)
    scan(pp.activeProductions)   -- and currently running lines
    return out
end

-- the fill types a pallet-spawner asset emits (husbandry: array of indices; beehive: just HONEY)
local function palletSpawnerFillTypes(p)
    if p == nil then return nil end
    local hs = p.spec_husbandryPallets
    if hs ~= nil and type(hs.fillTypes) == "table" then return hs.fillTypes end
    local bs = p.spec_beehivePalletSpawner
    if bs ~= nil and bs.fillType ~= nil then return { bs.fillType } end
    -- a production point with a pallet spawner: the palletized fill types it outputs
    local pp = getProductionPoint(p)
    if pp ~= nil and pp.palletSpawner ~= nil then
        local out = productionPalletFillTypes(pp)
        if #out > 0 then return out end
    end
    return nil
end

-- The OUTPUT fill types a husbandry building actually produces. Milk types are
-- read from spec_husbandryMilk.fillTypes, so normal / buffalo / goat (and any
-- modded) milk are ALL covered automatically; liquid manure from its own spec;
-- plus the named manure family. Per-building, not one fixed global list.
-- Does this husbandry actually PRODUCE manure / slurry? Slurry barns have spec_husbandryLiquidManure; straw
-- / bedding barns convert bedding to a manure-family output (spec_husbandryStraw / husbandryBeddingMulti
-- with a MANURE/LIQUIDMANURE/SLURRY outputFillType). A plain egg coop (base chickenHusbandryPasture) has
-- none of these -- it produces only eggs, so it must NOT be listed as a manure source or given a manure
-- slot. A modded coop that DOES declare straw->manure (e.g. Nordkirchen chickenManure) still qualifies.
function SmartDistribution.husbandryProducesManure(p)
    if p == nil then return false end
    if p.spec_husbandryLiquidManure ~= nil then return true end
    local mset = outputNamedSet()
    local ss = p.spec_husbandryStraw
    if ss ~= nil and ss.outputFillType ~= nil and mset[ss.outputFillType] then return true end
    local bm = p.spec_husbandryBeddingMulti
    if bm ~= nil and bm.outputFillType ~= nil and mset[bm.outputFillType] then return true end
    return false
end

local function husbandryOutputFillTypes(p)
    local out = {}
    -- A PASTURE produces nothing: no milk, no manure, no slurry. It is a grazing area, not a barn, so it
    -- must never appear as a source of any output and must never be offered manure/slurry routing.
    if SmartDistribution.isGrazingPasture(p) then return out end
    if p.spec_husbandryMilk ~= nil and p.spec_husbandryMilk.fillTypes ~= nil then
        for _, ft in ipairs(p.spec_husbandryMilk.fillTypes) do out[ft] = true end
    end
    if p.spec_husbandryLiquidManure ~= nil and p.spec_husbandryLiquidManure.fillType ~= nil then
        out[p.spec_husbandryLiquidManure.fillType] = true
    end
    -- The manure family (MANURE / LIQUIDMANURE / SLURRY) is NOT universal: a chicken coop produces eggs and
    -- nothing else. Only list it for barns that ACTUALLY produce manure (straw/bedding or slurry) -- a plain
    -- egg coop that DR happened to give a manure patch must not show manure as an output.
    if SmartDistribution.husbandryProducesManure(p) then
        for ft in pairs(outputNamedSet()) do
            local supported = false
            if p.getHusbandryIsFillTypeSupported ~= nil then
                local ok, r = pcall(p.getHusbandryIsFillTypeSupported, p, ft)
                supported = ok and r == true
            end
            if not supported and SmartDistribution.assetHoldsFillType ~= nil then
                supported = SmartDistribution.assetHoldsFillType(p, ft)
            end
            if supported then out[ft] = true end
        end
    end
    return out
end

local function isHusbandryOutput(p, ft)
    return husbandryOutputFillTypes(p)[ft] == true
end

-- raw (non-production) storages on a placeable that can hold ft
-- A standalone manure heap (PlaceableManureHeap, no spec_husbandry) -- the "Manure Pit".  Its
-- spec_manureHeap.manureHeap IS a full Storage (getFillLevel / getCapacity / getFreeCapacity /
-- getIsFillTypeSupported / setFillLevel, fillTypeIndex == MANURE -- confirmed via sdManureProbe), so
-- it drives through the generic storage helpers like any silo, as its OWN asset.  The barn's own 50k
-- manure patch is a separate storage and is left untouched.  The Pit and the manure-heap EXTENSION both
-- carry isExtension="true"; the extension is the one shipped with needsBarn="true".  We strip that flag
-- at load (installManureExtensionPlaceable) so it can be placed anywhere -- like the slurry extension --
-- and mark it spec_manureHeap.sdManureExt so it stays out of the Pit class and folds into a nearby Pit.
local function isManurePit(p)
    return p ~= nil and p.spec_manureHeap ~= nil and p.spec_husbandry == nil
           and p.spec_manureHeap.sdManureExt ~= true
end
-- A "Manure Heap Extension" (shipped needsBarn=true, re-flagged sdManureExt at load): no asset of its
-- own.  detachManureHeap keeps it off any barn; its storage folds into the nearest owned Pit (map below).
local function isManureHeapExtension(p)
    return p ~= nil and p.spec_manureHeap ~= nil and p.spec_manureHeap.sdManureExt == true
end
local function manureHeapStorage(p)
    local mh = p ~= nil and p.spec_manureHeap or nil
    return mh ~= nil and mh.manureHeap or nil    -- the ManureHeap object itself is the Storage
end

-- Manure-heap extensions can't pool through the engine (a heap has no extendable unloading station of
-- its own), so we map each extension's Storage to the nearest owned Pit ourselves, by proximity, and
-- fold it in for distribution exactly like a silo extension.  Rebuilt on load + on heap placement
-- (alongside detachManureHeap).  No Pit in range -> the extension maps to nothing and is inert.
local MANURE_EXT_ATTACH_RADIUS = 50    -- metres: an extension pools into the nearest owned Pit in range
local MANURE_EXT_BY_PIT = {}
local function rebuildManureExtensionMap()
    MANURE_EXT_BY_PIT = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    local pits = {}
    for _, p in ipairs(ps.placeables) do
        if p.rootNode ~= nil and isManurePit(p) then
            local x, _, z = getWorldTranslation(p.rootNode)
            pits[#pits + 1] = { p = p, x = x, z = z }
        end
    end
    if #pits == 0 then return end
    local r2 = MANURE_EXT_ATTACH_RADIUS * MANURE_EXT_ATTACH_RADIUS
    for _, p in ipairs(ps.placeables) do
        if p.rootNode ~= nil and isManureHeapExtension(p) then
            local hs = manureHeapStorage(p)
            if hs ~= nil then
                local ex, _, ez = getWorldTranslation(p.rootNode)
                local best, bestd2 = nil, nil
                for _, pit in ipairs(pits) do
                    local dx, dz = pit.x - ex, pit.z - ez
                    local d2 = dx * dx + dz * dz
                    if d2 <= r2 and (bestd2 == nil or d2 < bestd2) then best, bestd2 = pit.p, d2 end
                end
                if best ~= nil then
                    local set = MANURE_EXT_BY_PIT[best]
                    if set == nil then set = {}; MANURE_EXT_BY_PIT[best] = set end
                    set[hs] = true
                end
            end
        end
    end
end
local function parentPitExtensionStorages(p)
    local out = {}
    local set = p ~= nil and MANURE_EXT_BY_PIT[p] or nil
    if set ~= nil then for s in pairs(set) do out[#out + 1] = s end end
    return out
end

-- is there a Manure Pit within attach range of (x,z)? used by the manure-extension placement gate.
local function manurePitInRange(x, z)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil or type(x) ~= "number" or type(z) ~= "number" then return false end
    local r2 = MANURE_EXT_ATTACH_RADIUS * MANURE_EXT_ATTACH_RADIUS
    for _, p in ipairs(ps.placeables) do
        if p.rootNode ~= nil and isManurePit(p) then
            local px, _, pz = getWorldTranslation(p.rootNode)
            local dx, dz = px - x, pz - z
            if dx * dx + dz * dz <= r2 then return true end
        end
    end
    return false
end

-- a slurry tank extension (siloExtension whose storage holds LIQUIDMANURE) -- used only to reword its
-- placement warning from "barn" to "Slurry Pit".  Grain extensions keep the generic "next to a silo".
local function isSlurryExtension(p)
    local se = p ~= nil and p.spec_siloExtension or nil
    if se == nil then return false end
    local slurry = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName("LIQUIDMANURE") or nil
    if slurry == nil then return false end
    local function has(s) return s ~= nil and s.fillTypes ~= nil and s.fillTypes[slurry] == true end
    if has(se.storage) then return true end
    if se.storages ~= nil then for _, s in ipairs(se.storages) do if has(s) then return true end end end
    return false
end

-- A silo CAPACITY EXTENSION (PlaceableSiloExtension, type="siloExtension") has no I/O of its own: the
-- engine registers its Storage into a nearby parent silo's station, which the extension block above now
-- permits ONLY for real storage silos (recording the storage into EXT_BY_PARENT).  An extension is
-- therefore never its own asset -- its capacity is folded into the parent silo via
-- parentExtensionStorages() everywhere we read spec_silo.storages.

local function getRawStorages(p, ft)
    local result = {}
    if isHusbandryBuilding(p) and not isHusbandryOutput(p, ft) then return result end
    local heapStore = manureHeapStorage(p)
    if heapStore ~= nil then result[#result + 1] = heapStore end
    for _, s in ipairs(parentPitExtensionStorages(p)) do result[#result + 1] = s end  -- folded manure-heap extensions
    if p.spec_silo ~= nil and p.spec_silo.storages ~= nil then
        for _, s in ipairs(p.spec_silo.storages) do result[#result+1] = s end
    end
    for _, s in ipairs(parentExtensionStorages(p)) do result[#result + 1] = s end   -- folded-in silo extensions
    if p.spec_husbandry ~= nil then
        local h = p.spec_husbandry
        if h.storage ~= nil then result[#result+1] = h.storage end
        if h.storages ~= nil then for _, s in ipairs(h.storages) do result[#result+1] = s end end
    end
    return result
end

-- all raw storages regardless of ft (used by the sell phase)
local function getAllStorages(p)
    local result = {}
    if p.spec_silo ~= nil and p.spec_silo.storages ~= nil then
        for _, s in ipairs(p.spec_silo.storages) do result[#result+1] = s end
    end
    for _, s in ipairs(parentExtensionStorages(p)) do result[#result + 1] = s end   -- folded-in silo extensions
    if p.spec_husbandry ~= nil then
        local h = p.spec_husbandry
        if h.storage ~= nil then result[#result+1] = h.storage end
        if h.storages ~= nil then for _, s in ipairs(h.storages) do result[#result+1] = s end end
    end
    local heapStore = manureHeapStorage(p)
    if heapStore ~= nil then result[#result + 1] = heapStore end
    for _, s in ipairs(parentPitExtensionStorages(p)) do result[#result + 1] = s end  -- folded manure-heap extensions
    return result
end

local function storageFillTypes(storage)
    if storage ~= nil and storage.fillLevels ~= nil then return storage.fillLevels end
    return {}
end

-- Can this placeable actually hold ft in one of its own storages? Used to trim the blanket manure-family
-- output set down to what an asset really carries (a Manure Pit holds MANURE, a Slurry Pit LIQUIDMANURE).
function SmartDistribution.assetHoldsFillType(p, ft)
    if p == nil or ft == nil then return false end
    for _, s in ipairs(getAllStorages(p)) do
        if storageFillTypes(s)[ft] ~= nil then return true end
    end
    -- object-storage sheds (pallet shed / hay loft) don't expose their contents through getAllStorages;
    -- their supported/stored fill types come from the shed helpers instead. Without this a shed is never
    -- seen as holding anything, so Store To wouldn't treat it as a valid target or source.
    if p.spec_objectStorage ~= nil then
        if SmartDistribution.shedSupportedFillTypes ~= nil and SmartDistribution.shedSupportedFillTypes(p)[ft] then return true end
        if SmartDistribution.shedStoredFillTypes ~= nil and SmartDistribution.shedStoredFillTypes(p)[ft] then return true end
    end
    return false
end

-- a "slurry pit": a storage silo whose tank holds LIQUIDMANURE (and isn't a barn or a production).
-- Grouped with the manure pit under the HEAP class so the Animal Husbandry setting governs both.
local function isLiquidManureSilo(p)
    if p == nil or p.spec_silo == nil then return false end
    if p.spec_husbandry ~= nil or getProductionPoint(p) ~= nil then return false end
    local idx = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName("LIQUIDMANURE") or nil
    if idx == nil or type(p.spec_silo.storages) ~= "table" then return false end
    for _, s in ipairs(p.spec_silo.storages) do
        if s.fillTypes ~= nil and s.fillTypes[idx] == true then return true end
    end
    return false
end

-- ---- owned markets / kiosks (sell points) ----------------------------------
-- The "Transfer to My Market" target: a selling-station placeable this farm owns with real price
-- dynamics (priceDropPerLiter set; fixed-price production-input buyers -- piano/biomass -- have it
-- nil), not a train stop and not a production. Routed product waits in a mod-side buffer
-- (MARKET_CAP litres per fill type) and is sold through the station's native price + degradation,
-- with a +20% bonus credited on top. All fields (not locals) -- the file is at Lua's 200-local cap.
SmartDistribution.MARKET_CAP = 200000
-- per-market storage cap (litres, per fill type) = 2x the market's placement price.
-- Falls back to the flat MARKET_CAP when the store price can't be read.
function SmartDistribution.marketCap(market)
    local si = market ~= nil and market.storeItem or nil
    if si ~= nil and type(si.price) == "number" and si.price > 0 then return si.price * 2 end
    return SmartDistribution.MARKET_CAP
end
function SmartDistribution.marketStationOf(p)
    local spec = p ~= nil and p.spec_sellingStation or nil
    return spec ~= nil and (spec.sellingStation or spec.station) or nil
end
-- Only genuine market / kiosk sell points count -- not stone, pallet, bale, or other specialised sell
-- points that also have live pricing. Matched on the placeable's config file + display name; add hints
-- to MARKET_NAME_HINTS to admit more market types later.
SmartDistribution.MARKET_NAME_HINTS = { "market", "kiosk" }
function SmartDistribution.isMarketKind(p)
    if p == nil then return false end
    local id = tostring(p.configFileName or p.xmlFilename or "")
    if p.getName ~= nil then
        local ok, n = pcall(p.getName, p); if ok and type(n) == "string" then id = id .. " " .. n end
    end
    id = id:lower()
    for _, hint in ipairs(SmartDistribution.MARKET_NAME_HINTS) do
        if id:find(hint, 1, true) then return true end
    end
    return false
end
function SmartDistribution.isMarket(p)
    if p == nil or p.spec_sellingStation == nil then return false end
    if getProductionPoint(p) ~= nil then return false end
    local st = SmartDistribution.marketStationOf(p)
    if type(st) ~= "table" or st.isTrainStation == true or st.priceDropPerLiter == nil then return false end
    local owner = (p.getOwnerFarmId ~= nil) and p:getOwnerFarmId() or nil
    if owner == nil or owner == 0 then return false end
    return SmartDistribution.isMarketKind(p)   -- only real market / kiosk sell points, not stone / pallet / etc.
end
function SmartDistribution.marketAccepts(p, ft)
    local st = SmartDistribution.marketStationOf(p)
    if st == nil then return false end
    if type(st.getIsFillTypeSupported) == "function" then
        local ok, r = pcall(function() return st:getIsFillTypeSupported(ft) end)
        if ok then return r == true end
    end
    if type(st.acceptedFillTypes) == "table" then return st.acceptedFillTypes[ft] == true end
    return false
end
-- mod-side virtual buffer + per-market sell timing (persisted + synced).
SmartDistribution._marketBuffer = {}   -- uid -> ft -> litres (<= MARKET_CAP)
SmartDistribution._marketTiming = {}   -- uid -> ft -> sell mode: 1 = best price, 2 = hold (0/immediate omitted)
SmartDistribution._marketPriceHigh = {}   -- uid -> ft -> highest effective price seen (session; best-price target)
function SmartDistribution.marketBufferLevel(uid, ft)
    local b = uid ~= nil and SmartDistribution._marketBuffer[uid] or nil
    return (b ~= nil and b[ft]) or 0
end
function SmartDistribution.marketBufferAdd(uid, ft, delta)
    if uid == nil or ft == nil or delta == nil then return end
    local b = SmartDistribution._marketBuffer[uid]; if b == nil then b = {}; SmartDistribution._marketBuffer[uid] = b end
    local v = math.max(0, (b[ft] or 0) + delta)
    b[ft] = (v > 0) and v or nil
end
-- per-market sell mode: 0 = sell immediately, 1 = wait for the seasonal peak, 2 = hold (never sell)
SmartDistribution.MARKET_IMMEDIATE = 0
SmartDistribution.MARKET_BEST      = 1
SmartDistribution.MARKET_HOLD      = 2
function SmartDistribution.marketSellMode(uid, ft)
    local b = uid ~= nil and SmartDistribution._marketTiming[uid] or nil
    return (b ~= nil and b[ft]) or 0
end
function SmartDistribution.setMarketSellMode(uid, ft, mode)
    if uid == nil or ft == nil then return end
    local b = SmartDistribution._marketTiming[uid]
    if mode ~= nil and mode ~= 0 then
        if b == nil then b = {}; SmartDistribution._marketTiming[uid] = b end
        b[ft] = mode
    elseif b ~= nil then
        b[ft] = nil
        if next(b) == nil then SmartDistribution._marketTiming[uid] = nil end
    end
end

-- ---- asset classification / identity / settings resolution -----------------
local function getAssetClass(p)
    if getProductionPoint(p) ~= nil then return "PRODUCTION" end
    if SmartDistribution.isMarket(p) then return "MARKET" end   -- owned sell point / kiosk
    if isManurePit(p) then return "HEAP" end              -- manure pit (standalone manure heap)
    if isLiquidManureSilo(p) then return "HEAP" end       -- slurry pit (liquid-manure silo) -- rides with husbandry
    if p.spec_silo ~= nil then return "SILO" end
    if isHusbandryBuilding(p) then return "HUSBANDRY" end
    -- a beehive honey spawner is a pallet-output asset like a coop, so it shares the HUSBANDRY class
    -- bucket (mode/reach/store-capable/enrolled) while isHusbandryBuilding() stays false so the
    -- husbandry-specific phases (feed / milk / manure) correctly skip it.
    if isBeehiveSpawner(p) then return "HUSBANDRY" end
    if p.spec_objectStorage ~= nil then return "SHED" end
    return "OTHER"
end

-- which classes vanilla itself would distribute from (for VANILLA_ONLY)
local VANILLA_ELIGIBLE = { PRODUCTION = true, SILO = true, HUSBANDRY = false, OTHER = false }

local function getUid(p)
    if p == nil then return nil end
    if p.uniqueId ~= nil then return p.uniqueId end          -- stable across save/load (verified in placeables.xml)
    if p.getUniqueId ~= nil then
        local ok, u = pcall(p.getUniqueId, p)
        if ok and u ~= nil then return u end
    end
    return "node:" .. tostring(p.rootNode)                   -- transient fallback (no persistence yet)
end

-- ---- per-cycle accounting (for the asset dialog's last-cycle columns) -------
-- cycleAcc tallies THIS hour's real moves; SmartDistribution.runHourly publishes
-- it to S.lastCycle at the end of the pass. Keyed uid -> ft -> {dist,sold,stored}.
-- Host-side only (clients don't run the pass). Real moves only (skips dry-run).
local cycleAcc = nil
-- rolling N-cycle "monthly" window of the SAME per-(uid,ft) deltas, published from runHourly
-- alongside S.lastCycle. SmartDistribution.monthlyStats / monthlyReceived sum the window for the
-- UI's /mo columns; persisted across save/load (see save/loadOverrides). A month is 24 hourly cycles.
local MONTHLY_CYCLES = 24
local monthlyRing = {}    -- [1..MONTHLY_CYCLES] = one completed cycle's snapshot (uid -> ft -> {dist,sold,stored,received})
local monthlyPos  = 0     -- next slot to overwrite (0-based; wraps at MONTHLY_CYCLES)
-- MULTIPLAYER: the hourly pass (and so the ring above) runs only on the server, leaving clients
-- with no /mo data. Each hour the server pushes the rolling aggregate via DistributionStatsEvent
-- and clients keep it here; monthlyStats / monthlyReceived read this on a client instead of summing
-- the (empty) ring. Stays nil on the server / in single-player, so those keep using the ring.
local clientMonthly = nil   -- client-only: uid -> ft -> {dist,sold,stored,received}
local function ledgerAdd(placeable, ft, field, amount)
    if cycleAcc == nil or placeable == nil or ft == nil or amount == nil or amount <= 0 then return end
    local uid = getUid(placeable)
    if uid == nil then return end
    local a = cycleAcc[uid]; if a == nil then a = {}; cycleAcc[uid] = a end
    local e = a[ft];        if e == nil then e = { dist = 0, sold = 0, stored = 0, received = 0 }; a[ft] = e end
    e[field] = (e[field] or 0) + amount
end

local function classField(classKey, field)
    local c = S.classes[classKey]
    if c ~= nil and c[field] ~= nil and c[field] ~= 0 then return c[field] end   -- 0 == INHERIT
    return nil
end

local function isEnrolled(p)
    if not S.master then return false end
    local part = S.global.participation
    if part == PART.NONE then return false end
    if part == PART.VANILLA_ONLY then return VANILLA_ELIGIBLE[getAssetClass(p)] == true end
    -- per-class network toggles (Settings: Animal Husbandry / Silos & Pallet Storage). Manure +
    -- slurry pits (HEAP) are storage, so they ride with Silos & Pallet Storage now (they used to ride
    -- with Animal Husbandry).
    local cls = getAssetClass(p)
    if cls == "HUSBANDRY" and not S.global.includeHusbandry then return false end
    if (cls == "SILO" or cls == "SHED" or cls == "HEAP") and not S.global.includeSilosSheds then return false end
    if cls == "MARKET" and not S.global.includeMarkets then return false end
    return true   -- ALL
end

local function resolveReach(p)
    return classField(getAssetClass(p), "reach") or S.global.reach
end

local function resolveMode(p, ft)
    local uid = getUid(p)
    local a = uid ~= nil and S.assets[uid] or nil
    if a ~= nil and a[ft] ~= nil and a[ft] ~= MODE.INHERIT then return a[ft] end
    return classField(getAssetClass(p), "mode") or S.global.mode
end

-- public per-asset override API (for the future config dialog) ----------------
function SmartDistribution.setAssetMode(uid, ft, mode)
    if uid == nil or ft == nil then return end
    S.assets[uid] = S.assets[uid] or {}
    S.assets[uid][ft] = mode
end
function SmartDistribution.getAssetMode(uid, ft)
    local a = S.assets[uid]
    return a ~= nil and a[ft] or MODE.INHERIT
end

-- Set a per-asset override AND sync it in multiplayer. This is the seam the
-- console and (later) the per-silo dialog call. On the receiving side of the
-- sync event, run() calls this with noEventSend = true so it doesn't echo back.
function SmartDistribution.applyAssetMode(placeable, ft, mode, noEventSend)
    if placeable == nil or ft == nil then return end
    SmartDistribution.setAssetMode(getUid(placeable), ft, mode)
    SmartDistribution._seedMoveToBlocks(placeable, ft, mode)   -- Move To starts all-blocked (loop-safe)
    if not noEventSend and DistributionModeEvent ~= nil and DistributionModeEvent.sendEvent ~= nil then
        DistributionModeEvent.sendEvent(placeable, ft, mode)
    end
end

-- Move To (and Distribute + Move To) is the ONE mode whose destinations default to BLOCKED, so a store
-- never auto-cascades into another store until the player deliberately activates a target (loop-safe).
-- We express that in the unified model by blocking every candidate store the moment the output enters a
-- Move To mode -- but only when the player has not already configured this output (no existing blocks or
-- priority for it), so re-entering the mode doesn't wipe their choices. Server-authoritative; the block
-- edits persist + replay to clients like any other.
function SmartDistribution._seedMoveToBlocks(placeable, ft, mode)
    if mode ~= MODE.STORE_TO and mode ~= MODE.DISTRIBUTE_STORE_TO then return end
    if placeable == nil or placeable.rootNode == nil then return end
    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil and not g_currentMission:getIsServer() then return end
    local srcUid = getUid(placeable)
    if srcUid == nil then return end
    -- already configured? leave it alone
    local C = SmartDistribution.control
    if (C.blocked[srcUid] ~= nil and C.blocked[srcUid][ft] ~= nil)
       or (C.priority[srcUid] ~= nil and C.priority[srcUid][ft] ~= nil) then return end
    local form = SmartDistribution.sourceHoldForm(placeable, ft)
    if form == nil then
        if placeable.spec_objectStorage ~= nil then form = "PALLET" else form = "BULK" end
    end
    local myFarm = SmartDistribution._ownerFarmId(placeable)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    for _, tp in ipairs(ps ~= nil and ps.placeables or {}) do
        if tp ~= placeable and tp.rootNode ~= nil and isEnrolled(tp)
           and SmartDistribution._ownerFarmId(tp) == myFarm
           and SmartDistribution.storeToTargetValid(form, tp, ft) then
            local du = getUid(tp)
            if du ~= nil then SmartDistribution.setDestBlocked(srcUid, ft, du, true) end
        end
    end
end

-- Replay every RAW per-asset override as (placeable, ft, mode).  Used by the multiplayer join
-- sync: the server resends each override to a connecting client so its display + behaviour match
-- the host.  Resolves each stored uniqueId back to its live placeable (clients re-resolve locally).
function SmartDistribution.forEachAssetOverride(cb)
    if cb == nil then return end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    local byUid = {}
    for _, p in ipairs(ps.placeables) do
        if p.rootNode ~= nil then byUid[getUid(p)] = p end
    end
    for uid, byFt in pairs(S.assets) do
        local p = byUid[uid]
        if p ~= nil then
            for ft, mode in pairs(byFt) do
                if mode ~= nil and mode ~= MODE.INHERIT then cb(p, ft, mode) end
            end
        end
    end
end

-- ---- per-asset sell-timing override (best price vs sell immediately) --------
-- Orthogonal to mode; only meaningful when the resolved mode is SELL or
-- DISTRIBUTE_SELL. Stored value: true = best price, false = immediate, nil =
-- follow the global default (S.global.bestPriceDefault).
function SmartDistribution.setAssetSellTiming(uid, ft, value)
    if uid == nil or ft == nil then return end
    S.sellTiming[uid] = S.sellTiming[uid] or {}
    S.sellTiming[uid][ft] = value
end
function SmartDistribution.getAssetSellTiming(uid, ft)
    local a = S.sellTiming[uid]
    if a == nil then return nil end
    return a[ft]
end

-- Resolve whether THIS output is configured to hold for the best price (config
-- only -- the calendar "is it the peak month" check happens at sell time).
-- master on -> mode sells -> explicit per-output value, else the global default.
function SmartDistribution.resolveBestPrice(placeable, ft, mode)
    if not S.global.bestPriceEnabled then return false end
    if mode ~= MODE.SELL and mode ~= MODE.DISTRIBUTE_SELL then return false end
    local uid = getUid(placeable)
    local v = nil
    if uid ~= nil then v = SmartDistribution.getAssetSellTiming(uid, ft) end   -- may be false (explicit immediate); don't collapse with and/or
    if v ~= nil then return v end
    return S.global.bestPriceDefault and true or false
end

-- set + multiplayer sync (mirror of applyAssetMode)
function SmartDistribution.applyAssetSellTiming(placeable, ft, value, noEventSend)
    if placeable == nil or ft == nil then return end
    SmartDistribution.setAssetSellTiming(getUid(placeable), ft, value)
    if not noEventSend and DistributionSellTimingEvent ~= nil and DistributionSellTimingEvent.sendEvent ~= nil then
        DistributionSellTimingEvent.sendEvent(placeable, ft, value)
    end
end

-- replay every explicit sell-timing override (multiplayer join sync)
function SmartDistribution.forEachAssetSellTiming(cb)
    if cb == nil then return end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    local byUid = {}
    for _, p in ipairs(ps.placeables) do
        if p.rootNode ~= nil then byUid[getUid(p)] = p end
    end
    for uid, byFt in pairs(S.sellTiming) do
        local p = byUid[uid]
        if p ~= nil then
            for ft, value in pairs(byFt) do
                if value ~= nil then cb(p, ft, value) end
            end
        end
    end
end

-- UI helper: nil when (placeable, ft) is not a sell output; otherwise "Best price"
-- or "Immediate", reflecting the resolved best-price timing. `mode` optional.
function SmartDistribution.sellTimingLabel(placeable, ft, mode)
    mode = mode or resolveMode(placeable, ft)
    if mode ~= MODE.SELL and mode ~= MODE.DISTRIBUTE_SELL then return nil end
    return SmartDistribution.resolveBestPrice(placeable, ft, mode) and "Best price" or "Immediate"
end

-- UI helper: flip a sell output between best-price and immediate (writes an explicit
-- per-output value, MP-synced). Returns false if it isn't a sell output.
function SmartDistribution.toggleSellTiming(placeable, ft)
    local mode = resolveMode(placeable, ft)
    if mode ~= MODE.SELL and mode ~= MODE.DISTRIBUTE_SELL then return false end
    local cur = SmartDistribution.resolveBestPrice(placeable, ft, mode)
    SmartDistribution.applyAssetSellTiming(placeable, ft, not cur)
    return true
end

-- the EFFECTIVE mode for (placeable, ft) after L4 -> L3 -> L2 resolution
function SmartDistribution.resolvedAssetMode(placeable, ft)
    return resolveMode(placeable, ft)
end

-- fill-type HUD icon file (the same overlay the input/output lists use), for the no-store-image fallback.
local function fillHudIconFile(ft)
    if ft == nil or g_fillTypeManager == nil or g_fillTypeManager.getFillTypeByIndex == nil then return nil end
    local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
    if ok and type(def) == "table" then
        local f = def.hudOverlayFilename or def.hudOverlayFilenameSmall
        if type(f) == "string" and f ~= "" then return f end
    end
    return nil
end

-- A representative fill type for a building that has no store image -- used so preplaced productions
-- whose base-game storeData ships an EMPTY <image> (e.g. the map biogas plant) still show something:
-- the primary product (else the first output) of the building's first production line.
local function placeablePrimaryProduct(p)
    local pp = getProductionPoint(p)
    if pp == nil then return nil end
    for _, list in ipairs({ pp.productions, pp.activeProductions }) do
        if type(list) == "table" then
            for _, prod in ipairs(list) do
                if prod.primaryProductFillType ~= nil then return prod.primaryProductFillType end
                for _, o in ipairs(prod.outputs or {}) do
                    if o.type ~= nil then return o.type end
                end
            end
        end
    end
    return nil
end

-- Set the "assetIcon" cell of a building-list row to that placeable's store image ("default game
-- picture"). When the building has no store image (some preplaced buildings ship an empty <image>,
-- e.g. the biogas plant), fall back to its primary product's icon so the row is never blank; only if
-- that also fails is the icon hidden. The store item is resolved via g_storeManager keyed by the
-- placeable's config XML (with a direct storeItem shortcut). UI-only and fully guarded.
function SmartDistribution.setAssetIcon(cell, placeable)
    if cell == nil or cell.getAttribute == nil then return end
    local iconCell = cell:getAttribute("assetIcon")
    if iconCell == nil then return end
    local file = nil
    if placeable ~= nil then
        local si = placeable.storeItem
        if type(si) ~= "table" and g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil then
            local cfg = placeable.configFileName or placeable.xmlFilename
            if cfg ~= nil then
                local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, cfg)
                if ok then si = item end
            end
        end
        if type(si) == "table" then
            local img = si.imageFilename or si.imageFilenameSmall
            if type(img) == "string" and img ~= "" then file = img end
        end
        if file == nil then file = fillHudIconFile(placeablePrimaryProduct(placeable)) end   -- no store image: primary-product fallback
    end
    if file ~= nil and iconCell.setImageFilename ~= nil then
        iconCell:setImageFilename(file)
        if iconCell.setVisible ~= nil then iconCell:setVisible(true) end
    elseif iconCell.setVisible ~= nil then
        iconCell:setVisible(false)
    end
end

-- a source may hand out ft only if enrolled, not excluded, and mode distributes
local function canSourceDistribute(p, ft)
    if SmartDistribution.isMarket(p) then return false end   -- a market's buffer is sell-only; it can never feed the network back
    if not isEnrolled(p) then return false end
    if S.global.excludedFillTypes[ft] then return false end
    local m = resolveMode(p, ft)
    return m == MODE.DISTRIBUTE or m == MODE.DISTRIBUTE_SELL or m == MODE.DISTRIBUTE_STORE or m == MODE.DISTRIBUTE_MARKET
        or m == MODE.DISTRIBUTE_STORE_TO
end

-- ---- demand (only ACTIVE / player-enabled productions count) ---------------
local function getActiveProductionDefs(pp)
    local defs = {}
    local active = pp.activeProductions
    if active == nil then return defs end
    for _, ap in ipairs(active) do
        local def = ap
        if def.inputs == nil then
            if def.id ~= nil and pp.productionsIdToObj ~= nil then
                def = pp.productionsIdToObj[def.id] or def
            elseif def.index ~= nil and pp.productions ~= nil then
                def = pp.productions[def.index] or def
            end
        end
        defs[#defs + 1] = def
    end
    return defs
end

local function getActiveHourlyConsumption(pp, ft)
    local total = 0
    for _, production in ipairs(getActiveProductionDefs(pp)) do
        local passThrough = false
        for _, o in ipairs(production.outputs or {}) do
            if o.type == ft then passThrough = true break end
        end
        if not passThrough then
            local cph = production.cyclesPerHour or 0
            for _, input in ipairs(production.inputs or {}) do
                if input.type == ft then total = total + (input.amount or 0) * cph end
            end
        end
    end
    return total
end

local function hasActivePassThrough(pp, ft)
    for _, production in ipairs(getActiveProductionDefs(pp)) do
        local isIn, isOut = false, false
        for _, i in ipairs(production.inputs or {}) do if i.type == ft then isIn = true end end
        for _, o in ipairs(production.outputs or {}) do if o.type == ft then isOut = true end end
        if isIn and isOut then return true end
    end
    return false
end

local function getPullAmount(pp, ft)
    if S.global.excludedFillTypes[ft] then return 0 end
    local current = getLevel(pp.storage, ft)
    local hourly = getActiveHourlyConsumption(pp, ft)
    if hourly > 0 then
        local target = hourly * S.global.bufferHours
        return math.max(0, math.min(target - current, getFree(pp.storage, ft)))
    end
    if hasActivePassThrough(pp, ft) then
        return getFree(pp.storage, ft)
    end
    return 0
end

-- ---- transfer --------------------------------------------------------------
local function transfer(farmId, src, dst, ft, amount)
    local available = getLevel(src, ft)
    if available <= 0 or amount <= 0 then return 0 end
    local moved = math.min(amount, available, getFree(dst, ft))
    if moved <= 0 then return 0 end
    if SmartDistribution.dryRun then
        log("[dry-run] would move %d %s", moved, fillTypeName(ft))
        return moved
    end
    setLevel(src, ft, available - moved, farmId, -moved)
    setLevel(dst, ft, getLevel(dst, ft) + moved, farmId, moved)
    return moved
end

-- pallet-spawner read/drain primitives + source proxy are defined further down (next to the
-- pallet phase); forward-declared here so the gatherSources pallet branch can reference them.
local palletFillLevel, drainPallets, makePalletSourceProxy
local shedStoredLiters, drainShedStored, makeShedSourceProxy

-- ---- source gathering (enrolment + reach + mode gated) ---------------------
-- ---- ambient water supply --------------------------------------------------
-- Items that consume WATER (productions with a WATER input; animal pastures that need water)
-- are topped up from an effectively infinite ambient supply, billed by distance to the NEAREST
-- water source using the normal distribution charge. A "water source" is the nearest of:
--   * a placeable that holds/produces water (a water tank/silo, pump/well, or water-output production), or
--   * open water (river/lake/ocean), located with a downward CollisionFlag.WATER raycast -- the
--     same test the engine uses to let a trailer fill from water. Open-water geography is static,
--     so the per-item result is cached for the session.
local _waterFt = nil
local function waterFillType()
    if _waterFt == nil then
        _waterFt = (g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName("WATER")) or false
    end
    return _waterFt or nil
end

-- infinite ambient-water "storage": always full, debits ignored
local WATER_SOURCE_PROXY = {
    getFillLevel = function(_, ft) return 1e12 end,
    setFillLevel = function(_, level, ft) end,
}
-- stand-in source placeable for open water / fallback (billing + ledger only)
local AMBIENT_WATER_PLACEABLE = { uniqueId = "sd_ambient_water", getName = function() return "Water source" end }

-- open-water search tuning
local OPEN_WATER_MAX  = 225      -- metres: how far out to look for open water
local OPEN_WATER_STEP = 15       -- metres: ring spacing
local OPEN_WATER_DIRS = 12       -- samples per ring

-- is there open water at (sx,sz)? returns the water surface Y, or nil. Cast straight down with
-- CollisionFlag.WATER from above the local terrain (rivers sit in carved terrain, so start high).
local function openWaterY(sx, sz)
    if RaycastUtil == nil or RaycastUtil.raycastClosest == nil or CollisionFlag == nil
       or CollisionFlag.WATER == nil or g_terrainNode == nil then return nil end
    local th = getTerrainHeightAtWorldPos(g_terrainNode, sx, 0, sz)
    local objectId, _, hitY = RaycastUtil.raycastClosest(sx, th + 50, sz, 0, -1, 0, 120, CollisionFlag.WATER)
    if objectId ~= nil and objectId ~= 0 then return hitY end
    return nil
end

-- nearest open water to (x,z): ring-sampled distance^2, or nil if none within OPEN_WATER_MAX.
-- Cached per position for the session (water bodies don't move).
local _openWaterCache = {}
local function nearestOpenWaterDist2(x, z)
    local key = string.format("%.0f:%.0f", x, z)
    local cached = _openWaterCache[key]
    if cached ~= nil then return cached or nil end
    local best = nil
    if openWaterY(x, z) ~= nil then
        best = 0
    else
        local r = OPEN_WATER_STEP
        while r <= OPEN_WATER_MAX and best == nil do
            for i = 0, OPEN_WATER_DIRS - 1 do
                local a = (i / OPEN_WATER_DIRS) * 2 * math.pi
                if openWaterY(x + math.cos(a) * r, z + math.sin(a) * r) ~= nil then best = r * r; break end
            end
            r = r + OPEN_WATER_STEP
        end
    end
    _openWaterCache[key] = best or false
    return best
end

-- litres of WATER a placeable currently holds (tank/silo storages + a production's own storage)
local function placeableWaterLevel(p)
    local w = waterFillType()
    if w == nil then return 0 end
    local total = 0
    for _, s in ipairs(getRawStorages(p, w)) do total = total + getLevel(s, w) end
    local pp = getProductionPoint(p)
    if pp ~= nil and pp.storage ~= nil then total = total + getLevel(pp.storage, w) end
    return total
end

-- water-providing placeables, cached per cycle (token = the per-cycle cycleAcc table)
local _waterSrc, _waterSrcToken = nil, nil
local function waterSourcePlaceables()
    if _waterSrcToken ~= cycleAcc or _waterSrc == nil then
        _waterSrc = {}
        local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
        if ps ~= nil and waterFillType() ~= nil then
            for _, p in ipairs(ps.placeables) do
                if p.rootNode ~= nil and placeableWaterLevel(p) > 0 then
                    local px, _, pz = getWorldTranslation(p.rootNode)
                    _waterSrc[#_waterSrc + 1] = { p = p, x = px, z = pz }
                end
            end
        end
        _waterSrcToken = cycleAcc
    end
    return _waterSrc
end

-- nearest water source to (x,z): min(water placeable, open water). Returns (placeable, d2);
-- falls back to ambient @ d2=0 when nothing is found.
local function nearestWaterSource(x, z)
    local best, bestd2 = nil, nil
    for _, s in ipairs(waterSourcePlaceables()) do
        local dx, dz = s.x - x, s.z - z
        local d2 = dx * dx + dz * dz
        if bestd2 == nil or d2 < bestd2 then best, bestd2 = s.p, d2 end
    end
    local owd2 = nearestOpenWaterDist2(x, z)
    if owd2 ~= nil and (bestd2 == nil or owd2 < bestd2) then best, bestd2 = AMBIENT_WATER_PLACEABLE, owd2 end
    if best == nil then return AMBIENT_WATER_PLACEABLE, 0 end
    return best, bestd2
end

local function gatherSources(consumerPP, consumerPlaceable, ft, x, z, farmId)
    local sources = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return sources end
    local r2 = S.global.radius * S.global.radius
    for _, p in ipairs(ps.placeables) do
        if p ~= consumerPlaceable and p.rootNode ~= nil and canSourceDistribute(p, ft) then
            local pFarm = p.ownerFarmId
            if pFarm == nil or farmId == nil or pFarm == farmId then
                local px, _, pz = getWorldTranslation(p.rootNode)
                local dx, dz = px - x, pz - z
                local d2 = dx*dx + dz*dz
                if resolveReach(p) == REACH.FARM_WIDE or d2 <= r2 then
                    -- (a) production OUTPUT this placeable distributes. The mode gate is the outer
                    -- canSourceDistribute(p, ft) (resolved mod mode, incl. the global Distribute
                    -- default); here we only require ft to be a genuine OUTPUT of this production
                    -- (never an input it is stocking) with something on hand. This makes an output on
                    -- the global default usable as a source, and also lets Distribute+Store outputs feed
                    -- consumers -- both previously excluded because their engine auto-deliver flag is off.
                    local pp2 = getProductionPoint(p)
                    if pp2 ~= nil and pp2 ~= consumerPP and pp2.storage ~= nil and
                       pp2.outputFillTypeIds ~= nil and pp2.outputFillTypeIds[ft] and
                       getLevel(pp2.storage, ft) > 0 then
                        sources[#sources+1] = { storage = pp2.storage, d2 = d2, placeable = p }
                    end
                    -- (b) raw silo / husbandry / manure storages holding ft
                    for _, s in ipairs(getRawStorages(p, ft)) do
                        if getLevel(s, ft) > 0 then
                            sources[#sources+1] = { storage = s, d2 = d2, placeable = p }
                        end
                    end
                    -- (c) pallet-spawner assets (coops / sheep / beehives) distributing ft: pull the
                    -- physical egg/wool/honey pallets via a thin proxy so transfer + billing are unchanged
                    if isPalletSpawnerAsset(p) and palletFillLevel(p, ft) > 0 then
                        sources[#sources+1] = { storage = makePalletSourceProxy(p), d2 = d2, placeable = p }
                    end
                    -- (d) pallet storage sheds (object storage) holding ft: pull the stored
                    -- pallet liters via a thin proxy (same transfer + billing path)
                    if p.spec_objectStorage ~= nil and shedStoredLiters(p, ft) > 0 then
                        sources[#sources+1] = { storage = makeShedSourceProxy(p), d2 = d2, placeable = p }
                    end
                end
            end
        end
    end
    -- (e) ambient WATER supply: an effectively infinite source at the nearest water source
    -- (water-providing placeable OR open water), so items that consume water are topped up and
    -- billed by haul distance just like any other source.
    if S.global.waterSupplyEnabled then
        local w = waterFillType()
        if w ~= nil and ft == w then
            local srcP, d2 = nearestWaterSource(x, z)
            sources[#sources + 1] = { storage = WATER_SOURCE_PROXY, d2 = d2, placeable = srcP }
        end
    end
    -- Production Redux input control: drop any source the player has blocked from feeding
    -- this consumer this fill type. No-op (and skipped entirely) when no blocks are set,
    -- so standalone Distribution Redux behaviour is unchanged.
    if next(SmartDistribution.control.blocked) ~= nil and consumerPlaceable ~= nil then
        local cu = getUid(consumerPlaceable)
        local kept = {}
        for _, s in ipairs(sources) do
            if s.placeable == nil or not SmartDistribution.isDestBlocked(getUid(s.placeable), ft, cu) then   -- source-side block
                kept[#kept + 1] = s
            end
        end
        sources = kept
    end
    table.sort(sources, function(a, b) return a.d2 < b.d2 end)   -- nearest first
    return sources
end

-- ---- distance-based distribution billing -----------------------------------
-- Each unique (source -> consumer) link that moved material this hour is one
-- billable haul. Cost per link/hour = base * max(1, dist/threshold): flat base at
-- or under the threshold, scaling linearly beyond (base 10, threshold 50 ->
-- 50m=$10, 500m=$100). Distance is the SAME rootNode<->rootNode value gatherSources
-- used for the reach test, carried on each source as d2. HOLD assets never
-- distribute, so they never appear here and are free. Charged per farm via addMoney.
local function billLinkKey(farmId, src, dst)
    return tostring(farmId) .. "|" .. tostring(getUid(src)) .. "|" .. tostring(getUid(dst))
end

local function recordBill(bill, farmId, src, dst, d2)
    if bill == nil or src == nil or dst == nil then return end
    local k = billLinkKey(farmId, src, dst)
    if bill[k] == nil then bill[k] = { farmId = farmId, d2 = d2 or 0 } end   -- distance is fixed per link
end

-- ---- fast-forward / sleep detection -----------------------------------------
-- The engine fires the hourly tick many times per second during sleep.  If each addMoney call popped
-- the on-screen +/-$ and cash sound, the distribution cost AND every hourly sale would "beep" once per
-- accelerated hour.  applyMoney() (below) instead applies each change immediately but SILENTLY
-- (forceShowChange=false) while the game is fast-forwarding, so the balance still tracks the sleep with
-- no per-hour notification and no jarring wake-time lump.  Fast-forward is flagged in onHourChanged
-- from the real-time gap between hourly ticks.
local FAST_FORWARD_GAP_SEC = 4.0    -- hourly ticks closer than this (real seconds) == sleep (enter fast-forward);
                                    -- 2x this is the hysteresis exit gap (stay asleep through brief stalls)

-- single money chokepoint.  During fast-forward (sleep) the money is STILL applied each accelerated
-- hour, so the balance tracks the sleep correctly -- but with forceShowChange=false so the engine does
-- not pop a +$ notification / cash sound for every hour (the same silent convention vanilla uses for
-- upkeep).  Normal time shows the change as usual.  No batching => no jarring wake-time lump.
-- ---- per-cycle money summary ----------------------------------------------
-- Every mod money change (product sales, biogas, distribution cost) is applied
-- SILENTLY (forceShowChange=false) and tallied here by category. flushCycleSummary()
-- then emits ONE side-notification per cycle with the combined net + breakdown,
-- instead of one +/-$ popup per individual sale. The money still lands immediately
-- in the correct finances category (addChange=true), so the budget screen stays exact.
local cycleMoney = nil   -- { sales, biogas, cost, any, ff } while a cycle is open; nil between cycles

local function resetCycleMoney()
    cycleMoney = { sales = 0, biogas = 0, cost = 0, any = false, ff = SmartDistribution._fastForward == true }
end

local function tallyMoney(delta, mt)
    if cycleMoney == nil then resetCycleMoney() end
    local PM = (MoneyType ~= nil) and MoneyType.PROPERTY_MAINTENANCE or nil
    local BG = (MoneyType ~= nil) and MoneyType.INCOME_BGA or nil
    if PM ~= nil and mt == PM then
        cycleMoney.cost = cycleMoney.cost + delta            -- costs arrive as negative deltas
    elseif BG ~= nil and mt == BG then
        cycleMoney.biogas = cycleMoney.biogas + delta        -- biogas plant grid income (electricity / methane)
    else
        cycleMoney.sales = cycleMoney.sales + delta          -- all other product sales
    end
    cycleMoney.any = true
    SmartDistribution._lastTallySec = (getTimeSec ~= nil) and getTimeSec() or SmartDistribution._lastTallySec
end

-- single money chokepoint. Money is applied immediately every (accelerated) hour so the
-- balance always tracks play -- but SILENTLY; the once-per-cycle summary is the only popup.
local function applyMoney(delta, farmId, mt)
    if delta == nil or delta == 0 or farmId == nil then return end
    if g_currentMission ~= nil and g_currentMission.addMoney ~= nil then
        g_currentMission:addMoney(delta, farmId, mt, true, false)   -- addChange=true (books stay exact), forceShowChange=false (no per-sale popup)
        tallyMoney(delta, mt)
    end
end
SmartDistribution._applyMoney = applyMoney   -- exposed for harness + ProductionDistributeSell biogas surplus

local function fmtMoney(v)
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, s = pcall(function() return g_i18n:formatMoney(v, 0, true, false) end)
        if ok and type(s) == "string" then return s end
    end
    return string.format("%s%d", v < 0 and "-" or "", math.floor(math.abs(v) + 0.5))
end
SmartDistribution.formatMoney = fmtMoney
-- compact money for tight table cells: -$1.2M / $12.3k / $980, locale currency symbol if available
function SmartDistribution.formatMoneyShort(v)
    v = v or 0
    local a = math.abs(v)
    local num
    if a >= 1e6 then num = string.format("%.1fM", a / 1e6)
    elseif a >= 1e3 then num = string.format("%.1fk", a / 1e3)
    else num = string.format("%d", math.floor(a + 0.5)) end
    local sym = "$"
    if g_i18n ~= nil and g_i18n.getCurrencySymbol ~= nil then
        local ok, s = pcall(function() return g_i18n:getCurrencySymbol(true) end)
        if ok and type(s) == "string" and s ~= "" then sym = s end
    end
    return (v < 0 and "-" or "") .. sym .. num
end

-- Emit one combined notification for the cycle just completed, then clear the tally.
-- Called at the START of the next cycle so a removable add-on's late biogas-surplus
-- sale (ProductionDistributeSell, which runs after this pass) is already counted.
-- Emit one combined notification (per non-zero category) for an accumulated tally; the caller clears it.
-- Shared by the normal-cycle flush and the wake-up flush.
SmartDistribution.COST_NOTIFY_COLOUR = { 1.0, 0.5, 0.0, 1.0 }   -- orange, for the distribution-cost side notification

function SmartDistribution.emitSummary(acc)
    if acc == nil then return end
    if acc.biogas ~= 0 then SmartDistribution.notify("Biogas income: "     .. fmtMoney(acc.biogas)) end
    if acc.sales  ~= 0 then SmartDistribution.notify("Product sales: "     .. fmtMoney(acc.sales))  end
    if acc.cost   ~= 0 then SmartDistribution.notify("Distribution costs: -" .. fmtMoney(math.abs(acc.cost)), SmartDistribution.COST_NOTIFY_COLOUR) end
    if DistributionMoneyNotifyEvent ~= nil and DistributionMoneyNotifyEvent.broadcast ~= nil then
        DistributionMoneyNotifyEvent.broadcast(acc.biogas, acc.sales, acc.cost)   -- MP: mirror the summary to clients
    end
end

function SmartDistribution.flushCycleSummary()
    local cm = cycleMoney
    cycleMoney = nil
    if cm == nil or not cm.any then return end
    -- fold this cycle's tallies into the running summary. No emit here: the settled emit in
    -- flushPendingSummary() (update frame) fires once the hour's money has stopped arriving, so the
    -- deferred distribution cost AND the PDS production / biogas pass all land in ONE notification
    -- (they otherwise flush a frame -- and thus an hour -- apart).
    local acc = SmartDistribution._summaryAccum
    if acc == nil then acc = { sales = 0, biogas = 0, cost = 0 }; SmartDistribution._summaryAccum = acc end
    acc.sales  = acc.sales  + cm.sales
    acc.biogas = acc.biogas + cm.biogas
    acc.cost   = acc.cost   + cm.cost
end

-- emit the combined summary this many real seconds after the last money tally: long enough that an
-- hour's tick-time and deferred-frame tallies (and rapid sleep hours) coalesce, short enough to feel prompt.
SmartDistribution.SUMMARY_SETTLE_SEC = 2.0
-- Emit the accumulated summary once the money for the current hour (or the whole sleep) has SETTLED --
-- i.e. no new tally has arrived for SUMMARY_SETTLE_SEC real seconds. During normal play this fires a
-- couple seconds after each hour; during sleep the rapid tallies keep resetting it, so it fires just
-- once, right on waking. Called every update frame.
function SmartDistribution.flushPendingSummary()
    local acc = SmartDistribution._summaryAccum
    if acc == nil then return end
    local now  = (getTimeSec ~= nil) and getTimeSec() or nil
    local last = SmartDistribution._lastTallySec
    if now == nil or last == nil or (now - last) < (SmartDistribution.SUMMARY_SETTLE_SEC or 2.0) then return end
    SmartDistribution._summaryAccum = nil
    SmartDistribution.emitSummary(acc)
end

local function chargeDistribution(bill)
    if not S.global.distCostEnabled or bill == nil then return end
    local base = S.global.distCostBase or 0
    if base <= 0 then return end
    local threshold = S.global.distCostThreshold or 50
    if threshold <= 0 then threshold = 50 end
    local perFarm = {}   -- [farmId] = { cost = n, links = n }
    for _, link in pairs(bill) do
        local dist = math.sqrt(link.d2 or 0)
        local factor = dist / threshold
        if factor < 1 then factor = 1 end           -- proximity (<=threshold) billed flat at base
        local pf = perFarm[link.farmId] or { cost = 0, links = 0 }
        pf.cost  = pf.cost + base * factor
        pf.links = pf.links + 1
        perFarm[link.farmId] = pf
    end
    local mt = MoneyType ~= nil and (MoneyType.PROPERTY_MAINTENANCE or MoneyType.OTHER) or nil
    for farmId, pf in pairs(perFarm) do
        if farmId ~= nil and pf.cost > 0 then
            if SmartDistribution.dryRun then
                log("[dry-run] would charge farm %s $%.2f distribution cost (%d link(s))",
                    tostring(farmId), pf.cost, pf.links)
            else
                applyMoney(-pf.cost, farmId, mt)   -- batched across sleep, settled at wake
                log("charged farm %s $%.2f distribution cost (%d link(s))", tostring(farmId), pf.cost, pf.links)
            end
        end
    end
end
SmartDistribution._chargeDistribution = chargeDistribution   -- exposed for harness

-- ============================================================================
-- UNIFIED DEMAND ALLOCATOR  (phases 1 + 1b + 1c)
-- Every hourly consumer becomes a "slot": it wants `need` liters and accepts one
-- or more fill types, each candidate source tagged with quality (food
-- productionWeight; flat 1.0 for productions/straw) and distance. All slots are
-- resolved together so that:
--   * a slot always pulls its BEST candidate first  (quality DESC, then nearest)
--   * when one source is wanted by several slots and is short, that source's
--     stock is split PROPORTIONALLY to the claimants' remaining demand
-- For a lone consumer this reduces to "drain nearest-first up to need", i.e. the
-- pre-allocator behaviour whenever supply >= demand.
-- ============================================================================
local ALLOC_EPS = 0.5   -- liters: <= this counts as empty; keeps contested splits whole-liter (no dust hauls)

-- quality (productionWeight) per food fill type, from the animal food system.
-- Mixtures (TMR) are the complete ration -> treat as best. Fully guarded: any
-- missing field returns nil and the caller falls back to flat quality.
local function foodQualityMap(p)
    local m = g_currentMission
    local afs = m ~= nil and m.animalFoodSystem or nil
    if afs == nil or afs.getAnimalFood == nil then return nil end
    local fs = p.spec_husbandryFood
    local ati = fs ~= nil and fs.animalTypeIndex or nil
    if ati == nil and p.getAnimalTypeIndex ~= nil then
        local okA, a = pcall(p.getAnimalTypeIndex, p); if okA then ati = a end
    end
    if ati == nil then return nil end
    local map = {}
    local okF, food = pcall(afs.getAnimalFood, afs, ati)
    if okF and food ~= nil and food.groups ~= nil then
        for _, grp in pairs(food.groups) do
            local w = grp.productionWeight or 0
            for _, ft in pairs(grp.fillTypes or {}) do map[ft] = w end
        end
    end
    if afs.getMixturesByAnimalTypeIndex ~= nil then
        local okM, mix = pcall(afs.getMixturesByAnimalTypeIndex, afs, ati)
        if okM and mix ~= nil then
            for _, ft in ipairs(mix) do map[ft] = math.max(map[ft] or 0, 1.0) end
        end
    end
    if next(map) == nil then return nil end
    return map
end
SmartDistribution._foodQualityMap = foodQualityMap   -- exposed for harness

-- whole-liter proportional split of `stock` across `needs` (largest remainder).
-- A lone claimant gets an EXACT min(need, stock) so single-consumer behaviour is
-- byte-identical to the old drain; only true contention uses the integer split.
local function proportionalSplit(stock, needs)
    local n = #needs
    local out = {}
    if n == 0 then return out end
    if n == 1 then out[1] = math.min(needs[1], stock); return out end
    local total = 0
    for i = 1, n do total = total + needs[i] end
    if total <= 0 or stock <= 0 then for i = 1, n do out[i] = 0 end return out end
    if stock >= total then for i = 1, n do out[i] = needs[i] end return out end   -- not short: full need
    local used, frac = 0, {}
    for i = 1, n do
        local raw = stock * needs[i] / total
        out[i] = math.floor(raw)
        frac[i] = { i = i, f = raw - out[i] }
        used = used + out[i]
    end
    local rem = math.floor(stock) - used
    if rem > 0 then
        table.sort(frac, function(a, b) if a.f ~= b.f then return a.f > b.f end return a.i < b.i end)
        for k = 1, rem do out[frac[k].i] = out[frac[k].i] + 1 end
    end
    return out
end
SmartDistribution._proportionalSplit = proportionalSplit   -- exposed for harness

-- candidate edges for a slot: every (source, ft) the consumer accepts, sorted by
-- quality DESC then distance ASC. `qmap` (ft->weight) only for husbandry food.
local function buildSlotCandidates(consumerPP, placeable, fts, x, z, farmId, qmap)
    local out = {}
    for _, ft in ipairs(fts) do
        local q = (qmap ~= nil and qmap[ft]) or 1.0
        for _, s in ipairs(gatherSources(consumerPP, placeable, ft, x, z, farmId)) do
            out[#out + 1] = { placeable = s.placeable, storage = s.storage, ft = ft, d2 = s.d2, q = q,
                              key = tostring(s.storage) .. "#" .. tostring(ft) }
        end
    end
    table.sort(out, function(a, b)
        if a.q ~= b.q then return a.q > b.q end       -- best feed quality first
        if a.d2 ~= b.d2 then return a.d2 < b.d2 end    -- then nearest
        return a.key < b.key                            -- stable tie-break
    end)
    return out
end

local function slotBestCandidate(slot)
    for i = 1, #slot.cands do
        local c = slot.cands[i]
        if not slot.blocked[i] and getLevel(c.storage, c.ft) > ALLOC_EPS then
            return c, i
        end
    end
    return nil, nil
end

-- move up to `give` liters from candidate c into the slot's consumer; debit the
-- source, decrement need, record one billable haul. Honours dry-run. Returns accepted.
local function slotMove(slot, c, give, bill)
    local stock = getLevel(c.storage, c.ft)
    local amount = math.min(give, slot.need, stock)
    if amount <= ALLOC_EPS then return 0 end
    local accepted = slot.deposit(c.ft, amount, SmartDistribution.dryRun) or 0
    if accepted <= ALLOC_EPS then return 0 end
    if SmartDistribution.dryRun then
        log("[dry-run] would move %.0f %s : %s -> %s", accepted, fillTypeName(c.ft),
            placeableName(c.placeable), placeableName(slot.placeable))
    else
        setLevel(c.storage, c.ft, stock - accepted, slot.farmId, -accepted)
        ledgerAdd(c.placeable, c.ft, "dist", accepted)            -- distributed-out, source side
        ledgerAdd(slot.placeable, c.ft, "received", accepted)     -- received-in, recipient side (productions inputs, troughs, ...)
        log("move %.0f %s : %s -> %s", accepted, fillTypeName(c.ft), placeableName(c.placeable), placeableName(slot.placeable))
        SmartDistribution.recordFeed(slot.placeable, c.ft, c.placeable, accepted)   -- link status: this source fed this consumer
    end
    slot.need = slot.need - accepted
    recordBill(bill, slot.farmId, c.placeable, slot.placeable, c.d2)
    return accepted
end

-- the rounds: each pass every hungry slot claims its best source; sources wanted
-- by several slots are split proportionally; drained sources / capped deposits
-- fall away. Terminates because every round either moves liters or retires a
-- candidate; the guard is a backstop only.
local function allocate(slots, bill)
    if slots == nil or #slots == 0 then return end
    local guard = 0
    while true do
        guard = guard + 1
        if guard > 100000 then log("allocate: round cap hit [VERIFY]"); break end

        local groups, order, any = {}, {}, false
        for _, slot in ipairs(slots) do
            if slot.need > ALLOC_EPS then
                local c, idx = slotBestCandidate(slot)
                if c ~= nil then
                    any = true
                    local g = groups[c.key]
                    if g == nil then
                        g = { ft = c.ft, storage = c.storage, claims = {} }
                        groups[c.key] = g; order[#order + 1] = c.key
                    end
                    g.claims[#g.claims + 1] = { slot = slot, c = c, idx = idx }
                end
            end
        end
        if not any then break end

        local progress = false
        for _, key in ipairs(order) do
            local g = groups[key]
            local stock = getLevel(g.storage, g.ft)
            if stock > ALLOC_EPS then
                -- Production Redux output priority: when this contested source has a priority
                -- order set for (source, ft), fill claimants strictly in rank order (rank 1 to
                -- need, then rank 2, ...). priorityOrder returns nil otherwise, so the original
                -- proportional split runs unchanged when no priority is set.
                local ord = nil
                if next(SmartDistribution.control.priority) ~= nil and #g.claims > 1 then
                    local srcUid = g.claims[1].c.placeable ~= nil and getUid(g.claims[1].c.placeable) or nil
                    if srcUid ~= nil then
                        ord = SmartDistribution.priorityOrder(srcUid, g.ft, g.claims,
                            function(cl) return cl.slot.placeable ~= nil and getUid(cl.slot.placeable) or nil end)
                    end
                end
                if ord ~= nil then
                    local remaining = stock
                    for _, cl in ipairs(ord) do
                        if remaining <= ALLOC_EPS then break end
                        local give = math.min(cl.slot.need, remaining)
                        if give > ALLOC_EPS then
                            local moved = slotMove(cl.slot, cl.c, give, bill)
                            if moved > ALLOC_EPS then progress = true; remaining = remaining - moved end
                            if moved + ALLOC_EPS < give then cl.slot.blocked[cl.idx] = true; progress = true end  -- deposit capped: retire
                        end
                    end
                else
                    local needs = {}
                    for i, cl in ipairs(g.claims) do needs[i] = cl.slot.need end
                    local share = proportionalSplit(stock, needs)
                    for i, cl in ipairs(g.claims) do
                        local give = share[i] or 0
                        if give > ALLOC_EPS then
                            local moved = slotMove(cl.slot, cl.c, give, bill)
                            if moved > ALLOC_EPS then progress = true end
                            if moved + ALLOC_EPS < give then cl.slot.blocked[cl.idx] = true; progress = true end  -- deposit capped: retire
                        end
                    end
                end
            end
        end
        if not progress then break end
    end
end

-- ---- slot collectors (build the work list for allocate) --------------------
-- phase 1: production inputs. Each input fill type is its own (non-substitutable) slot.
local function collectProductionSlots(points, slots)
    if points == nil then return end
    for _, pp in ipairs(points) do
        local placeable = pp.owningPlaceable
        if placeable ~= nil and placeable.rootNode ~= nil and
           pp.storage ~= nil and pp.inputFillTypeIds ~= nil then
            local x, _, z = getWorldTranslation(placeable.rootNode)
            local farmId  = pp.getOwnerFarmId ~= nil and pp:getOwnerFarmId() or placeable.ownerFarmId
            for ft in pairs(pp.inputFillTypeIds) do
                -- default = recipe pull; a fill target instead demands toward its set level and then holds it
                local need = SmartDistribution.effectiveInputNeed(placeable, ft, getPullAmount(pp, ft), getLevel(pp.storage, ft))
                if need > ALLOC_EPS then
                    local cands = buildSlotCandidates(pp, placeable, { ft }, x, z, farmId, nil)
                    if SmartDistribution.debug then
                        local parts = {}
                        for _, c in ipairs(cands) do
                            parts[#parts + 1] = string.format("%s@%.0fm=%.0fL", placeableName(c.placeable), math.sqrt(c.d2 or 0), getLevel(c.storage, c.ft))
                        end
                        log("input %s @ %s need %.0fL <- [%s]", fillTypeName(ft), placeableName(placeable), need, #parts > 0 and table.concat(parts, ", ") or "NO SOURCES")
                    end
                    if #cands > 0 then
                        slots[#slots + 1] = {
                            placeable = placeable, farmId = farmId, need = need, cands = cands, blocked = {},
                            deposit = function(dft, amount, dry)
                                local free = getFree(pp.storage, dft)
                                local room = SmartDistribution.inputAcceptableLiters(placeable, dft)   -- receiver-side block / max %
                                local mv = math.min(amount, free, room)
                                if mv <= 0 then return 0 end
                                if not dry then setLevel(pp.storage, dft, getLevel(pp.storage, dft) + mv, farmId, mv) end
                                return mv
                            end,
                        }
                    end
                end
            end
        end
    end
end

-- phase 1b: husbandry food trough. ONE slot, shared need, accepts every supported
-- food type (quality-ranked). Independent of the barn's own output mode.
local function collectFoodSlots(slots)
    if not S.global.feedHusbandryEnabled then return end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    for _, p in ipairs(ps.placeables) do
        local fs = p.spec_husbandryFood
        if fs ~= nil and p.rootNode ~= nil and p.addFood ~= nil and isEnrolled(p)
           and SmartDistribution.feedingRobotOf(p) == nil then   -- robot barns feed their bunkers, not the food pool
            local rate = SmartDistribution.husbandryInputRate(p, fs.litersPerHour, "food")
            if rate > 0 then
                local current = 0
                for _, lvl in pairs(fs.fillLevels) do current = current + lvl end
                local capacity = fs.capacity or 0
                local farmId = p.getOwnerFarmId ~= nil and p:getOwnerFarmId() or p.ownerFarmId
                local x, _, z = getWorldTranslation(p.rootNode)
                local qmap = foodQualityMap(p) or {}
                local rcvUid = getUid(p)
                local fts = {}
                for ft in pairs(fs.supportedFillTypes) do
                    -- skip water, excluded types, and any food the player has BLOCKED on Advanced Inputs
                    if not S.global.excludedFillTypes[ft] and ft ~= waterFillType()
                       and not (rcvUid ~= nil and SmartDistribution.isInputBlocked(rcvUid, ft)) then
                        fts[#fts + 1] = ft
                    end
                end
                -- shared-pool deposit: add `dft` up to the pool's live remaining room
                local function foodDeposit(dft, amount, dry)
                    local tot = 0
                    for _, l in pairs(fs.fillLevels) do tot = tot + l end
                    local mv = math.min(amount, capacity - tot)
                    if mv <= 0 then return 0 end
                    if dry then return mv end
                    return p:addFood(farmId, mv, dft, nil, nil, nil) or 0
                end
                -- Pool fill level to demand toward: the highest fill TARGET % set across the food types, applied
                -- to the FULL pool capacity (the pool is shared, so one setpoint governs it); else buffer-hours.
                local tgtPct = nil
                if SmartDistribution.advancedEnabled() then
                    local uid = getUid(p)
                    if uid ~= nil then
                        for _, ft in ipairs(fts) do
                            local up = SmartDistribution.getInputTargetPct(uid, ft)
                            if up ~= nil and (tgtPct == nil or up > tgtPct) then tgtPct = up end
                        end
                    end
                end
                local desired  = tgtPct ~= nil and (capacity * tgtPct / 100) or (rate * S.global.bufferHours)
                local poolNeed = math.min(desired - current, capacity - current)
                if poolNeed > ALLOC_EPS and #fts > 0 then
                    -- Fill BEST-QUALITY-FIRST to maximise animal health: fill the highest-quality food tier that
                    -- has stock, splitting proportionally among EQUAL-quality types (so a 3-grain chicken coop
                    -- mixes evenly, while a graded barn takes TMR first and only falls back to lower-quality
                    -- feed if the better one runs short). Higher tiers are sized first, so lower tiers only get
                    -- the remainder the better feed couldn't cover.
                    table.sort(fts, function(a, b) return (qmap[a] or 0) > (qmap[b] or 0) end)
                    local remaining, i = poolNeed, 1
                    while i <= #fts and remaining > ALLOC_EPS do
                        local q, tier = (qmap[fts[i]] or 0), {}
                        while i <= #fts and (qmap[fts[i]] or 0) == q do tier[#tier + 1] = fts[i]; i = i + 1 end
                        local tierInfo, tierStock = {}, 0
                        for _, ft in ipairs(tier) do
                            local cands, stock = buildSlotCandidates(nil, p, { ft }, x, z, farmId, qmap), 0
                            for _, c in ipairs(cands) do stock = stock + (getLevel(c.storage, c.ft) or 0) end
                            tierInfo[ft] = { cands = cands, stock = stock }
                            tierStock = tierStock + stock
                        end
                        if tierStock > ALLOC_EPS then
                            local tierFill = math.min(remaining, tierStock)
                            for _, ft in ipairs(tier) do
                                local ti = tierInfo[ft]
                                if #ti.cands > 0 and ti.stock > 0 then
                                    local share = tierFill * (ti.stock / tierStock)
                                    if share > ALLOC_EPS then
                                        slots[#slots + 1] = { placeable = p, farmId = farmId, need = share, cands = ti.cands, blocked = {}, deposit = foodDeposit }
                                    end
                                end
                            end
                            remaining = remaining - tierFill
                        end
                    end
                end
            end
        end
    end
end

-- ---- feeding-robot (Lely Vector / GEA) bunkers ----------------------------
-- A cowHusbandryBarnMilkFeedingRobot mixes feed from per-fill-type ingredient BUNKERS (unloadingSpots on
-- spec_husbandryFeedingRobot.feedingRobot) instead of a single "food" pool. The FeedingRobot object exposes
-- getFillLevel / getFreeCapacity / getIsFillTypeAllowed / addFillLevelFromTool keyed by fill type, plus
-- fillTypeToUnloadingSpot[ft] -> the bunker. Read + write validated via sdRobotProbe / sdRobotFill.
-- (SmartDistribution.* fields, not top-level locals, to respect the 200-local main-chunk ceiling.)
function SmartDistribution.feedingRobotOf(p)
    local spec = p ~= nil and p.spec_husbandryFeedingRobot or nil
    return spec ~= nil and spec.feedingRobot or nil
end
function SmartDistribution.robotBunkerFillTypes(p)
    local out = {}
    local fr = SmartDistribution.feedingRobotOf(p)
    if fr ~= nil and type(fr.fillTypeToUnloadingSpot) == "table" then
        for ft, spot in pairs(fr.fillTypeToUnloadingSpot) do
            if type(ft) == "number" and spot ~= nil then out[ft] = true end
        end
    end
    return out
end
function SmartDistribution.robotBunkerCapacity(p, ft)
    local fr = SmartDistribution.feedingRobotOf(p)
    local spot = (fr ~= nil and type(fr.fillTypeToUnloadingSpot) == "table") and fr.fillTypeToUnloadingSpot[ft] or nil
    return spot ~= nil and (spot.capacity or 0) or 0
end
function SmartDistribution.robotBunkerLevel(p, ft)
    local fr = SmartDistribution.feedingRobotOf(p)
    if fr == nil then return 0 end
    if fr.getFillLevel ~= nil then local ok, v = pcall(fr.getFillLevel, fr, ft); if ok and type(v) == "number" then return v end end
    local spot = type(fr.fillTypeToUnloadingSpot) == "table" and fr.fillTypeToUnloadingSpot[ft] or nil
    return spot ~= nil and (spot.fillLevel or 0) or 0
end
function SmartDistribution.robotBunkerFree(p, ft)
    local fr = SmartDistribution.feedingRobotOf(p)
    if fr == nil then return 0 end
    if fr.getFreeCapacity ~= nil then local ok, v = pcall(fr.getFreeCapacity, fr, ft); if ok and type(v) == "number" then return v end end
    return math.max(0, SmartDistribution.robotBunkerCapacity(p, ft) - SmartDistribution.robotBunkerLevel(p, ft))
end
function SmartDistribution.robotBunkerAdd(p, ft, liters, farmId)
    local fr = SmartDistribution.feedingRobotOf(p)
    if fr == nil or fr.addFillLevelFromTool == nil or (liters or 0) <= 0 then return 0 end
    local ok, added = pcall(fr.addFillLevelFromTool, fr, farmId, liters, ft, nil, nil, nil)
    return (ok and type(added) == "number") and added or 0
end

-- The mixer recipe's ingredient list (spec.feedingRobot.robot.recipe.ingredients): each entry has a
-- fillTypes table + a ratio (fraction of the mixed feed made from that ingredient). nil if unreadable.
function SmartDistribution.robotRecipeIngredients(p)
    local fr = SmartDistribution.feedingRobotOf(p)
    local robot = fr ~= nil and fr.robot or nil
    local rec = robot ~= nil and robot.recipe or nil
    return (type(rec) == "table" and type(rec.ingredients) == "table") and rec.ingredients or nil
end

-- Default LEVEL (litres) DR keeps in the bunker for `ft`: the animals' food need over the buffer window
-- (foodRate x bufferHours) times THIS ingredient's recipe ratio -- so DR only tops each bunker to what the
-- herd actually needs, not to capacity. Returns nil when the recipe or food rate can't be read (caller then
-- falls back to keep-full), and 0 when the barn has no food demand (empty / no animals).
function SmartDistribution.robotBunkerDefaultLevel(p, ft)
    local ings = SmartDistribution.robotRecipeIngredients(p)
    if ings == nil then return nil end
    local fs = p.spec_husbandryFood
    local rate = fs ~= nil and SmartDistribution.husbandryInputRate(p, fs.litersPerHour, "food") or 0
    if rate <= 0 then return 0 end
    local ratio = nil
    for _, ing in ipairs(ings) do
        if type(ing.fillTypes) == "table" then
            for _, ift in pairs(ing.fillTypes) do
                if ift == ft then ratio = ing.ratio; break end
            end
        end
        if ratio ~= nil then break end
    end
    if type(ratio) ~= "number" then return nil end          -- ft not in the recipe -> keep-full fallback
    return rate * S.global.bufferHours * ratio
end

-- phase 1b-robot: feeding-robot ingredient bunkers. One demand per bunker; DR delivers each ingredient to
-- its own spot (silage / hay / straw / mineral feed) and the robot mixes + feeds the herd automatically.
-- Default tops each bunker to just the herd's buffer-hours need for that ingredient (from the mixer recipe);
-- a per-input fill target (Advanced Inputs) overrides it.
SmartDistribution.collectRobotFeedSlots = function(slots)
    if not S.global.feedHusbandryEnabled then return end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    for _, p in ipairs(ps.placeables) do
        if SmartDistribution.feedingRobotOf(p) ~= nil and p.rootNode ~= nil and isEnrolled(p) then
            local farmId = p.getOwnerFarmId ~= nil and p:getOwnerFarmId() or p.ownerFarmId
            local x, _, z = getWorldTranslation(p.rootNode)
            local rcvUid = getUid(p)
            for ft in pairs(SmartDistribution.robotBunkerFillTypes(p)) do
                if not S.global.excludedFillTypes[ft]
                   and not (rcvUid ~= nil and SmartDistribution.isInputBlocked(rcvUid, ft)) then   -- respect Advanced-Inputs block
                    local cur  = SmartDistribution.robotBunkerLevel(p, ft)
                    local free = SmartDistribution.robotBunkerFree(p, ft)
                    -- default = buffer-hours of this ingredient per the mixer recipe (only what the herd needs);
                    -- falls back to keep-full if the recipe/rate is unreadable. A fill target overrides to its
                    -- set level.
                    local defLevel = SmartDistribution.robotBunkerDefaultLevel(p, ft)
                    local defNeed  = (defLevel ~= nil) and (defLevel - cur) or (SmartDistribution.robotBunkerCapacity(p, ft) - cur)
                    local base = SmartDistribution.effectiveInputNeed(p, ft, defNeed, cur)
                    local need = math.min(base, free)
                    if need > ALLOC_EPS then
                        local cands = buildSlotCandidates(nil, p, { ft }, x, z, farmId, nil)
                        if #cands > 0 then
                            slots[#slots + 1] = {
                                placeable = p, farmId = farmId, need = need, cands = cands, blocked = {},
                                deposit = function(dft, amount, dry)
                                    local fc = SmartDistribution.robotBunkerFree(p, dft)
                                    local mv = math.min(amount, fc)
                                    if mv <= 0 then return 0 end
                                    if dry then return mv end
                                    return SmartDistribution.robotBunkerAdd(p, dft, mv, farmId)
                                end,
                            }
                        end
                    end
                end
            end
        end
    end
end

-- phase 1c: straw bedding (single STRAW type, main husbandry storage).
local function collectStrawSlots(slots)
    if not S.global.feedHusbandryEnabled or not S.global.feedStrawEnabled then return end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    local STRAW = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName("STRAW") or nil
    if STRAW == nil or S.global.excludedFillTypes[STRAW] then return end
    for _, p in ipairs(ps.placeables) do
        local ss = p.spec_husbandryStraw
        if ss ~= nil and p.rootNode ~= nil and p.addHusbandryFillLevelFromTool ~= nil and
           p.getHusbandryIsFillTypeSupported ~= nil and p:getHusbandryIsFillTypeSupported(STRAW) and isEnrolled(p)
           and not (getUid(p) ~= nil and SmartDistribution.isInputBlocked(getUid(p), STRAW)) then   -- respect Advanced-Inputs block
            -- pastures DO take straw (as in the base pasture mod); manure is prevented at the sink side:
            -- they get no manure storage slot and never link to a heap/pit, so the conversion has nowhere
            -- to go and is discarded exactly as it is without DR.
            local rate    = SmartDistribution.husbandryInputRate(p, ss.inputLitersPerHour, "straw")
            local current = p:getHusbandryFillLevel(STRAW) or 0
            local free    = p:getHusbandryFreeCapacity(STRAW) or 0
            -- Straw-bedding barns that publish no per-hour straw rate AND whose animal subtype has no
            -- "straw" input curve (e.g. the modded Nordkirchen chicken coop, which bolts a <straw> block
            -- onto a chicken husbandry) resolve to rate 0 -- yet they genuinely accept straw as bedding.
            -- Fall back to topping their straw storage up to free capacity, exactly as a player would by
            -- hand, so they still register as a demand slot. When a real rate IS known (cows/pigs/horses,
            -- via the spec or the animal curve) keep the normal buffer-hours cap.
            local defNeed = (rate > 0) and (rate * S.global.bufferHours - current) or free
            -- fill target (bedding straw): demand toward the set level instead. Skipped on robot barns,
            -- where STRAW is a robot feed bunker fed separately (its target lives on that bunker).
            if SmartDistribution.feedingRobotOf(p) == nil then
                defNeed = SmartDistribution.effectiveInputNeed(p, STRAW, defNeed, current)
            end
            local need    = math.min(defNeed, free)
            if need > ALLOC_EPS then
                local farmId = p.getOwnerFarmId ~= nil and p:getOwnerFarmId() or p.ownerFarmId
                local x, _, z = getWorldTranslation(p.rootNode)
                local cands = buildSlotCandidates(nil, p, { STRAW }, x, z, farmId, nil)
                if #cands > 0 then
                    slots[#slots + 1] = {
                        placeable = p, farmId = farmId, need = need, cands = cands, blocked = {},
                        deposit = function(dft, amount, dry)
                            local fr = p:getHusbandryFreeCapacity(STRAW) or 0
                            local mv = math.min(amount, fr)
                            if mv <= 0 then return 0 end
                            if dry then return mv end
                            return p:addHusbandryFillLevelFromTool(farmId, mv, STRAW, nil, nil, nil) or 0
                        end,
                    }
                end
            end
        end
    end
end

-- phase 1c-water: animal pastures that need water (spec_husbandryWater, automaticWaterSupply off).
-- One WATER slot per pasture, filled from the ambient water source (gatherSources branch (e)),
-- billed by distance to the nearest water source. Mirrors the straw slot.
local function collectHusbandryWaterSlots(slots)
    if not S.global.waterSupplyEnabled then return end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    local WATER = waterFillType()
    if WATER == nil or S.global.excludedFillTypes[WATER] then return end
    for _, p in ipairs(ps.placeables) do
        local ws = p.spec_husbandryWater
        if ws ~= nil and not ws.automaticWaterSupply and p.rootNode ~= nil and
           p.addHusbandryFillLevelFromTool ~= nil and p.getHusbandryIsFillTypeSupported ~= nil and
           p:getHusbandryIsFillTypeSupported(WATER) and isEnrolled(p)
           and not (getUid(p) ~= nil and SmartDistribution.isInputBlocked(getUid(p), WATER)) then   -- respect Advanced-Inputs block
            local rate = SmartDistribution.husbandryInputRate(p, ws.litersPerHour, "water")
            if rate > 0 then
                local current = p:getHusbandryFillLevel(WATER) or 0
                local free    = p:getHusbandryFreeCapacity(WATER) or 0
                -- fill target: demand toward the set level instead of the buffer-hours default
                local need    = math.min(SmartDistribution.effectiveInputNeed(p, WATER, rate * S.global.bufferHours - current, current), free)
                if need > ALLOC_EPS then
                    local farmId = p.getOwnerFarmId ~= nil and p:getOwnerFarmId() or p.ownerFarmId
                    local x, _, z = getWorldTranslation(p.rootNode)
                    local cands = buildSlotCandidates(nil, p, { WATER }, x, z, farmId, nil)
                    if #cands > 0 then
                        slots[#slots + 1] = {
                            placeable = p, farmId = farmId, need = need, cands = cands, blocked = {},
                            deposit = function(dft, amount, dry)
                                local fr = p:getHusbandryFreeCapacity(WATER) or 0
                                local mv = math.min(amount, fr)
                                if mv <= 0 then return 0 end
                                if dry then return mv end
                                return p:addHusbandryFillLevelFromTool(farmId, mv, WATER, nil, nil, nil) or 0
                            end,
                        }
                    end
                end
            end
        end
    end
end

-- ---- phase 1d: store remainders offsite ------------------------------------
-- The mirror of Distribute+Sell, but to storage instead of selling. A producer
-- output set to DISTRIBUTE_STORE is first available to consumers (canSourceDistribute
-- includes it, so the pull phases run normally); whatever is LEFT this hour is pushed
-- into storage buildings in range. Destination = nearest owned storage (silo/storage
-- hall, or a standalone manure pit) that SUPPORTS the fill type and has spare capacity;
-- fill each to full nearest-first until the product is moved or all sinks are full.
-- Billed by distance like every other haul. Storages themselves never get this mode
-- (no offsite option in the UI) and storePhase only treats producers as sources, so
-- there is no silo->silo cascade.
local function storageSupports(storage, ft)
    if storage == nil then return false end
    if storage.fillTypes ~= nil and storage.fillTypes[ft] ~= nil then return true end
    if storage.getIsFillTypeSupported ~= nil then
        local ok, r = pcall(storage.getIsFillTypeSupported, storage, ft)
        if ok and r then return true end
    end
    if storage.capacities ~= nil and storage.capacities[ft] ~= nil then return true end
    if storage.fillLevels ~= nil and storage.fillLevels[ft] ~= nil then return true end
    return false
end

-- storages on p that can RECEIVE ft (dedicated storage only: silos / storage halls,
-- and standalone manure pits -- never a barn or a production point)
local function getSinkStorages(p, ft)
    local result = {}
    local isSilo = p.spec_silo ~= nil
    local pit = isManurePit(p)
    if not (isSilo or pit) then return result end
    local stores = {}
    if isSilo and p.spec_silo.storages ~= nil then
        for _, s in ipairs(p.spec_silo.storages) do stores[#stores+1] = s end
    end
    if isSilo then
        for _, s in ipairs(parentExtensionStorages(p)) do stores[#stores+1] = s end
    end
    if pit then
        local hs = manureHeapStorage(p)
        if hs ~= nil then stores[#stores+1] = hs end
        for _, s in ipairs(parentPitExtensionStorages(p)) do stores[#stores+1] = s end
    end
    for _, s in ipairs(stores) do
        if storageSupports(s, ft) and getFree(s, ft) > 0 then result[#result+1] = s end
    end
    return result
end

local function gatherSinks(sourcePlaceable, ft, x, z, farmId, srcReach)
    local sinks = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return sinks end
    local r2 = S.global.radius * S.global.radius
    for _, p in ipairs(ps.placeables) do
        if p ~= sourcePlaceable and p.rootNode ~= nil then
            local pFarm = p.ownerFarmId
            if pFarm == nil or farmId == nil or pFarm == farmId then
                local px, _, pz = getWorldTranslation(p.rootNode)
                local dx, dz = px - x, pz - z
                local d2 = dx*dx + dz*dz
                if srcReach == REACH.FARM_WIDE or d2 <= r2 then
                    for _, s in ipairs(getSinkStorages(p, ft)) do
                        sinks[#sinks+1] = { storage = s, d2 = d2, placeable = p }
                    end
                end
            end
        end
    end
    table.sort(sinks, function(a, b) return a.d2 < b.d2 end)   -- nearest first
    return sinks
end

-- A Pallet Storage Shed (object storage) is a sink for pallet fill types: it holds whole pallet
-- OBJECTS (capacity is an object count), not bulk liters.  Eligible when it supports pallets +
-- the fill type and has a free object slot.
local function isPalletShedSink(p, ft)
    local spec = p.spec_objectStorage
    if spec == nil or spec.supportsPallets == false then return false end
    if p.getObjectStorageSupportsFillType ~= nil and not p:getObjectStorageSupportsFillType(ft) then return false end
    local cap = spec.capacity or 0
    local stored = (spec.storedObjects ~= nil and #spec.storedObjects) or (spec.numStoredObjects or 0)
    return cap <= 0 or stored < cap
end

-- gather pallet-shed sinks (object storages) within reach; entries carry `.shed` instead of
-- `.storage`, so the pallet store path moves whole pallets into them rather than draining liters.
local function gatherShedSinks(sourcePlaceable, ft, x, z, farmId, srcReach)
    local sinks = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return sinks end
    local r2 = S.global.radius * S.global.radius
    for _, p in ipairs(ps.placeables) do
        if p ~= sourcePlaceable and p.rootNode ~= nil and isPalletShedSink(p, ft) then
            local pFarm = p.ownerFarmId
            if pFarm == nil or farmId == nil or pFarm == farmId then
                local px, _, pz = getWorldTranslation(p.rootNode)
                local dx, dz = px - x, pz - z
                local d2 = dx*dx + dz*dz
                if srcReach == REACH.FARM_WIDE or d2 <= r2 then
                    sinks[#sinks+1] = { shed = p, d2 = d2, placeable = p }
                end
            end
        end
    end
    return sinks
end

-- Drop BLOCKED destinations from a candidate sink list, then order by the player's rank (destRank)
-- first, else nearest-first. Shared by the bulk and pallet store paths. cands = {{placeable,storage,d2}}.
function SmartDistribution.orderedStoreSinks(p, ft, farmId, x, z, cands, srcUid)
    local out = {}
    for _, si in ipairs(cands or {}) do
        local du = si.placeable ~= nil and getUid(si.placeable) or nil
        if du ~= nil and not SmartDistribution.isDestBlocked(srcUid, ft, du) then
            si.rank = SmartDistribution.destRank(srcUid, ft, du)
            out[#out + 1] = si
        end
    end
    table.sort(out, function(a, b)
        if (a.rank ~= nil) ~= (b.rank ~= nil) then return a.rank ~= nil end
        if a.rank ~= nil and b.rank ~= nil and a.rank ~= b.rank then return a.rank < b.rank end
        return (a.d2 or 0) < (b.d2 or 0)
    end)
    return out
end

local function storeAmount(p, storage, ft, farmId, bill)
    if S.global.excludedFillTypes[ft] then return end
    local rm = resolveMode(p, ft)
    if rm ~= MODE.DISTRIBUTE_STORE and rm ~= MODE.STORE then return end
    if p.rootNode == nil then return end
    -- Palletized outputs are delivered as whole pallets by palletPhase, NOT drained in bulk from the
    -- production buffer here -- otherwise the product is stored twice (bulk drain + pallet deposit),
    -- which splits it across targets instead of filling the ranked one. (palletSpawnerFillTypes is an
    -- ARRAY -- search by value.)
    local pfts = palletSpawnerFillTypes(p)
    if pfts ~= nil then
        for _, pf in ipairs(pfts) do
            if pf == ft then return end
        end
    end
    local level = getLevel(storage, ft)
    if level <= 0 then return end
    local x, _, z = getWorldTranslation(p.rootNode)

    -- Default-ON: auto-hunt all valid store sinks, drop any the player BLOCKED, order by rank else distance.
    local srcUid = getUid(p)
    local sinks = SmartDistribution.orderedStoreSinks(p, ft, farmId, x, z, gatherSinks(p, ft, x, z, farmId, resolveReach(p)), srcUid)

    local remaining = level
    for _, sink in ipairs(sinks) do
        if remaining <= 0 then break end
        local room = SmartDistribution.inputAcceptableLiters(sink.placeable, ft)   -- receiver-side block / max %
        local want = math.min(remaining, room)
        local moved = want > 0 and transfer(farmId, storage, sink.storage, ft, want) or 0
        if moved > 0 then
            ledgerAdd(p, ft, "stored", moved)
            ledgerAdd(sink.placeable, ft, "received", moved)   -- recipient side: a store transfer is incoming product too
            recordBill(bill, farmId, p, sink.placeable, sink.d2)
            log("stored %d %s : %s -> %s", moved, fillTypeName(ft), placeableName(p), placeableName(sink.placeable))
            SmartDistribution.recordFeed(sink.placeable, ft, p, moved)   -- link status: this source fed this sink
            remaining = remaining - moved
        end
    end
end

-- uid -> placeable lookup (Store To resolves its chosen targets through this)
function SmartDistribution.placeableByUid(uid)
    if uid == nil or g_currentMission == nil or g_currentMission.placeableSystem == nil then return nil end
    for _, p in ipairs(g_currentMission.placeableSystem.placeables) do
        if p.rootNode ~= nil and getUid(p) == uid then return p end
    end
    return nil
end

-- Store To: push only into the stores the player explicitly chose for this (source, ft), in their ranked
-- order -- or nearest-first while the list is unranked. Each target takes what it can up to its capacity
-- and the rest spills to the next. If nothing can be pushed (every chosen store is full, or none are
-- chosen yet) the stock simply stays put and the mode stays as it is: we flag it so the UI can show that
-- the product can no longer be pushed, and it will top the stores up again on a later cycle.
function SmartDistribution.storeToAmount(p, storage, ft, farmId, bill)
    if S.global.excludedFillTypes[ft] then return end
    local rm = resolveMode(p, ft)
    if rm ~= MODE.STORE_TO and rm ~= MODE.DISTRIBUTE_STORE_TO then return end
    if p.rootNode == nil then return end
    local srcUid = getUid(p)
    if srcUid == nil then return end

    -- Palletized outputs (production pallet outputs, coop eggs/wool, beehive honey) are delivered as
    -- whole pallets by palletPhase -> _storeToPalletAmount, not by this bulk/shed transfer. Skip them here
    -- so they aren't processed twice. (palletSpawnerFillTypes is an ARRAY -- search by value.)
    local pfts = palletSpawnerFillTypes(p)
    if pfts ~= nil then
        for _, pf in ipairs(pfts) do
            if pf == ft then return end
        end
    end

    -- how the source holds this product right now decides both the amount and which targets are valid
    local form = SmartDistribution.sourceHoldForm(p, ft)
    if form == nil then SmartDistribution.setStoreTargetFull(srcUid, ft, false); return end
    local level = (form == "PALLET") and shedStoredLiters(p, ft) or getLevel(storage, ft)
    if level <= 0 then SmartDistribution.setStoreTargetFull(srcUid, ft, false); return end

    -- Move To: every form-compatible OTHER store on the farm is a candidate, MINUS blocked ones. The
    -- dialog blocks them all by default (loop-safe) so nothing moves until the player activates targets.
    -- Order by rank, else nearest-first.
    local x, _, z = getWorldTranslation(p.rootNode)
    local myFarm = SmartDistribution._ownerFarmId(p)
    local targets = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    for _, tp in ipairs(ps ~= nil and ps.placeables or {}) do
        if tp ~= p and tp.rootNode ~= nil and isEnrolled(tp)
           and SmartDistribution._ownerFarmId(tp) == myFarm
           and SmartDistribution.storeToTargetValid(form, tp, ft) then
            local du = getUid(tp)
            if du ~= nil and not SmartDistribution.isDestBlocked(srcUid, ft, du) then
                local tx, _, tz = getWorldTranslation(tp.rootNode)
                targets[#targets + 1] = { placeable = tp, d2 = (tx - x) ^ 2 + (tz - z) ^ 2, rank = SmartDistribution.destRank(srcUid, ft, du) }
            end
        end
    end
    if #targets == 0 then SmartDistribution.setStoreTargetFull(srcUid, ft, true); return end
    table.sort(targets, function(a, b)
        if (a.rank ~= nil) ~= (b.rank ~= nil) then return a.rank ~= nil end
        if a.rank ~= nil and b.rank ~= nil and a.rank ~= b.rank then return a.rank < b.rank end
        return a.d2 < b.d2
    end)

    local remaining, movedAny = level, false
    for _, t in ipairs(targets) do
        if remaining <= 0 then break end
        local moved = SmartDistribution.storeToMove(p, storage, t.placeable, ft, remaining, farmId)
        if moved > 0 then
            movedAny = true
            ledgerAdd(p, ft, "stored", moved)
            ledgerAdd(t.placeable, ft, "received", moved)
            recordBill(bill, farmId, p, t.placeable, t.d2)
            log("storedTo %d %s : %s -> %s", moved, fillTypeName(ft), placeableName(p), placeableName(t.placeable))
            SmartDistribution.recordFeed(t.placeable, ft, p, moved)
            remaining = remaining - moved
        end
    end
    -- still holding stock but nothing would take it => every chosen store is full
    SmartDistribution.setStoreTargetFull(srcUid, ft, (not movedAny) and remaining > 0)
end

local function storePhase(manager, bill)
    -- production outputs set to Distribute+Store: push the remainder to storage
    for _, farmTable in pairs(manager.farmIds or {}) do
        for _, pp in ipairs(farmTable.productionPoints or {}) do
            local placeable = pp.owningPlaceable
            if placeable ~= nil and placeable.rootNode ~= nil and pp.storage ~= nil then
                local farmId = pp.getOwnerFarmId ~= nil and pp:getOwnerFarmId() or placeable.ownerFarmId
                local outFts = {}
                for _, def in ipairs(getActiveProductionDefs(pp)) do
                    for _, o in ipairs(def.outputs or {}) do if o.type ~= nil then outFts[o.type] = true end end
                end
                for ft in pairs(outFts) do
                    storeAmount(placeable, pp.storage, ft, farmId, bill)
                end
            end
        end
    end
    -- husbandry outputs (milk / manure / slurry) set to Distribute+Store
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    for _, p in ipairs(ps.placeables) do
        if getProductionPoint(p) == nil and isHusbandryBuilding(p) and isEnrolled(p) then
            local farmId = p.ownerFarmId
            local outs = husbandryOutputFillTypes(p)
            for _, storage in ipairs(getAllStorages(p)) do
                for ft in pairs(storageFillTypes(storage)) do
                    if outs[ft] then storeAmount(p, storage, ft, farmId, bill) end
                end
            end
        end
    end

    -- Store To / Distribute + Store To: silos, sheds and any other enrolled store pushing into the
    -- stores the player chose. Sheds (object storage) hold their product as pallets/bales, which don't
    -- appear in getAllStorages, so we sweep by the source's supported fill types, not its bulk tanks.
    for _, p in ipairs(ps.placeables) do
        if isEnrolled(p) and p.rootNode ~= nil then
            local farmId = p.ownerFarmId
            local seen = {}
            for _, storage in ipairs(getAllStorages(p)) do
                for ft in pairs(storageFillTypes(storage)) do
                    if not seen[ft] then seen[ft] = true
                        SmartDistribution.storeToAmount(p, storage, ft, farmId, bill)
                    end
                end
            end
            -- object-storage sheds: their held pallet/bale fill types aren't in getAllStorages
            if p.spec_objectStorage ~= nil and SmartDistribution.shedStoredFillTypes ~= nil then
                for ft in pairs(SmartDistribution.shedStoredFillTypes(p)) do
                    if not seen[ft] then seen[ft] = true
                        SmartDistribution.storeToAmount(p, nil, ft, farmId, bill)
                    end
                end
            end
        end
    end
end
-- ---- phase 2: sell remainders ----------------------------------------------

-- SEASONAL HARVEST RESERVE (off by default). For a crop in Distribute+Sell, hold
-- back ~a year's feedstock farm-wide and sell only the genuine surplus. This map
-- is the per-cycle, farm-wide sellable surplus per crop fill type (litres); it is
-- built at the start of the sell phase and consumed by sellAmount.
local seasonalBudget = nil

-- reserve(ft) = monthlyDemand x (learned months-to-cover, else fallback). Held
-- counts ALL farm storage of the crop (Hold/Store stock still feeds demand);
-- the surplus above the reserve is shared across every Distribute+Sell source.
-- Returns nil (no capping) when the feature is off or seasonal growth is disabled.
local function computeSeasonalBudget()
    if not S.global.seasonalReserveEnabled then return nil end
    if SmartDistribution.growthEnabled ~= nil and not SmartDistribution.growthEnabled() then return nil end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil or type(ps.placeables) ~= "table" then return nil end
    local want = {}
    for _, p in ipairs(ps.placeables) do
        if getProductionPoint(p) == nil then            -- silos/barns/etc; productions sell separately
            local fts = SmartDistribution.assetFillTypes(p)
            if type(fts) == "table" then
                for ft in pairs(fts) do
                    if SmartDistribution.isCropFillType(ft)
                       and SmartDistribution.resolvedAssetMode(p, ft) == MODE.DISTRIBUTE_SELL then
                        want[ft] = true
                    end
                end
            end
        end
    end
    if next(want) == nil then return nil end
    local budget = {}
    for ft in pairs(want) do
        local held = 0
        for _, p in ipairs(ps.placeables) do held = held + (SmartDistribution.assetHeld(p, ft) or 0) end
        local months  = SmartDistribution.cropReserveMonths(ft)
        local reserve = SmartDistribution.monthlyDemand(ft) * months
        local surplus = held - reserve
        budget[ft] = surplus > 0 and surplus or 0
    end
    return budget
end

-- ---- best-price inflow tracker --------------------------------------------
-- Rolling per-(asset, ft) measure of how much a store nets per cycle, used to
-- size the best-price full-storage release so production never stalls. Measured
-- as the rise from last cycle's post-sell level to this cycle's pre-sell level
-- (i.e. net production accumulation between passes). Session-only; not persisted.
local function observeInflow(uid, ft, preSellLevel)
    if uid == nil or ft == nil then return 0 end
    local byFt = S.inflow[uid]
    if byFt == nil then byFt = {}; S.inflow[uid] = byFt end
    local rec = byFt[ft]
    if rec == nil then byFt[ft] = { last = preSellLevel, rate = 0 }; return 0 end
    local rise = preSellLevel - rec.last
    if rise > 0 then
        rec.rate = (rec.rate > 0) and (rec.rate * 0.6 + rise * 0.4) or rise
    end
    return rec.rate
end
local function commitLevel(uid, ft, postSellLevel)
    if uid == nil or ft == nil then return end
    local byFt = S.inflow[uid]
    if byFt ~= nil and byFt[ft] ~= nil then byFt[ft].last = postSellLevel end
end

-- Best-price hold/release decision for a filling store (silo OR production output).
-- Returns how many liters of `surplus` to sell THIS cycle: all of it when not holding
-- (master off / mode isn't a sell mode / per-output immediate / peak / flat season), 0
-- to hold everything for the peak, or the minimum release that keeps room for the next
-- inflow when a non-crop store is filling. `storage` is anything getFree/getLevel grok
-- (a Storage or proxy). Crops hold in full (player-filled; the game blocks overfill).
function SmartDistribution.bestPriceSellAmount(placeable, ft, mode, storage, level, surplus)
    if surplus <= 0 then return 0 end
    if not SmartDistribution.resolveBestPrice(placeable, ft, mode) then return surplus end
    if DistributionPricing == nil or DistributionPricing.isPeakNow(ft) then return surplus end
    if SmartDistribution.isCropFillType(ft) then
        log("best-price hold: %s surplus %d (peak P%s)", fillTypeName(ft), surplus,
            tostring(DistributionPricing.getPeakPeriod(ft)))
        return 0
    end
    local free = getFree(storage, ft)
    local sell = 0
    if free ~= nil and free < INF then
        local uid = getUid(placeable)
        local inflow = observeInflow(uid, ft, level)
        if inflow > free then
            sell = inflow - free
            if sell > surplus then sell = surplus end
        end
        commitLevel(uid, ft, level - sell)
    end
    if sell <= 0 then
        log("best-price hold: %s surplus %d (peak P%s)", fillTypeName(ft), surplus,
            tostring(DistributionPricing.getPeakPeriod(ft)))
        return 0
    end
    log("best-price release: %s sell %d, hold %d", fillTypeName(ft), sell, surplus - sell)
    return sell
end

local function sellAmount(p, storage, ft, farmId)
    if S.global.excludedFillTypes[ft] then return end
    local m = resolveMode(p, ft)
    if m ~= MODE.SELL and m ~= MODE.DISTRIBUTE_SELL then return end
    local level = getLevel(storage, ft)
    local amount = level - (S.global.sellReserve or 0)
    -- seasonal reserve: a CROP in Distribute+Sell may only sell the farm-wide surplus
    -- above ~a year's feedstock. Plain SELL is unaffected (sell it all, as configured).
    if amount > 0 and m == MODE.DISTRIBUTE_SELL and seasonalBudget ~= nil then
        local b = seasonalBudget[ft]
        if b ~= nil then
            if b <= 0 then return end
            if amount > b then amount = b end
            seasonalBudget[ft] = b - amount     -- consume the shared farm-wide budget
        end
    end
    if amount <= 0 then return end
    -- best-price: hold the post-reserve surplus for its seasonal peak (releasing only
    -- enough to keep a filling non-crop store from stalling production). Shared with the
    -- production-output sell path so both behave identically.
    amount = SmartDistribution.bestPriceSellAmount(p, ft, m, storage, level, amount)
    if amount <= 0 then return end
    local econ = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if econ == nil or econ.getPricePerLiter == nil then return end
    local price = econ:getPricePerLiter(ft) or 0
    if price <= 0 then return end
    if SmartDistribution.dryRun then
        log("[dry-run] would sell %d %s for %d", amount, fillTypeName(ft), amount * price)
        return
    end
    setLevel(storage, ft, level - amount, farmId, -amount)
    ledgerAdd(p, ft, "sold", amount)
    ledgerAdd(p, ft, "money", amount * price)
    local mt = MoneyType ~= nil and (MoneyType.SOLD_PRODUCTS or MoneyType.OTHER) or nil
    applyMoney(amount * price, farmId, mt)   -- batched across sleep, settled at wake
    log("sold %d %s for %d", amount, fillTypeName(ft), amount * price)
end

-- vanilla DIRECT_SELL replication for a production point
local function sellProduction(pp, farmId)
    if pp.outputFillTypeIdsDirectSell == nil or pp.storage == nil then return end
    local econ = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if econ == nil or econ.getPricePerLiter == nil then return end
    for ft in pairs(pp.outputFillTypeIdsDirectSell) do
        local amount = getLevel(pp.storage, ft)
        if amount > 0 and not S.global.excludedFillTypes[ft] then
            local price = econ:getPricePerLiter(ft) or 0
            if price > 0 then
                if SmartDistribution.dryRun then
                    log("[dry-run] would sell %d %s for %d", amount, fillTypeName(ft), amount * price)
                else
                    local mt = MoneyType ~= nil and (MoneyType.SOLD_PRODUCTS or MoneyType.OTHER) or nil
                    applyMoney(amount * price, farmId, mt)   -- batched across sleep, settled at wake
                    setLevel(pp.storage, ft, 0, farmId, -amount)
                    ledgerAdd(pp.owningPlaceable, ft, "sold", amount)
                    ledgerAdd(pp.owningPlaceable, ft, "money", amount * price)
                    log("sold %d %s for %d", amount, fillTypeName(ft), amount * price)
                end
            end
        end
    end
end

-- ---- sellDirectly outputs (biogas electric charge + methane) ----------------
-- Some production outputs carry sellDirectly=true: vanilla sells them the instant they're produced
-- and they never enter pp.storage.  Our full suppression of the vanilla hourly pass dropped that
-- income, so we reproduce it here.  Per active production that could actually run this hour (inputs
-- on hand, room for its stored outputs), sell each sellDirectly output's hourly amount
-- (amount * cyclesPerHour) at the fill type's base price, booked to INCOME_BGA and batched through
-- applyMoney like all other money.  Gated on SmartDistribution.sellDirectEnabled (log-only until
-- verified).  These outputs are never stored, so there is nothing to drain -- we only add the money.

-- Economic-difficulty sell multiplier for the FIXED grid income (biogas electricity / methane).  These
-- outputs sell at a fixed per-liter price scaled ONLY by the economic difficulty -- no dynamic market --
-- so they are the one sell path that can't use economyManager:getPricePerLiter (which folds in the
-- market fluctuation the grid price doesn't have).  The fillType base pricePerLiter is the HARD value
-- (x1.0); Normal and Easy pay more.  Keyed on the ECONOMIC difficulty (1=Easy, 2=Normal, 3=Hard),
-- which is a SEPARATE setting from the general gameplay difficulty -- a save can run Hard gameplay
-- with an Easy economy, so we must NOT read missionInfo.difficulty here.
local ECON_DIFFICULTY_SELL_MULT = { [1] = 3.0, [2] = 1.8, [3] = 1.0 }   -- easy / normal / hard
local _econDiffLogged = false
local function economyDifficultySellMultiplier()
    local mi = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local raw = nil
    if mi ~= nil then
        if mi.economicDifficulty ~= nil then raw = mi.economicDifficulty else raw = mi.difficulty end
    end
    local idx = raw
    if type(raw) == "string" then                       -- persisted as "EASY" / "NORMAL" / "HARD"
        local s = string.upper(raw)
        idx = (s == "EASY" and 1) or (s == "NORMAL" and 2) or (s == "HARD" and 3) or nil
    end
    local mult = (type(idx) == "number" and ECON_DIFFICULTY_SELL_MULT[idx]) or 1.0
    if SmartDistribution.debug and not _econDiffLogged then
        _econDiffLogged = true
        log("grid sell multiplier: economicDifficulty=%s -> x%.2f", tostring(raw), mult)
    end
    return mult
end

local function fillTypeBasePrice(ft)
    local ftm = g_fillTypeManager
    if ftm ~= nil and ftm.getFillTypeByIndex ~= nil then
        local d = ftm:getFillTypeByIndex(ft)
        if type(d) == "table" and d.pricePerLiter ~= nil then return d.pricePerLiter end
    end
    return 0
end

-- would this production complete >=1 hour of cycles right now?  inputs must cover the hour's draw,
-- and each STORED (non-sellDirectly) output needs room or the vanilla cycle stalls (and would make
-- no sellDirectly output either).  Mirrors vanilla's "can run" gate closely enough to avoid crediting
-- a starved / backed-up plant.
local function productionCanRun(pp, prod)
    local cph = prod.cyclesPerHour or 0
    if cph <= 0 or pp.storage == nil then return false end
    for _, i in ipairs(prod.inputs or {}) do
        if (i.amount or 0) > 0 and getLevel(pp.storage, i.type) < (i.amount or 0) * cph then return false end
    end
    for _, o in ipairs(prod.outputs or {}) do
        if not o.sellDirectly and (o.amount or 0) > 0 and getFree(pp.storage, o.type) < (o.amount or 0) * cph then
            return false
        end
    end
    return true
end

local function sellDirectProduction(manager)
    local mt = MoneyType ~= nil and (MoneyType.INCOME_BGA or MoneyType.SOLD_PRODUCTS or MoneyType.OTHER) or nil
    for _, farmTable in pairs(manager.farmIds or {}) do
        for _, pp in ipairs(farmTable.productionPoints or {}) do
            local placeable = pp.owningPlaceable
            if placeable ~= nil and pp.storage ~= nil then
                local farmId = pp.getOwnerFarmId ~= nil and pp:getOwnerFarmId() or placeable.ownerFarmId
                for _, prod in ipairs(getActiveProductionDefs(pp)) do
                    if productionCanRun(pp, prod) then
                        local cph = prod.cyclesPerHour or 1
                        for _, o in ipairs(prod.outputs or {}) do
                            if o.sellDirectly and (o.amount or 0) > 0 and not S.global.excludedFillTypes[o.type] then
                                local amount = (o.amount or 0) * cph
                                local price  = fillTypeBasePrice(o.type) * economyDifficultySellMultiplier()
                                if price > 0 then
                                    if SmartDistribution.dryRun or not SmartDistribution.sellDirectEnabled then
                                        log("[sell-direct OFF] would sell %.0f %s @ %.4f = %.0f  [%s]",
                                            amount, fillTypeName(o.type), price, amount * price, placeableName(placeable))
                                    else
                                        applyMoney(amount * price, farmId, mt)   -- batched across sleep
                                        ledgerAdd(placeable, o.type, "sold", amount)
                                        ledgerAdd(placeable, o.type, "money", amount * price)
                                        log("sell-direct %.0f %s @ %.4f = %.0f  [%s]",
                                            amount, fillTypeName(o.type), price, amount * price, placeableName(placeable))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function sellPhase(manager)
    seasonalBudget = computeSeasonalBudget()      -- nil unless the feature is on (and growth on)
    -- productions: vanilla "Sell directly" outputs
    for _, farmTable in pairs(manager.farmIds or {}) do
        for _, pp in ipairs(farmTable.productionPoints or {}) do
            sellProduction(pp, pp.getOwnerFarmId ~= nil and pp:getOwnerFarmId() or nil)
        end
    end
    -- silos / other enrolled storages: mode-driven (SELL / DISTRIBUTE_SELL)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then seasonalBudget = nil; return end
    for _, p in ipairs(ps.placeables) do
        if getProductionPoint(p) == nil and isEnrolled(p) then
            local farmId = p.ownerFarmId
            for _, storage in ipairs(getAllStorages(p)) do
                for ft in pairs(storageFillTypes(storage)) do
                    sellAmount(p, storage, ft, farmId)
                end
            end
        end
    end
    seasonalBudget = nil
end

-- ---- owned-market sell points: transfer + sale (+20% bonus) ----------------
-- A source set to "Transfer to My Market" pushes surplus into the buffers of the farm's markets
-- (nearest first, up to MARKET_CAP each); markets then sell those buffers at the station's native
-- listed price with a +20% bonus (immediate, or held for best price). Stage 1: storage-based sources
-- (silos etc.) + abstract sale at native price x1.2. Follow-ups: native addFillLevelFromTool so our
-- sales advance the station's own degradation, the degradation-aware spill, and production/pallet sources.
function SmartDistribution.assetHasMarket(asset)
    if asset == nil or asset.rootNode == nil or g_currentMission == nil then return false end
    local ps = g_currentMission.placeableSystem
    if ps == nil then return false end
    local farmId = asset.ownerFarmId
    local reach = resolveReach(asset)
    local ax, _, az = getWorldTranslation(asset.rootNode)
    local r = (S.global.radius or 50)
    for _, m in ipairs(ps.placeables) do
        if SmartDistribution.isMarket(m) and m.rootNode ~= nil then
            local mo = m.getOwnerFarmId and m:getOwnerFarmId() or m.ownerFarmId
            if mo == farmId then
                if reach ~= REACH.PROXIMITY then return true end
                local mx, _, mz = getWorldTranslation(m.rootNode)
                local dx, dz = ax - mx, az - mz
                if dx * dx + dz * dz <= r * r then return true end
            end
        end
    end
    return false
end

-- The market list a source should actually use for (ft): the player's picked markets when set (ranked
-- order, else nearest-first), otherwise the auto-hunt result from marketsFor. Picked markets are still
-- filtered to ones that accept ft and belong to the farm, so a stale pick can't misroute. Mirrors the
-- store-target override in storeAmount; empty picks => unchanged behaviour.
function SmartDistribution.effectiveMarketsFor(srcPlaceable, farmId, ft, sx, sz, reach)
    local srcUid = srcPlaceable ~= nil and getUid(srcPlaceable) or nil
    -- Default-ON: every market in reach that accepts ft, MINUS blocked ones, ordered rank then distance.
    local out = {}
    for _, mm in ipairs(SmartDistribution.marketsFor(farmId, ft, sx, sz, reach)) do
        local du = getUid(mm.p)
        if srcUid == nil or du == nil or not SmartDistribution.isDestBlocked(srcUid, ft, du) then
            mm.rank = (srcUid ~= nil and du ~= nil) and SmartDistribution.destRank(srcUid, ft, du) or nil
            out[#out + 1] = mm
        end
    end
    table.sort(out, function(a, b)
        if (a.rank ~= nil) ~= (b.rank ~= nil) then return a.rank ~= nil end
        if a.rank ~= nil and b.rank ~= nil and a.rank ~= b.rank then return a.rank < b.rank end
        return a.d2 < b.d2
    end)
    return out
end

function SmartDistribution.marketsFor(farmId, ft, sx, sz, reach)
    local out = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return out end
    local r = (S.global.radius or 50)
    for _, m in ipairs(ps.placeables) do
        if SmartDistribution.isMarket(m) and m.rootNode ~= nil and SmartDistribution.marketAccepts(m, ft) then
            local mo = m.getOwnerFarmId and m:getOwnerFarmId() or m.ownerFarmId
            if mo == farmId then
                local mx, _, mz = getWorldTranslation(m.rootNode)
                local dx, dz = sx - mx, sz - mz
                local d2 = dx * dx + dz * dz
                if reach ~= REACH.PROXIMITY or d2 <= r * r then
                    out[#out + 1] = { p = m, d2 = d2 }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.d2 < b.d2 end)
    return out
end

-- how many litres of ft this source may hand to the market this cycle. Market Supply transfers the
-- post-reserve level; Distribute + Market Supply additionally respects the seasonal (annual-harvest)
-- budget -- exactly like Distribute + Sell -- and only ever sees the post-distribution remainder,
-- since the allocator has already pulled downstream demand from it before this phase runs.
function SmartDistribution.marketTransferAmount(p, ft, mode, level)
    if level == nil or level <= 0 then return 0 end
    local amount = level - (S.global.sellReserve or 0)
    if amount <= 0 then return 0 end
    if mode == MODE.DISTRIBUTE_MARKET and seasonalBudget ~= nil then
        local b = seasonalBudget[ft]
        if b ~= nil then
            if b <= 0 then return 0 end
            if amount > b then amount = b end
            seasonalBudget[ft] = b - amount     -- consume the shared farm-wide harvest budget
        end
    end
    return amount
end

-- spread up to `maxAmount` litres of a storage's ft across the farm's in-range markets (nearest first).
function SmartDistribution.transferStorageToMarkets(storage, ft, farmId, sx, sz, reach, maxAmount, srcPlaceable)
    local level = getLevel(storage, ft)
    if level <= 0 then return 0 end
    local budget = (maxAmount ~= nil) and math.min(level, maxAmount) or level
    local moved = 0
    for _, mm in ipairs(SmartDistribution.effectiveMarketsFor(srcPlaceable, farmId, ft, sx, sz, reach)) do
        if budget <= 0 or level <= 0 then break end
        local muid = getUid(mm.p)
        local push = math.min(budget, level, SmartDistribution.marketCap(mm.p) - SmartDistribution.marketBufferLevel(muid, ft))
        if push > 0 then
            setLevel(storage, ft, level - push, farmId, -push)
            level = level - push; budget = budget - push; moved = moved + push
            SmartDistribution.marketBufferAdd(muid, ft, push)
            ledgerAdd(mm.p, ft, "received", push)
            SmartDistribution.recordFeed(mm.p, ft, srcPlaceable, push)   -- link status: this building fed this market
        end
    end
    return moved
end

-- same, but the source is a pallet spawner (coop eggs / sheep wool / beehive honey): drain pallets.
function SmartDistribution.transferPalletsToMarkets(spawner, ft, farmId, sx, sz, reach, maxAmount)
    local level = palletFillLevel(spawner, ft)
    if level == nil or level <= 0 then return 0 end
    local budget = (maxAmount ~= nil) and math.min(level, maxAmount) or level
    local moved = 0
    for _, mm in ipairs(SmartDistribution.effectiveMarketsFor(spawner, farmId, ft, sx, sz, reach)) do
        if budget <= 0 then break end
        local muid = getUid(mm.p)
        local want = math.min(budget, SmartDistribution.marketCap(mm.p) - SmartDistribution.marketBufferLevel(muid, ft))
        if want > 0 then
            local drained = drainPallets(spawner, ft, want, farmId)
            if drained <= 0 then break end
            SmartDistribution.marketBufferAdd(muid, ft, drained)
            ledgerAdd(mm.p, ft, "received", drained)
            SmartDistribution.recordFeed(mm.p, ft, spawner, drained)   -- link status: pallets fed this market
            budget = budget - drained; moved = moved + drained
        end
    end
    return moved
end

-- same, but the source is an object-storage shed (pallet / bale warehouse): drain its stored liters.
function SmartDistribution.transferShedToMarkets(shed, ft, farmId, sx, sz, reach, maxAmount)
    local level = shedStoredLiters(shed, ft)
    if level == nil or level <= 0 then return 0 end
    local budget = (maxAmount ~= nil) and math.min(level, maxAmount) or level
    local moved = 0
    for _, mm in ipairs(SmartDistribution.effectiveMarketsFor(shed, farmId, ft, sx, sz, reach)) do
        if budget <= 0 then break end
        local muid = getUid(mm.p)
        local want = math.min(budget, SmartDistribution.marketCap(mm.p) - SmartDistribution.marketBufferLevel(muid, ft))
        if want > 0 then
            local drained = drainShedStored(shed, ft, want, farmId)
            if drained <= 0 then break end
            SmartDistribution.marketBufferAdd(muid, ft, drained)
            ledgerAdd(mm.p, ft, "received", drained)
            SmartDistribution.recordFeed(mm.p, ft, shed, drained)   -- link status: the shed fed this market
            budget = budget - drained; moved = moved + drained
        end
    end
    return moved
end

function SmartDistribution.marketTransferPhase(manager)
    if not S.master then return end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    seasonalBudget = computeSeasonalBudget()   -- annual-harvest reserve for Distribute + Market Supply (nil when the feature is off)
    -- storage sources (silos / husbandry storages) + non-production pallet spawners + object-storage sheds
    for _, p in ipairs(ps.placeables) do
        if not SmartDistribution.isMarket(p) and isEnrolled(p) and p.rootNode ~= nil and getProductionPoint(p) == nil then
            local farmId = (p.getOwnerFarmId ~= nil and p:getOwnerFarmId()) or p.ownerFarmId
            local reach = resolveReach(p)
            local sx, _, sz = getWorldTranslation(p.rootNode)
            for _, storage in ipairs(getAllStorages(p)) do
                for ft in pairs(storageFillTypes(storage)) do
                    local m = resolveMode(p, ft)
                    if not S.global.excludedFillTypes[ft] and (m == MODE.TRANSFER_MARKET or m == MODE.DISTRIBUTE_MARKET) then
                        local amt = SmartDistribution.marketTransferAmount(p, ft, m, getLevel(storage, ft))
                        if amt > 0 then local moved = SmartDistribution.transferStorageToMarkets(storage, ft, farmId, sx, sz, reach, amt, p); if moved > 0 then ledgerAdd(p, ft, "stored", moved) end end
                    end
                end
            end
            local pfts = palletSpawnerFillTypes(p)
            if pfts ~= nil then
                for _, ft in ipairs(pfts) do
                    local m = resolveMode(p, ft)
                    if not S.global.excludedFillTypes[ft] and (m == MODE.TRANSFER_MARKET or m == MODE.DISTRIBUTE_MARKET) then
                        local amt = SmartDistribution.marketTransferAmount(p, ft, m, palletFillLevel(p, ft))
                        if amt > 0 then local moved = SmartDistribution.transferPalletsToMarkets(p, ft, farmId, sx, sz, reach, amt); if moved > 0 then ledgerAdd(p, ft, "stored", moved) end end
                    end
                end
            end
            if p.spec_objectStorage ~= nil then   -- pallet / bale warehouse (object storage)
                for ft in pairs(SmartDistribution.shedStoredFillTypes(p)) do
                    local m = resolveMode(p, ft)
                    if not S.global.excludedFillTypes[ft] and (m == MODE.TRANSFER_MARKET or m == MODE.DISTRIBUTE_MARKET) then
                        local amt = SmartDistribution.marketTransferAmount(p, ft, m, shedStoredLiters(p, ft))
                        if amt > 0 then local moved = SmartDistribution.transferShedToMarkets(p, ft, farmId, sx, sz, reach, amt); if moved > 0 then ledgerAdd(p, ft, "stored", moved) end end
                    end
                end
            end
        end
    end
    -- production outputs (mill -> flour, dairy -> cheese/butter, ...): drain pp.storage output fill types
    for _, farmTable in pairs(manager.farmIds or {}) do
        for _, pp in ipairs(farmTable.productionPoints or {}) do
            local placeable = pp.owningPlaceable
            if placeable ~= nil and placeable.rootNode ~= nil and pp.storage ~= nil then
                local farmId = (pp.getOwnerFarmId ~= nil and pp:getOwnerFarmId()) or placeable.ownerFarmId
                local reach = resolveReach(placeable)
                local sx, _, sz = getWorldTranslation(placeable.rootNode)
                local outFts = {}
                for _, def in ipairs(getActiveProductionDefs(pp)) do
                    for _, o in ipairs(def.outputs or {}) do if o.type ~= nil then outFts[o.type] = true end end
                end
                for ft in pairs(outFts) do
                    local m = resolveMode(placeable, ft)
                    if not S.global.excludedFillTypes[ft] and (m == MODE.TRANSFER_MARKET or m == MODE.DISTRIBUTE_MARKET) then
                        local amt = SmartDistribution.marketTransferAmount(placeable, ft, m, getLevel(pp.storage, ft))
                        if amt > 0 then local moved = SmartDistribution.transferStorageToMarkets(pp.storage, ft, farmId, sx, sz, reach, amt); if moved > 0 then ledgerAdd(placeable, ft, "stored", moved) end end
                    end
                end
            end
        end
    end
    seasonalBudget = nil
end

-- Read a farm's current balance (used to measure what a native station sale actually paid).
function SmartDistribution.farmMoney(farmId)
    if g_currentMission == nil or farmId == nil then return nil end
    if g_currentMission.getMoney ~= nil then
        local ok, a = pcall(function() return g_currentMission:getMoney(farmId) end)
        if ok and type(a) == "number" then return a end
    end
    if g_farmManager ~= nil and g_farmManager.getFarmById ~= nil then
        local ok, f = pcall(function() return g_farmManager:getFarmById(farmId) end)
        if ok and type(f) == "table" then
            if type(f.getBalance) == "function" then
                local ok2, b = pcall(function() return f:getBalance() end)
                if ok2 and type(b) == "number" then return b end
            end
            if type(f.money) == "number" then return f.money end
        end
    end
    return nil
end

-- Sell `liters` of `ft` at this market. Preferred path: the station's native addFillLevelFromTool,
-- so the game applies its own price + degradation and pays the base -- we measure the balance delta
-- to confirm it actually paid, then credit a +20% bonus on those real proceeds. If the balance can't
-- be read or the native call pays nothing, fall back to an abstract sale at native price x1.2 (never
-- double-pays: the native branch only runs when we can measure it).
function SmartDistribution.marketSell(station, farmId, ft, liters)
    if station == nil or farmId == nil or liters == nil or liters <= 0 then return end
    local price = 0
    if type(station.getEffectiveFillTypePrice) == "function" then
        local ok, a = pcall(function() return station:getEffectiveFillTypePrice(ft) end)
        if ok and type(a) == "number" then price = a end
    end
    if price <= 0 then
        local econ = g_currentMission ~= nil and g_currentMission.economyManager or nil
        if econ ~= nil and econ.getPricePerLiter ~= nil then price = econ:getPricePerLiter(ft) or 0 end
    end
    if price <= 0 then return end
    local mt = MoneyType ~= nil and (MoneyType.SOLD_PRODUCTS or MoneyType.OTHER) or nil
    local before = SmartDistribution.farmMoney(farmId)
    local nativePaid = 0
    local mission = g_currentMission
    if before ~= nil and mission ~= nil and mission.addMoney ~= nil and type(station.addFillLevelFromTool) == "function" then
        local tt = (ToolType ~= nil) and (ToolType.UNDEFINED or ToolType.UNKNOWN) or nil
        -- Suppress the station's OWN per-sale notification (the base-game "sold products" money-change).
        -- forceShowChange=false on addMoney isn't enough by itself -- a normal-sized sale still pushes a
        -- money-change straight to the HUD -- so we also no-op the money-change / notification calls for the
        -- duration of the native sale. The proceeds still land on the finance sheet and get folded into the
        -- mod's batched "Product sales" summary below, so the player sees ONE combined notification, not two.
        local realAddMoney = mission.addMoney
        mission.addMoney = function(selfm, amount, fid, mtype, addChange, forceShow)
            return realAddMoney(selfm, amount, fid, mtype, addChange, false)
        end
        local noop    = function() end
        local hud     = mission.hud
        local rHudMC  = (hud ~= nil) and hud.addMoneyChange or nil
        local rShowMC = mission.showMoneyChange
        local rAddMC  = mission.addMoneyChange
        local rIngame = mission.addIngameNotification
        if rHudMC  ~= nil then hud.addMoneyChange           = noop end
        if rShowMC ~= nil then mission.showMoneyChange       = noop end
        if rAddMC  ~= nil then mission.addMoneyChange        = noop end
        if rIngame ~= nil then mission.addIngameNotification = noop end
        pcall(function() station:addFillLevelFromTool(farmId, liters, ft, nil, tt, nil) end)
        mission.addMoney = realAddMoney
        if rHudMC  ~= nil then hud.addMoneyChange           = rHudMC  end
        if rShowMC ~= nil then mission.showMoneyChange       = rShowMC end
        if rAddMC  ~= nil then mission.addMoneyChange        = rAddMC  end
        if rIngame ~= nil then mission.addIngameNotification = rIngame end
        local after = SmartDistribution.farmMoney(farmId)
        if after ~= nil then nativePaid = after - before end
    end
    if nativePaid > 0 then
        tallyMoney(nativePaid, mt)                          -- fold the native base into the batched "Product sales" summary (silent through sleep)
        applyMoney(0.20 * nativePaid, farmId, mt)          -- +20% bonus (silent + tallied)
        log("market sold %d %s: native %d + bonus %d", liters, fillTypeName(ft), math.floor(nativePaid), math.floor(0.20 * nativePaid))
        return nativePaid * 1.20
    end
    applyMoney(liters * price * 1.20, farmId, mt)          -- native path unavailable / paid nothing: abstract sale, silent + tallied
    log("market sold %d %s: abstract %d (native price %.4f x1.2)", liters, fillTypeName(ft), math.floor(liters * price * 1.20), price)
    return liters * price * 1.20
end

-- Best-price gate for a market product. Sells when this market's current effective price is within ~5%
-- of the best price we can justify: the higher of (a) the highest price seen here for this product and
-- (b) the seasonal peak the price forecast projects from the current price. Early on, with no observed
-- high yet, (b) -- the graph -- drives it; once a real high has been seen, (a) does. A near-full buffer
-- always sells, so best-price never back-pressures the supplying network.
function SmartDistribution.marketAtBestPrice(market, muid, ft, station, avail)
    local cur = 0
    if station ~= nil and type(station.getEffectiveFillTypePrice) == "function" then
        local ok, a = pcall(function() return station:getEffectiveFillTypePrice(ft) end)
        if ok and type(a) == "number" then cur = a end
    end
    if cur <= 0 then return true end                                  -- can't price it -> don't trap it
    local hi = SmartDistribution._marketPriceHigh[muid]
    if hi == nil then hi = {}; SmartDistribution._marketPriceHigh[muid] = hi end
    if (hi[ft] or 0) < cur then hi[ft] = cur end                      -- track the observed high
    if avail ~= nil and avail >= SmartDistribution.marketCap(market) * 0.95 then return true end   -- safety: near cap, sell
    local graphPeak = cur
    if DistributionPricing ~= nil and DistributionPricing.peakRatio ~= nil then
        graphPeak = cur * (DistributionPricing.peakRatio(ft) or 1)    -- current price projected to the seasonal peak
    end
    local target = math.max(hi[ft] or 0, graphPeak)
    return cur >= target * 0.95                                       -- within 5% of the best justifiable price
end

function SmartDistribution.marketSellPhase(manager)
    if not S.master then return end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    for _, p in ipairs(ps.placeables) do
        if SmartDistribution.isMarket(p) then
            local muid = getUid(p)
            local buf = SmartDistribution._marketBuffer[muid]
            if buf ~= nil then
                local farmId = p.getOwnerFarmId and p:getOwnerFarmId() or p.ownerFarmId
                local station = SmartDistribution.marketStationOf(p)
                local fts = {}
                for ft, v in pairs(buf) do if v ~= nil and v > 0 then fts[#fts + 1] = ft end end
                for _, ft in ipairs(fts) do
                    local mode = SmartDistribution.marketSellMode(muid, ft)   -- per-product: 0 immediate / 1 best price / 2 hold
                    local avail = SmartDistribution.marketBufferLevel(muid, ft)
                    local sellNow = mode ~= SmartDistribution.MARKET_HOLD
                    if sellNow and mode == SmartDistribution.MARKET_BEST then
                        sellNow = SmartDistribution.marketAtBestPrice(p, muid, ft, station, avail)
                    end
                    if avail > 0 and sellNow and station ~= nil then
                        local got = SmartDistribution.marketSell(station, farmId, ft, avail)
                        SmartDistribution.marketBufferAdd(muid, ft, -avail)
                        ledgerAdd(p, ft, "sold", avail)
                        if got ~= nil and got > 0 then ledgerAdd(p, ft, "money", got) end
                    end
                end
            end
        end
    end
end

-- ---- pallet-spawner outputs (eggs / wool / honey) --------------------------
-- Coops, sheep pastures and beehives emit their product as physical pallet
-- vehicles tracked in spec_husbandryPallets.pallets (a set), NOT in a Storage, so they
-- need their own read/drain primitives. resolveMode(coop, ft) drives them like any other
-- asset -- the coop *is* the asset.  These primitives (forward-declared above) back both the
-- pallet phase (sell/store remainders) and the gatherSources pallet source branch (distribute).

-- sum the movable liters of `ft` across an asset's tracked pallets
-- A husbandry only tracks pallets it spawned THIS session in spec.pallets; savegame load does NOT
-- restore that set (loadFromXMLFile restores only pendingLiters) and the pallet trigger removes on
-- leave but never adds on enter.  So full pallets carried over from a prior save sit at the farm
-- UNTRACKED.  To act on ALL of a husbandry's pallets, union the tracked set with nearby world
-- pallet vehicles of the same fill type + owner farm (within PALLET_ASSOC_RADIUS of the building).
local PALLET_ASSOC_RADIUS = 25
-- productions emit their pallets at designated output spots that can sit further from the
-- building centre than a coop's, so they get a wider association radius. The per-fill-type
-- filter in husbandryPalletObjects keeps two nearby productions from claiming each other's pallets.
local PALLET_ASSOC_RADIUS_PROD = 50
local function husbandryPalletObjects(p, ft)
    local out, seen = {}, {}
    local function consider(pallet)
        if type(pallet) ~= "table" or seen[pallet] then return end
        local idx = (pallet.spec_pallet ~= nil and pallet.spec_pallet.fillUnitIndex) or 1
        if pallet.getFillUnitFillType == nil or pallet:getFillUnitFillType(idx) == ft then
            seen[pallet] = true
            out[#out + 1] = pallet
        end
    end
    local spec = p.spec_husbandryPallets
    if spec ~= nil and type(spec.pallets) == "table" then
        for pallet in pairs(spec.pallets) do consider(pallet) end
    end
    local vs = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if vs ~= nil and type(vs.vehicles) == "table" and p.rootNode ~= nil then
        local hx, _, hz = getWorldTranslation(p.rootNode)
        local farmId = (p.getOwnerFarmId ~= nil and p:getOwnerFarmId()) or p.ownerFarmId
        local radius = (getProductionPoint(p) ~= nil) and PALLET_ASSOC_RADIUS_PROD or PALLET_ASSOC_RADIUS
        local r2 = radius * radius
        for _, v in ipairs(vs.vehicles) do
            if v ~= nil and v.isPallet and v.rootNode ~= nil and not seen[v] then
                local vfarm = (v.getOwnerFarmId ~= nil and v:getOwnerFarmId()) or v.ownerFarmId
                if vfarm == nil or farmId == nil or vfarm == farmId then
                    local vx, _, vz = getWorldTranslation(v.rootNode)
                    local dx, dz = vx - hx, vz - hz
                    if dx * dx + dz * dz <= r2 then consider(v) end
                end
            end
        end
    end
    return out
end

function palletFillLevel(p, ft)
    if not isPalletSpawnerAsset(p) then return 0 end
    local total = 0
    for _, pallet in ipairs(husbandryPalletObjects(p, ft)) do
        if pallet.getFillUnitFillLevel ~= nil then
            local idx = (pallet.spec_pallet ~= nil and pallet.spec_pallet.fillUnitIndex) or 1
            total = total + (pallet:getFillUnitFillLevel(idx) or 0)
        end
    end
    return total
end

-- drain up to `amount` liters of `ft` from the asset's pallets; returns liters drained.
-- pallets that hit empty are deleted and dropped from the spawner's set (server-side;
-- the base game replicates pallet deletion to clients).
function drainPallets(p, ft, amount, farmId)
    if not isPalletSpawnerAsset(p) then return 0 end
    local spec = p.spec_husbandryPallets   -- nil for a beehive spawner (no tracked set to prune)
    local drained, toDelete = 0, {}
    for _, pallet in ipairs(husbandryPalletObjects(p, ft)) do
        if amount - drained <= 0 then break end
        if pallet.addFillUnitFillLevel ~= nil then
            local idx = (pallet.spec_pallet ~= nil and pallet.spec_pallet.fillUnitIndex) or 1
            local lvl = (pallet.getFillUnitFillLevel ~= nil and pallet:getFillUnitFillLevel(idx)) or 0
            local d = math.min(amount - drained, lvl)
            if d > 0 then
                pallet:addFillUnitFillLevel(farmId, idx, -d, ft, ToolType ~= nil and ToolType.UNDEFINED or nil)
                drained = drained + d
                if lvl - d <= 0 then toDelete[#toDelete + 1] = pallet end
            end
        end
    end
    for _, pallet in ipairs(toDelete) do
        if pallet.delete ~= nil then pcall(function() pallet:delete() end) end
        if spec ~= nil and type(spec.pallets) == "table" then spec.pallets[pallet] = nil end
    end
    return drained
end

-- wrap a pallet-spawner asset as a thin read/drain "storage" so the normal distribute path
-- (gatherSources -> transfer) can pull from it: getFillLevel reports summed pallet liters, and
-- the negative addFillLevel that transfer issues when draining a source drains+deletes pallets.
-- No fillLevels table, so getLevel/setLevel fall through to these two methods.
function makePalletSourceProxy(p)
    return {
        getFillLevel = function(_, ft) return palletFillLevel(p, ft) end,
        addFillLevel = function(_, farmId, ft, delta)
            if delta ~= nil and delta < 0 then drainPallets(p, ft, -delta, farmId) end
        end,
    }
end

-- ---- pallet storage shed as a distribute SOURCE ----------------------------
-- Stored pallets/bales are despawned into abstract objects; each keeps a nested
-- attributes table carrying its numeric fillType + fillLevel so it can respawn
-- intact.  That field name isn't in the public API (bales use `baleAttributes`),
-- so locate it generically: the nested table holding BOTH a numeric fillType and
-- a numeric fillLevel.  Returns nil for objects we can't read (left untouched).
local function storedObjectAttrs(obj)
    if type(obj) ~= "table" then return nil end
    local named = obj.palletAttributes or obj.baleAttributes
    if type(named) == "table" and type(named.fillType) == "number" and type(named.fillLevel) == "number" then
        return named
    end
    for _, v in pairs(obj) do
        if type(v) == "table" and type(v.fillType) == "number" and type(v.fillLevel) == "number" then
            return v
        end
    end
    return nil
end

-- Resolve a shed's stored contents to a flat list of { fillType=, fillLevel= } attrs, reading the
-- structure THIS machine actually has. spec.storedObjects (the flat abstract list) is SERVER-ONLY,
-- so on a client it is empty -- which left pallet sheds showing no rows and 0 liters for non-host
-- players. The base game keeps spec.objectInfos (objects grouped per type) in sync for the HUD, so
-- prefer that; fall back to the flat list on the server. Server totals are unchanged because
-- objectInfos is rebuilt from storedObjects and carries the same objects.
local function shedStoredAttrs(shed)
    local spec = shed ~= nil and shed.spec_objectStorage or nil
    local out = {}
    if spec == nil then return out end
    if type(spec.objectInfos) == "table" then
        for _, info in pairs(spec.objectInfos) do
            if type(info) == "table" then
                if type(info.objects) == "table" and #info.objects > 0 then
                    for _, obj in ipairs(info.objects) do
                        local a = storedObjectAttrs(obj)
                        if a ~= nil then out[#out + 1] = a end
                    end
                elseif type(info.fillType) == "number" and type(info.fillLevel) == "number" then
                    out[#out + 1] = { fillType = info.fillType, fillLevel = info.fillLevel }   -- info-level aggregate
                end
            end
        end
    end
    if #out > 0 then return out end
    if type(spec.storedObjects) == "table" then
        for _, obj in ipairs(spec.storedObjects) do
            local a = storedObjectAttrs(obj)
            if a ~= nil then out[#out + 1] = a end
        end
    end
    return out
end

-- liters of `ft` held across a shed's stored pallet/bale objects (client-safe; see shedStoredAttrs)
local _shedDiagSeen = setmetatable({}, { __mode = "k" })
function shedStoredLiters(shed, ft)
    local total = 0
    for _, a in ipairs(shedStoredAttrs(shed)) do
        if a.fillType == ft and (a.fillLevel or 0) > 0 then total = total + a.fillLevel end
    end
    -- one-time diagnostic: the shed clearly holds objects but we resolved nothing -- helps pin the
    -- synced field if a future build changes the object-storage layout. Debug-gated, once per shed.
    if SmartDistribution.debug and total == 0 and shed ~= nil and not _shedDiagSeen[shed] then
        local spec = shed.spec_objectStorage
        local nStored = (spec ~= nil and type(spec.storedObjects) == "table" and #spec.storedObjects) or -1
        local nInfos  = (spec ~= nil and type(spec.objectInfos)  == "table" and #spec.objectInfos)  or -1
        if nStored > 0 or nInfos > 0 then
            _shedDiagSeen[shed] = true
            local keys = {}
            if spec ~= nil then for k, v in pairs(spec) do keys[#keys + 1] = tostring(k) .. ":" .. type(v) end end
            log("shed read miss: %s ft=%s storedObjects=%d objectInfos=%d spec{%s}",
                tostring(placeableName(shed)), tostring(fillTypeName(ft)), nStored, nInfos, table.concat(keys, ","))
        end
    end
    return total
end

-- pull up to `amount` liters of `ft` from a shed's stored objects.  Iterates from
-- the end so part-emptied objects are removed without shifting indices underfoot;
-- objects drained to ~0 are removed from storage (and deleted if they support it).
-- Returns liters actually drained, and refreshes the shed's count/visual/save state.
function drainShedStored(shed, ft, amount, farmId)
    local spec = shed.spec_objectStorage
    if spec == nil or type(spec.storedObjects) ~= "table" or amount <= 0 then return 0 end
    local drained = 0
    for i = #spec.storedObjects, 1, -1 do
        if drained >= amount then break end
        local obj = spec.storedObjects[i]
        local a = storedObjectAttrs(obj)
        if a ~= nil and a.fillType == ft and a.fillLevel > 0 then
            local take = math.min(a.fillLevel, amount - drained)
            a.fillLevel = a.fillLevel - take
            drained = drained + take
            if a.fillLevel <= 0.0001 then
                table.remove(spec.storedObjects, i)
                if type(obj) == "table" and obj.delete ~= nil then pcall(function() obj:delete() end) end
            end
        end
    end
    if drained > 0 then
        spec.numStoredObjects = #spec.storedObjects
        if shed.setObjectStorageObjectInfosDirty ~= nil then shed:setObjectStorageObjectInfosDirty() end
    end
    return drained
end

function makeShedSourceProxy(shed)
    return {
        getFillLevel = function(_, ft) return shedStoredLiters(shed, ft) end,
        addFillLevel = function(_, farmId, ft, delta)
            if delta ~= nil and delta < 0 then drainShedStored(shed, ft, -delta, farmId) end
        end,
    }
end

-- distinct fill types a shed currently holds (drives shed-sell + the config dialog); (set, anyFlag)
local function shedStoredFillTypes(shed)
    local set, any = {}, false
    for _, a in ipairs(shedStoredAttrs(shed)) do
        if a.fillType ~= nil and (a.fillLevel or 0) > 0 then set[a.fillType] = true; any = true end
    end
    return set, any
end
SmartDistribution.shedStoredFillTypes = shedStoredFillTypes

-- farm-wide pallet/bale fill types the network can supply a shed with, split by ORIGIN:
--   pallets = real pallet outputs the network PRODUCES (production palletized outputs + pallet
--             spawners: eggs / wool / honey). Genuine pallets, not generic big-bags.
--   bulk    = fill types on hand (level > 0) in enrolled bulk storage. Only their BALEABLE members
--             are of interest (the bale signal: stored straw / grass / hay / silage). We deliberately
--             do NOT treat bulk as palletisable -- FS gives most crops a generic fillable-pallet
--             filename, so a "palletizable" test would wrongly admit wheat and every other crop.
-- Enrolled assets only, so a class toggled off in Settings contributes nothing. Returns (pallets, bulk).
function SmartDistribution.networkPalletBaleFillTypes()
    local pallets, bulk = {}, {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil or type(ps.placeables) ~= "table" then return pallets, bulk end
    local farmId = (g_currentMission.getFarmId ~= nil) and g_currentMission:getFarmId() or nil
    for _, p in ipairs(ps.placeables) do
        if p.rootNode ~= nil and isEnrolled(p) then
            local owned = (p.getOwnerFarmId == nil) or (farmId == nil) or (p:getOwnerFarmId() == farmId)
            if owned then
                local pp = getProductionPoint(p)
                if pp ~= nil then
                    for _, ft in ipairs(productionPalletFillTypes(pp)) do pallets[ft] = true end
                end
                local sp = palletSpawnerFillTypes(p)
                if type(sp) == "table" then for _, ft in ipairs(sp) do pallets[ft] = true end end
                for _, storage in ipairs(getAllStorages(p)) do
                    if type(storage.fillLevels) == "table" then
                        for ft, lvl in pairs(storage.fillLevels) do
                            if (lvl or 0) > 0 then bulk[ft] = true end
                        end
                    end
                end
            end
        end
    end
    return pallets, bulk
end

-- fill types that have a real BALE form, so a pallet shed could actually hold them as bales (stored
-- straw / grass / hay / silage etc. -- NOT bulk crops like wheat). Built once + cached: tries the
-- runtime bale registry (covers modded bales), then supplements with the base-game baleable crop set.
function SmartDistribution.baleableFillTypes()
    if SmartDistribution._baleableCache ~= nil then return SmartDistribution._baleableCache end
    local set = {}
    local ftm = g_fillTypeManager
    local bm  = rawget(_G, "g_baleManager")
    if bm ~= nil then
        pcall(function()
            local bales = (type(bm.getBales) == "function" and bm:getBales()) or bm.bales or bm.nameToBale
            if type(bales) == "table" then
                for _, b in pairs(bales) do
                    local ft = b and (b.fillType or b.fillTypeIndex)
                    if ft == nil and b and b.fillTypeName ~= nil and ftm ~= nil then
                        ft = ftm:getFillTypeIndexByName(b.fillTypeName)
                    end
                    if ft ~= nil then set[ft] = true end
                end
            end
        end)
    end
    if ftm ~= nil and ftm.getFillTypeIndexByName ~= nil then       -- base-game baleable crops (always)
        for _, name in ipairs({ "STRAW", "DRYGRASS_WINDROW", "HAY", "GRASS_WINDROW", "GRASS", "SILAGE", "COTTON" }) do
            local idx = ftm:getFillTypeIndexByName(name)
            if idx ~= nil then set[idx] = true end
        end
    end
    SmartDistribution._baleableCache = set
    return set
end

-- the configurable fill-type set shown for a pallet shed in the menu: everything the shed actually
-- accepts (getObjectStorageSupportsFillType) that the network can supply, UNION whatever is physically
-- in the shed right now (manual loads show even if unsupported / off-network). Lets players pre-set a
-- distribution mode for material not in the shed yet -- the mode persists + applies once stock lands.
-- Kept SEPARATE from assetConfigFillTypes so the allocator's stored-only view stays untouched.
function SmartDistribution.shedSupportedFillTypes(shed)
    local set, any = {}, false
    if shed == nil then return set, any end
    -- (a) physically present now -- always shown, even if off-network / unsupported
    for _, a in ipairs(shedStoredAttrs(shed)) do
        if a.fillType ~= nil and (a.fillLevel or 0) > 0 and not set[a.fillType] then
            set[a.fillType] = true; any = true
        end
    end
    -- (b) the network's real produced pallets + baleable bulk on hand, intersected with what this shed
    -- accepts. Origins are kept separate on purpose: getObjectStorageSupportsFillType is permissive and
    -- FS marks most crops as generically "palletisable", so the only safe way to keep wheat etc. out is
    -- to admit bulk material only when it is genuinely BALEABLE; pallets come from actual producers.
    local supportsFn = shed.getObjectStorageSupportsFillType
    local baleable   = SmartDistribution.baleableFillTypes()
    local pallets, bulk = SmartDistribution.networkPalletBaleFillTypes()
    local function offer(ft)
        if set[ft] then return end
        local ok = (supportsFn == nil) or shed:getObjectStorageSupportsFillType(ft)
        if ok then set[ft] = true; any = true end
    end
    for ft in pairs(pallets) do offer(ft) end                          -- produced pallets (planks / eggs / wool / honey / ...)
    for ft in pairs(bulk) do if baleable[ft] then offer(ft) end end    -- bulk on hand: baleable crops only
    return set, any
end
-- count a shed's stored objects of one fill type (each stored object = one slot)
local function shedObjectCount(shed, ft)
    local n = 0
    for _, a in ipairs(shedStoredAttrs(shed)) do
        if a.fillType == ft and (a.fillLevel or 0) > 0 then n = n + 1 end
    end
    return n
end

-- sell up to `liters` of a shed's `ft` at market price, in place. Returns liters sold.
local function sellShedLiters(shed, ft, liters, farmId)
    if liters <= 0 then return 0 end
    local econ = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if econ == nil or econ.getPricePerLiter == nil then return 0 end
    local price = econ:getPricePerLiter(ft) or 0
    if price <= 0 then return 0 end
    if SmartDistribution.dryRun then
        log("[dry-run] would sell %d %s (shed) for %d", liters, fillTypeName(ft), liters * price)
        return 0
    end
    local drained = drainShedStored(shed, ft, liters, farmId)
    if drained > 0 then
        ledgerAdd(shed, ft, "sold", drained)
        ledgerAdd(shed, ft, "money", drained * price)
        local mt = MoneyType ~= nil and (MoneyType.SOLD_PRODUCTS or MoneyType.OTHER) or nil
        applyMoney(drained * price, farmId, mt)   -- batched across sleep, settled at wake
        log("sold %d %s (shed) for %d  [%s]", drained, fillTypeName(ft), drained * price, placeableName(shed))
    end
    return drained
end

-- sell all of a shed's stored `ft` liters at market price (caller gates on mode + sellEnabled).
-- Sold in place, no haul -- mirrors sellPalletAmount.
local function sellShedAmount(shed, ft, farmId)
    sellShedLiters(shed, ft, shedStoredLiters(shed, ft), farmId)
end

-- keep ~this fraction of a shed's slots free for incoming pallets when holding for best price
local BESTPRICE_SHED_RESERVE_FRAC = 0.05

-- Relocate up to `maxSlots` FULL `ft` pallets from one shed's object storage into another's by moving
-- the abstract stored entry directly. Server-only (the shed pass is server-gated), so src.storedObjects
-- is populated. Mirrors drainShedStored's removal and the deposit path's setObjectStorageObjectInfosDirty()
-- refresh on BOTH sheds, so each shed's count / visual pallets / save / MP sync all follow. The moved
-- object is self-contained pallet data and both sheds share the same fill type + farm (the caller picks
-- destinations via gatherShedSinks -> isPalletShedSink), so it stays valid in the destination. Returns
-- slots moved.
local function transferShedPallets(src, dst, ft, maxSlots)
    if src == nil or dst == nil or (maxSlots or 0) <= 0 then return 0 end
    local ss = src.spec_objectStorage
    local ds = dst.spec_objectStorage
    if ss == nil or ds == nil or type(ss.storedObjects) ~= "table" then return 0 end
    if type(ds.storedObjects) ~= "table" then ds.storedObjects = {} end
    local moved = 0
    for i = #ss.storedObjects, 1, -1 do                       -- from the end: removal won't shift unseen indices
        if moved >= maxSlots then break end
        local dcap = ds.capacity or 0
        if dcap > 0 and #ds.storedObjects >= dcap then break end          -- destination full
        local obj = ss.storedObjects[i]
        local a = storedObjectAttrs(obj)
        if a ~= nil and a.fillType == ft and (a.fillLevel or 0) > 0 then
            table.remove(ss.storedObjects, i)
            ds.storedObjects[#ds.storedObjects + 1] = obj
            moved = moved + 1
        end
    end
    if moved > 0 then
        ss.numStoredObjects = #ss.storedObjects
        ds.numStoredObjects = #ds.storedObjects
        if src.setObjectStorageObjectInfosDirty ~= nil then src:setObjectStorageObjectInfosDirty() end
        if dst.setObjectStorageObjectInfosDirty ~= nil then dst:setObjectStorageObjectInfosDirty() end
    end
    return moved
end

-- ---- Store To: form-aware routing across ALL storage types --------------------------------------
-- Store To lets any store push a product to another store that can physically receive it. The rule is
-- FORM, not building class: a product held as pallets/bales (object storage) can only go to a store that
-- accepts those pallets; a product held in bulk can only go to a store with a bulk tank for it. This
-- covers modded buildings too (a non-silo bulk store can feed a silo, and vice versa), because we decide
-- from how the SOURCE currently holds the item and whether the DESTINATION supports that same form --
-- never from the class name. Cross-form (bulk <-> pallet) is rejected: the base game gates that behind a
-- baler / shredder, so the mod won't fabricate the conversion.

-- Does this placeable hold `ft` as pallets/bales in object storage (with some on hand)?
function SmartDistribution._holdsAsPallets(p, ft)
    return p ~= nil and p.spec_objectStorage ~= nil and shedStoredLiters(p, ft) > 0
end

-- A bulk storage on `p` that supports `ft` (nil if none). This is the receiving tank for a bulk push.
function SmartDistribution._bulkStorageFor(p, ft)
    if p == nil then return nil end
    for _, s in ipairs(getAllStorages(p)) do
        if storageFillTypes(s)[ft] ~= nil then return s end
    end
    return nil
end

-- Is `dst` a valid Store To target for `ft` held (in `srcForm`) by the source? srcForm is "PALLET" or
-- "BULK". Same-form only, and the destination must be genuine STORAGE -- a barn/pen or a production has
-- a bulk tank for its inputs/outputs but is a DEMAND, not a place to stockpile into, so it is excluded
-- here (Distribute feeds those; Store To does not).
function SmartDistribution.storeToTargetValid(srcForm, dst, ft)
    if dst == nil or ft == nil then return false end
    local cls = getAssetClass(dst)
    if cls ~= "SILO" and cls ~= "SHED" and cls ~= "HEAP" then return false end   -- storage only, never a demand
    if srcForm == "PALLET" then
        return isPalletShedSink(dst, ft)                      -- object storage that supports + has a free slot
    end
    return SmartDistribution._bulkStorageFor(dst, ft) ~= nil  -- any bulk tank that supports ft
end

-- The form a source hands `ft` out in ("PALLET" or "BULK"), or nil if it has none.
--   * object-storage sheds hold pallets/bales directly -> PALLET
--   * a production PALLETIZES some outputs (bottled milk, bread, ...): those leave as pallets even though
--     the production buffers them in a bulk tank internally, so they must target a pallet store, not a
--     bulk silo. Detect that from the production's pallet-spawner output set.
--   * anything held in a real bulk tank -> BULK
function SmartDistribution.sourceHoldForm(p, ft)
    if SmartDistribution._holdsAsPallets(p, ft) then return "PALLET" end
    -- palletSpawnerFillTypes returns an ARRAY of fill-type indices, not a set -- search it by value.
    local pfts = palletSpawnerFillTypes(p)
    if pfts ~= nil then
        for _, pf in ipairs(pfts) do
            if pf == ft then return "PALLET" end
        end
    end
    if SmartDistribution._bulkStorageFor(p, ft) ~= nil then return "BULK" end
    return nil
end

-- Move up to `amount` litres of `ft` from source to dst, using the right primitive for the source's
-- current FORM. Returns litres moved. Caller has already validated form compatibility.
function SmartDistribution.storeToMove(srcP, srcStorage, dstP, ft, amount, farmId)
    if amount <= 0 then return 0 end
    -- receiver-side cap: never push more than the target will accept for this product (block / max %).
    local room = SmartDistribution.inputAcceptableLiters(dstP, ft)
    if room <= 0 then return 0 end
    if amount > room then amount = room end
    if SmartDistribution._holdsAsPallets(srcP, ft) then
        -- pallet/bale source -> pallet store: move whole slots, report the litres they carried
        local count = shedObjectCount(srcP, ft)
        if count <= 0 then return 0 end
        local perSlot = shedStoredLiters(srcP, ft) / count
        if perSlot <= 0 then return 0 end
        local slots = math.max(1, math.floor(amount / perSlot))
        local movedSlots = transferShedPallets(srcP, dstP, ft, slots)
        return movedSlots * perSlot
    end
    -- bulk source -> bulk store
    local dstStorage = SmartDistribution._bulkStorageFor(dstP, ft)
    if dstStorage == nil then return 0 end
    return transfer(farmId, srcStorage, dstStorage, ft, amount)
end

-- Best-price release for a shed: the held fill types want to wait for their peak,
-- but the shed has a single shared slot limit fed by several sources. If slots are
-- filling, free the lowest opportunity-cost-per-slot held stock first (cheap or
-- far-from-peak goes before valuable, near-peak stock), down to a small reserve.
local function shedReleaseHeld(shed, farmId, held)
    local spec = shed.spec_objectStorage
    if spec == nil then return end
    local capacity = spec.capacity or 0
    if capacity <= 0 then return end                          -- unlimited slots: never forced
    local stored  = (spec.storedObjects ~= nil and #spec.storedObjects) or (spec.numStoredObjects or 0)
    local reserve = math.max(1, math.floor(capacity * BESTPRICE_SHED_RESERVE_FRAC))
    local toFree  = reserve - (capacity - stored)
    if toFree <= 0 then return end                            -- enough headroom: hold all

    local econ = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if econ == nil or econ.getPricePerLiter == nil then return end

    local ranked = {}
    for ft in pairs(held) do
        local count = shedObjectCount(shed, ft)
        if count > 0 then
            local perSlot = shedStoredLiters(shed, ft) / count
            local now     = econ:getPricePerLiter(ft) or 0
            local opp     = (DistributionPricing ~= nil and DistributionPricing.opportunityCostPerLiter(ft, now) or 0) * perSlot
            ranked[#ranked + 1] = { ft = ft, count = count, perSlot = perSlot, opp = opp }
        end
    end
    table.sort(ranked, function(a, b) return a.opp < b.opp end)

    -- STEP 1 -- relocate before selling: push the surplus into other pallet sheds in the network that
    -- have room (same farm, supports the fill type, free slot) instead of dumping it on the market.
    -- Move the most valuable held stock first, so only the cheapest is ever left to sell.
    if shed.rootNode ~= nil then
        local sx, _, sz = getWorldTranslation(shed.rootNode)
        local reach = resolveReach(shed)
        for r = #ranked, 1, -1 do                                  -- high opportunity-cost -> low
            if toFree <= 0 then break end
            local e = ranked[r]
            local sinks = gatherShedSinks(shed, e.ft, sx, sz, farmId, reach)
            table.sort(sinks, function(a, b) return a.d2 < b.d2 end)   -- nearest shed first
            for _, sink in ipairs(sinks) do
                if toFree <= 0 or e.count <= 0 then break end
                local movedSlots = transferShedPallets(shed, sink.shed, e.ft, math.min(e.count, toFree))
                if movedSlots > 0 then
                    local movedL = movedSlots * e.perSlot
                    ledgerAdd(shed, e.ft, "stored", movedL)            -- left this shed (distributed out)
                    ledgerAdd(sink.shed, e.ft, "received", movedL)     -- arrived at the other shed
                    SmartDistribution.recordFeed(sink.shed, e.ft, shed, movedL)   -- link status: shed -> shed
                    e.count = e.count - movedSlots
                    toFree  = toFree  - movedSlots
                    log("shed relocate: moved %d slot(s) %s : %s -> %s (kept for peak, no sale)",
                        movedSlots, fillTypeName(e.ft), placeableName(shed), placeableName(sink.shed))
                end
            end
        end
    end
    if toFree <= 0 then return end                                  -- fully relocated; nothing to sell

    -- STEP 2 -- sell only what could not be relocated, cheapest (lowest opportunity cost) first.
    for _, e in ipairs(ranked) do
        if toFree <= 0 then break end
        local count = shedObjectCount(shed, e.ft)                   -- refresh: relocation changed counts
        if count > 0 then
            local slots = math.min(count, toFree)
            local sold  = sellShedLiters(shed, e.ft, slots * e.perSlot + 0.5, farmId)
            if sold > 0 then
                local freed = math.max(1, math.floor(sold / e.perSlot + 0.0001))
                toFree = toFree - freed
                log("best-price shed release: %s freed ~%d slot(s) to keep room (opp/slot %.2f)",
                    fillTypeName(e.ft), freed, e.opp)
            end
        end
    end
end

-- phase 1e: pallet-spawner remainders after the phase-1 distribute pass.  SELL / DISTRIBUTE_SELL
-- sell whatever pallets are left; DISTRIBUTE_STORE stores the remainder; plain DISTRIBUTE holds
-- it.  (Distribution itself happens in gatherSources / phase 1.)

-- sell all of an asset's `ft` pallets at market price (caller gates on mode + sellEnabled)
local function sellPalletAmount(p, ft, farmId, cap)
    local level = palletFillLevel(p, ft)
    if cap ~= nil and cap < level then level = cap end
    if level <= 0 then return end
    local econ = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if econ == nil or econ.getPricePerLiter == nil then return end
    local price = econ:getPricePerLiter(ft) or 0
    if price <= 0 then return end
    if SmartDistribution.dryRun then
        log("[dry-run] would sell %d %s (pallets) for %d", level, fillTypeName(ft), level * price)
        return
    end
    local drained = drainPallets(p, ft, level, farmId)
    if drained > 0 then
        ledgerAdd(p, ft, "sold", drained)
        ledgerAdd(p, ft, "money", drained * price)
        local mt = MoneyType ~= nil and (MoneyType.SOLD_PRODUCTS or MoneyType.OTHER) or nil
        applyMoney(drained * price, farmId, mt)   -- batched across sleep, settled at wake
        log("sold %d %s (pallets) for %d  [%s]", drained, fillTypeName(ft), drained * price, placeableName(p))
    end
end

-- per-spawner best-price tracker: peak liters seen (the spawn-area ceiling, learned),
-- last liters, and a smoothed inflow rate. Stored in S.inflow (spawners and silos never
-- share a uid). Not persisted.
local function palletWatch(uid, ft)
    local byFt = S.inflow[uid]
    if byFt == nil then byFt = {}; S.inflow[uid] = byFt end
    local rec = byFt[ft]
    if rec == nil then rec = { last = 0, rate = 0, peak = 0 }; byFt[ft] = rec end
    return rec
end

-- Best-price for a husbandry / beehive pallet spawner (one fill type): hold the
-- pallets for their seasonal peak, but if the spawn area has filled -- pallet liters
-- plateaued at their learned high-water and stopped rising -- sell ~one cycle's worth
-- so the spawner keeps producing. A plateau BELOW the high-water is just paused
-- production (no animals / no feed), not a full area, and simply holds.
local function palletHoldOrRelease(p, ft, farmId)
    local uid = getUid(p)
    local cur = palletFillLevel(p, ft)
    if cur <= 0 then return end
    local rec = palletWatch(uid, ft)
    if rec.peak <= 0 then rec.last = cur; rec.peak = cur; return end   -- first sighting: seed and hold
    local rise = cur - rec.last
    if rise > 1.0 then
        rec.rate = (rec.rate > 0) and (rec.rate * 0.6 + rise * 0.4) or rise
        rec.flat = 0
    else
        rec.flat = (rec.flat or 0) + 1                                 -- count consecutive non-rising cycles
    end
    if cur > rec.peak then rec.peak = cur end
    local full = cur >= rec.peak - 1.0 and (rec.flat or 0) >= 2        -- at the ceiling AND flat 2+ cycles
    rec.last = cur
    if not full then return end                                       -- room to grow / paused: hold
    local release = rec.rate
    if release <= 0 then
        local n = #husbandryPalletObjects(p, ft)
        release = (n > 0) and (cur / n) or cur                        -- ~one pallet's worth
    end
    if release > cur then release = cur end
    sellPalletAmount(p, ft, farmId, release)                          -- sell only enough to free room
    rec.last = palletFillLevel(p, ft)                                 -- resync after the sale
    rec.flat = 0                                                      -- require fresh evidence before the next release
    log("best-price pallet release: %s sold ~%d to keep %s producing", fillTypeName(ft), release, placeableName(p))
end

-- a pallet is "completely full" when it has no free capacity left for ft.  The shed only takes
-- whole FULL pallets, so the coop's actively-filling pallet is left alone to keep filling.
local function palletIsFull(pallet, idx, ft)
    if pallet.getFillUnitFreeCapacity ~= nil then
        return (pallet:getFillUnitFreeCapacity(idx, ft) or 0) <= 0.0001
    end
    local lvl = (pallet.getFillUnitFillLevel ~= nil and pallet:getFillUnitFillLevel(idx)) or 0
    local cap = (pallet.getFillUnitCapacity ~= nil and pallet:getFillUnitCapacity(idx)) or nil
    return cap ~= nil and lvl > 0 and lvl >= cap - 0.0001
end

-- liters held in COMPLETELY FULL `ft` pallets (what a shed will accept this hour)
local function fullPalletLiters(coop, ft)
    if not isPalletSpawnerAsset(coop) then return 0 end
    local total = 0
    for _, pallet in ipairs(husbandryPalletObjects(coop, ft)) do
        local idx = (pallet.spec_pallet ~= nil and pallet.spec_pallet.fillUnitIndex) or 1
        if palletIsFull(pallet, idx, ft) then
            total = total + ((pallet.getFillUnitFillLevel ~= nil and pallet:getFillUnitFillLevel(idx)) or 0)
        end
    end
    return total
end

-- pallet Distribute+Store -- two kinds of destination, nearest-first across both: bulk storages
-- (silos / standalone manure pits) get pallet liters DRAINED into them; Pallet Storage Sheds
-- (object storage) get whole pallets MOVED into them (so they visibly hold the pallets).

-- move the coop's `ft` pallets (whole objects) into a Pallet Storage Shed; returns liters moved.
-- addObjectToObjectStorage despawns each real pallet and stores it abstractly (the shed then
-- shows the pallets), bounded by the shed's free object slots.
local function depositPalletsToShed(coop, ft, shed, maxSlots)
    local spec = coop.spec_husbandryPallets   -- nil for a beehive spawner (loose pallets, nothing to prune)
    local oss = shed.spec_objectStorage
    if not isPalletSpawnerAsset(coop) or oss == nil or shed.addObjectToObjectStorage == nil then
        return 0
    end
    local toMove = {}
    for _, pallet in ipairs(husbandryPalletObjects(coop, ft)) do
        local idx = (pallet.spec_pallet ~= nil and pallet.spec_pallet.fillUnitIndex) or 1
        local lvl = (pallet.getFillUnitFillLevel ~= nil and pallet:getFillUnitFillLevel(idx)) or 0
        if lvl > 0 and palletIsFull(pallet, idx, ft) then toMove[#toMove + 1] = { pallet = pallet, lvl = lvl } end
    end
    local moved, slotsUsed = 0, 0
    for _, e in ipairs(toMove) do
        local cap = oss.capacity or 0
        local stored = (oss.storedObjects ~= nil and #oss.storedObjects) or (oss.numStoredObjects or 0)
        if cap > 0 and stored >= cap then break end
        if maxSlots ~= nil and slotsUsed >= maxSlots then break end   -- per-product cap (receiver-side)
        local can = true
        if shed.getObjectStorageCanStoreObject ~= nil then can = shed:getObjectStorageCanStoreObject(e.pallet) end
        if can then
            shed:addObjectToObjectStorage(e.pallet)   -- despawns the pallet + stores it abstractly
            if spec ~= nil and type(spec.pallets) == "table" then spec.pallets[e.pallet] = nil end  -- defensive (trigger also clears on delete)
            moved = moved + e.lvl
            slotsUsed = slotsUsed + 1
        end
    end
    -- mirror the game's store path: schedule the shed's count / visual-pallet / dirty-flag refresh.
    -- setObjectStorageObjectInfosDirty() sets the update timer + raiseActive, so the shed's own
    -- update() then runs updateObjectStorageObjectInfos + updateObjectStorageVisualAreas +
    -- raiseDirtyFlags. Without it the objects sit invisibly in storedObjects and never save/sync.
    if moved > 0 and shed.setObjectStorageObjectInfosDirty ~= nil then
        shed:setObjectStorageObjectInfosDirty()
    end
    return moved
end

local function storePalletAmount(p, ft, farmId, bill)
    if p.rootNode == nil then return end
    local level = palletFillLevel(p, ft)
    if level <= 0 then return end
    local x, _, z = getWorldTranslation(p.rootNode)
    local reach = resolveReach(p)
    local sinks = gatherSinks(p, ft, x, z, farmId, reach)                  -- bulk storages (silos / pits)
    for _, sh in ipairs(gatherShedSinks(p, ft, x, z, farmId, reach)) do    -- + pallet sheds (object storage)
        sinks[#sinks + 1] = sh
    end
    table.sort(sinks, function(a, b) return a.d2 < b.d2 end)              -- nearest first across both kinds
    local remaining = level
    for _, sink in ipairs(sinks) do
        if remaining <= 0 then break end
        local room = SmartDistribution.inputAcceptableLiters(sink.placeable, ft)   -- receiver-side block / max %
        if sink.shed ~= nil then
            -- Pallet Storage Shed: move whole FULL pallets (object storage), not liters
            local perSlot = SmartDistribution._shedLitresPerSlot(sink.placeable) or 1
            local slotCap = math.floor(room / math.max(1, perSlot))
            if SmartDistribution.dryRun then
                local would = math.min(remaining, fullPalletLiters(p, ft), room)
                if would > 0 then
                    log("[dry-run] would store %d %s (full pallets) : %s -> %s [shed]", would, fillTypeName(ft), placeableName(p), placeableName(sink.placeable))
                    recordBill(bill, farmId, p, sink.placeable, sink.d2)
                    remaining = remaining - would
                end
            elseif slotCap >= 1 then
                local moved = depositPalletsToShed(p, ft, sink.shed, slotCap)
                if moved > 0 then
                    ledgerAdd(p, ft, "stored", moved)
                    recordBill(bill, farmId, p, sink.placeable, sink.d2)
                    log("stored %d %s (pallets) : %s -> %s [shed]", moved, fillTypeName(ft), placeableName(p), placeableName(sink.placeable))
                    remaining = remaining - moved
                end
            end
        else
            local want = math.min(remaining, getFree(sink.storage, ft), room)
            if want > 0 then
                if SmartDistribution.dryRun then
                    log("[dry-run] would store %d %s (pallets) : %s -> %s", want, fillTypeName(ft), placeableName(p), placeableName(sink.placeable))
                    recordBill(bill, farmId, p, sink.placeable, sink.d2)
                    remaining = remaining - want
                else
                    local drained = drainPallets(p, ft, want, farmId)
                    if drained > 0 then
                        setLevel(sink.storage, ft, getLevel(sink.storage, ft) + drained, farmId, drained)
                        ledgerAdd(p, ft, "stored", drained)
                        recordBill(bill, farmId, p, sink.placeable, sink.d2)
                        log("stored %d %s (pallets) : %s -> %s", drained, fillTypeName(ft), placeableName(p), placeableName(sink.placeable))
                        remaining = remaining - drained
                    end
                end
            end
        end
    end
end

-- Store To for palletized outputs (production pallet outputs, coop eggs/wool, beehive honey). Same
-- delivery as storePalletAmount, but restricted to the player's chosen targets (ranked, else nearest);
-- with none chosen it falls back to the auto-hunt storePalletAmount. Sets the target-full UI flag when
-- stock remains but no chosen target could take it.
function SmartDistribution._storeToPalletAmount(p, ft, farmId, bill)
    if p.rootNode == nil then return end
    local srcUid = getUid(p)
    if srcUid == nil then return end
    local level = palletFillLevel(p, ft)
    if level <= 0 then SmartDistribution.setStoreTargetFull(srcUid, ft, false); return end
    local x, _, z = getWorldTranslation(p.rootNode)
    local reach = resolveReach(p)
    local myFarm = SmartDistribution._ownerFarmId(p)

    -- Default-ON: all candidate sinks (bulk + shed) for this pallet output, MINUS blocked, ordered by
    -- rank then nearest-first.
    local cands = {}
    for _, si in ipairs(gatherSinks(p, ft, x, z, farmId, reach)) do cands[#cands+1] = si end
    for _, sh in ipairs(gatherShedSinks(p, ft, x, z, farmId, reach)) do cands[#cands+1] = sh end
    local ordered = {}
    for _, si in ipairs(cands) do
        local du = si.placeable ~= nil and getUid(si.placeable) or nil
        if du ~= nil and SmartDistribution._ownerFarmId(si.placeable) == myFarm
           and not SmartDistribution.isDestBlocked(srcUid, ft, du) then
            si.rank = SmartDistribution.destRank(srcUid, ft, du)
            ordered[#ordered + 1] = si
        end
    end
    if #ordered == 0 then SmartDistribution.setStoreTargetFull(srcUid, ft, true); return end
    table.sort(ordered, function(a, b)
        if (a.rank ~= nil) ~= (b.rank ~= nil) then return a.rank ~= nil end
        if a.rank ~= nil and b.rank ~= nil and a.rank ~= b.rank then return a.rank < b.rank end
        return a.d2 < b.d2
    end)

    local remaining, movedAny = level, false
    for _, sink in ipairs(ordered) do
        if remaining <= 0 then break end
        local room = SmartDistribution.inputAcceptableLiters(sink.placeable, ft)   -- receiver-side block / max %
        if sink.shed ~= nil then
            local perSlot = SmartDistribution._shedLitresPerSlot(sink.placeable) or 1
            local slotCap = math.floor(room / math.max(1, perSlot))   -- how many slots the cap still allows
            if slotCap >= 1 then   -- room for at least one slot
                local moved = depositPalletsToShed(p, ft, sink.shed, slotCap)
                if moved > 0 then
                    movedAny = true
                    ledgerAdd(p, ft, "stored", moved)
                    ledgerAdd(sink.placeable, ft, "received", moved)
                    recordBill(bill, farmId, p, sink.placeable, sink.d2)
                    SmartDistribution.recordFeed(sink.placeable, ft, p, moved)
                    log("storedTo %d %s (pallets) : %s -> %s#%s [shed]", moved, fillTypeName(ft), placeableName(p), placeableName(sink.placeable), tostring(getUid(sink.placeable)))
                    remaining = remaining - moved
                end
            end
        else
            local want = math.min(remaining, getFree(sink.storage, ft), room)
            if want > 0 then
                local drained = drainPallets(p, ft, want, farmId)
                if drained > 0 then
                    movedAny = true
                    setLevel(sink.storage, ft, getLevel(sink.storage, ft) + drained, farmId, drained)
                    ledgerAdd(p, ft, "stored", drained)
                    ledgerAdd(sink.placeable, ft, "received", drained)
                    recordBill(bill, farmId, p, sink.placeable, sink.d2)
                    SmartDistribution.recordFeed(sink.placeable, ft, p, drained)
                    log("storedTo %d %s (pallets) : %s -> %s", drained, fillTypeName(ft), placeableName(p), placeableName(sink.placeable))
                    remaining = remaining - drained
                end
            end
        end
    end
    SmartDistribution.setStoreTargetFull(srcUid, ft, (not movedAny) and remaining > 0)
end

local function palletPhase(manager, bill)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    for _, p in ipairs(ps.placeables) do
        local fts = palletSpawnerFillTypes(p)   -- coops/sheep (eggs/wool) + beehives (honey) + production pallet outputs
        if fts ~= nil and isEnrolled(p) then
            local farmId = (p.getOwnerFarmId ~= nil and p:getOwnerFarmId()) or p.ownerFarmId
            local isProd = getProductionPoint(p) ~= nil
            for _, ft in ipairs(fts) do
                if not S.global.excludedFillTypes[ft] then
                    local m = resolveMode(p, ft)
                    if m == MODE.DISTRIBUTE_STORE or m == MODE.STORE then
                        -- Store / Dist+Store: auto-hunt all compatible stores, minus blocked, ranked
                        -- (else nearest). _storeToPalletAmount handles all of that.
                        SmartDistribution._storeToPalletAmount(p, ft, farmId, bill)
                    elseif (m == MODE.SELL or m == MODE.DISTRIBUTE_SELL) and not isProd then
                        -- SELL: sell all.  DISTRIBUTE_SELL: phase 1 already distributed to
                        -- consumers; sell whatever pallets remain.  Production pallet outputs in
                        -- Sell / Distribute+Sell are left to the production's own direct-sell path.
                        if S.global.sellEnabled then
                            if SmartDistribution.resolveBestPrice(p, ft, m)
                               and DistributionPricing ~= nil and not DistributionPricing.isPeakNow(ft) then
                                palletHoldOrRelease(p, ft, farmId)   -- hold for peak; release if the spawn area fills
                            else
                                sellPalletAmount(p, ft, farmId)      -- immediate / peak / flat
                            end
                        end
                    end
                    -- plain DISTRIBUTE: phase 1 distributed the demand; hold any remainder
                end
            end
        end
    end
end

-- phase 1f: shed (object storage) sell remainders.  SELL sells everything; DISTRIBUTE_SELL sells
-- whatever consumers did not pull in phase 1.  DISTRIBUTE / HOLD release-or-hold via gatherSources;
-- a shed never stores-into-another-store, so DISTRIBUTE_STORE doesn't apply here.
local function shedPhase(manager)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    for _, p in ipairs(ps.placeables) do
        if p.spec_objectStorage ~= nil and isEnrolled(p) then
            local farmId = (p.getOwnerFarmId ~= nil and p:getOwnerFarmId()) or p.ownerFarmId
            local fts = shedStoredFillTypes(p)
            local held = nil
            for ft in pairs(fts) do
                if not S.global.excludedFillTypes[ft] then
                    local m = resolveMode(p, ft)
                    if (m == MODE.SELL or m == MODE.DISTRIBUTE_SELL) and S.global.sellEnabled then
                        if SmartDistribution.resolveBestPrice(p, ft, m)
                           and DistributionPricing ~= nil and not DistributionPricing.isPeakNow(ft) then
                            held = held or {}
                            held[ft] = true                  -- hold for peak (subject to the slot fallback)
                        else
                            sellShedAmount(p, ft, farmId)    -- immediate / peak / flat: sell now
                        end
                    end
                end
            end
            if held ~= nil then shedReleaseHeld(p, farmId, held) end
        end
    end
end

-- ---- the hourly pass -------------------------------------------------------
-- ============================================================================
-- HARVEST-MONTH LEARNER
-- Between hourly cycles only EXTERNAL events change storage levels (the mod acts
-- only inside runHourly). So a large unexplained rise in a crop's farm-wide held,
-- measured from the end of last cycle to the start of this one, is a harvest --
-- and the current month is recorded as part of that crop's window. Farm-wide
-- aggregation cancels silo-to-silo moves, avoiding false positives. Server-side;
-- runs whenever growth is on, independent of whether the reserve is enabled.
-- ============================================================================

-- farm-wide held per crop fill type, one pass over non-production storages
local function scanCropHeld()
    local out = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil or type(ps.placeables) ~= "table" then return out end
    for _, p in ipairs(ps.placeables) do
        if getProductionPoint(p) == nil then
            for _, storage in ipairs(getAllStorages(p)) do
                for ft in pairs(storageFillTypes(storage)) do
                    if SmartDistribution.isCropFillType(ft) then
                        out[ft] = (out[ft] or 0) + getLevel(storage, ft)
                    end
                end
            end
        end
    end
    return out
end

local lastCropLevels = nil   -- crop ft -> farm-wide held at the END of the previous cycle

-- add a month to a crop's harvest window (dedup, kept sorted). Returns true if new.
local function recordHarvestMonth(ft, month)
    if S.harvestMonths == nil then S.harvestMonths = {} end
    local list = S.harvestMonths[ft]
    if list == nil then list = {}; S.harvestMonths[ft] = list end
    for _, m in ipairs(list) do if m == month then return false end end
    list[#list + 1] = month
    table.sort(list)
    return true
end

-- START of cycle: compare current crop held vs end-of-last-cycle; flag harvests.
local function detectHarvests()
    if SmartDistribution.growthEnabled ~= nil and not SmartDistribution.growthEnabled() then return end
    if lastCropLevels == nil then return end          -- first cycle: nothing to compare yet
    local now = SmartDistribution.currentMonth()
    if now == nil then return end
    local minInflow = S.global.seasonalHarvestMinInflow or 5000
    local cur = scanCropHeld()
    for ft, level in pairs(cur) do
        if level - (lastCropLevels[ft] or 0) >= minInflow then
            if recordHarvestMonth(ft, now) then
                log("learned harvest: %s month %d  window now {%s}",
                    fillTypeName(ft), now, table.concat(S.harvestMonths[ft] or {}, ","))
            end
        end
    end
end

-- END of cycle: remember post-cycle crop levels for next comparison.
local function snapshotCropLevels()
    lastCropLevels = scanCropHeld()
end

-- ---- self-healing: a mode whose endpoint disappears reverts to the default (Hold) -----------------
-- Endpoints are live: demolish the only market that takes a product and any building still set to a
-- market mode would be stranded on a mode that can never do anything. Each pass we sweep the network and
-- revert those to the default HOLD (which the menu shows as "Hold Pallets" where the asset spawns
-- pallets, and a plain internal hold where it does not). Server-side; applyAssetMode syncs + persists.
function SmartDistribution.enforceValidModes()
    if not S.master or g_currentMission == nil or g_currentMission.placeableSystem == nil then return end
    for _, p in ipairs(g_currentMission.placeableSystem.placeables) do
        if p.rootNode ~= nil and isEnrolled(p) then
            local pp = getProductionPoint(p)
            -- assetMenuFillTypes returns a SET, not an array: ipairs would iterate NOTHING and this
            -- whole self-heal would silently never run.
            for ft in pairs(SmartDistribution.assetMenuFillTypes(p) or {}) do
                local cur = SmartDistribution.resolvedAssetMode(p, ft)
                if cur ~= nil and not SmartDistribution.modeHasEndpoint(p, ft, cur) then
                    if pp ~= nil and SmartDistribution.setProductionOutputMode ~= nil then
                        SmartDistribution.setProductionOutputMode(pp, ft, 0)   -- production virtual KEEP (= Hold)
                    else
                        SmartDistribution.applyAssetMode(p, ft, MODE.HOLD)
                    end
                    log("%s [%s]: %s has no endpoint any more -> reverted to Hold",
                        placeableName(p), fillTypeName(ft), SmartDistribution.modeName(cur))
                end
            end
        end
    end
end

function SmartDistribution.runHourly(manager)
    if not S.master then return end
    resetCycleMoney()                                         -- open this hour's money tally (flushed at the END of this tick, after the appended surplus-sell pass)
    SmartDistribution.enforceValidModes()                      -- drop any mode whose endpoint has gone away
    SmartDistribution.beginFeedPass()                          -- start a fresh feed log; the UI reads the previous (complete) one
    detectHarvests()                                          -- learn crop harvest months (pre-phase levels)
    cycleAcc = {}                                              -- begin per-cycle accounting
    SmartDistribution.observeHusbandryProduction()            -- record husbandry output produced since last cycle (pre-drain)
    local bill = {}
    local slots = {}
    for _, farmTable in pairs(manager.farmIds or {}) do        -- phases 1 + 1b + 1c: unified allocation
        collectProductionSlots(farmTable.productionPoints, slots)
    end
    collectFoodSlots(slots)
    SmartDistribution.collectRobotFeedSlots(slots)             -- feeding-robot ingredient bunkers
    collectStrawSlots(slots)
    collectHusbandryWaterSlots(slots)
    allocate(slots, bill)
    storePhase(manager, bill)                                  -- phase 1d: push Distribute+Store remainders to storage
    palletPhase(manager, bill)                                 -- phase 1e: pallet-spawner outputs (eggs/wool/honey)
    shedPhase(manager)                                         -- phase 1f: shed (object storage) SELL / DISTRIBUTE_SELL remainders
    chargeDistribution(bill)                                   -- phase 1.5: distance-based billing
    if S.global.sellEnabled then                               -- phase 2
        sellPhase(manager)
    end
    SmartDistribution.marketTransferPhase(manager)             -- phase 2c: route "Transfer to My Market" surplus into market buffers
    if S.global.sellEnabled then
        SmartDistribution.marketSellPhase(manager)             -- phase 2d: markets sell their buffers (native price + 20% bonus)
    end
    sellDirectProduction(manager)                              -- phase 2b: plant sellDirectly outputs (biogas electric/methane)
    SmartDistribution.commitHusbandryProduction()             -- baseline husbandry output levels for next cycle's produced calc
    SmartDistribution.recordProductionThroughput(cycleAcc)    -- production consumed/produced this cycle (delta + this cycle's flows, aligned windows)
    SmartDistribution.recordHusbandryConsumption(cycleAcc)    -- husbandry feed/water/straw consumed this cycle
    S.lastCycle = cycleAcc                                     -- publish this cycle's tallies for the asset dialog
    monthlyRing[(monthlyPos % MONTHLY_CYCLES) + 1] = cycleAcc  -- roll the 24-cycle "monthly" window (persisted)
    monthlyPos = (monthlyPos + 1) % MONTHLY_CYCLES
    cycleAcc = nil
    if DistributionStatsEvent ~= nil and DistributionStatsEvent.broadcast ~= nil then
        DistributionStatsEvent.broadcast()                    -- MP: push the rolling /mo aggregate to clients
    end
    snapshotCropLevels()                                      -- remember post-cycle crop levels for harvest detection
    -- Money summary: when the ProductionDistributeSell add-on is loaded it sells the output surplus in an
    -- appended pass right after this one (same hourly tick) and flushes the summary at the end of THAT
    -- pass, so its sales fold into the same number. With the add-on absent, nothing sells after this
    -- point, so emit the summary here and now -- still the same tick the money was applied.
    SmartDistribution.flushCycleSummary()                         -- accumulate this cycle; the settled emit fires from the update frame
end

-- ---- hook ------------------------------------------------------------------
function SmartDistribution.onHourChanged(manager, superFunc, ...)
    if g_currentMission ~= nil and not g_currentMission:getIsServer() then
        return superFunc(manager, ...)                         -- clients defer
    end
    if not S.master then
        return superFunc(manager, ...)                         -- inert: vanilla pass runs
    end
    -- detect sleep / fast-forward: hourly ticks arriving within a few REAL seconds of each other.
    -- getTimeSec() is REAL wall-clock (the engine uses it for network/UI timeouts); g_time is GAME
    -- time and ACCELERATES during sleep, so it must NOT be used for this.
    local nowSec = (getTimeSec ~= nil) and getTimeSec() or nil
    local lastSec = SmartDistribution._lastHourSec
    if nowSec ~= nil and lastSec ~= nil then
        local gap = nowSec - lastSec
        if SmartDistribution._fastForward then
            SmartDistribution._fastForward = gap < (FAST_FORWARD_GAP_SEC * 2)   -- hysteresis: stay asleep through brief stalls
        else
            SmartDistribution._fastForward = gap < FAST_FORWARD_GAP_SEC
        end
    else
        SmartDistribution._fastForward = false
    end
    SmartDistribution._lastHourSec = nowSec

    -- Safety: if a previously deferred pass has not run yet (e.g. two hour ticks
    -- arrive before an update frame), flush it now so we never drop an hour.
    if SmartDistribution._pendingHourly ~= nil then
        local pm = SmartDistribution._pendingHourly
        SmartDistribution._pendingHourly = nil
        SmartDistribution._pendingHourlyWait = nil
        local okp, errp = pcall(SmartDistribution.runHourly, pm)
        if not okp and Logging ~= nil then
            Logging.error("[SmartDistribution] deferred hourly pass failed: %s", tostring(errp))
        end
    end

    if SmartDistribution._fastForward then
        -- Sleep / fast-forward: run SYNCHRONOUSLY so each skipped hour bills exactly one
        -- haul. (A producer's fresh batch for this hour lands just after, and is picked up
        -- by the next pass -- so at most one batch trails the end of a skip, cleared next hour.)
        local ok, err = pcall(SmartDistribution.runHourly, manager)
        if not ok and Logging ~= nil then
            Logging.error("[SmartDistribution] hourly pass failed: %s", tostring(err))
        end
    else
        -- Normal play: DEFER the pass to a later update tick, after the engine has finished
        -- this hour's change processing -- producers deposit their hour batch in a hour-change
        -- listener that runs AFTER ours, so storing then empties the source the instant the
        -- batch appears instead of a full hour later. proximityWatcher:update runs it.
        SmartDistribution._pendingHourly = manager
        SmartDistribution._pendingHourlyWait = 1   -- skip one update so frame-N hour processing (incl. the deposit) completes first
    end
    -- master on: suppress the vanilla distribution + sell pass
end

local function install()
    if ProductionChainManager == nil or ProductionChainManager.hourChanged == nil then
        if Logging ~= nil then
            Logging.error("[SmartDistribution] ProductionChainManager.hourChanged not found.")
        end
        return
    end
    ProductionChainManager.hourChanged =
        Utils.overwrittenFunction(ProductionChainManager.hourChanged, SmartDistribution.onHourChanged)
    log("installed (preset=%s participation=%d reach=%d radius=%d bufferHours=%d)",
        PRESET, S.global.participation, S.global.reach, S.global.radius, S.global.bufferHours)
end

-- ============================================================================
-- PERSISTENCE  (per-asset L4 overrides only; server-side; per-savegame)
-- Stored in a small XML file in the savegame folder, keyed by placeable.uniqueId
-- (engine-managed, stable across save/load) and by fill-type NAME (stable across
-- fill-type index shifts). Global settings are NOT persisted here yet - they stay
-- driven by the config at the top of this file until the settings screen lands.
-- Mechanics (XML calls, save hook) mirror proven reference mods; identity and
-- scoping are fixed (uniqueId, not node; savegame folder, not global modSettings).
-- ============================================================================
local PERSIST_VERSION = 1

local function getSaveDir()
    local mi = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if mi == nil then return nil end
    if mi.savegameDirectory ~= nil and mi.savegameDirectory ~= "" then  -- [VERIFY] field
        return mi.savegameDirectory .. "/"
    end
    if mi.savegameIndex ~= nil and getUserProfileAppPath ~= nil then     -- fallback
        return getUserProfileAppPath() .. "savegame" .. tostring(mi.savegameIndex) .. "/"
    end
    return nil
end

local function saveOverrides(missionInfo)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    -- FS25 fires FSCareerMissionInfo:saveToXMLFile(missionInfo) on every game save; prefer the
    -- savegame dir it hands us (gated on isValid), else fall back to g_currentMission.missionInfo.
    local mi = missionInfo or (g_currentMission ~= nil and g_currentMission.missionInfo) or nil
    if mi ~= nil and mi.isValid == false then
        print("[SmartDistribution persist] SAVE skipped: missionInfo.isValid == false")
        return
    end
    local dir = (mi ~= nil and mi.savegameDirectory ~= nil and mi.savegameDirectory ~= "")
        and (mi.savegameDirectory .. "/") or getSaveDir()
    print(string.format("[SmartDistribution persist] SAVE fired: dir=%s  mi.savegameDirectory=%s",
        tostring(dir), tostring(mi ~= nil and mi.savegameDirectory or "nil")))
    if dir == nil then print("[SmartDistribution persist] SAVE skipped: savegame directory unresolved") return end
    local path = dir .. "smartDistribution.xml"
    local xml = createXMLFile("SmartDistributionXML", path, "smartDistribution")
    if xml == nil or xml == 0 then print(string.format("[SmartDistribution persist] SAVE FAILED: createXMLFile(%s)", tostring(path))) return end
    setXMLInt(xml, "smartDistribution#version", PERSIST_VERSION)
    local i = 0
    for uid, fts in pairs(S.assets) do
        for ft, mode in pairs(fts) do
            if mode ~= nil and mode ~= MODE.INHERIT then
                local k = string.format("smartDistribution.asset(%d)", i)
                setXMLString(xml, k .. "#uniqueId", tostring(uid))
                setXMLString(xml, k .. "#fillType", fillTypeName(ft))
                setXMLInt(xml,    k .. "#mode",     mode)
                i = i + 1
            end
        end
    end
    -- per-asset sell-timing overrides (best price vs immediate)
    local t = 0
    for uid, fts in pairs(S.sellTiming) do
        for ft, value in pairs(fts) do
            if value ~= nil then
                local k = string.format("smartDistribution.timing(%d)", t)
                setXMLString(xml, k .. "#uniqueId",  tostring(uid))
                setXMLString(xml, k .. "#fillType",  fillTypeName(ft))
                setXMLBool(xml,   k .. "#bestPrice", value and true or false)
                t = t + 1
            end
        end
    end
    -- market virtual buffers (uid -> ft -> litres) + per-market sell timing (best price)
    local mb = 0
    for uid, byFt in pairs(SmartDistribution._marketBuffer) do
        for ft, litres in pairs(byFt) do
            if type(litres) == "number" and litres > 0 then
                local k = string.format("smartDistribution.marketBuf(%d)", mb)
                setXMLString(xml, k .. "#uniqueId", tostring(uid))
                setXMLString(xml, k .. "#fillType", fillTypeName(ft))
                setXMLFloat(xml,  k .. "#litres",   litres)
                mb = mb + 1
            end
        end
    end
    local mtc = 0
    for uid, byFt in pairs(SmartDistribution._marketTiming) do
        for ft, mode in pairs(byFt) do
            if mode ~= nil and mode ~= 0 then
                local k = string.format("smartDistribution.marketTiming(%d)", mtc)
                setXMLString(xml, k .. "#uniqueId", tostring(uid))
                setXMLString(xml, k .. "#fillType", fillTypeName(ft))
                setXMLInt(xml,    k .. "#sellMode", mode)
                mtc = mtc + 1
            end
        end
    end
    -- learned harvest windows per crop (seasonal reserve)
    local j = 0
    for ft, months in pairs(S.harvestMonths or {}) do
        if type(months) == "table" and #months > 0 then
            local k = string.format("smartDistribution.crop(%d)", j)
            setXMLString(xml, k .. "#fillType",      fillTypeName(ft))
            setXMLString(xml, k .. "#harvestMonths", table.concat(months, ","))
            j = j + 1
        end
    end
    -- distribution control: output->destination blocks + destination priority (source-keyed, DR-owned)
    local bi = 0
    for srcUid, byFt in pairs(SmartDistribution.control.blocked or {}) do
        for ft, dests in pairs(byFt) do
            for destUid in pairs(dests) do
                local k = string.format("smartDistribution.block(%d)", bi)
                setXMLString(xml, k .. "#source",   tostring(srcUid))
                setXMLString(xml, k .. "#fillType", fillTypeName(ft))
                setXMLString(xml, k .. "#dest",     tostring(destUid))
                bi = bi + 1
            end
        end
    end
    local pi = 0
    for srcUid, byFt in pairs(SmartDistribution.control.priority or {}) do
        for ft, list in pairs(byFt) do
            if type(list) == "table" and #list > 0 then
                local k = string.format("smartDistribution.priority(%d)", pi)
                setXMLString(xml, k .. "#source",   tostring(srcUid))
                setXMLString(xml, k .. "#fillType", fillTypeName(ft))
                setXMLString(xml, k .. "#dests",    table.concat(list, ","))
                pi = pi + 1
            end
        end
    end
    -- receiver-side input control: per-building block + max %% per product
    local ibi = 0
    for rcvUid, byFt in pairs(SmartDistribution.control.inputBlock or {}) do
        for ft, on in pairs(byFt) do
            if on then
                local k = string.format("smartDistribution.inputBlock(%d)", ibi)
                setXMLString(xml, k .. "#receiver", tostring(rcvUid))
                setXMLString(xml, k .. "#fillType", fillTypeName(ft))
                ibi = ibi + 1
            end
        end
    end
    local ici = 0
    for rcvUid, byFt in pairs(SmartDistribution.control.inputCapPct or {}) do
        for ft, pct in pairs(byFt) do
            if type(pct) == "number" then
                local k = string.format("smartDistribution.inputCap(%d)", ici)
                setXMLString(xml, k .. "#receiver", tostring(rcvUid))
                setXMLString(xml, k .. "#fillType", fillTypeName(ft))
                setXMLInt(xml,    k .. "#pct",      pct)
                ici = ici + 1
            end
        end
    end
    local iti = 0
    for rcvUid, byFt in pairs(SmartDistribution.control.inputTarget or {}) do
        for ft, pct in pairs(byFt) do
            if type(pct) == "number" then
                local k = string.format("smartDistribution.inputTarget(%d)", iti)
                setXMLString(xml, k .. "#receiver", tostring(rcvUid))
                setXMLString(xml, k .. "#fillType", fillTypeName(ft))
                setXMLInt(xml,    k .. "#pct",      pct)
                iti = iti + 1
            end
        end
    end
    -- rolling 24-cycle "monthly" transaction window (dist/sold/stored/received per asset+ft)
    setXMLInt(xml, "smartDistribution.monthly#pos", monthlyPos)
    local ci = 0
    for slot = 1, MONTHLY_CYCLES do
        local snap = monthlyRing[slot]
        if type(snap) == "table" and next(snap) ~= nil then
            local ck = string.format("smartDistribution.monthly.cycle(%d)", ci)
            setXMLInt(xml, ck .. "#slot", slot)
            local ei = 0
            for uid, byFt in pairs(snap) do
                for ft, e in pairs(byFt) do
                    if type(e) == "table" then
                        local ek = string.format("%s.e(%d)", ck, ei)
                        setXMLString(xml, ek .. "#uniqueId", tostring(uid))
                        setXMLString(xml, ek .. "#fillType", fillTypeName(ft))
                        setXMLFloat(xml,  ek .. "#dist",     e.dist or 0)
                        setXMLFloat(xml,  ek .. "#sold",     e.sold or 0)
                        setXMLFloat(xml,  ek .. "#stored",   e.stored or 0)
                        setXMLFloat(xml,  ek .. "#received", e.received or 0)
                        setXMLFloat(xml,  ek .. "#money",    e.money or 0)
                        setXMLFloat(xml,  ek .. "#produced", e.produced or 0)
                        setXMLFloat(xml,  ek .. "#consumed", e.consumed or 0)
                        ei = ei + 1
                    end
                end
            end
            ci = ci + 1
        end
    end
    saveXMLFile(xml)
    delete(xml)
    print(string.format("[SmartDistribution persist] SAVED %d mode(s) + %d timing + %d marketBuf + %d marketTiming -> %s", i, t, mb, mtc, tostring(path)))
    log("saved %d per-asset override(s) + %d timing(s) + %d crop window(s) + %d monthly cycle(s) + %d marketBuf + %d marketTiming -> %s", i, t, j, ci, mb, mtc, path)
end

local function loadOverrides()
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local dir = getSaveDir()
    local sgd = (g_currentMission.missionInfo ~= nil) and g_currentMission.missionInfo.savegameDirectory or nil
    print(string.format("[SmartDistribution persist] LOAD fired: dir=%s  mi.savegameDirectory=%s", tostring(dir), tostring(sgd)))
    if dir == nil then print("[SmartDistribution persist] LOAD skipped: savegame directory unresolved") return end
    local path = dir .. "smartDistribution.xml"
    if not fileExists(path) then print(string.format("[SmartDistribution persist] LOAD: no file at %s (fresh save, or save wrote a different path)", tostring(path))) return end
    local xml = loadXMLFile("SmartDistributionXML", path)
    if xml == nil or xml == 0 then print(string.format("[SmartDistribution persist] LOAD FAILED: loadXMLFile(%s)", tostring(path))) return end
    local i, n = 0, 0
    while true do
        local k = string.format("smartDistribution.asset(%d)", i)
        local uid = getXMLString(xml, k .. "#uniqueId")
        if uid == nil then break end
        local ftName = getXMLString(xml, k .. "#fillType")
        local mode   = getXMLInt(xml,    k .. "#mode")
        if ftName ~= nil and mode ~= nil and g_fillTypeManager ~= nil then
            local ft = g_fillTypeManager:getFillTypeIndexByName(ftName)
            if ft ~= nil then
                S.assets[uid] = S.assets[uid] or {}
                S.assets[uid][ft] = mode
                n = n + 1
            end
        end
        i = i + 1
    end
    -- learned harvest windows per crop
    local j, c = 0, 0
    while true do
        local k = string.format("smartDistribution.crop(%d)", j)
        local ftName = getXMLString(xml, k .. "#fillType")
        if ftName == nil then break end
        local monthsStr = getXMLString(xml, k .. "#harvestMonths")
        if monthsStr ~= nil and g_fillTypeManager ~= nil then
            local ft = g_fillTypeManager:getFillTypeIndexByName(ftName)
            if ft ~= nil then
                local months = {}
                for tok in string.gmatch(monthsStr, "%d+") do months[#months + 1] = tonumber(tok) end
                if #months > 0 then S.harvestMonths[ft] = months; c = c + 1 end
            end
        end
        j = j + 1
    end
    -- distribution control: output->destination blocks + destination priority (source-keyed, DR-owned),
    -- plus receiver-side input block + max %% (must include ALL fields or later accessors index nil)
    SmartDistribution.control = { blocked = {}, priority = {}, inputBlock = {}, inputCapPct = {}, inputTarget = {} }
    local bi = 0
    while true do
        local k = string.format("smartDistribution.block(%d)", bi)
        local source = getXMLString(xml, k .. "#source")
        if source == nil then break end
        local ftName = getXMLString(xml, k .. "#fillType")
        local dest   = getXMLString(xml, k .. "#dest")
        local ft = (ftName ~= nil and g_fillTypeManager ~= nil) and g_fillTypeManager:getFillTypeIndexByName(ftName) or nil
        if ft ~= nil and dest ~= nil then
            SmartDistribution.setDestBlocked(source, ft, dest, true)
        end
        bi = bi + 1
    end
    local pi = 0
    while true do
        local k = string.format("smartDistribution.priority(%d)", pi)
        local source = getXMLString(xml, k .. "#source")
        if source == nil then break end
        local ftName = getXMLString(xml, k .. "#fillType")
        local csv    = getXMLString(xml, k .. "#dests")
        local ft = (ftName ~= nil and g_fillTypeManager ~= nil) and g_fillTypeManager:getFillTypeIndexByName(ftName) or nil
        if ft ~= nil and csv ~= nil then
            local list = {}
            for tok in string.gmatch(csv, "[^,]+") do list[#list + 1] = tok end
            if #list > 0 then
                SmartDistribution.control.priority[source] = SmartDistribution.control.priority[source] or {}
                SmartDistribution.control.priority[source][ft] = list
            end
        end
        pi = pi + 1
    end
    -- receiver-side input control: per-building block + max %% per product
    local ibi = 0
    while true do
        local k = string.format("smartDistribution.inputBlock(%d)", ibi)
        local receiver = getXMLString(xml, k .. "#receiver")
        if receiver == nil then break end
        local ftName = getXMLString(xml, k .. "#fillType")
        local ft = (ftName ~= nil and g_fillTypeManager ~= nil) and g_fillTypeManager:getFillTypeIndexByName(ftName) or nil
        if ft ~= nil then SmartDistribution.setInputBlocked(receiver, ft, true) end
        ibi = ibi + 1
    end
    local ici = 0
    while true do
        local k = string.format("smartDistribution.inputCap(%d)", ici)
        local receiver = getXMLString(xml, k .. "#receiver")
        if receiver == nil then break end
        local ftName = getXMLString(xml, k .. "#fillType")
        local pct    = getXMLInt(xml, k .. "#pct")
        local ft = (ftName ~= nil and g_fillTypeManager ~= nil) and g_fillTypeManager:getFillTypeIndexByName(ftName) or nil
        if ft ~= nil and pct ~= nil then SmartDistribution.setInputCapPct(receiver, ft, pct) end
        ici = ici + 1
    end
    local iti = 0
    while true do
        local k = string.format("smartDistribution.inputTarget(%d)", iti)
        local receiver = getXMLString(xml, k .. "#receiver")
        if receiver == nil then break end
        local ftName = getXMLString(xml, k .. "#fillType")
        local pct    = getXMLInt(xml, k .. "#pct")
        local ft = (ftName ~= nil and g_fillTypeManager ~= nil) and g_fillTypeManager:getFillTypeIndexByName(ftName) or nil
        if ft ~= nil and pct ~= nil then SmartDistribution.setInputTargetPct(receiver, ft, pct) end
        iti = iti + 1
    end
    -- per-asset sell-timing overrides
    local t, tn = 0, 0
    while true do
        local k = string.format("smartDistribution.timing(%d)", t)
        local uid = getXMLString(xml, k .. "#uniqueId")
        if uid == nil then break end
        local ftName = getXMLString(xml, k .. "#fillType")
        local value  = getXMLBool(xml,   k .. "#bestPrice")
        if ftName ~= nil and value ~= nil and g_fillTypeManager ~= nil then
            local ft = g_fillTypeManager:getFillTypeIndexByName(ftName)
            if ft ~= nil then
                S.sellTiming[uid] = S.sellTiming[uid] or {}
                S.sellTiming[uid][ft] = value
                tn = tn + 1
            end
        end
        t = t + 1
    end
    -- market virtual buffers + per-market sell timing
    local mb, mbn = 0, 0
    while true do
        local k = string.format("smartDistribution.marketBuf(%d)", mb)
        local uid = getXMLString(xml, k .. "#uniqueId")
        if uid == nil then break end
        local ftName = getXMLString(xml, k .. "#fillType")
        local litres = getXMLFloat(xml,  k .. "#litres")
        if ftName ~= nil and litres ~= nil and litres > 0 and g_fillTypeManager ~= nil then
            local ft = g_fillTypeManager:getFillTypeIndexByName(ftName)
            if ft ~= nil then
                local b = SmartDistribution._marketBuffer[uid]; if b == nil then b = {}; SmartDistribution._marketBuffer[uid] = b end
                b[ft] = math.max(0, litres)
                mbn = mbn + 1
            end
        end
        mb = mb + 1
    end
    local mtc = 0
    while true do
        local k = string.format("smartDistribution.marketTiming(%d)", mtc)
        local uid = getXMLString(xml, k .. "#uniqueId")
        if uid == nil then break end
        local ftName = getXMLString(xml, k .. "#fillType")
        local ft = (ftName ~= nil and g_fillTypeManager ~= nil) and g_fillTypeManager:getFillTypeIndexByName(ftName) or nil
        local mode = getXMLInt(xml, k .. "#sellMode")
        if ft ~= nil and mode ~= nil and mode ~= 0 then
            local b = SmartDistribution._marketTiming[uid]; if b == nil then b = {}; SmartDistribution._marketTiming[uid] = b end
            b[ft] = mode
        end
        mtc = mtc + 1
    end
    -- rolling 24-cycle "monthly" transaction window
    monthlyRing = {}
    local mp = getXMLInt(xml, "smartDistribution.monthly#pos")
    monthlyPos = (mp ~= nil and mp >= 0) and (mp % MONTHLY_CYCLES) or 0
    local ci, mloaded = 0, 0
    while true do
        local ck = string.format("smartDistribution.monthly.cycle(%d)", ci)
        local slot = getXMLInt(xml, ck .. "#slot")
        if slot == nil then break end
        if slot < 1 or slot > MONTHLY_CYCLES then slot = ((ci % MONTHLY_CYCLES) + 1) end
        local snap = {}
        local ei = 0
        while true do
            local ek = string.format("%s.e(%d)", ck, ei)
            local uid = getXMLString(xml, ek .. "#uniqueId")
            if uid == nil then break end
            local ftName = getXMLString(xml, ek .. "#fillType")
            if ftName ~= nil and g_fillTypeManager ~= nil then
                local ft = g_fillTypeManager:getFillTypeIndexByName(ftName)
                if ft ~= nil then
                    local a = snap[uid]; if a == nil then a = {}; snap[uid] = a end
                    a[ft] = {
                        dist     = getXMLFloat(xml, ek .. "#dist")     or 0,
                        sold     = getXMLFloat(xml, ek .. "#sold")     or 0,
                        stored   = getXMLFloat(xml, ek .. "#stored")   or 0,
                        received = getXMLFloat(xml, ek .. "#received") or 0,
                        money    = getXMLFloat(xml, ek .. "#money")    or 0,
                        produced = getXMLFloat(xml, ek .. "#produced") or 0,
                        consumed = getXMLFloat(xml, ek .. "#consumed") or 0,
                    }
                end
            end
            ei = ei + 1
        end
        if next(snap) ~= nil then monthlyRing[slot] = snap; mloaded = mloaded + 1 end
        ci = ci + 1
    end
    delete(xml)
    print(string.format("[SmartDistribution persist] LOADED %d mode(s) + %d timing from %s", n, tn, tostring(path)))
    log("loaded %d per-asset override(s) + %d timing(s) + %d crop window(s) + %d monthly cycle(s) from %s", n, tn, c, mloaded, path)
end

local function installPersistence()
    if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
        Mission00.loadMission00Finished = Utils.appendedFunction(
            Mission00.loadMission00Finished, function(...) pcall(loadOverrides) end)
        print("[SmartDistribution persist] load hook attached (Mission00.loadMission00Finished)")
    else
        print("[SmartDistribution persist] LOAD HOOK NOT ATTACHED -- Mission00.loadMission00Finished missing")
    end
    -- FS25's savegame writer is FSCareerMissionInfo:saveToXMLFile(missionInfo) -- the same hook
    -- EasyDevControls uses to persist into the savegame folder.  (The old FSCareerMission.saveSavegame
    -- hook never fired: that class doesn't exist under that name in FS25, so nothing ever saved.)
    if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
        FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
            FSCareerMissionInfo.saveToXMLFile, function(self, ...) pcall(saveOverrides, self) end)
        print("[SmartDistribution persist] save hook attached (FSCareerMissionInfo.saveToXMLFile)")
    else
        print("[SmartDistribution persist] SAVE HOOK NOT ATTACHED -- FSCareerMissionInfo.saveToXMLFile missing")
    end
end

-- ============================================================================
-- CONSOLE  (developer/support commands; requires the in-game dev console)
-- ============================================================================
local function listedPlaceables()
    local res = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps ~= nil then
        for _, p in ipairs(ps.placeables) do
            if p.rootNode ~= nil then res[#res + 1] = p end
        end
    end
    return res
end

function SmartDistribution.cmdList(self)
    local ps = listedPlaceables()
    print(string.format("[SmartDistribution] --- %d placeable(s): index | uniqueId | name | class | overrides ---", #ps))
    for i, p in ipairs(ps) do
        local uid = getUid(p)
        local ov  = S.assets[uid]
        local ovs = ""
        if ov ~= nil then
            local parts = {}
            for ft, m in pairs(ov) do parts[#parts + 1] = fillTypeName(ft) .. "=" .. tostring(m) end
            ovs = "  {" .. table.concat(parts, ",") .. "}"
        end
        print(string.format("[SmartDistribution] %d | %s | %s | %s%s",
            i, tostring(uid), placeableName(p), getAssetClass(p), ovs))
    end
    return string.format("%d placeable(s) listed", #ps)
end

function SmartDistribution.cmdMode(self, indexStr, ftName, modeStr)
    local idx  = tonumber(indexStr)
    local mode = tonumber(modeStr)
    if idx == nil or ftName == nil or mode == nil then
        return "usage: sdMode <index> <fillTypeName> <mode>  | modes: 1=Hold 2=Distribute 3=Distribute+Sell 4=Sell 5=Distribute+Store 6=Store 0=Inherit  (sdList for indices)"
    end
    local p = listedPlaceables()[idx]
    if p == nil then return "no placeable at index " .. tostring(idx) end
    local ft = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName(string.upper(ftName)) or nil
    if ft == nil then return "unknown fill type: " .. tostring(ftName) end
    SmartDistribution.applyAssetMode(p, ft, mode)
    return string.format("set %s [%s] mode=%d (uid=%s) - save the game to persist",
        placeableName(p), string.upper(ftName), mode, tostring(getUid(p)))
end

-- Fill a freshly spawned pallet from the production's held stock and debit the storage by what went in.
-- Called (async) once the pallet has loaded. Returns the litres actually added. (Verified in-game: the
-- spawn callback passes (target, pallet, fillUnitIndex, fillTypeIndex); we locate the unit + fill it.)
function SmartDistribution._fillSpawnedPallet(pp, ft, pallet)
    if pp == nil or ft == nil or type(pallet) ~= "table" or pallet.addFillUnitFillLevel == nil then return 0 end
    local farmId = (pp.getOwnerFarmId ~= nil and pp:getOwnerFarmId()) or 1
    local unit
    if pallet.getFillUnits ~= nil then
        local units = pallet:getFillUnits() or {}
        for i = 1, #units do
            if pallet.getFillUnitSupportsFillType == nil or pallet:getFillUnitSupportsFillType(i, ft) then unit = i; break end
        end
    end
    unit = unit or 1
    local cap    = (pallet.getFillUnitCapacity ~= nil and pallet:getFillUnitCapacity(unit)) or 0
    local avail  = (pp.getFillLevel ~= nil and pp:getFillLevel(ft)) or 0
    local amount = math.min(cap > 0 and cap or avail, avail)
    if amount <= 0 then return 0 end
    local added = pallet:addFillUnitFillLevel(farmId, unit, amount, ft, ToolType and ToolType.UNDEFINED or nil) or 0
    if added > 0 and pp.storage ~= nil and pp.storage.setFillLevel ~= nil and pp.storage.getFillLevel ~= nil then
        pp.storage:setFillLevel(math.max(0, (pp.storage:getFillLevel(ft) or avail) - added), ft)
    end
    -- let an open UI refresh its displayed held volume once the pallet is filled + the storage debited
    if added > 0 and SmartDistribution._spawnCompleteCb ~= nil then pcall(SmartDistribution._spawnCompleteCb) end
    return added
end

-- Spawn up to `count` filled pallets of `ft` from a production's held stock, SERIALLY: each pallet fills
-- from + debits the storage in its load callback, then the next spawns -- so two pallets never draw the
-- same litres. Stops early when the stock runs out. Uses the production's own base-game palletSpawner.
function SmartDistribution.spawnPalletsFromProduction(pp, ft, count)
    if pp == nil or pp.palletSpawner == nil or ft == nil then return 0 end
    count = math.max(1, math.min(math.floor(count or 1), 50))
    local farmId = (pp.getOwnerFarmId ~= nil and pp:getOwnerFarmId()) or 1
    local function spawnNext(remaining)
        if remaining <= 0 then return end
        if pp.getFillLevel ~= nil and (pp:getFillLevel(ft) or 0) <= 0 then return end
        pcall(function()
            pp.palletSpawner:spawnPallet(farmId, ft, function(_, pallet)
                SmartDistribution._fillSpawnedPallet(pp, ft, pallet)
                spawnNext(remaining - 1)
            end, pp)
        end)
    end
    spawnNext(count)
    return count
end

-- Read a pallet's per-unit capacity (litres) from its XML, cached by filename. Returns nil if unknown.
-- Works off any PalletSpawner instance (productions use pp.palletSpawner; a husbandry uses its per-fill-type
-- spec.fillTypeIndexToPalletSpawner[ft]), so both spawn paths share one capacity reader.
function SmartDistribution._palletCapacityFromSpawner(spawner, ft)
    if spawner == nil or ft == nil then return nil end
    local map = spawner.fillTypeIdToPallet
    local entry = map ~= nil and map[ft] or nil
    local filename = entry ~= nil and entry.filename or nil
    if filename == nil or filename == "nope" then return nil end
    SmartDistribution._palletCapCache = SmartDistribution._palletCapCache or {}
    local cached = SmartDistribution._palletCapCache[filename]
    if cached ~= nil then return cached or nil end                    -- false is cached "known bad"
    local cap
    pcall(function()
        if XMLFile ~= nil and XMLFile.load ~= nil and FillUnit ~= nil and FillUnit.getCapacityFromXml ~= nil then
            local schema = (Vehicle ~= nil and Vehicle.xmlSchema) or nil
            local xml = XMLFile.load("sdPalletCap", filename, schema)
            if xml ~= nil then cap = FillUnit.getCapacityFromXml(xml); xml:delete() end
        end
    end)
    SmartDistribution._palletCapCache[filename] = cap or false
    return cap
end
function SmartDistribution.palletCapacityFor(pp, ft)
    if pp == nil then return nil end
    return SmartDistribution._palletCapacityFromSpawner(pp.palletSpawner, ft)
end
-- The PalletSpawner a husbandry uses for ft (per-fill-type map, else the single shared spawner).
function SmartDistribution.husbandryPalletSpawner(p, ft)
    local hs = p ~= nil and p.spec_husbandryPallets or nil
    if hs == nil then return nil end
    if type(hs.fillTypeIndexToPalletSpawner) == "table" and hs.fillTypeIndexToPalletSpawner[ft] ~= nil then
        return hs.fillTypeIndexToPalletSpawner[ft]
    end
    return hs.palletSpawner
end
function SmartDistribution.palletCapacityForHusbandry(p, ft)
    return SmartDistribution._palletCapacityFromSpawner(SmartDistribution.husbandryPalletSpawner(p, ft), ft)
end

-- Build the list of spawn options for a production output. v1: the single pallet type the production's
-- spawner uses; bale sizes and tree species will be appended here later. Each option is
-- { kind, name, fillType, capacity, maxCount } where maxCount is capped by held litres / unit capacity.
function SmartDistribution.getSpawnOptions(pp, ft)
    local opts = {}
    if pp == nil or ft == nil then return opts end
    local held = (pp.getFillLevel ~= nil and pp:getFillLevel(ft)) or 0
    local cap = SmartDistribution.palletCapacityFor(pp, ft)
    if cap ~= nil and cap > 0 then
        local volStr = (g_i18n ~= nil and g_i18n.formatVolume ~= nil) and g_i18n:formatVolume(cap, 0) or (tostring(math.floor(cap)) .. " l")
        opts[#opts + 1] = { kind = "pallet", name = "Pallet - " .. volStr, fillType = ft, capacity = cap, maxCount = math.floor(held / cap) }
    end
    return opts
end

function SmartDistribution.cmdSpawn(self, indexStr, ftName, countStr)
    local idx = tonumber(indexStr)
    if idx == nil or ftName == nil then
        return "usage: sdSpawn <index> <fillType> [count]  (index from sdList; spawns pallets from that production's held stock)"
    end
    local p = listedPlaceables()[idx]
    if p == nil then return "no placeable at index " .. tostring(idx) end
    local pp = getProductionPoint(p)
    if pp == nil then return placeableName(p) .. " is not a production" end
    if pp.palletSpawner == nil then return placeableName(p) .. " has no pallet spawner" end
    local ft = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName(string.upper(ftName)) or nil
    if ft == nil then return "unknown fill type: " .. tostring(ftName) end
    local n = SmartDistribution.spawnPalletsFromProduction(pp, ft, tonumber(countStr) or 1)
    return string.format("spawned %d pallet(s) of %s from %s", n, string.upper(ftName), placeableName(p))
end

-- ---- manual pallet spawn from a pallet-spawner HUSBANDRY (coops / sheep) ----
-- Parallel to the production path, but the source is the coop's internal buffer (spec_husbandryPallets
-- .pendingLiters[ft]) rather than a production storage, and the spawner is the coop's per-fill-type one.
-- Fill a freshly spawned pallet from that buffer and debit it. Serial, one pallet at a time.
function SmartDistribution._fillSpawnedPalletFromHusbandry(p, ft, pallet)
    local hs = p ~= nil and p.spec_husbandryPallets or nil
    if hs == nil or ft == nil or type(pallet) ~= "table" or pallet.addFillUnitFillLevel == nil then return 0 end
    if type(hs.pendingLiters) ~= "table" then return 0 end
    local farmId = (p.getOwnerFarmId ~= nil and p:getOwnerFarmId()) or p.ownerFarmId or 1
    local unit
    if pallet.getFillUnits ~= nil then
        local units = pallet:getFillUnits() or {}
        for i = 1, #units do
            if pallet.getFillUnitSupportsFillType == nil or pallet:getFillUnitSupportsFillType(i, ft) then unit = i; break end
        end
    end
    unit = unit or 1
    local cap    = (pallet.getFillUnitCapacity ~= nil and pallet:getFillUnitCapacity(unit)) or 0
    local avail  = hs.pendingLiters[ft] or 0
    local amount = math.min(cap > 0 and cap or avail, avail)
    if amount <= 0 then return 0 end
    local added = pallet:addFillUnitFillLevel(farmId, unit, amount, ft, ToolType and ToolType.UNDEFINED or nil) or 0
    if added > 0 then hs.pendingLiters[ft] = math.max(0, avail - added) end
    if added > 0 and SmartDistribution._spawnCompleteCb ~= nil then pcall(SmartDistribution._spawnCompleteCb) end
    return added
end

-- Spawn up to `count` filled pallets of `ft` from a husbandry's internal buffer, SERIALLY (each fills +
-- debits pendingLiters in its load callback before the next spawns). Stops early when the buffer drops
-- below one pallet. Uses the coop's own base-game PalletSpawner. Returns pallets requested (best effort).
function SmartDistribution.spawnPalletsFromHusbandry(p, ft, count)
    local hs = p ~= nil and p.spec_husbandryPallets or nil
    if hs == nil or ft == nil or type(hs.pendingLiters) ~= "table" then return 0 end
    local spawner = SmartDistribution.husbandryPalletSpawner(p, ft)
    if spawner == nil or spawner.spawnPallet == nil then return 0 end
    count = math.max(1, math.min(math.floor(count or 1), 50))
    local farmId = (p.getOwnerFarmId ~= nil and p:getOwnerFarmId()) or p.ownerFarmId or 1
    local cap = SmartDistribution.palletCapacityForHusbandry(p, ft) or 0
    local function spawnNext(remaining)
        if remaining <= 0 then return end
        if (hs.pendingLiters[ft] or 0) < (cap > 0 and cap or 1) then return end
        pcall(function()
            spawner:spawnPallet(farmId, ft, function(_, pallet)
                SmartDistribution._fillSpawnedPalletFromHusbandry(p, ft, pallet)
                spawnNext(remaining - 1)
            end, p)
        end)
    end
    spawnNext(count)
    return count
end

-- dev: test the husbandry pallet-spawn primitive before wiring it to the UI. sdSpawnHusb <index> [count]
function SmartDistribution.cmdSpawnHusb(self, indexStr, countStr)
    local idx = tonumber(indexStr)
    if idx == nil then return "usage: sdSpawnHusb <index> [count]  (index from sdList; spawns pallets from a coop/sheep internal buffer)" end
    local p = listedPlaceables()[idx]
    if p == nil then return "no placeable at index " .. tostring(idx) end
    local hs = p.spec_husbandryPallets
    if hs == nil then return placeableName(p) .. " is not a pallet-spawner husbandry" end
    local fts = palletSpawnerFillTypes(p)
    local ft = fts ~= nil and fts[1] or nil
    if ft == nil then return placeableName(p) .. " has no pallet fill type" end
    local before = (type(hs.pendingLiters) == "table" and hs.pendingLiters[ft]) or 0
    local cap = SmartDistribution.palletCapacityForHusbandry(p, ft) or 0
    local palBefore = palletFillLevel(p, ft)
    local n = SmartDistribution.spawnPalletsFromHusbandry(p, ft, tonumber(countStr) or 1)
    local after = (type(hs.pendingLiters) == "table" and hs.pendingLiters[ft]) or 0
    return string.format("%s [%s]: requested=%d cap=%s pending %.1f->%.1f palletLiters %.1f->%.1f",
        placeableName(p), tostring(fillTypeName(ft)), n, tostring(cap), before, after, palBefore, palletFillLevel(p, ft))
end

-- dev: dump a feeding-robot husbandry (base-game Lely Vector / standalone GEA) so DR can be wired to its
-- ingredient bunkers (unloadingSpots) instead of the generic food pool. Reveals the runtime spec layout +
-- class methods -- the field/method names we can't read from the encrypted base scripts.
function SmartDistribution.cmdRobotProbe(self)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return "no placeableSystem" end
    local function dump(s) print("[SmartDistribution] " .. s) end
    local function scalar(v)
        local t = type(v)
        if t == "number" or t == "string" or t == "boolean" then return tostring(v) end
        return "<" .. t .. ">"
    end
    local function classFuncs(cls, label)
        if type(cls) ~= "table" then dump(label .. " = " .. type(cls)); return end
        local fns = {}
        for k, v in pairs(cls) do if type(v) == "function" then fns[#fns + 1] = tostring(k) end end
        table.sort(fns)
        dump(label .. " funcs (" .. #fns .. "): " .. table.concat(fns, ", "))
    end
    classFuncs(_G["PlaceableHusbandryFeedingRobot"], "PlaceableHusbandryFeedingRobot")
    classFuncs(_G["FeedingRobot"], "FeedingRobot")
    local n = 0
    for _, p in ipairs(ps.placeables) do
        local spec = p.spec_husbandryFeedingRobot
        if spec ~= nil then
            n = n + 1
            dump(string.format("[robot %d] %s  type=%s foodSpec=%s", n, tostring(placeableName(p)),
                tostring(p.typeName), tostring(p.spec_husbandryFood ~= nil)))
            local fields = {}
            for k, v in pairs(spec) do fields[#fields + 1] = tostring(k) .. ":" .. type(v) end
            table.sort(fields)
            dump("   spec fields: " .. table.concat(fields, ", "))
            -- The real robot object hangs off spec.feedingRobot; its unloadingSpots hold the ingredient
            -- bunkers. Recurse into it: dump its fields, every list-of-tables it holds (each spot's
            -- fillType / capacity / fillLevel), and its class method surface.
            local fr = spec.feedingRobot
            if type(fr) == "table" then
                local frf = {}
                for k, v in pairs(fr) do frf[#frf + 1] = tostring(k) .. ":" .. type(v) end
                table.sort(frf)
                dump("   feedingRobot fields: " .. table.concat(frf, ", "))
                for k, v in pairs(fr) do
                    if type(v) == "table" then
                        local rows = {}
                        for kk, e in pairs(v) do
                            if type(e) == "table" then
                                local sub = {}
                                for k2, v2 in pairs(e) do sub[#sub + 1] = tostring(k2) .. "=" .. scalar(v2) end
                                table.sort(sub)
                                rows[#rows + 1] = "[" .. tostring(kk) .. "]{ " .. table.concat(sub, ", ") .. " }"
                            end
                        end
                        if #rows > 0 then dump("      feedingRobot." .. tostring(k) .. ": " .. table.concat(rows, "  ")) end
                    end
                end
                -- recipe (mixing ratios) -- the input for a demand-based (not keep-full) default per bunker
                local robot = fr.robot
                if type(robot) == "table" and type(robot.recipe) == "table" then
                    local rec = robot.recipe
                    local rf = {}
                    for k, v in pairs(rec) do if type(v) ~= "table" then rf[#rf + 1] = tostring(k) .. "=" .. scalar(v) end end
                    table.sort(rf)
                    dump("   recipe scalars: { " .. table.concat(rf, ", ") .. " }")
                    if type(rec.ingredients) == "table" then
                        for kk, ing in pairs(rec.ingredients) do
                            if type(ing) == "table" then
                                local sub = {}
                                for k2, v2 in pairs(ing) do
                                    if type(v2) == "table" then
                                        local inner = {}
                                        for k3, v3 in pairs(v2) do inner[#inner + 1] = tostring(k3) .. "=" .. scalar(v3) end
                                        table.sort(inner)
                                        sub[#sub + 1] = tostring(k2) .. "={" .. table.concat(inner, ",") .. "}"
                                    else
                                        sub[#sub + 1] = tostring(k2) .. "=" .. scalar(v2)
                                    end
                                end
                                table.sort(sub)
                                dump(string.format("   recipe.ingredients[%s]: { %s }", tostring(kk), table.concat(sub, ", ")))
                            end
                        end
                    end
                end
                local mt = getmetatable(fr)
                if type(mt) == "table" and type(mt.__index) == "table" then classFuncs(mt.__index, "   feedingRobot class") end
            end
            local fsp = p.spec_husbandryFood
            if fsp ~= nil then
                dump(string.format("   spec_husbandryFood: litersPerHour=%s capacity=%s animalTypeIndex=%s",
                    tostring(fsp.litersPerHour), tostring(fsp.capacity), tostring(fsp.animalTypeIndex)))
            end
        end
    end
    if n == 0 then return "no feeding-robot husbandries (spec_husbandryFeedingRobot) found" end
    return string.format("probed %d feeding-robot barn(s) -- see log", n)
end

-- dev: validate the feeding-robot READ + WRITE API on the (first) robot barn before wiring the feed pass.
-- sdRobotFill <fillType> [liters]  -- e.g. sdRobotFill SILAGE 5000
function SmartDistribution.cmdRobotFill(self, ftName, litersStr)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    local p, fr
    for _, pl in ipairs(ps ~= nil and ps.placeables or {}) do
        if pl.spec_husbandryFeedingRobot ~= nil and pl.spec_husbandryFeedingRobot.feedingRobot ~= nil then
            p = pl; fr = pl.spec_husbandryFeedingRobot.feedingRobot; break
        end
    end
    if fr == nil then return "no feeding-robot barn found" end
    if ftName == nil then return "usage: sdRobotFill <fillType> [liters]  (e.g. sdRobotFill SILAGE 5000)" end
    local ft = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName(string.upper(ftName)) or nil
    if ft == nil then return "unknown fill type: " .. tostring(ftName) end
    local spot = type(fr.fillTypeToUnloadingSpot) == "table" and fr.fillTypeToUnloadingSpot[ft] or nil
    if spot == nil then return placeableName(p) .. " has no bunker for " .. string.upper(ftName) end
    local liters = tonumber(litersStr) or 1000
    local farmId = (p.getOwnerFarmId ~= nil and p:getOwnerFarmId()) or p.ownerFarmId or 1
    local before = spot.fillLevel or 0
    local getL   = fr.getFillLevel ~= nil and select(2, pcall(fr.getFillLevel, fr, ft)) or "n/a"
    local getFree = fr.getFreeCapacity ~= nil and select(2, pcall(fr.getFreeCapacity, fr, ft)) or "n/a"
    local allowed = fr.getIsFillTypeAllowed ~= nil and select(2, pcall(fr.getIsFillTypeAllowed, fr, ft)) or "n/a"
    local added = "n/a"
    if fr.addFillLevelFromTool ~= nil then
        local ok, r = pcall(fr.addFillLevelFromTool, fr, farmId, liters, ft, nil, nil, nil)
        added = ok and tostring(r) or ("ERR:" .. tostring(r))
    end
    return string.format("%s [%s]: cap=%s fillLevel %.0f->%.0f  getFillLevel=%s getFree=%s allowed=%s addReturned=%s",
        placeableName(p), string.upper(ftName), tostring(spot.capacity), before, spot.fillLevel or 0,
        tostring(getL), tostring(getFree), tostring(allowed), tostring(added))
end

-- dev: set / clear / query an input FILL TARGET (%) on the first feeding-robot barn, to test the demand
-- override before the Advanced Inputs UI exists. sdTarget <fillType> <pct|off>  (e.g. sdTarget SILAGE 50)
function SmartDistribution.cmdTarget(self, ftName, pctStr)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    local p
    for _, pl in ipairs(ps ~= nil and ps.placeables or {}) do
        if pl.spec_husbandryFeedingRobot ~= nil then p = pl; break end
    end
    if p == nil then return "no feeding-robot barn found" end
    if ftName == nil then return "usage: sdTarget <fillType> <pct|off>  (e.g. sdTarget SILAGE 50)" end
    local ft = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName(string.upper(ftName)) or nil
    if ft == nil then return "unknown fill type: " .. tostring(ftName) end
    local uid = getUid(p)
    if pctStr == "off" or pctStr == "clear" then
        SmartDistribution.setInputTargetPct(uid, ft, nil)
        return string.format("%s [%s]: target cleared", placeableName(p), string.upper(ftName))
    end
    local pct = tonumber(pctStr)
    if pct == nil then
        local cur = SmartDistribution.getInputTargetPct(uid, ft)
        return string.format("%s [%s]: target=%s  held=%.0f cap=%.0f", placeableName(p), string.upper(ftName),
            cur ~= nil and (cur .. "%") or "none",
            SmartDistribution.husbandryInputHeld(p, ft), SmartDistribution.husbandryInputCapacity(p, ft))
    end
    SmartDistribution.setInputTargetPct(uid, ft, pct)
    return string.format("%s [%s]: target=%d%% (%.0f L)  held=%.0f cap=%.0f", placeableName(p), string.upper(ftName),
        pct, SmartDistribution.inputTargetLiters(p, ft) or 0,
        SmartDistribution.husbandryInputHeld(p, ft), SmartDistribution.husbandryInputCapacity(p, ft))
end

-- Spawn options for a pallet-spawner husbandry output: the single pallet type its spawner uses, maxCount
-- capped by internally-held (pending) litres / unit capacity. Mirrors getSpawnOptions (production side).
function SmartDistribution.getSpawnOptionsHusbandry(p, ft)
    local opts = {}
    if p == nil or ft == nil then return opts end
    local held = SmartDistribution.palletPendingLiters(p, ft)
    local cap  = SmartDistribution.palletCapacityForHusbandry(p, ft)
    if cap ~= nil and cap > 0 then
        local volStr = (g_i18n ~= nil and g_i18n.formatVolume ~= nil) and g_i18n:formatVolume(cap, 0) or (tostring(math.floor(cap)) .. " l")
        opts[#opts + 1] = { kind = "pallet", name = "Pallet - " .. volStr, fillType = ft, capacity = cap, maxCount = math.floor(held / cap) }
    end
    return opts
end

-- Is a manual "Spawn Pallets" action meaningful for (asset, ft)? Requires Hold Internal AND at least one
-- FULL pallet's worth held internally. Handles productions (storage) and pallet-spawner husbandries
-- (pending buffer). Single gate for the footer button on every page + the vanilla-menu hooks, so the
-- button is hidden below one pallet's worth everywhere.
function SmartDistribution.palletSpawnReady(asset, ft)
    if asset == nil or ft == nil or MODE == nil then return false end
    if SmartDistribution.resolvedAssetMode == nil
       or SmartDistribution.resolvedAssetMode(asset, ft) ~= MODE.HOLD_INTERNAL then return false end
    local pp = getProductionPoint(asset)
    if pp ~= nil then
        local cap  = SmartDistribution.palletCapacityFor(pp, ft)
        local held = (pp.getFillLevel ~= nil and pp:getFillLevel(ft)) or 0
        return cap ~= nil and cap > 0 and held >= cap
    end
    if asset.spec_husbandryPallets ~= nil then
        local cap  = SmartDistribution.palletCapacityForHusbandry(asset, ft)
        local held = SmartDistribution.palletPendingLiters(asset, ft)
        return cap ~= nil and cap > 0 and held >= cap
    end
    return false
end

function SmartDistribution.cmdShow(self)
    local assets, total = 0, 0
    for uid, fts in pairs(S.assets) do
        assets = assets + 1
        local parts = {}
        for ft, m in pairs(fts) do parts[#parts + 1] = fillTypeName(ft) .. "=" .. tostring(m); total = total + 1 end
        print(string.format("[SmartDistribution] %s -> {%s}", tostring(uid), table.concat(parts, ",")))
    end
    return string.format("%d override(s) across %d asset(s)", total, assets)
end

function SmartDistribution.cmdManage(self)
    SmartDistribution.openMenu()
    return "opening distribution menu"
end

-- dev probe: dump Pallet Storage Shed (object storage) structure so the shed-as-source path can
-- be built on the real abstract stored-object API (not present in the public lua docs).
function SmartDistribution.cmdShedProbe(self)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return "no placeableSystem" end
    local function dump(s) print("[SmartDistribution] " .. s) end
    local function scalar(v)
        local t = type(v)
        if t == "number" or t == "string" or t == "boolean" then return tostring(v) end
        return "<" .. t .. ">"
    end
    local function tryCall(label, fn)
        local ok, a, b = pcall(fn)
        if ok then dump(string.format("      %s -> %s  %s", label, tostring(a), tostring(b))) end
    end
    local n = 0
    for _, p in ipairs(ps.placeables) do
        local spec = p.spec_objectStorage
        if spec ~= nil then
            n = n + 1
            local stored = (spec.storedObjects ~= nil and #spec.storedObjects) or -1
            dump(string.format("[shed %d] %s  cap=%s stored=%s supportsPallets=%s supportsBales=%s",
                n, tostring(placeableName(p)), tostring(spec.capacity), tostring(stored),
                tostring(spec.supportsPallets), tostring(spec.supportsBales)))
            local names = {}
            for _, ft in ipairs(spec.supportedFillTypes or {}) do names[#names + 1] = tostring(fillTypeName(ft)) end
            dump("   supportedFillTypes: " .. (#names > 0 and table.concat(names, ",") or "(all)"))
            if type(spec.supportedObjects) == "table" then
                for i, so in ipairs(spec.supportedObjects) do
                    dump(string.format("   supportedObject[%d] filename=%s amount=%s", i, tostring(so.filename), tostring(so.amount)))
                end
            end
            if type(spec.objectInfos) == "table" then
                for i, info in ipairs(spec.objectInfos) do
                    local o1 = info.objects and info.objects[1]
                    local xfn, dlg
                    if o1 ~= nil then
                        if o1.getXMLFilename then local ok, a = pcall(function() return o1:getXMLFilename() end); if ok then xfn = a end end
                        if o1.getDialogText then local ok, a = pcall(function() return o1:getDialogText() end); if ok then dlg = a end end
                    end
                    dump(string.format("   objectInfo[%d] numObjects=%s xml=%s dialog=%s", i, tostring(info.numObjects), tostring(xfn), tostring(dlg)))
                    if type(o1) == "table" then
                        local parts = {}
                        for k, v in pairs(o1) do parts[#parts + 1] = tostring(k) .. "=" .. scalar(v) end
                        dump("      [" .. i .. "] fields: " .. table.concat(parts, ", "))
                        for k, v in pairs(o1) do
                            if type(v) == "table" then
                                local sub, cnt = {}, 0
                                for kk, vv in pairs(v) do cnt = cnt + 1; if cnt <= 30 then sub[#sub + 1] = tostring(kk) .. "=" .. scalar(vv) end end
                                dump("      [" .. i .. "]." .. tostring(k) .. " {" .. table.concat(sub, ", ") .. (cnt > 30 and ", ..." or "") .. "}")
                            end
                        end
                    end
                end
            end
            local obj = (spec.storedObjects ~= nil and spec.storedObjects[1]) or nil
            if obj == nil then
                dump("   (no stored objects yet -- deposit a FULL egg pallet, then re-run)")
            else
                dump("   storedObjects[1] type=" .. type(obj))
                if type(obj) == "table" then
                    local parts = {}
                    for k, v in pairs(obj) do parts[#parts + 1] = tostring(k) .. "=" .. scalar(v) end
                    dump("   [1] fields: " .. table.concat(parts, ", "))
                    for k, v in pairs(obj) do
                        if type(v) == "table" then
                            local sub, cnt = {}, 0
                            for kk, vv in pairs(v) do
                                cnt = cnt + 1
                                if cnt <= 30 then sub[#sub + 1] = tostring(kk) .. "=" .. scalar(vv) end
                            end
                            dump("   [1]." .. tostring(k) .. " {" .. table.concat(sub, ", ") .. (cnt > 30 and ", ..." or "") .. "}")
                        end
                    end
                end
                if obj.getFillType ~= nil then tryCall("getFillType()", function() return obj:getFillType() end) end
                if obj.getFillTypeIndex ~= nil then tryCall("getFillTypeIndex()", function() return obj:getFillTypeIndex() end) end
                if obj.getFillLevel ~= nil then tryCall("getFillLevel()", function() return obj:getFillLevel() end) end
                if obj.getFillUnitFillLevel ~= nil then tryCall("getFillUnitFillLevel(1)", function() return obj:getFillUnitFillLevel(1) end) end
                if obj.getDialogText ~= nil then tryCall("getDialogText()", function() return obj:getDialogText() end) end
                if obj.getXMLFilename ~= nil then tryCall("getXMLFilename()", function() return obj:getXMLFilename() end) end
                if obj.getRealObject ~= nil then tryCall("getRealObject()", function() return obj:getRealObject() end) end
            end
        end
    end
    if n == 0 then return "no Pallet Storage Sheds (spec_objectStorage) found" end
    return string.format("probed %d shed(s) -- see log", n)
end

-- dev: dump every husbandry pallet asset (chicken coops / sheep) -- mode, buffered vs spawned
-- pallet liters, per-pallet fullness, and nearest-shed reach + sink eligibility.  Diagnoses why a
-- given pallet type (e.g. WOOL) isn't storing: wrong mode, no FULL pallets, or shed out of reach.
function SmartDistribution.cmdPalletProbe(self)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return "no placeableSystem" end
    local function dump(s) print("[SmartDistribution] " .. s) end
    -- [DR hold-internal probe] dump the base specialization + PalletSpawner class functions ONCE. Base
    -- classes live in the sandbox global scope BEHIND a metatable, so use _G[name] (rawget bypasses it and
    -- returns nil). This reveals the spawn/update driver we must override for Hold Internal.
    local function classFuncs(cls, label)
        if type(cls) ~= "table" then dump(label .. " = " .. type(cls)); return end
        local fns = {}
        for k, v in pairs(cls) do if type(v) == "function" then fns[#fns + 1] = tostring(k) end end
        local mt = getmetatable(cls)
        dump(string.format("%s: %d own funcs; metatable=%s __index=%s", label, #fns,
            tostring(mt ~= nil), tostring(type(mt) == "table" and type(mt.__index) or "n/a")))
        table.sort(fns)
        if #fns > 0 then dump("   " .. label .. " funcs: " .. table.concat(fns, ", ")) end
    end
    classFuncs(_G["PlaceableHusbandryPallets"], "PlaceableHusbandryPallets")
    classFuncs(_G["PalletSpawner"], "PalletSpawner")
    local sheds = {}
    for _, p in ipairs(ps.placeables) do
        if p.spec_objectStorage ~= nil and p.rootNode ~= nil then sheds[#sheds + 1] = p end
    end
    local radius = S.global.radius
    local n = 0
    for _, p in ipairs(ps.placeables) do
        local fts  = palletSpawnerFillTypes(p)
        local spec = p.spec_husbandryPallets        -- nil for a beehive spawner
        if fts ~= nil and p.rootNode ~= nil then
            n = n + 1
            local px, _, pz = getWorldTranslation(p.rootNode)
            dump(string.format("[pallet-asset %d] %s  class=%s enrolled=%s reach=%s owner=%s",
                n, tostring(placeableName(p)), tostring(getAssetClass(p)), tostring(isEnrolled(p)),
                tostring(resolveReach(p)), tostring(p.ownerFarmId)))
            -- [DR hold-internal probe] reveal the base-game egg-pallet spawn interception point. Walk the
            -- placeable's class chain for pallet/spawn methods, and dump the husbandry-pallet spec's data
            -- fields (maxNumPallets / spawnPlaces / fillLevels / pendingLiters / palletSpawner). One-shot:
            -- tells us exactly which function to override to suppress spawning under Hold Internal.
            do
                local names, seen, mt = {}, {}, p
                for _ = 1, 24 do
                    mt = getmetatable(mt); if type(mt) ~= "table" then break end
                    local idx = mt.__index
                    if type(idx) == "table" then
                        for k, v in pairs(idx) do
                            if type(v) == "function" and not seen[k] then
                                local kl = tostring(k):lower()
                                if kl:find("pallet") or kl:find("spawn") then seen[k] = true; names[#names + 1] = tostring(k) end
                            end
                        end
                        mt = idx
                    end
                end
                table.sort(names)
                dump("   class pallet/spawn methods: " .. (#names > 0 and table.concat(names, ", ") or "(none)"))
                if spec ~= nil then
                    local fields = {}
                    for k, v in pairs(spec) do fields[#fields + 1] = tostring(k) .. ":" .. type(v) end
                    table.sort(fields)
                    dump("   spec_husbandryPallets fields: " .. table.concat(fields, ", "))
                    dump(string.format("   maxNumPallets=%s numSpawnPlaces=%s pendingLiters=%s palletSpawner=%s",
                        tostring(spec.maxNumPallets),
                        tostring(type(spec.spawnPlaces) == "table" and #spec.spawnPlaces or spec.spawnPlaces),
                        tostring(spec.pendingLiters), tostring(spec.palletSpawner)))
                    if type(spec.palletSpawner) == "table" then
                        local psmt = getmetatable(spec.palletSpawner)
                        local cls = type(psmt) == "table" and psmt.__index or nil
                        if type(cls) == "table" then classFuncs(cls, "spec.palletSpawner class")
                        else dump("   spec.palletSpawner metatable __index = " .. tostring(type(cls))) end
                    end
                end
            end
            for _, ft in ipairs(fts) do
                local buf = (spec ~= nil and spec.fillLevels ~= nil and spec.fillLevels[ft])
                    or (p.spec_beehivePalletSpawner ~= nil and p.spec_beehivePalletSpawner.pendingLiters) or 0
                dump(string.format("   ft %s: mode=%s  buffer=%s  palletLiters=%s  fullLiters=%s",
                    tostring(fillTypeName(ft)), tostring(resolveMode(p, ft)), tostring(buf),
                    tostring(palletFillLevel(p, ft)), tostring(fullPalletLiters(p, ft))))
                if spec ~= nil then
                    dump(string.format("      spec[ft] maxNumPallets=%s capacity=%s fillLevel=%s pending=%s fillPending=%s capPending=%s litersPerHour=%s limitReached=%s numSpawnsPending=%s",
                        tostring(spec.maxNumPallets and spec.maxNumPallets[ft]),
                        tostring(spec.capacities and spec.capacities[ft]),
                        tostring(spec.fillLevels and spec.fillLevels[ft]),
                        tostring(spec.pendingLiters and spec.pendingLiters[ft]),
                        tostring(spec.fillLevelsPending and spec.fillLevelsPending[ft]),
                        tostring(spec.capacitiesPending and spec.capacitiesPending[ft]),
                        tostring(spec.litersPerHour and spec.litersPerHour[ft]),
                        tostring(spec.palletLimitReached), tostring(spec.numSpawnsPending)))
                end
                if spec ~= nil and type(spec.pallets) == "table" then
                    local k = 0
                    for pallet in pairs(spec.pallets) do
                        if type(pallet) == "table" then
                            local idx = (pallet.spec_pallet ~= nil and pallet.spec_pallet.fillUnitIndex) or 1
                            local pft = pallet.getFillUnitFillType ~= nil and pallet:getFillUnitFillType(idx) or nil
                            if pft == ft then
                                k = k + 1
                                local lvl  = pallet.getFillUnitFillLevel ~= nil and pallet:getFillUnitFillLevel(idx) or -1
                                local free = pallet.getFillUnitFreeCapacity ~= nil and pallet:getFillUnitFreeCapacity(idx, ft) or -1
                                dump(string.format("      pallet[%d] level=%s free=%s full=%s", k, tostring(lvl), tostring(free),
                                    tostring(free ~= -1 and free <= 0.0001)))
                            end
                        end
                    end
                    if k == 0 then dump("      (no spawned pallets of this ft yet -- still buffering)") end
                end
                local bestD, bestShed = nil, nil
                for _, sh in ipairs(sheds) do
                    local sx, _, sz = getWorldTranslation(sh.rootNode)
                    local d = math.sqrt((sx - px) ^ 2 + (sz - pz) ^ 2)
                    if bestD == nil or d < bestD then bestD = d; bestShed = sh end
                end
                if bestShed ~= nil then
                    local reachOK = (resolveReach(p) == REACH.FARM_WIDE) or (bestD <= radius)
                    dump(string.format("      nearest shed: %s dist=%.1fm (radius=%s reachOK=%s) sinkEligible=%s",
                        tostring(placeableName(bestShed)), bestD, tostring(radius), tostring(reachOK),
                        tostring(isPalletShedSink(bestShed, ft))))
                else
                    dump("      (no Pallet Storage Sheds placed)")
                end
            end
        end
    end
    if n == 0 then return "no husbandry-pallet assets (coops / sheep) found" end
    return string.format("probed %d pallet asset(s) -- see log", n)
end

-- dev: settle the ManureHeap storage API + the heap<->barn relationship.  Dumps every
-- spec_manureHeap placeable (heaps + extensions): the real mh.manureHeap object, its Storage
-- method surface, read values for MANURE, and station links -- plus every barn's MANURE + SLURRY
-- storage (+ our _sdManurePatch flag).  Tells us if a heap can be driven as its own Storage so it
-- acts as a separate pit (like slurry) WITHOUT touching the pen.
function SmartDistribution.cmdManureProbe(self)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return "no placeableSystem" end
    local function dump(s) print("[SmartDistribution] " .. s) end
    local function scalar(v)
        local t = type(v)
        if t == "number" or t == "string" or t == "boolean" then return tostring(v) end
        return "<" .. t .. ">"
    end
    local function methods(obj, names)
        local present = {}
        for _, m in ipairs(names) do
            if type(obj) == "table" and obj[m] ~= nil then present[#present + 1] = m end
        end
        return #present > 0 and table.concat(present, ",") or "(none)"
    end
    local function tryCall(label, fn)
        local ok, a, b = pcall(fn)
        dump(string.format("      %s -> %s %s%s", label, ok and "ok" or "ERR",
            tostring(a), b ~= nil and (" " .. tostring(b)) or ""))
    end
    local ftm = g_fillTypeManager
    local MANURE = ftm ~= nil and ftm:getFillTypeIndexByName("MANURE") or nil
    local SLURRY = ftm ~= nil and ftm:getFillTypeIndexByName("LIQUIDMANURE") or nil
    dump(string.format("== manure probe == MANURE=%s LIQUIDMANURE=%s", tostring(MANURE), tostring(SLURRY)))
    local nh, nb = 0, 0
    for _, p in ipairs(ps.placeables) do
        local mh = p.spec_manureHeap
        if mh ~= nil then
            nh = nh + 1
            dump(string.format("[heap %d] %s  isExtension=%s needsBarn=%s sdManureExt=%s attachedToBarn=%s owner=%s",
                nh, tostring(placeableName(p)), tostring(mh.isExtension), tostring(mh.needsBarn), tostring(mh.sdManureExt),
                tostring(p.spec_husbandry ~= nil), tostring(p.ownerFarmId)))
            dump("   spec: hasStorageField=" .. tostring(mh.storage ~= nil)
                .. " hasManureHeapObj=" .. tostring(mh.manureHeap ~= nil)
                .. " hasLoadingStation=" .. tostring(mh.loadingStation ~= nil))
            local obj = mh.manureHeap
            if type(obj) == "table" then
                local parts = {}
                for k, v in pairs(obj) do parts[#parts + 1] = tostring(k) .. "=" .. scalar(v) end
                dump("   manureHeap fields: " .. table.concat(parts, ", "))
                for k, v in pairs(obj) do
                    if type(v) == "table" then
                        local sub, cnt = {}, 0
                        for kk, vv in pairs(v) do cnt = cnt + 1; if cnt <= 20 then sub[#sub + 1] = tostring(kk) .. "=" .. scalar(vv) end end
                        dump("   manureHeap." .. tostring(k) .. " {" .. table.concat(sub, ", ") .. (cnt > 20 and ", ..." or "") .. "}")
                    end
                end
                dump("   Storage methods present: " .. methods(obj, {
                    "getFillLevel", "getFillLevels", "getCapacity", "getFreeCapacity", "setFillLevel",
                    "addFillLevel", "getIsFillTypeSupported", "getSupportedFillTypes", "getFillTypes",
                    "raiseDirtyFlags", "updateFillPlanes" }))
                dump("   fillTypeIndex=" .. tostring(obj.fillTypeIndex))
                if obj.getFillLevel then tryCall("getFillLevel(fillTypeIndex)", function() return obj:getFillLevel(obj.fillTypeIndex) end) end
                if MANURE then
                    if obj.getFillLevel then tryCall("getFillLevel(MANURE)", function() return obj:getFillLevel(MANURE) end) end
                    if obj.getCapacity then tryCall("getCapacity(MANURE)", function() return obj:getCapacity(MANURE) end) end
                    if obj.getFreeCapacity then tryCall("getFreeCapacity(MANURE)", function() return obj:getFreeCapacity(MANURE) end) end
                    if obj.getIsFillTypeSupported then tryCall("getIsFillTypeSupported(MANURE)", function() return obj:getIsFillTypeSupported(MANURE) end) end
                end
                if obj.getSupportedFillTypes then
                    local ok, t = pcall(function() return obj:getSupportedFillTypes() end)
                    if ok and type(t) == "table" then
                        local nm = {}
                        for ft in pairs(t) do nm[#nm + 1] = tostring(fillTypeName(ft)) end
                        dump("      getSupportedFillTypes -> {" .. table.concat(nm, ",") .. "}")
                    end
                end
                if type(obj.unloadingStations) == "table" then dump("   unloadingStations=" .. tostring(#obj.unloadingStations)) end
                if type(obj.loadingStations) == "table" then dump("   loadingStations=" .. tostring(#obj.loadingStations)) end
            else
                dump("   (mh.manureHeap is " .. type(obj) .. " -- nothing to probe)")
            end
        end
    end
    for _, p in ipairs(ps.placeables) do
        local h = p.spec_husbandry
        if h ~= nil then
            nb = nb + 1
            local st = h.storage
            dump(string.format("[barn %d] %s  hasHeapSpec=%s patched=%s owner=%s",
                nb, tostring(placeableName(p)), tostring(p.spec_manureHeap ~= nil),
                tostring(st ~= nil and st._sdManurePatch == true), tostring(p.ownerFarmId)))
            if p.getHusbandryFillLevel ~= nil then
                if MANURE then dump(string.format("   MANURE: supported=%s level=%s cap=%s",
                    tostring(p.getHusbandryIsFillTypeSupported and p:getHusbandryIsFillTypeSupported(MANURE)),
                    tostring(p:getHusbandryFillLevel(MANURE)),
                    tostring(p.getHusbandryCapacity and p:getHusbandryCapacity(MANURE)))) end
                if SLURRY then dump(string.format("   LIQUIDMANURE: supported=%s level=%s cap=%s",
                    tostring(p.getHusbandryIsFillTypeSupported and p:getHusbandryIsFillTypeSupported(SLURRY)),
                    tostring(p:getHusbandryFillLevel(SLURRY)),
                    tostring(p.getHusbandryCapacity and p:getHusbandryCapacity(SLURRY)))) end
            end
            if st ~= nil then
                dump(string.format("   barn storage: cap[MANURE]=%s level[MANURE]=%s totalCap=%s",
                    tostring(st.capacities and MANURE and st.capacities[MANURE]),
                    tostring(st.fillLevels and MANURE and st.fillLevels[MANURE]),
                    tostring(st.capacity)))
            end
        end
    end
    if nh == 0 then dump("   (no spec_manureHeap placeables found -- place/own a heap or extension)") end
    return string.format("probed %d heap(s) + %d barn(s) -- see log", nh, nb)
end

-- [dev] reveal how the base game gates extension placement + stores the "not near X" warning, so we can
-- restrict the manure extension to a Pit and reword the messages.  Dumps placement-ish method names on
-- the relevant classes + the scalar spec fields of a live siloExtension and manureHeap.
function SmartDistribution.cmdExtProbe(self)
    local function dump(s) print("[SmartDistribution] " .. s) end
    local function dumpMethods(name, cls)
        if cls == nil then dump(name .. " = nil"); return end
        local hits = {}
        for k, v in pairs(cls) do
            if type(v) == "function" and type(k) == "string" then
                local lk = k:lower()
                if lk:find("test") or lk:find("place") or lk:find("valid") or lk:find("range")
                   or lk:find("near") or lk:find("area") or lk:find("preview") or lk:find("restrict")
                   or lk:find("allow") or lk:find("check") or lk:find("position") or lk:find("warning")
                   or lk:find("barn") or lk:find("silo") then
                    hits[#hits + 1] = k
                end
            end
        end
        table.sort(hits)
        dump(name .. ": " .. (next(hits) and table.concat(hits, ", ") or "(no placement-ish methods)"))
    end
    dumpMethods("PlaceableManureHeap", PlaceableManureHeap)
    dumpMethods("PlaceableSiloExtension", PlaceableSiloExtension)
    dumpMethods("Placeable", Placeable)
    local function dumpSpecScalars(label, p, spec)
        if spec == nil then return end
        local parts = {}
        for k, v in pairs(spec) do
            local t = type(v)
            if t == "string" or t == "number" or t == "boolean" then parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
        end
        table.sort(parts)
        dump(label .. " [" .. tostring(placeableName(p)) .. "]: " .. table.concat(parts, ", "))
    end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps ~= nil then
        local gotSE, gotMH = false, false
        for _, p in ipairs(ps.placeables) do
            if not gotSE and p.spec_siloExtension ~= nil then dumpSpecScalars("spec_siloExtension", p, p.spec_siloExtension); gotSE = true end
            if not gotMH and p.spec_manureHeap ~= nil then dumpSpecScalars("spec_manureHeap", p, p.spec_manureHeap); gotMH = true end
            if gotSE and gotMH then break end
        end
        if not gotSE then dump("(no spec_siloExtension placeable found -- place a slurry/grain extension first)") end
        if not gotMH then dump("(no spec_manureHeap placeable found -- place a heap/extension first)") end
    end
    return "ext probe done -- see log"
end

-- [dev] dump every production point's selling station + direct-sell outputs and what each price
-- source returns, so we can wire electricity/methane selling through the plant's own selling point.
function SmartDistribution.cmdBiogasProbe(self)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return "no placeableSystem" end
    local function dump(s) print("[SmartDistribution] " .. s) end
    local function scalar(v)
        local t = type(v)
        if t == "number" or t == "string" or t == "boolean" then return tostring(v) end
        return "<" .. t .. ">"
    end
    local function methodList(obj, names)
        local present = {}
        for _, m in ipairs(names) do
            if type(obj) == "table" and type(obj[m]) == "function" then present[#present + 1] = m end
        end
        return #present > 0 and table.concat(present, ",") or "(none)"
    end
    local function tryCall(label, fn)
        local ok, a, b = pcall(fn)
        dump(string.format("        %s -> %s %s%s", label, ok and "ok" or "ERR",
            tostring(a), b ~= nil and (" " .. tostring(b)) or ""))
    end
    local ftm  = g_fillTypeManager
    local econ = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if ftm ~= nil and ftm.getFillTypeIndexByName ~= nil then
        local names = {}
        for _, nm in ipairs({ "ELECTRICCHARGE", "ELECTRICITY", "METHANE", "GAS", "NATURALGAS", "DIGESTATE" }) do
            local idx = ftm:getFillTypeIndexByName(nm)
            if idx ~= nil then names[#names + 1] = nm .. "=" .. tostring(idx) end
        end
        print("[SmartDistribution] energy fillTypes present: " .. (#names > 0 and table.concat(names, ", ") or "(none)"))
    end

    -- locate a selling-station-like object on/under the production point
    local function findStation(pp)
        if type(pp) ~= "table" then return nil, "nil pp" end
        if type(pp.sellingStation) == "table" then return pp.sellingStation, "pp.sellingStation" end
        for k, v in pairs(pp) do
            if type(v) == "table" and (type(v.sellFillType) == "function" or type(v.sellWares) == "function"
               or type(v.getEffectiveFillTypePrice) == "function") then
                return v, "pp." .. tostring(k)
            end
        end
        local op = pp.owningPlaceable
        if type(op) == "table" then
            for k, v in pairs(op) do
                if type(k) == "string" and k:sub(1, 5) == "spec_" and type(v) == "table"
                   and type(v.sellingStation) == "table" then
                    return v.sellingStation, "owningPlaceable." .. k .. ".sellingStation"
                end
            end
        end
        return nil, "(not found)"
    end

    local n = 0
    for _, p in ipairs(ps.placeables) do
        local pp = getProductionPoint(p)
        if pp ~= nil then
            n = n + 1
            dump(string.format("[prod %d] %s  owner=%s  hasStorage=%s", n, tostring(placeableName(p)),
                tostring(p.ownerFarmId), tostring(pp.storage ~= nil)))
            local ds = pp.outputFillTypeIdsDirectSell
            if type(ds) == "table" then
                for ft in pairs(ds) do
                    local mkt
                    if econ ~= nil and econ.getPricePerLiter ~= nil then
                        local ok, v = pcall(function() return econ:getPricePerLiter(ft) end)
                        if ok then mkt = v end
                    end
                    local base
                    if ftm ~= nil and ftm.getFillTypeByIndex ~= nil then
                        local d = ftm:getFillTypeByIndex(ft)
                        if type(d) == "table" then base = d.pricePerLiter end
                    end
                    dump(string.format("   directSell %-14s level=%s  market=%s  fillTypeBase=%s",
                        tostring(fillTypeName(ft)),
                        tostring(pp.storage ~= nil and getLevel(pp.storage, ft) or "?"),
                        tostring(mkt), tostring(base)))
                end
            else
                dump("   outputFillTypeIdsDirectSell = " .. scalar(ds))
            end
            local ss, where = findStation(pp)
            dump("   sellingStation @ " .. tostring(where))
            if type(ss) == "table" then
                dump("      sell-ish methods: " .. methodList(ss, {
                    "sellFillType", "addFillLevelFromTool", "onSellFillType",
                    "getEffectiveFillTypePrice", "getIsFillTypeAllowed", "getIsFillTypeSupported" }))
                local function dumpFtTable(label, t)
                    if type(t) ~= "table" then return end
                    local parts = {}
                    for k, v in pairs(t) do
                        local kn = (type(k) == "number") and tostring(fillTypeName(k)) or tostring(k)
                        parts[#parts + 1] = kn .. "=" .. scalar(v)
                    end
                    if #parts > 0 then dump("      ss." .. label .. ": " .. table.concat(parts, ", ")) end
                end
                dumpFtTable("fillTypePrices", ss.fillTypePrices)
                dumpFtTable("priceMultipliers", ss.priceMultipliers)
                dumpFtTable("moneyChangeType", ss.moneyChangeType)
                dumpFtTable("acceptedFillTypes", ss.acceptedFillTypes)
            end
            -- every output the plant makes: storage level + distribution mode + station price + income type
            local outs = {}
            if type(pp.outputFillTypeIds) == "table" then for ft in pairs(pp.outputFillTypeIds) do outs[ft] = true end end
            if type(pp.outputFillTypeIdsAutoDeliver) == "table" then for ft in pairs(pp.outputFillTypeIdsAutoDeliver) do outs[ft] = true end end
            if type(ds) == "table" then for ft in pairs(ds) do outs[ft] = true end end
            if type(ss) == "table" and type(ss.fillTypePrices) == "table" then for ft in pairs(ss.fillTypePrices) do outs[ft] = true end end
            for ft in pairs(outs) do
                local lvl = (pp.storage ~= nil) and getLevel(pp.storage, ft) or "?"
                local directSell = (type(ds) == "table" and ds[ft]) and "DIRECT_SELL" or "-"
                local mode = "?"
                if type(pp.getOutputDistributionMode) == "function" then
                    local ok, m = pcall(function() return pp:getOutputDistributionMode(ft) end)
                    if ok then mode = m end
                end
                local sp = (type(ss) == "table" and type(ss.fillTypePrices) == "table") and ss.fillTypePrices[ft] or nil
                local mt = (type(ss) == "table" and type(ss.moneyChangeType) == "table") and ss.moneyChangeType[ft] or nil
                dump(string.format("   out %-14s lvl=%s mode=%s %s stationPrice=%s moneyType=%s",
                    tostring(fillTypeName(ft)), tostring(lvl), tostring(mode), directSell, tostring(sp), tostring(mt)))
            end
            -- production chain definitions: every output incl. sellDirectly (electricity/methane)
            local prods = pp.productions
            if type(prods) == "table" then
                for _, prod in ipairs(prods) do
                    local active = false
                    if type(pp.activeProductions) == "table" then
                        for _, ap in ipairs(pp.activeProductions) do
                            if ap == prod or (prod.id ~= nil and ap.id == prod.id) then active = true break end
                        end
                    end
                    dump(string.format("   production '%s' active=%s cyclesPerHour=%s",
                        tostring(prod.name or prod.id or "?"), tostring(active), tostring(prod.cyclesPerHour)))
                    for _, i in ipairs(prod.inputs or {}) do
                        dump(string.format("        in  %-14s amount=%s", tostring(fillTypeName(i.type)), tostring(i.amount)))
                    end
                    for _, o in ipairs(prod.outputs or {}) do
                        dump(string.format("        out %-14s amount=%s sellDirectly=%s",
                            tostring(fillTypeName(o.type)), tostring(o.amount), tostring(o.sellDirectly)))
                    end
                end
            end
            -- full output storage snapshot (what is actually sitting in pp.storage right now)
            if pp.storage ~= nil and type(pp.storage.fillLevels) == "table" then
                local parts = {}
                for ft, lvl in pairs(pp.storage.fillLevels) do
                    parts[#parts + 1] = tostring(fillTypeName(ft)) .. "=" .. tostring(lvl)
                end
                dump("   storage.fillLevels: " .. (#parts > 0 and table.concat(parts, ", ") or "(empty)"))
            end
        end
    end
    if n == 0 then dump("no production points found") end

    if MoneyType ~= nil then
        local mt = {}
        for k, v in pairs(MoneyType) do if type(v) ~= "function" then mt[#mt + 1] = tostring(k) end end
        table.sort(mt)
        dump("MoneyType: " .. table.concat(mt, ", "))
    end
    return "biogas probe done"
end

-- Probe for the seasonal-reserve feature: confirms (1) how to read the current
-- in-game month/period, (2) which fill types are harvested crops (fruitType link)
-- and what growth/harvest fields exist, and (3) the growth system shape. Run once
-- in a real save and read the result from log.txt; nothing is changed.
function SmartDistribution.cmdSeasonProbe(self)
    local function dump(s) print("[SmartDistribution] " .. s) end
    local function scalar(v)
        local t = type(v)
        if t == "number" or t == "string" or t == "boolean" then return tostring(v) end
        return "<" .. t .. ">"
    end
    local function dumpScalars(label, obj, max)
        if type(obj) ~= "table" then dump("  " .. label .. " = " .. scalar(obj)); return end
        dump("  " .. label .. ":")
        local n = 0
        for k, v in pairs(obj) do
            local t = type(v)
            if t == "number" or t == "string" or t == "boolean" then
                dump(string.format("      .%s = %s", tostring(k), tostring(v)))
                n = n + 1; if max and n >= max then dump("      ...(truncated)"); break end
            end
        end
        if n == 0 then dump("      (no scalar fields)") end
    end
    local function tryCall(label, fn)
        local ok, a = pcall(fn)
        dump(string.format("      %s -> %s %s", label, ok and "ok" or "ERR", tostring(a)))
    end

    dump("==== SEASON PROBE ====")
    local m = g_currentMission

    dump("-- 1) current month / period --")
    local env = m ~= nil and m.environment or nil
    dumpScalars("g_currentMission.environment", env, 50)
    if env ~= nil then
        tryCall("env:getPeriod()",        function() return env.getPeriod and env:getPeriod() end)
        tryCall("env.currentPeriod",      function() return env.currentPeriod end)
        tryCall("env.currentMonth",       function() return env.currentMonth end)
        tryCall("env.daysPerPeriod",      function() return env.daysPerPeriod end)
        tryCall("env.currentDayInPeriod", function() return env.currentDayInPeriod end)
        tryCall("env.currentDay",         function() return env.currentDay end)
    end

    dump("-- 2) growth system shape --")
    local gs = (m ~= nil and m.growthSystem) or rawget(_G, "g_growthSystem")
    dumpScalars("growthSystem", gs, 30)

    dump("-- 3) crops: fruitType <-> fillType + harvest/growth fields --")
    local ftm = rawget(_G, "g_fruitTypeManager")
    if ftm == nil then dump("  g_fruitTypeManager == nil"); return "season probe done (no fruitTypeManager)" end
    local list = ftm.fruitTypes or ftm.indexToFruitType or {}
    local count = 0
    for _, fruit in pairs(list) do
        if type(fruit) == "table" then
            local fillName = "?"
            local fillIdx = fruit.fillType or fruit.fillTypeIndex
            if type(fillIdx) == "number" and g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeNameByIndex ~= nil then
                fillName = g_fillTypeManager:getFillTypeNameByIndex(fillIdx) or "?"
            end
            local extra = {}
            for _, key in ipairs({ "numGrowthStates", "minHarvestingGrowthState", "maxHarvestingGrowthState",
                                   "cutState", "minForageGrowthState", "maxWeedState", "plantsWeed" }) do
                if fruit[key] ~= nil then extra[#extra + 1] = key .. "=" .. scalar(fruit[key]) end
            end
            dump(string.format("  fruit '%s'  fill=%s  %s", tostring(fruit.name), tostring(fillName), table.concat(extra, " ")))
            count = count + 1; if count >= 50 then dump("  ...(truncated)"); break end
        end
    end
    tryCall("getFruitTypeIndexByFillTypeIndex(WHEAT)", function()
        local wf = g_fillTypeManager and g_fillTypeManager:getFillTypeIndexByName("WHEAT")
        return ftm.getFruitTypeIndexByFillTypeIndex and ftm:getFruitTypeIndexByFillTypeIndex(wf)
    end)
    return "season probe done"
end

-- ECON PROBE (dev): discover the FS25 price-forecast API so "sell at best price"
-- can find the peak month. Read-only; run `sdEconProbe` in a save, read log.txt.
function SmartDistribution.cmdEconProbe(self)
    local function dump(s) print("[SmartDistribution] " .. s) end
    local function scalar(v)
        local t = type(v)
        if t == "number" or t == "string" or t == "boolean" then return tostring(v) end
        return "<" .. t .. ">"
    end
    -- list a table's keys, split into scalar / function / subtable groups
    local function keysOf(label, obj)
        if type(obj) ~= "table" then dump(label .. " = " .. scalar(obj)); return end
        local sc, fn, tb = {}, {}, {}
        for k, v in pairs(obj) do
            local kn, t = tostring(k), type(v)
            if t == "function" then fn[#fn + 1] = kn
            elseif t == "table" then tb[#tb + 1] = kn
            else sc[#sc + 1] = kn .. "=" .. tostring(v) end
        end
        table.sort(sc); table.sort(fn); table.sort(tb)
        dump(label .. " scalars: " .. table.concat(sc, ", "))
        dump(label .. " funcs:   " .. table.concat(fn, ", "))
        dump(label .. " tables:  " .. table.concat(tb, ", "))
    end
    -- print a table's numeric (array) portion + named scalars + one level of nested arrays
    local function dumpArray(label, t)
        if type(t) ~= "table" then return end
        local maxi = 0
        for k in pairs(t) do if type(k) == "number" and k > maxi then maxi = k end end
        if maxi > 0 then
            local parts = {}
            for i = 1, maxi do parts[#parts + 1] = i .. ":" .. tostring(t[i]) end
            dump(label .. " [array " .. maxi .. "]: " .. table.concat(parts, "  "))
        end
        local named = {}
        for k, v in pairs(t) do
            if type(k) ~= "number" and (type(v) == "number" or type(v) == "string" or type(v) == "boolean") then
                named[#named + 1] = tostring(k) .. "=" .. tostring(v)
            end
        end
        if #named > 0 then dump(label .. " fields: " .. table.concat(named, ", ")) end
        for k, v in pairs(t) do
            if type(v) == "table" then
                local smax = 0
                for kk in pairs(v) do if type(kk) == "number" and kk > smax then smax = kk end end
                if smax > 0 then
                    local parts = {}
                    for i = 1, smax do parts[#parts + 1] = i .. ":" .. tostring(v[i]) end
                    dump(label .. "." .. tostring(k) .. " [array " .. smax .. "]: " .. table.concat(parts, "  "))
                end
            end
        end
    end
    local function tc(label, f)
        local ok, a, b = pcall(f)
        dump("   " .. label .. " -> " .. (ok and "ok " or "ERR ") .. tostring(a) .. (b ~= nil and (" / " .. tostring(b)) or ""))
    end

    local m    = g_currentMission
    local env  = m ~= nil and m.environment or nil
    local econ = m ~= nil and m.economyManager or nil
    local ftm  = g_fillTypeManager

    dump("==== ECON PROBE ====")

    dump("-- 1) current period / month --")
    if env ~= nil then
        tc("env:getPeriod()",         function() return env.getPeriod and env:getPeriod() end)
        tc("env.currentPeriod",       function() return env.currentPeriod end)
        tc("env.currentMonth",        function() return env.currentMonth end)
        tc("env.daysPerPeriod",       function() return env.daysPerPeriod end)
        tc("env.currentDayInPeriod",  function() return env.currentDayInPeriod end)
        tc("env:getDaysPerPeriod()",  function() return env.getDaysPerPeriod and env:getDaysPerPeriod() end)
    else
        dump("   environment == nil")
    end

    dump("-- 2) economyManager surface --")
    if econ ~= nil then
        keysOf("economyManager", econ)
        if EconomyManager ~= nil then keysOf("EconomyManager(static)", EconomyManager) end
        local wf = ftm ~= nil and ftm:getFillTypeIndexByName("WHEAT") or nil
        if wf ~= nil then
            tc("getPricePerLiter(WHEAT)",        function() return econ:getPricePerLiter(wf) end)
            tc("getPricePerLiter(WHEAT,false)",  function() return econ:getPricePerLiter(wf, false) end)
            tc("getPricePerLiter(WHEAT,0)",      function() return econ:getPricePerLiter(wf, 0) end)
            for _, name in ipairs({ "getFillTypePrice", "getPriceForPeriod", "getFillTypePriceTrend",
                                    "getPriceMultiplier", "getFillTypeMultiplier", "getForecast",
                                    "getFillTypePriceForPeriod", "getEstimatedPrice" }) do
                if type(econ[name]) == "function" then
                    tc(name .. "(WHEAT,1)", function() return econ[name](econ, wf, 1) end)
                end
            end
            if EconomyManager ~= nil and type(EconomyManager.getPriceMultiplier) == "function" then
                tc("EconomyManager.getPriceMultiplier(WHEAT)", function() return EconomyManager.getPriceMultiplier(wf) end)
            end
        end
        for _, key in ipairs({ "fillTypePrices", "fillTypePriceHistory", "history", "priceHistory",
                               "fillTypePriceUpdates", "periods", "fillTypeFactors", "forecast" }) do
            if type(econ[key]) == "table" then dumpArray("economyManager." .. key, econ[key]) end
        end
    else
        dump("   economyManager == nil")
    end

    dump("-- 3) per-crop economy curve (deterministic forecast source) --")
    local crops = { "WHEAT", "BARLEY", "OAT", "CANOLA", "MAIZE", "SUNFLOWER", "SOYBEAN", "POTATO",
                    "SUGARBEET", "SUGARCANE", "COTTON", "SORGHUM", "GRASS_WINDROW", "SILAGE", "MILK" }
    for _, nm in ipairs(crops) do
        local idx = ftm ~= nil and ftm:getFillTypeIndexByName(nm) or nil
        if idx ~= nil then
            local d = ftm:getFillTypeByIndex(idx)
            local cur = "?"
            if econ ~= nil and econ.getPricePerLiter ~= nil then
                local ok, v = pcall(function() return econ:getPricePerLiter(idx) end)
                if ok then cur = v end
            end
            dump(string.format("-- %s idx=%s base=%s market=%s --", nm, tostring(idx),
                tostring(d ~= nil and d.pricePerLiter), tostring(cur)))
            if type(d) == "table" then
                if type(d.economy) == "table" then
                    keysOf("   " .. nm .. ".economy", d.economy)
                    dumpArray("   " .. nm .. ".economy", d.economy)
                else
                    dump("   " .. nm .. ".economy = " .. scalar(d ~= nil and d.economy))
                    keysOf("   " .. nm .. " desc", d)
                end
            end
        end
    end

    return "econ probe done"
end

-- Toggle the seasonal harvest reserve and set the fallback horizon (session-scoped):
--   sdSeasonReserve on|off   sdSeasonReserve <months>   sdSeasonReserve  (show)
function SmartDistribution.cmdSeasonReserve(self, arg)
    local g = S.global
    if arg == "on" or arg == "1" or arg == "true" then g.seasonalReserveEnabled = true
    elseif arg == "off" or arg == "0" or arg == "false" then g.seasonalReserveEnabled = false
    elseif arg ~= nil and tonumber(arg) ~= nil then g.seasonalFallbackMonths = math.max(1, math.floor(tonumber(arg))) end
    return string.format("seasonalReserve = %s  (fallback %d months; crops in Distribute+Sell only)",
        tostring(g.seasonalReserveEnabled), g.seasonalFallbackMonths or 13)
end

-- Quick in-game readout to validate the seasonal primitives on the real save:
-- current month, growth flag, and per production-input fill type whether it's a
-- crop, its monthly demand, and total held across the farm.
function SmartDistribution.cmdSeasonStatus(self)
    local function dump(s) print("[SmartDistribution] " .. s) end
    dump(string.format("season status: month=%s  growthEnabled=%s",
        tostring(SmartDistribution.currentMonth()), tostring(SmartDistribution.growthEnabled())))
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil or type(ps.placeables) ~= "table" then return "no placeableSystem" end
    local seen, fts = {}, {}
    for _, p in ipairs(ps.placeables) do
        local pp = getProductionPoint(p)
        if pp ~= nil and type(pp.activeProductions) == "table" then
            for _, prod in ipairs(pp.activeProductions) do
                for _, i in ipairs(prod.inputs or {}) do
                    if i.type ~= nil and not seen[i.type] then seen[i.type] = true; fts[#fts + 1] = i.type end
                end
            end
        end
    end
    table.sort(fts)
    if #fts == 0 then dump("  (no active production inputs found)"); return "season status done" end
    for _, ft in ipairs(fts) do
        local held = 0
        for _, p in ipairs(ps.placeables) do held = held + (SmartDistribution.assetHeld(p, ft) or 0) end
        local hm = S.harvestMonths and S.harvestMonths[ft]
        local win = (type(hm) == "table" and #hm > 0) and table.concat(hm, ",") or "-"
        local cover = SmartDistribution.monthsToCover(hm) or (S.global.seasonalFallbackMonths or 13)
        dump(string.format("  %-16s crop=%-5s demand/mo=%-8.0f heldFarm=%-10.0f harvest={%s} cover=%dmo",
            fillTypeName(ft), tostring(SmartDistribution.isCropFillType(ft)),
            SmartDistribution.monthlyDemand(ft), held, win, cover))
    end
    return "season status done"
end

-- Probe for the production-pallet store gap: for each production point, dump
-- whether it has a pallet spawner, the fill types that spawner emits, each output's
-- asset/virtual mode and whether it's palletized, and any loose pallet vehicles
-- sitting near it (the same world-scan the mover uses). Read-only.
function SmartDistribution.cmdProdPalletProbe(self)
    local function dump(s) print("[SmartDistribution] " .. s) end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return "no placeableSystem" end
    dump("==== PRODUCTION PALLET PROBE ====")
    local function nearbyPallets(p, radius)
        local list = {}
        local vs = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
        if vs == nil or type(vs.vehicles) ~= "table" or p.rootNode == nil then return list end
        local hx, _, hz = getWorldTranslation(p.rootNode)
        local r2 = radius * radius
        for _, v in ipairs(vs.vehicles) do
            if v ~= nil and v.isPallet and v.rootNode ~= nil then
                local vx, _, vz = getWorldTranslation(v.rootNode)
                local dx, dz = vx - hx, vz - hz
                if dx * dx + dz * dz <= r2 then list[#list + 1] = v end
            end
        end
        return list
    end
    local count = 0
    for _, p in ipairs(ps.placeables) do
        local pp = getProductionPoint(p)
        if pp ~= nil then
            local hasSpawner = pp.palletSpawner ~= nil
            local pallets = nearbyPallets(p, 40)
            if hasSpawner or #pallets > 0 then
                count = count + 1
                dump(string.format("PRODUCTION '%s'  palletSpawner=%s  limitReached=%s",
                    placeableName(p), tostring(hasSpawner), tostring(pp.palletLimitReached)))
                if hasSpawner and type(pp.palletSpawner.fillTypeToSpawnPlaces) == "table" then
                    local sf = {}
                    for ft in pairs(pp.palletSpawner.fillTypeToSpawnPlaces) do sf[#sf + 1] = fillTypeName(ft) end
                    dump("    spawner fillTypes: " .. (table.concat(sf, ", ")))
                end
                local outs = {}
                if type(pp.activeProductions) == "table" then
                    for _, prod in ipairs(pp.activeProductions) do
                        for _, o in ipairs(prod.outputs or {}) do outs[o.type] = true end
                    end
                end
                for ft in pairs(outs) do
                    local def = g_fillTypeManager and g_fillTypeManager.indexToFillType and g_fillTypeManager.indexToFillType[ft]
                    dump(string.format("    output %-14s assetMode=%s vmode=%s palletized=%s",
                        fillTypeName(ft), tostring(SmartDistribution.resolvedAssetMode(p, ft)),
                        tostring(SmartDistribution.productionOutputVMode and SmartDistribution.productionOutputVMode(pp, ft)),
                        tostring(def ~= nil and def.palletFilename ~= nil)))
                end
                dump(string.format("    loose pallets within 40m: %d", #pallets))
                local byFt = {}
                for _, v in ipairs(pallets) do
                    local idx = (v.spec_pallet ~= nil and v.spec_pallet.fillUnitIndex) or 1
                    local vft = (v.getFillUnitFillType ~= nil) and v:getFillUnitFillType(idx) or nil
                    local lvl = (v.getFillUnitFillLevel ~= nil) and v:getFillUnitFillLevel(idx) or 0
                    if vft ~= nil then byFt[vft] = (byFt[vft] or 0) + lvl end
                end
                for vft, lvl in pairs(byFt) do
                    dump(string.format("        pallet %s: %.0f L total", fillTypeName(vft), lvl))
                end
            end
        end
    end
    if count == 0 then dump("  (no productions with a pallet spawner or nearby pallets)") end
    return "prod pallet probe done"
end

-- [dev] dump the base-game construction categories so we can copy the production/silo/animal
-- tab icons (sprite filename + UV rect) used by the building-placement menu. The icons live in
-- dataS/menu/construction/ui_construction_icons.png, sliced per-category by UVs we can't read
-- statically (they're sealed in dataS.gar); this reads them straight off g_storeManager at runtime.
function SmartDistribution.cmdIconProbe(self)
    local function dump(s) print("[SmartDistribution] " .. s) end
    local sm = g_storeManager
    if sm == nil then return "no g_storeManager" end
    local cats = sm.constructionCategories or sm.getConstructionCategories and sm:getConstructionCategories() or nil
    if type(cats) ~= "table" then return "no constructionCategories table on g_storeManager" end
    local function numList(t)
        if type(t) ~= "table" then return nil end
        local out, n = {}, 0
        for i = 1, #t do if type(t[i]) == "number" then out[#out + 1] = string.format("%.4f", t[i]); n = n + 1 end end
        if n == 0 then return nil end
        return "{" .. table.concat(out, ", ") .. "}"
    end
    dump(string.format("=== construction categories (%d) ===", #cats))
    for i, c in ipairs(cats) do
        local scal = {}
        for k, v in pairs(c) do
            local t = type(v)
            if t == "string" or t == "number" or t == "boolean" then
                scal[#scal + 1] = tostring(k) .. "=" .. tostring(v)
            end
        end
        table.sort(scal)
        dump(string.format("[%d] %s", i, table.concat(scal, "  ")))
        -- any nested numeric-array fields (UVs, refSize, etc.)
        for k, v in pairs(c) do
            local nl = numList(v)
            if nl ~= nil then dump(string.format("      %s = %s", tostring(k), nl)) end
        end
        -- store categories grouped under this construction category (helps map prod/silo/animal)
        local grouped = c.categories or c.storeCategories
        if type(grouped) == "table" then
            local names = {}
            for _, sc in pairs(grouped) do
                if type(sc) == "table" and sc.name ~= nil then names[#names + 1] = tostring(sc.name)
                elseif type(sc) == "string" then names[#names + 1] = sc end
            end
            if #names > 0 then dump("      groups: " .. table.concat(names, ", ")) end
        end
    end
    return "icon probe done -- see log"
end

function SmartDistribution.cmdMarketProbe(self)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return "no placeableSystem" end
    local function dump(s) print("[SmartDistribution] " .. s) end
    local function scalar(v)
        local t = type(v)
        if t == "number" or t == "string" or t == "boolean" then return tostring(v) end
        return "<" .. t .. ">"
    end
    local myFarm = (g_currentMission.getFarmId ~= nil) and g_currentMission:getFarmId() or nil
    local function keysOf(obj)
        local ks = {}
        if type(obj) == "table" then for k, v in pairs(obj) do ks[#ks + 1] = tostring(k) .. "=" .. scalar(v) end end
        table.sort(ks); return table.concat(ks, ", ")
    end
    local function methodsOf(obj, label)
        if type(obj) ~= "table" then return end
        for _, m in ipairs({ "sellFillType", "getEffectiveFillTypePrice", "getFillTypePrice", "getPricePerLiter",
                             "getIsFillTypeSupported", "getIsFillTypeAllowed", "addFillLevelFromTool", "sellArea",
                             "updateSellPrice", "getFillTypePriceMultiplier", "getAcceptedFillTypes", "sell" }) do
            if type(obj[m]) == "function" then dump("   [" .. label .. "] method: " .. m) end
        end
    end
    local n = 0
    for _, p in ipairs(ps.placeables) do
        local spec = p.spec_sellingStation
        if spec ~= nil then
            n = n + 1
            local owner = (p.getOwnerFarmId ~= nil) and p:getOwnerFarmId() or nil
            dump(string.format("[market %d] %s  ownerFarm=%s (myFarm=%s)", n, tostring(placeableName(p)), tostring(owner), tostring(myFarm)))
            dump("   spec keys: " .. keysOf(spec))
            local st = spec.sellingStation or spec.station or nil
            if type(st) == "table" then dump("   station keys: " .. keysOf(st)) end
            methodsOf(p, "placeable"); methodsOf(st, "station"); methodsOf(spec, "spec")
            local isProd = (getProductionPoint ~= nil) and (getProductionPoint(p) ~= nil) or false
            local function nparams(obj, m)
                if type(obj) == "table" and type(obj[m]) == "function" and debug ~= nil and debug.getinfo ~= nil then
                    local ok, info = pcall(debug.getinfo, obj[m], "u")
                    if ok and type(info) == "table" then return tostring(info.nparams) .. (info.isvararg and "+vararg" or "") end
                end
                return "?"
            end
            dump(string.format("   isProduction=%s isTrainStation=%s storageRadius=%s priceDropPerLiter=%s priceRecoverPerSecond=%s",
                tostring(isProd), tostring(st and st.isTrainStation), tostring(st and st.storageRadius),
                tostring(st and st.priceDropPerLiter), tostring(st and st.priceRecoverPerSecond)))
            if st ~= nil then
                dump(string.format("   nparams: sellFillType=%s addFillLevelFromTool=%s getEffectiveFillTypePrice=%s getIsFillTypeAllowed=%s getIsFillTypeSupported=%s",
                    nparams(st, "sellFillType"), nparams(st, "addFillLevelFromTool"), nparams(st, "getEffectiveFillTypePrice"),
                    nparams(st, "getIsFillTypeAllowed"), nparams(st, "getIsFillTypeSupported")))
            end
            local accepted = (st ~= nil and st.acceptedFillTypes) or spec.acceptedFillTypes or nil
            if type(accepted) == "table" then
                local cnt = 0
                for ft, okv in pairs(accepted) do
                    if okv and cnt < 10 then
                        cnt = cnt + 1
                        local sp, bp = "?", "?"
                        local target = (st ~= nil and type(st.getEffectiveFillTypePrice) == "function") and st or nil
                        if target ~= nil then local ok, a = pcall(function() return target:getEffectiveFillTypePrice(ft) end); if ok then sp = tostring(a) end end
                        if g_currentMission.economyManager ~= nil and g_currentMission.economyManager.getPricePerLiter ~= nil then
                            local ok, a = pcall(function() return g_currentMission.economyManager:getPricePerLiter(ft) end); if ok then bp = tostring(a) end
                        end
                        dump(string.format("   accepts %s  stationPrice=%s basePrice=%s", tostring(fillTypeName(ft)), sp, bp))
                    end
                end
                if cnt == 0 then dump("   acceptedFillTypes table present but empty") end
            else
                dump("   acceptedFillTypes: not a plain table (report this + spec/station keys above)")
            end
        end
    end
    if n == 0 then return "no selling-station placeables found" end
    return "market probe done -- see log.txt"
end

local function installConsole()
    if addConsoleCommand == nil then return end
    addConsoleCommand("sdList", "List placeables: index | uniqueId | name | class | overrides", "cmdList", SmartDistribution)
    addConsoleCommand("sdMode", "Set per-asset mode: sdMode <index> <fillType> <mode>",          "cmdMode", SmartDistribution)
    addConsoleCommand("sdShow", "Show all per-asset overrides currently in memory",               "cmdShow", SmartDistribution)
    addConsoleCommand("sdManage", "Open the distribution manager (list of all configurable assets)", "cmdManage", SmartDistribution)
    addConsoleCommand("sdShedProbe", "Dump Pallet Storage Shed (object storage) structure [dev]", "cmdShedProbe", SmartDistribution)
    addConsoleCommand("sdPalletProbe", "Dump husbandry pallet assets (coops/sheep) + nearest shed [dev]", "cmdPalletProbe", SmartDistribution)
    addConsoleCommand("sdManureProbe", "Dump manure heaps/extensions + barn manure/slurry storage [dev]", "cmdManureProbe", SmartDistribution)
    addConsoleCommand("sdExtProbe", "Dump extension placement methods + siloExtension/manureHeap spec fields [dev]", "cmdExtProbe", SmartDistribution)
    addConsoleCommand("sdBiogasProbe", "Dump production selling station + direct-sell outputs/prices [dev]", "cmdBiogasProbe", SmartDistribution)
    addConsoleCommand("sdSpawn", "Spawn pallets from a production's held stock: sdSpawn <index> <fillType> [count]", "cmdSpawn", SmartDistribution)
    addConsoleCommand("sdSeasonProbe", "Dump current month/period + crop fill-type mapping + growth fields [dev]", "cmdSeasonProbe", SmartDistribution)
    addConsoleCommand("sdSeasonStatus", "Show current month + per-crop monthly demand and farm-held [dev]", "cmdSeasonStatus", SmartDistribution)
    addConsoleCommand("sdSeasonReserve", "Toggle seasonal harvest reserve: sdSeasonReserve on|off|<months>", "cmdSeasonReserve", SmartDistribution)
    addConsoleCommand("sdProdPalletProbe", "Dump production pallet spawners + nearby loose pallets + modes [dev]", "cmdProdPalletProbe", SmartDistribution)
    addConsoleCommand("sdEconProbe", "Dump economy price forecast/curve API for best-price selling [dev]", "cmdEconProbe", SmartDistribution)
    addConsoleCommand("sdIconProbe", "Dump construction-menu category icons (sprite + UVs) for tab matching [dev]", "cmdIconProbe", SmartDistribution)
end

-- ============================================================================
-- IN-WORLD CYCLE INTERACTION  (MVP for the per-silo dialog)
-- Piggybacks the silo's own player trigger: while near an owned silo, a bound
-- key cycles that silo's held fill types through Distribute -> Hold ->
-- Distribute+Sell -> Sell, routed through applyAssetMode (MP sync + persists on
-- save). Leaves the vanilla "Refill Silo" interaction untouched.
-- GUI/input cannot be harness-tested; uncertain calls are pcall-guarded and
-- logged so the in-game log shows exactly what resolved. [VERIFY] tags mark them.
-- ============================================================================
local MODE_NAMES = { [0]="Inherit", [1]="Hold", [2]="Distribute", [3]="Distribute + Sell", [4]="Sell", [5]="Distribute + Store", [6]="Store", [7]="Market Supply", [8]="Distribute + Market Supply", [9]="Hold Internal", [10]="Move To", [11]="Distribute + Move To" }
-- For a palletisable production output, plain Hold lets the engine auto-spawn pallets, so we surface it as
-- "Hold Pallets" to distinguish it from Hold Internal (keep as bulk, no spawn). Non-palletisable outputs
-- (silos, bulk goods) keep the plain "Hold" label since there are no pallets to differentiate.
function SmartDistribution.modeName(m, palletizable)
    if m == MODE.HOLD and palletizable then return "Hold Pallets" end
    return MODE_NAMES[m] or ("mode" .. tostring(m))
end

-- store-capable = a valid storePhase SOURCE (production output or husbandry output)
local function assetCanStore(asset)
    local c = getAssetClass(asset)
    return c == "PRODUCTION" or c == "HUSBANDRY"
end

-- Mode cycle ring. Distribute+Store is only offered for store-capable assets; a
-- plain silo can't store-cascade to another silo, so it keeps the 4-mode ring and
-- never lands on Distribute+Store.
local function cycleNext(m, includeStore, includeMarket, includePallets)
    if m == MODE.DISTRIBUTE       then return MODE.HOLD end
    if m == MODE.HOLD             then return includePallets and MODE.HOLD_INTERNAL or MODE.DISTRIBUTE_SELL end
    if m == MODE.HOLD_INTERNAL    then return MODE.DISTRIBUTE_SELL end
    if m == MODE.DISTRIBUTE_SELL  then return MODE.SELL end
    if m == MODE.SELL then
        if includeStore  then return MODE.DISTRIBUTE_STORE end
        return MODE.DISTRIBUTE_STORE_TO
    end
    if m == MODE.DISTRIBUTE_STORE then return MODE.STORE end
    if m == MODE.STORE            then return MODE.DISTRIBUTE_STORE_TO end
    -- Store To pair sits after the auto-Store pair; cycleNextForAsset skips whichever has no endpoint
    -- (e.g. Store To is only meaningful for a silo/shed that has somewhere to push to).
    if m == MODE.DISTRIBUTE_STORE_TO then return MODE.STORE_TO end
    if m == MODE.STORE_TO         then return includeMarket and MODE.TRANSFER_MARKET or MODE.DISTRIBUTE end
    if m == MODE.TRANSFER_MARKET   then return MODE.DISTRIBUTE_MARKET end
    if m == MODE.DISTRIBUTE_MARKET then return MODE.DISTRIBUTE end
    return MODE.HOLD
end

function SmartDistribution.notify(text, colour)
    log("%s", text)                         -- always log, so the chain is visible
    local m = g_currentMission
    if m == nil then return end
    if m.hud ~= nil and m.hud.addSideNotification ~= nil then   -- [VERIFY] FS25 signature
        colour = colour or (FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_OK) or nil
        if pcall(function() m.hud:addSideNotification(colour, text, 7500) end) then return end
    end
    if m.showBlinkingWarning ~= nil then     -- [VERIFY] fallback
        pcall(function() m:showBlinkingWarning(text, 7500) end)
    end
end

-- ALL supported fill types of a silo, so distribution can be configured before
-- anything is stored - not just what it currently holds.
local function siloFillTypes(silo)
    local fts, any = {}, false
    local spec = silo.spec_silo
    if spec ~= nil and spec.storages ~= nil then
        for _, storage in pairs(spec.storages) do
            if storage.fillTypes ~= nil then
                for ft in pairs(storage.fillTypes) do fts[ft] = true; any = true end
            end
        end
    end
    if not any and silo.fillTypes ~= nil then          -- fallback: placeable-level supported set
        for ft in pairs(silo.fillTypes) do fts[ft] = true; any = true end
    end
    return fts, any
end

-- does a husbandry have a STORAGE SLOT for ft? a supported-set entry, a capacity
-- entry (our manure patch adds one), or a non-zero level all count. Lets empty
-- manure show for configuration without inventing outputs the barn can't hold.
local function husbandryStoresFillType(p, ft)
    for _, storage in ipairs(getAllStorages(p)) do
        if storage.fillTypes  ~= nil and storage.fillTypes[ft]  then return true end
        if storage.capacities ~= nil and storage.capacities[ft] ~= nil then return true end
        if (storageFillTypes(storage)[ft] or 0) > 0 then return true end
    end
    return false
end

-- ALL output fill types a husbandry can ever distribute, shown so the player can
-- configure them BEFORE any are produced: milk variants + liquid manure (from the
-- barn's own specs) + any manure-family type the barn has a storage slot for. Empty
-- manure appears (the slot exists); types the barn can't hold (e.g. slurry on a cow)
-- do not.
local function husbandryConfigFillTypes(p)
    local fts, any = {}, false
    if p.spec_husbandryMilk ~= nil and p.spec_husbandryMilk.fillTypes ~= nil then
        for _, ft in ipairs(p.spec_husbandryMilk.fillTypes) do fts[ft] = true; any = true end
    end
    if p.spec_husbandryLiquidManure ~= nil and p.spec_husbandryLiquidManure.fillType ~= nil then
        fts[p.spec_husbandryLiquidManure.fillType] = true; any = true
    end
    for ft in pairs(outputNamedSet()) do
        if husbandryStoresFillType(p, ft) then fts[ft] = true; any = true end
    end
    -- pallet-spawner outputs on a husbandry: chicken EGGS, sheep WOOL (item 5 step a).
    -- These live as physical FillUnit pallets, not in a Storage, so listing them here
    -- only lets the asset take a mode -- the palletPhase that actually moves them is a
    -- later step. spec.fillTypes is the array of pallet fill type indices.
    if p.spec_husbandryPallets ~= nil and p.spec_husbandryPallets.fillTypes ~= nil then
        for _, ft in ipairs(p.spec_husbandryPallets.fillTypes) do fts[ft] = true; any = true end
    end
    return fts, any
end

-- generalized lister used by the dialog + cycle key: dispatch on asset class.
-- Silos list held/allowed fill types; husbandry lists its outputs. (Productions
-- get folded in later; OTHER returns empty so the lookup simply skips them.)
-- A manure heap lists exactly MANURE (its single supported type), shown whether empty or not so it
-- can be configured before any manure accumulates -- mirrors how slurry lists on a barn.
local function heapFillTypes(p)
    local hs = manureHeapStorage(p)
    if hs == nil then return {}, false end
    local set = {}
    if hs.getSupportedFillTypes ~= nil then
        local ok, t = pcall(hs.getSupportedFillTypes, hs)
        if ok and type(t) == "table" then for ft in pairs(t) do set[ft] = true end end
    end
    if next(set) == nil and hs.fillTypeIndex ~= nil then set[hs.fillTypeIndex] = true end
    return set, next(set) ~= nil
end

-- ALL output fill types a production point makes (incl. auto-deliver outputs),
-- shown so each output's mode can be set from the distribution dialog, mirroring
-- the vanilla production screen's output list.
local function productionOutputFillTypes(p)
    local pp = getProductionPoint(p)
    if pp == nil then return {}, false end
    local set = {}
    if type(pp.outputFillTypeIds) == "table" then for ft in pairs(pp.outputFillTypeIds) do set[ft] = true end end
    if type(pp.outputFillTypeIdsAutoDeliver) == "table" then for ft in pairs(pp.outputFillTypeIdsAutoDeliver) do set[ft] = true end end
    return set, next(set) ~= nil
end

local function assetConfigFillTypes(p)
    if p == nil then return {}, false end
    if getProductionPoint(p) ~= nil then return productionOutputFillTypes(p) end
    if p.spec_silo ~= nil then return siloFillTypes(p) end
    if isManurePit(p) then return heapFillTypes(p) end
    if isHusbandryBuilding(p) then return husbandryConfigFillTypes(p) end
    if isBeehiveSpawner(p) then                          -- beehive honey spawner: single HONEY output
        local set, bs = {}, p.spec_beehivePalletSpawner
        if bs ~= nil and bs.fillType ~= nil then set[bs.fillType] = true end
        return set, next(set) ~= nil
    end
    if p.spec_objectStorage ~= nil then return shedStoredFillTypes(p) end
    return {}, false
end

-- menu / cycle-facing fill-type set: identical to assetConfigFillTypes EXCEPT a pallet shed expands to
-- every network-supplyable + shed-accepted type (so empty types can be pre-configured). The allocator
-- keeps using assetConfigFillTypes (stored-only for sheds), so seasonal budget / sell passes are unchanged.
function SmartDistribution.assetMenuFillTypes(p)
    if p ~= nil and p.spec_objectStorage ~= nil then return SmartDistribution.shedSupportedFillTypes(p) end
    return assetConfigFillTypes(p)
end

-- ---- endpoint gating: never offer a mode with nowhere to send the product -----------------------
-- A mode is only meaningful if something in the world can actually receive that fill type. Slurry with
-- no market that takes slurry should not offer Market Supply; a product nothing buys should not offer
-- Sell, and so on. Each check is per (asset, fill type) and honours the asset's reach, so the answer
-- matches what the hourly pass would really do. Used by the mode cycle + the menu labels.
function SmartDistribution.hasMarketEndpoint(asset, ft)
    if asset == nil or ft == nil or asset.rootNode == nil then return false end
    local farmId = SmartDistribution._ownerFarmId(asset)
    local x, _, z = getWorldTranslation(asset.rootNode)
    local ms = SmartDistribution.marketsFor(farmId, ft, x, z, resolveReach(asset))
    return ms ~= nil and #ms > 0
end

function SmartDistribution.hasStoreEndpoint(asset, ft)
    if asset == nil or ft == nil or asset.rootNode == nil then return false end
    if not assetCanStore(asset) then return false end            -- class can't store-cascade at all
    local farmId = SmartDistribution._ownerFarmId(asset)
    local x, _, z = getWorldTranslation(asset.rootNode)
    local sinks = gatherSinks(asset, ft, x, z, farmId, resolveReach(asset))
    if sinks ~= nil and #sinks > 0 then return true end
    -- palletized outputs (bottled milk, bread, ...) store into pallet sheds, which gatherSinks does not
    -- return -- check those too, or Store would look endpoint-less and enforceValidModes would revert it.
    local shedSinks = gatherShedSinks(asset, ft, x, z, farmId, resolveReach(asset))
    return shedSinks ~= nil and #shedSinks > 0
end

-- something in the game actually buys this fill type
function SmartDistribution.hasSellEndpoint(asset, ft)
    if ft == nil then return false end
    local econ = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if econ == nil or econ.getPricePerLiter == nil then return true end   -- unknown -> don't hide the option
    local ok, price = pcall(econ.getPricePerLiter, econ, ft)
    return ok and (price or 0) > 0
end

-- some other building in the network would take this fill type as an input
function SmartDistribution.hasDistributeEndpoint(asset, ft)
    if asset == nil or ft == nil then return false end
    local uid = getUid(asset)
    if uid == nil then return false end
    local sinks = SmartDistribution.sinksFor(uid, ft)
    return sinks ~= nil and #sinks > 0
end

-- Store To is meaningful when this asset is itself a store (silo / shed) AND some OTHER store on the
-- farm can hold the product -- i.e. there is somewhere to push to. It is offered even before the player
-- has chosen any targets (the outputs indicator tells them none are set yet); what would make it a dead
-- end is having nowhere at all it could ever push.
function SmartDistribution.hasStoreToEndpoint(asset, ft)
    if asset == nil or ft == nil then return false end
    -- Store To is meaningful when some OTHER store can physically receive the product in the SAME form
    -- (bulk->bulk or pallet->pallet). Offered even before targets are chosen; a dead end is having
    -- nowhere it could ever push. Form follows how the source currently holds it; on an empty store we
    -- fall back to its declared capability so the mode can be pre-configured.
    local form = SmartDistribution.sourceHoldForm ~= nil and SmartDistribution.sourceHoldForm(asset, ft) or nil
    if form == nil then
        if asset.spec_objectStorage ~= nil then form = "PALLET"
        elseif SmartDistribution.assetHoldsFillType ~= nil and SmartDistribution.assetHoldsFillType(asset, ft) then form = "BULK"
        else
            if SmartDistribution._storeToDebug then SmartDistribution.log("storeto? %s [%s]: no form (holds nothing)", placeableName(asset), fillTypeName(ft)) end
            return false
        end
    end
    local myFarm = SmartDistribution._ownerFarmId(asset)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return false end
    for _, p in ipairs(ps.placeables) do
        if p ~= asset and p.rootNode ~= nil and isEnrolled(p)
           and SmartDistribution._ownerFarmId(p) == myFarm
           and SmartDistribution.storeToTargetValid ~= nil and SmartDistribution.storeToTargetValid(form, p, ft) then
            return true
        end
    end
    if SmartDistribution._storeToDebug then SmartDistribution.log("storeto? %s [%s] form=%s: no compatible target found", placeableName(asset), fillTypeName(ft), tostring(form)) end
    return false
end

-- Is a mode meaningful for this (asset, fill type)? Hold is always allowed (it is the "do nothing"
-- state); every other mode needs a live endpoint for EACH thing it does. A combined mode requires BOTH
-- halves: Distribute+Market with no market that takes the product is just Distribute, so we only offer
-- the single mode and never the misleading pair.
function SmartDistribution.modeHasEndpoint(asset, ft, m)
    local M = MODE
    if m == M.HOLD or m == M.INHERIT or m == M.HOLD_INTERNAL then return true end
    local dist   = SmartDistribution.hasDistributeEndpoint(asset, ft)
    local sell   = SmartDistribution.hasSellEndpoint(asset, ft)
    local store  = SmartDistribution.hasStoreEndpoint(asset, ft)
    local market = SmartDistribution.hasMarketEndpoint(asset, ft)
    -- Move To (Store To) is an Advanced-routing feature -- configured in the Advanced Outputs dialog and
    -- driven by the block/priority model -- so it is only offered when the Advanced routing master switch is
    -- on. With it off, STORE_TO / DISTRIBUTE_STORE_TO report no endpoint, so the mode cycle skips them and
    -- enforceValidModes reverts any existing Move To output back to Hold.
    local storeTo = SmartDistribution.advancedEnabled() and SmartDistribution.hasStoreToEndpoint(asset, ft)
    if m == M.DISTRIBUTE         then return dist end
    if m == M.SELL               then return sell end
    if m == M.STORE              then return store end
    if m == M.TRANSFER_MARKET    then return market end
    if m == M.STORE_TO           then return storeTo end
    if m == M.DISTRIBUTE_SELL    then return dist and sell end
    if m == M.DISTRIBUTE_STORE   then return dist and store end
    if m == M.DISTRIBUTE_MARKET  then return dist and market end
    if m == M.DISTRIBUTE_STORE_TO then return dist and storeTo end
    return true
end

-- exposed for the per-asset dialog (DistributionSiloDialog.lua)
SmartDistribution.log            = log
SmartDistribution.cycleNext      = cycleNext
-- Step the ring, skipping any mode with no endpoint for this fill type (so e.g. slurry never lands on a
-- market mode when no market takes slurry). ft is optional: without it the old, ungated ring is used.
function SmartDistribution.cycleNextForAsset(asset, m, ft)   -- store-aware + pallet-aware (Hold Internal only where the asset spawns pallets)
    local step = function(cur)
        return cycleNext(cur, assetCanStore(asset), SmartDistribution.assetHasMarket(asset), palletSpawnerFillTypes(asset) ~= nil)
    end
    local nxt = step(m)
    if ft == nil then return nxt end
    for _ = 1, 12 do                                          -- ring is 10 long; the cap is a backstop
        if SmartDistribution.modeHasEndpoint(asset, ft, nxt) then return nxt end
        nxt = step(nxt)
        if nxt == m then return m end                         -- full lap: nothing else is valid, stay put
    end
    return nxt
end
SmartDistribution.siloFillTypes  = siloFillTypes
SmartDistribution.assetFillTypes = assetConfigFillTypes        -- allocator view (sheds: stored only)

-- "Cycle all" target: if every current mode is identical, advance it one step;
-- if they differ, unify to the anchor (first) mode WITHOUT stepping. So the first
-- click makes a mixed group uniform, and the next click steps them together.
local function bulkCycleTarget(modes, anchor, step)
    if #modes == 0 then return anchor end
    for i = 2, #modes do if modes[i] ~= modes[1] then return anchor end end
    return step(modes[1])
end

-- ---- productions: point accessor + class check + whole-plant on/off state ----
-- (output MODE for productions is driven through ProductionDistributeSell's shared
-- 5-state virtual mode, not the generic applyAssetMode path; the dialog dispatches
-- on isProductionAsset.)
function SmartDistribution.productionPointOf(p) return getProductionPoint(p) end
function SmartDistribution.isProductionAsset(p) return getProductionPoint(p) ~= nil end

-- whole-plant on/off + run status (all production lines together). enabled = at
-- least one line active; running = at least one actually producing. Fully guarded.
function SmartDistribution.productionInfo(p)
    local pp = getProductionPoint(p)
    if pp == nil then return nil end
    local total   = (type(pp.productions) == "table") and #pp.productions or 0
    local active  = (type(pp.activeProductions) == "table") and #pp.activeProductions or 0
    local running = 0
    local RUN = (ProductionPoint ~= nil and ProductionPoint.PROD_STATUS ~= nil and ProductionPoint.PROD_STATUS.RUNNING) or 1
    if type(pp.activeProductions) == "table" then
        for _, ap in ipairs(pp.activeProductions) do
            if ap.status == RUN then running = running + 1 end
        end
    end
    local enabled = active > 0
    local status  = (not enabled) and "Off" or (running > 0 and "Running" or "Idle")
    return { enabled = enabled, status = status, total = total, active = active, running = running }
end

-- turn the whole plant on/off (every line). Vanilla setProductionState broadcasts
-- its own MP event and persists, so we just drive it. [VERIFY MP]
function SmartDistribution.setProductionEnabled(p, on)
    local pp = getProductionPoint(p)
    if pp == nil or pp.setProductionState == nil or type(pp.productions) ~= "table" then return false end
    for _, prod in ipairs(pp.productions) do
        if prod.id ~= nil then pcall(function() pp:setProductionState(prod.id, on and true or false) end) end
    end
    return true
end

-- ---- per-line detail (for DistributionProductionDialog) --------------------
-- One descriptor per production LINE: name, on/off + run status, and each input /
-- output with its currently-held amount (shared plant storage) + per-month rate
-- (cyclesPerMonth x amount) + the output's 5-state mode label. Reads are guarded.
local function ftTitle(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local def = g_fillTypeManager:getFillTypeByIndex(ft)
        if def ~= nil and def.title ~= nil then return def.title end
    end
    return tostring(ft)
end

function SmartDistribution.productionLines(p)
    local pp = getProductionPoint(p)
    if pp == nil or type(pp.productions) ~= "table" then return {} end
    local RUN = (ProductionPoint ~= nil and ProductionPoint.PROD_STATUS ~= nil and ProductionPoint.PROD_STATUS.RUNNING) or 1
    local activeSet, activeStatus = {}, {}
    if type(pp.activeProductions) == "table" then
        for _, ap in ipairs(pp.activeProductions) do
            if ap.id ~= nil then activeSet[ap.id] = true; activeStatus[ap.id] = ap.status end
        end
    end
    local function held(ft)
        local s = pp.storage
        if s ~= nil and s.getFillLevel ~= nil then
            local ok, lvl = pcall(s.getFillLevel, s, ft)
            if ok and type(lvl) == "number" then return lvl end
        end
        return 0
    end
    local function cap(ft) return storageCapacity(pp.storage, ft) end
    local out = {}
    for _, prod in ipairs(pp.productions) do
        local id = prod.id
        local enabled = id ~= nil and activeSet[id] == true
        local st = enabled and (activeStatus[id] or prod.status) or nil
        local status = (not enabled) and "Off" or (st == RUN and "Running" or "Idle")
        local cpm = prod.cyclesPerMonth or (prod.cyclesPerHour ~= nil and prod.cyclesPerHour * 24) or 1440
        local cph = prod.cyclesPerHour
        if (cph == nil or cph == 0) and prod.cyclesPerMonth ~= nil then
            local env = g_currentMission ~= nil and g_currentMission.environment or nil
            local dpp = (env ~= nil and env.daysPerPeriod) or 1
            if dpp and dpp > 0 then cph = prod.cyclesPerMonth / (dpp * 24) end
        end
        cph = cph or 0
        local inputs = {}
        for _, i in ipairs(prod.inputs or {}) do
            inputs[#inputs + 1] = { ft = i.type, name = ftTitle(i.type), held = held(i.type), capacity = cap(i.type), amount = i.amount or 0, perMonth = (i.amount or 0) * cpm }
        end
        local outputs = {}
        for _, o in ipairs(prod.outputs or {}) do
            local vmode, vname
            if SmartDistribution.productionOutputVMode ~= nil then
                vmode = SmartDistribution.productionOutputVMode(pp, o.type)
                vname = SmartDistribution.productionOutputVModeName(vmode)
                -- Hold and Hold Internal both collapse to vanilla KEEP above, so name them from the DR mode.
                local drMode = SmartDistribution.resolvedAssetMode ~= nil and SmartDistribution.resolvedAssetMode(p, o.type) or nil
                if drMode == MODE.HOLD_INTERNAL then vname = "Hold Internal"
                elseif drMode == MODE.HOLD and palletSpawnerFillTypes(p) ~= nil then vname = "Hold Pallets" end
            end
            outputs[#outputs + 1] = { ft = o.type, name = ftTitle(o.type), held = held(o.type), capacity = cap(o.type), amount = o.amount or 0,
                                      perMonth = (o.amount or 0) * cpm, perHour = (o.amount or 0) * cph, mode = vmode, modeName = vname, sellDirectly = o.sellDirectly }
        end
        local label = prod.name
        if (label == nil or label == "") and outputs[1] ~= nil then label = outputs[1].name end
        if label == nil or label == "" then label = "Line " .. tostring(#out + 1) end
        out[#out + 1] = { id = id, name = label, index = prod.index, enabled = enabled,
                          status = status, cyclesPerMonth = cpm, inputs = inputs, outputs = outputs }
    end
    return out
end

-- toggle ONE production line on/off (vanilla owns persist + MP). [VERIFY MP]
function SmartDistribution.setProductionLineEnabled(p, id, on)
    local pp = getProductionPoint(p)
    if pp == nil or pp.setProductionState == nil or id == nil then return false end
    return pcall(function() pp:setProductionState(id, on and true or false) end)
end

-- cycle ONE line's output mode(s) through the shared 5-state seam (synced to the
-- production screen). Advances every output of the line together.
function SmartDistribution.cycleProductionLineOutput(p, id)
    local pp = getProductionPoint(p)
    if pp == nil or SmartDistribution.productionOutputVMode == nil then return false end
    local prod = (type(pp.productionsIdToObj) == "table") and pp.productionsIdToObj[id] or nil
    if prod == nil then return false end
    local outs = {}
    for _, o in ipairs(prod.outputs or {}) do outs[#outs + 1] = o.type end
    if #outs == 0 then return true end
    local modes = {}
    for i, ft in ipairs(outs) do modes[i] = SmartDistribution.productionOutputVMode(pp, ft) or 0 end
    local target = bulkCycleTarget(modes, modes[1], function(v) return (v + 1) % 6 end)
    for _, ft in ipairs(outs) do
        if SmartDistribution.setProductionOutputMode ~= nil then
            SmartDistribution.setProductionOutputMode(pp, ft, target)
        else
            SmartDistribution.cycleProductionOutputMode(pp, ft)   -- fallback if PDS set API missing
        end
    end
    return true
end

-- ---- asset dialog: held + last-cycle distributed/sold/stored ---------------
-- current held liters of ft across an asset's storages, plus shed (object
-- storage) and pallet-spawner (eggs/wool/honey) holdings. Guarded; never throws.
-- Eggs / wool / honey a pallet-spawner husbandry holds INTERNALLY but hasn't materialised as pallets: the
-- base game's per-fill-type pending queue (spec_husbandryPallets.pendingLiters[ft]; a scalar on a beehive
-- spawner). Normally near zero -- updatePallets drains it into pallets each tick -- but under Hold Internal
-- DR suppresses that spawn, so produced eggs pile up here instead. Counting it as held makes the amount
-- VISIBLE and growing (else the display sits on the frozen spawned-pallet total) and keeps the husbandry
-- produced-throughput stat correct. It is NOT a distributable source: gatherSources still pulls only real
-- spawned pallets (palletFillLevel), so nothing tries to drain this queue directly.
function SmartDistribution.palletPendingLiters(p, ft)
    if p == nil or ft == nil then return 0 end
    local hs = p.spec_husbandryPallets
    if hs ~= nil and type(hs.pendingLiters) == "table" then
        local v = hs.pendingLiters[ft]; if type(v) == "number" then return v end
    end
    local bs = p.spec_beehivePalletSpawner
    if bs ~= nil and bs.fillType == ft and type(bs.pendingLiters) == "number" then return bs.pendingLiters end
    return 0
end

function SmartDistribution.assetHeld(p, ft)
    if p == nil or ft == nil then return 0 end
    local total = 0
    local okS, storages = pcall(getAllStorages, p)
    if okS and type(storages) == "table" then
        for _, storage in ipairs(storages) do total = total + (getLevel(storage, ft) or 0) end
    end
    if p.spec_objectStorage ~= nil and shedStoredLiters ~= nil then
        local ok, v = pcall(shedStoredLiters, p, ft); if ok and type(v) == "number" then total = total + v end
    end
    if (p.spec_husbandryPallets ~= nil or p.spec_beehivePalletSpawner ~= nil) and palletFillLevel ~= nil then
        -- Under Hold Internal the "held" is the INTERNAL buffer only (pending litres): a manually spawned
        -- pallet is released physical inventory to be collected, so counting it too would freeze the number
        -- after a spawn (buffer drops, pallet rises, total unchanged). Buffer-only makes held GROW as eggs
        -- accumulate and DROP by a pallet's worth on each spawn. Other modes: the pallets ARE the inventory
        -- (the buffer drains to them immediately, so it's ~0), so count those instead.
        local holdInternal = SmartDistribution.resolvedAssetMode ~= nil and MODE ~= nil
            and SmartDistribution.resolvedAssetMode(p, ft) == MODE.HOLD_INTERNAL
        if holdInternal then
            total = total + SmartDistribution.palletPendingLiters(p, ft)
        else
            local ok, v = pcall(palletFillLevel, p, ft); if ok and type(v) == "number" then total = total + v end
        end
    end
    return total
end

-- distributed / sold / stored liters for (asset, ft) in the last completed hourly
-- cycle (host-side; clients don't run the pass). Returns three numbers.
function SmartDistribution.lastCycleStats(p, ft)
    local lc = S.lastCycle
    if lc == nil or p == nil or ft == nil then return 0, 0, 0 end
    local a = lc[getUid(p)]
    local e = a ~= nil and a[ft] or nil
    if e == nil then return 0, 0, 0 end
    return e.dist or 0, e.sold or 0, e.stored or 0
end

-- liters RECEIVED from distribution for (asset, ft) in the last completed cycle
-- (recipient side -- e.g. liters that arrived into a production's input storage).
function SmartDistribution.lastCycleReceived(p, ft)
    local lc = S.lastCycle
    if lc == nil or p == nil or ft == nil then return 0 end
    local a = lc[getUid(p)]
    local e = a ~= nil and a[ft] or nil
    return e ~= nil and (e.received or 0) or 0
end

-- MONTHLY (rolling 24-cycle) distributed / sold / stored for (asset, ft): the same per-cycle
-- deltas as lastCycleStats, summed over the last MONTHLY_CYCLES completed cycles. Persisted.
function SmartDistribution.monthlyStats(p, ft)
    if p == nil or ft == nil then return 0, 0, 0, 0 end
    local uid = getUid(p)
    if clientMonthly ~= nil then                                  -- client: read the synced aggregate
        local au = clientMonthly[uid]; local e = au ~= nil and au[ft] or nil
        if e == nil then return 0, 0, 0, 0 end
        return e.dist or 0, e.sold or 0, e.stored or 0, e.money or 0
    end
    local d, s, st, mo = 0, 0, 0, 0
    for i = 1, MONTHLY_CYCLES do
        local snap = monthlyRing[i]
        local a = snap ~= nil and snap[uid] or nil
        local e = a ~= nil and a[ft] or nil
        if e ~= nil then d = d + (e.dist or 0); s = s + (e.sold or 0); st = st + (e.stored or 0); mo = mo + (e.money or 0) end
    end
    return d, s, st, mo
end

-- MONTHLY (rolling 24-cycle) received for (asset, ft); mirror of lastCycleReceived. Persisted.
function SmartDistribution.monthlyReceived(p, ft)
    if p == nil or ft == nil then return 0 end
    local uid = getUid(p)
    if clientMonthly ~= nil then                                  -- client: read the synced aggregate
        local au = clientMonthly[uid]; local e = au ~= nil and au[ft] or nil
        return e ~= nil and (e.received or 0) or 0
    end
    local r = 0
    for i = 1, MONTHLY_CYCLES do
        local snap = monthlyRing[i]
        local a = snap ~= nil and snap[uid] or nil
        local e = a ~= nil and a[ft] or nil
        if e ~= nil then r = r + (e.received or 0) end
    end
    if SmartDistribution._monthlyDebug then
        local parts = {}
        for i = 1, MONTHLY_CYCLES do
            local snap = monthlyRing[i]; local a = snap ~= nil and snap[uid] or nil; local e = a ~= nil and a[ft] or nil
            parts[#parts+1] = string.format("%d", (e ~= nil and (e.received or 0)) or 0)
        end
        SmartDistribution.log("monthlyRecv %s [%s] pos=%d sum=%d slots=[%s]", placeableName(p), fillTypeName(ft), monthlyPos, r, table.concat(parts, ","))
    end
    return r
end

-- Aggregate SOLD liters + money per fill type across ALL assets, for Production Redux.
-- window = "hour"  -> the last completed cycle (S.lastCycle)
--          "month" -> the rolling 24-cycle window (monthlyRing; clientMonthly on an MP client)
-- Returns { [fillTypeIndex] = { sold = <liters>, money = <currency> }, ... }. Server-authoritative
-- for "hour" (clients don't run the pass, so their lastCycle is empty); "month" also works on clients
-- via the synced clientMonthly aggregate. Read-only; never mutates the ring.
function SmartDistribution.salesByProduct(window)
    local out = {}
    local function add(ft, sold, money)
        if ft == nil then return end
        sold = sold or 0; money = money or 0
        if sold == 0 and money == 0 then return end
        local e = out[ft]
        if e == nil then e = { sold = 0, money = 0 }; out[ft] = e end
        e.sold  = e.sold  + sold
        e.money = e.money + money
    end
    local function scan(byUid)
        if type(byUid) ~= "table" then return end
        for _, byFt in pairs(byUid) do
            if type(byFt) == "table" then
                for ft, e in pairs(byFt) do
                    if type(e) == "table" then add(ft, e.sold, e.money) end
                end
            end
        end
    end

    if window == "hour" then
        scan(S.lastCycle)                                  -- last completed cycle (host-side)
    elseif clientMonthly ~= nil then
        scan(clientMonthly)                                -- MP client: synced monthly aggregate
    else
        for i = 1, MONTHLY_CYCLES do scan(monthlyRing[i]) end   -- server/SP: sum the 24-cycle ring
    end
    return out
end

-- Per-ASSET sold liters + money for Production Redux's expanded Product Sales view.
-- Like salesByProduct, but keeps the placeable dimension so the UI can show one row
-- per selling asset. Each uid is resolved to its placeable for a display name + shop
-- image. window = "hour" (last cycle) | "month" (24-cycle window / client aggregate).
-- Returns an ARRAY: { { ft=, uid=, assetName=, assetIcon=, sold=, money= }, ... }.
function SmartDistribution.salesByAsset(window)
    local byUid = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps ~= nil and ps.placeables ~= nil then
        for _, p in ipairs(ps.placeables) do
            if p ~= nil and p.rootNode ~= nil then byUid[getUid(p)] = p end
        end
    end

    local function storeItemOf(p)
        if p == nil then return nil end
        if type(p.storeItem) == "table" then return p.storeItem end
        if p.configFileName ~= nil and g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil then
            local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, p.configFileName)
            if ok and type(item) == "table" then return item end
        end
        return nil
    end
    local function assetName(p)
        if p ~= nil and p.getName ~= nil then
            local ok, n = pcall(p.getName, p)
            if ok and type(n) == "string" and n ~= "" then return n end
        end
        local si = storeItemOf(p)
        if si ~= nil and type(si.name) == "string" and si.name ~= "" then return si.name end
        return "Unknown asset"
    end
    local function assetIcon(p)
        local si = storeItemOf(p)
        if si ~= nil then
            local f = si.imageFilename or si.iconFilename
            if type(f) == "string" and f ~= "" then return f end
        end
        return nil
    end

    local out = {}
    local function emit(uid, byFt)
        if type(byFt) ~= "table" then return end
        local p = byUid[uid]
        local name, icon
        for ft, e in pairs(byFt) do
            if type(e) == "table" then
                local sold, money = e.sold or 0, e.money or 0
                if sold ~= 0 or money ~= 0 then
                    if name == nil then name = assetName(p); icon = assetIcon(p) end
                    out[#out + 1] = { ft = ft, uid = uid, assetName = name, assetIcon = icon, sold = sold, money = money }
                end
            end
        end
    end

    if window == "hour" then
        if type(S.lastCycle) == "table" then
            for uid, byFt in pairs(S.lastCycle) do emit(uid, byFt) end
        end
    elseif clientMonthly ~= nil then
        for uid, byFt in pairs(clientMonthly) do emit(uid, byFt) end
    else
        local acc = {}   -- uid -> ft -> {sold, money}
        for i = 1, MONTHLY_CYCLES do
            local snap = monthlyRing[i]
            if type(snap) == "table" then
                for uid, byFt in pairs(snap) do
                    if type(byFt) == "table" then
                        local au = acc[uid]; if au == nil then au = {}; acc[uid] = au end
                        for ft, e in pairs(byFt) do
                            if type(e) == "table" then
                                local ae = au[ft]; if ae == nil then ae = { sold = 0, money = 0 }; au[ft] = ae end
                                ae.sold = ae.sold + (e.sold or 0)
                                ae.money = ae.money + (e.money or 0)
                            end
                        end
                    end
                end
            end
        end
        for uid, byFt in pairs(acc) do emit(uid, byFt) end
    end
    return out
end

-- Record a per-cycle stat for a move/sale that happens OUTSIDE the main pass -- e.g. the
-- ProductionDistributeSell add-on's appended surplus-sell, which runs right after runHourly has
-- already published (cycleAcc niled). Writes into the live cycle if one is open, else into the
-- just-published cycle (S.lastCycle) -- the same table the monthly ring's newest slot references --
-- so the sale shows in BOTH the per-cycle and monthly columns. field = "dist"/"sold"/"stored"/"received".
function SmartDistribution.recordCycleStat(placeable, ft, field, amount)
    if placeable == nil or ft == nil or amount == nil or amount <= 0 then return end
    local tbl = cycleAcc or S.lastCycle
    if tbl == nil then return end
    local uid = getUid(placeable)
    if uid == nil then return end
    local a = tbl[uid]; if a == nil then a = {}; tbl[uid] = a end
    local e = a[ft];    if e == nil then e = { dist = 0, sold = 0, stored = 0, received = 0 }; a[ft] = e end
    e[field] = (e[field] or 0) + amount
end

-- ============================================================================
-- MULTIPLAYER: monthly /mo stats sync (server -> clients)
-- The hourly distribute/sell/store pass runs only on the server, so the monthly ring -- and thus
-- monthlyStats / monthlyReceived -- is empty on clients, leaving every /mo column blank for non-host
-- players. Each hour (and once for a joining client) the server flattens the 24-cycle ring to a
-- per-(placeable,fillType) aggregate and pushes it; the client stores it in clientMonthly, which the
-- two accessors above read. Sent in chunks; the first chunk of a push clears the client's table so
-- fill types that aged out of the 24-cycle window correctly fall back to zero.
-- ============================================================================
local STATS_MAX_PER_EVENT = 60     -- entries per event; keeps each network stream comfortably small

-- flatten the ring to a list of { p = placeable, ft, d, s, st, r } with any non-zero total (server side)
local function buildMonthlyAggList()
    local agg = {}
    for i = 1, MONTHLY_CYCLES do
        local snap = monthlyRing[i]
        if snap ~= nil then
            for uid, fts in pairs(snap) do
                local au = agg[uid]; if au == nil then au = {}; agg[uid] = au end
                for ft, e in pairs(fts) do
                    local ae = au[ft]
                    if ae == nil then ae = { d = 0, s = 0, st = 0, r = 0, mo = 0, pr = 0, co = 0 }; au[ft] = ae end
                    ae.d  = ae.d  + (e.dist or 0);   ae.s = ae.s + (e.sold or 0)
                    ae.st = ae.st + (e.stored or 0); ae.r = ae.r + (e.received or 0)
                    ae.mo = ae.mo + (e.money or 0)
                    ae.pr = ae.pr + (e.produced or 0); ae.co = ae.co + (e.consumed or 0)
                end
            end
        end
    end
    local list = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps ~= nil then
        for _, p in ipairs(ps.placeables) do
            local uid = getUid(p)
            if uid ~= nil then
                local au = agg[uid]
                local isMkt = SmartDistribution.isMarket(p)
                if au ~= nil then
                    for ft, ae in pairs(au) do
                        local buf = isMkt and SmartDistribution.marketBufferLevel(uid, ft) or 0
                        if (ae.d + ae.s + ae.st + ae.r + ae.mo + ae.pr + ae.co) > 0 or buf > 0 then
                            list[#list + 1] = { p = p, ft = ft, d = ae.d, s = ae.s, st = ae.st, r = ae.r, mo = ae.mo, buf = buf, pr = ae.pr, co = ae.co }
                        end
                    end
                end
                if isMkt then   -- markets with buffer but no monthly activity: still send so the tab shows live buffer
                    local b = SmartDistribution._marketBuffer[uid]
                    if b ~= nil then
                        for ft, litres in pairs(b) do
                            if litres ~= nil and litres > 0 and (au == nil or au[ft] == nil) then
                                list[#list + 1] = { p = p, ft = ft, d = 0, s = 0, st = 0, r = 0, mo = 0, buf = litres }
                            end
                        end
                    end
                end
            end
        end
    end
    return list
end

DistributionStatsEvent = {}
local DistributionStatsEvent_mt = Class(DistributionStatsEvent, Event)
InitEventClass(DistributionStatsEvent, "DistributionStatsEvent")   -- register network id (server + client)

function DistributionStatsEvent.emptyNew()
    return Event.new(DistributionStatsEvent_mt)
end
function DistributionStatsEvent.new(entries, clearFirst)
    local self = DistributionStatsEvent.emptyNew()
    self.entries    = entries or {}
    self.clearFirst = clearFirst and true or false
    return self
end
function DistributionStatsEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.clearFirst)
    streamWriteUIntN(streamId, #self.entries, 8)                 -- <=255 per event; chunked well under
    for _, en in ipairs(self.entries) do
        NetworkUtil.writeNodeObject(streamId, en.p)
        streamWriteUIntN(streamId, en.ft, FillTypeManager.SEND_NUM_BITS)
        streamWriteFloat32(streamId, en.d)
        streamWriteFloat32(streamId, en.s)
        streamWriteFloat32(streamId, en.st)
        streamWriteFloat32(streamId, en.r)
        streamWriteFloat32(streamId, en.mo or 0)
        streamWriteFloat32(streamId, en.buf or 0)
        streamWriteFloat32(streamId, en.pr or 0)
        streamWriteFloat32(streamId, en.co or 0)
    end
end
function DistributionStatsEvent:readStream(streamId, connection)
    self.clearFirst = streamReadBool(streamId)
    local n = streamReadUIntN(streamId, 8)
    self.entries = {}
    for i = 1, n do
        local p  = NetworkUtil.readNodeObject(streamId)
        local ft = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
        local d  = streamReadFloat32(streamId)
        local s  = streamReadFloat32(streamId)
        local st = streamReadFloat32(streamId)
        local r  = streamReadFloat32(streamId)
        local mo = streamReadFloat32(streamId)
        local bf = streamReadFloat32(streamId)
        local pr = streamReadFloat32(streamId)
        local co = streamReadFloat32(streamId)
        self.entries[i] = { p = p, ft = ft, d = d, s = s, st = st, r = r, mo = mo, buf = bf, pr = pr, co = co }
    end
    self:run(connection)
end
function DistributionStatsEvent:run(connection)
    -- stats flow server -> client only; never relayed onward.
    if self.clearFirst or clientMonthly == nil then clientMonthly = {}; SmartDistribution._marketBuffer = {} end
    for _, en in ipairs(self.entries) do
        local p = en.p
        if p ~= nil then
            local uid = getUid(p)
            if uid ~= nil then
                local au = clientMonthly[uid]; if au == nil then au = {}; clientMonthly[uid] = au end
                au[en.ft] = { dist = en.d, sold = en.s, stored = en.st, received = en.r, money = en.mo or 0, produced = en.pr or 0, consumed = en.co or 0 }
                if (en.buf or 0) > 0 then   -- client-side market buffer for the Markets tab
                    local b = SmartDistribution._marketBuffer[uid]; if b == nil then b = {}; SmartDistribution._marketBuffer[uid] = b end
                    b[en.ft] = en.buf
                end
            end
        end
    end
end

-- server: push the whole rolling aggregate. targetConnection set -> only that joining client;
-- nil -> broadcast to everyone. No-op in single-player (the host reads the ring directly).
function DistributionStatsEvent.broadcast(targetConnection)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local dyn = g_currentMission.missionDynamicInfo
    if dyn == nil or dyn.isMultiplayer ~= true or g_server == nil then return end
    local list = buildMonthlyAggList()
    local i, total, first = 1, #list, true
    repeat
        local slice = {}
        while #slice < STATS_MAX_PER_EVENT and i <= total do
            slice[#slice + 1] = list[i]; i = i + 1
        end
        local ev = DistributionStatsEvent.new(slice, first)
        if targetConnection ~= nil then targetConnection:sendEvent(ev) else g_server:broadcastEvent(ev) end
        first = false
    until i > total
end

-- ============================================================================
-- MULTIPLAYER: per-cycle money summary mirror (server -> clients)
-- flushCycleSummary emits the "Biogas income / Product sales / Distribution costs" side-notifications
-- on the server (which runs the pass). This event carries the same three category totals to clients
-- so non-host players see the identical summary; each client formats with its own locale and notifies.
-- ============================================================================
DistributionMoneyNotifyEvent = {}
local DistributionMoneyNotifyEvent_mt = Class(DistributionMoneyNotifyEvent, Event)
InitEventClass(DistributionMoneyNotifyEvent, "DistributionMoneyNotifyEvent")   -- register network id (server + client)

function DistributionMoneyNotifyEvent.emptyNew()
    return Event.new(DistributionMoneyNotifyEvent_mt)
end
function DistributionMoneyNotifyEvent.new(biogas, sales, cost)
    local self = DistributionMoneyNotifyEvent.emptyNew()
    self.biogas = biogas or 0
    self.sales  = sales  or 0
    self.cost   = cost   or 0
    return self
end
function DistributionMoneyNotifyEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.biogas)
    streamWriteFloat32(streamId, self.sales)
    streamWriteFloat32(streamId, self.cost)
end
function DistributionMoneyNotifyEvent:readStream(streamId, connection)
    self.biogas = streamReadFloat32(streamId)
    self.sales  = streamReadFloat32(streamId)
    self.cost   = streamReadFloat32(streamId)
    self:run(connection)
end
function DistributionMoneyNotifyEvent:run(connection)
    -- client display only; never relayed onward. Mirrors flushCycleSummary's notifications.
    if self.biogas ~= 0 then SmartDistribution.notify("Biogas income: "     .. fmtMoney(self.biogas)) end
    if self.sales  ~= 0 then SmartDistribution.notify("Product sales: "     .. fmtMoney(self.sales))  end
    if self.cost   ~= 0 then SmartDistribution.notify("Distribution costs: -" .. fmtMoney(math.abs(self.cost)), SmartDistribution.COST_NOTIFY_COLOUR) end
end
-- server: mirror the just-emitted summary to all clients. No-op in single-player.
function DistributionMoneyNotifyEvent.broadcast(biogas, sales, cost)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local dyn = g_currentMission.missionDynamicInfo
    if dyn == nil or dyn.isMultiplayer ~= true or g_server == nil then return end
    if (biogas or 0) == 0 and (sales or 0) == 0 and (cost or 0) == 0 then return end
    g_server:broadcastEvent(DistributionMoneyNotifyEvent.new(biogas, sales, cost))
end

-- cycle ONE production output's distribution mode (per fill type) through the shared
-- 5-state seam. Backs the Productions page's per-output "Cycle Output" action.
function SmartDistribution.cycleProductionOutput(p, ft)
    local pp = getProductionPoint(p)
    if pp == nil or ft == nil or SmartDistribution.cycleProductionOutputMode == nil then return false end
    return SmartDistribution.cycleProductionOutputMode(pp, ft)
end

-- ============================================================================
-- SEASONAL HARVEST RESERVE -- primitives (calendar + crop test + demand)
-- Foundation for holding a year's feedstock back from Distribute+Sell. Nothing
-- here changes behaviour yet; it's the data layer the reserve will use.
-- Confirmed in-game (sdSeasonProbe): environment.currentPeriod is the 1..12 month;
-- growthSystem.growthEnabled flags seasonal growth; g_fruitTypeManager resolves via
-- direct global access (rawget does not see engine globals).
-- ============================================================================

-- current in-game month, 1..12 (FS calls it "period"); nil if unavailable
function SmartDistribution.currentMonth()
    local e = g_currentMission ~= nil and g_currentMission.environment or nil
    return e ~= nil and e.currentPeriod or nil
end

-- whether seasonal crop growth is on; if off there are no harvest windows
function SmartDistribution.growthEnabled()
    local g = g_currentMission ~= nil and g_currentMission.growthSystem or nil
    if g == nil or g.growthEnabled == nil then return true end
    return g.growthEnabled == true
end

-- forward distance in months from `from` to `to` (1..12, wrapping; same month -> 12)
local function monthsForward(from, to)
    if from == nil or to == nil then return nil end
    local d = (to - from) % 12
    return d == 0 and 12 or d
end

-- the smallest circular window covering recorded harvest months -> earliest month
-- of that window and its span in months (0 for a single-month window).
local function harvestWindow(months)
    local ms = {}
    for _, m in ipairs(months) do if type(m) == "number" then ms[#ms + 1] = m end end
    if #ms == 0 then return nil, nil end
    table.sort(ms)
    if #ms == 1 then return ms[1], 0 end
    local largestGap, gapIdx = -1, 1
    for i = 1, #ms do
        local gap = (ms[(i % #ms) + 1] - ms[i]) % 12
        if gap == 0 then gap = 12 end
        if gap > largestGap then largestGap = gap; gapIdx = i end
    end
    return ms[(gapIdx % #ms) + 1], 12 - largestGap   -- month after the largest gap; span
end

-- months of demand to cover before the crop is reliably replenished. Worst case:
-- the player harvested at the EARLIEST window month, then waits until the LATEST
-- window month the NEXT time round -- so cover = (now -> earliest) + window span.
-- A 2-month window peaks at 13 just after an early harvest. nil if no data.
function SmartDistribution.monthsToCover(harvestMonths)
    local now = SmartDistribution.currentMonth()
    if now == nil or type(harvestMonths) ~= "table" then return nil end
    local earliest, span = harvestWindow(harvestMonths)
    if earliest == nil then return nil end
    return monthsForward(now, earliest) + span
end

-- is this fill type a harvested crop? (has a fruitType). Direct global on purpose.
function SmartDistribution.isCropFillType(ft)
    if ft == nil then return false end
    local ftm = g_fruitTypeManager
    if ftm == nil or ftm.getFruitTypeIndexByFillTypeIndex == nil then return false end
    local ok, idx = pcall(ftm.getFruitTypeIndexByFillTypeIndex, ftm, ft)
    return ok and idx ~= nil and idx ~= 0
end

-- Perennial / multi-cut forage (grass and similar): regrows and is harvested several times a
-- year, so it needs far less seasonal reserve than an annual crop. Base game marks grass with
-- foliageState regrowthStart="true"; that flag isn't reliably exposed at runtime, so we match
-- the fruit's NAME against a forage keyword set (covers base GRASS plus common mod forages such
-- as alfalfa / clover / meadow / ryegrass). Annual grains, roots and oilseeds return false.
SmartDistribution.REGROW_CROP_KEYWORDS = { "GRASS", "MEADOW", "ALFALFA", "LUCERNE", "LUZERNE", "CLOVER", "RYEGRASS", "HERBAL" }
function SmartDistribution.isRegrowCrop(ft)
    if ft == nil then return false end
    local ftm = g_fruitTypeManager
    if ftm == nil or ftm.getFruitTypeIndexByFillTypeIndex == nil then return false end
    local ok, idx = pcall(ftm.getFruitTypeIndexByFillTypeIndex, ftm, ft)
    if not ok or idx == nil or idx == 0 then return false end
    local ftype = ftm.getFruitTypeByIndex ~= nil and ftm:getFruitTypeByIndex(idx) or nil
    local name = ftype ~= nil and ftype.name or nil
    if type(name) ~= "string" then return false end
    name = string.upper(name)
    for _, kw in ipairs(SmartDistribution.REGROW_CROP_KEYWORDS) do
        if string.find(name, kw, 1, true) ~= nil then return true end
    end
    return false
end

-- Reserve horizon (months of feedstock to hold) for a crop in the seasonal reserve. Regrowing
-- forage regrows every few months, so it holds only GRASS_RESERVE_MONTHS; annual crops use the
-- learned single-season harvest-window cover (monthsToCover), else the configured fallback.
SmartDistribution.GRASS_RESERVE_MONTHS = 3
function SmartDistribution.cropReserveMonths(ft)
    if SmartDistribution.isRegrowCrop(ft) then return SmartDistribution.GRASS_RESERVE_MONTHS end
    local fallback = S.global.seasonalFallbackMonths or 13
    return SmartDistribution.monthsToCover(S.harvestMonths and S.harvestMonths[ft]) or fallback
end

-- Monthly feed demand a single husbandry places on a specific crop fill type, for the
-- seasonal reserve.
--   * Feeding-robot barns take each ingredient into its own BUNKER, so a crop ingredient's
--     demand is simply the herd's food rate x that ingredient's recipe ratio (e.g. grass in
--     a TMR mix) -- no group attribution needed.
--   * Shared food-pool barns (chicken / pig / etc.) eat a food GROUP of interchangeable crops
--     at ONE aggregate rate with no per-crop split, so we attribute that rate only to the crops
--     the pen is actually eating -- weighted by recent per-ft consumption, or (no history yet)
--     by what's currently loaded in the food pool. A feed crop the animals aren't touching gets
--     weight 0 and stays fully sellable.
-- Returns 0 for pens that don't eat ft and for water.
function SmartDistribution.husbandryFeedDemand(p, ft)
    if p == nil or ft == nil or not isHusbandryBuilding(p) then return 0 end
    if ft == waterFillType() then return 0 end
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local hpm = 24 * ((env ~= nil and env.daysPerPeriod) or 1)   -- hours per economic month (period)

    -- feeding-robot barns: one bunker per ingredient. Demand for a crop ingredient is the herd's
    -- food rate x this ingredient's mixer-recipe ratio. Non-bunker / non-recipe fts demand nothing.
    if SmartDistribution.feedingRobotOf(p) ~= nil then
        if not SmartDistribution.robotBunkerFillTypes(p)[ft] then return 0 end
        local rfs = p.spec_husbandryFood
        local rrate = rfs ~= nil and SmartDistribution.husbandryInputRate(p, rfs.litersPerHour, "food") or 0
        if rrate <= 0 then return 0 end
        local ings = SmartDistribution.robotRecipeIngredients(p)
        if ings == nil then return 0 end
        for _, ing in ipairs(ings) do
            if type(ing.fillTypes) == "table" then
                for _, ift in pairs(ing.fillTypes) do
                    if ift == ft and type(ing.ratio) == "number" then return rrate * ing.ratio * hpm end
                end
            end
        end
        return 0
    end

    -- shared food-pool husbandry
    local fs = p.spec_husbandryFood
    if fs == nil or fs.supportedFillTypes == nil or not fs.supportedFillTypes[ft] then return 0 end
    local rate = SmartDistribution.husbandryInputRate(p, fs.litersPerHour, "food")
    if not rate or rate <= 0 then return 0 end
    local monthly = rate * hpm
    if monthly <= 0 then return 0 end
    -- attribution weight: share of the food rate to charge to ft. primary = recent per-ft
    -- consumption (what it's really eating); fallback = current per-ft holdings in the pool.
    local ftShare, total = 0, 0
    for f in pairs(fs.supportedFillTypes) do
        if f ~= waterFillType() then
            local c = SmartDistribution.monthlyConsumed(p, f) or 0
            total = total + c
            if f == ft then ftShare = c end
        end
    end
    if total <= 0 then
        ftShare, total = 0, 0
        if fs.fillLevels ~= nil then
            for f, lvl in pairs(fs.fillLevels) do
                if f ~= waterFillType() then
                    total = total + (lvl or 0)
                    if f == ft then ftShare = (lvl or 0) end
                end
            end
        end
    end
    if total <= 0 then return 0 end     -- can't tell what it eats -> reserve nothing (don't freeze cash crops)
    return monthly * (ftShare / total)
end

-- total monthly INPUT demand for a fill type across all ACTIVE production lines
-- (cyclesPerMonth x input amount, summed) PLUS husbandry feed demand for the crops each
-- pen is actually eating (husbandryFeedDemand). Used by the seasonal harvest reserve.
function SmartDistribution.monthlyDemand(ft)
    if ft == nil then return 0 end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil or type(ps.placeables) ~= "table" then return 0 end
    local total = 0
    for _, p in ipairs(ps.placeables) do
        local pp = getProductionPoint(p)
        if pp ~= nil and type(pp.activeProductions) == "table" then
            for _, prod in ipairs(pp.activeProductions) do
                local cpm = prod.cyclesPerMonth or (prod.cyclesPerHour ~= nil and prod.cyclesPerHour * 24) or 1440
                for _, i in ipairs(prod.inputs or {}) do
                    if i.type == ft then total = total + (i.amount or 0) * cpm end
                end
            end
        elseif pp == nil and isHusbandryBuilding(p) then
            total = total + SmartDistribution.husbandryFeedDemand(p, ft)
        end
    end
    return total
end

function SmartDistribution.cycleAssetMode(asset)
    if asset == nil then return end
    local fts, any = SmartDistribution.assetMenuFillTypes(asset)
    if not any then
        SmartDistribution.notify(placeableName(asset) .. ": no fill types to configure")
        return
    end
    -- stable order so the "unify to first" anchor is deterministic
    local order = {}
    for ft in pairs(fts) do order[#order + 1] = ft end
    table.sort(order)

    -- productions: bulk-cycle the outputs through the shared 5-state virtual mode
    -- (Keep/Distribute/Sell/Distribute+Sell/Distribute+Store), unify-then-step, so
    -- the distribution UI and the production screen stay in lockstep.
    if getProductionPoint(asset) ~= nil and SmartDistribution.productionOutputVMode ~= nil then
        local pp = getProductionPoint(asset)
        local modes = {}
        for i, ft in ipairs(order) do modes[i] = SmartDistribution.productionOutputVMode(pp, ft) or 0 end
        local target = bulkCycleTarget(modes, modes[1] or 0, function(v) return (v + 1) % 6 end)
        local names = {}
        for _, ft in ipairs(order) do
            if SmartDistribution.setProductionOutputMode ~= nil then
                SmartDistribution.setProductionOutputMode(pp, ft, target)
            else
                SmartDistribution.cycleProductionOutputMode(pp, ft)
            end
            names[#names + 1] = fillTypeName(ft)
        end
        local label = (SmartDistribution.productionOutputVModeName and SmartDistribution.productionOutputVModeName(target)) or tostring(target)
        log("%s", string.format("%s outputs -> %s  [%s]", placeableName(asset), label, table.concat(names, ", ")))
        return
    end

    -- everything else: unify-then-step the asset mode across all its fill types
    local store = assetCanStore(asset)
    local market = SmartDistribution.assetHasMarket(asset)
    local modes = {}
    for i, ft in ipairs(order) do modes[i] = SmartDistribution.resolvedAssetMode(asset, ft) end
    local target = bulkCycleTarget(modes, modes[1], function(m) return cycleNext(m, store, market, palletSpawnerFillTypes(asset) ~= nil) end)
    local names, skipped = {}, {}
    for _, ft in ipairs(order) do
        -- don't park a product on a mode it has no endpoint for (e.g. Market Supply for a product no
        -- market accepts): leave that one on its current mode instead.
        if SmartDistribution.modeHasEndpoint == nil or SmartDistribution.modeHasEndpoint(asset, ft, target) then
            SmartDistribution.applyAssetMode(asset, ft, target)   -- syncs MP + persists on save
            names[#names + 1] = fillTypeName(ft)
        else
            skipped[#skipped + 1] = fillTypeName(ft)
        end
    end
    log("%s", string.format("%s -> %s  [%s]%s",
        placeableName(asset), SmartDistribution.modeName(target), table.concat(names, ", "),
        #skipped > 0 and ("  (no endpoint, unchanged: " .. table.concat(skipped, ", ") .. ")") or ""))
end
-- back-compat alias
SmartDistribution.cycleSiloMode = SmartDistribution.cycleAssetMode

-- Targeting for the in-world keys. We measure to each asset's INTERACTION node
-- (where the player actually stands to use it) rather than its rootNode, which
-- on large buildings can sit far from the working area. Among in-range
-- candidates we additionally require the player to be LOOKING AT (gaze gate),
-- and among those that pass, prefer the nearest / most-centred one.
local CYCLE_MAX_DIST = 2    -- metres: in-world prompt + keys act on an owned asset within this range
local LOOK_AT_RADIUS = 6    -- metres: how far a load/unload node may sit from the player's gaze
                            -- line and still count as "looking at it". A perpendicular tolerance, so
                            -- it's forgiving at the node you're standing at and tightens with distance.

local function playerPos()
    local p = g_localPlayer
    if p == nil then return nil end
    if p.getPosition ~= nil then
        local ok, x, y, z = pcall(p.getPosition, p)
        if ok and x ~= nil then return x, y, z end
    end
    if p.rootNode ~= nil then return getWorldTranslation(p.rootNode) end
    return nil
end

-- normalised world XZ the player is facing (camera yaw node forward = +Z); nil
-- if unresolved, in which case selection falls back to pure distance.
local function playerForwardXZ()
    local pl = g_localPlayer
    if pl == nil or pl.camera == nil or pl.camera.yawNode == nil then return nil end
    local ok, fx, _, fz = pcall(localDirectionToWorld, pl.camera.yawNode, 0, 0, 1)
    if not ok or fx == nil then return nil end
    local len = math.sqrt(fx * fx + fz * fz)
    if len < 1e-4 then return nil end
    return fx / len, fz / len
end

-- All DISTRIBUTION interaction nodes for an asset: every loading + unloading
-- station trigger it has, so the player can open the menu from ANY input/output
-- point rather than one mystery spot. Deliberately EXCLUDES animal-management and
-- production-access nodes (those aren't load/unload points). Silos and husbandries
-- both carry loading/unloading stations; productions contribute nothing here.
-- Falls back to the silo player trigger, then the rootNode, if no station nodes.
local function triggerNodeOf(t)
    if t == nil then return nil end
    return t.triggerNode          -- LoadTrigger (output pickup point)
        or t.exactFillRootNode    -- UnloadTrigger (input fill point)
        or t.aiNode               -- UnloadTrigger AI node (last-resort position)
end

local function collectStationNodes(station, out)
    if station == nil then return end
    if type(station.loadTriggers) == "table" then
        for _, t in ipairs(station.loadTriggers) do
            local n = triggerNodeOf(t); if n ~= nil then out[#out + 1] = n end
        end
    end
    if type(station.unloadTriggers) == "table" then
        for _, t in ipairs(station.unloadTriggers) do
            local n = triggerNodeOf(t); if n ~= nil then out[#out + 1] = n end
        end
    end
end

local function assetInteractionNodes(p)
    local out = {}
    if p.spec_silo ~= nil then
        collectStationNodes(p.spec_silo.loadingStation, out)
        collectStationNodes(p.spec_silo.unloadingStation, out)
        if #out == 0 and p.spec_silo.playerActionTrigger ~= nil then
            out[#out + 1] = p.spec_silo.playerActionTrigger
        end
    end
    if p.spec_husbandry ~= nil then
        collectStationNodes(p.spec_husbandry.loadingStation, out)
        collectStationNodes(p.spec_husbandry.unloadingStation, out)
    end
    -- Chicken coops / sheep pastures have no husbandry loading/unloading station --
    -- their output is pallets -- so the checks above find nothing and we'd fall back to
    -- the unreachable building rootNode (no in-world prompt). The food trough is the one
    -- interaction point every husbandry has and the player can physically stand at, so
    -- add it as a reachable node. (item 5 step a follow-up: gives coops/sheep a node.)
    if p.spec_husbandryFood ~= nil and type(p.spec_husbandryFood.feedingTroughs) == "table" then
        for _, t in ipairs(p.spec_husbandryFood.feedingTroughs) do
            local n = triggerNodeOf(t); if n ~= nil then out[#out + 1] = n end
        end
    end
    -- Pallet/bale storage sheds (object storage) have TWO interaction spots: the player
    -- (load/pickup) trigger and the object (unload/drop-off) trigger, often at different ends of
    -- the shed. Expose BOTH so the [ gaze prompt resolves whichever one you're standing at. (The
    -- old "#out == 0" guard hid the object trigger whenever a player trigger existed, leaving a
    -- shed reachable from only one of its two points -- looking at it from the other end did
    -- nothing, even though the shed's own load icon was showing.)
    if p.spec_objectStorage ~= nil then
        local oss = p.spec_objectStorage
        if oss.playerTriggerNode ~= nil then out[#out + 1] = oss.playerTriggerNode end
        if oss.objectTriggerNode ~= nil then out[#out + 1] = oss.objectTriggerNode end
    end
    -- Manure heap / extension: the loading station (where you back a trailer in) + the heap's own
    -- activation trigger are the reachable interaction nodes.
    if p.spec_manureHeap ~= nil then
        collectStationNodes(p.spec_manureHeap.loadingStation, out)
        local hs = p.spec_manureHeap.manureHeap
        if hs ~= nil and hs.activationTriggerNode ~= nil then out[#out + 1] = hs.activationTriggerNode end
    end
    -- Productions: the reachable interaction points are the input/output station triggers (where
    -- you back a trailer in to deliver/collect) plus the building's player trigger.  Without these,
    -- a production falls back to its building-centre rootNode -- out of the in-world key's reach --
    -- so the walk-up open-dialog key never fires on a production (manager access still works).
    local pp = getProductionPoint(p)
    if pp ~= nil then
        collectStationNodes(pp.loadingStation, out)
        collectStationNodes(pp.unloadingStation, out)
        if pp.playerTrigger ~= nil then out[#out + 1] = pp.playerTrigger end
        if pp.playerTriggerNode ~= nil then out[#out + 1] = pp.playerTriggerNode end
    end
    -- Markets / kiosks: the reachable interaction points are the selling station's load / unload
    -- trigger(s) -- where you drive a trailer in to sell. Lets the [ gaze prompt fire at any of them.
    if SmartDistribution.isMarket ~= nil and SmartDistribution.isMarket(p) then
        collectStationNodes(SmartDistribution.marketStationOf(p), out)
    end
    if #out == 0 and p.rootNode ~= nil then out[#out + 1] = p.rootNode end
    return out
end
SmartDistribution.assetInteractionNodes = assetInteractionNodes

local function findNearestOwned(matchFn)
    local px, _, pz = playerPos()
    if px == nil then log("cycle: no player position [VERIFY g_localPlayer]"); return nil end
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return nil end
    local farmId = (g_currentMission.getFarmId ~= nil) and g_currentMission:getFarmId() or nil
    local fx, fz = playerForwardXZ()
    local max2 = CYCLE_MAX_DIST * CYCLE_MAX_DIST
    local best, bestScore = nil, math.huge
    for _, p in ipairs(ps.placeables) do
        if p.rootNode ~= nil and matchFn(p) then
            local owned = (p.getOwnerFarmId == nil) or (farmId == nil) or (p:getOwnerFarmId() == farmId)
            if owned then
                -- consider EVERY loading/unloading node; the player may stand at any
                -- of them, so the asset is "the one you mean" when you are near + looking
                -- at any single input/output point of it.
                for _, node in ipairs(assetInteractionNodes(p)) do
                    local x, _, z = getWorldTranslation(node)
                    local dx, dz = x - px, z - pz
                    local d2 = dx * dx + dz * dz
                    if d2 <= max2 then
                        -- hard "looking at it" gate: node must be IN FRONT of the player and within
                        -- LOOK_AT_RADIUS of the gaze line. No gaze available (fx == nil) -> don't gate,
                        -- fall back to nearest-within-range so the prompt still functions.
                        local looking, score = true, d2
                        if fx ~= nil and d2 > 1e-4 then
                            local along = dx * fx + dz * fz             -- > 0  => in front of the player
                            local perp  = math.abs(dx * fz - dz * fx)   -- perpendicular distance to gaze line
                            looking = (along > 0) and (perp <= LOOK_AT_RADIUS)
                            local align = along / math.sqrt(d2)         -- cos(angle), for ranking only
                            score = d2 * (1.5 - 0.5 * align)            -- among gated nodes: prefer near + centred
                        end
                        if looking and score < bestScore then best, bestScore = p, score end
                    end
                end
            end
        end
    end
    return best
end

-- silo-only (kept for back-compat) and the generalized configurable-asset lookup
function SmartDistribution.findNearestOwnedSilo()
    return findNearestOwned(function(p) return p.spec_silo ~= nil end)
end
function SmartDistribution.findNearestConfigurableAsset()
    -- a configurable class AND still in the network: assets excluded via Settings lose their direct
    -- loading/unloading-point access (the [ prompt + cycle key stop seeing them).
    return findNearestOwned(function(p)
        if SmartDistribution.isMarket ~= nil and SmartDistribution.isMarket(p) then return isEnrolled(p) end   -- markets/kiosks: [ opens the Markets tab (only while the Markets group is on)
        local cfg = p.spec_silo ~= nil or isHusbandryBuilding(p) or p.spec_objectStorage ~= nil
                 or isManurePit(p) or isBeehiveSpawner(p) or getProductionPoint(p) ~= nil
        return cfg and isEnrolled(p)
    end)
end

-- input action callback: cycle the nearest configurable asset (silo or barn)
function SmartDistribution.onCycleAction(self, actionName, inputValue)
    local asset = SmartDistribution.findNearestConfigurableAsset()
    if asset == nil then
        SmartDistribution.notify(string.format("No configurable asset within %dm", CYCLE_MAX_DIST))
        return
    end
    SmartDistribution.cycleAssetMode(asset)
end

-- open the per-asset config dialog for the nearest configurable asset
-- (openAssetDialog + the old per-asset Silo/Production popups were retired; [ opens the menu now)

function SmartDistribution.onOpenDialogAction(self, actionName, inputValue)
    local asset = SmartDistribution.findNearestConfigurableAsset()
    if asset == nil then
        SmartDistribution.notify(string.format("No configurable asset within %dm", CYCLE_MAX_DIST))
        return
    end
    SmartDistribution.openMenuForAsset(asset)
end

-- [ + gaze: open the consolidated menu jumped straight to the gazed asset's tab
-- (productions / silos / silo extensions / animal husbandry) with that asset
-- preselected. Falls back to the old list dialog only if the new menu is absent.
function SmartDistribution.openMenuForAsset(asset)
    if asset == nil then return end
    local menu = SmartDistribution._menu
    if menu == nil then
        SmartDistribution.notify("Distribution menu isn't ready yet")
        return
    end
    menu._focusAsset = asset
    menu._focusClass = getAssetClass(asset)
    if menu.isOpen then
        if menu.focusAsset ~= nil then menu:focusAsset() end          -- already open: jump now
    elseif g_gui ~= nil and not g_gui:getIsGuiVisible() then
        g_gui:showGui("DistributionMenu")                             -- onOpen consumes the pending focus
    end
end

-- ---- manager (authoritative list) ------------------------------------------
-- every owned configurable asset (silos + barns for now; productions join when
-- their config lands), ordered by class then name, for the manager list.
-- ---- Markets tab helpers (per-market buffer / timing / accepted-item list) --
function SmartDistribution.hasAnyMarket()
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return false end
    for _, p in ipairs(ps.placeables) do if SmartDistribution.isMarket(p) then return true end end
    return false
end
function SmartDistribution.marketBufferOf(market, ft)
    if market == nil then return 0 end
    return SmartDistribution.marketBufferLevel(getUid(market), ft)
end
-- per-(market, ft) sell-mode label for the MODE column.
function SmartDistribution.marketProductLabel(market, ft)
    if market == nil then return "Sell  -  Immediate" end
    local m = SmartDistribution.marketSellMode(getUid(market), ft)
    if m == SmartDistribution.MARKET_HOLD then return "Hold" end
    if m == SmartDistribution.MARKET_BEST then return "Sell  -  Best price" end
    return "Sell  -  Immediate"
end
-- current per-(market, ft) sell mode (0/1/2), taking the market placeable.
function SmartDistribution.marketModeOf(market, ft)
    if market == nil or ft == nil then return 0 end
    return SmartDistribution.marketSellMode(getUid(market), ft)
end
-- short sell-type label (Immediate / Best price) for the footer button; nil while Held.
function SmartDistribution.marketSellTypeLabel(market, ft)
    if market == nil or ft == nil then return nil end
    local m = SmartDistribution.marketSellMode(getUid(market), ft)
    if m == SmartDistribution.MARKET_HOLD then return nil end
    return (m == SmartDistribution.MARKET_BEST) and "Best price" or "Immediate"
end
-- "Change output": toggle the selected product between Sell (immediate) and Hold.
function SmartDistribution.marketToggleOutput(market, ft)
    if market == nil or ft == nil then return 0 end
    local cur = SmartDistribution.marketSellMode(getUid(market), ft)
    local nextMode = (cur == SmartDistribution.MARKET_HOLD) and SmartDistribution.MARKET_IMMEDIATE or SmartDistribution.MARKET_HOLD
    SmartDistribution.applyMarketTiming(market, ft, nextMode)
    return nextMode
end
-- "Change sell type": toggle the selected product between Immediate and Best price (no-op while Held).
function SmartDistribution.marketToggleSellType(market, ft)
    if market == nil or ft == nil then return end
    local cur = SmartDistribution.marketSellMode(getUid(market), ft)
    if cur == SmartDistribution.MARKET_HOLD then return cur end
    local nextMode = (cur == SmartDistribution.MARKET_BEST) and SmartDistribution.MARKET_IMMEDIATE or SmartDistribution.MARKET_BEST
    SmartDistribution.applyMarketTiming(market, ft, nextMode)
    return nextMode
end
-- "Change all outputs": set every accepted product of the market to Sell (immediate) or Hold.
function SmartDistribution.marketSetAllOutputs(market, hold)
    if market == nil then return end
    local mode = hold and SmartDistribution.MARKET_HOLD or SmartDistribution.MARKET_IMMEDIATE
    for ft in pairs(SmartDistribution.marketMenuFillTypes(market)) do
        SmartDistribution.applyMarketTiming(market, ft, mode)
    end
end
-- set + sync a (market, ft) sell mode. On the sync-receiving side run() calls this with
-- noEventSend = true so it never echoes back. Mirrors applyAssetSellTiming.
function SmartDistribution.applyMarketTiming(market, ft, mode, noEventSend)
    if market == nil or ft == nil then return end
    SmartDistribution.setMarketSellMode(getUid(market), ft, mode)
    if not noEventSend and DistributionMarketTimingEvent ~= nil and DistributionMarketTimingEvent.sendEvent ~= nil then
        DistributionMarketTimingEvent.sendEvent(market, ft, mode)
    end
end
-- replay every non-default (market, ft, mode) for the multiplayer join sync.
function SmartDistribution.forEachMarketTiming(fn)
    if fn == nil or g_currentMission == nil then return end
    local ps = g_currentMission.placeableSystem
    if ps == nil then return end
    for _, p in ipairs(ps.placeables) do
        if SmartDistribution.isMarket(p) then
            local byFt = SmartDistribution._marketTiming[getUid(p)]
            if byFt ~= nil then
                for ft, mode in pairs(byFt) do
                    if mode ~= nil and mode ~= 0 then fn(p, ft, mode) end
                end
            end
        end
    end
end
-- ---- Animal Husbandry tab data --------------------------------------------
-- the input fill types a husbandry demands: animal food + straw + (non-automatic) water.
function SmartDistribution.husbandryInputFillTypes(p)
    local out = {}
    if p == nil then return out end
    -- Feeding-robot barns take ingredients into per-fill-type BUNKERS, not a shared food pool: list the
    -- bunker fill types (silage / hay / straw / mineral feed) instead of the generic food supportedFillTypes.
    -- Water still applies if not auto-supplied. (Straw bedding shares the STRAW bunker ft here.)
    if SmartDistribution.feedingRobotOf(p) ~= nil then
        for ft in pairs(SmartDistribution.robotBunkerFillTypes(p)) do out[ft] = true end
        local water = waterFillType()
        if water ~= nil and p.spec_husbandryWater ~= nil and not p.spec_husbandryWater.automaticWaterSupply then out[water] = true end
        return out
    end
    local fmap = foodQualityMap(p)
    if fmap ~= nil then for ft in pairs(fmap) do out[ft] = true end end
    if p.getHusbandryIsFillTypeSupported ~= nil then
        local straw = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName("STRAW") or nil
        if straw ~= nil and p.spec_husbandryStraw ~= nil then
            local ok, sup = pcall(p.getHusbandryIsFillTypeSupported, p, straw); if ok and sup then out[straw] = true end
        end
        local water = waterFillType()
        if water ~= nil and p.spec_husbandryWater ~= nil and not p.spec_husbandryWater.automaticWaterSupply then
            local ok, sup = pcall(p.getHusbandryIsFillTypeSupported, p, water); if ok and sup then out[water] = true end
        end
    end
    -- The pits (Manure Pit / Slurry Pit) are HEAP assets, not barns, so none of the barn specs above
    -- apply and they were listing no incoming product at all. What flows INTO a pit is simply what its
    -- storage holds: manure for a manure heap, liquid manure for a slurry pit.
    if not isHusbandryBuilding(p) then
        for _, s in ipairs(getAllStorages(p)) do
            for ft in pairs(storageFillTypes(s)) do out[ft] = true end
        end
    end
    return out
end

-- held / capacity for a husbandry INPUT. Animal food is a single SHARED pool (spec_husbandryFood):
-- every food fill type reports the same total food level and the shared food capacity. Straw / water
-- read their own husbandry fill levels.
function SmartDistribution.husbandryInputHeld(p, ft)
    if p == nil or ft == nil then return 0 end
    if SmartDistribution.feedingRobotOf(p) ~= nil and SmartDistribution.robotBunkerFillTypes(p)[ft] then
        return SmartDistribution.robotBunkerLevel(p, ft)
    end
    local fs = p.spec_husbandryFood
    if fs ~= nil and fs.supportedFillTypes ~= nil and fs.supportedFillTypes[ft] and ft ~= waterFillType() then
        local total = 0
        if fs.fillLevels ~= nil then for _, lvl in pairs(fs.fillLevels) do total = total + (lvl or 0) end end
        return total
    end
    if p.getHusbandryFillLevel ~= nil then
        local ok, lvl = pcall(p.getHusbandryFillLevel, p, ft); if ok and type(lvl) == "number" then return lvl end
    end
    return SmartDistribution.assetHeld(p, ft)
end
function SmartDistribution.husbandryInputCapacity(p, ft)
    if p == nil or ft == nil then return 0 end
    if SmartDistribution.feedingRobotOf(p) ~= nil and SmartDistribution.robotBunkerFillTypes(p)[ft] then
        return SmartDistribution.robotBunkerCapacity(p, ft)
    end
    local fs = p.spec_husbandryFood
    if fs ~= nil and fs.supportedFillTypes ~= nil and fs.supportedFillTypes[ft] and ft ~= waterFillType() then
        return fs.capacity or 0
    end
    if p.getHusbandryCapacity ~= nil then
        local ok, c = pcall(p.getHusbandryCapacity, p, ft); if ok and type(c) == "number" and c > 0 then return c end
    end
    return SmartDistribution.assetCapacity(p, ft)
end

-- total storage capacity for ft across an asset's storages (partner to assetHeld).
function SmartDistribution.assetCapacity(p, ft)
    if p == nil or ft == nil then return 0 end
    local total = 0
    local okS, storages = pcall(getAllStorages, p)
    if okS and type(storages) == "table" then
        for _, storage in ipairs(storages) do
            local c = storageCapacity(storage, ft); if type(c) == "number" then total = total + c end
        end
    end
    return total
end

-- monthly husbandry production per (asset, ft), summed from the rolling window (mirrors monthlyReceived).
function SmartDistribution.monthlyProduced(p, ft)
    if p == nil or ft == nil then return 0 end
    local uid = getUid(p)
    if clientMonthly ~= nil then
        local au = clientMonthly[uid]; local e = au ~= nil and au[ft] or nil
        return e ~= nil and (e.produced or 0) or 0
    end
    local r = 0
    for i = 1, MONTHLY_CYCLES do
        local snap = monthlyRing[i]
        local a = snap ~= nil and snap[uid] or nil
        local e = a ~= nil and a[ft] or nil
        if e ~= nil then r = r + (e.produced or 0) end
    end
    return r
end

-- Per-cycle husbandry PRODUCED tracker: the rise in an output's held level between the previous
-- cycle's end and this cycle's start is pure production (nothing is drained in between). Recorded
-- into the cycle ledger as "produced"; the end-of-cycle level is committed as next cycle's baseline.
SmartDistribution._husbProdLast = {}   -- uid -> ft -> last end-of-cycle output level
function SmartDistribution.observeHusbandryProduction()
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    for _, p in ipairs(ps.placeables) do
        if getProductionPoint(p) == nil and isHusbandryBuilding(p) and isEnrolled(p) then
            local uid = getUid(p)
            local last = SmartDistribution._husbProdLast[uid]
            local outs = husbandryOutputFillTypes(p)
            local pfts = palletSpawnerFillTypes(p)
            if pfts ~= nil then for _, ft in ipairs(pfts) do outs[ft] = true end end
            for ft in pairs(outs) do
                local cur  = SmartDistribution.assetHeld(p, ft)
                local prev = (last ~= nil and last[ft]) or cur
                if cur - prev > 0 then ledgerAdd(p, ft, "produced", cur - prev) end
            end
        end
    end
end
function SmartDistribution.commitHusbandryProduction()
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    for _, p in ipairs(ps.placeables) do
        if getProductionPoint(p) == nil and isHusbandryBuilding(p) and isEnrolled(p) then
            local uid = getUid(p)
            local rec = SmartDistribution._husbProdLast[uid]; if rec == nil then rec = {}; SmartDistribution._husbProdLast[uid] = rec end
            local outs = husbandryOutputFillTypes(p)
            local pfts = palletSpawnerFillTypes(p)
            if pfts ~= nil then for _, ft in ipairs(pfts) do outs[ft] = true end end
            for ft in pairs(outs) do rec[ft] = SmartDistribution.assetHeld(p, ft) end
        end
    end
end

-- Per-cycle husbandry CONSUMED tracker (feed / water / straw eaten by the animals). Same buffer-delta
-- idea as the production tracker: consumed = (prevLevel + received) - currentLevel, using THIS cycle's
-- flows (cycleAcc, passed in) so the windows align. Called once at end of runHourly.
--
-- COMPLICATION: animal food is a single SHARED pool (spec_husbandryFood) -- every food fill type
-- reports the SAME pool total via husbandryInputHeld, so a naive per-ft delta would count the whole
-- pool's drop once for EACH food type. We handle food specially: measure the pool drop ONCE, then
-- attribute it across the food types in proportion to what was delivered (received) this cycle. Water
-- and straw (and pit contents) are single fill types with their own levels, so they use the plain
-- per-ft formula.
SmartDistribution._husbConsumeLast = {}   -- uid -> ft -> last end-of-cycle input level (per-ft; food uses a shared key)
function SmartDistribution.recordHusbandryConsumption(flows)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    local function flow(uid, ft, field)
        local a = flows ~= nil and flows[uid] or nil
        local e = a ~= nil and a[ft] or nil
        return e ~= nil and (e[field] or 0) or 0
    end
    local water = waterFillType()
    for _, p in ipairs(ps.placeables) do
        if getProductionPoint(p) == nil and isHusbandryBuilding(p) and isEnrolled(p) then
            local uid = getUid(p)
            local last = SmartDistribution._husbConsumeLast[uid]
            local rec  = last; if rec == nil then rec = {}; SmartDistribution._husbConsumeLast[uid] = rec end
            local fs = p.spec_husbandryFood

            -- split inputs into shared-pool food vs standalone (water / straw / pit)
            local foodFts, soloFts = {}, {}
            for ft in pairs(SmartDistribution.husbandryInputFillTypes(p)) do
                if fs ~= nil and fs.supportedFillTypes ~= nil and fs.supportedFillTypes[ft] and ft ~= water then
                    foodFts[#foodFts + 1] = ft
                else
                    soloFts[#soloFts + 1] = ft
                end
            end

            -- standalone inputs: plain per-ft delta
            for _, ft in ipairs(soloFts) do
                local cur  = SmartDistribution.husbandryInputHeld(p, ft)
                local prev = (last ~= nil and last[ft]) or cur
                local consumed = (prev + flow(uid, ft, "received")) - cur
                if consumed > 0 then ledgerAdd(p, ft, "consumed", consumed) end
                rec[ft] = cur
            end

            -- shared food pool: measure the pool drop once, attribute by received-share
            if #foodFts > 0 then
                local pool = 0
                if fs ~= nil and fs.fillLevels ~= nil then for _, lvl in pairs(fs.fillLevels) do pool = pool + (lvl or 0) end end
                local prevPool = (last ~= nil and last["__foodPool"]) or pool
                local totalRecv = 0
                for _, ft in ipairs(foodFts) do totalRecv = totalRecv + flow(uid, ft, "received") end
                local poolConsumed = (prevPool + totalRecv) - pool
                if poolConsumed > 0 then
                    if totalRecv > 0 then
                        -- attribute proportional to what was delivered this cycle
                        for _, ft in ipairs(foodFts) do
                            local share = flow(uid, ft, "received") / totalRecv
                            local c = poolConsumed * share
                            if c > 0 then ledgerAdd(p, ft, "consumed", c) end
                        end
                    else
                        -- nothing delivered this cycle: attribute to the food type with the most on hand
                        local bigFt, bigLvl = nil, -1
                        if fs ~= nil and fs.fillLevels ~= nil then
                            for ft, lvl in pairs(fs.fillLevels) do
                                if (lvl or 0) > bigLvl then bigLvl = lvl or 0; bigFt = ft end
                            end
                        end
                        if bigFt ~= nil then ledgerAdd(p, bigFt, "consumed", poolConsumed) end
                    end
                end
                rec["__foodPool"] = pool
            end
        end
    end
end

-- Per-cycle production THROUGHPUT tracker (buffer deltas, mirrors the husbandry produced tracker).
-- A production point shares one pp.storage for inputs and outputs, so a raw level delta mixes
-- production with distribution flow. We isolate production by adjusting with the flows we ledgered
-- THIS cycle (cycleAcc, passed in), measured over the SAME window as the buffer delta:
--   consumed(input ft)  = (prevLevel + received) - currentLevel          -- fell despite deliveries in
--   produced(output ft) = (currentLevel - prevLevel) + (dist+sold+stored) -- rose despite draw-off
-- Both clamped >= 0. Called ONCE at end of runHourly (before cycleAcc is cleared): it snapshots the
-- new baseline AND records the deltas in one pass, so the delta window and the flow window align
-- exactly (both = this cycle). `flows` is cycleAcc.
SmartDistribution._prodThruLast = {}   -- uid -> ft -> last end-of-cycle pp.storage level
function SmartDistribution.recordProductionThroughput(flows)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    local function flow(uid, ft, field)
        local a = flows ~= nil and flows[uid] or nil
        local e = a ~= nil and a[ft] or nil
        return e ~= nil and (e[field] or 0) or 0
    end
    for _, p in ipairs(ps.placeables) do
        local pp = getProductionPoint(p)
        if pp ~= nil and pp.storage ~= nil and isEnrolled(p) then
            local uid = getUid(p)
            local last = SmartDistribution._prodThruLast[uid]
            local rec  = last; if rec == nil then rec = {}; SmartDistribution._prodThruLast[uid] = rec end
            local inFts, outFts = {}, {}
            for _, line in ipairs(SmartDistribution.productionLines(p) or {}) do
                for _, i in ipairs(line.inputs or {})  do inFts[i.ft]  = true end
                for _, o in ipairs(line.outputs or {}) do outFts[o.ft] = true end
            end
            -- inputs: consumed = (prev + received) - cur
            for ft in pairs(inFts) do
                local cur  = getLevel(pp.storage, ft)
                local prev = (last ~= nil and last[ft]) or cur
                local consumed = (prev + flow(uid, ft, "received")) - cur
                if SmartDistribution._prodThruDebug then
                    SmartDistribution.log("prodThru IN %s [%s] prev=%d recv=%d cur=%d -> consumed=%d", placeableName(p), fillTypeName(ft), prev, flow(uid, ft, "received"), cur, consumed)
                end
                if consumed > 0 then ledgerAdd(p, ft, "consumed", consumed) end
            end
            -- outputs: how we measure produced depends on the output's FORM.
            --   * BULK (in pp.storage): produced = (cur - prev) + (dist + sold + stored). The buffer is
            --     drained the SAME cycle it fills, so adding the outflows back reconstructs gross output.
            --   * PALLET (bottled milk, planks, ...): the pallet level itself tracks production directly,
            --     but whole-pallet STORE/SELL/DISTRIBUTE happens a cycle LATER than the spawn (the level
            --     rises one cycle, drops the next). Adding the outflows in the spawn cycle double-counts
            --     (verified: prev=0 cur=1000 stored=1000 -> 2000, then prev=1000 cur=0 -> -1000 dropped by
            --     the >=0 clamp, netting 2x). So for pallets we take just the positive level rise and do
            --     NOT re-add flows; the lagged drop is correctly ignored.
            local pal = palletSpawnerFillTypes(p)
            local isPal = {}
            if pal ~= nil then for _, pf in ipairs(pal) do isPal[pf] = true end end
            for ft in pairs(outFts) do
                local produced
                if isPal[ft] then
                    local cur  = palletFillLevel(p, ft)
                    local prev = (last ~= nil and last[ft]) or cur
                    produced = cur - prev                      -- pallet level rise = production (outflows lag a cycle)
                else
                    local cur  = getLevel(pp.storage, ft)
                    local prev = (last ~= nil and last[ft]) or cur
                    local out  = flow(uid, ft, "dist") + flow(uid, ft, "sold") + flow(uid, ft, "stored")
                    produced = (cur - prev) + out
                end
                if SmartDistribution._prodThruDebug then
                    SmartDistribution.log("prodThru OUT %s [%s] pal=%s dist=%d sold=%d stored=%d -> produced=%d", placeableName(p), fillTypeName(ft), tostring(isPal[ft] == true), flow(uid, ft, "dist"), flow(uid, ft, "sold"), flow(uid, ft, "stored"), produced)
                end
                if produced > 0 then ledgerAdd(p, ft, "produced", produced) end
            end
            -- snapshot the new baseline (both input and output fts), using the matching accessor per ft
            for ft in pairs(inFts)  do rec[ft] = getLevel(pp.storage, ft) end
            for ft in pairs(outFts) do
                if isPal[ft] then rec[ft] = palletFillLevel(p, ft) else rec[ft] = getLevel(pp.storage, ft) end
            end
        end
    end
end

-- MONTHLY (rolling 24-cycle) consumed for (production, input ft). Mirror of monthlyProduced.
function SmartDistribution.monthlyConsumed(p, ft)
    if p == nil or ft == nil then return 0 end
    local uid = getUid(p)
    if clientMonthly ~= nil then
        local au = clientMonthly[uid]; local e = au ~= nil and au[ft] or nil
        return e ~= nil and (e.consumed or 0) or 0
    end
    local r = 0
    for i = 1, MONTHLY_CYCLES do
        local snap = monthlyRing[i]
        local a = snap ~= nil and snap[uid] or nil
        local e = a ~= nil and a[ft] or nil
        if e ~= nil then r = r + (e.consumed or 0) end
    end
    return r
end

-- a husbandry's full output set: milk / manure / slurry + egg / wool / honey pallets (for the tab).
function SmartDistribution.husbandryOutputSet(p)
    local outs = husbandryOutputFillTypes(p)
    local pfts = palletSpawnerFillTypes(p)
    if pfts ~= nil then for _, ft in ipairs(pfts) do outs[ft] = true end end
    -- husbandryOutputFillTypes() adds the whole manure family (MANURE / LIQUIDMANURE / SLURRY) to every
    -- asset, which is right for a barn but wrong for a pit: a Manure Pit was listing slurry and a Slurry
    -- Pit was listing manure. For the pits (non-barn HEAP assets) keep only what they actually hold.
    if not isHusbandryBuilding(p) then
        for ft in pairs(outputNamedSet()) do
            if outs[ft] and not SmartDistribution.assetHoldsFillType(p, ft) then outs[ft] = nil end
        end
    end
    return outs
end

-- every fill type currently "in the distribution network": an active output of an enrolled production
-- (regardless of current stock), produced by a pallet spawner (coop eggs / wool / honey), or currently
-- held in an enrolled silo / husbandry / shed storage. Used to decide which rows a market shows.
function SmartDistribution.networkFillTypes(farmId)
    local out = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return out end
    for _, p in ipairs(ps.placeables) do
        if p.ownerFarmId == farmId and isEnrolled(p) and not SmartDistribution.isMarket(p) then
            local cls = getAssetClass(p)
            if cls == "PRODUCTION" then
                -- outputs of every ENABLED production line (shown even while a line is idle / waiting for input)
                local pp = getProductionPoint(p)
                if pp ~= nil then
                    for _, def in ipairs(getActiveProductionDefs(pp)) do
                        for _, o in ipairs(def.outputs or {}) do if o.type ~= nil then out[o.type] = true end end
                    end
                end
            elseif cls == "HUSBANDRY" then
                -- husbandries always generate their outputs: milk / manure + egg / wool / honey pallets (shown regardless of stock)
                for ft in pairs(husbandryOutputFillTypes(p)) do out[ft] = true end
                local pfts = palletSpawnerFillTypes(p)
                if pfts ~= nil then for _, ft in ipairs(pfts) do out[ft] = true end end
            else
                -- SILO / SHED / HEAP / OTHER: only what is currently stored (grain in silos, pallets in the warehouse)
                for _, storage in ipairs(getAllStorages(p)) do
                    for ft in pairs(storageFillTypes(storage)) do
                        if getLevel(storage, ft) > 0 then out[ft] = true end
                    end
                end
                if p.spec_objectStorage ~= nil then
                    for ft in pairs(shedStoredFillTypes(p)) do out[ft] = true end
                end
            end
        end
    end
    return out
end

-- fill types a market's tab shows: currently buffered, active this month (received/sold), or in the
-- distribution network (produced or held) AND supported by this market.
function SmartDistribution.marketMenuFillTypes(market)
    local out = {}
    if market == nil then return out end
    local uid = getUid(market)
    local buf = SmartDistribution._marketBuffer[uid]
    if buf ~= nil then for ft, v in pairs(buf) do if v ~= nil and v > 0 then out[ft] = true end end end   -- stock the market is currently holding
    local farmId = (market.getOwnerFarmId and market:getOwnerFarmId()) or market.ownerFarmId
    for ft in pairs(SmartDistribution.networkFillTypes(farmId)) do
        if SmartDistribution.marketAccepts(market, ft) then out[ft] = true end
    end
    return out
end

function SmartDistribution.enumerateConfigurableAssets()
    local out = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return out end
    local farmId = (g_currentMission.getFarmId ~= nil) and g_currentMission:getFarmId() or nil
    for _, p in ipairs(ps.placeables) do
        if p.rootNode ~= nil then
            local cls = getAssetClass(p)
            if cls == "SILO" or cls == "HUSBANDRY" or cls == "PRODUCTION" or cls == "SHED" or cls == "HEAP" or cls == "MARKET" then
                local owned = (p.getOwnerFarmId == nil) or (farmId == nil) or (p:getOwnerFarmId() == farmId)
                if owned then
                    out[#out + 1] = { placeable = p, name = placeableName(p), class = cls,
                                      origName = SmartDistribution.placeableRenamedFrom(p) }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.class ~= b.class then return a.class < b.class end
        return a.name < b.name
    end)
    return out
end

function SmartDistribution.onOpenManagerAction(self, actionName, inputValue)
    SmartDistribution.openMenu()
end

-- (the ] help keybind was removed; the User Guide is a tab in the consolidated menu)

-- ---- consolidated menu (TabbedMenu) ----------------------------------------
-- Registered once at mission load (installMenu). Loads the four page frames
-- first -- each under the name its FrameReference in DistributionMenu.xml
-- expects -- then the menu screen itself. Mirrors AutoDrive's ADSettings load.
function SmartDistribution.registerMenuGui()
    if SmartDistribution._menuRegistered then return end
    if g_gui == nil or TabbedMenu == nil or DistributionMenu == nil then
        log("registerMenuGui: g_gui/TabbedMenu/DistributionMenu missing [VERIFY]")
        return
    end
    local dir = SmartDistribution.modDir or ""
    local ok, err = pcall(function()
        g_gui:loadProfiles(dir .. "gui/DistributionSiloProfiles.xml")
        local function loadPage(cls, guiName, xml)
            if cls == nil then return end
            local inst = cls.new()
            g_gui:loadGui(dir .. xml, guiName, inst, true)
        end
        loadPage(DistributionSettingsPage,    "distributionSettingsPage",    "gui/DistributionSettingsPage.xml")
        loadPage(DistributionStoragePage,         "distributionStoragePage",     "gui/DistributionStoragePage.xml")
        loadPage(DistributionAnimalHusbandryPage, "distributionHusbandryPage",   "gui/DistributionHusbandryPage.xml")
        loadPage(DistributionMarketsPage,         "distributionMarketsPage",     "gui/DistributionMarketsPage.xml")
        loadPage(DistributionProductionsPage, "distributionProductionsPage", "gui/DistributionProductionsPage.xml")
        loadPage(DistributionHelpPage,        "distributionHelpPage",        "gui/DistributionHelpPage.xml")
        SmartDistribution._menu = DistributionMenu.new()
        g_gui:loadGui(dir .. "gui/DistributionMenu.xml", "DistributionMenu", SmartDistribution._menu)
        if DistributionSpawnDialog ~= nil then
            SmartDistribution._spawnDialog = DistributionSpawnDialog.new()
            g_gui:loadGui(dir .. "gui/DistributionSpawnDialog.xml", "DistributionSpawnDialog", SmartDistribution._spawnDialog)
        end
        if DistributionAdvancedDialog ~= nil then
            SmartDistribution._advDialog = DistributionAdvancedDialog.new()
            g_gui:loadGui(dir .. "gui/DistributionAdvancedDialog.xml", "DistributionAdvancedDialog", SmartDistribution._advDialog)
        end
        if DistributionInputsDialog ~= nil then
            SmartDistribution._inputsDialog = DistributionInputsDialog.new()
            g_gui:loadGui(dir .. "gui/DistributionInputsDialog.xml", "DistributionInputsDialog", SmartDistribution._inputsDialog)
        end
    end)
    if ok then
        SmartDistribution._menuRegistered = true
        log("consolidated menu registered")
    else
        log("registerMenuGui error: %s", tostring(err))
    end
end

-- Open the Advanced window (granular routing) for a building.
function SmartDistribution.openAdvancedDialog(asset, ft)
    if g_gui == nil or SmartDistribution._advDialog == nil or asset == nil or ft == nil then return false end
    SmartDistribution._advDialog:setup(asset, ft)
    g_gui:showDialog("DistributionAdvancedDialog")
    return true
end

-- Open the Advanced Inputs window (receiver-side block + per-product max %) for a building.
function SmartDistribution.openInputsDialog(asset)
    if g_gui == nil or asset == nil then return false end
    if SmartDistribution._inputsDialog == nil then
        log("openInputsDialog: dialog not registered (needs a full game restart after adding DistributionInputsDialog)")
        return false
    end
    SmartDistribution._inputsDialog:setup(asset)
    g_gui:showDialog("DistributionInputsDialog")
    return true
end

-- Rows for the Advanced Inputs dialog: one per input product the building can receive, carrying its
-- pooled/individual classification, block state, effective max %, and the live litre equivalent so the
-- UI can show "50%  (125,000 L)". Pooled products are grouped; the caller renders a pooled section and
-- an individual section.
function SmartDistribution.receiverInputRows(p)
    local rows = {}
    if p == nil then return rows end
    local rcvUid = getUid(p)
    local pool = SmartDistribution.pooledInputCapacity(p)
    local poolSet = {}
    if pool ~= nil then for _, ft in ipairs(pool.fts) do poolSet[ft] = true end end
    for ft in pairs(SmartDistribution.receiverInputFillTypes(p)) do
        local pooled = poolSet[ft] == true
        local cap = SmartDistribution.inputProductCapacity(p, ft)
        local pct = SmartDistribution.inputCapPct(p, ft)
        rows[#rows + 1] = {
            ft = ft,
            name = fillTypeName(ft),   -- dialog re-resolves the display title from ft; this is a fallback
            pooled = pooled,
            blocked = rcvUid ~= nil and SmartDistribution.isInputBlocked(rcvUid, ft) or false,
            pct = pct,
            capLiters = cap,
            maxLiters = cap * (pct / 100),
            held = SmartDistribution.inputHeldLevel(p, ft),
            explicit = rcvUid ~= nil and SmartDistribution.hasExplicitInputCapPct(rcvUid, ft) or false,
            targetPct = rcvUid ~= nil and SmartDistribution.getInputTargetPct(rcvUid, ft) or nil,
            targetLiters = SmartDistribution.inputTargetLiters(p, ft),
        }
    end
    -- Feeding-robot barn: append a READ-ONLY row for the internal mixed-feed / food level (the robot mixes
    -- the bunkers into this and feeds the herd from it; shown for reference only, not settable).
    if SmartDistribution.feedingRobotOf(p) ~= nil and p.spec_husbandryFood ~= nil then
        local fs = p.spec_husbandryFood
        local held = 0
        if type(fs.fillLevels) == "table" then for _, lvl in pairs(fs.fillLevels) do held = held + (lvl or 0) end end
        rows[#rows + 1] = {
            ft = 0, name = "Mixed feed", readOnly = true, pooled = false, blocked = false,
            pct = 100, capLiters = fs.capacity or 0, maxLiters = fs.capacity or 0, held = held,
        }
    end
    table.sort(rows, function(a, b)
        if (a.readOnly or false) ~= (b.readOnly or false) then return not a.readOnly end   -- read-only rows last
        if a.pooled ~= b.pooled then return a.pooled end   -- then pooled products first
        return tostring(a.name) < tostring(b.name)
    end)
    return rows, (pool ~= nil and pool.liters or nil)
end

-- Which input products a building can receive (for the Advanced Inputs dialog). Productions use their
-- input fill types; husbandries use husbandryInputFillTypes; storage/sheds use their supported fts.
function SmartDistribution.receiverInputFillTypes(p)
    local out = {}
    if p == nil then return out end
    local pp = getProductionPoint(p)
    if pp ~= nil then
        for _, def in ipairs(getActiveProductionDefs(pp)) do
            for _, i in ipairs(def.inputs or {}) do if i.type ~= nil then out[i.type] = true end end
        end
        -- include configured (not just active) lines so the player can pre-set caps
        if type(pp.productions) == "table" then
            for _, def in ipairs(pp.productions) do
                for _, i in ipairs(def.inputs or {}) do if i.type ~= nil then out[i.type] = true end end
            end
        end
        return out
    end
    if isHusbandryBuilding(p) and SmartDistribution.husbandryInputFillTypes ~= nil then
        for ft in pairs(SmartDistribution.husbandryInputFillTypes(p)) do out[ft] = true end
        return out
    end
    -- storage / sheds: everything the building can hold is an "input" for cap purposes
    if p.spec_objectStorage ~= nil and SmartDistribution.shedSupportedFillTypes ~= nil then
        for ft in pairs(SmartDistribution.shedSupportedFillTypes(p)) do out[ft] = true end
    end
    for _, s in ipairs(getAllStorages(p)) do
        for ft in pairs(storageFillTypes(s)) do out[ft] = true end
    end
    return out
end

-- Should the Advanced button be offered for this (asset, ft)? Only when the output's mode routes
-- somewhere the player can configure -- i.e. it distributes, stores, or supplies a market (incl. combos).
-- Sell / Hold / Hold Internal / Market-less setups have nothing to arrange, so no button.
function SmartDistribution.modeConfigurable(asset, ft)
    if asset == nil or ft == nil then return false end
    local pp = getProductionPoint(asset)
    if pp ~= nil then
        local v = SmartDistribution.productionOutputVMode ~= nil and SmartDistribution.productionOutputVMode(pp, ft) or nil
        return v == 1 or v == 3 or v == 4 or v == 5 or v == 6 or v == 7   -- dist / dist+sell / dist+store / store / market / dist+market
    end
    local m = SmartDistribution.resolvedAssetMode(asset, ft)
    local M = MODE
    if SmartDistribution.modeDistributes(m) then return true end
    return m == M.STORE or m == M.STORE_TO
        or m == M.TRANSFER_MARKET
end

-- Open the manual pallet-spawn pop-up for a production output. onConfirm(option, count) is invoked
-- when the player presses Spawn. Returns true if the dialog was shown.
function SmartDistribution.openSpawnDialog(placeable, ft, onConfirm)
    if g_gui == nil or SmartDistribution._spawnDialog == nil or ft == nil then return false end
    local pp = getProductionPoint(placeable)
    if pp ~= nil then
        local held = (pp.getFillLevel ~= nil and pp:getFillLevel(ft)) or 0
        SmartDistribution._spawnDialog:setup(pp, ft, held, onConfirm)
    elseif placeable ~= nil and placeable.spec_husbandryPallets ~= nil then
        local held = SmartDistribution.palletPendingLiters(placeable, ft)
        SmartDistribution._spawnDialog:setupHusbandry(placeable, ft, held, onConfirm)
    else
        return false
    end
    g_gui:showDialog("DistributionSpawnDialog")
    return true
end

-- open (or toggle) the consolidated menu; falls back to the old manager list if
-- the menu failed to register for any reason.
function SmartDistribution.openMenu()
    if SmartDistribution._menu == nil then
        SmartDistribution.notify("Distribution menu isn't ready yet")
        return
    end
    if SmartDistribution._menu.isOpen then
        pcall(function() SmartDistribution._menu:onClickBack() end)
    elseif g_gui ~= nil and not g_gui:getIsGuiVisible() then
        g_gui:showGui("DistributionMenu")
    end
end

-- register the key in the player's on-foot context. registerActionEvents re-runs
-- on every context setup; target is the player component (self) so the event is
-- cleaned up with the player's own events on teardown - no duplicate/leak.
local function installInteraction()
    if PlayerInputComponent == nil or PlayerInputComponent.registerActionEvents == nil then
        log("PlayerInputComponent.registerActionEvents not found [VERIFY]")
        return
    end
    PlayerInputComponent.registerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerActionEvents,
        function(self, ...)
            -- vanilla returns early for non-owning players; mirror that so we
            -- don't register a stray event for remote players in MP.
            if self == nil or self.player == nil or not self.player.isOwner then return end
            if g_inputBinding == nil or InputAction == nil then
                print("[SmartDistribution] input: g_inputBinding/InputAction missing [VERIFY]")
                return
            end
            -- CRITICAL: registerActionEvents() ends its own modification scope
            -- before returning, so an appended call lands OUTSIDE the player
            -- context. Re-open the SAME context for our registration, then end it.
            local ctx = PlayerInputComponent.INPUT_CONTEXT_NAME
            g_inputBinding:beginActionEventsModification(ctx)
            -- [ "Configure distribution": registered HIDDEN; the proximity watcher reveals it in the
            -- top-left input help only while a configurable asset is the current on-foot target.
            -- (The old right-bracket "cycle all" key is gone -- that lives on a dialog button now.)
            SmartDistribution._dialogEventId = nil
            if InputAction.DISTREDUX_OPEN_DIALOG ~= nil then
                local ok2, _, eventId2 = pcall(g_inputBinding.registerActionEvent, g_inputBinding,
                    InputAction.DISTREDUX_OPEN_DIALOG, self, SmartDistribution.onOpenDialogAction,
                    false, true, false, true, nil, true)
                if ok2 and eventId2 ~= nil then
                    SmartDistribution._dialogEventId = eventId2
                    pcall(function()
                        g_inputBinding:setActionEventText(eventId2, "Configure distribution")
                        g_inputBinding:setActionEventTextVisibility(eventId2, false)
                        g_inputBinding:setActionEventActive(eventId2, false)
                    end)
                    log("dialog action registered hidden (eventId=%s)", tostring(eventId2))
                else
                    print("[SmartDistribution] dialog register FAILED [VERIFY]: " .. tostring(eventId2))
                end
            end
            -- third key: open the authoritative manager list
            if InputAction.DISTREDUX_OPEN_MANAGER ~= nil then
                local ok3, _, eventId3 = pcall(g_inputBinding.registerActionEvent, g_inputBinding,
                    InputAction.DISTREDUX_OPEN_MANAGER, self, SmartDistribution.onOpenManagerAction,
                    false, true, false, true, nil, true)
                if ok3 and eventId3 ~= nil then
                    pcall(function()
                        g_inputBinding:setActionEventText(eventId3, "Distribution menu")
                        g_inputBinding:setActionEventTextVisibility(eventId3, true)
                    end)
                    log("manager action registered (eventId=%s)", tostring(eventId3))
                else
                    print("[SmartDistribution] manager register FAILED [VERIFY]: " .. tostring(eventId3))
                end
            end
            g_inputBinding:endActionEventsModification()
        end)
    log("cycle interaction installed (player on-foot context)")
end

-- ---- husbandry manure storage patch ----------------------------------------
-- Vanilla barns (spec_husbandry) ship with NO manure storage slot, so manure
-- has nowhere to accumulate. Add a MANURE capacity to each barn's storage so it
-- can be held, distributed and sold. Gated on cur==0 so it is idempotent and
-- coexists with any other mod doing the same (e.g. legacy PDNE).
local MANURE_STORAGE_CAPACITY = 50000

local function patchHusbandryManureStorage(placeable)
    if placeable == nil or placeable.spec_husbandry == nil then return end
    if placeable.spec_manureHeap ~= nil then return end          -- already has a heap
    if not SmartDistribution.husbandryProducesManure(placeable) then return end   -- egg-only coops make no manure -> no slot
    -- The Grazing Pasture mod's pastures ship MANURE capacity 0 on purpose and must keep it; every other
    -- husbandry (including vanilla barns, which also declare 0) gets the slot as designed.
    local grazing = SmartDistribution.isGrazingPasture(placeable)
    Logging.info("[DR manure] %s: typeName=%s grazing=%s -> %s",
        tostring(placeable.getName ~= nil and placeable:getName() or placeable),
        tostring(placeable.typeName), tostring(grazing), grazing and "SKIP (pasture)" or "patch")
    if grazing then return end
    local manureFT = g_fillTypeManager ~= nil and
        g_fillTypeManager:getFillTypeIndexByName("MANURE") or nil
    if manureFT == nil or manureFT <= 0 then return end
    local storages = {}
    if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
        for _, s in ipairs(placeable.spec_silo.storages) do storages[#storages + 1] = s end
    end
    if placeable.spec_husbandry.storage ~= nil then
        storages[#storages + 1] = placeable.spec_husbandry.storage
    end
    for _, storage in ipairs(storages) do
        local cur = (storage.capacities ~= nil and storage.capacities[manureFT]) or 0
        if cur == 0 then
            storage.capacities = storage.capacities or {}
            storage.capacities[manureFT] = MANURE_STORAGE_CAPACITY
            storage.fillLevels = storage.fillLevels or {}
            if storage.fillLevels[manureFT] == nil then storage.fillLevels[manureFT] = 0 end
            if storage._sdManurePatch == nil then
                storage._sdManurePatch = true
                if storage.capacity ~= nil then
                    storage.capacity = storage.capacity + MANURE_STORAGE_CAPACITY
                end
            end
        end
    end
end

local function installHusbandryPatch()
    local function safePatch(self) pcall(patchHusbandryManureStorage, self) end
    if PlaceableHusbandry ~= nil and PlaceableHusbandry.onFinalizePlacement ~= nil then
        PlaceableHusbandry.onFinalizePlacement =
            Utils.appendedFunction(PlaceableHusbandry.onFinalizePlacement,
                function(self) safePatch(self) end)
        if PlaceableHusbandry.onPostLoad ~= nil then
            PlaceableHusbandry.onPostLoad =
                Utils.appendedFunction(PlaceableHusbandry.onPostLoad,
                    function(self) safePatch(self) end)
        end
        log("husbandry manure-storage patch installed")
    elseif Placeable ~= nil and Placeable.onFinalizePlacement ~= nil then
        Placeable.onFinalizePlacement =
            Utils.appendedFunction(Placeable.onFinalizePlacement,
                function(self) if self.spec_husbandry ~= nil then safePatch(self) end end)
        if Placeable.onPostLoad ~= nil then
            Placeable.onPostLoad =
                Utils.appendedFunction(Placeable.onPostLoad,
                    function(self) if self.spec_husbandry ~= nil then safePatch(self) end end)
        end
        log("husbandry manure-storage patch installed (Placeable fallback)")
    else
        print("[SmartDistribution] husbandry manure-storage patch SKIPPED [VERIFY]: no hook point")
    end
end

-- exposed for the per-asset dialog (Stage H2)
SmartDistribution.husbandryOutputFillTypes = husbandryOutputFillTypes

-- ---- in-world prompt visibility --------------------------------------------
-- The "[ Configure distribution" entry in the top-left input help is shown ONLY
-- while a configurable asset is the current on-foot target (recomputed a few times
-- a second). There is no separate HUD box -- the prompt lives in the standard input
-- help list like every other binding. We toggle the action event's text visibility +
-- active state on the id stashed by installInteraction; a context re-registration
-- (vehicle enter/exit, etc.) hands us a fresh id, so we re-assert on the next tick.
local proximityWatcher = { acc = 0, target = nil, lastNear = nil, lastEid = nil }

function proximityWatcher:update(dt)
    SmartDistribution.flushPendingSummary()      -- emit the slept-through summary the moment fast-forward stops
    -- Run an hourly pass deferred from onHourChanged (normal play). We wait one update
    -- tick first, so the engine's hour-change processing -- including producers depositing
    -- this hour's batch in a listener that runs after ours -- has completed; the store pass
    -- then empties the source the instant the batch appears instead of a hour later.
    if SmartDistribution._pendingHourly ~= nil then
        if (SmartDistribution._pendingHourlyWait or 0) > 0 then
            SmartDistribution._pendingHourlyWait = SmartDistribution._pendingHourlyWait - 1
        else
            local pm = SmartDistribution._pendingHourly
            SmartDistribution._pendingHourly = nil
            local ok, err = pcall(SmartDistribution.runHourly, pm)
            if not ok and Logging ~= nil then
                Logging.error("[SmartDistribution] deferred hourly pass failed: %s", tostring(err))
            end
        end
    end

    dt = dt or 0
    self.acc = self.acc + dt
    if self.acc >= 300 then                     -- recompute target ~3 Hz (the scan is the costly part)
        self.acc = 0
        local ok, t = pcall(SmartDistribution.findNearestConfigurableAsset)
        self.target = ok and t or nil
    end

    local eid = SmartDistribution._dialogEventId
    if eid == nil or g_inputBinding == nil then return end
    if eid ~= self.lastEid then self.lastEid = eid; self.lastNear = nil end   -- re-registered: re-assert
    local near = self.target ~= nil
    if near ~= self.lastNear then
        self.lastNear = near
        pcall(function()
            g_inputBinding:setActionEventTextVisibility(eid, near)
            g_inputBinding:setActionEventActive(eid, near)
        end)
    end
end

-- ---- detach manure heaps from barns (un-merge the shared manure pool) -------
-- A "Manure Heap Extension" registers its storage onto nearby barns' UNLOADING stations (base game,
-- from BOTH sides: the heap's onFinalizePlacement AND the barn's own in-range re-scan).
-- getHusbandryCapacity/FillLevel sum that unloading station's target storages, so the heap gets merged
-- into the barn's manure pool (the user saw cap 8.05M = barn 50k + two 4M heaps).  The Liquidmanure
-- Tank stays separate only because it isn't an extension.  To make each heap a SEPARATE storage like
-- the tank, remove the heap's storage from those barn unloading stations after placement/load.  A heap
-- has NO unloading station of its own (only a loadingStation for trailers), so heap.unloadingStations
-- holds only barn links -- removing them can't break the heap's own trailer loading.  Result: the barn's
-- 50k patch and the heap each store manure independently; the pen's storage/station/animals are untouched.
local function detachManureHeap(p)
    if p == nil or p.spec_manureHeap == nil then return end
    local heap = p.spec_manureHeap.manureHeap
    if heap == nil then return end
    local ss = g_currentMission ~= nil and g_currentMission.storageSystem or nil
    if ss == nil or ss.removeStorageFromUnloadingStations == nil then return end
    if type(heap.unloadingStations) == "table" and next(heap.unloadingStations) ~= nil then
        pcall(function() ss:removeStorageFromUnloadingStations(heap, heap.unloadingStations) end)
    end
end

local function detachAllManureHeaps()
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    for _, p in ipairs(ps.placeables) do
        if p.spec_manureHeap ~= nil then detachManureHeap(p) end
    end
end
SmartDistribution._detachAllManureHeaps = detachAllManureHeaps  -- exposed for harness

-- Free the manure-heap EXTENSION from its needsBarn placement gate so it can be placed near a Manure
-- Pit (or anywhere) like the slurry extension, and remember it via sdManureExt so it folds into a Pit
-- rather than being treated as its own Pit.  Fires at load; idempotent across reloads (the XML re-supplies
-- needsBarn=true each time).  The standalone Pit (needsBarn=false) is left untouched.
local function neutralizeManureExtension(self)
    local spec = self ~= nil and self.spec_manureHeap or nil
    if spec == nil then return end
    if spec.needsBarn == true then
        spec.sdManureExt = true
        spec.needsBarn = false
    end
end
local function installManureExtensionPlaceable()
    if PlaceableManureHeap == nil then return end
    local hooked = false
    if PlaceableManureHeap.onLoad ~= nil then
        PlaceableManureHeap.onLoad = Utils.appendedFunction(PlaceableManureHeap.onLoad,
            function(self) pcall(neutralizeManureExtension, self) end)
        hooked = true
    end
    if PlaceableManureHeap.onPostLoad ~= nil then
        PlaceableManureHeap.onPostLoad = Utils.appendedFunction(PlaceableManureHeap.onPostLoad,
            function(self) pcall(neutralizeManureExtension, self) end)
        hooked = true
    end
    if hooked then print("[SmartDistribution] manure-extension freed from needsBarn") end
end

-- Hard placement gates via getCanBePlacedAt (the base placement-validity method both extension types
-- override).  Manure extension: must sit next to a Manure Heap (Pit) or placement is refused.  Slurry
-- extension: its "...next to a barn" message is reworded to "...next to a Slurry Pit".  Grain extension
-- is left alone (it already reads "...next to a silo").
local function installExtensionPlacementGates()
    if PlaceableManureHeap ~= nil and PlaceableManureHeap.getCanBePlacedAt ~= nil then
        PlaceableManureHeap.getCanBePlacedAt = Utils.overwrittenFunction(PlaceableManureHeap.getCanBePlacedAt,
            function(self, superFunc, ...)
                local canPlace, warning = superFunc(self, ...)
                local spec = self.spec_manureHeap
                if spec ~= nil and spec.sdManureExt == true and canPlace == true then
                    local x, y, z = ...
                    if type(x) ~= "number" or type(z) ~= "number" then
                        if self.rootNode ~= nil then x, y, z = getWorldTranslation(self.rootNode) end
                    end
                    if not manurePitInRange(x, z) then
                        return false, "A Manure Heap Extension needs to be placed near a manure heap."
                    end
                end
                return canPlace, warning
            end)
    end
    if PlaceableSiloExtension ~= nil and PlaceableSiloExtension.getCanBePlacedAt ~= nil then
        PlaceableSiloExtension.getCanBePlacedAt = Utils.overwrittenFunction(PlaceableSiloExtension.getCanBePlacedAt,
            function(self, superFunc, ...)
                local canPlace, warning = superFunc(self, ...)
                if canPlace == false and isSlurryExtension(self) then
                    return false, "A slurry pit extension needs to be placed near a slurry pit."
                end
                return canPlace, warning
            end)
    end
    log("extension placement gates installed")
end

local function installManureHeapDetach()
    -- a heap placed near a barn registers onto the barn's unloading station -> detach it, then re-map
    if PlaceableManureHeap ~= nil and PlaceableManureHeap.onFinalizePlacement ~= nil then
        PlaceableManureHeap.onFinalizePlacement = Utils.appendedFunction(
            PlaceableManureHeap.onFinalizePlacement, function(self) pcall(detachManureHeap, self); pcall(rebuildManureExtensionMap) end)
    end
    -- a barn placed near existing heaps re-scans + re-adds them -> sweep them back off
    if PlaceableHusbandry ~= nil and PlaceableHusbandry.onFinalizePlacement ~= nil then
        PlaceableHusbandry.onFinalizePlacement = Utils.appendedFunction(
            PlaceableHusbandry.onFinalizePlacement, function(self) pcall(detachAllManureHeaps) end)
    end
    -- savegame load: after every placeable is finalized, sweep all heaps off all barns + build the map
    if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
        Mission00.loadMission00Finished = Utils.appendedFunction(
            Mission00.loadMission00Finished, function(...) pcall(detachAllManureHeaps); pcall(rebuildManureExtensionMap) end)
    end
    log("manure-heap detach installed")
end

local function installProximityWatcher()
    if Mission00 == nil or Mission00.loadMission00Finished == nil then return end
    Mission00.loadMission00Finished = Utils.appendedFunction(
        Mission00.loadMission00Finished,
        function()
            pcall(function()
                if g_currentMission ~= nil and g_currentMission.addUpdateable ~= nil then
                    g_currentMission:addUpdateable(proximityWatcher)
                    log("proximity watcher installed")
                end
            end)
        end)
end

-- Register the consolidated TabbedMenu once, after the mission has finished
-- loading (so g_gui and the base GUI classes are ready).
local function installMenu()
    if Mission00 == nil or Mission00.loadMission00Finished == nil then return end
    Mission00.loadMission00Finished = Utils.appendedFunction(
        Mission00.loadMission00Finished,
        function() pcall(SmartDistribution.registerMenuGui) end)
end

-- ---- rename unlock ---------------------------------------------------------
-- The base game only shows its rename option for placeables whose XML opts in with
-- <base><canBeRenamed>true</canBeRenamed></base> (greenhouses and husbandries do; bunker silos and most
-- storage do not). That flag is just a field on the placeable, so DR flips it on for every building in
-- its network: the player renames from the base-game construction menu, and the name flows back through
-- getName() into DR's lists. No custom rename UI, and the name saves + syncs like any other.
function SmartDistribution.isNetworkAsset(p)
    if p == nil or p.rootNode == nil then return false end
    return SmartDistribution.productionPointOf ~= nil and SmartDistribution.productionPointOf(p) ~= nil
        or p.spec_productionPoint ~= nil
        or p.spec_husbandry ~= nil
        or p.spec_silo ~= nil
        or p.spec_objectStorage ~= nil
        or p.spec_sellingStation ~= nil
end

function SmartDistribution.unlockRename(p)
    if p ~= nil and p.canBeRenamed ~= true and SmartDistribution.isNetworkAsset(p) then
        p.canBeRenamed = true
    end
end

if PlaceableSystem ~= nil and PlaceableSystem.addPlaceable ~= nil then
    PlaceableSystem.addPlaceable = Utils.appendedFunction(PlaceableSystem.addPlaceable, function(_, placeable)
        SmartDistribution.unlockRename(placeable)
    end)
else
    log("rename unlock: PlaceableSystem.addPlaceable not found; renaming left as the base game set it.")
end

-- ---- Hold Internal: suppress vanilla egg / wool / honey pallet spawning -----
-- A pallet-spawner husbandry (chicken coop, sheep barn) set to Hold Internal should keep its product in
-- the building's internal buffer (spec_husbandryPallets.fillLevels), NOT spawn physical pallets. The base
-- game accumulates output in updateOutput / addPendingLiters and SPAWNS separately in
-- PlaceableHusbandryPallets.updatePallets (confirmed via sdPalletProbe). Overriding updatePallets to
-- no-op while EVERY spawner fill type is HOLD_INTERNAL stops the spawn but leaves accumulation intact --
-- switch the mode back and the accumulated buffer spawns as pallets again. Because the override re-checks
-- the resolved mode on every call it survives save/reload (the prior symptom, Open Item 6.1). The server
-- runs the pallet update, so this replicates in multiplayer. SmartDistribution.* fields, never top-level
-- locals, to respect the 200-local main-chunk ceiling.
function SmartDistribution.shouldHoldPalletsInternal(p)
    if p == nil or p.spec_husbandryPallets == nil or not isEnrolled(p) then return false end
    local fts = palletSpawnerFillTypes(p)
    if fts == nil or #fts == 0 then return false end
    for _, ft in ipairs(fts) do
        if resolveMode(p, ft) ~= MODE.HOLD_INTERNAL then return false end   -- any non-held output -> let vanilla spawn
    end
    return true
end
function SmartDistribution.installHoldInternalPalletSuppression()
    if PlaceableHusbandryPallets == nil or PlaceableHusbandryPallets.updatePallets == nil then
        log("hold-internal pallet suppression: PlaceableHusbandryPallets.updatePallets not found [VERIFY]")
        return
    end
    PlaceableHusbandryPallets.updatePallets = Utils.overwrittenFunction(
        PlaceableHusbandryPallets.updatePallets,
        function(self, superFunc, ...)
            if SmartDistribution.shouldHoldPalletsInternal(self) then return end   -- suppress spawn; keep buffer
            return superFunc(self, ...)
        end)
    log("hold-internal pallet suppression installed")
end

install()
installPersistence()
-- installConsole()   -- dev console commands (sdList / sdMode / sdSpawn / sd*Probe / ...) disabled for release. Uncomment to re-enable for testing.
-- TEMP dev probe for the Markets feature; disabled for release (uncomment to re-enable):
-- if addConsoleCommand ~= nil then
--     addConsoleCommand("sdMarketProbe", "Dump owned selling-station/market spec + sell API [dev]", "cmdMarketProbe", SmartDistribution)
-- end
installInteraction()
installHusbandryPatch()
SmartDistribution.installHoldInternalPalletSuppression()
installManureExtensionPlaceable()
installExtensionPlacementGates()
installManureHeapDetach()
installProximityWatcher()
installMenu()

-- ---- cross-mod API publish -------------------------------------------------
-- FS25 loads each mod's scripts in its OWN script environment, so a bare top-level
-- global defined here does not reliably reach another mod (e.g. Production Redux).
-- Publish the API through channels a companion mod can definitely read:
--   1) the shared root environment via getfenv(0), when available;
--   2) g_currentMission once the mission exists (set at load-finished, which runs
--      before a later-loading companion mod's own load-finished hook).
-- wrapped in a function so its locals don't count against this file's 200-local
-- main-chunk ceiling (bare top-level locals here would overflow it)
;(function()
    local ok, G = pcall(getfenv, 0)
    if ok and type(G) == "table" then G.SmartDistribution = SmartDistribution end
end)()
if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
    Mission00.loadMission00Finished = Utils.appendedFunction(
        Mission00.loadMission00Finished,
        function()
            if g_currentMission ~= nil then
                g_currentMission.smartDistribution = SmartDistribution
            end
        end)
end

-- ============================================================================
-- Distribution control layer: input source blocks + output priority + store targets.
--
-- OWNED AND PERSISTED BY DISTRIBUTION REDUX. (This began life in Production Redux, which
-- pushed it in via setControl(); PR is retired and DR now owns the whole feature.)
--
--   blocked[consumerUid][ft][sourceUid] = true      source may NOT feed that consumer
--   priority[sourceUid][ft] = { consumerUid, ... }  ordered, rank 1 first
--   (destinations are demands, stores or markets; unified source-side model)
--
-- The allocator reads these directly: gatherSources filters blocked edges, and allocate()
-- fills a contested source's claimants in rank order (proportional split when unranked).
-- Empty tables => behaviour is exactly as it was before any of this existed.
-- Everything here is SmartDistribution.* fields -- the file is at Lua's 200 main-chunk
-- local ceiling, so no new top-level locals may be introduced.
-- ============================================================================
SmartDistribution.control = SmartDistribution.control or { blocked = {}, priority = {}, inputBlock = {}, inputCapPct = {}, inputTarget = {} }

function SmartDistribution.setControl(t)
    if type(t) ~= "table" then t = {} end
    SmartDistribution.control = {
        blocked     = t.blocked     or {},   -- [srcUid][ft][destUid] = true : output never goes to that destination
        priority    = t.priority    or {},   -- [srcUid][ft] = { destUid, ... } : ranked order; unranked -> distance
        inputBlock  = t.inputBlock  or {},   -- [rcvUid][ft] = true : building refuses this product on the way IN
        inputCapPct = t.inputCapPct or {},   -- [rcvUid][ft] = 0..100 : max % of the (pooled) capacity this product may take
        inputTarget = t.inputTarget or {},   -- [rcvUid][ft] = 0..100 : fill target as % of that product's capacity share
    }
end

-- Reset ALL advanced input/output overrides to default (empty the source blocks / priority, and the
-- receiver input blocks / caps / targets). Called when the Advanced routing master switch is turned OFF,
-- so switching it off truly resets those settings rather than just ignoring them until it's turned back on.
-- Move To modes aren't stored here -- they lose their endpoint with Advanced off and enforceValidModes
-- reverts them to Hold on the next hourly pass.
function SmartDistribution.clearAdvancedControl()
    local C = SmartDistribution.control
    if C == nil then return end
    C.blocked, C.priority, C.inputBlock, C.inputCapPct, C.inputTarget = {}, {}, {}, {}, {}
end

-- ============================================================================
-- UNIFIED OUTPUT->DESTINATION CONTROL (source-side).
--
-- One block table and one priority table, both keyed by the SOURCE output:
--   blocked[srcUid][ft][destUid]  the output never routes to that destination (demand, store or market)
--   priority[srcUid][ft] = {...}  ranked destinations; anything unranked falls back to nearest-first
--
-- Every mode reads the same thing: "all valid destinations for this output, minus blocked, in priority
-- then distance order." Move To differs only in its DEFAULT: the dialog blocks every store when the
-- player switches an output to Move To, so nothing moves until they deliberately unblock (activate)
-- targets -- the loop-safe default. There is no separate allow-list anymore.
-- ============================================================================

-- block / unblock one output->destination edge
function SmartDistribution.setDestBlocked(srcUid, ft, destUid, blocked)
    local B = SmartDistribution.control.blocked
    if blocked then
        B[srcUid] = B[srcUid] or {}
        B[srcUid][ft] = B[srcUid][ft] or {}
        B[srcUid][ft][destUid] = true
    else
        local bs = B[srcUid]
        local bf = bs ~= nil and bs[ft] or nil
        if bf ~= nil then
            bf[destUid] = nil
            if next(bf) == nil then bs[ft] = nil end
            if next(bs) == nil then B[srcUid] = nil end
        end
    end
end

-- Master switch for the Advanced routing overrides (source-side blocks + priority, receiver-side input
-- blocks + caps). When OFF, the four accessors below return their NEUTRAL value, so the hourly pass ignores
-- every stored override and reverts to the default nearest-first, distance-based behaviour -- the stored
-- edits are kept (not wiped), so flipping it back on restores them. Default ON.
function SmartDistribution.advancedEnabled()
    local g = SmartDistribution.settings and SmartDistribution.settings.global
    return g == nil or g.advancedRoutingEnabled ~= false
end

function SmartDistribution.isDestBlocked(srcUid, ft, destUid)
    if not SmartDistribution.advancedEnabled() then return false end
    local b = SmartDistribution.control.blocked
    local bs = b ~= nil and b[srcUid] or nil
    local bf = bs ~= nil and bs[ft] or nil
    return bf ~= nil and bf[destUid] == true
end

-- toggle a destination's place in the (source, ft) priority order (append / remove + compact)
function SmartDistribution.toggleDestPriority(srcUid, ft, destUid)
    local P = SmartDistribution.control.priority
    P[srcUid] = P[srcUid] or {}
    local list = P[srcUid][ft]
    if list == nil then list = {}; P[srcUid][ft] = list end
    local found
    for i = 1, #list do if list[i] == destUid then found = i; break end end
    if found ~= nil then
        table.remove(list, found)
        if #list == 0 then
            P[srcUid][ft] = nil
            if next(P[srcUid]) == nil then P[srcUid] = nil end
        end
    else
        list[#list + 1] = destUid
    end
end

-- move a ranked destination up/down one place
function SmartDistribution.moveDestPriority(srcUid, ft, destUid, delta)
    local P = SmartDistribution.control.priority
    local list = P[srcUid] ~= nil and P[srcUid][ft] or nil
    if list == nil then return end
    local at
    for i = 1, #list do if list[i] == destUid then at = i; break end end
    if at == nil then return end
    local to = math.max(1, math.min(#list, at + (delta or 0)))
    if to == at then return end
    table.remove(list, at)
    table.insert(list, to, destUid)
end

function SmartDistribution.clearDestPriority(srcUid, ft)
    local P = SmartDistribution.control.priority
    if P[srcUid] ~= nil then
        P[srcUid][ft] = nil
        if next(P[srcUid]) == nil then P[srcUid] = nil end
    end
end

-- rank of a destination in the (source, ft) order, or nil when unranked
function SmartDistribution.destRank(srcUid, ft, destUid)
    local P = SmartDistribution.control.priority
    local list = P[srcUid] ~= nil and P[srcUid][ft] or nil
    if list == nil then return nil end
    for i = 1, #list do if list[i] == destUid then return i end end
    return nil
end

-- has the player ranked this (source, ft) at all? (any explicit order present)
function SmartDistribution.destsAreRanked(srcUid, ft)
    local P = SmartDistribution.control.priority
    local list = P[srcUid] ~= nil and P[srcUid][ft] or nil
    return list ~= nil and #list > 0
end

-- ============================================================================
-- RECEIVER-SIDE INPUT CONTROL (block + per-product max %).
--
-- Separate from the source-side block/priority: this governs what a building will accept ON THE WAY IN.
--   inputBlock[rcvUid][ft]  = true    -- the building refuses this product entirely
--   inputCapPct[rcvUid][ft] = 0..100  -- max % of the (pooled) capacity this product may occupy
--
-- WHY PERCENT, not litres: a silo extension changes the capacity; a percent cap rides that change with
-- no re-tuning, and the UI shows the live litre equivalent so the player still sees the real number.
--
-- POOLED vs INDIVIDUAL capacity. Some buildings share one capacity across several products (an object-
-- storage hay loft: N bale slots shared by hay + straw; a bulk tank that accepts several fill types).
-- There, one product can starve another -- the cap is what stops straw filling the loft and locking out
-- hay. Individual per-product tanks can't starve each other, so a cap there is just a fine-tune.
-- ============================================================================

-- The pooled TOTAL capacity (in litres) a building shares across products, plus the set of products that
-- share it, or nil when the building has no pooled capacity. Three pooled shapes exist:
--   * object-storage shed (hay loft, pallet shed): slot count is one shared limit; litres = slots x per-slot
--   * husbandry FOOD: spec_husbandryFood is ONE shared pool across all the food types the animals accept
--     (the barn shows a single "Food" total). Straw and water are SEPARATE specs, each a single fill type,
--     so they are individual -- never pooled. A food pool only matters when 2+ food types share it.
--   * bulk store: pooled when ONE storage tank supports 2+ fill types.
function SmartDistribution.pooledInputCapacity(p)
    if p == nil then return nil end
    -- Feeding-robot barns take ingredients into INDIVIDUAL per-fill-type bunkers (unloadingSpots), each with
    -- its own capacity. They also carry a generic spec_husbandryFood pool whose supported types include
    -- silage / hay -- but that pool is NOT a DR target here, and matching it would mislabel the bunkers as
    -- pooled (silage + hay shown sharing 60k at 25% each). Never pool a robot barn: each bunker is its own
    -- tank, resolved individually by inputProductCapacity -> husbandryInputCapacity.
    if SmartDistribution.feedingRobotOf(p) ~= nil then return nil end
    -- object-storage shed (hay loft, pallet shed): shared slot pool
    local spec = p.spec_objectStorage
    if spec ~= nil then
        local slots = spec.capacity or 0
        if slots <= 0 then return nil end                     -- unlimited: no meaningful cap
        local fts = {}
        if SmartDistribution.shedSupportedFillTypes ~= nil then
            for ft in pairs(SmartDistribution.shedSupportedFillTypes(p)) do fts[#fts + 1] = ft end
        end
        if #fts < 1 then return nil end
        -- litres per slot: infer from stock on hand, else a sane bale default
        local perSlot = SmartDistribution._shedLitresPerSlot(p)
        return { liters = slots * perSlot, fts = fts, kind = "SHED", slots = slots, perSlot = perSlot }
    end
    -- production input buffer: pp.storage holds every input. FS25 productions usually give each input its
    -- OWN capacity (capacities[ft]) -> individual, no contention. Some share one buffer across inputs ->
    -- pooled. Detect: if a per-ft capacities table lists the inputs, they're individual (return nil here,
    -- inputProductCapacity resolves each one); if the storage exposes only a single shared capacity that
    -- every input draws from, they're pooled.
    local pp = getProductionPoint(p)
    if pp ~= nil and pp.storage ~= nil then
        local fts = {}
        if type(pp.inputFillTypeIds) == "table" then
            for ft in pairs(pp.inputFillTypeIds) do fts[#fts + 1] = ft end
        end
        if #fts < 2 then return nil end                        -- 0-1 inputs: nothing to pool
        local st = pp.storage
        local perFt = type(st.capacities) == "table"
        if perFt then
            -- confirm EACH input has its own entry; if any input is missing a per-ft cap the buffer is
            -- effectively shared for that input, so treat the whole thing as pooled to be safe.
            for _, ft in ipairs(fts) do if st.capacities[ft] == nil then perFt = false; break end end
        end
        if perFt then return nil end                           -- individual per-input buffers: not pooled
        -- shared buffer: total = current levels + free (free is the same shared remainder for any input)
        local total = 0
        for _, ft in ipairs(fts) do total = total + (getLevel(st, ft) or 0) end
        local cap = total + getFree(st, fts[1])
        if cap > 0 and cap < INF then return { liters = cap, fts = fts, kind = "PRODIN", storage = st } end
        return nil
    end
    -- husbandry FOOD pool: one shared capacity across all accepted food types (straw / water are their own
    -- single-type specs and are NOT part of this pool). Only a pool when 2+ food types share it.
    local fs = p.spec_husbandryFood
    if fs ~= nil and fs.supportedFillTypes ~= nil then
        local water = waterFillType()
        local fts = {}
        for ft in pairs(fs.supportedFillTypes) do
            if ft ~= water then fts[#fts + 1] = ft end
        end
        if #fts >= 2 then
            local cap = fs.capacity or 0
            if cap > 0 then return { liters = cap, fts = fts, kind = "FOOD" } end
        end
        return nil   -- a husbandry's non-food inputs (straw, water) are individual, never pooled
    end
    -- bulk storage that supports several fts in ONE storage = pooled
    for _, s in ipairs(getAllStorages(p)) do
        local fts = {}
        for ft in pairs(storageFillTypes(s)) do fts[#fts + 1] = ft end
        if #fts >= 2 then
            -- shared capacity: getFreeCapacity returns the same remaining total for every ft, so total
            -- capacity = current total level + free
            local total = 0
            for _, ft in ipairs(fts) do total = total + (getLevel(s, ft) or 0) end
            local cap = total + getFree(s, fts[1])
            if cap > 0 and cap < INF then return { liters = cap, fts = fts, kind = "BULK", storage = s } end
        end
    end
    return nil
end

-- best-effort litres-per-slot for a shed: average of what's stored, else a bale-sized default.
function SmartDistribution._shedLitresPerSlot(p)
    local spec = p ~= nil and p.spec_objectStorage or nil
    if spec ~= nil then
        local stored = (spec.storedObjects ~= nil and #spec.storedObjects) or (spec.numStoredObjects or 0)
        if stored and stored > 0 and SmartDistribution.shedSupportedFillTypes ~= nil then
            local totalL = 0
            for ft in pairs(SmartDistribution.shedSupportedFillTypes(p)) do totalL = totalL + (shedStoredLiters(p, ft) or 0) end
            if totalL > 0 then return totalL / stored end
        end
    end
    return 4000   -- a round bale ~ 4000 L; only used until real stock reveals the true per-slot size
end

-- the litre capacity + current level for a specific input product at a building. For pooled storage the
-- capacity is the shared pool; for individual storage it's that product's own tank.
function SmartDistribution.inputProductCapacity(p, ft)
    local pool = SmartDistribution.pooledInputCapacity(p)
    if pool ~= nil then
        for _, pf in ipairs(pool.fts) do if pf == ft then return pool.liters, pool end end
    end
    -- production input (individual per-ft buffer): capacity is this input's own slot in pp.storage
    local pp = getProductionPoint(p)
    if pp ~= nil and pp.storage ~= nil then
        local cap = (getLevel(pp.storage, ft) or 0) + getFree(pp.storage, ft)
        if cap > 0 and cap < INF then return cap, nil end
        return 0, nil
    end
    -- husbandry non-food inputs (straw / water) or a food type on a single-food barn: use the husbandry
    -- capacity helper, which knows the food pool from straw/water.
    if p ~= nil and isHusbandryBuilding(p) and SmartDistribution.husbandryInputCapacity ~= nil then
        local c = SmartDistribution.husbandryInputCapacity(p, ft)
        if type(c) == "number" and c > 0 then return c, nil end
    end
    -- individual: this ft's own tank
    if p ~= nil and p.spec_objectStorage == nil then
        for _, s in ipairs(getAllStorages(p)) do
            if storageFillTypes(s)[ft] ~= nil then
                local cap = (getLevel(s, ft) or 0) + getFree(s, ft)
                if cap > 0 and cap < INF then return cap, nil end
            end
        end
    end
    return 0, nil
end

function SmartDistribution.inputHeldLevel(p, ft)
    if p == nil or ft == nil then return 0 end
    if p.spec_objectStorage ~= nil then return shedStoredLiters(p, ft) or 0 end
    -- production input buffer
    local pp = getProductionPoint(p)
    if pp ~= nil and pp.storage ~= nil then return getLevel(pp.storage, ft) or 0 end
    -- husbandry: food reports the shared-pool total, straw/water their own levels
    if isHusbandryBuilding(p) and SmartDistribution.husbandryInputHeld ~= nil then
        return SmartDistribution.husbandryInputHeld(p, ft) or 0
    end
    local s = SmartDistribution._bulkStorageFor(p, ft)
    if s ~= nil then return getLevel(s, ft) or 0 end
    return SmartDistribution.assetHeld(p, ft)
end

-- ---- input block ----------------------------------------------------------
function SmartDistribution.setInputBlocked(rcvUid, ft, blocked)
    local C = SmartDistribution.control
    C.inputBlock = C.inputBlock or {}
    local B = C.inputBlock
    if blocked then
        B[rcvUid] = B[rcvUid] or {}
        B[rcvUid][ft] = true
    elseif B[rcvUid] ~= nil then
        B[rcvUid][ft] = nil
        if next(B[rcvUid]) == nil then B[rcvUid] = nil end
    end
end
function SmartDistribution.isInputBlocked(rcvUid, ft)
    if not SmartDistribution.advancedEnabled() then return false end
    local ib = SmartDistribution.control.inputBlock
    local b = ib ~= nil and ib[rcvUid] or nil
    return b ~= nil and b[ft] == true
end

-- ---- input max % ----------------------------------------------------------
-- Default % when the player hasn't set one: pooled storage splits evenly across the products that share
-- it (250k pool, 2 products -> 125k -> 50% each); individual storage defaults to 100% (no restriction).
function SmartDistribution.defaultInputCapPct(p, ft)
    local pool = SmartDistribution.pooledInputCapacity(p)
    if pool ~= nil then
        for _, pf in ipairs(pool.fts) do
            if pf == ft then
                local n = #pool.fts
                if n > 0 then return math.floor(100 / n + 0.5) end
            end
        end
    end
    return 100
end

-- For a POOLED product, the highest % it may be set to so the pool's shares still sum to <= 100%:
--   100 - (sum of the OTHER pooled products' effective caps).
-- Individual (non-pooled) products aren't constrained this way, so they return 100.
function SmartDistribution.inputCapPctHeadroom(p, ft)
    local pool = SmartDistribution.pooledInputCapacity(p)
    if pool == nil then return 100 end
    local inPool = false
    for _, pf in ipairs(pool.fts) do if pf == ft then inPool = true; break end end
    if not inPool then return 100 end
    local others = 0
    for _, pf in ipairs(pool.fts) do
        if pf ~= ft then others = others + (SmartDistribution.inputCapPct(p, pf) or 0) end
    end
    return math.max(0, 100 - others)
end
function SmartDistribution.setInputCapPct(rcvUid, ft, pct)
    if pct == nil then return end
    pct = math.max(0, math.min(100, math.floor(pct + 0.5)))
    local C = SmartDistribution.control
    C.inputCapPct = C.inputCapPct or {}
    local T = C.inputCapPct
    T[rcvUid] = T[rcvUid] or {}
    T[rcvUid][ft] = pct
end
function SmartDistribution.clearInputCapPct(rcvUid, ft)
    local C = SmartDistribution.control.inputCapPct
    if C ~= nil and C[rcvUid] ~= nil then
        C[rcvUid][ft] = nil
        if next(C[rcvUid]) == nil then C[rcvUid] = nil end
    end
end

-- ---- input FILL TARGET ------------------------------------------------------
-- A per-(receiver, ft) setpoint: fill this product up to targetPct % of its capacity SHARE, then just hold
-- that level (top up what's consumed each cycle) instead of the default recipe / buffer-hours demand. As a
-- percentage it rides capacity changes automatically. nil = no target (default demand). Set nil to clear.
function SmartDistribution.setInputTargetPct(rcvUid, ft, pct)
    local C = SmartDistribution.control
    C.inputTarget = C.inputTarget or {}
    local T = C.inputTarget
    if pct == nil then
        if T[rcvUid] ~= nil then T[rcvUid][ft] = nil; if next(T[rcvUid]) == nil then T[rcvUid] = nil end end
        return
    end
    pct = math.max(0, math.min(100, math.floor(pct + 0.5)))
    T[rcvUid] = T[rcvUid] or {}
    T[rcvUid][ft] = pct
end
function SmartDistribution.getInputTargetPct(rcvUid, ft)
    local T = SmartDistribution.control.inputTarget
    local C = T ~= nil and T[rcvUid] or nil
    return C ~= nil and C[ft] or nil
end
-- The target LEVEL in litres for (p, ft): targetPct % of the product's cap-adjusted capacity (pool share or
-- own tank). nil when no target is set, or when Advanced routing is off (targets are an advanced override).
function SmartDistribution.inputTargetLiters(p, ft)
    if not SmartDistribution.advancedEnabled() then return nil end
    local rcvUid = getUid(p)
    local pct = rcvUid ~= nil and SmartDistribution.getInputTargetPct(rcvUid, ft) or nil
    if pct == nil then return nil end
    local cap = SmartDistribution.inputProductCapacity(p, ft)
    if cap == nil or cap <= 0 then return nil end
    local capPct = SmartDistribution.inputCapPct(p, ft) or 100
    return cap * (capPct / 100) * (pct / 100)
end
-- Effective demand for (p, ft) this cycle: if a fill target is set, demand toward that LEVEL (target - cur,
-- clamped >= 0) so DR fills to it then holds it; otherwise the caller's default (recipe / buffer / keep-full).
function SmartDistribution.effectiveInputNeed(p, ft, defaultNeed, cur)
    local tgt = SmartDistribution.inputTargetLiters(p, ft)
    if tgt == nil then return defaultNeed end
    return math.max(0, tgt - (cur or 0))
end
-- the effective % for (rcv, ft): the player's explicit value, else the default.
function SmartDistribution.inputCapPct(p, ft)
    -- Advanced off: no input constraint at all -- return 100% so inputAcceptableLiters lets each product
    -- fill the whole (shared) tank, the base-game first-come approach. The pooled even-split only mattered
    -- for moving product between storages, which is itself disabled with Advanced off, so nothing is left
    -- for the split to protect.
    if not SmartDistribution.advancedEnabled() then return 100 end
    local rcvUid = getUid(p)
    local T = SmartDistribution.control.inputCapPct
    local C = (rcvUid ~= nil and T ~= nil) and T[rcvUid] or nil
    local v = C ~= nil and C[ft] or nil
    if v ~= nil then return v end
    return SmartDistribution.defaultInputCapPct(p, ft)
end
function SmartDistribution.hasExplicitInputCapPct(rcvUid, ft)
    local T = SmartDistribution.control.inputCapPct
    local C = T ~= nil and T[rcvUid] or nil
    return C ~= nil and C[ft] ~= nil
end

-- ENFORCEMENT: how many more litres of `ft` this building will accept right now, given its input block
-- and its per-product cap. Every fill path clamps its deposit to this. Returns a big number when the
-- product is unconstrained (blocked -> 0; no pooled cap and no explicit cap -> the normal free space).
function SmartDistribution.inputAcceptableLiters(p, ft)
    local rcvUid = getUid(p)
    if rcvUid == nil then return INF end
    if SmartDistribution.isInputBlocked(rcvUid, ft) then return 0 end
    local cap, pool = SmartDistribution.inputProductCapacity(p, ft)
    if cap <= 0 then return INF end                            -- unknown capacity: don't constrain
    local pct = SmartDistribution.inputCapPct(p, ft)
    local maxL = cap * (pct / 100)
    local held = SmartDistribution.inputHeldLevel(p, ft)
    return math.max(0, maxL - held)
end

-- "Store To" could push nothing last pass because every chosen store is full (UI indicator).
-- The stock stays where it is and the mode stays on Store To, so it tops them up again next cycle.
SmartDistribution._storeTargetFull = SmartDistribution._storeTargetFull or {}
function SmartDistribution.isStoreTargetFull(sourceUid, ft)
    local t = SmartDistribution._storeTargetFull[sourceUid]
    return t ~= nil and t[ft] == true
end
function SmartDistribution.setStoreTargetFull(sourceUid, ft, full)
    local T = SmartDistribution._storeTargetFull
    if full then
        T[sourceUid] = T[sourceUid] or {}
        T[sourceUid][ft] = true
    elseif T[sourceUid] ~= nil then
        T[sourceUid][ft] = nil
        if next(T[sourceUid]) == nil then T[sourceUid] = nil end
    end
end

-- Compat shim: old consumer-side "is this source blocked from feeding me?" is now source-side
-- isDestBlocked(source, ft, consumer). Kept so input-status views + link status read one block table.
function SmartDistribution.isSourceBlocked(consumerUid, ft, sourceUid)
    return SmartDistribution.isDestBlocked(sourceUid, ft, consumerUid)
end

-- Ordered claim list for a contested source output, or nil when no usable priority
-- is set for (sourceUid, ft). Returning nil keeps allocate()'s proportional split,
-- so the default (no priority) path is byte-identical to the original engine.
-- uidOf(claim) -> the claim's CONSUMER uid.
function SmartDistribution.priorityOrder(sourceUid, ft, claims, uidOf)
    if not SmartDistribution.advancedEnabled() then return nil end   -- default proportional/distance split
    local pr = SmartDistribution.control.priority
    local pf = pr ~= nil and pr[sourceUid] or nil
    local list = pf ~= nil and pf[ft] or nil
    if list == nil or #list == 0 then return nil end
    local rank = {}
    for i = 1, #list do rank[list[i]] = i end
    local ranked, unranked = {}, {}
    for _, cl in ipairs(claims) do
        local u = uidOf(cl)
        if u ~= nil and rank[u] ~= nil then ranked[#ranked + 1] = { cl = cl, r = rank[u] }
        else unranked[#unranked + 1] = cl end
    end
    if #ranked == 0 then return nil end                 -- no ranked claimant here -> default split
    table.sort(ranked, function(a, b) return a.r < b.r end)
    local out = {}
    for _, e in ipairs(ranked) do out[#out + 1] = e.cl end
    for _, cl in ipairs(unranked) do out[#out + 1] = cl end   -- unranked go last, in candidate order
    return out
end

-- ---- Production Redux introspection (read-only network model) ---------------
function SmartDistribution.assetIconFile(p)
    if p == nil then return nil end
    local si = p.storeItem
    if type(si) ~= "table" and g_storeManager ~= nil and g_storeManager.getItemByXMLFilename ~= nil then
        local cfg = p.configFileName or p.xmlFilename
        if cfg ~= nil then
            local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, cfg)
            if ok then si = item end
        end
    end
    if type(si) == "table" then
        local img = si.imageFilename or si.imageFilenameSmall
        if type(img) == "string" and img ~= "" then return img end
    end
    return fillHudIconFile(placeablePrimaryProduct(p))
end

-- The local player's farm id (best-effort across FS25 accessors); nil if unknown.
function SmartDistribution._playerFarmId()
    local m = g_currentMission
    if m == nil then return nil end
    if m.getFarmId ~= nil then local ok, f = pcall(m.getFarmId, m); if ok and f ~= nil then return f end end
    if m.player ~= nil and m.player.farmId ~= nil then return m.player.farmId end
    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then return g_localPlayer.farmId end
    return m.playerFarmId
end

-- Owner farm id of a placeable (getOwnerFarmId method or the field), or nil.
function SmartDistribution._ownerFarmId(p)
    if p == nil then return nil end
    if p.getOwnerFarmId ~= nil then local ok, f = pcall(p.getOwnerFarmId, p); if ok and f ~= nil then return f end end
    return p.ownerFarmId
end

function SmartDistribution._ftTitle(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local def = g_fillTypeManager:getFillTypeByIndex(ft)
        if def ~= nil and def.title ~= nil then return def.title end
    end
    return tostring(ft)
end

-- Products a building supports: inputs (can consume/receive) and outputs (can
-- produce/provide). Productions use their input/output fill-type sets; storages
-- (silos / pits / husbandry) list what they can hold as BOTH (source + sink).
function SmartDistribution.assetProducts(p)
    local inputs, outputs, seenIn, seenOut = {}, {}, {}, {}
    local function addIn(ft)  if ft ~= nil and not seenIn[ft]  then seenIn[ft]  = true; inputs[#inputs + 1]   = ft end end
    local function addOut(ft) if ft ~= nil and not seenOut[ft] then seenOut[ft] = true; outputs[#outputs + 1] = ft end end

    local pp = getProductionPoint(p)
    if pp ~= nil then
        if type(pp.inputFillTypeIds)  == "table" then for ft in pairs(pp.inputFillTypeIds)  do addIn(ft)  end end
        if type(pp.outputFillTypeIds) == "table" then for ft in pairs(pp.outputFillTypeIds) do addOut(ft) end end
        if #inputs == 0 or #outputs == 0 then
            for _, prod in ipairs(pp.productions or {}) do
                for _, i in ipairs(prod.inputs  or {}) do addIn(i.type)  end
                for _, o in ipairs(prod.outputs or {}) do addOut(o.type) end
            end
        end
    end
    for _, s in ipairs(getAllStorages(p)) do
        for ft in pairs(storageFillTypes(s)) do addIn(ft); addOut(ft) end
    end

    local function byName(a, b) return tostring(SmartDistribution._ftTitle(a)) < tostring(SmartDistribution._ftTitle(b)) end
    table.sort(inputs, byName); table.sort(outputs, byName)
    return { inputs = inputs, outputs = outputs }
end

-- Every owned placeable Distribution Redux treats as part of the network, with the
-- products it supports. Sorted by name. Used by Production Redux's Control tab.
function SmartDistribution.enrolledAssets()
    local out = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return out end
    local myFarm = SmartDistribution._playerFarmId()
    for _, p in ipairs(ps.placeables) do
        -- owned by the player only (strict: unowned / other-farm placeables are excluded)
        if p.rootNode ~= nil and isEnrolled(p)
           and (myFarm == nil or SmartDistribution._ownerFarmId(p) == myFarm) then
            local prod = SmartDistribution.assetProducts(p)
            if #prod.inputs > 0 or #prod.outputs > 0 then
                out[#out + 1] = {
                    uid = getUid(p), name = placeableName(p), icon = SmartDistribution.assetIconFile(p),
                    origName = SmartDistribution.placeableRenamedFrom(p),
                    inputs = prod.inputs, outputs = prod.outputs,
                }
            end
        end
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

-- Can placeable p provide ft into the network (mode/enrolment gate + physically holds/outputs it)?
function SmartDistribution.canProvide(p, ft)
    if not canSourceDistribute(p, ft) then return false end
    local pp = getProductionPoint(p)
    if pp ~= nil and type(pp.outputFillTypeIds) == "table" and pp.outputFillTypeIds[ft] then return true end
    for _, s in ipairs(getRawStorages(p, ft)) do if storageSupports(s, ft) then return true end end
    if isPalletSpawnerAsset(p) and palletFillLevel ~= nil and palletFillLevel(p, ft) > 0 then return true end
    if p.spec_objectStorage ~= nil then
        if p.getObjectStorageSupportsFillType == nil then return false end
        local ok, sup = pcall(p.getObjectStorageSupportsFillType, p, ft)
        if ok and sup and shedStoredLiters ~= nil and shedStoredLiters(p, ft) > 0 then return true end
    end
    return false
end

-- All network sources that could feed ft to the consumer (uid), each flagged blocked
-- per the current control state. consumerUid is excluded from its own source list.
function SmartDistribution.sourcesFor(consumerUid, ft)
    local out = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return out end
    local myFarm = SmartDistribution._playerFarmId()
    for _, p in ipairs(ps.placeables) do
        if p.rootNode ~= nil then
            local of = SmartDistribution._ownerFarmId(p)
            local u = getUid(p)
            -- same farm-scoping the engine uses: neutral (nil owner) allowed, other farms excluded
            if u ~= consumerUid and (myFarm == nil or of == nil or of == myFarm)
               and SmartDistribution.canProvide(p, ft) then
                out[#out + 1] = {
                    uid = u, name = placeableName(p), icon = SmartDistribution.assetIconFile(p),
                    blocked = SmartDistribution.isSourceBlocked(consumerUid, ft, u),
                }
            end
        end
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

-- ---- Advanced window data --------------------------------------------------
-- Destinations only make sense for a mode that actually ROUTES the product somewhere. Sell, Market
-- Supply, Hold and Hold Internal send it nowhere on the farm (it is sold, or it just sits there), so
-- they have no destinations and the window must not imply otherwise.
--   showDemands -> the buildings that consume it (rank via the priority order; can be blocked)
--   showStores  -> the stores the player picks for Store To (rank = fill order; "listed" = chosen)
-- The caller decides which apply, because a production's mode lives in the parallel virtual system.
-- Does this MODE route product to demands on the farm? (There is no existing mode-only predicate:
-- canSourceDistribute() takes a placeable + fill type, not a mode, so this tests the mode directly.)
function SmartDistribution.modeDistributes(m)
    return m == MODE.DISTRIBUTE
        or m == MODE.DISTRIBUTE_SELL
        or m == MODE.DISTRIBUTE_STORE
        or m == MODE.DISTRIBUTE_MARKET
        or m == MODE.DISTRIBUTE_STORE_TO
end

-- Destinations of one kind for (asset, ft), for the Advanced window. Called once per section, so exactly
-- one of showDemands/showStores/showMarkets is set. Each row carries rank/listed/blocked + link status.
--   DEMAND -> buildings that consume ft (rank = priority order; can be blocked)
--   STORE  -> silos/sheds/heaps that hold ft (rank = Store To order; "listed" = picked)
--   MARKET -> markets/kiosks that buy ft   (rank = market order;   "listed" = picked)
function SmartDistribution.outputDestinations(asset, ft, showDemands, showStores, showMarkets)
    local out = {}
    if asset == nil or ft == nil then return out end
    if not showDemands and not showStores and not showMarkets then return out end
    local srcUid = getUid(asset)
    if srcUid == nil or asset.rootNode == nil then return out end
    local x, _, z = getWorldTranslation(asset.rootNode)

    -- MARKETS come from marketsFor (sinksFor never returns markets -- a market isn't a network sink).
    if showMarkets then
        local farmId = SmartDistribution._ownerFarmId ~= nil and SmartDistribution._ownerFarmId(asset) or asset.ownerFarmId
        for _, mm in ipairs(SmartDistribution.marketsFor(farmId, ft, x, z, resolveReach(asset))) do
            local muid = getUid(mm.p)
            local rank = SmartDistribution.destRank(srcUid, ft, muid)
            local blk  = SmartDistribution.isDestBlocked(srcUid, ft, muid)
            local status
            if blk then status = SmartDistribution.LINK.BLOCKED
            elseif SmartDistribution.fedBy(muid, ft, srcUid) > 0 then status = SmartDistribution.LINK.ACTIVE
            else status = SmartDistribution.LINK.IDLE end
            out[#out + 1] = {
                uid = muid, name = placeableName(mm.p), kind = "MARKET",
                dist = math.sqrt(mm.d2), rank = rank, listed = rank ~= nil, blocked = blk,
                status = status, statusLabel = (SmartDistribution.LINK_LABEL or {})[status] or "",
            }
        end
        table.sort(out, function(a, b)
            if (a.rank ~= nil) ~= (b.rank ~= nil) then return a.rank ~= nil end
            if a.rank ~= nil and b.rank ~= nil and a.rank ~= b.rank then return a.rank < b.rank end
            return a.dist < b.dist
        end)
        return out
    end

    -- STORES: build directly from every form-compatible store (sinksFor is for network demand and does
    -- not return sheds). This mirrors the engine's Store To validity exactly, so the pickable list and
    -- what actually gets pushed always agree.
    if showStores then
        local form = SmartDistribution.sourceHoldForm ~= nil and SmartDistribution.sourceHoldForm(asset, ft) or nil
        if form == nil then
            if asset.spec_objectStorage ~= nil then form = "PALLET" else form = "BULK" end
        end
        if SmartDistribution._storeToDebug then SmartDistribution.log("advstore: %s [%s] form=%s", placeableName(asset), fillTypeName(ft), tostring(form)) end
        local myFarm = SmartDistribution._ownerFarmId(asset)
        local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
        for _, p in ipairs(ps ~= nil and ps.placeables or {}) do
            if p ~= asset and p.rootNode ~= nil then
                local en = isEnrolled(p)
                local sameFarm = SmartDistribution._ownerFarmId(p) == myFarm
                local valid = SmartDistribution.storeToTargetValid ~= nil and SmartDistribution.storeToTargetValid(form, p, ft)
                if SmartDistribution._storeToDebug and (getAssetClass(p) == "SHED" or getAssetClass(p) == "SILO" or getAssetClass(p) == "HEAP") then
                    SmartDistribution.log("advstore:   cand %s cls=%s enrolled=%s sameFarm=%s valid=%s",
                        placeableName(p), getAssetClass(p), tostring(en), tostring(sameFarm), tostring(valid))
                end
                if en and sameFarm and valid then
                local puid = getUid(p)
                local tx, _, tz = getWorldTranslation(p.rootNode)
                local rank = SmartDistribution.destRank(srcUid, ft, puid)
                local blk  = SmartDistribution.isDestBlocked(srcUid, ft, puid)
                local status
                if blk then status = SmartDistribution.LINK.BLOCKED
                elseif SmartDistribution.fedBy(puid, ft, srcUid) > 0 then status = SmartDistribution.LINK.ACTIVE
                else status = SmartDistribution.LINK.IDLE end
                out[#out + 1] = {
                    uid = puid, name = placeableName(p), kind = "STORE",
                    dist = math.sqrt((tx - x) ^ 2 + (tz - z) ^ 2),
                    rank = rank, listed = rank ~= nil, blocked = blk,
                    status = status, statusLabel = (SmartDistribution.LINK_LABEL or {})[status] or "",
                }
                end   -- if en and sameFarm and valid
            end   -- if p ~= asset and rootNode
        end
        table.sort(out, function(a, b)
            if (a.rank ~= nil) ~= (b.rank ~= nil) then return a.rank ~= nil end
            if a.rank ~= nil and b.rank ~= nil and a.rank ~= b.rank then return a.rank < b.rank end
            return a.dist < b.dist
        end)
        return out
    end

    -- DEMANDS: buildings that consume ft (from the network sink list).
    for _, s in ipairs(SmartDistribution.sinksFor(srcUid, ft)) do
        local p = SmartDistribution.placeableByUid(s.uid)
        if p ~= nil and p.rootNode ~= nil then
            local cls = getAssetClass(p)
            local isStore = (cls == "SILO" or cls == "SHED" or cls == "HEAP")
            if (not isStore) and showDemands then
                local tx, _, tz = getWorldTranslation(p.rootNode)
                local dist = math.sqrt((tx - x) ^ 2 + (tz - z) ^ 2)
                local rank    = SmartDistribution.destRank(srcUid, ft, s.uid)
                local blocked = SmartDistribution.isDestBlocked(srcUid, ft, s.uid)   -- this output blocks that demand
                local status
                if blocked then status = SmartDistribution.LINK.BLOCKED
                elseif SmartDistribution.fedBy(s.uid, ft, srcUid) > 0 then status = SmartDistribution.LINK.ACTIVE
                else status = SmartDistribution.LINK.IDLE end
                out[#out + 1] = {
                    uid = s.uid, name = s.name, icon = s.icon, kind = "DEMAND",
                    dist = dist, rank = rank, listed = rank ~= nil, blocked = blocked,
                    status = status, statusLabel = (SmartDistribution.LINK_LABEL or {})[status] or "",
                }
            end
        end
    end

    -- ranked (in order) first, then nearest-first
    table.sort(out, function(a, b)
        if (a.rank ~= nil) ~= (b.rank ~= nil) then return a.rank ~= nil end
        if a.rank ~= nil and b.rank ~= nil and a.rank ~= b.rank then return a.rank < b.rank end
        return a.dist < b.dist
    end)
    return out
end

-- ---- output link status (source side; mirror of inputLinkStatus) ------------
-- Same three states + colours as the input side, but ACTIVE reads "Sending" (a source sends; a receiver
-- receives), so outgoing rows use OUT_LINK_LABEL.
SmartDistribution.OUT_LINK_LABEL = {
    ACTIVE  = "Active (Sending)",
    IDLE    = "Active (Idle)",
    BLOCKED = "Blocked",
}

-- The destinations relevant to (asset, ft)'s CURRENT mode -- demands for a distribute mode, stores for a
-- store / Move To mode, markets for a market mode (combined for combo modes) -- each carrying a .blocked
-- flag. Mirrors DistributionAdvancedDialog:resolveOutput so the status matches what the Advanced dialog shows.
function SmartDistribution.outputDestinationsForMode(asset, ft)
    local out = {}
    if asset == nil or ft == nil then return out end
    local showDemands, rightKind = false, nil
    local pp = getProductionPoint(asset)
    if pp ~= nil then
        local v = SmartDistribution.productionOutputVMode ~= nil and SmartDistribution.productionOutputVMode(pp, ft) or nil
        showDemands = (v == 1 or v == 3 or v == 4 or v == 7)
        if v == 4 or v == 5 then rightKind = "STORE" elseif v == 6 or v == 7 then rightKind = "MARKET" end
    else
        local m = SmartDistribution.resolvedAssetMode(asset, ft)
        local M = MODE
        showDemands = (SmartDistribution.modeDistributes ~= nil) and SmartDistribution.modeDistributes(m) or false
        if m == M.STORE or m == M.DISTRIBUTE_STORE or m == M.STORE_TO or m == M.DISTRIBUTE_STORE_TO then rightKind = "STORE"
        elseif m == M.TRANSFER_MARKET or m == M.DISTRIBUTE_MARKET then rightKind = "MARKET" end
    end
    local function append(list) for _, d in ipairs(list or {}) do out[#out + 1] = d end end
    if showDemands then append(SmartDistribution.outputDestinations(asset, ft, true, false, false)) end
    if rightKind == "STORE" then append(SmartDistribution.outputDestinations(asset, ft, false, true, false))
    elseif rightKind == "MARKET" then append(SmartDistribution.outputDestinations(asset, ft, false, false, true)) end
    return out
end

-- Overall status of an OUTGOING product row: Sending if it moved product anywhere last cycle; Blocked if it
-- has routable destinations but every one is blocked; otherwise Idle. Returns nil for a non-sending mode
-- (Hold / Hold Internal / Inherit / production Keep) so the status column stays blank there.
function SmartDistribution.outputLinkStatus(p, ft)
    if p == nil or ft == nil then return nil end
    local L, M = SmartDistribution.LINK, MODE
    local pp = getProductionPoint(p)
    if pp ~= nil then
        local v = SmartDistribution.productionOutputVMode ~= nil and SmartDistribution.productionOutputVMode(pp, ft) or nil
        if v == nil or v == 0 then return nil end            -- 0 = Keep (Hold)
    else
        local m = SmartDistribution.resolvedAssetMode(p, ft)
        if m == nil or m == M.INHERIT or m == M.HOLD or m == M.HOLD_INTERNAL then return nil end
    end
    local dist, sold, stored = SmartDistribution.lastCycleStats(p, ft)
    if (dist + sold + stored) > 0 then return L.ACTIVE end   -- Sending
    local dests = SmartDistribution.outputDestinationsForMode(p, ft)
    if #dests > 0 then
        local allBlocked = true
        for _, d in ipairs(dests) do if not d.blocked then allBlocked = false; break end end
        if allBlocked then return L.BLOCKED end
    end
    return L.IDLE
end

-- ---- input link status (shared by every building category) ------------------
-- Public uid accessor: the UI holds placeables, the link API is keyed by uid.
function SmartDistribution.assetUid(p)
    return getUid(p)
end

-- The UI needs to say, for each input a building takes, whether distribution is currently feeding it,
-- and the same for each individual source that could feed it. Three states, deliberately open for the
-- planned player-blocking feature:
--   ACTIVE  - the link is live AND product moved on the most recent pass
--   IDLE    - the link is live but nothing moved (no demand, source empty, consumer full)
--   BLOCKED - the player has blocked it (SmartDistribution.control.blocked; nothing sets this yet)
-- Category-agnostic on purpose: silos, storages, productions, animal pens and markets all resolve the
-- same way, and each category page just gates on whether it supports inputs at all.
SmartDistribution.LINK = { ACTIVE = "ACTIVE", IDLE = "IDLE", BLOCKED = "BLOCKED" }
SmartDistribution.LINK_LABEL = {
    ACTIVE  = "Active (Receiving)",   -- product actually moved last pass
    IDLE    = "Active (Idle)",        -- link live, nothing needed to move
    BLOCKED = "Blocked",              -- player-blocked (future feature)
}
-- status colours (shared, so every category page reads identically): green = feeding, orange = live but
-- nothing moving, red = blocked by the player.
SmartDistribution.LINK_COLOR = {
    ACTIVE  = { 0.45, 0.78, 0.13, 1 },   -- green
    IDLE    = { 1.00, 0.55, 0.05, 1 },   -- orange
    BLOCKED = { 0.86, 0.20, 0.18, 1 },   -- red
}

-- feed log from the most recent pass: _feed[consumerUid][ft][sourceUid] = litres moved.
-- Rebuilt each pass (see beginFeedPass) so "Active" always means "on the last pass", not "ever".
SmartDistribution._feed     = SmartDistribution._feed or {}
SmartDistribution._feedPrev = SmartDistribution._feedPrev or {}

-- called at the start of each pass: the pass being built becomes current, the previous one is what the
-- UI reads (a pass in progress is incomplete, so reading it would flicker rows between Active and Idle).
function SmartDistribution.beginFeedPass()
    SmartDistribution._feedPrev = SmartDistribution._feed or {}
    SmartDistribution._feed = {}
end

function SmartDistribution.recordFeed(consumer, ft, source, litres)
    if consumer == nil or ft == nil or source == nil or (litres or 0) <= 0 then return end
    local cu, su = getUid(consumer), getUid(source)
    if cu == nil or su == nil then return end
    local f = SmartDistribution._feed
    f[cu] = f[cu] or {}
    f[cu][ft] = f[cu][ft] or {}
    f[cu][ft][su] = (f[cu][ft][su] or 0) + litres
end

-- litres a given source moved into a consumer for ft on the last completed pass (0 if none)
function SmartDistribution.fedBy(consumerUid, ft, sourceUid)
    local f = SmartDistribution._feedPrev
    local c = f ~= nil and f[consumerUid] or nil
    local t = c ~= nil and c[ft] or nil
    return (t ~= nil and t[sourceUid]) or 0
end

-- total litres a consumer received for ft on the last completed pass
function SmartDistribution.fedTotal(consumerUid, ft)
    local f = SmartDistribution._feedPrev
    local c = f ~= nil and f[consumerUid] or nil
    local t = c ~= nil and c[ft] or nil
    local sum = 0
    if t ~= nil then for _, v in pairs(t) do sum = sum + v end end
    return sum
end

-- status of ONE source's link into a consumer for ft
function SmartDistribution.sourceLinkStatus(consumerUid, ft, sourceUid)
    local L = SmartDistribution.LINK
    if SmartDistribution.isSourceBlocked(consumerUid, ft, sourceUid) then return L.BLOCKED end
    if SmartDistribution.fedBy(consumerUid, ft, sourceUid) > 0 then return L.ACTIVE end
    return L.IDLE
end

-- overall status of an INPUT row on a building page: Active if anything fed it last pass; Blocked only
-- when it has possible sources and every one of them is blocked; otherwise Idle.
function SmartDistribution.inputLinkStatus(consumerUid, ft)
    local L = SmartDistribution.LINK
    if consumerUid == nil or ft == nil then return L.IDLE end
    if SmartDistribution.fedTotal(consumerUid, ft) > 0 then return L.ACTIVE end
    local srcs = SmartDistribution.sourcesFor(consumerUid, ft)
    if #srcs > 0 then
        local allBlocked = true
        for _, s in ipairs(srcs) do
            if not s.blocked then allBlocked = false; break end
        end
        if allBlocked then return L.BLOCKED end
    end
    return L.IDLE
end

-- The sources that could fulfil an input, each with its link status. This is what the (future) input
-- drill-down shows; sourcesFor() already handles farm scoping + the blocked flag.
function SmartDistribution.inputSources(consumerUid, ft)
    local out = SmartDistribution.sourcesFor(consumerUid, ft)
    for _, s in ipairs(out) do
        s.status = SmartDistribution.sourceLinkStatus(consumerUid, ft, s.uid)
        s.label  = SmartDistribution.LINK_LABEL[s.status]
        s.fed    = SmartDistribution.fedBy(consumerUid, ft, s.uid)
    end
    return out
end

-- Can placeable p accept ft as a sink (production input / storage sink / pallet shed)?
-- Returns supports(bool), active(bool) -- active means a running production consumes ft.
function SmartDistribution.canAccept(p, ft)
    local pp = getProductionPoint(p)
    if pp ~= nil then
        local supports = type(pp.inputFillTypeIds) == "table" and pp.inputFillTypeIds[ft] == true
        if supports then
            return true, (getActiveHourlyConsumption(pp, ft) > 0)
        end
    end
    -- Husbandry buildings are sinks for their animal inputs (food / straw / water). Without this branch the
    -- endpoint gate (sinksFor -> hasDistributeEndpoint) never sees a barn, so a source holding straw/food
    -- for animals is offered NO Distribute mode -- and enforceValidModes then reverts that source to Hold
    -- every hour, so it never feeds the barn at runtime either. This is why a hay loft could not be set to
    -- distribute straw to the modded chicken coop. Mirrors receiverInputFillTypes' husbandry branch.
    if isHusbandryBuilding(p) and SmartDistribution.husbandryInputFillTypes ~= nil
       and SmartDistribution.husbandryInputFillTypes(p)[ft] then
        return true, true
    end
    if (p.spec_silo ~= nil or isManurePit(p)) then
        for _, s in ipairs(getAllStorages(p)) do if storageSupports(s, ft) then return true, true end end
    end
    if p.spec_objectStorage ~= nil and isPalletShedSink(p, ft) then return true, true end
    return false, false
end

-- All network sinks that can accept ft from the source (uid), with the source's current
-- priority rank for each (0 = unranked). Ordered ranked-first (by rank), then by name.
function SmartDistribution.sinksFor(sourceUid, ft)
    local out = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return out end
    local pr = SmartDistribution.control.priority
    local pf = pr ~= nil and pr[sourceUid] or nil
    local list = pf ~= nil and pf[ft] or nil
    local rank = {}
    if list ~= nil then for i = 1, #list do rank[list[i]] = i end end
    local myFarm = SmartDistribution._playerFarmId()
    for _, p in ipairs(ps.placeables) do
        if p.rootNode ~= nil and isEnrolled(p) then
            local of = SmartDistribution._ownerFarmId(p)
            local u = getUid(p)
            if u ~= sourceUid and (myFarm == nil or of == nil or of == myFarm) then
                local supports, active = SmartDistribution.canAccept(p, ft)
                if supports then
                    out[#out + 1] = {
                        uid = u, name = placeableName(p), icon = SmartDistribution.assetIconFile(p),
                        active = active, rank = rank[u] or 0,
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        local ar = a.rank == 0 and math.huge or a.rank
        local br = b.rank == 0 and math.huge or b.rank
        if ar ~= br then return ar < br end
        return tostring(a.name) < tostring(b.name)
    end)
    return out
end

-- ---- dev console commands: direct registration -----------------------------
-- The earlier registration block was not taking effect (sdManureProbe reported "command not found"),
-- so register here at file scope, after every cmd* function above is defined. Guarded so it is a no-op
-- if the console is unavailable or the command was already registered.
if addConsoleCommand ~= nil then
    pcall(addConsoleCommand, "sdManureProbe",
        "Dump manure heaps/extensions + barn manure/slurry storage [dev]",
        "cmdManureProbe", SmartDistribution)
    -- installConsole() is disabled for release (see its call site), so the probes it registered never
    -- take effect. Re-register the ones needed for the Hold-Internal pallet investigation the proven way,
    -- directly at file scope after their cmd* functions are defined.
    pcall(addConsoleCommand, "sdPalletProbe",
        "Dump husbandry pallet assets (coops/sheep) + spawn methods [dev]",
        "cmdPalletProbe", SmartDistribution)
    pcall(addConsoleCommand, "sdList",
        "List placeables: index | uniqueId | name | class | overrides",
        "cmdList", SmartDistribution)
    pcall(addConsoleCommand, "sdSpawnHusb",
        "Spawn pallets from a coop/sheep internal buffer: sdSpawnHusb <index> [count] [dev]",
        "cmdSpawnHusb", SmartDistribution)
    pcall(addConsoleCommand, "sdRobotProbe",
        "Dump feeding-robot husbandry (Lely Vector / GEA) ingredient bunkers [dev]",
        "cmdRobotProbe", SmartDistribution)
    pcall(addConsoleCommand, "sdRobotFill",
        "Test feeding-robot bunker fill: sdRobotFill <fillType> [liters] [dev]",
        "cmdRobotFill", SmartDistribution)
    pcall(addConsoleCommand, "sdTarget",
        "Set input fill target on the robot barn: sdTarget <fillType> <pct|off> [dev]",
        "cmdTarget", SmartDistribution)
    print("[SmartDistribution] sd* probes + sdSpawnHusb / sdRobotFill / sdTarget registered")
else
    print("[SmartDistribution] addConsoleCommand unavailable -- console commands disabled by the game")
end

-- ---- pooled input share: a blocked product gives its share back -------------
-- A pooled store splits its capacity evenly across the products sharing it, so 250,000 L across 2 products
-- defaults to 50% (125,000 L) each.  Once a product is BLOCKED it needs no reservation at all, and its
-- share should return to the rest instead of sitting idle: block one of three and the remaining two should
-- read 50% each, not 33%.  These wrappers apply that to the DEFAULT share and to the headroom test.  An
-- explicitly set percentage is the player's and is never overwritten -- only the default moves.
if type(SmartDistribution.defaultInputCapPct) == "function" then
    SmartDistribution._origDefaultInputCapPct = SmartDistribution.defaultInputCapPct
    SmartDistribution.defaultInputCapPct = function(p, ft)
        local pool = (SmartDistribution.pooledInputCapacity ~= nil)
            and SmartDistribution.pooledInputCapacity(p) or nil
        if pool ~= nil and type(pool.fts) == "table" and SmartDistribution.isInputBlocked ~= nil
           and SmartDistribution.assetUid ~= nil then
            -- isInputBlocked is keyed by RECEIVER UID (control.inputBlock[rcvUid][ft]), not the placeable
            local uid = SmartDistribution.assetUid(p)
            -- only products that actually SHARE the pool get the redistributed split; one with its own
            -- individual tank (straw / water beside a food pool) is unaffected by what the pool does.
            local inPool, active = false, 0
            for _, f in ipairs(pool.fts) do
                if f == ft then inPool = true end
                if uid ~= nil and not SmartDistribution.isInputBlocked(uid, f) then active = active + 1 end
            end
            if uid ~= nil and inPool and active > 0 then
                return math.floor(100 / active + 0.5)
            end
        end
        return SmartDistribution._origDefaultInputCapPct(p, ft)
    end
end

-- Headroom for raising a pooled product's share is 100 minus what the OTHER products hold.  A blocked
-- product holds nothing, so the share it used to reserve becomes available to the rest.
if type(SmartDistribution.inputCapPctHeadroom) == "function" then
    SmartDistribution._origInputCapPctHeadroom = SmartDistribution.inputCapPctHeadroom
    SmartDistribution.inputCapPctHeadroom = function(p, ft)
        local pool = (SmartDistribution.pooledInputCapacity ~= nil)
            and SmartDistribution.pooledInputCapacity(p) or nil
        if pool ~= nil and type(pool.fts) == "table" and SmartDistribution.isInputBlocked ~= nil
           and SmartDistribution.inputCapPct ~= nil and SmartDistribution.assetUid ~= nil then
            local uid = SmartDistribution.assetUid(p)
            local inPool = false
            for _, f in ipairs(pool.fts) do
                if f == ft then inPool = true; break end
            end
            if uid ~= nil and inPool then
                local used = 0
                for _, f in ipairs(pool.fts) do
                    if f ~= ft and not SmartDistribution.isInputBlocked(uid, f) then
                        used = used + (SmartDistribution.inputCapPct(p, f) or 0)
                    end
                end
                return math.max(0, 100 - used)
            end
        end
        return SmartDistribution._origInputCapPctHeadroom(p, ft)
    end
end

-- ---- blocking a pooled input hands its share back ---------------------------
-- Blocking or unblocking changes how the pool should divide, but a product carrying an EXPLICIT
-- percentage ignores the default and so never rescales -- it stays pinned at whatever it was last set to
-- while every other product redistributes around it.  Clearing the stored percentages across that pool on
-- each block change returns them all to the automatic share, which is the behaviour the split is meant to
-- have.  Wrapped on setInputBlocked rather than done in the dialog so it runs identically when the change
-- arrives as a DistributionControlEvent from another player.
-- Only a product that actually SHARES the pool triggers this: blocking an individual tank (straw / water
-- beside a food pool) leaves the pool's percentages alone.
if type(SmartDistribution.setInputBlocked) == "function" then
    SmartDistribution._origSetInputBlocked = SmartDistribution.setInputBlocked
    SmartDistribution.setInputBlocked = function(rcvUid, ft, flag, ...)
        local res = SmartDistribution._origSetInputBlocked(rcvUid, ft, flag, ...)
        if rcvUid ~= nil and ft ~= nil and SmartDistribution.clearInputCapPct ~= nil
           and SmartDistribution.pooledInputCapacity ~= nil and SmartDistribution.assetUid ~= nil then
            -- setInputBlocked is keyed by uid, pooledInputCapacity wants the placeable
            local owner = nil
            local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
            if ps ~= nil and ps.placeables ~= nil then
                for _, cand in ipairs(ps.placeables) do
                    if SmartDistribution.assetUid(cand) == rcvUid then owner = cand; break end
                end
            end
            if owner ~= nil then
                local pool = SmartDistribution.pooledInputCapacity(owner)
                if pool ~= nil and type(pool.fts) == "table" then
                    local shares = false
                    for _, f in ipairs(pool.fts) do
                        if f == ft then shares = true; break end
                    end
                    if shares then
                        for _, f in ipairs(pool.fts) do
                            pcall(SmartDistribution.clearInputCapPct, rcvUid, f)
                        end
                    end
                end
            end
        end
        return res
    end
end
