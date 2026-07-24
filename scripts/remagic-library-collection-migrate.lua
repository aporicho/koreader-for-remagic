-- Remove the connected-folder configuration written by adapter schema v1
-- before KOReader loads readcollection.lua.  readcollection.lua scans every
-- connected folder synchronously as a module side effect, which can block the
-- first painted frame for an unbounded amount of time.

local function migrate(options)
    assert(type(options) == "table", "collection migration options are required")

    local LuaSettings = assert(options.LuaSettings)
    local collection_file = assert(options.collection_file)
    local collection_name = assert(options.collection_name)
    local logger = assert(options.logger)

    local settings = LuaSettings:open(collection_file)
    local collection = settings.data[collection_name]
    if type(collection) ~= "table" or type(collection.settings) ~= "table" then
        return false
    end

    local metadata = collection.settings
    if metadata.remagic_collection_version ~= 1 then return false end

    metadata.folders = nil
    metadata.remagic_collection_version = 2
    settings:flush()
    logger.info("koreader-for-remagic: event=library-collection schema-migrated from=1 to=2")
    return true
end

return migrate
