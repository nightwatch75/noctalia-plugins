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
    startsWith = function(v, pre) return v:sub(1, #pre) == pre end,
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
    busy = false, onStep = nil,
    onOpen = function() end, onClose = function() end,
    render = function() return ui.label({ key = "space", text = "space" }) end,
}
-- needsTick/step driven by the test: onStep plays what one engine step does.
function space.onOpen(redraw) space.redraw = redraw end
function space.needsTick() return space.busy end
function space.step()
    if space.onStep then space.onStep() end
    return space.busy
end
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

-- Frame tick follows space.needsTick() after every step. (a) A step that
-- ends a load (its redraw sees nothing left, the tick goes off) and then
-- starts the deferred rescan: the tick must be on again afterwards.
find(rendered, "tab-space").props.onClick()
space.busy = true
space.onStep = function()
    space.busy = false
    space.redraw() -- endLoad -> changed(): render sees nothing left
    space.busy = true -- the deferred scan starts in the same step
end
onFrameTick(16)
assert(frameTick == true, "tick on while the deferred scan runs")
space.onStep = function() space.busy = false end -- marker consumed, load done
onFrameTick(16)
assert(frameTick == false, "tick off once nothing is left")

-- (b) Reopened on the Search tab while a scan runs: the tick goes off after
-- the last step even though no redraw comes from the closed-over space side.
onClose()
space.busy = true
space.onStep = nil
onOpen(nil)
assert(find(rendered, "tab-search").props.selected == true)
assert(frameTick == true, "tick on: the scan still needs polling")
space.onStep = function() space.busy = false end
onFrameTick(16)
assert(frameTick == false, "tick off on the Search tab after the last step")

-- Search here: inside the search root restricts the search, outside only notifies.
do
    local function eq(a, b, m) assert(a == b, m .. ": got " .. tostring(a)) end
    local notes = {}
    noctalia.notify = function(_, body) table.insert(notes, body) end
    local function hasFilter()
        local function walk(n)
            if n.props and n.props.text == "usage_filter" then return true end
            for _, c in ipairs(n.children or {}) do if walk(c) then return true end end
        end
        return walk(rendered)
    end
    find(rendered, "tab-space").props.onClick()
    onSearchHere("/elsewhere/x")
    assert(find(rendered, "tab-space").props.selected == true, "outside the root: stay on Space")
    eq(#notes, 1, "outside the root: one notice")
    assert(not hasFilter(), "outside the root: no restriction")
    onSearchHere("/homework")
    eq(#notes, 2, "sibling with the same prefix is outside")
    onSearchHere("/home/a b/c")
    assert(find(rendered, "tab-search").props.selected == true, "inside: Search tab")
    assert(hasFilter(), "inside: restriction strip")
    eq(#notes, 2, "inside: no notice")
    onSearchHere("/home")
    assert(not hasFilter(), "the root itself lifts the restriction")
end

print("file-search panel tab tests: ok")
