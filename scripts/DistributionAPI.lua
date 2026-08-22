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
SmartDistribution.API.VERSION = 3

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
-- "gui.icon_ingameMenu_animals"); `title` is the tab's name -- pass it, because
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
function SmartDistribution.API.addMenuPage(menu, page, position, sliceId, title, predicate, buttons)
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

print("[SmartDistribution] extension API v" .. tostring(SmartDistribution.API.VERSION) .. " available")
