-- Tab bar of panel.luau: Search/Space buttons, selection and body swap, with
-- the host stubbed. Run through tests/run.sh, which prepends the unmodified
-- panel source as PANEL_SRC.

local rendered, opened, frameTick
local searches = {} -- callbacks of the fzf runs the panel has started

local function node(kind)
    return function(props, children)
        return { kind = kind, props = props, children = children }
    end
end
ui = setmetatable({}, { __index = function(_, kind) return node(kind) end })
panel = {
    render = function(tree) rendered = tree end,
    setNeedsFrameTick = function(on) frameTick = on end,
    close = function() end,
    openContextMenu = function() end,
}
noctalia = {
    readFile = function() return nil end,
    writeFile = function() return true end,
    log = function() end,
    getConfig = function() return nil end,
    fileInfo = function() return nil end,
    fileExists = function() return true end,
    commandExists = function() return true end,
    nowMs = function() return 0 end,
    notify = function() end,
    copyToClipboard = function() end,
    openSettings = function() end,
    diskStats = function() return nil end,
    state = { set = function() end },
    runAsync = function(_, callback)
        table.insert(searches, callback)
        return true
    end,
}
local shared = {
    roots = { "/home" }, mounts = {}, scope = "folder", whole = false,
    ranking = "path", schemeSupported = true,
    NEXT_RANKING = { path = "default", default = "path" },
    NEXT_SCOPE = { folder = "all" }, RANKING_GLYPHS = {}, SCOPE_GLYPHS = {},
    tr = function(key) return key end,
    trim = function(value) return value:match("^%s*(.-)%s*$") end,
    dataDir = function() return "/data" end,
    cacheTag = function() return "folder" end,
    searchRoot = function() return "/home" end,
    computeRoots = function() return { "/home" } end,
    indexRootsOf = function() return nil end,
    cacheFresh = function() return true end,
    autoIndexAllowed = function() return true end,
    cacheSh = function() return "" end,
    searchCommand = function() return "fzf" end,
    readScope = function() return "folder" end,
    readWhole = function() return false end,
    readRanking = function() return "path" end,
    probeMounts = function(_, callback) callback() end,
    probeFzfScheme = function() end,
    formatBytes = function() return "0 B" end,
    absolutePath = function(rel) return "/home/" .. rel end,
    openPath = function(path) opened = path end,
}
local usage = {
    state = "idle", slices = {}, skipped = {}, total = 0,
    load = function() return false end,
    scan = function() end,
    writeSvg = function() end,
}
local space = {
    onOpen = function() end, onClose = function() end,
    needsTick = function() return false end, step = function() return false end,
    render = function() return ui.label({ key = "space", text = "space" }) end,
}
require = function(path)
    if path == "./shared.luau" then return shared end
    return path == "./space.luau" and space or usage
end
assert(loadstring(PANEL_SRC, "=panel.luau"))()


local function find(node, key)
    if node.props and node.props.key == key then return node end
    for _, child in ipairs(node.children or {}) do
        local hit = find(child, key)
        if hit then return hit end
    end
end

onOpen(nil)
local tabSearch, tabSpace = find(rendered, "tab-search"), find(rendered, "tab-space")
assert(tabSearch and tabSpace)
assert(tabSearch.props.glyph == "search" and tabSpace.props.glyph == "chart-pie")
assert(tabSearch.props.selected == true and not tabSpace.props.selected)
assert(find(rendered, "query-1") ~= nil)

tabSpace.props.onClick()
assert(find(rendered, "tab-space").props.selected == true)
assert(not find(rendered, "tab-search").props.selected)
assert(find(rendered, "query-1") == nil)
assert(find(rendered, "space") ~= nil)

find(rendered, "tab-search").props.onClick()
assert(find(rendered, "tab-search").props.selected == true)
assert(find(rendered, "query-1") ~= nil)
assert(find(rendered, "space") == nil)

print("file-search panel tab tests: ok")
