-- Header row and Sessions toolbar of panel.luau, with the host stubbed. Run
-- through tests/claude-cockpit/run.sh, which prepends the unmodified panel
-- source as PANEL_SRC.

local rendered

local function node(kind)
    return function(props, children)
        return { kind = kind, props = props, children = children }
    end
end
ui = setmetatable({}, { __index = function(_, kind) return node(kind) end })
panel = {
    render = function(tree) rendered = tree end,
    setWantsSecondTicks = function() end,
    close = function() end,
}
noctalia = {
    readFile = function() return 'version = "9.9.9"' end,
    tr = function(key) return key end,
    openSettings = function() end,
    notify = function() end,
    notifyError = function() end,
    expandPath = function(p) return p end,
    fileExists = function() return true end,
    state = { set = function() end, get = function() return nil end, watch = function() end },
}
local function session(id, mtime)
    return { id = id, label = id, mtime = mtime, empty = false, prompt = "" }
end
local projects = {
    { cwd = "/p/few", lastActivity = 100, sessions = { session("a", 100) } },
    { cwd = "/p/many", lastActivity = 50, sessions = { session("b", 50), session("c", 40), session("d", 30) } },
}
local shared = { trim = function(v) return v:match("^%s*(.-)%s*$") end }
require = function(path)
    if path == "./sessions.luau" then
        return { refresh = function(cb) cb(projects, nil) end }
    end
    if path == "./shared.luau" then return shared end
    return { GROUPS = {} }
end
assert(loadstring(PANEL_SRC, "=panel.luau"))()

local function find(n, key)
    if n.props and n.props.key == key then return n end
    for _, child in ipairs(n.children or {}) do
        local hit = find(child, key)
        if hit then return hit end
    end
end

onOpen(nil)

-- (a) version right after the title; only the spacer grows.
local header = rendered.children[1]
local title
for i, child in ipairs(header.children) do
    if child.props.text == "title" then title = i end
end
assert(title, "title label")
assert(header.children[title].props.flexGrow == nil, "title must not grow")
assert(header.children[title + 1].props.text == "9.9.9", "version follows the title")
local spacer = header.children[title + 2]
assert(spacer.props.key == "hdr-spacer" and spacer.props.flexGrow == 1, "spacer grows")
assert(header.children[title + 3].kind == "button", "refresh button follows the spacer")

-- (b) Count sort: button exists, largest group first.
find(rendered, "tab-sessions").props.onClick()
assert(find(rendered, "sort-count"), "sort-count button")
find(rendered, "sort-count").props.onClick()
local scroll = find(rendered, "sessions-scroll")
local order = {}
for _, row in ipairs(scroll.children) do
    local key = row.props and row.props.key
    if key and key:match("^grp%-") then table.insert(order, key) end
end
assert(order[1] == "grp-/p/many" and order[2] == "grp-/p/few", "count sort puts 3-session group first: " .. table.concat(order, ","))
print("panel_header_test ok")
