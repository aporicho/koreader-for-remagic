-- This patch must sort before the lifecycle patch: requiring FileManager loads
-- readcollection.lua, whose module initializer synchronously scans connected
-- folders.  Remove only ReMagic schema-v1 folder ownership before that import.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local support_dir = assert(os.getenv("REMAGIC_KOREADER_LIBEXEC_DIR"),
    "REMAGIC_KOREADER_LIBEXEC_DIR is required")
local collection_name = os.getenv("KOREADER_COLLECTION_NAME") or "全部书籍"
local migrate = assert(dofile(support_dir .. "/remagic-library-collection-migrate.lua"))

local ok, err = pcall(migrate, {
    LuaSettings = LuaSettings,
    collection_file = DataStorage:getSettingsDir() .. "/collection.lua",
    collection_name = collection_name,
    logger = logger,
})
if not ok then
    logger.warn("koreader-for-remagic: event=library-collection-migration-failed error="
        .. tostring(err))
end
