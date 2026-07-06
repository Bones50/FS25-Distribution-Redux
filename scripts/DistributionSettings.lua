-- ============================================================================
-- DistributionSettings.lua  (Distribution Redux)
-- Global settings screen. Injects rows into the in-game Settings page and
-- persists the global preset + dials PER PROFILE, separate from the per-asset,
-- per-savegame override file owned by SmartDistribution.lua.
--
-- The menu-injection mirrors the proven reference pattern
-- (PDNESettings.injectMenu): clone the multiVolumeVoiceBox option row on
-- pageSettings.gameSettingsLayout, point it at our controls target, add it to
-- controlsList. GUI can't be offline-tested; the save/load + apply logic is
-- harness-validated. Display strings are literal (no l10n dependency yet).
-- ============================================================================

DistributionSettings = {}
DistributionControls = {}   -- separate callback target (reference-mod pattern)

-- ---- setting definitions ---------------------------------------------------
-- Each: order, label, tooltip (literal text); default (index into values);
-- values (applied to the engine); strings (shown in the left/right selector).
DistributionSettings.SETTINGS = {
    scope = {
        order   = 1,
        label   = "Scope",
        tooltip = "Range: every owned asset reaches farm-wide.  Proximity: assets only reach sources within the proximity radius below.",
        default = 1,                                            -- Range (farm-wide)
        values  = { "RANGE", "PROXIMITY" },
        strings = { "Range (farm-wide)", "Proximity (radius)" },
    },
    includeHusbandry = {
        order   = 1.3,
        label   = "Animal Husbandry",
        tooltip = "Include animal husbandry -- barns, coops, beehives, plus manure & slurry pits -- in the distribution network. Off removes them entirely: they are neither fed nor is their output (milk / manure / slurry / eggs / wool / honey) distributed or sold.",
        default = 1,                                            -- On
        values  = { true, false },
        strings = { "On", "Off" },
    },
    includeSilosSheds = {
        order   = 1.6,
        label   = "Silos & Pallet Storage",
        tooltip = "Include crop / material silos and pallet storage sheds in the distribution network. Off removes them: silos no longer feed productions, and pallet sheds neither receive nor release pallets. (Manure & slurry pits follow the Animal Husbandry setting.)",
        default = 1,                                            -- On
        values  = { true, false },
        strings = { "On", "Off" },
    },
    radius = {
        order   = 2,
        label   = "Proximity radius",
        tooltip = "How far a consumer reaches for sources in Proximity mode.",
        default = 2,                                            -- 50 m
        values  = { 25, 50, 75, 100, 150, 200 },
        strings = { "25 m", "50 m", "75 m", "100 m", "150 m", "200 m" },
    },
    bufferHours = {
        order   = 3,
        label   = "Consumer buffer",
        tooltip = "Hours of feedstock topped up at each consumer per cycle.",
        default = 2,                                            -- 2 h
        values  = { 1, 2, 4, 8, 12, 24 },
        strings = { "1 hour", "2 hours", "4 hours", "8 hours", "12 hours", "24 hours" },
    },
    sellEnabled = {
        order   = 4,
        label   = "Selling",
        tooltip = "Global switch for all auto-selling (Sell / Distribute+Sell modes).",
        default = 1,                                            -- Enabled
        values  = { true, false },
        strings = { "Enabled", "Disabled" },
    },
    waterSupplyEnabled = {
        order   = 4.5,                                          -- sits between Selling and the cost settings
        label   = "Auto-Water",
        tooltip = "Automatically supply water to water-input productions and animal pastures (billed by distance to the nearest water source).",
        default = 1,                                            -- Enabled
        values  = { true, false },
        strings = { "Enabled", "Disabled" },
    },
    distCostEnabled = {
        order   = 5,
        label   = "Distribution cost",
        tooltip = "Charge a per-hour transport cost for each active distribution (scales with haul distance).",
        default = 1,                                            -- Enabled
        values  = { true, false },
        strings = { "Enabled", "Disabled" },
    },
    distCostBase = {
        order   = 6,
        label   = "Cost rate",
        tooltip = "Base transport cost per hour for a short haul (at or under the cost distance below).",
        default = 3,                                            -- $10/h
        values  = { 0, 5, 10, 20, 50 },
        strings = { "$0 /h", "$5 /h", "$10 /h", "$20 /h", "$50 /h" },
    },
    distCostThreshold = {
        order   = 7,
        label   = "Cost distance",
        tooltip = "Hauls at or under this distance pay the flat base rate; longer hauls scale up linearly.",
        default = 2,                                            -- 50 m
        values  = { 25, 50, 100, 200, 500 },
        strings = { "25 m", "50 m", "100 m", "200 m", "500 m" },
    },
    seasonalReserveEnabled = {
        order   = 8,
        label   = "Seasonal harvest reserve",
        tooltip = "Crops set to Distribute+Sell keep enough feedstock to feed production until the next harvest; only the surplus is sold.",
        default = 2,                                            -- Disabled
        values  = { true, false },
        strings = { "Enabled", "Disabled" },
    },
    seasonalFallbackMonths = {
        order   = 9,
        label   = "Reserve months (until learned)",
        tooltip = "Months of feedstock to hold for a crop before the mod has observed its real harvest window.",
        default = 3,                                            -- 13 months
        values  = { 6, 12, 13, 18, 24 },
        strings = { "6 months", "12 months", "13 months", "18 months", "24 months" },
    },
    bestPriceEnabled = {
        order   = 9.3,                                          -- groups with the selling / seasonal controls
        label   = "Sell at best price",
        tooltip = "Master switch: hold Sell / Distribute+Sell surplus until its best month before selling. Off: everything sells immediately.",
        default = 1,                                            -- Enabled
        values  = { true, false },
        strings = { "Enabled", "Disabled" },
    },
    bestPriceDefault = {
        order   = 9.6,
        label   = "Default sell timing",
        tooltip = "Default for a newly-set Sell / Distribute+Sell output, until you change that building's own toggle.",
        default = 1,                                            -- Sell at best price
        values  = { true, false },
        strings = { "Sell at best price", "Sell immediately" },
    },
    debugEnabled = {
        order   = 10,
        label   = "Debug logging",
        tooltip = "Write detailed distribution activity to log.txt (moves, sales, stores, water top-ups and charges). Turn off for a quieter log.",
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
local ORDERED_IDS = {}
for id in pairs(DistributionSettings.SETTINGS) do ORDERED_IDS[#ORDERED_IDS + 1] = id end
table.sort(ORDERED_IDS, function(a, b)
    return DistributionSettings.SETTINGS[a].order < DistributionSettings.SETTINGS[b].order
end)

-- live menu option controls, keyed by id, so a sync can refresh what other players see
DistributionSettings._optionById = {}

local SETTINGS_FILE = "modSettings/FS25_Distribution_Redux/settings.xml"

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
    SD.debug = DistributionSettings.debugEnabled
    if SD.debug then
        print(string.format("[DistributionSettings] applied scope=%s husbandry=%s silos/sheds=%s radius=%d buffer=%dh selling=%s cost=%s($%d/%dm)",
            tostring(DistributionSettings.scope), tostring(g.includeHusbandry), tostring(g.includeSilosSheds), g.radius, g.bufferHours, tostring(g.sellEnabled),
            tostring(g.distCostEnabled), g.distCostBase, g.distCostThreshold))
    end
end

-- ---- save / load (per-profile) ---------------------------------------------
function DistributionSettings.save()
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(getUserProfileAppPath() .. "modSettings/FS25_Distribution_Redux/")
    local path = Utils.getFilename(SETTINGS_FILE, getUserProfileAppPath())
    local xml
    if fileExists(path) then
        xml = loadXMLFile("DistReduxSettings", path)
    else
        xml = createXMLFile("DistReduxSettings", path, "distributionRedux")
    end
    if xml == nil or xml == 0 then return end
    setXMLString(xml, "distributionRedux.settings#scope",       tostring(DistributionSettings.scope))
    setXMLBool(xml,   "distributionRedux.settings#includeHusbandry",  DistributionSettings.includeHusbandry)
    setXMLBool(xml,   "distributionRedux.settings#includeSilosSheds", DistributionSettings.includeSilosSheds)
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
    setXMLBool(xml,   "distributionRedux.settings#debugEnabled", DistributionSettings.debugEnabled)
    saveXMLFile(xml)
    delete(xml)
end

function DistributionSettings.load()
    local path = Utils.getFilename(SETTINGS_FILE, getUserProfileAppPath())
    if not fileExists(path) then
        DistributionSettings.save()        -- write defaults on first run
        return
    end
    local xml = loadXMLFile("DistReduxSettings", path)
    if xml == nil or xml == 0 then return end

    local scope = getXMLString(xml, "distributionRedux.settings#scope")
    if scope ~= nil and isAllowed("scope", scope) then DistributionSettings.scope = scope end

    local incHusb = getXMLBool(xml, "distributionRedux.settings#includeHusbandry")
    if incHusb ~= nil then DistributionSettings.includeHusbandry = incHusb end

    local incSilos = getXMLBool(xml, "distributionRedux.settings#includeSilosSheds")
    if incSilos ~= nil then DistributionSettings.includeSilosSheds = incSilos end

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

    local dbg = getXMLBool(xml, "distributionRedux.settings#debugEnabled")
    if dbg ~= nil then DistributionSettings.debugEnabled = dbg end

    delete(xml)
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
    -- only the server owns the world settings file; clients persist nothing from an MP session
    if g_currentMission == nil or g_currentMission:getIsServer() then
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
