-- Late userpatch: connect ReMagic's two document roots to KOReader's native
-- Collections UI after G_reader_settings and UIManager are ready.
-- All behavior lives in the adapter; the pinned official KOReader tree stays
-- byte-for-byte unchanged.

local logger = require("logger")
local support_dir = assert(os.getenv("REMAGIC_KOREADER_LIBEXEC_DIR"),
    "REMAGIC_KOREADER_LIBEXEC_DIR is required")
local install = assert(dofile(support_dir .. "/remagic-library-collection.lua"))

local ok, err = pcall(install, {
    FileManager = require("apps/filemanager/filemanager"),
    FileManagerCollection = require("apps/filemanager/filemanagercollection"),
    InfoMessage = require("ui/widget/infomessage"),
    ReadCollection = require("readcollection"),
    ReaderUI = require("apps/reader/readerui"),
    UIManager = require("ui/uimanager"),
    ffiUtil = require("ffi/util"),
    logger = logger,
    collection_name = os.getenv("KOREADER_COLLECTION_NAME") or "全部书籍",
    library_dir = os.getenv("KOREADER_LIBRARY_DIR")
        or "/home/root/.local/share/koreader-for-remagic/library",
    books_dir = os.getenv("KOREADER_BOOKS_DIR") or "/home/root/books",
    source_dir = os.getenv("KOREADER_SOURCE_LIBRARY_DIR")
        or "/home/root/.local/share/remarkable/xochitl",
    index_file = os.getenv("KOREADER_LIBRARY_INDEX")
        or "/home/root/.local/share/koreader-for-remagic/library.index",
    initial_open_path = os.getenv("REMAGIC_INITIAL_OPEN_PATH"),
})
if not ok then
    logger.warn("koreader-for-remagic: event=library-collection-disabled error=" .. tostring(err))
end
