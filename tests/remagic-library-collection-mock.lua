local module_path = assert(arg[1])
local mode = assert(arg[2])
local root = assert(arg[3])

local function fail(message) error("FAIL: " .. message, 0) end
local function equal(actual, expected, message)
    if actual ~= expected then
        fail((message or "values differ") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
    end
end

local collection_name = "全部书籍"
local library_dir = root .. "/library"
local books_dir = root .. "/books"
local source_dir = root .. "/xochitl"
local index_file = root .. "/library.index"
local uuid_one = "00000000-0000-0000-0000-000000000001"
local uuid_two = "00000000-0000-0000-0000-000000000002"
local uuid_missing = "00000000-0000-0000-0000-000000000003"
local official_one = source_dir .. "/" .. uuid_one .. ".epub"
local official_two = source_dir .. "/" .. uuid_two .. ".epub"
local official_missing = source_dir .. "/" .. uuid_missing .. ".epub"
local local_one = books_dir .. "/论语.epub"

if mode == "invalid_index" then
    local invalid = assert(io.open(index_file, "wb"))
    invalid:write("invalid-index\n")
    invalid:close()
end

local logs = {}
local logger = {}
for _, level in ipairs({ "info", "warn", "err", "dbg" }) do
    logger[level] = function(message) logs[#logs + 1] = level .. ":" .. tostring(message) end
end

local ReadCollection = {
    coll = { favorites = {} },
    coll_settings = { favorites = { order = 1 } },
    write_count = 0,
}
if mode == "existing" then
    ReadCollection.coll[collection_name] = {
        [root .. "/custom.epub"] = { file = root .. "/custom.epub", text = "custom.epub" },
    }
    ReadCollection.coll_settings[collection_name] = {
        order = 7,
        collate = "access",
        folders = { [root .. "/custom"] = { subfolders = false, scan_on_show = false } },
    }
end
function ReadCollection:addCollection(name)
    self.coll[name] = {}
    self.coll_settings[name] = { order = 2 }
end
function ReadCollection:write(updated)
    self.write_count = self.write_count + 1
    self.last_written = updated
end
function ReadCollection:updateCollectionFromFolder(name)
    if name ~= collection_name then return 0 end
    local collection = self.coll[name]
    local added = 0
    local fixtures = {
        [library_dir] = { official_one, official_two, official_missing },
        [books_dir] = { local_one },
    }
    for folder in pairs(self.coll_settings[name].folders or {}) do
        for _, file in ipairs(fixtures[folder] or {}) do
            if not collection[file] then
                collection[file] = { file = file, text = file:match("([^/]+)$") }
                added = added + 1
            end
        end
    end
    return added
end

local collection_open_count = 0
local last_collection_items
local collection_ui = {}
function collection_ui:onShowColl(name)
    equal(name, collection_name, "opened collection")
    ReadCollection:updateCollectionFromFolder(name, nil, true)
    collection_open_count = collection_open_count + 1
    last_collection_items = {}
    for file, item in pairs(ReadCollection.coll[name]) do
        last_collection_items[file] = item.text
    end
    return true
end

local FileManager = {
    instance = nil,
    delete_count = 0,
    move_count = 0,
    rename_count = 0,
    write_count = 0,
    file_chooser = { path = books_dir },
}
function FileManager:showFiles(path)
    self.last_path = path
    self.instance = { collections = collection_ui }
    return "show-files", nil, 3
end
function FileManager:showDeleteFileDialog(path)
    self.delete_count = self.delete_count + 1
    return "delete:" .. path
end
function FileManager:deleteFile(path)
    self.delete_count = self.delete_count + 1
    return "deleted:" .. path
end
function FileManager:showRenameFileDialog(path)
    self.rename_count = self.rename_count + 1
    return "rename:" .. path
end
function FileManager:renameFile(path)
    self.rename_count = self.rename_count + 1
    return "renamed:" .. path
end
function FileManager:cutFile(path) return "cut:" .. path end
function FileManager:moveFile(from, to)
    self.move_count = self.move_count + 1
    return from .. "->" .. to
end
function FileManager:pasteFileFromClipboard(path)
    self.write_count = self.write_count + 1
    return "pasted:" .. tostring(path)
end
function FileManager:pasteSelectedFiles()
    self.write_count = self.write_count + 1
    return "selected-pasted"
end
function FileManager:createFolder()
    self.write_count = self.write_count + 1
    return "folder-created"
end
function FileManager:copyFileFromTo(from, to)
    self.write_count = self.write_count + 1
    return from .. "=>" .. to
end
function FileManager:copyRecursive(from, to)
    self.write_count = self.write_count + 1
    return from .. "=>" .. to
end
function FileManager:deleteSelectedFiles()
    self.delete_count = self.delete_count + 1
    return "selected-deleted"
end

local FileManagerCollection = { select_count = 0 }
function FileManagerCollection:onMenuSelect(item)
    self.select_count = (self.select_count or 0) + 1
    self.last_selected = item.file
    return "selected", nil, 4
end

local ReaderUI = { last_file_manager_path = nil }
function ReaderUI:showFileManager(file)
    self.last_file_manager_path = file
    FileManager:showFiles(file or library_dir)
    return "file-manager", nil, 5
end

local UIManager = { shown = {} }
function UIManager:show(widget) self.shown[#self.shown + 1] = widget end
local InfoMessage = {}
function InfoMessage:new(options) return options end
local ffiUtil = { realpath = function(path) return path end }

local install = assert(dofile(module_path))
local state = install({
    FileManager = FileManager,
    FileManagerCollection = FileManagerCollection,
    InfoMessage = InfoMessage,
    ReadCollection = ReadCollection,
    ReaderUI = ReaderUI,
    UIManager = UIManager,
    ffiUtil = ffiUtil,
    logger = logger,
    collection_name = collection_name,
    library_dir = library_dir,
    books_dir = books_dir,
    source_dir = source_dir,
    index_file = index_file,
    initial_open_path = mode == "explicit" and official_one or nil,
})

equal(state.collection_name, collection_name, "managed collection name")
local settings = ReadCollection.coll_settings[collection_name]
equal(settings.folders[library_dir].subfolders, false, "official recursion")
equal(settings.folders[library_dir].scan_on_show, false, "official scan-on-show")
equal(settings.folders[books_dir].subfolders, true, "local recursion")
equal(settings.folders[books_dir].scan_on_show, false, "local scan-on-show")
equal(settings.remagic_collection_version, 1, "collection schema")

if mode == "existing" then
    equal(settings.order, 7, "existing collection order")
    equal(settings.collate, "access", "existing collection sort")
    if not settings.folders[root .. "/custom"] then fail("custom folder was overwritten") end
    if not ReadCollection.coll[collection_name][root .. "/custom.epub"] then
        fail("custom collection item was overwritten")
    end
else
    equal(settings.collate, "natural", "new collection sort")
end

local first, second, third = FileManager:showFiles(root .. "/bootstrap")
equal(first, "show-files", "FileManager return 1")
equal(second, nil, "FileManager return 2")
equal(third, 3, "FileManager return 3")
if mode == "explicit" then
    equal(collection_open_count, 0, "explicit path bypasses collection")
    print("collection mock passed: " .. mode)
    return
end

equal(collection_open_count, 1, "cold start opens collection")
if mode == "invalid_index" then
    if not ReadCollection.coll[collection_name][official_one]
            or not ReadCollection.coll[collection_name][official_missing]
    then
        fail("invalid index removed an official collection entry")
    end
    print("collection mock passed: " .. mode)
    return
end
equal(last_collection_items[official_one], "论语（官方）.epub", "official collision label")
equal(last_collection_items[local_one], "论语（本地）.epub", "local collision label")
equal(last_collection_items[official_two], "孟子.epub", "friendly official name")
if ReadCollection.coll[collection_name][official_missing] then
    fail("unmapped official UUID leaked into the collection")
end

FileManager:showFiles(root .. "/second")
equal(collection_open_count, 1, "collection opens only on initial FileManager")

equal(FileManager:showDeleteFileDialog(official_one), false, "official delete guard")
equal(FileManager.delete_count, 0, "official delete reached KOReader")
equal(FileManager:moveFile(official_one, root .. "/moved"), false, "official move guard")
equal(FileManager.move_count, 0, "official move reached KOReader")
FileManager.file_chooser.path = source_dir
equal(FileManager:pasteFileFromClipboard(source_dir), false, "official paste guard")
equal(FileManager:pasteSelectedFiles(), false, "official selected paste guard")
equal(FileManager:createFolder(), false, "official create-folder guard")
equal(FileManager:copyFileFromTo(local_one, source_dir), false, "official copy guard")
equal(FileManager:copyRecursive(local_one, source_dir), false, "official recursive-copy guard")
equal(FileManager.write_count, 0, "official write reached KOReader")
if #UIManager.shown < 2 then fail("read-only warning was not shown") end
equal(FileManager:showDeleteFileDialog(local_one), "delete:" .. local_one, "local delete")
equal(FileManager.delete_count, 1, "local delete was blocked")
FileManager.file_chooser.path = books_dir
equal(FileManager:createFolder(), "folder-created", "local create-folder")
equal(FileManager.write_count, 1, "local write was blocked")

local booklist = { path = collection_name, _manager = { selected_files = nil } }
local selected, empty, marker = FileManagerCollection.onMenuSelect(booklist, { file = official_one })
equal(selected, "selected", "collection select return 1")
equal(empty, nil, "collection select return 2")
equal(marker, 4, "collection select return 3")
local shown, nil_value, return_marker = ReaderUI:showFileManager(official_one)
equal(shown, "file-manager", "ReaderUI return 1")
equal(nil_value, nil, "ReaderUI return 2")
equal(return_marker, 5, "ReaderUI return 3")
equal(ReaderUI.last_file_manager_path, library_dir .. "/论语.epub", "safe return path")
equal(collection_open_count, 2, "reader returns to collection")

print("collection mock passed: " .. mode)
