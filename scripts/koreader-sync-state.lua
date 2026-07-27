-- ReMagic sync provider for KOReader. This file runs under the exact KOReader
-- vendor LuaJIT and uses upstream DocSettings for all writes.
require("setupkoenv")

local lfs = require("libs/libkoreader-lfs")
local json = require("json")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local DocSettings = require("docsettings")

local operation, exchange_file = arg[1], arg[2]
local books_root = assert(os.getenv("KOREADER_BOOKS_DIR"), "KOREADER_BOOKS_DIR is required")
local source_root = os.getenv("KOREADER_SOURCE_LIBRARY_DIR") or books_root
local library_root = os.getenv("KOREADER_LIBRARY_DIR")
local data_root = assert(os.getenv("KOREADER_DATA_DIR"), "KOREADER_DATA_DIR is required")
local document_roots = { books_root, source_root, library_root }
local supported_extensions = {
    epub = true,
    pdf = true,
    djvu = true,
    djv = true,
    mobi = true,
    azw3 = true,
    fb2 = true,
    cbz = true,
    cbr = true,
    txt = true,
}
local document_setting_fields = {
    "font_face",
    "font_family_fonts",
    "css",
    "style_tweaks",
    "copt_font_size",
    "copt_line_spacing",
    "copt_word_spacing",
    "copt_word_expansion",
    "copt_h_page_margins",
    "copt_t_page_margin",
    "copt_b_page_margin",
    "copt_sync_t_b_page_margins",
    "copt_font_base_weight",
    "copt_font_hinting",
    "copt_font_kerning",
    "copt_font_gamma",
    "copt_embedded_fonts",
    "copt_embedded_css",
    "copt_block_rendering_mode",
    "copt_page_scroll",
    "copt_rotation_mode",
    "copt_visible_pages",
    "copt_smooth_scaling",
    "copt_nightmode_images",
    "copt_render_dpi",
    "copt_writing_direction",
    "kopt_font_size",
    "kopt_text_wrap",
    "kopt_line_spacing",
    "kopt_word_spacing",
    "kopt_page_margin",
    "kopt_trim_page",
    "kopt_zoom_factor",
    "kopt_zoom_mode_genus",
    "kopt_zoom_mode_type",
    "kopt_zoom_direction",
    "kopt_zoom_range_number",
    "kopt_zoom_overlap_h",
    "kopt_zoom_overlap_v",
    "kopt_contrast",
    "kopt_quality",
    "kopt_page_opt",
    "kopt_rotation_mode",
    "kopt_page_scroll",
    "kopt_page_gap_height",
    "kopt_doc_language",
    "kopt_forced_ocr",
    "kopt_max_columns",
    "kopt_justification",
    "kopt_writing_direction",
    "kopt_auto_straighten",
}

local function direct_child(root, path)
    if type(root) ~= "string" or root == "" then
        return nil
    end
    root = root:gsub("/+$", "")
    if root == "" then
        root = "/"
    end
    local prefix = root == "/" and "/" or (root .. "/")
    if path:sub(1, #prefix) ~= prefix then
        return nil
    end
    local relative = path:sub(#prefix + 1)
    if relative == "" or relative:find("/", 1, true) then
        return nil
    end
    return relative
end

local function has_supported_extension(filename)
    local extension = filename:match("%.([^.]+)$")
    return extension and supported_extensions[extension:lower()] == true
end

local function is_book_path(path)
    if type(path) ~= "string" or path:find("/../", 1, true) or path:sub(-3) == "/.." then
        return false
    end
    for _, root in ipairs(document_roots) do
        local child = direct_child(root, path)
        if child and has_supported_extension(child) then
            return true
        end
    end
    return false
end

local function is_regular(path)
    return lfs.attributes(path, "mode") == "file"
end

local function copy_bookmarks(annotations)
    local bookmarks = {}
    if type(annotations) ~= "table" then return bookmarks end
    for _, item in ipairs(annotations) do
        if type(item) == "table" and not item.drawer
            and (type(item.page) == "number" or type(item.page) == "string") then
            bookmarks[#bookmarks + 1] = {
                page = item.page,
                datetime = type(item.datetime) == "string" and item.datetime or nil,
                text = type(item.text) == "string" and item.text or nil,
                notes = type(item.notes) == "string" and item.notes or nil,
            }
        end
    end
    return bookmarks
end

local function bookmark_key(item)
    return tostring(item.page or "") .. "\0" .. tostring(item.text or "") .. "\0"
        .. tostring(item.notes or "")
end

local function copy_json_value(value, depth)
    if depth > 4 then return nil end
    local value_type = type(value)
    if value_type == "string" then
        if #value <= 65536 then return value end
    elseif value_type == "number" then
        if value == value and value > -1000000000 and value < 1000000000 then return value end
    elseif value_type == "boolean" then
        return value
    elseif value_type == "table" then
        local copy, count = {}, 0
        for key, child in pairs(value) do
            local key_type = type(key)
            if key_type ~= "string" and (key_type ~= "number" or key < 1 or key > 10000 or key % 1 ~= 0) then
                return nil
            end
            local child_copy = copy_json_value(child, depth + 1)
            if child_copy ~= nil then
                copy[key] = child_copy
            end
            count = count + 1
            if count > 512 then return nil end
        end
        return copy
    end
    return nil
end

local function copy_document_settings(record, stored)
    for _, field in ipairs(document_setting_fields) do
        local value = copy_json_value(stored[field], 0)
        if value ~= nil then
            record[field] = value
        end
    end
end

local function save_document_settings(settings, record)
    for _, field in ipairs(document_setting_fields) do
        local value = copy_json_value(record[field], 0)
        if value ~= nil then
            settings:saveSetting(field, value)
        end
    end
end

local function record_from_file(path)
    local ok, stored = pcall(dofile, path)
    if not ok or type(stored) ~= "table" or not is_book_path(stored.doc_path)
        or not is_regular(stored.doc_path) then
        return nil
    end
    local attributes = lfs.attributes(path)
    local record = {
        path = stored.doc_path,
        updated_at = attributes and attributes.modification or 0,
        last_xpointer = type(stored.last_xpointer) == "string" and stored.last_xpointer or nil,
        last_page = type(stored.last_page) == "number" and stored.last_page or nil,
        percent_finished = type(stored.percent_finished) == "number" and stored.percent_finished or nil,
        bookmarks = copy_bookmarks(stored.annotations),
    }
    copy_document_settings(record, stored)
    return record
end

local function walk(root, records, seen)
    if lfs.attributes(root, "mode") ~= "directory" then return end
    for entry in lfs.dir(root) do
        if entry ~= "." and entry ~= ".." then
            local path = root .. "/" .. entry
            local mode = lfs.symlinkattributes(path, "mode")
            if mode == "directory" then
                walk(path, records, seen)
            elseif mode == "file" and entry:match("^metadata%..+%.lua$") then
                local record = record_from_file(path)
                if record and not seen[record.path] then
                    seen[record.path] = true
                    records[#records + 1] = record
                end
            end
        end
    end
end

local function write_atomic(path, value)
    local temporary = path .. ".tmp"
    local file = assert(io.open(temporary, "wb"))
    file:write(assert(json.encode(value)))
    file:write("\n")
    assert(file:close())
    assert(os.rename(temporary, path))
end

local function export_state()
    -- LuaJSON otherwise serializes an empty table as {}, while the ReMagic
    -- reading-state contract requires books to remain an array even when this
    -- device has never opened a book.
    local records, seen = json.util.InitArray({}), {}
    walk(books_root, records, seen)
    walk(data_root .. "/docsettings", records, seen)
    walk(data_root .. "/hashdocsettings", records, seen)
    table.sort(records, function(a, b) return a.path < b.path end)
    write_atomic(exchange_file, { schema = 1, books = records })
    io.write(string.format("exported %d reading records\n", #records))
end

local function safe_number(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum
end

local function import_state()
    local file = assert(io.open(exchange_file, "rb"))
    local bytes = assert(file:read("*a"))
    file:close()
    assert(#bytes <= 16 * 1024 * 1024, "sync state exceeds 16 MiB")
    local payload = assert(json.decode(bytes))
    assert(payload.schema == 1 and type(payload.books) == "table", "unsupported sync state")
    local applied = 0
    for _, record in ipairs(payload.books) do
        if type(record) == "table" and is_book_path(record.path) and is_regular(record.path) then
            local settings = DocSettings:open(record.path)
            if type(record.last_xpointer) == "string" and #record.last_xpointer <= 65536 then
                settings:saveSetting("last_xpointer", record.last_xpointer)
                settings:delSetting("last_page")
            elseif safe_number(record.last_page, 1, 100000000) then
                settings:saveSetting("last_page", math.floor(record.last_page))
                settings:delSetting("last_xpointer")
            end
            if safe_number(record.percent_finished, 0, 1) then
                settings:saveSetting("percent_finished", record.percent_finished)
            end
            save_document_settings(settings, record)

            local annotations = settings:readSetting("annotations") or {}
            local preserved, seen = {}, {}
            for _, item in ipairs(annotations) do
                if type(item) == "table" and item.drawer then
                    preserved[#preserved + 1] = item
                elseif type(item) == "table" then
                    local key = bookmark_key(item)
                    if not seen[key] then
                        seen[key] = true
                        preserved[#preserved + 1] = item
                    end
                end
            end
            if type(record.bookmarks) == "table" then
                for _, bookmark in ipairs(record.bookmarks) do
                    if type(bookmark) == "table"
                        and (type(bookmark.page) == "number" or type(bookmark.page) == "string") then
                        local bookmark = {
                            page = bookmark.page,
                            datetime = type(bookmark.datetime) == "string" and bookmark.datetime or os.date("%Y-%m-%d %H:%M:%S"),
                            text = type(bookmark.text) == "string" and bookmark.text or "",
                            notes = type(bookmark.notes) == "string" and bookmark.notes or nil,
                        }
                        local key = bookmark_key(bookmark)
                        if not seen[key] then
                            seen[key] = true
                            preserved[#preserved + 1] = bookmark
                        end
                    end
                end
                settings:saveSetting("annotations", preserved)
            end
            assert(settings:flush(), "unable to persist KOReader document settings")
            applied = applied + 1
        end
    end
    io.write(string.format("imported %d reading records\n", applied))
end

if operation == "export" then
    export_state()
elseif operation == "import" then
    import_state()
else
    error("operation must be export or import")
end
