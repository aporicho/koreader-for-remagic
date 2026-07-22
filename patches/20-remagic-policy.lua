-- ReMagic Manager owns application upgrades and does not provide a terminal
-- sandbox. Apply those two policies through KOReader's supported settings and
-- device capability surfaces without changing the official plugin tree.

local Device = require("device")
local logger = require("logger")

Device.hasOTAUpdates = function() return false end
Device.hasOTARunning = function() return false end

local disabled = G_reader_settings:readSetting("plugins_disabled")
if type(disabled) ~= "table" then disabled = {} end
if disabled.terminal ~= true then
    disabled.terminal = true
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    logger.info("koreader-for-remagic: event=policy-terminal-disabled")
end
