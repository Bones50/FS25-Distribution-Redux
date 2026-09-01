-- ============================================================================
-- DistributionStoragePage.lua  (Distribution Redux) -- Storage tab
-- Master-detail reproduction of the manager + Asset (silo) dialog:
--   left  list (assetList)  : silos / barns / sheds / heaps you can configure
--   right list (detailList) : the selected building's per-product rows
--                             (icon / held / distr / sold / stored / mode+timing)
-- Footer buttons (real keys via the menu's setMenuButtonInfo): Cycle Output,
-- Sell Timing. All actions reuse the existing engine seams, so this
-- is a new view over the same logic the popup uses.
-- ============================================================================

DistributionStoragePage = {}
local DistributionStoragePage_mt = Class(DistributionStoragePage, DistributionMenuPage)

-- English fallbacks; storageClassLabel resolves them through l10n at display time.
local STORAGE_CLASSES = { SILO = "Silo", HUSBANDRY = "Barn", SHED = "Storage", HEAP = "Pit", MARKET = "Market" }
local STORAGE_CLASS_KEYS = { SILO = "dr_class_silo", HUSBANDRY = "dr_class_barn", SHED = "dr_class_storage",
                             HEAP = "dr_class_pit", MARKET = "dr_class_market" }
local function storageClassLabel(cls)
    local fb = STORAGE_CLASSES[cls]
    if fb == nil then return nil end
    if SmartDistribution == nil or SmartDistribution.l10n == nil then return fb end
    return SmartDistribution.l10n(STORAGE_CLASS_KEYS[cls], fb)
end

-- The input list and the output/detail list each keep their own selected row, and FS25 draws the
-- selection highlight on a row regardless of which list has focus -- so both look selected at once. Each
-- row element carries a `hideSelection` flag (its own built-in way to suppress the highlight); we set it
-- on rows of the list that is NOT active so only the active list shows a highlight. active == true means
-- "this list currently owns focus".
local function applyRowHighlight(cell, active)
    if cell == nil then return end
    cell.hideSelection = not active
    if not active and cell.setSelected ~= nil then pcall(function() cell:setSelected(false) end) end
end

-- integer liters with thousands separators
local function fmt(n)
    n = math.floor((n or 0) + 0.5)
    local s = tostring(n)
    local k
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
end

-- EVERY litre figure on this page goes through here, and here delegates to SmartDistribution.formatVolume
-- so the whole mod switches to kilolitres in one place: up to 999 L reads in litres, anything above reads
-- in kL with the extraneous zeros dropped (600,000 L -> "600 kL", 123,123 L -> "123.123 kL"). It carries
-- the UNIT itself -- do not append " L" to it. `fmt` above survives for things that are not volumes.
local function fmtV(n)
    if SmartDistribution ~= nil and SmartDistribution.formatVolume ~= nil then
        local ok, s = pcall(SmartDistribution.formatVolume, n or 0)
        if ok and type(s) == "string" then return s end
    end
    return fmt(n) .. " L"
end

-- ---- BLOCKED-PRODUCT NOTICE ------------------------------------------------
-- With Advanced routing ON, a blocked product the building is not holding is dropped from these lists
-- (SmartDistribution.visibleProducts) and the count comes back as one final row, so a shortened table
-- always explains itself rather than quietly losing rows. The row carries `notice` and NO `ft`, and every
-- accessor that reaches for a product treats it as absent -- see selectedDetailRow.
local NOTICE_CELLS = { "typeText", "fillName", "name", "heldText", "amount", "remainingText", "recvText", "received",
                       "consumedText", "consumed", "prodText", "produced", "distText", "distr",
                       "modeText", "method", "statusText", "status",
                       "barHeld", "barCap",
                       "statusIn", "statusSep", "statusOut" }

local function renderNoticeRow(cell, hidden, what)
    local icon = cell:getAttribute("fillIcon")
    if icon ~= nil and icon.setVisible ~= nil then icon:setVisible(false) end
    -- SmoothList RECYCLES cells, so every column must be actively cleared or this row inherits whatever
    -- the product row that last used the slot left behind -- the trap 5.7 already hit with colours.
    for _, k in ipairs(NOTICE_CELLS) do
        local c = cell:getAttribute(k)
        if c ~= nil then
            if c.setText ~= nil then c:setText("") end
            if c.setTextColor ~= nil then c:setTextColor(1, 1, 1, 1) end
        end
    end
    -- ...and the BAR itself. Cells are RECYCLED, so without this the notice row inherits whatever bar
    -- the product row that last used this slot drew (5.57's colour trap, one widget over). Its two
    -- LABELS need no special case: they are in NOTICE_CELLS with every other text cell.
    -- the track AND the pallet chip, which is a sibling of barBg and so is not hidden with it
    if SmartDistribution.hideStorageBar ~= nil then
        SmartDistribution.hideStorageBar(cell)
    else
        local bar = cell:getAttribute("barBg")
        if bar ~= nil and bar.setVisible ~= nil then bar:setVisible(false) end
    end
    local n = cell:getAttribute("noticeText")
    if n == nil then return end
    if n.setVisible ~= nil then n:setVisible(true) end
    if n.setText ~= nil then
        -- Whole-sentence singular/plural keys. The old form made the singular by deleting the final
        -- "s" of "inputs", which is English-only and does not survive translation.
        local key = (hidden == 1) and "dr_notice_blockedInput" or "dr_notice_blockedInputs"
        local fb  = (hidden == 1) and "+%d input blocked (See Advanced Inputs)"
                                   or "+%d inputs blocked (See Advanced Inputs)"
        n:setText(string.format(SmartDistribution.l10n(key, fb), hidden))
    end
    local COL = (SmartDistribution ~= nil and SmartDistribution.LINK_COLOR) or {}
    local col = COL.IDLE or { 0.95, 0.65, 0.20, 1 }
    if n.setTextColor ~= nil then n:setTextColor(col[1], col[2], col[3], col[4] or 1) end
end

-- ...and every NORMAL row has to hide the overlay again, for that same recycling reason
local function hideNoticeRow(cell)
    local n = cell:getAttribute("noticeText")
    if n ~= nil and n.setVisible ~= nil then n:setVisible(false) end
end

-- ---- in-row mode arrows ----------------------------------------------------------------------
-- A module-level constant, not a literal in the loop: this runs per row per populate, which is the
-- throttled hot path 5.46 / 5.52 exist to keep cheap, and a table literal there allocates every call.
local MODE_ARROWS = { "modePrev", "modeNext" }

-- Bind the arrows on ONE row, and show or hide them.
-- The function now receives the *asset* being displayed so it can decide whether the
-- asset is a bunker‑silo that is currently filling or fermenting.
local function setModeArrows(cell, ft, asset)
    --------------------------------------------------------------------
    -- 1) Existing rule – hide when there is no fill‑type.
    --------------------------------------------------------------------
    local hideArrows = (ft == nil)

    --------------------------------------------------------------------
    -- 2) New rule – hide when the asset is a bunker‑silo in a
    --    non‑editable stage (filling / fermenting).
    --------------------------------------------------------------------
    if not hideArrows and asset ~= nil
       and SmartDistribution ~= nil
       and SmartDistribution.isBunkerSiloPlaceable ~= nil
       and SmartDistribution.bunkerStage ~= nil
       and SmartDistribution.isBunkerSiloPlaceable(asset) then

        local stage = SmartDistribution.bunkerStage(asset)
        if stage == "filling" or stage == "fermenting" or stage == "fermented" then
            hideArrows = true
        end
    end

    --------------------------------------------------------------------
    -- 3) Apply the visibility to each arrow button.
    --    When hidden we also clear the stored fill‑type so that a click
    --    cannot act on a stale value (mirrors the original `ft == nil`
    --    behaviour).
    --------------------------------------------------------------------
    for i = 1, #MODE_ARROWS do
        local b = cell:getAttribute(MODE_ARROWS[i])
        if b ~= nil then
            b.sdFillType = hideArrows and nil or ft
            if b.setVisible ~= nil then
                b:setVisible(not hideArrows)
            end
        end
    end
end

-- ButtonElement's onClick raise site sits in the STRIPPED part of the base source (8.1), so the exact
-- argument list is not readable. DR's own MultiTextOption handler is declared (state, element), which
-- proves the element IS passed but not in which position for a plain Button -- so find it by looking
-- for the argument carrying our stashed field instead of assuming an index.
local function clickedArrow(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "table" and v.sdFillType ~= nil then return v end
    end
    return nil
end

-- "<liters>  (<money>)" for the SOLD /mo column; money omitted when zero/unknown (e.g. MP clients)
local function soldWithMoney(liters, money)
    local base = fmtV(liters)
    if money ~= nil and money > 0.5 and SmartDistribution ~= nil and SmartDistribution.formatMoneyShort ~= nil then
        return base .. "  (" .. SmartDistribution.formatMoneyShort(money) .. ")"
    end
    return base
end

-- Everything that LEFT the building over the window, as one figure: distributed + stored/moved + sold,
-- with the sale value in brackets when any of it sold. The three-way split now lives on the Overview tab,
-- which is where these pages point the player for detail.
local function outTotalText(e)
    if type(e) ~= "table" then return fmtV(0) end
    return soldWithMoney((e.dist or 0) + (e.stored or 0) + (e.sold or 0), e.money)
end

-- "473 L + 3,000 L (3p)" -- the internal buffer, then what stands on the pad, matching the Productions and
-- Overview tabs. A pen's stock lives in BOTH places at once and the split is the useful information: one
-- lump could not say whether the eggs were still buffering or already on pallets, and the figure used to
-- change meaning with the mode (473 under Hold Internal, 3,473 under anything else) because assetHeld
-- switched basis. assetHeld is now always the full stock, and this splits it back out for display.
-- Pallets are counted as OBJECTS by palletCountOf, never litres/1000 -- a part-filled pallet is one pallet
-- standing on the pad, not zero. Falls back to the plain total for anything that spawns no pallets, so
-- milk / manure / slurry rows are unchanged.
local function heldWithPallets(placeable, ft, held, role)
    if placeable == nil or ft == nil or SmartDistribution == nil then return fmtV(held) end
    -- one memoised pad scan for both figures rather than two full vehicle-list walks per row per refresh
    local pallets, n = 0, 0
    if SmartDistribution.padSnapshot ~= nil then
        local ok, litres, count = pcall(SmartDistribution.padSnapshot, placeable, ft)
        if ok and type(litres) == "number" then pallets = litres end
        if ok and type(count)  == "number" then n = count end
    else
        if SmartDistribution.palletLitresOf ~= nil then
            local ok, v = pcall(SmartDistribution.palletLitresOf, placeable, ft)
            if ok and type(v) == "number" then pallets = v end
        end
        if pallets > 0 and SmartDistribution.palletCountOf ~= nil then
            local ok, v = pcall(SmartDistribution.palletCountOf, placeable, ft)
            if ok and type(v) == "number" then n = v end
        end
    end
    local internal = math.max(0, (held or 0) - pallets)
    local text = fmtV(internal)
    -- capacity sits directly beside the figure it qualifies, not trailing after the pad part
    if SmartDistribution.outputCapacityTotal ~= nil then
        local ok, c = pcall(SmartDistribution.outputCapacityTotal, placeable, ft, role)
        if ok and type(c) == "number" and c > 0 and c < math.huge then
            text = text .. " (" .. fmtV(c) .. ")"
        end
    end
    if pallets > 0 then text = text .. " + " .. fmtV(pallets) .. " (" .. tostring(n) .. "p)" end
    return text
end

local function fillIconFile(ft)
    if g_fillTypeManager == nil or g_fillTypeManager.getFillTypeByIndex == nil then return nil end
    local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
    if ok and def ~= nil then
        return def.hudOverlayFilename or def.hudOverlayFilenameSmall
    end
    return nil
end

local function fillTypeTitle(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local def = g_fillTypeManager:getFillTypeByIndex(ft)
        if def ~= nil and def.title ~= nil then return def.title end
    end
    return tostring(ft)
end
-- Build the product rows for one list, dropping blocked-and-empty products and appending the notice.
-- Shared by all three classes in this file so the rule cannot drift between the tabs.
local function buildProductRows(asset, ordered, role)
    local rows, hidden = {}, 0
    if SmartDistribution ~= nil and SmartDistribution.visibleProducts ~= nil then
        ordered, hidden = SmartDistribution.visibleProducts(asset, ordered, role)
    end
    for _, ft in ipairs(ordered) do rows[#rows + 1] = { ft = ft, name = fillTypeTitle(ft) } end
    if hidden > 0 then rows[#rows + 1] = { notice = hidden } end
    return rows
end


-- How much of this product the building will actually take: its storage AFTER the Advanced Inputs
-- percentage is applied, so the figure on the main list matches the one the dialog reserves. A pooled
-- store reports the shared pool times this product's share; an individual tank reports its own capacity.
-- Blocked -> 0 (it will accept nothing). Returns nil when capacity can't be resolved, so the caller can
-- fall back to showing the held figure alone rather than inventing a denominator.
local function inputMaxLiters(placeable, ft, role)
    if placeable == nil or ft == nil or SmartDistribution == nil then return nil end
    local uid = (SmartDistribution.settingUid ~= nil) and SmartDistribution.settingUid(placeable, ft, role) or nil
    if uid ~= nil and SmartDistribution.isInputBlocked ~= nil and SmartDistribution.isInputBlocked(uid, ft) then
        return 0
    end
    local cap = nil
    if SmartDistribution.inputProductCapacity ~= nil then
        local ok, c = pcall(SmartDistribution.inputProductCapacity, placeable, ft, role)
        if ok and type(c) == "number" then cap = c end
    end
    if (cap == nil or cap <= 0) and SmartDistribution.husbandryInputCapacity ~= nil then
        local ok, c = pcall(SmartDistribution.husbandryInputCapacity, placeable, ft)
        if ok and type(c) == "number" then cap = c end
    end
    if cap == nil or cap <= 0 or cap >= math.huge then return nil end
    -- MAX means the CAP: this product's percentage of the building's capacity, matching the Advanced Inputs
    -- dialog's own MAX IN column exactly. It used to return inputEffectiveMaxLiters -- the ELASTIC "what
    -- could still fit given what the others hold" -- which made the figure shrink as neighbours filled up
    -- and had no relationship to the percentage the player had set. That elastic number is still shown, as
    -- AVAILABLE in the dialog, where it is labelled honestly.
    local pct = 100
    if SmartDistribution.inputCapPct ~= nil then
        local ok, v = pcall(SmartDistribution.inputCapPct, placeable, ft)
        if ok and type(v) == "number" then pct = v end
    end
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return cap * pct / 100, pct
end

-- "619 L / 50,000 L (50%)" for an input row: what is there, the most that may go in, and the percentage
-- that ceiling comes from. Drops the tail when capacity cannot be resolved rather than inventing one.
local function heldOfMaxText(placeable, ft, held, role)
    local maxL, pct = inputMaxLiters(placeable, ft, role)
    if maxL == nil then return fmtV(held) end
    local s = fmtV(held) .. " / " .. fmtV(maxL)
    if pct ~= nil then s = s .. string.format(" (%d%%)", pct) end
    return s
end

-- ---- FREE STORAGE ---------------------------------------------------------
-- How much more will fit, and the colour that says how comfortable that is.
--   inputs  -> inputAcceptableLiters: the very figure the allocator clamps every delivery to, and the same
--              one the Advanced Inputs dialog shows as AVAILABLE, so the three can never disagree
--   outputs -> a straight capacity - held
-- Colour: red when nothing is left (or it is overfilled), orange at 10% or less of the ceiling, green
-- otherwise. nil capacity means there is nothing to judge against, so the cell shows a dash in the default
-- colour rather than inventing a verdict.
local function inputRemaining(placeable, ft, role)
    if placeable == nil or ft == nil or SmartDistribution == nil then return nil end
    if SmartDistribution.inputAcceptableLiters == nil then return nil end
    local ok, v = pcall(SmartDistribution.inputAcceptableLiters, placeable, ft, role)
    if not ok or type(v) ~= "number" or v ~= v or v < 0 or v >= math.huge then return nil end
    return v
end

local function outputRemaining(placeable, ft, held, role)
    if placeable == nil or ft == nil or SmartDistribution == nil then return nil, nil end
    if SmartDistribution.outputCapacityTotal == nil then return nil, nil end
    local ok, c = pcall(SmartDistribution.outputCapacityTotal, placeable, ft, role)
    if not ok or type(c) ~= "number" or c <= 0 or c >= math.huge then return nil, nil end
    -- POOLED TANKS: `c - held` is this product's OWN holding subtracted from the WHOLE tank, so a silo
    -- filled to the brim with wheat still reported full free space for every other crop. The INPUT side
    -- already answers this correctly -- inputAcceptableLiters clamps by `cap - othersHeld` -- so the free
    -- figure is taken from there and only falls back to the naive form when it cannot answer (a pure
    -- output with no input side, e.g. a pen's eggs).
    local room = inputRemaining(placeable, ft, role)
    if room ~= nil then return math.min(room, math.max(0, c - (held or 0))), c end
    return math.max(0, c - (held or 0)), c
end

-- Writes the FREE STORAGE figure, and paints the verdict on the HELD cell instead of on the figure it was
-- derived from. Same maths either way -- how full this product is, is the question both cells answer, and
-- "12,000 L / 50,000 L" is where the eye already goes to ask it. FREE STORAGE therefore stays plain white.
-- Cells are RECYCLED by SmoothList, so BOTH the nil path and the plain cell must actively reset to white or
-- a row inherits whatever colour the previous row left behind.
-- ---- THE STORAGE BAR -----------------------------------------------------------------------------
-- Draws one product's row of a tank: the WHOLE tank as the track, this product GREEN, everything else
-- RED behind it, and the player's configured "Max in" ceiling as an ORANGE line. Replaces the old
-- HELD / MAX and FREE STORAGE text columns, whose 240px and 115px it occupies.
--
-- DECLARED ABOVE ITS CALLER ON PURPOSE. A `local function` used before its declaration compiles clean
-- and resolves to a nil GLOBAL at runtime, which inside a GUI populate aborts the page mid render and
-- shows an EMPTY LIST, a symptom nothing like its cause (5.44 / 5.57 -- twice each).
--
-- NO PX TO NORMALISED ARITHMETIC ANYWHERE. The track's own absSize is already laid out and already
-- normalised, so every segment is a fraction of it -- which also means the bar follows 6.15's
-- resolution widening for free instead of having to be told about it.
--
-- OTHERS IS DRAWN FIRST AND SELF OVER THE TOP, both anchored left, so `others` carries the TOTAL fill
-- and `self` covers its left-hand part. That renders green from 0 and red beyond it with no positioning
-- at all; only the max line is positioned.
-- THE SHARE, AS A WHOLE PERCENT, with one floor: a holding that is not zero never reads as "0%".
--
local function setStorageBar(cell, placeable, ft, role, side, held)
    if SmartDistribution.drawStorageBar == nil then return end
    SmartDistribution.drawStorageBar(cell, placeable, ft, role, side or "both", held)
end


-- Distribution status of an input row (Active (Receiving) / Active (Idle) / Blocked). Shared by every
-- building category -- silos, storages, productions, animal pens and markets resolve a link the same way.
local function inputStatusLabel(placeable, ft, window, role)
    if placeable == nil or ft == nil or SmartDistribution == nil then return "" end
    if SmartDistribution.inputLinkStatus == nil or SmartDistribution.assetUid == nil then return "" end
    -- the ROLE's key, so a pallet-store row answers for itself and not for the building
    local uid = SmartDistribution.settingUid ~= nil and SmartDistribution.settingUid(placeable, ft, role)
                or SmartDistribution.assetUid(placeable)
    if uid == nil then return "" end
    local st = SmartDistribution.inputLinkStatus(uid, ft, window)
    return (SmartDistribution.LINK_LABEL or {})[st] or ""
end

-- BOTH DIRECTIONS IN ONE CELL, for the merged table: "in / out", e.g. "Recv / Send".
--
-- The two statuses are different facts (is anything arriving; is anything leaving) and the merged table
-- has one 131px column for them, so the long forms ("Active (Receiving)") do not fit side by side. Short
-- words, the same vocabulary the Overview settles on for its own narrow column (5.37).
--
-- ONE COLOUR FOR TWO STATES, resolved by SEVERITY: red if EITHER side is blocked, green if either is
-- actively moving, else orange. Blocked outranks active because it is the state the player has to act on,
-- and a row that is receiving while blocked outbound is not "fine". Cells are RECYCLED by SmoothList, so
-- the colour is set on every path and never left to inherit the previous row's (the 5.7 trap).
local SHORT_STATUS = { ACTIVE_IN = "dr_status_short_recv", ACTIVE_OUT = "dr_status_short_send",
                       IDLE = "dr_status_short_idle", BLOCKED = "dr_status_short_blocked" }
local SHORT_FALLBACK = { ACTIVE_IN = "Recv", ACTIVE_OUT = "Send", IDLE = "Idle", BLOCKED = "Blocked" }
-- `sold` names the market case. Nothing is SENT from a market -- its buffer never feeds the network back
-- (5.36), so the only way product leaves is a sale, and "Send" claimed a movement that cannot happen.
-- Only the ACTIVE_OUT word changes: Idle and Blocked mean the same on a market as anywhere else.
local function shortStatus(st, dir, sold)
    if st == nil then return SmartDistribution.l10n("dr_status_short_none", "-") end
    if sold and st == "ACTIVE" and dir == "OUT" then
        return SmartDistribution.l10n("dr_status_short_sold", "Sold")
    end
    local k = (st == "ACTIVE") and ("ACTIVE_" .. dir) or st
    local key, fb = SHORT_STATUS[k], SHORT_FALLBACK[k]
    if key == nil then return SmartDistribution.l10n("dr_status_short_none", "-") end
    return SmartDistribution.l10n(key, fb)
end

local function setCombinedStatusCell(cell, placeable, ft, window, role)
    local cIn  = cell:getAttribute("statusIn")
    local cSep = cell:getAttribute("statusSep")
    local cOut = cell:getAttribute("statusOut")
    if cIn == nil and cOut == nil then return end
    
    -- SILOS ARE OUTPUT-ONLY: hide the receive status for silos
    local isSilo = (SmartDistribution ~= nil and SmartDistribution.isBunkerSiloPlaceable ~= nil and 
                   SmartDistribution.isBunkerSiloPlaceable(placeable)) or
                  (placeable ~= nil and placeable.spec_silo ~= nil)
    
    local inSt, outSt = nil, nil
    if placeable ~= nil and ft ~= nil and SmartDistribution ~= nil and SmartDistribution.assetUid ~= nil then
        local uid = SmartDistribution.assetUid(placeable)
        if uid ~= nil then
            -- Skip input status for silos (they only output, never receive)
            if not isSilo then
                if SmartDistribution.isInputBlocked ~= nil and SmartDistribution.isInputBlocked(
                       (SmartDistribution.settingUid ~= nil)
                           and SmartDistribution.settingUid(placeable, ft, role) or uid, ft) then
                    inSt = "BLOCKED"
                elseif SmartDistribution.inputLinkStatus ~= nil then
                    inSt = SmartDistribution.inputLinkStatus(uid, ft, window)
                end
            end
            if SmartDistribution.outputLinkStatus ~= nil then
                outSt = SmartDistribution.outputLinkStatus(placeable, ft, window, role)
            end
        end
    end
    -- EACH HALF CARRIES ITS OWN COLOUR. One cell could not: a row whose input is blocked while its
    -- output is sending is two states, and painting the whole string red asserted it was one. The
    -- separator stays neutral so it reads as punctuation rather than as a third status.
    -- Cells are RECYCLED by SmoothList, so every part is written and coloured on EVERY populate --
    -- never left to inherit the previous row's (the trap 5.7 and 5.57 both hit).
    local COL = (SmartDistribution.LINK_COLOR or {})
    local isMkt = (SmartDistribution.isMarket ~= nil) and SmartDistribution.isMarket(placeable) or false
    local function paint(c, st, dir)
        if c == nil then return end
        -- the OUT half also says how many destinations are live: "Send (1/4)". A market has none, so
        -- outputDestCountText returns nothing there and the word itself becomes "Sold".
        local suffix = ""
        if dir == "OUT" and st ~= nil and SmartDistribution.outputDestCountText ~= nil then
            suffix = SmartDistribution.outputDestCountText(placeable, ft, role, st) or ""
        end

        if c.setText ~= nil then c:setText(shortStatus(st, dir, isMkt) .. suffix) end
        if c.setTextColor == nil then return end
        local col = (st ~= nil) and COL[st] or nil
        if col ~= nil then c:setTextColor(col[1], col[2], col[3], col[4] or 1)
        else c:setTextColor(1, 1, 1, 1) end
    end
    paint(cIn,  inSt,  "IN")
    paint(cOut, outSt, "OUT")
    if cSep ~= nil then
        if cSep.setText ~= nil then cSep:setText("/") end
        if cSep.setTextColor ~= nil then cSep:setTextColor(1, 1, 1, 1) end
    end
end

-- write the status into a row cell AND colour it: green feeding, orange idle, red blocked
local function setStatusCell(cell, placeable, ft, window, role)
    local c = cell:getAttribute("statusText")
    if c == nil then return end
    if placeable == nil or ft == nil or SmartDistribution == nil or SmartDistribution.inputLinkStatus == nil
       or SmartDistribution.assetUid == nil then
        if c.setText ~= nil then c:setText("") end
        return
    end
    local uid = SmartDistribution.assetUid(placeable)
    -- A product BLOCKED on the Advanced Inputs page is refused at the door, whatever the source-side link
    -- says, so it must read "Blocked" here too -- otherwise the main list still shows it as receiving.
    if uid ~= nil and SmartDistribution.isInputBlocked ~= nil and SmartDistribution.isInputBlocked(uid, ft) then
        if c.setText ~= nil then c:setText(SmartDistribution.l10n("dr_label_blocked", "Blocked")) end
        local bc = (SmartDistribution.LINK_COLOR or {}).BLOCKED
        if bc ~= nil and c.setTextColor ~= nil then c:setTextColor(bc[1], bc[2], bc[3], bc[4]) end
        return
    end
    local st   = uid ~= nil and SmartDistribution.inputLinkStatus(uid, ft, window) or nil
    local base = (st ~= nil) and ((SmartDistribution.LINK_LABEL or {})[st] or "") or ""
    -- "N of M buildings are feeding me this" -- appended exactly the way the OUTPUT side already appends
    -- its destination count (setOutputStatusCell / outputDestCountText), so both directions read alike.
    -- Suppressed on a blocked row and where nothing on the farm could supply it; see the engine function.
    local suffix, feeding = "", nil
    if base ~= "" and uid ~= nil and SmartDistribution.inputSourceCountText ~= nil then
        suffix, feeding = SmartDistribution.inputSourceCountText(uid, ft, st)
        suffix = suffix or ""
    end
    if c.setText ~= nil then c:setText(base .. suffix) end
    -- RED WHEN NOTHING IS FEEDING while something could -- the silent-stall signal 5.37 added DEST for.
    -- It OUTRANKS the status word's own colour, ACTIVE included: on a Month window a row can read
    -- "Active (Receiving) (0/3)" because something arrived this month and nothing this pass, and the
    -- count is the half worth acting on. feeding is nil whenever no count is shown, so this cannot fire
    -- on a row that has no ratio to report.
    local col = st ~= nil and (SmartDistribution.LINK_COLOR or {})[st] or nil
    -- RED ONLY ON A ROW THAT IS NOT ALREADY ACTIVE. Red means "something could feed me and nothing is",
    -- which is a claim DR itself contradicts when the status word beside it reads Active (Receiving) --
    -- and the two are answered on DIFFERENT TIME BASES, so they legitimately disagree: the word can come
    -- from the selected WINDOW's ledger while the count is the last completed pass only (the only
    -- per-source data that exists). Reported 2026-08-27 as "Active (Receiving)" painted red at 0/2.
    -- An idle row with sources standing by still goes red, which is the stall this was added to surface.
    if feeding == 0 and st ~= "ACTIVE" then col = (SmartDistribution.LINK_COLOR or {}).BLOCKED end
    -- Cells are RECYCLED by SmoothList, so the colour is written on EVERY path rather than left to
    -- inherit the previous row's (the 5.7 / 5.57 trap) -- which matters more now one of them is red.
    if c.setTextColor ~= nil then
        if col ~= nil then c:setTextColor(col[1], col[2], col[3], col[4])
        else c:setTextColor(1, 1, 1, 1) end
    end
end

-- OUTGOING (source-side) status into a row's statusText cell + the same green/orange/red colours:
-- Active (Sending) when it moved product last cycle, Active (Idle) when configured but nothing moved,
-- Blocked when every routable destination is blocked. Blank for Hold / non-sending modes.
local function setOutputStatusCell(cell, placeable, ft, window, role)
    local c = cell:getAttribute("statusText")
    if c == nil then return end
    local st = (placeable ~= nil and ft ~= nil and SmartDistribution ~= nil and SmartDistribution.outputLinkStatus ~= nil)
        and SmartDistribution.outputLinkStatus(placeable, ft, window, role) or nil
    if c.setText ~= nil then
        local base = (st ~= nil) and ((SmartDistribution.OUT_LINK_LABEL or {})[st] or "") or ""
        local suffix = (base ~= "" and SmartDistribution.outputDestCountText ~= nil)
            and (SmartDistribution.outputDestCountText(placeable, ft, role, st) or "") or ""
        c:setText(base .. suffix)
    end
    local col = st ~= nil and (SmartDistribution.LINK_COLOR or {})[st] or nil
    if col ~= nil and c.setTextColor ~= nil then c:setTextColor(col[1], col[2], col[3], col[4])
    elseif c.setTextColor ~= nil then c:setTextColor(1, 1, 1, 1) end
end

function DistributionStoragePage.new(target, custom_mt)
    local self = DistributionMenuPage.new(target, custom_mt or DistributionStoragePage_mt)
    self.pageName = "DISTREDUX_STORAGE"
    self.classFilter = { SILO = true, SHED = true, HEAP = true }   -- Silos / Storage tab: silos, sheds, and manure heaps / slurry pits (all are storage)
    self.assets = {}     -- { { placeable, name, class }, ... }
    self.rows = {}       -- detail rows for the selected asset: { { ft, name }, ... }
    self.selectedAsset = nil
    self.detailIndex = 1
    return self
end

function DistributionStoragePage:onGuiSetupFinished()
    DistributionStoragePage:superClass().onGuiSetupFinished(self)
    self:initPeriodOption()   -- Hour / Month / Year selector; inherited by the Husbandry + Markets layouts
    if self.assetList ~= nil then
        self.assetList:setDataSource(self)
        self.assetList:setDelegate(self)
    end
    if self.detailList ~= nil then
        self.detailList:setDataSource(self)
        self.detailList:setDelegate(self)
    end
    if self.inputList ~= nil then
        self.inputList:setDataSource(self)
        self.inputList:setDelegate(self)
    end
    -- rows that fit each frame at the 42px SDListItemStats pitch (340/42 = 8, 280/42 = 6); this only
    -- hides the scrollbar track when the list does NOT overflow its frame
    -- ONE list now, 672px at the 42px row pitch = 16 rows. The count is "rows that fit the frame", so it
    -- has to move with the height or the scrollbar track hides on a list that does overflow (5.55).
    self._scrollMap = { { "detailSlider", "detailList", 16 } }
end

-- which configurable assets belong on this tab
function DistributionStoragePage:rebuildAssets()
    self.assets = {}
    if SmartDistribution == nil or SmartDistribution.enumerateConfigurableAssets == nil then return end
    local allow = self.classFilter or {}
    for _, a in ipairs(SmartDistribution.enumerateConfigurableAssets()) do
        if allow[a.class] then
            self.assets[#self.assets + 1] = a
        end
    end
end

function DistributionStoragePage:buildDetailRows()
    self.rows = {}
    local asset = self.selectedAsset
    local lister = SmartDistribution ~= nil and (SmartDistribution.assetMenuFillTypes or SmartDistribution.assetFillTypes or SmartDistribution.siloFillTypes) or nil
    if asset == nil or lister == nil then return end
    local fts = lister(asset, self.selectedRole)
    local ordered = {}
    for ft in pairs(fts) do ordered[#ordered + 1] = ft end
    table.sort(ordered)
    self.rows = buildProductRows(asset, ordered, self.selectedRole)
end

function DistributionStoragePage:selectAsset(index)
    local a = self.assets[index]
    self.selectedAsset = a ~= nil and a.placeable or nil
    -- WHICH HALF of the building this row is. nil for an ordinary single-role building, which is every
    -- building bar a handful, and nil means "the primary role" everywhere downstream -- so the whole
    -- role mechanism costs those buildings nothing and changes nothing about them.
    self.selectedRole = a ~= nil and a.role or nil
    if self.assetTitleElement ~= nil then
        self.assetTitleElement:setText(a ~= nil and (a.name or ""):upper() or "")
    end
    -- THE MERGED TABLE IS THE ONLY PRODUCT LIST, and it lives INSIDE inputPanel (see the XML) --
    -- so hiding that panel for a bunker hid its product rows too. The old two-list layout had a
    -- separate output list, which is why this used to work. The merged row already suppresses the
    -- IN status for silos (setCombinedStatusCell), so nothing is lost by always showing the table.
    -- The footer's contextual default stays "output", which is right for every building here.
    self:buildDetailRows()
    self.detailIndex = 1
    self.inputIndex = 1
    if self.detailList ~= nil then
        self.detailList:reloadData()
        -- setSelectedItem, not setSelectedIndex (see selectRowByFt): the latter does not exist on a
        -- SmoothList, so this silently did nothing and a newly selected building kept the old row index.
        if self.detailList.setSelectedItem ~= nil then
            pcall(self.detailList.setSelectedItem, self.detailList, 1, 1)
        end
    end
    if self.inputList ~= nil then self.inputList:reloadData() end
    self:updateSellTimingButton()
end

function DistributionStoragePage:onFrameOpen()
    DistributionStoragePage:superClass().onFrameOpen(self)
    self._realtimeLists = { "detailList" }   -- 2 Hz live-refresh of the number rows (not the asset picker)
    self:rebuildAssets()
    if self.assetList ~= nil then self.assetList:reloadData() end
    self:selectAsset(1)

    self:setSoundSuppressed(true)
    if self.assetList ~= nil then
        FocusManager:setFocus(self.assetList)
        if self.assetList.setSelectedIndex ~= nil then
            pcall(function() self.assetList:setSelectedIndex(1) end)
        end
    end
    self:setSoundSuppressed(false)
end

-- ---- SmoothList delegate (two lists, told apart by identity) ----------------
function DistributionStoragePage:getNumberOfItemsInSection(list, section)
    if list == self.assetList then return #self.assets end
    return #self.rows            -- inputList and detailList show the same products (incoming vs outgoing view)
end

function DistributionStoragePage:populateCellForItemInSection(list, section, index, cell)
    if list == self.assetList then
        local a = self.assets[index]
        if a == nil then return end
        local nameCell = cell:getAttribute("assetName")
        if nameCell ~= nil then nameCell:setText(a.name or "?") end
        -- renamed buildings show the player's name, with the original store name as a secondary label
        local origCell = cell:getAttribute("assetOrigName")
        if origCell ~= nil then origCell:setText(a.origName or "") end
        local typeCell = cell:getAttribute("assetType")
        if typeCell ~= nil then typeCell:setText(storageClassLabel(a.class) or a.class or "") end
        if SmartDistribution.setAssetIcon ~= nil then SmartDistribution.setAssetIcon(cell, a.placeable) end
        return
    end

    -- detail row
    local row = self.rows[index]
    if row == nil then return end
    if row.notice ~= nil then
        renderNoticeRow(cell, row.notice, "inputs")   -- one table, one notice; blocking is input-side
        setModeArrows(cell, nil, self.selectedAsset)                       -- notice row has no mode: hide the arrows
        return
    end
    hideNoticeRow(cell)

    local iconCell = cell:getAttribute("fillIcon")
    if iconCell ~= nil then
        local file = fillIconFile(row.ft)
        if file ~= nil and file ~= "" and iconCell.setImageFilename ~= nil then
            iconCell:setImageFilename(file)
            iconCell:setVisible(true)
        else
            iconCell:setVisible(false)
        end
    end

    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end

    -- ONE ROW PER PRODUCT, carrying both directions. The two lists used to draw this same `self.rows`
    -- twice with different columns; the storage BAR replaced HELD (MAX) and FREE STORAGE, which is what
    -- freed the width to put received, distributed, the mode and both statuses on one line.
    -- heldText / remainingText / typeText no longer exist in this layout, so their setters are gone
    -- rather than writing into nil cells. Husbandry and Productions keep their own two-list layouts and
    -- their own populate overrides, so nothing there is touched.
    applyRowHighlight(cell, true)
    -- BUNKER INPUT ROW: while the heap holds anything OTHER than the declared OUTPUT, the row
    -- is informational -- DR cannot move that material (bunkerTakeSilage only takes the output
    -- type, from an open silo), so a mode here would be inert. Hide the arrows and label the
    -- row plainly; they return the moment the heap converts to the output type.
    local bunkerInputRow = false
    if SmartDistribution.isBunkerSiloPlaceable ~= nil and SmartDistribution.isBunkerSiloPlaceable(self.selectedAsset)
       and SmartDistribution.bunkerOutputFillType ~= nil
       and row.ft ~= SmartDistribution.bunkerOutputFillType(self.selectedAsset) then
        bunkerInputRow = true
    end
    -- WHILE FILLING / FERMENTING, EVERY ROW IS INFORMATIONAL: the mode cannot act yet, so
    -- every row shows the stage label and an orange tint, not the stored mode.
    if SmartDistribution.isBunkerSiloPlaceable ~= nil and SmartDistribution.bunkerStage ~= nil
       and SmartDistribution.isBunkerSiloPlaceable(self.selectedAsset)
       and (SmartDistribution.bunkerStage(self.selectedAsset) == "filling"
            or SmartDistribution.bunkerStage(self.selectedAsset) == "fermenting"
            or SmartDistribution.bunkerStage(self.selectedAsset) == "fermented") then
        bunkerInputRow = true
    end

    setc("fillName", row.name)
    -- STORAGE TYPE, abbreviated. Role-scoped like every other read on this row: without the role a
    -- building that is a silo AND a pallet store answers the silo's rows from the SHED pool (5.65 /
    -- 6.30). Already listed in NOTICE_CELLS, so the notice row clears it like every other cell.
    setc("typeText", (SmartDistribution.storageTypeLabel ~= nil)
        and (SmartDistribution.storageTypeLabel(self.selectedAsset, row.ft, self.selectedRole, true) or "") or "")

    local e = self:windowStats(row.ft)
    setc("recvText", fmtV(e.received))
    setc("distText", outTotalText(e))
    -- Held amount for the storage bar. assetHeld answers every ordinary building; a
    -- bunker silo owns no Storage, so bunkerHeldForDisplay returns the heap amount for
    -- the row the heap actually holds (nil for non-bunkers, so the figure stands).
    local barHeld = 0
    if SmartDistribution.assetHeld ~= nil then
        barHeld = SmartDistribution.assetHeld(self.selectedAsset, row.ft) or 0
        if SmartDistribution.bunkerHeldForDisplay ~= nil then
            local bh = SmartDistribution.bunkerHeldForDisplay(self.selectedAsset, row.ft)
            if bh ~= nil then barHeld = bh end
        end
    end
    setStorageBar(cell, self.selectedAsset, row.ft, self.selectedRole, nil, barHeld)

    -- Arrows STAY HIDDEN on a bunker's filling/fermenting row. The mode can't act yet
    -- (bunkerTakeSilage only pulls the output type from an open silo), and showing
    -- live arrows that change an inert setting would only confuse. They return when the
    -- heap converts to the output type and bunkerInputRow goes false.
    -- setModeArrows also clears sdFillType to nil, which stepRowMode (line 877) rejects,
    -- so the arrows are inert even if somehow still visible.
    setModeArrows(cell, bunkerInputRow and nil or row.ft, self.selectedAsset)

    local modeCell = cell:getAttribute("modeText")
    if modeCell ~= nil then
        if bunkerInputRow then
            -- Stage-aware label: "Filling", "Fermenting", or "Fermented - uncover to access"
            local stage = (SmartDistribution.bunkerStage ~= nil)
                and SmartDistribution.bunkerStage(self.selectedAsset) or nil
            local label
            if stage == "fermenting" then
                label = SmartDistribution.l10n("dr_bunker_fermenting", "Fermenting")
            elseif stage == "fermented" then
                label = SmartDistribution.l10n("dr_bunker_fermented", "Fermented - uncover to access")
            else
                label = SmartDistribution.l10n("dr_bunker_filling", "Filling")
            end
            modeCell:setText(label)
            if modeCell.setTextColor ~= nil then modeCell:setTextColor(0.95, 0.65, 0.20, 1) end
        else
            local pal = (SmartDistribution.holdLabelFlag ~= nil)
                and SmartDistribution.holdLabelFlag(self.selectedAsset, row.ft) or false
            local text = SmartDistribution.modeName(SmartDistribution.resolvedAssetMode(self.selectedAsset, row.ft, self.selectedRole), pal)
            local timing = (SmartDistribution.sellTimingLabel ~= nil)
                and SmartDistribution.sellTimingLabel(self.selectedAsset, row.ft, nil, self.selectedRole) or nil
            if timing ~= nil then text = text .. "  -  " .. timing end
            modeCell:setText(text)
            if modeCell.setTextColor ~= nil then modeCell:setTextColor(1, 1, 1, 1) end
        end
    end



    -- BOTH directions in the one status cell now that there is one row per product
    setCombinedStatusCell(cell, self.selectedAsset, row.ft, self:currentWindow(), self.selectedRole)
end

function DistributionStoragePage:onListSelectionChanged(list, section, index)
    if list == self.assetList then
        self:selectAsset(index)
    elseif list == self.detailList then
        self.detailIndex = index
        self:_focusOn("output")
        self:updateSellTimingButton()
    elseif list == self.inputList then
        self.inputIndex = index
        self:_focusOn("input")
        self:updateSellTimingButton()
    end
end

function DistributionStoragePage:onClickAsset(element) end
function DistributionStoragePage:onClickDetailRow(element) end

-- selecting an input row switches the footer's Advanced button to the input (Advanced Inputs) context.
function DistributionStoragePage:onInputSelectionChanged(list, section, index)
    self.inputIndex = index
    self:_focusOn("input")
    self:updateSellTimingButton()
end
function DistributionStoragePage:onClickInputRow(element) end

-- Only ONE of the input / output(detail) lists should be the active selection at a time. Move keyboard
-- focus to the list the player just touched: FocusManager gives the focused list the active highlight and
-- the other list's row recedes, so a single selection reads as current. _focusRole drives the footer.
function DistributionStoragePage:_focusOn(role)
    if self._focusing then return end   -- reloadData below can re-enter selection events; guard against recursion
    self._focusing = true
    self._focusRole = role
    local keep = (role == "input") and self.inputList or self.detailList
    if keep ~= nil and FocusManager ~= nil and FocusManager.setFocus ~= nil then
        pcall(function() FocusManager:setFocus(keep) end)
    end
    -- repaint both lists so the highlight suppression (applyRowHighlight) reflects the new active list
    if self.inputList ~= nil then self.inputList:reloadData() end
    if self.detailList ~= nil then self.detailList:reloadData() end
    self._focusing = false
end

-- ---- footer actions (wired from the menu's setMenuButtonInfo) ---------------
function DistributionStoragePage:selectedDetailRow()
    local r = self.rows[self.detailIndex or 1]
    -- the "+N blocked" row is a message, not a product: every footer action (cycle mode, sell timing,
    -- Advanced) must see it as no selection at all rather than acting on a nil fill type
    if r ~= nil and r.notice ~= nil then return nil end
    return r
end

-- current best-price/immediate label of the selected product (nil if not a sell mode)
function DistributionStoragePage:currentSellTimingLabel()
    local row = self:selectedDetailRow()
    if row == nil or self.selectedAsset == nil or SmartDistribution.sellTimingLabel == nil then return nil end
    return SmartDistribution.sellTimingLabel(self.selectedAsset, row.ft, nil, self.selectedRole)
end

-- rebuild the footer button list, showing the Sell Timing button ONLY when the selected output is a
-- sell mode (Sell / Distribute + Sell); otherwise it's dropped from the list entirely.
function DistributionStoragePage:updateSellTimingButton()
    local all = self._allButtons
    if all == nil then return end
    local label = self:currentSellTimingLabel()
    -- The single "Advanced" button is CONTEXTUAL: it acts on whichever list last had focus. With an input
    -- row focused it becomes "Advanced Inputs"; with an output/detail row focused it's "Advanced Outputs".
    local row = self:selectedDetailRow()
    -- Advanced routing master switch (Settings): off hides both Advanced buttons entirely.
    local adv = SmartDistribution.advancedEnabled == nil or SmartDistribution.advancedEnabled()
    -- NOTE markets never reach this function: DistributionMarketsPage overrides updateSellTimingButton and
    -- decides its own footer (Advanced Inputs only). Do not add a market case here -- it would be dead code.
    local showAdvancedOut = adv and row ~= nil and row.ft ~= nil and self.selectedAsset ~= nil
        and SmartDistribution.modeConfigurable ~= nil
        and SmartDistribution.modeConfigurable(self.selectedAsset, row.ft, self.selectedRole)
    local showAdvancedIn = adv and self.selectedAsset ~= nil and SmartDistribution.receiverInputFillTypes ~= nil
        and next(SmartDistribution.receiverInputFillTypes(self.selectedAsset)) ~= nil
    -- Shared CANCEL slot: "Spawn Pallets" for a Hold Internal pallet output holding at least one pallet's
    -- worth (coops / sheep), else "Sell Timing" for a sell output, else hidden. The two never overlap.
    local spawnReady = row ~= nil and row.ft ~= nil and self.selectedAsset ~= nil
        and SmartDistribution.palletSpawnReady ~= nil
        and SmartDistribution.palletSpawnReady(self.selectedAsset, row.ft)
    local vis = {}
    for _, b in ipairs(all) do
        if b._role == "sellTiming" then
            if spawnReady then b.text = SmartDistribution.l10n("dr_title_spawnPallets", "Spawn Pallets"); vis[#vis + 1] = b
            elseif label ~= nil then b.text = string.format(SmartDistribution.l10n("dr_btn_sellTimingValue", "Sell Timing: %s"), label); vis[#vis + 1] = b end
        -- TWO BUTTONS, EACH SHOWN ON ITS OWN MERIT. The single contextual button dispatched on which list
        -- was last touched, and the merged table has one list -- so there is nothing left to infer from.
        -- Each still hides when it would open on nothing, which is what the two flags below decide.
        elseif b._role == "advancedIn" then
            if showAdvancedIn then vis[#vis + 1] = b end
        elseif b._role == "advancedOut" then
            if showAdvancedOut then vis[#vis + 1] = b end
        else
            vis[#vis + 1] = b
        end
    end
    self:applyFooterButtons(vis)
end

-- The footer's single Advanced button dispatches by which list last had focus.
function DistributionStoragePage:onAdvancedContextual()
    if (self._focusRole or "output") == "input" then
        if self.onAdvancedInputs ~= nil then self:onAdvancedInputs() end
    else
        if self.onAdvanced ~= nil then self:onAdvanced() end
    end
end

-- SELECT THE ROW AN ARROW WAS PRESSED ON, so the line the player just changed is the highlighted one
-- and the footer's Sell Timing / Advanced buttons act on it too.
--
-- The arrows do not select on their own, by construction: SmoothList treats a click as row-selection
-- only when no CHILD consumed it (mouseEvent calls its superclass first and gates on `not eventUsed`),
-- and the button consumes it. That is what stops an arrow press from also toggling the selection -- so
-- the selection has to be set here, explicitly.
--
-- setSelectedItem, NOT setSelectedIndex. The latter has no definition anywhere in the shipped source and
-- its only two base-game call sites are on the paging TAB list, a different element class; every caller
-- on a SmoothList uses setSelectedItem(section, index). DR has eleven pcall-wrapped setSelectedIndex
-- calls that are therefore silent no-ops -- the one on this path is corrected below, the rest are left
-- alone rather than changed blind, since "fixing" them would start moving selections that currently
-- stay put.
function DistributionStoragePage:selectRowByFt(ft)
    if ft == nil then return end
    local rows, list = self.rows, self.detailList
    if list == nil and self.outputList ~= nil then rows, list = self.outputRows, self.outputList end
    if rows == nil or list == nil or list.setSelectedItem == nil then return end
    for i, r in ipairs(rows) do
        if r ~= nil and r.ft == ft then
            self.detailIndex = i                       -- what selectedDetailRow reads
            pcall(list.setSelectedItem, list, 1, i)
            return
        end
    end
end

-- In-row arrows: step this product's mode one place either way, and select that row.
-- Shares applyMode with the footer "Cycle Output" so all three routes behave identically (same MP
-- replication, same refresh, same sell-timing button update).
function DistributionStoragePage:onModePrev(...) self:stepRowMode(-1, ...) end
function DistributionStoragePage:onModeNext(...) self:stepRowMode( 1, ...) end

function DistributionStoragePage:stepRowMode(dir, ...)
    local el = clickedArrow(...)
    local ft = (el ~= nil) and el.sdFillType or nil
    if ft == nil or self.selectedAsset == nil then return end
        local bs
    if SmartDistribution.bunkerIsSealed ~= nil and SmartDistribution.bunkerIsSealed(self.selectedAsset) then return end
    local cur = SmartDistribution.resolvedAssetMode(self.selectedAsset, ft, self.selectedRole)
    local nxt
    if dir < 0 then
        nxt = (SmartDistribution.cyclePrevForAsset ~= nil)
              and SmartDistribution.cyclePrevForAsset(self.selectedAsset, cur, ft, self.selectedRole) or cur
    else
        nxt = (SmartDistribution.cycleNextForAsset ~= nil)
              and SmartDistribution.cycleNextForAsset(self.selectedAsset, cur, ft, self.selectedRole)
              or SmartDistribution.cycleNext(cur)
    end
    if nxt == nil or nxt == cur then return end
    SmartDistribution.applyAssetMode(self.selectedAsset, ft, nxt, false, self.selectedRole)
    -- Silos use detailList; Animal Husbandry has separate input/output lists. Reload whichever this
    -- page actually has, rather than making each subclass override this the way onCycleSelected has to.
    if self.detailList ~= nil then self.detailList:reloadData() end
    if self.outputList ~= nil then self.outputList:reloadData() end
    self:selectRowByFt(ft)          -- AFTER the reload, so it lands on the rebuilt cells
    self:updateSellTimingButton()
end

-- ---- Z = step the selected output mode BACKWARD ------------------------------------------------
-- A RAW KEY, not an input action, and that is a deliberate trade.
--
-- The game defines only two spare menu actions (MENU_EXTRA_1 = x, EXTRA_2 = c) and both are already
-- used here; ACCEPT / ACTIVATE / BACK / CANCEL / PAGE_PREV / PAGE_NEXT are all taken too. A custom
-- DR action would work but only shows up usefully as another FOOTER button, and the footer is
-- deliberately not growing. So the key is read directly instead.
--
-- The cost, stated plainly: Z is HARDCODED and cannot be rebound in Options > Controls. The on-page
-- hint (dr_lbl_modeKeys) is what tells the player, since there is no footer glyph to do it.
--
-- THE HANDLER ITSELF LIVES ON THE MENU (DistributionMenu:keyEvent), not here, and this page carries
-- only the action it calls (onCycleSelectedBack) plus the opt-out flag below. A page-level keyEvent
-- was tried first and removed: Gui:keyEvent dispatches to g_gui.currentListener and its target, so
-- reaching a frame that way is not something to rely on. See the menu for the modifier trap that
-- actually kept this key dead (a permanently-set 4096 lock bit vs. a `modifier == 0` guard).
DistributionStoragePage.MODE_KEYS_ENABLED = true


-- The exact mirror of onCycleSelected below, acting on the SELECTED row rather than a clicked arrow,
-- so the key and the in-row arrows always agree.
function DistributionStoragePage:onCycleSelectedBack()
    local row = self:selectedDetailRow()
    if row == nil or self.selectedAsset == nil then return end
        local bs
    if SmartDistribution.bunkerIsSealed ~= nil and SmartDistribution.bunkerIsSealed(self.selectedAsset) then return end
    if SmartDistribution.cyclePrevForAsset == nil then return end
    local cur = SmartDistribution.resolvedAssetMode(self.selectedAsset, row.ft, self.selectedRole)
    local nxt = SmartDistribution.cyclePrevForAsset(self.selectedAsset, cur, row.ft, self.selectedRole)
    if nxt == nil or nxt == cur then return end
    SmartDistribution.applyAssetMode(self.selectedAsset, row.ft, nxt, false, self.selectedRole)
    if self.detailList ~= nil then self.detailList:reloadData() end
    if self.outputList ~= nil then self.outputList:reloadData() end
    -- no selectRowByFt here: this acts on the row that is ALREADY selected
    self:updateSellTimingButton()
end

function DistributionStoragePage:onCycleSelected()
    local row = self:selectedDetailRow()
    if row == nil or self.selectedAsset == nil then return end
        local bs
    if SmartDistribution.bunkerIsSealed ~= nil and SmartDistribution.bunkerIsSealed(self.selectedAsset) then return end
    local cur = SmartDistribution.resolvedAssetMode(self.selectedAsset, row.ft, self.selectedRole)
    local nxt = (SmartDistribution.cycleNextForAsset and SmartDistribution.cycleNextForAsset(self.selectedAsset, cur, row.ft, self.selectedRole))
                or SmartDistribution.cycleNext(cur)
    SmartDistribution.applyAssetMode(self.selectedAsset, row.ft, nxt, false, self.selectedRole)
    if self.detailList ~= nil then self.detailList:reloadData() end
    self:updateSellTimingButton()
end

-- footer "Advanced Outputs": granular routing for this building (rank demands, block one, pick stores)
function DistributionStoragePage:onAdvanced()
    if self.selectedAsset == nil or SmartDistribution.openAdvancedDialog == nil then return end
    local row = self:selectedDetailRow()
    if row == nil or row.ft == nil then return end
    SmartDistribution.openAdvancedDialog(self.selectedAsset, row.ft, self.selectedRole)
end

-- footer "Advanced Inputs": receiver-side block + per-product max %% for this building
function DistributionStoragePage:onAdvancedInputs()
    if self.selectedAsset == nil or SmartDistribution.openInputsDialog == nil then return end
    SmartDistribution.openInputsDialog(self.selectedAsset, self.selectedRole)
end

function DistributionStoragePage:onSellTiming()
    local row = self:selectedDetailRow()
    if row == nil or self.selectedAsset == nil or SmartDistribution.toggleSellTiming == nil then return end
    if not SmartDistribution.toggleSellTiming(self.selectedAsset, row.ft) then return end
    if self.detailList ~= nil then self.detailList:reloadData() end
    self:updateSellTimingButton()
end

-- The shared CANCEL footer slot dispatches to Spawn (a ready Hold Internal pallet output) or Sell Timing.
function DistributionStoragePage:onSellTimingOrSpawn()
    local row = self:selectedDetailRow()
    if row == nil or row.ft == nil or self.selectedAsset == nil then return end
    if SmartDistribution.palletSpawnReady ~= nil and SmartDistribution.palletSpawnReady(self.selectedAsset, row.ft) then
        self:onSpawn()
    else
        self:onSellTiming()
    end
end

-- Spawn `count` pallet(s) of the selected Hold Internal output from its internal buffer (MP-safe via the
-- event). Opens the shared count pop-up; the completion hook refreshes this page as each pallet fills.
function DistributionStoragePage:onSpawn(count)
    local row = self:selectedDetailRow()
    if row == nil or row.ft == nil or self.selectedAsset == nil then return end
    local page, asset, ft = self, self.selectedAsset, row.ft
    local function refreshHook()
        SmartDistribution._spawnCompleteCb = function()
            pcall(function()
                -- the husbandry layout has no detailList (inputs/outputs are split lists); reload whatever exists
                if page.detailList ~= nil then page.detailList:reloadData() end
                if page.outputList ~= nil then page.outputList:reloadData() end
                page:updateSellTimingButton()
            end)
        end
    end
    if SmartDistribution.openSpawnDialog ~= nil and SmartDistribution.openSpawnDialog(asset, ft, function(option, n, liters)
            if DistributionSpawnEvent ~= nil and DistributionSpawnEvent.request ~= nil then
                refreshHook()
                -- option carries the pallet TYPE the player picked; liters is the exact total requested
                DistributionSpawnEvent.request(asset, ft, n, option ~= nil and option.filename or nil, liters)
            end
        end) then
        return
    end
    if DistributionSpawnEvent ~= nil and DistributionSpawnEvent.request ~= nil then
        refreshHook()
        DistributionSpawnEvent.request(asset, ft, count or 1)   -- fallback: default type, fill each pallet
    end
end

-- [ + gaze entry: jump the building list to a specific placeable and select it
-- (called right after this tab is switched to, so the list is already populated).
function DistributionStoragePage:selectPlaceable(placeable, role)
    if placeable == nil then return end
    self:rebuildAssets()
    if self.assetList ~= nil then self.assetList:reloadData() end
    local target = 1
    -- A building that does two jobs has two rows on this tab. Prefer the one the caller MEANT (the
    -- gazed building's primary role), falling back to whichever row comes first -- so walking up to a
    -- DriveIn and pressing [ lands on its silo rather than on its pallet store.
    local first = nil
    for i, a in ipairs(self.assets) do
        if a.placeable == placeable then
            if first == nil then first = i end
            if role == nil or a.role == role then first = i; break end
        end
    end
    if first ~= nil then target = first end
    self:selectAsset(target)
    self:setSoundSuppressed(true)
    if self.assetList ~= nil then
        if self.assetList.setSelectedIndex ~= nil then
            pcall(function() self.assetList:setSelectedIndex(target) end)
        end
        pcall(function() FocusManager:setFocus(self.assetList) end)
    end
    self:setSoundSuppressed(false)
end

-- ---- tab variants: the same master-detail page, filtered to one asset class --
-- Animal Husbandry tab (barns / pens / coops + beehive honey spawners).
DistributionAnimalHusbandryPage = {}
local DistributionAnimalHusbandryPage_mt = Class(DistributionAnimalHusbandryPage, DistributionStoragePage)
function DistributionAnimalHusbandryPage.new(target, custom_mt)
    local self = DistributionStoragePage.new(target, custom_mt or DistributionAnimalHusbandryPage_mt)
    self.pageName = "DISTREDUX_HUSBANDRY"
    self.classFilter = { HUSBANDRY = true }   -- barns / pens only (manure heaps + slurry pits are storage -> Silos tab)
    self.inputRows = {}
    self.outputRows = {}
    return self
end

-- two detail lists: INPUTS (demand) on top, OUTPUTS on the bottom.
-- HUSBANDRY'S FOOTER IS THE PRODUCTIONS ONE, not the base class's. The base was rewritten for the
-- MERGED Silos / Markets table, where a single row carries both directions so a contextual Advanced
-- button has nothing to infer from and had to become two explicit ones (advancedIn / advancedOut).
-- A pen keeps TWO lists, so the contextual button works exactly as it always did -- and without this
-- override the inherited filter would not match the "advanced" role at all, dropping it into the
-- catch-all `else` and showing it unconditionally, past both visibility gates AND the Advanced master
-- switch. Same trap the Productions page is one rename away from; see the note in DistributionMenu.
--
-- Deliberately a near-copy of DistributionProductionsPage's version: the two pages are meant to be
-- aligned (author, 2026-08-26), so they should read alike. Change them together.
function DistributionAnimalHusbandryPage:updateSellTimingButton()
    local all = self._allButtons
    if all == nil then return end
    local label = self:currentSellTimingLabel()
    local row   = self:selectedDetailRow()
    local adv   = SmartDistribution.advancedEnabled == nil or SmartDistribution.advancedEnabled()
    local showAdvancedOut = adv and row ~= nil and row.ft ~= nil and self.selectedAsset ~= nil
        and SmartDistribution.modeConfigurable ~= nil
        and SmartDistribution.modeConfigurable(self.selectedAsset, row.ft, self.selectedRole)
    local showAdvancedIn = adv and self.selectedAsset ~= nil and SmartDistribution.receiverInputFillTypes ~= nil
        and next(SmartDistribution.receiverInputFillTypes(self.selectedAsset)) ~= nil
    -- Shared CANCEL slot: "Spawn Pallets" for a Hold Internal pallet output holding a full pallet's worth
    -- (coops / sheep), else "Sell Timing" for a sell output, else hidden. The two never overlap.
    local spawnReady = row ~= nil and row.ft ~= nil and self.selectedAsset ~= nil
        and SmartDistribution.palletSpawnReady ~= nil
        and SmartDistribution.palletSpawnReady(self.selectedAsset, row.ft)
    local focus = self._focusRole or "output"
    local vis = {}
    for _, b in ipairs(all) do
        if b._role == "sellTiming" then
            if spawnReady then b.text = SmartDistribution.l10n("dr_title_spawnPallets", "Spawn Pallets"); vis[#vis + 1] = b
            elseif label ~= nil then b.text = string.format(SmartDistribution.l10n("dr_btn_sellTimingValue", "Sell Timing: %s"), label); vis[#vis + 1] = b end
        elseif b._role == "advanced" then
            if focus == "input" then
                if showAdvancedIn then b.text = SmartDistribution.l10n("dr_title_advancedInputs", "Advanced Inputs"); vis[#vis + 1] = b end
            else
                if showAdvancedOut then b.text = SmartDistribution.l10n("dr_btn_advancedOutputs", "Advanced Outputs"); vis[#vis + 1] = b end
            end
        else
            vis[#vis + 1] = b
        end
    end
    self:applyFooterButtons(vis)
end

function DistributionAnimalHusbandryPage:onGuiSetupFinished()
    DistributionStoragePage.onGuiSetupFinished(self)   -- sets up assetList (this layout has no detailList)
    if self.inputList ~= nil then
        self.inputList:setDataSource(self); self.inputList:setDelegate(self)
    end
    if self.outputList ~= nil then
        self.outputList:setDataSource(self); self.outputList:setDelegate(self)
    end
    -- rows that fit each frame at the 42px SDListItemStats pitch (280/42 = 6, 340/42 = 8)
    self._scrollMap = { { "inputSlider", "inputList", 6 }, { "outputSlider", "outputList", 8 } }
    -- THE ANIMAL PANEL (API v4). Only an extension that has registered a provider moves anything;
    -- with none registered this is one boolean and the tab is byte-identical to before. reflowForPanel
    -- rewrites _scrollMap itself, so it must run AFTER the line above rather than before it.
    if SmartDistribution ~= nil and SmartDistribution.hasHusbandryPanel ~= nil
       and SmartDistribution.hasHusbandryPanel() and SmartDistribution.reflowForPanel ~= nil then
        SmartDistribution.reflowForPanel(self)
    end
end

-- This layout's output rows live in outputList (there is no detailList), so the inherited onFrameOpen's
-- realtime set { inputList, detailList } never refreshes the output side -- husbandry distributed/sold/held
-- would sit stale between selections. Re-point the realtime set at outputList after super runs. Output cells
-- read all figures live in populateCellForItemInSection, so a plain reloadData refreshes them; no
-- rebuildRealtimeData needed. Safe from focus-stealing now that refreshRealtimeLists holds the _focusing guard.
function DistributionAnimalHusbandryPage:onFrameOpen()
    DistributionStoragePage.onFrameOpen(self)
    self._realtimeLists = { "inputList", "outputList" }
    self:refreshAnimalPanel()
end

function DistributionAnimalHusbandryPage:buildDetailRows()
    self.inputRows = {}
    self.outputRows = {}
    local asset = self.selectedAsset
    if asset == nil or SmartDistribution == nil then return end
    if SmartDistribution.husbandryInputFillTypes ~= nil then
        local ins = {}
        for ft in pairs(SmartDistribution.husbandryInputFillTypes(asset)) do ins[#ins + 1] = ft end
        table.sort(ins)
        self.inputRows = buildProductRows(asset, ins, self.selectedRole)
    end
    if SmartDistribution.husbandryOutputSet ~= nil then
        local outs = {}
        for ft in pairs(SmartDistribution.husbandryOutputSet(asset)) do outs[#outs + 1] = ft end
        table.sort(outs)
        self.outputRows = buildProductRows(asset, outs, self.selectedRole)
    end
end

function DistributionAnimalHusbandryPage:selectAsset(index)
    local a = self.assets[index]
    self.selectedAsset = a ~= nil and a.placeable or nil
    if self.assetTitleElement ~= nil then
        self.assetTitleElement:setText(a ~= nil and (a.name or ""):upper() or "")
    end
    self:buildDetailRows()
    self.detailIndex = 1
    if self.inputList ~= nil then self.inputList:reloadData() end
    if self.outputList ~= nil then self.outputList:reloadData() end
    self:refreshAnimalPanel()
    self:updateSellTimingButton()
end

-- The panel is LIVE state (a trough fills, an animal is born), so it is redrawn on selection AND on
-- the page refresh rather than only when the building changes. drawHusbandryPanel hides the strip
-- itself when a barn answers with nothing, so a husbandry the provider knows nothing about leaves a
-- gap rather than showing the previous building's herd.
-- rebuildRealtimeData is the hook DistributionMenuPage:refreshRealtimeLists already calls on every
-- timed refresh, for pages that cache figures rather than reading them live. This page reads live, so
-- it never needed one -- but the PANEL is not a list cell and nothing else would repaint it, so this
-- is the existing seam rather than a second timer.
function DistributionAnimalHusbandryPage:rebuildRealtimeData()
    self:refreshAnimalPanel()
end

function DistributionAnimalHusbandryPage:refreshAnimalPanel()
    if self.animalPanel == nil or SmartDistribution == nil then return end
    if SmartDistribution.drawHusbandryPanel == nil then return end
    local d = nil
    if self.selectedAsset ~= nil and SmartDistribution.husbandryPanelData ~= nil then
        d = SmartDistribution.husbandryPanelData(self.selectedAsset)
    end
    SmartDistribution.drawHusbandryPanel(self.animalPanel, d)
end

function DistributionAnimalHusbandryPage:getNumberOfItemsInSection(list, section)
    if list == self.assetList then return #self.assets end
    if list == self.inputList then return #self.inputRows end
    if list == self.outputList then return #self.outputRows end
    return 0
end

function DistributionAnimalHusbandryPage:populateCellForItemInSection(list, section, index, cell)
    if list == self.assetList then
        return DistributionStoragePage.populateCellForItemInSection(self, list, section, index, cell)
    end
    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end
    local function setIcon(ft)
        local ic = cell:getAttribute("fillIcon")
        if ic == nil then return end
        local file = fillIconFile(ft)
        if file ~= nil and file ~= "" and ic.setImageFilename ~= nil then
            ic:setImageFilename(file); ic:setVisible(true)
        else
            ic:setVisible(false)
        end
    end

    if list == self.inputList then
        local row = self.inputRows[index]; if row == nil then return end
        if row.notice ~= nil then renderNoticeRow(cell, row.notice, "inputs"); return end
        hideNoticeRow(cell)
        applyRowHighlight(cell, (self._focusRole or "output") == "input")
        setIcon(row.ft); setc("fillName", row.name)
        local e = self:windowStats(row.ft)
        local held = (SmartDistribution.husbandryInputHeld ~= nil) and SmartDistribution.husbandryInputHeld(self.selectedAsset, row.ft) or 0
        setc("recvText", fmtV(e.received))
        setc("consumedText", fmtV(e.consumed))
        setc("typeText", (SmartDistribution.storageTypeLabel ~= nil)
            and SmartDistribution.storageTypeLabel(self.selectedAsset, row.ft, self.selectedRole, true) or "")
        -- The BAR replaces the held/max text and the free-storage cell, with the MAX and TARGET marks.
        -- A pen PULLS its feed, so a fill target binds here and is worth showing.
        setStorageBar(cell, self.selectedAsset, row.ft, self.selectedRole, "input")
        setStatusCell(cell, self.selectedAsset, row.ft, self:currentWindow(), self.selectedRole)
    elseif list == self.outputList then
        local row = self.outputRows[index]; if row == nil then return end
        if row.notice ~= nil then renderNoticeRow(cell, row.notice, "outputs"); setModeArrows(cell, nil, self.selectedAsset); return end
        hideNoticeRow(cell)
        setModeArrows(cell, row.ft, self.selectedAsset)                    -- in-row mode arrows, as on the Silos tab
        applyRowHighlight(cell, (self._focusRole or "output") ~= "input")
        setIcon(row.ft); setc("fillName", row.name)
        local e = self:windowStats(row.ft)
        local held = (SmartDistribution.roleHeld ~= nil)
        and SmartDistribution.roleHeld(self.selectedAsset, row.ft, self.selectedRole) or nil
    if held == nil then
        held = (SmartDistribution.assetHeld ~= nil) and SmartDistribution.assetHeld(self.selectedAsset, row.ft) or 0
    end
        setc("prodText", fmtV(e.produced))
        setc("distText", outTotalText(e))
        -- The BAR replaces the held text and the free-storage cell. An OUTPUT gets the RESERVE mark and
        -- not max/target. `held` is handed in because assetHeld already folds a pen's pallets AND its
        -- pending queue into one figure (5.21) -- outputBarValues re-reading it would be a second basis.
        setStorageBar(cell, self.selectedAsset, row.ft, self.selectedRole, "output", held)
        local modeCell = cell:getAttribute("modeText")
        if modeCell ~= nil then
            -- palletizable flag passed so a pallet output reads "Hold Pallets" rather than a bare "Hold",
        -- matching the Productions tab for the same pair of modes
        local pal = (SmartDistribution.holdLabelFlag ~= nil)
            and SmartDistribution.holdLabelFlag(self.selectedAsset, row.ft) or false
        local text = SmartDistribution.modeName(SmartDistribution.resolvedAssetMode(self.selectedAsset, row.ft, self.selectedRole), pal)
            local timing = (SmartDistribution.sellTimingLabel ~= nil)
                and SmartDistribution.sellTimingLabel(self.selectedAsset, row.ft, nil, self.selectedRole) or nil
            if timing ~= nil then text = text .. "  -  " .. timing end
            modeCell:setText(text)
        end
        setOutputStatusCell(cell, self.selectedAsset, row.ft, self:currentWindow(), self.selectedRole)
    end
end

function DistributionAnimalHusbandryPage:onListSelectionChanged(list, section, index)
    if list == self.assetList then
        self:selectAsset(index)
    elseif list == self.outputList then
        self.detailIndex = index   -- outputs carry the sell mode; the footer acts on the selected output
        self:_focusOn("output")
        self:updateSellTimingButton()
    elseif list == self.inputList then
        self.inputIndex = index
        self:_focusOn("input")
        self:updateSellTimingButton()
    end
end

-- selecting an input row switches the footer's Advanced button to the input (Advanced Inputs) context.
function DistributionAnimalHusbandryPage:onInputSelectionChanged(list, section, index)
    self.inputIndex = index
    self:_focusOn("input")
    self:updateSellTimingButton()
end

-- husbandry's output side is outputList (not detailList), so it needs its own focus swap.
function DistributionAnimalHusbandryPage:_focusOn(role)
    if self._focusing then return end
    self._focusing = true
    self._focusRole = role
    local keep = (role == "input") and self.inputList or self.outputList
    if keep ~= nil and FocusManager ~= nil and FocusManager.setFocus ~= nil then
        pcall(function() FocusManager:setFocus(keep) end)
    end
    if self.inputList ~= nil then self.inputList:reloadData() end
    if self.outputList ~= nil then self.outputList:reloadData() end
    self._focusing = false
end

function DistributionAnimalHusbandryPage:onClickInputRow(element) end
function DistributionAnimalHusbandryPage:onClickOutputRow(element) end

-- footer mode / sell-timing actions operate on the selected OUTPUT row (inputs are demand-only)
function DistributionAnimalHusbandryPage:selectedDetailRow()
    local r = self.outputRows[self.detailIndex or 1]
    if r ~= nil and r.notice ~= nil then return nil end
    return r
end

-- the base footer handlers reload self.detailList (absent in this layout); refresh the output list instead
function DistributionAnimalHusbandryPage:onCycleSelected()
    DistributionStoragePage.onCycleSelected(self)
    if self.outputList ~= nil then self.outputList:reloadData() end
end
function DistributionAnimalHusbandryPage:onSellTiming()
    DistributionStoragePage.onSellTiming(self)
    if self.outputList ~= nil then self.outputList:reloadData() end
end

-- ---- Markets tab: owned sell points (kiosks / farmers markets) --------------
-- Same master-detail shell, but the detail list shows each accepted item's buffer,
-- distributed-in and sold /mo, and the mode is locked to Sell with a per-market
-- Immediate / Best-price timing toggle (footer "Timing").
DistributionMarketsPage = {}
local DistributionMarketsPage_mt = Class(DistributionMarketsPage, DistributionStoragePage)
-- Markets HAS mode keys and in-row arrows, like every other tab -- but they drive the market TIMING ring
-- (Hold -> Sell Immediate -> Sell Best price), NOT the asset mode ring, which is why stepRowMode is
-- overridden below. 5.64 originally excluded this page on the grounds that its MODE column is a different
-- enum; that argued for giving it its OWN ring rather than for having no arrows at all, and the gap
-- surfaced 2026-08-21 as "I can not change the market output mode" (the third state was unreachable --
-- see marketTimingNext).
DistributionMarketsPage.MODE_KEYS_ENABLED = true
function DistributionMarketsPage.new(target, custom_mt)
    local self = DistributionStoragePage.new(target, custom_mt or DistributionMarketsPage_mt)
    self.pageName = "DISTREDUX_MARKETS"
    self.classFilter = { MARKET = true }
    return self
end

function DistributionMarketsPage:buildDetailRows()
    self.rows = {}
    local asset = self.selectedAsset
    if asset == nil or SmartDistribution == nil or SmartDistribution.marketMenuFillTypes == nil then return end
    local ordered = {}
    for ft in pairs(SmartDistribution.marketMenuFillTypes(asset)) do ordered[#ordered + 1] = ft end
    table.sort(ordered)
    self.rows = buildProductRows(asset, ordered, self.selectedRole)
end

function DistributionMarketsPage:populateCellForItemInSection(list, section, index, cell)
    if list == self.assetList then
        return DistributionStoragePage.populateCellForItemInSection(self, list, section, index, cell)
    end
    local row = self.rows[index]
    if row == nil then return end
    if row.notice ~= nil then
        renderNoticeRow(cell, row.notice, "inputs")   -- one table, one notice; blocking is input-side
        setModeArrows(cell, nil, self.selectedAsset)                       -- notice row has no timing: hide the arrows
        return
    end
    hideNoticeRow(cell)
    setModeArrows(cell, row.ft, self.selectedAsset)   -- one table, so every real row carries the timing arrows
    local iconCell = cell:getAttribute("fillIcon")
    if iconCell ~= nil then
        local file = fillIconFile(row.ft)
        if file ~= nil and file ~= "" and iconCell.setImageFilename ~= nil then
            iconCell:setImageFilename(file); iconCell:setVisible(true)
        else
            iconCell:setVisible(false)
        end
    end
    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end
    -- ONE ROW PER PRODUCT. A market's buffer IS its own storage, and it resolves through
    -- inputProductCapacity -> marketCap like any other receiver (5.36), so the same bar helper draws it:
    -- green is what the market is holding, the track is marketCap. There is no red, because a market has
    -- no pool -- each product gets its own slice -- which is the honest answer rather than a missing one.
    setc("fillName", row.name)
    -- STORAGE TYPE. This page has its OWN populate, so it does not inherit the base one that fills this
    -- cell -- the column was added to both XMLs and wired in one place only, and a market showed a blank
    -- (reported 2026-08-26). It reads "Ind": a market has no Storage at all, its stock is DR's virtual
    -- buffer and each product gets its own marketCap slice (5.36), so the products genuinely do not
    -- share a tank.
    setc("typeText", (SmartDistribution.storageTypeLabel ~= nil)
        and (SmartDistribution.storageTypeLabel(self.selectedAsset, row.ft, self.selectedRole, true) or "") or "")
    local e = self:windowStats(row.ft)
    setc("recvText", fmtV(e.received))
    setc("distText", outTotalText(e))
    setStorageBar(cell, self.selectedAsset, row.ft, self.selectedRole)
    local modeCell = cell:getAttribute("modeText")
    if modeCell ~= nil and SmartDistribution.marketModeDisplay ~= nil then
        -- Shows what the market is DOING, and the player's own setting after it when the two differ
        -- (i.e. while the Selling setting is off). Coloured to flag the override -- and RESET to white
        -- otherwise, because SmoothList recycles cells and a row would inherit the previous row's
        -- colour (the trap 5.7 and 5.57 both hit).
        local text, overridden = SmartDistribution.marketModeDisplay(self.selectedAsset, row.ft)
        modeCell:setText(text or "")
        if modeCell.setTextColor ~= nil then
            if overridden then modeCell:setTextColor(0.95, 0.65, 0.20, 1)
            else               modeCell:setTextColor(1, 1, 1, 1) end
        end
    elseif modeCell ~= nil then
        modeCell:setText((SmartDistribution.marketProductLabel ~= nil)
            and SmartDistribution.marketProductLabel(self.selectedAsset, row.ft)
            or SmartDistribution.l10n("dr_market_immediate", "Sell  -  Immediate"))
    end
    -- both directions in one cell, as on the Silos tab
    setCombinedStatusCell(cell, self.selectedAsset, row.ft, self:currentWindow(), self.selectedRole)
end

-- In-row arrows. The asset-mode version in the base class would write a meaningless asset mode over a
-- market's timing, so this is a full override rather than a tweak -- but it keeps the identical
-- element-carries-the-ft contract (5.64), because these lists re-enumerate on a timer and a row index
-- captured at populate can point at a different product by the time it is clicked.
function DistributionMarketsPage:stepRowMode(dir, ...)
    local el = clickedArrow(...)
    local ft = (el ~= nil) and el.sdFillType or nil
    if ft == nil or self.selectedAsset == nil or SmartDistribution.marketCycleTiming == nil then return end
    SmartDistribution.marketCycleTiming(self.selectedAsset, ft, dir < 0)
    if self.detailList ~= nil then self.detailList:reloadData() end
    self:selectRowByFt(ft)          -- AFTER the reload, so it lands on the rebuilt cells
    self:updateTimingButton()
end

-- footer "Cycle Output" and the X key: one step FORWARD around the same ring, so all three routes agree.
function DistributionMarketsPage:onCycleSelected()
    local row = self:selectedDetailRow()
    if self.selectedAsset == nil or row == nil or SmartDistribution.marketCycleTiming == nil then return end
    SmartDistribution.marketCycleTiming(self.selectedAsset, row.ft, false)
    if self.detailList ~= nil then self.detailList:reloadData() end
    self:updateTimingButton()
end

-- the Z key: one step BACKWARD. MODE_KEYS_ENABLED gates whether DistributionMenu calls this at all.
function DistributionMarketsPage:onCycleSelectedBack()
    local row = self:selectedDetailRow()
    if self.selectedAsset == nil or row == nil or SmartDistribution.marketCycleTiming == nil then return end
    SmartDistribution.marketCycleTiming(self.selectedAsset, row.ft, true)
    if self.detailList ~= nil then self.detailList:reloadData() end
    self:updateTimingButton()
end

-- footer "Sell Type": toggle the selected product between Immediate and Best price
function DistributionMarketsPage:onSellTiming()
    local row = self:selectedDetailRow()
    if self.selectedAsset == nil or row == nil or SmartDistribution.marketToggleSellType == nil then return end
    SmartDistribution.marketToggleSellType(self.selectedAsset, row.ft)
    if self.detailList ~= nil then self.detailList:reloadData() end
    self:updateTimingButton()
end

-- reflect the selected product's sell type on the footer "Sell Type" button
-- The page-level banner. Per-row the MODE cell already says "Sells now (set: Hold)", but a player
-- opening the tab needs to see the override without selecting anything -- so the overview-pointer line
-- doubles as it. Refreshed here because this runs on frame open AND on every selection change.
function DistributionMarketsPage:updateSellingBanner()
    local h = self.marketsHint
    if h == nil or h.setText == nil then return end
    local sellOff = SmartDistribution.settings ~= nil and SmartDistribution.settings.global ~= nil
                    and not SmartDistribution.settings.global.sellEnabled
    if sellOff then
        h:setText(SmartDistribution.l10n("dr_lbl_sellingOff",
            "SELLING IS OFF - every market sells on arrival, whatever these rows are set to"))
        if h.setTextColor ~= nil then h:setTextColor(0.95, 0.65, 0.20, 1) end
    else
        h:setText(SmartDistribution.l10n("dr_lbl_overviewPointer",
            "FULL BREAKDOWN + SUPPLY CHAINS: OVERVIEW TAB"))
        if h.setTextColor ~= nil then h:setTextColor(1, 1, 1, 1) end
    end
end

function DistributionMarketsPage:updateTimingButton()
    self:updateSellingBanner()
    local all = self._allButtons
    if all == nil then return end
    local row = self:selectedDetailRow()
    local label = (self.selectedAsset ~= nil and row ~= nil and SmartDistribution.marketSellTypeLabel ~= nil)
        and SmartDistribution.marketSellTypeLabel(self.selectedAsset, row.ft) or nil
    local vis = {}
    for _, b in ipairs(all) do
        if b._role == "sellTiming" then
            -- The button always shows and edits the player's CHOICE. With the Selling setting off the
            -- pass overrules that choice (a market reverts to base-game operation and sells on arrival),
            -- so the label says so rather than the control being locked or the row quietly reporting
            -- something the player never chose -- which is what the first version did, and it read as
            -- "can't adjust output type ... can't do anything in the market".
            local sellOff = SmartDistribution.settings ~= nil and SmartDistribution.settings.global ~= nil
                            and not SmartDistribution.settings.global.sellEnabled
            if sellOff then
                b.text = SmartDistribution.l10n("dr_btn_sellTimingOff", "Sell Timing: selling is OFF")
                vis[#vis + 1] = b
            elseif label ~= nil then b.text = string.format(SmartDistribution.l10n("dr_btn_sellTimingValue", "Sell Timing: %s"), label); vis[#vis + 1] = b end   -- hidden while the product is Held
        elseif b._role == "advancedIn" then
            -- A market is the exact OPPOSITE of what this used to say ("sell endpoints (no inputs)"): its
            -- buffer never feeds the network back (5.7), so there is no outgoing routing to arrange, while
            -- every source on the farm delivers INTO it. Hidden when the Advanced routing master switch
            -- (Settings) is off, or when the market resolves no input fill types at all.
            local advOK = SmartDistribution.advancedEnabled == nil or SmartDistribution.advancedEnabled()
            local hasIn = self.selectedAsset ~= nil and SmartDistribution.receiverInputFillTypes ~= nil
                and next(SmartDistribution.receiverInputFillTypes(self.selectedAsset)) ~= nil
            if advOK and hasIn then vis[#vis + 1] = b end
        elseif b._role == "advancedOut" then
            -- ...and there is genuinely no output side to configure, so this one is DROPPED on a market
            -- rather than shown and doing nothing. That is the whole reason markets get their own footer.
        else
            vis[#vis + 1] = b
        end
    end
    self:applyFooterButtons(vis)
end
-- selectAsset() (inherited) calls updateSellTimingButton; route it to our button refresh
function DistributionMarketsPage:updateSellTimingButton()
    self:updateTimingButton()
end

-- The inherited handler dispatches on _focusRole (input list vs output list). A market has only one
-- meaningful destination for that button, so send it straight there rather than depending on which list
-- the player happened to touch last.
function DistributionMarketsPage:onAdvancedContextual()
    if self.onAdvancedInputs ~= nil then self:onAdvancedInputs() end
end
