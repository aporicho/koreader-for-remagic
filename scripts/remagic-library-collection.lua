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
    local logger = assert(options.logger)

    local collection_name = assert(options.collection_name)
    local library_dir = assert(options.library_dir)
    local books_dir = assert(options.books_dir)
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
    books_dir = normalize_root(books_dir)
    source_dir = normalize_root(canonical(source_dir))

    local function is_within(path, root)
        path = canonical(path)
        if not path then return false end
        return path == root or path:sub(1, #root + 1) == root .. "/"
    end

    local function is_read_only_library_path(path)
        return is_within(path, source_dir) or is_within(path, canonical(library_dir))
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
            local uuid, extension, filename = line:match(
                "^([0-9A-Fa-f%-]+)\t(epub)\t([^\t\r\n]+)$")
            if not uuid then
                uuid, extension, filename = line:match(
                    "^([0-9A-Fa-f%-]+)\t(pdf)\t([^\t\r\n]+)$")
            end
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
            elseif is_within(file, canonical(books_dir)) then
                text = basename(file)
                source = "本地"
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

    local function managed_folder(settings, path, subfolders, source)
        settings.folders = type(settings.folders) == "table" and settings.folders or {}
        local folder = settings.folders[path]
        local changed = false
        local added = false
        if type(folder) ~= "table" then
            folder = {}
            settings.folders[path] = folder
            changed = true
            added = true
        end
        if folder.subfolders ~= subfolders then folder.subfolders = subfolders; changed = true end
        if folder.scan_on_show ~= false then folder.scan_on_show = false; changed = true end
        if folder.remagic_source ~= source then folder.remagic_source = source; changed = true end
        return changed, added
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

        local changed, library_added = managed_folder(settings, library_dir, false, "remarkable")
        local books_changed, books_added = managed_folder(settings, books_dir, true, "local")
        changed = books_changed or changed
        if created and settings.collate == nil then settings.collate = "natural"; changed = true end
        if settings.remagic_collection_version ~= 1 then
            settings.remagic_collection_version = 1
            changed = true
        end
        if created or changed then
            ReadCollection:write({ [collection_name] = true })
            log("info", created and "collection-created" or "collection-updated")
        end
        return created or library_added or books_added
    end

    local initial_scan_required = ensure_collection()

    local original_update = ReadCollection.updateCollectionFromFolder
    ReadCollection.updateCollectionFromFolder = function(self, name, ...)
        local count = original_update(self, name, ...)
        if name == collection_name then
            local removed = decorate_collection()
            if count > 0 or removed then self:write({ [collection_name] = true }) end
        end
        return count
    end
    if initial_scan_required then
        ReadCollection:updateCollectionFromFolder(collection_name)
    elseif decorate_collection() then
        ReadCollection:write({ [collection_name] = true })
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
        if is_within(file, canonical(books_dir)) then return file end
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
