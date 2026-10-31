local function pricing(curve)
    local env = sandbox({'DistributionPricing'}, {
        g_fillTypeManager = {fillTypes = {[1] = {economy = {factors = curve}}}},
        g_currentMission = {environment = {currentPeriod = 1}}
    })
    return env.DistributionPricing, env
end
local function seasonal() return {1, 1.5, 2, 1.9, 1, 1, 1, 1, 1, 1, 1, 1} end

test('pricing: peak, tolerance, ratio and opportunity cost', function()
    local p, env = pricing(seasonal())
    eq(p.getPeakPeriod(1), 3); eq(p.hasSeason(1), true)
    eq(p.isPeakNow(1), false); eq(p.peakRatio(1), 2)
    eq(p.opportunityCostPerLiter(1, 4), 4)
    eq(p.opportunityCostPerLiter(1, -4), 0)
    env.g_currentMission.environment.currentPeriod = 4
    eq(p.isPeakNow(1), true); eq(p.isPeakNow(1, 1), false)
end)
test('pricing: periods wrap across year boundaries', function()
    local p = pricing(seasonal())
    eq(p.getFactor(1, 15), 2); eq(p.getFactor(1, 0), 1)
end)
test('pricing: flat and incomplete curves allow immediate sale', function()
    local p = pricing({1,1,1,1,1,1,1,1,1,1,1,1})
    eq(p.hasSeason(1), false); eq(p.isPeakNow(1), true)
    p = pricing({1,2})
    eq(p.getPeakPeriod(1), nil); eq(p.isPeakNow(1), true)
end)
test('pricing: unknown and nil fill types use safe defaults', function()
    local p = pricing(seasonal())
    for _, ft in ipairs({999, false}) do
        local value = ft or nil
        eq(p.getPeakPeriod(value), nil); eq(p.hasSeason(value), false)
        eq(p.getFactor(value), nil); eq(p.isPeakNow(value), true)
        eq(p.peakRatio(value), 1)
    end
end)
test('pricing: missing clock allows immediate sale', function()
    local p, env = pricing(seasonal())
    -- A missing mission is represented by nil in the engine.
    env.g_currentMission = nil
    eq(p.isPeakNow(1), true); eq(p.peakRatio(1), 1)
end)
test('pricing: clearing cache picks up a changed curve', function()
    local curve = seasonal()
    local p = pricing(curve)
    eq(p.getPeakPeriod(1), 3)
    curve[8] = 3
    eq(p.getPeakPeriod(1), 3)
    p.clearCache(); eq(p.getPeakPeriod(1), 8)
end)
