-- bookshelf_cover_progress.lua
-- Pure decision logic for per-book progress indicators (bar + glyphs).
--
-- decide(book) maps a book's KOReader sidecar status + percent to a render
-- intent: whether to draw a top-edge progress bar, what fill ratio, and
-- which (if any) status glyph to overlay. Master toggle from
-- G_reader_settings["bookshelf_progress_enabled"].
--
-- Widget builders (buildBarWidget, buildGlyphWidget) live in this file
-- alongside the decision logic so SpineWidget has a single require to
-- pull in everything it needs.

local M = {}

-- Glyph code points (KOReader's bundled nerd font).
M.GLYPH_BOOKMARK       = "\u{e7bf}"  -- in-progress
M.GLYPH_BOOKMARK_CHECK = "\u{e7c0}"  -- finished

-- Read the master toggle. Default true (feature on) when unset.
local function _enabled()
    local v = G_reader_settings:readSetting("bookshelf_progress_enabled")
    if v == nil then return true end
    return v == true
end

-- Lazy reference to bookshelf_book_repository for the readProgress fallback
-- below. Required so chip paths that use the light book constructor
-- (buildBookMeta -> no DocSettings read) still get status/pct without the
-- expensive eager attachment.
local _Repo

-- Pure decision with a lazy filepath-based fallback for status/pct.
-- @param book table|nil with keys `status` (string|nil), `book_pct` (number|nil)
--             and optionally `filepath` (string|nil)
-- @return table { bar=bool, bar_pct=number, glyph="in_progress"|"complete"|nil }
function M.decide(book)
    local none = { bar = false, bar_pct = 0, glyph = nil }
    if not _enabled()  then return none end
    if not book        then return none end
    local status = book.status
    local pct    = book.book_pct
    -- Most shelf chips (getRecent, getLatest, getAll, ...) use the
    -- light book constructor and don't open DocSettings -- book.status
    -- arrives nil. Fall back to Repo.readProgress which is cached with
    -- TTL, so the per-cover cost is bounded.
    if status == nil and book.filepath then
        if not _Repo then _Repo = require("bookshelf_book_repository") end
        local p, s = _Repo.readProgress(book.filepath)
        pct    = pct or p
        status = s
    end
    if status == "reading" then
        return { bar = (pct ~= nil), bar_pct = pct or 0, glyph = "in_progress" }
    elseif status == "complete" then
        return { bar = false, bar_pct = 0, glyph = "complete" }
    elseif status == "abandoned" then
        return { bar = (pct ~= nil), bar_pct = pct or 0, glyph = "in_progress" }
    end
    -- status = "new" or nil: nothing.
    return none
end

-- ---------------------------------------------------------------------------
-- Widget: ProgressBarWidget
-- ---------------------------------------------------------------------------

local Widget         = require("ui/widget/widget")
local Geom           = require("ui/geometry")
local _BlitbufferBar = require("ffi/blitbuffer")
local _ScreenBar     = require("device").screen

local ProgressBarWidget = Widget:extend{
    width  = 0,
    height = 0,
    pct    = 0,        -- 0..1
    fill   = nil,      -- Blitbuffer colour
    track  = nil,      -- Blitbuffer colour
}

function ProgressBarWidget:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function ProgressBarWidget:paintTo(bb, x, y)
    -- Top border: a scaled-1dp dark line matching the card's own border
    -- thickness, so the bar reads as visually continuous with the cover
    -- frame. Using raw 1px here was invisible on the PW5 (~264 DPI);
    -- scaleBySize(1) returns ~2 raw px on that device.
    local border_h = math.max(1, _ScreenBar:scaleBySize(1))
    bb:paintRect(x, y, self.width, border_h, _BlitbufferBar.COLOR_BLACK)
    local body_y = y + border_h
    local body_h = self.height - border_h
    if body_h < 1 then return end
    local clamped = self.pct
    if clamped < 0 then clamped = 0 end
    if clamped > 1 then clamped = 1 end
    local fill_w  = math.floor(self.width * clamped + 0.5)
    local track_w = self.width - fill_w
    if fill_w > 0 then
        bb:paintRect(x, body_y, fill_w, body_h, self.fill)
    end
    if track_w > 0 then
        bb:paintRect(x + fill_w, body_y, track_w, body_h, self.track)
    end
end

-- Build a ProgressBarWidget. `fill` and `track` are Blitbuffer colour
-- objects (Color8 or ColorRGB32); callers resolve them via
-- bookshelf_colour.parseColorValue before calling here.
function M.buildBarWidget(width, height, pct, fill, track)
    return ProgressBarWidget:new{
        width  = width,
        height = height,
        pct    = pct,
        fill   = fill,
        track  = track,
    }
end

-- ---------------------------------------------------------------------------
-- Widget: GlyphWidget (status indicator)
-- ---------------------------------------------------------------------------

local TextWidget      = require("ui/widget/textwidget")
local Font            = require("ui/font")
local Blitbuffer      = require("ffi/blitbuffer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")

-- Build a single-glyph TextWidget for the in-progress / finished badges.
-- @param glyph_char  one of GLYPH_BOOKMARK / GLYPH_BOOKMARK_CHECK
-- @param size        target glyph height in pixels (already scaled)
-- @param colour      Blitbuffer colour (resolved via bookshelf_colour)
-- @return TextWidget
function M.buildGlyphWidget(glyph_char, size, colour)
    return TextWidget:new{
        text    = glyph_char,
        face    = Font:getFace("symbols", size),
        fgcolor = colour,
    }
end

-- BadgeBackdrop: solid white rounded rectangle painted behind a glyph
-- so hollow nerd-font shapes (like the bookmark-check, where the tick
-- is transparent) read cleanly against busy cover artwork.
local BadgeBackdrop = Widget:extend{
    width  = 0,
    height = 0,
    radius = 0,
}
function BadgeBackdrop:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function BadgeBackdrop:paintTo(bb, x, y)
    bb:paintRoundedRect(x, y, self.width, self.height,
                        Blitbuffer.COLOR_WHITE, self.radius)
end

-- Build a badged glyph: glyph centred on a white rounded backdrop.
-- Used for the 'completed' indicator. Returns a widget whose getSize
-- is the badge (slightly larger than the glyph).
function M.buildBadgedGlyphWidget(glyph_char, size, colour)
    local pad     = math.floor(size * 0.15 + 0.5)
    local badge_w = size + 2 * pad
    local badge_h = size + 2 * pad
    local radius  = math.floor(badge_w * 0.2 + 0.5)
    return OverlapGroup:new{
        dimen = Geom:new{ w = badge_w, h = badge_h },
        BadgeBackdrop:new{ width = badge_w, height = badge_h, radius = radius },
        CenterContainer:new{
            dimen = Geom:new{ w = badge_w, h = badge_h },
            M.buildGlyphWidget(glyph_char, size, colour),
        },
    }
end

-- ---------------------------------------------------------------------------
-- Resolved-settings accessor
-- ---------------------------------------------------------------------------

local Colour   = require("bookshelf_colour")
local Device   = require("device")

local DEFAULT_FILL  = { grey = 0x40 }
-- Track defaults to pure white so the bar stays clearly distinct from
-- the cover's drop shadow (mid-grey) on monochrome devices.
local DEFAULT_TRACK = { grey = 0xFF }

-- Returns colour values resolved to Blitbuffer objects for the current
-- screen mode. Called per cover paint; relies on bookshelf_colour's
-- internal hex cache to keep the work cheap.
function M.resolvedColours()
    local is_colour = Device.screen:isColorEnabled()
    local fill_raw  = G_reader_settings:readSetting("bookshelf_progress_fill")  or DEFAULT_FILL
    local track_raw = G_reader_settings:readSetting("bookshelf_progress_track") or DEFAULT_TRACK
    return {
        fill  = Colour.parseColorValue(fill_raw,  is_colour),
        track = Colour.parseColorValue(track_raw, is_colour),
    }
end

-- Returns the raw setting values (storage shape, not Blitbuffer). For the
-- settings menu's "currently set to..." label rendering.
function M.rawColours()
    return {
        fill  = G_reader_settings:readSetting("bookshelf_progress_fill")  or DEFAULT_FILL,
        track = G_reader_settings:readSetting("bookshelf_progress_track") or DEFAULT_TRACK,
        fill_default  = DEFAULT_FILL,
        track_default = DEFAULT_TRACK,
    }
end

return M
