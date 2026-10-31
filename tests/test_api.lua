local function api()
    return sandbox({'DistributionAPI'}, {SmartDistribution = {}, print = function() end}).SmartDistribution
end

test('feed API: no provider and invalid registration', function()
    local s = api()
    eq(s.feedPlanFor({}, {1}, 100), nil)
    eq(s.API.registerFeedPlanner('', function() end), false)
    eq(s.API.registerFeedPlanner('bad', 1), false)
end)
test('feed API: filters blocked types and scales to capacity', function()
    local s = api()
    s.API.registerFeedPlanner('test', function() return {[1]=100, [2]=300, [3]=900} end)
    local plan = s.feedPlanFor({}, {1,2}, 100)
    local amounts = {}
    for _, entry in ipairs(plan) do amounts[entry.fillTypes[1]] = entry.litres end
    near(amounts[1], 25); near(amounts[2], 75); eq(amounts[3], nil)
end)
test('feed API: ordered alternatives preserve order and exclude blocked feed', function()
    local s = api()
    s.API.registerFeedPlanner('test', function()
        return {{fillTypes={3,2,1}, litres=50, ordered=true}}
    end)
    local entry = s.feedPlanFor({}, {1,2}, 100)[1]
    eq(table.concat(entry.fillTypes, ','), '2,1'); eq(entry.ordered, true); eq(entry.litres, 50)
end)
test('feed API: rejects invalid quantities and falls back to next provider', function()
    local s = api()
    s.API.registerFeedPlanner('bad', function() return {[1]=0/0, [2]=math.huge, [3]=-1} end)
    s.API.registerFeedPlanner('good', function() return {[1]=10} end)
    eq(s.feedPlanFor({}, {1,2,3}, 100)[1].litres, 10)
end)
test('feed API: failing provider disabled after three errors; re-register resets it', function()
    local s, calls = api(), 0
    s.API.registerFeedPlanner('broken', function() calls=calls+1; error('broken') end)
    for i=1,5 do eq(s.feedPlanFor({}, {1}, 100), nil) end
    eq(calls, 3)
    s.API.registerFeedPlanner('broken', function() return {[1]=5} end)
    eq(#s._feedPlanners, 1); eq(s.feedPlanFor({}, {1}, 100)[1].litres, 5)
    eq(s.API.unregisterFeedPlanner('broken'), true)
    eq(s.API.unregisterFeedPlanner('broken'), false)
end)
