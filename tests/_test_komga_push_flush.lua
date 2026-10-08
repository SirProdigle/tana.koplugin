-- tests/_test_komga_push_flush.lua
-- tana_komga_push.flush() end to end against stubs: queued page positions
-- for chapter files with arbitrary names reach the right Komga book.
--
-- Usage: cd into the plugin dir, then `lua tests/_test_komga_push_flush.lua`.

local queue_store = {}
package.loaded["datastorage"] = { getDataDir = function() return "/tmp" end }
package.loaded["luasettings"] = { open = function()
    return {
        readSetting = function(_, k) return queue_store[k] end,
        saveSetting = function(_, k, v) queue_store[k] = v end,
        flush = function() end,
    }
end }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return nil end, dir = function() end }
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end }
package.loaded["ltn12"] = { sink = {}, source = { string = function(s) return s end } }
package.loaded["mime"] = { b64 = function(s) return s end }
package.loaded["socket"] = { skip = function(n, ...) return select(n + 1, ...) end }
package.loaded["socketutil"] = { set_timeout = function() end, reset_timeout = function() end }

local requests = {}
package.loaded["socket.http"] = { request = function(req)
    requests[#requests + 1] = { url = req.url, method = req.method, body = req.source }
    return 1, 204
end }

local SERIES = "https://komga.example/opds/v1.2/series/SBR"
local function book(id, file, num, rp)
    return { id = id, url = "/manga/mangas/Weeb Central (EN)/SBR/" .. file, number = num,
             metadata = { number = tostring(num), numberSort = num },
             media = { pagesCount = 40 }, readProgress = rp }
end
local server_books = {
    book("B9", "Official_# 9.cbz", 9, { page = 40, completed = true }),
    book("B10", "Official_# 10.cbz", 10),
    book("B11", "Official_# 11.cbz", 11),
    book("D5", "Official_Spell 101.5.cbz", 101.5),
}
local marker = {
    catalog = "https://komga.example/opds/v1.2/catalog",
    feed = SERIES,
    fetched = { ["https://komga.example/opds/v1.2/books/B11/file/x"] = { file = "renamed locally.cbz" } },
}
package.loaded["tana_komga_progress"] = {
    _readMarker = function() return marker end,
    _findCredentials = function() return "u", "p" end,
    _fetchJSON = function() return { content = server_books } end,
}

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

local COLL = "/sdcard/Books/_MANGA/SBR"
local function queue(entries)
    local q = {}
    for file, e in pairs(entries) do
        q[COLL .. "/" .. file] = { coll_path = COLL, file = file, page = e[1], pages = 40,
                                   completed = e[2] or nil, updated = 1 }
    end
    queue_store.queue = q
    requests = {}
end

test("'# N' chapter (no 'Chapter' in the name) is pushed to its book", function()
    queue({ ["Official_# 10.cbz"] = { 40, true } })
    Push.flush()
    assert_eq(#requests, 1, "requests")
    assert_eq(requests[1].url, "https://komga.example/api/v1/books/B10/read-progress")
    assert_eq(requests[1].body, '{"page":40,"completed":true}')
    assert_eq(next(queue_store.queue), nil, "queue drained")
end)

test("ledger maps a locally renamed file to its book", function()
    queue({ ["renamed locally.cbz"] = { 12 } })
    Push.flush()
    assert_eq(requests[1] and requests[1].url, "https://komga.example/api/v1/books/B11/read-progress")
end)

test("unknown file is dropped, nothing pushed", function()
    queue({ ["Extras.cbz"] = { 3 } })
    Push.flush()
    assert_eq(#requests, 0, "requests")
    assert_eq(next(queue_store.queue), nil, "dropped")
end)

test("behind the server's furthest chapter: dropped, not pushed", function()
    queue({ ["Official_# 9.cbz"] = { 5 } })
    Push.flush()
    assert_eq(#requests, 0, "requests")
end)

print(string.format("komga push flush: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
