-- Run from the repository root: lua5.1 tests/run.lua (or luajit).
local passed, failed = 0, 0
function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('PASS ' .. name)
    else failed = failed + 1; io.stderr:write('FAIL ' .. name .. '\n' .. err .. '\n') end
end
function eq(actual, expected)
    assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
function near(actual, expected)
    assert(math.abs(actual - expected) < 1e-9, 'expected ' .. expected .. ', got ' .. tostring(actual))
end
-- Only standard Lua facilities are inherited; each test gets fresh mod globals.
function sandbox(files, globals)
    local env = setmetatable(globals or {}, {__index = _G})
    env._G = env
    for _, file in ipairs(files) do
        setfenv(assert(loadfile('scripts/' .. file .. '.lua')), env)()
    end
    return env
end
for _, suite in ipairs({'pricing', 'sort', 'api', 'events'}) do
    dofile('tests/test_' .. suite .. '.lua')
end
print(string.format('%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
