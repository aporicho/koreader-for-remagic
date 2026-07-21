-- Remagic lifecycle protocol v2 bridge for KOReader.
--
-- The patch is loaded at userpatch priority 2: UIManager is available, while
-- the initial FileManager/ReaderUI has not yet been created. Readiness is
-- deliberately published only after the first repaint of a real main UI.

local Event = require("ui/event")
local Device = require("device")
local FileManager = require("apps/filemanager/filemanager")
local logger = require("logger")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")

if UIManager._remagic_runtime_patch_installed then
    logger.info("remagic-koreader: event=patch-already-installed")
    return
end
UIManager._remagic_runtime_patch_installed = true

-- Remagic owns application upgrades; the direct reader.lua wrapper never runs
-- upstream koreader.sh's OTA extraction loop. Hide the unusable OTA action so
-- it cannot download an archive that will never be installed.
Device.hasOTAUpdates = function() return false end
Device.hasOTARunning = function() return false end

-- The upstream terminal plugin writes terminal.pid relative to the immutable
-- program directory. Keep it disabled in the managed runtime, including for a
-- standalone adapter install where the bundle has not removed the plugin.
local plugin_loader_ok, PluginLoader = pcall(require, "pluginloader")
if plugin_loader_ok and not PluginLoader._remagic_restrictions_installed then
    PluginLoader._remagic_restrictions_installed = true
    local original_discover = PluginLoader._discover
    PluginLoader._discover = function(self, ...)
        local discovered = original_discover(self, ...)
        for _, plugin in ipairs(discovered) do
            if plugin.name == "terminal.koplugin"
                    or (type(plugin.path) == "string"
                        and plugin.path:match("/terminal%.koplugin$")) then
                plugin.main = plugin.meta
                plugin.disabled = true
            end
        end
        return discovered
    end
end

local app_id = os.getenv("REMAGIC_APP_ID") or "koreader"
local app_pid = os.getenv("REMAGIC_APP_PID")
local app_generation = os.getenv("REMAGIC_APP_GENERATION")
local lifecycle_helper = os.getenv("REMAGIC_KOREADER_LIFECYCLE_HELPER")
    or "/home/root/apps/remagic-koreader/libexec/koreader-lifecycle"
local lifecycle_fd_text = os.getenv("REMAGIC_LIFECYCLE_FD")
local app_bridge = os.getenv("REMAGIC_APP_BRIDGE")
local poll_interval = tonumber(os.getenv("REMAGIC_KOREADER_POLL_SECONDS")) or 0.10
poll_interval = math.max(0.05, math.min(poll_interval, 5.0))
local exit_drain_delay = tonumber(os.getenv("REMAGIC_KOREADER_EXIT_DRAIN_SECONDS")) or 0.05
exit_drain_delay = math.max(0.01, math.min(exit_drain_delay, 1.0))

local function is_decimal(value)
    return type(value) == "string" and value:match("^[0-9]+$") ~= nil
end

-- Every lifecycle message must be bound to one manager-created generation.
-- Otherwise a late event could be accepted after a fast close/relaunch cycle.
if app_id ~= "koreader" or not is_decimal(app_pid) or not is_decimal(app_generation) then
    logger.warn("remagic-koreader: event=patch-disabled reason=invalid-instance-identity")
    return
end

local ok_json, json = pcall(require, "dkjson")
if not ok_json then
    logger.warn("remagic-koreader: event=patch-disabled reason=json-unavailable error="
        .. tostring(json))
    return
end

local function instance_log(level, event, detail)
    local message = "remagic-koreader: event=" .. event
        .. " pid=" .. app_pid .. " generation=" .. app_generation
    if detail then
        message = message .. " " .. detail
    end
    logger[level](message)
end

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local lifecycle_fd
local ffi
if is_decimal(lifecycle_fd_text) then
    local ok_ffi, loaded_ffi = pcall(require, "ffi")
    if ok_ffi then
        ffi = loaded_ffi
        pcall(function()
            ffi.cdef[[
                long read(int fd, void *buf, unsigned long count);
                long write(int fd, const void *buf, unsigned long count);
                long recv(int fd, void *buf, unsigned long count, int flags);
                long send(int fd, const void *buf, unsigned long count, int flags);
                int fcntl(int fd, int command, ...);
            ]]
        end)
        local candidate = tonumber(lifecycle_fd_text)
        -- Linux F_GETFL/F_SETFL/O_NONBLOCK. Failure leaves the bridge/helper
        -- fallback active instead of risking a blocking UI thread.
        local configured, flags = pcall(function()
            local current_flags = ffi.C.fcntl(candidate, 3)
            local nonblocking_flags = current_flags
            if current_flags >= 0 and math.floor(current_flags / 0x800) % 2 == 0 then
                nonblocking_flags = current_flags + 0x800
            end
            -- fcntl is variadic. LuaJIT passes a plain Lua number as a C
            -- double in a vararg slot, so F_SETFL must receive typed cdata.
            -- Re-read the flags as well: a successful return alone does not
            -- prove that a malformed vararg preserved O_NONBLOCK.
            if current_flags < 0
                    or ffi.C.fcntl(candidate, 4, ffi.new("int", nonblocking_flags)) < 0 then
                return nil
            end
            local verified_flags = ffi.C.fcntl(candidate, 3)
            if verified_flags < 0 or math.floor(verified_flags / 0x800) % 2 == 0 then
                return nil
            end
            return verified_flags
        end)
        if configured and flags then
            lifecycle_fd = candidate
        else
            ffi = nil
            instance_log("warn", "lifecycle-fd-disabled", "reason=fcntl-failed")
        end
    else
        instance_log("warn", "lifecycle-fd-disabled", "reason=ffi-unavailable")
    end
end

local outbound = {}
local inbound_buffer = ""
local event_sequence = 0
local current_foreground_epoch = tonumber(os.getenv("REMAGIC_FOREGROUND_EPOCH")) or 0
local current_lease_id = os.getenv("REMAGIC_DISPLAY_LEASE_ID")
local legacy_transport = lifecycle_fd == nil and (not app_bridge or app_bridge == "")
local runtime_dir = os.getenv("REMAGIC_RUNTIME_DIR") or "/run/remagic"
local legacy_exit_path = runtime_dir .. (runtime_dir:sub(-1) == "/" and "" or "/")
    .. "koreader-exit"
local legacy_identity = "pid=" .. app_pid .. "\ngeneration=" .. app_generation .. "\n"

local function helper_pipe(mode, pipe_mode)
    local command = shell_quote(lifecycle_helper) .. " " .. mode
    return io.popen(command, pipe_mode)
end

local function send_via_helper(line)
    local process = helper_pipe("emit", "w")
    if not process then
        return false
    end
    local wrote = process:write(line, "\n")
    local closed = process:close()
    return wrote ~= nil and closed ~= nil
end

local function send_line(line)
    if lifecycle_fd and ffi then
        local payload = line .. "\n"
        -- MSG_NOSIGNAL prevents a closed supervisor socket from terminating
        -- KOReader. ENOTSOCK (88) permits pipe-based test/transition hosts.
        local sent, written = pcall(function()
            local count = tonumber(ffi.C.send(lifecycle_fd, payload, #payload, 0x4000))
            if count < 0 and ffi.errno() == 88 then
                count = tonumber(ffi.C.write(lifecycle_fd, payload, #payload))
            end
            return count
        end)
        return sent and written == #payload
    end
    return send_via_helper(line)
end

local function flush_outbound()
    while outbound[1] do
        if not send_line(outbound[1]) then
            return false
        end
        table.remove(outbound, 1)
    end
    return true
end

local function encode_envelope(event, fields)
    event_sequence = event_sequence + 1
    local generation_sentinel = "__REMAGIC_GENERATION__"
    local lease_sentinel = "__REMAGIC_LEASE_ID__"
    local body = {
        event = event,
        app_id = app_id,
        generation = generation_sentinel,
        foreground_epoch = current_foreground_epoch,
    }
    if is_decimal(current_lease_id) then
        body.lease_id = lease_sentinel
    end
    if fields then
        for key, value in pairs(fields) do
            body[key] = value
        end
    end
    local envelope = {
        protocol = 2,
        request_id = "koreader-" .. app_pid .. "-" .. app_generation
            .. "-" .. tostring(event_sequence),
        body = body,
    }
    local encoded = json.encode(envelope)
    -- dkjson represents large Lua numbers through floating point. Inject the
    -- manager's already validated decimal generation verbatim to preserve u64.
    encoded = encoded:gsub('"' .. generation_sentinel .. '"', app_generation, 1)
    if is_decimal(current_lease_id) then
        encoded = encoded:gsub('"' .. lease_sentinel .. '"', current_lease_id, 1)
    end
    return encoded
end

local function emit_event(event, fields)
    if #outbound >= 64 then
        instance_log("warn", "lifecycle-outbound-overflow", "event=" .. event)
        return false
    end
    outbound[#outbound + 1] = encode_envelope(event, fields)
    return flush_outbound()
end

local function read_direct_commands()
    if not lifecycle_fd or not ffi then
        return ""
    end
    local chunks = {}
    local buffer = ffi.new("char[65536]")
    for _ = 1, 32 do
        local read_ok, count = pcall(function()
            -- The production lifecycle transport is SOCK_SEQPACKET.  Use a
            -- per-call nonblocking flag as the final authority: relying only
            -- on fcntl state allowed the second read after Start to block the
            -- UI thread indefinitely on this device.  ENOTSOCK keeps the
            -- pipe-backed compatibility test path working.
            local received = tonumber(ffi.C.recv(lifecycle_fd, buffer, 65535, 0x40))
            if received < 0 and ffi.errno() == 88 then
                received = tonumber(ffi.C.read(lifecycle_fd, buffer, 65535))
            end
            return received
        end)
        if not read_ok then
            instance_log("warn", "lifecycle-fd-read-failed", "reason=ffi-call")
            break
        end
        if not count or count <= 0 then
            break
        end
        chunks[#chunks + 1] = ffi.string(buffer, count)
    end
    return table.concat(chunks)
end

local function read_helper_commands()
    local process = helper_pipe("poll", "r")
    if not process then
        return ""
    end
    local contents = process:read(256 * 1024 + 1) or ""
    process:close()
    if #contents > 256 * 1024 then
        instance_log("warn", "lifecycle-input-dropped", "reason=oversize")
        return ""
    end
    return contents
end

local function read_legacy_commands()
    local file = io.open(legacy_exit_path, "rb")
    if not file then
        return ""
    end
    local requested_identity = file:read("*a")
    file:close()
    if requested_identity ~= legacy_identity then
        return ""
    end
    return '{"protocol":2,"request_id":"legacy-koreader-' .. app_pid .. "-"
        .. app_generation .. '-shutdown","body":{"command":"shutdown",'
        .. '"app_id":"koreader","generation":' .. app_generation
        .. ',"legacy":true}}\n'
end

local function read_commands()
    if lifecycle_fd then
        inbound_buffer = inbound_buffer .. read_direct_commands()
    elseif legacy_transport then
        -- Keep schema-v1 compatibility off the process-spawning bridge path:
        -- the old manager has no command stream, only one identity-bound file.
        -- This isolated fallback performs the same cheap read as the original
        -- integration and disappears as soon as a v2 transport is supplied.
        inbound_buffer = inbound_buffer .. read_legacy_commands()
    else
        inbound_buffer = inbound_buffer .. read_helper_commands()
    end

    local lines = {}
    while true do
        local boundary = inbound_buffer:find("\n", 1, true)
        if not boundary then
            break
        end
        local line = inbound_buffer:sub(1, boundary - 1):gsub("\r$", "")
        inbound_buffer = inbound_buffer:sub(boundary + 1)
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end
    if #inbound_buffer > 256 * 1024 then
        inbound_buffer = ""
        instance_log("warn", "lifecycle-input-dropped", "reason=unterminated")
    end
    return lines
end

local function active_main_ui()
    local file_manager = FileManager.instance
    if file_manager and UIManager:isWidgetShown(file_manager) then
        return "filemanager", file_manager
    end
    local reader = ReaderUI.instance
    if reader and UIManager:isWidgetShown(reader) then
        return "reader", reader
    end
end

local readiness_serial = 0
local next_ready_reason = "initial"

local function schedule_ready(kind, widget, reason)
    if not widget then
        return
    end
    readiness_serial = readiness_serial + 1
    local serial = readiness_serial
    reason = reason or next_ready_reason or "initial"
    next_ready_reason = nil

    -- tickAfterNext runs after _repaint(), unlike nextTick. The manager can
    -- therefore reveal KOReader without exposing an uninitialized/blank page.
    UIManager:tickAfterNext(function()
        if serial ~= readiness_serial then
            return
        end
        local current_kind, current_widget = active_main_ui()
        if current_kind ~= kind or current_widget ~= widget then
            return
        end
        emit_event("ready", { ui = kind, reason = reason })
        instance_log("info", "semantic-ready", "ui=" .. kind .. " reason=" .. reason)
    end)
end

local unpack_values = table.unpack or unpack
local function pack_values(...)
    return { n = select("#", ...), ... }
end

local original_show_files = FileManager.showFiles
FileManager.showFiles = function(self, ...)
    local results = pack_values(original_show_files(self, ...))
    schedule_ready("filemanager", FileManager.instance)
    return unpack_values(results, 1, results.n)
end

-- showReader() only starts a coroutine. doShowReader() returns after the
-- ReaderUI widget exists, including any password prompt handling.
local original_do_show_reader = ReaderUI.doShowReader
ReaderUI.doShowReader = function(self, ...)
    local results = pack_values(original_do_show_reader(self, ...))
    schedule_ready("reader", ReaderUI.instance)
    return unpack_values(results, 1, results.n)
end

local initial_kind, initial_widget = active_main_ui()
if initial_widget then
    schedule_ready(initial_kind, initial_widget, "initial")
end

local function invoke_helper(mode)
    local process = helper_pipe(mode, "r")
    if not process then
        return false
    end
    process:read("*a")
    return process:close() ~= nil
end

local function schedule_exit_drain(kind, widget)
    UIManager:scheduleIn(exit_drain_delay, function()
        if UIManager._exit_code ~= nil then
            return
        end
        local current_kind, current_widget = active_main_ui()
        if current_kind == kind and current_widget == widget then
            local closed, close_error = pcall(function()
                if kind == "reader" then
                    widget:onClose(false)
                else
                    widget:onClose()
                end
            end)
            if not closed then
                instance_log("warn", "exit-main-close-failed",
                    "error=" .. tostring(close_error))
            end
        end
        instance_log("info", "exit-drain-forced", "ui=" .. kind)
        UIManager:quit(0)
    end)
end

local shutdown_dispatched = false
local shutdown_waiting_for_ui = false
local shutdown_completion_emitted = false
local shutdown_ui

-- A lifecycle shutdown is complete only after KOReader's real Device:exit has
-- flushed settings, closed the display backend and torn down input. Emitting
-- before this point lets a supervisor mistake an in-flight exit for a durable
-- one. Preserve all return values and never acknowledge a failed device exit.
local original_device_exit = Device.exit
Device.exit = function(self, ...)
    local results = pack_values(pcall(original_device_exit, self, ...))
    local succeeded = results[1]
    if succeeded and shutdown_dispatched and not shutdown_completion_emitted then
        shutdown_completion_emitted = true
        emit_event("state_saved", { reason = "shutdown" })
        emit_event("shutdown_complete", {
            ui = shutdown_ui,
            exit_code = tonumber(UIManager._exit_code) or 0,
        })
        instance_log("info", "shutdown-complete", "ui=" .. tostring(shutdown_ui))
    end
    if not succeeded then
        error(results[2], 0)
    end
    return unpack_values(results, 2, results.n)
end

local function dispatch_shutdown(legacy)
    if shutdown_dispatched then
        return true
    end
    local kind, widget = active_main_ui()
    if not kind then
        if not shutdown_waiting_for_ui then
            shutdown_waiting_for_ui = true
            instance_log("info", "shutdown-waiting-for-ui")
        end
        return false
    end

    local ok, err = pcall(function()
        UIManager:broadcastEvent(Event:new("Exit"))
    end)
    if not ok then
        instance_log("warn", "shutdown-dispatch-failed", "error=" .. tostring(err))
        return false
    end

    shutdown_dispatched = true
    shutdown_waiting_for_ui = false
    shutdown_ui = kind
    if legacy then
        invoke_helper("consume-legacy-shutdown")
    end
    schedule_exit_drain(kind, widget)
    instance_log("info", "shutdown-dispatched", "ui=" .. kind)
    return true
end

local function normalized_command(value)
    if type(value) ~= "string" then
        return nil
    end
    return value:gsub("%-", "_"):gsub("(%l)(%u)", "%1_%2"):lower()
end

local function command_matches_instance(line, body)
    if body.app_id ~= app_id then
        return false, "app-id"
    end
    -- Compare the exact source bytes, not a Lua double, to preserve u64.
    local raw_generation = line:match('"generation"%s*:%s*"?(%d+)"?')
    if raw_generation ~= app_generation then
        return false, "generation"
    end
    return true
end

local function path_allowed(path)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("%z") then
        return false
    end
    if path:find("/%.%./", 1, false) or path:match("/%.%.$") then
        return false
    end
    local roots = os.getenv("REMAGIC_ALLOWED_OPEN_ROOTS")
        or "/home/root/.local/share/remagic-koreader/library:/home/root/books:/home/root/koreader:/home/root/.local/share/remarkable/xochitl"
    for root in roots:gmatch("[^:]+") do
        local normalized_root = root:gsub("/+$", "")
        if path == normalized_root
            or path:sub(1, #normalized_root + 1) == normalized_root .. "/"
        then
            return true
        end
    end
    return false
end

local function open_path(path)
    if not path_allowed(path) then
        emit_event("failed", { operation = "open_path", reason = "path_not_allowed" })
        return false
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local attributes = ok_lfs and lfs.attributes(path) or nil
    if not attributes then
        emit_event("failed", { operation = "open_path", reason = "path_not_found" })
        return false
    end

    next_ready_reason = "open_path"
    if attributes.mode == "directory" then
        local active_reader = ReaderUI.instance
        if active_reader and UIManager:isWidgetShown(active_reader) then
            local closed, close_error = pcall(function()
                active_reader:onClose()
            end)
            if not closed then
                next_ready_reason = nil
                emit_event("failed", { operation = "open_path", reason = "close_reader_failed" })
                instance_log("warn", "open-path-close-reader-failed",
                    "error=" .. tostring(close_error))
                return false
            end
        end
        FileManager:showFiles(path)
    elseif attributes.mode == "file" then
        ReaderUI:showReader(path)
    else
        next_ready_reason = nil
        emit_event("failed", { operation = "open_path", reason = "unsupported_path" })
        return false
    end
    return true
end

local backgrounded = false
local function enter_background()
    local ok, err = pcall(function()
        UIManager:flushSettings()
    end)
    if not ok then
        emit_event("failed", { operation = "enter_background", reason = "save_failed" })
        instance_log("warn", "background-save-failed", "error=" .. tostring(err))
        return false
    end
    backgrounded = true
    emit_event("state_saved", { reason = "background" })
    emit_event("background_ready")
    current_lease_id = nil
    instance_log("info", "background-ready")
    return true
end

local function enter_foreground(body)
    backgrounded = false
    if body.foreground_epoch then
        current_foreground_epoch = tonumber(body.foreground_epoch) or current_foreground_epoch
    end
    if body._raw_lease_id then
        current_lease_id = body._raw_lease_id
    elseif body.lease_id then
        current_lease_id = tostring(body.lease_id)
    end
    local requested_path = body.open_path or body.path
    if requested_path then
        if open_path(requested_path) then
            instance_log("info", "foreground-entered", "open_path=true")
        end
        return
    end
    local kind, widget = active_main_ui()
    if kind and widget then
        UIManager:setDirty("all", "ui")
        schedule_ready(kind, widget, "resume")
    end
    instance_log("info", "foreground-entered")
end

local function handle_command(line)
    local decoded, _, decode_error = json.decode(line, 1, nil)
    if type(decoded) ~= "table" or decoded.protocol ~= 2 or type(decoded.body) ~= "table" then
        instance_log("warn", "lifecycle-command-ignored",
            "reason=" .. tostring(decode_error or "invalid-envelope"))
        return
    end
    local body = decoded.body
    body._raw_lease_id = line:match('"lease_id"%s*:%s*"?(%d+)"?')
    local matches, mismatch = command_matches_instance(line, body)
    if not matches then
        instance_log("info", "lifecycle-command-ignored", "reason=stale-" .. mismatch)
        return
    end
    local command = normalized_command(body.command)
    local command_epoch = tonumber(line:match('"foreground_epoch"%s*:%s*"?(%d+)"?'))
    if command == "enter_foreground" then
        if command_epoch and command_epoch < current_foreground_epoch then
            instance_log("info", "lifecycle-command-ignored", "reason=stale-foreground-epoch")
            return
        end
    else
        if current_foreground_epoch > 0 and command_epoch
            and command_epoch < current_foreground_epoch
        then
            instance_log("info", "lifecycle-command-ignored", "reason=stale-foreground-epoch")
            return
        end
        if command_epoch and command_epoch > current_foreground_epoch then
            current_foreground_epoch = command_epoch
            current_lease_id = body._raw_lease_id
        elseif current_lease_id and body._raw_lease_id
            and body._raw_lease_id ~= current_lease_id
        then
            instance_log("info", "lifecycle-command-ignored", "reason=stale-lease")
            return
        end
        if not current_lease_id and body._raw_lease_id then
            current_lease_id = body._raw_lease_id
        end
    end
    if command == "enter_background" then
        enter_background()
    elseif command == "enter_foreground" then
        enter_foreground(body)
    elseif command == "open_path" then
        open_path(body.path or body.open_path)
    elseif command == "shutdown" then
        dispatch_shutdown(body.legacy == true)
    elseif command == "start" then
        local requested_path = body.open_path or body.path
        if requested_path
                and requested_path ~= os.getenv("REMAGIC_INITIAL_OPEN_PATH") then
            open_path(requested_path)
        elseif requested_path then
            instance_log("info", "start-open-path-preapplied")
        end
    else
        instance_log("warn", "lifecycle-command-ignored",
            "reason=unknown-command command=" .. tostring(command))
    end
end

local poll_lifecycle
poll_lifecycle = function()
    flush_outbound()
    for _, line in ipairs(read_commands()) do
        handle_command(line)
    end
    if not shutdown_dispatched then
        UIManager:scheduleIn(poll_interval, poll_lifecycle)
    end
end

UIManager:scheduleIn(poll_interval, poll_lifecycle)
instance_log("info", "patch-active",
    lifecycle_fd and "transport=fd"
        or (legacy_transport and "transport=legacy" or "transport=bridge"))
