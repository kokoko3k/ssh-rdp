local mp = require "mp"
local msg = require "mp.msg"

-- Description
-- ========================================
-- Since ssh-rdp works on ssh and tcp, when a packet is late for whatever reason,
-- It will be internally buffered either by TCP algorithms or by ssh itself.
-- If the reading speed stay costant, audio latency may increase over time.
-- So this script modulates playback speed so that the playback buffer
-- oscillates around a target value.
-- The idea is to enable mpv readahead cache and then consume it faster
-- as it gets bigger by modulating the playback speed according to
-- the "queue" size.


-- Script configuration
-- ========================================

-- This script needs demuxer readahead
local READAHEAD_SECS = 10

-- Try to keep the following readahead buffer
-- 1500 is good for per 2ch pcm, 800 is good for a 128kbps opus stream.
-- If you hear dropouts, try to increase this value.
local BUFFER_TARGET = 1500

-- K is a factor that expresses how aggressive is the adaption speed.
-- There should be no need to make it high, as the adaption speed
-- increases as the readahead buffer gets higher.
local K = 0.05

-- This is the minimum speed to keep when the current buffered data is lower than
-- the target buffer.
local MIN_SPEED = 0.999

-- This is the maximum speed used to consume the buffer when it is higher
-- than the target buffer.
local MAX_SPEED = 100.0

-- Monitoring interval in secs: 0.2 seems a good value
-- but if you hear dropouts, you may want to lower it.
-- It may have an impact on cpu use.
local INTERVAL = 0.2



-- MPV Configuration
-- ========================================

mp.set_property_number(
    "demuxer-readahead-secs",
    READAHEAD_SECS
)

msg.verbose(string.format(
    "[BUFFER-SPEED] demuxer-readahead-secs=%d",
    READAHEAD_SECS
))


local current_speed = nil


-- Adaption speed computation
-- ========================================

local function calculate_speed(total_bytes)

    local error =
        (total_bytes - BUFFER_TARGET) / BUFFER_TARGET

    local speed = 1.0 + K * error

    return math.min(math.max(speed, MIN_SPEED), MAX_SPEED)
    
end

-- Main buffer monironing timer
-- ========================================

mp.add_periodic_timer(INTERVAL, function()

    local state =
        mp.get_property_native("demuxer-cache-state")

    if not state then
        return
    end

    local total_bytes = state["total-bytes"]

    if total_bytes == nil then
        return
    end

    local speed = calculate_speed(total_bytes)

    -- Change speed, log it any speed change.
    if current_speed == nil
        or math.abs(current_speed - speed) > 0.0001 then

        current_speed = speed

        mp.set_property_number("speed", speed)

        msg.verbose(string.format(
            "[BUFFER-SPEED] speed=%.4f | buffer=%d | target=%d",
            speed,
            total_bytes,
            BUFFER_TARGET
        ))
    end
end)