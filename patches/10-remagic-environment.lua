-- ReMagic keeps the official KOReader release tree read-only. Redirect the one
-- upstream version log that is otherwise package-relative into KO_HOME.

local DataStorage = require("datastorage")
local Version = require("version")
local CanvasContext = require("document/canvascontext")
local version_log = DataStorage:getDataDir() .. "/version.log"

-- On reMarkable the upstream device advertises system fonts, which makes
-- FontList ignore EXT_FONT_DIR. In the managed runtime the adapter owns the
-- complete external font list, so select KOReader's existing EXT_FONT_DIR path
-- after CanvasContext has copied the device capability methods.
if os.getenv("REMAGIC_MANAGED") == "1" and (os.getenv("EXT_FONT_DIR") or "") ~= "" then
    local original_init = CanvasContext.init
    function CanvasContext:init(...)
        local result = original_init(self, ...)
        self.hasSystemFonts = function() return false end
        return result
    end
end

function Version:getLastLogLine()
    local log_file = io.open(version_log, "r")
    if not log_file then return "" end
    local last_line
    for line in log_file:lines() do last_line = line end
    log_file:close()
    return last_line or ""
end

function Version:appendToLogFile(text)
    local log_file = io.open(version_log, "a")
    if not log_file then return end
    log_file:write(text, "\n")
    log_file:close()
    return true
end
