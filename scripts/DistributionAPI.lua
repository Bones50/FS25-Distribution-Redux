-- ============================================================================
-- DistributionAPI.lua  (Distribution Redux)
--
-- The public extension surface other mods build on. Currently one thing: a mod
-- may supply the FEED PLAN for a husbandry -- which products, and how many
-- litres of each, DR should route into its food pool this pass.
--
-- WHY A SEPARATE FILE: SmartDistribution.lua's main chunk sits at Lua's hard
-- 200-local ceiling (CLAUDE.md 1.1), so this cannot live there. Same reasoning
-- as DistributionStats.lua. It must load AFTER SmartDistribution.lua (see
-- modDesc extraSourceFiles) because it hangs fields off that table.
--
-- IT DOES NOTHING UNLESS SOMETHING IS PLUGGED INTO IT, and that is layered
-- rather than promised:
--   1. `collectFoodSlots` already returns on its first line when
--      `feedHusbandryEnabled` is off, so the hook is NEVER REACHED on a farm
--      that is not auto-feeding animals.
--   2. `isEnrolled` is false for a husbandry when `includeHusbandry` is off, so
--      those buildings are skipped before the hook too.
--   3. With no provider registered, `feedPlanFor` returns nil on a single
--      numeric test and the original best-quality-first path runs BYTE FOR
--      BYTE as before.
-- So on a stock install this file costs one comparison per husbandry per hour
-- and changes nothing.
--
-- CONTRACT
--   SmartDistribution.API.VERSION                    -- integer, bumped on any
--                                                       breaking change
--   SmartDistribution.API.registerFeedPlanner(name, fn)
--   SmartDistribution.API.unregisterFeedPlanner(name)
--
--   fn(placeable, allowedFillTypes, poolNeed) -> { [fillTypeIndex] = litres } | nil
--
--     placeable         the husbandry
--     allowedFillTypes  array of fill types DR will accept here THIS pass --
--                       already filtered for the excluded list, water, and any
--                       product the player blocked in Advanced Inputs. A plan
--                       may only name these; anything else is dropped.
--     poolNeed          litres DR wants to add to the pool this pass
--     return            absolute litres per fill type, or nil to DECLINE and
--                       leave DR's own behaviour in place
--
-- A planner is called INSIDE the hourly pass, so it must be cheap and must not
-- write game state. It is pcall'd, and one that throws three times is struck
-- out for the session rather than breaking the pass every hour.
-- ============================================================================

if SmartDistribution == nil then
    print("[SmartDistribution] DistributionAPI: SmartDistribution missing; extension API NOT installed "
        .. "(check extraSourceFiles order -- this file must load AFTER SmartDistribution.lua)")
    return
end

SmartDistribution.API = SmartDistribution.API or {}
SmartDistribution.API.VERSION = 1

-- name -> { fn = function, strikes = n }. Kept as an ARRAY too, so call order is
-- registration order and therefore predictable rather than pairs()-random.
SmartDistribution._feedPlanners = SmartDistribution._feedPlanners or {}

local MAX_STRIKES = 3

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[SmartDistribution API] " .. (ok and msg or tostring(fmt)))
end

-- ---------------------------------------------------------------------------
---Register a feed planner. `name` identifies the mod and replaces any previous
-- registration under the same name (so a reload does not stack duplicates).
function SmartDistribution.API.registerFeedPlanner(name, fn)
    if type(name) ~= "string" or name == "" or type(fn) ~= "function" then
        log("registerFeedPlanner refused: needs (string name, function fn)")
        return false
    end
    local list = SmartDistribution._feedPlanners
    for i, entry in ipairs(list) do
        if entry.name == name then
            list[i] = { name = name, fn = fn, strikes = 0 }
            log("feed planner '%s' re-registered", name)
            return true
        end
    end
    list[#list + 1] = { name = name, fn = fn, strikes = 0 }
    if #list > 1 then
        -- Not an error, but worth saying out loud: two mods planning the same
        -- trough is a configuration the player did not ask for, and the winner
        -- would otherwise be silent.
        log("feed planner '%s' registered (%d planners now; the FIRST to return "
            .. "a plan wins, in registration order)", name, #list)
    else
        log("feed planner '%s' registered", name)
    end
    return true
end

function SmartDistribution.API.unregisterFeedPlanner(name)
    local list = SmartDistribution._feedPlanners
    for i, entry in ipairs(list) do
        if entry.name == name then
            table.remove(list, i)
            log("feed planner '%s' unregistered", name)
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
---Validate and normalise a planner's answer. Returns a clean table, or nil.
-- A planner is third-party code running inside the hourly pass, so its output is
-- treated as a REQUEST, never as fact: unknown fill types are dropped, junk
-- values are rejected outright, and a plan asking for more than DR offered is
-- scaled down rather than allowed to over-fill the pool.
local function sanitisePlan(plan, allowed, poolNeed, who)
    if type(plan) ~= "table" then return nil end

    local ok = {}
    for _, ft in ipairs(allowed) do ok[ft] = true end

    local out, total, badValue, notAllowed = {}, 0, 0, 0
    for ft, litres in pairs(plan) do
        if type(ft) ~= "number" or type(litres) ~= "number"
           or litres ~= litres                       -- NaN
           or litres == math.huge or litres < 0 then
            badValue = badValue + 1
        elseif not ok[ft] then
            notAllowed = notAllowed + 1              -- blocked / excluded / not accepted here
        elseif litres > 0 then
            out[ft] = litres
            total = total + litres
        end
    end

    -- Reported separately because they mean different things and point at
    -- different bugs: a rejected VALUE is the planner miscalculating, while a
    -- disallowed FILL TYPE usually means it ignored the allowed list it was
    -- handed -- most often a product the player blocked in Advanced Inputs.
    if badValue > 0 then
        log("planner '%s': %d entr%s rejected for an unusable value (nan/inf/negative)",
            who, badValue, badValue == 1 and "y was" or "ies were")
    end
    if notAllowed > 0 then
        log("planner '%s': %d fill type(s) dropped, not accepted by this building "
            .. "(blocked, excluded, or not a food it takes)", who, notAllowed)
    end
    if total <= 0 then return nil end

    -- Never let a plan exceed what DR asked for: the pool would simply refuse
    -- the surplus at deposit time, but the slots would have competed for
    -- sources they were never going to use.
    if total > poolNeed then
        local scale = poolNeed / total
        for ft, litres in pairs(out) do out[ft] = litres * scale end
    end
    return out
end

-- ---------------------------------------------------------------------------
---Ask the registered planners what this husbandry's food pool should receive.
-- Returns nil when there is nothing plugged in, when every planner declines, or
-- when a plan does not survive validation -- and nil means "DR does what it has
-- always done".
function SmartDistribution.feedPlanFor(placeable, allowedFillTypes, poolNeed)
    local list = SmartDistribution._feedPlanners
    -- COST, not correctness: with an empty registry the loop below cannot execute
    -- and the function returns nil regardless, so behaviour is identical either
    -- way. This exists so a stock install pays one length check per husbandry per
    -- hour instead of three type checks it can never act on. (Verified by removing
    -- it -- tools/feedapi.lua still passed 37/37, which is what proves the claim
    -- is about speed rather than semantics.)
    if #list == 0 then return nil end
    if placeable == nil or allowedFillTypes == nil or #allowedFillTypes == 0 then return nil end
    if type(poolNeed) ~= "number" or poolNeed <= 0 then return nil end

    for _, entry in ipairs(list) do
        if entry.strikes < MAX_STRIKES then
            local ok, plan = pcall(entry.fn, placeable, allowedFillTypes, poolNeed)
            if not ok then
                entry.strikes = entry.strikes + 1
                log("feed planner '%s' threw (%d/%d): %s", entry.name, entry.strikes,
                    MAX_STRIKES, tostring(plan))
                if entry.strikes >= MAX_STRIKES then
                    log("feed planner '%s' STRUCK OUT for this session; DR's own feed logic "
                        .. "is in use for every husbandry from now on", entry.name)
                end
            elseif plan ~= nil then
                local clean = sanitisePlan(plan, allowedFillTypes, poolNeed, entry.name)
                if clean ~= nil then return clean end
            end
        end
    end
    return nil
end

print("[SmartDistribution] extension API v" .. tostring(SmartDistribution.API.VERSION) .. " available")
