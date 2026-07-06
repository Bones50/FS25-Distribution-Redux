-- ============================================================================
-- DistributionSellTimingEvent.lua  /  FS25 Distribution Redux
--
-- Multiplayer sync for a single per-asset (placeable, fillType, bestPrice)
-- sell-timing override. Direct mirror of DistributionModeEvent, but the payload
-- is one bool (true = sell at best price, false = sell immediately) instead of a
-- mode. nil ("follow global default") is never sent: the UI toggle always writes
-- an explicit true/false.
--   - a player flips the toggle -> SmartDistribution.applyAssetSellTiming sends
--   - client sends to server; server applies + broadcasts to every client
--   - on the receiving side run() applies with noEventSend so it never echoes
-- ============================================================================

DistributionSellTimingEvent = {}
local DistributionSellTimingEvent_mt = Class(DistributionSellTimingEvent, Event)
InitEventClass(DistributionSellTimingEvent, "DistributionSellTimingEvent")   -- register network id

function DistributionSellTimingEvent.emptyNew()
    return Event.new(DistributionSellTimingEvent_mt)
end

function DistributionSellTimingEvent.new(placeable, fillTypeIndex, bestPrice)
    local self = DistributionSellTimingEvent.emptyNew()
    self.placeable     = placeable
    self.fillTypeIndex = fillTypeIndex
    self.bestPrice     = bestPrice and true or false
    return self
end

function DistributionSellTimingEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteUIntN(streamId, self.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
    streamWriteBool(streamId, self.bestPrice)
end

function DistributionSellTimingEvent:readStream(streamId, connection)
    self.placeable     = NetworkUtil.readNodeObject(streamId)
    self.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
    self.bestPrice     = streamReadBool(streamId)
    self:run(connection)
end

function DistributionSellTimingEvent:run(connection)
    -- received on the server from a client: relay to the other clients
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection)
    end
    if self.placeable ~= nil and SmartDistribution ~= nil and SmartDistribution.applyAssetSellTiming ~= nil then
        SmartDistribution.applyAssetSellTiming(self.placeable, self.fillTypeIndex, self.bestPrice, true) -- noEventSend
    end
end

function DistributionSellTimingEvent.sendEvent(placeable, fillTypeIndex, bestPrice, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(DistributionSellTimingEvent.new(placeable, fillTypeIndex, bestPrice))
        elseif g_client ~= nil then
            g_client:getServerConnection():sendEvent(DistributionSellTimingEvent.new(placeable, fillTypeIndex, bestPrice))
        end
    end
end
