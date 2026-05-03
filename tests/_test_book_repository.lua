-- tests/_test_book_repository.lua
-- Pure-Lua integration-style tests for book_repository.lua with stubbed KOReader modules.
-- Usage: cd into the plugin dir, then `lua tests/_test_book_repository.lua`.

package.loaded["readhistory"] = { hist = {} }
package.loaded["readcollection"] = { coll = { favorites = {} }, default_collection_name = "favorites" }
package.loaded["bookinfomanager"] = {
    getBookInfo = function(_self, fp, _with_cover)
        return _G._test_bim_data and _G._test_bim_data[fp] or nil
    end,
}
package.loaded["docsettings"] = {
    open = function(_self, fp)
        return setmetatable({}, { __index = function(_, k)
            if k == "readSetting" then return function(_, key)
                return _G._test_docsettings_data and _G._test_docsettings_data[fp]
                    and _G._test_docsettings_data[fp][key]
            end end
        end })
    end,
}
package.loaded["lfs"] = {
    attributes = function(fp, key)
        if key == "modification" then
            return _G._test_mtime and _G._test_mtime[fp] or 0
        end
    end,
}
_G.G_reader_settings = setmetatable({}, {
    __index = function(_, k)
        if k == "readSetting" then
            return function(_, key)
                return _G._test_settings and _G._test_settings[key]
            end
        end
        return nil
    end,
})

local Repo = dofile("book_repository.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

-- ============================================================================
-- Task 2.1: smoke + getCurrent
-- ============================================================================

test("smoke: Repo loads", function() assert(type(Repo) == "table") end)

test("getCurrent: returns nil when no lastfile in settings", function()
    _G._test_settings = nil
    local b = Repo.getCurrent()
    assert(b == nil, "expected nil, got " .. tostring(b))
end)

test("getCurrent: returns a book when lastfile is set", function()
    _G._test_settings = { lastfile = "/books/dune.epub" }
    _G._test_bim_data = {
        ["/books/dune.epub"] = {
            title = "Dune",
            authors = "Frank Herbert",
            series = "Dune #1",
            pages = 688,
        }
    }
    _G._test_docsettings_data = {
        ["/books/dune.epub"] = {
            last_page = 142,
            percent_finished = 0.206,
        }
    }
    local b = Repo.getCurrent()
    assert(b ~= nil, "expected a book record")
    assert(b.title == "Dune", "expected title=Dune got " .. tostring(b.title))
    assert(b.author == "Frank Herbert", "expected author got " .. tostring(b.author))
    assert(b.series_name == "Dune", "expected series_name=Dune got " .. tostring(b.series_name))
    assert(b.series_num == "1", "expected series_num=1 got " .. tostring(b.series_num))
    assert(b.page_num == 142, "expected page_num=142 got " .. tostring(b.page_num))
    assert(b.page_count == 688, "expected page_count=688 got " .. tostring(b.page_count))
    assert(b.format == "EPUB", "expected format=EPUB got " .. tostring(b.format))
    assert(b.filename == "dune", "expected filename=dune got " .. tostring(b.filename))
end)

-- ============================================================================
-- Task 2.2: getRecent (already committed)
-- ============================================================================

test("getRecent: orders by ReadHistory.hist time desc, caps at limit", function()
    package.loaded["readhistory"].hist = {
        { file = "/a.epub", time = 300 },
        { file = "/b.epub", time = 200 },
        { file = "/c.epub", time = 100 },
    }
    _G._test_bim_data = {
        ["/a.epub"] = { title = "A" },
        ["/b.epub"] = { title = "B" },
        ["/c.epub"] = { title = "C" },
    }
    local recent = Repo.getRecent(2)
    assert(#recent == 2, "got " .. #recent)
    assert(recent[1].title == "A")
    assert(recent[2].title == "B")
end)

-- ============================================================================
-- Task 2.3: getLatest
-- ============================================================================

test("getLatest: orders by mtime desc, respects limit and depth", function()
    -- Stub a tiny directory walk via the lfs mock above.
    package.loaded["lfs"].dir = function(path)
        local files
        if path == "/home" then files = { ".", "..", "old.epub", "new.epub", "sub" }
        elseif path == "/home/sub" then files = { ".", "..", "deep.epub" }
        else files = {} end
        local i = 0
        return function() i = i + 1; return files[i] end
    end
    package.loaded["lfs"].attributes = function(fp, key)
        local times = { ["/home/old.epub"] = 100, ["/home/new.epub"] = 500, ["/home/sub/deep.epub"] = 300 }
        local modes = { ["/home/sub"] = "directory" }
        if key == "modification" then return times[fp] or 0
        elseif key == "mode" then return modes[fp] or "file" end
    end
    _G._test_settings = { home_dir = "/home", bookshelf_latest_walk_depth = 3 }
    _G._test_bim_data = {
        ["/home/old.epub"]      = { title = "Old" },
        ["/home/new.epub"]      = { title = "New" },
        ["/home/sub/deep.epub"] = { title = "Deep" },
    }
    local latest = Repo.getLatest(3)
    assert(#latest == 3, "got " .. #latest)
    assert(latest[1].title == "New")
    assert(latest[2].title == "Deep")
    assert(latest[3].title == "Old")
end)

-- ============================================================================
-- Task 2.4: getFavorites + getSeriesGroups
-- ============================================================================

test("getFavorites: pulls from ReadCollection.coll.favorites", function()
    package.loaded["readcollection"].coll = {
        favorites = {
            ["/a.epub"] = { file = "/a.epub", attr = { access = 200 } },
            ["/b.epub"] = { file = "/b.epub", attr = { access = 300 } },
        }
    }
    _G._test_bim_data = {
        ["/a.epub"] = { title = "A" },
        ["/b.epub"] = { title = "B" },
    }
    local favs = Repo.getFavorites(10)
    assert(#favs == 2)
    assert(favs[1].title == "B", "expected B (most recent) first")
end)

test("getSeriesGroups: groups books by series_name, sorts by latest activity", function()
    package.loaded["readhistory"].hist = {
        { file = "/dune.epub", time = 500 },
        { file = "/foundation1.epub", time = 400 },
        { file = "/foundation2.epub", time = 450 },
        { file = "/standalone.epub", time = 100 },
    }
    _G._test_bim_data = {
        ["/dune.epub"]        = { title = "Dune", series = "Dune #1" },
        ["/foundation1.epub"] = { title = "Foundation", series = "Foundation #1" },
        ["/foundation2.epub"] = { title = "Foundation and Empire", series = "Foundation #2" },
        ["/standalone.epub"]  = { title = "Standalone" },
    }
    local groups = Repo.getSeriesGroups(10)
    -- Standalone should NOT appear (no series).
    assert(#groups == 2, "expected 2 series groups, got " .. #groups)
    -- Dune is most recently active (time=500).
    assert(groups[1].series_name == "Dune")
    assert(groups[2].series_name == "Foundation")
    -- Foundation has 2 books; ensure ordered by series_num.
    assert(#groups[2].books == 2)
    assert(groups[2].books[1].title == "Foundation")
    assert(groups[2].books[2].title == "Foundation and Empire")
end)

-- ============================================================================
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
