-- tana_series_mosaic.lua
-- A 2×2 mosaic-of-mini-covers widget for book-series slots. Used in place
-- of bookshelf_series_stack when the series has at least 2 books with
-- covers. Renders the same folder-card overlay + count badge so the
-- caller's down-stream code stays identical (tap/hold semantics, drill
-- behaviour, breadcrumb labelling).
--
-- Composition (z-order, bottom to top):
--   1. 2×2 grid of mini cover BBs (slot_w/2 × cell_h each)
--   2. FolderCard cardboard L (overlays bottom portion + tab carries name)
--   3. "×N" count badge in the top-right
--
-- Why not 4 small SpineWidgets: SpineWidget enforces its own card shadow,
-- border, and corner geometry; at half slot width those internals eat too
-- much of the cell. Direct ImageWidgets give us a clean half-cell-fills-
-- the-mini-cover render. Selection highlight is irrelevant on this widget
-- (no individual book is the "selected" one when a series is the entry).

local Blitbuffer      = require("ffi/blitbuffer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local ImageWidget     = require("ui/widget/imagewidget")
local TextWidget      = require("ui/widget/textwidget")
local Widget          = require("ui/widget/widget")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Size            = require("ui/size")
local Font            = require("ui/font")
local Screen          = require("device").screen
local FolderCard      = require("bookshelf_folder_card")
local ScaledCoverCache = require("bookshelf_scaled_cover_cache")

local CELL_GAP    = Screen:scaleBySize(3)
local CELL_BORDER = Screen:scaleBySize(1)
local CELL_RADIUS = Screen:scaleBySize(2)
local FALLBACK_BG = Blitbuffer.gray(0.85)

-- A solid rounded rectangle used as the per-cell placeholder when a book
-- has no cover_bb. Mid-paper grey reads as "missing artwork" without
-- pulling focus from the cells that DO have covers.
local Placeholder = Widget:extend{
    width  = nil,
    height = nil,
}
function Placeholder:init() self.dimen = Geom:new{ w = self.width, h = self.height } end
function Placeholder:paintTo(bb, x, y)
    bb:paintRoundedRect(x, y, self.width, self.height, FALLBACK_BG, CELL_RADIUS)
end

-- Build one mosaic cell: a cover image (or placeholder) at (cell_w, cell_h).
-- The cover bb is upscaled via the shared scaled-cover cache so a 2×2 page
-- of series cards doesn't re-scale on every paint.
local function _buildCell(book, cell_w, cell_h)
    if cell_w <= 0 or cell_h <= 0 then
        return Widget:new{ dimen = Geom:new{ w = math.max(cell_w, 1), h = math.max(cell_h, 1) } }
    end
    local cover_bb = book and book.cover_bb
    if not cover_bb then
        return Placeholder:new{ width = cell_w, height = cell_h }
    end
    -- Scaled bb: try cache first, else scale and cache.
    local scaled
    if book.filepath then
        scaled = ScaledCoverCache:get(book.filepath, cell_w, cell_h)
    end
    if not scaled then
        local ok, result = pcall(function()
            -- Centre-crop fill: most book covers are taller than the cell
            -- aspect; scaling-to-fill plus the rounded clip keeps the
            -- composition tight. bb:scale's default already does this.
            return cover_bb:scale(cell_w, cell_h)
        end)
        if ok and result then
            scaled = result
            if book.filepath then
                ScaledCoverCache:put(book.filepath, cell_w, cell_h, scaled)
            end
        end
    end
    if not scaled then
        return Placeholder:new{ width = cell_w, height = cell_h }
    end
    local img = ImageWidget:new{
        image             = scaled,
        image_disposable  = false,    -- cache owns this bb
        width             = cell_w,
        height            = cell_h,
    }
    return FrameContainer:new{
        bordersize   = CELL_BORDER,
        radius       = CELL_RADIUS,
        padding      = 0,
        margin       = 0,
        img,
    }
end

-- Compose a 2×2 grid wrapped in a FrameContainer sized to the slot.
-- Returns a single widget that paints the grid; caller stacks the folder
-- card + badge over it via OverlapGroup.
local function _buildMosaicLayer(books, slot_w, slot_h)
    -- Mosaic occupies the slot minus the SpineWidget shadow allocation,
    -- so it lines up with the folder card's anchor.
    local card_w = slot_w - FolderCard.SHADOW_OFFSET
    local card_h = slot_h - FolderCard.SHADOW_OFFSET
    local cell_w = math.floor((card_w - CELL_GAP) / 2)
    local cell_h = math.floor((card_h - CELL_GAP) / 2)

    local cells = {}
    for i = 1, 4 do cells[i] = _buildCell(books[i], cell_w, cell_h) end

    -- Layout via direct overlap_offset positioning so the grid lives in a
    -- single dimen-controlled FrameContainer (the OverlapGroup parent
    -- gives each child a slot-sized dimen so they can be positioned).
    local function pos(widget, dx, dy)
        widget.overlap_offset = { dx, dy }
        return widget
    end
    pos(cells[1], 0,                 0)
    pos(cells[2], cell_w + CELL_GAP, 0)
    pos(cells[3], 0,                 cell_h + CELL_GAP)
    pos(cells[4], cell_w + CELL_GAP, cell_h + CELL_GAP)

    return OverlapGroup:new{
        dimen = Geom:new{ w = slot_w, h = slot_h },
        cells[1], cells[2], cells[3], cells[4],
    }
end

-- ─── Widget ──────────────────────────────────────────────────────────────

local TanaSeriesMosaic = InputContainer:extend{
    series      = nil,     -- { series_name, books[] }  (same shape as SeriesStack)
    width       = nil,
    height      = nil,
    on_tap      = nil,
    on_hold     = nil,
    is_selected = false,   -- ignored; mosaic doesn't render a "selected" state
    count_override = nil,  -- overrides #books for the badge (used by manga)
}

function TanaSeriesMosaic:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local books = (self.series and self.series.books) or {}

    -- Pick up to 4 books by series_num, falling back to the original order
    -- when series_num isn't populated. We do NOT shuffle the caller's list
    -- in place.
    local picked = {}
    for i = 1, math.min(4, #books) do picked[i] = books[i] end

    local mosaic = _buildMosaicLayer(picked, self.width, self.height)

    local folder_widget, label_widget = FolderCard.build{
        width  = self.width,
        height = self.height,
        label  = self.series and self.series.series_name or "",
    }

    local children = { mosaic, folder_widget, label_widget }

    -- Count badge: matches bookshelf_series_stack.lua's badge for consistency.
    local count = self.count_override or self.series.count_override or #books
    if count and count > 0 then
        local badge = FrameContainer:new{
            bordersize     = Size.border.thin,
            background     = Blitbuffer.COLOR_WHITE,
            radius         = Screen:scaleBySize(3),
            padding_left   = Size.padding.default,
            padding_right  = Size.padding.default,
            padding_top    = Size.padding.small,
            padding_bottom = Size.padding.small,
            TextWidget:new{
                text = "\xc3\x97" .. tostring(count),
                face = Font:getFace("smallinfofont", 12),
                bold = true,
            }
        }
        local badge_w = badge:getSize().w
        local cover_right_x = self.width - FolderCard.SHADOW_OFFSET
        local badge_x = math.max(0, math.min(self.width - badge_w,
                                             cover_right_x - math.floor(badge_w / 2)))
        badge.overlap_offset = { badge_x, -FolderCard.SHADOW_OFFSET }
        children[#children + 1] = badge
    end

    children.dimen = self.dimen
    self[1] = OverlapGroup:new(children)
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function TanaSeriesMosaic:onTap()
    if self.on_tap then self.on_tap(self.series) end
    return true
end
function TanaSeriesMosaic:onHold()
    if self.on_hold then self.on_hold(self.series) end
    return true
end

return TanaSeriesMosaic
