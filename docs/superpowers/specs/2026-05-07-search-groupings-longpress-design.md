# Search Groupings + Long-Press Navigation — Design Spec

**Date:** 2026-05-07

## Overview

Two related improvements to search and book interaction:

1. Search results surface folder, author, series, and genre group tiles above individual book results, so searching an author name or folder name gives a one-tap shortcut to the right view.
2. Long-pressing any book opens a menu with options to navigate directly to that book's author, series, or genre grouping (when those tabs are enabled).

## Files Changed

- `book_repository.lua` — new `Repo.searchAll(query)` method
- `bookshelf_widget.lua` — extend `_fetchChipItems` (search mode) and `_openBookMenu`

No new files.

## `Repo.searchAll(query)`

Replaces the `Repo.searchBooks(query)` call in `_searchAndDrill`.

Returns:
```lua
{
    folders = { ... },   -- folder records: { kind="folder", path, label, first_book }
    authors = { ... },   -- author group records: { kind="author", series_name, books, latest }
    series  = { ... },   -- series group records: { kind="series", series_name, books, latest }
    genres  = { ... },   -- genre group records:  { kind="genre",  series_name, books, latest }
    books   = { ... },   -- Book records (existing searchBooks logic, unchanged)
}
```

All matching is case-insensitive substring (`query:lower()` vs `field:lower()`). Returns
`{ folders={}, authors={}, series={}, genres={}, books={} }` immediately if query is blank.

### Folder matching

Derives folders from `_books` (already in memory, no disk I/O):

1. One pass over all books, collecting unique parent-directory paths.
2. Filter: `basename(path):lower()` contains the lowercased query.
3. For each matching path, pick the first book in `_books` whose `filepath` starts with that
   path (no `findFirstBookIn` disk walk — first in-memory match is enough for the tile cover).
4. Return `{ kind="folder", path=path, label=basename(path), first_book=book }`.

### Author / series / genre matching

Each uses its existing cached getter, then filters in one pass:

```
authors: getAuthors()    → keep where series_name:lower() contains query
series:  getSeriesGroups() → keep where series_name:lower() contains query
genres:  getGenres()     → keep where series_name:lower() contains query
```

The getters are cached, so these are fast table iterations.

### Books

Existing `searchBooks(query)` logic, result assigned to `books` field unchanged.

### Stored payload shape

`_searchAndDrill` stores the drilldown entry as:
```lua
{ kind = "search", payload = { query = query, folders = {}, authors = {}, series = {}, genres = {}, books = {} } }
```
The old `payload.books`-only shape is replaced. `_fetchChipItems` reads all five fields.

## Search Results Display

`_fetchChipItems` in `kind == "search"` mode is extended to emit tiles in this order:

1. **Folder tiles** — only if home tab not in `disabled_set`
2. **Author group tiles** — only if `"author"` tab not in `disabled_set`
3. **Series group tiles** — only if `"series"` tab not in `disabled_set`
4. **Genre group tiles** — only if `"genre"` tab not in `disabled_set`
5. **Book tiles** — always shown

Each group tile renders as a `SeriesStack` tile, identical to those on the Authors/Series/Genre
tabs. Folder tiles render using the existing folder tile path (same as home tab).

Empty sections are silently omitted — no headings, no separators.

Pagination footer count reflects the total across all tile types.

### Tapping a result tile

- **Folder tile** — calls `_drillInto` with the folder record; shows the folder's books (same
  as tapping a folder on the home tab).
- **Group tile** — calls `_drillInto` with the group record; navigates into that author/series/
  genre view (same as tapping a group tile on its tab).
- **Book tile** — unchanged.

## Long-Press Navigation

`_openBookMenu` gains up to three new menu items, inserted before the existing "Cancel" entry.

Each item is only added when two conditions are both true:
- The book has the relevant metadata field populated.
- The corresponding tab is not in `disabled_set`.

| Item | Condition | Action |
|------|-----------|--------|
| "Go to Author: [name]" | `book.author` set, authors tab enabled | `getAuthors()` → find group where `series_name == book.author` → `_drillInto(group)` |
| "Go to Series" | `book.series` set, series tab enabled | `getSeriesGroups()` → find group where `series_name == book.series` → `_drillInto(group)` |
| "Go to Genre: [genre]" | `book.genres` non-empty, genres tab enabled | One item per genre, capped at 3. Each calls `getGenres()` → find group → `_drillInto(group)` |

If none of the three conditions are met the menu is identical to today — no empty section added.

The group lookup uses the cached getter results; no new Repo scan is triggered.

## Out of Scope

- Folder long-press navigation (folder is already the navigation destination, not a metadata
  attribute on a book in the same way author/series are).
- Fuzzy / ranked search ordering within each section.
- "Tag" groupings in search results (tags/collections are a separate tab; can be added later
  following the same pattern as genres).
