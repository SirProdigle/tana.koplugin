-- tana_booksync.lua
-- Client for the booksync server (kosync-compatible + extras) that carries
-- regular-book reading positions between devices and mirrors them to
-- Hardcover — the books analogue of tana_komga_progress/push for manga.
--
-- The actual position sync is done by KOReader's stock "Progress sync"
-- (kosync) plugin; this module only talks to the server's EXTRA endpoints
-- for tana's UI:
--   GET    /status                    — every synced book + Hardcover state
--   DELETE /syncs/progress/<digest>   — forget a book and unwind whatever
--                                       booksync created on Hardcover
--
-- Credentials/server are read from the kosync plugin's own settings file,
-- so there is nothing extra to configure: log in to Progress sync once and
-- tana follows.

local DataStorage = require("datastorage")
local logger      = require("logger")
local ltn12       = require("ltn12")
local socket      = require("socket")
local socketutil  = require("socketutil")
local http        = require("socket.http")

local M = {}

-- kosync plugin settings ({settings = {custom_server, username, userkey}}).
local function conf()
    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok then return nil end
    local ok2, s = pcall(function()
        return LuaSettings:open(DataStorage:getSettingsDir() .. "/kosync.lua")
    end)
    if not ok2 or not s then return nil end
    local cfg = s:readSetting("settings")
    if type(cfg) ~= "table" or not cfg.custom_server
        or not cfg.username or not cfg.userkey then
        return nil
    end
    return {
        base     = cfg.custom_server:gsub("/+$", ""),
        username = cfg.username,
        userkey  = cfg.userkey,
    }
end

function M.available()
    return conf() ~= nil
end

local function request(method, path, quick)
    local c = conf()
    if not c then return nil end
    local sink = {}
    socketutil:set_timeout(quick and 3 or 10, quick and 6 or 30)
    local code = socket.skip(1, http.request{
        url     = c.base .. path,
        method  = method,
        headers = {
            ["Accept"]      = "application/json",
            ["x-auth-user"] = c.username,
            ["x-auth-key"]  = c.userkey,
        },
        sink    = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.warn("tana_booksync: HTTP", code, "for", method, path)
        return nil
    end
    local body = table.concat(sink)
    local ok_rj, rapidjson = pcall(require, "rapidjson")
    local ok, parsed
    if ok_rj then
        ok, parsed = pcall(rapidjson.decode, body)
    else
        local ok_j, json = pcall(require, "json")
        if not ok_j then return nil end
        ok, parsed = pcall(json.decode, body)
    end
    -- KOReader's decoders map JSON null to truthy userdata — only trust
    -- tables (see tana_komga_push's boot-crash postmortem).
    if not ok or type(parsed) ~= "table" then return nil end
    return parsed
end

-- All synced books: array of { document, filename, title, authors,
-- percentage, device, timestamp, hardcover = {matched_title, status_id,
-- pushed_pct, pages, error} | nil }. nil when offline/unconfigured.
function M.getStatus(quick)
    local data = request("GET", "/status", quick)
    if type(data) ~= "table" or type(data.books) ~= "table" then return nil end
    return data.books
end

-- Forget a book server-side (also unwinds its Hardcover entry).
function M.clearDocument(digest)
    if not digest then return false end
    return request("DELETE", "/syncs/progress/" .. digest) ~= nil
end

-- The kosync document id for a local file: the partial-md5 checksum the
-- reader stashes in the sidecar on first open. nil for never-opened books
-- (nothing to clear in that case anyway).
function M.digestFor(filepath)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not filepath then return nil end
    if not DocSettings:hasSidecarFile(filepath) then return nil end
    local digest
    pcall(function()
        digest = DocSettings:open(filepath):readSetting("partial_md5_checksum")
    end)
    return digest
end

-- Human label for a Hardcover state row ("Reading · p204/476" / "Read").
function M.hardcoverLabel(hc)
    if type(hc) ~= "table" then return nil end
    if hc.error then return "HC: " .. tostring(hc.error) end
    if not hc.matched_title then return nil end
    local status = hc.status_id == 3 and "Read"
        or hc.status_id == 2 and "Reading" or "?"
    return string.format("HC: %s (%s)", hc.matched_title, status)
end

return M
