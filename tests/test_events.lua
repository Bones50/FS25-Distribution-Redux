local definitions = {
    {'DistributionModeEvent', 'applyAssetMode', 'setAssetMode', 8},
    {'DistributionSellTimingEvent', 'applyAssetSellTiming', 'setAssetSellTiming', false},
    {'DistributionMarketTimingEvent', 'applyMarketTiming', 'setMarketSellMode', 2}
}
local function setup(def)
    local state = {broadcasts={}, applies={}, sets={}}
    local env = {
        Class = function(cls) return {__index=cls} end,
        Event = {new=function(mt) return setmetatable({},mt) end},
        InitEventClass = function() end,
        FillTypeManager = {SEND_NUM_BITS=10},
        NetworkUtil = {}, SmartDistribution = {},
        g_server = {broadcastEvent=function(_, event, _, connection)
            state.broadcasts[#state.broadcasts+1] = {uid=event.uid,event=event,connection=connection}
        end}
    }
    local sd = env.SmartDistribution
    sd.roleUid = function(p, role) return p.uid .. (role and ':' .. role or '') end
    sd.assetUid = function(p) return p.uid end
    sd[def[2]] = function(...) state.applies[#state.applies+1]={...} end
    sd[def[3]] = function(...) state.sets[#state.sets+1]={...} end
    local function write(stream, value, bits)
        if bits then assert(value >= 0 and value < 2^bits and value % 1 == 0) end
        stream[#stream+1]= {value=value,bits=bits}
    end
    local function read(stream, bits)
        stream.pos=(stream.pos or 0)+1
        local entry=assert(stream[stream.pos], 'stream underflow')
        eq(entry.bits,bits)
        return entry.value
    end
    env.NetworkUtil.writeNodeObject=write; env.NetworkUtil.readNodeObject=read
    env.streamWriteUIntN=write; env.streamReadUIntN=read
    env.streamWriteString=write; env.streamReadString=read
    env.streamWriteBool=write; env.streamReadBool=read
    sandbox({def[1]},env)
    return env[def[1]],state
end
local fromClient = {getIsServer=function() return false end}
local fromServer = {getIsServer=function() return true end}

for _, definition in ipairs(definitions) do
    local def = definition
    test(def[1] .. ': stream round trip and client UID replay without node', function()
        local cls,state=setup(def)
        local event=cls.new({uid='server'}, 1023, def[4], 'storage')
        event.placeable=nil -- joining client has not loaded the node yet
        local stream={}
        event:writeStream(stream,fromServer)
        local received=cls.emptyNew()
        received:readStream(stream,fromServer)
        eq(received.uid,event.uid); eq(received.fillTypeIndex,1023)
        eq(state.sets[1][1],event.uid); eq(state.sets[1][3],def[4])
        eq(#state.broadcasts,0)
    end)
    test(def[1] .. ': server relays authoritative UID, preserving role and value', function()
        local cls,state=setup(def)
        local placeable={uid='server'}
        local event=cls.new(placeable, 1, def[4], 'storage')
        local expected=event.uid
        event.uid='client-local-uid'
        event:run(fromClient)
        eq(#state.applies,1); eq(state.applies[1][1],placeable)
        eq(state.applies[1][3],def[4]); eq(state.applies[1][4],true)
        if def[1] ~= "DistributionMarketTimingEvent" then
            eq(state.applies[1][5], "storage")
            eq(state.broadcasts[1].event.role, "storage")
        end
        eq(#state.broadcasts,1); eq(state.broadcasts[1].uid,expected)
        eq(state.broadcasts[1].connection,fromClient)
    end)
    test(def[1] .. ': server does not relay unresolved client objects', function()
        local cls,state=setup(def)
        local event=cls.new(nil, 1, def[4])
        event.uid='untrusted-uid'
        event:run(fromClient)
        eq(#state.broadcasts,0); eq(#state.applies,0)
    end)
    test(def[1] .. ': noEventSend suppresses outgoing event', function()
        local cls,state=setup(def)
        cls.sendEvent({uid='server'},1,def[4],true)
        eq(#state.broadcasts,0)
    end)
end
