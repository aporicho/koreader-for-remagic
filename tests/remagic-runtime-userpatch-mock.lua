local patch_path = assert(arg[1], "patch path is required")
local mode = assert(arg[2], "test mode is required")

local function fail(message)
    error("FAIL: " .. message, 0)
end

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        fail((message or "values differ") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
    end
end

local logs = {}
local function log(...)
    local fields = {}
    for i = 1, select("#", ...) do
        fields[#fields + 1] = tostring(select(i, ...))
    end
    logs[#logs + 1] = table.concat(fields, " ")
end

local logger = { info = log, warn = log, err = log, dbg = log }
local Device = {
    exit_count = 0,
    hasOTAUpdates = function() return true end,
    hasOTARunning = function() return true end,
}
function Device:exit()
    self.exit_count = self.exit_count + 1
    if self.fail_exit then
        error("mock device exit failed")
    end
    return "device-exit-result"
end
local PluginLoader = {}
function PluginLoader:_discover()
    return {
        {
            name = "terminal.koplugin",
            path = "/program/plugins/terminal.koplugin",
            main = "/program/plugins/terminal.koplugin/main.lua",
            meta = "/program/plugins/terminal.koplugin/_meta.lua",
            disabled = false,
        },
        {
            name = "statistics.koplugin",
            path = "/program/plugins/statistics.koplugin",
            main = "/program/plugins/statistics.koplugin/main.lua",
            meta = "/program/plugins/statistics.koplugin/_meta.lua",
            disabled = false,
        },
    }
end
local UIManager = {
    after_paint = {},
    broadcasts = {},
    scheduled = {},
    shown = {},
    save_count = 0,
    flush_count = 0,
    dirty_count = 0,
}
local mock_now_seconds = 0

function UIManager:scheduleIn(_, action)
    self.scheduled[#self.scheduled + 1] = action
end

function UIManager:tickAfterNext(action)
    if self.fail_tick_after_next then
        error("mock tickAfterNext failed")
    end
    self.after_paint[#self.after_paint + 1] = action
end

function UIManager:isWidgetShown(widget)
    return self.shown[widget] == true
end

function UIManager:flushSettings()
    if self.fail_flush then
        error("mock settings flush failed")
    end
    self.flush_count = self.flush_count + 1
end

function UIManager:setDirty(widget, refresh_type)
    if self.fail_set_dirty then
        error("mock redraw failed")
    end
    self.dirty_count = self.dirty_count + 1
    self.last_dirty_widget = widget
    self.last_refresh_type = refresh_type
end

function UIManager:broadcastEvent(event)
    if self.fail_broadcast then
        error("mock broadcast failed")
    end
    self.broadcasts[#self.broadcasts + 1] = event.name
    if event.name == "Exit" then
        -- Model FileManager/ReaderUI's Exit handler: settings are saved and an
        -- empty window stack makes UIManager:run() return its default code 0.
        self.save_count = self.save_count + 1
        if self.modal_survives_exit then
            -- A modal InputDialog remains on the real UIManager stack even
            -- though FileManager itself has closed and saved successfully.
            self.shown[self.main_widget] = false
        else
            self._exit_code = 0
            self.exit_code = 0
        end
    end
end

function UIManager:quit(exit_code)
    self._exit_code = exit_code or self._exit_code or 0
    self.exit_code = self._exit_code
    self.scheduled = {}
    return self._exit_code
end

local Event = {}
function Event:new(name)
    return { name = name }
end

local FileManager = { instance = nil }
function FileManager:showFiles(path)
    local widget = { kind = "filemanager", path = path }
    self.instance = widget
    self.last_opened_path = path
    UIManager.shown[widget] = true
    return "filemanager-result", nil, 3
end

local ReaderUI = { instance = nil }
function ReaderUI:doShowReader(label)
    if FileManager.instance then
        UIManager.shown[FileManager.instance] = false
    end
    local widget = { kind = "reader", label = label }
    function widget:onClose()
        UIManager.shown[self] = false
    end
    self.instance = widget
    UIManager.shown[widget] = true
    return "reader-result", nil, 4
end


function ReaderUI:showReader(path)
    self.show_reader_count = (self.show_reader_count or 0) + 1
    self.last_opened_path = path
    self.flush_count_at_show = UIManager.flush_count
    return self:doShowReader(path)
end

local function json_escape(value)
    return value:gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\b", "\\b")
        :gsub("\f", "\\f")
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
end

local function json_encode(value)
    local value_type = type(value)
    if value_type == "nil" then
        return "null"
    elseif value_type == "boolean" or value_type == "number" then
        return tostring(value)
    elseif value_type == "string" then
        return '"' .. json_escape(value) .. '"'
    elseif value_type ~= "table" then
        error("unsupported mock JSON value: " .. value_type)
    end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    local fields = {}
    for _, key in ipairs(keys) do
        fields[#fields + 1] = json_encode(tostring(key)) .. ":" .. json_encode(value[key])
    end
    return "{" .. table.concat(fields, ",") .. "}"
end

local function json_string_field(input, name)
    local raw = input:match('"' .. name .. '"%s*:%s*"(.-)"')
    if not raw then return nil end
    return raw:gsub('\\"', '"')
        :gsub("\\n", "\n")
        :gsub("\\r", "\r")
        :gsub("\\t", "\t")
        :gsub("\\\\", "\\")
end

local mock_json = {}
function mock_json.encode(value)
    return json_encode(value)
end
function mock_json.decode(input)
    local body = {
        command = json_string_field(input, "command"),
        app_id = json_string_field(input, "app_id"),
        path = json_string_field(input, "path"),
        open_path = json_string_field(input, "open_path"),
        lease_id = json_string_field(input, "lease_id")
            or tonumber(input:match('"lease_id"%s*:%s*(%d+)')),
        generation = tonumber(input:match('"generation"%s*:%s*(%d+)')),
        foreground_epoch = tonumber(input:match('"foreground_epoch"%s*:%s*(%d+)')),
        legacy = input:match('"legacy"%s*:%s*true') ~= nil,
    }
    return {
        protocol = tonumber(input:match('"protocol"%s*:%s*(%d+)')),
        request_id = json_string_field(input, "request_id"),
        body = body,
    }, #input + 1, nil
end

local mock_lfs = {}
function mock_lfs.attributes(path)
    if path == os.getenv("TEST_OPEN_PATH") then
        return { mode = "file" }
    elseif path == os.getenv("TEST_OPEN_DIR") then
        return { mode = "directory" }
    end
end

-- Production KOReader provides ffi/util.runInSubProcess. Execute child tasks
-- immediately in this hermetic mock while preserving the parent-side API, so
-- lifecycle tests exercise the asynchronous orchestration deterministically.
local MockFFIUtil = {
    next_pid = 1000,
    outputs = {},
    done = {},
    launches = 0,
    terminated = 0,
}
local MockFFI = { C = {} }
function MockFFI.new(_, size) return { value = "", size = size } end
function MockFFI.cast(_, value) return value end
function MockFFI.string(buffer, size) return buffer.value:sub(1, size) end
function MockFFI.C.read(fd, buffer, size)
    local value = MockFFIUtil.outputs[fd] or ""
    local count = math.min(size, #value)
    buffer.value = value:sub(1, count)
    MockFFIUtil.outputs[fd] = value:sub(count + 1)
    return count
end
function MockFFI.C.close() return 0 end
function MockFFI.C.kill(pid)
    if pid > 0 then
        MockFFIUtil.terminated = MockFFIUtil.terminated + 1; MockFFIUtil.done[pid] = true
    end
    return 0
end
function MockFFIUtil.runInSubProcess(task, with_pipe)
    MockFFIUtil.next_pid = MockFFIUtil.next_pid + 1
    local pid = MockFFIUtil.next_pid
    local read_fd = with_pipe and pid or nil
    MockFFIUtil.launches = MockFFIUtil.launches + 1
    local stall = os.getenv("TEST_STALL_SUBPROCESS") == "1"
        or (os.getenv("TEST_STALL_FIRST_SUBPROCESS") == "1"
            and MockFFIUtil.launches == 1)
    local partial_stall = os.getenv("TEST_PARTIAL_STALL_FIRST_SUBPROCESS") == "1"
        and MockFFIUtil.launches == 1
    if not stall then
        task(pid, read_fd)
        if partial_stall then
            MockFFIUtil.outputs[read_fd] = (MockFFIUtil.outputs[read_fd] or "")
                .. '{"protocol":2,"request_id":"truncated'
        else
            MockFFIUtil.done[pid] = true
        end
    end
    return pid, read_fd
end
function MockFFIUtil.isSubProcessDone(pid) return MockFFIUtil.done[pid] == true end
function MockFFIUtil.getNonBlockingReadSize(fd) return #(MockFFIUtil.outputs[fd] or "") end
function MockFFIUtil.writeToFD(fd, value)
    MockFFIUtil.outputs[fd] = (MockFFIUtil.outputs[fd] or "") .. value
    return true
end
function MockFFIUtil.readAllFromFD(fd)
    local value = MockFFIUtil.outputs[fd] or ""
    MockFFIUtil.outputs[fd] = nil
    return value
end
function MockFFIUtil.terminateSubProcess(pid)
    MockFFIUtil.terminated = MockFFIUtil.terminated + 1
    MockFFIUtil.done[pid] = true
end

package.preload["logger"] = function() return logger end
package.preload["device"] = function() return Device end
package.preload["pluginloader"] = function() return PluginLoader end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/event"] = function() return Event end
package.preload["apps/filemanager/filemanager"] = function() return FileManager end
package.preload["apps/reader/readerui"] = function() return ReaderUI end
package.preload["dkjson"] = function() return mock_json end
package.preload["libs/libkoreader-lfs"] = function() return mock_lfs end
package.preload["ffi/util"] = function() return MockFFIUtil end
package.preload["ffi"] = function() return MockFFI end
package.preload["ui/time"] = function()
    return {
        now = function() return math.floor(mock_now_seconds * 1000000) end,
        to_s = function(value) return value / 1000000 end,
    }
end

assert(dofile(patch_path) == nil)
assert_equal(Device:hasOTAUpdates(), false, "managed OTA capability")
assert_equal(Device:hasOTARunning(), false, "managed OTA running capability")
local discovered_plugins = PluginLoader:_discover()
assert_equal(discovered_plugins[1].disabled, true, "terminal plugin disabled")
assert_equal(discovered_plugins[1].main, discovered_plugins[1].meta,
    "terminal plugin loads metadata only")
assert_equal(discovered_plugins[2].disabled, false, "unrelated plugin remains enabled")

local runtime_dir = assert(os.getenv("REMAGIC_RUNTIME_DIR"))
local ready_path = runtime_dir .. "/koreader-ready"
local exit_path = runtime_dir .. "/koreader-exit"
local identity = "pid=" .. tostring(os.getenv("REMAGIC_APP_PID"))
    .. "\ngeneration=" .. tostring(os.getenv("REMAGIC_APP_GENERATION")) .. "\n"

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function write_file(path, value)
    local file = assert(io.open(path, "wb"))
    assert(file:write(value))
    assert(file:close())
end

local function append_file(path, value)
    local file = assert(io.open(path, "ab"))
    assert(file:write(value))
    assert(file:close())
end

local function bridge_command(body)
    local inbox = assert(os.getenv("TEST_BRIDGE_INBOX"), "bridge inbox is required")
    local envelope = {
        protocol = 2,
        request_id = "mock-command-" .. tostring(#UIManager.broadcasts + UIManager.flush_count
            + UIManager.dirty_count + 1),
        body = body,
    }
    -- Preserve the exact large generation for the source-byte identity check.
    body.app_id = "koreader"
    body.generation = "__REMAGIC_GENERATION__"
    local encoded = mock_json.encode(envelope):gsub(
        '"__REMAGIC_GENERATION__"', tostring(os.getenv("REMAGIC_APP_GENERATION")), 1)
    append_file(inbox, encoded .. "\n")
end

local function bridge_trace()
    return read_file(assert(os.getenv("TEST_BRIDGE_TRACE"))) or ""
end

local function run_after_paint()
    local callback = table.remove(UIManager.after_paint, 1)
    if not callback then fail("no after-paint callback was scheduled") end
    callback()
end

local function run_poll()
    local callback = table.remove(UIManager.scheduled, 1)
    if not callback then fail("no exit poll was scheduled") end
    mock_now_seconds = mock_now_seconds + 0.05
    callback()
end

local function run_bridge_poll()
    local inbox = assert(os.getenv("TEST_BRIDGE_INBOX"), "bridge inbox is required")
    for _ = 1, 128 do
        run_poll()
        if read_file(inbox) == "" then
            return
        end
    end
    fail("bridge command was not consumed at the configured low polling rate")
end

local function show_filemanager()
    local a, b, c = FileManager:showFiles("library")
    UIManager.main_widget = FileManager.instance
    assert_equal(a, "filemanager-result", "FileManager return value 1")
    assert_equal(b, nil, "FileManager return value 2")
    assert_equal(c, 3, "FileManager return value 3")
end

local function assert_ready_after_paint(show)
    show()
    assert_equal(read_file(ready_path), nil, "ready marker appeared before repaint")
    run_after_paint()
    if os.getenv("REMAGIC_APP_BRIDGE") then
        local trace = bridge_trace()
        if not trace:match('"event":"ready"') then
            fail("v2 readiness was not emitted after repaint")
        end
        assert_equal(read_file(ready_path), nil, "v2 readiness wrote a legacy marker")
    elseif os.getenv("REMAGIC_LIFECYCLE_FD") then
        assert_equal(read_file(ready_path), nil, "direct-FD readiness wrote a legacy marker")
    else
        assert_equal(read_file(ready_path), identity, "ready marker identity")
    end
end

if mode == "filemanager" then
    assert_ready_after_paint(show_filemanager)
elseif mode == "reader" then
    assert_ready_after_paint(function()
        local a, b, c = ReaderUI:doShowReader("book")
        assert_equal(a, "reader-result", "ReaderUI return value 1")
        assert_equal(b, nil, "ReaderUI return value 2")
        assert_equal(c, 4, "ReaderUI return value 3")
    end)
elseif mode == "rapid_transition" then
    show_filemanager()
    local old_filemanager = FileManager.instance
    ReaderUI:doShowReader("book")
    UIManager.shown[old_filemanager] = false

    run_after_paint()
    assert_equal(read_file(ready_path), nil, "superseded FileManager published readiness")
    run_after_paint()
    assert_equal(read_file(ready_path), identity, "ReaderUI did not publish after rapid transition")
elseif mode == "stale_exit" then
    assert_ready_after_paint(show_filemanager)
    write_file(exit_path, "pid=1\ngeneration=2\n")
    run_poll()
    assert_equal(#UIManager.broadcasts, 0, "stale exit marker was dispatched")
    assert_equal(read_file(exit_path), "pid=1\ngeneration=2\n", "stale marker was removed")

    write_file(exit_path, identity)
    run_poll()
    assert_equal(#UIManager.broadcasts, 1, "matching exit dispatch count")
    assert_equal(UIManager.broadcasts[1], "Exit", "matching event name")
    assert_equal(UIManager.save_count, 1, "graceful save count")
    assert_equal(UIManager.exit_code, 0, "graceful exit code")
    assert_equal(read_file(exit_path), nil, "owned exit marker cleanup")
    assert_equal(read_file(ready_path), identity, "ready marker cleared before Device:exit")
    Device:exit()
    assert_equal(read_file(ready_path), nil, "owned ready marker cleanup")
elseif mode == "exit_before_ready" then
    write_file(exit_path, identity)
    run_poll()
    assert_equal(#UIManager.broadcasts, 0, "exit dispatched without a semantic UI")
    show_filemanager()
    run_after_paint()
    run_poll()
    assert_equal(UIManager.broadcasts[1], "Exit", "deferred exit event")
    assert_equal(UIManager.exit_code, 0, "deferred exit code")
    Device:exit()
    assert_equal(read_file(ready_path), nil, "deferred exit ready marker cleanup")
elseif mode == "modal_exit" then
    assert_ready_after_paint(show_filemanager)
    UIManager.modal_survives_exit = true
    write_file(exit_path, identity)
    run_poll()
    assert_equal(#UIManager.broadcasts, 1, "modal exit dispatch count")
    assert_equal(UIManager.save_count, 1, "modal exit native save count")
    assert_equal(UIManager.exit_code, nil, "modal unexpectedly drained on broadcast")
    assert_equal(read_file(exit_path), nil, "modal owned exit marker cleanup")
    assert_equal(read_file(ready_path), identity, "modal ready marker cleared before Device:exit")
    run_poll()
    assert_equal(UIManager.exit_code, 0, "modal exit drain code")
    Device:exit()
    assert_equal(read_file(ready_path), nil, "modal owned ready marker cleanup")
elseif mode == "background_resume" then
    assert_ready_after_paint(show_filemanager)
    bridge_command({ command = "enter_background", foreground_epoch = 1 })
    run_bridge_poll()
    assert_equal(UIManager.flush_count, 1, "background settings flush count")
    local trace = bridge_trace()
    if not trace:match('"event":"state_saved"') then fail("state_saved was not emitted") end
    if not trace:match('"event":"background_ready"') then fail("background_ready was not emitted") end

    bridge_command({ command = "enter_foreground", foreground_epoch = 2, lease_id = 22 })
    run_bridge_poll()
    assert_equal(UIManager.dirty_count, 1, "resume redraw count")
    assert_equal(UIManager.last_refresh_type, "ui", "resume refresh type")
    run_after_paint()
    trace = bridge_trace()
    if not trace:match('"event":"ready"') or not trace:match('"reason":"resume"') then
        fail("resume readiness was not emitted after repaint")
    end
    if not trace:match('"foreground_epoch":2') or not trace:match('"lease_id":22') then
        fail("resume readiness did not preserve the foreground token")
    end
elseif mode == "background_save_failure" then
    assert_ready_after_paint(function() ReaderUI:doShowReader("book") end)
    UIManager.fail_flush = true
    bridge_command({ command = "enter_background", foreground_epoch = 1 })
    run_bridge_poll()
    local trace = bridge_trace()
    if not trace:match('"event":"failed"') or not trace:match('"reason":"save_failed"') then
        fail("background save failure was not reported")
    end
    if trace:match('"event":"background_ready"') then
        fail("failed background save acknowledged parking")
    end
    if #UIManager.scheduled == 0 then fail("polling stopped after background save failure") end
    UIManager.fail_flush = false
    bridge_command({ command = "enter_background", foreground_epoch = 1 })
    run_bridge_poll()
    trace = bridge_trace()
    if not trace:match('"event":"state_saved"')
            or not trace:match('"event":"background_ready"') then
        fail("background retry did not publish both durable milestones")
    end
    assert_equal(UIManager.flush_count, 1, "successful background save count")
elseif mode == "foreground_failure_rollback" then
    assert_ready_after_paint(show_filemanager)
    bridge_command({ command = "enter_background", foreground_epoch = 1 })
    run_bridge_poll()
    UIManager.fail_set_dirty = true
    bridge_command({ command = "enter_foreground", foreground_epoch = 2, lease_id = 22 })
    run_bridge_poll()
    local trace = bridge_trace()
    if not trace:match('"event":"failed"')
            or not trace:match('"operation":"enter_foreground"')
            or not trace:match('"foreground_epoch":2') then
        fail("foreground redraw failure was not fenced and reported")
    end
    UIManager.fail_set_dirty = false
    bridge_command({ command = "enter_foreground", foreground_epoch = 3, lease_id = 33 })
    run_bridge_poll()
    assert_equal(UIManager.dirty_count, 1, "foreground retry redraw count")
    run_after_paint()
    trace = bridge_trace()
    if not trace:match('"reason":"resume"') or not trace:match('"foreground_epoch":3') then
        fail("foreground retry did not recover with the new fence")
    end
elseif mode == "foreground_open_save_failure_rollback" then
    assert_ready_after_paint(show_filemanager)
    bridge_command({ command = "enter_background", foreground_epoch = 1 })
    run_bridge_poll()
    UIManager.fail_flush = true
    local path = assert(os.getenv("TEST_OPEN_PATH"))
    bridge_command({ command = "enter_foreground", foreground_epoch = 2,
        lease_id = 22, open_path = path })
    run_bridge_poll()
    assert_equal(ReaderUI.show_reader_count, nil, "open mutated UI after failed save")
    local trace = bridge_trace()
    if not trace:match('"operation":"open_path"')
            or not trace:match('"reason":"save_failed"')
            or not trace:match('"foreground_epoch":2') then
        fail("foreground open save failure was not fenced and reported")
    end
    UIManager.fail_flush = false
    bridge_command({ command = "enter_foreground", foreground_epoch = 3,
        lease_id = 33, open_path = path })
    run_bridge_poll()
    assert_equal(ReaderUI.last_opened_path, path, "foreground open retry target")
    assert_equal(ReaderUI.flush_count_at_show, 2, "open mutated UI before durable save")
    run_after_paint()
    trace = bridge_trace()
    if not trace:match('"reason":"open_path"')
            or not trace:match('"foreground_epoch":3')
            or not trace:match('"lease_id":33') then
        fail("foreground open retry did not restore the new fence")
    end
elseif mode == "open_path" then
    assert_ready_after_paint(show_filemanager)
    local path = assert(os.getenv("TEST_OPEN_PATH"))
    bridge_command({ command = "open_path", foreground_epoch = 3, path = path })
    run_bridge_poll()
    assert_equal(ReaderUI.last_opened_path, path, "open_path target")
    assert_equal(ReaderUI.flush_count_at_show, 1, "open_path mutated UI before durable save")
    run_after_paint()
    local trace = bridge_trace()
    if not trace:match('"reason":"open_path"') or not trace:match('"ui":"reader"') then
        fail("open_path readiness was not emitted after reader repaint")
    end
elseif mode == "foreground_open_file" then
    assert_ready_after_paint(show_filemanager)
    bridge_command({ command = "enter_background", foreground_epoch = 1 })
    run_bridge_poll()
    local path = assert(os.getenv("TEST_OPEN_PATH"))
    bridge_command({ command = "enter_foreground", foreground_epoch = 2,
        lease_id = 22, open_path = path })
    run_bridge_poll()
    assert_equal(ReaderUI.last_opened_path, path, "foreground file target")
    run_after_paint()
    local trace = bridge_trace()
    if not trace:match('"reason":"open_path"')
            or not trace:match('"foreground_epoch":2')
            or not trace:match('"lease_id":22') then
        fail("foreground file readiness did not use the resumed token")
    end
elseif mode == "foreground_open_directory" then
    assert_ready_after_paint(function()
        ReaderUI:doShowReader("old-book")
    end)
    bridge_command({ command = "enter_background", foreground_epoch = 1 })
    run_bridge_poll()
    local path = assert(os.getenv("TEST_OPEN_DIR"))
    bridge_command({ command = "enter_foreground", foreground_epoch = 3,
        lease_id = 33, open_path = path })
    run_bridge_poll()
    assert_equal(FileManager.last_opened_path, path, "foreground directory target")
    run_after_paint()
    local trace = bridge_trace()
    if not trace:match('"reason":"open_path"')
            or not trace:match('"foreground_epoch":3')
            or not trace:match('"lease_id":33') then
        fail("foreground directory readiness did not use the resumed token")
    end
elseif mode == "start_preapplied" then
    local path = assert(os.getenv("TEST_OPEN_PATH"))
    assert_equal(os.getenv("REMAGIC_INITIAL_OPEN_PATH"), path, "initial argv marker")
    assert_ready_after_paint(function()
        ReaderUI:showReader(path)
    end)
    assert_equal(ReaderUI.show_reader_count, 1, "initial argv open count")
    bridge_command({ command = "start", foreground_epoch = 1, open_path = path })
    run_bridge_poll()
    assert_equal(ReaderUI.show_reader_count, 1, "Start opened the argv path twice")
elseif mode == "v2_shutdown" then
    assert_ready_after_paint(show_filemanager)
    bridge_command({ command = "shutdown", foreground_epoch = 4 })
    run_bridge_poll()
    assert_equal(UIManager.broadcasts[1], "Exit", "v2 graceful exit event")
    assert_equal(UIManager.save_count, 1, "v2 graceful save count")
    local trace = bridge_trace()
    if trace:match('"event":"state_saved"') or trace:match('"event":"shutdown_complete"') then
        fail("shutdown completion was emitted before Device:exit")
    end
    assert_equal(Device:exit(), "device-exit-result", "wrapped Device:exit return value")
    assert_equal(Device.exit_count, 1, "real Device:exit call count")
    trace = bridge_trace()
    local saved_at = trace:find('"event":"state_saved"', 1, true)
    local complete_at = trace:find('"event":"shutdown_complete"', 1, true)
    if not saved_at then fail("shutdown state_saved was not emitted after Device:exit") end
    if not complete_at then fail("shutdown_complete was not emitted after Device:exit") end
    if complete_at < saved_at then fail("shutdown_complete preceded state_saved") end
    if not trace:match('"exit_code":0') then fail("shutdown_complete omitted exit code") end
elseif mode == "v2_shutdown_before_ready" then
    bridge_command({ command = "shutdown", foreground_epoch = 4 })
    run_bridge_poll()
    assert_equal(#UIManager.broadcasts, 0, "v2 shutdown dispatched without a semantic UI")
    show_filemanager()
    run_after_paint()
    run_poll()
    assert_equal(UIManager.broadcasts[1], "Exit", "deferred v2 shutdown Exit event")
    assert_equal(UIManager.flush_count, 1, "deferred v2 shutdown durable save count")
    Device:exit()
    local trace = bridge_trace()
    if not trace:match('"event":"shutdown_complete"') then
        fail("deferred v2 shutdown omitted completion")
    end
elseif mode == "shutdown_save_failure" then
    assert_ready_after_paint(function() ReaderUI:doShowReader("book") end)
    UIManager.fail_flush = true
    bridge_command({ command = "shutdown", foreground_epoch = 4 })
    run_bridge_poll()
    local trace = bridge_trace()
    assert_equal(#UIManager.broadcasts, 0, "Exit dispatched after failed position save")
    if not trace:match('"event":"failed"') or not trace:match('"reason":"save_failed"') then
        fail("shutdown save failure was not reported")
    end
    if #UIManager.scheduled == 0 then fail("shutdown save failure stopped command polling") end
    UIManager.fail_flush = false
    bridge_command({ command = "shutdown", foreground_epoch = 4 })
    run_bridge_poll()
    assert_equal(UIManager.broadcasts[1], "Exit", "shutdown retry Exit event")
    assert_equal(UIManager.flush_count, 1, "shutdown retry durable save count")
    Device:exit()
    trace = bridge_trace()
    if not trace:match('"event":"shutdown_complete"') then
        fail("successful shutdown retry omitted completion")
    end
elseif mode == "shutdown_dispatch_failure" then
    assert_ready_after_paint(function() ReaderUI:doShowReader("book") end)
    UIManager.fail_broadcast = true
    bridge_command({ command = "shutdown", foreground_epoch = 4 })
    run_bridge_poll()
    local trace = bridge_trace()
    assert_equal(#UIManager.broadcasts, 0, "failed Exit dispatch mutated UI state")
    if not trace:match('"reason":"exit_dispatch_failed"') then
        fail("Exit dispatch failure was not reported")
    end
    if #UIManager.scheduled == 0 then fail("Exit dispatch failure stopped command polling") end
    UIManager.fail_broadcast = false
    bridge_command({ command = "shutdown", foreground_epoch = 4 })
    run_bridge_poll()
    assert_equal(UIManager.broadcasts[1], "Exit", "Exit dispatch retry event")
    assert_equal(UIManager.flush_count, 2, "Exit dispatch attempts persisted reading state")
    Device:exit()
    trace = bridge_trace()
    if not trace:match('"event":"shutdown_complete"') then
        fail("Exit dispatch retry omitted completion")
    end
elseif mode == "device_exit_failure" then
    assert_ready_after_paint(function() ReaderUI:doShowReader("book") end)
    bridge_command({ command = "shutdown", foreground_epoch = 5 })
    run_bridge_poll()
    assert_equal(UIManager.flush_count, 1, "pre-exit reading-position save count")
    Device.fail_exit = true
    local exited = pcall(function() Device:exit() end)
    assert_equal(exited, false, "failed Device:exit result")
    local trace = bridge_trace()
    if not trace:match('"event":"failed"')
            or not trace:match('"reason":"device_exit_failed"') then
        fail("Device:exit failure was not reported")
    end
    if trace:match('"event":"shutdown_complete"') then
        fail("failed Device:exit acknowledged shutdown completion")
    end
elseif mode == "ready_schedule_failure" then
    UIManager.fail_tick_after_next = true
    show_filemanager()
    assert_equal(#UIManager.after_paint, 0, "failed readiness callback was retained")
    local trace = bridge_trace()
    if not trace:match('"event":"failed"')
            or not trace:match('"operation":"ready"')
            or not trace:match('"reason":"schedule_failed"') then
        fail("readiness scheduling failure was not reported")
    end
    if #UIManager.scheduled == 0 then fail("readiness scheduling failure stopped polling") end
elseif mode == "helper_large_command" then
    assert_ready_after_paint(show_filemanager)
    bridge_command({ command = "enter_background", foreground_epoch = 1,
        padding = string.rep("x", 48 * 1024) })
    run_bridge_poll()
    assert_equal(UIManager.flush_count, 1, "large bridge command settings flush count")
    local trace = bridge_trace()
    if not trace:match('"event":"state_saved"')
            or not trace:match('"event":"background_ready"') then
        fail("valid large bridge command was dropped")
    end
elseif mode == "helper_low_frequency" then
    for _ = 1, 40 do run_poll() end
    assert_equal(MockFFIUtil.launches, 2, "helper polls across two seconds")
elseif mode == "helper_timeout" then
    for _ = 1, 6 do run_poll() end
    assert_equal(MockFFIUtil.terminated, 1, "stalled helper termination count")
    if #UIManager.scheduled == 0 then fail("polling stopped after helper timeout") end
elseif mode == "helper_timeout_retry" then
    bridge_command({ command = "enter_background", foreground_epoch = 1 })
    for _ = 1, 7 do run_poll() end
    assert_equal(MockFFIUtil.terminated, 1, "first stalled helper termination count")
    assert_equal(UIManager.flush_count, 1, "command was not consumed on immediate retry")
    if read_file(assert(os.getenv("TEST_BRIDGE_INBOX"))) ~= "" then
        fail("timed-out poll waited a full poll interval before retrying")
    end
elseif mode == "helper_timeout_partial_frame" then
    bridge_command({ command = "enter_background", foreground_epoch = 1 })
    for _ = 1, 6 do run_poll() end
    assert_equal(MockFFIUtil.terminated, 1, "partial poll helper termination count")
    bridge_command({ command = "enter_background", foreground_epoch = 1 })
    run_poll()
    assert_equal(UIManager.flush_count, 2,
        "partial timed-out frame corrupted the next complete command")
elseif mode == "final_serializes_pending_emit" then
    show_filemanager()
    run_after_paint()
    assert_equal(bridge_trace(), "", "stalled ready emit unexpectedly completed")
    Device.fail_exit = true
    local exited = pcall(function() Device:exit() end)
    assert_equal(exited, false, "failed Device:exit result with pending emit")
    local trace = bridge_trace()
    local ready_at = trace:find('"event":"ready"', 1, true)
    local failed_at = trace:find('"event":"failed"', 1, true)
    if not ready_at or not failed_at then fail("final batch omitted a queued event") end
    if failed_at < ready_at then fail("final event overtook queued readiness") end
    assert_equal(MockFFIUtil.terminated, 1, "pending emit cancellation count")
elseif mode == "normal_exit_cancels_worker" then
    show_filemanager()
    run_after_paint()
    assert_equal(Device:exit(), "device-exit-result", "normal Device:exit return value")
    assert_equal(MockFFIUtil.terminated, 1, "normal exit worker cancellation count")
    assert_equal(bridge_trace(), "", "normal exit leaked a late ready event")
elseif mode == "direct_fd" then
    assert_ready_after_paint(show_filemanager)
    run_poll()
    assert_equal(UIManager.flush_count, 1, "direct-FD background settings flush count")
elseif mode == "invalid_identity" then
    assert_equal(#UIManager.scheduled, 0, "polling enabled for invalid identity")
    show_filemanager()
    assert_equal(#UIManager.after_paint, 0, "readiness enabled for invalid identity")
    assert_equal(read_file(ready_path), nil, "invalid identity published readiness")
else
    fail("unknown mode: " .. mode)
end
print("mock userpatch test passed: " .. mode)
