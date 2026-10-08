-- 1-lumi-native-portrait.lua
--
-- Keeps KOReader's idea of the Boox Go 10.3 Gen II's natural orientation
-- pinned to portrait.
--
-- The launcher decides the device's natural orientation exactly once, in
-- MainActivity.onCreate:
--
--     screenIsLandscape = defaultDisplay.width > defaultDisplay.height
--
-- That reads the display as it is *right now*, rotation included. If
-- KOReader starts while the display is still sideways — it was killed on a
-- landscape spread, or restarted from its crash screen while rotated — a
-- portrait device is taken to be a landscape one for the whole session.
-- Every rotation is then translated through the wrong table
-- (setOrientationCompat/getOrientationCompat): portrait requests come out
-- landscape, landscape ones come out upside-down, and the rotation menu
-- "doesn't work". Seen on-device 2026-09-28 as "native orientation:
-- landscape" in logcat and REVERSE_PORTRAIT (9) orientation requests.
--
-- The Go 10.3 is a portrait panel, full stop, so we reset the field to
-- false over JNI before anything reads it. Runs at stage 1 (early), ahead
-- of Device/Screen init. Remove if upstream computes the natural
-- orientation from rotation-independent metrics.

local ok_android, android = pcall(require, "android")
if not ok_android or type(android) ~= "table" or not android.prop then return end

local product = tostring(android.prop.product or ""):lower()
if product ~= "go103_2lumi" then return end

local ffi = require("ffi")
local logger = require("logger")

-- Same attach/detach pattern as 2-lumi-frontlight.lua (android.lua's JNI
-- helper isn't exported).
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

local was_landscape = jni_call(function(e)
    local activity = android.app.activity.clazz
    local clazz = e[0].GetObjectClass(e, activity)
    local fid = e[0].GetFieldID(e, clazz, "screenIsLandscape", "Z")
    if fid == nil then
        e[0].DeleteLocalRef(e, clazz)
        error("screenIsLandscape field not found")
    end
    local before = e[0].GetBooleanField(e, activity, fid) == 1
    e[0].SetBooleanField(e, activity, fid, 0)
    e[0].DeleteLocalRef(e, clazz)
    return before
end)

android.LOGI("lumi-native-portrait: screenIsLandscape was " .. tostring(was_landscape) .. ", now false")
if was_landscape == nil then
    logger.warn("lumi-native-portrait: could not reach MainActivity.screenIsLandscape")
elseif was_landscape then
    logger.info("lumi-native-portrait: launcher started rotated and took the panel for landscape; reset to portrait")
end
