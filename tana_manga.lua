-- tana_manga.lua
-- Manga awareness layer for Tana. Adds three concepts on top of Bookshelf's
-- file-flat library model:
--
--   1. A "manga root" is a folder declared by the user (settings key
--      `tana_manga_roots`, default `{ "_MANGA" }`). Roots are paths
--      RESOLVED relative to G_reader_settings.home_dir; absolute paths are
--      honoured as-is. The roots themselves are NOT manga; they're just
--      containers for collections.
--
--   2. A "manga collection" is any directory whose parent is a manga root.
--      Collections render as a single card in the UI (one per series), not
--      as 200+ chapter-file cards.
--
--   3. A "chapter file" is any supported book file whose grandparent is a
--      manga root (i.e. it lives inside a collection). Chapter files get
--      filtered out of Latest / Recent so they don't drown the library.
--
-- Resume info comes from KOReader's ReadHistory (recency) + DocSettings
-- (percent/page). Both already-cached primitives in the Repo module.
--
-- This module deliberately has no UI / widget dependencies — it's a pure
-- data layer so it can be unit-tested without a KOReader runtime.

local logger = require("logger")

local M = {}

-- ─── Settings access ─────────────────────────────────────────────────────

local DEFAULT_MANGA_ROOTS = { "_MANGA" }
local CHAPTER_EXT = {
    cbz = true, cbr = true, cb7 = true, cbt = true,
    -- One-shots are often .pdf or .epub; we still treat them as chapter
    -- files because the collection-folder collapse is what the user wants.
    pdf = true, epub = true,
}

local function getHomeDir()
    if not _G.G_reader_settings then return nil end
    return G_reader_settings:readSetting("home_dir")
end

-- Returns the configured manga roots as a list of ABSOLUTE paths. Settings
-- entries that are relative get resolved under home_dir; absolute entries
-- pass through. Empty / unconfigured returns the empty list.
local function _resolveRoots()
    local raw
    if _G.G_reader_settings then
        raw = G_reader_settings:readSetting("tana_manga_roots")
    end
    if type(raw) ~= "table" or #raw == 0 then raw = DEFAULT_MANGA_ROOTS end
    local home = getHomeDir()
    local out = {}
    for _, entry in ipairs(raw) do
        if type(entry) == "string" and entry ~= "" then
            local abs
            if entry:sub(1, 1) == "/" then
                abs = entry
            elseif home then
                abs = home:gsub("/$", "") .. "/" .. entry
            end
            if abs then
                abs = abs:gsub("/+$", "")
                out[#out + 1] = abs
            end
        end
    end
    return out
end

-- Cached resolved-roots list (rebuilt when settings change). Cheap enough
-- to rebuild on demand but the path-membership checks below run inside the
-- chip-rebuild loop so a per-call rebuild adds up.
local _roots_cache
local _roots_cache_t = 0
local ROOTS_CACHE_TTL = 30

local function _roots()
    local now = os.time()
    if _roots_cache and (now - _roots_cache_t) < ROOTS_CACHE_TTL then
        return _roots_cache
    end
    _roots_cache = _resolveRoots()
    _roots_cache_t = now
    return _roots_cache
end

function M.invalidate()
    _roots_cache = nil
    _roots_cache_t = 0
end

-- ─── Path predicates ─────────────────────────────────────────────────────

local function _stripTrailingSlash(p)
    if not p then return nil end
    return (p:gsub("/+$", ""))
end

local function _parentOf(p)
    p = _stripTrailingSlash(p)
    if not p then return nil end
    local parent = p:match("^(.*)/[^/]+$")
    return parent
end

function M.isMangaRoot(path)
    path = _stripTrailingSlash(path)
    if not path then return false end
    for _, root in ipairs(_roots()) do
        if root == path then return true end
    end
    return false
end

function M.isMangaCollection(path)
    local parent = _parentOf(path)
    return parent and M.isMangaRoot(parent) or false
end

-- A chapter file is a supported file whose IMMEDIATE parent is a manga
-- collection (i.e. its grandparent is a manga root). Files directly inside
-- a manga root (one-shots dropped at the top level) are NOT chapter files —
-- they fall through to the normal book rendering.
function M.isChapterFile(filepath)
    if not filepath then return false end
    local parent = _parentOf(filepath)
    if not parent then return false end
    return M.isMangaCollection(parent)
end

-- For a given path, return the collection path it lives in (or nil). Used
-- to fold chapter recency up to the collection level in getRecent.
function M.collectionFor(filepath)
    if not filepath then return nil end
    local parent = _parentOf(filepath)
    if parent and M.isMangaCollection(parent) then return parent end
    return nil
end

function M.hideChaptersEnabled()
    if not _G.G_reader_settings then return true end
    local v = G_reader_settings:readSetting("tana_hide_chapters")
    if v == nil then return true end
    return v ~= false
end

-- ─── Filesystem helpers ──────────────────────────────────────────────────

local function _safeDir(path)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or not lfs or not lfs.dir then return nil end
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok or type(iter) ~= "function" then return nil end
    return iter, dir_obj, lfs
end

-- Natural sort comparator: splits strings into digit/non-digit chunks and
-- compares numerically where both are digits. Stable, case-insensitive on
-- the non-digit parts.
local function _natKey(s)
    s = (s or ""):lower()
    local parts = {}
    local i = 1
    while i <= #s do
        local c = s:sub(i, i)
        if c:match("%d") then
            local j = i
            while j <= #s and s:sub(j, j):match("%d") do j = j + 1 end
            parts[#parts + 1] = { kind = "n", value = tonumber(s:sub(i, j - 1)) or 0 }
            i = j
        else
            local j = i
            while j <= #s and not s:sub(j, j):match("%d") do j = j + 1 end
            parts[#parts + 1] = { kind = "s", value = s:sub(i, j - 1) }
            i = j
        end
    end
    return parts
end

local function _natLess(a, b)
    local ka, kb = _natKey(a), _natKey(b)
    local n = math.min(#ka, #kb)
    for i = 1, n do
        local pa, pb = ka[i], kb[i]
        if pa.kind == "n" and pb.kind == "n" then
            if pa.value ~= pb.value then return pa.value < pb.value end
        elseif pa.kind == "s" and pb.kind == "s" then
            if pa.value ~= pb.value then return pa.value < pb.value end
        else
            -- Mixed: numbers sort before strings (so "Chapter 1" < "Chapter a").
            return pa.kind == "n"
        end
    end
    return #ka < #kb
end

M._natLess = _natLess  -- exposed for tests

-- ─── Collection / chapter enumeration ────────────────────────────────────

-- listCollections(home_dir) → array of {path, label} shapes for every
-- direct-child directory under any configured manga root. Empty list if
-- no roots are configured or none exist.
function M.listCollections()
    local out = {}
    for _, root in ipairs(_roots()) do
        local iter, dir_obj, lfs = _safeDir(root)
        if iter and lfs then
            for entry in iter, dir_obj do
                if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
                    local fp = root .. "/" .. entry
                    local mode = lfs.attributes(fp, "mode")
                    if mode == "directory" then
                        out[#out + 1] = { path = fp, label = entry }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return _natLess(a.label, b.label) end)
    return out
end

-- Naturally-sorted list of chapter files inside a collection. Returns
-- array of {fp, mtime} matching the walk-cache shape so downstream code
-- doesn't have to special-case it.
function M.listChaptersSorted(coll_path)
    local out = {}
    local iter, dir_obj, lfs = _safeDir(coll_path)
    if not iter then return out end
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
            local fp = coll_path .. "/" .. entry
            local attr = lfs.attributes(fp)
            if type(attr) == "table" and attr.mode == "file" then
                local ext = entry:match("%.([^.]+)$")
                if ext and CHAPTER_EXT[ext:lower()] then
                    out[#out + 1] = {
                        fp = fp,
                        name = entry,
                        mtime = attr.modification or 0,
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b) return _natLess(a.name, b.name) end)
    return out
end

-- For UI: a short "Ch 97" label from a chapter filename. Tries common
-- patterns (Chapter 97, Ch. 97, c097, _097) and falls back to the bare
-- filename without extension.
function M.chapterLabel(filename)
    if not filename then return "" end
    local stem = filename:gsub("%.[^.]+$", "")
    local n = stem:match("[Cc]hapter[%s_%-%.]*0*(%d+)")
           or stem:match("[Cc]h[%.%s_%-]+0*(%d+)")
           or stem:match("[Vv]ol[%s_%-%.]*0*(%d+)")
           or stem:match("c0*(%d+)")
    if n then return "Ch. " .. n end
    return stem
end

-- ─── Resume lookup ───────────────────────────────────────────────────────

-- Returns the most-recently-opened chapter for a collection, or nil if
-- nothing in this collection has ever been opened. Uses ReadHistory which
-- is already loaded by Bookshelf for the Recent chip; no extra disk cost
-- on the steady-state path.
--
-- Shape: { fp = "...", filename = "...", label = "Ch 97", mtime = 1779... }
--
-- The caller is responsible for picking up percent/page via Repo.readProgress.
function M.getResumeRaw(coll_path)
    coll_path = _stripTrailingSlash(coll_path)
    if not coll_path then return nil end
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory or not ReadHistory.hist then return nil end
    local prefix = coll_path .. "/"
    for i = 1, #ReadHistory.hist do
        local entry = ReadHistory.hist[i]
        if not entry.dim and entry.file and entry.file:sub(1, #prefix) == prefix
                and not entry.file:sub(#prefix + 1):find("/") then
            -- Direct child of the collection (filter out nested entries).
            local filename = entry.file:match("([^/]+)$") or entry.file
            return {
                fp       = entry.file,
                filename = filename,
                label    = M.chapterLabel(filename),
                mtime    = entry.time,
            }
        end
    end
    return nil
end

-- Convenience: full resume tuple with percent/page resolved. Returns nil
-- if no history; resume.pct / resume.page / resume.total are nil if the
-- DocSettings sidecar is missing/unreadable but the file IS in history.
function M.getResume(coll_path, readProgress)
    local raw = M.getResumeRaw(coll_path)
    if not raw then return nil end
    if readProgress then
        local pct = readProgress(raw.fp)
        raw.pct = pct
    end
    -- Page/total: best-effort via DocSettings direct read so callers that
    -- only pass readProgress (which doesn't expose last_page) still get a
    -- useful label. pcall guards a missing/corrupt sidecar.
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings then
        local ok_ds, ds = pcall(function() return DocSettings:open(raw.fp) end)
        if ok_ds and ds then
            local ok_p, page = pcall(ds.readSetting, ds, "last_page")
            if ok_p then raw.page = tonumber(page) end
            local ok_t, pages = pcall(ds.readSetting, ds, "doc_pages")
            if ok_t then raw.total = tonumber(pages) end
        end
    end
    return raw
end

-- ─── Collection card shape (for the Manga chip) ──────────────────────────

-- Build a card-ready shape for a collection. The chapter file used as the
-- visual cover is the FIRST chapter by natural sort (matches what the
-- Komga OPDS catalog renders, and works whether or not the user has read
-- anything in the series yet).
--
-- `repo_buildBookMeta` is injected so this module stays test-friendly —
-- callers (the repository) pass `Repo.buildBookMeta`.
function M.buildCollectionShape(coll_path, label, repo_buildBookMeta)
    local chapters = M.listChaptersSorted(coll_path)
    local first = chapters[1]
    local cover_book
    if first and repo_buildBookMeta then
        cover_book = repo_buildBookMeta(first.fp)
    end
    return {
        kind          = "manga",
        path          = coll_path,
        label         = label or (coll_path:match("([^/]+)$") or coll_path),
        chapter_count = #chapters,
        first_fp      = first and first.fp,
        -- SeriesStack-compatible shape so the existing widget renders it.
        series_name   = label or (coll_path:match("([^/]+)$") or coll_path),
        books         = cover_book and { cover_book } or {},
        count_override = #chapters,
    }
end

-- ─── Diagnostics ─────────────────────────────────────────────────────────

function M.debugDump()
    local roots = _roots()
    logger.info("[tana-manga] resolved roots:", #roots)
    for _, r in ipairs(roots) do logger.info("  -", r) end
end

return M
