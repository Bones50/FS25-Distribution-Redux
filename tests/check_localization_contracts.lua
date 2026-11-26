-- Compare present translations with English; missing keys may fall back to English.
-- Input files are XMLStarlet-generated TSVs. The first argument is English.
local function read(path)
    local entries = {}
    for line in io.lines(path) do
        if line ~= '' then
            local key, value = line:match('^(.-)\t(.*)$')
            assert(key and key ~= '', path .. ': malformed row')
            assert(entries[key] == nil, path .. ': duplicate key ' .. key)
            entries[key] = value
        end
    end
    return entries
end
local function formats(value)
    local result = {}
    for token in value:gmatch('%%[-+ #0]*%d*%.?%d*[cdiouxXeEfgGqs%%]') do
        result[#result + 1] = token
    end
    return table.concat(result, '|')
end
local function marker(value)
    return value:match('^(#+ )') or value:match('^(%- )') or value:match('^(%d+%. )') or ''
end
assert(#arg >= 2, 'Usage: check_localization_contracts.lua ENGLISH.tsv LOCALE.tsv [...]')
local english, errors, checked = read(arg[1]), 0, 0
for i = 2, #arg do
    local locale, keys = read(arg[i]), {}
    for key in pairs(locale) do keys[#keys + 1] = key end
    table.sort(keys)
    local function verify(ok, key, reason)
        if not ok then
            errors = errors + 1
            print(string.format('%s | %s | %s', arg[i]:match('[^/]+$'), key, reason))
        end
    end
    for _, key in ipairs(keys) do
        local target, source = locale[key], english[key]
        -- Extra legacy/mod-specific keys have no English contract to compare.
        if source ~= nil then
            checked = checked + 1
            verify(target:match('%S') ~= nil, key, 'empty translation')
            -- A percent sign in ordinary prose is not a string.format contract.
            if formats(source) ~= '' then
                verify(formats(source) == formats(target), key, 'format arguments differ')
            end
            if key:match('^dr_guide_') then
                verify(marker(source) == marker(target), key, 'guide structure differs')
            end
            if key:match('^dr_unit_') then
                verify(source:match('^%s*') == target:match('^%s*'), key, 'leading spaces differ')
                verify(source:match('[%s:%-]*$') == target:match('[%s:%-]*$'), key, 'suffix punctuation/spaces differ')
            end
            if key:match('^dr_money_') then
                verify(source:match('%-$') == target:match('%-$'), key, 'money sign differs')
            end
        end
    end
end
print(string.format('Localization contracts: %d locale(s), %d shared key(s), %d error(s).', #arg-1, checked, errors))
os.exit(errors == 0 and 0 or 1)
