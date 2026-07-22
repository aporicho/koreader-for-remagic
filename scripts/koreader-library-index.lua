#!/usr/bin/env lua

-- Build a deterministic, shell-safe mapping from reMarkable metadata to
-- friendly KOReader filenames. JSON decoding deliberately comes from the
-- KOReader installation rather than from an ad-hoc parser in this adapter.

local function die(message)
    io.stderr:write("koreader-library-index: ", message, "\n")
    os.exit(2)
end

if arg[1] == "--atomic-rename" then
    if not arg[2] or not arg[3] or arg[4] then
        die("--atomic-rename requires SOURCE and DESTINATION")
    end
    local ok, err = os.rename(arg[2], arg[3])
    if not ok then
        die("atomic rename failed: " .. tostring(err))
    end
    os.exit(0)
end

local source_dir = arg[1]
if not source_dir or source_dir == "" then
    die("source directory argument is required")
end
source_dir = source_dir:gsub("/+$", "")
if source_dir == "" then
    source_dir = "/"
end

local koreader_dir = os.getenv("KOREADER_DIR") or "/home/root/apps/koreader"
local json_dir = os.getenv("KOREADER_JSON_DIR") or (koreader_dir .. "/common")
package.path = json_dir .. "/?.lua;" .. json_dir .. "/?/init.lua;" .. package.path

local ok_json, json = pcall(require, "dkjson")
if not ok_json then
    die("could not load KOReader JSON decoder: " .. tostring(json))
end

local function read_metadata(path)
    local file, open_err = io.open(path, "rb")
    if not file then
        die("could not read metadata " .. path .. ": " .. tostring(open_err))
    end
    local contents = file:read(1024 * 1024 + 1)
    file:close()
    if not contents then
        die("could not read metadata " .. path)
    end
    if #contents > 1024 * 1024 then
        die("metadata is unexpectedly large: " .. path)
    end

    local decoded_ok, value, next_position, decode_err = pcall(json.decode, contents, 1, nil)
    if not decoded_ok then
        die("invalid JSON in " .. path .. ": " .. tostring(value))
    end
    if value == nil or decode_err then
        die("invalid JSON in " .. path .. ": " .. tostring(decode_err or "empty value"))
    end
    if type(value) ~= "table" then
        die("metadata root is not an object: " .. path)
    end
    if next_position and contents:sub(next_position):match("%S") then
        die("trailing data after JSON object: " .. path)
    end
    return value
end

local function valid_uuid(value)
    if #value ~= 36 or not value:match("^[%x%-]+$") then
        return false
    end
    return value:sub(9, 9) == "-"
        and value:sub(14, 14) == "-"
        and value:sub(19, 19) == "-"
        and value:sub(24, 24) == "-"
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function utf8_prefix(value, maximum)
    local chunks = {}
    local length = 0
    local index = 1
    while index <= #value do
        local first = value:byte(index)
        local width
        if first < 0x80 then
            width = 1
        elseif first >= 0xC2 and first <= 0xDF then
            width = 2
        elseif first >= 0xE0 and first <= 0xEF then
            width = 3
        elseif first >= 0xF0 and first <= 0xF4 then
            width = 4
        else
            width = 0
        end

        local chunk
        if width > 0 and index + width - 1 <= #value then
            local valid = true
            for offset = 1, width - 1 do
                local byte = value:byte(index + offset)
                if byte < 0x80 or byte > 0xBF then
                    valid = false
                    break
                end
            end
            if valid then
                chunk = value:sub(index, index + width - 1)
                index = index + width
            end
        end
        if not chunk then
            chunk = "_"
            index = index + 1
        end
        if length + #chunk > maximum then
            break
        end
        chunks[#chunks + 1] = chunk
        length = length + #chunk
    end
    return table.concat(chunks)
end

local function sanitize_title(value, uuid)
    if type(value) ~= "string" then
        value = ""
    end
    value = value:gsub("[%z\1-\31\127]", " ")
    value = value:gsub("/", "／")
    value = value:gsub("\\", "＼")
    value = value:gsub("%s+", " ")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("^[%.%s]+", "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = utf8_prefix(value, 200)
    value = value:gsub("%s+$", "")
    if value == "" then
        value = "未命名-" .. uuid:sub(1, 8)
    end
    return value
end

local records = {}
for index = 2, #arg do
    local metadata_path = arg[index]
    local expected_prefix = source_dir == "/" and "/" or (source_dir .. "/")
    if metadata_path:sub(1, #expected_prefix) ~= expected_prefix then
        die("metadata path is outside the source directory: " .. metadata_path)
    end

    local basename = metadata_path:match("([^/]+)%.metadata$")
    local uuid = basename
    if uuid and valid_uuid(uuid) then
        local metadata = read_metadata(metadata_path)
        if metadata.type == "DocumentType" and metadata.deleted ~= true then
            local extension
            if file_exists(source_dir .. "/" .. uuid .. ".epub") then
                extension = ".epub"
            elseif file_exists(source_dir .. "/" .. uuid .. ".pdf") then
                extension = ".pdf"
            end
            if extension then
                records[#records + 1] = {
                    uuid = uuid,
                    extension = extension,
                    base = sanitize_title(metadata.visibleName, uuid),
                }
            end
        end
    end
end

table.sort(records, function(left, right)
    return left.uuid < right.uuid
end)

local initial_counts = {}
for _, record in ipairs(records) do
    local candidate = record.base .. record.extension
    initial_counts[candidate] = (initial_counts[candidate] or 0) + 1
end

local function with_suffix(base, suffix, extension)
    local maximum_base = 240 - #suffix - #extension
    return utf8_prefix(base, maximum_base) .. suffix .. extension
end

local used = {}
for _, record in ipairs(records) do
    local initial = record.base .. record.extension
    local candidate = initial
    if initial_counts[initial] > 1 then
        candidate = with_suffix(record.base, " [" .. record.uuid:sub(1, 8) .. "]", record.extension)
    end
    if used[candidate] then
        candidate = with_suffix(record.base, " [" .. record.uuid .. "]", record.extension)
        local sequence = 2
        while used[candidate] do
            candidate = with_suffix(record.base, " [" .. record.uuid .. "-" .. sequence .. "]", record.extension)
            sequence = sequence + 1
        end
    end
    record.filename = candidate
    used[candidate] = true
end

io.write("# koreader-for-remagic-library-v1\n")
for _, record in ipairs(records) do
    io.write(record.uuid, "\t", record.extension:sub(2), "\t", record.filename, "\n")
end
