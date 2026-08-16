-- ============================================================================
-- DistributionSettings.lua  (Distribution Redux)
-- Global settings DATA + persistence. The settings SCREEN is
-- gui/DistributionSettingsPage.xml + scripts/gui/DistributionSettingsPage.lua;
-- this file owns the definitions and saves the global preset + dials PER PROFILE,
-- separate from the per-asset, per-savegame override file owned by
-- SmartDistribution.lua.
--
-- (The header here used to describe injecting rows into the game's own options
-- page, the PDNESettings.injectMenu pattern. No such injection function has
-- existed for a long time -- DR has its own Settings tab.)
-- ============================================================================

DistributionSettings = {}
DistributionControls = {}   -- separate callback target (reference-mod pattern)

-- ---- setting definitions ---------------------------------------------------
-- Each: order (display position); default (INDEX into values); values (applied to
-- the engine); strings (the selector's value labels).
--
-- WHERE THE PLAYER-FACING TEXT LIVES, since it is deliberately not all here:
--   * row TITLE + TOOLTIP  -> gui/DistributionSettingsPage.xml, as
--                             $l10n_dr_set_<id> and $l10n_dr_set_<id>_tt.
--     A setting needs a hand-authored row in that file or it silently does not
--     appear at all (CLAUDE.md 5.41) -- adding one is still a two-file job.
--   * value LABELS         -> translations/translation_<lang>.xml, as
--                             dr_set_<id>_v1, _v2, ... resolved by convention in
--                             DistributionSettingsPage:onGuiSetupFinished.
--     `strings` below is the ENGLISH FALLBACK for those, and stays in step with
--     `values` -- the two are index-parallel and that is what the save file and
--     the multiplayer settings event carry.
--
-- There used to be `label` and `tooltip` fields here too. They were read by
-- NOTHING (dead since the options-page injection was dropped), and had already
-- drifted from the live XML wording on advancedRouting and palletSpawnMode -- two
-- copies of every tooltip, one of them wrong and invisible. Removed with the l10n
-- pass rather than translated twice.
DistributionSettings.SETTINGS = {
    scope = {
        order   = 1,
        default = 1,                                            -- Range (farm-wide)
        values  = { "RANGE", "PROXIMITY" },
        strings = { "Range (farm-wide)", "Proximity (radius)" },
    },
    includeHusbandry = {
        order   = 1.3,
        default = 1,                                            -- On
        values  = { true, false },
        strings = { "On", "Off" },
    },
    includeSilosSheds = {
        order   = 1.6,
        default = 1,                                            -- On
        values  = { true, false },
        strings = { "On", "Off" },
    },
    includeMarkets = {
        order   = 1.7,
        default = 1,                                            -- On
        values  = { true, false },
        strings = { "On", "Off" },
    },
    -- Public map silos (Zielonka's Grain Pool East and the like): buildings nobody owns that still let a
    -- farm store goods, via a per-farm storage inside them. OFF by default -- switching it on adds
    -- buildings to the network that cost money to store in (the vanilla railroad silo charges
    -- costsPerFillLevelAndDay), so it must be an explicit choice, never a surprise.
    includeMapStorage = {
        order   = 1.8,                                          -- with the other network toggles
        default = 2,                                            -- Off
        values  = { true, false },
        strings = { "On", "Off" },
    },
    advancedRouting = {
        order   = 1.9,                                          -- with the network toggles, above the range/buffer dials
        default = 1,                                            -- On
        values  = { true, false },
        strings = { "On", "Off" },
    },
    radius = {
        order   = 2,
        default = 2,                                            -- 50 m
        values  = { 25, 50, 75, 100, 150, 200, 400 },
        strings = { "25 m", "50 m", "75 m", "100 m", "150 m", "200 m", "400 m" },
    },
    bufferHours = {
        order   = 3,
        default = 2,                                            -- 2 h
        values  = { 1, 2, 4, 8, 12, 24 },
        strings = { "1 hour", "2 hours", "4 hours", "8 hours", "12 hours", "24 hours" },
    },
    sellEnabled = {
        order   = 4,
        default = 1,                                            -- Enabled
        values  = { true, false },
        strings = { "Enabled", "Disabled" },
    },
    waterSupplyEnabled = {
        order   = 4.5,                                          -- sits between Selling and the cost settings
        default = 1,                                            -- Enabled
        values  = { true, false },
        strings = { "Enabled", "Disabled" },
    },
    distCostEnabled = {
        order   = 5,
        default = 1,                                            -- Enabled
        values  = { true, false },
        strings = { "Enabled", "Disabled" },
    },
    distCostBase = {
        order   = 6,
        default = 3,                                            -- $10/h
        values  = { 0, 5, 10, 20, 50 },
        strings = { "$0 /h", "$5 /h", "$10 /h", "$20 /h", "$50 /h" },
    },
    distCostThreshold = {
        order   = 7,
        default = 2,                                            -- 50 m
        values  = { 25, 50, 100, 200, 500 },
        strings = { "25 m", "50 m", "100 m", "200 m", "500 m" },
    },
    seasonalReserveEnabled = {
        order   = 8,
        default = 2,                                            -- Disabled
        values  = { true, false },
        strings = { "Enabled", "Disabled" },
    },
    seasonalFallbackMonths = {
        order   = 9,
        default = 3,                                            -- 13 months
        values  = { 6, 12, 13, 18, 24 },
        strings = { "6 months", "12 months", "13 months", "18 months", "24 months" },
    },
    bestPriceEnabled = {
        order   = 9.3,                                          -- groups with the selling / seasonal controls
        default = 1,                                            -- Enabled
        values  = { true, false },
        strings = { "Enabled", "Disabled" },
    },
    bestPriceDefault = {
        order   = 9.6,
        default = 1,                                            -- Sell at best price
        values  = { true, false },
        strings = { "Sell at best price", "Sell immediately" },
    },
    -- ---- DEFAULTS STAMPED ON NEWLY PLACED BUILDINGS -------------------------------------------------
    -- BOTH of these apply ONLY to a building placed AFTER the world has finished loading, and ONLY at the
    -- moment it is placed. They are NOT resolver defaults: changing one NEVER touches a building that
    -- already exists, and loading an old savegame with a new version changes nothing. That is the whole
    -- requirement, and it is why neither of these is wired to S.global.mode -- see stampPlacementDefaults
    -- in SmartDistribution.lua, which is the only thing that reads them.
    --
    -- Hold is stored as plain MODE.HOLD, never HOLD_INTERNAL. One value covers every case because the
    -- LABEL adapts: "Hold Pallets" on a pallet output, "Hold Internal" once pallet spawning is Never,
    -- "Hold" otherwise (holdLabelFlag). Stamping HOLD_INTERNAL instead would pin a building to a mode
    -- cycleNext REMOVES from the ring in Never mode -- selectable, but impossible to return to.
    defaultOutputMode = {
        order   = 1.92,                                         -- beside advancedRouting, above the dials
        default = 1,                                            -- Distribute (today's behaviour)
        values  = { 0, 1 },                                     -- 0 = Distribute, 1 = Hold
        strings = { "Distribute", "Hold" },
    },
    -- Block all only BITES while Advanced routing is on: isInputBlocked returns false without it, and
    -- clearAdvancedControl wipes every input block when that switch goes off. Said plainly in the tooltip
    -- rather than worked around -- making blocks survive with Advanced off would leave a player unable to
    -- see or clear them, since the Advanced Inputs dialog is the only UI for it.
    defaultInputMode = {
        order   = 1.94,
        default = 1,                                            -- Accept all (today's behaviour)
        values  = { 0, 1 },                                     -- 0 = accept all, 1 = block all
        strings = { "Accept all", "Block all" },
    },
    -- Replaces the old fullPalletSpawn on/off (migrated on load, see loadSettings). One axis with three
    -- states rather than two switches: productions already behave the "whole pallet" way natively, so
    -- the middle state is really "make pens behave like productions", and Never turns both off.
    palletSpawnMode = {
        order   = 9.8,
        default = 2,                                            -- Whole pallets
        values  = { 0, 1, 2 },
        strings = { "Vanilla (fill gradually)", "Whole pallets only", "Never spawn pallets" },
    },
    -- How hard the OPEN menu works. Every DR tab re-reads live state on a timer -- the building tabs
    -- re-populate their number cells, and the Overview re-enumerates the entire network. That cost scales
    -- with the farm, and on a very large one (reported: ~103 productions, ~270 active products) it is worth
    -- being able to turn down or stop. "Manual only" still refreshes on every action the player takes
    -- (selecting a building, changing a selector, pressing Refresh) -- it only stops the background timer.
    -- Seconds between refreshes; -1 means manual only.
    menuRefresh = {
        -- LOCAL ONLY: deliberately excluded from the multiplayer settings sync (see ORDERED_IDS). Every
        -- other setting is world state the server is authoritative for; this one is a display pacing dial
        -- for the machine the menu is open on, and the whole point of it is that a player whose PC is
        -- struggling can turn their own menu down. Syncing it would let the server overwrite that choice.
        localOnly = true,
        order   = 9.9,
        default = 2,                                            -- Normal (2s)
        values  = { 0.5, 2, 10, -1 },
        strings = { "Live (0.5s)", "Normal (2s)", "Relaxed (10s)", "Manual only" },
    },
    debugEnabled = {
        order   = 10,
        default = 2,                                            -- Disabled
        values  = { true, false },
        strings = { "Enabled", "Disabled" },
    },
}

-- current values (initialised to defaults)
for id, def in pairs(DistributionSettings.SETTINGS) do
    DistributionSettings[id] = def.values[def.default]
end

-- a FIXED serialization order for the multiplayer settings event (pairs() is unordered, so the
-- write and read sides must agree on the sequence). Sorted by each setting's display order.
-- A `localOnly` setting is NOT world state and never goes on the wire, so it is left out of this list
-- entirely -- which is also what keeps the write and read sides the same length, since both ends build the
-- list from this same table with this same filter.
local ORDERED_IDS = {}
for id, d in pairs(DistributionSettings.SETTINGS) do
    if not d.localOnly then ORDERED_IDS[#ORDERED_IDS + 1] = id end
end
table.sort(ORDERED_IDS, function(a, b)
    return DistributionSettings.SETTINGS[a].order < DistributionSettings.SETTINGS[b].order
end)

-- live menu option controls, keyed by id, so a sync can refresh what other players see
DistributionSettings._optionById = {}

-- ---- where settings live ---------------------------------------------------
-- TWO files, deliberately, because these settings answer two different questions.
--
--   WORLD settings -> savegame<N>/distributionSettings.xml
--     scope, radius, buffer hours, haulage cost, seasonal reserve, pallet spawning -- every rule the
--     hourly pass runs under. These belong to the WORLD, not to the player: a test map and a realism
--     map want different answers, and a single profile-wide file forced them to share one. This now
--     sits beside smartDistribution.xml (the per-asset modes), which has always been per-savegame --
--     the settings file was the odd one out. Server-authoritative in MP, exactly as before.
--
--   LOCAL settings -> modSettings/FS25_Distribution_Redux/settings.xml (the original profile file)
--     menuRefresh alone, for the reason it carries `localOnly` (see its definition): a display pacing
--     dial for the machine the menu is open on, not world state. Profile-wide so one choice serves
--     every savegame.
--
-- The profile file ALSO still holds the world keys, historically. They are now read ONLY to seed a
-- savegame that predates this split -- see firstLoadSource.
local PROFILE_FILE  = "modSettings/FS25_Distribution_Redux/settings.xml"
local SAVEGAME_FILE = "distributionSettings.xml"

-- NOTHING may be written until a load has completed. onMenuOptionChanged saves on EVERY option change,
-- and the load is DEFERRED on a dedicated server (missionInfo.savegameDirectory is nil at
-- loadMission00Finished -- the trap SmartDistribution's own loader carries a retry for). Without this
-- guard, a player who opens Settings before that retry lands would write a set of mostly-DEFAULT values
-- over that savegame's real file, destroying it before it had ever been read.
DistributionSettings._loaded = false

-- ---- helpers ---------------------------------------------------------------
local function getStateIndex(id)
    local def = DistributionSettings.SETTINGS[id]
    local cur = DistributionSettings[id]
    for i, v in ipairs(def.values) do
        if v == cur then return i end
    end
    return def.default
end

-- public wrapper so the consolidated menu's Settings page can read current state
function DistributionSettings.getStateIndex(id) return getStateIndex(id) end

local function isAllowed(id, value)
    for _, v in ipairs(DistributionSettings.SETTINGS[id].values) do
        if v == value then return true end
    end
    return false
end

-- apply the current values into the live engine settings
function DistributionSettings.apply()
    local SD = SmartDistribution
    if SD == nil or SD.settings == nil or SD.settings.global == nil then return end
    -- scope reuses the engine's preset machinery: RANGE -> farm-wide, PROXIMITY -> radius (both keep all classes)
    if SD.applyGlobalPreset ~= nil then SD.applyGlobalPreset(DistributionSettings.scope) end
    local g = SD.settings.global
    g.includeHusbandry  = DistributionSettings.includeHusbandry
    g.includeSilosSheds = DistributionSettings.includeSilosSheds
    g.includeMarkets    = DistributionSettings.includeMarkets
    g.includeMapStorage = DistributionSettings.includeMapStorage
    g.advancedRoutingEnabled = DistributionSettings.advancedRouting
    -- Advanced routing OFF resets every advanced input/output override to default (not just ignores them):
    -- clear the source blocks / priority + receiver input blocks / caps / targets. Runs after loadOverrides
    -- on load (source-file order) and on every settings change / MP sync, so an OFF state always means clean.
    if DistributionSettings.advancedRouting == false and SD.clearAdvancedControl ~= nil then
        SD.clearAdvancedControl()
    end
    g.radius      = DistributionSettings.radius
    g.bufferHours = DistributionSettings.bufferHours
    g.sellEnabled = DistributionSettings.sellEnabled
    g.waterSupplyEnabled = DistributionSettings.waterSupplyEnabled
    g.distCostEnabled   = DistributionSettings.distCostEnabled
    g.distCostBase      = DistributionSettings.distCostBase
    g.distCostThreshold = DistributionSettings.distCostThreshold
    g.seasonalReserveEnabled = DistributionSettings.seasonalReserveEnabled
    g.seasonalFallbackMonths = DistributionSettings.seasonalFallbackMonths
    g.bestPriceEnabled = DistributionSettings.bestPriceEnabled
    g.bestPriceDefault = DistributionSettings.bestPriceDefault
    -- Read ONLY by stampPlacementDefaults, at the moment a building is placed. Deliberately NOT fed into
    -- anything the resolver consults: g.mode stays MODE.DISTRIBUTE permanently, so a building that was
    -- never stamped keeps resolving exactly as it always did, whatever these are set to.
    g.defaultOutputMode = DistributionSettings.defaultOutputMode
    g.defaultInputMode  = DistributionSettings.defaultInputMode
    -- One setting, two engine flags. fullPalletSpawn means "the pen's vanilla auto-spawn is suppressed",
    -- which is true for BOTH "whole pallets" and "never" -- only Vanilla lets the base game trickle-fill.
    -- Every existing 5.20 code path reads fullPalletSpawn and keeps working untouched; palletSpawnMode is
    -- what the new NEVER behaviour tests (SmartDistribution.palletSpawnAllowed).
    g.palletSpawnMode  = DistributionSettings.palletSpawnMode
    g.fullPalletSpawn  = (DistributionSettings.palletSpawnMode ~= 0)
    -- purely a GUI pacing dial: read by DistributionMenuPage and the Overview, never by the hourly pass.
    -- Clearing the adaptive backoff gives an explicit choice a fresh start rather than leaving it stretched
    -- by whatever the menu measured before -- the menu re-learns within a refresh or two if it needs to.
    g.menuRefresh      = DistributionSettings.menuRefresh
    if DistributionMenuPage ~= nil and DistributionMenuPage.resetRefreshPacing ~= nil then
        DistributionMenuPage.resetRefreshPacing()
    end
    SD.debug = DistributionSettings.debugEnabled
    if SD.debug then
        print(string.format("[DistributionSettings] applied scope=%s husbandry=%s silos/sheds=%s markets=%s radius=%d buffer=%dh selling=%s cost=%s($%d/%dm)",
            tostring(DistributionSettings.scope), tostring(g.includeHusbandry), tostring(g.includeSilosSheds), tostring(g.includeMarkets), g.radius, g.bufferHours, tostring(g.sellEnabled),
            tostring(g.distCostEnabled), g.distCostBase, g.distCostThreshold))
    end
end

-- ---- save / load -----------------------------------------------------------
-- The savegame folder, resolved by SmartDistribution's OWN resolver so the two files can never land in
-- different places. A second, private copy of that logic is precisely how the dedicated-server bug in
-- its header comment was created: a writer and a reader that disagreed about where the file lived.
-- Second return says whether the answer is AUTHORITATIVE (the engine's own savegameDirectory) or a
-- GUESS rebuilt from savegameIndex -- and a guess must never be taken as proof that a file is absent.
-- missionInfo is the one handed to the SAVE HOOK, and passing it is load-bearing rather than tidy: while
-- a save is in progress the engine points savegameDirectory at .../tempsavegame/, and that is where this
-- file HAS to be written. See installSaveHook below for why.
local function savegameDir(missionInfo)
    if SmartDistribution ~= nil and SmartDistribution.getSaveDir ~= nil then
        local ok, dir, authoritative = pcall(SmartDistribution.getSaveDir, missionInfo)
        if ok then return dir, authoritative == true end
    end
    return nil, false
end

-- Open an XML file for writing, reusing the existing document when there is one so unknown keys (an
-- older build's, or a hand-edit) survive a rewrite. Returns nil on failure; every caller reports it.
local function openForWrite(path)
    if fileExists(path) then return loadXMLFile("DistReduxSettings", path) end
    return createXMLFile("DistReduxSettings", path, "distributionRedux")
end

-- ---- the LOCAL half: menuRefresh, profile-wide ------------------------------
function DistributionSettings.saveLocal()
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(getUserProfileAppPath() .. "modSettings/FS25_Distribution_Redux/")
    local path = Utils.getFilename(PROFILE_FILE, getUserProfileAppPath())
    local xml = openForWrite(path)
    if xml == nil or xml == 0 then
        print(string.format("[DistributionSettings persist] LOCAL SAVE FAILED: could not open %s", tostring(path)))
        return
    end
    setXMLFloat(xml, "distributionRedux.settings#menuRefresh", DistributionSettings.menuRefresh)
    saveXMLFile(xml)
    delete(xml)
end

-- ---- the WORLD half: everything else, per savegame --------------------------
-- STARTING A NEW GAME USED TO LOSE EVERY SETTING. Reported and then reproduced deliberately
-- 2026-08-09: new game -> place buildings -> change DR settings -> save -> reload -> all settings back
-- at hard defaults. Modes survived, which is what narrowed it to this file (smartDistribution.xml has
-- no equivalent gate). The chain, every step visible in one log:
--
--   1. a NEW GAME has no savegame folder yet -- it is created BY the first save -- so
--      missionInfo.savegameDirectory is nil and savegameDir() falls back to a GUESS (authoritative=false)
--   2. load() finds no file at the guessed path, hits its "a guess is not evidence of absence" guard
--      (correct, and there for the dedicated server) and returns with _loaded FALSE
--   3. this function was gated on _loaded, so EVERY save that session was skipped -- including the one
--      the game's own save hook fires ("SAVE skipped: settings not loaded yet")
--   4. so distributionSettings.xml never reached tempsavegame/, and the folder swap left the new
--      savegame with no settings file at all (see installSaveHook below for the swap)
--   5. next load: authoritative, file absent -> seedFromProfile -> "NEW savegame, hard defaults"
--
-- The gate itself is right; refusing an ad-hoc write during the deferred window still protects a live
-- farm. What was wrong is refusing the GAME SAVE, because skipping that does not preserve the old file,
-- it DESTROYS it. So the deferral now applies only to non-authoritative callers (a menu change), while
-- an authoritative one -- the save hook, writing into tempsavegame/ -- always resolves the situation
-- first via adoptPendingWorldSettings and then writes.
--
-- dir is resolved BEFORE the gate now, because the gate needs `authoritative` to tell those two apart.
-- savegameDir() has no side effects, so the reorder changes nothing else.
function DistributionSettings.save(missionInfo)
    local dir, authoritative = savegameDir(missionInfo)
    if dir == nil then
        print("[DistributionSettings persist] SAVE skipped: savegame directory unresolved")
        return
    end
    if not DistributionSettings._loaded then
        if not authoritative then
            print("[DistributionSettings persist] SAVE skipped: settings not loaded yet (deferred load pending)")
            return
        end
        if not DistributionSettings.adoptPendingWorldSettings() then return end
    end
    -- A brand-new career has not been saved yet, so its savegame folder may not exist the first time a
    -- setting is changed. Creating an existing folder is a no-op. Gated on an AUTHORITATIVE path so a
    -- guess reconstructed from savegameIndex can never conjure a savegameN folder that is not the one
    -- in use -- the same "a guess is not proof" rule the loader works to.
    if authoritative then createFolder(dir) end
    local path = dir .. SAVEGAME_FILE
    local xml = openForWrite(path)
    -- Unconditional print, not gated on debugEnabled: a settings file that cannot be written is the exact
    -- shape of "none of my settings persist", and until now this returned in total silence. Matches the
    -- [SmartDistribution persist] lines so both halves of persistence are greppable from one log.
    if xml == nil or xml == 0 then
        print(string.format("[DistributionSettings persist] SAVE FAILED: could not open %s", tostring(path)))
        return
    end
    setXMLString(xml, "distributionRedux.settings#scope",       tostring(DistributionSettings.scope))
    setXMLBool(xml,   "distributionRedux.settings#includeHusbandry",  DistributionSettings.includeHusbandry)
    setXMLBool(xml,   "distributionRedux.settings#includeSilosSheds", DistributionSettings.includeSilosSheds)
    setXMLBool(xml,   "distributionRedux.settings#includeMarkets",    DistributionSettings.includeMarkets)
    setXMLBool(xml,   "distributionRedux.settings#includeMapStorage", DistributionSettings.includeMapStorage)
    setXMLBool(xml,   "distributionRedux.settings#advancedRouting",   DistributionSettings.advancedRouting)
    setXMLInt(xml,    "distributionRedux.settings#radius",      DistributionSettings.radius)
    setXMLInt(xml,    "distributionRedux.settings#bufferHours", DistributionSettings.bufferHours)
    setXMLBool(xml,   "distributionRedux.settings#sellEnabled", DistributionSettings.sellEnabled)
    setXMLBool(xml,   "distributionRedux.settings#waterSupplyEnabled", DistributionSettings.waterSupplyEnabled)
    setXMLBool(xml,   "distributionRedux.settings#distCostEnabled",   DistributionSettings.distCostEnabled)
    setXMLInt(xml,    "distributionRedux.settings#distCostBase",      DistributionSettings.distCostBase)
    setXMLInt(xml,    "distributionRedux.settings#distCostThreshold", DistributionSettings.distCostThreshold)
    setXMLBool(xml,   "distributionRedux.settings#seasonalReserveEnabled", DistributionSettings.seasonalReserveEnabled)
    setXMLInt(xml,    "distributionRedux.settings#seasonalFallbackMonths", DistributionSettings.seasonalFallbackMonths)
    setXMLBool(xml,   "distributionRedux.settings#bestPriceEnabled", DistributionSettings.bestPriceEnabled)
    setXMLBool(xml,   "distributionRedux.settings#bestPriceDefault", DistributionSettings.bestPriceDefault)
    setXMLInt(xml,    "distributionRedux.settings#defaultOutputMode", DistributionSettings.defaultOutputMode)
    setXMLInt(xml,    "distributionRedux.settings#defaultInputMode",  DistributionSettings.defaultInputMode)
    setXMLInt(xml,    "distributionRedux.settings#palletSpawnMode", DistributionSettings.palletSpawnMode)
    -- menuRefresh is NOT written here: it is localOnly, so it belongs to the machine rather than to the
    -- world, and lives in the profile file via saveLocal(). Writing it per-savegame would make one
    -- player's display pacing a property of the map.
    setXMLBool(xml,   "distributionRedux.settings#debugEnabled", DistributionSettings.debugEnabled)
    saveXMLFile(xml)
    delete(xml)
    print(string.format("[DistributionSettings persist] SAVED -> %s", tostring(path)))
end

-- Read every WORLD key out of an already-open settings document. Factored out of load() because it is
-- now applied to TWO different files: the savegame's own, and -- once, for a savegame that predates the
-- per-savegame split -- the profile file it is seeded from. Every isAllowed() gate and the
-- palletSpawnMode migration are the originals, moved verbatim. The caller owns the handle.
local function readWorldSettings(xml)
    local scope = getXMLString(xml, "distributionRedux.settings#scope")
    if scope ~= nil and isAllowed("scope", scope) then DistributionSettings.scope = scope end

    local incHusb = getXMLBool(xml, "distributionRedux.settings#includeHusbandry")
    if incHusb ~= nil then DistributionSettings.includeHusbandry = incHusb end

    local incSilos = getXMLBool(xml, "distributionRedux.settings#includeSilosSheds")
    if incSilos ~= nil then DistributionSettings.includeSilosSheds = incSilos end

    local incMarkets = getXMLBool(xml, "distributionRedux.settings#includeMarkets")
    if incMarkets ~= nil then DistributionSettings.includeMarkets = incMarkets end

    local incMapStore = getXMLBool(xml, "distributionRedux.settings#includeMapStorage")
    if incMapStore ~= nil then DistributionSettings.includeMapStorage = incMapStore end

    local advRouting = getXMLBool(xml, "distributionRedux.settings#advancedRouting")
    if advRouting ~= nil then DistributionSettings.advancedRouting = advRouting end

    local radius = getXMLInt(xml, "distributionRedux.settings#radius")
    if radius ~= nil and isAllowed("radius", radius) then DistributionSettings.radius = radius end

    local buffer = getXMLInt(xml, "distributionRedux.settings#bufferHours")
    if buffer ~= nil and isAllowed("bufferHours", buffer) then DistributionSettings.bufferHours = buffer end

    local sell = getXMLBool(xml, "distributionRedux.settings#sellEnabled")
    if sell ~= nil then DistributionSettings.sellEnabled = sell end

    local autoWater = getXMLBool(xml, "distributionRedux.settings#waterSupplyEnabled")
    if autoWater ~= nil then DistributionSettings.waterSupplyEnabled = autoWater end

    local dcEnabled = getXMLBool(xml, "distributionRedux.settings#distCostEnabled")
    if dcEnabled ~= nil then DistributionSettings.distCostEnabled = dcEnabled end

    local dcBase = getXMLInt(xml, "distributionRedux.settings#distCostBase")
    if dcBase ~= nil and isAllowed("distCostBase", dcBase) then DistributionSettings.distCostBase = dcBase end

    local dcThreshold = getXMLInt(xml, "distributionRedux.settings#distCostThreshold")
    if dcThreshold ~= nil and isAllowed("distCostThreshold", dcThreshold) then DistributionSettings.distCostThreshold = dcThreshold end

    local seasonal = getXMLBool(xml, "distributionRedux.settings#seasonalReserveEnabled")
    if seasonal ~= nil then DistributionSettings.seasonalReserveEnabled = seasonal end


    local fallback = getXMLInt(xml, "distributionRedux.settings#seasonalFallbackMonths")
    if fallback ~= nil and isAllowed("seasonalFallbackMonths", fallback) then DistributionSettings.seasonalFallbackMonths = fallback end

    local bpEnabled = getXMLBool(xml, "distributionRedux.settings#bestPriceEnabled")
    if bpEnabled ~= nil then DistributionSettings.bestPriceEnabled = bpEnabled end

    local bpDefault = getXMLBool(xml, "distributionRedux.settings#bestPriceDefault")
    if bpDefault ~= nil then DistributionSettings.bestPriceDefault = bpDefault end

    -- Absent in a file written before these existed, which is exactly right: they then keep their
    -- defaults (Distribute / Accept all), and since neither is a resolver default, an upgraded save
    -- behaves identically to how it did before the upgrade.
    local defOut = getXMLInt(xml, "distributionRedux.settings#defaultOutputMode")
    if defOut ~= nil and isAllowed("defaultOutputMode", defOut) then DistributionSettings.defaultOutputMode = defOut end

    local defIn = getXMLInt(xml, "distributionRedux.settings#defaultInputMode")
    if defIn ~= nil and isAllowed("defaultInputMode", defIn) then DistributionSettings.defaultInputMode = defIn end

    -- palletSpawnMode replaced the fullPalletSpawn on/off. Read the new key first; fall back to
    -- MIGRATING the old boolean so an existing settings file keeps the behaviour it had (true was
    -- "whole pallets", false was vanilla trickle-fill). Nobody lands on Never by migration -- that is
    -- new behaviour and has to be chosen.
    local palMode = getXMLInt(xml, "distributionRedux.settings#palletSpawnMode")
    if palMode ~= nil then
        DistributionSettings.palletSpawnMode = palMode
    else
        local fullPal = getXMLBool(xml, "distributionRedux.settings#fullPalletSpawn")
        if fullPal ~= nil then DistributionSettings.palletSpawnMode = fullPal and 1 or 0 end
    end

    -- menuRefresh is deliberately NOT read here -- it is localOnly and comes from the profile file, so a
    -- savegame written by an older build cannot impose one machine's display pacing on another's.

    local dbg = getXMLBool(xml, "distributionRedux.settings#debugEnabled")
    if dbg ~= nil then DistributionSettings.debugEnabled = dbg end
end

-- The LOCAL half. Its own reader because it comes from a different file on a different schedule, and
-- because it must still be picked up on a multiplayer CLIENT, which never loads world settings at all.
local function readLocalSettings()
    local path = Utils.getFilename(PROFILE_FILE, getUserProfileAppPath())
    if not fileExists(path) then return end
    local xml = loadXMLFile("DistReduxSettings", path)
    if xml == nil or xml == 0 then return end
    -- absent in a settings file written before this option existed, so it simply keeps its default
    local refresh = getXMLFloat(xml, "distributionRedux.settings#menuRefresh")
    if refresh ~= nil and isAllowed("menuRefresh", refresh) then DistributionSettings.menuRefresh = refresh end
    delete(xml)
end

-- A savegame with no distributionSettings.xml of its own is one of two very different things, and
-- treating them alike would be wrong in both directions:
--
--   EXISTING save -- played with DR before this split, so its owner has settings they tuned in the
--     profile file. Seed from there, or the update would silently change scope, radius, haulage cost
--     and pallet spawning on a live farm (the failure class CLAUDE.md 5.31 / 5.44 both had to migrate).
--
--   NEW save -- hard defaults, per the author's call. The profile file is explicitly NOT consulted: a
--     fresh map starts from the mod's own defaults rather than inheriting whatever the last farm was
--     tuned to.
--
-- smartDistribution.xml is the discriminator because saveOverrides writes it UNCONDITIONALLY on every
-- save (version + backlog marker even with nothing configured), so its presence means exactly "this
-- savegame has been saved at least once with DR installed". Deleting a savegame takes the whole folder
-- with it -- verified on this profile, where savegame4's directory is gone entirely -- so a NEW save can
-- never inherit a stale marker from the slot it reuses.
local function seedFromProfile(dir)
    if not fileExists(dir .. "smartDistribution.xml") then
        print("[DistributionSettings persist] first load: NEW savegame -- using hard defaults")
        return
    end
    local path = Utils.getFilename(PROFILE_FILE, getUserProfileAppPath())
    if not fileExists(path) then
        print("[DistributionSettings persist] first load: existing savegame, but no profile file -- using hard defaults")
        return
    end
    local xml = loadXMLFile("DistReduxSettings", path)
    if xml == nil or xml == 0 then
        print(string.format("[DistributionSettings persist] first load: could not open profile %s -- using hard defaults", tostring(path)))
        return
    end
    readWorldSettings(xml)
    delete(xml)
    print(string.format("[DistributionSettings persist] first load: EXISTING savegame -- migrated settings from %s", tostring(path)))
end

-- Called by save() when a GAME SAVE arrives while the load is still deferred. Returns true if the
-- caller may write, false if it must skip. Reported 2026-08-09: on a NEW GAME every setting reverted
-- to hard defaults after the first save/reload -- see the block above save() for the full chain.
--
-- The two cases look identical from inside the deferred window and must NOT be treated alike:
--
--   NEW SAVE -- there is genuinely no file, because the savegame folder itself does not exist until
--     this very save creates it. The in-memory values ARE the player's (a menu change applies to
--     memory even when the save is skipped), so writing them is exactly right.
--
--   DEFERRED LOAD over a REAL file (the dedicated-server case the _loaded gate was built for) -- a
--     file exists that we have not read. Writing memory here would overwrite a live farm's settings
--     with defaults, which is precisely what that gate prevents. So ADOPT it first: read it, apply it,
--     and let the normal write put it back unchanged. That also repairs the session, which until now
--     ran on defaults until the hourly retry happened to resolve.
--
-- The discriminator is the LIVE savegame folder, rebuilt from savegameIndex. It cannot come from
-- savegameDir(): during a save the engine points savegameDirectory at .../tempsavegame/, which is where
-- we are writing TO, never where the existing file lives.
--
-- Placed here, BELOW readWorldSettings -- that is a local, and save() sits ABOVE its declaration, so
-- calling it from there would resolve to a nil global and throw inside the save hook (CLAUDE.md 5.44;
-- luac -p does not catch it). save() reaches this as a FIELD, which resolves at call time.
function DistributionSettings.adoptPendingWorldSettings()
    local mi  = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local idx = mi ~= nil and mi.savegameIndex or nil
    if idx == nil or getUserProfileAppPath == nil then
        print("[DistributionSettings persist] SAVE skipped: load still pending and the live savegame folder is unresolved")
        return false
    end
    local livePath = getUserProfileAppPath() .. "savegame" .. tostring(idx) .. "/" .. SAVEGAME_FILE
    if fileExists(livePath) then
        local xml = loadXMLFile("DistReduxSettings", livePath)
        if xml == nil or xml == 0 then
            print(string.format("[DistributionSettings persist] SAVE skipped: load pending and %s could not be read", tostring(livePath)))
            return false                                          -- never overwrite a file we failed to read
        end
        readWorldSettings(xml)
        delete(xml)
        DistributionSettings._loaded = true
        DistributionSettings.apply()                              -- the session has been running on defaults; fix that too
        print(string.format("[DistributionSettings persist] SAVE: adopted the pending file before writing -> %s", tostring(livePath)))
        return true
    end
    DistributionSettings._loaded = true
    print("[DistributionSettings persist] SAVE: no settings file for this savegame (NEW save) -- writing the current settings")
    return true
end

function DistributionSettings.load()
    if DistributionSettings._loaded then return end              -- already loaded; never load twice
    readLocalSettings()                                          -- profile-wide, and safe on a client

    -- A CLIENT owns no world settings -- the server is authoritative and sends them through
    -- DistributionSettingsEvent on join. Marking the load complete here is what lets a client persist
    -- its own menuRefresh without ever writing a world file (the world save is guarded on isServer).
    if g_currentMission ~= nil and not g_currentMission:getIsServer() then
        DistributionSettings._loaded = true
        return
    end

    local dir, authoritative = savegameDir()
    -- DEDICATED SERVER: savegameDirectory is nil at loadMission00Finished. Leave _loaded false so the
    -- retry in runHourly picks this up once the path resolves -- and so nothing may be SAVED meanwhile.
    if dir == nil then
        print("[DistributionSettings persist] LOAD deferred: savegame directory unresolved -- will retry")
        return
    end
    local path = dir .. SAVEGAME_FILE
    if not fileExists(path) then
        -- A GUESSED PATH IS NOT EVIDENCE OF ABSENCE. Concluding "first load" from a guess would seed
        -- the wrong thing and then write it, permanently. Only an authoritative miss is proof.
        if not authoritative then
            print(string.format("[DistributionSettings persist] LOAD deferred: %s absent but path was GUESSED -- will retry", tostring(path)))
            return
        end
        seedFromProfile(dir)
        DistributionSettings._loaded = true                       -- set BEFORE save(), which is gated on it
        DistributionSettings.save()                               -- lay down this savegame's own file
        return
    end
    local xml = loadXMLFile("DistReduxSettings", path)
    if xml == nil or xml == 0 then
        print(string.format("[DistributionSettings persist] LOAD FAILED: could not open %s", tostring(path)))
        return
    end
    print(string.format("[DistributionSettings persist] LOAD fired: %s", tostring(path)))
    readWorldSettings(xml)
    delete(xml)
    DistributionSettings._loaded = true
end

-- ---- menu callback target --------------------------------------------------
function DistributionControls:onMenuOptionChanged(state, menuOption)
    if menuOption == nil then return end
    local id  = menuOption.id
    local def = DistributionSettings.SETTINGS[id]
    if def == nil then return end
    local value = def.values[state]
    if value == nil then return end
    DistributionSettings[id] = value
    DistributionSettings.apply()                       -- push into the live engine settings
    if def.localOnly then
        -- A localOnly setting is this MACHINE's, so it is written on a client too -- which is what makes
        -- a client's menu refresh choice survive a session at last (CLAUDE.md 5.46 records that it did
        -- not, precisely because the only save path was gated on isServer).
        DistributionSettings.saveLocal()
    elseif g_currentMission == nil or g_currentMission:getIsServer() then
        -- only the server owns the world settings file; clients persist no world state from an MP session
        DistributionSettings.save()
    end
    -- multiplayer: relay the change so the server (authoritative for the hourly pass) and every
    -- client converge.  A client sends to the server, which applies + rebroadcasts to all.
    if DistributionSettingsEvent ~= nil then DistributionSettingsEvent.sendCurrent() end
end

-- ---- multiplayer settings sync ---------------------------------------------
-- Apply a full set of setting indices (the wire format) locally: update each dialed value, push
-- into the engine, refresh any open menu controls, and persist on the server. Never re-sends.
function DistributionSettings.applyIndices(indices)
    for i, id in ipairs(ORDERED_IDS) do
        local def = DistributionSettings.SETTINGS[id]
        local idx = indices[i]
        if def ~= nil and idx ~= nil and def.values[idx] ~= nil then
            DistributionSettings[id] = def.values[idx]
        end
    end
    DistributionSettings.apply()
    DistributionSettings.refreshDisplay()
    if g_currentMission == nil or g_currentMission:getIsServer() then
        DistributionSettings.save()
    end
end

-- re-set the on-screen state of each injected option control (so a synced change shows live)
function DistributionSettings.refreshDisplay()
    for id, option in pairs(DistributionSettings._optionById or {}) do
        if option ~= nil and option.setState ~= nil then
            pcall(function() option:setState(getStateIndex(id)) end)
        end
    end
end

-- Event: carries the full global settings as state indices.  A player change -> sendCurrent();
-- a client sends to the server, the server applies + rebroadcasts; everyone converges.
local SETTINGS_NUM_BITS = 8     -- a state index (1..#values) fits easily in 8 bits
DistributionSettingsEvent = {}
local DistributionSettingsEvent_mt = Class(DistributionSettingsEvent, Event)
InitEventClass(DistributionSettingsEvent, "DistributionSettingsEvent")   -- register network id

function DistributionSettingsEvent.emptyNew()
    return Event.new(DistributionSettingsEvent_mt)
end
function DistributionSettingsEvent.new()
    local self = DistributionSettingsEvent.emptyNew()
    self.indices = {}
    for _, id in ipairs(ORDERED_IDS) do self.indices[#self.indices + 1] = getStateIndex(id) end
    return self
end
function DistributionSettingsEvent:writeStream(streamId, connection)
    for _, idx in ipairs(self.indices) do streamWriteUIntN(streamId, idx, SETTINGS_NUM_BITS) end
end
function DistributionSettingsEvent:readStream(streamId, connection)
    self.indices = {}
    for i = 1, #ORDERED_IDS do self.indices[i] = streamReadUIntN(streamId, SETTINGS_NUM_BITS) end
    self:run(connection)
end
function DistributionSettingsEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection)    -- server relays to the other clients
    end
    DistributionSettings.applyIndices(self.indices)          -- local apply only (no echo)
end
function DistributionSettingsEvent.sendCurrent()
    if g_server ~= nil then
        g_server:broadcastEvent(DistributionSettingsEvent.new())
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(DistributionSettingsEvent.new())
    end
end

-- Event: one distribution-control edit (input block / output priority / Store To target). Same shape as
-- the settings event -- a client sends it to the server, the server applies + rebroadcasts, everyone
-- converges. Any farm member may edit, matching how the mode events already work.
DistributionControlEvent = {}
local DistributionControlEvent_mt = Class(DistributionControlEvent, Event)
InitEventClass(DistributionControlEvent, "DistributionControlEvent")
DistributionControlEvent.ACT_NUM_BITS = 4   -- up to 15 actions; 8 used
-- Unified output->destination control. For EVERY action a=source output, b=destination (demand,
-- store or market -- they are all the same edge now). No per-kind actions any more.
DistributionControlEvent.ACT = {
    BLOCK       = 1,   -- a=source, b=dest, flag=blocked
    PRIO_TOGGLE = 2,   -- a=source, b=dest
    PRIO_MOVE   = 3,   -- a=source, b=dest, delta
    PRIO_CLEAR  = 4,   -- a=source
    INPUT_BLOCK = 5,   -- a=receiver, flag=blocked (receiver-side input block)
    INPUT_CAP   = 6,   -- a=receiver, delta=pct 0..100 (receiver-side per-product max %)
    INPUT_TARGET = 7,  -- a=receiver, delta=pct 0..100 (receiver-side fill target %); delta<0 clears
    OUTPUT_RESERVE = 8, -- a=source, amount=litres the source keeps back; amount<=0 clears
}

function DistributionControlEvent.emptyNew() return Event.new(DistributionControlEvent_mt) end
-- `amount` is a separate float because it carries LITRES: delta is an int8 (-128..127), which is fine
-- for the percentage actions but nowhere near enough for a silo-sized reserve.
function DistributionControlEvent.new(act, a, ft, b, delta, flag, amount)
    local self = DistributionControlEvent.emptyNew()
    self.act, self.a, self.ft, self.b = act, a or "", ft or 0, b or ""
    self.delta, self.flag, self.amount = delta or 0, flag and true or false, amount or 0
    return self
end
function DistributionControlEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.act, DistributionControlEvent.ACT_NUM_BITS)
    streamWriteString(streamId, self.a)
    streamWriteString(streamId, self.b)
    streamWriteUIntN(streamId, self.ft, FillTypeManager.SEND_NUM_BITS)
    streamWriteInt8(streamId, self.delta)
    streamWriteBool(streamId, self.flag)
    streamWriteFloat32(streamId, self.amount or 0)
end
function DistributionControlEvent:readStream(streamId, connection)
    self.act    = streamReadUIntN(streamId, DistributionControlEvent.ACT_NUM_BITS)
    self.a      = streamReadString(streamId)
    self.b      = streamReadString(streamId)
    self.ft     = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
    self.delta  = streamReadInt8(streamId)
    self.flag   = streamReadBool(streamId)
    self.amount = streamReadFloat32(streamId)
    self:run(connection)
end
function DistributionControlEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection)      -- server relays to the other clients
    end
    DistributionControlEvent.applyLocal(self.act, self.a, self.ft, self.b, self.delta, self.flag, self.amount)
end

-- apply on this machine only (no echo) -- used by run() and by the local sender
function DistributionControlEvent.applyLocal(act, a, ft, b, delta, flag, amount)
    local SD = SmartDistribution
    if SD == nil then return end
    -- Every advanced-routing mutation funnels through here -- including one arriving from another player --
    -- so this is the one place that has to drop the menu's cached destination lists and pooled shares.
    -- Without it a block or priority change would keep reading its old value for up to MEMO_TTL.
    if SD.invalidateMenuMemos ~= nil then SD.invalidateMenuMemos() end
    local A = DistributionControlEvent.ACT
    if     act == A.BLOCK       then SD.setDestBlocked(a, ft, b, flag)
    elseif act == A.PRIO_TOGGLE then SD.toggleDestPriority(a, ft, b)
    elseif act == A.PRIO_MOVE   then SD.moveDestPriority(a, ft, b, delta)
    elseif act == A.PRIO_CLEAR  then SD.clearDestPriority(a, ft)
    elseif act == A.INPUT_BLOCK then SD.setInputBlocked(a, ft, flag)
    elseif act == A.INPUT_CAP   then SD.setInputCapPct(a, ft, delta)
    elseif act == A.INPUT_TARGET then SD.setInputTargetPct(a, ft, (delta ~= nil and delta >= 0) and delta or nil)   -- delta<0 clears
    elseif act == A.OUTPUT_RESERVE then SD.setOutputReserve(a, ft, (amount ~= nil and amount > 0) and amount or nil)  -- <=0 clears
    end
end

-- The UI calls this. Applies locally straight away (so the menu responds), then syncs: the host
-- broadcasts, a client asks the server (which applies + relays to everyone else).
function DistributionControlEvent.send(act, a, ft, b, delta, flag, amount)
    DistributionControlEvent.applyLocal(act, a, ft, b, delta, flag, amount)
    local e = DistributionControlEvent.new(act, a, ft, b, delta, flag, amount)
    if g_server ~= nil then
        g_server:broadcastEvent(e)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(e)
    end
end

-- Event: the server tells a client which uniqueId IT uses for each placeable.
--
-- Required because a placeable's uniqueId is never streamed, so a client MINTS its own for every
-- player-built building and no uid-keyed DR state can match across the wire. The full reasoning is
-- in the _serverUidById note above getUid in SmartDistribution.lua.
--
-- Addressed by NETWORK OBJECT ID, not by a node object, and that is the whole point: an id is a
-- plain number in a shared server-assigned space, so neither end has to have finished loading the
-- placeable for the entry to be recorded. A joining client loads player-built placeables
-- asynchronously, so anything sent as a node object during the join burst can read back nil.
DistributionUidMapEvent = {}
local DistributionUidMapEvent_mt = Class(DistributionUidMapEvent, Event)
InitEventClass(DistributionUidMapEvent, "DistributionUidMapEvent")

DistributionUidMapEvent.CHUNK          = 64   -- entries per event, so one stream stays small
DistributionUidMapEvent.COUNT_NUM_BITS = 8    -- 0..255; CHUNK must stay within that

function DistributionUidMapEvent.emptyNew() return Event.new(DistributionUidMapEvent_mt) end
function DistributionUidMapEvent.new(entries)
    local self = DistributionUidMapEvent.emptyNew()
    self.entries = entries or {}                 -- { {id = <objectId>, uid = <string>}, ... }
    return self
end
function DistributionUidMapEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, #self.entries, DistributionUidMapEvent.COUNT_NUM_BITS)
    for _, e in ipairs(self.entries) do
        NetworkUtil.writeNodeObjectId(streamId, e.id)   -- the ID, not the object: no resolution needed
        streamWriteString(streamId, e.uid)
    end
end
function DistributionUidMapEvent:readStream(streamId, connection)
    local n = streamReadUIntN(streamId, DistributionUidMapEvent.COUNT_NUM_BITS)
    self.entries = {}
    for i = 1, n do
        local id  = NetworkUtil.readNodeObjectId(streamId)
        self.entries[i] = { id = id, uid = streamReadString(streamId) }
    end
    self:run(connection)
end
function DistributionUidMapEvent:run(connection)
    -- server -> client only. A client never sends this, and the server must never adopt one:
    -- it is the authority on its own ids.
    if connection == nil or not connection:getIsServer() then return end
    if SmartDistribution == nil or SmartDistribution.setServerUid == nil then return end
    for _, e in ipairs(self.entries) do SmartDistribution.setServerUid(e.id, e.uid) end
    print(string.format("[SmartDistribution mp] uid map: adopted %d server id(s)", #self.entries))
    -- Every uid this map teaches changes what getUid answers, and therefore what a production's mode
    -- resolves to. Anything read BEFORE this event landed was derived from the local (wrong) id and cached
    -- -- measured at 68 ms too early for one building on a real join. Drop those derived answers so they
    -- are recomputed correctly; explicit player choices are not affected.
    if SmartDistribution.invalidateSeededVModes ~= nil then SmartDistribution.invalidateSeededVModes() end
    if SmartDistribution.invalidateMenuMemos ~= nil then SmartDistribution.invalidateMenuMemos() end
end
-- Send the whole map to ONE connection, in chunks.
function DistributionUidMapEvent.sendTo(connection)
    if connection == nil or SmartDistribution == nil or SmartDistribution.forEachServerUid == nil then return end
    local batch, sent = {}, 0
    SmartDistribution.forEachServerUid(function(id, uid)
        batch[#batch + 1] = { id = id, uid = uid }
        if #batch >= DistributionUidMapEvent.CHUNK then
            connection:sendEvent(DistributionUidMapEvent.new(batch))
            sent  = sent + #batch
            batch = {}                                   -- a NEW table; the event keeps the old one
        end
    end)
    if #batch > 0 then
        connection:sendEvent(DistributionUidMapEvent.new(batch))
        sent = sent + #batch
    end
    print(string.format("[SmartDistribution mp] uid map: sent %d placeable id(s) to a joining client", sent))
end

-- Event: a joining client asks the server for the current state; the server replies (to that one
-- connection) with the settings event + every per-asset override, so the client's display and
-- behaviour match the host immediately instead of showing its own local defaults.
DistributionStateRequestEvent = {}
local DistributionStateRequestEvent_mt = Class(DistributionStateRequestEvent, Event)
InitEventClass(DistributionStateRequestEvent, "DistributionStateRequestEvent")

function DistributionStateRequestEvent.emptyNew()
    return Event.new(DistributionStateRequestEvent_mt)
end
function DistributionStateRequestEvent.new()
    return DistributionStateRequestEvent.emptyNew()
end
function DistributionStateRequestEvent:writeStream(streamId, connection) end   -- no payload
function DistributionStateRequestEvent:readStream(streamId, connection)
    self:run(connection)
end
function DistributionStateRequestEvent:run(connection)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    -- FIRST, before any state: the client cannot key ANYTHING correctly until it knows our ids.
    -- Everything below is either keyed by uid outright (the control replay) or resolves one locally
    -- on arrival (the mode / timing replays), so the map has to be in place before they land.
    if DistributionUidMapEvent ~= nil then DistributionUidMapEvent.sendTo(connection) end
    connection:sendEvent(DistributionSettingsEvent.new())                       -- global settings
    if SmartDistribution ~= nil and SmartDistribution.forEachAssetOverride ~= nil
       and DistributionModeEvent ~= nil then
        SmartDistribution.forEachAssetOverride(function(placeable, ft, mode)    -- per-asset overrides
            connection:sendEvent(DistributionModeEvent.new(placeable, ft, mode))
        end)
    end
    if SmartDistribution ~= nil and SmartDistribution.forEachAssetSellTiming ~= nil
       and DistributionSellTimingEvent ~= nil then
        SmartDistribution.forEachAssetSellTiming(function(placeable, ft, value) -- per-asset sell-timing
            connection:sendEvent(DistributionSellTimingEvent.new(placeable, ft, value))
        end)
    end
    if SmartDistribution ~= nil and SmartDistribution.forEachMarketTiming ~= nil
       and DistributionMarketTimingEvent ~= nil then
        SmartDistribution.forEachMarketTiming(function(placeable, ft, mode) -- per-(market, ft) sell mode
            connection:sendEvent(DistributionMarketTimingEvent.new(placeable, ft, mode))
        end)
    end
    -- distribution control: output->destination blocks + destination priority (source-keyed, DR-owned).
    -- Replayed as individual edits so the joining client rebuilds the same two tables the server holds.
    if SmartDistribution ~= nil and SmartDistribution.control ~= nil and DistributionControlEvent ~= nil then
        local A = DistributionControlEvent.ACT
        local C = SmartDistribution.control
        for srcUid, byFt in pairs(C.blocked or {}) do
            for ft, dests in pairs(byFt) do
                for destUid in pairs(dests) do
                    connection:sendEvent(DistributionControlEvent.new(A.BLOCK, srcUid, ft, destUid, 0, true))
                end
            end
        end
        for srcUid, byFt in pairs(C.priority or {}) do
            for ft, list in pairs(byFt) do
                for _, destUid in ipairs(list) do   -- appended in rank order, so the order is preserved
                    connection:sendEvent(DistributionControlEvent.new(A.PRIO_TOGGLE, srcUid, ft, destUid, 0, false))
                end
            end
        end
        for rcvUid, byFt in pairs(C.inputBlock or {}) do   -- receiver-side input blocks
            for ft, on in pairs(byFt) do
                if on then connection:sendEvent(DistributionControlEvent.new(A.INPUT_BLOCK, rcvUid, ft, "", 0, true)) end
            end
        end
        for rcvUid, byFt in pairs(C.inputCapPct or {}) do   -- receiver-side per-product max %
            for ft, pct in pairs(byFt) do
                if type(pct) == "number" then connection:sendEvent(DistributionControlEvent.new(A.INPUT_CAP, rcvUid, ft, "", pct, false)) end
            end
        end
        for rcvUid, byFt in pairs(C.inputTarget or {}) do   -- receiver-side fill target %
            for ft, pct in pairs(byFt) do
                if type(pct) == "number" then connection:sendEvent(DistributionControlEvent.new(A.INPUT_TARGET, rcvUid, ft, "", pct, false)) end
            end
        end
        for srcUid, byFt in pairs(C.outputReserve or {}) do   -- source-side output reserve (litres)
            for ft, litres in pairs(byFt) do
                if type(litres) == "number" and litres > 0 then
                    connection:sendEvent(DistributionControlEvent.new(A.OUTPUT_RESERVE, srcUid, ft, "", 0, false, litres))
                end
            end
        end
    end
    if DistributionStatsEvent ~= nil and DistributionStatsEvent.broadcast ~= nil then
        DistributionStatsEvent.broadcast(connection)                            -- monthly /mo stats for the joining client
    end
end
function DistributionStateRequestEvent.sendToServer()
    if g_client ~= nil and g_server == nil then
        g_client:getServerConnection():sendEvent(DistributionStateRequestEvent.new())
    end
end

-- (the old in-game options-page settings injection was retired; settings now live
--  on the consolidated menu's Settings tab via DistributionSettingsPage.)

-- ---- hook: write the settings file INTO the game's own save ------------------
-- THIS IS WHAT MAKES PER-SAVEGAME SETTINGS PERSIST, and its absence is the whole of the bug reported
-- 2026-08-08 ("set settings on savegame2, saved, reloaded, settings reset").
--
-- FS25 does NOT write into savegame<N>/ when the player saves. It builds a fresh **tempsavegame/**
-- folder, writes the whole savegame into it, and then swaps that folder over savegame<N>/ -- so
-- ANYTHING already sitting in savegame<N>/ that was not also written into tempsavegame/ is destroyed by
-- the swap. The log shows it plainly:
--     [SmartDistribution persist] SAVE fired: dir=.../tempsavegame/  mi.savegameDirectory=.../tempsavegame
--
-- distributionSettings.xml was written only at load and on each option change, straight into
-- savegame<N>/ -- so every game save deleted it, every reload found nothing, and the settings came back
-- seeded from the profile. The tell was in the log: EVERY load printed "first load: EXISTING savegame
-- -- migrated" instead of "LOAD fired", i.e. the file was absent every single time.
--
-- smartDistribution.xml never had this problem because it has always been written from THIS hook. The
-- fix is simply to do the same, and to hand save() the missionInfo we are given so it resolves the
-- TEMP directory rather than the live one.
if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        function(self, ...)
            -- server owns the world settings; a client persists nothing from an MP session
            if g_currentMission == nil or g_currentMission:getIsServer() then
                pcall(DistributionSettings.save, self)
            end
        end)
    print("[DistributionSettings persist] save hook attached (FSCareerMissionInfo.saveToXMLFile)")
else
    print("[DistributionSettings persist] SAVE HOOK NOT ATTACHED -- FSCareerMissionInfo.saveToXMLFile missing")
end

-- ---- hook: load + apply + inject once the mission is up ---------------------
if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
    Mission00.loadMission00Finished = Utils.appendedFunction(
        Mission00.loadMission00Finished,
        function()
            DistributionSettings.load()
            DistributionSettings.apply()
            -- multiplayer: a client requests the authoritative state from the host so its
            -- settings + per-asset overrides match (the host owns the world settings).
            if g_currentMission ~= nil and not g_currentMission:getIsServer()
               and DistributionStateRequestEvent ~= nil then
                DistributionStateRequestEvent.sendToServer()
            end
        end)
end
