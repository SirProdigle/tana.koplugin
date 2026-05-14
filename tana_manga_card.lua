-- tana_manga_card.lua
-- Slot widget for a manga collection on the home / manga chips. Unlike a
-- regular book series (SeriesStack: cover + cardboard folder card + count
-- badge), a manga collection reads as a single entity — there's no "book
-- inside a folder" metaphor to communicate. The card here is just the
-- first chapter's cover with a bottom title bar and a small ×N badge in
-- the top-right.
--
-- Composition (z-order):
--   1. Full-slot SpineWidget for the cover (uses BIM thumbnail for the
--      first-chapter file as configured by tana_manga.buildCollectionShape)
--   2. Bottom title strip: solid black band, white text, single line with
--      ellipsis truncation. Sits OVER the bottom ~22% of the cover.
--   3. ×N badge in the top-right (matches SeriesStack convention)
--
-- The strip-on-cover approach lets the full cover artwork breathe at the
-- top while still calling out the series name. e-ink-friendly: pure
-- B&W contrast, no semi-transparent compositing.

local Blitbuffer     = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local TextWidget     = require("ui/widget/textwidget")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Screen         = require("device").screen
local SpineWidget    = require("bookshelf_spine_widget")

-- Drop-shadow shorthand: re-use the same allocation SpineWidget uses so
-- the title strip lines up with the cover's visible bounds (not the
-- slot's outer footprint, which includes the shadow band).
local SHADOW_OFFSET = Screen:scaleBySize(4)

local TanaMangaCard = InputContainer:extend{
    coll        = nil,    -- collection shape: { path, label, chapter_count, books, ... }
    width       = nil,
    height      = nil,
    on_tap      = nil,
    on_hold     = nil,
}

function TanaMangaCard:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }

    local books      = (self.coll and self.coll.books) or {}
    local cover_book = books[1]

    -- Cover layer — full slot, treats the collection's first chapter as
    -- the canonical "book" so SpineWidget's existing cover_fill +
    -- has_cover fallback paths render the chapter-1 thumbnail naturally.
    local cover_widget
    if cover_book then
        cover_widget = SpineWidget:new{
            book        = cover_book,
            width       = self.width,
            height      = self.height,
            cover_fill  = true,
            is_selected = false,
        }
    else
        cover_widget = SpineWidget:new{
            book        = { title = self.coll and self.coll.label or "" },
            width       = self.width,
            height      = self.height,
            is_selected = false,
        }
    end

    -- Title strip — black band over the bottom portion of the cover.
    -- Height tuned to fit one line at the chosen face plus comfortable
    -- vertical padding, with a hard cap so the cover stays readable on
    -- short slots (expanded mode / portrait at heavy font scales).
    local strip_face   = Font:getFace("infofont", 16)
    local strip_text_h = strip_face.size or 16
    local pad_v        = Size.padding.small
    local strip_h      = math.min(
        math.floor(self.height * 0.22),
        strip_text_h + pad_v * 2 + Screen:scaleBySize(4)
    )
    -- Visible cover width (excludes drop shadow allocation on the right /
    -- bottom). The strip aligns to that visible bounding box so it doesn't
    -- overhang the cover into the shadow band.
    local card_w = self.width  - SHADOW_OFFSET
    local card_h = self.height - SHADOW_OFFSET
    local strip_w = card_w
    local strip_x = 0
    local strip_y = card_h - strip_h

    local label = (self.coll and (self.coll.label or self.coll.series_name)) or ""

    local label_widget = TextBoxWidget:new{
        text                          = label,
        face                          = strip_face,
        bold                          = true,
        alpha                         = true,
        fgcolor                       = Blitbuffer.COLOR_WHITE,
        bgcolor                       = Blitbuffer.COLOR_BLACK,
        width                         = strip_w - Size.padding.default * 2,
        height                        = strip_text_h + Screen:scaleBySize(2),
        alignment                     = "center",
        height_overflow_show_ellipsis = true,
    }

    local strip = FrameContainer:new{
        background    = Blitbuffer.COLOR_BLACK,
        bordersize    = 0,
        margin        = 0,
        padding       = 0,
        padding_left  = Size.padding.default,
        padding_right = Size.padding.default,
        padding_top   = pad_v,
        padding_bottom = pad_v,
        dimen         = Geom:new{ w = strip_w, h = strip_h },
        label_widget,
    }
    strip.overlap_offset = { strip_x, strip_y }

    -- Count badge — top-right corner, mirrors bookshelf_series_stack so
    -- the visual language stays consistent across collection cards.
    local children = { cover_widget, strip }
    local count = (self.coll and self.coll.count_override)
                  or (self.coll and self.coll.chapter_count)
                  or 0
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
                text = "\xc3\x97" .. tostring(count),  -- × (UTF-8 U+00D7)
                face = Font:getFace("smallinfofont", 12),
                bold = true,
            }
        }
        local badge_w   = badge:getSize().w
        local cover_rt  = self.width - SHADOW_OFFSET
        local badge_x   = math.max(0, math.min(self.width - badge_w,
                                               cover_rt - math.floor(badge_w / 2)))
        badge.overlap_offset = { badge_x, -SHADOW_OFFSET }
        children[#children + 1] = badge
    end

    children.dimen = self.dimen
    self[1] = OverlapGroup:new(children)
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function TanaMangaCard:onTap()
    if self.on_tap then self.on_tap(self.coll) end
    return true
end

function TanaMangaCard:onHold()
    if self.on_hold then self.on_hold(self.coll) end
    return true
end

return TanaMangaCard
