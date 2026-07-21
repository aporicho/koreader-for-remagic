-- Keep KOReader runtime metadata in DataStorage when the immutable program
-- directory and writable KO_HOME are separate. This early userpatch runs
-- before reader.lua first calls Version:updateVersionLog().

local DataStorage = require("datastorage")
local Version = require("version")

local version_log = DataStorage:getDataDir() .. "/version.log"

function Version:getLastLogLine()
    local log_file = io.open(version_log, "r")
    if not log_file then
        return ""
    end
    local last_log_line
    for line in log_file:lines() do
        last_log_line = line
    end
    log_file:close()
    return last_log_line or ""
end

function Version:appendToLogFile(text)
    local log_file = io.open(version_log, "a")
    if not log_file then
        return
    end
    log_file:write(text, "\n")
    log_file:close()
    return true
end
