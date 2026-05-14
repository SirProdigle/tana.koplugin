# Tana 棚

A KOReader home-screen plugin for libraries that mix books and **sideloaded manga**. Tana is a fork of [AndyHazz/bookshelf.koplugin](https://github.com/AndyHazz/bookshelf.koplugin) tuned for the maki + bussybox sync layout where each manga series lives in its own folder with hundreds of `.cbz` chapter files.

棚 (tana) is Japanese for "shelf".

## What Tana adds on top of Bookshelf

- **Manga chip.** A dedicated tab next to Recent / Latest / Series. Lists every manga series as a single collection card — not 200 chapter files.
- **Chapter folding.** Individual chapter files vanish from Recent / Latest / All listings; only the collection card surfaces. Opening Chapter 97 makes the collection's card jump to the top of Recent, not the bare chapter file.
- **Resume action sheet.** Tap a manga collection → bottom sheet with **Continue Ch. 97 · p9 / 22** (history-driven), **Start from beginning**, **Browse chapters**, and **Open in file browser**.
- **2×2 cover mosaic for book series.** Series like ASOIAF or Discworld render with a quad of mini covers behind the cardboard folder card, instead of one cover. Tap drills into the book list like upstream.
- **Path-driven manga detection.** Configure `tana_manga_roots` (default `["_MANGA"]`); any direct subfolder of a root becomes a collection card. Nothing else needs metadata — no Calibre tags, no kosync, no server side state.

The rest is upstream Bookshelf: chip strip, drill-down breadcrumbs, hero card, the search dialog, the chip-sort menus, cover-progress indicators, hero region templates — all the same.

## What changed vs. upstream

| File | Why |
|---|---|
| `_meta.lua` | name=tana, fullname=Tana, version 1.2.0-tana.0 |
| `bookshelf_book_repository.lua` | Manga injection into `getAll` shapes, chapter filter in `getLatest`, collection-fold in `getRecent`, new `getMangaCollections`, 4-cover hydration in `hydrateSeriesShape` for the mosaic |
| `bookshelf_widget.lua` | New `manga` chip in CHIP_ORDER, `_openManga` action-sheet handler, `_openInFileBrowser` helper, sort menu / refresh hooks for the chip |
| `bookshelf_shelf_row.lua` | `kind = "manga"` slot routing; series with ≥2 covers render via `TanaSeriesMosaic` |
| `bookshelf_series_stack.lua` | Honours `series.count_override` for the badge so manga collections show `×255` instead of `×1` |
| `bookshelf_settings.lua` | New "Manga collections" submenu (root editor + hide-chapters toggle); Manga chip added to the Edit shelf tabs list |
| `bookshelf_updater.lua` | GitHub release URLs point at `SirProdigle/tana.koplugin` |
| `tana_manga.lua` (new) | Path predicates, chapter enumeration, resume lookup |
| `tana_action_sheet.lua` (new) | Manga tap sheet |
| `tana_series_mosaic.lua` (new) | 2×2 mosaic widget |

Everything else (module names, `G_reader_settings` keys, gettext strings, event names) stays byte-identical to upstream. Cherry-picking an upstream fix into Tana is a small per-file conflict on the files above; everything outside that list merges clean.

## Why this is a hard fork

We previously tried to keep Tana as a minimum-difference fork ("name change only") so `git merge upstream/master` would just work. That dropped the moment manga awareness landed — the new behaviour touches the repository, the widget, the shelf row, and the settings tree. Upstream's design isn't built for it, and asking AndyHazz to take on a niche use case isn't fair to the project. So:

- We **don't** rename `bookshelf_*` modules. Cherry-picking upstream changes is still mechanical (find the same file, eyeball the diff). The internal name stays Bookshelf so we don't fight the library on every conflict.
- We **don't** run alongside upstream Bookshelf. Both register the same menu items and write to the same settings keys; **uninstall upstream first**.

## Install

```
<koreader>/plugins/tana.koplugin/      ← this repo
```

| Device | Path |
|--------|------|
| Kindle | `/mnt/us/koreader/plugins/tana.koplugin/` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/tana.koplugin/` |
| Desktop | `<koreader-dir>/plugins/tana.koplugin/` |

If upstream Bookshelf is installed, delete `<koreader>/plugins/bookshelf.koplugin/` first — both register the same module names and menu hooks, and KOReader's plugin loader will pick one nondeterministically.

Restart KOReader, enable **Tana** under Plugin management, then set the home screen via Settings → Start with → Tana so it loads on launch.

## Configuration

- **File manager → ... → Bookshelf settings → Manga collections → Edit manga roots.** One path per line. Relative paths resolve under `home_dir`; absolute paths start with `/`. Default: `_MANGA`.
- **Manga collections → Hide chapter files in listings.** On by default; flip off only when diagnosing why a chapter file isn't behaving.

## Tracking upstream

```bash
git fetch upstream
git diff upstream/master -- _meta.lua bookshelf_book_repository.lua \
    bookshelf_widget.lua bookshelf_shelf_row.lua bookshelf_series_stack.lua \
    bookshelf_settings.lua bookshelf_updater.lua
git checkout upstream/master -- <files we did NOT touch>
```

The files in the table above are the only ones with hand-tended Tana code. Everything else can be lifted from upstream wholesale.

## Credits

The non-manga rendering paths, hero card, chip strip, cover progress, settings tree, and i18n machinery are all [AndyHazz/bookshelf.koplugin](https://github.com/AndyHazz/bookshelf.koplugin) (AGPL-3.0). Tana wraps that with a manga awareness layer; the rest is upstream's work.

## License

AGPL-3.0, inherited from upstream. See [LICENSE](LICENSE).
