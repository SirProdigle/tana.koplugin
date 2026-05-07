# Search Groupings + Long-Press Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Search results show folder/author/series/genre group tiles before books; long-pressing any book offers one-tap navigation to its author, series, or genre grouping.

**Architecture:** `Repo.searchAll(query)` replaces `Repo.searchBooks` in `_searchAndDrill`, returning a structured result with five fields. `_fetchChipItems` emits group and folder tiles before book tiles in search mode. `_openBookMenu` gains up to five navigation items built via a new `Repo.findGroup(kind, name)` lookup.

**Tech Stack:** Lua 5.1, KOReader plugin API, `book_repository.lua` internal caches (`_walk_cache`, `_series_cache`, `_authors_cache`, `_genres_cache`), `ButtonDialog` widget, existing `_drillInto` / `_expand*` helpers.

---

## File map

| File | Change |
|------|--------|
| `book_repository.lua` | Add `Repo.searchAll(query)` after line 833 (after `searchBooks`); add `Repo.findGroup(kind, name)` after it |
| `bookshelf_widget.lua` | Update `_searchAndDrill` (line 2175); update `_fetchChipItems` search branch (lines 1019–1028); extend `_openBookMenu` (insert nav rows before Cancel at line 2000) |
| `tests/_test_book_repository.lua` | Append tests for `searchAll` and `findGroup` |

---

## Task 1 — `Repo.searchAll` in `book_repository.lua`

**Files:**
- Modify: `book_repository.lua` (insert after line 833, the closing `end` of `searchBooks`)
- Test: `tests/_test_book_repository.lua`

### Step 1.1 — Write the failing tests

Append to `tests/_test_book_repository.lua` (before the final `io.write` summary line at 406):

```lua
-- ============================================================================
-- searchAll
-- ============================================================================

test("searchAll: returns empty result for blank query", function()
    Repo.invalidateWalkCache()
    local r = Repo.searchAll("")
    assert(type(r) == "table")
    assert(#(r.books   or {}) == 0)
    assert(#(r.folders or {}) == 0)
    assert(#(r.authors or {}) == 0)
    assert(#(r.series  or {}) == 0)
    assert(#(r.genres  or {}) == 0)
end)

test("searchAll: matches books by title", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "dune.epub", "foundation.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end
        return 0
    end
    _G._test_settings  = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data  = {
        ["/lib/dune.epub"]       = { title = "Dune", authors = "Frank Herbert" },
        ["/lib/foundation.epub"] = { title = "Foundation", authors = "Isaac Asimov" },
    }
    local r = Repo.searchAll("dune")
    assert(#r.books == 1, "expected 1 book, got " .. #r.books)
    assert(r.books[1].title == "Dune")
end)

test("searchAll: matches author groups by name", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "dune.epub", "foundation.epub"} or {".", ".."}
        local i = 0; return function() i = i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end
        return 0
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/lib/dune.epub"]       = { title = "Dune",       authors = "Frank Herbert" },
        ["/lib/foundation.epub"] = { title = "Foundation", authors = "Isaac Asimov" },
    }
    Repo.invalidateSeriesCache()
    local r = Repo.searchAll("asimov")
    assert(#r.authors == 1, "expected 1 author group, got " .. #r.authors)
    assert(r.authors[1].series_name == "Isaac Asimov",
        "expected Isaac Asimov got " .. tostring(r.authors[1].series_name))
    assert(#r.authors[1].books == 1)
end)

test("searchAll: matches folders by directory name", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        if path == "/lib" then
            local files = {".", "..", "scifi"}
            local i = 0; return function() i=i+1; return files[i] end
        elseif path == "/lib/scifi" then
            local files = {".", "..", "dune.epub"}
            local i = 0; return function() i=i+1; return files[i] end
        else
            local files = {".", ".."}
            local i = 0; return function() i=i+1; return files[i] end
        end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then
            if fp == "/lib/scifi" then return "directory" end
            return "file"
        end
        return 0
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 2 }
    _G._test_bim_data = { ["/lib/scifi/dune.epub"] = { title = "Dune", authors = "Frank Herbert" } }
    local r = Repo.searchAll("scifi")
    assert(#r.folders == 1, "expected 1 folder, got " .. #r.folders)
    assert(r.folders[1].label == "scifi")
    assert(r.folders[1].kind  == "folder")
    assert(r.folders[1].path  == "/lib/scifi")
    assert(r.folders[1].first_book ~= nil)
end)
```

- [ ] **Step 1.2 — Run tests, confirm new tests fail**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && lua tests/_test_book_repository.lua
```

Expected: the four new `searchAll` tests report FAIL; all prior tests still PASS.

- [ ] **Step 1.3 — Implement `Repo.searchAll`**

In `book_repository.lua`, insert the following block after line 833 (the closing `end` of `Repo.searchBooks`):

```lua
-- ─── searchAll ───────────────────────────────────────────────────────────────
-- Returns { folders, authors, series, genres, books } for a query string.
-- All matching is case-insensitive substring. Returns empty lists immediately
-- for a blank query.
function Repo.searchAll(query)
    local empty = { folders = {}, authors = {}, series = {}, genres = {}, books = {} }
    if not query or query == "" then return empty end
    local q = query:lower()

    -- ── folders ──
    -- Derive from the already-cached walk: unique parent directories whose
    -- basename matches the query. No disk I/O: cachedWalk returns { fp, mtime }.
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local cands = cachedWalk(home, depth)
    local seen_dirs = {}
    local folders = {}
    for _, c in ipairs(cands) do
        local dir = c.fp:match("^(.*)/[^/]+$") or "/"
        if not seen_dirs[dir] then
            seen_dirs[dir] = true
            local basename = dir:match("([^/]+)$") or dir
            if basename:lower():find(q, 1, true) then
                local first_book = Repo.buildBookMeta(c.fp)
                folders[#folders + 1] = {
                    kind       = "folder",
                    path       = dir,
                    label      = basename,
                    first_book = first_book,
                }
            end
        end
    end

    -- ── author / series / genre groups ──
    -- Warm each shape cache with limit=0 (populates the cache without
    -- hydrating any groups — in Lua, 0 is truthy so `0 or 8` = 0, giving
    -- an empty loop but still running the _buildGroups fill). Then iterate
    -- shapes directly and hydrate only matching entries, avoiding the cost
    -- of hydrating the full collection just to filter it.
    local function matchGroups(cache_table)
        if not cache_table[key] then return {} end
        local out = {}
        for _, shape in ipairs(cache_table[key].groups) do
            if (shape.series_name or ""):lower():find(q, 1, true) then
                out[#out + 1] = _hydrateGroupShape(shape)
            end
        end
        return out
    end
    if not _authors_cache[key] then Repo.getAuthors(0, 0) end
    if not _series_cache[key]  then Repo.getSeriesGroups(0, 0) end
    if not _genres_cache[key]  then Repo.getGenres(0, 0) end

    local authors = matchGroups(_authors_cache)
    local series  = matchGroups(_series_cache)
    local genres  = matchGroups(_genres_cache)

    -- ── books ──
    local books = Repo.searchBooks(query, 200) or {}

    return { folders = folders, authors = authors, series = series, genres = genres, books = books }
end
```

- [ ] **Step 1.4 — Run tests, confirm searchAll tests pass**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && lua tests/_test_book_repository.lua
```

Expected: all tests PASS including the four new `searchAll` tests.

- [ ] **Step 1.5 — Commit**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin
git add book_repository.lua tests/_test_book_repository.lua
git commit -m "feat(repo): add Repo.searchAll returning folders/authors/series/genres/books"
```

---

## Task 2 — `Repo.findGroup` in `book_repository.lua`

Used by `_openBookMenu` (Task 4) to resolve a book's author/series/genre name to a full group record without hydrating the entire collection.

**Files:**
- Modify: `book_repository.lua` (insert after `Repo.searchAll`)
- Test: `tests/_test_book_repository.lua`

- [ ] **Step 2.1 — Write the failing tests**

Append to `tests/_test_book_repository.lua` (before the final `io.write` line):

```lua
-- ============================================================================
-- findGroup
-- ============================================================================

test("findGroup: returns nil for unknown kind", function()
    local g = Repo.findGroup("unknown", "anything")
    assert(g == nil)
end)

test("findGroup: returns nil when name not in author cache", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "dune.epub"} or {".", ".."}
        local i = 0; return function() i=i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end; return 0
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = { ["/lib/dune.epub"] = { title = "Dune", authors = "Frank Herbert" } }
    Repo.invalidateSeriesCache()
    Repo.getAuthors(10, 0) -- warm cache
    local g = Repo.findGroup("author", "Tolkien")
    assert(g == nil, "expected nil for non-existent author")
end)

test("findGroup: returns hydrated group for known author", function()
    Repo.invalidateWalkCache()
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        local files = (path == "/lib") and {".", "..", "dune.epub", "dune2.epub"} or {".", ".."}
        local i = 0; return function() i=i+1; return files[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "mode" then return "file" end; return 0
    end
    _G._test_settings = { home_dir = "/lib", bookshelf_latest_walk_depth = 1 }
    _G._test_bim_data = {
        ["/lib/dune.epub"]  = { title = "Dune",           authors = "Frank Herbert" },
        ["/lib/dune2.epub"] = { title = "Dune Messiah",   authors = "Frank Herbert" },
    }
    Repo.invalidateSeriesCache()
    Repo.getAuthors(10, 0) -- warm cache
    local g = Repo.findGroup("author", "Frank Herbert")
    assert(g ~= nil, "expected a group record")
    assert(g.series_name == "Frank Herbert")
    assert(#g.books == 2, "expected 2 books, got " .. #g.books)
end)
```

- [ ] **Step 2.2 — Run tests, confirm new tests fail**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && lua tests/_test_book_repository.lua
```

Expected: the three new `findGroup` tests FAIL; all prior tests PASS.

- [ ] **Step 2.3 — Implement `Repo.findGroup`**

Insert immediately after `Repo.searchAll` in `book_repository.lua`:

```lua
-- ─── findGroup ───────────────────────────────────────────────────────────────
-- Searches the in-memory shape cache for a group whose series_name matches
-- `name` (case-insensitive exact match) and hydrates just that one group.
-- Returns nil when: kind is unrecognised, the relevant cache is cold (has
-- never been populated this session), or no group matches the name.
-- Callers that get nil should fall back to a minimal single-book group.
function Repo.findGroup(kind, name)
    if not name or name == "" then return nil end
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local cache
    if     kind == "author" then cache = _authors_cache[key]
    elseif kind == "series" then cache = _series_cache[key]
    elseif kind == "genre"  then cache = _genres_cache[key]
    else return nil end
    if not cache then return nil end
    local lname = name:lower()
    for _, shape in ipairs(cache.groups) do
        if (shape.series_name or ""):lower() == lname then
            return _hydrateGroupShape(shape)
        end
    end
    return nil
end
```

- [ ] **Step 2.4 — Run tests, all pass**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && lua tests/_test_book_repository.lua
```

Expected: all tests PASS.

- [ ] **Step 2.5 — Commit**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin
git add book_repository.lua tests/_test_book_repository.lua
git commit -m "feat(repo): add Repo.findGroup for efficient single-group lookup"
```

---

## Task 3 — Wire `searchAll` into `_searchAndDrill` and `_fetchChipItems`

**Files:**
- Modify: `bookshelf_widget.lua`

- [ ] **Step 3.1 — Update `_searchAndDrill` (line 2175)**

Replace lines 2176–2202 of `bookshelf_widget.lua`:

```lua
-- OLD (replace this):
function BookshelfWidget:_searchAndDrill(query)
    local books = Repo.searchBooks(query, 200) or {}
    ...
    self:_drillInto{
        kind            = "search",
        label           = query,
        payload         = { query = query, books = books },
        prior_drilldown = prior_path,
    }
end
```

The minimal diff — change the first line and the payload line only:

```lua
function BookshelfWidget:_searchAndDrill(query)
    local results = Repo.searchAll(query)
    local prior_path
    local current_top = self._drilldown_path[#self._drilldown_path]
    if current_top and current_top.kind == "search" and current_top.prior_drilldown then
        prior_path = current_top.prior_drilldown
    else
        prior_path = self._drilldown_path
    end
    self._drilldown_path = {}
    self:_drillInto{
        kind            = "search",
        label           = query,
        payload         = {
            query   = query,
            folders = results.folders,
            authors = results.authors,
            series  = results.series,
            genres  = results.genres,
            books   = results.books,
        },
        prior_drilldown = prior_path,
    }
end
```

- [ ] **Step 3.2 — Update `_fetchChipItems` search branch (lines 1019–1028)**

Replace the search branch inside `_fetchChipItems`. The current block is:

```lua
    if tip and (tip.kind == "series" or tip.kind == "author"
            or tip.kind == "genre" or tip.kind == "tag"
            or tip.kind == "search") then
        local fresh = {}
        for _, b in ipairs(tip.payload.books) do
            local nb = b.filepath and Repo.buildBookMeta(b.filepath) or b
            fresh[#fresh + 1] = nb
        end
        return fresh
    end
```

Split search mode out into its own branch so folder/group tiles are interleaved correctly, while keeping the series/author/genre/tag branch's book-rebuild logic intact:

```lua
    -- Search mode: emit ordered tiles (folders → authors → series → genres → books).
    if tip and tip.kind == "search" then
        local ds = G_reader_settings:readSetting("bookshelf_chips_disabled")
                   or { latest = true, authors = true, genres = true, tags = true }
        local fresh = {}
        if not ds["all"] then
            for _, f in ipairs(tip.payload.folders or {}) do
                fresh[#fresh + 1] = f
            end
        end
        if not ds["authors"] then
            for _, g in ipairs(tip.payload.authors or {}) do
                fresh[#fresh + 1] = g
            end
        end
        if not ds["series"] then
            for _, g in ipairs(tip.payload.series or {}) do
                fresh[#fresh + 1] = g
            end
        end
        if not ds["genres"] then
            for _, g in ipairs(tip.payload.genres or {}) do
                fresh[#fresh + 1] = g
            end
        end
        for _, b in ipairs(tip.payload.books or {}) do
            local nb = b.filepath and Repo.buildBookMeta(b.filepath) or b
            fresh[#fresh + 1] = nb
        end
        return fresh
    end
    -- Drill into a group (series / author / genre / tag): rebuild from filepaths
    -- so cover_bbs are fresh (image_disposable frees them after each render).
    if tip and (tip.kind == "series" or tip.kind == "author"
            or tip.kind == "genre" or tip.kind == "tag") then
        local fresh = {}
        for _, b in ipairs(tip.payload.books) do
            local nb = b.filepath and Repo.buildBookMeta(b.filepath) or b
            fresh[#fresh + 1] = nb
        end
        return fresh
    end
```

- [ ] **Step 3.3 — Also fix the empty-state check**

`_rebuild` checks `#items == 0` to show the "No matches" placeholder. With the new payload shape, `payload.query` still exists, so the existing check at line 631 still works:

```lua
if _tip and _tip.kind == "search" then
    placeholder_text = string.format(
        _("No matches for \"%s\""), _tip.payload.query or "")
```

No change needed here — confirm by reading lines 630–633 after your edits.

- [ ] **Step 3.4 — luac check**

```bash
luac -p /home/andyhazz/projects/bookshelf.koplugin/bookshelf_widget.lua && echo "OK"
```

Expected: `OK` with no errors.

- [ ] **Step 3.5 — Manual smoke test on desktop KOReader**

1. Open desktop KOReader (bookshelf is symlinked to working tree — changes take effect on next widget open).
2. Open Bookshelf → tap the search icon → type an author name that exists in your library.
3. Confirm: author group tile appears above book tiles.
4. Tap the author tile → confirm it drills into that author's books.
5. Search for a folder name → confirm folder tile appears first.
6. Tap folder tile → confirm it opens that folder's contents.
7. Search for a term with no matches → confirm "No matches for …" placeholder still appears.

- [ ] **Step 3.6 — Commit**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin
git add bookshelf_widget.lua
git commit -m "feat(widget): search results show folder/author/series/genre tiles before books"
```

---

## Task 4 — Long-press navigation in `_openBookMenu`

**Files:**
- Modify: `bookshelf_widget.lua` (`_openBookMenu` function, lines 1932–2005)

- [ ] **Step 4.1 — Add nav rows before Cancel**

In `_openBookMenu`, the `buttons` table currently has three rows:
1. `{ "Show info", fav_label }`
2. `{ "Remove from history" }`
3. `{ "Cancel" }`

Insert the navigation rows between row 2 and the Cancel row. The full replacement for the `buttons` definition (lines 1959–2002):

```lua
    -- Build optional navigation rows (author / series / genres).
    -- Each item is only included if the book has the field AND the
    -- corresponding chip is not disabled.
    local ds = G_reader_settings:readSetting("bookshelf_chips_disabled")
               or { latest = true, authors = true, genres = true, tags = true }
    local nav_rows = {}
    -- Go to Author
    if book.author and book.author ~= "" and not ds["authors"] then
        local author_name = book.author
        nav_rows[#nav_rows + 1] = {
            { text = "Go to author: " .. author_name,
              callback = closing(function()
                local group = Repo.findGroup("author", author_name)
                if not group then
                    group = { kind = "author", series_name = author_name,
                              books = { book }, latest = 0 }
                end
                bw:_expandAuthor(group)
              end) },
        }
    end
    -- Go to Series
    -- Book records carry `series_name` (cleaned, e.g. "Foundation") which
    -- is the same key used by series group records. `book.series` is the
    -- raw BIM string (e.g. "Foundation #1") — do NOT use it here.
    if book.series_name and book.series_name ~= "" and not ds["series"] then
        local series_name = book.series_name
        nav_rows[#nav_rows + 1] = {
            { text = "Go to series: " .. series_name,
              callback = closing(function()
                local group = Repo.findGroup("series", series_name)
                if not group then
                    group = { kind = "series", series_name = series_name,
                              books = { book }, latest = 0 }
                end
                bw:_expandSeries(group)
              end) },
        }
    end
    -- Go to Genre (up to 3)
    if book.genres and #book.genres > 0 and not ds["genres"] then
        local max_genres = math.min(#book.genres, 3)
        for i = 1, max_genres do
            local genre_name = book.genres[i]
            nav_rows[#nav_rows + 1] = {
                { text = "Go to genre: " .. genre_name,
                  callback = closing(function()
                    local group = Repo.findGroup("genre", genre_name)
                    if not group then
                        group = { kind = "genre", series_name = genre_name,
                                  books = { book }, latest = 0 }
                    end
                    bw:_expandGenre(group)
                  end) },
            }
        end
    end

    dialog = ButtonDialog:new{
        title = book.title or book.filename or "Book",
        buttons = {
            {
                { text = "Show info",
                  callback = closing(function()
                    local FileManager = require("apps/filemanager/filemanager")
                    local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
                    if FileManager.instance and FileManager.instance.bookinfo then
                        FileManager.instance.bookinfo:show(book.filepath)
                    else
                        FileManagerBookInfo:new{}:show(book.filepath)
                    end
                  end) },
                { text = fav_label,
                  callback = closing(function()
                    local ok, already = pcall(function()
                        return ReadCollection:isFileInCollection(book.filepath, "favorites")
                    end)
                    if ok and already then
                        ReadCollection:removeItem(book.filepath, "favorites")
                    else
                        ReadCollection:addItem(book.filepath, "favorites")
                        ReadCollection:write({ favorites = true })
                    end
                    bw:_rebuild()
                    UIManager:setDirty(bw, "ui")
                  end) },
            },
            {
                { text = "Remove from history",
                  callback = closing(function()
                    require("readhistory"):removeItemByPath(book.filepath)
                    bw:_rebuild()
                    UIManager:setDirty(bw, "ui")
                  end) },
            },
        },
    }
    -- Splice in nav rows, then Cancel
    local btns = dialog.buttons
    for _, row in ipairs(nav_rows) do
        btns[#btns + 1] = row
    end
    btns[#btns + 1] = { { text = "Cancel", callback = closing() } }
```

- [ ] **Step 4.2 — luac check**

```bash
luac -p /home/andyhazz/projects/bookshelf.koplugin/bookshelf_widget.lua && echo "OK"
```

Expected: `OK`.

- [ ] **Step 4.3 — Manual smoke test on desktop KOReader**

1. Open Bookshelf on a book that has author + series + genre metadata.
2. Long-press the book spine → confirm "Go to author: …" and "Go to series: …" appear.
3. Tap "Go to author: …" → confirm it drills into that author's group view.
4. Back out → long-press again → tap "Go to series: …" → confirm series drill.
5. Long-press a book with no series but with genres → confirm "Go to series" is absent, genre items present.
6. Long-press a book with no author/series/genre metadata → confirm menu is unchanged (no nav rows).
7. Long-press a book when the Authors chip is disabled (Settings → Chips) → confirm "Go to author" is absent.

- [ ] **Step 4.4 — Commit**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin
git add bookshelf_widget.lua
git commit -m "feat(widget): long-press book menu offers Go-to-Author/Series/Genre navigation"
```

---

## Task 5 — Push to remote

- [ ] **Step 5.1 — Final luac check on both modified files**

```bash
luac -p /home/andyhazz/projects/bookshelf.koplugin/book_repository.lua && \
luac -p /home/andyhazz/projects/bookshelf.koplugin/bookshelf_widget.lua && \
echo "both OK"
```

- [ ] **Step 5.2 — Run full test suite**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && lua tests/_test_book_repository.lua
```

Expected: all tests PASS, 0 failed.

- [ ] **Step 5.3 — Push**

```bash
git push origin master
```
