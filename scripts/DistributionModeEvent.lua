-- ============================================================================
-- DistributionModeEvent.lua  /  FS25 Distribution Redux
--
-- Multiplayer sync for a single per-asset (placeable, fillType, mode) override.
-- Pattern mirrors the GIANTS engine event ProductionPointOutputModeEvent:
--   - a player changes a mode -> SmartDistribution.applyAssetMode fires sendEvent
--   - client sends to server; server applies + broadcasts to every client
--   - on the receiving side run() applies with noEventSend so it never echoes
-- The placeable is sent as a node object (engine-synced); the override table is
-- keyed by uniqueId, which each side resolves from the placeable locally.
-- ============================================================================

DistributionModeEvent = {}
local DistributionModeEvent_mt = Class(DistributionModeEvent, Event)
-- REQUIRED: registers this event's network id so the engine can serialize it across machines.
-- Without it a client's sendEvent is silently undeliverable, so only the host's local apply took
-- effect -- the multiplayer "non-host changes do nothing" bug.
InitEventClass(DistributionModeEvent, "DistributionModeEvent")

DistributionModeEvent.MODE_NUM_BITS = 4   -- modes 0..8 need 4 bits (Market Supply=7, Distribute + Market Supply=8)

function DistributionModeEvent.emptyNew()
    return Event.new(DistributionModeEvent_mt)
end

function DistributionModeEvent.new(placeable, fillTypeIndex, mode)
    local self = DistributionModeEvent.emptyNew()
    self.placeable = placeable
    self.fillTypeIndex = fillTypeIndex
    self.mode = mode
    return self
end

function DistributionModeEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteUIntN(streamId, self.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
    streamWriteUIntN(streamId, self.mode, DistributionModeEvent.MODE_NUM_BITS)
end

function DistributionModeEvent:readStream(streamId, connection)
    self.placeable = NetworkUtil.readNodeObject(streamId)
    self.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
    self.mode = streamReadUIntN(streamId, DistributionModeEvent.MODE_NUM_BITS)
    self:run(connection)
end

function DistributionModeEvent:run(connection)
    -- received on the server from a client: relay to the other clients
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection)
    end
    if self.placeable ~= nil and SmartDistribution ~= nil and SmartDistribution.applyAssetMode ~= nil then
        SmartDistribution.applyAssetMode(self.placeable, self.fillTypeIndex, self.mode, true) -- noEventSend
    end
end

function DistributionModeEvent.sendEvent(placeable, fillTypeIndex, mode, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(DistributionModeEvent.new(placeable, fillTypeIndex, mode))
        elseif g_client ~= nil then
            g_client:getServerConnection():sendEvent(DistributionModeEvent.new(placeable, fillTypeIndex, mode))
        end
    end
end
