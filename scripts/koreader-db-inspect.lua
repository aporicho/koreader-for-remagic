local db_path = arg[1]
if not db_path then
    io.stderr:write("usage: koreader-db-inspect.lua DATABASE\n")
    os.exit(2)
end

local min_schema = tonumber(os.getenv("KOREADER_DB_MIN_SCHEMA") or "20221111")
local max_schema = tonumber(os.getenv("KOREADER_DB_MAX_SCHEMA") or "20221111")
if not min_schema or not max_schema or min_schema > max_schema then
    io.stderr:write("invalid supported schema range\n")
    os.exit(2)
end

dofile("setupkoenv.lua")

local ffi = require("ffi")
ffi.cdef([[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;
    int sqlite3_open_v2(const char*, sqlite3**, int, const char*);
    int sqlite3_close_v2(sqlite3*);
    const char *sqlite3_errmsg(sqlite3*);
    int sqlite3_prepare_v2(sqlite3*, const char*, int, sqlite3_stmt**, const char**);
    int sqlite3_step(sqlite3_stmt*);
    int sqlite3_finalize(sqlite3_stmt*);
    const unsigned char *sqlite3_column_text(sqlite3_stmt*, int);
]])

local ok, result = pcall(function()
    local sqlite = ffi.load("libs/libsqlite3.so.0", true)
    local db_ptr = ffi.new("sqlite3*[1]")
    local escaped_path = db_path:gsub("([^%w%-%._~/])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
    local uri = "file:" .. escaped_path .. "?immutable=1"
    local rc = sqlite.sqlite3_open_v2(uri, db_ptr, 0x00000001 + 0x00000040, nil)
    local db = db_ptr[0]
    if rc ~= 0 then
        local message = db ~= nil and ffi.string(sqlite.sqlite3_errmsg(db)) or "open failed"
        if db ~= nil then
            sqlite.sqlite3_close_v2(db)
        end
        error(message)
    end

    local function query_value(sql)
        local stmt_ptr = ffi.new("sqlite3_stmt*[1]")
        local prepare_rc = sqlite.sqlite3_prepare_v2(db, sql, #sql, stmt_ptr, nil)
        if prepare_rc ~= 0 then
            error(ffi.string(sqlite.sqlite3_errmsg(db)))
        end
        local stmt = stmt_ptr[0]
        local step_rc = sqlite.sqlite3_step(stmt)
        if step_rc ~= 100 then -- SQLITE_ROW
            sqlite.sqlite3_finalize(stmt)
            error(ffi.string(sqlite.sqlite3_errmsg(db)))
        end
        local text_ptr = sqlite.sqlite3_column_text(stmt, 0)
        local value = text_ptr ~= nil and ffi.string(text_ptr) or nil
        sqlite.sqlite3_finalize(stmt)
        return value
    end

    local integrity = query_value("PRAGMA integrity_check;")
    if integrity ~= "ok" then
        sqlite.sqlite3_close_v2(db)
        error("integrity_check=" .. tostring(integrity))
    end

    local schema = tonumber(query_value("PRAGMA user_version;"))
    if not schema then
        sqlite.sqlite3_close_v2(db)
        error("non-numeric schema")
    end
    if schema < min_schema or schema > max_schema then
        sqlite.sqlite3_close_v2(db)
        return { schema = schema, unsupported = true }
    end
    local relations = tonumber(query_value([[
        SELECT count(*) FROM sqlite_master
        WHERE name IN ('book', 'page_stat')
          AND type IN ('table', 'view');
    ]]))
    if not schema or relations ~= 2 then
        sqlite.sqlite3_close_v2(db)
        error("missing book/page_stat schema")
    end

    local books = tonumber(query_value("SELECT count(*) FROM book;"))
    local pages = tonumber(query_value("SELECT count(*) FROM page_stat;"))
    sqlite.sqlite3_close_v2(db)

    if not books or not pages then
        error("could not count book/page_stat rows")
    end
    return { schema = schema, books = books, pages = pages }
end)

if not ok then
    io.stderr:write("invalid database: ", tostring(result), "\n")
    os.exit(1)
end

if result.unsupported then
    io.write(string.format(
        "KOREADER_DB_UNSUPPORTED\t%d\t%d\t%d\n",
        result.schema,
        -1,
        -1
    ))
    os.exit(3)
end

io.write(string.format(
    "KOREADER_DB_VALID\t%d\t%d\t%d\n",
    result.schema,
    result.books,
    result.pages
))
