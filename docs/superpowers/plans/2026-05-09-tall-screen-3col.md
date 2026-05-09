# Tall-Screen 3-Column Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On tall screens (width/height < 0.65) use 3 columns instead of 4, giving larger covers while keeping the same row counts (3×3 normal-tall, 4×3 expanded-tall).

**Architecture:** A new `_nCols()` helper returns 3 on tall screens, 4 on standard. `_pageSize()`/`_viewSize()` multiply by `_nCols()`. `_buildShelfRows` passes `n_slots = n_cols` into `ShelfRow.new`, which already supports a column override via `opts.n_slots`. One local (`n_cols`) defined early in `_rebuild` is reused by the BIM block below it — no redundant calls.

**Tech Stack:** Lua 5.1, KOReader widget framework. Tests run with `lua` binary, no KOReader runtime needed.

---

### Task 1: Add `_nCols()` + update `_pageSize`/`_viewSize` (TDD)

**Files:**
- Modify: `tests/_test_tall_screen.lua` (add 2 tests, update 3 expectations)
- Modify: `bookshelf_widget.lua` (new helper + updated methods)

- [ ] **Step 1: Update test file — add `_nCols` cases and fix tall expectations**

In `tests/_test_tall_screen.lua`, make these three edits:

**A.** Insert the `_nCols` block immediately before the `-- ── _pageSize tests` comment:

```lua
-- ── _nCols tests ───────────────────────────────────────────────────────────
test("_nCols: standard screen = 4", function()
    eq(bw(750, 1024):_nCols(), 4)
end)

test("_nCols: tall screen = 3", function()
    eq(bw(1080, 2400):_nCols(), 3)
end)

```

**B.** Replace the entire `_pageSize: tall screen` test (name string + body):

```lua
test("_pageSize: tall screen = 9 (regardless of expanded)", function()
    eq(bw(1080, 2400, false):_pageSize(), 9)
    eq(bw(1080, 2400, true):_pageSize(),  9)
end)
```

(The old test had the string `"_pageSize: tall screen = 12 ..."` — replace the whole `test(...)` call including its name.)

**C.** Replace the two tall `_viewSize` tests:

```lua
test("_viewSize: tall normal = 9", function()
    eq(bw(1080, 2400, false):_viewSize(), 9)
end)

test("_viewSize: tall expanded = 12", function()
    eq(bw(1080, 2400, true):_viewSize(), 12)
end)
```

- [ ] **Step 2: Run tests to confirm failures**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && lua tests/_test_tall_screen.lua
```

Expected: `_nCols` tests fail (method nil), tall `_pageSize` and `_viewSize` tests fail (wrong values). Standard tests still pass.

- [ ] **Step 3: Add `_nCols()` to `bookshelf_widget.lua`**

In `bookshelf_widget.lua`, find the block ending with `_nShelves`:

```lua
-- _nShelves() — shelf row count for the current mode and screen shape.
--   normal + standard → 2,  expanded + standard → 3
--   normal + tall     → 3,  expanded + tall     → 4
function BookshelfWidget:_nShelves()
    local base = self:_isTallScreen() and 3 or 2
    return self._expanded and base + 1 or base
end
```

Insert immediately after it (before the `-- _pageSize()` comment):

```lua
-- _nCols() — column count per shelf row. Tall screens use 3 for larger
-- covers; standard screens use 4.
function BookshelfWidget:_nCols()
    return self:_isTallScreen() and 3 or 4
end

```

- [ ] **Step 4: Update `_pageSize()` and `_viewSize()` in `bookshelf_widget.lua`**

Replace the current `_pageSize` block:

```lua
-- _pageSize() — page-advance step: non-expanded row count × 4. Constant
-- across the expand/collapse toggle so the first-visible book stays put —
-- the top rows are identical, toggling reveals one extra row at the bottom.
-- Standard screens: 8 (2×4). Tall screens: 12 (3×4).
function BookshelfWidget:_pageSize()
    return (self:_isTallScreen() and 3 or 2) * 4
end
```

With:

```lua
-- _pageSize() — page-advance step: non-expanded rows × cols. Constant
-- across the expand/collapse toggle so the first-visible book stays put —
-- the top rows are identical, toggling reveals one extra row at the bottom.
-- Standard: 8 (2×4). Tall: 9 (3×3).
function BookshelfWidget:_pageSize()
    return (self:_isTallScreen() and 3 or 2) * self:_nCols()
end
```

Replace the current `_viewSize` block:

```lua
-- _viewSize() — books shown per page: current row count × 4.
-- Standard normal: 8, standard expanded / tall normal: 12, tall expanded: 16.
-- Expanded pages overlap _pageSize by 4 books (one row) so paging forward
-- reveals one new row at the bottom while the top rows stay fixed.
function BookshelfWidget:_viewSize()
    return self:_nShelves() * 4
end
```

With:

```lua
-- _viewSize() — books shown per page: current rows × cols.
-- Standard normal: 8, standard expanded: 12, tall normal: 9, tall expanded: 12.
-- Expanded pages overlap _pageSize by one row so paging forward reveals
-- one new row at the bottom while the top rows stay fixed.
function BookshelfWidget:_viewSize()
    return self:_nShelves() * self:_nCols()
end
```

- [ ] **Step 5: Run tests to confirm all pass**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && lua tests/_test_tall_screen.lua
```

Expected: `17 passed, 0 failed`

- [ ] **Step 6: luac check**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && luac -p bookshelf_widget.lua && echo OK
```

Expected: `OK`

- [ ] **Step 7: Commit**

```bash
git add tests/_test_tall_screen.lua bookshelf_widget.lua
git commit -m "feat(layout): add _nCols helper; _pageSize/_viewSize use _nCols()"
```

---

### Task 2: Update `slot_w_natural` and `n_slots` hardcodes in `bookshelf_widget.lua`

**Files:**
- Modify: `bookshelf_widget.lua` (three locations)

- [ ] **Step 1: Replace `slot_w_natural` block (around line 461–466)**

Replace:

```lua
    -- Natural shelf row dimensions: 4 covers fill content_w with PAD gaps,
    -- preserving the 2:3 cover aspect ratio. Used in BOTH modes so cover
    -- size doesn't shift between expanded / collapsed — the hero is the
    -- only element that flexes. Pagination y stays fixed.
    local slot_w_natural = math.floor((content_w - PAD * 3) / 4)
    local slot_h_natural = math.floor(slot_w_natural * 1.5)
```

With:

```lua
    -- Natural shelf row dimensions: n_cols covers fill content_w with PAD
    -- gaps, preserving the 2:3 cover aspect ratio. Used in BOTH modes so
    -- cover size doesn't shift between expanded / collapsed — the hero is
    -- the only element that flexes. Pagination y stays fixed.
    local n_cols         = self:_nCols()
    local slot_w_natural = math.floor((content_w - PAD * (n_cols - 1)) / n_cols)
    local slot_h_natural = math.floor(slot_w_natural * 1.5)
```

- [ ] **Step 2: Remove `n_slots = 4` from the BIM extraction block (around line 825)**

The BIM block currently reads:

```lua
    local n_slots = 4
    local slot_w  = math.floor((content_w - PAD * (n_slots - 1)) / n_slots)
    local slot_h  = math.floor(slot_w * 1.5)
    self:_kickOffMissingMetaExtraction(items, slot_w, slot_h, hero_cover_w, hero_cover_h)
```

Replace with (reusing `n_cols` already in scope from Step 1 above):

```lua
    local slot_w  = math.floor((content_w - PAD * (n_cols - 1)) / n_cols)
    local slot_h  = math.floor(slot_w * 1.5)
    self:_kickOffMissingMetaExtraction(items, slot_w, slot_h, hero_cover_w, hero_cover_h)
```

- [ ] **Step 3: Update `n_slots = 4` in `_swapShelvesInPlace` fast-path (around line 1945)**

Replace:

```lua
    local n_slots = 4
    local slot_w  = math.floor((d.content_w - d.PAD * (n_slots - 1)) / n_slots)
```

With:

```lua
    local n_slots = self:_nCols()
    local slot_w  = math.floor((d.content_w - d.PAD * (n_slots - 1)) / n_slots)
```

Note: This fast-path only runs when `_nShelves() == 2` (standard non-expanded screens), so `_nCols()` returns 4 here — behaviour is unchanged. The update keeps the code consistent.

- [ ] **Step 4: luac check**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && luac -p bookshelf_widget.lua && echo OK
```

Expected: `OK`

- [ ] **Step 5: Run full test suite**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && lua tests/_test_tall_screen.lua && lua tests/_test_tokens.lua && lua tests/_test_book_repository.lua
```

Expected: `_test_tall_screen` 17 passed. Other suites same pass/fail counts as before this task.

- [ ] **Step 6: Commit**

```bash
git add bookshelf_widget.lua
git commit -m "feat(layout): use _nCols() for slot_w_natural and BIM extraction dims"
```

---

### Task 3: Thread `n_cols` through `_buildShelfRows` and `ShelfRow.new`

**Files:**
- Modify: `bookshelf_widget.lua` (`_buildShelfRows` body)
- Modify: `shelf_row.lua` (line 67)

- [ ] **Step 1: Update `ShelfRow.new` to read `n_slots` from opts**

In `shelf_row.lua`, replace line 67:

```lua
    local n_slots = 4
```

With:

```lua
    local n_slots = opts.n_slots or 4
```

No other changes to `shelf_row.lua`. The `opts.n_slots or 4` default keeps all existing callers that don't pass `n_slots` working correctly.

- [ ] **Step 2: Update `_buildShelfRows` in `bookshelf_widget.lua`**

Find the `_buildShelfRows` function body. The `row_opts` table starts with:

```lua
    local row_opts = {
        width             = content_w,
        height            = shelf_h,
        gap               = PAD,
        selected_filepath = selected_filepath,
```

And the item-slice loop reads:

```lua
        for i = 1, 4 do row_items[i] = items[(r - 1) * 4 + i] end
```

Make two changes:

**A.** Add `local n_cols = self:_nCols()` immediately before `local row_opts`, and add `n_slots = n_cols` to the `row_opts` table:

```lua
    local n_cols   = self:_nCols()
    local row_opts = {
        width             = content_w,
        height            = shelf_h,
        gap               = PAD,
        n_slots           = n_cols,
        selected_filepath = selected_filepath,
```

**B.** Replace the item-slice loop:

```lua
        for i = 1, n_cols do row_items[i] = items[(r - 1) * n_cols + i] end
```

- [ ] **Step 3: luac check both files**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && luac -p bookshelf_widget.lua && luac -p shelf_row.lua && echo OK
```

Expected: `OK`

- [ ] **Step 4: Run full test suite**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && lua tests/_test_tall_screen.lua && lua tests/_test_tokens.lua && lua tests/_test_book_repository.lua
```

Expected: `_test_tall_screen` 17 passed. Other suites unchanged.

- [ ] **Step 5: Commit**

```bash
git add bookshelf_widget.lua shelf_row.lua
git commit -m "feat(layout): 3 columns on tall screens via _nCols() in _buildShelfRows and ShelfRow"
```

---

### Task 4: Deploy and verify

- [ ] **Step 1: Push branch to remote**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && git push
```

- [ ] **Step 2: Deploy to Android/phone**

Transfer the two changed files to the device's KOReader plugin directory and restart KOReader. Verify:
- Normal mode: 3 columns × 3 rows of covers (9 books per page)
- North-swipe to expanded: 3 columns × 4 rows (top 3 rows identical to normal mode, one new row at bottom)
- South-swipe back: 3 columns × 3 rows, same books at top
- Page forward: 9 entirely new books

- [ ] **Step 3: Deploy to Kindle (standard screen check)**

```bash
cd /home/andyhazz/projects/bookshelf.koplugin && tar -czf - bookshelf_widget.lua shelf_row.lua | ssh kindle "tar -xzf - -C /mnt/us/koreader/plugins/bookshelf.koplugin/"
```

Then `ssh kindle "killall -TERM koreader"` and cold-launch. Verify standard layout is unchanged: 4 columns × 2 rows normal, 4 columns × 3 rows expanded.
