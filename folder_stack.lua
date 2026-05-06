-- folder_stack.lua
-- Renders a folder-as-magazine-file: the first book inside the folder peeks
-- out the top of a manilla cardboard "magazine file" shape; the folder name
-- sits centred on the cardboard's front face. Drop-shadowed to match the
-- depth of regular spine widgets.
--
-- Visual composition (back-to-front):
--   1. Magazine drop shadow — the magazine's polygon shape filled in
--      shadow-grey at SHADOW_OFFSET down+right of the card. Visible as an
--      L-shaped halo on the right and bottom edges of the magazine, and a
--      thinner band tracing the slope on its underside.
--   2. First-book cover (rendered via SpineWidget) inset slightly inside
--      the card so the cardboard's side walls visually wrap the book.
--   3. Magazine front: a filled cardboard polygon with a sloped top edge.
--      The slope rises on the LEFT (high y on right, low y on left → the
--      slope drops as the eye moves rightward, matching the reference
--      photo's open-mouth orientation). Below the slope: cardboard fill
--      to the bottom edge.
--   4. Folder name centred horizontally and vertically on the cardboard
--      (TextBoxWidget with bgcolor = CARDBOARD so its rendering matches
--      the surrounding fill rather than knocking out a white rectangle).
--
-- All shapes paint into an OverlapGroup at slot dimen so the whole stack
-- has the same getSize() / tap zone as a regular SpineWidget — drop-in
-- replacement at the ShelfRow slot level.

local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local CenterContainer= require("ui/widget/container/centercontainer")
local TopContainer   = require("ui/widget/container/topcontainer")
local TextWidget     = require("ui/widget/textwidget")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local Widget         = require("ui/widget/widget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Blitbuffer     = require("ffi/blitbuffer")
local Screen         = require("device").screen
local SpineWidget    = require("spine_widget")

-- The magazine front is a triangle sitting on a rectangle (one
-- composite quadrilateral): a gentle slope across the TOP carries the
-- triangle "opening" of the file, and a full-width rectangle below
-- holds the folder label. Slope falls left-to-right (back wall on
-- LEFT, slightly shorter front wall on RIGHT).
--   y at x=0 is SLOPE_LEFT_FRAC·card_h
--   y at x=w-1 is SLOPE_RIGHT_FRAC·card_h
-- Below max(SLOPE_LEFT_FRAC, SLOPE_RIGHT_FRAC) the cardboard is
-- full-width — that's the "rectangle" where the label lives.
-- Magazine height reduced by ≈ 1/3 from the prior 0.50/0.60 so the
-- book peeks more prominently above the cardboard.
local SLOPE_LEFT_FRAC  = 0.67
local SLOPE_RIGHT_FRAC = 0.73

-- Cardboard colour and a darker outline. Dispatched on Screen:isColorEnabled
-- so colour devices (Kaleido panels, SDL desktop) get a real manilla cardboard
-- hue rather than reading the grey through their RGB filter as a desaturated
-- mush. On B&W e-ink the manilla degrades to grey via the ColorRGB→Color8
-- coercion; we set the grayscale value directly so dithering stays predictable
-- and we don't pay the colour-coerce cost on every paint.
-- Lightened from the previous gray(0.30) — user wanted the magazine to read
-- as cardboard rather than a dark slab when sitting next to bright covers.
local CARDBOARD, CARDBOARD_EDGE
if Screen.isColorEnabled and Screen:isColorEnabled() then
    -- Manilla cardboard. Edge is a deeper tan so the outline reads as a
    -- shadow-side fold rather than a separate stroke colour.
    CARDBOARD      = Blitbuffer.colorFromString("#e7c9a9")
    CARDBOARD_EDGE = Blitbuffer.colorFromString("#b8946b")
else
    CARDBOARD      = Blitbuffer.gray(0.20)
    CARDBOARD_EDGE = Blitbuffer.gray(0.55)
end
local PAGE_BG         = Blitbuffer.COLOR_WHITE

-- Drop-shadow geometry — must match SpineWidget so book and magazine spines
-- on the same shelf cast shadows the same depth. The previous folder render
-- skipped the shadow (the comment cited it making the shape look 1-D); user
-- now wants it back to align with the book-cover treatment.
local SHADOW_OFFSET   = Screen:scaleBySize(4)
local SHADOW_GRAY     = Blitbuffer.gray(0.5)

-- Border thickness — matches SpineWidget's CARD_BORDER (Screen:scaleBySize(1))
-- so book covers and magazine outlines on the same shelf have visually
-- equivalent stroke weight. Size.border.thin (the previous value) is a
-- non-scaled 1px and was visibly thinner than the books on hidpi displays.
local CARD_BORDER     = Screen:scaleBySize(1)

-- Bottom-corner rounding (matches SpineWidget's CARD_RADIUS so adjacent
-- magazine and book spines on the same shelf have consistent corner
-- treatment). The TOP corners are kept angular — they're slope/wall
-- junctions, sharp by design in a real magazine file.
local CARD_RADIUS = Screen:scaleBySize(4)

-- Book inset in absolute pixels. Just enough that a thin band of
-- cardboard wraps the book on each side and the top — the book "barely
-- fits inside" the file rather than shrinking visibly inside it.
local BOOK_INSET_X = Screen:scaleBySize(3)
local BOOK_INSET_Y = Screen:scaleBySize(2)

-- Painter for the magazine front: a quadrilateral with a sloped top
-- edge. The slope drops gently from (0, y_left) on the left to
-- (w-1, y_right) on the right (y_left < y_right ⇒ slope falls L→R).
-- Below max(y_left, y_right) the shape is full-width — the
-- "rectangle" portion that carries the folder label. Above the
-- slope, no fill (the book behind shows through). Bottom-left and
-- bottom-right corners are rounded at `radius`.
local MagazinePolygon = Widget:extend{
    width      = nil,
    height     = nil,
    y_left     = nil,    -- slope y at x=0
    y_right    = nil,    -- slope y at x=w-1
    fill_color = nil,
    edge_color = nil,
    radius     = 0,
}

function MagazinePolygon:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function MagazinePolygon:paintTo(bb, x, y)
    local w     = self.width
    local h     = self.height
    local yl    = self.y_left
    local yr    = self.y_right
    local fill  = self.fill_color
    local y_min = math.min(yl, yr)
    local y_max = math.max(yl, yr)
    -- Per-row fill. "Below the slope" is geometrically the side closer
    -- to the bottom of the slot — for slope falling L→R (yl < yr) that
    -- is the LEFT side of each slope-band row; for slope rising L→R
    -- (yl > yr) it's the RIGHT side. Below y_max the cardboard is full
    -- width (the rectangle portion); above y_min nothing paints.
    local fall_lr = (yl <= yr)
    for dy = 0, h - 1 do
        if dy >= y_max then
            bb:paintRect(x, y + dy, w, 1, fill)
        elseif dy >= y_min then
            local frac    = (dy - yl) / (yr - yl)
            local x_slope = math.floor((w - 1) * frac + 0.5)
            if x_slope < 0 then x_slope = 0 end
            if x_slope > w - 1 then x_slope = w - 1 end
            if fall_lr then
                -- Slope falls L→R: cardboard to the LEFT of x_slope.
                if x_slope > 0 then
                    bb:paintRect(x, y + dy, x_slope, 1, fill)
                end
            else
                -- Slope rises L→R: cardboard to the RIGHT of x_slope.
                if x_slope < w then
                    bb:paintRect(x + x_slope, y + dy, w - x_slope, 1, fill)
                end
            end
        end
    end
    -- Round bottom-left and bottom-right corners (page-bg knockout).
    local r    = self.radius or 0
    local r_sq = r * r
    if r > 0 then
        for i = 0, r - 1 do
            local dy = h - r + i
            local i_sq = (i + 1) * (i + 1)
            local cutoff = 0
            while cutoff < r and (r - cutoff) * (r - cutoff) + i_sq > r_sq do
                cutoff = cutoff + 1
            end
            if cutoff > 0 then
                bb:paintRect(x, y + dy, cutoff, 1, PAGE_BG)
                bb:paintRect(x + w - cutoff, y + dy, cutoff, 1, PAGE_BG)
            end
        end
    end
    if self.edge_color then
        local b    = CARD_BORDER
        local edge = self.edge_color
        bb:paintRect(x + r, y + h - b, w - 2 * r, b, edge)            -- bottom
        -- Side edges start where the slope MEETS each side, not at
        -- y_min — using y_min painted a stray strip from y_min up to
        -- yr on whichever side the slope was lower (visible as a thin
        -- black line extending past the polygon's actual outline).
        local right_h = h - yr - r
        if right_h > 0 then
            bb:paintRect(x + w - b, y + yr, b, right_h, edge)         -- right edge
        end
        local left_h = h - yl - r
        if left_h > 0 then
            bb:paintRect(x, y + yl, b, left_h, edge)                   -- left edge
        end
        -- Slope.
        local steps = math.max(w, math.abs(yr - yl))
        for s = 0, steps do
            local px = math.floor(s * (w - 1) / steps + 0.5)
            local py = math.floor(yl + (yr - yl) * s / steps + 0.5)
            bb:paintRect(x + px, y + py, b, b, edge)
        end
        if r > 0 then
            for i = 0, r - 1 do
                local dy = h - r + i
                local i_sq = (i + 1) * (i + 1)
                local cutoff = 0
                while cutoff < r and (r - cutoff) * (r - cutoff) + i_sq > r_sq do
                    cutoff = cutoff + 1
                end
                bb:paintRect(x + cutoff, y + dy, b, b, edge)
                bb:paintRect(x + w - cutoff - b, y + dy, b, b, edge)
            end
        end
    end
end

local FolderStack = InputContainer:extend{
    folder      = nil,    -- { path, label, first_book }
    width       = nil,
    height      = nil,
    on_tap      = nil,
    on_hold     = nil,
    is_selected = false,
}

function FolderStack:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    -- Reserve SHADOW_OFFSET pixels at right and bottom for the drop shadow
    -- (matches SpineWidget's allocation so books and magazines line up).
    local card_w = self.width  - SHADOW_OFFSET
    local card_h = self.height - SHADOW_OFFSET

    -- Slope endpoints in card-local coordinates.
    local y_left  = math.floor(card_h * SLOPE_LEFT_FRAC)
    local y_right = math.floor(card_h * SLOPE_RIGHT_FRAC)

    -- Book layer: SpineWidget for the first book, inset within the card
    -- by a few pixels on every side. The book's bottom extends to the
    -- card bottom and is hidden by the magazine's cardboard fill below
    -- the slope; only the top portion (above the slope) is visible.
    local book_w = card_w - BOOK_INSET_X * 2
    local book_h = card_h - BOOK_INSET_Y
    local book_widget
    if self.folder and self.folder.first_book then
        book_widget = SpineWidget:new{
            book        = self.folder.first_book,
            width       = book_w,
            height      = book_h,
            cover_fill  = true,
            is_selected = self.is_selected,
        }
    else
        -- Empty folder: SpineWidget's fallback path with the folder's
        -- label as the title so the "?" placeholder reads correctly.
        book_widget = SpineWidget:new{
            book        = { title = self.folder and self.folder.label or "" },
            width       = book_w,
            height      = book_h,
            is_selected = self.is_selected,
        }
    end
    local book_positioned = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_top   = BOOK_INSET_Y,
        padding_left  = BOOK_INSET_X,
        book_widget,
    }

    -- Magazine front: cardboard quadrilateral with a sloped top.
    local magazine = MagazinePolygon:new{
        width      = card_w,
        height     = card_h,
        y_left     = y_left,
        y_right    = y_right,
        fill_color = CARDBOARD,
        edge_color = CARDBOARD_EDGE,
        radius     = CARD_RADIUS,
    }

    -- Folder label: in the rectangle area below max(y_left, y_right)
    -- where the cardboard is full width. Left-aligned text, top-aligned
    -- vertically (renders flush against the rectangle's top edge with
    -- a generous interior padding). Probe-then-build pattern still
    -- caps the widget height at the available rectangle height so a
    -- long folder name truncates with "…" instead of overflowing.
    local label_text = self.folder and self.folder.label or ""
    label_text = label_text:gsub("/$", "")
    local label_pad     = Size.padding.large
    local label_top     = math.max(y_left, y_right) + label_pad
    local label_h_avail = card_h - label_top - label_pad
    local label_w_avail = card_w - label_pad * 2
    local face          = Font:getFace("infofont", 16)
    local probe = TextBoxWidget:new{
        text  = label_text,
        face  = face,
        bold  = true,
        width = label_w_avail,
    }
    local content_h = probe:getSize().h
    probe:free()
    local fits      = content_h <= label_h_avail
    local label_h   = fits and content_h or label_h_avail
    local label_widget = TextBoxWidget:new{
        text                          = label_text,
        face                          = face,
        bold                          = true,
        fgcolor                       = Blitbuffer.COLOR_BLACK,
        bgcolor                       = CARDBOARD,
        width                         = label_w_avail,
        alignment                     = "left",
        height                        = label_h,
        height_overflow_show_ellipsis = not fits,
    }
    -- Top-aligned: the label widget paints starting at label_top with
    -- label_pad of inset on the left. No CenterContainer — the
    -- FrameContainer padding directly positions the label at the top
    -- of the rectangle region.
    local label_positioned = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_top   = label_top,
        padding_left  = label_pad,
        label_widget,
    }

    -- Drop shadow: a magazine-shaped silhouette painted at SHADOW_OFFSET
    -- down+right of the card. We render it as the same MagazinePolygon
    -- shape (not a plain rect) so the shadow follows the slope rather
    -- than peeking out as a rectangular halo above the cardboard's open
    -- mouth — the book's own SpineWidget shadow handles the upper region.
    local shadow_polygon = MagazinePolygon:new{
        width      = card_w,
        height     = card_h,
        y_left     = y_left,
        y_right    = y_right,
        fill_color = SHADOW_GRAY,
        radius     = CARD_RADIUS,
    }
    local shadow_positioned = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = SHADOW_OFFSET,
        padding_left = SHADOW_OFFSET,
        shadow_polygon,
    }

    self[1] = OverlapGroup:new{
        dimen = self.dimen,
        shadow_positioned,     -- 0: drop shadow (back-most)
        book_positioned,       -- 1: book cover, inset within card
        magazine,              -- 2: cardboard front (covers book bottom)
        label_positioned,      -- 3: folder name centred on cardboard
    }
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function FolderStack:onTap()
    if self.on_tap then self.on_tap(self.folder) end
    return true
end
function FolderStack:onHold()
    if self.on_hold then self.on_hold(self.folder) end
    return true
end

return FolderStack
