-- book_repository.lua
-- Unified Book record source over KOReader's ReadHistory, ReadCollection,
-- BookInfoManager, DocSettings, and (optionally) statistics.koplugin.
--
-- Design contract: this module produces Book records only — no widget code,
-- no UI imports. All external KOReader modules are reached through getter
-- functions so that pure-Lua tests can stub them via package.loaded before
-- require() is called.

local Repo = {}

-- ─── Lazy module accessors ───────────────────────────────────────────────────
-- Never require() at module top-level; tests stub via package.loaded.

local function getReadHistory()  return require("readhistory") end
local function getCollections()  return require("readcollection") end
local function getBookInfoMgr()  return require("bookinfomanager") end
local function getDocSettings()  return require("docsettings") end

-- ─── buildBook ────────────────────────────────────────────────────────────────
-- Constructs a Book record for a given filepath.
-- Fields follow spec §5.1. Metadata from BookInfoManager; position from
-- DocSettings. Enrichment (stats) is a separate step (see enrichStats).
--
-- Series number strategy: BookInfoManager may return both info.series
-- (formatted as "<name> #<n>") and info.series_index (bare number). We prefer
-- series_index when present to avoid fragile string parsing; fall back to
-- parsing the formatted series string for compatibility with older caches.

function Repo.buildBook(filepath)
    if not filepath then return nil end
    local bim  = getBookInfoMgr()
    local info = bim:getBookInfo(filepath, true) or {}
    local ds   = getDocSettings():open(filepath)

    -- Parse series info.
    -- KOReader's BookInfoManager returns info.series as "<name> #<n>" and
    -- info.series_index as the bare number when the cache is populated.
    -- We use series_index when available; otherwise parse the formatted string.
    local series_name, series_num
    if info.series then
        series_name = info.series:gsub(" #%d+$", "")
        series_num  = info.series:match(" #(%d+)$")
    end
    if info.series_index then
        -- Prefer the discrete numeric index over the parsed string.
        series_num = tostring(info.series_index)
    end

    local book = {
        filepath    = filepath,
        filename    = (filepath:match("([^/]+)$") or filepath):gsub("%.[^.]+$", ""),
        format      = (filepath:match("%.([^.]+)$") or ""):upper(),
        title       = info.title,
        -- authors field in BookInfoManager is a comma-separated string.
        author      = info.authors and info.authors:match("^([^,]+)") or nil,
        authors     = info.authors and { info.authors:match("^([^,]+)") } or nil,
        series      = info.series,
        series_name = series_name,
        series_num  = series_num,
        cover_bb    = info.cover_bb,
        has_cover   = info.has_cover and not info.ignore_cover,
        lang        = info.language,
        page_num    = ds:readSetting("last_page"),
        page_count  = info.pages,
        book_pct    = ds:readSetting("percent_finished"),
        last_xp     = ds:readSetting("last_xpointer"),
    }
    return book
end

-- ─── getCurrent ──────────────────────────────────────────────────────────────
-- Returns the Book record for the last opened file, or nil if none.

function Repo.getCurrent()
    local lastfile = G_reader_settings:readSetting("lastfile")
    if not lastfile then return nil end
    return Repo.buildBook(lastfile)
end

-- ─── getRecent ───────────────────────────────────────────────────────────────
-- Returns up to `limit` Book records from ReadHistory.hist, in order
-- (ReadHistory keeps hist sorted newest-first already).

function Repo.getRecent(limit)
    local rh  = getReadHistory()
    local out = {}
    for i = 1, math.min(limit or 8, #rh.hist) do
        local entry = rh.hist[i]
        local book  = Repo.buildBook(entry.file)
        if book then
            book.last_read_time = entry.time
            out[#out + 1] = book
        end
    end
    return out
end

-- ─── getLatest ───────────────────────────────────────────────────────────────
-- Returns up to `limit` Book records, sorted newest-by-mtime first, from a
-- recursive filesystem walk rooted at G_reader_settings `home_dir`.
-- Walk depth is capped by `bookshelf_latest_walk_depth` setting (default 3).
-- Results are NOT memoised here — caching is a BookshelfWidget-level concern.

-- Supported e-book extensions for the filesystem walk.
local SUPPORTED_EXT = {
    epub=true, pdf=true, mobi=true, azw3=true, fb2=true,
    cbz=true, cbr=true, txt=true, md=true, html=true, htm=true, djvu=true,
}

local function walkBooks(root, depth, out, current_depth)
    current_depth = current_depth or 0
    if current_depth > depth then return end
    local lfs = require("lfs")
    if not lfs.dir then return end
    for entry in lfs.dir(root) do
        if entry ~= "." and entry ~= ".." then
            local fp   = root .. "/" .. entry
            local mode = lfs.attributes(fp, "mode")
            if mode == "directory" then
                walkBooks(fp, depth, out, current_depth + 1)
            elseif mode == "file" then
                local ext = entry:match("%.([^.]+)$")
                if ext and SUPPORTED_EXT[ext:lower()] then
                    out[#out + 1] = { fp = fp, mtime = lfs.attributes(fp, "modification") or 0 }
                end
            end
        end
    end
end

function Repo.getLatest(limit)
    local home       = G_reader_settings:readSetting("home_dir") or "/"
    local depth      = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local candidates = {}
    walkBooks(home, depth, candidates)
    table.sort(candidates, function(a, b) return a.mtime > b.mtime end)
    local out = {}
    for i = 1, math.min(limit or 8, #candidates) do
        local book = Repo.buildBook(candidates[i].fp)
        if book then
            book.added_time = candidates[i].mtime
            out[#out + 1] = book
        end
    end
    return out
end

-- ─── getFavorites ────────────────────────────────────────────────────────────
-- Returns up to `limit` Book records from ReadCollection favorites collection,
-- sorted by access time descending (most recently accessed first).

function Repo.getFavorites(limit)
    local rc    = getCollections()
    local items = {}
    for _file, item in pairs(rc.coll and rc.coll.favorites or {}) do
        items[#items + 1] = item
    end
    table.sort(items, function(a, b)
        return (a.attr and a.attr.access or 0) > (b.attr and b.attr.access or 0)
    end)
    local out = {}
    for i = 1, math.min(limit or 8, #items) do
        local book = Repo.buildBook(items[i].file)
        if book then
            book.in_favorites = true
            out[#out + 1] = book
        end
    end
    return out
end

-- ─── getSeriesGroups ─────────────────────────────────────────────────────────
-- Returns up to `limit` series groups derived from ReadHistory.
-- Each group is { series_name, books, latest } where books are sorted by
-- series_num ascending. Groups are sorted by most recent activity descending.
-- Books without a series_name are excluded.

function Repo.getSeriesGroups(limit)
    local rh     = getReadHistory()
    local groups = {}  -- keyed by series_name
    local order  = {}  -- preserves insertion order for deterministic sorting
    for _, entry in ipairs(rh.hist) do
        local book = Repo.buildBook(entry.file)
        if book and book.series_name then
            local key = book.series_name
            if not groups[key] then
                groups[key] = { series_name = key, books = {}, latest = 0 }
                order[#order + 1] = key
            end
            groups[key].books[#groups[key].books + 1] = book
            if entry.time > groups[key].latest then
                groups[key].latest = entry.time
            end
        end
    end
    -- Flatten to list and sort by most recent activity.
    local list = {}
    for _, k in ipairs(order) do list[#list + 1] = groups[k] end
    table.sort(list, function(a, b) return a.latest > b.latest end)
    -- Within each group, sort books by series_num ascending.
    for _, g in ipairs(list) do
        table.sort(g.books, function(a, b)
            return (tonumber(a.series_num) or 0) < (tonumber(b.series_num) or 0)
        end)
    end
    local out = {}
    for i = 1, math.min(limit or 4, #list) do out[i] = list[i] end
    return out
end

return Repo
