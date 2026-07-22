local patch_path = assert(arg[1], "patch path is required")
local mode = assert(arg[2], "test mode is required")

local function fail(message) error("FAIL: " .. message, 0) end
local function assert_equal(actual, expected, message)
    if actual ~= expected then
        fail((message or "values differ") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
    end
end

local logs = {}
local function log(...)
    local values = {}
    for index = 1, select("#", ...) do values[index] = tostring(select(index, ...)) end
    logs[#logs + 1] = table.concat(values, " ")
end
local logger = { info = log, warn = log, err = log, dbg = log }

local Device = { exit_count = 0 }
function Device:exit()
    self.exit_count = self.exit_count + 1
    if self.fail_exit then error("mock device exit failed") end
    return "device-exit-result"
end

local UIManager = {
    after_paint = {}, broadcasts = {}, scheduled = {}, shown = {},
    flush_count = 0, dirty_count = 0,
}
function UIManager:scheduleIn(_, callback) self.scheduled[#self.scheduled + 1] = callback end
function UIManager:tickAfterNext(callback)
    if self.fail_tick_after_next then error("mock repaint scheduling failed") end
    self.after_paint[#self.after_paint + 1] = callback
end
function UIManager:isWidgetShown(widget) return self.shown[widget] == true end
function UIManager:flushSettings()
    if self.fail_flush then error("mock settings flush failed") end
    self.flush_count = self.flush_count + 1
end
function UIManager:setDirty(widget, refresh_type)
    if self.fail_set_dirty then error("mock redraw failed") end
    self.dirty_count = self.dirty_count + 1
    self.last_dirty_widget, self.last_refresh_type = widget, refresh_type
end
function UIManager:broadcastEvent(event)
    if self.fail_broadcast then error("mock Exit dispatch failed") end
    self.broadcasts[#self.broadcasts + 1] = event.name
    if event.name == "Exit" and not self.modal_survives_exit then self._exit_code = 0 end
end
function UIManager:quit(code) self._exit_code = code or 0 end

local Event = {}
function Event:new(name) return { name = name } end

local FileManager = { instance = nil }
function FileManager:showFiles(path)
    local widget = { kind = "filemanager", path = path }
    function widget:onClose() UIManager.shown[self] = false end
    self.instance, self.last_opened_path = widget, path
    UIManager.shown[widget] = true
    return "filemanager-result", nil, 3
end

local ReaderUI = { instance = nil }
function ReaderUI:doShowReader(path)
    if FileManager.instance then UIManager.shown[FileManager.instance] = false end
    local widget = { kind = "reader", path = path }
    function widget:onClose() UIManager.shown[self] = false end
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
    return value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end
local function json_encode(value)
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" or kind == "number" then return tostring(value) end
    if kind == "string" then return '"' .. json_escape(value) .. '"' end
    if kind ~= "table" then error("unsupported JSON type: " .. kind) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    local fields = {}
    for _, key in ipairs(keys) do
        fields[#fields + 1] = json_encode(tostring(key)) .. ":" .. json_encode(value[key])
    end
    return "{" .. table.concat(fields, ",") .. "}"
end
local function string_field(input, name)
    return input:match('"' .. name .. '"%s*:%s*"(.-)"')
end
local json = { encode = json_encode }
function json.decode(input)
    return {
        protocol = tonumber(input:match('"protocol"%s*:%s*(%d+)')),
        body = {
            command = string_field(input, "command"),
            app_id = string_field(input, "app_id"),
            path = string_field(input, "path"),
            open_path = string_field(input, "open_path"),
            foreground_epoch = tonumber(input:match('"foreground_epoch"%s*:%s*"?(%d+)')),
            lease_id = tonumber(input:match('"lease_id"%s*:%s*"?(%d+)')),
        },
    }, #input + 1, nil
end

local mock_lfs = {}
function mock_lfs.attributes(path)
    if path == os.getenv("TEST_OPEN_PATH") then return { mode = "file" } end
    if path == os.getenv("TEST_OPEN_DIR") then return { mode = "directory" } end
end

local incoming, outgoing = "", ""
local MockFFI = { C = {} }
local last_errno = 11
function MockFFI.new(_, size) return { value = "", size = size } end
function MockFFI.string(buffer, size) return buffer.value:sub(1, size) end
function MockFFI.errno() return last_errno end
function MockFFI.C.fcntl(_, command)
    if command == 3 then return 0x800 end
    return 0
end
function MockFFI.C.recv(_, buffer, size)
    if incoming == "" then last_errno = 11 return -1 end
    local count = math.min(size, #incoming)
    buffer.value = incoming:sub(1, count)
    incoming = incoming:sub(count + 1)
    return count
end
MockFFI.C.read = MockFFI.C.recv
function MockFFI.C.send(_, payload, size)
    outgoing = outgoing .. payload:sub(1, size)
    return size
end
MockFFI.C.write = MockFFI.C.send

package.preload.logger = function() return logger end
package.preload.device = function() return Device end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/event"] = function() return Event end
package.preload["apps/filemanager/filemanager"] = function() return FileManager end
package.preload["apps/reader/readerui"] = function() return ReaderUI end
package.preload.dkjson = function() return json end
package.preload["libs/libkoreader-lfs"] = function() return mock_lfs end
if os.getenv("TEST_REAL_FFI") ~= "1" then package.preload.ffi = function() return MockFFI end end

assert(dofile(patch_path) == nil)

local generation = assert(os.getenv("REMAGIC_APP_GENERATION"))
local sequence = 0
local function command(body, override_generation)
    sequence = sequence + 1
    body.app_id = body.app_id or "koreader"
    body.generation = "__GENERATION__"
    local encoded = json_encode({
        protocol = 2, request_id = "mock-" .. sequence, body = body,
    }):gsub('"__GENERATION__"', override_generation or generation, 1)
    incoming = incoming .. encoded .. "\n"
end
local function has_event(event)
    return outgoing:match('"event":"' .. event .. '"') ~= nil
end
local function clear_output() outgoing = "" end
local function run_paint()
    local callback = table.remove(UIManager.after_paint, 1)
    if not callback then fail("no repaint callback was scheduled") end
    callback()
end
local function run_poll()
    local callback = table.remove(UIManager.scheduled, 1)
    if not callback then fail("no lifecycle poll was scheduled") end
    callback()
end
local function show_filemanager()
    local first, second, third = FileManager:showFiles("library")
    assert_equal(first, "filemanager-result", "FileManager return 1")
    assert_equal(second, nil, "FileManager return 2")
    assert_equal(third, 3, "FileManager return 3")
end
local function ready(show)
    show()
    if has_event("ready") then fail("ready was emitted before repaint") end
    run_paint()
    if not has_event("ready") then fail("ready was not emitted after repaint") end
end

if mode == "filemanager" then
    ready(show_filemanager)
elseif mode == "reader" then
    ready(function()
        local first, second, third = ReaderUI:doShowReader("book")
        assert_equal(first, "reader-result", "ReaderUI return 1")
        assert_equal(second, nil, "ReaderUI return 2")
        assert_equal(third, 4, "ReaderUI return 3")
    end)
elseif mode == "rapid_transition" then
    show_filemanager()
    ReaderUI:doShowReader("book")
    run_paint()
    if has_event("ready") then fail("superseded UI emitted ready") end
    run_paint()
    if not outgoing:match('"event":"ready".-"ui":"reader"')
            and not outgoing:match('"ui":"reader".-"event":"ready"') then
        fail("reader did not emit ready after rapid transition")
    end
elseif mode == "background_resume" then
    ready(show_filemanager)
    clear_output()
    command({ command = "enter_background", foreground_epoch = 1, lease_id = 11 })
    run_poll()
    assert_equal(UIManager.flush_count, 1, "background save count")
    if not has_event("state_saved") or not has_event("background_ready") then
        fail("background milestones were not emitted")
    end
    clear_output()
    command({ command = "enter_foreground", foreground_epoch = 2, lease_id = 22 })
    run_poll()
    assert_equal(UIManager.dirty_count, 1, "foreground redraw count")
    run_paint()
    if not outgoing:match('"reason":"resume"')
            or not outgoing:match('"foreground_epoch":2')
            or not outgoing:match('"lease_id":22') then
        fail("resumed ready event omitted its fence")
    end
elseif mode == "background_save_failure" then
    ready(show_filemanager)
    clear_output()
    UIManager.fail_flush = true
    command({ command = "enter_background", foreground_epoch = 1 })
    run_poll()
    if not outgoing:match('"reason":"save_failed"') or has_event("background_ready") then
        fail("background save failure was acknowledged incorrectly")
    end
elseif mode == "stale_fences" then
    ready(show_filemanager)
    clear_output()
    command({ command = "enter_foreground", foreground_epoch = 5, lease_id = 55 })
    run_poll()
    run_paint()
    clear_output()
    command({ command = "enter_background", foreground_epoch = 4, lease_id = 55 })
    command({ command = "enter_background", foreground_epoch = 5, lease_id = 44 })
    command({ command = "enter_background", foreground_epoch = 5, lease_id = 55 }, "7")
    run_poll()
    assert_equal(UIManager.flush_count, 0, "stale commands mutated state")
elseif mode == "foreground_failure_rollback" then
    ready(show_filemanager)
    clear_output()
    command({ command = "enter_background", foreground_epoch = 1 })
    run_poll()
    UIManager.fail_set_dirty = true
    command({ command = "enter_foreground", foreground_epoch = 2, lease_id = 22 })
    run_poll()
    if not outgoing:match('"reason":"resume_failed"') then fail("resume failure missing") end
    UIManager.fail_set_dirty = false
    command({ command = "enter_foreground", foreground_epoch = 3, lease_id = 33 })
    run_poll()
    run_paint()
    if not outgoing:match('"foreground_epoch":3') then fail("resume retry did not recover") end
elseif mode == "open_path" then
    ready(show_filemanager)
    clear_output()
    local path = assert(os.getenv("TEST_OPEN_PATH"))
    command({ command = "open_path", foreground_epoch = 1, path = path })
    run_poll()
    assert_equal(ReaderUI.last_opened_path, path, "opened file")
    assert_equal(ReaderUI.flush_count_at_show, 1, "save happened before open")
    run_paint()
    if not outgoing:match('"reason":"open_path"') then fail("open ready reason missing") end
elseif mode == "open_directory" then
    ready(function() ReaderUI:doShowReader("book") end)
    clear_output()
    local path = assert(os.getenv("TEST_OPEN_DIR"))
    command({ command = "open_path", foreground_epoch = 1, path = path })
    run_poll()
    assert_equal(FileManager.last_opened_path, path, "opened directory")
    run_paint()
elseif mode == "open_rejected" then
    ready(show_filemanager)
    clear_output()
    command({ command = "open_path", foreground_epoch = 1, path = "/outside/book.epub" })
    run_poll()
    if not outgoing:match('"reason":"path_not_allowed"') then fail("unsafe path accepted") end
elseif mode == "start_preapplied" then
    local path = assert(os.getenv("TEST_OPEN_PATH"))
    ready(function() ReaderUI:showReader(path) end)
    command({ command = "start", foreground_epoch = 1, open_path = path })
    run_poll()
    assert_equal(ReaderUI.show_reader_count, 1, "initial path opened twice")
elseif mode == "shutdown" then
    ready(show_filemanager)
    clear_output()
    command({ command = "shutdown", foreground_epoch = 1 })
    run_poll()
    assert_equal(UIManager.broadcasts[1], "Exit", "native shutdown event")
    if has_event("shutdown_complete") then fail("shutdown completed before Device:exit") end
    assert_equal(Device:exit(), "device-exit-result", "Device exit return")
    if not has_event("state_saved") or not has_event("shutdown_complete") then
        fail("shutdown completion milestones missing")
    end
elseif mode == "shutdown_before_ready" then
    command({ command = "shutdown", foreground_epoch = 1 })
    run_poll()
    assert_equal(#UIManager.broadcasts, 0, "shutdown dispatched without a UI")
    show_filemanager()
    run_paint()
    run_poll()
    assert_equal(UIManager.broadcasts[1], "Exit", "deferred shutdown event")
elseif mode == "shutdown_failures" then
    ready(show_filemanager)
    clear_output()
    UIManager.fail_flush = true
    command({ command = "shutdown", foreground_epoch = 1 })
    run_poll()
    if not outgoing:match('"reason":"save_failed"') then fail("save failure missing") end
    UIManager.fail_flush = false
    UIManager.fail_broadcast = true
    command({ command = "shutdown", foreground_epoch = 1 })
    run_poll()
    if not outgoing:match('"reason":"exit_dispatch_failed"') then fail("dispatch failure missing") end
elseif mode == "direct_fd" then
    ready(show_filemanager)
    run_poll()
    assert_equal(UIManager.flush_count, 1, "direct FD background save count")
else
    fail("unknown mode: " .. mode)
end

print("mock lifecycle test passed: " .. mode)
