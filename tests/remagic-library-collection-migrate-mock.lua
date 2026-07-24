local module_path = assert(arg[1])
local migrate = assert(dofile(module_path))

local function fail(message) error("FAIL: " .. message, 0) end
local settings = {
    data = {
        ["全部书籍"] = {
            { file = "/books/keep.epub", order = 1 },
            settings = {
                order = 2,
                folders = { ["/books"] = { subfolders = true } },
                remagic_collection_version = 1,
            },
        },
        ["用户收藏"] = {
            settings = { folders = { ["/other"] = { subfolders = true } } },
        },
    },
    flush_count = 0,
}
function settings:flush() self.flush_count = self.flush_count + 1 end

local LuaSettings = {}
function LuaSettings:open(path)
    if path ~= "/data/settings/collection.lua" then fail("unexpected collection path") end
    return settings
end
local logger = { info = function() end }
local options = {
    LuaSettings = LuaSettings,
    collection_file = "/data/settings/collection.lua",
    collection_name = "全部书籍",
    logger = logger,
}

if migrate(options) ~= true then fail("schema-v1 collection was not migrated") end
local managed = settings.data["全部书籍"]
if managed.settings.folders ~= nil then fail("managed connected folders survived") end
if managed.settings.remagic_collection_version ~= 2 then fail("schema marker was not advanced") end
if managed[1].file ~= "/books/keep.epub" then fail("collection item was changed") end
if settings.data["用户收藏"].settings.folders["/other"] == nil then
    fail("unrelated collection was changed")
end
if settings.flush_count ~= 1 then fail("migration was not flushed exactly once") end
if migrate(options) ~= false then fail("migration was not idempotent") end
if settings.flush_count ~= 1 then fail("idempotent migration rewrote settings") end

print("collection migration mock passed")
