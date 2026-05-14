# Tana 棚

A KOReader home-screen plugin — fork of [AndyHazz/bookshelf.koplugin](https://github.com/AndyHazz/bookshelf.koplugin), tracking upstream **as closely as possible** so fixes apply with `git merge`.

棚 (tana) is Japanese for "shelf".

## What's different from upstream

Almost nothing — that's the point.

- `_meta.lua`: `name = "tana"`, `fullname = "Tana"`. This is the only change KOReader's plugin loader sees, so the two plugins can be installed alongside each other (settings keys and most module names are shared, so they're effectively the same plugin with two faces — install only one in practice).
- `bookshelf_updater.lua`: GitHub release URLs and self-update paths point at this repo (`SirProdigle/tana.koplugin`) instead of upstream. User-Agent rebranded.
- This README.

The `bookshelf_*` internal module names, gettext strings, `G_reader_settings` keys, menu items, event names, and class identifiers are deliberately **unchanged** so cherry-picking from upstream is trivial.

## Why this fork exists

The maki + bussybox sync setup creates a `_MANGA/` folder structure where each series is a folder with many chapter files. Bookshelf walks `home_dir` for files and shows every chapter as a separate book. Tana is the place we'll layer manga-aware behavior (folder-as-entity rendering, resume-at-last-chapter on tap, `_`-prefix sort priority) without burdening AndyHazz with a niche use case.

Those features land here over time. Until they do, **Tana is feature-identical to upstream Bookshelf v1.1.2.**

## Tracking upstream

```bash
git fetch upstream
git merge upstream/master
# fix any conflicts (usually none) and push
```

The only files we modify outside the upstream tree are `_meta.lua`, `bookshelf_updater.lua`, and `README.md`. Upstream changes to those files will need a manual look; everything else merges clean.

## Install

Copy the contents of this repo into `<koreader>/plugins/tana.koplugin/`:

| Device | Path |
|--------|------|
| Kindle | `/mnt/us/koreader/plugins/tana.koplugin/` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/tana.koplugin/` |
| Desktop | `<koreader-dir>/plugins/tana.koplugin/` |

Restart KOReader, then enable under **Plugin management → Tana**.

If you currently have upstream Bookshelf installed, **uninstall it first** — both plugins share `G_reader_settings` keys and `menu_items` registrations, so running them simultaneously will produce undefined behavior.

## Credits

The entire codebase is [AndyHazz/bookshelf.koplugin](https://github.com/AndyHazz/bookshelf.koplugin) — AGPL-3.0. Every feature, every line of widget code, every locale file is upstream's work. This fork exists to add a thin layer of customisation; the upstream README is the source of truth for everything else.

## License

AGPL-3.0, inherited from upstream. See [LICENSE](LICENSE).
