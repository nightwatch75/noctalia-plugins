-- Tab bar of panel.luau: Search/Space buttons, selection and body swap, with
-- the host stubbed. Run through tests/file-search/run.sh, which prepends the unmodified
-- panel source as PANEL_SRC.

local rendered, opened, frameTick
local config = {}
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
    getConfig = function(key) return config[key] end,
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
    extraRoots = function() return {} end,
    readFolders = function() return false end,
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
    busy = false, onStep = nil, opens = 0, closes = 0,
    render = function() return ui.label({ key = "space", text = "space" }) end,
}
-- needsTick/step driven by the test: onStep plays what one engine step does.
function space.onOpen(redraw) space.redraw = redraw; space.opens += 1 end
function space.onClose() space.closes += 1 end
function space.onDisabled() space.disabled = (space.disabled or 0) + 1 end
function space.onConfigChanged() space.configs = (space.configs or 0) + 1 end
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

-- Leaving Space closes its side (its events stop redrawing the Search tab);
-- entering opens it again.
do
    local opens, closes = space.opens, space.closes
    find(rendered, "tab-space").props.onClick()
    assert(space.opens == opens + 1 and space.closes == closes, "entering Space opens it")
    find(rendered, "tab-search").props.onClick()
    assert(space.closes == closes + 1, "leaving Space closes it")
end

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
    eq(notes[1], "space_search_outside", "outside notice text")
    -- other scopes / whole system: unavailable notice, no switch
    for _, mode in ipairs({ "external", "whole" }) do
        shared.scope, shared.whole = mode == "external" and "external" or "folder", mode == "whole"
        find(rendered, "tab-space").props.onClick()
        local before = #notes
        onSearchHere("/home/sub")
        assert(find(rendered, "tab-space").props.selected == true, mode .. ": stay on Space")
        eq(#notes, before + 1, mode .. ": one notice")
        eq(notes[#notes], "space_search_unavailable", mode .. ": notice text")
        assert(not hasFilter(), mode .. ": no restriction")
    end
    shared.scope, shared.whole = "folder", false
    -- a control character in the path: unavailable, no switch
    find(rendered, "tab-space").props.onClick()
    onSearchHere("/home/a\nb")
    assert(find(rendered, "tab-space").props.selected == true, "control char: stay on Space")
    eq(notes[#notes], "space_search_unavailable", "control char: notice text")
    assert(not hasFilter(), "control char: no restriction")
    -- a search root of "/" (records relative to it, no leading slash)
    shared.roots = { "/" }
    onSearchHere("/etc/x")
    assert(find(rendered, "tab-search").props.selected == true, "root /: inside")
    assert(hasFilter(), "root /: restriction strip")
    shared.roots = { "/home" }
end

-- A settings change reaches the Space side (it drops an index built with
-- other excludes).
onConfigChanged()
assert(space.configs == 1, "onConfigChanged forwarded to space")

-- ── space_enabled = false ───────────────────────────────────────────────────
do
    local argvs = {}
    local runAsync = noctalia.runAsync
    noctalia.runAsync = function(argv, callback)
        table.insert(argvs, type(argv) == "table" and table.concat(argv, " ") or tostring(argv))
        return runAsync(argv, callback)
    end
    local steps = 0
    space.onStep = function() steps += 1 end

    -- on Space, then the setting goes off: back to Search, closed once
    onClose()
    onOpen(nil)
    find(rendered, "tab-space").props.onClick()
    local closes, disabled = space.closes, space.disabled or 0
    config.space_enabled = false
    onConfigChanged()
    assert(space.closes == closes + 1, "space.onClose once")
    assert(space.disabled == disabled + 1, "space.onDisabled once")
    assert(find(rendered, "tab-search") == nil and find(rendered, "tab-space") == nil, "no tab bar")
    assert(find(rendered, "refresh") ~= nil, "Search body")
    assert(find(rendered, "space") == nil, "no Space body")

    -- fresh open: Search layout without the bar, same keys otherwise
    onClose()
    onOpen(nil)
    assert(find(rendered, "tabs") == nil)
    assert(find(rendered, "header") ~= nil and find(rendered, "refresh") ~= nil, "Search header kept")
    local opens = space.opens
    space.busy = true -- would keep the tick alive if the panel asked
    onFrameTick(16)
    assert(steps == 0, "frame tick never steps Space")
    assert(frameTick == false, "tick off for Space")
    onKey("down", true)
    onKey("down", false)
    onSearchHere("/home/x") -- guarded: no tab switch, no Space call
    assert(find(rendered, "tab-space") == nil and space.opens == opens, "Space never opened")
    for _, a in ipairs(argvs) do
        assert(not a:find("ncdu") and not a:find("jq") and not a:find("/bin/sh"), "Space spawned: " .. a)
    end
    space.busy = false
    onClose()
    assert(space.closes == closes + 1, "onClose does not call space.onClose while off")

    -- back on: the bar is back, starting on Search
    config.space_enabled = true
    onConfigChanged()
    onOpen(nil)
    assert(find(rendered, "tab-search").props.selected == true and find(rendered, "tab-space") ~= nil)
    config.space_enabled = nil
    noctalia.runAsync = runAsync
end

print("file-search panel tab tests: ok")
