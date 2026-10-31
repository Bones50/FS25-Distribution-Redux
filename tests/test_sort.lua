local function sorting(lang)
    local env = sandbox({'DistributionSort'}, {g_languageShort = lang or 'en'})
    return env.DistributionSort, env
end

test('sort: Latin accents and case share a primary key', function()
    local s = sorting()
    eq(s.key('École'), s.key('ecole'))
    eq(s.key('Straße'), s.key('strasse'))
    eq(s.key(nil), '')
end)
test('sort: locale changes invalidate cached keys', function()
    local s, env = sorting('en')
    eq(s.key('ä'), s.key('a'))
    env.g_languageShort = 'sv'
    assert(s.key('z') < s.key('å') and s.key('å') < s.key('ä'))
    env.g_languageShort = 'en'; eq(s.key('ä'), s.key('a'))
end)
test('sort: Czech alias and ch digraph', function()
    local s = sorting('_cz')
    eq(s.getLanguage(), 'cs')
    assert(s.key('h') < s.key('ch') and s.key('ch') < s.key('i'))
end)
test('sort: malformed UTF-8 terminates without error', function()
    local s = sorting()
    assert(type(s.key('\255\192x\226\130')) == 'string')
end)
test('sort: stable rows and numeric tie breakers', function()
    local s = sorting()
    local a, b = {name='same',id=2}, {name='same',id=2}
    local rows = {{name='same',id=10}, a, b}
    eq(s.sort(rows), rows); eq(rows[1], a); eq(rows[2], b)
    eq(s.sort(nil), nil)
end)
test('sort: mixed identifier comparisons remain transitive', function()
    local s = sorting()
    local ids = {2, 10, '11'}
    for _, a in ipairs(ids) do
        for _, b in ipairs(ids) do
            for _, c in ipairs(ids) do
                if s.less('same', a, 'same', b) and s.less('same', b, 'same', c) then
                    assert(s.less('same', a, 'same', c), 'comparison cycle')
                end
            end
        end
    end
    local rows = {{name='same',id=10}, {name='same',id='11'}, {name='same',id=2}}
    s.sort(rows)
    for i=1,#rows do
        for j=i+1,#rows do assert(not s.less('same',rows[j].id,'same',rows[i].id)) end
    end
end)
test('sort: fill type ties use numeric index order', function()
    local s = sorting()
    local list = {10, 2, 1}
    s.sortFillTypes(list, function() return 'same' end)
    eq(table.concat(list, ','), '1,2,10')
end)
