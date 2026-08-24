-- tana_action_sheet.lua
-- The bottom sheet shown when the user taps a manga collection card. Lets
-- them resume the last-read chapter, start from the first chapter, drill
-- into the chapter list, or open the folder in the file browser.
--
-- All callbacks are wired by the caller (bookshelf_widget). The sheet
-- closes itself before invoking the callback so the action's own UI
-- (ReaderUI, the drill-in widget, FileManager) can take the screen
-- without overlapping.

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager    = require("ui/uimanager")
local _            = require("gettext")
local T            = require("ffi/util").template

local TanaActionSheet = {}

-- TanaActionSheet.show(opts)
-- opts:
--   title          string   — collection name + chapter count line
--   resume         table?   — { fp, label, pct, page, total } or nil
--   first_fp       string?  — first chapter filepath (for "Start from beginning")
--   coll_path      string   — folder path
--   on_open        function(fp)   — open a chapter file in the reader
--   on_browse      function(coll) — drill into the chapter list (Bookshelf)
--   on_filebrowser function(path) — close Tana, navigate FileManager here
function TanaActionSheet.show(opts)
    if not opts then return end

    local dialog
    local function closing(fn)
        return function()
            UIManager:close(dialog)
            if fn then fn() end
        end
    end

    local rows = {}

    -- Subtitle line: " · 255 chapters" appended to the title for context.
    -- Title is the only place to fit it — ButtonDialog has no subtitle slot.
    local title = opts.title or ""

    -- "Continue (Server) · Ch 97/169" — first row, for collections Maki
    -- manages (they carry a .maki.lua marker). The chapter is looked up
    -- BEFORE the sheet shows: one small JSON GET against Komga (short
    -- timeouts), so reading done on other devices (Kindle page-streaming)
    -- is offered by name. Offline or unreachable, it degrades to
    -- "Continue (Local)" from the freshest local position — which the push
    -- queue re-syncs to the server on the next network connection anyway.
    do
        local ok, TanaKomga = pcall(require, "tana_komga_progress")
        local peek
        if ok and TanaKomga.hasMarker(opts.coll_path) then
            peek = TanaKomga.peekContinue(opts.coll_path)
        end
        if peek then
            local callback
            if peek.kind == "server" then
                callback = closing(function()
                    TanaKomga.continueFromServer(opts.coll_path, opts.on_open, peek.target)
                end)
            else -- "local": the sidecar already holds the page
                callback = closing(function()
                    if opts.on_open then opts.on_open(peek.fp) end
                end)
            end
            rows[#rows + 1] = {
                { text = TanaKomga.peekLabel(peek), callback = callback },
            }
        end
    end

    if opts.first_fp then
        rows[#rows + 1] = {
            {
                text     = _("Start from beginning"),
                callback = closing(function()
                    if opts.on_open then opts.on_open(opts.first_fp) end
                end),
            },
        }
    end

    rows[#rows + 1] = {
        {
            text     = _("Browse chapters"),
            callback = closing(function()
                if opts.on_browse then opts.on_browse(opts.coll_path) end
            end),
        },
    }

    rows[#rows + 1] = {
        {
            text     = _("Open in file browser"),
            callback = closing(function()
                if opts.on_filebrowser then opts.on_filebrowser(opts.coll_path) end
            end),
        },
    }

    rows[#rows + 1] = {
        {
            text     = _("Cancel"),
            callback = closing(),
        },
    }

    dialog = ButtonDialog:new{
        title         = title,
        title_align   = "center",
        buttons       = rows,
        anchor        = function() return opts.anchor and opts.anchor() end,
    }
    UIManager:show(dialog)
    return dialog
end

-- Helper: format the title line a caller can use directly. Handles the
-- "X chapters" pluralisation. Kept here so the widget doesn't have to
-- duplicate the formatting.
function TanaActionSheet.formatTitle(name, chapter_count)
    if not name or name == "" then return "" end
    if not chapter_count or chapter_count == 0 then
        return name
    end
    local suffix
    if chapter_count == 1 then
        suffix = _("1 chapter")
    else
        suffix = T(_("%1 chapters"), tostring(chapter_count))
    end
    return name .. "  \xc2\xb7  " .. suffix
end

return TanaActionSheet
