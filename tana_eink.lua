-- tana_eink.lua
-- Fast-waveform page flips for the bookshelf on Onyx Boox devices.
--
-- Problem: on the Boox Go 10.3 the bookshelf's page-turn repaint runs on
-- the EAC's quality waveform (driver mode 16, ~800ms visible melt). The
-- plugin already requests plain "ui" refreshes — the slowness is the
-- panel transition itself, which on a dense grid of grayscale covers
-- reads as "wipe, then every panel slowly morphs in".
--
-- Fix, mirroring Onyx's own list-scroll UX: arm the firmware's transient
-- update override (android.onyx.ViewUpdateHelper.applyTransientUpdate)
-- with UI_DU_MODE right before the flip's repaint — the flip then paints
-- in ~150ms with DU's light ghosting/posterisation — and once flipping
-- pauses, clear the override and repaint once at quality (REGAL) to
-- settle the greys. Rapid flipping stays pure DU; the quality melt only
-- happens after the user stops.
--
-- All hidden-API statics (device has hidden_api_policy=1). Verified on
-- go103_2lumi 2026-08-24: applyTransientUpdate(1) → SDM update_to_display
-- waveform 1 for subsequent paints; clearTransientUpdate(false) restores.
-- Every entry point degrades to a no-op off Android or if the probe
-- fails, so the Kindle build carries this file inert.

local logger = require("logger")

local M = {}

local CLASS = "android/onyx/ViewUpdateHelper"
local UI_DU_MODE    = 1 -- fast 2-level waveform
local UI_REGAL_MODE = 6 -- quality settle

local SETTLE_DELAY_S = 0.9

local android, ffi
local available -- nil = not probed yet, false = unusable, true = ready

-- Same attach/detach-per-call JNI pattern as android.lua's own helper
-- (and the 2-lumi user patches).
local function jni_call(runnable)
    local jvm = android.app.activity.vm
    local env = ffi.new("JNIEnv*[1]")
    jvm[0].GetEnv(jvm, ffi.cast("void**", env), ffi.C.JNI_VERSION_1_6)
    if jvm[0].AttachCurrentThread(jvm, env, nil) == ffi.C.JNI_ERR then
        return nil
    end
    local e = env[0]
    local ok, result = pcall(runnable, e)
    if e[0].ExceptionCheck(e) == 1 then
        e[0].ExceptionClear(e)
        ok = false
    end
    jvm[0].DetachCurrentThread(jvm)
    if not ok then return nil end
    return result
end

local function static_void(method, sig, ...)
    local args = { ... }
    return jni_call(function(e)
        local clazz = e[0].FindClass(e, CLASS)
        if clazz == nil then error("class not found") end
        local mid = e[0].GetStaticMethodID(e, clazz, method, sig)
        if mid == nil then error("method not found: " .. method) end
        if #args == 0 then
            e[0].CallStaticVoidMethod(e, clazz, mid)
        elseif sig == "(Z)V" then
            e[0].CallStaticVoidMethod(e, clazz, mid,
                ffi.new("uint8_t", args[1] and 1 or 0))
        else
            e[0].CallStaticVoidMethod(e, clazz, mid,
                ffi.new("int32_t", args[1]))
        end
        e[0].DeleteLocalRef(e, clazz)
        return true
    end)
end

local function probe()
    if available ~= nil then return available end
    available = false
    local ok_dev, Device = pcall(require, "device")
    if not ok_dev or not Device:isAndroid() then return false end
    local ok_a
    ok_a, android = pcall(require, "android")
    if not ok_a or type(android) ~= "table" or not android.app then
        return false
    end
    ffi = require("ffi")
    -- Existence check only — no waveform side effects at probe time.
    local found = jni_call(function(e)
        local clazz = e[0].FindClass(e, CLASS)
        if clazz == nil then error("no ViewUpdateHelper") end
        local mid = e[0].GetStaticMethodID(e, clazz, "applyTransientUpdate", "(I)V")
        e[0].DeleteLocalRef(e, clazz)
        if mid == nil then error("no applyTransientUpdate") end
        return true
    end)
    available = found == true
    logger.info("tana_eink: transient waveform control",
                available and "available" or "unavailable")
    return available
end

local settle_fn -- currently-scheduled settle closure (for unschedule)

local function settle()
    settle_fn = nil
    if not probe() then return end
    static_void("clearTransientUpdate", "(Z)V", false)
    -- One quality repaint so the DU-painted greys settle. REGAL keeps it
    -- non-flashing; the EAC's own gcInterval still deep-cleans over time.
    static_void("repaintEverything", "(I)V", UI_REGAL_MODE)
end

-- Call right before a page-flip repaint: the flip paints in DU. Re-arms
-- on every call, and (re)schedules the quality settle for when the user
-- pauses.
function M.fastFlip()
    if not probe() then return end
    static_void("applyTransientUpdate", "(I)V", UI_DU_MODE)
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not ok_ui then return end
    if settle_fn then UIManager:unschedule(settle_fn) end
    settle_fn = function() settle() end
    UIManager:scheduleIn(SETTLE_DELAY_S, settle_fn)
end

-- Immediate cleanup — call when leaving the shelf for the reader so a
-- pending DU override never bleeds into the first reader paint.
function M.restoreNow()
    if not probe() then return end
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and settle_fn then
        UIManager:unschedule(settle_fn)
        settle_fn = nil
    end
    static_void("clearTransientUpdate", "(Z)V", false)
end

return M
