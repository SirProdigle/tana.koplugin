-- tests/_test_broadcast_tag.lua
-- Pure-Lua test runner. No KOReader dependencies.
-- Usage: cd into the plugin dir, then `lua tests/_test_broadcast_tag.lua`.

local BroadcastTag = dofile("bookshelf_broadcast_tag.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, e, msg)
    if a ~= e then error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2) end
end

local function fakeUIManager()
    local um = { seen = {} }
    function um:broadcastEvent(event) self.seen[#self.seen + 1] = event; return "orig" end
    return um
end

test("table events are tagged and forwarded", function()
    local um = fakeUIManager(); BroadcastTag.install(um)
    local ev = { handler = "onFoo" }
    eq(um:broadcastEvent(ev), "orig")
    eq(ev._bookshelf_from_broadcast, true)
    eq(um.seen[1], ev)
end)

test("string events (autodim's broadcastEvent(\"UpdateFooter\")) do not crash", function()
    local um = fakeUIManager(); BroadcastTag.install(um)
    eq(um:broadcastEvent("UpdateFooter"), "orig")
    eq(um.seen[1], "UpdateFooter")
end)

test("nil events are forwarded untouched", function()
    local um = fakeUIManager(); BroadcastTag.install(um)
    um:broadcastEvent(nil)
    eq(#um.seen, 0 + (um.seen[1] == nil and 0 or 1))
end)

test("install is idempotent", function()
    local um = fakeUIManager(); BroadcastTag.install(um); BroadcastTag.install(um)
    local ev = {}
    um:broadcastEvent(ev)
    eq(#um.seen, 1)
end)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
