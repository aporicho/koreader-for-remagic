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
local UIManager = {
    after_paint = {},
    broadcasts = {},
    scheduled = {},
    shown = {},
    save_count = 0,
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
function FileManager:showFiles(label)
    local widget = { kind = "filemanager", label = label }
    self.instance = widget
    UIManager.shown[widget] = true
    return "filemanager-result", nil, 3
end

local ReaderUI = { instance = nil }
function ReaderUI:doShowReader(label)
    local widget = { kind = "reader", label = label }
    self.instance = widget
    UIManager.shown[widget] = true
    return "reader-result", nil, 4
end

package.preload["logger"] = function() return logger end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/event"] = function() return Event end
package.preload["apps/filemanager/filemanager"] = function() return FileManager end
package.preload["apps/reader/readerui"] = function() return ReaderUI end

assert(dofile(patch_path) == nil)

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
    assert_equal(read_file(ready_path), identity, "ready marker identity")
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
elseif mode == "modal_exit" then
    assert_ready_after_paint(show_filemanager)
    UIManager.modal_survives_exit = true
    write_file(exit_path, identity)
    run_poll()
    assert_equal(#UIManager.broadcasts, 1, "modal exit dispatch count")
    assert_equal(UIManager.save_count, 1, "modal exit native save count")
    assert_equal(UIManager.exit_code, nil, "modal unexpectedly drained on broadcast")
    assert_equal(read_file(exit_path), nil, "modal owned exit marker cleanup")
    assert_equal(read_file(ready_path), nil, "modal owned ready marker cleanup")
    run_poll()
    assert_equal(UIManager.exit_code, 0, "modal exit drain code")
elseif mode == "invalid_identity" then
    assert_equal(#UIManager.scheduled, 0, "polling enabled for invalid identity")
    show_filemanager()
    assert_equal(#UIManager.after_paint, 0, "readiness enabled for invalid identity")
    assert_equal(read_file(ready_path), nil, "invalid identity published readiness")
else
    fail("unknown mode: " .. mode)
end

print("mock userpatch test passed: " .. mode)
