-- tana_sync.lua
-- The one interface tana's UI talks to about reading-progress sync.
--
-- Manga sync (Komga) and book sync (booksync/kosync + Hardcover) grew as
-- separate stacks because their transports are genuinely different — but
-- the SURFACES tana builds on top (the sync-status rows, the long-press
-- clear/set actions) are the same shape for both. This module gives each
-- stack a small backend with a common capability set so the dialogs are
-- written once:
--
--   backend.kind            "manga" | "book"
--   backend.label           display name
--   backend:tracked()       is this item under sync at all?
--   backend:peek()          { label } summary of the continue point, or nil
--   backend:pending()       count of queued-but-unpushed local entries
--   backend:clearServer()   wipe server-side progress   → ok, why
--   backend:clearLocal()    wipe device-local traces    → n touched
--   backend.can_set_progress  then :fetchRange() → {current, max}, why
--                             and  :setProgress(n, cb) → result, why
--
-- What deliberately does NOT live here: the in-book "continue from
-- server" jump. For manga that is tana_komga_progress.continueFromServer
-- (chapter-file resolution + download); for books it is KOReader's stock
-- Progress-sync plugin, which pulls the server position when the file is
-- opened. Both already work; this layer only unifies what the shelf UI
-- shows and edits.

local M = {}

-- ── Manga backend (Komga via the Maki marker) ────────────────────────────

local MangaBackend = {}
MangaBackend.__index = MangaBackend
MangaBackend.kind = "manga"
MangaBackend.can_set_progress = true

function MangaBackend:tracked()
    return require("tana_komga_progress").hasMarker(self.coll_path)
end

function MangaBackend:peek()
    local Progress = require("tana_komga_progress")
    local l = Progress._findLocalContinue(self.coll_path)
    if not l then return nil end
    return {
        label = string.format("Ch %g/%g", l.num, l.total or 0),
        num   = l.num,
        total = l.total,
    }
end

function MangaBackend:pending()
    return #require("tana_komga_push").pendingFor(self.coll_path)
end

function MangaBackend:clearServer()
    return require("tana_komga_admin").clearServerProgress(self.coll_path)
end

function MangaBackend:clearLocal()
    return require("tana_komga_admin").clearLocalProgress(self.coll_path)
end

-- Current furthest-completed chapter + last chapter number, for the
-- set-progress spinner. Needs the network.
function MangaBackend:fetchRange()
    local books, why = require("tana_komga_admin").fetchSeries(self.coll_path)
    if not books or #books == 0 then return nil, why or "empty series" end
    -- Default the spinner to the furthest sensible "read up to" point:
    -- the last completed chapter, or one before an in-progress chapter
    -- (reading ch 97 now ⇒ "read up to 96"). 0 when the series is fresh.
    local current = 0
    for _, b in ipairs(books) do
        if b.completed then
            if b.num > current then current = b.num end
        elseif (b.page or 0) > 0 and b.num - 1 > current then
            current = b.num - 1
        end
    end
    return {
        current = math.max(0, math.floor(current)),
        max     = math.ceil(books[#books].num),
    }
end

function MangaBackend:setProgress(upto_num, progress_cb)
    return require("tana_komga_admin").setProgress(self.coll_path, upto_num, progress_cb)
end

-- ── Book backend (booksync server + Hardcover) ───────────────────────────

local BookBackend = {}
BookBackend.__index = BookBackend
BookBackend.kind = "book"
BookBackend.can_set_progress = false

function BookBackend:tracked()
    return require("tana_booksync").available()
        and require("tana_booksync").digestFor(self.filepath) ~= nil
end

function BookBackend:peek()
    local ok_repo, Repo = pcall(require, "bookshelf_book_repository")
    if not ok_repo then return nil end
    local pct = Repo.readProgress(self.filepath)
    if not pct or pct <= 0 then return nil end
    return { label = string.format("%d%%", math.floor(pct * 100 + 0.5)), pct = pct }
end

function BookBackend:pending()
    return 0 -- the kosync plugin pushes directly; it keeps no visible queue
end

function BookBackend:clearServer()
    local Booksync = require("tana_booksync")
    local digest = Booksync.digestFor(self.filepath)
    if not digest then return true end -- never synced: nothing to clear
    if Booksync.clearDocument(digest) then return true end
    return false, "server unreachable"
end

function BookBackend:clearLocal()
    local touched = 0
    pcall(function()
        local DocSettings = require("docsettings")
        if DocSettings:hasSidecarFile(self.filepath) then
            DocSettings:open(self.filepath):purge()
            touched = 1
        end
    end)
    pcall(function()
        require("readhistory"):removeItemByPath(self.filepath)
    end)
    return touched
end

-- ── Constructors ─────────────────────────────────────────────────────────

function M.manga(coll_path, label)
    return setmetatable({ coll_path = coll_path, label = label }, MangaBackend)
end

function M.book(filepath, label)
    return setmetatable({
        filepath = filepath,
        label = label or (filepath and filepath:match("([^/]+)$")),
    }, BookBackend)
end

return M
