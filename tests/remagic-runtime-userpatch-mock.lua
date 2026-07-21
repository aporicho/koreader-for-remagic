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

function UIManager:scheduleIn(_, action)
    self.scheduled[#self.scheduled + 1] = action
end

function UIManager:tickAfterNext(action)
    self.after_paint[#self.after_paint + 1] = action
end

function UIManager:isWidgetShown(widget)
    return self.shown[widget] == true
end

function UIManager:flushSettings()
    self.flush_count = self.flush_count + 1
end

function UIManager:setDirty(widget, refresh_type)
    self.dirty_count = self.dirty_count + 1
    self.last_dirty_widget = widget
    self.last_refresh_type = refresh_type
end

function UIManager:broadcastEvent(event)
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

package.preload["logger"] = function() return logger end
package.preload["device"] = function() return Device end
package.preload["pluginloader"] = function() return PluginLoader end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/event"] = function() return Event end
package.preload["apps/filemanager/filemanager"] = function() return FileManager end
package.preload["apps/reader/readerui"] = function() return ReaderUI end
package.preload["dkjson"] = function() return mock_json end
package.preload["libs/libkoreader-lfs"] = function() return mock_lfs end

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
    callback()
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
    run_poll()
    assert_equal(UIManager.flush_count, 1, "background settings flush count")
    local trace = bridge_trace()
    if not trace:match('"event":"state_saved"') then fail("state_saved was not emitted") end
    if not trace:match('"event":"background_ready"') then fail("background_ready was not emitted") end

    bridge_command({ command = "enter_foreground", foreground_epoch = 2, lease_id = 22 })
    run_poll()
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
elseif mode == "open_path" then
    assert_ready_after_paint(show_filemanager)
    local path = assert(os.getenv("TEST_OPEN_PATH"))
    bridge_command({ command = "open_path", foreground_epoch = 3, path = path })
    run_poll()
    assert_equal(ReaderUI.last_opened_path, path, "open_path target")
    run_after_paint()
    local trace = bridge_trace()
    if not trace:match('"reason":"open_path"') or not trace:match('"ui":"reader"') then
        fail("open_path readiness was not emitted after reader repaint")
    end
elseif mode == "foreground_open_file" then
    assert_ready_after_paint(show_filemanager)
    bridge_command({ command = "enter_background", foreground_epoch = 1 })
    run_poll()
    local path = assert(os.getenv("TEST_OPEN_PATH"))
    bridge_command({ command = "enter_foreground", foreground_epoch = 2,
        lease_id = 22, open_path = path })
    run_poll()
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
    run_poll()
    local path = assert(os.getenv("TEST_OPEN_DIR"))
    bridge_command({ command = "enter_foreground", foreground_epoch = 3,
        lease_id = 33, open_path = path })
    run_poll()
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
    run_poll()
    assert_equal(ReaderUI.show_reader_count, 1, "Start opened the argv path twice")
elseif mode == "v2_shutdown" then
    assert_ready_after_paint(show_filemanager)
    bridge_command({ command = "shutdown", foreground_epoch = 4 })
    run_poll()
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
