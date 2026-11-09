-- module: shared.luau
-- Source modes: which roots the index covers (computeRoots), the cache it uses
-- (cacheTag) and how a saved scope is read. Home only = no extras, home +
-- folders = search folder plus the extra list, whole system = "/" alone.
-- Run through tests/file-search/run.sh, which splices shared.luau as MODULE_SRC.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end

local FILES = {}
noctalia = {
    pluginDataDir = function() return "/data" end,
    readFile = function(p) return FILES[p] end,
    getConfig = function(k) return k == "search_folder" and "/home/u" or nil end,
    expandPath = function(p) return p end,
    getenv = function(k) return "/home/u" end,
    log = function() end,
}
local shared = loadstring(MODULE_SRC)()

local function roots(state)
    shared.scope = state.scope or "folder"
    shared.whole = state.whole or false
    shared.folders = state.folders or false
    shared.mounts = state.mounts or {}
    return table.concat(shared.computeRoots(), "|")
end

-- A scope saved by an older build still reads: "external" is now "all".
FILES["/data/scope"] = "external"
eq(shared.readScope("/data"), "all", "legacy external scope")
FILES["/data/scope"] = "folder"
eq(shared.readScope("/data"), "folder", "folder scope")
eq(shared.NEXT_SCOPE.folder, "all", "folder -> all")
eq(shared.NEXT_SCOPE.all, "folder", "all -> folder")

-- folders on/off persisted as a word file.
FILES["/data/folders"] = "on"
eq(shared.readFolders("/data"), true, "folders on")
FILES["/data/folders"] = "off"
eq(shared.readFolders("/data"), false, "folders off")
eq(shared.readFolders("/missing"), false, "folders default off")

FILES["/data/extra_roots"] = "/media/windows\n/home/u/sub\nrelative/path\n/bad\1path\n/a/../b\n/a//b\n/a/./b\n/\n"

-- A folder the user adds must be a plain absolute path.
for _, bad in ipairs({ "", "/", "rel", "/a/../b", "/a//b", "/a/./b", "/..", "/bad\1" }) do
    eq(shared.validRoot(bad), false, "rejected: " .. bad)
end
eq(shared.validRoot("/media/windows"), true, "plain path")
eq(shared.validRoot("/media/my disk"), true, "space is fine")

eq(roots({}), "/home/u", "home only ignores the list")
eq(roots({ folders = true }), "/home/u|/media/windows", "home + folders; nested and invalid lines dropped")
eq(roots({ whole = true, folders = true }), "/", "whole system wins over folders")
eq(roots({ scope = "all", folders = true, mounts = { "/run/media/u/USB/" } }),
    "/home/u|/media/windows|/run/media/u/USB", "folders + USB disks")
eq(roots({ scope = "all", folders = true, mounts = { "/media/windows/" } }),
    "/home/u|/media/windows", "mount equal to an extra is one root")

-- One cache per combination, so switching modes does not rebuild.
local function tag(state) roots(state) return shared.cacheTag() end
eq(tag({}), "folder", "tag home")
eq(tag({ folders = true }), "folder-dirs", "tag folders")
eq(tag({ scope = "all", whole = true }), "all-root", "tag whole + USB")
eq(tag({ whole = true, folders = true }), "folder-root", "whole ignores folders in the tag")

print("shared_roots_test OK")
