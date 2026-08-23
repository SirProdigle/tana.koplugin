-- tests/_test_makimarker.lua
-- Pure-Lua tests for makimarker.lua using an in-memory filesystem.
-- Usage: cd maki.koplugin && lua tests/_test_makimarker.lua

package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }

-- Minimal serializer standing in for KOReader's `dump`.
local function dump(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    local out = { "{\n" }
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local ks = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
        out[#out + 1] = indent .. "    " .. ks .. " = " .. dump(v[k], indent .. "    ") .. ",\n"
    end
    out[#out + 1] = indent .. "}"
    return table.concat(out)
end
package.loaded["dump"] = dump

local M = dofile("makimarker.lua")

-- In-memory FS: files[path] = content; dirs[path] = { child names }
local files, dirs
local function deps()
    return {
        readFile = function(path) return files[path] end,
        writeFile = function(path, content) files[path] = content; return true end,
        rename = function(from, to)
            if files[from] == nil then return nil, "no such file" end
            files[to] = files[from]; files[from] = nil; return true
        end,
        listDirs = function(path) return dirs[path] or {} end,
    }
end

local pass, fail = 0, 0
local function test(name, fn)
    files, dirs = {}, {}
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

test("read: returns nil when marker missing", function()
    assert(M.read("/m/S", deps()) == nil)
end)

test("read: parses marker and guarantees fetched table", function()
    files["/m/S/.maki.lua"] = 'return { catalog = "C", feed = "F", title = "S" }'
    local mk = M.read("/m/S", deps())
    assert(mk.catalog == "C" and mk.feed == "F" and mk.title == "S")
    assert(type(mk.fetched) == "table")
end)

test("read: returns nil on unparseable content", function()
    files["/m/S/.maki.lua"] = "return {{{"
    assert(M.read("/m/S", deps()) == nil)
end)

test("write: writes tmp then renames; round-trips", function()
    local d = deps()
    local mk = { catalog = "C", feed = "F", title = "S",
                 fetched = { ["http://x/1"] = { file = "a.cbz", at = 5 } } }
    assert(M.write("/m/S", mk, d) == true)
    assert(files["/m/S/.maki.lua.tmp"] == nil)
    local back = M.read("/m/S", d)
    assert(back.fetched["http://x/1"].file == "a.cbz")
    assert(back.fetched["http://x/1"].at == 5)
end)

test("write: returns false,err when rename fails", function()
    local d = deps()
    d.rename = function() return nil, "EACCES" end
    local ok, err = M.write("/m/S", { catalog = "C", fetched = {} }, d)
    assert(ok == false and err == "EACCES")
end)

test("listFollowed: only dirs with a marker for this catalog, sorted", function()
    dirs["/m"] = { "Zeta", "Alpha", "NoMarker", "Other" }
    files["/m/Zeta/.maki.lua"]  = 'return { catalog = "C", feed = "fz" }'
    files["/m/Alpha/.maki.lua"] = 'return { catalog = "C", feed = "fa" }'
    files["/m/Other/.maki.lua"] = 'return { catalog = "D", feed = "fo" }'
    local list = M.listFollowed("/m", "C", deps())
    assert(#list == 2, "got " .. #list)
    assert(list[1].dir == "/m/Alpha" and list[1].marker.feed == "fa")
    assert(list[2].dir == "/m/Zeta")
end)

test("listFollowed: trailing slash on sync_dir is tolerated", function()
    dirs["/m"] = { "A" }
    files["/m/A/.maki.lua"] = 'return { catalog = "C", feed = "f" }'
    local list = M.listFollowed("/m/", "C", deps())
    assert(#list == 1 and list[1].dir == "/m/A")
end)

test("markFetched: adds entry and reports change; repeat is no change", function()
    local mk = { fetched = {} }
    assert(M.markFetched(mk, "u", "f.cbz", 9) == true)
    assert(mk.fetched.u.file == "f.cbz" and mk.fetched.u.at == 9)
    assert(M.markFetched(mk, "u", "f.cbz", 10) == false)
    assert(mk.fetched.u.at == 9, "existing entry must not be overwritten")
end)

print(string.format("%d/%d tests passed", pass, pass + fail))
if fail > 0 then os.exit(1) end
