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
--   SmartDistribution.API.registerHusbandryPanel(name, fn)      -- v4, v5 profit
--   SmartDistribution.API.onMenuReady / loadMenuPage / addMenuPage  -- v3, v7 badge
--   SmartDistribution.API.registerSettingsTab(modName, label, defs)   -- v8
--   SmartDistribution.API.unregisterSettingsTab(modName)              -- v8
--   SmartDistribution.API.registerHelpTab(modName, label, topics)     -- v9
--   SmartDistribution.API.unregisterHelpTab(modName)                  -- v9
--
--   fn(placeable, allowedFillTypes, poolNeed) -> plan | nil
--
--   A plan is EITHER (v2, preferred)
--       { { fillTypes = { ftA, ftB }, litres = n }, ... }
--     where each entry's fillTypes are ALTERNATIVES -- any of them satisfies that
--     request, and DR chooses by what is actually in stock and nearest. This
--     matters because a planner cannot see the farm's stock: naming one product
--     and hoping is how a pig pen starves on maize while its sorghum sits unused.
--   OR (v1, still accepted)
--       { [fillTypeIndex] = litres }
--     normalised internally to one single-alternative entry each.
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
SmartDistribution.API.VERSION = 9

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

-- ---------------------------------------------------------------------------
-- THE HUSBANDRY PANEL (API v4). A mod supplies the FACTS about a barn -- herd,
-- health, value, feed groups -- and DR draws them into a panel between the
-- INCOMING and OUTGOING tables on the Animal Husbandry tab.
--
-- DR OWNS THE LAYOUT, THE PROVIDER OWNS THE DATA, exactly as registerFeedPlanner
-- splits it. That is not tidiness: a provider that could place its own elements
-- into DR's page could break the page for everyone, and the geometry here is
-- hand-tiled to the pixel (5.55). A table of numbers cannot.
--
-- WITH NO PROVIDER REGISTERED THE TAB IS BYTE-IDENTICAL TO TODAY. The panel's
-- elements ship hidden and the two lists keep their original heights; only a
-- successful registration reflows them. So a stock install cannot be affected by
-- any of this, which is the same layering registerFeedPlanner has.
--
-- The provider is called during a GUI populate, so it is treated exactly as a
-- planner is: pcall'd, its answer validated field by field, and STRUCK OUT for
-- the session after MAX_STRIKES throws (grep the log for STRUCK OUT).
SmartDistribution._husbandryPanels = SmartDistribution._husbandryPanels or {}

function SmartDistribution.API.registerHusbandryPanel(name, fn)
    if type(name) ~= "string" or name == "" or type(fn) ~= "function" then
        log("registerHusbandryPanel refused: needs (string name, function fn)")
        return false
    end
    local list = SmartDistribution._husbandryPanels
    for i, entry in ipairs(list) do
        if entry.name == name then
            list[i] = { name = name, fn = fn, strikes = 0 }
            log("husbandry panel '%s' re-registered", name)
            return true
        end
    end
    list[#list + 1] = { name = name, fn = fn, strikes = 0 }
    -- ONE panel is drawn -- the first registration that answers, in registration
    -- order -- because there is exactly one strip of screen to draw it in. Said
    -- out loud for the same reason the planner says it: the loser would
    -- otherwise be silently absent and look like a broken mod.
    if #list > 1 then
        log("husbandry panel '%s' registered (%d now; the FIRST to answer wins, "
            .. "in registration order)", name, #list)
    else
        log("husbandry panel '%s' registered", name)
    end
    return true
end

function SmartDistribution.API.unregisterHusbandryPanel(name)
    local list = SmartDistribution._husbandryPanels
    for i, entry in ipairs(list) do
        if entry.name == name then
            table.remove(list, i)
            log("husbandry panel '%s' unregistered", name)
            return true
        end
    end
    return false
end

---Is anything registered? The page asks this ONCE at setup to decide whether to
-- reflow, so it must not depend on a particular barn answering.
function SmartDistribution.hasHusbandryPanel()
    local list = SmartDistribution._husbandryPanels
    return type(list) == "table" and #list > 0
end

-- ---------------------------------------------------------------------------
---Validate a provider's answer. EVERY field is optional and every one is checked:
-- a panel drawing a NaN or a negative litre count is worse than a panel with a
-- gap in it, and this runs per populate on data DR did not compute.
--
--   herd    = { count, max, health,                  health 0..1
--               productivity, prodApplies,           productivity 0..1
--               advice = { text, tone } }            tone good|warn|bad
--   value   = { current, potential, pastPeak }       money; potential >= current
--   profit  = { perMonth, outputs, inputs,           money PER MONTH; MAY BE
--               ageing, births, complete }           NEGATIVE, so never clamped
--   feed    = { factor, serial, activeTitle,         factor 0..1
--               advice = { text, tone },             tone good|warn|bad
--               groups = { { title, colourIndex, share, met, held, need }, ... } }
--
-- `profit` is v5 and PURELY ADDITIVE: an older DR drops it in this sanitiser and
-- draws the panel exactly as before, and a provider that does not send it leaves
-- the line blank. Neither side needs to feature-detect the other.
--
-- `serial` is the load-bearing flag and the reason this shape carries it at all.
-- For a PARALLEL animal (pig, horse, sheep, chicken) the groups SUM: each one
-- contributes production x met and the total is the factor, so a stacked bar is
-- literally the arithmetic. For a SERIAL animal (a COW) the groups are quality
-- tiers and are ALTERNATIVES -- only the best one present counts -- so stacking a
-- barn holding grass AND hay AND silage would draw 0.4 + 0.8 + 0.8 = 2.0 and be
-- nonsense. DR draws the two differently and cannot infer which is which.
local function panelNum(v, lo, hi)
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
    if lo ~= nil and v < lo then v = lo end
    if hi ~= nil and v > hi then v = hi end
    return v
end

-- AN ADVICE LINE IS PROVIDER TEXT, and that is deliberate rather than a lapse of
-- the code-and-data rule: DR draws the panel but has no vocabulary for which food
-- groups an animal type has or what a full pen destroys. `feed.activeTitle` set the
-- precedent in v4 -- the provider names the tier, DR prints it. What DR keeps is the
-- LAYOUT and the PALETTE, which is the split that matters: the tone arrives as a
-- WORD and DR maps it to a colour, so a provider can never paint on this page.
local PANEL_TONES = { good = true, warn = true, bad = true }
local function panelAdvice(v)
    if type(v) ~= "table" then return nil end
    local t = v.text
    if type(t) ~= "string" or t == "" then return nil end
    -- capped because these cells TRUNCATE rather than wrap, and a provider that
    -- sends a paragraph would silently lose the end of it either way
    if #t > 120 then t = t:sub(1, 120) end
    return { text = t, tone = PANEL_TONES[v.tone] and v.tone or nil }
end

local function sanitisePanel(d)
    if type(d) ~= "table" then return nil end
    local out = {}

    if type(d.herd) == "table" then
        out.herd = { count  = panelNum(d.herd.count, 0),
                     max    = panelNum(d.herd.max, 0),
                     health = panelNum(d.herd.health, 0, 1),
                     -- PRODUCTIVITY is the base game's own headline for a husbandry
                     -- and is NOT the food factor: food is one input to it, so a
                     -- perfectly fed barn can still sit at 15%. `prodApplies` false
                     -- means the base game hides it for this animal type (horses and
                     -- pigs), which is a different fact from "it is zero".
                     productivity = panelNum(d.herd.productivity, 0, 1),
                     prodApplies  = d.herd.prodApplies ~= false,
                     advice       = panelAdvice(d.herd.advice) }
    end
    if type(d.value) == "table" then
        local cur = panelNum(d.value.current, 0)
        local pot = panelNum(d.value.potential, 0)
        -- POTENTIAL IS A CEILING, so a provider that reports less than the herd is
        -- already worth is clamped up rather than drawn as an over-full bar.
        if cur ~= nil and pot ~= nil and pot < cur then pot = cur end
        out.value = { current = cur, potential = pot, pastPeak = d.value.pastPeak == true }
    end
    -- PROFIT IS THE ONE FIELD THAT MAY BE NEGATIVE, so it is the one field that
    -- must NOT be clamped at 0. A barn losing money is exactly what this line
    -- exists to say, and panelNum(v, 0) would have drawn every such barn as
    -- breaking even -- the "0 is a real value" trap this codebase keeps meeting
    -- (5.46c / 5.47), one field over.
    if type(d.profit) == "table" then
        out.profit = { perMonth = panelNum(d.profit.perMonth),
                       outputs  = panelNum(d.profit.outputs),
                       inputs   = panelNum(d.profit.inputs),
                       ageing   = panelNum(d.profit.ageing),
                       births   = panelNum(d.profit.births),
                       complete = d.profit.complete == true }
    end
    if type(d.feed) == "table" then
        local groups = {}
        local maxG = SmartDistribution.PANEL_MAX_GROUPS or 6
        if type(d.feed.groups) == "table" then
            for _, g in ipairs(d.feed.groups) do
                if type(g) == "table" and #groups < maxG then
                    local share = panelNum(g.share, 0, 1)
                    if share ~= nil then
                        groups[#groups + 1] = {
                            title  = tostring(g.title or "?"),
                            share  = share,
                            met    = panelNum(g.met, 0, 1),
                            held   = panelNum(g.held, 0),
                            need   = panelNum(g.need, 0),
                            colourIndex = panelNum(g.colourIndex, 1, maxG),
                        }
                    end
                end
            end
        end
        out.feed = { factor = panelNum(d.feed.factor, 0, 1),
                     serial = d.feed.serial == true,
                     activeTitle = d.feed.activeTitle ~= nil and tostring(d.feed.activeTitle) or nil,
                     grazes = d.feed.grazes == true,
                     advice = panelAdvice(d.feed.advice),
                     groups = groups }
    end
    if out.herd == nil and out.value == nil and out.feed == nil and out.profit == nil then
        return nil
    end
    return out
end

---The panel's facts for one barn, or nil when nothing is registered / nothing
-- answered. Never throws: a provider that does is struck out, not propagated into
-- a GUI populate where it would abort the page mid-render (5.44 / 5.57).
function SmartDistribution.husbandryPanelData(placeable)
    local list = SmartDistribution._husbandryPanels
    if type(list) ~= "table" or #list == 0 or placeable == nil then return nil end
    for _, entry in ipairs(list) do
        if entry.strikes < MAX_STRIKES then
            local ok, res = pcall(entry.fn, placeable)
            if not ok then
                entry.strikes = entry.strikes + 1
                log("husbandry panel '%s' threw (%d/%d): %s", entry.name, entry.strikes,
                    MAX_STRIKES, tostring(res))
                if entry.strikes >= MAX_STRIKES then
                    log("husbandry panel '%s' STRUCK OUT for this session; the panel will "
                        .. "stay empty rather than the tab breaking", entry.name)
                end
            else
                local clean = sanitisePanel(res)
                if clean ~= nil then return clean end
            end
        end
    end
    return nil
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
---Validate and normalise a planner's answer into the ARRAY form the caller uses:
--   { { fillTypes = { ft, ... }, litres = n }, ... }
--
-- TWO INPUT FORMS ARE ACCEPTED.
--   v2  an array of { fillTypes = { ... }, litres = n } -- fillTypes are
--       ALTERNATIVES: any of them satisfies this request, and DR picks by what is
--       actually in stock and nearest. This exists because a planner cannot know
--       what the farm holds; naming one product and hoping is how a pig pen ends
--       up starving on maize while its sorghum sits in a silo.
--   v1  a flat { [ft] = litres } map, normalised to one single-alternative entry
--       each. Kept working so an existing planner does not break.
--
-- A planner is third-party code running inside the hourly pass, so its output is
-- treated as a REQUEST, never as fact: unknown fill types are dropped, junk
-- values are rejected outright, and a plan asking for more than DR offered is
-- scaled down rather than allowed to over-fill the pool.
local function sanitisePlan(plan, allowed, poolNeed, who)
    if type(plan) ~= "table" then return nil end

    local ok = {}
    for _, ft in ipairs(allowed) do ok[ft] = true end

    local out, total, badValue, notAllowed = {}, 0, 0, 0

    local function addEntry(fts, litres)
        if type(litres) ~= "number" or litres ~= litres           -- NaN
           or litres == math.huge or litres <= 0 then
            badValue = badValue + 1
            return
        end
        local usable = {}
        for _, ft in ipairs(fts) do
            if type(ft) ~= "number" then
                badValue = badValue + 1
            elseif ok[ft] then
                usable[#usable + 1] = ft
            else
                notAllowed = notAllowed + 1          -- blocked / excluded / not accepted here
            end
        end
        if #usable == 0 then return end              -- nothing DR may deliver for this request
        out[#out + 1] = { fillTypes = usable, litres = litres }
        total = total + litres
    end

    -- v1 values are numbers, v2 entries are tables, so the first element tells the
    -- forms apart even when fill type index 1 is a legitimate key.
    if type(plan[1]) == "table" then
        for _, e in ipairs(plan) do
            if type(e) == "table" and type(e.fillTypes) == "table" then
                addEntry(e.fillTypes, e.litres)
            else
                badValue = badValue + 1
            end
        end
    else
        for ft, litres in pairs(plan) do
            if type(ft) == "number" then addEntry({ ft }, litres) else badValue = badValue + 1 end
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
    if total <= 0 or #out == 0 then return nil end

    -- Never let a plan exceed what DR asked for: the pool would simply refuse
    -- the surplus at deposit time, but the slots would have competed for
    -- sources they were never going to use.
    if total > poolNeed then
        local scale = poolNeed / total
        for _, e in ipairs(out) do e.litres = e.litres * scale end
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

-- ===========================================================================
-- MENU EXTENSION (API v3)
--
-- A mod may add its own tab to DR's consolidated menu. TabbedMenu:addPage is a
-- documented runtime API, so the mechanism is the base game's; what DR adds is
-- the three things a mod cannot get right on its own.
--
--   1. TIMING. DR registers its menu on Mission00.loadMission00Finished, and a
--      mod that appends to the same hook may run BEFORE it -- Animal Redux does,
--      because mods load alphabetically and its chunk appends first. So
--      SmartDistribution._menu does not exist yet at the moment a mod would
--      naturally reach for it. onMenuReady fires AFTER the menu is built, and
--      immediately if it already is, so registration order stops mattering.
--   2. THE ICON. TabbedMenu:addPage takes a texture FILE and UVs, but DR's own
--      tabs use base-game icon SLICES (addPageTab's fourth argument). A mod
--      wanting a stock icon cannot express that through addPage.
--   3. THE LAYOUT. On a display wider than 16:9 DR widens its own design units
--      (CLAUDE.md 6.15) around its own g_gui:loadGui calls only. A page loaded
--      by a mod would come out narrow beside every DR tab. loadMenuPage applies
--      the same treatment.
--
-- Additive: v2 planners are untouched, and a mod can feature-detect these by
-- testing for the function rather than by comparing versions.
-- ===========================================================================

SmartDistribution._menuReadyCallbacks = SmartDistribution._menuReadyCallbacks or {}

---Call `fn(menu)` once DR's menu exists. Fires immediately if it already does.
function SmartDistribution.API.onMenuReady(name, fn)
    if type(name) ~= "string" or name == "" or type(fn) ~= "function" then
        log("onMenuReady refused: needs (string name, function fn)")
        return false
    end
    local list = SmartDistribution._menuReadyCallbacks
    for i, e in ipairs(list) do
        if e.name == name then list[i] = { name = name, fn = fn }; return true end
    end
    list[#list + 1] = { name = name, fn = fn }

    -- Already built? Then this registration is late and must not simply be lost.
    if SmartDistribution._menuRegistered and SmartDistribution._menu ~= nil then
        local ok, err = pcall(fn, SmartDistribution._menu)
        if not ok then log("onMenuReady '%s' threw: %s", name, tostring(err)) end
    end
    return true
end

---Fired by registerMenuGui. Each callback is pcall'd: a mod's tab failing to
-- build must never take DR's own menu down with it.
function SmartDistribution.fireMenuReady(menu)
    for _, e in ipairs(SmartDistribution._menuReadyCallbacks) do
        local ok, err = pcall(e.fn, menu)
        if ok then
            log("menu extension '%s' installed", e.name)
        else
            log("menu extension '%s' FAILED and was skipped: %s", e.name, tostring(err))
        end
    end
end

---Load a mod's page frame with DR's profiles and DR's ultrawide widening, so it
-- matches the built-in tabs instead of rendering narrow beside them.
function SmartDistribution.API.loadMenuPage(pageInstance, guiName, xmlPath)
    if g_gui == nil or pageInstance == nil or guiName == nil or xmlPath == nil then return false end
    local widen = SmartDistribution.layoutScaleX ~= nil and SmartDistribution.layoutScaleX() or 1
    SmartDistribution._layoutScaling = (widen > 1)
    local ok, err = pcall(g_gui.loadGui, g_gui, xmlPath, guiName, pageInstance, true)
    SmartDistribution._layoutScaling = false        -- cleared on EVERY path: left set, it
                                                    -- would widen unrelated base-game menus
    if not ok then log("loadMenuPage('%s') failed: %s", tostring(guiName), tostring(err)) end
    return ok
end

---Add a page as a tab. `sliceId` is a base-game icon slice (e.g.
-- "gui.icon_ingameMenu_animals"); `badgeSliceId` is an OPTIONAL second slice drawn
-- small in the corner of the same tab, for a page that is about two things at once
-- (the base game allows a tab exactly one icon, and its icons are slices inside
-- dataS.gar, so two of them cannot be merged into a file); `title` is the tab's
-- name -- pass it, because
-- the base game's fallback looks up "ui_<pageName>" in ITS namespace and a mod
-- key will never be found there.
-- ATOMIC. This mutates several of the menu's internal tables, and a failure part
-- way through leaves DR's menu unusable -- which is exactly what happened the
-- first time: registerPage put the page into pageFrames, the paging element never
-- learned about it, and rebuildTabList then threw on every frame
-- (idPageHash[nil].disabled), taking the whole menu down. A pcall stops the error
-- propagating; it does NOT undo a half-applied change.
--
-- So: every step records how to undo itself, the result is VERIFIED before being
-- kept, and anything short of complete success is rolled back. An extension mod
-- must not be able to break DR's own menu, however wrong its page is.
--
-- ORDER MATTERS. The page is given to the paging element FIRST, because that is
-- both what parents it (an unparented page renders nothing) and what registers
-- it in idPageHash. Only then is TabbedMenu told about it. addElement is used
-- rather than addPage: addElement is present in the shipped source and passes the
-- ELEMENT ITSELF, which is what rebuildTabList later looks up. addPage is
-- stripped, and the base game's own addPage() hands it pageRoot instead of the
-- controller -- a mismatch that works for XML-declared pages and not for one
-- added at runtime.
function SmartDistribution.API.addMenuPage(menu, page, position, sliceId, title, predicate,
                                           buttons, badgeSliceId)
    if menu == nil or page == nil then return false end
    if menu.pagingElement == nil or menu.registerPage == nil then
        log("addMenuPage: this menu has no paging element")
        return false
    end

    local undo = {}
    local ok, err = pcall(function()
        menu.pagingElement:addElement(page)
        undo[#undo + 1] = function() menu.pagingElement:removeElement(page) end

        -- GEOMETRY. addElement parents the page but does not lay it out, so a
        -- runtime-added page renders at the default position -- observed as the
        -- whole tab drawn over the tab strip with its header stranded mid-screen.
        -- The pages the game placed itself (via the FrameReference entries in the
        -- menu XML) have the right position and size, and a sibling in the same
        -- parent can simply be given theirs. Copying a known-good element beats
        -- deriving the geometry, since the paging element's own sizing rules are
        -- stripped from the shipped source.
        local ref = nil
        for _, f in ipairs(menu.pageFrames) do
            if f ~= page and f.position ~= nil and f.size ~= nil then ref = f; break end
        end
        if ref ~= nil then
            if page.setPosition ~= nil then page:setPosition(ref.position[1], ref.position[2]) end
            if page.setSize ~= nil then page:setSize(ref.size[1], ref.size[2]) end
        end
        if page.updateAbsolutePosition ~= nil then page:updateAbsolutePosition() end

        -- Verify the paging element really took it. Without this the failure only
        -- shows up later, inside rebuildTabList, on every frame.
        local pageId = menu.pagingElement:getPageIdByElement(page)
        if pageId == nil or menu.pagingElement:getPageById(pageId) == nil then
            error("the paging element did not register the page", 0)
        end
        if title ~= nil then
            local entry = menu.pagingElement:getPageById(pageId)
            if entry ~= nil then entry.title = title end
        end

        menu:registerPage(page, position, predicate or function() return true end)
        undo[#undo + 1] = function() menu:unregisterPage(page:class()) end

        menu:addPageTab(page, nil, nil, sliceId)
        undo[#undo + 1] = function() menu.pageTabs[page] = nil end

        -- A SECOND SLICE IN THE CORNER OF THE SAME TAB, for a page that is about
        -- two things at once. Optional and additive: omit it and the tab is
        -- exactly as it was. Rolled back with everything else, so a later step
        -- failing cannot leave a badge on a tab that was never added.
        if badgeSliceId ~= nil and menu.setPageTabBadge ~= nil then
            menu:setPageTabBadge(page, badgeSliceId)
            undo[#undo + 1] = function() menu:setPageTabBadge(page, nil) end
        end

        if buttons ~= nil and page.setMenuButtonInfo ~= nil then page:setMenuButtonInfo(buttons) end
        menu:rebuildTabList()

        -- Final consistency check on the WHOLE menu, not just our page: every
        -- registered frame must resolve to a page the paging element knows, which
        -- is precisely the invariant rebuildTabList assumes and whose violation
        -- broke the menu.
        for _, f in ipairs(menu.pageFrames) do
            local id = menu.pagingElement:getPageIdByElement(f)
            if id == nil or menu.pagingElement:getPageById(id) == nil then
                error("menu left inconsistent: a registered page has no paging entry", 0)
            end
        end
    end)

    if not ok then
        log("addMenuPage failed, rolling back: %s", tostring(err))
        for i = #undo, 1, -1 do pcall(undo[i]) end
        pcall(function() menu:rebuildTabList() end)
        return false
    end
    return true
end

---The standard Back button, so a mod's footer matches DR's without guessing at
-- the input action or the callback.
function SmartDistribution.API.menuBackButton(menu)
    return {
        inputAction = InputAction.MENU_BACK,
        text = (g_i18n ~= nil and g_i18n:getText("button_back")) or "Back",
        callback = menu:makeSelfCallback(menu.onClickBack),
        showWhenPaused = true,
    }
end

-- ---------------------------------------------------------------------------
-- SETTINGS TABS (v8)
--
-- A mod puts its OWN settings on DR's Settings page, as a tab beside DR's.
--
-- DR OWNS THE LAYOUT, THE PROVIDER OWNS THE DATA -- the same split
-- registerHusbandryPanel uses, and for the same reason: DR's settings rows are
-- hand authored and hand tiled, and a provider that could place its own elements
-- could break a page whose geometry is measured to the pixel. A table of
-- definitions cannot. So a mod hands over WHAT its settings are and DR renders
-- them into pre-authored generic rows.
--
-- THE TAB ONLY EXISTS WHILE THE MOD DOES. Nothing here is declared by DR: the
-- registry is empty on a stock install, DR's own tab is the only one, and the
-- strip looks exactly as it did. Remove the mod and its tab is simply never
-- registered again.
--
--   SmartDistribution.API.registerSettingsTab(modName, label, defs)
--   SmartDistribution.API.unregisterSettingsTab(modName)
--
--   label    the tab caption, ALREADY LOCALISED -- DR cannot resolve another
--            mod's l10n namespace (5.60: getText needs the owning MOD_NAME or it
--            misses into the base game's table and silently falls back).
--   defs     an array of up to PAGE_SETTING_ROW_MAX rows, each:
--       { id      = "trade",                 -- the provider's own key, for logs
--         title   = "Buy / Sell Animals",    -- localised
--         tooltip = "...",                   -- localised, optional
--         strings = { "Off", "On" },         -- localised value labels, 2 or more
--         get     = function() return 2 end, -- CURRENT 1-based index
--         set     = function(index) end }    -- the player moved it
--
-- `defs` MAY BE A FUNCTION returning that array, for a mod whose rows depend on
-- state that does not exist at registration time. It is re-read on every page
-- open, so a provider may also change its own labels between opens.
--
-- get / set ARE PROVIDER CODE RUNNING INSIDE DR's GUI, so both are pcall'd and a
-- provider that throws three times is struck out for the session -- the same rule
-- the feed planner and the husbandry panel carry. A throwing setting must not be
-- able to abort a populate, which aborts the render and shows as an EMPTY PAGE
-- with nothing in the log (5.44 / 5.57).
--
-- INDEX, NEVER LABEL. `get` returns and `set` receives a 1-based index into
-- `strings`, because the label is display text and the index is what a provider
-- can persist. DR's own settings have carried the index for exactly this reason.
SmartDistribution._settingsTabs = SmartDistribution._settingsTabs or {}

function SmartDistribution.API.registerSettingsTab(modName, label, defs)
    if type(modName) ~= "string" or modName == "" or type(label) ~= "string" then
        log("registerSettingsTab refused: needs (string modName, string label, defs)")
        return false
    end
    if type(defs) ~= "table" and type(defs) ~= "function" then
        log("registerSettingsTab refused for '%s': defs must be a table or a function", modName)
        return false
    end
    if SmartDistribution.registerPageTab == nil then
        log("registerSettingsTab refused: this DR has no page tab registry")
        return false
    end
    SmartDistribution._settingsTabs[modName] = { defs = defs, strikes = 0 }
    local i, why = SmartDistribution.registerPageTab("settings", modName, label,
                                                    { settingsOwner = modName })
    if i == nil then
        SmartDistribution._settingsTabs[modName] = nil
        log("registerSettingsTab refused for '%s': %s", modName, tostring(why))
        return false
    end
    log("settings tab '%s' registered as tab %d", modName, i)
    return true
end

function SmartDistribution.API.unregisterSettingsTab(modName)
    if type(modName) ~= "string" then return false end
    SmartDistribution._settingsTabs[modName] = nil
    if SmartDistribution.unregisterPageTab == nil then return false end
    local gone = SmartDistribution.unregisterPageTab("settings", modName)
    if gone then log("settings tab '%s' unregistered", modName) end
    return gone
end

---Resolve one provider's rows, validated. Returns an array DR can render, never
-- nil -- an empty array is the honest answer for a provider that has been struck
-- out or has nothing to show, and the page then draws a tab with no rows rather
-- than falling back to DR's own, which would be a lie about whose tab it is.
--
-- EVERY FIELD IS CHECKED. This is data DR did not compute, rendered into DR's own
-- page: a nil title or a `strings` of one entry would show as a blank row or a
-- selector that cannot move, neither of which names its cause.
function SmartDistribution.settingsTabRows(modName)
    local rec = SmartDistribution._settingsTabs[modName]
    if rec == nil then return {} end
    if (rec.strikes or 0) >= 3 then return {} end

    local defs = rec.defs
    if type(defs) == "function" then
        local ok, out = pcall(defs)
        if not ok then
            SmartDistribution.noteSettingsTabThrow(modName, out)
            return {}
        end
        defs = out
    end
    if type(defs) ~= "table" then return {} end

    local rows = {}
    local max = SmartDistribution.PAGE_SETTING_ROW_MAX or 12
    for _, d in ipairs(defs) do
        if #rows >= max then
            log("settings tab '%s' offered more than %d rows; the rest are ignored", modName, max)
            break
        end
        if type(d) == "table" and type(d.title) == "string" and d.title ~= ""
           and type(d.strings) == "table" and #d.strings >= 2
           and type(d.set) == "function" then
            local labels = {}
            for i = 1, #d.strings do labels[i] = tostring(d.strings[i]) end
            rows[#rows + 1] = {
                owner   = modName,
                id      = tostring(d.id or ("row" .. tostring(#rows + 1))),
                title   = d.title,
                tooltip = type(d.tooltip) == "string" and d.tooltip or nil,
                strings = labels,
                get     = type(d.get) == "function" and d.get or nil,
                set     = d.set,
            }
        else
            log("settings tab '%s' offered an unusable row and it was dropped "
                .. "(needs title, 2 or more strings, and set)", modName)
        end
    end
    return rows
end

---Record a throw against a provider and strike it out at three, so one broken
-- callback cannot re-throw on every page open for the rest of the session.
function SmartDistribution.noteSettingsTabThrow(modName, err)
    local rec = SmartDistribution._settingsTabs[modName]
    if rec == nil then return end
    rec.strikes = (rec.strikes or 0) + 1
    log("settings tab '%s' threw (strike %d/3): %s", modName, rec.strikes, tostring(err))
    if rec.strikes >= 3 then
        log("settings tab '%s' STRUCK OUT for this session; its rows will stop drawing", modName)
    end
end


-- ---------------------------------------------------------------------------
-- HELP TABS (v9)
--
-- A mod puts its OWN user guide on DR's User Guide page, as a tab beside DR's.
-- The exact shape registerSettingsTab takes, and for the same reason: the page
-- already reads `entry.topics` off the registry, so this adds validation and
-- symmetry rather than a second mechanism.
--
--   SmartDistribution.API.registerHelpTab(modName, label, topics)
--   SmartDistribution.API.unregisterHelpTab(modName)
--
--   label   the tab caption, ALREADY LOCALISED -- DR cannot resolve another mod's
--           l10n namespace (5.60).
--   topics  an array of { title = "...", body = "..." }, or a FUNCTION returning
--           one. The function form is the useful one for a guide: it is re-read on
--           every page open, so a mod may resolve its own l10n at open time rather
--           than at load, and may rewrite its guide without re-registering.
--
-- THE TAB ONLY EXISTS WHILE THE MOD DOES. DR declares nothing; remove the mod and
-- the tab is simply never registered again, and the strip is DR's one tab exactly
-- as before.
--
-- BODY IS PLAIN TEXT with the guide's own light conventions -- a line beginning
-- "## " is a heading, blank lines separate paragraphs, and long lines are wrapped
-- at render time. Do NOT hand-wrap: the page word-wraps to its own column count
-- and a pre-wrapped paragraph comes out ragged.
SmartDistribution._helpTabs = SmartDistribution._helpTabs or {}

function SmartDistribution.API.registerHelpTab(modName, label, topics)
    if type(modName) ~= "string" or modName == "" or type(label) ~= "string" then
        log("registerHelpTab refused: needs (string modName, string label, topics)")
        return false
    end
    if type(topics) ~= "table" and type(topics) ~= "function" then
        log("registerHelpTab refused for '%s': topics must be a table or a function", modName)
        return false
    end
    if SmartDistribution.registerPageTab == nil then
        log("registerHelpTab refused: this DR has no page tab registry")
        return false
    end
    SmartDistribution._helpTabs[modName] = { topics = topics, strikes = 0 }
    -- THE PAGE READS `entry.topics` ITSELF and has since the strip was built, so
    -- what is registered is a THUNK that runs the validator. That keeps the page
    -- unchanged and means a malformed guide yields an empty tab rather than a
    -- half-rendered one.
    local i, why = SmartDistribution.registerPageTab("help", modName, label,
        { helpOwner = modName,
          topics = function() return SmartDistribution.helpTabTopics(modName) end })
    if i == nil then
        SmartDistribution._helpTabs[modName] = nil
        log("registerHelpTab refused for '%s': %s", modName, tostring(why))
        return false
    end
    log("help tab '%s' registered as tab %d", modName, i)
    return true
end

function SmartDistribution.API.unregisterHelpTab(modName)
    if type(modName) ~= "string" then return false end
    SmartDistribution._helpTabs[modName] = nil
    if SmartDistribution.unregisterPageTab == nil then return false end
    local gone = SmartDistribution.unregisterPageTab("help", modName)
    if gone then log("help tab '%s' unregistered", modName) end
    return gone
end

---Resolve and validate one provider's guide. Returns an array, never nil.
--
-- EVERY TOPIC IS CHECKED, because this is third-party text rendered into DR's own
-- page: a topic with no title is an unselectable entry in the contents list, and a
-- non-string body would throw inside the renderer -- which aborts the populate and
-- shows as an EMPTY PAGE with nothing in the log (5.44 / 5.57).
--
-- A topic with a title and NO body is kept, with an empty body. That is a heading
-- a mod has written but not filled in yet, and showing it is more useful than
-- silently dropping it -- it tells the reader the section exists.
function SmartDistribution.helpTabTopics(modName)
    local rec = SmartDistribution._helpTabs[modName]
    if rec == nil then return {} end
    if (rec.strikes or 0) >= 3 then return {} end

    local src = rec.topics
    if type(src) == "function" then
        local ok, out = pcall(src)
        if not ok then
            rec.strikes = (rec.strikes or 0) + 1
            log("help tab '%s' threw resolving its topics (strike %d/3): %s",
                modName, rec.strikes, tostring(out))
            if rec.strikes >= 3 then
                log("help tab '%s' STRUCK OUT for this session", modName)
            end
            return {}
        end
        src = out
    end
    if type(src) ~= "table" then return {} end

    local topics = {}
    for _, t in ipairs(src) do
        if type(t) == "table" and type(t.title) == "string" and t.title ~= "" then
            topics[#topics + 1] = {
                title = t.title,
                body  = type(t.body) == "string" and t.body or "",
            }
        else
            log("help tab '%s' offered a topic with no title and it was dropped", modName)
        end
    end
    return topics
end


print("[SmartDistribution] extension API v" .. tostring(SmartDistribution.API.VERSION) .. " available")
