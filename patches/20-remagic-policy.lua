-- ReMagic Manager owns application upgrades and does not provide a terminal
-- sandbox. Apply those two policies through KOReader's supported settings and
-- device capability surfaces without changing the official plugin tree.

local Device = require("device")
local logger = require("logger")

Device.hasOTAUpdates = function() return false end
Device.hasOTARunning = function() return false end

-- The managed wrapper may keep KOReader's active startup copy outside /tmp
-- (notably in the isolated acceptance root). Upstream hard-codes /tmp here and
-- would otherwise display a modal restart prompt before FileManager exists,
-- making semantic readiness impossible. The wrapper has already atomically
-- copied and verified this file; retain upstream's MD5 comparison but use the
-- declared managed path.
local active_startup = os.getenv("KOREADER_ACTIVE_STARTUP_SCRIPT")
if os.getenv("REMAGIC_MANAGED") == "1" and active_startup and active_startup ~= "" then
    local md5 = require("ffi/MD5")
    Device.isStartupScriptUpToDate = function()
        return md5.sumFile(active_startup) == md5.sumFile("koreader.sh")
    end
end

local disabled = G_reader_settings:readSetting("plugins_disabled")
if type(disabled) ~= "table" then disabled = {} end
if disabled.terminal ~= true then
    disabled.terminal = true
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    logger.info("koreader-for-remagic: event=policy-terminal-disabled")
end
