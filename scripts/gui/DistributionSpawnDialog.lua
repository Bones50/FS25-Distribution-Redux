-- ============================================================================
-- DistributionSpawnDialog.lua  (Distribution Redux)
--
-- Pop-up for manually spawning pallets (later: bales / tree saplings) from a
-- production's held stock. A TYPE dropdown (MultiTextOption; locked when there's
-- only one option) and a QUANTITY stepper (MultiTextOption, 1..max where max is
-- held litres / unit capacity), plus Spawn / Cancel. Own code + layout on the
-- base-game dialog frame; a MessageDialog subclass like DR's DistributionSiloDialog.
-- Registered + shown via SmartDistribution.registerMenuGui / openSpawnDialog.
-- ============================================================================

DistributionSpawnDialog = {}
local Dlg_mt = Class(DistributionSpawnDialog, MessageDialog)

local function fmt(n)
    n = math.floor((n or 0) + 0.5)
    local s = tostring(n)
    local k
    repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
    return s
end

function DistributionSpawnDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or Dlg_mt)
    self.options   = {}
    self.optIndex  = 1
    self.count     = 1
    self.onConfirm = nil
    return self
end

-- Populate the dialog for a production output. onConfirm(option, count) fires on Spawn.
function DistributionSpawnDialog:setup(pp, ft, held, onConfirm)
    self.pp = pp
    self.ft = ft
    self.held = held or 0
    self.onConfirm = onConfirm
    self.options = (SmartDistribution ~= nil and SmartDistribution.getSpawnOptions ~= nil)
        and SmartDistribution.getSpawnOptions(pp, ft) or {}
    self.optIndex = 1
    self.count = (#self.options > 0 and (self.options[1].maxCount or 0) > 0) and 1 or 0
end

function DistributionSpawnDialog:onOpen()
    DistributionSpawnDialog:superClass().onOpen(self)
    self._armed = true   -- steppers fire once per press; re-armed on mouse release (see mouseEvent)
    -- type dropdown: one entry per spawn option; lock it when there's only one
    if self.typeElement ~= nil then
        local names = {}
        for _, o in ipairs(self.options) do names[#names + 1] = o.name or "?" end
        if #names == 0 then names = { "-" } end
        self.typeElement:setTexts(names)
        self.typeElement:setState(math.min(self.optIndex, #names), false)
        if self.typeElement.setDisabled ~= nil then self.typeElement:setDisabled(#self.options <= 1) end
    end
    self:rebuildCountTexts()
    self:refresh()
end

function DistributionSpawnDialog:option() return self.options[self.optIndex] end
function DistributionSpawnDialog:maxForSelected()
    local o = self:option()
    return o ~= nil and math.max(0, o.maxCount or 0) or 0
end

-- (re)build the quantity stepper's list to 1..max for the selected type
function DistributionSpawnDialog:rebuildCountTexts()
    if self.countElement == nil then return end
    local maxN = self:maxForSelected()
    local texts = {}
    if maxN <= 0 then
        texts = { "0" }
    else
        for i = 1, maxN do texts[i] = i .. (i == 1 and " pallet" or " pallets") end
    end
    self.countElement:setTexts(texts)
    self.count = math.max(1, math.min(self.count or 1, math.max(1, maxN)))
    self.countElement:setState(math.min(self.count, #texts), false)
    if self.countElement.setDisabled ~= nil then self.countElement:setDisabled(maxN <= 0) end
end

-- update the held / pallet / max description line + the Spawn button enabled state
function DistributionSpawnDialog:refresh()
    local maxN = self:maxForSelected()
    local o = self:option()
    if self.dialogTextElement ~= nil then
        local held = (self.pp ~= nil and self.pp.getFillLevel ~= nil) and self.pp:getFillLevel(self.ft) or self.held
        local capTxt = (o ~= nil and o.capacity ~= nil) and (fmt(o.capacity) .. " l") or "?"
        self.dialogTextElement:setText(string.format("Held: %s l    Pallet: %s    Max: %d", fmt(held), capTxt, maxN))
    end
    if self.yesButton ~= nil and self.yesButton.setDisabled ~= nil then self.yesButton:setDisabled(maxN <= 0) end
end

-- MultiTextOption onClick passes the new STATE (a number), not the element. The arrows auto-repeat while
-- held, so we gate to one +/-1 step per press (disarm after a step; re-armed on mouse release below) and
-- always snap the REAL widget (self.typeElement / self.countElement) back to our controlled value.
function DistributionSpawnDialog:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    local r = DistributionSpawnDialog:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
    if isUp then self._armed = true end
    return r
end

-- Reliable re-arm: while an arrow is held, onClick fires every frame (sets _clicked); the frame it stops
-- firing (button released) we re-arm. This doesn't depend on catching the mouse-up event.
function DistributionSpawnDialog:update(dt)
    DistributionSpawnDialog:superClass().update(self, dt)
    if self._clicked then self._clicked = false else self._armed = true end
end

function DistributionSpawnDialog:onClickType(state)
    local el = self.typeElement
    if el == nil then return end
    self._clicked = true
    state = tonumber(state) or self.optIndex
    if not self._armed then el:setState(self.optIndex, false); return end
    self._armed = false
    if state > self.optIndex then self.optIndex = self.optIndex + 1
    elseif state < self.optIndex then self.optIndex = self.optIndex - 1 end
    self.optIndex = math.max(1, math.min(self.optIndex, math.max(1, #self.options)))
    el:setState(self.optIndex, false)
    self:rebuildCountTexts()
    self:refresh()
end

function DistributionSpawnDialog:onClickCount(state)
    local el = self.countElement
    if el == nil then return end
    self._clicked = true
    state = tonumber(state) or self.count
    if not self._armed then el:setState(self.count, false); return end
    self._armed = false
    local maxN = self:maxForSelected()
    if state > self.count then self.count = self.count + 1
    elseif state < self.count then self.count = self.count - 1 end
    self.count = math.max(1, math.min(self.count, math.max(1, maxN)))
    el:setState(self.count, false)
end

-- +10 / -10 buttons: one clamped step per press (shares the stepper's arm guard)
function DistributionSpawnDialog:onCountStep(delta)
    self._clicked = true
    if not self._armed then return end
    self._armed = false
    local maxN = self:maxForSelected()
    self.count = math.max(1, math.min((self.count or 1) + delta, math.max(1, maxN)))
    if self.countElement ~= nil and self.countElement.setState ~= nil then
        self.countElement:setState(math.min(self.count, math.max(1, maxN)), false)
    end
end
function DistributionSpawnDialog:onCountMinus10() self:onCountStep(-10) end
function DistributionSpawnDialog:onCountPlus10()  self:onCountStep( 10) end

-- Spawn = the dialog's confirm (yes) button; Cancel = the back (no) button
function DistributionSpawnDialog:onClickOk()
    local o = self:option()
    if o ~= nil and self.count and self.count > 0 and self.onConfirm ~= nil then
        self.onConfirm(o, self.count)
    end
    self:close()
    return false
end
function DistributionSpawnDialog:onClickBack()
    self:close()
    return false
end
