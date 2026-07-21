-- ============================================================================
-- DistributionLimits.lua  (Distribution Redux)
--
-- Raises a few base-game engine caps so large farms and the pallet/bale spawner
-- don't run into them. These are plain value assignments against the engine's
-- own managers. math.max is used throughout so we only ever RAISE a cap, never
-- lower one that a map or another mod has already set higher.
-- ============================================================================

-- More bale / pallet objects allowed on the map at once (the spawner can create
-- a lot at a time). We only lift the DESKTOP caps to unlimited; console and
-- mobile keep their platform-safe defaults so we don't blow their memory budget.
if SlotSystem ~= nil and SlotSystem.NUM_OBJECT_LIMITS ~= nil and PlatformId ~= nil then
    local function liftDesktop(objType)
        local row = SlotSystem.NUM_OBJECT_LIMITS[objType]
        if row == nil then return end
        if PlatformId.WIN ~= nil then row[PlatformId.WIN] = math.huge end
        if PlatformId.MAC ~= nil then row[PlatformId.MAC] = math.huge end
    end
    if SlotSystem.LIMITED_OBJECT_BALE   ~= nil then liftDesktop(SlotSystem.LIMITED_OBJECT_BALE)   end
    if SlotSystem.LIMITED_OBJECT_PALLET ~= nil then liftDesktop(SlotSystem.LIMITED_OBJECT_PALLET) end
end

-- Allow more production points per savegame (big farms with many chains).
if ProductionChainManager ~= nil and ProductionChainManager.NUM_MAX_PRODUCTION_POINTS ~= nil then
    ProductionChainManager.NUM_MAX_PRODUCTION_POINTS =
        math.max(ProductionChainManager.NUM_MAX_PRODUCTION_POINTS, 512)
end

-- Give the fill-type network id more headroom (large modpacks with many fill types).
-- This is a global MP setting, so every player must run the same mod set (as usual).
if FillTypeManager ~= nil and FillTypeManager.SEND_NUM_BITS ~= nil then
    FillTypeManager.SEND_NUM_BITS = math.max(FillTypeManager.SEND_NUM_BITS, 10)
end

if Logging ~= nil and Logging.info ~= nil then
    Logging.info("[Distribution Redux] engine limits raised: production points >= %s, fill-type bits >= %s, desktop pallet/bale slots unlimited",
        tostring(ProductionChainManager ~= nil and ProductionChainManager.NUM_MAX_PRODUCTION_POINTS or "?"),
        tostring(FillTypeManager ~= nil and FillTypeManager.SEND_NUM_BITS or "?"))
end
