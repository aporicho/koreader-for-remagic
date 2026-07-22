-- Safe KOReader path transition with reading-position persistence.

return function(options)
    local UIManager = assert(options.UIManager)
    local FileManager = assert(options.FileManager)
    local ReaderUI = assert(options.ReaderUI)
    local emit_failed = assert(options.emit_failed)
    local log = options.log or function() end
    local get_ready_reason = assert(options.get_ready_reason)
    local set_ready_reason = assert(options.set_ready_reason)
    local roots = assert(options.allowed_roots)

    local function path_allowed(path)
        if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("%z") then
            return false
        end
        if path:find("/%.%./", 1, false) or path:match("/%.%.$") then
            return false
        end
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

    return function(path)
        if not path_allowed(path) then
            emit_failed("path_not_allowed")
            return false
        end
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        local attributes = ok_lfs and lfs.attributes(path) or nil
        if not attributes then
            emit_failed("path_not_found")
            return false
        end
        if attributes.mode ~= "directory" and attributes.mode ~= "file" then
            emit_failed("unsupported_path")
            return false
        end

        -- A transition closes the current ReaderUI. Persist the current page
        -- before any UI mutation so a failed open can recover without rollback.
        local saved, save_error = pcall(function()
            UIManager:flushSettings()
        end)
        if not saved then
            emit_failed("save_failed")
            log("save-failed", "error=" .. tostring(save_error))
            return false
        end

        local previous_ready_reason = get_ready_reason()
        set_ready_reason("open_path")
        local opened, open_error = pcall(function()
            if attributes.mode == "directory" then
                local active_reader = ReaderUI.instance
                if active_reader and UIManager:isWidgetShown(active_reader) then
                    active_reader:onClose()
                end
                FileManager:showFiles(path)
            else
                ReaderUI:showReader(path)
            end
        end)
        if not opened then
            set_ready_reason(previous_ready_reason)
            emit_failed("open_failed")
            log("failed", "error=" .. tostring(open_error))
            return false
        end
        return true
    end
end
