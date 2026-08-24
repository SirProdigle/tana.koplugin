-- 2-luaerror-dump.lua — KOReader user patch (deploy to /sdcard/koreader/patches/).
-- Wraps UIManager:run so a fatal Lua error writes its traceback to
-- /sdcard/koreader/luaerror.log before the app exits (Android drops
-- stderr, so tracebacks are otherwise lost). Remove when done.
local UIManager = require("ui/uimanager")
local orig_run = UIManager.run
function UIManager:run(...)
    local result
    local ok, err = xpcall(function() result = orig_run(self) end, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
    end)
    if not ok then
        local f = io.open("/sdcard/koreader/luaerror.log", "a")
        if f then f:write(os.date("%Y-%m-%d %H:%M:%S"), "\n", err, "\n\n") f:close() end
        error(err, 0)
    end
    return result
end
local mk = io.open("/sdcard/koreader/luaerror.log", "a")
if mk then mk:write(os.date("%Y-%m-%d %H:%M:%S"), " patch loaded\n") mk:close() end
