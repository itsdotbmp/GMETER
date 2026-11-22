--[[
    G-Meter loader.
    Install to: Saved Games/DCS/Scripts/Hooks/gmeter-hook.lua

    Contains no gauge logic. It:

      1. Registers the DCS callbacks once and forwards them to whatever
         body is currently loaded, so reloading never calls
         DCS.setUserCallbacks again.

      2. Loads the body from Scripts/GMeter/GMeter.lua and reloads it when
         a watched file changes, without restarting DCS.

    The body is run with loadfile and returns its callback table. It is not
    passed through a global: the DCS hooks environment does not share
    globals across a loaded file.

    The previous body table is passed in as the chunk argument so the new
    one can kill the old window.

    Watched: the body, GMeterWindow.dlg and GMeterConfig.lua. Checked every
    WATCH_EVERY_FRAMES frames. Turned off with watchFiles in the config;
    mission start reloads regardless.

    Logs to Logs/GMeter.log, the same file the body writes to.
]]

local BODY_PATH          = "Scripts\\GMeter\\GMeter.lua"
local DIALOG_PATH        = "Scripts\\GMeter\\GMeterWindow.dlg"
local CONFIG_PATH        = "Config\\GMeterConfig.lua"
local LOG_PATH           = "Logs\\GMeter.log"
local MAX_FRAME_FAILURES = 5
local WATCH_EVERY_FRAMES = 60

local lfs      = require("lfs")
local bodyPath = lfs.writedir() .. BODY_PATH
local logPath  = lfs.writedir() .. LOG_PATH

local watchedPaths = {
    bodyPath,
    lfs.writedir() .. DIALOG_PATH,
    lfs.writedir() .. CONFIG_PATH,
}

local function logLine(message)
    local handle = io.open(logPath, "a")
    if handle then
        handle:write(os.date("%H:%M:%S") .. "  [stub] " .. tostring(message) .. "\n")
        handle:close()
    end
end

local currentBody   = nil
local frameFailures = 0
local reportedNoBody = false

local function reload()
    local chunk, compileError = loadfile(bodyPath)
    if not chunk then
        logLine("body FAILED to compile: " .. tostring(compileError))
        return false
    end

    local succeeded, result = pcall(chunk, currentBody)
    if not succeeded then
        logLine("body FAILED to run: " .. tostring(result))
        return false
    end

    if type(result) ~= "table" or type(result.onSimulationFrame) ~= "function" then
        logLine("body returned no callbacks, keeping the previous version")
        return false
    end

    currentBody    = result
    frameFailures  = 0
    reportedNoBody = false
    logLine("body loaded from " .. bodyPath)
    return true
end

-- ----------------------------------------------------------------------
-- File watching
-- ----------------------------------------------------------------------

local watchStamps    = {}
local watchCountdown = WATCH_EVERY_FRAMES
local watchDisabled  = false

local function modifiedTime(path)
    local succeeded, value = pcall(lfs.attributes, path, "modification")
    if not succeeded then return nil, value end
    return value
end

-- Returns true when a watched file has changed since the last check.
local function watchedFilesChanged()
    local changed = false

    for _, path in ipairs(watchedPaths) do
        local stamp, failure = modifiedTime(path)

        if stamp == nil and failure ~= nil and not watchDisabled then
            watchDisabled = true
            logLine("lfs.attributes unavailable, auto reload is off: "
                .. tostring(failure))
            return false
        end

        -- A file appearing for the first time is not a change, so the
        -- config being created on the first frame does not reload.
        if stamp and watchStamps[path] and stamp ~= watchStamps[path] then
            changed = true
        end
        watchStamps[path] = stamp
    end

    return changed
end

local callbacks = {}

function callbacks.onSimulationFrame()
    -- With no body loaded, watch regardless of the setting: nothing else
    -- would read the file that turns watching back on.
    local watching = (currentBody == nil) or (currentBody.watchFiles ~= false)

    if watching and not watchDisabled then
        watchCountdown = watchCountdown - 1
        if watchCountdown <= 0 then
            watchCountdown = WATCH_EVERY_FRAMES
            if watchedFilesChanged() then
                logLine("a watched file changed, reloading")
                reload()
                return
            end
        end
    end

    if frameFailures >= MAX_FRAME_FAILURES then return end

    if not currentBody then
        if not reportedNoBody then
            reportedNoBody = true
            logLine("no body loaded, nothing will draw")
        end
        return
    end

    local succeeded, failure = pcall(currentBody.onSimulationFrame)
    if not succeeded then
        frameFailures = frameFailures + 1
        logLine("frame error: " .. tostring(failure))
        if frameFailures >= MAX_FRAME_FAILURES then
            logLine("too many frame errors, stopping until reload or restart")
        end
    end
end

function callbacks.onMissionLoadEnd()
    -- Always reloads, whatever watchFiles says. A fresh body starts with
    -- clean state, so the event is not forwarded to it as well.
    if reload() then return end

    -- Reload failed, so the previous body is still live and still needs
    -- the event.
    if currentBody and currentBody.onMissionLoadEnd then
        pcall(currentBody.onMissionLoadEnd)
    end
end

function callbacks.onSimulationStop()
    if currentBody and currentBody.onSimulationStop then
        pcall(currentBody.onSimulationStop)
    end
end

-- Registered before the body is loaded, so a body that throws still
-- leaves the callbacks in place for a later reload to recover through.
DCS.setUserCallbacks(callbacks)
logLine("callbacks registered")

reload()

-- Seeds the timestamps so the first check has something to compare to.
watchedFilesChanged()
