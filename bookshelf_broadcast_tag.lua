-- bookshelf_broadcast_tag.lua
-- Tag every event delivered via UIManager:broadcastEvent so BookshelfWidget's
-- "forward to FM" path can distinguish broadcasts (which already reach FM
-- via the broadcast loop) from sendEvents (which only reach the topmost
-- widget and DO need our forward). See BookshelfWidget:handleEvent for the
-- consumer side. Fixes issue #19 (Night Mode toggle double-handled).
--
-- Install is idempotent: if the plugin's init runs again (second host
-- context, plugin reload), we skip the wrap. The wrapper delegates to the
-- original so other listeners and any future KOReader changes are
-- unaffected.

local M = {}

function M.install(UIManager)
    if UIManager._bookshelf_broadcast_wrapped then return end
    UIManager._bookshelf_broadcast_wrapped = true
    local orig = UIManager.broadcastEvent
    UIManager.broadcastEvent = function(self_um, event, ...)
        -- Only Event tables can carry the tag. Some callers pass a bare
        -- string (autodim.koplugin: broadcastEvent("UpdateFooter")); stock
        -- KOReader no-ops those, but indexing one here is a hard error.
        if type(event) == "table" then event._bookshelf_from_broadcast = true end
        return orig(self_um, event, ...)
    end
end

return M
