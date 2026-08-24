-- 2-lumi-eink.lua
--
-- E-ink waveform control for the Onyx Boox Go 10.3 Gen II ("Lumi",
-- model go103_2lumi). KOReader v2026.07.1's launcher doesn't recognise
-- this model, so EPDFactory hands it the no-op EPD controller:
-- android.einkUpdate() does nothing, every KOReader "full refresh" is
-- silently dropped, and all panel updates run with whatever fast waveform
-- Onyx's EAC picks for an unmanaged app. Result: heavy ghosting that even
-- apparent flashes don't clear, because no GC16 is ever actually requested.
--
-- This patch reimplements what KOReader's OnyxEPDController (via
-- QualcommEPDController) does on recognised models: after each buffer
-- blit, call the Onyx framework's View.refreshScreen(x, y, w, h, mode) —
-- a PUBLIC method on this firmware — with the proper waveform:
--   full          = DEEP_GC (flashing deep anti-ghost clean)
--   flash UI      = GC     (flashing full-quality refresh)
--   partial / UI  = REGAL  (slow high-quality partial, minimal ghosting)
--   fast          = DU
-- (setWaveformAndScheme/preventSystemRefresh no longer exists on this
-- firmware; refreshScreen alone re-refreshes the region with the wanted
-- waveform after the surface frame lands, hence the small delays — same
-- values the launcher uses.)
--
-- Remove this patch (and 2-lumi-frontlight.lua) once upstream KOReader
-- ships go103_2lumi support (android-luajit-launcher PR #613).

local ok_android, android = pcall(require, "android")
if not ok_android or type(android) ~= "table" or not android.prop then return end

local product = tostring(android.prop.product or ""):lower()
if product ~= "go103_2lumi" then return end

local ffi = require("ffi")
local logger = require("logger")

-- Waveform constants — the authoritative values from THIS firmware's
-- android.onyx.ViewUpdateHelper static fields (dexdumped from
-- /system/framework, 2026-05 build), NOT the old Qualcomm-era combos:
--   UI_DU_MODE=1  UI_GU_MODE=2  UI_GC4_MODE=3  UI_DEFAULT_MODE=5
--   UI_REGAL_MODE=6  UI_REGAL_PLUS_MODE=9  UI_GC_MODE=98
--   UI_GCC_MODE=107  UI_DEEP_GC_MODE=108
-- (The old 32+64+2 arithmetic lands on 98 = UI_GC_MODE by coincidence;
-- 2 is GU — a mediocre grayscale update that ghosts — and 38 is simply
-- undefined here.)
local WF_FULL       = 108 -- UI_DEEP_GC_MODE: flashing deep anti-ghost clean
local WF_FLASH_UI   = 98  -- UI_GC_MODE: flashing GC full refresh
local WF_PARTIAL    = 6   -- UI_REGAL_MODE (unused here; EAC profile supplies it)
local WF_FAST       = 1   -- UI_DU_MODE (unused here)

-- Flash delay: long enough that the system's own REGAL update of the
-- freshly posted frame has fully completed. Firing earlier collides with
-- the in-flight waveform and cancels it midway — pixels freeze half
-- transitioned, which reads as severe ghosting ("items fade out and stop
-- before fully fading").
local DELAY_FLASH = 0.45

-- Same attach/detach-per-call JNI pattern as 2-lumi-frontlight.lua.
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

-- activity.getWindow().getDecorView():refreshScreen(x, y, w, h, mode)
-- Every int MUST be wrapped in ffi.new("int32_t", ...): variadic JNI args
-- promote plain Lua numbers to double (the frontlight patch's lesson).
local function refresh_screen(x, y, w, h, mode)
    return jni_call(function(e)
        local act = android.app.activity.clazz
        local actC = e[0].GetObjectClass(e, act)
        local mWindow = e[0].GetMethodID(e, actC, "getWindow", "()Landroid/view/Window;")
        if mWindow == nil then error("getWindow not found") end
        local win = e[0].CallObjectMethod(e, act, mWindow)
        if win == nil then error("no window") end
        local winC = e[0].GetObjectClass(e, win)
        local mDecor = e[0].GetMethodID(e, winC, "getDecorView", "()Landroid/view/View;")
        local decor = e[0].CallObjectMethod(e, win, mDecor)
        if decor == nil then error("no decor view") end
        local viewC = e[0].GetObjectClass(e, decor)
        local mRefresh = e[0].GetMethodID(e, viewC, "refreshScreen", "(IIIII)V")
        if mRefresh == nil then error("View.refreshScreen(IIIII) not found") end
        e[0].CallVoidMethod(e, decor, mRefresh,
            ffi.new("int32_t", x), ffi.new("int32_t", y),
            ffi.new("int32_t", w), ffi.new("int32_t", h),
            ffi.new("int32_t", mode))
        e[0].DeleteLocalRef(e, viewC)
        e[0].DeleteLocalRef(e, decor)
        e[0].DeleteLocalRef(e, winC)
        e[0].DeleteLocalRef(e, win)
        e[0].DeleteLocalRef(e, actC)
        return true
    end)
end

local Device = require("device")
local Screen = Device.screen

-- Sanity-probe once: if refreshScreen is missing on this firmware, leave
-- the stock (no-op) behaviour alone rather than break rendering.
local probe = refresh_screen(0, 0, Screen:getWidth(), Screen:getHeight(), WF_FLASH_UI)
if not probe then
    logger.warn("2-lumi-eink: View.refreshScreen unavailable; patch inactive")
    return
end
logger.info("2-lumi-eink: Onyx EPD refresh wired (View.refreshScreen)")

-- Schedule the waveform refresh shortly after the frame is posted, like
-- the launcher's delayed thread. Falls back to an immediate call if
-- UIManager isn't up yet (early boot paints).
local function request(mode, delay, x, y, w, h)
    -- Clamp/transform to physical coords the same way _updatePartial does.
    local bb = Screen.full_bb or Screen.bb
    if bb then
        x, y, w, h = bb:getBoundedRect(x or 0, y or 0,
                                       w or Screen:getWidth(), h or Screen:getHeight())
        x, y, w, h = bb:getPhysicalRect(x, y, w, h)
    else
        x, y = x or 0, y or 0
        w, h = w or Screen:getWidth(), h or Screen:getHeight()
    end
    local fire = function()
        refresh_screen(x, y, w, h, mode)
    end
    if delay and delay > 0 then
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if ok_ui and UIManager and UIManager.scheduleIn then
            UIManager:scheduleIn(delay, fire)
            return
        end
    end
    fire()
end

-- Routine paints (partial/ui/fast) are left to the system: KOReader now
-- has a per-app EAC profile (applied via koboot's EAC_APPLY receiver)
-- whose app-scope updateMode is REGAL, so the FIRST update of every
-- posted frame is already the high-quality slow waveform, at exactly the
-- right moment. Re-refreshing after the fact — what this patch originally
-- did — collided with that in-flight update and cancelled it midway.
--
-- Only the deliberate flash paths add work: a GC / DEEP_GC re-refresh
-- well after the frame's own update has finished.
function Screen:refreshFullImp(x, y, w, h)
    self:_updateWindow()
    request(WF_FULL, DELAY_FLASH, 0, 0, self:getWidth(), self:getHeight())
end

function Screen:refreshFlashPartialImp(x, y, w, h)
    self:_updateWindow()
    request(WF_FULL, DELAY_FLASH, x, y, w, h)
end

function Screen:refreshFlashUIImp(x, y, w, h)
    self:_updateWindow()
    request(WF_FLASH_UI, DELAY_FLASH, x, y, w, h)
end

-- Let KOReader know it really has an e-ink screen now: unlocks the E-ink
-- settings menu (full refresh rate etc.) and flash-aware UI behaviour.
Device.hasEinkScreen = function() return true end
