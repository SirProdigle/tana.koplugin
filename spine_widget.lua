-- spine_widget.lua
-- One book's cover. Cover render path when book.cover_bb is present;
-- otherwise paper-tone fallback (Task 3.2 adds this).

local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ImageWidget    = require("ui/widget/imagewidget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local InputContainer = require("ui/widget/container/inputcontainer")

local SpineWidget = InputContainer:extend{
    book      = nil,    -- Book record
    width     = nil,    -- pixels
    height    = nil,    -- pixels
    on_tap    = nil,    -- function(book) — opens reader
    on_hold   = nil,    -- function(book) — long-press menu
}

function SpineWidget:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if self.book and self.book.has_cover and self.book.cover_bb then
        self[1] = self:_renderCover()
    else
        self[1] = self:_renderFallback()
    end
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function SpineWidget:_renderCover()
    return FrameContainer:new{
        bordersize = Size.border.thin,
        padding    = 0,
        ImageWidget:new{
            image  = self.book.cover_bb,
            width  = self.width,
            height = self.height,
            scale_factor = 0,  -- fit (preserves aspect, no upscale)
        },
    }
end

function SpineWidget:_renderFallback()
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local Font = require("ui/font")
    local Blitbuffer = require("ffi/blitbuffer")
    local pad = Size.padding.small

    local title = TextBoxWidget:new{
        text = self.book and self.book.title or "?",
        face = Font:getFace("infofont", 12),
        width = self.width - pad * 2,
        alignment = "center",
        bold = true,
    }
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local rule = FrameContainer:new{
        bordersize = 0,
        background = Blitbuffer.COLOR_BLACK,
        padding = 0,
        HorizontalSpan:new{ width = math.floor(self.width / 4) },
    }
    -- KOReader's TextBoxWidget doesn't support italic; render upright.
    -- Visually distinguishing the author line via italic is deferred to a
    -- future revision that loads an italic font face. v0.1 accepts the
    -- visual compromise.
    local author = TextBoxWidget:new{
        text = self.book and self.book.author or "",
        face = Font:getFace("infofont", 10),
        width = self.width - pad * 2,
        alignment = "center",
    }

    local stack = VerticalGroup:new{
        align = "center",
        title,
        rule,
        author,
    }

    -- Faint grey card so the "no cover" fallback reads as a tile against the
    -- white page. Blitbuffer.gray semantics: 0 = white, 1 = black.
    local paper = Blitbuffer.gray(0.07)

    return FrameContainer:new{
        bordersize    = Size.border.thin,
        padding_top    = pad * 2,
        padding_bottom = pad * 2,
        padding_left  = pad,
        padding_right = pad,
        background = paper,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            stack,
        },
    }
end

function SpineWidget:onTap()      if self.on_tap  then self.on_tap(self.book)  end; return true end
function SpineWidget:onHold()     if self.on_hold then self.on_hold(self.book) end; return true end

return SpineWidget
