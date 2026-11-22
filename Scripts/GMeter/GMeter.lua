-- GMETER - on-screen G-force indicator for DCS World
-- Copyright (C) 2026 dotbmp
--
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, version 3.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.

--[[
    G-Meter body.
    Install to: Saved Games/DCS/Scripts/GMeter/GMeter.lua

    Draws a bar that grows up from the zero mark for positive G and down
    for negative, with a tick at 1 G. The scale is the same in every
    aircraft. Rate of change is added to the reading, so a fast pull reads
    high and decays back onto the true value.

    Loaded by Scripts/Hooks/gmeter-hook.lua, which owns the DCS callbacks.
    Returns its callback table as the last statement in the file; on any
    error above that the loader keeps the previous version running.

    The previous load's table arrives as the chunk argument so its window
    can be killed once this one is built.
]]

local previousBody = ...

package.path = package.path
    .. ";.\\Scripts\\?.lua;"
    .. ".\\Scripts\\UI\\?.lua;"
    .. ".\\dxgui\\skins\\common\\?.lua;"

local DialogLoader = require("DialogLoader")
local SkinUtils    = require("SkinUtils")
local dxgui        = require("dxgui")
local lfs          = require("lfs")

-- Callback table handed back to the loader at the end of this file.
local moduleTable = {}

local function asinh(value)
    return math.log(value + math.sqrt(value * value + 1))
end

-- ----------------------------------------------------------------------
-- Logging
-- ----------------------------------------------------------------------

local logPath = lfs.writedir() .. "Logs\\GMeter.log"

local function logLine(message)
    local handle = io.open(logPath, "a")
    if handle then
        handle:write(os.date("%H:%M:%S") .. "  " .. tostring(message) .. "\n")
        handle:close()
    end
end

-- ----------------------------------------------------------------------
-- Configuration
-- ----------------------------------------------------------------------

local configurationPath = lfs.writedir() .. "Config\\GMeterConfig.lua"

local defaultConfiguration = [[
-- GMETER - on-screen G-force indicator for DCS World
-- Copyright (C) 2026 dotbmp
--
-- SPDX-License-Identifier: GPL-3.0-only
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, version 3.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.

-- G-Meter configuration.
-- Picked up at mission start, or on save while watchFiles is on.
-- Never overwritten once it exists.
return {
    -- Show/hide toggle. Key names: DCS World\dxgui\bind\KeyNames.txt
    hotkey = "Ctrl+Shift+G",

    -- Reload GMeter.lua, GMeterWindow.dlg and this file whenever one of
    -- them changes on disk, so edits apply without leaving the mission.
    -- Costs a few file stats a second. Turn it on while tuning.
    -- Mission start reloads regardless of this setting.
    watchFiles = false,

    -- Screen position in pixels. Positive measures from the top-left
    -- corner, negative measures the gap from the right and bottom edges.
    -- The gauge does not take the mouse cursor and cannot be dragged.
    position = { x = -140, y = -80 },

    -- G at which the bar is fully extended. Anything above it reads the
    -- same. The negative ceiling is a third of this. Clamped to 2.0 - 15.0.
    maxG = 7.0,

    -- Where the 1 G tick sits as a fraction of the upward travel. Lower
    -- leaves more room above 1 G. Clamped to 1/maxG + 0.02 and 0.90.
    oneGPosition = 0.23,

    -- Seconds for the bar to track the real load factor. Clamped to
    -- 0.01 - 1.00.
    responseSeconds = 0.08,

    -- Seconds of rate of change added to the reading. 0 makes the bar read
    -- the true load factor. Clamped to 0 - 0.5.
    onsetBoost = 0.16,

    -- Rate in G per second below which nothing is added.
    onsetThreshold = 1.0,

    -- Seconds for the added amount to decay once the rate drops. Raised to
    -- responseSeconds * 1.5 if set below that. Capped at 2.0.
    onsetHoldSeconds = 0.25,

    -- ------------------------------------------------------------------
    -- Appearance. Optional: delete the block, or any key in it, and the
    -- built-in value is used instead.
    -- ------------------------------------------------------------------
    layout = {
        scale       = 1,          -- whole-number multiplier for every size
                                  -- below; 2 doubles the gauge for a high
                                  -- resolution display
        travel      = 160,        -- upward travel in pixels
        margin      = 4,          -- space around the bar inside the window
        fillX       = 18,         -- left edge of the bar within the window
        fillWidth   = 32,
        zeroHeight  = 2,          -- thickness of the zero mark
        zeroExtra   = 1,          -- extra width on EACH side of the bar
        capHeight   = 3,          -- thickness of the cap riding the bar tip
        capAlpha    = 255,        -- cap opacity, 0 to 255
        tickHeight  = 5,          -- thickness of the 1 G tick
        tickWidth   = 9,          -- length of the 1 G tick
        tickGap     = 1,          -- gap between tick and bar, negative overlaps

        -- 0xRRGGBBAA. The fill runs low to mid to high to limit as the bar
        -- departs 1 G in either direction. Alpha interpolates too.
        colourLow   = "0x12cc8588",
        colourMid   = "0xf0c040cc",
        colourHigh  = "0xe04030ee",
        colourLimit = "0x9050c8ff",

        colourTick  = "0xeeFFeefa",
        colourZero  = "0x303030ff",
    },
}
]]

local configuration = nil

local function loadConfiguration()
    local handle = io.open(configurationPath, "r")
    if not handle then
        handle = io.open(configurationPath, "w")
        if handle then
            handle:write(defaultConfiguration)
            handle:close()
            logLine("Created default config at " .. configurationPath)
        end
    else
        handle:close()
    end

    local loaded, loadError = loadfile(configurationPath)
    if not loaded then
        logLine("Config failed to parse, using built-in defaults: " .. tostring(loadError))
        configuration = assert(loadstring(defaultConfiguration))()
        return
    end

    local succeeded, result = pcall(loaded)
    if not succeeded or type(result) ~= "table" then
        logLine("Config returned no table, using built-in defaults")
        configuration = assert(loadstring(defaultConfiguration))()
        return
    end

    configuration = result
end

-- ----------------------------------------------------------------------
-- Appearance, read from the optional layout block
-- ----------------------------------------------------------------------

local function layoutNumber(name, fallback)
    local block = configuration and configuration.layout
    local value = block and tonumber(block[name])
    if value == nil then return fallback end
    return value
end

-- Returns { red, green, blue, alpha } from a 0xRRGGBBAA string, or the
-- fallback if the value is missing or malformed.
local function layoutColour(name, fallback)
    local block = configuration and configuration.layout
    local text  = block and block[name]

    if type(text) == "string" then
        local digits = text:match("^0[xX](%x%x%x%x%x%x%x%x)$")
        if digits then
            return {
                tonumber(digits:sub(1, 2), 16),
                tonumber(digits:sub(3, 4), 16),
                tonumber(digits:sub(5, 6), 16),
                tonumber(digits:sub(7, 8), 16),
            }
        end
        logLine("layout." .. name .. " is not a 0xRRGGBBAA colour, ignoring")
    end

    return fallback
end

local POSITIVE_TRAVEL, MARGIN, FILL_X, FILL_WIDTH
local ZERO_HEIGHT, ZERO_EXTRA, ZERO_WIDTH, ZERO_X
local CAP_HEIGHT, CAP_ALPHA, TOP_PAD, BOTTOM_PAD
local TICK_HEIGHT, TICK_WIDTH, TICK_GAP, TICK_X
local WINDOW_WIDTH, ZERO_Y
local COLOUR_LOW, COLOUR_MID, COLOUR_HIGH, COLOUR_LIMIT
local COLOUR_TICK, COLOUR_ZERO

local SCALE = 1

local function applyLayout()
    SCALE = math.floor(layoutNumber("scale", 1))
    if SCALE < 1 then SCALE = 1 end
    if SCALE > 8 then SCALE = 8 end

    -- Every pixel dimension is multiplied by SCALE. capAlpha and the
    -- colours are not sizes and are left alone, and so is position, which
    -- is a screen coordinate rather than a size.
    POSITIVE_TRAVEL = layoutNumber("travel", 160) * SCALE
    MARGIN          = layoutNumber("margin", 4) * SCALE
    FILL_X          = layoutNumber("fillX", 18) * SCALE
    FILL_WIDTH      = layoutNumber("fillWidth", 32) * SCALE
    ZERO_HEIGHT     = layoutNumber("zeroHeight", 2) * SCALE
    ZERO_EXTRA      = layoutNumber("zeroExtra", 1) * SCALE
    CAP_HEIGHT      = layoutNumber("capHeight", 3) * SCALE
    CAP_ALPHA       = layoutNumber("capAlpha", 255)
    TICK_HEIGHT     = layoutNumber("tickHeight", 5) * SCALE
    TICK_WIDTH      = layoutNumber("tickWidth", 9) * SCALE
    TICK_GAP        = layoutNumber("tickGap", 1) * SCALE

    -- Tick's right edge lands on FILL_X - TICK_GAP. Negative gap overlaps.
    TICK_X     = FILL_X - TICK_GAP - TICK_WIDTH

    -- Zero mark is centred on the bar, ZERO_EXTRA wider on each side.
    ZERO_WIDTH = FILL_WIDTH + ZERO_EXTRA * 2
    ZERO_X     = FILL_X - ZERO_EXTRA

    -- Half the cap sits past the travel at each extreme, so pad for it.
    local capOverhang = math.floor(CAP_HEIGHT / 2) + 1
    TOP_PAD    = MARGIN
    BOTTOM_PAD = MARGIN
    if capOverhang > TOP_PAD    then TOP_PAD    = capOverhang end
    if capOverhang > BOTTOM_PAD then BOTTOM_PAD = capOverhang end

    ZERO_Y = TOP_PAD + POSITIVE_TRAVEL

    local rightEdge = FILL_X + FILL_WIDTH
    if ZERO_X + ZERO_WIDTH > rightEdge then rightEdge = ZERO_X + ZERO_WIDTH end
    WINDOW_WIDTH = rightEdge + MARGIN

    if TICK_WIDTH < 1 then TICK_WIDTH = 1 end
    if TICK_X < 0 then TICK_X = 0 end
    if ZERO_X < 0 then ZERO_X = 0 end

    COLOUR_LOW  = layoutColour("colourLow",  { 18, 204, 133, 136 })
    COLOUR_MID  = layoutColour("colourMid",  { 240, 192, 64, 204 })
    COLOUR_HIGH  = layoutColour("colourHigh",  { 224, 64, 48, 238 })
    COLOUR_LIMIT = layoutColour("colourLimit", { 144, 80, 200, 255 })
    COLOUR_TICK = layoutColour("colourTick", { 238, 255, 238, 250 })
    COLOUR_ZERO = layoutColour("colourZero", { 48, 48, 48, 255 })
end

-- ----------------------------------------------------------------------
-- Scale
--
-- Deflection is asinh(g / curveScale) normalised by the span at the
-- ceiling. Larger curveScale is more linear. curveScale is solved from
-- the configured oneGPosition.
-- ----------------------------------------------------------------------

local POSITIVE_CEILING, NEGATIVE_CEILING
local POSITIVE_SPAN, NEGATIVE_SPAN
local curveScale
local NEGATIVE_TRAVEL, WINDOW_HEIGHT, TICK_Y, ONE_G_PIXELS

local function deflectionFraction(magnitude, span)
    local fraction = asinh(magnitude / curveScale) / span
    if fraction < 0 then return 0 end
    if fraction > 1 then return 1 end
    return fraction
end

-- Bisects for the curveScale that puts 1 G at targetPosition. Monotonic,
-- so 60 iterations converge. Runs once per load.
local function solveCurveScale(maxG, targetPosition)
    local low, high = 0.05, 200.0
    for _ = 1, 60 do
        local middle = (low + high) / 2
        if asinh(1.0 / middle) / asinh(maxG / middle) > targetPosition then
            low = middle
        else
            high = middle
        end
    end
    return (low + high) / 2
end

local function computeGeometry(maxG, requestedPosition)
    POSITIVE_CEILING = maxG
    NEGATIVE_CEILING = maxG / 3

    -- 1/maxG is the linear case; nothing below it is reachable.
    local lowestPossible = 1.0 / maxG + 0.02
    local oneGPosition   = requestedPosition
    if oneGPosition < lowestPossible then oneGPosition = lowestPossible end
    if oneGPosition > 0.90          then oneGPosition = 0.90          end

    curveScale    = solveCurveScale(maxG, oneGPosition)
    POSITIVE_SPAN = asinh(POSITIVE_CEILING / curveScale)
    NEGATIVE_SPAN = asinh(NEGATIVE_CEILING / curveScale)

    -- Scaled so +1 G and -1 G deflect the same number of pixels despite
    -- the different ceilings.
    local positiveAtOneG = deflectionFraction(1.0, POSITIVE_SPAN)
    local negativeAtOneG = deflectionFraction(1.0, NEGATIVE_SPAN)

    NEGATIVE_TRAVEL = math.floor(
        POSITIVE_TRAVEL * positiveAtOneG / negativeAtOneG + 0.5)

    -- Pixel position of 1 G. The colour ramp measures departure from it.
    ONE_G_PIXELS = positiveAtOneG * POSITIVE_TRAVEL

    WINDOW_HEIGHT = ZERO_Y + NEGATIVE_TRAVEL + BOTTOM_PAD

    TICK_Y = ZERO_Y
        - math.floor(positiveAtOneG * POSITIVE_TRAVEL + 0.5)
        - math.floor(TICK_HEIGHT / 2)

    if requestedPosition ~= oneGPosition then
        logLine(string.format(
            "oneGPosition %.3f not reachable at maxG %.1f, using %.3f",
            requestedPosition, maxG, oneGPosition))
    end
end

-- ----------------------------------------------------------------------
-- Colour
--
-- COLOUR_STEPS colours are precomputed at load. A skin is pushed only when
-- the step index changes.
-- ----------------------------------------------------------------------

local COLOUR_STEPS = 32
local colourRamp   = {}
local capRamp      = {}

local function mixChannel(from, to, amount)
    return math.floor(from + (to - from) * amount + 0.5)
end

local function mixColour(from, to, amount)
    return SkinUtils.RGBA256ToHexColor(
        mixChannel(from[1], to[1], amount),
        mixChannel(from[2], to[2], amount),
        mixChannel(from[3], to[3], amount),
        mixChannel(from[4], to[4], amount))
end

-- Position of each colour along the ramp, 0 at 1 G to 1 at either end of
-- the travel.
local function colourStops()
    return {
        { 0.00, COLOUR_LOW },
        { 0.45, COLOUR_MID },
        { 0.88, COLOUR_HIGH },
        { 1.00, COLOUR_LIMIT },
    }
end

local function buildColourRamp()
    local stops = colourStops()

    for step = 1, COLOUR_STEPS do
        local position = (step - 1) / (COLOUR_STEPS - 1)
        local colour = nil

        for index = 1, #stops - 1 do
            local lower, upper = stops[index], stops[index + 1]
            if position <= upper[1] or index == #stops - 1 then
                local span = upper[1] - lower[1]
                local amount = span > 0 and (position - lower[1]) / span or 0
                if amount < 0 then amount = 0 end
                if amount > 1 then amount = 1 end
                colour = mixColour(lower[2], upper[2], amount)
                break
            end
        end

        colourRamp[step] = colour

        -- Same colour with the cap's alpha substituted.
        capRamp[step] = colour:sub(1, 8)
            .. string.format("%.2x", math.floor(CAP_ALPHA))
    end
end

local function colourStepFor(fraction)
    local step = math.floor(fraction * (COLOUR_STEPS - 1) + 0.5) + 1
    if step < 1 then return 1 end
    if step > COLOUR_STEPS then return COLOUR_STEPS end
    return step
end

local function flatColour(channels)
    return SkinUtils.RGBA256ToHexColor(
        channels[1], channels[2], channels[3], channels[4])
end

-- SkinUtils.setStaticColor writes only center_center. The other slice
-- slots are filled here so the element is one flat colour.
local BACKGROUND_SLOTS = {
    "center_bottom", "center_center", "center_top",
    "left_bottom", "left_center", "left_top",
    "right_bottom", "right_center", "right_top",
}

local colourWarningLogged = false

local function applyColour(widget, colour)
    local succeeded, failure = pcall(function()
        local skin = SkinUtils.setStaticColor(colour, widget:getSkin())
        local background = skin.skinData.states.released[1].bkg
        for _, slot in ipairs(BACKGROUND_SLOTS) do
            background[slot] = colour
        end
        widget:setSkin(skin)
    end)

    if not succeeded and not colourWarningLogged then
        colourWarningLogged = true
        logLine("applyColour failed, elements keep their authored colour: "
            .. tostring(failure))
    end
end

-- ----------------------------------------------------------------------
-- Onset response
--
-- Displayed value is a first-order smoothed load factor plus a lead term
-- proportional to its rate of change. The lead jumps to each new extreme
-- and decays over onsetHold, so the reading settles onto the true value
-- from above. configureFilter keeps onsetHold longer than responseSeconds,
-- which is what makes the approach one-directional.
-- ----------------------------------------------------------------------

local responseSeconds = 0.08
local onsetHold       = 0.25
local onsetBoost      = 0.16
local onsetThreshold  = 1.0

-- One state table per channel: bar length and ramp colour are filtered
-- separately because they follow different signals.
local function newFilter()
    return { smoothedG = 0, smoothedRate = 0, heldLead = 0 }
end

local lengthFilter = newFilter()
local colourFilter = newFilter()

local function configureFilter()
    responseSeconds = tonumber(configuration.responseSeconds) or 0.08
    if responseSeconds < 0.01 then responseSeconds = 0.01 end
    if responseSeconds > 1.00 then responseSeconds = 1.00 end

    onsetHold = tonumber(configuration.onsetHoldSeconds) or 0.25
    if onsetHold > 2.0 then onsetHold = 2.0 end

    -- Below this the reading would dip under the true value and climb back.
    local shortest = responseSeconds * 1.5
    if onsetHold < shortest then
        logLine(string.format(
            "onsetHoldSeconds %.3f is too short next to responseSeconds %.3f,"
            .. " using %.3f",
            onsetHold, responseSeconds, shortest))
        onsetHold = shortest
    end

    onsetBoost = tonumber(configuration.onsetBoost) or 0.16
    if onsetBoost < 0 then onsetBoost = 0 end
    if onsetBoost > 0.5 then onsetBoost = 0.5 end

    onsetThreshold = tonumber(configuration.onsetThreshold) or 1.0
    if onsetThreshold < 0 then onsetThreshold = 0 end
end

local function advanceFilter(filter, targetG, deltaTime)
    -- Clamped so a frame hitch cannot produce a huge rate.
    if deltaTime > 0.05 then deltaTime = 0.05 end
    if deltaTime <= 0 then
        return filter.smoothedG + filter.heldLead
    end

    local previous = filter.smoothedG

    local trackBlend = 1 - math.exp(-deltaTime / responseSeconds)
    filter.smoothedG = filter.smoothedG + trackBlend * (targetG - filter.smoothedG)

    -- Smoothed over a shorter time than the value itself, so a snatch
    -- stays a spike.
    local instantRate = (filter.smoothedG - previous) / deltaTime
    local rateBlend   = 1 - math.exp(-deltaTime / (responseSeconds * 0.6))
    filter.smoothedRate = filter.smoothedRate
        + rateBlend * (instantRate - filter.smoothedRate)

    -- Rates under onsetThreshold contribute nothing. The threshold is
    -- subtracted rather than gated on, so the response stays continuous.
    local effectiveRate = 0
    local magnitude     = math.abs(filter.smoothedRate)

    if magnitude > onsetThreshold then
        effectiveRate = magnitude - onsetThreshold
        if filter.smoothedRate < 0 then effectiveRate = -effectiveRate end
    end

    -- Jumps straight to a larger lead, decays toward a smaller one.
    local lead = onsetBoost * effectiveRate

    if math.abs(lead) > math.abs(filter.heldLead) then
        filter.heldLead = lead
    else
        local releaseBlend = 1 - math.exp(-deltaTime / onsetHold)
        filter.heldLead = filter.heldLead
            + releaseBlend * (lead - filter.heldLead)
    end

    return filter.smoothedG + filter.heldLead
end

-- Length follows the magnitude of the whole acceleration vector. Colour
-- follows the vertical component alone.
--
-- Direction comes from whichever of the vertical and longitudinal axes is
-- carrying more load, so decelerating harder than 1 G reads as negative.
-- The lateral axis adds to the magnitude but never sets the direction,
-- because neither side is the negative one.
local function resolveInputs(acceleration)
    local vertical     = acceleration.y
    local longitudinal = tonumber(acceleration.x) or 0
    local lateral      = tonumber(acceleration.z) or 0

    local magnitude = math.sqrt(vertical * vertical
        + longitudinal * longitudinal + lateral * lateral)

    local leading = vertical
    if math.abs(longitudinal) > math.abs(leading) then leading = longitudinal end

    if leading < 0 then magnitude = -magnitude end
    return magnitude, vertical
end

-- ----------------------------------------------------------------------
-- Widgets
-- ----------------------------------------------------------------------

local window        = nil
local fillUp        = nil
local fillDown      = nil
local capMark       = nil
local zeroMark      = nil
local referenceTick = nil

local gaugeEnabled    = true
local childrenShown   = nil
local shownUpHeight   = -1
local shownDownHeight = -1
local shownStepUp     = -1
local shownStepDown   = -1
local shownCapY       = nil
local shownCapStep    = -1

local function showChildren(visible)
    if childrenShown == visible then return end
    childrenShown = visible

    zeroMark:setVisible(visible)
    referenceTick:setVisible(visible)
    capMark:setVisible(visible)

    if not visible then
        fillUp:setVisible(false)
        fillDown:setVisible(false)
        shownUpHeight   = 0
        shownDownHeight = 0
    end
end

-- Negative coordinates measure the gap from the right and bottom edges
-- instead of the top left.
local function resolvePosition()
    local x = tonumber(configuration.position and configuration.position.x) or 60
    local y = tonumber(configuration.position and configuration.position.y) or 200

    if x < 0 or y < 0 then
        local screenWidth, screenHeight = dxgui.GetScreenSize()
        if x < 0 then x = screenWidth  - WINDOW_WIDTH  + x end
        if y < 0 then y = screenHeight - WINDOW_HEIGHT + y end
    end

    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    return math.floor(x), math.floor(y)
end

local function buildWindow()
    window = DialogLoader.spawnDialogFromFile(
        lfs.writedir() .. "Scripts\\GMeter\\GMeterWindow.dlg"
    )

    fillUp        = window.FillUp
    fillDown      = window.FillDown
    capMark       = window.Cap
    zeroMark      = window.ZeroMark
    referenceTick = window.Tick

    if not fillUp or not fillDown or not capMark
        or not zeroMark or not referenceTick then
        logLine("GMeterWindow.dlg does not match this script: expected "
            .. "children FillUp, FillDown, Cap, ZeroMark and Tick")
        return false
    end

    local maxG = tonumber(configuration.maxG) or 7.0
    if maxG < 2.0  then maxG = 2.0  end
    if maxG > 15.0 then maxG = 15.0 end

    computeGeometry(maxG, tonumber(configuration.oneGPosition) or 0.23)

    local x, y = resolvePosition()
    window:setBounds(x, y, WINDOW_WIDTH, WINDOW_HEIGHT)
    window:setVisible(true)

    -- Overwrites the bounds authored in the .dlg.
    zeroMark:setBounds(ZERO_X, ZERO_Y - math.floor(ZERO_HEIGHT / 2),
                       ZERO_WIDTH, ZERO_HEIGHT)
    referenceTick:setBounds(TICK_X, TICK_Y, TICK_WIDTH, TICK_HEIGHT)
    capMark:setBounds(FILL_X, ZERO_Y, FILL_WIDTH, CAP_HEIGHT)
    shownCapY    = nil
    shownCapStep = -1

    buildColourRamp()
    applyColour(zeroMark, flatColour(COLOUR_ZERO))
    applyColour(referenceTick, flatColour(COLOUR_TICK))

    configureFilter()
    showChildren(false)

    window:addHotKeyCallback(configuration.hotkey, function()
        gaugeEnabled = not gaugeEnabled
        if not gaugeEnabled then
            showChildren(false)
        end
        logLine("Toggled " .. (gaugeEnabled and "on" or "off"))
    end)

    -- dxgui honours one hotkey callback per window. A second registration
    -- is silently dropped and its key fires the first callback.

    moduleTable.window = window

    logLine(string.format(
        "Window %dx%d at %d,%d scale %d | ceilings +%.1f/-%.1f G | curve %.3f"
        .. " | travel +%d/-%d px | zero y=%d tick y=%d",
        WINDOW_WIDTH, WINDOW_HEIGHT, x, y, SCALE,
        POSITIVE_CEILING, NEGATIVE_CEILING, curveScale,
        POSITIVE_TRAVEL, NEGATIVE_TRAVEL, ZERO_Y, TICK_Y))
    return true
end

-- ----------------------------------------------------------------------
-- Display
-- ----------------------------------------------------------------------

-- Pixels the exact height must move before the drawn height follows it,
-- scaled so a doubled gauge is no twitchier than a single one.
local PIXEL_HYSTERESIS = 1.0

local function steadyHeight(exact, showing)
    if showing < 0 then return math.floor(exact + 0.5) end
    if math.abs(exact - showing) > PIXEL_HYSTERESIS * SCALE then
        return math.floor(exact + 0.5)
    end
    return showing
end

-- Returns 0 at 1 G rising to 1 at either end of the travel, so the ramp
-- advances whether the bar is loading or unloading.
local function colourFraction(exactPixels)
    local span, distance

    if exactPixels >= ONE_G_PIXELS then
        span     = POSITIVE_TRAVEL - ONE_G_PIXELS
        distance = exactPixels - ONE_G_PIXELS
    else
        span     = ONE_G_PIXELS + NEGATIVE_TRAVEL
        distance = ONE_G_PIXELS - exactPixels
    end

    if span <= 0 then return 0 end

    local value = distance / span
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

-- Pixel position a G value would put the bar tip at. Signed like the bar.
local function deflectionPixels(value)
    if value >= 0 then
        return deflectionFraction(value, POSITIVE_SPAN) * POSITIVE_TRAVEL
    end
    return -deflectionFraction(-value, NEGATIVE_SPAN) * NEGATIVE_TRAVEL
end

-- displayG drives the bar's length, colourG drives the ramp.
local function updateDisplay(displayG, colourG)
    local upHeight, downHeight = 0, 0
    local exactPixels = deflectionPixels(displayG)

    if displayG >= 0 then
        upHeight   = steadyHeight(exactPixels, shownUpHeight)
    else
        downHeight = steadyHeight(-exactPixels, shownDownHeight)
    end

    local fraction = colourFraction(deflectionPixels(colourG))

    if upHeight ~= shownUpHeight then
        if upHeight < 1 then
            fillUp:setVisible(false)
        else
            fillUp:setBounds(FILL_X, ZERO_Y - upHeight, FILL_WIDTH, upHeight)
            fillUp:setVisible(true)
        end
        shownUpHeight = upHeight
    end

    if downHeight ~= shownDownHeight then
        if downHeight < 1 then
            fillDown:setVisible(false)
        else
            fillDown:setBounds(FILL_X, ZERO_Y, FILL_WIDTH, downHeight)
            fillDown:setVisible(true)
        end
        shownDownHeight = downHeight
    end

    local step = colourStepFor(fraction)

    -- Centred on the bar's tip. At zero length this is the only fill
    -- element still visible.
    local capY = ZERO_Y - (upHeight - downHeight) - math.floor(CAP_HEIGHT / 2)

    if capY ~= shownCapY then
        capMark:setPosition(FILL_X, capY)
        shownCapY = capY
    end

    if step ~= shownCapStep then
        applyColour(capMark, capRamp[step])
        shownCapStep = step
    end

    if upHeight >= 1 and step ~= shownStepUp then
        applyColour(fillUp, colourRamp[step])
        shownStepUp = step
    end

    if downHeight >= 1 and step ~= shownStepDown then
        applyColour(fillDown, colourRamp[step])
        shownStepDown = step
    end
end

-- ----------------------------------------------------------------------
-- Callbacks, forwarded from the loader
-- ----------------------------------------------------------------------

local windowFailed    = false
local lastModelTime   = nil
local exportComplaint = false

local function onSimulationFrame()
    if windowFailed then return end

    if configuration == nil then
        loadConfiguration()
        applyLayout()
        moduleTable.watchFiles = configuration.watchFiles == true
    end

    if window == nil then
        if not buildWindow() then
            windowFailed = true
            return
        end
    end

    if not gaugeEnabled then return end

    local unitType = DCS.getPlayerUnitType()
    if unitType == nil or unitType == "" then
        showChildren(false)
        return
    end

    local acceleration = Export.LoGetAccelerationUnits()
    if acceleration == nil or acceleration.y == nil then
        -- Not in an aircraft, or ownship export is blocked by the server.
        if not exportComplaint then
            exportComplaint = true
            local allowed = "unknown"
            pcall(function()
                allowed = tostring(Export.LoIsOwnshipExportAllowed())
            end)
            logLine("No acceleration data. LoIsOwnshipExportAllowed = " .. allowed)
        end
        showChildren(false)
        return
    end

    showChildren(true)

    local modelTime = DCS.getModelTime and DCS.getModelTime() or nil
    local deltaTime = 0.016
    if modelTime and lastModelTime then
        deltaTime = modelTime - lastModelTime
    end
    lastModelTime = modelTime

    local combined, vertical = resolveInputs(acceleration)
    updateDisplay(advanceFilter(lengthFilter, combined, deltaTime),
                  advanceFilter(colourFilter, vertical, deltaTime))
end

local function onMissionLoadEnd()
    lastModelTime   = nil
    lengthFilter    = newFilter()
    colourFilter    = newFilter()
    exportComplaint = false
end

local function onSimulationStop()
    lastModelTime = nil
    lengthFilter  = newFilter()
    colourFilter  = newFilter()
    if window then
        showChildren(false)
    end
end

-- ----------------------------------------------------------------------
-- Publish
--
-- Must stay last in the file. The loader treats a missing return as a
-- failed load and keeps the previous version running.
-- ----------------------------------------------------------------------

if previousBody and previousBody.window then
    pcall(function() previousBody.window:kill() end)
    previousBody.window = nil
end

-- Corrected on the first frame, once the config has been read.
moduleTable.watchFiles        = true
moduleTable.onSimulationFrame = onSimulationFrame
moduleTable.onMissionLoadEnd  = onMissionLoadEnd
moduleTable.onSimulationStop  = onSimulationStop

logLine("body built, handing callbacks to the loader")

return moduleTable
