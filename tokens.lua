-- tokens.lua
-- Homescreen-scoped token expander. Bookends-compatible syntax, scoped
-- vocabulary tied to homescreen-available data sources.

local Tokens = {}

-- Token registry: name → function(book, state) → string
Tokens.expanders = {}

local function metaToken(field)
    return function(book) return book and book[field] or "" end
end

Tokens.expanders.title       = metaToken("title")
Tokens.expanders.author      = metaToken("author")
Tokens.expanders.author_2    = function(book)
    return book and book.authors and book.authors[2] or ""
end
Tokens.expanders.authors     = function(book)
    if not book or not book.authors then return "" end
    return table.concat(book.authors, ", ")
end
Tokens.expanders.series      = metaToken("series")
Tokens.expanders.series_name = metaToken("series_name")
Tokens.expanders.series_num  = metaToken("series_num")
Tokens.expanders.filename    = metaToken("filename")
Tokens.expanders.lang        = metaToken("lang")
Tokens.expanders.format      = metaToken("format")

local function pct(v) return string.format("%d%%", math.floor((v or 0) * 100 + 0.5)) end

Tokens.expanders.page_num   = function(b) return b and b.page_num and tostring(b.page_num) or "" end
Tokens.expanders.page_count = function(b) return b and b.page_count and tostring(b.page_count) or "" end
Tokens.expanders.book_pct       = function(b) return b and b.book_pct and pct(b.book_pct) or "" end
Tokens.expanders.book_pct_left  = function(b) return b and b.book_pct and pct(1 - b.book_pct) or "" end
Tokens.expanders.pages_left     = function(b)
    if not b or not b.page_num or not b.page_count then return "" end
    return tostring(b.page_count - b.page_num)
end

local function timeNow(state)
    return (state and state.now) or os.time()
end
local function fmt(spec, state) return os.date(spec, timeNow(state)) end

Tokens.expanders.time     = function(_b, s) return fmt("%H:%M", s) end
Tokens.expanders.time_24h = function(_b, s) return fmt("%H:%M", s) end
Tokens.expanders.time_12h = function(_b, s)
    local t = fmt("%I:%M %p", s)
    return (t:gsub("^0", ""))
end
Tokens.expanders.date          = function(_b, s) return fmt("%d %b", s):gsub("^0", "") end
Tokens.expanders.date_long     = function(_b, s) return fmt("%d %B %Y", s):gsub("^0", "") end
Tokens.expanders.date_numeric  = function(_b, s) return fmt("%d/%m/%Y", s) end
Tokens.expanders.weekday       = function(_b, s) return fmt("%A", s) end
Tokens.expanders.weekday_short = function(_b, s) return fmt("%a", s) end

local function minutesToHM(m)
    if not m or m <= 0 then return "" end
    local h = math.floor(m / 60); local mm = m % 60
    return string.format("%dh %02dm", h, mm)
end

Tokens.expanders.book_time_left   = function(b) return minutesToHM(b and b.book_time_left_minutes) end
Tokens.expanders.book_read_time   = function(b)
    return b and b.book_read_time_seconds and minutesToHM(math.floor(b.book_read_time_seconds / 60)) or ""
end
Tokens.expanders.pages_today      = function(_b, s) return s and s.pages_today and tostring(s.pages_today) or "" end
Tokens.expanders.time_today       = function(_b, s) return minutesToHM(s and s.time_today_minutes) end
Tokens.expanders.speed            = function(b) return b and b.speed_pph and tostring(b.speed_pph) or "" end
Tokens.expanders.avg_page_time    = function(b)
    if not b or not b.avg_page_time_seconds then return "" end
    local s = b.avg_page_time_seconds
    if s < 60 then return string.format("%ds", s) end
    return string.format("%dm %02ds", math.floor(s / 60), s % 60)
end
Tokens.expanders.book_pages_read    = function(b) return b and b.book_pages_read and tostring(b.book_pages_read) or "" end
Tokens.expanders.days_reading_book  = function(b) return b and b.days_reading_book and tostring(b.days_reading_book) or "" end
Tokens.expanders.pages_per_day      = function(b) return b and b.pages_per_day and tostring(b.pages_per_day) or "" end

Tokens.expanders.highlights   = function(b) return b and b.highlights and tostring(b.highlights) or "" end
Tokens.expanders.notes        = function(b) return b and b.notes and tostring(b.notes) or "" end
Tokens.expanders.bookmarks    = function(b) return b and b.bookmarks and tostring(b.bookmarks) or "" end
Tokens.expanders.annotations  = function(b)
    if not b then return "" end
    local total = (b.highlights or 0) + (b.notes or 0) + (b.bookmarks or 0)
    return total > 0 and tostring(total) or ""
end

Tokens.expanders.batt      = function(_b, s) return s and s.batt and (tostring(s.batt) .. "%") or "" end
Tokens.expanders.batt_icon = function(_b, s)
    if not s or not s.batt then return "" end
    if s.charging then return "⚡" end
    if s.batt < 20 then return "🪫" end
    return "🔋"
end
Tokens.expanders.wifi  = function(_b, s) return s and s.wifi == "on" and "📶" or "" end
Tokens.expanders.light = function(_b, s) return s and s.light or "" end
Tokens.expanders.warmth= function(_b, s) return s and s.warmth and tostring(s.warmth) or "" end
Tokens.expanders.mem   = function(_b, s) return s and s.mem and (tostring(s.mem) .. "%") or "" end
Tokens.expanders.ram   = function(_b, s) return s and s.ram_mib and (tostring(s.ram_mib) .. " MiB") or "" end
Tokens.expanders.disk  = function(_b, s) return s and s.disk_free or "" end

-- Bar: book-progress bar. The hero card has a dedicated ProgressWidget
-- separate from token lines in v0.1, so %bar inline expands to empty.
-- A future version may render an inline progress glyph here, matching
-- bookends' `%bar` semantics.
Tokens.expanders.bar = function() return "" end

-- ─── Conditional evaluator ──────────────────────────────────────────────────
-- Recognises [if:cond]…[else]…[/if]. Cond grammar:
--   atom    := [not] (token | token op value)
--   value   := number | "double-quoted string"
--   op      := = | != | < | > | <= | >=
--   expr    := atom (and|or atom)*
-- Strings vs numbers: numeric tokens compare numerically; string tokens
-- compare by string equality. Missing tokens compare as empty/zero.

local function valueForCondition(name, book, state)
    -- Single source of truth for if-condition values. Falls through to
    -- expanders so e.g. "book_pct" in a condition matches %book_pct token.
    local exp = Tokens.expanders[name]
    if not exp then return nil end
    local v = exp(book, state)
    if v == nil or v == "" then return nil end
    return v
end

local function asNumber(s)
    if type(s) == "number" then return s end
    if type(s) ~= "string" then return nil end
    local n = tonumber(s)
    if n then return n end
    -- Strip trailing %, try again.
    return tonumber((s:gsub("%%$", "")))
end

local function evaluateAtom(atom, book, state)
    local negate, body = atom:match("^%s*(not)%s+(.+)$")
    if not negate then body = atom end
    local v = valueForCondition(body:match("^%s*([%w_]+)") or "", book, state)
    -- token op value form
    local name, op, raw = body:match('^%s*([%w_]+)%s*([=<>!]+)%s*(.+)%s*$')
    if name and op then
        local lhs = valueForCondition(name, book, state)
        local quoted = raw:match('^"(.-)"$')
        local rhs = quoted or raw
        local result
        if op == "=" then
            result = (tostring(lhs or "") == tostring(rhs))
        elseif op == "!=" then
            result = (tostring(lhs or "") ~= tostring(rhs))
        else
            local lhs_n, rhs_n = asNumber(lhs) or 0, asNumber(rhs) or 0
            if op == "<"  then result = lhs_n <  rhs_n
            elseif op == ">"  then result = lhs_n >  rhs_n
            elseif op == "<=" then result = lhs_n <= rhs_n
            elseif op == ">=" then result = lhs_n >= rhs_n
            end
        end
        if result == nil then result = false end
        if negate then result = not result end
        return result
    end
    -- token-truthy form
    local truthy = (v ~= nil and v ~= "" and v ~= "0" and v ~= 0)
    if negate then truthy = not truthy end
    return truthy
end

local function evaluateExpr(expr, book, state)
    -- Split on `and`/`or`, left-to-right (no precedence: keep it boring).
    local parts, ops = {}, {}
    local pos = 1
    while true do
        -- find next operator: leftmost of and/or, by position
        local sa, ea = expr:find("%s+and%s+", pos)
        local so, eo = expr:find("%s+or%s+",  pos)
        local s, e, op
        if sa and (not so or sa <= so) then
            s, e, op = sa, ea, "and"
        elseif so then
            s, e, op = so, eo, "or"
        end
        if not s then parts[#parts + 1] = expr:sub(pos); break end
        parts[#parts + 1] = expr:sub(pos, s - 1)
        ops[#ops + 1] = op
        pos = e + 1
    end
    local result = evaluateAtom(parts[1], book, state)
    for i, op in ipairs(ops) do
        local r = evaluateAtom(parts[i + 1], book, state)
        if op == "and" then result = result and r else result = result or r end
    end
    return result
end

local function expandConditionals(format, book, state)
    -- Iteratively peel innermost [if:…]…[/if] blocks until none remain.
    -- This handles arbitrary nesting without a real parser by always finding
    -- the leftmost [if:] whose body contains no nested [if:].
    while true do
        -- Scan for an innermost [if:...][/if] block (body has no nested [if:)
        local found = false
        local pos = 1
        while true do
            local ifstart = format:find("%[if:", pos)
            if not ifstart then break end
            local condstart = ifstart + 4
            local condend = format:find("%]", condstart)
            if not condend then break end
            local cond = format:sub(condstart, condend - 1)
            local bodystart = condend + 1
            local endstart = format:find("%[/if%]", bodystart)
            if not endstart then break end
            local body = format:sub(bodystart, endstart - 1)
            local endfinish = endstart + #"[/if]" - 1
            if not body:find("%[if:") then
                -- This is an innermost block; evaluate and replace.
                local truthy = evaluateExpr(cond, book, state)
                local matched
                local mid = body:find("%[else%]")
                if mid then
                    if truthy then matched = body:sub(1, mid - 1)
                    else matched = body:sub(mid + #"[else]") end
                else
                    matched = truthy and body or ""
                end
                format = format:sub(1, ifstart - 1) .. matched .. format:sub(endfinish + 1)
                found = true
                break
            end
            pos = ifstart + 1
        end
        if not found then break end
    end
    return format
end

-- Match longest token names first so %book_pct_left wins over %book_pct.
local function compareLengthDesc(a, b) return #a > #b end
local function tokenNamesByLengthDesc()
    local names = {}
    for k in pairs(Tokens.expanders) do names[#names + 1] = k end
    table.sort(names, compareLengthDesc)
    return names
end

local function expandDatetimeBraces(format, state)
    return (format:gsub("%%datetime{(.-)}", function(spec)
        return os.date(spec, timeNow(state))
    end))
end

function Tokens.expand(format, book, state)
    if not format or format == "" then return "" end
    local result = expandDatetimeBraces(format, state)
    result = expandConditionals(result, book, state)
    local names = tokenNamesByLengthDesc()
    for _, name in ipairs(names) do
        local expander = Tokens.expanders[name]
        result = result:gsub("%%" .. name, function()
            return tostring(expander(book, state) or "")
        end)
    end
    return result
end

function Tokens.isEmpty(s)
    if not s then return true end
    -- Strip the v0.1 inline format tags ([b][i][u] and closers) before deciding
    -- emptiness, otherwise [b][/b] around an empty value would count as
    -- non-empty. New format tags added in future versions need to be added here.
    local stripped = s:gsub("%[/?[biu]%]", "")
    return stripped:match("^%s*$") ~= nil
end

return Tokens
