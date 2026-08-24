-- tana_sync_status.lua
-- "Sync status" overview, reached from the bookshelf gear menu. One
-- popout Menu with two sections:
--
--   Manga (Komga)  — every Maki-tracked collection: the furthest local
--                    position (queue-freshest, same source as the action
--                    sheet's Continue peek) and how many page-turn entries
--                    are still queued for the server. Tapping a row opens
--                    the same set/clear dialog as long-pressing its card.
--   Books          — everything the booksync server knows: percent, which
--                    device last touched it, and what Hardcover entry it
--                    auto-matched to (so a wrong match is visible).
--                    Local in-progress books that haven't reached the
--                    server yet are listed from reading history below.
--
-- Everything renders from local state plus ONE quick /status call — no
-- per-series network fetches, so the view opens fast even offline.

local UIManager = require("ui/uimanager")
local _         = require("gettext")

local TanaSyncStatus = {}

local function fmtNum(n)
    n = tonumber(n)
    return n and string.format("%g", n) or "?"
end

local function agoLabel(ts)
    if not ts then return "" end
    local d = os.time() - ts
    if d < 90 then return _("just now") end
    if d < 5400 then return string.format(_("%dm ago"), math.floor(d / 60)) end
    if d < 129600 then return string.format(_("%dh ago"), math.floor(d / 3600)) end
    return string.format(_("%dd ago"), math.floor(d / 86400))
end

local function header(text)
    return { text = "\xe2\x94\x80\xe2\x94\x80 " .. text .. " \xe2\x94\x80\xe2\x94\x80",
             bold = true, select_enabled = false }
end

function TanaSyncStatus:show(bw)
    local Screen     = require("device").screen
    local Menu       = require("ui/widget/menu")
    local TanaManga  = require("tana_manga")
    local TanaKomga  = require("tana_komga_progress")
    local TanaPush   = require("tana_komga_push")
    local Booksync   = require("tana_booksync")

    local items = {}

    -- ── Manga ────────────────────────────────────────────────────────────
    local colls = TanaManga.listCollections()
    local tracked = {}
    for _, c in ipairs(colls) do
        if TanaKomga.hasMarker(c.path) then tracked[#tracked + 1] = c end
    end
    if #tracked > 0 then
        items[#items + 1] = header(_("Manga · Komga"))
        for _, c in ipairs(tracked) do
            local l = TanaKomga._findLocalContinue(c.path)
            local pending = #TanaPush.pendingFor(c.path)
            local state
            if l then
                state = string.format(_("Ch %s/%s"), fmtNum(l.num), fmtNum(l.total))
            else
                state = _("not started")
            end
            if pending > 0 then
                state = state .. string.format(_(" · %d queued"), pending)
            end
            local coll = c
            items[#items + 1] = {
                text      = c.label,
                mandatory = state,
                callback  = function()
                    if self.menu then UIManager:close(self.menu) end
                    if bw and bw._openMangaMenu then
                        bw:_openMangaMenu({ path = coll.path, label = coll.label })
                    end
                end,
            }
        end
    end

    -- ── Books ────────────────────────────────────────────────────────────
    items[#items + 1] = header(_("Books"))
    local server_books = Booksync.available() and Booksync.getStatus(true) or nil
    local on_server = {}
    if server_books then
        for _, b in ipairs(server_books) do
            on_server[b.document] = true
            local pct = b.percentage and math.floor(b.percentage * 100 + 0.5) or 0
            local hc = type(b.hardcover) == "table" and b.hardcover or nil
            local mark = ""
            if hc then
                mark = hc.error and " \xc2\xb7 HC!" or (hc.matched_title and " \xc2\xb7 HC\xe2\x9c\x93" or "")
            end
            local entry = b
            items[#items + 1] = {
                text      = b.title or b.filename or b.document,
                mandatory = string.format("%d%%%s", pct, mark),
                callback  = function() self:_bookDetail(bw, entry) end,
            }
        end
        if #server_books == 0 then
            items[#items + 1] = { text = _("Nothing synced yet"), select_enabled = false, dim = true }
        end
    else
        items[#items + 1] = {
            text = Booksync.available()
                and _("Sync server unreachable (Wi-Fi?)")
                or _("Progress sync not configured"),
            select_enabled = false, dim = true,
        }
    end

    -- Local in-progress books the server hasn't seen (or while offline).
    local ok_rh, ReadHistory = pcall(require, "readhistory")
    local ok_repo, Repo = pcall(require, "bookshelf_book_repository")
    if ok_rh and ok_repo and type(ReadHistory.hist) == "table" then
        local shown = 0
        for _, h in ipairs(ReadHistory.hist) do
            if shown >= 15 then break end
            local fp = h.file
            if fp and not TanaManga.isChapterFile(fp) then
                local digest = Booksync.digestFor(fp)
                if not (digest and on_server[digest]) then
                    local pct, status = Repo.readProgress(fp)
                    if pct and pct > 0 and status ~= "complete" then
                        local book_fp = fp
                        items[#items + 1] = {
                            text      = fp:match("([^/]+)$"),
                            mandatory = string.format(_("local %d%%"),
                                            math.floor(pct * 100 + 0.5)),
                            callback  = function()
                                if self.menu then UIManager:close(self.menu) end
                                if bw and bw._openBookMenu then
                                    bw:_openBookMenu(Repo.buildBook(book_fp))
                                end
                            end,
                        }
                        shown = shown + 1
                    end
                end
            end
        end
    end

    local menu_w = math.floor(Screen:getWidth()  * 0.9)
    local menu_h = math.floor(Screen:getHeight() * 0.8)
    self.menu = Menu:new{
        title      = _("Sync status"),
        item_table = items,
        is_popout  = true,
        width      = menu_w,
        height     = menu_h,
    }
    local x = math.floor((Screen:getWidth()  - menu_w) / 2)
    local y = math.floor((Screen:getHeight() - menu_h) / 2)
    UIManager:show(self.menu, nil, nil, x, y)
end

-- Detail dialog for one server-synced book: full Hardcover match info and
-- the "forget this book" action (device + server + Hardcover).
function TanaSyncStatus:_bookDetail(bw, b)
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox   = require("ui/widget/confirmbox")
    local InfoMessage  = require("ui/widget/infomessage")
    local Booksync     = require("tana_booksync")

    local pct = b.percentage and math.floor(b.percentage * 100 + 0.5) or 0
    local lines = {
        string.format(_("%d%% · %s · %s"), pct, b.device or "?", agoLabel(b.timestamp)),
    }
    local hc = type(b.hardcover) == "table" and b.hardcover or nil
    lines[#lines + 1] = Booksync.hardcoverLabel(hc) or _("Hardcover: not matched yet")

    local dialog
    local function closing(fn)
        return function()
            UIManager:close(dialog)
            if fn then fn() end
        end
    end
    dialog = ButtonDialog:new{
        title = (b.title or b.filename or b.document) .. "\n" .. table.concat(lines, "\n"),
        title_align = "center",
        buttons = {
            {
                { text = _("Clear synced progress\xe2\x80\xa6"),
                  callback = closing(function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Forget this book's synced progress?\n\nRemoves it from the sync server and undoes its Hardcover entry. Local reading position on each device is kept."),
                        ok_text = _("Clear"),
                        ok_callback = function()
                            local ok = Booksync.clearDocument(b.document)
                            UIManager:show(InfoMessage:new{
                                text = ok and _("Synced progress cleared.")
                                    or _("Could not reach the sync server."),
                                timeout = 3,
                            })
                        end,
                    })
                  end) },
            },
            { { text = _("Close"), callback = closing() } },
        },
    }
    UIManager:show(dialog)
end

return TanaSyncStatus
