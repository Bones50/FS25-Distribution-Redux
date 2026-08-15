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

-- ---- pallet TYPE registry (for the manual Spawn Pallets dialog) -------------
-- A fill type can have its pallet declared MORE THAN ONCE: once by the base game, and again by any mod
-- shipping its own <fillType><pallet filename="..."/>. The engine keeps only the winner --
-- `fillType.palletFilename` is overwritten by whichever declaration loads last -- so by the time anything
-- can ask, the alternatives are gone. PROVEN IN GAME 2026-08-15: with Liftable Pallets & Bales installed,
-- TOMATO's palletFilename pointed at that mod's pallet and there was no record of the vanilla one
-- anywhere, which is why the type dropdown only ever had one entry.
--
-- So capture the declarations AS THEY LOAD, keyed by the mod that made each one. Same approach
-- FS25_ProductionStorageControl takes, and the only one available: the information does not survive
-- anywhere else.
--
-- MUST BE INSTALLED HERE. This file is the FIRST of DR's extraSourceFiles, so it runs at mod load,
-- before the map's fillTypes.xml (and every mod's) is parsed. Installed any later and the hook simply
-- never sees the declarations it exists to record.
--
-- Writes to `sdPallets`, NOT to `pallets`: that name is Production Storage Control's, and two mods
-- writing one field is a collision waiting to happen even when they agree today.
-- The path is resolved against the DECLARING mod's baseDirectory (the third getValue argument), so what
-- is stored is absolute and loadable -- a relative path would fail to open later, silently.
if FillTypeDesc ~= nil and FillTypeDesc.loadFromXMLFile ~= nil
   and Utils ~= nil and Utils.overwrittenFunction ~= nil then
    FillTypeDesc.loadFromXMLFile = Utils.overwrittenFunction(FillTypeDesc.loadFromXMLFile,
        function(self, superFunc, xmlFile, xmlKey, baseDirectory, customEnvironment)
            local ok, path = pcall(function()
                return xmlFile:getValue(xmlKey .. ".pallet#filename", nil, baseDirectory)
            end)
            if ok and type(path) == "string" and path ~= "" then
                self.sdPallets = self.sdPallets or {}
                self.sdPallets[customEnvironment or "VANILLA"] = path
            end
            return superFunc(self, xmlFile, xmlKey, baseDirectory, customEnvironment)
        end)
elseif print ~= nil then
    -- not gated on debug: if this is ever missing the dropdown silently loses every alternative, and a
    -- feature that quietly does nothing is worse than a line in the log
    print("[Distribution Redux] FillTypeDesc.loadFromXMLFile not found; alternative pallet types will be unavailable [VERIFY]")
end

if Logging ~= nil and Logging.info ~= nil then
    Logging.info("[Distribution Redux] engine limits raised: production points >= %s, fill-type bits >= %s, desktop pallet/bale slots unlimited",
        tostring(ProductionChainManager ~= nil and ProductionChainManager.NUM_MAX_PRODUCTION_POINTS or "?"),
        tostring(FillTypeManager ~= nil and FillTypeManager.SEND_NUM_BITS or "?"))
end
