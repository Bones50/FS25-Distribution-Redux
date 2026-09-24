-- ============================================================================
-- TextPicker.lua -- A NUMBER YOU TYPE, with the arrows still there.
--
-- Requested 2026-09-02: a control to be used anywhere a number is picked, tested
-- first on the auto trader's "How many each time". A selector ring is the wrong
-- instrument for a bounded number -- reaching 47 out of 1..100 is 47 clicks, so
-- every ring in this mod is a CURATED list (1,2,3,4,5,6,8,10,12,15,20,25,30,40,
-- 50) and every value between them is simply unreachable. Typing 47 is one
-- gesture, and the arrows stay for the small nudges they are actually good at.
--
-- ---------------------------------------------------------------------------
-- THIS FILE IS MEANT TO BE COPIED VERBATIM INTO DR, NOT CALLED ACROSS MODS.
-- DR 5.87 ruled that AR must be able to stand alone and that DR must never
-- depend on AR, so a shared widget cannot be a runtime call in either direction.
-- But a control with a parse, a clamp, a wrap and a placeholder rule is real
-- BEHAVIOUR, which is exactly what DR 5.69 promoted out of a GUI file after 6.18
-- recorded three regressions caused by copying helpers between pages. The
-- resolution is the one the page-tab registry reached from the other side: ONE
-- SOURCE FILE, copied, each mod loading its own under its own namespace.
--
-- So this file knows NOTHING about Husbandry Redux. No globals, no l10n lookups --
-- the words are handed in, the pattern AnimalSellPolicy.textFor already uses
-- ("l10n is handed in so this module stays free of any GUI dependency").
--
-- ---------------------------------------------------------------------------
-- THE PURE HALF IS SEPARATE FROM THE ELEMENT HALF, deliberately. parse,
-- stepValue and isDigit are plain functions over plain values and are what the
-- harness drives; render is the only thing that touches a GuiElement. A control
-- whose wrapping arithmetic can only be tested by opening a dialog is a control
-- whose wrapping arithmetic does not get tested.
--
-- ---------------------------------------------------------------------------
-- WHAT THE BASE GAME GIVES, read from TextInputElement.lua (22% blank, 38
-- functions -- COMPLETE, so an absence there is real, CLAUDE.md 8.1):
--
--   onIsUnicodeAllowed  raised from getIsUnicodeAllowed, and a false return
--                       REJECTS the character before it is inserted. That is the
--                       digits-only filter exactly -- not a scrub of the text
--                       afterwards, which would fight the cursor position.
--   onEnterPressed      raised on return AND on a click outside when
--                       enterWhenClickOutside is set. setForcePressed(false) runs
--                       BEFORE it, so by the time we are called the field has
--                       already released the keyboard and render may write to it.
--   onEscPressed        abandons the edit.
--   onTextChanged       every insertion and deletion; this is what takes the
--                       prompt down as the first character lands.
--
-- AND WHAT IT DOES NOT GIVE: a placeholder. imePlaceholder is for the console IME
-- overlay only and never reaches the field. So the grey prompt is a SEPARATE Text
-- element sitting over the box, which is also the only shape that cannot go
-- wrong -- a prompt held in the field's own text becomes real input the moment a
-- character is appended to it ("Enter number...5").
--
-- IT CANNOT STEAL THE CLICK: TextElement declares no mouseEvent of its own, and
-- GuiElement:mouseEvent only propagates to its children and returns what they
-- return. Verified in the shipped source rather than assumed, because a prompt
-- that ate the click would make the field unfocusable and look like a dead
-- control -- a symptom nothing like its cause.
-- ============================================================================

TextPicker = {}
TextPicker.__index = TextPicker

---Longest number that may be typed. Deliberately GENEROUS rather than cut to the
-- width of max: maxCharacters TRUNCATES SILENTLY (TextInputElement:setText), so a
-- 3-character cap would turn a typed 1000 into 100 -- a number that is IN range
-- and is not the one asked for. Better to accept 1000 and refuse it out loud.
TextPicker.MAX_DIGITS = 9

-- ---------------------------------------------------------------------------
-- THE PURE HALF
-- ---------------------------------------------------------------------------

---Is this keystroke a digit? 48..57 and nothing else -- no minus, no decimal
-- point, no separator. Every consumer so far wants a whole positive count, and a
-- filter admitting "-" would have to be paired with a parse that rejects it,
-- which is two places to keep in step for a character nobody wants.
function TextPicker.isDigit(unicode)
    return type(unicode) == "number" and unicode >= 48 and unicode <= 57
end

---Text -> number, or nil. Whitespace and thousands separators are tolerated
-- because the obvious thing to do is read a figure off the screen and type it
-- back (DR 5.70 makes the same allowance for litres).
-- EMPTY IS NOT ZERO. It returns nil for "no number given", which is a different
-- fact from the number 0 -- and 0 is a legal value for some ranges. Conflating
-- the two is the trap DR 5.46c / 5.47 record twice over.
function TextPicker.parse(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("%s", ""):gsub(",", "")
    if s == "" then return nil end
    if s:match("^%d+$") == nil then return nil end
    local n = tonumber(s)
    if n == nil or n ~= n then return nil end
    return math.floor(n)
end

function TextPicker.inRange(n, minV, maxV)
    return type(n) == "number" and n >= minV and n <= maxV
end

---One arrow press. cur may be nil, which is the whole reason this is a function
-- rather than cur + dir.
--   no number yet : RIGHT lands on the minimum, LEFT on the maximum. So either
--                   arrow gives a usable number from an empty field, and the one
--                   that reads as "down from nothing" gives the top.
--   at an end     : it WRAPS, the way the selector ring it replaces did.
--
-- `step` DEFAULTS TO 1, so every caller that does not pass one is byte for byte
-- unchanged. It exists because a range can be far wider than a count: DR 2026-09-22
-- asked for the arrows on a RESERVE in litres to move 5% of the building's capacity,
-- which on a 500,000 L silo is 25,000 a press where 1 is meaningless.
--
-- IT CLAMPS TO THE END BEFORE IT WRAPS, and with step 1 that is the same function.
-- Stepping 98 by 5 in a 0..100 range must reach 100, not skip it and land on 0 --
-- so a step that would overshoot stops at the end, and only a press made FROM the
-- end wraps. At step 1 there is no difference: from maxV the old code wrapped and so
-- does this, and from below maxV neither clamps.
function TextPicker.stepValue(cur, dir, minV, maxV, step)
    if type(dir) ~= "number" or dir == 0 then return cur end
    if type(minV) ~= "number" or type(maxV) ~= "number" or minV > maxV then return nil end
    step = (type(step) == "number" and step >= 1) and math.floor(step) or 1
    if type(cur) ~= "number" then
        if dir > 0 then return minV end
        return maxV
    end
    -- A value already OUTSIDE the range is pulled back to an end rather than
    -- stepped from where it should not have been.
    if cur < minV then return minV end
    if cur > maxV then return maxV end
    local n = math.floor(cur) + (dir > 0 and step or -step)
    if n > maxV then n = (cur >= maxV) and minV or maxV end
    if n < minV then n = (cur <= minV) and maxV or minV end
    return n
end

-- ---------------------------------------------------------------------------
-- THE INSTANCE
-- ---------------------------------------------------------------------------

---opts = { min, max, step, prompt, outOfRange, onChanged }
--   prompt / outOfRange  the two grey messages. STRINGS, already localised: this
--                        file must never reach for a mod's l10n table.
--   step                 how far one arrow press moves. Defaults to 1. Held as
--                        `stepBy`, NOT `step`: TextPicker:step(dir) is a method on
--                        this same table, so a field of that name shadows it and
--                        every arrow throws "attempt to call a number value".
--   onChanged(value)     fired only when the committed value actually moves, so a
--                        caller can refresh a money preview without diffing it.
function TextPicker.new(opts)
    opts = opts or {}
    local self = setmetatable({}, TextPicker)
    self.min        = tonumber(opts.min) or 1
    self.max        = tonumber(opts.max) or 100
    self.stepBy     = tonumber(opts.step) or 1
    self.prompt     = opts.prompt or "Enter number..."
    self.outOfRange = opts.outOfRange or "Number out of range..."
    self.onChanged  = opts.onChanged
    self.value      = nil      -- nil = nothing chosen yet. NEVER 0-as-absent.
    self.bad        = false    -- was the last commit refused for range?
    self.name       = opts.name        -- for the discard diagnostic below only
    return self
end

---SAY SO WHENEVER A TYPED NUMBER IS THROWN AWAY.
--
-- TEMPORARY, added 2026-09-02 to chase a report that turning one switch on cleared
-- EVERY field rather than only the one it governs. Five explanations were built by
-- reading the dialog and not one of them survived, which is exactly the point 5.50
-- names as the trigger to stop reading and instrument.
--
-- There are only three ways a value can be discarded -- an explicit set(nil), a
-- refused commit, and a bound moving under it -- and they all pass through here,
-- so one line names WHICH field lost its value and WHY, in a single run.
--
-- `print`, not a debug-gated log: a player cannot be talked through enabling
-- anything (5.63). Silent on a farm where nothing is being discarded.
function TextPicker:noteDiscard(why)
    print(string.format("[TextPicker] %s: typed value discarded (%s)",
                        tostring(self.name or "?"), tostring(why)))
end

---The elements. `hint` is optional: without one the control still works and simply
-- shows an empty field instead of a grey prompt. The two ARROWS are optional too
-- and are held only so `setInert` can grey them out with the field -- an arrow
-- left live over a dead field is a control that looks like it should work.
function TextPicker:attach(input, hint, left, right)
    self.input, self.hint = input, hint
    self.left, self.right = left, right
    if input ~= nil then input.maxCharacters = TextPicker.MAX_DIGITS end
    return self
end

---HOLD THE CONTROL INERT and show a fixed word where the number would be.
--
-- For a value some OTHER control owns: an order set to run FOREVER has no number
-- of buys, so the field must not merely be ignored, it must stop accepting input
-- and stop looking like it is waiting for some. Every entry point checks it, so
-- there is no route in -- keyboard, commit or arrow.
--
-- THE VALUE IS KEPT, NOT CLEARED. Switching Forever on and off again should give
-- back the number that was typed rather than making the player re-enter it; the
-- caller decides whether to read it (`get`) while inert.
function TextPicker:setInert(on, text)
    on = (on == true)
    local changed = (self.inert ~= on) or (self.inertText ~= text)
    self.inert, self.inertText = on, text
    if changed then self:render() end
    return self
end

---Set the value from code. Out of range is REFUSED rather than clamped: a caller
-- handing over a figure the control cannot represent has a bug, and silently
-- moving it would hide that at the one moment it is visible.
function TextPicker:set(n, silent)
    local old = self.value
    if n == nil then
        self.value, self.bad = nil, false
    elseif TextPicker.inRange(n, self.min, self.max) then
        self.value, self.bad = math.floor(n), false
    else
        self.value, self.bad = nil, true
    end
    if old ~= nil and self.value == nil and not silent then self:noteDiscard("set") end
    self:render()
    if not silent and self.value ~= old and self.onChanged ~= nil then
        self.onChanged(self.value)
    end
    return self.value
end

---Back to the opening state: no number, the ordinary prompt. Called on every
-- open, which is what was asked for -- the field does not remember.
function TextPicker:reset() return self:set(nil, true) end

function TextPicker:get() return self.value end

---Push the state onto the elements.
--
-- IT REFUSES TO WRITE WHILE THE PLAYER IS TYPING. isCapturingInput is the field's
-- own record of holding the keyboard; writing into it mid-edit moves the cursor
-- and eats characters. DR's reserve field carries the same guard for the same
-- reason.
function TextPicker:render()
    local inp = self.input
    local typing = (inp ~= nil and inp.isCapturingInput == true and not self.inert)

    -- GREY THE WHOLE CONTROL, arrows included, so an inert field never looks like
    -- one that is merely empty. The stock arrow profiles carry a transparent
    -- iconDisabledColor, so a disabled arrow simply is not drawn.
    for _, el in ipairs({ inp, self.left, self.right }) do
        if el ~= nil and el.setDisabled ~= nil then pcall(el.setDisabled, el, self.inert == true) end
    end

    if inp ~= nil and inp.setText ~= nil and not typing then
        if self.inert then inp:setText("")
        else inp:setText(self.value ~= nil and tostring(self.value) or "") end
    end
    if self.hint == nil then return end

    -- THE PROMPT IS HIDDEN WHILE THE FIELD IS LIVE, not only while it holds text.
    -- Clicking in gives an empty box with a cursor, which is what every text field
    -- anywhere does; grey words left under a blinking cursor read as text that
    -- will not delete.
    local show = self.inert or ((self.value == nil) and not typing)
    if self.hint.setVisible ~= nil then self.hint:setVisible(show) end
    if show and self.hint.setText ~= nil then
        if self.inert then self.hint:setText(self.inertText or "")
        else self.hint:setText(self.bad and self.outOfRange or self.prompt) end
    end
end

-- ---------------------------------------------------------------------------
-- THE HANDLERS. One line each in the owning dialog.
-- ---------------------------------------------------------------------------

---Digits only. Wired to #onIsUnicodeAllowed.
function TextPicker:allow(unicode)
    if self.inert then return false end
    return TextPicker.isDigit(unicode)
end

---THE VALUE FOLLOWS THE TEXT AS IT IS TYPED. Wired to #onTextChanged.
--
-- IT USED TO WAIT FOR A COMMIT, and that was the whole bug. Two separate attempts
-- to catch "the player left this field" -- enterWhenClickOutside, then a dialog
-- level mouse hook -- both failed for reasons in the engine rather than in this
-- file (27.12), and while a number sat uncommitted ANY refresh wrote the stored
-- value (nothing) straight over it. Hence "changing the toggle clears the fields":
-- there was never anything in them to redraw.
--
-- A KEYSTROKE IS THE ONE EVENT THAT CANNOT GO MISSING. The player can see the
-- digits appear, so onTextChanged demonstrably fires; anchoring the value to it
-- makes the number safe without knowing anything about focus, capture, click
-- ordering or the engine's shared input context. Commit events are still wired and
-- still do the strict range check -- they are no longer load bearing for the VALUE.
--
-- AN OUT OF RANGE PARTIAL DOES NOT DESTROY WHAT CAME BEFORE. Typing 50 into a
-- field capped at 12 passes through "5", which is valid; the "50" simply does not
-- update the value, and no complaint is raised until the player commits. Refusing
-- mid keystroke would make a field impossible to type a two digit number into.
function TextPicker:changed()
    if self.inert then return end
    local inp = self.input
    local txt = (inp ~= nil and inp.getText ~= nil) and inp:getText() or ""
    if type(txt) ~= "string" then txt = "" end

    if txt == "" then
        -- deleting the last character un-answers the field, which is a real state
        -- and not an error: no complaint, no discard note.
        self:setLive(nil)
    else
        local n = TextPicker.parse(txt)
        if n ~= nil and TextPicker.inRange(n, self.min, self.max) then self:setLive(n) end
    end

    if self.hint ~= nil and self.hint.setVisible ~= nil then
        local typing = (inp ~= nil and inp.isCapturingInput == true)
        self.hint:setVisible(txt == "" and self.value == nil and not typing)
    end
end

---Store a value the player is still typing.
--
-- DELIBERATELY NOT `set`: that renders, which would write over the text under the
-- cursor, and it reports a discard, which a half typed number is not. This only
-- moves the value and tells the caller, so the money block follows the keystrokes.
function TextPicker:setLive(n)
    local old = self.value
    if n == old then return n end
    self.value, self.bad = n, false
    if self.onChanged ~= nil then self.onChanged(n) end
    return n
end

---Clear the field and say why. The message stands until the next edit begins.
function TextPicker:setBad(why)
    local old = self.value
    if old ~= nil then self:noteDiscard(why or "out of range") end
    self.value, self.bad = nil, true
    self:render()
    if old ~= nil and self.onChanged ~= nil then self.onChanged(nil) end
    return nil
end

---Commit. Wired to #onEnterPressed, which also fires on a click outside when
-- enterWhenClickOutside is set.
--
-- AN EMPTY FIELD COMMITS TO NOTHING, and that is deliberate rather than a
-- shortcut: blanking the box and pressing Enter is how a player un-sets a value,
-- and keeping the old number while showing an empty box would leave the control
-- and the screen disagreeing about what is chosen.
function TextPicker:enter()
    if self.inert then return self.value end
    local inp = self.input
    local raw = (inp ~= nil and inp.getText ~= nil) and inp:getText() or ""
    if type(raw) ~= "string" then raw = "" end
    local n = TextPicker.parse(raw)
    if n == nil and raw:gsub("%s", "") ~= "" then
        -- Unparseable. It cannot arrive through the keyboard (the digit filter
        -- sees to that) but can through a paste or an IME, so it is refused the
        -- same way an out-of-range number is rather than left standing in the box.
        return self:setBad()
    end
    if n ~= nil and not TextPicker.inRange(n, self.min, self.max) then
        return self:setBad()
    end
    return self:set(n)
end

---ESC abandons the edit and puts the stored value back, exactly as DR's reserve
-- field does. It does NOT clear: escape means "forget what I was typing", not
-- "throw away what was already set".
function TextPicker:escape()
    self:render()
    return self.value
end

---AN ARROW CLICKED MID-EDIT IS A CLICK OUTSIDE THE FIELD, and without this the
-- arrow would silently do nothing.
--
-- The sequence, and the order is the whole problem. GuiElement:mouseEvent visits
-- children in REVERSE, so the arrow (declared last) runs FIRST and steps the
-- value -- but render cannot write to a field that still holds the keyboard, so
-- the box keeps the typed text. The input is then visited, finds the click
-- outside itself, and raises onEnterPressed, which reads that STALE text and
-- commits it OVER the step. Net effect: the first arrow press after typing
-- appears to be swallowed.
--
-- Fixed by taking the field out of capture BEFORE stepping, and committing what
-- was typed. The input's own mouseEvent then finds forcePressed false and takes
-- its "not pressed" branch, which with the cursor outside does nothing but drop
-- the highlight -- so there is no second commit to fight.
--
-- IT COMMITS RATHER THAN DISCARDS, deliberately: typing 47 and clicking the right
-- arrow should mean 48, not 1. An out-of-range or empty entry still resolves the
-- normal way first, and the step then runs from whatever that left.
function TextPicker:releaseAndCommit()
    local inp = self.input
    if inp == nil or inp.isCapturingInput ~= true then return end
    if inp.setForcePressed ~= nil then pcall(inp.setForcePressed, inp, false) end
    inp.isCapturingInput = false
    self:enter()
end

---An arrow. dir is +1 or -1. It always clears an out-of-range message, because
-- pressing an arrow IS a fresh attempt -- leaving the complaint up beside a
-- number the arrow just produced would be describing the previous one.
function TextPicker:step(dir)
    if self.inert then return self.value end
    self:releaseAndCommit()
    return self:set(TextPicker.stepValue(self.value, dir, self.min, self.max, self.stepBy))
end

---Re-range the control. A bound can genuinely move under a live field: DR's reserve
-- is bounded by the selected product's capacity and its step is 5% of it, so both
-- change every time the selection does.
--
-- IT DOES NOT RE-VALIDATE THE STORED VALUE, deliberately. A caller pushing a stored
-- figure in does that itself through `set`, which refuses out of range and says so;
-- silently discarding a value here would fire on every selection change and the
-- player would watch numbers vanish for no visible reason.
function TextPicker:setRange(minV, maxV, step)
    if type(minV) == "number" then self.min = minV end
    if type(maxV) == "number" then self.max = maxV end
    if type(step) == "number" and step >= 1 then self.stepBy = math.floor(step) end
    if self.min > self.max then self.min = self.max end
    return self
end
