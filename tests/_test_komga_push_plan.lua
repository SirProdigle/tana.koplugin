-- tests/_test_komga_push_plan.lua
-- Pure tests for tana_komga_push.planPush (furthest-ahead-wins + re-read).
package.loaded["datastorage"] = { getDataDir = function() return "/tmp" end }
package.loaded["luasettings"] = { open = function() return {} end }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return nil end, dir = function() end }
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end }
package.loaded["ltn12"] = { sink = {}, source = {} }
package.loaded["mime"] = { b64 = function(s) return s end }
package.loaded["socket"] = { skip = function() end }
package.loaded["socketutil"] = { set_timeout = function() end, reset_timeout = function() end }
package.loaded["socket.http"] = { request = function() end }

local Push = dofile("tana_komga_push.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function assert_eq(got, want, what)
    if got ~= want then error((what or "value") .. ": got " .. tostring(got) .. ", want " .. tostring(want), 2) end
end

-- Book helper: {num, pagesCount, page, completed}
local function b(num, pc, page, done) return { num = num, pagesCount = pc, page = page, completed = done } end
local function e(num, page, done) return { num = num, page = page, completed = done } end

test("no server progress: everything pushes", function()
    local plan = Push.planPush({ e(1, 5) }, { b(1, 20), b(2, 20) })
    assert_eq(#plan.pushes, 1); assert_eq(#plan.drops, 0); assert_eq(plan.reset, false)
end)

test("same chapter, higher page: pushes", function()
    local plan = Push.planPush({ e(97, 9) }, { b(96, 20, nil, true), b(97, 22, 5, false) })
    assert_eq(#plan.pushes, 1, "pushes")
end)

test("same chapter, lower page: dropped", function()
    local plan = Push.planPush({ e(97, 3) }, { b(96, 20, nil, true), b(97, 22, 9, false) })
    assert_eq(#plan.pushes, 0, "pushes"); assert_eq(#plan.drops, 1, "drops")
end)

test("behind the furthest chapter: dropped", function()
    local plan = Push.planPush({ e(50, 12) }, { b(50, 20, nil, true), b(97, 22, 9, false) })
    assert_eq(#plan.pushes, 0); assert_eq(#plan.drops, 1)
end)

test("ahead of furthest chapter: pushes", function()
    local plan = Push.planPush({ e(98, 2) }, { b(97, 22, 9, false), b(98, 20) })
    assert_eq(#plan.pushes, 1)
end)

test("completing the furthest in-progress chapter: pushes", function()
    local plan = Push.planPush({ e(97, 22, true) }, { b(97, 22, 9, false) })
    assert_eq(#plan.pushes, 1)
end)

test("finished series + first chapter = re-read reset", function()
    local plan = Push.planPush({ e(1, 2) },
        { b(1, 20, nil, true), b(2, 20, nil, true), b(3, 20, nil, true) })
    assert_eq(plan.reset, true, "reset"); assert_eq(#plan.pushes, 1)
end)

test("almost-finished (within 2 pages) still counts as re-readable", function()
    local plan = Push.planPush({ e(1, 2) },
        { b(1, 20, nil, true), b(2, 20, 18, false), b(3, 20, 19, false) })
    assert_eq(plan.reset, true, "reset")
end)

test("unfinished series + first chapter = plain drop, no reset", function()
    local plan = Push.planPush({ e(1, 2) },
        { b(1, 20, nil, true), b(2, 20, 5, false), b(3, 20) })
    assert_eq(plan.reset, false, "reset"); assert_eq(#plan.drops, 1, "drops")
end)

test("finished series + middle chapter re-open: dropped, no reset", function()
    local plan = Push.planPush({ e(2, 5) },
        { b(1, 20, nil, true), b(2, 20, nil, true), b(3, 20, nil, true) })
    assert_eq(plan.reset, false); assert_eq(#plan.drops, 1)
end)

test("after re-read reset, later entries push in order", function()
    local plan = Push.planPush({ e(2, 4), e(1, 20, true) },
        { b(1, 20, nil, true), b(2, 20, nil, true) })
    assert_eq(plan.reset, true); assert_eq(#plan.pushes, 2, "pushes")
    assert_eq(plan.pushes[1].num, 1); assert_eq(plan.pushes[2].num, 2)
end)

print(string.format("komga push plan: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
