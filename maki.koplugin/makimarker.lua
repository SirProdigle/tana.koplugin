-- makimarker.lua
-- Per-series marker file `<series_dir>/.maki.lua`:
--   { catalog = <server.url>, feed = <series feed URL>, title = <string>,
--     fetched = { [acquisition_url] = { file = <string|nil>, at = <os.time()> } } }
-- Pure module: all filesystem access goes through `deps` so it can run in
-- tests and inside a forked child alike. Default deps use io/lfs.

local dump = require("dump")
local logger = require("logger")

local M = {}

M.FILENAME = ".maki.lua"

local function default_deps()
    local lfs = require("libs/libkoreader-lfs")
    return {
        readFile = function(path)
            local f = io.open(path, "r")
            if not f then return nil end
            local s = f:read("*a"); f:close(); return s
        end,
        writeFile = function(path, content)
            local f, err = io.open(path, "w")
            if not f then return nil, err end
            f:write(content); f:close(); return true
        end,
        rename = function(from, to) return os.rename(from, to) end,
        listDirs = function(path)
            local out = {}
            local ok, iter, dir_obj = pcall(lfs.dir, path)
            if not ok then return out end
            for name in iter, dir_obj do
                if name ~= "." and name ~= ".." then
                    local attr = lfs.attributes(path .. "/" .. name)
                    if attr and attr.mode == "directory" then out[#out + 1] = name end
                end
            end
            return out
        end,
    }
end

local function with_deps(deps)
    if deps then return deps end
    M._default = M._default or default_deps()
    return M._default
end

local function strip_slash(p) return (p:gsub("/+$", "")) end

function M.path(dir) return strip_slash(dir) .. "/" .. M.FILENAME end

function M.read(dir, deps)
    deps = with_deps(deps)
    local src = deps.readFile(M.path(dir))
    if not src then return nil end
    local chunk = loadstring and loadstring(src) or load(src)
    if not chunk then
        logger.warn("Maki: unparseable marker in", dir)
        return nil
    end
    local ok, tbl = pcall(chunk)
    if not ok or type(tbl) ~= "table" then
        logger.warn("Maki: unparseable marker in", dir)
        return nil
    end
    if type(tbl.fetched) ~= "table" then tbl.fetched = {} end
    return tbl
end

function M.write(dir, marker, deps)
    deps = with_deps(deps)
    local final = M.path(dir)
    local tmp = final .. ".tmp"
    local ok, err = deps.writeFile(tmp, "return " .. dump(marker) .. "\n")
    if not ok then return false, err end
    local rok, rerr = deps.rename(tmp, final)
    if not rok then return false, rerr end
    return true
end

function M.listFollowed(sync_dir, catalog_url, deps)
    deps = with_deps(deps)
    sync_dir = strip_slash(sync_dir)
    local names = deps.listDirs(sync_dir)
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do
        local dir = sync_dir .. "/" .. name
        local marker = M.read(dir, deps)
        if marker and marker.catalog == catalog_url and marker.feed then
            out[#out + 1] = { dir = dir, marker = marker }
        end
    end
    return out
end

function M.markFetched(marker, url, file, now)
    marker.fetched = marker.fetched or {}
    if marker.fetched[url] then return false end
    marker.fetched[url] = { file = file, at = now }
    return true
end

return M
