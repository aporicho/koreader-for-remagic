-- ReMagic lifecycle v2 over the Manager-owned inherited descriptor. This is
-- the adapter's only lifecycle transport.

local Device = require("device")
local Event = require("ui/event")
local FileManager = require("apps/filemanager/filemanager")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local logger = require("logger")

if UIManager._remagic_lifecycle_v2_installed then return end
UIManager._remagic_lifecycle_v2_installed = true

local function is_decimal(value)
    return type(value) == "string" and value:match("^[0-9]+$") ~= nil
end

local app_id = os.getenv("REMAGIC_APP_ID") or "koreader"
local app_pid = os.getenv("REMAGIC_APP_PID")
local generation = os.getenv("REMAGIC_APP_GENERATION")
local fd_text = os.getenv("REMAGIC_LIFECYCLE_FD")
assert(app_id == "koreader", "ReMagic lifecycle app identity is invalid")
assert(is_decimal(app_pid), "REMAGIC_APP_PID is required")
assert(is_decimal(generation), "REMAGIC_APP_GENERATION is required")
assert(is_decimal(fd_text), "REMAGIC_LIFECYCLE_FD is required")

local ok_ffi, ffi = pcall(require, "ffi")
assert(ok_ffi, "ReMagic lifecycle requires LuaJIT FFI")
pcall(function()
    ffi.cdef[[
        long read(int fd, void *buf, unsigned long count);
        long write(int fd, const void *buf, unsigned long count);
        long recv(int fd, void *buf, unsigned long count, int flags);
        long send(int fd, const void *buf, unsigned long count, int flags);
        int fcntl(int fd, int command, ...);
    ]]
end)

local fd = tonumber(fd_text)
local flags = ffi.C.fcntl(fd, 3)
assert(flags >= 0, "REMAGIC_LIFECYCLE_FD is not open")
if math.floor(flags / 0x800) % 2 == 0 then
    assert(ffi.C.fcntl(fd, 4, ffi.new("int", flags + 0x800)) >= 0,
        "REMAGIC_LIFECYCLE_FD cannot be made nonblocking")
end
assert(math.floor(ffi.C.fcntl(fd, 3) / 0x800) % 2 == 1,
    "REMAGIC_LIFECYCLE_FD is blocking")

local ok_json, json = pcall(require, "dkjson")
assert(ok_json, "ReMagic lifecycle requires dkjson")
local support_dir = assert(os.getenv("REMAGIC_KOREADER_LIBEXEC_DIR"),
    "REMAGIC_KOREADER_LIBEXEC_DIR is required")
local new_protocol = assert(dofile(support_dir .. "/remagic-lifecycle-protocol.lua"))
local new_open_path = assert(dofile(support_dir .. "/remagic-open-path.lua"))

local foreground_epoch = tonumber(os.getenv("REMAGIC_FOREGROUND_EPOCH")) or 0
local lease_id = os.getenv("REMAGIC_DISPLAY_LEASE_ID")
local protocol = new_protocol({
    json = json,
    app_id = app_id,
    app_pid = app_pid,
    app_generation = generation,
    current_foreground_epoch = function() return foreground_epoch end,
    current_lease_id = function() return lease_id end,
    is_decimal = is_decimal,
})
local poll_seconds = tonumber(os.getenv("REMAGIC_KOREADER_POLL_SECONDS")) or 0.10
poll_seconds = math.max(0.05, math.min(poll_seconds, 1.0))
local exit_drain_seconds = tonumber(os.getenv("REMAGIC_KOREADER_EXIT_DRAIN_SECONDS")) or 0.05
exit_drain_seconds = math.max(0.01, math.min(exit_drain_seconds, 0.5))

local function log(level, event, detail)
    local message = "koreader-for-remagic: event=" .. event
        .. " pid=" .. app_pid .. " generation=" .. generation
    if detail then message = message .. " " .. detail end
    logger[level](message)
end

local outbound = {}
local inbound = ""
local polling = false

local function write_line(line)
    local payload = line .. "\n"
    local count = tonumber(ffi.C.send(fd, payload, #payload, 0x4000))
    if count < 0 and ffi.errno() == 88 then
        count = tonumber(ffi.C.write(fd, payload, #payload))
    end
    return count == #payload
end

local function flush_outbound()
    while outbound[1] do
        if not write_line(outbound[1]) then return false end
        table.remove(outbound, 1)
    end
    return true
end

local function emit_events(events)
    if #outbound + #events > 64 then
        log("warn", "lifecycle-outbound-overflow")
        return false
    end
    for _, item in ipairs(events) do
        local ok, encoded = pcall(protocol.encode_event, protocol, item.event, item.fields)
        if not ok then
            log("warn", "lifecycle-event-encode-failed", "event=" .. tostring(item.event))
            return false
        end
        outbound[#outbound + 1] = encoded
    end
    if not polling then flush_outbound() end
    return true
end

local function emit_event(event, fields)
    return emit_events({ { event = event, fields = fields } })
end

local function read_commands()
    local buffer = ffi.new("char[65536]")
    for _ = 1, 32 do
        local count = tonumber(ffi.C.recv(fd, buffer, 65535, 0x40))
        if count < 0 and ffi.errno() == 88 then
            count = tonumber(ffi.C.read(fd, buffer, 65535))
        end
        if not count or count <= 0 then break end
        inbound = inbound .. ffi.string(buffer, count)
    end
    if #inbound > 256 * 1024 then
        inbound = ""
        log("warn", "lifecycle-input-dropped", "reason=unterminated")
        return {}
    end
    local lines = {}
    while true do
        local boundary = inbound:find("\n", 1, true)
        if not boundary then break end
        local line = inbound:sub(1, boundary - 1):gsub("\r$", "")
        inbound = inbound:sub(boundary + 1)
        if line ~= "" then lines[#lines + 1] = line end
    end
    return lines
end

local function active_ui()
    local manager = FileManager.instance
    if manager and UIManager:isWidgetShown(manager) then return "filemanager", manager end
    local reader = ReaderUI.instance
    if reader and UIManager:isWidgetShown(reader) then return "reader", reader end
end

local ready_serial = 0
local next_ready_reason = "initial"
local function schedule_ready(kind, widget, reason)
    if not widget then return false end
    ready_serial = ready_serial + 1
    local serial = ready_serial
    reason = reason or next_ready_reason or "initial"
    next_ready_reason = nil
    local ok = pcall(UIManager.tickAfterNext, UIManager, function()
        if serial ~= ready_serial then return end
        local current_kind, current_widget = active_ui()
        if current_kind ~= kind or current_widget ~= widget then return end
        emit_event("ready", { ui = kind, reason = reason })
        log("info", "semantic-ready", "ui=" .. kind .. " reason=" .. reason)
    end)
    if not ok then
        emit_event("failed", { operation = "ready", reason = "schedule_failed" })
        return false
    end
    return true
end

local unpack_values = table.unpack or unpack
local function pack_values(...) return { n = select("#", ...), ... } end

local original_show_files = FileManager.showFiles
FileManager.showFiles = function(self, ...)
    local results = pack_values(original_show_files(self, ...))
    schedule_ready("filemanager", FileManager.instance)
    return unpack_values(results, 1, results.n)
end
local original_show_reader = ReaderUI.doShowReader
ReaderUI.doShowReader = function(self, ...)
    local results = pack_values(original_show_reader(self, ...))
    schedule_ready("reader", ReaderUI.instance)
    return unpack_values(results, 1, results.n)
end
local initial_kind, initial_widget = active_ui()
if initial_widget then schedule_ready(initial_kind, initial_widget, "initial") end

local shutdown_dispatched = false
local shutdown_waiting = false
local shutdown_complete = false
local shutdown_ui
local original_device_exit = Device.exit
Device.exit = function(self, ...)
    local results = pack_values(pcall(original_device_exit, self, ...))
    if results[1] and shutdown_dispatched and not shutdown_complete then
        shutdown_complete = true
        emit_events({
            { event = "state_saved", fields = { reason = "shutdown" } },
            { event = "shutdown_complete", fields = {
                ui = shutdown_ui, exit_code = tonumber(UIManager._exit_code) or 0,
            } },
        })
        flush_outbound()
        log("info", "shutdown-complete", "ui=" .. tostring(shutdown_ui))
    elseif not results[1] then
        emit_event("failed", { operation = "shutdown", reason = "device_exit_failed" })
        flush_outbound()
        error(results[2], 0)
    end
    return unpack_values(results, 2, results.n)
end

local function dispatch_shutdown()
    if shutdown_dispatched then return true end
    local kind, widget = active_ui()
    if not kind then shutdown_waiting = true return false end
    local saved, save_error = pcall(UIManager.flushSettings, UIManager)
    if not saved then
        emit_event("failed", { operation = "shutdown", reason = "save_failed" })
        log("warn", "shutdown-save-failed", "error=" .. tostring(save_error))
        return false
    end
    local sent, send_error = pcall(function()
        UIManager:broadcastEvent(Event:new("Exit"))
    end)
    if not sent then
        emit_event("failed", { operation = "shutdown", reason = "exit_dispatch_failed" })
        log("warn", "shutdown-dispatch-failed", "error=" .. tostring(send_error))
        return false
    end
    shutdown_dispatched = true
    shutdown_waiting = false
    shutdown_ui = kind
    UIManager:scheduleIn(exit_drain_seconds, function()
        if UIManager._exit_code ~= nil then return end
        local current_kind, current_widget = active_ui()
        if current_kind == kind and current_widget == widget then
            pcall(function()
                if kind == "reader" then widget:onClose(false) else widget:onClose() end
            end)
        end
        UIManager:quit(0)
    end)
    log("info", "shutdown-dispatched", "ui=" .. kind)
    return true
end

local open_path = new_open_path({
    UIManager = UIManager,
    FileManager = FileManager,
    ReaderUI = ReaderUI,
    allowed_roots = os.getenv("REMAGIC_ALLOWED_OPEN_ROOTS")
        or "/home/root/.local/share/koreader-for-remagic/library:/home/root/books:/home/root/koreader:/home/root/.local/share/remarkable/xochitl",
    get_ready_reason = function() return next_ready_reason end,
    set_ready_reason = function(value) next_ready_reason = value end,
    emit_failed = function(reason)
        emit_event("failed", { operation = "open_path", reason = reason })
    end,
    log = function(event, detail) log("warn", "open-path-" .. event, detail) end,
})

local backgrounded = false
local function enter_background()
    local saved, save_error = pcall(UIManager.flushSettings, UIManager)
    if not saved then
        emit_event("failed", { operation = "enter_background", reason = "save_failed" })
        log("warn", "background-save-failed", "error=" .. tostring(save_error))
        return false
    end
    if not emit_events({
        { event = "state_saved", fields = { reason = "background" } },
        { event = "background_ready" },
    }) then return false end
    backgrounded = true
    lease_id = nil
    log("info", "background-ready")
    return true
end

local function enter_foreground(body)
    local previous = { backgrounded, foreground_epoch, lease_id, next_ready_reason }
    backgrounded = false
    foreground_epoch = tonumber(body.foreground_epoch) or foreground_epoch
    lease_id = body._raw_lease_id or (body.lease_id and tostring(body.lease_id))
    local requested_path = body.open_path or body.path
    if requested_path and open_path(requested_path) then return true end
    if requested_path then
        backgrounded, foreground_epoch, lease_id, next_ready_reason = unpack_values(previous, 1, 4)
        return false
    end
    local resumed = pcall(function()
        local kind, widget = active_ui()
        assert(kind and widget, "no-active-main-ui")
        UIManager:setDirty("all", "ui")
        assert(schedule_ready(kind, widget, "resume"), "ready-schedule-failed")
    end)
    if not resumed then
        emit_event("failed", { operation = "enter_foreground", reason = "resume_failed" })
        backgrounded, foreground_epoch, lease_id, next_ready_reason = unpack_values(previous, 1, 4)
        return false
    end
    return true
end

local function handle_command(line)
    local envelope, _, decode_error = json.decode(line, 1, nil)
    if type(envelope) ~= "table" or envelope.protocol ~= 2
            or type(envelope.body) ~= "table" then
        log("warn", "lifecycle-command-ignored",
            "reason=" .. tostring(decode_error or "invalid-envelope"))
        return
    end
    local body = envelope.body
    body._raw_lease_id = line:match('"lease_id"%s*:%s*"?(%d+)"?')
    local matches, mismatch = protocol:matches_instance(line, body)
    if not matches then
        log("info", "lifecycle-command-ignored", "reason=stale-" .. mismatch)
        return
    end
    local command = protocol.normalized_command(body.command)
    local command_epoch = tonumber(line:match('"foreground_epoch"%s*:%s*"?(%d+)"?'))
    if command_epoch and command_epoch < foreground_epoch then
        log("info", "lifecycle-command-ignored", "reason=stale-foreground-epoch")
        return
    end
    if command ~= "enter_foreground" and lease_id and body._raw_lease_id
            and body._raw_lease_id ~= lease_id then
        log("info", "lifecycle-command-ignored", "reason=stale-lease")
        return
    end
    if command_epoch and command_epoch > foreground_epoch then foreground_epoch = command_epoch end
    if command == "enter_background" then
        enter_background()
    elseif command == "enter_foreground" then
        enter_foreground(body)
    elseif command == "open_path" then
        open_path(body.path or body.open_path)
    elseif command == "shutdown" then
        dispatch_shutdown()
    elseif command == "start" then
        local path = body.open_path or body.path
        if path and path ~= os.getenv("REMAGIC_INITIAL_OPEN_PATH") then open_path(path) end
    else
        log("warn", "lifecycle-command-ignored", "reason=unknown-command")
    end
end

local function poll()
    polling = true
    local ok, poll_error = xpcall(function()
        for _, line in ipairs(read_commands()) do handle_command(line) end
        if shutdown_waiting then dispatch_shutdown() end
        flush_outbound()
    end, debug.traceback)
    polling = false
    if not ok then log("warn", "lifecycle-poll-failed", "error=" .. tostring(poll_error)) end
    if not shutdown_dispatched then UIManager:scheduleIn(poll_seconds, poll) end
end

UIManager:scheduleIn(poll_seconds, poll)
log("info", "patch-active", "transport=fd")
