-- ReMagic's managed KOReader collection. The official KOReader tree remains
-- untouched; this module is loaded from KO_HOME/patches with explicit
-- dependencies so its behavior can be tested independently.

local function install(options)
    assert(type(options) == "table", "collection options are required")

    local FileManager = assert(options.FileManager)
    local FileManagerCollection = assert(options.FileManagerCollection)
    local InfoMessage = assert(options.InfoMessage)
    local ReadCollection = assert(options.ReadCollection)
    local ReaderUI = assert(options.ReaderUI)
    local UIManager = assert(options.UIManager)
    local ffiUtil = assert(options.ffiUtil)
    local lfs = assert(options.lfs)
    local logger = assert(options.logger)

    local collection_name = assert(options.collection_name)
    local library_dir = assert(options.library_dir)
    local source_dir = assert(options.source_dir)
    local index_file = assert(options.index_file)
    local initial_open_path = options.initial_open_path

    local unpack_values = table.unpack or unpack
    local function pack_values(...) return { n = select("#", ...), ... } end

    local function log(level, message)
        local writer = logger[level]
        if writer then writer("koreader-for-remagic: event=library-collection " .. message) end
    end

    local function normalize_root(path)
        assert(type(path) == "string" and path:sub(1, 1) == "/", "absolute path required")
        path = path:gsub("/+$", "")
        if path == "" then return "/" end
        return path
    end

    local function canonical(path)
        if type(path) ~= "string" then return nil end
        return ffiUtil.realpath(path) or path
    end

    library_dir = normalize_root(library_dir)
    source_dir = normalize_root(canonical(source_dir))
    local library_root = normalize_root(canonical(library_dir))

    local function is_within(path, root)
        path = canonical(path)
        if not path then return false end
        return path == root or path:sub(1, #root + 1) == root .. "/"
    end

    local function is_read_only_library_path(path)
        return is_within(path, source_dir) or is_within(path, library_root)
    end

    local function basename(path)
        return type(path) == "string" and path:match("([^/]+)$") or nil
    end

    local function with_source_label(name, label)
        local stem, extension = name:match("^(.*)(%.[^.]*)$")
        if not stem then return name .. "（" .. label .. "）" end
        return stem .. "（" .. label .. "）" .. extension
    end

    local friendly_by_source = {}
    local function read_friendly_index()
        local mapping = {}
        local handle = io.open(index_file, "rb")
        if not handle then
            log("warn", "index-unavailable path=" .. index_file)
            friendly_by_source = mapping
            return mapping, false
        end

        local header = handle:read("*l")
        if header ~= "# koreader-for-remagic-library-v1" then
            handle:close()
            log("warn", "index-invalid path=" .. index_file)
            friendly_by_source = mapping
            return mapping, false
        end

        for line in handle:lines() do
            local uuid, extension, filename =
                line:match("^([0-9A-Fa-f%-]+)\t([A-Za-z0-9]+)\t([^\t\r\n]+)$")
            if uuid and #uuid == 36 and filename ~= "" and not filename:find("/", 1, true) then
                local source = canonical(source_dir .. "/" .. uuid .. "." .. extension)
                mapping[source] = filename
            end
        end
        handle:close()
        friendly_by_source = mapping
        return mapping, true
    end

    local function decorate_collection()
        local collection = ReadCollection.coll[collection_name]
        if type(collection) ~= "table" then return false end

        local mapping, index_valid = read_friendly_index()
        local rows = {}
        local counts = {}
        local removed = false
        for key, item in pairs(collection) do
            local file = canonical(item.file or key)
            local text
            local source
            if is_within(file, source_dir) then
                text = mapping[file]
                source = "官方"
                if not text and index_valid then
                    collection[key] = nil
                    removed = true
                    log("warn", "unmapped-official-entry path=" .. tostring(file))
                elseif not text then
                    -- A missing index is a degraded display-name state, not
                    -- evidence that the official book disappeared. Keep the
                    -- collection intact until an atomically published index
                    -- is available again.
                    text = item.text or basename(file)
                end
            else
                text = basename(file) or item.text
                source = "其他"
            end
            if text then
                rows[#rows + 1] = { item = item, text = text, source = source }
                counts[text] = (counts[text] or 0) + 1
            end
        end

        for _, row in ipairs(rows) do
            row.item.text = counts[row.text] > 1
                and with_source_label(row.text, row.source)
                or row.text
        end
        return removed
    end

    local function ensure_collection()
        local created = false
        if type(ReadCollection.coll[collection_name]) ~= "table" then
            ReadCollection:addCollection(collection_name)
            created = true
        end
        local settings = ReadCollection.coll_settings[collection_name]
        if type(settings) ~= "table" then
            settings = { order = 1 }
            ReadCollection.coll_settings[collection_name] = settings
            created = true
        end

        local changed = false
        -- This collection is an adapter-owned projection. Never connect a
        -- folder through KOReader's native collection settings: ReadCollection
        -- scans those folders synchronously while the module is being loaded.
        if settings.folders ~= nil then settings.folders = nil; changed = true end
        if created and settings.collate == nil then settings.collate = "natural"; changed = true end
        if settings.remagic_collection_version ~= 2 then
            settings.remagic_collection_version = 2
            changed = true
        end
        if created or changed then
            log("info", created and "collection-created" or "collection-updated")
        end
        return created or changed
    end

    local function add_item(path, attr)
        local collection = ReadCollection.coll[collection_name]
        path = canonical(path)
        if not path or collection[path] then return false end
        attr = attr or lfs.attributes(path)
        if not attr or attr.mode ~= "file" then return false end
        collection[path] = {
            file = path,
            text = basename(path),
            order = nil,
            attr = attr,
        }
        return true
    end

    local function sync_official_items()
        local collection = ReadCollection.coll[collection_name]
        local mapping, index_valid = read_friendly_index()
        if not index_valid then return false end

        local changed = false
        local desired = {}
        for path in pairs(mapping) do
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                desired[path] = true
                changed = add_item(path, attr) or changed
            end
        end

        for key, item in pairs(collection) do
            local path = canonical(item.file or key)
            if is_within(path, source_dir) and not desired[path] then
                collection[key] = nil
                changed = true
            end
        end
        changed = decorate_collection() or changed
        return changed
    end

    local collection_changed = ensure_collection()
    collection_changed = sync_official_items() or collection_changed
    if collection_changed then
        ReadCollection:write({ [collection_name] = true })
    end

    local function refresh_open_collection()
        local manager = FileManager.instance
        local collections = manager and manager.collections
        local menu = collections and collections.booklist_menu
        if not menu or menu.path ~= collection_name then return end
        local ok, err = pcall(collections.updateItemTable, collections)
        if not ok then log("warn", "refresh-failed error=" .. tostring(err)) end
    end

    local function show_read_only(path)
        log("warn", "official-library-read-only path=" .. tostring(path))
        local ok, message = pcall(InfoMessage.new, InfoMessage, {
            text = "官方书库由 reMarkable 管理，KOReader 只能阅读。",
        })
        if ok and message then pcall(UIManager.show, UIManager, message) end
        return false
    end

    local function guard_single_path(method_name)
        local original = FileManager[method_name]
        if type(original) ~= "function" then return end
        FileManager[method_name] = function(self, path, ...)
            if is_read_only_library_path(path) then return show_read_only(path) end
            return original(self, path, ...)
        end
    end
    for _, method_name in ipairs({
        "showDeleteFileDialog", "deleteFile", "showRenameFileDialog", "renameFile", "cutFile",
    }) do
        guard_single_path(method_name)
    end

    local original_move = FileManager.moveFile
    if type(original_move) == "function" then
        FileManager.moveFile = function(self, from, to)
            if is_read_only_library_path(from) or is_read_only_library_path(to) then
                return show_read_only(from)
            end
            return original_move(self, from, to)
        end
    end

    local function guard_destination(method_name, destination)
        local original = FileManager[method_name]
        if type(original) ~= "function" then return end
        FileManager[method_name] = function(self, ...)
            local path = destination(self, ...)
            if is_read_only_library_path(path) then return show_read_only(path) end
            return original(self, ...)
        end
    end
    guard_destination("pasteFileFromClipboard", function(self, path)
        return path or (self.file_chooser and self.file_chooser.path)
    end)
    guard_destination("pasteSelectedFiles", function(self)
        return self.file_chooser and self.file_chooser.path
    end)
    guard_destination("createFolder", function(self)
        return self.file_chooser and self.file_chooser.path
    end)
    guard_destination("copyFileFromTo", function(_, _, to) return to end)
    guard_destination("copyRecursive", function(_, _, to) return to end)

    local original_delete_selected = FileManager.deleteSelectedFiles
    if type(original_delete_selected) == "function" then
        FileManager.deleteSelectedFiles = function(self, ...)
            for file in pairs(self.selected_files or {}) do
                if is_read_only_library_path(file) then return show_read_only(file) end
            end
            return original_delete_selected(self, ...)
        end
    end

    local function open_collection()
        local manager = FileManager.instance
        if not manager or not manager.collections then return false end
        local ok, err = pcall(manager.collections.onShowColl, manager.collections, collection_name)
        if not ok then
            log("warn", "open-failed error=" .. tostring(err))
            return false
        end
        log("info", "opened name=" .. collection_name)
        return true
    end

    local initial_collection_attempted = initial_open_path ~= nil and initial_open_path ~= ""
    local original_show_files = FileManager.showFiles
    FileManager.showFiles = function(self, ...)
        local results = pack_values(original_show_files(self, ...))
        if not initial_collection_attempted then
            initial_collection_attempted = true
            open_collection()
        end
        return unpack_values(results, 1, results.n)
    end

    local return_file
    local original_collection_select = FileManagerCollection.onMenuSelect
    FileManagerCollection.onMenuSelect = function(self, item, ...)
        if self.path == collection_name
                and not (self._manager and self._manager.selected_files)
                and item and item.file
        then
            return_file = canonical(item.file)
        end
        return original_collection_select(self, item, ...)
    end

    local function safe_return_file(file)
        file = canonical(file)
        if friendly_by_source[file] then
            return library_dir .. "/" .. friendly_by_source[file]
        end
        return nil
    end

    local original_show_file_manager = ReaderUI.showFileManager
    ReaderUI.showFileManager = function(self, file, ...)
        if not return_file then return original_show_file_manager(self, file, ...) end
        local origin = return_file
        return_file = nil
        local results = pack_values(original_show_file_manager(self, safe_return_file(origin), ...))
        open_collection()
        return unpack_values(results, 1, results.n)
    end

    return {
        collection_name = collection_name,
        decorate = decorate_collection,
        open_collection = open_collection,
    }
end

return install
