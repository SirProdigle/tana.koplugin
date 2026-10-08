-- tana_chapter.lua
-- One place that knows what a manga chapter file is: its chapter number,
-- the name Maki saves a server file under, and which Komga book a local
-- file is. Everything that used to pattern-match "Chapter N" by hand (the
-- progress push, Continue, the chapter list, labels) goes through here.
--
-- Chapter files arrive from Suwayomi as "<scanlator>_<chapter name>.cbz",
-- and the chapter name is whatever the source calls it: "Chapter 97",
-- "# 10", "Spell 101.5", "Day 3", "Vol.1 Ch.9.1 - Bios", "Volume 10".
-- Maki rewrites only the "Chapter N" family to "Chapter 0097.cbz"; every
-- other name lands on the device untouched. So a file name is a hint, not
-- an identity. Identity comes from the Komga book, resolved in order:
--   1. Maki's ledger (.maki.lua `fetched`): acquisition URL → local file.
--      Exact; covers every chapter Maki downloaded.
--   2. The server file name, raw or Maki-normalised, equal to the local one.
--      Exact; covers files that arrived another way (tana's own download).
--   3. The chapter number parsed from the local name against Komga's
--      ComicInfo number. Heuristic, last resort.

local M = {}

-- Komga returns JSON null for absent objects; KOReader's decoder maps null
-- to a truthy userdata sentinel. Only real tables are tables.
local function tbl(x)
    return type(x) == "table" and x or nil
end

local function stem_of(filename)
    return (filename:gsub("%.[^.]+$", ""))
end

-- A Suwayomi scanlator prefix: everything up to the first "_", but only
-- when a number follows it (so a bare "Chapter_12" keeps its keyword).
local function strip_scanlator(stem)
    local rest = stem:match("^[^_]*_(.*%d.*)$")
    return rest or stem
end

local NUM = "(%d+%.?%d*)"

-- Explicit chapter markers, most specific first. %f[%a] anchors a keyword
-- at a word start so "Official" or "Dorohedoro" never read as "c"/"ch".
local KEYWORD_PATTERNS = {
    "%f[%a][Cc][Hh][Aa]?[Pp]?[Tt]?[Ee]?[Rr]?%.?[%s_%-%.]*" .. NUM, -- Chapter 97, Chap 5, Ch.9.1, ch12
    "#%s*" .. NUM,                                                 -- # 10
    "%f[%a][Ee][Pp][Ii]?[Ss]?[Oo]?[Dd]?[Ee]?%.?[%s_%-]*" .. NUM,   -- Episode 4, Ep. 4
    "%f[%a][Cc]0*" .. NUM .. "%f[^%d%.]",                          -- c042
}

-- Chapter number of a chapter file name, or nil.
-- "Official_# 10.cbz" → 10, "Official_Spell 101.5.cbz" → 101.5,
-- "Hox_Vol.1 Ch.10 - Lingering Grudge.cbz" → 10, "Chapter 0061.5.cbz" → 61.5.
function M.number(filename)
    if type(filename) ~= "string" or filename == "" then return nil end
    local name = strip_scanlator(stem_of(filename))
    for _, pat in ipairs(KEYWORD_PATTERNS) do
        local n = name:match(pat)
        if n then return tonumber((n:gsub("%.$", ""))) end
    end
    -- No marker: the first number is the chapter ("Spell 100", "Day 3",
    -- "Volume 10", "Prologue 2"). A trailing dot belongs to the sentence,
    -- not the number.
    local n = name:match(NUM)
    return n and tonumber((n:gsub("%.$", ""))) or nil
end

-- "97", "61.5" — numbers as people write them.
function M.format(num)
    num = tonumber(num)
    return num and string.format("%g", num) or nil
end

-- Order chapter files by chapter number; files without one go last, by name.
-- `natLess` breaks ties (two releases of the same chapter) and orders the
-- unnumbered ones.
function M.less(a_name, b_name, natLess)
    local an, bn = M.number(a_name), M.number(b_name)
    if an and bn and an ~= bn then return an < bn end
    if an and not bn then return true end
    if bn and not an then return false end
    if natLess then return natLess(a_name, b_name) end
    return a_name < b_name
end

-- ── Komga ────────────────────────────────────────────────────────────────

-- The name Maki saves a server file under (it normalises "…Chapter N…" to
-- "Chapter 000N"). Uses Maki's own module when it is loaded so the two can
-- never disagree; identity otherwise.
function M.localName(server_name)
    if type(server_name) ~= "string" then return nil end
    local ok, names = pcall(require, "makinames")
    if ok and type(names) == "table" and names.normalizeChapter then
        return names.normalizeChapter(server_name)
    end
    return server_name
end

-- File name of a Komga book on the server (basename of its `url` path).
function M.serverName(book)
    book = tbl(book)
    if not book or type(book.url) ~= "string" then return nil end
    return book.url:match("([^/]+)$")
end

-- Chapter number of a Komga book: ComicInfo's number (numberSort is its
-- numeric form), else the book's position.
function M.bookNumber(book)
    book = tbl(book)
    if not book then return nil end
    local meta = tbl(book.metadata)
    return tonumber(meta and meta.numberSort)
        or tonumber(meta and meta.number)
        or tonumber(book.number)
end

-- Komga book id inside an OPDS acquisition URL (".../books/{id}/file/...").
function M.bookIdFromUrl(url)
    return type(url) == "string" and url:match("/books/([^/?#]+)/") or nil
end

-- The Komga book a local chapter file is. `books` is the `content` array
-- of /api/v1/series/{id}/books; `fetched` is the Maki ledger (optional).
-- Returns book, how ("ledger" | "name" | "number") — or nil.
function M.resolveBook(file, books, fetched)
    if type(file) ~= "string" or type(books) ~= "table" then return nil end
    local by_id = {}
    for _, b in ipairs(books) do
        if tbl(b) and b.id then by_id[b.id] = b end
    end
    if type(fetched) == "table" then
        for url, rec in pairs(fetched) do
            if tbl(rec) and rec.file == file then
                local book = by_id[M.bookIdFromUrl(url)]
                if book then return book, "ledger" end
            end
        end
    end
    for _, b in ipairs(books) do
        local server = M.serverName(b)
        if server and (server == file or M.localName(server) == file) then
            return b, "name"
        end
    end
    local num = M.number(file)
    if num then
        for _, b in ipairs(books) do
            if M.bookNumber(b) == num then return b, "number" end
        end
    end
    return nil
end

return M
