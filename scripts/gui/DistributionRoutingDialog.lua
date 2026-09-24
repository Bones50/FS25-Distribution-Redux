-- ============================================================================
-- DistributionRoutingDialog.lua  (Distribution Redux) -- the ROUTING graph
--
-- COMPLETE (CLAUDE.md 5.106-5.115). Seven columns of real data, squared connectors,
-- SELECTION (click an input or an output to re-point the column beyond it), a per-edge
-- TOGGLE on the two routable gaps, four BLOCK ALL buttons, drag-and-drop FILL ORDER on
-- the destinations, typed Max in / Target / Reserve fields, wheel SCROLLING on every
-- column, and a DOUBLE CLICK on any building to open its own tab. Chosen over the
-- classic list dialogs by the `routingView` setting (SmartDistribution.routingViewEnabled).
--
--     sources | inputs | in-storages | BUILDING | out-storages | outputs | destinations
--
-- NO ENGINE WORK AT ALL. Every column is already computed by machinery that
-- ships and is already MP-safe:
--   col 1  SmartDistribution.inputSourceRows(consumerUid, ft)     5.77 / 5.79
--   col 2  SmartDistribution.receiverInputFillTypes(p, role)      5.65
--   col 3  SmartDistribution.pooledInputCapacity(p, role).groups  5.67d
--   col 4  SmartDistribution.assetIconFile(p)                     5.71
--   col 5  the same pool groups, read from the output side
--   col 6  SmartDistribution.internalProcessFillTypes(p)          (the Overview's own In/Out authority)
--   col 7  SmartDistribution.outputDestinationsForMode(p, ft)
-- This is a presentation build over finished mechanism, which is rare here.
--
-- MEMBERSHIP IS THE EXISTING RULE, NOT A NEW ONE (author's ruling 2026-09-21):
-- "same rules as for the existing advanced input/output; blocked should still be
-- there and be visible that it is blocked." So col 1 is inputSourceRows' own
-- membership verbatim -- which already drops markets, globally excluded fill
-- types, unenrolled buildings and input-only stockers -- and all six of 5.79's
-- statuses are drawn, colour-coded, including OUT_OF_RANGE. Nothing is filtered
-- out here that the Advanced Inputs drill-down would have shown.
--
-- ---- THE TWO GEOMETRY RULES THIS PAGE RESTS ON ----
--
-- 1. CONNECTORS ARE SQUARED, so nothing here is ever rotated. Step 1 proved a GUI
--    quad CAN be rotated and that the engine does it in SCREEN space (5.106); the
--    squared form needs none of that, which is its real attraction beyond the
--    look. See drawSeg: a horizontal bar is EDGE_PX / screenHeight tall and a
--    vertical one EDGE_PX / screenWidth wide, so both render the same thickness
--    at any aspect ratio with no angle and no pivot.
--
-- 2. THE Y AXIS INSIDE THE CANVAS POINTS UP. Directly inside fs25_menuContainer
--    a child takes a NEGATIVE y measured down from the top; inside an ordinary
--    container y is measured UP from the bottom. Two builds of step 1 drew
--    nothing because of this. The canvas and everything in it uses the second.
-- ============================================================================

DistributionRoutingDialog = {}
local Dlg_mt = Class(DistributionRoutingDialog, MessageDialog)

-- MUST MATCH gui/DistributionRoutingDialog.xml, which is GENERATED from these same
-- numbers. A cap raised here without the elements silently drops nodes and edges
-- with no error and nothing in the log -- the exact failure shape 5.92b records
-- for the recipe strip -- so check_lists.py pins the pair.
local SLOTS      = 13      -- node slots per column. ODD, so a lone node lands on the
                           -- building's own centre line; see the generator's own note.
local EDGES      = 20      -- LOGICAL edges per gap
local GAPS       = 4       -- Src|In, In|Bld, Bld|Out, Out|Dst. The two ROUTABLE ones are 1 and 4.
local EDGE_SEGS  = 3       -- bars per edge: out, trunk, in. The XML declares EDGES x EDGE_SEGS.
local EDGE_PX    = 3       -- edge thickness, in screen pixels
-- THE BUILDING BLOCK. Design px; the runtime layout converts them through one measured unit.
-- 24 rows is MEASURED, not chosen: across the base game plus every installed mod, 347 buildings
-- declare production lines and 24 covers 96.8% of them. The eleven above are warehouse and
-- pass-through shapes, which DR reclassifies as SILOS (5.65) and which therefore draw no rows at
-- all. Past the cap the last row is "+N" rather than dropping lines in silence (5.92b).
local BLD_LINES  = 24
local BLD_W_PX   = 200     -- must match the Bld column width in the generator
local BLD_ICON_W = 64
local BLD_ICON_H = 52
local BLD_NAME_H = 22
local BLD_TYPE_H = 18
local BLD_ROW_H  = 15
-- The role's own storage, on the building node. It is what the two TANK columns used to carry:
-- measured 2026-09-22 across the base game and all 43 installed mods, 587 of 588 storage-bearing
-- containers hold exactly ONE tank, so a column of thirteen tank slots served one building in the
-- whole corpus. Three rows -- what comes in, what goes out, and how the tank is shared.
local BLD_STO_H  = 16
local BLD_STO_N  = 3
local BLD_PAD    = 12
local PITCH_PX   = 52      -- the slot pitch, and the ruler the runtime layout measures with

-- The "what moved last cycle" label on a connector, in design px. It is wider than the 56px
-- gap on purpose: a figure reads as "188,467 L" and the overhang lands on the lines it sits
-- above rather than on a node, because only a link that actually moved product is labelled.
local LABEL_W_PX    = 96
local LABEL_H_PX    = 14
local LABEL_LIFT_PX = 2

-- Where the vertical trunk sits across the gap, as a fraction of it. A gap is 56 design px,
-- so the lanes are only a few px apart: they are there to tell one TANK's bus from another's,
-- never to give every edge its own line, which at this width would be unreadable mush.
-- THE PER-EDGE TOGGLE. Two states only, and deliberately so: the LINE keeps 5.79's six
-- statuses (feeding / standby / no stock / blocked / not distributing / out of range) and
-- the CHIP says the one thing the player controls -- whether this link is allowed. A chip
-- with six states would be a second, competing reading of the same connector.
local TOGGLE_PX   = 14
local TOGGLE_INSET_PX = 4   -- along the run, clear of the node it belongs to
local TOGGLE_LIFT_PX  = 2   -- BELOW the bar; the "what moved" label is above it
local TOG_BLOCKED = { 0.80, 0.25, 0.22, 1 }
local TOG_ALLOWED = { 0.35, 0.60, 0.35, 0.90 }

-- A DOUBLE CLICK jumps to a building's own tab. There is no list here to give a selection
-- event, so the gesture is assembled the way the Overview assembles it (5.37): remember WHICH
-- target was pressed and treat a second press on the SAME one inside this window as the
-- gesture. Matched on the target's own IDENTITY, never a slot index -- this page re-enumerates
-- on every refresh and an index captured on the first click can point at a different building
-- by the second (5.64 / 5.37).
local DOUBLE_CLICK_SEC = 0.4

-- SCROLLING, so SLOTS stops being a cap. The columns a player SELECTS in (inputs, outputs) do not
-- scroll freely -- the wheel there steps the SELECTION and the window follows it, which is what
-- keeps the picture coherent: those two products are what the outer columns answer for, so a
-- window that could hide the selected one would leave the sources column with nothing to attach
-- its connectors to and every row would read as broken. The other four have no selection, so the
-- wheel simply scrolls them.
local SCROLL_KEYS = { Src = true, Dst = true }
-- Every node column, for the wheel's hit test. The x band is read off SLOT 1 of each -- a laid-out
-- element, even while hidden (visibility does not affect layout, 5.87c) -- so the design px in the
-- XML are never converted twice and the 6.15 ultrawide widening comes along for free (5.81).
local COL_KEYS = { "Src", "In", "Out", "Dst" }

-- ALL THREE STRIP FIELDS ARE TYPED, not stepped (author's call 2026-09-22). The dialogs step
-- theirs in 5% / 5%-of-capacity rings, which 5.70 already records as too coarse on a large store
-- and which cannot reach 37% at all. A box also SHOWS what it holds, which is what let the
-- separate value labels come out of the strip.

local TRUNK_MID   = 0.50
local TRUNK_LANES = 4
local TRUNK_FIRST = 0.32
local TRUNK_STEP  = 0.12

-- Edge colour says what the connection is DOING. Matches the status vocabulary the
-- Advanced Inputs drill-down already uses (5.79), so the two screens cannot describe
-- one link differently.
-- A product node's own background. The SELECTED one is lit, because from step 3 the columns
-- either side of the building answer for exactly one input and one output and the player has to
-- be able to see which.
local NODE_BG     = { 0.16, 0.17, 0.19, 0.85 }
local NODE_BG_SEL = { 0.24, 0.38, 0.22, 0.95 }

local EDGE_COLOUR = {
    FEEDING         = { 0.31, 0.72, 0.31, 1 },      -- moving product now
    ACTIVE          = { 0.31, 0.72, 0.31, 1 },
    STANDBY         = { 0.55, 0.57, 0.60, 0.9 },    -- could, is not
    IDLE            = { 0.55, 0.57, 0.60, 0.9 },
    NO_STOCK        = { 0.90, 0.65, 0.20, 0.9 },    -- could, has nothing
    BLOCKED         = { 0.80, 0.25, 0.22, 1 },      -- the player switched it off
    NOT_DISTRIBUTING= { 0.45, 0.40, 0.55, 0.85 },   -- its mode never supplies
    OUT_OF_RANGE    = { 0.38, 0.39, 0.42, 0.75 },   -- nothing the player can change
    INTERNAL        = { 0.55, 0.57, 0.60, 0.55 },   -- inside the building: always live
}

-- ---- small local helpers (the established pattern: each GUI file keeps its own) ----

---FULL LITRES ON THIS PAGE, deliberately against the mod-wide convention.
--
-- 5.56 made kilolitres the rule above 999 L everywhere, and this page is the one place the
-- author asked for the whole figure: a routing graph is read to compare quantities against one
-- another, and `1.646 kL` beside `898 L` is harder to compare at a glance than `1,646` beside
-- `898`. `SmartDistribution.formatVolume` is untouched, so every other screen is unaffected --
-- the convention is broken HERE, in one function, rather than moved for the whole mod.
--
-- Revisit if the columns start running out of room: the kL form exists because it is shorter.
local function fmtV(v)
    local n = math.floor((v or 0) + 0.5)
    local s, k = tostring(n), nil
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s .. " L"
end

---THE MOD'S OWN kL RULE (5.56: litres below 1,000, kilolitres above), used ONLY on the product
-- nodes' settings line. Everywhere else this page prints full litres, deliberately (5.107i: a
-- routing graph is read to compare quantities, and "1.646 kL" beside "898 L" is harder to compare
-- at a glance) -- but that argument is about the FLOW and HELD figures, which sit in a column and
-- are read against one another. A settings line is a readout of what one product is configured to
-- do, it is not compared across rows, and it has to carry TWO figures in a 98px cell: "max
-- 173,600 L  tgt 86,800 L" is 27 characters where 23 fit, while "max 174 kL  tgt 87 kL" is 21.
--
-- The EDIT BOXES on the strip stay full digits regardless, because TextPicker only accepts digits
-- and a field you type into must show what you would type.
local function cellV(v)
    if SmartDistribution ~= nil and SmartDistribution.formatVolume ~= nil then
        local ok, t = pcall(SmartDistribution.formatVolume, v or 0)
        if ok and type(t) == "string" then return t end
    end
    return fmtV(v)
end

---A ledger figure for one product over the LAST COMPLETED CYCLE, or "" when nothing moved.
--
-- `assetWindowStats` is what the building tabs read (5.11), so the routing page cannot end up
-- quoting a different number for the same thing -- the standing "two DR figures for one
-- quantity" rule (5.27 / 5.28 / 5.54c). The HOUR window rather than the month because every
-- other figure on this page describes the last pass: the storage levels are live, the connector
-- labels are `fed` from that pass, and mixing a monthly total in beside them would read as a
-- contradiction rather than as a wider view.
--
-- NOTHING MOVED SHOWS NOTHING, not a zero. That is the Overview's own convention for a flow
-- column (5.7 / 5.56), and here it is what keeps a three-row node from carrying a wall of
-- "used 0 L" on every product a building merely supports.
local function flowText(d, ft, field, fmt)
    if d == nil or d.placeable == nil or SmartDistribution.assetWindowStats == nil then return "" end
    local ok, st = pcall(SmartDistribution.assetWindowStats, d.placeable, ft, "hour")
    if not ok or type(st) ~= "table" then return "" end
    local v = st[field]
    if type(v) ~= "number" or v <= 0 then return "" end
    return string.format(fmt, fmtV(v))
end

local function fillTitle(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
        if ok and type(def) == "table" and def.title ~= nil then return def.title end
    end
    return tostring(ft)
end

local function fillIconFile(ft)
    if g_fillTypeManager == nil or g_fillTypeManager.getFillTypeByIndex == nil then return nil end
    local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
    if ok and type(def) == "table" then
        local f = def.hudOverlayFilename or def.hudOverlayFilenameSmall
        if type(f) == "string" and f ~= "" then return f end
    end
    return nil
end

---An edge leaves a node's RIGHT edge and lands on the next column's LEFT edge, both
-- vertically centred. Read off the LAID-OUT element rather than computed from the design px
-- in the XML: those are converted at load WITH the 6.15 widening applied, so re-deriving
-- them here would reproduce 5.81's bug (a value converted twice, or with the hook inert).
local function leftOf(el)
    if el == nil or el.absPosition == nil or el.absSize == nil then return nil end
    return el.absPosition[1], el.absPosition[2] + el.absSize[2] * 0.5
end

local function rightOf(el)
    if el == nil or el.absPosition == nil or el.absSize == nil then return nil end
    return el.absPosition[1] + el.absSize[1], el.absPosition[2] + el.absSize[2] * 0.5
end

---How far down the column to start, so `n` nodes sit CENTRED in the SLOTS available.
--
-- Done by choosing which SLOT to fill, never by moving anything: the slots are declared at
-- fixed y in the XML and a runtime `setPosition` would mean px-to-normalized arithmetic on a
-- laid-out element, which this project has got wrong four separate ways in one feature (5.81).
-- Quantising to whole slots is exact here because every column shares one pitch.
--
-- An OVERFLOWING column returns 0 and fills top to bottom, which is also what keeps the "+N"
-- note beneath the last node: overflow and centring cannot both happen, since overflow means
-- n == SLOTS.
local function slotOffset(n)
    if n == nil or n >= SLOTS then return 0 end
    return math.floor((SLOTS - n) * 0.5)
end

---Which SLICE of a column's list is on screen, and which slot the first of them goes in.
--
-- Returns from, to, base, maxOff. The slot for list index i is base + (i - from) + 1, so the two
-- offsets -- the scroll and slotOffset's centring -- are resolved in one place instead of being
-- added together at four call sites.
--
-- CENTRING AND SCROLLING ARE MUTUALLY EXCLUSIVE, and that falls out rather than being a rule: a
-- column only scrolls when it overflows, and an overflowing column has nothing to centre.
--
-- `mustShow` is a list index the window MUST contain -- the selected input or output. It snaps the
-- window rather than clamping the player's scroll, because those two columns are stepped by the
-- selection and never scrolled directly (see SCROLL_KEYS).
function DistributionRoutingDialog:columnWindow(key, n, hidden, mustShow)
    n = n or 0
    -- THE NOTE TAKES THE SLOT ABOVE THE FIRST BLOCK (asked for 2026-09-22: it used to sit at the
    -- bottom of the canvas, a long way from the column it describes). So a column that has
    -- something to say is one slot shorter, and that is the only place the slot can come from --
    -- an overflowing column's first block is already at the canvas top and there is nothing above
    -- it but the headings.
    --
    -- The question is asked ONCE at the full size and cannot flip back: a list that does not fit
    -- SLOTS does not fit SLOTS-1 either.
    local note = (hidden or 0) > 0 or n > SLOTS
    local usable = note and (SLOTS - 1) or SLOTS
    local maxOff = math.max(0, n - usable)
    local off = math.max(0, math.min(self._scroll[key] or 0, maxOff))
    if mustShow ~= nil and mustShow >= 1 then
        if mustShow <= off then off = mustShow - 1
        elseif mustShow > off + usable then off = mustShow - usable end
        off = math.max(0, math.min(off, maxOff))
    end
    -- WRITTEN BACK, so a wheel that ran past the end is clamped once and stays clamped rather than
    -- accumulating an offset the player then has to scroll all the way back through.
    self._scroll[key] = off
    local from = off + 1
    local to = math.min(n, off + usable)
    local base = (maxOff == 0) and slotOffset(math.max(0, to - from + 1)) or 0
    -- ...and the note needs a slot above the first block to sit in, so a column that would have
    -- started at slot 1 starts at slot 2 instead.
    if note and base < 1 then base = 1 end
    return from, to, base, maxOff, note
end

---Put a column's note in the empty slot ABOVE its first visible block.
--
-- Positioned at RUNTIME off that slot's own laid-out geometry, never from the design px in the XML:
-- the first block moves with the centring, and a literal px in setAbsolutePosition is about a
-- screenful (5.81). absPosition is the element's BOTTOM-left, so putting the note there stands it
-- directly on top of the first block. Reading a HIDDEN slot is fine -- visibility does not affect
-- layout (5.87c) -- and this only ever runs after the page has been laid out (5.99a).
function DistributionRoutingDialog:placeNote(key, base)
    local el = self["rg" .. key .. "More"]
    if el == nil or base == nil or base < 1 then return end
    local slot = self["rg" .. key .. base]
    if slot == nil or slot.absPosition == nil or el.setAbsolutePosition == nil then return end
    el:setAbsolutePosition(slot.absPosition[1], slot.absPosition[2])
end

---Set a column's note and stand it above the first block. One place, so the six columns cannot
-- come to disagree about where it goes.
function DistributionRoutingDialog:setNote(key, from, to, n, maxOff, hidden, base)
    local el = self["rg" .. key .. "More"]
    if el == nil then return end
    local txt = self:columnNote(from, to, n, maxOff, hidden)
    el:setText(txt)
    if txt ~= "" then self:placeNote(key, base) end
end

---What the note under a column says: the window when it is scrolling, otherwise the count of
-- products hidden for being blocked and empty (5.57's rule, which the tabs apply too).
function DistributionRoutingDialog:columnNote(from, to, n, maxOff, hidden)
    if maxOff > 0 then
        return string.format(SmartDistribution.l10n("dr_rg_range", "%d-%d of %d  (scroll)"), from, to, n)
    end
    if (hidden or 0) > 0 then
        return string.format(SmartDistribution.l10n("dr_rg_hiddenN", "+%d blocked"), hidden)
    end
    return ""
end

---Set a named child's text, tolerating a child the layout does not declare.
---THE FILL-ORDER NUMBER on a destination node: always the row's POSITION, never the stored rank.
--
-- Position is the honest figure whether or not a priority list exists -- unranked, storeToAmount
-- fills nearest-first and the column is already in that order -- and it is the only one that can
-- make "1 is always at the top" true of every row.
--
-- COLOURED BY PROVENANCE, which is the one thing the number alone cannot say: `explicit` means the
-- player put it there and it will survive the farm changing shape around it; implicit means it is
-- today's distance order and will re-measure itself. Both colours are set on every call, because
-- these nodes are reused for the next building and the next product (5.7 / 5.57).
local RANK_SET   = { 1.00, 0.70, 0.10, 1 }     -- accent: the player chose this
local RANK_AUTO  = { 0.62, 0.62, 0.62, 1 }     -- grey: measured, not chosen
local function setRank(node, pos, explicit)
    if node == nil or node.getDescendantByName == nil then return end
    local el = node:getDescendantByName("rank")
    if el == nil then return end
    if el.setText ~= nil then el:setText(pos ~= nil and tostring(pos) or "") end
    local c = explicit and RANK_SET or RANK_AUTO
    if el.setTextColor ~= nil then el:setTextColor(c[1], c[2], c[3], c[4]) end
end

local function setLine(node, name, text)
    if node == nil or node.getDescendantByName == nil then return end
    local el = node:getDescendantByName(name)
    if el ~= nil and el.setText ~= nil then el:setText(text or "") end
end

---Put a picture on ONE element. Split out of setIcon because the building block's icon is a
-- free-floating sibling now rather than a child of a node (it has to be: the block is laid out
-- at runtime and has no fixed-height parent to hang off).
local function applyIcon(el, file)
    if el == nil then return end
    if file ~= nil and el.setImageFilename ~= nil then
        el:setImageFilename(file)
        -- A FILENAME DOES NOT RESET THE UV WINDOW (5.94). createOverlay only swaps the image
        -- handle, so an overlay still carrying an atlas slice's sub-rectangle samples a
        -- standalone picture through it and renders as a smear.
        if el.overlay ~= nil and Overlay ~= nil and Overlay.DEFAULT_UVS ~= nil then
            local u = Overlay.DEFAULT_UVS
            el.overlay.uvs = { u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8] }
        end
        el:setVisible(true)
    else
        el:setVisible(false)
    end
end

local function setIcon(node, file)
    if node == nil or node.getDescendantByName == nil then return end
    applyIcon(node:getDescendantByName("icon"), file)
end

function DistributionRoutingDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or Dlg_mt)
    self.assets = {}
    self.assetIndex = 1
    -- WEAK-KEYED: these are page elements that outlive any one refresh, but if a layout ever
    -- stops declaring one it must not be kept alive by this table alone.
    self._hot = setmetatable({}, { __mode = "k" })
    -- Per-column scroll offsets. RESET WHEN THE BUILDING CHANGES: an offset of 9 carried onto a
    -- building with three sources would show an empty column with no way to tell why.
    self._scroll = {}
    return self
end

-- ---- edges ------------------------------------------------------------------

---One AXIS-ALIGNED bar, in absolute normalized coordinates. No rotation anywhere.
--
-- Step 1 proved a GUI quad CAN be rotated and established the pixel-space model for it
-- (5.106), and squared connectors need none of it -- which is the whole attraction of
-- them beyond the look: a horizontal bar is `EDGE_PX / screenHeight` tall and a vertical
-- one is `EDGE_PX / screenWidth` wide, so both render the same thickness on any aspect
-- ratio with no angle, no pivot and nothing that can be wrong by 18 degrees.
function DistributionRoutingDialog:drawSeg(el, x, y, w, h, colour)
    if el == nil or el.setSize == nil then return false end
    -- SIZE FIRST, THEN POSITION. setSize calls updateAnchorDeltas and then
    -- updateAbsolutePosition, which rebuilds absPosition from the anchors -- so a position
    -- written before it is discarded (5.90 records the same ordering trap).
    el:setSize(w, h)
    if el.setAbsolutePosition ~= nil then el:setAbsolutePosition(x, y) end
    local c = colour or EDGE_COLOUR.INTERNAL
    if el.setImageColor ~= nil then el:setImageColor(nil, c[1], c[2], c[3], c[4]) end
    el:setVisible(true)
    return true
end

---Take the next free edge in `gap` and draw it SQUARED: out of the source's right edge,
-- across a vertical trunk, into the target's left edge. Three bars, hence EDGE_SEGS.
--
-- `lane` NAMES THE SHARED ENDPOINT, not the edge, and that is what makes the picture
-- readable rather than merely square. Every edge arriving at the same storage tank is given
-- the same trunk column, so fourteen inputs feeding one tank draw ONE vertical with fourteen
-- horizontals off it -- a bus, the way a schematic does it -- instead of fourteen verticals a
-- pixel apart. Omit it and everything in the gap shares the centre column, which is the right
-- answer whenever the gap genuinely has one shared end (sources -> the selected input).
--
-- Returns false once the gap is full. That is a CAP and not an error: step 5 adds scrolling,
-- and until then a building with more links than quads shows the first EDGES of them.
function DistributionRoutingDialog:edge(gap, fromEl, toEl, colour, lane, labelText, tog)
    local used = self._edgeUsed[gap] or 0
    if used >= EDGES then return false end
    local x1, y1 = rightOf(fromEl)
    local x2, y2 = leftOf(toEl)
    if x1 == nil or x2 == nil then return false end

    local base = used * EDGE_SEGS
    local a = self["rgE" .. gap .. "_" .. (base + 1)]
    local b = self["rgE" .. gap .. "_" .. (base + 2)]
    local c = self["rgE" .. gap .. "_" .. (base + 3)]
    if a == nil or b == nil or c == nil then return false end

    local sw = (g_screenWidth ~= nil and g_screenWidth > 0) and g_screenWidth or 1920
    local sh = (g_screenHeight ~= nil and g_screenHeight > 0) and g_screenHeight or 1080
    local tY = EDGE_PX / sh      -- a HORIZONTAL bar's thickness
    local tX = EDGE_PX / sw      -- a VERTICAL bar's thickness

    local frac = TRUNK_MID
    if lane ~= nil and lane > 0 then
        frac = TRUNK_FIRST + TRUNK_STEP * ((lane - 1) % TRUNK_LANES)
    end
    local midX = x1 + (x2 - x1) * frac

    -- The vertical overshoots by half a bar at BOTH ends so the two corners are filled
    -- rather than notched, and each horizontal reaches the trunk's centre line for the
    -- same reason. Cheaper and more robust than drawing corner pieces.
    local yLo, yHi = math.min(y1, y2), math.max(y1, y2)
    self:drawSeg(a, x1, y1 - tY * 0.5, math.max((midX - x1) + tX * 0.5, tX), tY, colour)
    self:drawSeg(b, midX - tX * 0.5, yLo - tY * 0.5, tX, (yHi - yLo) + tY, colour)
    self:drawSeg(c, midX - tX * 0.5, y2 - tY * 0.5, math.max((x2 - midX) + tX * 0.5, tX), tY, colour)

    -- WHAT MOVED, on the connector. Sits just ABOVE its horizontal run so the bar does not
    -- strike the digits through, at the END the player asked for -- the SOURCE end of an input
    -- line, the DESTINATION end of an output one.
    --
    -- ONLY A LINK THAT ACTUALLY MOVED SOMETHING IS LABELLED, and that is what keeps the picture
    -- clean rather than being a courtesy: a 56px gap cannot hold a figure per edge without the
    -- labels overrunning the columns either side, but a building is usually drawing from ONE of
    -- its fourteen possible sources, so in practice one label is drawn per gap.
    -- THE TOGGLE, on the trunk's midpoint -- the visual centre of the connector, and the one
    -- part of it no other edge in the gap can be sitting on, because the trunk column is what
    -- `lane` keeps apart. Nothing is drawn for the four middle gaps: those are the building's
    -- own plumbing and there is nothing there to switch.
    local tgl = self["rgTog" .. gap .. "_" .. (used + 1)]
    if tgl ~= nil then
        if tog ~= nil then
            local w, h = TOGGLE_PX / sw, TOGGLE_PX / sh
            -- AT THE UNIQUE END, never on the trunk. Every edge in a gap converges on ONE
            -- shared node -- the selected input, or the selected output -- so a chip at the
            -- midpoint of the trunk is at almost the same place for all of them and they
            -- pile up. The OTHER end is a different node per edge, one slot apart, so chips
            -- there are PITCH_PX apart by construction and cannot overlap however many
            -- sources or destinations there are.
            local cx
            if tog.atEnd then cx = x2 - (TOGGLE_INSET_PX / sw) - w
            else              cx = x1 + (TOGGLE_INSET_PX / sw) end
            local cy = (tog.atEnd and y2 or y1)
            -- BELOW the bar, because 5.107e puts the litres label ABOVE it at the same end.
            self:drawSeg(tgl, cx, cy - tY * 0.5 - h - (TOGGLE_LIFT_PX / sh), w, h,
                         tog.blocked and TOG_BLOCKED or TOG_ALLOWED)
            -- The payload is stamped on the ELEMENT, never an index into a list this page
            -- re-enumerates on every refresh (5.64 / 5.37).
            tgl.drTog = tog
            self._hot[tgl] = true
            SmartDistribution.setIconTooltip(tgl, tog.blocked
                and SmartDistribution.l10n("dr_rg_togAllow", "Click to allow this link")
                or  SmartDistribution.l10n("dr_rg_togBlock", "Click to block this link"))
        else
            tgl.drTog = nil
            tgl:setVisible(false)
        end
    end

    local lbl = self["rgLbl" .. gap .. "_" .. (used + 1)]
    if lbl ~= nil then
        if labelText ~= nil and labelText ~= "" then
            local w = LABEL_W_PX / sw
            -- ALWAYS AT THE START, on both sides. It first sat at the destination end of an
            -- output line, which put the figure a long way from the product it describes and
            -- read as a property of the destination rather than of the link. Author's call:
            -- "right above the line start point, just like the input one."
            local lx = x1
            local ly = y1 + tY * 0.5 + (LABEL_LIFT_PX / sh)
            lbl:setSize(w, LABEL_H_PX / sh)
            if lbl.setAbsolutePosition ~= nil then lbl:setAbsolutePosition(lx, ly) end
            lbl:setText(labelText)
            lbl:setVisible(true)
        else
            lbl:setVisible(false)
        end
    end

    self._edgeUsed[gap] = used + 1
    return true
end

-- ---- the page ---------------------------------------------------------------

function DistributionRoutingDialog:rebuildAssets()
    self.assets = {}
    if SmartDistribution == nil or SmartDistribution.enumerateConfigurableAssets == nil then return end
    for _, a in ipairs(SmartDistribution.enumerateConfigurableAssets()) do
        self.assets[#self.assets + 1] = a
    end
    -- Alphabetical by the name the player SEES, tie-broken by roleUid so two identically
    -- named buildings never swap between rebuilds (the DistributionSort rule).
    if DistributionSort ~= nil then
        DistributionSort.sort(self.assets,
            function(a) return a.name or a.baseName or a.origName end,
            function(a) return a.roleUid end)
    end
    if self.assetIndex > #self.assets then self.assetIndex = 1 end
    self:updateAssetButton()
end

---The control shows the CURRENT choice; clicking it opens the list. FS25 has no dropdown
-- element (DistributionPickDialog's header records how that was established), and a
-- MultiTextOption is precisely the cycling this replaces -- on a farm with fifty buildings
-- reaching the last one meant fifty presses.
---THE BUILDING'S NAME GOES ON THE TITLE, not on the button.
--
-- On the page this set the picker button's text, because the button WAS the label. In a dialog
-- the title is already there and a row spent repeating it is a row the graph does not get -- and
-- a bare building name on a button reads as a statement rather than as something to press. So the
-- button keeps a fixed "Select a building" and the title says which one you are looking at.
function DistributionRoutingDialog:updateAssetButton()
    local a = self.assets[self.assetIndex]
    local name = (a ~= nil) and (a.name or a.baseName or a.origName or "?") or nil
    local t = self.dialogTitleElement
    if t ~= nil and t.setText ~= nil then
        local base = SmartDistribution.l10n("dr_title_routing", "Routing")
        t:setText(name ~= nil and string.format("%s  -  %s", base, name) or base)
    end
end

function DistributionRoutingDialog:onPickBuilding()
    if SmartDistribution == nil or SmartDistribution.openPickDialog == nil then return end
    local rows = {}
    for _, a in ipairs(self.assets) do
        rows[#rows + 1] = {
            name = a.name or a.baseName or a.origName or "?",
            sub  = a.origName or a.baseName or "",
            icon = (SmartDistribution.assetIconFile ~= nil) and SmartDistribution.assetIconFile(a.placeable) or nil,
        }
    end
    SmartDistribution.openPickDialog(
        SmartDistribution.l10n("dr_rg_pickBuilding", "Select a building"),
        rows, self.assetIndex,
        function(index)
            if type(index) == "number" and index >= 1 and index <= #self.assets then
                self.assetIndex = index
                self._scroll = {}
                self._notice = nil          -- a message about the last building is not about this one
                self:updateAssetButton()
                self:refreshGraph()
            end
        end)
end

---Everything the graph needs for the selected building, gathered in one place so the
-- layout below is pure placement. Nothing here mutates anything.
---Sort comparator for the SOURCE column: nearest first.
--
-- A FARM-WIDE source has no meaningful distance and must not sort as though it were at zero; it
-- goes last, where "can reach this from anywhere" belongs. Name breaks the remaining ties so two
-- equidistant buildings cannot swap places between refreshes -- table.sort is not stable, and a
-- column that reshuffles under the cursor reads as a fault.
--
-- A PLAIN FUNCTION, not a method: it is passed to table.sort, which calls it with two arguments
-- and no self.
function DistributionRoutingDialog.nearestFirst(a, b)
    local da, db = a.dist or math.huge, b.dist or math.huge
    if a.farWide ~= b.farWide then return not a.farWide end
    if da ~= db then return da < db end
    return tostring(a.name) < tostring(b.name)
end

function DistributionRoutingDialog:gather()
    local a = self.assets[self.assetIndex]
    local d = { inputs = {}, outputs = {}, stores = {}, sources = {}, dests = {} }
    if a == nil or a.placeable == nil or SmartDistribution == nil then return d end
    local p, role = a.placeable, a.role
    d.asset, d.placeable, d.role = a, p, role
    d.name = a.name or a.baseName or "?"
    d.typeName = a.origName or a.baseName or ""

    -- THE ROLE AN INPUT IS ADDRESSED BY, which is not always the role of the COLUMN.
    -- A pass-through store's silo half and its production half read ONE physical tank, so a
    -- genuine line's input is one setting seen from two places and is filed under the SILO's
    -- key on both (5.65's ownership split). This mirrors DistributionProductionsPage:inputRole
    -- exactly; if that changes, change this with it.
    d.inRole = role
    if SmartDistribution.treatPassThroughAsStore ~= nil
       and SmartDistribution.treatPassThroughAsStore(p) then
        d.inRole = nil
    end

    -- WHAT COMES IN AND WHAT GOES OUT, per ROLE, answered the way that role's own tab answers
    -- it -- see SmartDistribution.roleProductSets, which is where the four branches and the
    -- mirror obligation are written down.
    --
    -- This used to be internalProcessFillTypes, which takes a PLACEABLE and no role: on a
    -- multi-role building it cannot describe one half, so a DriveIn's production listed the
    -- whole silo (reported 2026-09-22).
    local ins, outs = {}, {}
    if SmartDistribution.roleProductSets ~= nil then
        local ok, i, o = pcall(SmartDistribution.roleProductSets, p, role)
        if ok and type(i) == "table" and type(o) == "table" then ins, outs = i, o end
    end

    -- ...AND THE SAME VISIBILITY FILTER THE TABS APPLY. visibleProducts drops a product that is
    -- BLOCKED and that the building is not actually holding, and hands back the count (5.57).
    -- Advanced routing off returns the original table untouched, so nothing changes for anyone
    -- not using the feature. Asked with the SETTING role on each side, which is why the input
    -- side uses inRole: the filter is per (uid, ft) and a pass-through's inputs are keyed to the
    -- silo.
    local function ordered(set, settingRole)
        local t = {}
        for k in pairs(set or {}) do t[#t + 1] = k end
        table.sort(t)                                   -- deterministic base order
        -- NOTHING IS HIDDEN HERE. visibleProducts (5.57) drops a product that is blocked and
        -- holding nothing, which is right for a building TAB -- a blocked row there has nothing
        -- more to say. On a graph the product is a NODE with sources and destinations hanging off
        -- it, and taking it away removes the thing the player just acted on. Reported 2026-09-23:
        -- blocking a mill's inputs made five of six disappear while the sixth, which held stock,
        -- stayed -- so the button looked as though it had done two different things.
        local hidden = 0
        local all = t                                   -- kept distinct: see the bulk buttons
        -- DISPLAY ORDER: alphabetical by the name the player READS, in the active language, the
        -- same DistributionSort collation the tabs use (5.92a).
        if DistributionSort ~= nil and DistributionSort.sortFillTypes ~= nil then
            DistributionSort.sortFillTypes(t, fillTitle)
        else
            table.sort(t, function(x, y) return fillTitle(x) < fillTitle(y) end)
        end
        return t, hidden, all
    end
    d.inputs,  d.inHidden,  d.inputsAll  = ordered(ins,  d.inRole)
    d.outputs, d.outHidden, d.outputsAll = ordered(outs, role)

    -- STORAGES. A pool's `groups` is one entry per physical tank (5.67d), which is exactly
    -- one storage node each; groupsOf[ft] names which tanks hold a product, and that is what
    -- the input/output edges connect through. A building with no pool at all (a production
    -- buffer, a market) gets ONE synthetic node so the graph still reads left to right.
    local pool = SmartDistribution.pooledInputCapacity ~= nil
        and SmartDistribution.pooledInputCapacity(p, role) or nil
    -- NO LABEL ANY MORE. Each entry was a node in a TANK COLUMN and carried its own caption; the
    -- columns are gone (see the canvas header for the measurement) and the entries survive only as
    -- the terms the building node's storage rows are summed from, plus `groupsOf`, which is what
    -- lets a product on the one multi-tank building in the corpus say which tanks it lives in.
    if pool ~= nil and type(pool.groups) == "table" and #pool.groups > 0 then
        for _, g in ipairs(pool.groups) do
            d.stores[#d.stores + 1] = {
                cap = g.cap, count = (type(g.fts) == "table") and #g.fts or 0,
            }
        end
        d.groupsOf = pool.groupsOf or {}
    else
        d.stores[1] = {
            cap = (pool ~= nil) and pool.liters or nil,
            count = (pool ~= nil and type(pool.fts) == "table") and #pool.fts or 0,
        }
        d.groupsOf = nil
    end

    -- HOW FULL EACH TANK IS, read SEPARATELY for the two sides. A cow barn's food pool and its
    -- milk / manure / slurry tanks are different containers, so one figure cannot serve both
    -- columns -- that is the "input MAX and output MAX are two figures for one quantity and must
    -- not disagree" rule (5.27 / 5.28 / 5.54c) arriving from the other direction: here they are
    -- genuinely two quantities and must not be conflated.
    --
    -- HELD is always summed PER PRODUCT, which is correct for a pool because each product carries
    -- its own level (5.68). CAPACITY is taken from the TANK wherever one is known, and only
    -- summed per product when it is not -- summing a pool's per-product capacities would report a
    -- 60 kL tank as 240 kL once four foods share it.
    local function storeOf(ft)
        if d.groupsOf ~= nil then
            local l = d.groupsOf[ft]
            if l ~= nil and #l > 0 then return l end
            return nil                                  -- lives in no tank we modelled
        end
        return { 1 }
    end
    d.storeOf = storeOf

    local function num(fn, ...)
        if fn == nil then return nil end
        local ok, v = pcall(fn, ...)
        if ok and type(v) == "number" and v == v and v < math.huge then return v end
        return nil
    end

    for si, st in ipairs(d.stores) do
        st.heldIn, st.heldOut, st.capIn, st.capOut = 0, 0, nil, nil
        local sumIn, sumOut = 0, 0
        for _, ft in ipairs(d.inputs) do
            local l = storeOf(ft)
            if l ~= nil then
                for _, gi in ipairs(l) do
                    if gi == si then
                        st.heldIn = st.heldIn + (num(SmartDistribution.inputHeldLevel, p, ft, d.inRole) or 0)
                        sumIn = sumIn + (num(SmartDistribution.inputProductCapacity, p, ft, d.inRole) or 0)
                    end
                end
            end
        end
        for _, ft in ipairs(d.outputs) do
            local l = storeOf(ft)
            if l ~= nil then
                for _, gi in ipairs(l) do
                    if gi == si then
                        st.heldOut = st.heldOut + (num(SmartDistribution.assetHeld, p, ft) or 0)
                        sumOut = sumOut + (num(SmartDistribution.outputCapacityTotal, p, ft, role) or 0)
                    end
                end
            end
        end
        -- the tank's own capacity beats any sum, and `cap` is already that where a group exists
        local tank = (st.cap ~= nil and st.cap > 0 and st.cap < math.huge) and st.cap or nil
        st.capIn  = tank or (sumIn  > 0 and sumIn  or nil)
        st.capOut = tank or (sumOut > 0 and sumOut or nil)
    end

    -- THE SELECTED PRODUCT ON EACH SIDE -- whatever is actually MOVING, not whatever sorts first.
    --
    -- Reported in game 2026-09-21: a grain mill switched from its barley line to its wheat one
    -- went on pointing every source at BARLEY. It was doing exactly what it was told -- `inputs[1]`
    -- after an alphabetical sort -- and the hint line said so, but "the first product by name" is
    -- never the one worth looking at. The mill was drawing wheat and the wheat lines carried no
    -- figures because barley's sources were on screen.
    --
    -- The feed log is keyed by the BASE uid (5.77 / 6.24), and `assetUid` rather than `p.uniqueId`
    -- because it carries the client-side remap a player-BUILT building needs (5.49 / 5.50).
    -- Step 3 replaces this with a real selection; until then the default should be the answer.
    local uid = (SmartDistribution.assetUid ~= nil) and SmartDistribution.assetUid(p) or nil
    local function busiest(list, totalFn)
        if uid == nil or totalFn == nil then return list[1] end
        local best, bestV = nil, 0
        for _, ft in ipairs(list) do
            local ok, v = pcall(totalFn, uid, ft)
            if ok and type(v) == "number" and v > bestV then best, bestV = ft, v end
        end
        return best or list[1]         -- nothing moved last pass: fall back to the first
    end
    -- A PINNED CHOICE WINS, and is dropped the moment it stops being a product of this building --
    -- which is what makes changing building behave: the pin is not cleared on the way out, it simply
    -- stops matching, so coming back to the same building restores what was being looked at.
    local function pinned(pin, list)
        if pin == nil then return nil end
        for _, ft in ipairs(list) do if ft == pin then return pin end end
        return nil
    end
    d.selIn  = pinned(self.pinIn,  d.inputs)  or busiest(d.inputs,  SmartDistribution.fedTotal)
    d.selOut = pinned(self.pinOut, d.outputs) or busiest(d.outputs, SmartDistribution.fedOutTotal)
    -- WHICH ROW that is, because the edges land on a node rather than on a fill type. Leaving
    -- this at 1 is what would make the columns and the connectors disagree about the selection.
    d.selInIdx, d.selOutIdx = 1, 1
    for i, ft in ipairs(d.inputs)  do if ft == d.selIn  then d.selInIdx  = i break end end
    for i, ft in ipairs(d.outputs) do if ft == d.selOut then d.selOutIdx = i break end end

    -- The CONSUMER key, kept because the gap-1 toggle writes a block against exactly the
    -- uid `inputSourceRows` and `fedBy` were asked about -- the BASE uid, not the role one
    -- (5.77): the feed log and `gatherSources`' own block test are both keyed that way.
    d.uid = uid
    if d.selIn ~= nil and SmartDistribution.inputSourceRows ~= nil then
        if uid ~= nil then
            local ok, rows = pcall(SmartDistribution.inputSourceRows, uid, d.selIn)
            if ok and type(rows) == "table" then d.sources = rows end
            -- NEAREST FIRST (author's call 2026-09-23). inputSourceRows sorts by 5.79's status
            -- BUCKETS, which is right for the drill-down TABLE -- there the top answers "who is
            -- supplying me" and the bottom "why isn't anyone else" -- and wrong on the graph,
            -- where every node already carries its own coloured status word and the column is
            -- read against the farm as it is laid out on the ground.
            --
            -- SORTED ON OUR OWN COPY. inputSourceRows builds a fresh table of fresh rows on every
            -- call (it copies out of the memoised sourcesFor precisely so per-consumer state
            -- cannot poison that cache), so the drill-down is untouched by this.
            table.sort(d.sources, DistributionRoutingDialog.nearestFirst)
        end
    end
    if d.selOut ~= nil and SmartDistribution.outputDestinationsForMode ~= nil then
        local ok, rows = pcall(SmartDistribution.outputDestinationsForMode, p, d.selOut)
        if ok and type(rows) == "table" then
            -- The memo hands back a SHARED table and its two existing callers only read
            -- `.blocked` (5.46). Copied rather than held, so nothing here can poison it.
            for _, r in ipairs(rows) do d.dests[#d.dests + 1] = r end
        end
    end
    return d
end

---Hide every node and edge. Called first on every refresh, because a slot left over from
-- the previous building would otherwise keep its picture and its text -- the same recycling
-- trap SmoothList cells have produced here twice (5.7 colours, 5.57 the notice row).
function DistributionRoutingDialog:clearGraph()
    for _, key in ipairs({ "Src", "In", "Out", "Dst" }) do
        for s = 1, SLOTS do
            local n = self["rg" .. key .. s]
            -- CLEARED AS WELL AS HIDDEN, the chips' own rule one element over: `_hot` is weak on
            -- the KEY, so a hidden node holding the previous building's uid outlives the refresh.
            if n ~= nil then
                n.drJumpKey, n.drJumpUid, n.drJumpP, n.drJumpFt = nil, nil, nil, nil
                n:setVisible(false)
            end
        end
        local more = self["rg" .. key .. "More"]
        if more ~= nil and more.setText ~= nil then more:setText("") end
    end
    for _, id in ipairs({ "rgBldBg", "rgBldIcon", "rgBldName", "rgBldType" }) do
        local el = self[id]
        if el ~= nil then
            el.drJumpKey, el.drJumpUid, el.drJumpP, el.drJumpFt = nil, nil, nil, nil
            el:setVisible(false)
        end
    end
    for i = 1, BLD_LINES do
        local el = self["rgBldL" .. i]
        if el ~= nil then el:setVisible(false) end
    end
    for i = 1, BLD_STO_N do
        local el = self["rgBldSto" .. i]
        if el ~= nil then el:setVisible(false) end
    end
    self._edgeUsed = {}
    for g = 1, GAPS do
        self._edgeUsed[g] = 0
        for n = 1, EDGES * EDGE_SEGS do
            local el = self["rgE" .. g .. "_" .. n]
            if el ~= nil then el:setVisible(false) end
        end
        for n = 1, EDGES do
            local lbl = self["rgLbl" .. g .. "_" .. n]
            if lbl ~= nil then lbl:setVisible(false) end
            local tgl = self["rgTog" .. g .. "_" .. n]
            -- CLEARED AS WELL AS HIDDEN: a stale payload on an invisible chip would still be
            -- reachable, and `_hot` is weak on the KEY, so the element itself outlives it.
            if tgl ~= nil then tgl.drTog = nil; tgl:setVisible(false) end
        end
    end
end

---Fill and show slot `s` of column `key`. Returns the node element, or nil past the cap.
function DistributionRoutingDialog:node(key, s, icon, line1, line2, line3, selected)
    if s > SLOTS then return nil end
    local n = self["rg" .. key .. s]
    if n == nil then return nil end
    -- SET ON BOTH PATHS: these nodes are reused for the next building and the next product, so a
    -- highlight left behind would mark the wrong row (the recycling trap, 5.7 / 5.57).
    if n.setImageColor ~= nil then
        local c = selected and NODE_BG_SEL or NODE_BG
        n:setImageColor(nil, c[1], c[2], c[3], c[4])
    end
    setIcon(n, icon)
    setLine(n, "line1", line1)
    setLine(n, "line2", line2)
    -- Cleared as well as set: only the product nodes declare a third row, and a node reused for a
    -- different building must not keep the last one's figure (the SmoothList recycling trap, 5.7).
    setLine(n, "line3", line3)
    n:setVisible(true)
    return n
end

---uid -> placeable, from ONE placeableSystem walk.
--
-- The DESTINATION rows carry a uid and no placeable -- outputDestinations builds them in three
-- branches and the row shape is the same in all three -- and `placeableByUid` is itself a full linear
-- scan. So asking it per row would be a scan PER DESTINATION: the O(rows x placeables) shape 5.52
-- removed from the Overview, on a page that already pays two full walks in gather(). One walk, read
-- by every row, is the move 5.78 makes for the feed event's own uid -> placeable resolution.
--
-- Keyed on the BASE uid, because a destination may address one HALF of a building ("uid#shed") and it
-- is still that building (5.65) -- which is exactly what placeableByUid does with baseUidOf.
--
-- `assetUid`, never `p.uniqueId`: it carries the client-side remap a player-BUILT building needs, and
-- resolving identity locally is correct in singleplayer and silently wrong on an MP client (5.49).
function DistributionRoutingDialog:uidPlaceables()
    local map = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    for _, p in ipairs(ps ~= nil and ps.placeables or {}) do
        if p.rootNode ~= nil and SmartDistribution.assetUid ~= nil then
            local ok, u = pcall(SmartDistribution.assetUid, p)
            if ok and u ~= nil and map[u] == nil then map[u] = p end
        end
    end
    return map
end

---"holds 12.5 kL" / "holds 12.5 kL (200 kL)", or "" for nothing worth saying.
--
-- 5.21's ONE held format -- the amount, then what it can hold beside it -- so this reads the way every
-- other held figure in the mod reads. The bracket is omitted rather than invented when no capacity
-- resolves: showing held alone is the honest answer, and a denominator DR cannot justify is worse than
-- none (5.21 / 5.45b).
local function holdsText(held, cap)
    if held == nil and cap == nil then return "" end
    local body
    if cap ~= nil and cap > 0 then
        body = string.format("%s (%s)", fmtV(held or 0), fmtV(cap))
    elseif held ~= nil and held > 0 then
        body = fmtV(held)
    else
        -- nothing held and no capacity known. The STATUS on the line above already names this case
        -- ("No Stock"), so a "holds -" here would restate it -- the wall-of-zeros the Overview's own
        -- dash convention exists to avoid (5.7 / 5.56).
        return ""
    end
    return string.format(SmartDistribution.l10n("dr_rg_holds", "holds %s"), body)
end

---What a DESTINATION holds of the selected output, and what it can hold.
--
-- READ AS AN INPUT, both terms, because a destination RECEIVES this product -- and through the same
-- pair the storage bar's input side uses, so the two screens cannot quote different figures for one
-- tank. Held MUST come off the same basis as capacity, or the fill is measured against a total it was
-- never measured against (5.29b / 5.61 / 5.54c).
--
-- The ROLE is recovered from the uid: a destination may be one half of a building, and the half that
-- is receiving is the half whose capacity is the answer.
function DistributionRoutingDialog:destHoldsText(uid, ft, map)
    if uid == nil or ft == nil or map == nil then return "" end
    local p = map[(SmartDistribution.baseUidOf ~= nil) and SmartDistribution.baseUidOf(uid) or uid]
    if p == nil then return "" end
    local role = (SmartDistribution.roleOfUid ~= nil) and SmartDistribution.roleOfUid(uid) or nil
    local function num(fn)
        if fn == nil then return nil end
        local ok, v = pcall(fn, p, ft, role)
        if ok and type(v) == "number" and v == v and v < math.huge and v >= 0 then return v end
        return nil
    end
    return holdsText(num(SmartDistribution.inputHeldLevel), num(SmartDistribution.inputProductCapacity))
end

-- THIS PAGE REPORTS ITS OWN FAILURES, and that is not scaffolding left behind.
--
-- 2026-09-22: a nil method threw on the first row of the first loop and the page drew its building
-- block, nothing else, and LOGGED NOTHING -- because its onFrameOpen runs inside a pcall somewhere
-- above DR. Six theories were built from reading the code before the error was simply caught and
-- printed, which named it in one run. An error that reaches nobody is the most expensive kind this
-- project produces (5.50), and on a page assembled from ~450 elements looked up by name it is also
-- the likeliest. Catching it costs one call per refresh and turns a blank screen into a line a
-- player can paste.
--
-- `print`, not log(): a player cannot be talked through enabling debug (5.63). Silent unless
-- something actually fails.
function DistributionRoutingDialog:refreshGraph()
    local ok, err = xpcall(function() return self:_refreshGraphInner() end,
                           function(e) return tostring(e) .. "  |  " .. debug.traceback("", 2) end)
    if not ok then print("[DR rg] refreshGraph FAILED: " .. tostring(err)) end
end

function DistributionRoutingDialog:_refreshGraphInner()
    self:clearGraph()
    local d = self:gather()
    self._data = d
    if d.placeable == nil then return end

    local L = function(k, fb) return SmartDistribution.l10n(k, fb) end

    if self.rgSrcHdr    ~= nil then self.rgSrcHdr:setText(L("dr_rg_hdrSources", "SOURCES")) end
    if self.rgInHdr     ~= nil then self.rgInHdr:setText(L("dr_rg_hdrInputs", "INPUTS")) end
    if self.rgBldHdr    ~= nil then self.rgBldHdr:setText(L("dr_rg_hdrBuilding", "BUILDING")) end
    if self.rgOutHdr    ~= nil then self.rgOutHdr:setText(L("dr_rg_hdrOutputs", "OUTPUTS")) end
    if self.rgDstHdr    ~= nil then self.rgDstHdr:setText(L("dr_rg_hdrDests", "DESTINATIONS")) end

    -- ---- the building itself: name and type above the picture, its lines below ----
    local lines = {}
    if SmartDistribution.productionLines ~= nil then
        local ok, l = pcall(SmartDistribution.productionLines, d.placeable)
        if ok and type(l) == "table" then lines = l end
    end
    -- `line.name` is already 5.72's disambiguated label, which is why two `( *2)` twins over
    -- identical products do not both read as the same line, and `status` is the same
    -- Off / Running / Idle resolver the Productions tab uses.
    if self.rgBldName ~= nil then self.rgBldName:setText(d.name or "") end
    if self.rgBldType ~= nil then self.rgBldType:setText(d.typeName or "") end
    applyIcon(self.rgBldIcon, (SmartDistribution.assetIconFile ~= nil)
                              and SmartDistribution.assetIconFile(d.placeable) or nil)
    self:layoutBuilding(d, lines)
    -- THE BUILDING ITSELF IS A JUMP TARGET. Only the BACKGROUND is registered, not the picture
    -- or the two text rows sitting on it: the hit test is geometric and ignores z-order, so the
    -- box already answers for a click anywhere inside it and three more registrations would
    -- only give the arbitration something to arbitrate.
    self:markJump(self.rgBldBg, d.uid, d.placeable,
                  string.format(L("dr_rg_jump", "Double-click to open %s"), d.name or ""), "DETAIL")

    -- EVERY COLUMN IS CENTRED WHEN IT FITS and fills top to bottom when it does not, so a
    -- four-product building reads as a band across the middle rather than everything hanging off
    -- the top with the building node alone in the middle. See columnWindow.
    local frIn,  toIn,  offIn,  moIn  = self:columnWindow("In",    #d.inputs,  d.inHidden,  d.selInIdx)
    local frOut, toOut, offOut, moOut = self:columnWindow("Out",   #d.outputs, d.outHidden, d.selOutIdx)
    local frSrc, toSrc, offSrc, moSrc = self:columnWindow("Src",   #d.sources, 0)
    local frDst, toDst, offDst, moDst = self:columnWindow("Dst",   #d.dests,   0)

    -- ---- columns 2 and 6: the products ----
    local inNode, outNode = {}, {}
    for i = frIn, toIn do
        local ft = d.inputs[i]
        local held = nil
        if SmartDistribution.inputHeldLevel ~= nil then
            -- inRole, not role: on a pass-through store a line's input is the SILO's setting seen
            -- from the production tab, so every input-side read has to name the same half the
            -- product list and the block were resolved against (5.65).
            local ok, v = pcall(SmartDistribution.inputHeldLevel, d.placeable, ft, d.inRole)
            if ok and type(v) == "number" then held = v end
        end
        local n = self:node("In", offIn + (i - frIn) + 1, fillIconFile(ft),
            self:heldWithPool(d, ft, held, d.inRole),
            flowText(d, ft, "consumed", L("dr_rg_used", "used %s")),
            self:inSettingsText(d, ft), ft == d.selIn)
        if n == nil then break end
        self:markSelectable(n, "IN", ft, fillTitle(ft))
        inNode[i] = n
    end
    self:setNote("In", frIn, toIn, #d.inputs, moIn, d.inHidden, offIn)
    for i = frOut, toOut do
        local ft = d.outputs[i]
        local held = nil
        if SmartDistribution.assetHeld ~= nil then
            local ok, v = pcall(SmartDistribution.assetHeld, d.placeable, ft)
            if ok and type(v) == "number" then held = v end
        end
        -- LINE 2 IS THE MODE, line 3 what it made and what it holds back. The mode is what this
        -- output is SET to do and the flow is what it did; a player opens this column to check the
        -- first, so it goes above the second.
        local made = flowText(d, ft, "produced", L("dr_rg_made", "made %s"))
        local res  = self:outSettingsText(d, ft)
        local n = self:node("Out", offOut + (i - frOut) + 1, fillIconFile(ft),
            self:heldWithPool(d, ft, held, d.role),
            self:outModeText(d, ft),
            (made ~= "" and res ~= "") and (made .. "  " .. res) or (made ~= "" and made or res),
            ft == d.selOut)
        if n == nil then break end
        self:markSelectable(n, "OUT", ft, fillTitle(ft))
        outNode[i] = n
    end
    self:setNote("Out", frOut, toOut, #d.outputs, moOut, d.outHidden, offOut)

    -- ---- column 1: the sources of the selected input ----
    -- ONCE, not per source: the receiver-side block is a property of the PRODUCT, so every
    -- source of it is equally unable to deliver. 5.79's BLOCKED already means "something is
    -- stopping this", which is exactly true here -- so the word needs no new state.
    local selInBlocked = self:inputBlockedFor(d, d.selIn)
    for i = frSrc, toSrc do
        local s = d.sources[i]
        local sStatus = selInBlocked and "BLOCKED" or s.status
        local range = s.farWide and L("dr_rg_farmWide", "farm") or string.format("%dm", math.floor(s.dist or 0))
        -- THE STATUS, which is the one thing this column could not say. It is 5.79's six-state answer
        -- to "why is nothing arriving" -- feeding / standby / no stock / blocked / not distributing /
        -- out of range -- and the drill-down has carried it since 5.77 while the graph beside it did
        -- not. The word comes from SmartDistribution so the two surfaces cannot come to disagree.
        --
        -- The litres move to line 3 and are LABELLED. They were sitting unlabelled next to the range,
        -- where a figure with no noun is read as whatever the reader expects; this is `providableLiters`,
        -- i.e. what the building could actually hand over, which is the same figure and the same
        -- reasoning the drill-down's own HOLDS column uses.
        local n = self:node("Src", offSrc + (i - frSrc) + 1, s.icon, s.name,
            string.format("%s  %s", range, SmartDistribution.sourceStatusLabel(sStatus)),
            holdsText(s.liters, nil))
        if n == nil then break end
        self:markJump(n, s.uid, nil,
                      string.format(L("dr_rg_jumpRg", "Double-click to route %s"), s.name or ""),
                      "ROUTING", d.selIn, "SRC")
        local tgt = inNode[d.selInIdx or 1]
        if tgt ~= nil then
            -- `fed` is what this source handed over on the LAST COMPLETED PASS (5.78), which is
            -- the only per-source figure that exists: the feed log is rebuilt every pass, so
            -- there is no windowed per-source history to offer instead.
            local fed = (type(s.fed) == "number" and s.fed > 0) and fmtV(s.fed) or nil
            -- THE BLOCK IS ASKED FOR DIRECTLY rather than read off the status word, because
            -- 5.79 ranks OUT_OF_RANGE above BLOCKED: a source that is both reads "out of
            -- range", and a chip inferred from that word would show a blocked link as allowed.
            local tog = self:togFor(s.uid, d.selIn, d.uid, nil, s.name, false)
            self:edge(1, n, tgt, self:edgeColour(sStatus, tog), nil, fed, tog)
        end
    end
    self:setNote("Src", frSrc, toSrc, #d.sources, moSrc, 0, offSrc)

    -- ---- column 7: the destinations of the selected output ----
    -- `outputDestinations` resolves fedBy only far enough to pick a status, so the litres are
    -- asked for here rather than inferred from the word.
    local srcUid = (SmartDistribution.settingUid ~= nil)
        and SmartDistribution.settingUid(d.placeable, d.selOut, d.role) or nil
    -- ONE walk for the whole column, and only when there is a column to draw. A destination row
    -- carries no placeable, and the held / capacity pair needs one.
    local dstMap = (frDst <= toDst) and self:uidPlaceables() or nil
    for i = frDst, toDst do
        local r = d.dests[i]
        local n = self:node("Dst", offDst + (i - frDst) + 1, r.icon, r.name,
            string.format("%dm  %s", math.floor(r.dist or 0), r.statusLabel or ""),
            self:destHoldsText(r.uid, d.selOut, dstMap))
        if n == nil then break end
        -- THE FILL ORDER, large, on the node itself, from the moment the window opens. `r.rank`
        -- decides only the COLOUR: the number is the position either way, because that is what
        -- the product will actually do.
        setRank(n, i, r.rank ~= nil)
        self:markJump(n, r.uid, nil,
                      string.format(L("dr_rg_jumpRg", "Double-click to route %s"), r.name or ""),
                      "ROUTING", d.selOut, "DST")
        local src = outNode[d.selOutIdx or 1]
        if src ~= nil then
            local fed = nil
            if srcUid ~= nil and r.uid ~= nil and SmartDistribution.fedBy ~= nil then
                local ok, v = pcall(SmartDistribution.fedBy,
                    (SmartDistribution.destStatusUid ~= nil) and SmartDistribution.destStatusUid(r.uid) or r.uid,
                    d.selOut, srcUid)
                if ok and type(v) == "number" and v > 0 then fed = fmtV(v) end
            end
            local tog = self:togFor(srcUid, d.selOut, r.uid, d.role, r.name, true)
            self:edge(GAPS, src, n, self:edgeColour(r.status, tog), nil, fed, tog)
        end
    end
    self:setNote("Dst", frDst, toDst, #d.dests, moDst, 0, offDst)

    -- ---- the internal edges: product <-> building ----
    -- NO LANE on either of these. `lane` exists to tell one shared ENDPOINT from another, and with
    -- the tank columns gone every input converges on the building and the building feeds every
    -- output -- one shared end each way, so one trunk each way, which is what a bus should look
    -- like (5.107b). Where a product lives in only SOME of a multi-tank pool, its own node says so.
    local function link(gap, from, to, lane)
        if from ~= nil and to ~= nil then self:edge(gap, from, to, EDGE_COLOUR.INTERNAL, lane) end
    end
    local bld = self.rgBldBg
    for i = frIn, toIn do link(2, inNode[i], bld) end
    for i = frOut, toOut do link(3, bld, outNode[i]) end

    if self.rgHint ~= nil then
        self.rgHint:setText(string.format(L("dr_rg_hint", "Sources: %s   Destinations: %s"),
            d.selIn ~= nil and fillTitle(d.selIn) or "-",
            d.selOut ~= nil and fillTitle(d.selOut) or "-"))
    end
    self:refreshControls(d)
end

-- ---- the control strip ---------------------------------------------------------------------
-- Four settings on the page rather than behind a dialog. Every one of them reads the value the
-- SAME way its dialog reads it and writes it through the SAME event, so the two surfaces cannot
-- come to disagree about one number -- the standing rule this codebase keeps paying for
-- (5.27 / 5.28 / 5.54c, and 5.70 for the reserve in particular).
--
-- EVERY CONTROL IS SET ON EVERY PATH. This runs on each refresh, so a label or a disabled state
-- left over from the previous building would describe it for the rest of the session.

---THE SETTINGS, ALL THREE IN LITRES. Since 2026-09-22 the engine stores Max in and Fill target as
-- litres too, so nothing here converts anything: the box shows the stored figure and commits the
-- typed one. What was a percentage basis is now only the RANGE the box is bounded by.
--
-- These take an explicit fill type rather than reading the selection, because the strip asks about
-- the SELECTED product and every input / output NODE asks about its own: the figures live on the
-- columns and the strip is only where one is changed. One resolver for both, or the two would come
-- to disagree about the same setting (5.27 / 5.28 / 5.54c).

---The ceiling this product may occupy, in litres. Defaults to its whole capacity.
function DistributionRoutingDialog:capLitres(d, ft)
    if d == nil or ft == nil or SmartDistribution.inputCapLiters == nil then return nil end
    local ok, v = pcall(SmartDistribution.inputCapLiters, d.placeable, ft, d.inRole)
    return (ok and type(v) == "number") and v or nil
end

---The highest ceiling this product may be given: its own capacity. Also the box's range.
function DistributionRoutingDialog:capBasis(d, ft)
    if d == nil or ft == nil or SmartDistribution.defaultInputCapLiters == nil then return 0 end
    local ok, c = pcall(SmartDistribution.defaultInputCapLiters, d.placeable, ft, d.inRole)
    return (ok and type(c) == "number" and c > 0 and c < math.huge) and c or 0
end

---The fill target in litres, and whether one can bind here at all. nil target = Off, which is a real
-- setting and NOT the same as 0 L: Off is the recipe's own demand, 0 L is "hold this at empty".
function DistributionRoutingDialog:targetLitres(d, ft)
    if d == nil or ft == nil then return nil, false end
    local applies = true
    if SmartDistribution.fillTargetApplies ~= nil then
        local ok, v = pcall(SmartDistribution.fillTargetApplies, d.placeable, ft, d.inRole)
        applies = (ok and v ~= false)
    end
    if not applies then return nil, false end
    local uid = (SmartDistribution.settingUid ~= nil)
                and SmartDistribution.settingUid(d.placeable, ft, d.inRole) or nil
    if uid == nil or SmartDistribution.getInputTargetStored == nil then return nil, true end
    local ok, v = pcall(SmartDistribution.getInputTargetStored, uid, ft)
    return (ok and type(v) == "number") and v or nil, true
end

---The target's own ceiling: the Max in figure, because the engine bounds it there (inputTargetLiters).
-- So the two are not independent -- lowering Max in lowers what a target can be set to.
function DistributionRoutingDialog:targetBasis(d, ft)
    return self:capLitres(d, ft) or self:capBasis(d, ft)
end

---The arrow step. A plain 1,000 L now: with the setting stored in litres there is no rounding floor
-- to work around -- the reason litreStep used to take the larger of 1,000 and one percent was that an
-- integer percentage could not express anything finer, and it no longer has to.
function DistributionRoutingDialog:litreStep(basis)
    return LITRE_STEP
end

---The reserve on the selected output, read through settingUid the way the Advanced Outputs dialog
-- reads it -- so a secondary role's row shows what that role stored (5.70's own note that the
-- reserve is written role-aware and read bare is about the ENGINE's enforcement, not the display).
function DistributionRoutingDialog:currentReserve(d, ft)
    if d == nil or ft == nil or SmartDistribution.settingUid == nil then return nil end
    local uid = SmartDistribution.settingUid(d.placeable, ft, d.role)
    if uid == nil or SmartDistribution.getOutputReserve == nil then return nil end
    local ok, v = pcall(SmartDistribution.getOutputReserve, uid, ft)
    return (ok and type(v) == "number") and v or nil
end

---A product's held figure, and WHICH TANK it lives in when that is a real question.
--
-- The building node carries the role's storage word, which is the whole answer for 587 of the 588
-- storage-bearing containers in the corpus. A product tag is added ONLY where the building has more
-- than one tank -- the single outlier -- because there and only there do two products of one role
-- have different answers. On every other building it would be the same word on every row.
--
-- LOST ONCE AND RESTORED (2026-09-22). The litre pass replaced a block of resolvers by ANCHORING ON
-- THE COMMENT BELOW, and this function sat immediately above that anchor, so it went with them. The
-- two calls then resolved to a nil method and threw on the FIRST input node -- which is not a syntax
-- error, so luac -p passed it (the 5.44 trap), and the engine swallowed it because the page's
-- onFrameOpen runs inside a pcall: the page drew its building block, nothing else, and logged
-- nothing. tools/check_lists.py now checks that every self:method() on these pages resolves.
function DistributionRoutingDialog:heldWithPool(d, ft, held, role)
    local txt = (held ~= nil) and fmtV(held) or ""
    if d == nil or #(d.stores or {}) <= 1 then return txt end
    if SmartDistribution.storageTypeLabel == nil then return txt end
    local ok, lbl = pcall(SmartDistribution.storageTypeLabel, d.placeable, ft, role, true)
    if not ok or type(lbl) ~= "string" or lbl == "" then return txt end
    if txt == "" then return lbl end
    return txt .. "  " .. lbl
end

---The third line of an INPUT node: its Max in and its Fill target. Shown per product because that
-- is where the player reads them (author's call); the strip holds only the one being edited.
-- Nothing at all with Advanced routing off, where neither setting is consulted (5.57).
---Is this product's RECEIVER-SIDE block set -- the per-product ACT.INPUT_BLOCK that gates
-- inputAcceptableLiters to zero, as distinct from the per-link blocks the chips carry. Asked live
-- rather than read off a status word, for the reason togFor gives: the two answer different
-- questions and 5.79 ranks OUT_OF_RANGE above BLOCKED, so a word can hide a block.
function DistributionRoutingDialog:inputBlockedFor(d, ft)
    if d == nil or ft == nil or d.placeable == nil then return false end
    if SmartDistribution.settingUid == nil or SmartDistribution.isInputBlocked == nil then return false end
    local uid = SmartDistribution.settingUid(d.placeable, ft, d.inRole)
    if uid == nil then return false end
    local ok, v = pcall(SmartDistribution.isInputBlocked, uid, ft)
    return (ok and v) and true or false
end

function DistributionRoutingDialog:inSettingsText(d, ft)
    if SmartDistribution.advancedEnabled == nil or not SmartDistribution.advancedEnabled() then return "" end
    -- BLOCKED REPLACES the ceilings rather than joining them: max and target are limits on a
    -- delivery that cannot happen, so printing all three would state two contradicting rules.
    -- The WORD comes from sourceStatusLabel, so the node and the SOURCES column beside it cannot
    -- come to describe the same condition differently.
    if self:inputBlockedFor(d, ft) then
        return SmartDistribution.sourceStatusLabel("BLOCKED")
    end
    local capL = self:capLitres(d, ft)
    local maxTxt = (capL ~= nil) and cellV(capL) or "-"
    local tgtL, applies = self:targetLitres(d, ft)
    local tgt
    if not applies then tgt = "-"
    elseif tgtL == nil then tgt = SmartDistribution.l10n("dr_rg_targetOff", "Off")
    else tgt = cellV(tgtL) end
    return string.format(SmartDistribution.l10n("dr_rg_nodeIn", "max %s  tgt %s"), maxTxt, tgt)
end

---The third line of an OUTPUT node: its reserve, and NOTHING when there is none. A dash on every
-- output of every building would be a column of noise about a setting almost nobody sets, which is
-- the Overview's own reason for a blank rather than a zero (5.7).
---What this output is SET to do: the same words the Productions tab and the Overview use.
function DistributionRoutingDialog:outModeText(d, ft)
    if d == nil or ft == nil or d.placeable == nil then return "" end
    local SD, p = SmartDistribution, d.placeable
    local pp = (SD.productionPointOf ~= nil) and SD.productionPointOf(p) or nil
    local name
    if pp ~= nil and (SD.usesVMode == nil or SD.usesVMode(p, ft))
       and SD.productionOutputVMode ~= nil and SD.productionOutputVModeName ~= nil then
        local okv, v = pcall(SD.productionOutputVMode, pp, ft)
        if okv and v ~= nil then
            local okn, t = pcall(SD.productionOutputVModeName, v)
            name = okn and t or nil
        end
    elseif SD.modeName ~= nil and SD.resolvedAssetMode ~= nil then
        local pal = (SD.holdLabelFlag ~= nil) and SD.holdLabelFlag(p, ft) or nil
        local okm, m = pcall(SD.resolvedAssetMode, p, ft, d.role)
        if okm then
            local okn, t = pcall(SD.modeName, m, pal)
            name = okn and t or nil
        end
    end
    return name or ""
end

function DistributionRoutingDialog:outSettingsText(d, ft)
    if SmartDistribution.advancedEnabled == nil or not SmartDistribution.advancedEnabled() then return "" end
    local res = self:currentReserve(d, ft)
    if res == nil or res <= 0 then return "" end
    return string.format(SmartDistribution.l10n("dr_rg_nodeRes", "res %s"), cellV(res))
end

-- ---- the strip's three typed fields ---------------------------------------------------------
-- HUSBANDRY REDUX'S TextPicker, copied into this mod verbatim (its own header rules that it be
-- copied rather than called across mods, since DR must never depend on AR -- 5.87). A box you
-- type into, with the stock arrows still at its ends for the nudges they are good at.
--
-- ONE ARROW PRESS MOVES 5% OF THE RANGE (author's call 2026-09-22): five percentage points, or
-- 5% of the building's capacity for a reserve in litres. That is the same 20-press sweep the
-- Advanced Outputs ring already uses (DistributionAdvancedDialog.RESERVE_STEPS = 20), so the two
-- surfaces move a reserve by the same amount as well as storing it the same way.
-- ONE ARROW PRESS MOVES 1,000 L (author's call 2026-09-22), on all three fields, exactly.
--
-- The first version of this had to take the LARGER of 1,000 L and one percent of the tank, because
-- Max in and Fill target were stored as INTEGER percentages and a 1,000 L press on a 500,000 L silo
-- rounded straight back to the figure it started from. They are stored in LITRES now, so there is no
-- rounding floor left to work around and the step is the plain figure that was asked for.
local LITRE_STEP = 1000

---Build the three controls, once. Not in new(): the elements do not exist until the layout has
-- loaded, and this page has no onGuiSetupFinished to hang it off.
--
-- onChanged IS DELIBERATELY NOT USED. TextPicker raises it on every KEYSTROKE that produces a
-- valid number (setLive), and every write here is a DistributionControlEvent that broadcasts in
-- multiplayer -- so the settings are committed from the enter and arrow handlers instead, once
-- per gesture.
function DistributionRoutingDialog:buildPickers()
    if self._pkMax ~= nil or TextPicker == nil then return end
    local L = function(k, fb) return SmartDistribution.l10n(k, fb) end
    -- The range is the product's capacity, which changes with the selection, so the complaint
    -- cannot name a number. setRange moves the bound; this is the words beside it.
    local badPct = L("dr_rg_badRes", "above capacity")
    self._pkMax = TextPicker.new({ min = 0, max = 100, step = LITRE_STEP, name = "maxIn",
            prompt = L("dr_rg_hintLitres", "click to set litres"), outOfRange = badPct })
        :attach(self.rgCtlMax, self.rgCtlMaxHint, self.rgCtlMaxLeft, self.rgCtlMaxRight)
    -- THE TARGET'S EMPTY STATE IS A REAL SETTING, not an absence: an empty field means Off, i.e.
    -- the recipe's own demand, which is genuinely different from a target of 0% ("keep it
    -- empty"). So its prompt SAYS Off rather than inviting a number.
    self._pkTgt = TextPicker.new({ min = 0, max = 100, step = LITRE_STEP, name = "fillTarget",
            prompt = L("dr_rg_hintTarget", "Off - click to set"), outOfRange = badPct })
        :attach(self.rgCtlTgt, self.rgCtlTgtHint, self.rgCtlTgtLeft, self.rgCtlTgtRight)
    self._pkRes = TextPicker.new({ min = 0, max = 1, step = 1, name = "reserve",
            prompt = L("dr_rg_hintLitres", "click to set litres"),
            outOfRange = L("dr_rg_badRes", "above capacity") })
        :attach(self.rgCtlRes, self.rgCtlResHint, self.rgCtlResLeft, self.rgCtlResRight)
end

function DistributionRoutingDialog:refreshControls(d)
    local L = function(k, fb) return SmartDistribution.l10n(k, fb) end
    local adv = SmartDistribution.advancedEnabled ~= nil and SmartDistribution.advancedEnabled()
    local hasIn  = d ~= nil and d.selIn  ~= nil and adv
    local hasOut = d ~= nil and d.selOut ~= nil and adv

    local function txt(el, v) if el ~= nil and el.setText ~= nil then el:setText(v or "") end end

    self:buildPickers()
    -- LIVE ONLY WHEN THERE IS AN ORDER TO CLEAR. Every destination carries `rank` already, so
    -- this costs a walk of a handful of rows rather than a second question to the engine.
    if self.rgClearOrder ~= nil and self.rgClearOrder.setDisabled ~= nil then
        local ranked = false
        for _, r in ipairs(d ~= nil and d.dests or {}) do
            if r.rank ~= nil then ranked = true break end
        end
        self.rgClearOrder:setDisabled(not (ranked and adv))
    end
    -- ONE CAPTION PER FIELD, directly above its box, naming the setting AND the product it acts
    -- on. Folding the product in is what removed the separate IN: / OUT: cells, and it also
    -- removes the reading those invited: with one "IN: Wheat" serving two boxes, which product
    -- Fill target applied to had to be inferred from the cell two along.
    local function caption(el, live, key, fb, ft)
        txt(el, live and string.format(L("dr_rg_ctlField", "%s  -  %s"),
                                       L(key, fb), fillTitle(ft)) or "")
    end
    caption(self.rgCtlMaxLbl, hasIn,  "dr_rg_lblMaxFill", "Max Fill",      d ~= nil and d.selIn)
    caption(self.rgCtlTgtLbl, hasIn,  "dr_rg_lblTarget",  "Fill target", d ~= nil and d.selIn)
    caption(self.rgCtlResLbl, hasOut, "dr_rg_lblReserve", "Reserve",     d ~= nil and d.selOut)

    -- EVERY FIELD IS SET ON EVERY PATH, and `silent` on every push. This runs on each refresh, so
    -- a value or an inert state left over from the previous building would describe it for the
    -- rest of the session; and TextPicker's discard diagnostic is an unconditional print, which
    -- would fire on a stored figure that no longer fits rather than on anything a player did.
    local function push(pk, live, value, inertText)
        if pk == nil then return end
        pk:setInert(not live, inertText or "")
        if live then pk:set(value, true) else pk:set(nil, true) end
    end

    -- MAX IN, IN LITRES. The stored form is a percentage, so the box is that percentage OF this
    -- product's capacity and the commit converts back. Its RANGE is the full capacity rather than
    -- the POOL HEADROOM, deliberately: a stored figure above a shrunken headroom would be refused
    -- on the way IN and the player would watch their own number turn into "above capacity" for no
    -- action of theirs. The headroom is enforced where it belongs, on the commit, with a notice.
    --
    -- NO CAPACITY MEANS NO LITRE FIGURE, so the field goes INERT rather than showing a number it
    -- cannot honour. That is also the truth about the setting: with capacity 0,
    -- inputAcceptableLiters short-circuits to INF and Max in has never done anything (5.36).
    local capB = hasIn and self:capBasis(d, d.selIn) or 0
    if self._pkMax ~= nil then
        self._pkMax:setRange(0, math.max(1, math.floor(capB)), self:litreStep(capB))
    end
    local capL = hasIn and self:capLitres(d, d.selIn) or nil
    push(self._pkMax, hasIn and capB > 0,
         (capL ~= nil) and math.floor(capL + 0.5) or nil, "-")

    -- THE FILL TARGET, in litres of its own basis -- which is the MAX IN ceiling, not the raw
    -- capacity (see targetBasis). INERT where a receiver can never act on one: a control drawn as
    -- live that refuses every press is worse than no control, and inert greys the arrows with the
    -- field so it cannot be mistaken for merely empty.
    local tgtL, applies = self:targetLitres(d, d.selIn)
    local tgtB = (hasIn and applies) and self:targetBasis(d, d.selIn) or 0
    if self._pkTgt ~= nil then
        self._pkTgt:setRange(0, math.max(1, math.floor(tgtB)), self:litreStep(tgtB))
    end
    push(self._pkTgt, hasIn and applies and tgtB > 0,
         (tgtL ~= nil) and math.floor(tgtL + 0.5) or nil, "-")

    -- THE RESERVE is already litres, so its arrows are an exact 1,000 and nothing is converted.
    -- Its range moves with the selection because it is bounded by that product's own capacity;
    -- with none resolvable the range is left wide open and the engine's own clamp is the only
    -- bound, since refusing a figure because DR could not read a capacity would be worse.
    local cap = hasOut and self:reserveCap(d, d.selOut) or 0
    if self._pkRes ~= nil then
        if cap > 0 then self._pkRes:setRange(0, math.floor(cap), LITRE_STEP)
        else self._pkRes:setRange(0, 999999999, LITRE_STEP) end
    end
    local res = hasOut and self:currentReserve(d, d.selOut) or nil
    push(self._pkRes, hasOut, (res ~= nil and res > 0) and math.floor(res + 0.5) or nil)

    -- BLOCK ALL / ALLOW ALL, labelled by what the press will DO and computed from what is
    -- currently active (the onToggleAll idiom, 5.4). It acts on the LINKS, not the product list:
    -- every source of the selected input, every destination of the selected output. The SIDE is
    -- in the label rather than beside it, because a "DESTINATIONS" caption costs 110px of strip.
    local function allLabel(list, blockKey, blockFb, allowKey, allowFb)
        for _, r in ipairs(list or {}) do if not r.blocked then return L(blockKey, blockFb) end end
        return L(allowKey, allowFb)
    end
    local srcs = (d ~= nil) and d.sources or {}
    local dsts = (d ~= nil) and d.dests or {}
    local srcLive = hasIn  and #srcs > 0
    local dstLive = hasOut and #dsts > 0
    -- ALWAYS LABELLED, DISABLED WHEN INERT. These are footer buttons now, and a footer button is
    -- fitToContent inside a BoxLayout -- so an empty label does not leave a blank button, it
    -- collapses it to nothing and the separators either side close up over it. 5.74 settled this
    -- for the fill-target buttons: disabled rather than hidden, because removing an entry mid-row
    -- reflows the whole footer.
    txt(self.rgCtlSrcAll, allLabel(self:srcBlockStates(d),
        "dr_rg_blockAllSrc", "Block all sources", "dr_rg_allowAllSrc", "Allow all sources"))
    txt(self.rgCtlDstAll, allLabel(dsts,
        "dr_rg_blockAllDst", "Block all dests", "dr_rg_allowAllDst", "Allow all dests"))
    -- ...and the two BUILDING-WIDE ones, which answer over every product rather than the selected
    -- one. The output probe short-circuits on the first allowed link (see outputBlockStates), so
    -- labelling it normally costs one memoised lookup.
    local inStates, inAllowed = self:inputBlockStates(d)
    local _, outAllowed, outHasAny = self:outputBlockStates(d, true)
    txt(self.rgCtlInAll, inAllowed and L("dr_rg_blockAllIn", "Block all inputs")
                                    or L("dr_rg_allowAllIn", "Allow all inputs"))
    txt(self.rgCtlOutAll, outAllowed and L("dr_rg_blockAllOut", "Block all outputs")
                                      or L("dr_rg_allowAllOut", "Allow all outputs"))
    if self.rgCtlSrcAll ~= nil and self.rgCtlSrcAll.setDisabled ~= nil then
        self.rgCtlSrcAll:setDisabled(not srcLive)
    end
    if self.rgCtlDstAll ~= nil and self.rgCtlDstAll.setDisabled ~= nil then
        self.rgCtlDstAll:setDisabled(not dstLive)
    end
    if self.rgCtlInAll ~= nil and self.rgCtlInAll.setDisabled ~= nil then
        self.rgCtlInAll:setDisabled(#inStates == 0)
    end
    if self.rgCtlOutAll ~= nil and self.rgCtlOutAll.setDisabled ~= nil then
        self.rgCtlOutAll:setDisabled(not outHasAny)
    end
    -- ...AND THE ROW IS RE-FLOWED, because both labels FLIP between "Block all" and "Allow all"
    -- and the two are different widths. A BoxLayout lays its children out once and does not watch
    -- them, so without this the buttons keep the widths they had when the dialog opened and the
    -- longer label is clipped by its own neighbour.
    if self.buttonsPC ~= nil and self.buttonsPC.invalidateLayout ~= nil then
        self.buttonsPC:invalidateLayout()
    end
end

---The ceiling a reserve is measured against. ROLE-SCOPED: outputCapacityTotal takes a role, and
-- passing none is the call 5.70 already had to fix once, where a pallet-store row clamped against
-- the silo half's tank.
function DistributionRoutingDialog:reserveCap(d, ft)
    if d == nil or ft == nil or SmartDistribution.outputCapacityTotal == nil then return 0 end
    local ok, c = pcall(SmartDistribution.outputCapacityTotal, d.placeable, ft, d.role)
    return (ok and type(c) == "number" and c < math.huge) and c or 0
end

---Whether each source of the selected input is blocked, asked LIVE rather than read off the status
-- word: 5.79 ranks OUT_OF_RANGE above BLOCKED, so a source that is both reports "out of range" and
-- a label inferred from that would say "Block All" on a column that is already entirely blocked.
-- The same reason togFor asks directly (see edgeColour).
function DistributionRoutingDialog:srcBlockStates(d)
    local out = {}
    if d == nil or d.selIn == nil or d.uid == nil then return out end
    for i, s in ipairs(d.sources or {}) do
        local blk = false
        if SmartDistribution.isDestBlocked ~= nil and s.uid ~= nil then
            local ok, v = pcall(SmartDistribution.isDestBlocked, s.uid, d.selIn, d.uid)
            blk = (ok and v) and true or false
        end
        out[i] = { blocked = blk, uid = s.uid, name = s.name }
    end
    return out
end

-- ---- the strip's actions -------------------------------------------------------------------
-- All five go through DistributionControlEvent, which applies locally at once and then syncs, and
-- which bumps the menu memo epoch on the way (5.46) -- so the refresh below reads the new value
-- rather than a cached one.
function DistributionRoutingDialog:ctlApply(act, uid, ft, delta, flag, amount)
    if uid == nil or ft == nil then return end
    if DistributionControlEvent == nil or DistributionControlEvent.send == nil then return end
    DistributionControlEvent.send(act, uid, ft, "", delta or 0, flag or false, amount)
    self:refreshGraph()
end

-- ---- the three fields' handlers ------------------------------------------------------------
-- Six callbacks per field, which is what TextPicker's contract asks for, generated rather than
-- written out eighteen times (AR's own dialog does the same for its six slots):
--   Digit    #onIsUnicodeAllowed -- a false return REJECTS the character before insertion
--   Changed  #onTextChanged      -- takes the grey prompt down as the first character lands
--   Enter    #onEnterPressed     -- return, AND a click outside while enterWhenClickOutside
--   Esc      #onEscPressed       -- abandon the edit, put the stored value back
--   Left / Right                 -- one step of 5% of the range
--
-- THE COMMIT IS OURS, NOT THE PICKER'S. TextPicker resolves the parse, the range and the display;
-- only after it has done that do we write the setting -- once per gesture, never per keystroke,
-- because every write is an event that broadcasts in multiplayer.
--
-- A REFUSED COMMIT WRITES NOTHING AND SAYS SO IN THE FIELD ITSELF (TextPicker paints its
-- outOfRange prompt), so there is no refresh here: refreshing would push the stored value back
-- and wipe the complaint.

---Commit the Max in percentage. Clamped to the POOL HEADROOM, which is where that rule lives:
-- the box's own range is the full 0..100 so a stored figure is never refused on the way in.
function DistributionRoutingDialog:commitMax(v)
    local d = self._data
    if d == nil or d.selIn == nil then return end
    if SmartDistribution.advancedEnabled == nil or not SmartDistribution.advancedEnabled() then return end
    local uid = (SmartDistribution.settingUid ~= nil)
                and SmartDistribution.settingUid(d.placeable, d.selIn, d.inRole) or nil
    if uid == nil then return end
    if SmartDistribution.isInputBlocked ~= nil and SmartDistribution.isInputBlocked(uid, d.selIn) then
        self:notice(SmartDistribution.l10n("dr_rg_blockedNoSet", "That product is blocked"))
        return
    end
    -- NOTHING IS CONVERTED. The setting is litres and the box is litres, so the typed figure is the
    -- stored figure -- which is the whole point of the change: a ceiling of 173,600 L is 173,600 L,
    -- not the nearest hundredth of the tank.
    --
    -- AN EMPTY FIELD MEANS THE WHOLE CAPACITY, which is the same statement 5.53's "100% by default"
    -- made in the old unit. It is stored explicitly rather than cleared, so the figure the player sees
    -- is one they chose.
    local want = v
    if want == nil then want = self:capBasis(d, d.selIn) end
    local maxL = self:capBasis(d, d.selIn)
    if maxL > 0 and want > maxL then
        want = maxL
        self:notice(string.format(
            SmartDistribution.l10n("dr_rg_capClamped", "Capped at the tank: %s"), fmtV(maxL)))
    else
        self:notice(nil)
    end
    self:ctlApply(DistributionControlEvent.ACT.INPUT_CAP, uid, d.selIn, 0, false, want)
end

---Commit the fill target. An empty field clears it back to Off, which the wire carries as a NEGATIVE
-- amount: a float32 has no nil, and Off is genuinely different from a target of 0 L.
function DistributionRoutingDialog:commitTarget(v)
    local d = self._data
    if d == nil or d.selIn == nil then return end
    local _, applies = self:targetLitres(d, d.selIn)
    if not applies then return end
    local uid = (SmartDistribution.settingUid ~= nil)
                and SmartDistribution.settingUid(d.placeable, d.selIn, d.inRole) or nil
    if uid == nil then return end
    self:notice(nil)
    self:ctlApply(DistributionControlEvent.ACT.INPUT_TARGET, uid, d.selIn, 0, false,
                  (v == nil) and -1 or v)
end

---Commit the output reserve. The box's range already holds it to the role's capacity, so there is
-- nothing left to clamp here; an empty field clears it.
function DistributionRoutingDialog:commitReserve(v)
    local d = self._data
    if d == nil or d.selOut == nil then return end
    local uid = (SmartDistribution.settingUid ~= nil)
                and SmartDistribution.settingUid(d.placeable, d.selOut, d.role) or nil
    if uid == nil then return end
    self:notice(nil)
    self:ctlApply(DistributionControlEvent.ACT.OUTPUT_RESERVE, uid, d.selOut, 0, false,
                  (v == nil) and 0 or math.floor(v + 0.5))
end

---A transient message. It goes on the HINT LINE in the row above rather than in the strip, which
-- is 5.4's own pattern for exactly this: showBlinkingWarning renders BEHIND an open menu and is
-- never seen, so a notice is appended to a line that is already on screen. Cleared by the next
-- refresh, since refreshGraph rewrites that line.
function DistributionRoutingDialog:notice(msg)
    self._notice = msg
    if msg ~= nil and self.rgHint ~= nil and self.rgHint.setText ~= nil then
        self.rgHint:setText(msg)
    end
end

-- THE EIGHTEEN CALLBACKS. `commit` is the method that writes the setting for that field.
for _, f in ipairs({ { key = "Max", pk = "_pkMax", commit = "commitMax" },
                     { key = "Tgt", pk = "_pkTgt", commit = "commitTarget" },
                     { key = "Res", pk = "_pkRes", commit = "commitReserve" } }) do
    local pkName, commitName = f.pk, f.commit
    DistributionRoutingDialog["on" .. f.key .. "Digit"] = function(self, unicode)
        local pk = self[pkName]
        return pk ~= nil and pk:allow(unicode) or false
    end
    DistributionRoutingDialog["on" .. f.key .. "Changed"] = function(self)
        local pk = self[pkName]
        if pk ~= nil then pk:changed() end
    end
    DistributionRoutingDialog["on" .. f.key .. "Enter"] = function(self)
        local pk = self[pkName]
        if pk == nil then return end
        pk:enter()
        -- `bad` means the parse or the range refused it. The field is already saying so; writing
        -- nothing is the whole response.
        if pk.bad then return end
        self[commitName](self, pk:get())
    end
    DistributionRoutingDialog["on" .. f.key .. "Esc"] = function(self)
        local pk = self[pkName]
        if pk ~= nil then pk:escape() end
    end
    DistributionRoutingDialog["on" .. f.key .. "Left"] = function(self)
        local pk = self[pkName]
        if pk == nil then return end
        self[commitName](self, pk:step(-1))
    end
    DistributionRoutingDialog["on" .. f.key .. "Right"] = function(self)
        local pk = self[pkName]
        if pk == nil then return end
        self[commitName](self, pk:step(1))
    end
end

---Block or allow EVERY source of the selected input, in one press. Direction is decided ONCE from
-- the current state and then applied to all of them, so a mixed column collapses to one answer
-- rather than each link flipping to its own opposite.
--
-- ONE EVENT PER LINK -- there is no bulk BLOCK action and inventing one would mean a new wire
-- format for something a player presses occasionally. The refresh is deferred to the end so the
-- graph is rebuilt once rather than once per source.
function DistributionRoutingDialog:onToggleAllSources()
    local d = self._data
    if d == nil or d.selIn == nil or d.uid == nil then return end
    if SmartDistribution.advancedEnabled == nil or not SmartDistribution.advancedEnabled() then return end
    if DistributionControlEvent == nil or DistributionControlEvent.send == nil then return end
    local states = self:srcBlockStates(d)
    local anyAllowed = false
    for _, r in ipairs(states) do if not r.blocked then anyAllowed = true; break end end
    local n = 0
    for _, r in ipairs(states) do
        if r.uid ~= nil and r.blocked ~= anyAllowed then
            DistributionControlEvent.send(DistributionControlEvent.ACT.BLOCK,
                                          r.uid, d.selIn, d.uid, 0, anyAllowed)
            n = n + 1
        end
    end
    self:notice(nil)
    if n > 0 then self:refreshGraph() end
end

---The same, one gap over. A LOOP is never activated by this: 5.3 flags loop creation, so a
-- destination that would loop the product back here is SKIPPED and counted rather than refusing
-- the whole press -- the alternative is one bad destination making the button do nothing at all.
---Every destination of ONE output, as the DESTINATIONS column would draw them. Resolved through
-- outputDestinationsForMode -- the same call gather() makes for the selected product, and the same
-- one the Advanced Outputs dialog's own count comes from (5.37) -- so a per-product button and a
-- whole-building one can never disagree about which links exist.
function DistributionRoutingDialog:destStatesFor(ft)
    local out = {}
    local d = self._data
    if d == nil or d.placeable == nil or ft == nil then return out end
    if SmartDistribution.outputDestinationsForMode == nil then return out end
    local ok, rows = pcall(SmartDistribution.outputDestinationsForMode, d.placeable, ft)
    if not ok or type(rows) ~= "table" then return out end
    for _, r in ipairs(rows) do
        if r.uid ~= nil then out[#out + 1] = { uid = r.uid, blocked = r.blocked and true or false } end
    end
    return out
end

---One destination pass for ONE output. SHARED by the per-product button and the whole-building one,
-- so the loop guard cannot come to differ between them. 5.3 flags loop CREATION only, which is why
-- it is asked on the ALLOW direction alone -- blocking a loop is always permitted, and is how you
-- break one.
function DistributionRoutingDialog:setDestBlocks(ft, states, block)
    local d = self._data
    if d == nil or ft == nil then return 0, 0 end
    if DistributionControlEvent == nil or DistributionControlEvent.send == nil then return 0, 0 end
    local srcUid = (SmartDistribution.settingUid ~= nil)
                   and SmartDistribution.settingUid(d.placeable, ft, d.role) or nil
    if srcUid == nil then return 0, 0 end

    local M, mode = SmartDistribution.MODE, nil
    if not block and SmartDistribution.resolvedAssetMode ~= nil then
        local ok, v = pcall(SmartDistribution.resolvedAssetMode, d.placeable, ft, d.role)
        if ok then mode = v end
    end
    local moveTo = M ~= nil and (mode == M.STORE_TO or mode == M.DISTRIBUTE_STORE_TO)

    local n, skipped = 0, 0
    for _, r in ipairs(states or {}) do
        if r.uid ~= nil and r.blocked ~= block then
            local loops = false
            if not block and moveTo and SmartDistribution.moveToCreatesLoop ~= nil then
                local ok, v = pcall(SmartDistribution.moveToCreatesLoop, srcUid, ft, r.uid)
                loops = (ok and v) and true or false
            end
            if loops then
                skipped = skipped + 1
            else
                DistributionControlEvent.send(DistributionControlEvent.ACT.BLOCK,
                                              srcUid, ft, r.uid, 0, block)
                n = n + 1
            end
        end
    end
    return n, skipped
end

function DistributionRoutingDialog:onToggleAllDests()
    local d = self._data
    if d == nil or d.selOut == nil then return end
    if SmartDistribution.advancedEnabled == nil or not SmartDistribution.advancedEnabled() then return end
    local states = d.dests or {}
    local anyAllowed = false
    for _, r in ipairs(states) do if not r.blocked then anyAllowed = true; break end end
    local n, skipped = self:setDestBlocks(d.selOut, states, anyAllowed)
    if n > 0 or skipped > 0 then self:refreshGraph() end
    -- AFTER the refresh, which rewrites the hint line: a notice set before it would be erased.
    self:notice((skipped > 0)
        and string.format(SmartDistribution.l10n("dr_rg_loopSkipped", "%d skipped (would loop)"), skipped)
        or nil)
end

-- ---- the two BUILDING-WIDE buttons ---------------------------------------------------------
-- These reach products that are not on screen, which is the whole point of them and also the one
-- thing that makes them worth a count in the hint line: the columns show what happened to the
-- SELECTED product, and nothing else would tell you the other nine were touched.

---Every INPUT product of the building and whether any still accepts delivery. Reads the
-- UNFILTERED set (see gather): 5.57 hides a product that is blocked and holding nothing, so the
-- drawn list is exactly the one that empties as you block it -- and "Allow all" would then find
-- nothing to act on, leaving the building stuck blocked with no way back from this dialog.
-- Cheap enough to call from the refresh: isInputBlocked is a nested table read, not a scan.
function DistributionRoutingDialog:inputBlockStates(d)
    local out, anyAllowed = {}, false
    if d == nil or d.placeable == nil or SmartDistribution.settingUid == nil then return out, false end
    for _, ft in ipairs(d.inputsAll or d.inputs or {}) do
        local uid = SmartDistribution.settingUid(d.placeable, ft, d.inRole)
        if uid ~= nil then
            local blk = false
            if SmartDistribution.isInputBlocked ~= nil then
                local ok, v = pcall(SmartDistribution.isInputBlocked, uid, ft)
                blk = (ok and v) and true or false
            end
            out[#out + 1] = { uid = uid, ft = ft, blocked = blk }
            if not blk then anyAllowed = true end
        end
    end
    return out, anyAllowed
end

---Every output LINK of the building, whether any still lets product through, and whether there are
-- any at all. `probe` stops at the first allowed link, which is what keeps the footer label cheap:
-- outputDestinationsForMode is a placeableSystem walk on a cold memo (5.46), and a building with
-- anything open answers on its first product. Only a fully-blocked building pays the whole sweep --
-- the rare case, which is the right way round. The HANDLER passes false, because it needs the pairs.
function DistributionRoutingDialog:outputBlockStates(d, probe)
    local work, anyAllowed, hasAny = {}, false, false
    for _, ft in ipairs((d ~= nil) and (d.outputsAll or d.outputs) or {}) do
        local st = self:destStatesFor(ft)
        if #st > 0 then
            hasAny = true
            work[#work + 1] = { ft = ft, states = st }
            for _, r in ipairs(st) do
                if not r.blocked then
                    anyAllowed = true
                    if probe then return work, true, true end
                    break
                end
            end
        end
    end
    return work, anyAllowed, hasAny
end

---How the bulk buttons report themselves. A count is the only feedback for a product the player
-- cannot see, and `skipped` outranks it because a refused loop is the exceptional fact (5.3).
function DistributionRoutingDialog:bulkNotice(n, skipped, blocked, blockKey, blockFb, allowKey, allowFb)
    if skipped > 0 then
        return string.format(SmartDistribution.l10n("dr_rg_loopSkipped", "%d skipped (would loop)"),
                             skipped)
    end
    if n <= 0 then return nil end
    if blocked then return string.format(SmartDistribution.l10n(blockKey, blockFb), n) end
    return string.format(SmartDistribution.l10n(allowKey, allowFb), n)
end

function DistributionRoutingDialog:onToggleAllInputs()
    local d = self._data
    if d == nil then return end
    if SmartDistribution.advancedEnabled == nil or not SmartDistribution.advancedEnabled() then return end
    if DistributionControlEvent == nil or DistributionControlEvent.send == nil then return end
    -- THE DECISION IS TAKEN OVER THE WHOLE BUILDING, once, before anything is sent. Deciding per
    -- product instead would leave a building with one blocked input and five open ones half and
    -- half, each toggling away from its own state rather than toward a common one.
    local states, anyAllowed = self:inputBlockStates(d)
    local n = 0
    for _, w in ipairs(states) do
        if w.blocked ~= anyAllowed then
            DistributionControlEvent.send(DistributionControlEvent.ACT.INPUT_BLOCK,
                                          w.uid, w.ft, "", 0, anyAllowed)
            n = n + 1
        end
    end
    if n > 0 then self:refreshGraph() end
    -- AFTER the refresh, which rewrites the hint line: a notice set before it would be erased.
    self:notice(self:bulkNotice(n, 0, anyAllowed,
                                "dr_rg_nInBlocked", "%d inputs blocked",
                                "dr_rg_nInAllowed", "%d inputs allowed"))
end

function DistributionRoutingDialog:onToggleAllOutputs()
    local d = self._data
    if d == nil then return end
    if SmartDistribution.advancedEnabled == nil or not SmartDistribution.advancedEnabled() then return end
    if DistributionControlEvent == nil or DistributionControlEvent.send == nil then return end
    local work, anyAllowed = self:outputBlockStates(d, false)
    local n, skipped = 0, 0
    for _, w in ipairs(work) do
        local a, b = self:setDestBlocks(w.ft, w.states, anyAllowed)
        n, skipped = n + a, skipped + b
    end
    if n > 0 or skipped > 0 then self:refreshGraph() end
    self:notice(self:bulkNotice(n, skipped, anyAllowed,
                                "dr_rg_nOutBlocked", "%d output links blocked",
                                "dr_rg_nOutAllowed", "%d output links allowed"))
end

-- ---- the building block, laid out to fit ---------------------------------------------------
-- IT HAS NO FIXED HEIGHT: name and type above the picture, every production line below it, and
-- the box grown to wrap however many there are. So it cannot be a declared node with declared
-- children -- it is free-floating siblings positioned absolutely, the same technique the edges
-- and their labels already use here.
--
-- ONE MEASURED UNIT drives all of it, taken from two slot elements a known PITCH apart. That is
-- what keeps a literal px out of `setPosition`, which this project has got wrong six times
-- (5.81 four ways in one feature, then 5.99a and 5.100a) -- and it carries the 6.15 ultrawide
-- widening for free, because the slots themselves do.
function DistributionRoutingDialog:layoutBuilding(d, lines)
    local bg = self.rgBldBg
    local a, b = self.rgIn1, self.rgIn2
    if bg == nil or a == nil or b == nil
       or a.absPosition == nil or b.absPosition == nil then return end
    local unit = math.abs(a.absPosition[2] - b.absPosition[2]) / PITCH_PX
    if unit <= 0 then return end

    -- Captured ONCE, before anything is moved: after the first layout the box's own position is
    -- where this function last put it, not the column geometry the XML declared (5.100a).
    if self._bldX == nil then
        self._bldX = bg.absPosition[1]
        self._bldW = SmartDistribution._elemWidth(bg)
    end
    local ux = self._bldW / BLD_W_PX               -- normalized units per design px, horizontally

    -- THE ROLE'S STORAGE, in up to three rows. Built before the height is computed, because the
    -- box wraps whatever it is given and a row that says nothing must not reserve space.
    local sto = self:buildingStorageRows(d)
    local n = math.min(#lines, BLD_LINES)
    local rows = (#lines > BLD_LINES) and BLD_LINES or n     -- the last row becomes "+N"
    local hPx = BLD_PAD + BLD_NAME_H + BLD_TYPE_H + 6 + BLD_ICON_H
                + ((#sto > 0) and (8 + #sto * BLD_STO_H) or 0)
                + ((rows > 0) and (8 + rows * BLD_ROW_H) or 0) + BLD_PAD
    local h = hPx * unit

    -- CENTRED ON THE MIDDLE SLOT, not on the canvas. They are the same line by construction
    -- (5.107j derives the grid's padding to make it so), but reading the slot means the building
    -- follows the columns if that ever changes rather than having to be re-derived alongside it.
    local mid = self["rgIn" .. math.floor((SLOTS + 1) / 2)]
    local midY = (mid ~= nil and mid.absPosition ~= nil)
        and (mid.absPosition[2] + mid.absSize[2] * 0.5) or (bg.absPosition[2] + h * 0.5)

    bg:setSize(self._bldW, h)
    bg:setAbsolutePosition(self._bldX, midY - h * 0.5)
    bg:setVisible(true)

    -- top-down, in design px off the box's own top edge
    local top = midY + h * 0.5
    local function place(el, wPx, hRowPx, dyPx, dxPx)
        if el == nil then return end
        el:setSize((wPx or BLD_W_PX) * ux, hRowPx * unit)
        el:setAbsolutePosition(self._bldX + (dxPx or 0) * ux, top - (dyPx + hRowPx) * unit)
        el:setVisible(true)
    end
    local y = BLD_PAD
    place(self.rgBldName, BLD_W_PX, BLD_NAME_H, y);            y = y + BLD_NAME_H
    place(self.rgBldType, BLD_W_PX, BLD_TYPE_H, y);            y = y + BLD_TYPE_H + 6
    place(self.rgBldIcon, BLD_ICON_W, BLD_ICON_H, y, (BLD_W_PX - BLD_ICON_W) * 0.5)
    y = y + BLD_ICON_H + 8

    if #sto > 0 then y = y + 0 end
    for i = 1, BLD_STO_N do
        local el = self["rgBldSto" .. i]
        if el ~= nil then
            if sto[i] ~= nil then
                el:setText(sto[i])
                place(el, BLD_W_PX, BLD_STO_H, y)
                y = y + BLD_STO_H
            else
                el:setVisible(false)
            end
        end
    end
    if #sto > 0 then y = y + 8 end

    for i = 1, BLD_LINES do
        local el = self["rgBldL" .. i]
        if el ~= nil then
            if i <= rows then
                local txt
                if i == BLD_LINES and #lines > BLD_LINES then
                    txt = string.format("+%d", #lines - (BLD_LINES - 1))
                else
                    local ln = lines[i]
                    txt = (ln ~= nil) and string.format("%s  -  %s", ln.name or "?", ln.status or "") or ""
                end
                el:setText(txt)
                place(el, BLD_W_PX, BLD_ROW_H, y)
                y = y + BLD_ROW_H
            else
                -- HIDDEN, not merely blanked: the next building may have fewer lines, and a row
                -- left showing would report the previous one's (5.7 / 5.57).
                el:setVisible(false)
            end
        end
    end
end

---What the building node says about the role's storage: what comes IN, what goes OUT, and how
-- the tank is shared. This is what the two TANK COLUMNS used to carry, and it moved here because
-- the building node IS the role (author's call 2026-09-22, on the measurement above).
--
-- IN AND OUT ARE TWO QUANTITIES, NOT ONE READ TWICE. A cow barn's food pool and its milk / manure
-- tanks are different containers, so one figure cannot serve both -- that is 5.107f's finding, and
-- it is the reason this is two rows rather than one. A row with nothing to say is omitted rather
-- than showing a zero, so a pure receiver gets one row and not a blank second.
function DistributionRoutingDialog:buildingStorageRows(d)
    local out = {}
    if d == nil then return out end
    local L = function(k, fb) return SmartDistribution.l10n(k, fb) end
    local heldIn, capIn, heldOut, capOut = 0, 0, 0, 0
    for _, st in ipairs(d.stores or {}) do
        heldIn  = heldIn  + (st.heldIn  or 0)
        heldOut = heldOut + (st.heldOut or 0)
        capIn   = capIn   + (st.capIn   or 0)
        capOut  = capOut  + (st.capOut  or 0)
    end
    local function row(key, fb, held, cap)
        if cap <= 0 and held <= 0 then return end
        if cap > 0 then out[#out + 1] = string.format(L(key, fb), fmtV(held), fmtV(cap))
        else out[#out + 1] = string.format(L(key, fb), fmtV(held), "-") end
    end
    if #d.inputs  > 0 then row("dr_rg_bldStoIn",  "IN  %s / %s",  heldIn,  capIn) end
    if #d.outputs > 0 then row("dr_rg_bldStoOut", "OUT  %s / %s", heldOut, capOut) end

    -- HOW THE TANK IS SHARED. On a building with ONE tank -- 587 of 588 in the corpus -- this is
    -- the same answer for every product of the role, which is exactly why it belongs here and not
    -- on thirteen rows. The outlier says how many tanks instead, and its PRODUCTS carry which.
    local nTanks = #(d.stores or {})
    if nTanks > 1 then
        out[#out + 1] = string.format(L("dr_rg_bldTanks", "%d tanks"), nTanks)
    elseif nTanks == 1 and SmartDistribution.storageTypeLabel ~= nil then
        local ft = d.inputs[1] or d.outputs[1]
        if ft ~= nil then
            local ok, lbl = pcall(SmartDistribution.storageTypeLabel, d.placeable, ft, d.role)
            if ok and type(lbl) == "string" and lbl ~= "" then out[#out + 1] = lbl end
        end
    end
    return out
end

-- ---- selection ---------------------------------------------------------------------------
-- WHY A PAGE-LEVEL HIT TEST rather than turning the nodes into Buttons. The tooltip already
-- needs a hover hit test over these same elements, so one `mouseEvent` answers both questions
-- from one list -- and a Button would have to be given a profile that renders exactly like the
-- node bitmap, which is the atlas-slice risk 5.64 records and 5.107c had to navigate again.
--
-- The FILL TYPE is stamped on the element, never the row index: this page re-enumerates on every
-- building change and a captured index would point at a different product (5.64 / 5.37).
---Describe one routable link, or nil when there is nothing to switch.
--
-- GATED ON ADVANCED ROUTING, and that is not a courtesy: per-destination blocking is an
-- ADVANCED-ONLY concept -- `clearAdvancedControl` wipes the block table outright when the
-- master switch goes off (5.57) -- so a chip offered with it off would write a setting that
-- is deleted the moment anything touches that table.
function DistributionRoutingDialog:togFor(srcUid, ft, destUid, role, name, atEnd)
    if srcUid == nil or ft == nil or destUid == nil then return nil end
    if SmartDistribution.advancedEnabled == nil or not SmartDistribution.advancedEnabled() then return nil end
    if DistributionControlEvent == nil or DistributionControlEvent.send == nil then return nil end
    local blocked = false
    if SmartDistribution.isDestBlocked ~= nil then
        local ok, v = pcall(SmartDistribution.isDestBlocked, srcUid, ft, destUid)
        blocked = (ok and v) and true or false
    end
    return { src = srcUid, ft = ft, dst = destUid, role = role, name = name,
             atEnd = atEnd and true or false, blocked = blocked }
end

---Flip one link, through the SAME event the Advanced dialogs use -- so a change made here and
-- one made there are the same write, replicate identically in multiplayer, and cannot come to
-- disagree. This page adds no new control surface; it puts the existing one on the picture.
function DistributionRoutingDialog:toggleLink(t)
    if t == nil then return end

    -- THE LOOPBACK GUARD, and it applies on BOTH sides. 5.3 flags loop CREATION only, so it is
    -- asked only when ACTIVATING -- blocking a loop is always allowed, and is how you break one.
    -- The source's mode has to be resolved rather than assumed: on gap 1 the source is another
    -- building entirely, and `couldHoldFillType` has been structural since 5.79, so a Move To
    -- source really can appear in this column.
    if t.blocked and SmartDistribution.moveToCreatesLoop ~= nil then
        local M = SmartDistribution.MODE
        local sp = (SmartDistribution.placeableByUid ~= nil)
                   and SmartDistribution.placeableByUid(t.src) or nil
        local m = nil
        if sp ~= nil and SmartDistribution.resolvedAssetMode ~= nil then
            local ok, v = pcall(SmartDistribution.resolvedAssetMode, sp, t.ft, t.role)
            if ok then m = v end
        end
        if M ~= nil and (m == M.STORE_TO or m == M.DISTRIBUTE_STORE_TO)
           and SmartDistribution.moveToCreatesLoop(t.src, t.ft, t.dst) then
            -- Said on the HINT line and the graph left exactly as it was, so the refusal and
            -- the thing refused are on screen together.
            if self.rgHint ~= nil then
                self.rgHint:setText(string.format(
                    SmartDistribution.l10n("dr_adv_loopOne", "Cannot activate %s - it would loop the product back here."),
                    tostring(t.name or t.dst)))
            end
            return
        end
    end

    DistributionControlEvent.send(DistributionControlEvent.ACT.BLOCK,
                                  t.src, t.ft, t.dst, 0, not t.blocked)
    -- `applyLocal` bumps the memo epoch (5.46), so the destination and source memos this page
    -- reads are already stale by the time the refresh enumerates them.
    self:refreshGraph()
end

function DistributionRoutingDialog:markSelectable(el, side, ft, title)
    if el == nil then return end
    el.drSide, el.drFt = side, ft
    self._hot[el] = true
    SmartDistribution.setIconTooltip(el, title)
end

---THE LINE FOLLOWS THE CHIP, and this is 5.46b's TENSE bug arriving one screen over.
--
-- Reported in game: blocking a link left its connector GREEN. Nothing was cached and pressing
-- Refresh would not have helped -- the status word was stale BY DESIGN. `inputSourceRows` ranks
-- FEEDING above everything (5.79: "a source that is visibly working is never labelled by a
-- reason it might not be"), so a source that moved product on the LAST COMPLETED PASS goes on
-- reading FEEDING for the rest of the in-game hour however it is now configured. The two facts
-- are in different tenses -- "it moved last hour" is the past, "it is blocked" is now -- and it
-- is the second that says what happens NEXT.
--
-- Read off the toggle rather than off the word, because the toggle asks `isDestBlocked` LIVE
-- (see togFor, which does this for exactly the same reason one element over). So the chip and
-- the bar it sits on can never contradict each other, which is the invariant that matters on a
-- picture: a red chip on a green line is worse than either alone.
--
-- The drill-down TABLE keeps 5.79's precedence untouched -- this is the line's colour on this
-- page, not a change to what the word means. Known and accepted: a link that is BOTH blocked
-- and out of range now draws red, where 5.79 would say "out of range" because distance is not
-- something the player can press a button about. The chip beside it is already red in that
-- case, so agreeing with it is still the lesser of the two wrongs.
function DistributionRoutingDialog:edgeColour(status, tog)
    if tog ~= nil and tog.blocked then return EDGE_COLOUR.BLOCKED end
    return EDGE_COLOUR[status] or EDGE_COLOUR.STANDBY
end

---Mark a node as a building you can DOUBLE-CLICK to open. `p` is optional: the source and
-- destination rows carry a uid and no placeable, and resolving one is a full placeableSystem
-- scan -- so it is deferred to the click, where it is paid once per press, exactly as the
-- loopback guard in toggleLink already does it (5.76's own rule about that scan).
--
-- TWO DESTINATIONS, and which one is the whole point (author's call 2026-09-22). The building in
-- the MIDDLE opens its own detail tab -- you have its routing on screen already, so the only thing
-- left to look at is its figures. A SOURCE or a DESTINATION opens the ROUTING page FOR ITSELF,
-- because what you want next is that building's own graph: walk the chain, one double-click a hop.
--
-- `ft` and `side` carry the product across the hop. Without them the new building lands on
-- whatever is busiest (5.107h), which is rarely the product you were following.
function DistributionRoutingDialog:markJump(el, uid, p, title, mode, ft, side)
    if el == nil or (uid == nil and p == nil) then return end
    el.drJumpUid, el.drJumpP = uid, p
    el.drJumpMode, el.drJumpFt, el.drJumpSide = mode or "DETAIL", ft, side
    -- THE IDENTITY THE GESTURE IS MATCHED ON, and it is the uid rather than the element: a node
    -- SLOT is reused by whatever building lands in it next, so pairing two clicks by element
    -- would pair a click on one building with a click on another that arrived in the same slot
    -- between them. `tostring(el)` is only the fallback for a building whose uid did not resolve,
    -- where there is nothing better and exactly one such target exists.
    el.drJumpKey = uid or tostring(el)
    self._hot[el] = true
    if title ~= nil then SmartDistribution.setIconTooltip(el, title) end
end

---Open a building's own tab. Reuses the path the Overview's row double-click and `[` + gaze
-- both use, so which tab an asset class lands on -- production / silo / husbandry / heap /
-- market -- and the green tab highlight stay decided in ONE place (5.37).
--
-- `placeableByUid` accepts a ROLE uid and answers with the building (5.65), which is what makes
-- a destination row work whether it names a whole building or one half of one.
---Point THIS page at another building, by the uid a source or destination row carries.
--
-- The uid may be ROLE-SUFFIXED (a destination addressed by `storeRoleUid` names one HALF of a
-- multi-role building) or bare (a source, which `sourcesFor` keys by the base uid). So the exact
-- match is tried first, which lands on precisely the half that was named, and the base match is
-- the fallback -- preferring the PRIMARY role, because that is the row a bare uid means everywhere
-- else in the mod.
function DistributionRoutingDialog:selectBuildingByUid(uid, ft, side)
    if uid == nil then return end
    local baseOf = SmartDistribution.baseUidOf
    local want = (baseOf ~= nil) and baseOf(uid) or uid
    local exact, primary, first = nil, nil, nil
    for i, a in ipairs(self.assets) do
        if a.roleUid == uid then exact = i end
        local ab = (baseOf ~= nil) and baseOf(a.roleUid) or a.roleUid
        if ab == want then
            if first == nil then first = i end
            if a.isPrimaryRole and primary == nil then primary = i end
        end
    end
    local idx = exact or primary or first
    -- A building the picker does not list cannot be shown. That is not a failure to report: it
    -- means the source is not an enrolled, configurable asset, which is a legitimate state.
    if idx == nil then return end
    self.assetIndex = idx
    self._scroll = {}                 -- an offset from the previous building means nothing here
    self._notice = nil
    -- FOLLOW THE PRODUCT ACROSS THE HOP, and the side flips: a SOURCE was supplying it, so on that
    -- building the product is an OUTPUT and its destinations are what you want to see next; a
    -- DESTINATION was receiving it, so there it is an INPUT. pinned() drops the choice by itself if
    -- the product turns out not to be on that side of the new building (5.107h), so this can only
    -- ever help.
    if ft ~= nil then
        if side == "SRC" then self.pinOut = ft
        elseif side == "DST" then self.pinIn = ft end
    end
    self:updateAssetButton()
    self:refreshGraph()
end

function DistributionRoutingDialog:openBuilding(el)
    if el.drJumpMode == "ROUTING" then
        self:selectBuildingByUid(el.drJumpUid, el.drJumpFt, el.drJumpSide)
        return
    end
    local p = el.drJumpP
    if p == nil and SmartDistribution.placeableByUid ~= nil then
        local ok, v = pcall(SmartDistribution.placeableByUid, el.drJumpUid)
        if ok then p = v end
    end
    -- Silently does nothing when the building cannot be resolved, which is what the Overview's
    -- own openRowBuilding does with a nil placeable. There is nothing useful to say: it means
    -- the building was demolished between the two clicks.
    if p == nil or SmartDistribution.jumpMenuToAsset == nil then return end
    pcall(SmartDistribution.jumpMenuToAsset, p)
end

---How far the cursor is from an element's CENTRE, or nil if it is not over it at all.
-- Used to arbitrate between overlapping hit targets, which `pairs` cannot do: its order is
-- unspecified AND unstable, so a first-match hit test on two overlapping chips acts on an
-- arbitrary one of them and then acts on the OTHER one when the next refresh re-orders the
-- table -- exactly the reported "clicking one changes the other, clicking again changes the
-- one I meant". Nearest-centre is deterministic and needs no ordering at all.
local function hitDist(el, mx, my)
    if el == nil or el.absPosition == nil or el.absSize == nil then return nil end
    if el.visible == false then return nil end
    if GuiUtils == nil or GuiUtils.checkOverlayOverlap == nil then return nil end
    local x, y = el.absPosition[1], el.absPosition[2]
    local w, h = el.absSize[1], el.absSize[2]
    if not GuiUtils.checkOverlayOverlap(mx, my, x, y, w, h) then return nil end
    local dx, dy = mx - (x + w * 0.5), my - (y + h * 0.5)
    return dx * dx + dy * dy
end

local function hovered(el, mx, my)
    if el == nil or el.absPosition == nil or el.absSize == nil then return false end
    if el.visible == false then return false end
    if GuiUtils == nil or GuiUtils.checkOverlayOverlap == nil then return false end
    return GuiUtils.checkOverlayOverlap(mx, my, el.absPosition[1], el.absPosition[2],
                                        el.absSize[1], el.absSize[2])
end

---Which node column the cursor is over, or nil. The x band comes from SLOT 1 of the column -- a
-- laid-out element even while hidden -- and the y band from the canvas, so a cursor in the header
-- or the control strip is over no column at all.
function DistributionRoutingDialog:columnAt(posX, posY)
    local c = self.rgCanvas
    if c == nil or c.absPosition == nil or c.absSize == nil then return nil end
    if posY < c.absPosition[2] or posY > c.absPosition[2] + c.absSize[2] then return nil end
    for _, key in ipairs(COL_KEYS) do
        local el = self["rg" .. key .. "1"]
        if el ~= nil and el.absPosition ~= nil and el.absSize ~= nil then
            local x, w = el.absPosition[1], el.absSize[1]
            if posX >= x and posX <= x + w then return key end
        end
    end
    return nil
end

---WHICH DESTINATION SLOT the cursor is over, as an index into the VISIBLE window, or nil.
--
-- Geometric, like every other hit test on this page: the nodes are laid out by the XML and read
-- back through absPosition, so this cannot disagree with what is drawn.
function DistributionRoutingDialog:dstSlotAt(posX, posY)
    local d = self._data
    if d == nil then return nil end
    local from, to, base = self:columnWindow("Dst", #d.dests, 0)
    for i = from, to do
        local el = self["rgDst" .. (base + (i - from) + 1)]
        if el ~= nil and el.absPosition ~= nil and el.absSize ~= nil and el:getIsVisible() then
            local x, y = el.absPosition[1], el.absPosition[2]
            local w, h = el.absSize[1], el.absSize[2]
            if posX >= x and posX <= x + w and posY >= y and posY <= y + h then return i end
        end
    end
    return nil
end

---Redraw the destination column from `self._dragOrder` without re-gathering.
--
-- A full refreshGraph per mouse move would re-walk placeableSystem twice (sourcesFor and the
-- destination resolve), which is the cost 5.52 took off this page's ancestor. This moves TEXT
-- only, which is what a drag needs to look like.
--
-- THE GAP-4 CONNECTORS ARE HIDDEN WHILE DRAGGING, deliberately. They are drawn against slot
-- positions, so mid-drag they would point at whichever building has just shuffled into that
-- slot -- and a link drawn to the wrong building is worse than no link. They come back on drop.
---Move the dragged row to slot `at` in the working order; true when it actually moved.
--
-- REMOVE THEN INSERT, and the order of those two is the whole of it: remove() shifts everything
-- after the old slot left, so dragging DOWN past a row is not the mirror of dragging UP past it
-- and an insert-before-remove is off by one in exactly one direction. That reads in game as the
-- drag being ignored, or as the building landing one place from where it was dropped.
--
-- ITS OWN METHOD so tools/dragorder.lua can drive these two lines rather than keep a copy of them.
function DistributionRoutingDialog:dragTo(at)
    local order = self._dragOrder
    if order == nil or at == nil or self._dragAt == nil then return false end
    if at == self._dragAt or at < 1 or at > #order then return false end
    local row = table.remove(order, self._dragAt)
    table.insert(order, at, row)
    self._dragAt = at
    return true
end

function DistributionRoutingDialog:paintDragOrder()
    local d, order = self._data, self._dragOrder
    if d == nil or order == nil then return end
    local from, to, base = self:columnWindow("Dst", #order, 0)
    for gi = 1, EDGES do
        for si = 1, EDGE_SEGS do
            local e = self["rgE" .. GAPS .. "_" .. ((gi - 1) * EDGE_SEGS + si)]
            if e ~= nil then e:setVisible(false) end
        end
        local l = self["rgLbl" .. GAPS .. "_" .. gi]; if l ~= nil then l:setVisible(false) end
        local t = self["rgTog" .. GAPS .. "_" .. gi]; if t ~= nil then t:setVisible(false) end
    end
    local dstMap = self._dragMap
    for i = from, to do
        local r = order[i]
        local n = self:node("Dst", base + (i - from) + 1, r.icon, r.name,
            string.format("%dm  %s", math.floor(r.dist or 0), r.statusLabel or ""),
            self:destHoldsText(r.uid, d.selOut, dstMap), i == self._dragAt)
        if n == nil then break end
        -- NUMBERED BY POSITION, live. This is the whole point of the gesture: the number you see
        -- while dragging is the number it will have, so 1 is always the top of the column. Shown
        -- as EXPLICIT throughout a drag -- the moment the button is released every one of these
        -- is stored, so previewing them as "measured" would be the wrong promise.
        setRank(n, i, true)
    end
end

---Commit the dragged order: the stored list becomes EXACTLY what is on screen.
--
-- CLEAR THEN APPEND, rather than a PRIO_MOVE delta. toggleDestPriority appends and
-- moveDestPriority refuses a destination that is not already in the list, so a move would need a
-- different sequence depending on what was ranked before -- while clear-then-append states the
-- result directly and lands on it from ANY prior state, including none. It is also what makes
-- "1 is always at the top" true of every row rather than only the one that was dragged: the
-- first drag materialises the implicit distance order into an explicit list.
--
-- One event per destination, each tiny, on an action a player takes deliberately and rarely.
-- Every one goes through DistributionControlEvent, so this replicates exactly as the Advanced
-- Outputs dialog's own ranking does.
function DistributionRoutingDialog:commitDragOrder()
    local d, order = self._data, self._dragOrder
    if d == nil or order == nil or d.selOut == nil then return end
    local srcUid = (SmartDistribution.settingUid ~= nil)
        and SmartDistribution.settingUid(d.placeable, d.selOut, d.role) or nil
    if srcUid == nil then return end
    local A = DistributionControlEvent.ACT
    DistributionControlEvent.send(A.PRIO_CLEAR, srcUid, d.selOut, "", 0, false)
    for _, r in ipairs(order) do
        if r.uid ~= nil then
            DistributionControlEvent.send(A.PRIO_TOGGLE, srcUid, d.selOut, r.uid, 0, false)
        end
    end
end

---Drop the fill order back to nearest-first.
--
-- PRIO_CLEAR is the whole of it: with no stored list, outputDestinations sorts by distance, which
-- is the order the column started in. The badge then shows nothing on any row, which is honest --
-- there is no order to state, not an order of zero.
function DistributionRoutingDialog:onClearOrder()
    local d = self._data
    if d == nil or d.selOut == nil then return end
    local srcUid = (SmartDistribution.settingUid ~= nil)
        and SmartDistribution.settingUid(d.placeable, d.selOut, d.role) or nil
    if srcUid == nil then return end
    DistributionControlEvent.send(DistributionControlEvent.ACT.PRIO_CLEAR, srcUid, d.selOut, "", 0, false)
    self:refreshGraph()
end

function DistributionRoutingDialog:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    local used = DistributionRoutingDialog:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
    local LMB = (Input ~= nil and Input.MOUSE_BUTTON_LEFT or 1)

    -- ---- DRAG A DESTINATION INTO ITS PLACE IN THE FILL ORDER ----
    -- Handled BEFORE everything else, because a drag begins as a press on a node and would
    -- otherwise be read as the click that selects or jumps.
    if self._drag ~= nil then
        if isUp and button == LMB then
            local moved = self._dragAt ~= self._dragFrom
            if moved then self:commitDragOrder() end
            self._drag, self._dragOrder = nil, nil
            self._dragAt, self._dragFrom, self._dragMap = nil, nil, nil
            if moved then
                self:refreshGraph()
                return true
            end
            -- ...OTHERWISE FALL THROUGH. The press never left its slot, so it was a CLICK, and
            -- the double-click jump below is the only thing that can pair it with the next one.
            -- Nothing was painted, so there is nothing to put back.
        end
        if self._drag ~= nil then
            if self:dragTo(self:dstSlotAt(posX, posY)) then self:paintDragOrder() end
            return true
        end
    end
    if not used and isDown and button == LMB then
        local at = self:dstSlotAt(posX, posY)
        -- ONLY WHERE THERE IS AN ORDER TO SET. One destination cannot be re-ordered, and with
        -- advanced routing off the priority table is wiped by clearAdvancedControl (5.57) -- a
        -- drag there would write a setting that is deleted behind the player's back.
        local adv = SmartDistribution.advancedEnabled ~= nil and SmartDistribution.advancedEnabled()
        if at ~= nil and adv and self._data ~= nil and #self._data.dests > 1 then
            self._dragOrder = {}
            for _, r in ipairs(self._data.dests) do self._dragOrder[#self._dragOrder + 1] = r end
            self._drag, self._dragFrom, self._dragAt = true, at, at
            self._dragMap = self:uidPlaceables()
            -- NOT PAINTED YET. Painting here would hide the gap-4 connectors and light the row
            -- the instant the button went down, which is what made an ordinary click look like it
            -- had entered a mode. The column only changes once the cursor reaches another slot.
            return true
        end
    end

    -- ---- THE WHEEL: scroll a column, or step the selection in one ----
    -- POLLED, not read off `button`: that is how SmoothListElement reads the wheel
    -- (SmoothListElement.lua:1637, a file measuring complete), and it is read inside isDown for
    -- the same reason -- a wheel notch arrives as a press.
    if not used and isDown and Input ~= nil and Input.isMouseButtonPressed ~= nil then
        local dir = 0
        if Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_UP) then dir = -1
        elseif Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_DOWN) then dir = 1 end
        if dir ~= 0 then
            local key = self:columnAt(posX, posY)
            if key ~= nil and SCROLL_KEYS[key] then
                self._scroll[key] = math.max(0, (self._scroll[key] or 0) + dir)
                self:refreshGraph()
                return true
            elseif key == "In" or key == "Out" then
                -- THE WHEEL STEPS THE SELECTION HERE, and the window follows it. Scrolling these
                -- two freely would let the selected product leave the window, and the outer column
                -- answers for exactly that product -- so its connectors would have nothing to land
                -- on and every row would read as broken. Stepping keeps the picture coherent and
                -- is the gesture a player reaches for anyway: walk the list, watch the sources
                -- change.
                local d = self._data
                if d ~= nil then
                    local list = (key == "In") and d.inputs or d.outputs
                    local idx  = (key == "In") and (d.selInIdx or 1) or (d.selOutIdx or 1)
                    local nxt = idx + dir
                    if #list > 0 and nxt >= 1 and nxt <= #list then
                        if key == "In" then self.pinIn = list[nxt] else self.pinOut = list[nxt] end
                        self:refreshGraph()
                    end
                    return true
                end
            end
        end
    end
    -- Only an UNUSED left-click, so the tab strip, the arrows and the building button keep theirs.
    if used or not isUp or button ~= (Input ~= nil and Input.MOUSE_BUTTON_LEFT or 1) then return used end
    -- THE CHIPS ARE TESTED FIRST. A chip sits on the trunk, which is not inside any node, so
    -- the two can never actually overlap -- but ordering it this way means a future chip drawn
    -- over a node still does what it says rather than re-pointing the column underneath it.
    local best, bestD = nil, nil
    for el in pairs(self._hot) do
        if el.drTog ~= nil then
            local d = hitDist(el, posX, posY)
            if d ~= nil and (bestD == nil or d < bestD) then best, bestD = el, d end
        end
    end
    if best ~= nil then
        self:toggleLink(best.drTog)
        return true
    end
    for el in pairs(self._hot) do
        if el.drFt ~= nil and hovered(el, posX, posY) then
            -- STICKY, and remembered PER SIDE: picking an input must not disturb which output the
            -- destinations column is answering for, or every click would undo the last one.
            if el.drSide == "IN" then self.pinIn = el.drFt else self.pinOut = el.drFt end
            self:refreshGraph()
            return true
        end
    end
    -- ---- the building nodes: a DOUBLE click opens that building's own tab ----
    -- NEAREST-CENTRE, like the chips, rather than first-match: `pairs` has no order and its
    -- order is not even stable across a rebuild, so a first-match test over two overlapping
    -- targets acts on an arbitrary one and then on the other (5.109a). These three columns
    -- cannot physically overlap, so this costs nothing and cannot be got wrong later.
    local jump, jumpD = nil, nil
    for el in pairs(self._hot) do
        if el.drJumpKey ~= nil then
            local dd = hitDist(el, posX, posY)
            if dd ~= nil and (jumpD == nil or dd < jumpD) then jump, jumpD = el, dd end
        end
    end
    if jump ~= nil then
        local now = (getTimeSec ~= nil) and getTimeSec() or nil
        if now ~= nil and self._clickKey == jump.drJumpKey and self._clickTime ~= nil
           and (now - self._clickTime) <= DOUBLE_CLICK_SEC then
            self._clickKey, self._clickTime = nil, nil   -- consumed, so a third click starts fresh
            self:openBuilding(jump)
        else
            self._clickKey, self._clickTime = jump.drJumpKey, now
        end
        -- CLAIMED EITHER WAY. The first click of the pair has to be swallowed or it falls
        -- through to whatever is behind these nodes on a later build, and the two clicks of one
        -- gesture would then do two different things.
        return true
    end
    return used
end

function DistributionRoutingDialog:update(dt)
    DistributionRoutingDialog:superClass().update(self, dt)
    pcall(SmartDistribution.updateHoverTooltip, dt)
end

---Drawn AFTER the frame so it sits over the graph. The base draw takes clipping arguments in some
-- game versions, so they are passed straight through.
function DistributionRoutingDialog:draw(...)
    DistributionRoutingDialog:superClass().draw(self, ...)
    SmartDistribution.drawHoverTooltip()
end

function DistributionRoutingDialog:onClose()
    SmartDistribution.clearHoverTooltip()
    DistributionRoutingDialog:superClass().onClose(self)
end

---WHICH BUILDING THIS IS FOR. Called BEFORE showDialog, the convention every DR dialog follows,
-- so the graph is already gathered by the time the window appears.
--
-- `side` and `ft` carry the CONTEXT of the button that opened it: Advanced Outputs means "show me
-- this product's destinations", Advanced Inputs means "show me its sources". Without them the
-- dialog lands on whatever moved most last pass (5.107h), which is rarely what you clicked.
-- pinned() drops either choice by itself if the product turns out not to be on that side of the
-- building, so passing one can only ever help.
function DistributionRoutingDialog:setup(asset, role, ft, side)
    self:rebuildAssets()
    if asset ~= nil then
        local uid = (SmartDistribution.roleUid ~= nil) and SmartDistribution.roleUid(asset, role) or nil
        if uid == nil and SmartDistribution.assetUid ~= nil then uid = SmartDistribution.assetUid(asset) end
        if uid ~= nil then self:selectBuildingByUid(uid, ft, side) end
    end
    self:updateAssetButton()
end

function DistributionRoutingDialog:onOpen()
    DistributionRoutingDialog:superClass().onOpen(self)
    -- AFTER super. Every edge figure is read off absPosition / absSize, and an element the layout
    -- pass has not reached carries the GuiElement default of {1,1} -- the WHOLE SCREEN (5.99a).
    -- A dialog's box is positioned and sized at LOAD and does not move when it is shown, so its
    -- geometry is already settled here; the graph reads through _elemWidth regardless, which
    -- prefers `size` and treats absSize as the fallback, so a build that ordered this differently
    -- degrades to correct rather than to a bar across the page.
    if #self.assets == 0 then self:rebuildAssets() end
    self:refreshGraph()
end
