-- 2-lumi-frontlight.lua
--
-- Frontlight + warmth support for the Onyx Boox Go 10.3 Gen II ("Lumi",
-- model go103_2lumi). KOReader v2026.07.1's launcher doesn't recognise this
-- model, so it falls back to the generic Android backlight controller: the
-- brightness slider drives the (invisible) window brightness and there is
-- no warmth slider at all.
--
-- This patch reroutes the android.* light functions to Onyx's framework
-- API — android.onyx.hardware.DeviceController.setLightValue(type, value) —
-- exactly what KOReader's own OnyxAdbLightsController does on recognised
-- models (Go Color 7 Gen II, Note Air 3/4C, Palma 2, ...). Light types
-- mirror that controller: CTM firmware → brightness 7 / warmth 6, older
-- warm/cold firmware → cold 3 / warm 2.
--
-- Runs at stage 2 (after Device/powerd setup, before the UI), so it also
-- rewires Device and PowerD and replaces the native Android light dialog
-- (which talks to the unpatched Java controller) with KOReader's own
-- FrontLightWidget.
--
-- Remove this patch once upstream KOReader recognises go103_2lumi.

local ok_android, android = pcall(require, "android")
if not ok_android or type(android) ~= "table" or not android.prop then return end

local product = tostring(android.prop.product or ""):lower()
if product ~= "go103_2lumi" then return end

local ffi = require("ffi")
local logger = require("logger")

local CLASS = "android/onyx/hardware/DeviceController"

-- Minimal JNI helper mirroring android.lua's local JNI table (not exported).
-- Attach/detach per call is the same pattern android.lua itself uses.
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

local function static_int(method, sig, ...)
    local args = { ... }
    return jni_call(function(e)
        local clazz = e[0].FindClass(e, CLASS)
        if clazz == nil then error("class not found") end
        local mid = e[0].GetStaticMethodID(e, clazz, method, sig)
        if mid == nil then error("method not found: " .. method) end
        local res
        if #args == 0 then
            res = e[0].CallStaticIntMethod(e, clazz, mid)
        else
            res = e[0].CallStaticIntMethod(e, clazz, mid, ffi.new("int32_t", args[1]))
        end
        e[0].DeleteLocalRef(e, clazz)
        return tonumber(res)
    end)
end

local function static_bool(method, sig)
    return jni_call(function(e)
        local clazz = e[0].FindClass(e, CLASS)
        if clazz == nil then error("class not found") end
        local mid = e[0].GetStaticMethodID(e, clazz, method, sig)
        if mid == nil then error("method not found: " .. method) end
        local res = e[0].CallStaticBooleanMethod(e, clazz, mid)
        e[0].DeleteLocalRef(e, clazz)
        return res == 1
    end)
end

local function static_void(method, sig, a, b)
    return jni_call(function(e)
        local clazz = e[0].FindClass(e, CLASS)
        if clazz == nil then error("class not found") end
        local mid = e[0].GetStaticMethodID(e, clazz, method, sig)
        if mid == nil then error("method not found: " .. method) end
        e[0].CallStaticVoidMethod(e, clazz, mid,
            ffi.new("int32_t", a), ffi.new("int32_t", b))
        e[0].DeleteLocalRef(e, clazz)
        return true
    end)
end

-- Probe the API before rerouting anything: if the framework class is absent
-- or broken, leave stock behaviour alone.
local is_ctm = static_bool("checkCTM", "()Z")
if is_ctm == nil then
    logger.warn("lumi-frontlight: DeviceController unavailable, patch inactive")
    return
end

-- Light types, mirroring OnyxAdbLightsController:
--   CTM firmware:      brightness = 7 (CTM_BR), warmth = 6 (TEMP)
--   warm/cold firmware: brightness = 3 (CTM_COLD), warmth = 2 (CTM_WARM)
local BR_TYPE = is_ctm and 7 or 3
local WA_TYPE = is_ctm and 6 or 2

local max_br = static_int("getMaxLightValue", "(I)I", BR_TYPE) or 0
local max_wa = static_int("getMaxLightValue", "(I)I", WA_TYPE) or 0
if max_br == 0 then max_br = 100 end
if max_wa == 0 then max_wa = 100 end

logger.info(("lumi-frontlight: active (ctm=%s, br type %d max %d, warmth type %d max %d)")
    :format(tostring(is_ctm), BR_TYPE, max_br, WA_TYPE, max_wa))

android.hasLights = function() return true end
android.isWarmthDevice = function() return true end
android.hasStandaloneWarmth = function() return false end
android.enableFrontlightSwitch = function() return 1 end

android.getScreenMinBrightness = function() return 0 end
android.getScreenMaxBrightness = function() return max_br end
android.getScreenMinWarmth = function() return 0 end
android.getScreenMaxWarmth = function() return max_wa end

android.getScreenBrightness = function()
    return static_int("getLightValue", "(I)I", BR_TYPE) or 0
end

android.setScreenBrightness = function(brightness)
    brightness = math.max(0, math.min(max_br, math.floor(brightness or 0)))
    static_void("setLightValue", "(II)V", BR_TYPE, brightness)
end

android.getScreenWarmth = function()
    return static_int("getLightValue", "(I)I", WA_TYPE) or 0
end

android.setScreenWarmth = function(warmth)
    warmth = math.max(0, math.min(max_wa, math.floor(warmth or 0)))
    static_void("setLightValue", "(II)V", WA_TYPE, warmth)
end

-- ── Device + PowerD wiring (stage 2: both exist already) ─────────────────

local ok_dev, Device = pcall(require, "device")
if not ok_dev then return end

Device.hasFrontlight = function() return true end
Device.hasNaturalLight = function() return true end
-- Pretend a "mixer" exists so FrontLightWidget hides its Configure button,
-- which opens the Kobo Aura One R/G/B NaturalLight widget and crashes here.
Device.hasNaturalLightMixer = function() return true end

-- The native Android light dialog talks to the launcher's Java controller,
-- which doesn't know this device. Use KOReader's own widget instead — it
-- goes through PowerD and therefore through the overrides above.
Device.showLightDialog = function(self)
    local UIManager = require("ui/uimanager")
    local FrontLightWidget = require("ui/widget/frontlightwidget")
    UIManager:show(FrontLightWidget:new{})
end

local powerd = Device:getPowerDevice()
if powerd then
    powerd.fl_min = 0
    powerd.fl_max = max_br
    -- bright_diff == fl_max makes AndroidPowerD's scaling the identity,
    -- so sliders operate directly in native units (0..32 on the Lumi).
    powerd.bright_diff = max_br
    powerd.fl_warmth_min = 0
    powerd.fl_warmth_max = max_wa
    powerd.warm_diff = max_wa
    powerd.frontlightWarmthHW = function() return android.getScreenWarmth() end
    local cur_br = android.getScreenBrightness()
    if cur_br and cur_br > 0 then powerd.fl_intensity = cur_br end
    powerd.fl_warmth = android.getScreenWarmth() or 0
end

logger.info("lumi-frontlight: Device/PowerD rewired")
