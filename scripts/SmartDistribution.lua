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
local MODE = { INHERIT = 0, HOLD = 1, DISTRIBUTE = 2, DISTRIBUTE_SELL = 3, SELL = 4, DISTRIBUTE_STORE = 5, STORE = 6 }
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
SmartDistribution.debug  = false
SmartDistribution.dryRun = false
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
            if S.master and storage ~= nil and storage.isExtension == true then
                if not isStorageSiloStation(self) then return end   -- refuse: only storage silos may be extended
                recordExtensionParent(self, storage)                -- pool the extension into that silo
            end
            return orig(self, storage, ...)
        end
    end
    if LoadingStation ~= nil and LoadingStation.addSourceStorage ~= nil then
        local orig = LoadingStation.addSourceStorage
        LoadingStation.addSourceStorage = function(self, storage, ...)
            if S.master and storage ~= nil and storage.isExtension == true then
                if not isStorageSiloStation(self) then return end
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
local function husbandryOutputFillTypes(p)
    local out = {}
    if p.spec_husbandryMilk ~= nil and p.spec_husbandryMilk.fillTypes ~= nil then
        for _, ft in ipairs(p.spec_husbandryMilk.fillTypes) do out[ft] = true end
    end
    if p.spec_husbandryLiquidManure ~= nil and p.spec_husbandryLiquidManure.fillType ~= nil then
        out[p.spec_husbandryLiquidManure.fillType] = true
    end
    for ft in pairs(outputNamedSet()) do out[ft] = true end
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

-- ---- asset classification / identity / settings resolution -----------------
local function getAssetClass(p)
    if getProductionPoint(p) ~= nil then return "PRODUCTION" end
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
    -- slurry pits (HEAP) ride with Animal Husbandry; silos + pallet sheds are the other switch.
    local cls = getAssetClass(p)
    if (cls == "HUSBANDRY" or cls == "HEAP") and not S.global.includeHusbandry then return false end
    if (cls == "SILO" or cls == "SHED") and not S.global.includeSilosSheds then return false end
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
    if not noEventSend and DistributionModeEvent ~= nil and DistributionModeEvent.sendEvent ~= nil then
        DistributionModeEvent.sendEvent(placeable, ft, mode)
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
    if not isEnrolled(p) then return false end
    if S.global.excludedFillTypes[ft] then return false end
    local m = resolveMode(p, ft)
    return m == MODE.DISTRIBUTE or m == MODE.DISTRIBUTE_SELL or m == MODE.DISTRIBUTE_STORE
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
local FAST_FORWARD_GAP_SEC = 4.0    -- hourly ticks closer than this (real seconds) == sleep

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

-- Emit one combined notification for the cycle just completed, then clear the tally.
-- Called at the START of the next cycle so a removable add-on's late biogas-surplus
-- sale (ProductionDistributeSell, which runs after this pass) is already counted.
function SmartDistribution.flushCycleSummary()
    local cm = cycleMoney
    cycleMoney = nil
    if cm == nil or not cm.any then return end
    if cm.ff then return end                       -- stay silent through sleep/fast-forward (no wake-time lump)
    -- one notification PER category (only the non-zero ones), each this hour's combined total
    if cm.biogas ~= 0 then SmartDistribution.notify("Biogas income: "     .. fmtMoney(cm.biogas)) end
    if cm.sales  ~= 0 then SmartDistribution.notify("Product sales: "     .. fmtMoney(cm.sales))  end
    if cm.cost   ~= 0 then SmartDistribution.notify("Maintenance costs: " .. fmtMoney(cm.cost))   end
    if DistributionMoneyNotifyEvent ~= nil and DistributionMoneyNotifyEvent.broadcast ~= nil then
        DistributionMoneyNotifyEvent.broadcast(cm.biogas, cm.sales, cm.cost)   -- MP: mirror the summary to clients
    end
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
        ledgerAdd(slot.placeable, c.ft, "received", accepted)     -- received-in, recipient side (production inputs, troughs, ...)
        log("move %.0f %s : %s -> %s", accepted, fillTypeName(c.ft), placeableName(c.placeable), placeableName(slot.placeable))
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
                local need = getPullAmount(pp, ft)
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
                                local mv = math.min(amount, free)
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
        if fs ~= nil and p.rootNode ~= nil and p.addFood ~= nil and isEnrolled(p) then
            local rate = fs.litersPerHour or 0
            if rate > 0 then
                local current = 0
                for _, lvl in pairs(fs.fillLevels) do current = current + lvl end
                local capacity = fs.capacity or 0
                local need = math.min(rate * S.global.bufferHours - current, capacity - current)
                if need > ALLOC_EPS then
                    local farmId = p.getOwnerFarmId ~= nil and p:getOwnerFarmId() or p.ownerFarmId
                    local x, _, z = getWorldTranslation(p.rootNode)
                    local fts = {}
                    for ft in pairs(fs.supportedFillTypes) do
                        if not S.global.excludedFillTypes[ft] and ft ~= waterFillType() then fts[#fts + 1] = ft end
                    end
                    local cands = buildSlotCandidates(nil, p, fts, x, z, farmId, foodQualityMap(p))
                    if #cands > 0 then
                        slots[#slots + 1] = {
                            placeable = p, farmId = farmId, need = need, cands = cands, blocked = {},
                            deposit = function(dft, amount, dry)
                                local tot = 0
                                for _, l in pairs(fs.fillLevels) do tot = tot + l end
                                local room = (fs.capacity or 0) - tot
                                local mv = math.min(amount, room)
                                if mv <= 0 then return 0 end
                                if dry then return mv end
                                return p:addFood(farmId, mv, dft, nil, nil, nil) or 0
                            end,
                        }
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
           p.getHusbandryIsFillTypeSupported ~= nil and p:getHusbandryIsFillTypeSupported(STRAW) and isEnrolled(p) then
            local rate = ss.inputLitersPerHour or 0
            if rate > 0 then
                local current = p:getHusbandryFillLevel(STRAW) or 0
                local free    = p:getHusbandryFreeCapacity(STRAW) or 0
                local need    = math.min(rate * S.global.bufferHours - current, free)
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
           p:getHusbandryIsFillTypeSupported(WATER) and isEnrolled(p) then
            local rate = ws.litersPerHour or 0
            if rate > 0 then
                local current = p:getHusbandryFillLevel(WATER) or 0
                local free    = p:getHusbandryFreeCapacity(WATER) or 0
                local need    = math.min(rate * S.global.bufferHours - current, free)
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

local function storeAmount(p, storage, ft, farmId, bill)
    if S.global.excludedFillTypes[ft] then return end
    local rm = resolveMode(p, ft)
    if rm ~= MODE.DISTRIBUTE_STORE and rm ~= MODE.STORE then return end
    if p.rootNode == nil then return end
    local level = getLevel(storage, ft)
    if level <= 0 then return end
    local x, _, z = getWorldTranslation(p.rootNode)
    local sinks = gatherSinks(p, ft, x, z, farmId, resolveReach(p))
    local remaining = level
    for _, sink in ipairs(sinks) do
        if remaining <= 0 then break end
        local moved = transfer(farmId, storage, sink.storage, ft, remaining)
        if moved > 0 then
            ledgerAdd(p, ft, "stored", moved)
            recordBill(bill, farmId, p, sink.placeable, sink.d2)
            log("stored %d %s : %s -> %s", moved, fillTypeName(ft), placeableName(p), placeableName(sink.placeable))
            remaining = remaining - moved
        end
    end
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
    local fallback = S.global.seasonalFallbackMonths or 13
    local budget = {}
    for ft in pairs(want) do
        local held = 0
        for _, p in ipairs(ps.placeables) do held = held + (SmartDistribution.assetHeld(p, ft) or 0) end
        local months  = SmartDistribution.monthsToCover(S.harvestMonths and S.harvestMonths[ft]) or fallback
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
local function depositPalletsToShed(coop, ft, shed)
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
    local moved = 0
    for _, e in ipairs(toMove) do
        local cap = oss.capacity or 0
        local stored = (oss.storedObjects ~= nil and #oss.storedObjects) or (oss.numStoredObjects or 0)
        if cap > 0 and stored >= cap then break end
        local can = true
        if shed.getObjectStorageCanStoreObject ~= nil then can = shed:getObjectStorageCanStoreObject(e.pallet) end
        if can then
            shed:addObjectToObjectStorage(e.pallet)   -- despawns the pallet + stores it abstractly
            if spec ~= nil and type(spec.pallets) == "table" then spec.pallets[e.pallet] = nil end  -- defensive (trigger also clears on delete)
            moved = moved + e.lvl
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
        if sink.shed ~= nil then
            -- Pallet Storage Shed: move whole FULL pallets (object storage), not liters
            if SmartDistribution.dryRun then
                local would = math.min(remaining, fullPalletLiters(p, ft))
                if would > 0 then
                    log("[dry-run] would store %d %s (full pallets) : %s -> %s [shed]", would, fillTypeName(ft), placeableName(p), placeableName(sink.placeable))
                    recordBill(bill, farmId, p, sink.placeable, sink.d2)
                    remaining = remaining - would
                end
            else
                local moved = depositPalletsToShed(p, ft, sink.shed)
                if moved > 0 then
                    ledgerAdd(p, ft, "stored", moved)
                    recordBill(bill, farmId, p, sink.placeable, sink.d2)
                    log("stored %d %s (pallets) : %s -> %s [shed]", moved, fillTypeName(ft), placeableName(p), placeableName(sink.placeable))
                    remaining = remaining - moved
                end
            end
        else
            local want = math.min(remaining, getFree(sink.storage, ft))
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
                        storePalletAmount(p, ft, farmId, bill)   -- DISTRIBUTE_STORE: store the post-distribute remainder; STORE: store all
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

function SmartDistribution.runHourly(manager)
    if not S.master then return end
    resetCycleMoney()                                         -- open this hour's money tally (flushed at the END of this tick, after the appended surplus-sell pass)
    detectHarvests()                                          -- learn crop harvest months (pre-phase levels)
    cycleAcc = {}                                              -- begin per-cycle accounting
    local bill = {}
    local slots = {}
    for _, farmTable in pairs(manager.farmIds or {}) do        -- phases 1 + 1b + 1c: unified allocation
        collectProductionSlots(farmTable.productionPoints, slots)
    end
    collectFoodSlots(slots)
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
    sellDirectProduction(manager)                              -- phase 2b: plant sellDirectly outputs (biogas electric/methane)
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
    if not SmartDistribution.PRODUCTION_DISTSELL_ENABLED then
        SmartDistribution.flushCycleSummary()
    end
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
        SmartDistribution._fastForward = (nowSec - lastSec) < FAST_FORWARD_GAP_SEC
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
    if mi ~= nil and mi.isValid == false then return end
    local dir = (mi ~= nil and mi.savegameDirectory ~= nil and mi.savegameDirectory ~= "")
        and (mi.savegameDirectory .. "/") or getSaveDir()
    if dir == nil then log("save skipped: savegame directory unresolved") return end
    local path = dir .. "smartDistribution.xml"
    local xml = createXMLFile("SmartDistributionXML", path, "smartDistribution")
    if xml == nil or xml == 0 then log("save failed: createXMLFile(%s)", path) return end
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
                        ei = ei + 1
                    end
                end
            end
            ci = ci + 1
        end
    end
    saveXMLFile(xml)
    delete(xml)
    log("saved %d per-asset override(s) + %d timing(s) + %d crop window(s) + %d monthly cycle(s) -> %s", i, t, j, ci, path)
end

local function loadOverrides()
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local dir = getSaveDir()
    if dir == nil then return end
    local path = dir .. "smartDistribution.xml"
    if not fileExists(path) then log("no persisted overrides at %s (fresh save)", path) return end
    local xml = loadXMLFile("SmartDistributionXML", path)
    if xml == nil or xml == 0 then return end
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
                    }
                end
            end
            ei = ei + 1
        end
        if next(snap) ~= nil then monthlyRing[slot] = snap; mloaded = mloaded + 1 end
        ci = ci + 1
    end
    delete(xml)
    log("loaded %d per-asset override(s) + %d timing(s) + %d crop window(s) + %d monthly cycle(s) from %s", n, tn, c, mloaded, path)
end

local function installPersistence()
    if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
        Mission00.loadMission00Finished = Utils.appendedFunction(
            Mission00.loadMission00Finished, function(...) pcall(loadOverrides) end)
    end
    -- FS25's savegame writer is FSCareerMissionInfo:saveToXMLFile(missionInfo) -- the same hook
    -- EasyDevControls uses to persist into the savegame folder.  (The old FSCareerMission.saveSavegame
    -- hook never fired: that class doesn't exist under that name in FS25, so nothing ever saved.)
    if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
        FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
            FSCareerMissionInfo.saveToXMLFile, function(self, ...) pcall(saveOverrides, self) end)
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
            for _, ft in ipairs(fts) do
                local buf = (spec ~= nil and spec.fillLevels ~= nil and spec.fillLevels[ft])
                    or (p.spec_beehivePalletSpawner ~= nil and p.spec_beehivePalletSpawner.pendingLiters) or 0
                dump(string.format("   ft %s: mode=%s  buffer=%s  palletLiters=%s  fullLiters=%s",
                    tostring(fillTypeName(ft)), tostring(resolveMode(p, ft)), tostring(buf),
                    tostring(palletFillLevel(p, ft)), tostring(fullPalletLiters(p, ft))))
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
local MODE_NAMES = { [0]="Inherit", [1]="Hold", [2]="Distribute", [3]="Distribute + Sell", [4]="Sell", [5]="Distribute + Store", [6]="Store" }
function SmartDistribution.modeName(m) return MODE_NAMES[m] or ("mode" .. tostring(m)) end

-- store-capable = a valid storePhase SOURCE (production output or husbandry output)
local function assetCanStore(asset)
    local c = getAssetClass(asset)
    return c == "PRODUCTION" or c == "HUSBANDRY"
end

-- Mode cycle ring. Distribute+Store is only offered for store-capable assets; a
-- plain silo can't store-cascade to another silo, so it keeps the 4-mode ring and
-- never lands on Distribute+Store.
local function cycleNext(m, includeStore)
    if m == MODE.DISTRIBUTE       then return MODE.HOLD end
    if m == MODE.HOLD             then return MODE.DISTRIBUTE_SELL end
    if m == MODE.DISTRIBUTE_SELL  then return MODE.SELL end
    if m == MODE.SELL             then return includeStore and MODE.DISTRIBUTE_STORE or MODE.DISTRIBUTE end
    if m == MODE.DISTRIBUTE_STORE then return includeStore and MODE.STORE or MODE.DISTRIBUTE end
    if m == MODE.STORE            then return MODE.DISTRIBUTE end
    return MODE.HOLD
end

function SmartDistribution.notify(text)
    log("%s", text)                         -- always log, so the chain is visible
    local m = g_currentMission
    if m == nil then return end
    if m.hud ~= nil and m.hud.addSideNotification ~= nil then   -- [VERIFY] FS25 signature
        local colour = (FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_OK) or nil
        if pcall(function() m.hud:addSideNotification(colour, text, 2500) end) then return end
    end
    if m.showBlinkingWarning ~= nil then     -- [VERIFY] fallback
        pcall(function() m:showBlinkingWarning(text, 2500) end)
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

-- exposed for the per-asset dialog (DistributionSiloDialog.lua)
SmartDistribution.cycleNext      = cycleNext
function SmartDistribution.cycleNextForAsset(asset, m)   -- store-aware: only store-capable assets reach Distribute+Store
    return cycleNext(m, assetCanStore(asset))
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
        local ok, v = pcall(palletFillLevel, p, ft); if ok and type(v) == "number" then total = total + v end
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
    if p == nil or ft == nil then return 0, 0, 0 end
    local uid = getUid(p)
    if clientMonthly ~= nil then                                  -- client: read the synced aggregate
        local au = clientMonthly[uid]; local e = au ~= nil and au[ft] or nil
        if e == nil then return 0, 0, 0 end
        return e.dist or 0, e.sold or 0, e.stored or 0
    end
    local d, s, st = 0, 0, 0
    for i = 1, MONTHLY_CYCLES do
        local snap = monthlyRing[i]
        local a = snap ~= nil and snap[uid] or nil
        local e = a ~= nil and a[ft] or nil
        if e ~= nil then d = d + (e.dist or 0); s = s + (e.sold or 0); st = st + (e.stored or 0) end
    end
    return d, s, st
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
    return r
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
                    if ae == nil then ae = { d = 0, s = 0, st = 0, r = 0 }; au[ft] = ae end
                    ae.d  = ae.d  + (e.dist or 0);   ae.s = ae.s + (e.sold or 0)
                    ae.st = ae.st + (e.stored or 0); ae.r = ae.r + (e.received or 0)
                end
            end
        end
    end
    local list = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps ~= nil then
        for _, p in ipairs(ps.placeables) do
            local uid = getUid(p)
            local au = uid ~= nil and agg[uid] or nil
            if au ~= nil then
                for ft, ae in pairs(au) do
                    if (ae.d + ae.s + ae.st + ae.r) > 0 then
                        list[#list + 1] = { p = p, ft = ft, d = ae.d, s = ae.s, st = ae.st, r = ae.r }
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
        self.entries[i] = { p = p, ft = ft, d = d, s = s, st = st, r = r }
    end
    self:run(connection)
end
function DistributionStatsEvent:run(connection)
    -- stats flow server -> client only; never relayed onward.
    if self.clearFirst or clientMonthly == nil then clientMonthly = {} end
    for _, en in ipairs(self.entries) do
        local p = en.p
        if p ~= nil then
            local uid = getUid(p)
            if uid ~= nil then
                local au = clientMonthly[uid]; if au == nil then au = {}; clientMonthly[uid] = au end
                au[en.ft] = { dist = en.d, sold = en.s, stored = en.st, received = en.r }
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
-- flushCycleSummary emits the "Biogas income / Product sales / Maintenance costs" side-notifications
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
    if self.cost   ~= 0 then SmartDistribution.notify("Maintenance costs: " .. fmtMoney(self.cost))   end
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

-- total monthly INPUT demand for a fill type across all ACTIVE production lines
-- (cyclesPerMonth x input amount, summed). Husbandry feed demand is a later add.
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
    local modes = {}
    for i, ft in ipairs(order) do modes[i] = SmartDistribution.resolvedAssetMode(asset, ft) end
    local target = bulkCycleTarget(modes, modes[1], function(m) return cycleNext(m, store) end)
    local names = {}
    for _, ft in ipairs(order) do
        SmartDistribution.applyAssetMode(asset, ft, target)   -- syncs MP + persists on save
        names[#names + 1] = fillTypeName(ft)
    end
    log("%s", string.format("%s -> %s  [%s]",
        placeableName(asset), SmartDistribution.modeName(target), table.concat(names, ", ")))
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
function SmartDistribution.enumerateConfigurableAssets()
    local out = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return out end
    local farmId = (g_currentMission.getFarmId ~= nil) and g_currentMission:getFarmId() or nil
    for _, p in ipairs(ps.placeables) do
        if p.rootNode ~= nil then
            local cls = getAssetClass(p)
            if cls == "SILO" or cls == "HUSBANDRY" or cls == "PRODUCTION" or cls == "SHED" or cls == "HEAP" then
                local owned = (p.getOwnerFarmId == nil) or (farmId == nil) or (p:getOwnerFarmId() == farmId)
                if owned then
                    out[#out + 1] = { placeable = p, name = placeableName(p), class = cls }
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
        loadPage(DistributionProductionsPage, "distributionProductionsPage", "gui/DistributionProductionsPage.xml")
        loadPage(DistributionHelpPage,        "distributionHelpPage",        "gui/DistributionHelpPage.xml")
        SmartDistribution._menu = DistributionMenu.new()
        g_gui:loadGui(dir .. "gui/DistributionMenu.xml", "DistributionMenu", SmartDistribution._menu)
    end)
    if ok then
        SmartDistribution._menuRegistered = true
        log("consolidated menu registered")
    else
        log("registerMenuGui error: %s", tostring(err))
    end
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

install()
installPersistence()
-- installConsole() -- dev console commands disabled for release (registration removed)
installInteraction()
installHusbandryPatch()
installManureExtensionPlaceable()
installExtensionPlacementGates()
installManureHeapDetach()
installProximityWatcher()
installMenu()
