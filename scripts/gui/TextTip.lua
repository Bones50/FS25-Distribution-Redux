-- TextTip.lua -- THE FULL TEXT OF ANY CELL THE LAYOUT HAD TO CUT SHORT, on hover (2026-09-29).
--
-- Author: "add the ability to hover over any field in a table to see the full text ... some people
-- with very small screens lose information." Tables are hand-tiled to fixed widths, and a player on
-- a small or low-resolution screen sees more cells end in "...". This gives them the whole string
-- back without changing a single column.
--
-- ONE SOURCE FILE, COPIED INTO BOTH MODS, exactly like TextPicker.lua: Husbandry Redux must work
-- without Distribution Redux, and DR must never depend on AR (DR 5.87). check_lists.py fails the
-- build if the two copies differ -- change one, copy it to the other.
--
-- NO REGISTRATION AND NO MEASURING. The base game's TextElement keeps the string it was given in
-- `sourceText` and the string it actually draws in `text`; when the layout cuts it, `text` is the
-- shortened copy with "..." (TextElement:setTextInternal, which measures COMPLETE in the SDK). So
-- "was this cell cut?" is exactly `text ~= sourceText`, answered by the game's own layout rather than
-- by a second measurement that could disagree with it. Nothing on any page had to change.
--
-- WIRED ONCE PER CLASS: TextTip.install(cls) wraps a class's update and draw. It is installed on the
-- two BASE page classes (DistributionMenuPage, AnimalMenuPage), which every page inherits through
-- its super calls, and on each dialog class. Never on a subclass of an installed class, or it would
-- scan and draw twice -- the rawget guard only stops the SAME class being installed twice.
--
-- A PAGE WITH ITS OWN HOVER BOX WINS. A page may define hasOwnTooltip(); while it returns true this
-- box stays hidden, so two boxes never stack on one cursor (DR's icon names, AR's action lists).

TextTip = TextTip or {}

TextTip.DELAY_SEC  = 0.35   -- rest this long on a cut cell before the box appears
TextTip.RESCAN_SEC = 0.05   -- re-walk the page at most this often while the mouse moves
TextTip.IDLE_SEC   = 0.25   -- ...and this often while it is still, since rows repopulate on a timer
TextTip.MAX_W      = 0.32   -- wrap width, as a fraction of the screen
TextTip.BORDER     = { 0.22323, 0.40724, 0.00368 }   -- the same green as the other hover boxes

local function clock()
    return (getTimeSec ~= nil) and getTimeSec() or nil
end

---Was this element's text cut to fit? The game's own answer, never a second measurement.
function TextTip.isCut(el)
    local src, shown = el.sourceText, el.text
    return type(src) == "string" and type(shown) == "string" and src ~= "" and shown ~= src
end

-- CLIPPING IS FOLLOWED DOWN THE TREE. A SmoothList clips its rows, so a recycled cell scrolled half
-- out of the list is still laid out beyond it -- without the clip rectangle a hover on the table
-- BELOW would answer with a row that is not visible there. A subtree whose clip area misses the
-- cursor is skipped outright, which is also what keeps the walk cheap on a long list.
local function walk(el, mx, my, x1, y1, x2, y2, best)
    if el == nil or el.visible == false then return best end
    local p, s = el.absPosition, el.absSize
    if el.clipping == true and p ~= nil and s ~= nil then
        x1, y1 = math.max(x1, p[1]), math.max(y1, p[2])
        x2, y2 = math.min(x2, p[1] + s[1]), math.min(y2, p[2] + s[2])
    end
    if mx < x1 or mx > x2 or my < y1 or my > y2 then return best end
    if p ~= nil and s ~= nil and TextTip.isCut(el)
       and mx >= p[1] and mx <= p[1] + s[1] and my >= p[2] and my <= p[2] + s[2] then
        best = el   -- the LAST match wins: children draw after, and so on top of, their parents
    end
    for _, c in ipairs(el.elements or {}) do
        best = walk(c, mx, my, x1, y1, x2, y2, best)
    end
    return best
end

---The cut element under the cursor within `root`, or nil.
function TextTip.find(root, mx, my)
    if root == nil or mx == nil or my == nil then return nil end
    return walk(root, mx, my, 0, 0, 1, 1, nil)
end

---Split `text` into lines no wider than `maxW` at `size`, breaking on spaces. A single word wider
-- than the limit gets a line of its own rather than being cut: this box exists to show the whole thing.
function TextTip.wrap(text, size, maxW, widthOf)
    widthOf = widthOf or function(s) return (getTextWidth ~= nil) and getTextWidth(size, s) or (#s * size * 0.55) end
    local lines, cur = {}, nil
    for word in tostring(text):gmatch("%S+") do
        local try = (cur == nil) and word or (cur .. " " .. word)
        if cur ~= nil and widthOf(try) > maxW then
            lines[#lines + 1] = cur
            cur = word
        else
            cur = try
        end
    end
    if cur ~= nil then lines[#lines + 1] = cur end
    return lines
end

---One frame of tracking for `owner` (a page or a dialog). State lives on the owner, so two open
-- screens can never share a box.
function TextTip.tick(owner)
    local st = owner._textTip
    if st == nil then st = {}; owner._textTip = st end
    if g_inputBinding == nil or g_inputBinding.getMousePosition == nil then st.text = nil; return end
    local mx, my = g_inputBinding:getMousePosition()
    local t = clock()
    if mx == nil or my == nil or t == nil then st.text = nil; return end
    local moved = (mx ~= st.mx or my ~= st.my)
    local age = t - (st.scanT or -1000)
    if (moved and age >= TextTip.RESCAN_SEC) or age >= TextTip.IDLE_SEC then
        local el = TextTip.find(owner, mx, my)
        local text = (el ~= nil) and el.sourceText or nil
        if text ~= st.text then st.text, st.since = text, t end
        st.scanT = t
    end
    st.mx, st.my = mx, my
end

---Draw the box, if the cursor has rested on a cut cell long enough.
function TextTip.draw(owner)
    local st = owner._textTip
    if st == nil or st.text == nil or st.since == nil then return end
    if owner.hasOwnTooltip ~= nil then
        local ok, own = pcall(owner.hasOwnTooltip, owner)
        if ok and own then return end
    end
    local t = clock()
    if t == nil or t - st.since < TextTip.DELAY_SEC then return end
    pcall(TextTip.render, st.mx, st.my, st.text)
end

---Black box, thin green border, white text, wrapped; nudged back inside the screen. The same look
-- as both mods' other hover boxes, so a player cannot tell which one they are reading.
function TextTip.render(mx, my, text)
    if renderText == nil or drawFilledRect == nil or mx == nil then return end
    if new2DLayer ~= nil then new2DLayer() end
    local size = (getCorrectTextSize ~= nil) and getCorrectTextSize(0.013) or 0.013
    local lines = TextTip.wrap(text, size, TextTip.MAX_W)
    if #lines == 0 then return end
    local gap = size * 0.35
    local w = 0
    for _, l in ipairs(lines) do
        local lw = (getTextWidth ~= nil) and getTextWidth(size, l) or (#l * size * 0.55)
        if lw > w then w = lw end
    end
    local padX, padY = 0.008, 0.008
    local boxW = w + 2 * padX
    local boxH = #lines * size + (#lines - 1) * gap + 2 * padY
    local bdX, bdY = 2 * (g_pixelSizeX or 0.0005), 2 * (g_pixelSizeY or 0.0009)
    local bx, by = mx + 0.005, my + 0.013
    if bx + boxW + bdX > 0.99 then bx = 0.99 - boxW - bdX end
    if bx - bdX < 0.01 then bx = 0.01 + bdX end
    if by + boxH + bdY > 0.98 then by = my - boxH - 0.012 end
    if by - bdY < 0 then by = bdY end
    local b = TextTip.BORDER
    drawFilledRect(bx - bdX, by - bdY, boxW + 2 * bdX, boxH + 2 * bdY, b[1], b[2], b[3], 1)
    drawFilledRect(bx, by, boxW, boxH, 0, 0, 0, 1)
    setTextColor(1, 1, 1, 1)
    if RenderText ~= nil then setTextAlignment(RenderText.ALIGN_LEFT) end
    setTextBold(false)
    -- the FIRST line at the TOP: screen y runs upward
    for i, l in ipairs(lines) do
        renderText(bx + padX, by + boxH - padY - i * size - (i - 1) * gap + size * 0.12, size, l)
    end
end

---Wrap `cls`'s update and draw, once. The originals are whatever the class resolves at install
-- time, its own or inherited, and are always called first.
function TextTip.install(cls)
    if type(cls) ~= "table" or rawget(cls, "_textTipInstalled") then return end
    rawset(cls, "_textTipInstalled", true)
    local origUpdate, origDraw = cls.update, cls.draw
    cls.update = function(self, ...)
        if origUpdate ~= nil then origUpdate(self, ...) end
        pcall(TextTip.tick, self)
    end
    cls.draw = function(self, ...)
        if origDraw ~= nil then origDraw(self, ...) end
        TextTip.draw(self)
    end
end
