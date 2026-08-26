-- ============================================================================
-- DistributionAdvancedDialog.lua  (Distribution Redux)
--
-- "Advanced" pop-up: granular routing for ONE selected output of a building.
--
-- Opened for the output highlighted in the page (its fill type is passed to
-- setup), and only offered when that output's mode routes somewhere the player
-- can configure (SmartDistribution.modeConfigurable).
--
-- TWO lists side by side:
--   left  = DEMANDS   (buildings that consume the product)
--   right = STORAGE or MARKETS, per the mode
-- Every destination row (demand, store or market) supports the SAME two actions:
--   Priority  -- rank it (first press appends, later presses move it)
--   Block/Activate -- block or unblock this output -> destination edge
-- Which lists are populated depends on the mode:
--   Distribute alone          -> demands only
--   Store / Move To            -> storage only (right)
--   Market Supply              -> markets only (right)
--   Distribute + Store/Move To -> demands (left) + storage (right)
--   Distribute + Market        -> demands (left) + markets (right)
--
-- Move To differs from Store ONLY in its default: its storage destinations start
-- BLOCKED (seeded when the output enters the mode), so nothing moves until the
-- player deliberately activates targets -- the loop-safe default.
--
-- SELECTION IS MUTUALLY EXCLUSIVE across the two lists: selecting in one clears
-- the other, so exactly one row is ever highlighted and the action buttons always
-- have a single unambiguous target. Every edit goes through DistributionControlEvent.
-- ============================================================================

DistributionAdvancedDialog = {}
local Dlg_mt = Class(DistributionAdvancedDialog, MessageDialog)

local function fmtDist(d)
    if d == nil then return "" end
    return string.format("%dm", math.floor(d + 0.5))
end

local function fillTypeTitle(ft)
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
        if ok and def ~= nil and def.title ~= nil then return def.title end
    end
    return tostring(ft)
end

function DistributionAdvancedDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or Dlg_mt)
    self.demands = {}       -- left list rows
    self.rights  = {}       -- right list rows (stores OR markets)
    self.activeList = nil   -- "DEMAND" or the right kind ("STORE"/"MARKET") -- whichever holds the selection
    self.demandIndex, self.rightIndex = 1, 1
    return self
end

function DistributionAdvancedDialog:setup(asset, ft, role)
    self.asset = asset
    self.ft = ft
    -- WHICH HALF of the building this dialog is configuring. Carried so every source-side key below
    -- names the same half the MODE was set on -- see the header on outputDestinations. nil for an
    -- ordinary building, which is every building that does only one job.
    self.role = role
    self.demandIndex, self.rightIndex = 1, 1
    self.activeList = nil
    self:resolveOutput()
    self:rebuildRows()
end

-- Resolve the selected output's mode + which destination kinds it routes to. Productions carry the
-- parallel VIRTUAL mode; everything else uses the generic asset mode.
function DistributionAdvancedDialog:resolveOutput()
    self.outName, self.modeName = fillTypeTitle(self.ft), ""
    self.showDemands, self.rightKind = false, nil
    self.isMoveTo = false                      -- only Move To can close a routing ring
    local a, ft = self.asset, self.ft
    if a == nil or ft == nil or SmartDistribution == nil then return end

    local pp = SmartDistribution.productionPointOf ~= nil and SmartDistribution.productionPointOf(a) or nil
    -- A PASS-THROUGH STORE HAS A PRODUCTION POINT, BUT ITS TANK PRODUCTS ARE NOT PRODUCTION OUTPUTS.
    --
    -- Branching on `pp ~= nil` alone sent every product of such a building down the v-mode path -- and a
    -- tank product has no v-mode, so seedV fell through to the vanilla engine flag and reported plain
    -- DISTRIBUTE (5.49's exact fingerprint). Reported 2026-08-20: a DriveIn's EGG row read "Distribute"
    -- in this dialog whatever mode was set on the tab.
    --
    -- NOT just a wrong caption: showDemands and rightKind are derived here, so the dialog built the
    -- DEMAND list and never built the store list at all -- which is why no pallet stores appeared for a
    -- product on Move To. A Farma 400 has no production point, took the asset-mode path, and behaved --
    -- that contrast is what identified it.
    --
    -- The v-mode belongs to products the PRODUCTION half owns (5.65's ownership split). Everything else
    -- on a pass-through store runs on the asset MODE enum, exactly like any silo.
    local usesVMode = (pp ~= nil)
        and (SmartDistribution.usesVMode == nil or SmartDistribution.usesVMode(a, ft))
    if usesVMode then
        local v  = SmartDistribution.productionOutputVMode ~= nil and SmartDistribution.productionOutputVMode(pp, ft) or nil
        self.modeName = (v ~= nil and SmartDistribution.productionOutputVModeName ~= nil)
            and SmartDistribution.productionOutputVModeName(v) or ""
        -- virtual: 1 DISTRIBUTE, 3 DIST+SELL, 4 DIST+STORE, 5 STORE, 6 TRANSFER(market), 7 DIST+MARKET
        self.showDemands = (v == 1 or v == 3 or v == 4 or v == 7)
        if v == 4 or v == 5 then self.rightKind = "STORE"
        elseif v == 6 or v == 7 then self.rightKind = "MARKET" end
    else
        -- WITH THE ROLE. Without it this read the BARE uid -- the PRIMARY half's mode -- so standing on a
        -- pallet-store row showed the SILO half's mode: set the store to Distribute and the dialog still
        -- resolved the silo's Move To, so rightKind became "STORE" and it listed pallet stores instead of
        -- demands. Reported 2026-08-21. self.role was already threaded through every other call here.
        local m = SmartDistribution.resolvedAssetMode(a, ft, self.role)
        local M = SmartDistribution.MODE
        self.modeName = SmartDistribution.modeName(m)
        self.showDemands = (SmartDistribution.modeDistributes ~= nil) and SmartDistribution.modeDistributes(m) or false
        self.isMoveTo = (m == M.STORE_TO or m == M.DISTRIBUTE_STORE_TO)
        if m == M.STORE or m == M.DISTRIBUTE_STORE or m == M.STORE_TO or m == M.DISTRIBUTE_STORE_TO then
            self.rightKind = "STORE"
        elseif m == M.TRANSFER_MARKET or m == M.DISTRIBUTE_MARKET then
            self.rightKind = "MARKET"
        end
    end
end

function DistributionAdvancedDialog:rebuildRows()
    self.demands, self.rights = {}, {}
    local a, ft = self.asset, self.ft
    if a == nil or ft == nil or SmartDistribution == nil or SmartDistribution.outputDestinations == nil then return end
    if self.showDemands then
        self.demands = SmartDistribution.outputDestinations(a, ft, true, false, false, self.role)
    end
    if self.rightKind == "STORE" then
        self.rights = SmartDistribution.outputDestinations(a, ft, false, true, false, self.role)
    elseif self.rightKind == "MARKET" then
        self.rights = SmartDistribution.outputDestinations(a, ft, false, false, true, self.role)
    end
    -- LOOPBACK TEST: with Move To selected, an ACTIVE storage destination that can send this product back
    -- to us -- directly (A->B->A) or round any longer ring (A->B->C->A) -- would shuttle stock forever and
    -- bill a distribution cost every cycle while moving nothing on net.  Mark it rather than let the
    -- player activate a route that silently does that.  The graph is walked once, not once per row.
    if self.isMoveTo and self.rightKind == "STORE" and #self.rights > 0
       and SmartDistribution.moveToCreatesLoop ~= nil and SmartDistribution.assetUid ~= nil then
        local srcUid = SmartDistribution.settingUid(a, ft, self.role) or SmartDistribution.assetUid(a)
        if srcUid ~= nil then
            local edges = (SmartDistribution.moveToActiveEdges ~= nil)
                and SmartDistribution.moveToActiveEdges(ft) or nil
            for _, d in ipairs(self.rights) do
                if not d.blocked and d.uid ~= nil
                   and SmartDistribution.moveToCreatesLoop(srcUid, ft, d.uid, edges) then
                    d.statusLabel = SmartDistribution.l10n("dr_adv_activeInvalid", "Active - Invalid")
                    d.status      = "INVALID"
                end
            end
            local lc = SmartDistribution.LINK_COLOR
            if type(lc) == "table" and lc.INVALID == nil then lc.INVALID = { 0.90, 0.25, 0.20, 1 } end
        end
    end
    if self.demandIndex > #self.demands then self.demandIndex = math.max(1, #self.demands) end
    if self.rightIndex  > #self.rights  then self.rightIndex  = math.max(1, #self.rights)  end
    -- default the active list if nothing chosen yet: demands if present, else the right list
    if self.activeList == nil then
        if #self.demands > 0 then self.activeList = "DEMAND"
        elseif #self.rights > 0 then self.activeList = self.rightKind end
    end
end

function DistributionAdvancedDialog:onOpen()
    DistributionAdvancedDialog:superClass().onOpen(self)
    if self.demandList ~= nil then self.demandList:setDataSource(self); self.demandList:setDelegate(self) end
    if self.rightList  ~= nil then self.rightList:setDataSource(self);  self.rightList:setDelegate(self)  end
    self:refresh()
end

function DistributionAdvancedDialog:refresh()
    if self._refreshing then return end
    self._refreshing = true
    if self.demandList ~= nil then self.demandList:reloadData() end
    if self.rightList  ~= nil then self.rightList:reloadData() end
    if self.dialogTitleElement ~= nil and self.asset ~= nil then
        local nm = (self.asset.getName ~= nil) and self.asset:getName() or SmartDistribution.l10n("dr_label_building", "Building")
        -- format string, not concatenation: word order round the building name differs by language
        self.dialogTitleElement:setText(string.format(SmartDistribution.l10n("dr_adv_title", "Advanced - %s"), tostring(nm)))
    end
    if self.dialogTextElement ~= nil then
        -- The reserve is no longer PRINTED here: it is the editable field beside this line, which is
        -- both the display and the control. Keeping a second read-only copy in the subtitle would be a
        -- figure that has to be kept in step with the box for no benefit, and it is the width this
        -- centred line gives back that lets the field sit in the left margin at all.
        local line = string.format("%s  (%s)", tostring(self.outName), tostring(self.modeName))
        -- A transient notice (e.g. a refused loopback activation) is shown HERE, inside the dialog.
        -- g_currentMission:showBlinkingWarning draws behind an open menu, so it stays invisible until
        -- every window is closed -- useless for feedback on a button press.
        if self._notice ~= nil and self._notice ~= "" then line = line .. "     " .. self._notice end
        self.dialogTextElement:setText(line)
    end
    if self.rightHeaderElement ~= nil then
        self.rightHeaderElement:setText(self.rightKind == "MARKET" and "MARKETS" or "STORAGE")
    end
    -- The typed reserve field follows the stored value -- EXCEPT while the player is actually typing
    -- in it. refresh() runs on every selection change and after every button press, so without the
    -- isCapturingInput guard a half-typed figure would be wiped out from under them mid-entry.
    if self.reserveInput ~= nil and self.reserveInput.setText ~= nil
       and self.reserveInput.isCapturingInput ~= true then
        local cur = self:currentReserve()
        self.reserveInput:setText((cur ~= nil and cur > 0) and tostring(math.floor(cur + 0.5)) or "")
    end
    self:updateToggleLabel()
    self:updateToggleAllLabel()
    self._refreshing = false
end

-- ---- output RESERVE --------------------------------------------------------
-- A floor in litres this building keeps back for the selected output: nothing is distributed, sold,
-- stored, moved or sent to a market until it holds MORE than this, and every draw-off is capped so it
-- can only come back down to the number, never below it. The mirror of the Advanced Inputs fill target.
--
-- Stepped as a wrapping ring in 5%-of-capacity increments (Off -> 5% -> ... -> 100% -> Off), so one
-- button pair works for a 5,000 L production buffer and a 500,000 L silo alike, while the VALUE stored
-- and shown is plain litres.
DistributionAdvancedDialog.RESERVE_STEPS = 20     -- 20 presses from empty to full capacity

-- The ceiling a reserve is measured against, and what the typed field clamps to. ROLE-SCOPED:
-- outputCapacityTotal takes a role and this was not passing one, so on a multi-role building it
-- answered for the PLACEABLE -- a pallet-store row clamped against the silo half's tank. That is the
-- 5.65 rule (every read behind a role-scoped figure must be role-scoped) missed on one call.
-- Returns 0 when nothing resolves, and BOTH callers treat 0 as "no ceiling known": the ring refuses to
-- step and the typed field skips the clamp rather than snapping the value to zero.
function DistributionAdvancedDialog:reserveCapacity()
    if self.asset == nil or self.ft == nil or SmartDistribution.outputCapacityTotal == nil then return 0 end
    local ok, c = pcall(SmartDistribution.outputCapacityTotal, self.asset, self.ft, self.role)
    return (ok and type(c) == "number" and c < math.huge) and c or 0
end

function DistributionAdvancedDialog:currentReserve()
    if self.asset == nil or self.ft == nil or SmartDistribution.assetUid == nil then return nil end
    local uid = SmartDistribution.settingUid(self.asset, self.ft, self.role) or SmartDistribution.assetUid(self.asset)
    if uid == nil or SmartDistribution.getOutputReserve == nil then return nil end
    return SmartDistribution.getOutputReserve(uid, self.ft)
end

-- the mod's single litres/kilolitres rule, via SmartDistribution.formatVolume (up to 999 L in litres,
-- above that kL with the extraneous zeros dropped); the local form is only a fallback
local function litres(v)
    if SmartDistribution ~= nil and SmartDistribution.formatVolume ~= nil then
        local ok, s = pcall(SmartDistribution.formatVolume, v or 0)
        if ok and type(s) == "string" then return s end
    end
    local s = tostring(math.floor((v or 0) + 0.5))
    local k
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s .. " L"
end

function DistributionAdvancedDialog:onReserveDelta(dir)
    if self.asset == nil or self.ft == nil or SmartDistribution.assetUid == nil then return end
    local uid = SmartDistribution.settingUid(self.asset, self.ft, self.role) or SmartDistribution.assetUid(self.asset)
    if uid == nil then return end
    local cap = self:reserveCapacity()
    if cap <= 0 then
        self._notice = SmartDistribution.l10n("dr_adv_noCapacity", "No capacity to reserve against")
        self:refresh()
        return
    end
    local step = cap / DistributionAdvancedDialog.RESERVE_STEPS
    local n    = DistributionAdvancedDialog.RESERVE_STEPS + 1        -- ring: Off(0), 1 step .. full(n-1)
    local cur  = self:currentReserve() or 0
    local idx  = (cur <= 0) and 0 or math.floor(cur / step + 0.5)
    if idx > n - 1 then idx = n - 1 end
    local newIdx = (idx + dir) % n
    local amount = (newIdx == 0) and 0 or math.floor(newIdx * step + 0.5)   -- 0 clears back to the Settings default
    if DistributionControlEvent ~= nil and DistributionControlEvent.send ~= nil then
        DistributionControlEvent.send(DistributionControlEvent.ACT.OUTPUT_RESERVE, uid, self.ft, "", 0, false, amount)
    end
    self._notice = nil
    self:refresh()
end
-- ---- FOOTER KEYS -----------------------------------------------------------
-- A ButtonElement's input action is DISPLAY ONLY -- it draws the key glyph and nothing acts on it
-- (grepped: the only readers in the engine are ButtonElement and InputGlyphElementUI). A dialog that
-- wants the key to work has to handle it itself, the way YesNoDialog:inputEvent does.
--
-- Reported 2026-08-26 as "every footer button shows the Enter glyph". TWO faults, and the second is why
-- the first mattered:
--   * the XML attribute ButtonElement reads is `#inputAction`; DR wrote `inputActionName`, which is
--     never read. So every button fell through to the buttonOK PROFILE's action and drew the same glyph.
--   * and no dialog overrode inputEvent, so NONE of the keys did anything anyway. The glyphs were not
--     merely identical, they were claiming keys that did not exist.
-- This also retires 5.4's "5th/6th-action key-glyph scramble": that was never a limit on how many
-- actions a footer could carry, it was this typo making every extra button look the same.
--
-- OUR ACTIONS ARE HANDLED BEFORE THE SUPERCLASS CALL, and that is not cosmetic ordering. The first
-- version delegated first and acted only on `not eventUsed` -- and MENU_PAGE_NEXT never arrived, so
-- "+ Reserve" did nothing while "- Reserve" (MENU_PAGE_PREV) worked. Something above consumes NEXT and
-- not PREV. Claiming ours first sidesteps whatever that is, and passing eventUsed=true down still tells
-- the base the event is spoken for. Safe here because these are MessageDialogs: no tabs to page, and the
-- lists use MENU_LIST_PAGE_* rather than MENU_PAGE_*.
--
-- MENU_BACK is deliberately NOT claimed -- the close button owns it (Esc). MENU_CANCEL is Backspace, far
-- enough from an accidental press for the bulk "all" button.
--
-- Worth keeping even though it is no longer used: a profile declaring an EMPTY inputAction fails the
-- InputAction[name] lookup in ButtonElement:loadProfile and leaves a button with NO glyph at all --
-- confirmed in game 2026-08-26. That is the way to make a footer button genuinely mouse-only.
function DistributionAdvancedDialog:inputEvent(action, value, eventUsed)
    if not eventUsed and action ~= nil and InputAction ~= nil then
        if     action == InputAction.MENU_EXTRA_1  then self:onMoveUp();      eventUsed = true
        elseif action == InputAction.MENU_EXTRA_2  then self:onMoveDown();    eventUsed = true
        elseif action == InputAction.MENU_ACCEPT   then self:onToggle();      eventUsed = true
        elseif action == InputAction.MENU_ACTIVATE then self:onClear();       eventUsed = true
        elseif action == InputAction.MENU_CANCEL   then self:onToggleAll();   eventUsed = true
        elseif action == InputAction.MENU_PAGE_PREV then self:onReserveDown(); eventUsed = true
        elseif action == InputAction.MENU_PAGE_NEXT then self:onReserveUp();   eventUsed = true
        end
    end
    return DistributionAdvancedDialog:superClass().inputEvent(self, action, value, eventUsed)
end

function DistributionAdvancedDialog:onReserveDown() self:onReserveDelta(-1) end
function DistributionAdvancedDialog:onReserveUp()   self:onReserveDelta( 1) end

-- ---- typed reserve ---------------------------------------------------------
-- Parse what the player typed into litres. Forgiving about the shapes the mod itself PRINTS, because
-- the obvious thing to do is read the figure off the screen and type it back: "12,500", "12500 L" and
-- "12.5 kL" all mean the same number, and 5.56 made kL the mod's own display unit above 999 L.
-- Returns nil for anything that is not a number, and 0 for a deliberate clear.
-- A FILE-LOCAL declared ABOVE its first use (CLAUDE.md 5.44 / 5.57): a local used above its
-- declaration compiles clean and throws a nil-global at call time, inside a GUI callback.
local function parseLitres(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("%s", ""):gsub(",", "")
    if s == "" then return 0 end                      -- empty field clears the reserve
    local mult = 1
    local body = s:match("^(.-)[kK][lL]$")            -- kilolitres, the mod's own display unit
    if body ~= nil then mult, s = 1000, body
    else s = s:gsub("[lL]$", "") end                  -- a trailing plain "L" is decoration
    local n = tonumber(s)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    if n < 0 then return nil end
    return n * mult
end

-- Commit the typed value. Same uid resolution and same event as the +/- ring, deliberately: two ways
-- to set one number must not become two ways to store it.
function DistributionAdvancedDialog:onReserveEntered()
    if self.reserveInput == nil or self.asset == nil or self.ft == nil then return end
    local raw = (self.reserveInput.getText ~= nil) and self.reserveInput:getText() or nil
    -- NOT named `litres`: that is the file-local FORMATTER used two lines below, and shadowing it here
    -- would turn litres(cap) into an attempt to call a number.
    local want = parseLitres(raw)
    if want == nil then
        self._notice = SmartDistribution.l10n("dr_adv_reserveBad", "Reserve: type a number of litres")
        self:refresh()                                -- refresh puts the stored value back in the field
        return
    end

    -- Clamp to what the building can actually hold, and SAY SO rather than silently shrinking the
    -- figure: a reserve above capacity would read as accepted while behaving as "reserve everything".
    local cap = self:reserveCapacity()
    if cap > 0 and want > cap then
        want = cap
        self._notice = string.format(
            SmartDistribution.l10n("dr_adv_reserveClamped", "Reserve capped at capacity: %s"), litres(cap))
    else
        self._notice = nil
    end

    local uid = SmartDistribution.settingUid(self.asset, self.ft, self.role) or SmartDistribution.assetUid(self.asset)
    if uid == nil then return end
    local amount = math.floor(want + 0.5)
    if DistributionControlEvent ~= nil and DistributionControlEvent.send ~= nil then
        DistributionControlEvent.send(DistributionControlEvent.ACT.OUTPUT_RESERVE, uid, self.ft, "", 0, false, amount)
    end
    self:refresh()
end

-- ESC abandons the edit rather than committing it, and refresh() restores the stored figure.
function DistributionAdvancedDialog:onReserveEscaped()
    self._notice = nil
    self:refresh()
end

-- ---- list data ------------------------------------------------------------
function DistributionAdvancedDialog:getNumberOfItemsInSection(list, section)
    if list == self.demandList then return #self.demands end
    if list == self.rightList  then return #self.rights end
    return 0
end

function DistributionAdvancedDialog:populateCellForItemInSection(list, section, index, cell)
    local function setc(name, text)
        local c = cell:getAttribute(name)
        if c ~= nil and c.setText ~= nil then c:setText(text or "") end
    end
    local d = (list == self.demandList) and self.demands[index] or self.rights[index]
    if d == nil then return end
    setc("name",   d.name)
    setc("dist",   fmtDist(d.dist))
    setc("rank",   d.rank ~= nil and ("#" .. tostring(d.rank)) or "-")
    setc("status", d.statusLabel)
    local sc = cell:getAttribute("status")
    local col = (SmartDistribution.LINK_COLOR or {})[d.status]
    if sc ~= nil and col ~= nil and sc.setTextColor ~= nil then sc:setTextColor(col[1], col[2], col[3], col[4]) end
end

-- WHICH TABLE THE BUTTONS ACT ON. A compound mode (Distribute + Move To) shows demands on the LEFT and
-- stores on the RIGHT, and the player must be able to pick a row in either and have the button operate
-- on that row alone.
--
-- THE OLD CODE TRIED TO FORCE THE OTHER LIST TO "NO SELECTION" and it did neither thing it claimed:
--     pcall(self.rightList.setSelectedItem, self.rightList, 1, 0, false)   -- "clear right selection"
-- SmoothListElement has no clear-selection call. Every base-game caller passes a 1-based index, and the
-- list's own "nothing selected" sentinel (selectedIndex = 0) is assigned to the FIELD directly, never
-- through this method -- whose body is stripped from the SDK source (CLAUDE.md 8.1), so index 0 was a
-- guess. In practice it SELECTED the other list's first row: hence "highlights both rows", and hence the
-- first row of the demand table appearing permanently stuck.
--
-- IT ALSO COULD NOT FIX THE REAL FAULT, which is that this callback does not always fire.
-- SmoothListElement:mouseEvent computes `wasAlreadySelected = self.selectedIndex == clickedIndex`, and
-- BOTH lists are constructed on index 1 (new() sets demandIndex/rightIndex to 1; SmoothListElement.lua:83
-- does the same for its own). So clicking the FIRST row of a table changes no selection and raises no
-- selection-changed event at all -- and `activeList`, which rebuildRows defaults to "DEMAND" whenever
-- there are demands, was never moved off it.
--
-- Net effect on a fresh Distribute + Move To dialog: clicking the first STORE row did nothing
-- observable, and Activate then toggled the first DEMAND row instead -- the other table entirely. Which
-- is exactly "I cannot ever get the storage to be unblocked and the first row of demands is also
-- locked": one row unreachable, the other being toggled without being asked for.
--
-- So selection-changed no longer decides anything. onListClick does -- it is the SmoothList's own
-- onClickCallback, raised as (list, section, index, element, wasAlreadySelected) from notifyClick, AFTER
-- the selection has been applied and REGARDLESS of whether it moved. The cross-clearing is deleted
-- outright; the two lists no longer touch each other at all.
--
-- The double HIGHLIGHT is fixed where it belongs, in the XML: `selectedWithoutFocus="false"` on both
-- lists. That field defaults to TRUE, and it is what setSelected() consults --
--     element:setSelected(... and (self.selectedWithoutFocus or FocusManager:getFocusedElement() == self))
-- so with it false only the FOCUSED list draws its highlight, and clicking a list focuses it
-- (SmoothListElement.lua:1580). The base game's own mechanism, rather than a second one fighting it.
function DistributionAdvancedDialog:onListSelectionChanged(list, section, index)
    if self._refreshing then return end
    self._notice = nil                      -- any pending message is stale once the selection moves
    self:noteActiveList(list, index)
end

-- Fires on EVERY click, including a re-click of the already-selected row -- which is the case
-- onListSelectionChanged cannot see and the whole reason this exists.
function DistributionAdvancedDialog:onListClick(list, section, index, element, wasAlreadySelected)
    if self._refreshing then return end
    self._notice = nil
    self:noteActiveList(list, index)
end

function DistributionAdvancedDialog:noteActiveList(list, index)
    if list == self.demandList then
        if index ~= nil then self.demandIndex = index end
        self.activeList = "DEMAND"
    elseif list == self.rightList then
        if index ~= nil then self.rightIndex = index end
        self.activeList = self.rightKind
    else
        return
    end
    self:updateToggleLabel()
end

-- The row templates carry these so a click on a CELL is not swallowed before the list sees it; the list
-- itself now reports the click through onListClick, so these stay empty on purpose.
function DistributionAdvancedDialog:onClickDemandRow(element) end
function DistributionAdvancedDialog:onClickRightRow(element) end

-- Relabel the Block/Activate button for the selected row. One uniform action for every destination
-- kind: if the edge is currently blocked the button says "Activate" (unblock), else "Block".
function DistributionAdvancedDialog:updateToggleLabel()
    if self.toggleButton == nil or self.toggleButton.setText == nil then return end
    local r = self:selectedRow()
    local label = SmartDistribution.l10n("dr_btn_toggle", "Toggle")
    if r ~= nil then
        label = r.blocked and SmartDistribution.l10n("dr_btn_activate", "Activate") or SmartDistribution.l10n("dr_btn_block", "Block")
    end
    self.toggleButton:setText(label)
end

-- ---- actions (all routed through the MP-safe control event) ----------------
-- The single selected row + its owning list.
function DistributionAdvancedDialog:selectedRow()
    if self.asset == nil then return nil end
    local srcUid = SmartDistribution.settingUid(self.asset, self.ft, self.role) or SmartDistribution.assetUid(self.asset)
    if srcUid == nil then return nil end
    if self.activeList == "DEMAND" then
        return self.demands[self.demandIndex], "DEMAND", srcUid, self.demandList
    elseif self.activeList ~= nil then
        return self.rights[self.rightIndex], self.activeList, srcUid, self.rightList
    end
    return nil
end

-- Apply an edit, rebuild, and keep the highlight on the same row (ranking moves it).
function DistributionAdvancedDialog:sendControl(act, a, ft, b, delta, flag, whichList, keepUid)
    if DistributionControlEvent ~= nil and DistributionControlEvent.send ~= nil then
        DistributionControlEvent.send(act, a, ft, b, delta or 0, flag or false)
    end
    self:rebuildRows()
    if keepUid ~= nil then
        local rows = (whichList == self.demandList) and self.demands or self.rights
        for i, r in ipairs(rows) do
            if r.uid == keepUid then
                if whichList == self.demandList then self.demandIndex = i else self.rightIndex = i end
                break
            end
        end
    end
    self:refresh()
    if whichList ~= nil and whichList.setSelectedItem ~= nil then
        local idx = (whichList == self.demandList) and self.demandIndex or self.rightIndex
        pcall(whichList.setSelectedItem, whichList, 1, idx, true)
    end
end

function DistributionAdvancedDialog:onMove(delta)
    local r, _, srcUid, whichList = self:selectedRow()
    if r == nil then return end
    local A = DistributionControlEvent.ACT
    -- Same for every destination kind: first Priority press ranks it (append), later presses move it.
    if r.rank == nil then self:sendControl(A.PRIO_TOGGLE, srcUid, self.ft, r.uid, 0, false, whichList, r.uid)
    else self:sendControl(A.PRIO_MOVE, srcUid, self.ft, r.uid, delta, false, whichList, r.uid) end
end
function DistributionAdvancedDialog:onMoveUp()   self:onMove(-1) end
function DistributionAdvancedDialog:onMoveDown() self:onMove( 1) end

-- Block / activate the output -> destination edge, uniformly for demands, stores and markets.
function DistributionAdvancedDialog:onToggle()
    local r, _, srcUid, whichList = self:selectedRow()
    if r == nil then return end
    -- LOOPBACK GUARD: refuse to ACTIVATE a route that would send this product back to where it started,
    -- directly (A->B->A) or round any longer ring (A->B->C->A). Activating is the r.blocked == true case,
    -- since the toggle clears the block. Blocking an existing loop is always allowed -- that is the cure.
    if r.blocked and self.isMoveTo and r.uid ~= nil
       and SmartDistribution.moveToCreatesLoop ~= nil
       and SmartDistribution.moveToCreatesLoop(srcUid, self.ft, r.uid) then
        self._notice = string.format(SmartDistribution.l10n("dr_adv_loopOne", "Cannot activate %s - it would loop the product back here."), tostring(r.name))
        self:refresh()
        return
    end
    self._notice = nil
    local A = DistributionControlEvent.ACT
    self:sendControl(A.BLOCK, srcUid, self.ft, r.uid, 0, not r.blocked, whichList, r.uid)
end

-- Block or activate EVERY destination in one press, across both lists. Direction is decided by what is
-- on screen: if anything is still active it blocks them all, otherwise it activates them all. Activation
-- still honours the loopback guard -- any destination that would close a ring is left blocked and the
-- count is reported in the notice line rather than silently skipped.
function DistributionAdvancedDialog:onToggleAll()
    if self.asset == nil or SmartDistribution.assetUid == nil then return end
    if DistributionControlEvent == nil or DistributionControlEvent.send == nil then return end
    local srcUid = SmartDistribution.settingUid(self.asset, self.ft, self.role) or SmartDistribution.assetUid(self.asset)
    if srcUid == nil then return end
    local rows = {}
    for _, r in ipairs(self.demands) do rows[#rows + 1] = r end
    for _, r in ipairs(self.rights)  do rows[#rows + 1] = r end
    if #rows == 0 then return end
    local anyActive = false
    for _, r in ipairs(rows) do if not r.blocked then anyActive = true; break end end
    local blockTarget = anyActive     -- something active -> block everything; nothing active -> activate
    local A, skipped = DistributionControlEvent.ACT, 0
    -- one graph snapshot for the whole sweep: every edge we add shares this source, so adding them
    -- cannot create a NEW return path, and the snapshot stays valid for the pass.
    local edges = nil
    if not blockTarget and self.isMoveTo and SmartDistribution.moveToActiveEdges ~= nil then
        edges = SmartDistribution.moveToActiveEdges(self.ft)
    end
    for _, r in ipairs(rows) do
        if r.uid ~= nil and r.blocked ~= blockTarget then
            local skip = false
            if not blockTarget and self.isMoveTo and SmartDistribution.moveToCreatesLoop ~= nil
               and SmartDistribution.moveToCreatesLoop(srcUid, self.ft, r.uid, edges) then
                skip = true
                skipped = skipped + 1
            end
            if not skip then
                DistributionControlEvent.send(A.BLOCK, srcUid, self.ft, r.uid, 0, blockTarget)
            end
        end
    end
    if skipped > 0 then
        self._notice = string.format(SmartDistribution.l10n("dr_adv_loopMany", "%d destination(s) left blocked - they would loop the product back here."), skipped)
    else
        self._notice = nil
    end
    self:rebuildRows()
    self:refresh()
end

-- "Block All" while anything is still active, otherwise "Activate All".
function DistributionAdvancedDialog:updateToggleAllLabel()
    if self.toggleAllButton == nil or self.toggleAllButton.setText == nil then return end
    local anyActive = false
    for _, r in ipairs(self.demands) do if not r.blocked then anyActive = true; break end end
    if not anyActive then
        for _, r in ipairs(self.rights) do if not r.blocked then anyActive = true; break end end
    end
    self.toggleAllButton:setText(anyActive and SmartDistribution.l10n("dr_btn_blockAll", "Block All") or SmartDistribution.l10n("dr_btn_activateAll", "Activate All"))
end

function DistributionAdvancedDialog:onClear()
    local r, kind, srcUid, whichList = self:selectedRow()
    if r == nil then return end
    local A = DistributionControlEvent.ACT
    self:sendControl(A.PRIO_CLEAR, srcUid, self.ft, "", 0, false, whichList, r.uid)
end

function DistributionAdvancedDialog:onClickBack()
    self:close()
    return false
end
