-- tana_komga_admin.lua
-- Deliberate, user-driven edits to a series' Komga reading progress, for
-- the long-press menu on a manga card:
--
--   * setProgress(coll, N)  — "I read up to chapter N" (e.g. physically
--     read a volume): every chapter ≤ N becomes completed on the server,
--     every chapter > N loses its progress. Komga's read state then feeds
--     the AniList bridge exactly as if the chapters were read here.
--   * clearProgress(coll)   — wipe the series' server progress AND the
--     device-local traces (push queue, sidecars, history) so "just opened
--     a chapter to look at something" leaves no phantom resume points.
--
-- All server calls reuse the marker + credential plumbing from
-- tana_komga_progress; everything degrades to nil-with-reason so the UI
-- can toast instead of crash.

local logger     = require("logger")
local ltn12      = require("ltn12")
local mime       = require("mime")
local socket     = require("socket")
local socketutil = require("socketutil")
local http       = require("socket.http")

local M = {}

-- Komga JSON nulls decode to truthy userdata — table-guard every nested
-- access (see tana_komga_push).
local function tbl(x)
    return type(x) == "table" and x or nil
end

local function serverFor(coll_path)
    local Progress = require("tana_komga_progress")
    local marker = Progress._readMarker(coll_path)
    if not marker then return nil, "no Maki marker" end
    local base = marker.catalog and marker.catalog:match("^(https?://[^/]+)")
    local series_id = marker.feed and marker.feed:match("/series/([^/?#]+)")
    if not base or not series_id then return nil, "no series id in marker" end
    local username, password = Progress._findCredentials(marker.catalog)
    return {
        base      = base,
        series_id = series_id,
        username  = username,
        password  = password,
        _fetchJSON = Progress._fetchJSON,
    }
end

local function bodyless(srv, method, url)
    socketutil:set_timeout(10, 30)
    local headers = {}
    if srv.username then
        headers["Authorization"] = "Basic "
            .. mime.b64(srv.username .. ":" .. (srv.password or ""))
    end
    local code = socket.skip(1, http.request{
        url = url, method = method, headers = headers,
    })
    socketutil:reset_timeout()
    return code == 204 or code == 200
end

local function patchJSON(srv, url, body)
    socketutil:set_timeout(10, 30)
    local headers = {
        ["Content-Type"]   = "application/json",
        ["Content-Length"] = tostring(#body),
    }
    if srv.username then
        headers["Authorization"] = "Basic "
            .. mime.b64(srv.username .. ":" .. (srv.password or ""))
    end
    local code = socket.skip(1, http.request{
        url = url, method = "PATCH", headers = headers,
        source = ltn12.source.string(body),
    })
    socketutil:reset_timeout()
    return code == 204 or code == 200
end

-- Ascending chapter list with server read-state:
-- { {num, id, completed, page, pagesCount}, ... }. nil, reason on failure.
function M.fetchSeries(coll_path)
    local srv, why = serverFor(coll_path)
    if not srv then return nil, why end
    local data = srv._fetchJSON(string.format(
        "%s/api/v1/series/%s/books?size=1000&sort=metadata.numberSort,asc",
        srv.base, srv.series_id), srv.username, srv.password, 5, 15)
    if not data or type(data.content) ~= "table" then
        return nil, "server unreachable"
    end
    local books = {}
    for _, book in ipairs(data.content) do
        local meta = tbl(book.metadata)
        local num = tonumber((meta and meta.number) or book.number)
        if num then
            local rp    = tbl(book.readProgress)
            local media = tbl(book.media)
            books[#books + 1] = {
                num        = num,
                id         = book.id,
                completed  = rp and rp.completed or false,
                page       = rp and rp.page or nil,
                pagesCount = media and media.pagesCount or nil,
            }
        end
    end
    return books, nil, srv
end

-- Mark chapters ≤ upto_num read, and strip progress from chapters > it.
-- progress_cb(i, total) is called before each server write (for a Trapper
-- line). Returns marked, cleared, failed counts (nil, reason on failure).
function M.setProgress(coll_path, upto_num, progress_cb)
    local books, why, srv = M.fetchSeries(coll_path)
    if not books then return nil, why end
    local todo = {}
    for _, b in ipairs(books) do
        if b.num <= upto_num and not b.completed then
            todo[#todo + 1] = { book = b, action = "read" }
        elseif b.num > upto_num and (b.completed or (b.page or 0) > 0) then
            todo[#todo + 1] = { book = b, action = "unread" }
        end
    end
    local marked, cleared, failed = 0, 0, 0
    for i, t in ipairs(todo) do
        if progress_cb then progress_cb(i, #todo) end
        local url = string.format("%s/api/v1/books/%s/read-progress",
                                  srv.base, t.book.id)
        local ok
        if t.action == "read" then
            ok = patchJSON(srv, url, '{"completed":true}')
            if ok then marked = marked + 1 end
        else
            ok = bodyless(srv, "DELETE", url)
            if ok then cleared = cleared + 1 end
        end
        if not ok then failed = failed + 1 end
    end
    -- Local queue entries would re-advance the server past the number the
    -- user just chose — the deliberate edit wins.
    pcall(function() require("tana_komga_push").purgeCollection(coll_path) end)
    logger.info("tana_komga_admin: set", coll_path, "to ch", upto_num,
                "marked", marked, "cleared", cleared, "failed", failed)
    return { marked = marked, cleared = cleared, failed = failed }
end

-- Wipe the series' progress on the server. Returns true/false, reason.
function M.clearServerProgress(coll_path)
    local srv, why = serverFor(coll_path)
    if not srv then return false, why end
    local ok = bodyless(srv, "DELETE", string.format(
        "%s/api/v1/series/%s/read-progress", srv.base, srv.series_id))
    if not ok then return false, "server unreachable" end
    return true
end

-- Wipe the device-local traces: push queue, chapter sidecars, history
-- entries. Safe offline; returns the number of chapters touched.
function M.clearLocalProgress(coll_path)
    pcall(function() require("tana_komga_push").purgeCollection(coll_path) end)
    local TanaManga = require("tana_manga")
    local ok_ds, DocSettings = pcall(require, "docsettings")
    local ok_rh, ReadHistory = pcall(require, "readhistory")
    local touched = 0
    for _, ch in ipairs(TanaManga.listChaptersSorted(coll_path)) do
        local had = false
        if ok_ds and DocSettings:hasSidecarFile(ch.fp) then
            pcall(function() DocSettings:open(ch.fp):purge() end)
            had = true
        end
        if ok_rh then
            pcall(function() ReadHistory:removeItemByPath(ch.fp) end)
        end
        if had then touched = touched + 1 end
    end
    return touched
end

return M
