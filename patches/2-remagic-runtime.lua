-- Remagic lifecycle bridge for KOReader.
--
-- The patch is intentionally loaded at userpatch priority 2: UIManager is
-- available, while the initial FileManager/ReaderUI has not been created yet.

local Event = require("ui/event")
local FileManager = require("apps/filemanager/filemanager")
local logger = require("logger")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")

if UIManager._remagic_runtime_patch_installed then
    logger.info("remagic-koreader: event=patch-already-installed")
    return
end
UIManager._remagic_runtime_patch_installed = true

local app_pid = os.getenv("REMAGIC_APP_PID")
local app_generation = os.getenv("REMAGIC_APP_GENERATION")

local function is_decimal(value)
    return type(value) == "string" and value:match("^[0-9]+$") ~= nil
end

-- Refuse to publish unbound markers. A marker without both fields could be
-- mistaken for a different process after a fast close/relaunch cycle.
if not is_decimal(app_pid) or not is_decimal(app_generation) then
    logger.warn("remagic-koreader: event=patch-disabled reason=invalid-instance-identity")
    return
end

local runtime_dir = os.getenv("REMAGIC_RUNTIME_DIR") or "/run/remagic"
local separator = runtime_dir:sub(-1) == "/" and "" or "/"
local ready_path = runtime_dir .. separator .. "koreader-ready"
local exit_path = runtime_dir .. separator .. "koreader-exit"
local ready_tmp_path = runtime_dir .. separator .. ".koreader-ready."
    .. app_pid .. "." .. app_generation .. ".tmp"
local identity = "pid=" .. app_pid .. "\ngeneration=" .. app_generation .. "\n"

local poll_interval = tonumber(os.getenv("REMAGIC_KOREADER_POLL_SECONDS")) or 0.10
poll_interval = math.max(0.05, math.min(poll_interval, 5.0))
local exit_drain_delay = tonumber(os.getenv("REMAGIC_KOREADER_EXIT_DRAIN_SECONDS")) or 0.05
exit_drain_delay = math.max(0.01, math.min(exit_drain_delay, 1.0))

local ready_written = false
local exit_dispatched = false
local last_stale_exit
local waiting_for_ui_logged = false

local function instance_log(level, event, detail)
    local message = "remagic-koreader: event=" .. event
        .. " pid=" .. app_pid .. " generation=" .. app_generation
    if detail then
        message = message .. " " .. detail
    end
    logger[level](message)
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local contents = file:read("*a")
    file:close()
    return contents
end

local function atomic_write_ready()
    local file, open_error = io.open(ready_tmp_path, "wb")
    if not file then
        return false, open_error
    end

    local wrote, write_error = file:write(identity)
    local flushed, flush_error
    if wrote then
        flushed, flush_error = file:flush()
    end
    local closed, close_error = file:close()
    if not wrote or not flushed or not closed then
        os.remove(ready_tmp_path)
        return false, write_error or flush_error or close_error or "short write"
    end

    local renamed, rename_error = os.rename(ready_tmp_path, ready_path)
    if not renamed then
        os.remove(ready_tmp_path)
        return false, rename_error
    end
    return true
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

local function schedule_ready(kind, widget)
    if ready_written or not widget then
        return
    end

    -- tickAfterNext is deliberate. A plain nextTick runs before _repaint() on
    -- the first UI loop iteration; this callback runs only after that repaint.
    UIManager:tickAfterNext(function()
        if ready_written then
            return
        end
        local current_kind, current_widget = active_main_ui()
        if current_kind ~= kind or current_widget ~= widget then
            return
        end

        local ok, err = atomic_write_ready()
        if not ok then
            instance_log("warn", "ready-write-failed", "error=" .. tostring(err))
            return
        end
        ready_written = true
        instance_log("info", "semantic-ready", "ui=" .. kind)
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

-- showReader() only starts an asynchronous coroutine. doShowReader() returns
-- after the actual ReaderUI widget has been shown (and after password prompts,
-- if any), so it is the semantic boundary we need.
local original_do_show_reader = ReaderUI.doShowReader
ReaderUI.doShowReader = function(self, ...)
    local results = pack_values(original_do_show_reader(self, ...))
    schedule_ready("reader", ReaderUI.instance)
    return unpack_values(results, 1, results.n)
end

-- Also handle a patch being applied manually after a main UI already exists.
local initial_kind, initial_widget = active_main_ui()
if initial_widget then
    schedule_ready(initial_kind, initial_widget)
end

local function remove_owned_marker(path)
    if read_file(path) == identity then
        os.remove(path)
    end
end

local function schedule_exit_drain(kind, widget)
    -- KOReader's normal Exit event closes and saves FileManager/ReaderUI.  A
    -- transient window (for example the "New folder" InputDialog and its
    -- keyboard) can nevertheless remain in UIManager's window stack, which
    -- keeps run() alive indefinitely after the main UI has closed.  Give the
    -- native handler/ReaderUI nextTick callback one complete turn, then close
    -- the main UI explicitly if it somehow survived and terminate the already
    -- saved UI loop with KOReader's own success result.
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

local poll_exit
poll_exit = function()
    if exit_dispatched then
        return
    end

    local requested_identity = read_file(exit_path)
    if requested_identity == identity then
        local kind, widget = active_main_ui()
        if kind then
            exit_dispatched = true
            instance_log("info", "exit-request-dispatched", "ui=" .. kind)
            local ok, err = pcall(function()
                -- This is KOReader's own exit path. ReaderUI/FileManager save
                -- settings and close their documents before UIManager returns 0.
                UIManager:broadcastEvent(Event:new("Exit"))
            end)
            if not ok then
                exit_dispatched = false
                instance_log("warn", "exit-dispatch-failed", "error=" .. tostring(err))
            else
                schedule_exit_drain(kind, widget)
                remove_owned_marker(exit_path)
                remove_owned_marker(ready_path)
                return
            end
        elseif not waiting_for_ui_logged then
            waiting_for_ui_logged = true
            instance_log("info", "exit-request-waiting-for-ui")
        end
    elseif requested_identity then
        waiting_for_ui_logged = false
        if requested_identity ~= last_stale_exit then
            last_stale_exit = requested_identity
            instance_log("info", "stale-exit-ignored")
        end
    else
        waiting_for_ui_logged = false
        last_stale_exit = nil
    end

    UIManager:scheduleIn(poll_interval, poll_exit)
end

UIManager:scheduleIn(poll_interval, poll_exit)
instance_log("info", "patch-active")
