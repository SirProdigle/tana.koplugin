-- tests/_test_tana_chapter.lua
-- Pure tests for tana_chapter.lua: chapter numbers from every naming
-- scheme in the library, ordering, and local file → Komga book resolution.
--
-- Usage: cd into the plugin dir, then `lua tests/_test_tana_chapter.lua`.

-- Maki's real normaliser, so localName() is tested against the code the
-- device runs. Falls back to identity when the sibling repo is absent.
package.path = "../maki.koplugin/maki.koplugin/?.lua;" .. package.path

local C = dofile("tana_chapter.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function assert_eq(got, want, what)
    if got ~= want then error((what or "value") .. ": got " .. tostring(got) .. ", want " .. tostring(want), 2) end
end

-- ── number() over the names actually on the server ──────────────────────

local NAMES = {
    { "Official_Chapter 97.cbz", 97 },
    { "Official_Chapter 61.5.cbz", 61.5 },
    { "Chapter 0097.cbz", 97 },              -- Maki-normalised
    { "Chapter 0061.5.cbz", 61.5 },
    { "Official_# 10.cbz", 10 },             -- Steel Ball Run
    { "Unknown_# 95.cbz", 95 },
    { "Official_Spell 101.5.cbz", 101.5 },   -- Dorohedoro
    { "Official_Day 10.cbz", 10 },           -- Hirayasumi
    { "Official_Days 100.cbz", 100 },        -- Sakamoto Days
    { "Official_Phase 10.cbz", 10 },         -- Planetes
    { "Official_Stage 11.cbz", 11 },         -- Paradise Kiss
    { "Official_Smoke 10.cbz", 10 },
    { "Official_Volume 10.cbz", 10 },        -- Nana
    { "Official_Prologue 10.cbz", 10 },      -- Berserk
    { "Hox_Vol.1 Ch.0 - Intro.cbz", 0 },     -- MangaDex
    { "Hox_Vol.1 Ch.10 - Lingering Grudge.cbz", 10 },
    { "Giant Ethicist_Vol.1 Ch.9.1 - Character Bios.cbz", 9.1 },
    { "junontakeo_Vol.1 Ch.4 - 4th period.cbz", 4 },
    { "junontakeo_Vol.1 Ch.5.5.cbz", 5.5 },
    { "c042.cbz", 42 },
    { "Episode 4.cbz", 4 },
    { "Ch. 5..cbz", 5 },
}
for _, case in ipairs(NAMES) do
    test("number: " .. case[1], function()
        assert_eq(C.number(case[1]), case[2])
    end)
end

test("number: no digits → nil", function()
    assert_eq(C.number("Oneshot.cbz"), nil)
    assert_eq(C.number(nil), nil)
end)

test("number: 'Official' / 'Dorohedoro' never read as a c/ch keyword", function()
    -- the keyword patterns would grab a digit after a stray 'c'; the
    -- frontier anchor means only a word-initial C/Ch counts
    assert_eq(C.number("Official_Spell 7.cbz"), 7)
    assert_eq(C.number("Chainsaw Man 12.cbz"), 12)
end)

-- ── ordering ─────────────────────────────────────────────────────────────

test("less: numeric across scanlators (Official 72 < Unknown 73 < Official 100)", function()
    local names = { "Official_# 100.cbz", "Unknown_# 73.cbz", "Official_# 72.cbz", "Official_# 9.cbz" }
    table.sort(names, function(a, b) return C.less(a, b) end)
    assert_eq(table.concat(names, "|"),
        "Official_# 9.cbz|Official_# 72.cbz|Unknown_# 73.cbz|Official_# 100.cbz")
end)

test("less: unnumbered files sort last", function()
    local names = { "Extras.cbz", "Official_Day 2.cbz", "Official_Day 1.cbz" }
    table.sort(names, function(a, b) return C.less(a, b) end)
    assert_eq(names[3], "Extras.cbz")
end)

-- ── localName() ──────────────────────────────────────────────────────────

test("localName: Chapter family normalised like Maki, others untouched", function()
    assert_eq(C.localName("Official_Chapter 97.cbz"), "Chapter 0097.cbz")
    assert_eq(C.localName("Official_# 10.cbz"), "Official_# 10.cbz")
end)

-- ── resolveBook() ────────────────────────────────────────────────────────

local function book(id, file, num)
    return { id = id, url = "/manga/mangas/Weeb Central (EN)/S/" .. file,
             number = 1, metadata = { number = tostring(num), numberSort = num } }
end
local BOOKS = {
    book("A10", "Official_# 10.cbz", 10),
    book("A11", "Official_# 11.cbz", 11),
    book("B97", "Official_Chapter 97.cbz", 97),
}

test("resolveBook: ledger wins (exact id)", function()
    local fetched = { ["https://komga/opds/v1.2/books/A11/file/x.cbz"] = { file = "weird local name.cbz" } }
    local b, how = C.resolveBook("weird local name.cbz", BOOKS, fetched)
    assert_eq(b and b.id, "A11"); assert_eq(how, "ledger")
end)

test("resolveBook: stale ledger id not on server falls through", function()
    local fetched = { ["https://komga/opds/v1.2/books/GONE/file/x.cbz"] = { file = "Official_# 10.cbz" } }
    local b, how = C.resolveBook("Official_# 10.cbz", BOOKS, fetched)
    assert_eq(b and b.id, "A10"); assert_eq(how, "name")
end)

test("resolveBook: server name matches a Maki-normalised local file", function()
    local b, how = C.resolveBook("Chapter 0097.cbz", BOOKS, nil)
    assert_eq(b and b.id, "B97"); assert_eq(how, "name")
end)

test("resolveBook: number fallback", function()
    local b, how = C.resolveBook("ch 11 (renamed).cbz", BOOKS, {})
    assert_eq(b and b.id, "A11"); assert_eq(how, "number")
end)

test("resolveBook: JSON-null userdata metadata does not crash", function()
    local nullish = newproxy and newproxy() or {}
    local books = { { id = "X", url = "/a/b/Other.cbz", number = 3, metadata = nullish } }
    local b = C.resolveBook("Something 3.cbz", books, nil)
    assert_eq(b and b.id, "X")
end)

test("resolveBook: nothing matches → nil", function()
    assert_eq(C.resolveBook("Extras.cbz", BOOKS, {}), nil)
end)

print(string.format("tana_chapter: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
