-- Incremental local-book reconciliation for the managed KOReader collection.
-- Directory traversal is a coroutine and each UI callback has a fixed work
-- budget, keeping startup, touch and repaint responsive for large libraries.

local function new_scan(options)
    assert(type(options) == "table", "local scan options are required")
    local UIManager = assert(options.UIManager)
    local DocumentRegistry = assert(options.DocumentRegistry)
    local lfs = assert(options.lfs)
    local books_root = assert(options.books_root)
    local canonical = assert(options.canonical)
    local is_within = assert(options.is_within)
    local get_collection = assert(options.get_collection)
    local add_item = assert(options.add_item)
    local decorate = assert(options.decorate)
    local write = assert(options.write)
    local refresh = assert(options.refresh)
    local log = assert(options.log)

    local started = false
    return function()
        if started then return false end
        started = true

        local desired = {}
        local changed = false
        local function walk(directory)
            local ok, iterator, directory_object = pcall(lfs.dir, directory)
            if not ok then
                log("warn", "local-scan-directory-failed path=" .. tostring(directory))
                return
            end
            for name in iterator, directory_object do
                if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                    local path = directory .. "/" .. name
                    local attr = lfs.symlinkattributes and lfs.symlinkattributes(path)
                        or lfs.attributes(path)
                    if attr and attr.mode == "directory" then
                        walk(path)
                    elseif attr and attr.mode == "file" then
                        coroutine.yield(path, attr)
                    end
                end
            end
        end

        local scan = coroutine.create(function() walk(books_root) end)
        local function finish(complete)
            local collection = get_collection()
            if complete then
                for key, item in pairs(collection) do
                    local path = canonical(item.file or key)
                    if is_within(path, books_root) and not desired[path] then
                        collection[key] = nil
                        changed = true
                    end
                end
            end
            changed = decorate() or changed
            if changed then write() end
            refresh()
            log(complete and "info" or "warn",
                complete and "local-scan-complete" or "local-scan-incomplete")
        end

        local function scan_slice()
            for _ = 1, 24 do
                local ok, path, attr = coroutine.resume(scan)
                if not ok then
                    log("warn", "local-scan-failed error=" .. tostring(path))
                    finish(false)
                    return
                end
                if coroutine.status(scan) == "dead" then
                    finish(true)
                    return
                end
                if DocumentRegistry:hasProvider(path) then
                    local resolved = canonical(path)
                    if resolved and is_within(resolved, books_root) then
                        desired[resolved] = true
                        changed = add_item(resolved, attr) or changed
                    end
                end
            end
            UIManager:scheduleIn(0.01, scan_slice)
        end

        -- Lifecycle readiness and the first painted frame always win the
        -- startup race. Later slices yield between fixed-size batches.
        UIManager:scheduleIn(0.25, scan_slice)
        return true
    end
end

return new_scan
