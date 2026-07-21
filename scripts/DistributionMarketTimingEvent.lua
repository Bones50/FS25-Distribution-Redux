-- ============================================================================
-- DistributionMarketTimingEvent.lua  /  FS25 Distribution Redux
--
-- Multiplayer sync for a single per-(market, fillType) sell-mode choice on the
-- Markets tab. Mirror of DistributionSellTimingEvent: the payload is a market,
-- a fill type, and that product's sell mode:
--   0 = sell immediately, 1 = sell at the seasonal peak, 2 = hold (never sell).
--   - a player changes a product's output / sell type -> applyMarketTiming sends
--   - client sends to server; server applies + broadcasts to every client
--   - on the receiving side run() applies with noEventSend so it never echoes
-- ============================================================================

DistributionMarketTimingEvent = {}
local DistributionMarketTimingEvent_mt = Class(DistributionMarketTimingEvent, Event)
InitEventClass(DistributionMarketTimingEvent, "DistributionMarketTimingEvent")   -- register network id

DistributionMarketTimingEvent.MODE_NUM_BITS = 2   -- sell modes 0..2 fit in 2 bits

function DistributionMarketTimingEvent.emptyNew()
    return Event.new(DistributionMarketTimingEvent_mt)
end

function DistributionMarketTimingEvent.new(placeable, fillTypeIndex, mode)
    local self = DistributionMarketTimingEvent.emptyNew()
    self.placeable     = placeable
    self.fillTypeIndex = fillTypeIndex
    self.mode          = mode or 0
    return self
end

function DistributionMarketTimingEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteUIntN(streamId, self.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
    streamWriteUIntN(streamId, self.mode, DistributionMarketTimingEvent.MODE_NUM_BITS)
end

function DistributionMarketTimingEvent:readStream(streamId, connection)
    self.placeable     = NetworkUtil.readNodeObject(streamId)
    self.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
    self.mode          = streamReadUIntN(streamId, DistributionMarketTimingEvent.MODE_NUM_BITS)
    self:run(connection)
end

function DistributionMarketTimingEvent:run(connection)
    -- received on the server from a client: relay to the other clients
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection)
    end
    if self.placeable ~= nil and SmartDistribution ~= nil and SmartDistribution.applyMarketTiming ~= nil then
        SmartDistribution.applyMarketTiming(self.placeable, self.fillTypeIndex, self.mode, true)   -- noEventSend
    end
end

function DistributionMarketTimingEvent.sendEvent(placeable, fillTypeIndex, mode, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(DistributionMarketTimingEvent.new(placeable, fillTypeIndex, mode))
        elseif g_client ~= nil then
            g_client:getServerConnection():sendEvent(DistributionMarketTimingEvent.new(placeable, fillTypeIndex, mode))
        end
    end
end
