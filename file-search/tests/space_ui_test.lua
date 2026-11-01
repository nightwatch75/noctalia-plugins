-- module: space.luau shared.luau usage.luau space_index.luau
-- Space tab UI of space.luau (Folders mode), with the host stubbed: ui.* build
-- plain tables, files live in memory, json.decode maps known line texts to
-- tables (see space_scan_test.lua). Run through tests/run.sh.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end

local files, decoded, runs, tools, ms, redraws, notes
local DIR = "/data"
local HOME = "/home/u"

ui = setmetatable({}, { __index = function(_, kind)
    return function(props, children) return { kind = kind, props = props or {}, children = children } end
end })

local function boot()
    files, decoded, runs, tools, notes = {}, {}, {}, {}, {}
    ms, redraws = 1e9, 0
    noctalia = {
        readFile = function(p) local f = files[p]; return f and f.text end,
        writeFile = function(p, t) files[p] = { text = t, mtime = ms // 1000 }; return true end,
        removeFile = function(p) files[p] = nil; return true end,
        fileInfo = function(p) local f = files[p]; return f and { size = #f.text, mtime = f.mtime, isDir = false } end,
        fileExists = function(p)
            local name = p:match("^/usr/bin/([^/]+)$")
            if name then return tools[name] ~= false end
            return files[p] ~= nil
        end,
        listDir = function() return {} end,
        commandExists = function(n) return tools[n] ~= false end,
        getConfig = function() return nil end,
        expandPath = function(p) return (p:gsub("^~", HOME)) end,
        nowMs = function() return ms end,
        pluginDataDir = function() return DIR end,
        isDarkMode = function() return true end,
        tr = function(key) return key end,
        log = function() end,
        notify = function(title, body) table.insert(notes, body or title) end,
        json = { decode = function(t)
            local v = decoded[t]
            if v == nil then return nil, "bad json" end
            return v
        end },
        runAsync = function(argv, cb, timeout)
            table.insert(runs, { argv = argv, cb = cb, timeout = timeout })
            return true
        end,
    }
    local cache = {}
    require = function(path)
        local name = path:gsub("^%./", "")
        if cache[name] == nil then
            cache[name] = assert(loadstring(MODULES[name], "=" .. name))()
        end
        return cache[name]
    end
    return require("./space.luau")
end

local serial = 0
local function jsonl(root, records)
    serial += 1
    local head = "H" .. serial
    decoded[head] = { v = 1, root = root }
    local lines = { head }
    for _, r in ipairs(records) do
        serial += 1
        local key = "R" .. serial
        r.f, r.c, r.t = r.f or 0, r.c or { 0, 0, 0, 0, 0, 0, 0, 0 }, r.t or {}
        decoded[key] = r
        table.insert(lines, key)
    end
    return table.concat(lines, "\n") .. "\n"
end

local WEIRD = 'we<i&rd"\nname'
local function fixture(root)
    return jsonl(root, {
        { id = "0", n = root, s = 100, f = 5 },
        { id = "0/0", n = "usr", s = 60 },
        { id = "0/0/0", n = "lib", s = 50, leaf = true },
        { id = "0/1", n = WEIRD, s = 20 },
        { id = "0/2", n = "home", s = 15 },
    })
end
local function putIndex(root, text, age)
    local tag = root == "/" and "root" or "home"
    files[DIR .. "/space-" .. tag .. ".json"] = { text = text, mtime = ms // 1000 - (age or 0) }
end

local function drain(space)
    for _ = 1, 10000 do
        if not space.step() then return end
        ms += 1000
    end
    error("step() never settles")
end

local function find(node, key)
    if type(node) ~= "table" then return nil end
    if node.props and node.props.key == key then return node end
    for _, child in ipairs(node.children or {}) do
        local hit = find(child, key)
        if hit then return hit end
    end
end
local function findText(node, text)
    if type(node) ~= "table" then return nil end
    if node.props and node.props.text == text then return node end
    for _, child in ipairs(node.children or {}) do
        local hit = findText(child, text)
        if hit then return hit end
    end
end
local function clickable(node)
    if type(node) ~= "table" then return nil end
    if node.props and node.props.onClick then return node end
    for _, child in ipairs(node.children or {}) do
        local hit = clickable(child)
        if hit then return hit end
    end
end
local function click(node, m)
    local hit = clickable(node)
    assert(hit, m .. ": nothing clickable")
    hit.props.onClick()
end
-- The row (list or legend) whose label shows `text`.
local function rowOf(tree, prefix, text)
    for i = 1, 50 do
        local row = find(tree, prefix .. i)
        if row and findText(row, text) then return row end
    end
end
local function svgText()
    local a, b = files[DIR .. "/space-a.svg"], files[DIR .. "/space-b.svg"]
    assert((a == nil) ~= (b == nil), "exactly one of the two svg names on disk")
    return (a or b).text
end

local function ready()
    local space = boot()
    putIndex("/", fixture("/"), 60)
    space.onOpen(function() redraws += 1 end)
    drain(space)
    eq(space.state, "ready", "fixture loads")
    eq(#runs, 0, "fresh index: no scan")
    return space
end

-- ── layout keys in ready state ───────────────────────────────────────────────
do
    local space = ready()
    assert(redraws > 0, "load end redraws")
    local tree = space.render()
    for _, key in ipairs({ "space-up", "space-root", "space-mode", "space-path", "space-img", "space-refresh",
        "space-sort-size", "space-sort-name" }) do
        assert(find(tree, key), "key " .. key)
    end
    eq(find(tree, "space-path").props.text, "/", "path at root")
    eq(find(tree, "space-up").props.enabled, false, "up disabled at the root")
    -- slices: usr, weird, home, loose = 4 rows, all fit under MAX_SLICES
    for i = 1, 4 do assert(find(tree, "space-legend-" .. i), "legend row " .. i) end
    assert(not find(tree, "space-legend-5"), "one legend row per slice")
    for i = 1, 4 do assert(find(tree, "space-row-" .. i), "list row " .. i) end
    assert(find(tree, "space-img").props.path:match("/space%-[ab]%.svg$"), "image path")
    svgText()
end

-- ── legend click enters, up pops ─────────────────────────────────────────────
do
    local space = ready()
    local tree = space.render()
    local usr = rowOf(tree, "space-legend-", "usr")
    assert(usr, "usr legend row")
    click(usr, "usr legend")
    tree = space.render()
    eq(find(tree, "space-path").props.text, "/usr", "path entered")
    eq(find(tree, "space-up").props.enabled, true, "up enabled below the root")
    -- leaf directory: no click anywhere in its row or legend row
    local lib = rowOf(tree, "space-row-", "lib")
    assert(lib, "lib row")
    eq(clickable(lib), nil, "leaf list row has no onClick")
    eq(clickable(rowOf(tree, "space-legend-", "lib")), nil, "leaf legend row has no onClick")
    find(tree, "space-up").props.onClick()
    eq(find(space.render(), "space-path").props.text, "/", "up pops")
    -- a list row click also enters
    click(rowOf(space.render(), "space-row-", "home"), "home row")
    eq(find(space.render(), "space-path").props.text, "/home", "row enters")
end

-- ── sort header ──────────────────────────────────────────────────────────────
do
    local space = ready()
    local function first() return find(space.render(), "space-row-1") end
    assert(findText(first(), "usr"), "biggest first by default")
    find(space.render(), "space-sort-size").props.onClick()
    assert(findText(first(), "space_loose"), "second press on size flips to ascending")
    find(space.render(), "space-sort-name").props.onClick()
    assert(findText(first(), "space_loose"), "name ascending: the loose row (empty name) first")
    find(space.render(), "space-sort-name").props.onClick()
    assert(findText(first(), (WEIRD:gsub("%c", " "))), "second press on name flips to descending")
end

-- ── untrusted names: escaped in the SVG, one line in the list ────────────────
do
    local space = ready()
    local row = rowOf(space.render(), "space-row-", 'we<i&rd" name')
    assert(row, "control characters shown as spaces in the list")
    click(row, "weird row")
    space.render() -- the chart is written by render
    local svg = svgText()
    assert(svg:find("we&lt;i&amp;rd&quot;", 1, true), "name escaped in the svg")
    assert(not svg:find("<i", 1, true) and not svg:find("\n", 1, true), "no raw markup or newline in the svg")
end

-- ── scanning, error, refresh ─────────────────────────────────────────────────
do
    local space = boot()
    space.onOpen(function() redraws += 1 end) -- no index file: the scan starts by itself
    eq(space.state, "scanning", "no index: scanning")
    assert(findText(space.render(), "space_scanning"), "scanning label")

    space = boot()
    tools.ncdu = false
    space.onOpen(function() redraws += 1 end)
    drain(space)
    eq(space.state, "error", "missing ncdu")
    assert(findText(space.render(), "space_err.ncdu"), "error text per code")

    space = ready()
    find(space.render(), "space-refresh").props.onClick()
    eq(#runs, 1, "refresh ignores the cache")
    eq(runs[1].argv[2], "--version", "refresh starts a scan")
end

-- ── late callbacks after close are ignored ───────────────────────────────────
do
    local space = boot()
    space.onOpen(function() redraws += 1 end)
    local before = redraws
    space.onClose()
    runs[1].cb({ exitCode = 0, stdout = "ncdu 1.19\n", stderr = "", timedOut = false })
    eq(space.state, "error", "the probe answer still lands")
    eq(redraws, before, "no redraw after close")
end

-- ── root switch keeps a fresh cached index, rescans a stale one ──────────────
do
    local space = ready()
    putIndex(HOME, fixture(HOME), 60)
    find(space.render(), "space-root").props.onClick()
    eq(space.root, HOME, "switched to home")
    drain(space)
    eq(#runs, 0, "fresh home index: no scan")
    eq(space.state, "ready", "home index shown")
    eq(find(space.render(), "space-path").props.text, HOME, "path line shows home")

    space = ready()
    putIndex(HOME, fixture(HOME), 2 * 86400)
    space.toggleRoot()
    eq(#runs, 0, "no scan before the load ends")
    while space.loading do space.step() end -- the deferred scan starts in the step that ends the load
    eq(#runs, 1, "stale home index: rescan")
    assert(space.index ~= nil and space.scanning, "stale index shown while the rescan runs")

    -- the same through scan() itself (the Task 4 open Minor)
    space = ready()
    putIndex(HOME, fixture(HOME), 60)
    space.scan(HOME, false, function() end)
    drain(space)
    eq(#runs, 0, "scan() of another root waits for its load before the fresh check")
end

print("space_ui_test OK")
