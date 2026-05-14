-- tests/_test_tana_manga.lua
-- Pure-Lua tests for tana_manga.lua. Stubs G_reader_settings + lfs +
-- ReadHistory + DocSettings so the module's path predicates, natural
-- sort, and resume lookup can run without a KOReader runtime.
--
-- Usage: cd into the plugin dir, then `lua tests/_test_tana_manga.lua`.

package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }

-- ─── G_reader_settings stub ──────────────────────────────────────────────

local _settings = {}
_G.G_reader_settings = {
    readSetting = function(_self, key) return _settings[key] end,
    saveSetting = function(_self, key, val) _settings[key] = val end,
    flush       = function() end,
}

-- ─── lfs stub ────────────────────────────────────────────────────────────
-- A toy in-memory filesystem so listChaptersSorted / listCollections can
-- iterate without touching disk. The tree is keyed by absolute path and
-- carries { mode, modification, children } per entry.

local _fs = {}

local function _set_dir(path, children)
    _fs[path] = { mode = "directory", modification = 0, children = children }
end
local function _set_file(path, mtime)
    _fs[path] = { mode = "file", modification = mtime or 0 }
end

package.loaded["libs/libkoreader-lfs"] = {
    dir = function(path)
        local entry = _fs[path]
        if not entry or entry.mode ~= "directory" then
            error("lfs.dir: no such directory " .. tostring(path))
        end
        local list = { ".", ".." }
        for _, name in ipairs(entry.children or {}) do
            list[#list + 1] = name
        end
        local i = 0
        return function()
            i = i + 1
            return list[i]
        end
    end,
    attributes = function(path, key)
        local entry = _fs[path]
        if not entry then return nil end
        if key == "mode"          then return entry.mode end
        if key == "modification"  then return entry.modification end
        if key == nil then
            return { mode = entry.mode, modification = entry.modification }
        end
        return nil
    end,
}

-- ─── ReadHistory stub ────────────────────────────────────────────────────

package.loaded["readhistory"] = { hist = {} }

-- ─── DocSettings stub ────────────────────────────────────────────────────

local _docsettings_data = {}
package.loaded["docsettings"] = {
    open = function(_self, fp)
        return setmetatable({}, {
            __index = function(_, k)
                if k == "readSetting" then
                    return function(_, key)
                        return _docsettings_data[fp] and _docsettings_data[fp][key]
                    end
                end
            end,
        })
    end,
}

-- ─── Test runner ─────────────────────────────────────────────────────────

local M = dofile("tana_manga.lua")

local pass, fail = 0, 0
local function test(name, fn)
    M.invalidate()  -- reset roots cache between tests
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

-- ─── Path predicates ─────────────────────────────────────────────────────

test("isMangaRoot: absolute root path under home_dir matches", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    assert(M.isMangaRoot("/x/Books/_MANGA") == true)
    assert(M.isMangaRoot("/x/Books/_MANGA/") == true)
end)

test("isMangaRoot: not the home_dir itself", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    assert(M.isMangaRoot("/x/Books") == false)
end)

test("isMangaCollection: direct child of root", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    assert(M.isMangaCollection("/x/Books/_MANGA/Chainsaw Man") == true)
end)

test("isMangaCollection: root itself is not a collection", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    assert(M.isMangaCollection("/x/Books/_MANGA") == false)
end)

test("isMangaCollection: sibling folder is not a collection", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    assert(M.isMangaCollection("/x/Books/Discworld") == false)
end)

test("isChapterFile: chapter file inside collection", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    assert(M.isChapterFile("/x/Books/_MANGA/Chainsaw Man/Ch 1.cbz") == true)
end)

test("isChapterFile: file directly in root is NOT a chapter file", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    -- A one-shot dropped at the manga-root top level isn't a chapter,
    -- because its parent is the root (a root is not a collection).
    assert(M.isChapterFile("/x/Books/_MANGA/oneshot.cbz") == false)
end)

test("isChapterFile: regular ebook in Books is NOT a chapter file", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    assert(M.isChapterFile("/x/Books/dune.epub") == false)
end)

test("collectionFor: returns parent collection", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    assert(M.collectionFor("/x/Books/_MANGA/Chainsaw Man/Ch 1.cbz")
        == "/x/Books/_MANGA/Chainsaw Man")
    assert(M.collectionFor("/x/Books/dune.epub") == nil)
end)

test("absolute path manga root passes through", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "/sd/manga" }
    assert(M.isMangaRoot("/sd/manga") == true)
    assert(M.isMangaCollection("/sd/manga/Berserk") == true)
end)

test("multiple roots all resolve", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA", "Webtoons" }
    assert(M.isMangaRoot("/x/Books/_MANGA") == true)
    assert(M.isMangaRoot("/x/Books/Webtoons") == true)
    assert(M.isMangaCollection("/x/Books/Webtoons/Tower of God") == true)
end)

-- ─── Natural sort ────────────────────────────────────────────────────────

test("natLess: numeric ordering within strings", function()
    local items = { "Ch 100", "Ch 1", "Ch 2", "Ch 20", "Ch 10" }
    table.sort(items, M._natLess)
    assert(items[1] == "Ch 1",   "got " .. items[1])
    assert(items[2] == "Ch 2",   "got " .. items[2])
    assert(items[3] == "Ch 10",  "got " .. items[3])
    assert(items[4] == "Ch 20",  "got " .. items[4])
    assert(items[5] == "Ch 100", "got " .. items[5])
end)

test("natLess: case insensitive on string parts", function()
    local items = { "BERSERK", "berserk" }
    table.sort(items, M._natLess)
    -- Either ordering is fine; the point is the comparator doesn't crash.
    assert(items[1] and items[2])
end)

-- ─── listChaptersSorted ──────────────────────────────────────────────────

test("listChaptersSorted: natural order, only chapter extensions", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    _set_dir("/x/Books/_MANGA/Test", {
        "Ch 100.cbz", "Ch 1.cbz", "Ch 2.cbz", "Ch 10.cbz",
        "README.txt",  -- supported by Bookshelf but not by manga
    })
    _set_file("/x/Books/_MANGA/Test/Ch 100.cbz", 100)
    _set_file("/x/Books/_MANGA/Test/Ch 1.cbz",   1)
    _set_file("/x/Books/_MANGA/Test/Ch 2.cbz",   2)
    _set_file("/x/Books/_MANGA/Test/Ch 10.cbz",  10)
    _set_file("/x/Books/_MANGA/Test/README.txt", 50)
    -- README.txt has a chapter-eligible extension via CHAPTER_EXT.txt? No,
    -- we limited CHAPTER_EXT to cbz/cbr/cb7/cbt/pdf/epub. .txt is filtered.
    local out = M.listChaptersSorted("/x/Books/_MANGA/Test")
    assert(#out == 4, "expected 4 chapters, got " .. #out)
    assert(out[1].name == "Ch 1.cbz",   "got " .. out[1].name)
    assert(out[2].name == "Ch 2.cbz",   "got " .. out[2].name)
    assert(out[3].name == "Ch 10.cbz",  "got " .. out[3].name)
    assert(out[4].name == "Ch 100.cbz", "got " .. out[4].name)
end)

-- ─── listCollections ─────────────────────────────────────────────────────

test("listCollections: direct subfolders of each root", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    _set_dir("/x/Books/_MANGA", { "Chainsaw Man", "HxH" })
    _set_dir("/x/Books/_MANGA/Chainsaw Man", {})
    _set_dir("/x/Books/_MANGA/HxH",          {})
    local out = M.listCollections()
    assert(#out == 2, "expected 2 collections, got " .. #out)
    -- sorted alpha by label
    assert(out[1].label == "Chainsaw Man", "got " .. out[1].label)
    assert(out[2].label == "HxH",          "got " .. out[2].label)
end)

-- ─── chapterLabel ────────────────────────────────────────────────────────

test("chapterLabel: 'Official_Chapter 97.cbz' -> 'Ch. 97'", function()
    assert(M.chapterLabel("Official_Chapter 97.cbz") == "Ch. 97",
        "got " .. M.chapterLabel("Official_Chapter 97.cbz"))
end)

test("chapterLabel: 'c042.cbz' -> 'Ch. 42'", function()
    assert(M.chapterLabel("c042.cbz") == "Ch. 42",
        "got " .. M.chapterLabel("c042.cbz"))
end)

test("chapterLabel: unrecognised falls back to stem", function()
    assert(M.chapterLabel("weird-name.cbz") == "weird-name")
end)

-- ─── getResume ───────────────────────────────────────────────────────────

test("getResume: nil when no history under this collection", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    package.loaded["readhistory"].hist = {
        { file = "/x/Books/dune.epub", time = 100 },
    }
    local r = M.getResume("/x/Books/_MANGA/Chainsaw Man", nil)
    assert(r == nil, "expected nil, got " .. tostring(r))
end)

test("getResume: most-recent matching chapter wins", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    package.loaded["readhistory"].hist = {
        -- ReadHistory.hist is ordered newest-first (index 1 is newest).
        { file = "/x/Books/_MANGA/Chainsaw Man/Official_Chapter 97.cbz", time = 300 },
        { file = "/x/Books/_MANGA/Chainsaw Man/Official_Chapter 1.cbz",  time = 100 },
        { file = "/x/Books/dune.epub",                                   time = 50 },
    }
    _docsettings_data["/x/Books/_MANGA/Chainsaw Man/Official_Chapter 97.cbz"] = {
        last_page = 9, doc_pages = 22,
    }
    local r = M.getResume("/x/Books/_MANGA/Chainsaw Man", nil)
    assert(r, "expected a resume tuple")
    assert(r.filename == "Official_Chapter 97.cbz", "got " .. tostring(r.filename))
    assert(r.label == "Ch. 97", "got " .. tostring(r.label))
    assert(r.page == 9 and r.total == 22,
        "got page=" .. tostring(r.page) .. " total=" .. tostring(r.total))
end)

test("getResume: doesn't pick a nested file (deeper than collection)", function()
    _settings.home_dir = "/x/Books"
    _settings.tana_manga_roots = { "_MANGA" }
    package.loaded["readhistory"].hist = {
        { file = "/x/Books/_MANGA/Chainsaw Man/extras/sub/x.cbz", time = 300 },
    }
    local r = M.getResume("/x/Books/_MANGA/Chainsaw Man", nil)
    assert(r == nil, "nested file should not count")
end)

-- ─── hideChaptersEnabled ─────────────────────────────────────────────────

test("hideChaptersEnabled: default on when setting unset", function()
    _settings.tana_hide_chapters = nil
    assert(M.hideChaptersEnabled() == true)
end)

test("hideChaptersEnabled: respects explicit false", function()
    _settings.tana_hide_chapters = false
    assert(M.hideChaptersEnabled() == false)
end)

-- ─── Summary ─────────────────────────────────────────────────────────────

print(string.format("%d/%d tests passed", pass, pass + fail))
if fail > 0 then os.exit(1) end
