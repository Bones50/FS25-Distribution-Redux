-- Input: pairs of display filename and XMLStarlet-generated TSV path.
-- Budgets come from translation_en.xml comments, not font/pixel measurements.
-- Partial translations are valid; only present labels are checked. English is
-- used solely as fallback for units/Off in representative interpolated samples.
if #arg == 0 or #arg % 2 ~= 0 then
    io.stderr:write('Usage: check_localization_limits.lua LABEL TSV [LABEL TSV ...]\n')
    os.exit(2)
end
local budgets = {}
local function group(limit, keys)
    for key in keys:gmatch('%S+') do budgets[key] = limit end
end
group(12, 'dr_rg_hdrSources dr_rg_hdrInputs dr_rg_hdrBuilding dr_rg_hdrOutputs dr_rg_hdrDests')
group(24, 'dr_rg_hintLitres')
group(22, 'dr_rg_hintTarget dr_rg_badRes')
group(40, 'dr_col_buildings dr_col_husbandries dr_col_markets dr_col_productions')
group(16, [[dr_col_building dr_col_product dr_col_received dr_col_loaded dr_col_consumedExp
    dr_col_unloaded dr_col_producedExp dr_col_distributed dr_col_sold dr_col_storedMoved
    dr_col_distrCost dr_col_storageType dr_col_maxInPctL dr_col_heldOfMax dr_col_inStatus
    dr_col_lines dr_col_outMode dr_col_reserve dr_col_priority dr_col_outStatus]])
group(6, 'dr_col_dest')
group(30, 'dr_srcst_feeding dr_srcst_standby dr_srcst_noStock dr_srcst_blocked dr_srcst_notDist dr_srcst_outOfRange')
group(7, 'dr_role_in dr_role_out dr_role_inout')
group(20, 'dr_panel_profit')
group(10, 'dr_panel_pfOutputs dr_panel_pfInputs dr_panel_pfAgeing dr_panel_pfBirths')

local locales, english = {}, {}
local violations, errors, checked = 0, 0, 0
for i = 1, #arg, 2 do
    local name, path = arg[i], arg[i+1]
    local file, err = io.open(path, 'r')
    if not file then
        errors = errors + 1
        print(string.format('ERROR %s: %s', name, err))
    else
        local entries = {}
        for line in file:lines() do
            local key, value = line:match('^(.-)\t(.*)$')
            if line == '' then
                -- XMLStarlet emits a final newline even for an empty partial locale.
            elseif not key or key == '' then
                errors = errors + 1
                print(string.format('ERROR %s: malformed localization row', name))
            else entries[key] = value end
        end
        file:close()
        locales[#locales+1] = {name=name, entries=entries}
        if name:match('translation_en%.xml$') then english = entries end
    end
end
local function check(name, key, original, value, limit, sample)
    local _, length = value:gsub('[^\128-\191]', '') -- UTF-8 codepoints, not bytes
    checked = checked + 1
    if length > limit then
        violations = violations + 1
        print(string.format('LIMIT %s | %s | length=%d limit=%d | text=%q%s',
            name, key, length, limit, original,
            sample and (' | sample=' .. string.format('%q', value)) or ''))
    end
end
for _, locale in ipairs(locales) do
    local entries, keys = locale.entries, {}
    for key in pairs(entries) do keys[#keys+1] = key end
    table.sort(keys)
    local function fallback(key, default) return entries[key] or english[key] or default end
    for _, key in ipairs(keys) do
        local value, limit = entries[key], budgets[key]
        if key:match('^dr_mode_') then limit = 39 end
        if key:match('^dr_status_in_') or key:match('^dr_status_out_') then limit = 20 end
        if limit then check(locale.name, key, value, value, limit) end
        local samples
        if key == 'dr_rg_nodeIn' then
            samples = {
                {'174' .. fallback('dr_unit_kilolitre', ' kL'), '87' .. fallback('dr_unit_kilolitre', ' kL')},
                {'999' .. fallback('dr_unit_litre', ' L'), fallback('dr_rg_targetOff', 'Off')}
            }
        elseif key == 'dr_rg_nodeRes' then
            samples = {{'123.123' .. fallback('dr_unit_kilolitre', ' kL')}}
        end
        if samples then
            for _, sample in ipairs(samples) do
                local ok, rendered = pcall(string.format, value, unpack(sample))
                if ok then check(locale.name, key, value, rendered, 20, true)
                else
                    errors = errors + 1
                    print(string.format('ERROR %s | %s | text=%q | invalid format: %s', locale.name, key, value, rendered))
                end
            end
        end
    end
end
print(string.format('Localization limits: %d file(s), %d checks, %d over-limit result(s), %d error(s).',
    #locales, checked, violations, errors))
os.exit(violations == 0 and errors == 0 and 0 or 1)
