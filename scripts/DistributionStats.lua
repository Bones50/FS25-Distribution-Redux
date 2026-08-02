-- ============================================================================
-- DistributionStats.lua  (Distribution Redux)
-- Data behind the Overview tab: one row per (building, product) with Received /
-- Consumed / Held / Produced / Distributed / Stored-Moved / Sold, at three
-- timescales.
--
-- SmartDistribution.lua already keeps two of the three:
--   hour  -> S.lastCycle,  the last completed hourly pass
--   month -> monthlyRing,  a rolling 24-cycle window (24 hourly cycles = a month)
-- There was no year-scale ledger at all, so this file adds one: a rolling ring of
-- 12 MONTH BUCKETS. Each cycle is accumulated into the current bucket, and the
-- bucket advances every time the monthly window wraps -- i.e. once per month. The
-- year total is the sum of all 12, so it fills in over the first twelve in-game
-- months of a save rather than appearing complete on day one.
--
-- WHY A SEPARATE FILE: SmartDistribution.lua's main chunk sits at Lua's hard
-- 200-local-per-function ceiling (see CLAUDE.md 1.1), so the ring's state cannot
-- live there. A new file gets its own budget; the locals below are genuinely local
-- and cost the engine file nothing. It hooks in through four SmartDistribution.*
-- fields that SmartDistribution.lua calls only if present:
--   rollYearWindow / saveYearWindow / loadYearWindow / yearAggregate
-- Loads AFTER SmartDistribution.lua (see modDesc extraSourceFiles).
--
-- Server-authoritative, like every other ledger here: the hourly pass only runs on
-- the host, and clients read the aggregate the host pushes (DistributionStatsEvent).
-- ============================================================================

local YEAR_MONTHS = 12
local yearRing = {}     -- [1..YEAR_MONTHS] = uid -> ft -> { dist, sold, stored, received, money, produced, consumed }
local yearPos  = 0      -- 0-based index of the bucket currently being filled

-- every per-(asset, product) figure a cycle can carry. "loaded" / "unloaded" are the MANUAL counterparts
-- of received / distributed: product a player, helper or other mod put in or took out by hand.
-- "cost" is the distance-based haulage DR charged for moving this product OUT of this building
-- (source-side; see recordBill / chargeDistribution).
local FIELDS = { "dist", "sold", "stored", "received", "money", "produced", "consumed", "loaded", "unloaded", "cost" }

local function newEntry()
    local e = {}
    for _, f in ipairs(FIELDS) do e[f] = 0 end
    return e
end

-- ---- year ring --------------------------------------------------------------

-- Fold one completed hourly cycle into the current month bucket. monthCompleted is true on the cycle
-- that closes a month (the monthly window wrapping is what defines a month here), which advances the
-- ring and clears the bucket coming back round -- dropping the 13th month back.
function SmartDistribution.rollYearWindow(cycle, monthCompleted)
    if type(cycle) == "table" then
        local slot = (yearPos % YEAR_MONTHS) + 1
        local bucket = yearRing[slot]
        if bucket == nil then bucket = {}; yearRing[slot] = bucket end
        for uid, byFt in pairs(cycle) do
            if type(byFt) == "table" then
                local au = bucket[uid]; if au == nil then au = {}; bucket[uid] = au end
                for ft, e in pairs(byFt) do
                    if type(e) == "table" then
                        local ae = au[ft]; if ae == nil then ae = newEntry(); au[ft] = ae end
                        for _, f in ipairs(FIELDS) do ae[f] = ae[f] + (e[f] or 0) end
                    end
                end
            end
        end
    end
    if monthCompleted then
        yearPos = (yearPos + 1) % YEAR_MONTHS
        yearRing[(yearPos % YEAR_MONTHS) + 1] = nil     -- the bucket we are about to reuse starts empty
    end
end

-- The whole ring flattened to uid -> ft -> entry. Read by SmartDistribution.windowLedgers for the
-- "year" window (and so by the Overview tab and the multiplayer year push).
function SmartDistribution.yearAggregate()
    local out = {}
    for slot = 1, YEAR_MONTHS do
        local bucket = yearRing[slot]
        if type(bucket) == "table" then
            for uid, byFt in pairs(bucket) do
                local au = out[uid]; if au == nil then au = {}; out[uid] = au end
                for ft, e in pairs(byFt) do
                    local ae = au[ft]; if ae == nil then ae = newEntry(); au[ft] = ae end
                    for _, f in ipairs(FIELDS) do ae[f] = ae[f] + (e[f] or 0) end
                end
            end
        end
    end
    return out
end

-- ---- persistence (called from SmartDistribution's save/loadOverrides) --------
-- Same shape and key style as the monthly ring: fill types by NAME so the file survives a mod-order
-- change that renumbers fill-type indices.

function SmartDistribution.saveYearWindow(xml)
    if xml == nil then return end
    setXMLInt(xml, "smartDistribution.yearly#pos", yearPos)
    local mi = 0
    for slot = 1, YEAR_MONTHS do
        local bucket = yearRing[slot]
        if type(bucket) == "table" and next(bucket) ~= nil then
            local mk = string.format("smartDistribution.yearly.month(%d)", mi)
            setXMLInt(xml, mk .. "#slot", slot)
            local ei = 0
            for uid, byFt in pairs(bucket) do
                for ft, e in pairs(byFt) do
                    if type(e) == "table" then
                        local ek = string.format("%s.e(%d)", mk, ei)
                        setXMLString(xml, ek .. "#uniqueId", tostring(uid))
                        setXMLString(xml, ek .. "#fillType", SmartDistribution.fillTypeNameOf(ft))
                        for _, f in ipairs(FIELDS) do setXMLFloat(xml, ek .. "#" .. f, e[f] or 0) end
                        ei = ei + 1
                    end
                end
            end
            mi = mi + 1
        end
    end
end

function SmartDistribution.loadYearWindow(xml)
    if xml == nil then return end
    yearRing = {}
    local yp = getXMLInt(xml, "smartDistribution.yearly#pos")
    yearPos = (yp ~= nil and yp >= 0) and (yp % YEAR_MONTHS) or 0
    local mi = 0
    while true do
        local mk = string.format("smartDistribution.yearly.month(%d)", mi)
        local slot = getXMLInt(xml, mk .. "#slot")
        if slot == nil then break end
        if slot < 1 or slot > YEAR_MONTHS then slot = (mi % YEAR_MONTHS) + 1 end
        local bucket = {}
        local ei = 0
        while true do
            local ek = string.format("%s.e(%d)", mk, ei)
            local uid = getXMLString(xml, ek .. "#uniqueId")
            if uid == nil then break end
            local ft = SmartDistribution.fillTypeIndexOf(getXMLString(xml, ek .. "#fillType"))
            if ft ~= nil then
                local au = bucket[uid]; if au == nil then au = {}; bucket[uid] = au end
                local e = newEntry()
                for _, f in ipairs(FIELDS) do e[f] = getXMLFloat(xml, ek .. "#" .. f) or 0 end
                au[ft] = e
            end
            ei = ei + 1
        end
        if next(bucket) ~= nil then yearRing[slot] = bucket end
        mi = mi + 1
    end
end

-- ---- small fill-type helpers (public: the persistence above and the page use them) ----
function SmartDistribution.fillTypeNameOf(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeNameByIndex ~= nil then
        local ok, n = pcall(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, ft)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    return tostring(ft)
end

function SmartDistribution.fillTypeIndexOf(name)
    if name == nil or g_fillTypeManager == nil or g_fillTypeManager.getFillTypeIndexByName == nil then return nil end
    local ok, i = pcall(g_fillTypeManager.getFillTypeIndexByName, g_fillTypeManager, name)
    if ok then return i end
    return nil
end

local function fillTypeTitle(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
        if ok and def ~= nil and def.title ~= nil then return def.title end
    end
    return tostring(ft)
end

local function fillTypeIcon(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
        if ok and def ~= nil then return def.hudOverlayFilename or def.hudOverlayFilenameSmall end
    end
    return nil
end

-- ---- Overview rows ----------------------------------------------------------

-- Every product this building could plausibly have a figure for. Deliberately GENEROUS -- it unions the
-- input set, the configurable-output set, the husbandry output set (which is what carries egg / wool /
-- honey pallet types) and whatever the window's ledger already recorded. Over-inclusion is free: a row
-- only survives if at least one of its figures is non-zero.
local function candidateFillTypes(p, ledgerFts)
    local fts = {}
    local function addSet(t) if type(t) == "table" then for ft in pairs(t) do fts[ft] = true end end end
    local function addArr(t) if type(t) == "table" then for _, ft in ipairs(t) do fts[ft] = true end end end
    addSet(ledgerFts)
    local function trySet(fn)
        if fn == nil then return end
        local ok, t = pcall(fn, p); if ok then addSet(t) end
    end
    trySet(SmartDistribution.receiverInputFillTypes)
    trySet(SmartDistribution.assetMenuFillTypes)
    trySet(SmartDistribution.husbandryOutputSet)
    if SmartDistribution.assetProducts ~= nil then
        local ok, t = pcall(SmartDistribution.assetProducts, p)
        if ok and type(t) == "table" then addArr(t.inputs); addArr(t.outputs) end
    end
    return fts
end

-- What the building is holding of this product RIGHT NOW.
--
-- assetHeld covers silo / husbandry / shed / heap storages, but NOT a production's own buffer: it works
-- off getAllStorages, which does not reach pp.storage. Widening assetHeld itself is not safe -- the
-- seasonal crop reserve sums it across every placeable to decide farm-wide stock, so folding production
-- buffers in there would change distribution decisions. The buffer is added here instead, read exactly
-- the way the Productions tab reads it (pp.storage:getFillLevel).
--
-- This is what made bread vanish from a bakery in the Hour view: with held stuck at 0 for every
-- production, a row survived only while the window's ledger had an entry, and Hour is a single cycle --
-- so the moment nothing moved that hour the row disappeared, even with stock in the buffer.
-- Returns total, internalLitres, palletLitres. A production's output lives in its internal buffer AND on
-- its pallet spawner, and both are the building's stock -- showing only the buffer made a bakery holding
-- three pallets read as almost empty. palletFillLevel is now restricted to pallets actually sitting on
-- this building's spawner (see palletOnSpawner), so it no longer counts a neighbour's or one moved aside.
local function heldOf(p, ft)
    local internal = 0
    if SmartDistribution.assetHeld ~= nil then
        local ok, v = pcall(SmartDistribution.assetHeld, p, ft)
        if ok and type(v) == "number" then internal = internal + v end
    end
    local pp = SmartDistribution.productionPointOf ~= nil and SmartDistribution.productionPointOf(p) or nil
    local s  = pp ~= nil and pp.storage or nil
    if s ~= nil and s.getFillLevel ~= nil then
        local ok, v = pcall(s.getFillLevel, s, ft)
        if ok and type(v) == "number" then internal = internal + v end
    end
    local pallets, palletCount = 0, 0
    -- Asked for on ANY pallet-spawner building, production or pen. It is returned SEPARATELY from the
    -- internal figure so the page can show "buffer + pad" rather than one lump whose meaning depends on
    -- what is where.
    if SmartDistribution.palletLitresOf ~= nil then
        local ok, v = pcall(SmartDistribution.palletLitresOf, p, ft)
        if ok and type(v) == "number" then pallets = v end
    end
    -- assetHeld folds a PEN's pad into its total (a production's does not -- getAllStorages cannot see
    -- either pp.storage or pallets), so take it back out here to leave `internal` meaning the buffer alone.
    if p.spec_husbandryPallets ~= nil or p.spec_beehivePalletSpawner ~= nil then
        internal = internal - pallets
        if internal < 0 then internal = 0 end
    end
    -- the COUNT is asked for separately rather than derived as pallets/1000: capacity differs by fill
    -- type, and a part-filled pallet must still read as one pallet or it shows "(0p)" while standing
    -- plainly on the pad. palletCountOf returns 0 for anything that is not a pallet-spawner asset, so
    -- bulk rows are unchanged.
    if SmartDistribution.palletCountOf ~= nil then
        local ok, v = pcall(SmartDistribution.palletCountOf, p, ft)
        if ok and type(v) == "number" then palletCount = v end
    end
    return internal + pallets, internal, pallets, palletCount
end

-- Every enrolled building, with a DISPLAY NAME that is unique in the list. Rows are keyed by unique id
-- throughout -- two Grain Mills are always separate buildings with separate figures -- but by default
-- they read as two identical "Grain Mill" rows, so a name shared by more than one building gets a
-- " (n)" suffix. Numbered by unique id, not list position, so a building keeps the same number as
-- others are built, demolished or renamed, and the table never reshuffles under the player.
local function enrolledAssetsWithUniqueNames()
    local kept, byName = {}, {}
    for _, a in ipairs(SmartDistribution.enumerateConfigurableAssets()) do
        local p = a.placeable
        if p ~= nil and (SmartDistribution.isAssetEnrolled == nil or SmartDistribution.isAssetEnrolled(p)) then
            local e = {
                placeable = p,
                uid  = SmartDistribution.assetUid ~= nil and SmartDistribution.assetUid(p) or nil,
                name = a.name or "?",
                baseName = a.name or "?",     -- kept un-suffixed: this is what Grouping collapses on
                origName = a.origName,
            }
            kept[#kept + 1] = e
            local g = byName[e.name]
            if g == nil then g = {}; byName[e.name] = g end
            g[#g + 1] = e
        end
    end
    for name, group in pairs(byName) do
        if #group > 1 then
            table.sort(group, function(x, y) return tostring(x.uid) < tostring(y.uid) end)
            for i, e in ipairs(group) do e.name = string.format("%s (%d)", name, i) end
        end
    end
    return kept
end

-- ---- expected throughput + product role ------------------------------------

-- How many game HOURS each window spans, in DR's own terms: a cycle is an hour and a DR "month" is 24
-- of them (MONTHLY_CYCLES), a year twelve of those.
local WINDOW_HOURS = { hour = 1, month = 24, year = 24 * 12 }

-- What a PRODUCTION should consume and produce over the window, per fill type, from its recipes.
-- Only ENABLED lines count: a line the player switched off is expected to do nothing, while a line that
-- is on but starved keeps its expectation -- which is the whole point, that is what shows up short.
-- Scaled off cyclesPerHour, not cyclesPerMonth: the latter is the game's per-PERIOD figure and would be
-- wrong against DR's 24-hour month on a save with daysPerPeriod > 1.
-- Returns two tables (consumed, produced); both empty for anything that is not a production, so those
-- rows simply get no expectation shown rather than a made-up one.
local function expectedFlows(p, window)
    local cons, prod = {}, {}
    if SmartDistribution.productionLines == nil then return cons, prod end
    local hours = WINDOW_HOURS[window] or WINDOW_HOURS.month
    local ok, lines = pcall(SmartDistribution.productionLines, p)
    if not ok or type(lines) ~= "table" then return cons, prod end
    -- SERIAL points split one throughput budget across their active lines, so a dairy running bottled milk
    -- AND butter does NOT do 200 + 300 L/h -- it does half of each. Summing unconditionally is what showed
    -- a dairy "needing" 12,000 L/day it could never use, and painted a perfectly healthy building red.
    -- Uses the SAME divisor as the allocator's demand (SmartDistribution.throughputShare); those two
    -- disagreeing by a clean factor is exactly the trap this column set.
    local share = 1
    if SmartDistribution.throughputShare ~= nil then
        local okS, v = pcall(SmartDistribution.throughputShare, p)
        if okS and type(v) == "number" and v >= 1 then share = v end
    end
    for _, line in ipairs(lines) do
        local cph = line.enabled and ((line.cyclesPerHour or 0) / share) or 0
        if cph > 0 then
            for _, i in ipairs(line.inputs or {}) do
                if i.ft ~= nil then cons[i.ft] = (cons[i.ft] or 0) + (i.amount or 0) * cph * hours end
            end
            for _, o in ipairs(line.outputs or {}) do
                if o.ft ~= nil then prod[o.ft] = (prod[o.ft] or 0) + (o.amount or 0) * cph * hours end
            end
        end
    end
    return cons, prod
end

-- What a product IS to a building, for the "(In)" / "(Out)" / "(In/Out)" tag after its name.
-- Three shapes:
--   production / husbandry -- the recipe (or feed vs animal output) decides, and a fill type can be both
--   market                 -- only ever takes product in; a market buffer never feeds the network back
--   silo / shed / pit      -- pure storage: it both receives and supplies, so everything is In/Out
-- Returns the two sets plus which shape applies, resolved once per building.
local function roleSets(p)
    local outs, ins = {}, {}
    if SmartDistribution.internalProcessFillTypes ~= nil then
        local ok, o, i = pcall(SmartDistribution.internalProcessFillTypes, p)
        if ok and type(o) == "table" and type(i) == "table" then outs, ins = o, i end
    end
    if next(outs) ~= nil or next(ins) ~= nil then return ins, outs, "process" end
    if SmartDistribution.isMarket ~= nil and SmartDistribution.isMarket(p) then return ins, outs, "market" end
    return ins, outs, "storage"
end

-- listing order within a building: what comes in, then what is both, then what goes out
local ROLE_ORDER = { ["In"] = 1, ["In/Out"] = 2, ["Out"] = 3 }
-- ...and the REVERSE for the end-product chain, which reads downstream-first: each building shows what
-- it makes, then what it needed to make it, which is the product the NEXT building down the list supplies
local CHAIN_ROLE_ORDER = { ["Out"] = 1, ["In/Out"] = 2, ["In"] = 3 }

local function roleLabel(ft, ins, outs, kind)
    if kind == "storage" then return "In/Out" end
    if kind == "market"  then return "In" end
    local i, o = ins[ft] == true, outs[ft] == true
    if i and o then return "In/Out" end
    if o then return "Out" end
    if i then return "In" end
    return nil
end

-- every summable figure on a row; expectations are handled separately because nil (no recipe) has to
-- survive grouping rather than becoming a zero target that paints the row red
local SUMMED = { "received", "loaded", "consumed", "unloaded", "held", "produced",
                 "distributed", "stored", "sold", "money", "cost" }

-- Collapse buildings of the SAME TYPE into one row per product: two bakeries become a single
-- "Bakery x2" whose figures are the sum of both. The count is the number of enrolled buildings of that
-- name, not the number that happened to have a row for this product, so every product of a group
-- carries the same "x2" and the label does not shift between rows.
-- Expectations sum too, but only across the buildings that HAVE one -- if none does, the group keeps a
-- nil expectation and shows no target.
local function groupRows(rows, assets)
    local counts = {}
    for _, a in ipairs(assets) do counts[a.baseName] = (counts[a.baseName] or 0) + 1 end
    local byKey, out = {}, {}
    for _, r in ipairs(rows) do
        local key = tostring(r.baseName) .. "\0" .. tostring(r.ft)
        local g = byKey[key]
        if g == nil then
            g = {}
            for k, v in pairs(r) do g[k] = v end
            local n = counts[r.baseName] or 1
            g.assetName = r.baseName .. (n > 1 and (" x" .. n) or "")
            g.uid = r.baseName            -- groups sort by name; keeps a group's rows contiguous
            g.groupCount = n
            byKey[key] = g
            out[#out + 1] = g
        else
            for _, f in ipairs(SUMMED) do g[f] = (g[f] or 0) + (r[f] or 0) end
            if r.consumedExpected ~= nil then g.consumedExpected = (g.consumedExpected or 0) + r.consumedExpected end
            if r.producedExpected ~= nil then g.producedExpected = (g.producedExpected or 0) + r.producedExpected end
            -- capacity sums across the group, but only over buildings that HAVE one -- nil must survive
            -- as nil (unresolvable) rather than becoming a zero that reads as "holds nothing"
            if r.capacity ~= nil then g.capacity = (g.capacity or 0) + r.capacity end
            g.heldInternal = (g.heldInternal or 0) + (r.heldInternal or 0)
            g.heldPallets  = (g.heldPallets  or 0) + (r.heldPallets  or 0)
            g.heldPalletCount = (g.heldPalletCount or 0) + (r.heldPalletCount or 0)
            if g.role == nil then g.role = r.role end
            if g.assetIcon == nil then g.assetIcon = r.assetIcon end
            -- a group belongs to the chain if ANY of its buildings does, at the most DOWNSTREAM position
            -- any of them holds (two bakeries share a position, so this is normally just that position)
            if r.inChain then
                g.inChain = true
                if g.chainOrder == nil or (r.chainOrder ~= nil and r.chainOrder < g.chainOrder) then
                    g.chainOrder = r.chainOrder
                end
            end
        end
    end
    return out
end

-- ---- end-product chain -----------------------------------------------------

-- Everything the farm is actually MAKING right now. This is what the "End product" filter offers,
-- rather than every product in the table -- wheat and diesel in a dropdown labelled "End product" would
-- be nonsense, and so would offering a product whose production line is switched off.
--
-- Each building kind is tested by the strongest signal it has:
--   PRODUCTION -- outputs of ENABLED lines only (`line.enabled`). Deliberately NOT gated on having
--     produced anything: an enabled line sitting starved is precisely what you would open the chain to
--     diagnose, so it must stay pickable.
--   HUSBANDRY  -- no line to switch off, so the only honest signal is whether the herd HAS produced it.
--     A cow barn's output set nominally includes every milk variant, so without this test a farm with no
--     buffalo would still be offered Buffalo Milk.
-- Note the deliberate asymmetry with buildProducerIndex below, which ignores all of this: you should not
-- be able to PICK a product nobody makes, but once picked the chain must still show a paused or idle
-- intermediate step.
--
-- The husbandry test uses the MONTH window rather than literally the last cycle. Same ledger, wider
-- lens: this list is rebuilt every ~2 s, and a single-cycle test would drop any slow or intermittent
-- producer out of the dropdown the moment it had a quiet hour, moving the player's selection under them.
-- 24 cycles is stable for anything genuinely in production and still excludes what the farm never makes.
-- Returns { { ft = index, name = title }, ... } sorted by name.
function SmartDistribution.producibleProducts()
    local seen, out = {}, {}
    if SmartDistribution.enumerateConfigurableAssets == nil then return out end
    local function add(ft)
        if ft ~= nil and not seen[ft] then seen[ft] = true; out[#out + 1] = { ft = ft, name = fillTypeTitle(ft) } end
    end
    local agg = (SmartDistribution.windowAggregate ~= nil) and SmartDistribution.windowAggregate("month") or {}
    for _, a in ipairs(SmartDistribution.enumerateConfigurableAssets()) do
        local p = a.placeable
        if p ~= nil and (SmartDistribution.isAssetEnrolled == nil or SmartDistribution.isAssetEnrolled(p)) then
            local pp = (SmartDistribution.productionPointOf ~= nil) and SmartDistribution.productionPointOf(p) or nil
            if pp ~= nil then
                local ok, lines = pcall(SmartDistribution.productionLines, p)
                if ok and type(lines) == "table" then
                    for _, line in ipairs(lines) do
                        if line.enabled then
                            for _, o in ipairs(line.outputs or {}) do add(o.ft) end
                        end
                    end
                end
            else
                local ok, outs = pcall(SmartDistribution.internalProcessFillTypes, p)
                if ok and type(outs) == "table" and next(outs) ~= nil then
                    local uid  = (SmartDistribution.assetUid ~= nil) and SmartDistribution.assetUid(p) or nil
                    local byFt = uid ~= nil and agg[uid] or nil
                    for ft in pairs(outs) do
                        local e = byFt ~= nil and byFt[ft] or nil
                        if e ~= nil and (e.produced or 0) > 0 then add(ft) end
                    end
                end
            end
        end
    end
    table.sort(out, function(x, y) return tostring(x.name) < tostring(y.name) end)
    return out
end

-- Who PRODUCES what, and from which ingredients: [ft] = { { uid, ins = {ft=true} }, ... }.
-- Productions are indexed PER LINE, so a mill that also runs a sunflower->oil line does not drag
-- sunflower into the flour chain -- only lines whose OUTPUTS include the product being expanded
-- contribute their inputs. Each entry carries whether its line is switched ON; buildChainKeys is what
-- acts on that (it also needs the row list to decide), so nothing is filtered out here.
-- A husbandry has no per-line recipe, so all of its inputs feed all of its outputs (grass -> cow -> milk).
-- Returns producers plus anyEnabled[uid] -- whether that building has ANY line switched on. The pair is
-- what lets buildChainKeys tell "this building chose other lines" from "this building is paused".
local function buildProducerIndex(assets)
    local producers, anyEnabled = {}, {}
    local function add(ft, uid, ins, enabled)
        if ft == nil or uid == nil then return end
        local l = producers[ft]; if l == nil then l = {}; producers[ft] = l end
        l[#l + 1] = { uid = uid, ins = ins, enabled = enabled }
    end
    for _, a in ipairs(assets) do
        local p, uid = a.placeable, a.uid
        local pp = (p ~= nil and SmartDistribution.productionPointOf ~= nil)
            and SmartDistribution.productionPointOf(p) or nil
        if pp ~= nil then
            local ok, lines = pcall(SmartDistribution.productionLines, p)
            if ok and type(lines) == "table" then
                for _, line in ipairs(lines) do
                    local ins = {}
                    for _, i in ipairs(line.inputs or {}) do if i.ft ~= nil then ins[i.ft] = true end end
                    if line.enabled then anyEnabled[uid] = true end
                    for _, o in ipairs(line.outputs or {}) do add(o.ft, uid, ins, line.enabled == true) end
                end
            end
        elseif p ~= nil then
            local ok, outs, ins = pcall(SmartDistribution.internalProcessFillTypes, p)
            if ok and type(outs) == "table" and type(ins) == "table" and next(outs) ~= nil then
                for ft in pairs(outs) do add(ft, uid, ins, true) end   -- husbandry: no line to switch off
            end
        end
    end
    return producers, anyEnabled
end

local CHAIN_MAX_DEPTH = 12   -- insurance only; the visited set already guarantees termination

-- Every (building, product) that contributes to `target`, as keys["uid|ft"] = depth (0 = the target
-- itself, higher = further upstream). Two different inclusion rules:
--   * the SELECTED product: every row for it, anywhere -- who makes it, who stores it, who buys it
--   * anything UPSTREAM: producers and storage only, NOT other consumers
-- That second rule is what keeps a chicken coop's wheat input out of the bread chain while keeping the
-- grain mill's in: the mill qualifies because it produces something already in the chain.
-- With two bakeries, expanding BREAD walks both, so every flour source feeding either is pulled in.
--
-- A line that is switched OFF is not a way the farm makes anything, so it contributes nothing -- see
-- `contributes` below for the two escapes. Without that, a mod greenhouse carrying one line per vegetable
-- was a "producer" of every vegetable on the map, and its water / fertiliser / compost rows were dragged
-- into every chain that touched any of them, with no output row beside them to explain why.
local function buildChainKeys(target, rowsByFt, producers, anyEnabled)
    local chain = {}                                    -- [uid][ft] = depth
    anyEnabled = anyEnabled or {}
    local function mark(uid, ft, d)
        if uid == nil or ft == nil then return end
        local byFt = chain[uid]; if byFt == nil then byFt = {}; chain[uid] = byFt end
        if byFt[ft] == nil or d < byFt[ft] then byFt[ft] = d end
    end
    for _, r in ipairs(rowsByFt[target] or {}) do mark(r.uid, r.ft, 0) end   -- the selected product, everywhere

    local function hasRow(uid, ft)
        for _, r in ipairs(rowsByFt[ft] or {}) do if r.uid == uid then return true end end
        return false
    end
    -- Does this producer earn its place in the chain? Enabled lines always do. Two escapes keep the
    -- disabled ones that still matter:
    --   * a building with NO line enabled is simply PAUSED, not choosing between lines, so all of its
    --     lines still count -- a chain must not vanish because the player stopped the bakery
    --   * a disabled line still counts if the building actually HAS that product (held, or moved in this
    --     window). That stock is real and belongs in the chain whatever the line is doing.
    -- Row existence alone is deliberately NOT the whole test: a line that is running but starved produces
    -- nothing and holds nothing, and cutting its inputs would hide exactly the building worth looking at.
    local function contributes(e, ft)
        return e.enabled or not anyEnabled[e.uid] or hasRow(e.uid, ft)
    end

    local visited = {}
    local function expand(ft, d)
        if visited[ft] or d >= CHAIN_MAX_DEPTH then return end   -- visited: survives recipe loops (A->B->A)
        visited[ft] = true
        for _, prod in ipairs(producers[ft] or {}) do
            if contributes(prod, ft) then
                for ingredient in pairs(prod.ins) do
                    mark(prod.uid, ingredient, d + 1)                          -- the producer's own input row
                    for _, up in ipairs(producers[ingredient] or {}) do        -- who makes that ingredient
                        if contributes(up, ingredient) then mark(up.uid, ingredient, d + 1) end
                    end
                    for _, r in ipairs(rowsByFt[ingredient] or {}) do          -- and who stores it
                        if r.assetKind == "storage" then mark(r.uid, ingredient, d + 1) end
                    end
                    expand(ingredient, d + 1)
                end
            end
        end
    end
    expand(target, 0)
    return chain
end

-- ---- chain reading order ----------------------------------------------------
-- The chain reads DOWNSTREAM-FIRST, by BUILDING: the last place the product ends up, then back through
-- everything that fed it. For bread that is Pallet Store, Bakeries, Grain Mill, main Silo, feeder Silo.
-- Every row of a building shares its position, so a building's rows stay together.
--
-- Position is a sortable scalar built from three parts, most significant first:
--   depth -- the SHALLOWEST chain depth the building appears at (bakery holds bread(0) + flour(1) -> 0)
--   sub   -- at that depth: 0 if it only receives/stores the product, 1 if it MAKES it. That is what puts
--            the pallet store ahead of the bakery when both sit at depth 0.
--   hops  -- Move To steps to a store that forwards nowhere else in the chain. A feeder silo moving wheat
--            into the main silo is one hop upstream of it, so it reads after. Recipe depth cannot separate
--            those two: both merely hold wheat.
local CHAIN_MOVE_MAX = 8   -- cycle cap for the Move To walk (a save can contain an existing Move To ring)

local function chainBuildingOrder(chain, producers)
    local order = {}
    -- depth + sub
    for uid, byFt in pairs(chain) do
        local md
        for _, d in pairs(byFt) do if md == nil or d < md then md = d end end
        md = md or 0
        local makes = false
        for ft, d in pairs(byFt) do
            if d == md and not makes then
                for _, e in ipairs(producers[ft] or {}) do
                    if e.uid == uid then makes = true; break end
                end
            end
        end
        order[uid] = { depth = md, sub = makes and 1 or 0, hops = 0 }
    end

    -- hops: Move To edges between two buildings that are both in the chain
    if SmartDistribution.moveToActiveEdges ~= nil then
        local fts, out = {}, {}
        for _, byFt in pairs(chain) do for ft in pairs(byFt) do fts[ft] = true end end
        for ft in pairs(fts) do
            local ok, edges = pcall(SmartDistribution.moveToActiveEdges, ft)
            if ok and type(edges) == "table" then
                for src, dests in pairs(edges) do
                    if chain[src] ~= nil then
                        for dest in pairs(dests) do
                            if chain[dest] ~= nil and dest ~= src then
                                local o = out[src]; if o == nil then o = {}; out[src] = o end
                                o[dest] = true
                            end
                        end
                    end
                end
            end
        end
        local function hopsFrom(uid, seen, d)
            local o = out[uid]
            if o == nil or d >= CHAIN_MOVE_MAX then return 0 end
            local best = 0
            for dest in pairs(o) do
                if not seen[dest] then
                    seen[dest] = true
                    local h = 1 + hopsFrom(dest, seen, d + 1)
                    if h > best then best = h end
                    seen[dest] = nil
                end
            end
            return best
        end
        for uid in pairs(order) do
            order[uid].hops = hopsFrom(uid, { [uid] = true }, 0)
        end
    end

    local out2 = {}
    for uid, o in pairs(order) do out2[uid] = o.depth * 1000000 + o.sub * 1000 + o.hops end
    return out2
end

-- How much of this product the building can hold, for the bracket beside HELD.
--
-- For anything the building RECEIVES, that is not the raw tank size but what it will actually accept:
-- the Advanced Inputs "Max in" percentage applied to its capacity share, or 0 when the product is
-- blocked. inputEffectiveMaxLiters is the engine's own answer to that question -- the same figure
-- inputAcceptableLiters enforces during the pass -- so the number shown is what will really fit rather
-- than a nominal capacity the building would refuse.
-- Silo / shed products are In/Out and DO have an input cap (Advanced Inputs applies to any receiver),
-- so they take the same path. Pure outputs fall back to raw storage capacity.
-- Returns nil when nothing can be resolved, so the caller shows held alone rather than inventing a cap.
local function capacityOf(p, ft, role, held)
    if p == nil or ft == nil then return nil end
    -- the building's real tank for this product, used as the fallback below
    local raw = nil
    if SmartDistribution.outputCapacityTotal ~= nil then
        local ok, c = pcall(SmartDistribution.outputCapacityTotal, p, ft)
        if ok and type(c) == "number" and c > 0 and c < math.huge then raw = c end
    end
    if role == "In" or role == "In/Out" then
        local uid = (SmartDistribution.assetUid ~= nil) and SmartDistribution.assetUid(p) or nil
        if uid ~= nil and SmartDistribution.isInputBlocked ~= nil and SmartDistribution.isInputBlocked(uid, ft) then
            return 0                                             -- blocked: it will take nothing
        end
        if SmartDistribution.inputEffectiveMaxLiters ~= nil then
            local ok, v = pcall(SmartDistribution.inputEffectiveMaxLiters, p, ft)
            if ok and type(v) == "number" and v >= 0 and v < math.huge then
                -- On a POOLED store, a product sitting over its even share makes inputEffectiveMaxLiters
                -- return the held level itself ("the limit rises to match what is actually piled there").
                -- Correct for the allocator, useless as a denominator -- every product of a multi-fruit
                -- silo would read "58,597 (58,597)". Fall back to the silo's real capacity there.
                if raw ~= nil and held ~= nil and v <= held + 0.5 and v < raw then return raw end
                return v
            end
        end
    end
    return raw
end

-- ---- advanced-settings view -------------------------------------------------
-- The Overview's second face: the SAME rows, with the flow figures swapped for the Advanced Inputs /
-- Advanced Outputs configuration sitting behind them. Row parity is the point -- toggling the view must
-- never change which rows are listed, only what is written in them -- so this is a pure per-row enrichment
-- and the inclusion rule above is untouched.
--
-- Computed only when the view is on (`withSettings`), and only for the SIDE a row actually plays: an
-- input-only row never resolves output destinations, which is the expensive half.
local function settingsFor(p, ft, role)
    if p == nil or ft == nil then return nil end
    local SD = SmartDistribution
    local uid = (SD.assetUid ~= nil) and SD.assetUid(p) or nil
    local s = {}
    if role == "In" or role == "In/Out" then
        local pool = (SD.pooledInputCapacity ~= nil) and SD.pooledInputCapacity(p) or nil
        if pool ~= nil and type(pool.fts) == "table" then
            for _, f in ipairs(pool.fts) do if f == ft then s.pooled = true; break end end
        end
        s.blocked   = uid ~= nil and SD.isInputBlocked ~= nil and SD.isInputBlocked(uid, ft) or false
        s.pct       = (SD.inputCapPct ~= nil) and SD.inputCapPct(p, ft) or nil
        s.maxL      = (SD.inputEffectiveMaxLiters ~= nil) and SD.inputEffectiveMaxLiters(p, ft) or nil
        s.inHeld    = (SD.inputHeldLevel ~= nil) and SD.inputHeldLevel(p, ft) or nil
        s.explicit  = uid ~= nil and SD.hasExplicitInputCapPct ~= nil and SD.hasExplicitInputCapPct(uid, ft) or false
        s.targetPct = uid ~= nil and SD.getInputTargetPct ~= nil and SD.getInputTargetPct(uid, ft) or nil
        s.targetL   = (SD.inputTargetLiters ~= nil) and SD.inputTargetLiters(p, ft) or nil
        s.inStatus  = uid ~= nil and SD.inputLinkStatus ~= nil and SD.inputLinkStatus(uid, ft) or nil
        -- drives the "nearing the cap" highlight. Measured against maxL (the EFFECTIVE ceiling the
        -- allocator enforces), not the raw tank, so it means the same thing the Advanced Inputs dialog does.
        if type(s.maxL) == "number" and s.maxL > 0 and type(s.inHeld) == "number" then
            s.fillRatio = s.inHeld / s.maxL
        end
        s.isIn = true
    end
    if role == "Out" or role == "In/Out" then
        s.reserve = (SD.outputReserveLiters ~= nil) and SD.outputReserveLiters(p, ft) or nil
        local pr   = (SD.control ~= nil) and SD.control.priority or nil
        local list = (pr ~= nil and uid ~= nil and pr[uid] ~= nil) and pr[uid][ft] or nil
        s.ranked = (type(list) == "table") and #list or 0
        -- outputDestinationsForMode returns the destinations relevant to this product's CURRENT mode, each
        -- carrying .blocked, and deliberately mirrors DistributionAdvancedDialog -- so "3/5" here is the
        -- same set of destinations the Advanced Outputs dialog lists, not a second opinion.
        local dests = (SD.outputDestinationsForMode ~= nil) and SD.outputDestinationsForMode(p, ft) or nil
        if type(dests) == "table" then
            local n = 0
            for _, d in ipairs(dests) do if not d.blocked then n = n + 1 end end
            s.destTotal, s.destActive = #dests, n
        end
        s.outStatus = (SD.outputLinkStatus ~= nil) and SD.outputLinkStatus(p, ft) or nil
        -- "1/4" -- lines SWITCHED ON that make this product, of all lines that could. Nil for anything
        -- with no production lines (silo, pen, market), which the page renders as a dash.
        if SD.outputLineCounts ~= nil then s.lineOn, s.lineTotal = SD.outputLineCounts(p, ft) end
        -- Routing mode, resolved the way DistributionAdvancedDialog does it: a PRODUCTION's output runs on
        -- the v-mode enum (Keep / Distribute / ...), everything else on the asset MODE enum. Pallet-aware,
        -- so a coop's EGG row reads "Hold Pallets" where its MANURE row reads "Hold" (5.22).
        local pp = (SD.productionPointOf ~= nil) and SD.productionPointOf(p) or nil
        if pp ~= nil and SD.productionOutputVMode ~= nil and SD.productionOutputVModeName ~= nil then
            local v = SD.productionOutputVMode(pp, ft)
            s.mode = (v ~= nil) and SD.productionOutputVModeName(v) or nil
        elseif SD.modeName ~= nil and SD.resolvedAssetMode ~= nil then
            local pal = (SD.holdLabelFlag ~= nil) and SD.holdLabelFlag(p, ft) or nil
            s.mode = SD.modeName(SD.resolvedAssetMode(p, ft), pal)
        end
        s.isOut = true
    end
    return s
end

-- One row per (enrolled building, product) with any figure to show, for the Overview tab.
-- window = "hour" | "month" | "year". HELD is deliberately a live stock reading, not a windowed flow:
-- it is what the building is holding right now, whichever timescale the other columns are showing.
-- Rows with nothing at all -- no flow in the window and nothing held -- are dropped, or a multi-fruit
-- silo alone would contribute thirty empty rows.
-- grouped = true collapses same-type buildings (see groupRows).
-- chainFt = a fill type: tag each row with inChain / chainDepth for the "End product" filter. Tagging
-- happens BEFORE grouping, because grouping rewrites uid to the base name and the keys stop matching.
-- withSettings = also resolve each row's Advanced Inputs / Outputs configuration into row.settings, for the
-- Overview's settings view. NOT compatible with `grouped` -- settings are per building and a "Bakery x2" row
-- has no single answer -- so the page forces grouping off while that view is on.
function SmartDistribution.overviewRows(window, grouped, chainFt, withSettings)
    local rows, rowsByFt = {}, {}
    if SmartDistribution.enumerateConfigurableAssets == nil or SmartDistribution.windowAggregate == nil then
        return rows
    end
    local agg = SmartDistribution.windowAggregate(window)
    local assets = enrolledAssetsWithUniqueNames()
    for _, a in ipairs(assets) do
        local p, uid = a.placeable, a.uid
        local byFt = uid ~= nil and agg[uid] or nil
        local icon = SmartDistribution.assetIconFile ~= nil and SmartDistribution.assetIconFile(p) or nil
        local expCons, expProd = expectedFlows(p, window)      -- resolved once per building, not per row
        local ins, outs, kind   = roleSets(p)
        for ft in pairs(candidateFillTypes(p, byFt)) do
            local e = byFt ~= nil and byFt[ft] or nil
            local function v(field) return (e ~= nil and e[field]) or 0 end
            local held, heldInternal, heldPallets, heldPalletCount = heldOf(p, ft)
            local roleTag = roleLabel(ft, ins, outs, kind)
            local row = {
                -- carried for the row double-click (jump to this building's tab). groupRows copies every
                -- field from the FIRST row of a group, so a grouped row lands on one of its buildings
                -- rather than nowhere -- which is the useful answer for "Bakery x2".
                placeable = p,
                uid = uid, ft = ft,
                assetName = a.name or "?", baseName = a.baseName or a.name or "?",
                assetOrigName = a.origName, assetIcon = icon,
                product = fillTypeTitle(ft), productIcon = fillTypeIcon(ft),
                role = roleTag, assetKind = kind,
                capacity = capacityOf(p, ft, roleTag, held),
                received = v("received"), loaded   = v("loaded"),
                consumed = v("consumed"), unloaded = v("unloaded"),
                held = held, heldInternal = heldInternal, heldPallets = heldPallets,
                heldPalletCount = heldPalletCount,
                produced = v("produced"),
                distributed = v("dist"), stored = v("stored"), sold = v("sold"), money = v("money"),
                cost = v("cost"),
                -- nil (not 0) when there is no recipe expectation, so the page knows to leave the cell
                -- plain rather than painting a row red for a building that simply has no target
                consumedExpected = expCons[ft], producedExpected = expProd[ft],
                settings = withSettings and settingsFor(p, ft, roleTag) or nil,
            }
            -- SETTINGS VIEW: keep EVERY input and output the building has, whether or not anything moved.
            -- A cap, reserve or block set on a product that has not arrived yet is exactly what that view
            -- is opened to check, and the activity test would hide precisely those rows. Only "Filter by"
            -- narrows it from there.
            -- roleTag is nil for a fill type that is neither an input nor an output of THIS building, so
            -- this stays a genuine in/out list rather than everything the building could conceivably hold.
            -- The flow view keeps the original test: without it a multifruit silo alone contributes ~30
            -- all-dashes rows, which is the whole reason that rule exists.
            if (withSettings and roleTag ~= nil)
               or held > 0 or row.received > 0 or row.loaded > 0 or row.consumed > 0 or row.unloaded > 0
               or row.produced > 0 or row.distributed > 0 or row.stored > 0 or row.sold > 0
               or row.money > 0 or row.cost > 0 then
                rows[#rows + 1] = row
                local l = rowsByFt[ft]; if l == nil then l = {}; rowsByFt[ft] = l end
                l[#l + 1] = row
            end
        end
    end

    -- end-product chain: tag before grouping, while rows still carry real unique ids
    if chainFt ~= nil then
        local producers, anyEnabled = buildProducerIndex(assets)
        local chain = buildChainKeys(chainFt, rowsByFt, producers, anyEnabled)
        local order = chainBuildingOrder(chain, producers)
        for _, r in ipairs(rows) do
            local byFt = chain[r.uid]
            local d = byFt ~= nil and byFt[r.ft] or nil
            r.inChain    = d ~= nil
            r.chainOrder = d ~= nil and order[r.uid] or nil   -- per BUILDING: all its rows share it
        end
    end

    if grouped then rows = groupRows(rows, assets) end
    -- Chain view reads DOWNSTREAM FIRST, by building: the last place the product ends up, then back
    -- through everything that fed it (pallet store, bakeries, mill, main silo, feeder silo). Within a
    -- building the order is REVERSED from the default -- outputs above inputs -- so each building reads
    -- "what it makes, then what it needed", and that need is what the next building down the list supplies.
    if chainFt ~= nil then
        table.sort(rows, function(x, y)
            local ox, oy = x.chainOrder or math.huge, y.chainOrder or math.huge
            if ox ~= oy then return ox < oy end
            if x.assetName ~= y.assetName then return tostring(x.assetName) < tostring(y.assetName) end
            if x.uid ~= y.uid then return tostring(x.uid) < tostring(y.uid) end
            local rx = CHAIN_ROLE_ORDER[x.role] or 4
            local ry = CHAIN_ROLE_ORDER[y.role] or 4
            if rx ~= ry then return rx < ry end
            return tostring(x.product) < tostring(y.product)
        end)
        return rows
    end
    -- Grouped by building (uniqueId is the tiebreak, so one building's rows always stay contiguous even
    -- if two somehow share a display name), then INPUTS FIRST and outputs last -- the order product
    -- actually flows through the building. Anything that is both sits between the two.
    table.sort(rows, function(x, y)
        if x.assetName ~= y.assetName then return tostring(x.assetName) < tostring(y.assetName) end
        if x.uid ~= y.uid then return tostring(x.uid) < tostring(y.uid) end
        local rx = ROLE_ORDER[x.role] or 4
        local ry = ROLE_ORDER[y.role] or 4
        if rx ~= ry then return rx < ry end
        return tostring(x.product) < tostring(y.product)
    end)
    return rows
end
