-- Remagic lifecycle v2 userpatch; readiness follows the first real UI repaint.

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
-- Remagic owns upgrades; the direct reader.lua wrapper cannot apply KOReader OTA.
Device.hasOTAUpdates = function() return false end
Device.hasOTARunning = function() return false end
-- The terminal plugin writes terminal.pid into the immutable program tree.
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
local lifecycle_support_dir = lifecycle_helper:match("^(.*)/[^/]+$") or "."
local lifecycle_async_module = os.getenv("REMAGIC_KOREADER_ASYNC_MODULE")
    or lifecycle_support_dir .. "/remagic-lifecycle-async.lua"
local lifecycle_protocol_module = os.getenv("REMAGIC_KOREADER_PROTOCOL_MODULE")
    or lifecycle_support_dir .. "/remagic-lifecycle-protocol.lua"
local open_path_module = os.getenv("REMAGIC_KOREADER_OPEN_PATH_MODULE")
    or lifecycle_support_dir .. "/remagic-open-path.lua"
local lifecycle_fd_text = os.getenv("REMAGIC_LIFECYCLE_FD")
local app_bridge = os.getenv("REMAGIC_APP_BRIDGE")
local poll_interval = tonumber(os.getenv("REMAGIC_KOREADER_POLL_SECONDS")) or 0.10
poll_interval = math.max(0.05, math.min(poll_interval, 5.0))
local bridge_poll_interval = tonumber(os.getenv("REMAGIC_KOREADER_BRIDGE_POLL_SECONDS")) or 1.0
bridge_poll_interval = math.max(0.25, math.min(bridge_poll_interval, 5.0))
local bridge_retry_interval = tonumber(os.getenv("REMAGIC_KOREADER_BRIDGE_RETRY_SECONDS")) or 1.0
bridge_retry_interval = math.max(0.25, math.min(bridge_retry_interval, 5.0))
local bridge_worker_timeout = tonumber(os.getenv("REMAGIC_KOREADER_BRIDGE_TIMEOUT_SECONDS")) or 2.0
bridge_worker_timeout = math.max(0.25, math.min(bridge_worker_timeout, 10.0))
local exit_drain_delay = tonumber(os.getenv("REMAGIC_KOREADER_EXIT_DRAIN_SECONDS")) or 0.05
exit_drain_delay = math.max(0.01, math.min(exit_drain_delay, 1.0))
local function is_decimal(value)
    return type(value) == "string" and value:match("^[0-9]+$") ~= nil
end

-- Reject unbound identities so late events cannot cross a fast relaunch.
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
local protocol_module_ok, new_protocol = pcall(dofile, lifecycle_protocol_module)
if not protocol_module_ok or type(new_protocol) ~= "function" then
    logger.warn("remagic-koreader: event=patch-disabled reason=protocol-module-unavailable")
    return
end
local open_module_ok, new_open_path = pcall(dofile, open_path_module)
if not open_module_ok or type(new_open_path) ~= "function" then
    logger.warn("remagic-koreader: event=patch-disabled reason=open-path-module-unavailable")
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
        -- Linux F_GETFL/F_SETFL/O_NONBLOCK; failure keeps the FD disabled.
        local configured, flags = pcall(function()
            local current_flags = ffi.C.fcntl(candidate, 3)
            local nonblocking_flags = current_flags
            if current_flags >= 0 and math.floor(current_flags / 0x800) % 2 == 0 then
                nonblocking_flags = current_flags + 0x800
            end
            -- A variadic F_SETFL needs typed cdata; verify O_NONBLOCK afterward.
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
local current_foreground_epoch = tonumber(os.getenv("REMAGIC_FOREGROUND_EPOCH")) or 0
local current_lease_id = os.getenv("REMAGIC_DISPLAY_LEASE_ID")
local protocol = new_protocol({
    json = json,
    app_id = app_id,
    app_pid = app_pid,
    app_generation = app_generation,
    current_foreground_epoch = function() return current_foreground_epoch end,
    current_lease_id = function() return current_lease_id end,
    is_decimal = is_decimal,
})
local legacy_transport = lifecycle_fd == nil and (not app_bridge or app_bridge == "")
local async_helper
if lifecycle_fd == nil then
    local ffiutil_ok, FFIUtil = pcall(require, "ffi/util")
    local module_ok, new_async_helper = pcall(dofile, lifecycle_async_module)
    if ffiutil_ok and module_ok and type(new_async_helper) == "function" then
        local created, adapter = pcall(new_async_helper, {
            ffiutil = FFIUtil,
            helper_path = lifecycle_helper,
            tick_seconds = poll_interval,
            poll_seconds = bridge_poll_interval,
            retry_seconds = bridge_retry_interval,
            timeout_seconds = bridge_worker_timeout,
            log = function(event, detail)
                instance_log("warn", "lifecycle-helper-" .. event, detail)
            end,
        })
        if created then
            async_helper = adapter
        else
            instance_log("warn", "lifecycle-helper-disabled",
                "reason=module-init-failed error=" .. tostring(adapter))
        end
    else
        instance_log("warn", "lifecycle-helper-disabled",
            "reason=async-module-unavailable")
    end
end
local helper_transport = lifecycle_fd == nil and not legacy_transport
    and async_helper ~= nil
if lifecycle_fd == nil and not legacy_transport and not async_helper then
    instance_log("warn", "lifecycle-bridge-disabled", "reason=async-helper-unavailable")
end
local runtime_dir = os.getenv("REMAGIC_RUNTIME_DIR") or "/run/remagic"
local legacy_exit_path = runtime_dir .. (runtime_dir:sub(-1) == "/" and "" or "/")
    .. "koreader-exit"
local legacy_identity = "pid=" .. app_pid .. "\ngeneration=" .. app_generation .. "\n"
local function send_line(line)
    if lifecycle_fd and ffi then
        local payload = line .. "\n"
        -- MSG_NOSIGNAL is safe for sockets; ENOTSOCK permits pipe-backed tests.
        local sent, written = pcall(function()
            local count = tonumber(ffi.C.send(lifecycle_fd, payload, #payload, 0x4000))
            if count < 0 and ffi.errno() == 88 then
                count = tonumber(ffi.C.write(lifecycle_fd, payload, #payload))
            end
            return count
        end)
        return sent and written == #payload
    end
    return false
end

local flush_outbound
local poll_in_progress = false
local function emit_events(events, final)
    if not final and #outbound + #events > 64 then
        instance_log("warn", "lifecycle-outbound-overflow",
            "count=" .. tostring(#events))
        return false
    end
    local encoded = {}
    for _, item in ipairs(events) do
        local ok, value = pcall(protocol.encode_event, protocol, item.event, item.fields)
        if not ok then
            instance_log("warn", "lifecycle-event-encode-failed",
                "event=" .. tostring(item.event) .. " error=" .. tostring(value))
            return false
        end
        encoded[#encoded + 1] = value
    end
    for _, value in ipairs(encoded) do
        outbound[#outbound + 1] = value
    end
    if flush_outbound and not poll_in_progress then
        local ok, error_value = pcall(flush_outbound)
        if not ok then
            instance_log("warn", "lifecycle-flush-failed",
                "error=" .. tostring(error_value))
        end
    end
    -- Queueing succeeds even when nonblocking delivery needs a later UI tick.
    return true
end

local function emit_event(event, fields)
    return emit_events({ { event = event, fields = fields } })
end

local function read_direct_commands()
    if not lifecycle_fd or not ffi then
        return ""
    end
    local chunks = {}
    local buffer = ffi.new("char[65536]")
    for _ = 1, 32 do
        local read_ok, count = pcall(function()
            -- MSG_DONTWAIT is authoritative for SOCK_SEQPACKET; ENOTSOCK keeps
            -- the pipe-backed compatibility test nonblocking via O_NONBLOCK.
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

flush_outbound = function()
    if lifecycle_fd and ffi then
        while outbound[1] do
            if not send_line(outbound[1]) then
                return false
            end
            table.remove(outbound, 1)
        end
        return true
    end
    if async_helper then
        return async_helper:pump_emit(outbound)
    end
    return false
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
        -- Schema v1 has only one cheap identity-bound shutdown marker.
        inbound_buffer = inbound_buffer .. read_legacy_commands()
    elseif helper_transport then
        -- The background adapter returns only already-completed child output.
        inbound_buffer = inbound_buffer .. async_helper:pump_poll()
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
    if not widget then return end
    readiness_serial = readiness_serial + 1
    local serial = readiness_serial
    reason = reason or next_ready_reason or "initial"
    next_ready_reason = nil

    local scheduled, schedule_error = pcall(UIManager.tickAfterNext, UIManager, function()
        local ok, callback_error = xpcall(function()
            if serial ~= readiness_serial then return end
            local current_kind, current_widget = active_main_ui()
            if current_kind ~= kind or current_widget ~= widget then return end
            emit_event("ready", { ui = kind, reason = reason })
            instance_log("info", "semantic-ready", "ui=" .. kind .. " reason=" .. reason)
        end, debug.traceback)
        if not ok then
            instance_log("warn", "semantic-ready-failed", "error=" .. tostring(callback_error))
            emit_event("failed", { operation = "enter_foreground", reason = "ready_failed" })
        end
    end)
    if not scheduled then
        instance_log("warn", "semantic-ready-schedule-failed", "error=" .. tostring(schedule_error))
        emit_event("failed", { operation = "ready", reason = "schedule_failed" })
        return false
    end
    return true
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

-- doShowReader() returns after the ReaderUI widget exists.
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

local function invoke_helper_async(mode)
    return async_helper and async_helper:invoke(mode) or false
end

local function emit_final_events(events)
    if lifecycle_fd and ffi then
        emit_events(events, true)
        return
    end
    local lines = {}
    for _, item in ipairs(events) do
        local ok, line = pcall(protocol.encode_event, protocol, item.event, item.fields)
        if ok then
            lines[#lines + 1] = line
        else
            instance_log("warn", "lifecycle-event-encode-failed",
                "event=" .. tostring(item.event) .. " error=" .. tostring(line))
        end
    end
    if async_helper then
        async_helper:emit_final(lines, outbound)
    end
end

local function cancel_bridge_poll()
    if async_helper then
        async_helper:cancel_poll()
    end
end

local function schedule_exit_drain(kind, widget)
    local scheduled, schedule_error = pcall(UIManager.scheduleIn, UIManager, exit_drain_delay,
        function()
        local drained, drain_error = xpcall(function()
            if UIManager._exit_code ~= nil then return end
            local current_kind, current_widget = active_main_ui()
            if current_kind == kind and current_widget == widget then
                local closed, close_error = pcall(function()
                    if kind == "reader" then widget:onClose(false) else widget:onClose() end
                end)
                if not closed then
                    instance_log("warn", "exit-main-close-failed", "error=" .. tostring(close_error))
                end
            end
            instance_log("info", "exit-drain-forced", "ui=" .. kind)
            UIManager:quit(0)
        end, debug.traceback)
        if not drained then
            instance_log("warn", "exit-drain-failed", "error=" .. tostring(drain_error))
        end
    end)
    if not scheduled then
        instance_log("warn", "exit-drain-schedule-failed",
            "error=" .. tostring(schedule_error))
    end
end
local shutdown_dispatched = false
local shutdown_waiting_for_ui = false
local shutdown_completion_emitted = false
local shutdown_ui

-- Completion follows the real Device:exit teardown, never merely Exit dispatch.
local original_device_exit = Device.exit
Device.exit = function(self, ...)
    if async_helper then pcall(async_helper.cancel_all, async_helper) end
    local results = pack_values(pcall(original_device_exit, self, ...))
    local succeeded = results[1]
    if succeeded and shutdown_dispatched and not shutdown_completion_emitted then
        shutdown_completion_emitted = true
        pcall(emit_final_events, {
            { event = "state_saved", fields = { reason = "shutdown" } },
            { event = "shutdown_complete", fields = {
                ui = shutdown_ui,
                exit_code = tonumber(UIManager._exit_code) or 0,
            } },
        })
        instance_log("info", "shutdown-complete", "ui=" .. tostring(shutdown_ui))
    end
    if not succeeded then
        pcall(emit_final_events, {
            { event = "failed", fields = {
                operation = "shutdown", reason = "device_exit_failed",
            } },
        })
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

    -- Persist the current page before teardown so failed exit recovery is durable.
    local saved, save_error = pcall(function()
        UIManager:flushSettings()
    end)
    if not saved then
        emit_event("failed", { operation = "shutdown", reason = "save_failed" })
        instance_log("warn", "shutdown-save-failed", "error=" .. tostring(save_error))
        return false
    end
    local ok, err = pcall(function()
        UIManager:broadcastEvent(Event:new("Exit"))
    end)
    if not ok then
        emit_event("failed", { operation = "shutdown", reason = "exit_dispatch_failed" })
        instance_log("warn", "shutdown-dispatch-failed", "error=" .. tostring(err))
        return false
    end

    shutdown_dispatched = true
    shutdown_waiting_for_ui = false
    shutdown_ui = kind
    if legacy then
        invoke_helper_async("consume-legacy-shutdown")
    end
    cancel_bridge_poll()
    schedule_exit_drain(kind, widget)
    instance_log("info", "shutdown-dispatched", "ui=" .. kind)
    return true
end

local open_path = new_open_path({
    UIManager = UIManager,
    FileManager = FileManager,
    ReaderUI = ReaderUI,
    allowed_roots = os.getenv("REMAGIC_ALLOWED_OPEN_ROOTS")
        or "/home/root/.local/share/remagic-koreader/library:/home/root/books:/home/root/koreader:/home/root/.local/share/remarkable/xochitl",
    get_ready_reason = function() return next_ready_reason end,
    set_ready_reason = function(value) next_ready_reason = value end,
    emit_failed = function(reason)
        emit_event("failed", { operation = "open_path", reason = reason })
    end,
    log = function(event, detail)
        instance_log("warn", "open-path-" .. event, detail)
    end,
})

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
    local previous_backgrounded = backgrounded
    backgrounded = true
    local queued = emit_events({
        { event = "state_saved", fields = { reason = "background" } },
        { event = "background_ready" },
    })
    if not queued then
        backgrounded = previous_backgrounded
        instance_log("warn", "background-notification-failed")
        return false
    end
    current_lease_id = nil
    instance_log("info", "background-ready")
    return true
end

local function enter_foreground(body)
    local previous_backgrounded = backgrounded
    local previous_foreground_epoch = current_foreground_epoch
    local previous_lease_id = current_lease_id
    local previous_ready_reason = next_ready_reason
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
            return true
        end
        backgrounded = previous_backgrounded
        current_foreground_epoch = previous_foreground_epoch
        current_lease_id = previous_lease_id
        next_ready_reason = previous_ready_reason
        return false
    end
    local resumed, resume_error = pcall(function()
        local kind, widget = active_main_ui()
        if not kind or not widget then
            error("no-active-main-ui", 0)
        end
        UIManager:setDirty("all", "ui")
        if not schedule_ready(kind, widget, "resume") then
            error("ready-schedule-failed", 0)
        end
    end)
    if not resumed then
        -- Report against the attempted fence before restoring retryable state.
        emit_event("failed", { operation = "enter_foreground", reason = "resume_failed" })
        backgrounded = previous_backgrounded
        current_foreground_epoch = previous_foreground_epoch
        current_lease_id = previous_lease_id
        next_ready_reason = previous_ready_reason
        instance_log("warn", "foreground-resume-failed",
            "error=" .. tostring(resume_error))
        return false
    end
    instance_log("info", "foreground-entered")
    return true
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
    local matches, mismatch = protocol:matches_instance(line, body)
    if not matches then
        instance_log("info", "lifecycle-command-ignored", "reason=stale-" .. mismatch)
        return
    end
    local command = protocol.normalized_command(body.command)
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
    poll_in_progress = true
    local ok, error_value = xpcall(function()
        for _, line in ipairs(read_commands()) do
            local handled, command_error = xpcall(function()
                handle_command(line)
            end, debug.traceback)
            if not handled then
                instance_log("warn", "lifecycle-command-failed",
                    "error=" .. tostring(command_error))
                emit_event("failed", { operation = "lifecycle_command", reason = "callback_failed" })
            end
        end
        if shutdown_waiting_for_ui then dispatch_shutdown(false) end
        flush_outbound()
    end, debug.traceback)
    poll_in_progress = false
    if not ok then
        instance_log("warn", "lifecycle-poll-failed", "error=" .. tostring(error_value))
    end
    if not shutdown_dispatched then
        local scheduled, schedule_error = pcall(function()
            UIManager:scheduleIn(poll_interval, poll_lifecycle)
        end)
        if not scheduled then
            instance_log("warn", "lifecycle-poll-schedule-failed",
                "error=" .. tostring(schedule_error))
        end
    end
end

UIManager:scheduleIn(poll_interval, poll_lifecycle)
instance_log("info", "patch-active",
    lifecycle_fd and "transport=fd"
        or (legacy_transport and "transport=legacy"
            or (helper_transport and "transport=bridge" or "transport=disabled")))
