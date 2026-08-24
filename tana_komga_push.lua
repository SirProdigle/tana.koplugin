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
        local bn = tonumber((book.metadata and book.metadata.number) or book.number)
        if bn == num then return book.id end
    end
    return nil
end

-- Push everything queued. Entries are removed only when the server
-- accepted them; failures stay queued for the next opportunity.
function M.flush()
    flush_scheduled = false
    if not isOnline() then return end
    local s = settings()
    local q = s:readSetting("queue") or {}
    if next(q) == nil then return end
    local Progress = require("tana_komga_progress")
    local changed = false
    for fp, e in pairs(q) do
        local pushed = false
        local marker = Progress._readMarker and Progress._readMarker(e.coll_path)
        if marker then
            local username, password = Progress._findCredentials(marker.catalog)
            local base = marker.catalog:match("^(https?://[^/]+)")
            local book_id = resolveBookId(Progress, marker, e, username, password)
            if base and book_id then
                pushed = patchProgress(base, book_id, e.page, e.completed,
                                       username, password)
            end
        else
            pushed = true  -- collection gone: drop the orphan entry
        end
        if pushed then
            q[fp] = nil
            changed = true
        else
            logger.warn("tana_komga_push: push failed for", fp)
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
