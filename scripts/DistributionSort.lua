-- ============================================================================
-- DistributionSort.lua  (Distribution Redux) -- DISPLAY-ONLY localized sorting
--
-- One place that answers "which of these two names comes first in the language
-- the player is actually playing in". Used exclusively by the GUI pages to order
-- the DISPLAY copies of their row arrays (self.assets / self.rows / self.inputs /
-- self.outputs / self.lines). It never touches game data, production order,
-- recipes, economy, savegame order or any engine table -- the callers sort their
-- own throwaway tables only.
--
-- The Overview tab (DistributionOverviewPage) is deliberately NOT a caller: its
-- filter list keeps its existing plain table.sort(values) and its behaviour,
-- performance and appearance are unchanged.
--
-- HOW THE COMPARISON WORKS (three levels, so the result is always stable):
--   1. PRIMARY   collation key: one weight byte per letter, diacritics folded to
--                their base letter unless the active language treats the accented
--                form as a LETTER OF ITS OWN (cs c/c-caron, pl a-ogonek, sv/da/no
--                a-ring/a-umlaut/o-umlaut, tr c-cedilla, ro s-comma, ...). Codepoints
--                outside the Latin tables (Cyrillic, Greek, kana, Hangul, CJK) are
--                encoded by codepoint, which for Cyrillic, kana and Hangul syllables
--                IS alphabetical order in Unicode.
--   2. SECONDARY the lowercased raw string, so "e" sorts before "e-acute" rather
--                than the pair being declared equal.
--   3. TERTIARY  a stable identifier handed in by the caller (placeable id,
--                fillType index, production-line id). Two rows can therefore never
--                swap places between two rebuilds of the same list.
--
-- Normalisation is for COMPARISON ONLY. No displayed string is ever altered.
--
-- Everything is nil-safe and pcall-free by construction: a nil / non-string name
-- degrades to the empty key and simply sorts first, and a missing language falls
-- back to the language-independent Latin table.
-- ============================================================================

DistributionSort = {}

-- ---- letter weights --------------------------------------------------------
-- Base Latin letters get weights spaced 4 apart so a language can slot up to
-- three of its own letters between two of them (Polish needs two after z).
local LETTER = {}
do
    local w = 40
    for c = string.byte("a"), string.byte("z") do
        LETTER[c] = w
        w = w + 4
    end
end

-- digits sort before letters, everything else (space, punctuation, symbols)
-- before digits, so "Barley" beats "1st Silo" beats "- unnamed -" consistently.
local DIGIT_BASE = 20
local OTHER_W    = 8

-- Latin-1 / Latin Extended-A folding: accented codepoint -> base ASCII letter.
-- Deliberately generous (Vietnamese tone marks, Turkish dotless i, Romanian
-- comma-below, Polish stroked l, Icelandic eth) because folding is the SAFE
-- default: it can only ever place a name next to its unaccented twin.
local FOLD = {}
local function fold(base, codepoints)
    for _, cp in ipairs(codepoints) do FOLD[cp] = base end
end
fold("a", { 0xC0,0xC1,0xC2,0xC3,0xC4,0xC5,0xE0,0xE1,0xE2,0xE3,0xE4,0xE5,
            0x100,0x101,0x102,0x103,0x104,0x105,0x1CD,0x1CE,0x1EA0,0x1EA1,
            0x1EA2,0x1EA3,0x1EA4,0x1EA5,0x1EA6,0x1EA7,0x1EA8,0x1EA9,0x1EAA,
            0x1EAB,0x1EAC,0x1EAD,0x1EAE,0x1EAF,0x1EB0,0x1EB1,0x1EB2,0x1EB3,
            0x1EB4,0x1EB5,0x1EB6,0x1EB7 })
fold("c", { 0xC7,0xE7,0x106,0x107,0x108,0x109,0x10A,0x10B,0x10C,0x10D })
fold("d", { 0xD0,0xF0,0x10E,0x10F,0x110,0x111 })
fold("e", { 0xC8,0xC9,0xCA,0xCB,0xE8,0xE9,0xEA,0xEB,0x112,0x113,0x114,0x115,
            0x116,0x117,0x118,0x119,0x11A,0x11B,0x1EB8,0x1EB9,0x1EBA,0x1EBB,
            0x1EBC,0x1EBD,0x1EBE,0x1EBF,0x1EC0,0x1EC1,0x1EC2,0x1EC3,0x1EC4,
            0x1EC5,0x1EC6,0x1EC7 })
fold("g", { 0x11C,0x11D,0x11E,0x11F,0x120,0x121,0x122,0x123 })
fold("h", { 0x124,0x125,0x126,0x127 })
fold("i", { 0xCC,0xCD,0xCE,0xCF,0xEC,0xED,0xEE,0xEF,0x128,0x129,0x12A,0x12B,
            0x12C,0x12D,0x12E,0x12F,0x130,0x131,0x1EC8,0x1EC9,0x1ECA,0x1ECB })
fold("j", { 0x134,0x135 })
fold("k", { 0x136,0x137 })
fold("l", { 0x139,0x13A,0x13B,0x13C,0x13D,0x13E,0x141,0x142 })
fold("n", { 0xD1,0xF1,0x143,0x144,0x145,0x146,0x147,0x148 })
fold("o", { 0xD2,0xD3,0xD4,0xD5,0xD6,0xD8,0xF2,0xF3,0xF4,0xF5,0xF6,0xF8,
            0x14C,0x14D,0x14E,0x14F,0x150,0x151,0x1ECC,0x1ECD,0x1ECE,0x1ECF,
            0x1ED0,0x1ED1,0x1ED2,0x1ED3,0x1ED4,0x1ED5,0x1ED6,0x1ED7,0x1ED8,
            0x1ED9,0x1EDA,0x1EDB,0x1EDC,0x1EDD,0x1EDE,0x1EDF,0x1EE0,0x1EE1,
            0x1EE2,0x1EE3,0x1A0,0x1A1 })
fold("r", { 0x154,0x155,0x156,0x157,0x158,0x159 })
fold("s", { 0x15A,0x15B,0x15C,0x15D,0x15E,0x15F,0x160,0x161,0x218,0x219 })
fold("t", { 0x162,0x163,0x164,0x165,0x166,0x167,0x21A,0x21B })
fold("u", { 0xD9,0xDA,0xDB,0xDC,0xF9,0xFA,0xFB,0xFC,0x168,0x169,0x16A,0x16B,
            0x16C,0x16D,0x16E,0x16F,0x170,0x171,0x172,0x173,0x1AF,0x1B0,
            0x1EE4,0x1EE5,0x1EE6,0x1EE7,0x1EE8,0x1EE9,0x1EEA,0x1EEB,0x1EEC,
            0x1EED,0x1EEE,0x1EEF,0x1EF0,0x1EF1 })
fold("w", { 0x174,0x175 })
fold("y", { 0xDD,0xFD,0xFF,0x176,0x177,0x178,0x1EF2,0x1EF3,0x1EF4,0x1EF5,
            0x1EF6,0x1EF7,0x1EF8,0x1EF9 })
fold("z", { 0x179,0x17A,0x17B,0x17C,0x17D,0x17E })

-- Expansions: a single codepoint that collates as two letters.
local EXPAND = {
    [0xDF] = "ss",   -- German sharp s
    [0xC6] = "ae", [0xE6] = "ae",
    [0x152] = "oe", [0x153] = "oe",
    [0xDE] = "th", [0xFE] = "th",
}

local function wOf(letter) return LETTER[string.byte(letter)] end

-- Language-specific letters that are NOT folded, because the language sorts them
-- as letters in their own right. Value = the weight to use (base weight + offset,
-- which is why the base spacing is 4). Keys are lowercase codepoints; the
-- uppercase form is registered automatically from FOLD's own pairing below.
local function after(letter, n) return wOf(letter) + n end

local LANG_LETTERS = {
    cs = {   -- c-caron, d-caron, e-caron, n-caron, r-caron, s-caron, t-caron, z-caron
        [0x10D] = after("c", 1), [0x10F] = after("d", 1), [0x11B] = after("e", 1),
        [0x148] = after("n", 1), [0x159] = after("r", 1), [0x161] = after("s", 1),
        [0x165] = after("t", 1), [0x17E] = after("z", 1),
    },
    sk = {
        [0x10D] = after("c", 1), [0x10F] = after("d", 1), [0x13E] = after("l", 1),
        [0x148] = after("n", 1), [0x161] = after("s", 1), [0x165] = after("t", 1),
        [0x17E] = after("z", 1),
    },
    pl = {   -- a-ogonek, c-acute, e-ogonek, l-stroke, n-acute, o-acute, s-acute, z-acute, z-dot
        [0x105] = after("a", 1), [0x107] = after("c", 1), [0x119] = after("e", 1),
        [0x142] = after("l", 1), [0x144] = after("n", 1), [0xF3]  = after("o", 1),
        [0x15B] = after("s", 1), [0x17A] = after("z", 1), [0x17C] = after("z", 2),
    },
    ro = {   -- a-breve, a-circumflex, i-circumflex, s-comma, t-comma
        [0x103] = after("a", 1), [0xE2] = after("a", 2), [0xEE] = after("i", 1),
        [0x219] = after("s", 1), [0x15F] = after("s", 1),
        [0x21B] = after("t", 1), [0x163] = after("t", 1),
    },
    tr = {   -- c-cedilla, g-breve, dotless i (before i), o-umlaut, s-cedilla, u-umlaut
        [0xE7] = after("c", 1), [0x11F] = after("g", 1), [0x131] = wOf("i") - 1,
        [0xF6] = after("o", 1), [0x15F] = after("s", 1), [0xFC] = after("u", 1),
    },
    hu = {
        [0xE1] = after("a", 1), [0xE9] = after("e", 1), [0xED] = after("i", 1),
        [0xF3] = after("o", 1), [0xF6] = after("o", 2), [0x151] = after("o", 3),
        [0xFA] = after("u", 1), [0xFC] = after("u", 2), [0x171] = after("u", 3),
    },
    sv = { [0xE5] = wOf("z") + 1, [0xE4] = wOf("z") + 2, [0xF6] = wOf("z") + 3 },
    fi = { [0xE5] = wOf("z") + 1, [0xE4] = wOf("z") + 2, [0xF6] = wOf("z") + 3 },
    da = { [0xE6] = wOf("z") + 1, [0xF8] = wOf("z") + 2, [0xE5] = wOf("z") + 3 },
    no = { [0xE6] = wOf("z") + 1, [0xF8] = wOf("z") + 2, [0xE5] = wOf("z") + 3 },
    is = { [0xF0] = after("d", 1), [0xFE] = wOf("z") + 1, [0xE6] = wOf("z") + 2,
           [0xF6] = wOf("z") + 3 },
}
-- lowercase-only tables above; pair every entry with its uppercase codepoint so
-- "Ceres" / "ceres" collate identically. The uppercase form of every Latin
-- Extended-A letter used here is exactly one below its lowercase codepoint,
-- except the Latin-1 block, where it is 0x20 below.
for _, tbl in pairs(LANG_LETTERS) do
    local extra = {}
    for cp, w in pairs(tbl) do
        local upper
        if cp >= 0xE0 and cp <= 0xFE then upper = cp - 0x20
        elseif cp >= 0x100 then upper = cp - 1 end
        if upper ~= nil and tbl[upper] == nil then extra[upper] = w end
    end
    for cp, w in pairs(extra) do tbl[cp] = w end
end

-- Czech and Slovak sort the DIGRAPH "ch" as one letter between h and i.
local DIGRAPH_CH = { cs = true, cz = true, sk = true }

-- Language code normalisation. FS25 ships "cz" in some builds and "cs" in
-- others; both mean Czech. "jp"/"kr" are the game's codes for ja/ko, and
-- br/pt, ct/es, ea/es, fc/fr all reach a table we do not specialise, so they
-- simply take the folded Latin default -- which is correct for them.
local LANG_ALIAS = { cz = "cs", jp = "ja", kr = "ko", br = "pt", ct = "es",
                     ea = "es", fc = "fr", nb = "no", nn = "no" }

-- ---- UTF-8 decoding (no dependency on Lua 5.3 utf8, FS25 runs 5.1) ----------
-- Returns codepoint, nextIndex. Malformed bytes are returned as their own byte
-- value so a broken string can never loop forever or error.
local function nextCp(s, i)
    local b = string.byte(s, i)
    if b == nil then return nil, i end
    if b < 0x80 then return b, i + 1 end
    local n, cp
    if     b >= 0xF0 then n, cp = 4, b - 0xF0
    elseif b >= 0xE0 then n, cp = 3, b - 0xE0
    elseif b >= 0xC0 then n, cp = 2, b - 0xC0
    else return b, i + 1 end
    for k = 1, n - 1 do
        local c = string.byte(s, i + k)
        if c == nil or c < 0x80 or c > 0xBF then return b, i + 1 end
        cp = cp * 0x40 + (c - 0x80)
    end
    return cp, i + n
end

-- ---- key building ----------------------------------------------------------
local currentLang = nil
local langLetters = nil
local useDigraphCh = false
local keyCache = {}          -- name -> primary key; cleared when the language changes
local keyCacheCount = 0
local KEY_CACHE_MAX = 4000   -- generous; names are per-building/per-fillType, not per-frame

function DistributionSort.getLanguage()
    local l = nil
    if type(g_languageShort) == "string" then l = g_languageShort end
    if (l == nil or l == "") and g_i18n ~= nil then
        if type(g_i18n.getLanguageSuffix) == "function" then
            local ok, v = pcall(g_i18n.getLanguageSuffix, g_i18n)
            if ok and type(v) == "string" then l = v end
        end
        if (l == nil or l == "") and type(g_i18n.languageSuffix) == "string" then
            l = g_i18n.languageSuffix
        end
    end
    if type(l) ~= "string" then return "en" end
    l = l:gsub("^_", ""):lower()
    if l == "" then return "en" end
    return LANG_ALIAS[l] or l
end

-- Re-read the language and drop the cached keys. Called lazily on every sort
-- (cheap string compare) and exposed so a page can force it.
function DistributionSort.invalidate()
    currentLang   = nil
    langLetters   = nil
    keyCache      = {}
    keyCacheCount = 0
end

local function ensureLang()
    local lang = DistributionSort.getLanguage()
    if lang ~= currentLang then
        currentLang   = lang
        langLetters   = LANG_LETTERS[lang]
        useDigraphCh  = DIGRAPH_CH[lang] == true
        keyCache      = {}
        keyCacheCount = 0
    end
end

-- One weight byte per collating element. Unknown non-Latin codepoints are
-- emitted as an escape (0xFE) plus three big-endian bytes of the codepoint, so
-- they sort after every Latin letter and among themselves BY CODEPOINT -- which
-- is alphabetical for Cyrillic, Greek, kana and Hangul syllables.
local function primaryKey(s)
    local out, n = {}, 0
    local i, len = 1, #s
    while i <= len do
        local cp, nexti = nextCp(s, i)
        if cp == nil then break end
        local handled = false
        -- Czech / Slovak sort "ch" as ONE letter between h and i (Lua 5.1: no goto)
        if useDigraphCh and (cp == 0x63 or cp == 0x43) then
            local cp2, after2 = nextCp(s, nexti)
            if cp2 == 0x68 or cp2 == 0x48 then
                n = n + 1; out[n] = string.char(wOf("h") + 1)
                i = after2
                handled = true
            end
        end
        if not handled then
            local w = langLetters ~= nil and langLetters[cp] or nil
            if w == nil then
                if cp >= 0x41 and cp <= 0x5A then w = LETTER[cp + 0x20]
                elseif cp >= 0x61 and cp <= 0x7A then w = LETTER[cp]
                elseif cp >= 0x30 and cp <= 0x39 then w = DIGIT_BASE + (cp - 0x30)
                end
            end
            if w ~= nil then
                n = n + 1; out[n] = string.char(w)
            else
                local ex = EXPAND[cp]
                local fb = FOLD[cp]
                if ex ~= nil then
                    for k = 1, #ex do
                        n = n + 1; out[n] = string.char(wOf(ex:sub(k, k)))
                    end
                elseif fb ~= nil then
                    n = n + 1; out[n] = string.char(wOf(fb))
                elseif cp < 0x80 then
                    n = n + 1; out[n] = string.char(OTHER_W)   -- space / punctuation
                else
                    n = n + 1
                    out[n] = string.char(0xFE,
                                         math.floor(cp / 0x10000) % 0x100,
                                         math.floor(cp / 0x100) % 0x100,
                                         cp % 0x100)
                end
            end
            i = nexti
        end
    end
    return table.concat(out)
end

-- Primary collation key for a display name. nil / non-string / empty -> "".
function DistributionSort.key(name)
    if type(name) ~= "string" or name == "" then return "" end
    ensureLang()
    local k = keyCache[name]
    if k == nil then
        k = primaryKey(name)
        if keyCacheCount >= KEY_CACHE_MAX then keyCache = {}; keyCacheCount = 0 end
        keyCache[name] = k
        keyCacheCount = keyCacheCount + 1
    end
    return k
end

-- The three-level comparison. idA / idB are the caller's stable tie-breakers and
-- may be nil, numbers or strings.
local ID_TYPE_ORDER = { ["nil"] = 0, number = 1, string = 2 }
local function idLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return (ID_TYPE_ORDER[ta] or 3) < (ID_TYPE_ORDER[tb] or 3) end
    if ta == "number" or ta == "string" then return a < b end
    return false
end

function DistributionSort.less(nameA, idA, nameB, idB)
    local ka, kb = DistributionSort.key(nameA), DistributionSort.key(nameB)
    if ka ~= kb then return ka < kb end
    local la = (type(nameA) == "string") and nameA:lower() or ""
    local lb = (type(nameB) == "string") and nameB:lower() or ""
    if la ~= lb then return la < lb end
    return idLess(idA, idB)
end

-- Sort a DISPLAY table in place, alphabetically by the localized name each entry
-- shows. nameFn / idFn default to the conventional row fields used by the pages
-- (row.name, and row.ft / row.id / row.sortId as the stable key).
-- Returns the same table for convenience. Never errors on a nil / empty list.
function DistributionSort.sort(list, nameFn, idFn)
    if type(list) ~= "table" or #list < 2 then return list end
    local getName = nameFn or function(e) return type(e) == "table" and e.name or e end
    local getId   = idFn   or function(e)
        if type(e) ~= "table" then return nil end
        return e.sortId or e.ft or e.id
    end
    ensureLang()
    -- decorate / sort / undecorate: one key per element instead of one per compare
    local dec = {}
    for i = 1, #list do
        local e = list[i]
        local nm = getName(e)
        dec[i] = { e = e, k = DistributionSort.key(nm),
                   l = (type(nm) == "string") and nm:lower() or "",
                   id = getId(e), i = i }
    end
    table.sort(dec, function(a, b)
        if a.k ~= b.k then return a.k < b.k end
        if a.l ~= b.l then return a.l < b.l end
        if idLess(a.id, b.id) then return true end
        if idLess(b.id, a.id) then return false end
        return a.i < b.i          -- fully stable: original position is the last word
    end)
    for i = 1, #dec do list[i] = dec[i].e end
    return list
end

-- Sort a plain array of STRINGS in place (used for the input / output name lists
-- that get concatenated into a production-line label).
function DistributionSort.sortStrings(list)
    if type(list) ~= "table" or #list < 2 then return list end
    ensureLang()
    local dec = {}
    for i = 1, #list do
        local s = list[i]
        dec[i] = { s = s, k = DistributionSort.key(s),
                   l = (type(s) == "string") and s:lower() or "", i = i }
    end
    table.sort(dec, function(a, b)
        if a.k ~= b.k then return a.k < b.k end
        if a.l ~= b.l then return a.l < b.l end
        return a.i < b.i
    end)
    for i = 1, #dec do list[i] = dec[i].s end
    return list
end

-- Sort an array of fillType INDICES in place by their localized title, with the
-- index itself as the stable tie-breaker. titleFn lets the caller pass the
-- title lookup it already has (the pages keep their own fillTypeTitle).
function DistributionSort.sortFillTypes(list, titleFn)
    if type(list) ~= "table" or #list < 2 then return list end
    local title = titleFn or function(ft)
        if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
            local ok, def = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, ft)
            if ok and def ~= nil and def.title ~= nil then return def.title end
        end
        return tostring(ft)
    end
    ensureLang()
    local dec = {}
    for i = 1, #list do
        local ft = list[i]
        local nm = title(ft)
        dec[i] = { ft = ft, k = DistributionSort.key(nm),
                   l = (type(nm) == "string") and nm:lower() or "" }
    end
    table.sort(dec, function(a, b)
        if a.k ~= b.k then return a.k < b.k end
        if a.l ~= b.l then return a.l < b.l end
        return idLess(a.ft, b.ft)
    end)
    for i = 1, #dec do list[i] = dec[i].ft end
    return list
end
