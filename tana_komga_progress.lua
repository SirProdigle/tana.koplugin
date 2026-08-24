-- tana_komga_progress.lua
-- "Continue from server" for manga collections: asks the Komga server where
-- the user last left off in a series (progress accumulated from OTHER
-- devices — e.g. page-streamed reading on the Kindle reports back to Komga)
-- and maps that chapter to the locally downloaded file.
--
-- Everything hangs off the per-series `.maki.lua` marker that Maki's
-- "Download all here" writes: it holds the series' OPDS feed URL (which
-- embeds the Komga series id) and an acquisition-URL → local-filename map
-- (acquisition URLs embed book ids). Server credentials are borrowed from
-- Maki's own settings file, so there is nothing new to configure.
--
-- Soft dependency: collections without a marker (or without a matching
-- Maki server entry) simply don't get the button.

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local ltn12       = require("ltn12")
local mime        = require("mime")
local socket      = require("socket")
local socketutil  = require("socketutil")
local http        = require("socket.http")

local M = {}

local function readMarker(coll_path)
    local ok, marker = pcall(dofile, coll_path .. "/.maki.lua")
    if ok and type(marker) == "table" and marker.feed and marker.catalog then
        return marker
    end
    return nil
end

function M.hasMarker(coll_path)
    if not coll_path then return false end
    return lfs.attributes(coll_path .. "/.maki.lua", "mode") == "file"
end

-- Find the Maki server entry whose URL matches the marker's catalog, for
-- its username/password.
local function findCredentials(catalog_url)
    local LuaSettings = require("luasettings")
    local path = DataStorage:getDataDir() .. "/settings/maki.lua"
    local ok, cfg = pcall(function() return LuaSettings:open(path) end)
    if not ok or not cfg then return nil end
    local servers = cfg:readSetting("servers")
    if type(servers) ~= "table" then return nil end
    for _, srv in ipairs(servers) do
        if srv.url == catalog_url
           or (srv.url and catalog_url and srv.url:match("^https?://[^/]+")
               == catalog_url:match("^https?://[^/]+")) then
            return srv.username, srv.password
        end
    end
    return nil
end

local function fetchJSON(url, username, password)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local request = {
        url     = url,
        method  = "GET",
        headers = {
            ["Accept"] = "application/json",
        },
        sink    = ltn12.sink.table(sink),
    }
    if username then
        request.headers["Authorization"] =
            "Basic " .. mime.b64(username .. ":" .. (password or ""))
    end
    local code = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.warn("tana_komga_progress: HTTP", code, "for", url)
        return nil
    end
    local body = table.concat(sink)
    local ok, parsed
    local ok_rj, rapidjson = pcall(require, "rapidjson")
    if ok_rj then
        ok, parsed = pcall(rapidjson.decode, body)
    else
        local ok_j, json = pcall(require, "json")
        if not ok_j then return nil end
        ok, parsed = pcall(json.decode, body)
    end
    if not ok then return nil end
    return parsed
end

-- Query the server for the series' continue point.
-- Returns nil+reason, or a table:
--   { number, name, book_id, page, in_progress (bool) }
local function findContinuePoint(marker, username, password)
    local base = marker.catalog:match("^(https?://[^/]+)")
    local series_id = marker.feed:match("/series/([^/?#]+)")
    if not base or not series_id then return nil, "no series id in marker" end
    local url = string.format(
        "%s/api/v1/series/%s/books?size=1000&sort=metadata.numberSort,asc",
        base, series_id)
    local data = fetchJSON(url, username, password)
    if not data or type(data.content) ~= "table" then
        return nil, "server unreachable"
    end
    local last_completed_idx, in_progress
    for i, book in ipairs(data.content) do
        local rp = book.readProgress
        if type(rp) == "table" then
            if rp.completed then
                last_completed_idx = i
            elseif not in_progress then
                in_progress = { idx = i, page = rp.page }
            end
        end
    end
    local function shape(book, page, started)
        return {
            number      = (book.metadata and book.metadata.number) or book.number,
            name        = book.name,
            book_id     = book.id,
            page        = page,
            in_progress = started,
        }
    end
    if in_progress then
        return shape(data.content[in_progress.idx], in_progress.page, true)
    end
    if last_completed_idx then
        local nxt = data.content[last_completed_idx + 1]
        if nxt then return shape(nxt, nil, false) end
        return nil, "series finished"
    end
    return nil, "no server progress"
end

-- "Chapter %04d[.frac].cbz" — the normalised naming Maki's downloader uses.
local function chapterFileName(number)
    local num = tonumber(number)
    if not num then return nil end
    local int = math.floor(num)
    local frac = num - int
    if frac > 0 then
        return string.format("Chapter %04d.%g.cbz", int, frac * 10)
    end
    return string.format("Chapter %04d.cbz", int)
end

-- Numerically sorted list of chapters present on disk.
local function listLocalChapters(coll_path)
    local out = {}
    local ok, iter, dir_obj = pcall(lfs.dir, coll_path)
    if not ok then return out end
    for f in iter, dir_obj do
        local num = f:match("^[Cc]hapter%s+(%d+%.?%d*)%.cbz$")
        if num then
            out[#out + 1] = { num = tonumber(num), fp = coll_path .. "/" .. f }
        end
    end
    table.sort(out, function(a, b) return a.num < b.num end)
    return out
end

-- Map a Komga book id to the locally downloaded file via the marker's
-- fetched map (acquisition URLs embed "/books/<id>/"). Fall back to the
-- normalised "Chapter %04d" name scheme.
local function localFileFor(marker, coll_path, target)
    if type(marker.fetched) == "table" then
        for url, rec in pairs(marker.fetched) do
            if url:find("/books/" .. target.book_id .. "/", 1, true)
               and type(rec) == "table" and rec.file then
                local fp = coll_path .. "/" .. rec.file
                if lfs.attributes(fp, "mode") == "file" then return fp end
            end
        end
    end
    local num = tonumber(target.number)
    if num then
        local int = math.floor(num)
        local frac = num - int
        local name = frac > 0
            and string.format("Chapter %04d.%g.cbz", int, frac * 10)
            or  string.format("Chapter %04d.cbz", int)
        local fp = coll_path .. "/" .. name
        if lfs.attributes(fp, "mode") == "file" then return fp end
    end
    return nil
end

-- Fetch a single book straight from Komga's REST download endpoint into
-- the collection folder (part-file + rename). Returns the local path or
-- nil. Maki's background sync later adopts the file into its ledger (the
-- planner sees it on disk under the name it would have chosen itself).
local function downloadBook(marker, coll_path, target, username, password)
    local base = marker.catalog:match("^(https?://[^/]+)")
    local fname = chapterFileName(target.number)
    if not base or not fname then return nil end
    local dest = coll_path .. "/" .. fname
    local part = dest .. ".part"
    local f = io.open(part, "wb")
    if not f then return nil end
    socketutil:set_timeout(15, 180)
    local request = {
        url     = string.format("%s/api/v1/books/%s/file", base, target.book_id),
        method  = "GET",
        headers = {},
        sink    = ltn12.sink.file(f),  -- closes f when the request ends
    }
    if username then
        request.headers["Authorization"] =
            "Basic " .. mime.b64(username .. ":" .. (password or ""))
    end
    local code = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if code ~= 200 then
        pcall(os.remove, part)
        logger.warn("tana_komga_progress: download HTTP", code, "for book", target.book_id)
        return nil
    end
    local ok = os.rename(part, dest)
    if not ok then pcall(os.remove, part); return nil end
    return dest
end

-- Seed the reader's starting page for a not-yet-opened file so a
-- mid-chapter server position is honoured. Never touches an existing
-- sidecar (local progress wins).
local function seedPage(fp, page)
    if not page or page <= 1 then return end
    if DocSettings:hasSidecarFile(fp) then return end
    local ok = pcall(function()
        local ds = DocSettings:open(fp)
        ds:saveSetting("last_page", page)
        ds:flush()
    end)
    if not ok then logger.warn("tana_komga_progress: could not seed page for", fp) end
end

-- The action behind the sheet button. Shows its own progress/info UI and
-- calls on_open(fp) when a local chapter file is resolved.
function M.continueFromServer(coll_path, on_open)
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager   = require("ui/uimanager")
    local Trapper     = require("ui/trapper")
    local _           = require("gettext")
    local T           = require("ffi/util").template

    Trapper:wrap(function()
        Trapper:info(_("Checking reading progress on the server…"))
        local marker = readMarker(coll_path)
        if not marker then
            Trapper:reset()
            UIManager:show(InfoMessage:new{ text = _("No Maki marker for this series.") })
            return
        end
        local username, password = findCredentials(marker.catalog)
        local target, why = findContinuePoint(marker, username, password)
        Trapper:reset()
        if not target then
            local msgs = {
                ["no server progress"] = _("The server has no reading progress for this series."),
                ["series finished"]    = _("Every chapter of this series is already marked read on the server."),
                ["server unreachable"] = _("Could not reach the server (is Wi-Fi on?)."),
            }
            UIManager:show(InfoMessage:new{ text = msgs[why] or _("No continue point found.") })
            return
        end
        local fp = localFileFor(marker, coll_path, target)
        if not fp then
            -- Not downloaded: fetch it right now, no questions asked.
            Trapper:info(T(_("Downloading chapter %1…"), target.number or "?"))
            fp = downloadBook(marker, coll_path, target, username, password)
            Trapper:reset()
        end
        if fp then
            if target.in_progress then seedPage(fp, target.page) end
            if on_open then on_open(fp) end
            return
        end
        -- Download failed: offer the nearest chapters that ARE on disk.
        local ButtonDialog = require("ui/widget/buttondialog")
        local tgt = tonumber(target.number)
        local below, above
        for _, c in ipairs(listLocalChapters(coll_path)) do
            if tgt and c.num < tgt then below = c end
            if tgt and c.num > tgt and not above then above = c end
        end
        if not (below or above) then
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to download chapter %1, and no other chapters are on the device."),
                         target.number or "?"),
            })
            return
        end
        local dialog
        local function pick(c)
            return function()
                UIManager:close(dialog)
                if on_open then on_open(c.fp) end
            end
        end
        local rows = {}
        if above then
            rows[#rows + 1] = { { text = T(_("Read chapter %1"), string.format("%g", above.num)),
                                  callback = pick(above) } }
        end
        if below then
            rows[#rows + 1] = { { text = T(_("Read chapter %1"), string.format("%g", below.num)),
                                  callback = pick(below) } }
        end
        rows[#rows + 1] = { { text = _("Close"),
                              callback = function() UIManager:close(dialog) end } }
        dialog = ButtonDialog:new{
            title       = T(_("Failed to download chapter %1"), target.number or "?"),
            title_align = "center",
            buttons     = rows,
        }
        UIManager:show(dialog)
    end)
end

-- Label used by the sheet; kept short — the fetch happens on tap, so the
-- label can't know the chapter number yet.
function M.buttonLabel()
    local _ = require("gettext")
    return _("Continue from server")
end

-- Internals shared with tana_komga_push (the write direction).
M._readMarker      = readMarker
M._findCredentials = findCredentials
M._fetchJSON       = fetchJSON

return M
