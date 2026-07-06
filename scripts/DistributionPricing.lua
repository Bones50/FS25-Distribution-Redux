-- ============================================================================
-- DistributionPricing.lua  (Distribution Redux)
-- Reads FS25's deterministic seasonal price curve to answer "is now the best
-- month to sell fill type X?" for the best-price selling feature.
--
-- Pure reader: changes no engine state. Each fill type's curve is a fixed
-- definition (it never drifts year to year), so results are cached per fill
-- type and computed once.
--
-- Confirmed via sdEconProbe on patch 1.19:
--   g_fillTypeManager.fillTypes[ft].economy.factors = { [1..12] = multiplier }
--   g_currentMission.environment.currentPeriod      = current month (1..12)
-- The factor curve is the same data the in-game price forecast graph draws.
-- ============================================================================

DistributionPricing = {}

DistributionPricing.PERIODS           = 12     -- months per year
DistributionPricing.FLAT_THRESHOLD    = 1.02   -- peak/trough under this => no real season
DistributionPricing.DEFAULT_TOLERANCE = 0.95   -- "near peak" = current factor >= 95% of peak

-- ft -> analysed curve table, or false when the fill type has no readable curve
local factorCache = {}

-- read the raw 12-entry factor curve for a fill type, or nil if unavailable
local function readFactors(ft)
    if ft == nil or g_fillTypeManager == nil then return nil end
    local desc = g_fillTypeManager.fillTypes and g_fillTypeManager.fillTypes[ft] or nil
    if desc == nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        desc = g_fillTypeManager:getFillTypeByIndex(ft)
    end
    if type(desc) ~= "table" or type(desc.economy) ~= "table" then return nil end
    local f = desc.economy.factors
    if type(f) ~= "table" then return nil end
    local out = {}
    for i = 1, DistributionPricing.PERIODS do
        local v = f[i]
        if type(v) ~= "number" then return nil end   -- not a full numeric curve
        out[i] = v
    end
    return out
end

-- build (and cache) the analysed curve: factors + peak period + flatness
local function getCurve(ft)
    local c = factorCache[ft]
    if c == false then return nil end       -- known-absent (don't re-probe each tick)
    if c ~= nil then return c end

    local factors = readFactors(ft)
    if factors == nil then
        factorCache[ft] = false
        return nil
    end
    local peak, peakVal, minVal = 1, factors[1], factors[1]
    for i = 2, DistributionPricing.PERIODS do
        if factors[i] > peakVal then peak, peakVal = i, factors[i] end
        if factors[i] < minVal then minVal = factors[i] end
    end
    local flat = (minVal <= 0) or ((peakVal / minVal) < DistributionPricing.FLAT_THRESHOLD)
    c = { factors = factors, peak = peak, peakVal = peakVal, minVal = minVal, flat = flat }
    factorCache[ft] = c
    return c
end

local function wrapPeriod(period)
    return ((period - 1) % DistributionPricing.PERIODS) + 1
end

-- current in-game month/period (1..PERIODS), or nil if not in a mission
function DistributionPricing.getCurrentPeriod()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil then return nil end
    local p = env.currentPeriod
    if type(p) == "number" then return p end
    return nil
end

-- peak period for a fill type (1..PERIODS), or nil if no curve
function DistributionPricing.getPeakPeriod(ft)
    local c = getCurve(ft)
    return c and c.peak or nil
end

-- does this fill type have a meaningful season? false => always sell immediately
function DistributionPricing.hasSeason(ft)
    local c = getCurve(ft)
    return c ~= nil and not c.flat
end

-- seasonal factor for a fill type at a period (defaults to the current period)
function DistributionPricing.getFactor(ft, period)
    local c = getCurve(ft)
    if c == nil then return nil end
    period = period or DistributionPricing.getCurrentPeriod()
    if type(period) ~= "number" then return nil end
    return c.factors[wrapPeriod(period)]
end

-- is now at/near the seasonal peak for this fill type?
-- tolerance defaults to DEFAULT_TOLERANCE. Returns true (i.e. "sell now") for a
-- flat curve, an unknown curve, or when the clock can't be read - so best-price
-- never traps goods it can't reason about.
function DistributionPricing.isPeakNow(ft, tolerance)
    local c = getCurve(ft)
    if c == nil or c.flat then return true end
    local period = DistributionPricing.getCurrentPeriod()
    if period == nil then return true end
    local cur = c.factors[wrapPeriod(period)]
    tolerance = tolerance or DistributionPricing.DEFAULT_TOLERANCE
    return cur >= (c.peakVal * tolerance)
end

-- ratio of peak price to current price for a fill type (>= 1):
-- peakPrice ~= nowPrice * (factor[peak] / factor[now]). 1 when no usable curve.
function DistributionPricing.peakRatio(ft)
    local c = getCurve(ft)
    if c == nil then return 1 end
    local period = DistributionPricing.getCurrentPeriod()
    if period == nil then return 1 end
    local cur = c.factors[wrapPeriod(period)]
    if cur == nil or cur <= 0 then return 1 end
    return c.peakVal / cur
end

-- opportunity cost per liter of selling NOW instead of at peak, given the
-- caller's current effective price per liter. = nowPrice * (peakRatio - 1),
-- clamped at >= 0 (a fill type already at/above peak costs nothing to release).
function DistributionPricing.opportunityCostPerLiter(ft, nowPricePerLiter)
    if type(nowPricePerLiter) ~= "number" then return 0 end
    local cost = nowPricePerLiter * (DistributionPricing.peakRatio(ft) - 1)
    if cost < 0 then return 0 end
    return cost
end

-- drop the cache (e.g. if the economy is reloaded). Cheap; mainly for dev.
function DistributionPricing.clearCache()
    factorCache = {}
end
