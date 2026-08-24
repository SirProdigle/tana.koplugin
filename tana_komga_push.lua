-- tana_komga_push.lua
-- Push reading progress BACK to Komga for manga read from downloaded files,
-- giving the Boox parity with Kindle page-streaming (which reports progress
-- as a side effect). Komga's read state then feeds the existing
-- Komga → Suwayomi → AniList bridge when a chapter completes.
--
-- Fully offline-tolerant: every page turn updates a persistent queue
-- (settings/tana_komga_push.lua). Pushing happens opportunistically — a
-- debounced background flush while reading, on document close, and when
-- the network comes back (even a week later, the queue is still there).
-- Entries leave the queue only after the server accepts them.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local ltn12       = require("ltn12")
local mime        = require("mime")
local socket      = require("socket")
local socketutil  = require("socketutil")
local http        = require("socket.http")

local M = {}

-- Komga returns JSON null for readProgress/metadata/media on books the
-- server has no data for; KOReader's JSON decoder maps null to a TRUTHY
-- userdata sentinel, so `x and x.field` still indexes it and crashes the
-- whole app (this took down every boot on 2026-08-24 once a never-read
-- chapter entered a queued series). Route every nested access through tbl().
local function tbl(x)
    return type(x) == "table" and x or nil
end

local state           -- lazy LuaSettings
local dirty = false
local flush_scheduled = false

local function settings()
    if not state then
        state = LuaSettings:open(DataStorage:getDataDir() .. "/settings/tana_komga_push.lua")
    end
    return state
end

-- A file is trackable when its folder carries a Maki marker.
function M.trackable(fp)
    if not fp then return nil end
    local dir = fp:match("^(.*)/[^/]+$")
    if dir and lfs.attributes(dir .. "/.maki.lua", "mode") == "file" then
        return dir
    end
    return nil
end

-- Record the current page. Cheap: updates the in-memory settings table;
-- hits disk every 5th page and on completion (persist() covers the rest).
function M.notePage(fp, coll_path, page, pages)
    if not fp or type(page) ~= "number" then return end
    local s = settings()
    local q = s:readSetting("queue") or {}
    local e = q[fp] or {}
    e.coll_path = coll_path
    e.file      = fp:match("([^/]+)$")
    e.page      = page
    e.pages     = pages
    e.completed = (pages and page >= pages) or nil
    e.updated   = os.time()
    q[fp] = e
    s:saveSetting("queue", q)
    dirty = true
    if e.completed or page % 5 == 0 then M.persist() end
end

function M.persist()
    if dirty and state then state:flush(); dirty = false end
end

local function isOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok then return true end
    return NetworkMgr:isConnected()
end

local function patchProgress(base, book_id, page, completed, username, password)
    local body = string.format('{"page":%d,"completed":%s}',
                               page, completed and "true" or "false")
    socketutil:set_timeout(10, 30)
    local headers = {
        ["Content-Type"]   = "application/json",
        ["Content-Length"] = tostring(#body),
    }
    if username then
        headers["Authorization"] = "Basic " .. mime.b64(username .. ":" .. (password or ""))
    end
    local code = socket.skip(1, http.request{
        url     = string.format("%s/api/v1/books/%s/read-progress", base, book_id),
        method  = "PATCH",
        headers = headers,
        source  = ltn12.source.string(body),
    })
    socketutil:reset_timeout()
    return code == 204 or code == 200
end

-- Book id from the marker's fetched map (by local filename), falling back
-- to a series-books lookup matched on chapter number (covers chapters that
-- arrived outside Maki, e.g. tana's own auto-download).
local function resolveBookId(Progress, marker, entry, username, password)
    if type(marker.fetched) == "table" then
        for url, rec in pairs(marker.fetched) do
            if type(rec) == "table" and rec.file == entry.file then
                local id = url:match("/books/([^/]+)/")
                if id then return id end
            end
        end
    end
    local num = tonumber(entry.file and entry.file:match("[Cc]hapter%s+(%d+%.?%d*)"))
    local base = marker.catalog and marker.catalog:match("^(https?://[^/]+)")
    local series_id = marker.feed and marker.feed:match("/series/([^/?#]+)")
    if not (num and base and series_id and Progress._fetchJSON) then return nil end
    local data = Progress._fetchJSON(string.format(
        "%s/api/v1/series/%s/books?size=1000", base, series_id), username, password)
    if not data or type(data.content) ~= "table" then return nil end
    for _, book in ipairs(data.content) do
        local meta = tbl(book.metadata)
        local bn = tonumber((meta and meta.number) or book.number)
        if bn == num then return book.id end
    end
    return nil
end

-- Pure decision core: given this series' queued entries and the server's
-- book states, decide what to push, what to silently drop, and whether to
-- reset the series first.
--
-- Semantics ("furthest ahead wins, deliberate re-read resets"):
--   * A push must advance the series position: a higher chapter than the
--     server's furthest, or the same chapter at a higher page /
--     newly-completed. Anything behind is dropped — reopening an old
--     chapter never regresses the server.
--   * Exception: when the series is essentially finished on the server
--     (every chapter completed or within 2 pages of the end — network
--     hiccup tolerance) and the user opens the FIRST chapter, that is a
--     deliberate re-read: reset the series' server progress and push from
--     scratch.
--
-- entries: { {num, page, completed}, ... } (any order)
-- books:   { {num, pagesCount, page, completed}, ... } ascending by num;
--          page/completed nil when the server has no progress for it.
-- returns  { reset = bool, pushes = {entry...}, drops = {entry...} }
function M.planPush(entries, books)
    local plan = { reset = false, pushes = {}, drops = {} }
    if #books == 0 then
        for _, e in ipairs(entries) do plan.pushes[#plan.pushes + 1] = e end
        return plan
    end
    local furthest
    local almost_done = true
    for _, b in ipairs(books) do
        local read_pages = b.completed and (b.pagesCount or b.page or 0) or (b.page or 0)
        if b.completed or read_pages > 0 then
            if not furthest or b.num > furthest.num then
                furthest = { num = b.num, page = read_pages, completed = b.completed }
            end
        end
        if not (b.completed or (b.pagesCount and read_pages >= b.pagesCount - 2)) then
            almost_done = false
        end
    end
    local first_num = books[1].num
    local sorted = {}
    for _, e in ipairs(entries) do sorted[#sorted + 1] = e end
    table.sort(sorted, function(a, b) return a.num < b.num end)
    for _, e in ipairs(sorted) do
        local push
        if almost_done and e.num == first_num and not plan.reset then
            plan.reset = true
            furthest = nil
            push = true
        elseif not furthest then
            push = true
        elseif e.num > furthest.num then
            push = true
        elseif e.num == furthest.num
           and ((e.completed and not furthest.completed)
                or (e.page or 0) > (furthest.page or 0)) then
            push = true
        end
        if push then
            plan.pushes[#plan.pushes + 1] = e
            furthest = { num = e.num, page = e.page, completed = e.completed }
        else
            plan.drops[#plan.drops + 1] = e
        end
    end
    return plan
end

-- Push everything queued. Entries leave the queue when the server accepts
-- them OR when the planner drops them as behind; failures stay queued.
function M.flush()
    flush_scheduled = false
    if not isOnline() then return end
    local s = settings()
    local q = s:readSetting("queue") or {}
    if next(q) == nil then return end
    local Progress = require("tana_komga_progress")
    local changed = false

    -- Group queue entries by collection.
    local by_coll = {}
    for fp, e in pairs(q) do
        by_coll[e.coll_path] = by_coll[e.coll_path] or {}
        table.insert(by_coll[e.coll_path], { fp = fp, e = e })
    end

    for coll_path, items in pairs(by_coll) do
        local marker = Progress._readMarker and Progress._readMarker(coll_path)
        if not marker then
            -- Collection gone: drop its orphans.
            for _, it in ipairs(items) do q[it.fp] = nil; changed = true end
        else
            local username, password = Progress._findCredentials(marker.catalog)
            local base = marker.catalog:match("^(https?://[^/]+)")
            local series_id = marker.feed and marker.feed:match("/series/([^/?#]+)")
            local data = (base and series_id) and Progress._fetchJSON(string.format(
                "%s/api/v1/series/%s/books?size=1000&sort=metadata.numberSort,asc",
                base, series_id), username, password) or nil
            if data and type(data.content) == "table" then
                local books, id_by_num = {}, {}
                for _, book in ipairs(data.content) do
                    local meta = tbl(book.metadata)
                    local num = tonumber((meta and meta.number) or book.number)
                    if num then
                        local rp    = tbl(book.readProgress)
                        local media = tbl(book.media)
                        books[#books + 1] = {
                            num       = num,
                            pagesCount = media and media.pagesCount or nil,
                            page      = rp and rp.page or nil,
                            completed = rp and rp.completed or nil,
                        }
                        id_by_num[num] = book.id
                    end
                end
                local entries, fp_by_num = {}, {}
                for _, it in ipairs(items) do
                    local num = tonumber(it.e.file and it.e.file:match("[Cc]hapter%s+(%d+%.?%d*)"))
                    if num and id_by_num[num] then
                        entries[#entries + 1] = { num = num, page = it.e.page,
                                                  completed = it.e.completed }
                        fp_by_num[num] = it.fp
                    else
                        -- Number unparseable / unknown on server: drop.
                        q[it.fp] = nil; changed = true
                    end
                end
                local plan = M.planPush(entries, books)
                local ok_to_push = true
                if plan.reset then
                    -- Deliberate re-read: wipe the series' server progress.
                    socketutil:set_timeout(10, 30)
                    local headers = {}
                    if username then
                        headers["Authorization"] = "Basic "
                            .. mime.b64(username .. ":" .. (password or ""))
                    end
                    local code = socket.skip(1, http.request{
                        url     = string.format("%s/api/v1/series/%s/read-progress",
                                                base, series_id),
                        method  = "DELETE",
                        headers = headers,
                    })
                    socketutil:reset_timeout()
                    ok_to_push = (code == 204 or code == 200)
                    if ok_to_push then
                        logger.info("tana_komga_push: series re-read — reset", series_id)
                    end
                end
                if ok_to_push then
                    for _, e in ipairs(plan.drops) do
                        q[fp_by_num[e.num]] = nil; changed = true
                    end
                    for _, e in ipairs(plan.pushes) do
                        if patchProgress(base, id_by_num[e.num], e.page, e.completed,
                                         username, password) then
                            q[fp_by_num[e.num]] = nil; changed = true
                        else
                            logger.warn("tana_komga_push: push failed for chapter", e.num)
                        end
                    end
                end
            end
            -- data fetch failed → leave this series queued for next time
        end
    end
    if changed then
        s:saveSetting("queue", q)
        s:flush()
        dirty = false
    end
end

-- Debounced background flush; default ~30s after reading activity so the
-- network work never lands between page turns.
function M.scheduleFlush(delay)
    if flush_scheduled then return end
    flush_scheduled = true
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok then flush_scheduled = false; return end
    UIManager:scheduleIn(delay or 30, function() M.flush() end)
end

return M
