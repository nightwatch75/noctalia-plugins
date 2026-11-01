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
    files, decoded, runs, tools, notes = {}, {}, {}, { lsblk = false }, {}
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

-- ── no root switch while a scan runs (a detached run cannot be stopped) ──────
do
    local space = ready()
    eq(find(space.render(), "space-root").props.enabled, true, "root button enabled when idle")
    space.refresh()
    eq(space.scanning, true, "refresh scans")
    eq(find(space.render(), "space-root").props.enabled, false, "root button disabled while scanning")
    space.toggleRoot()
    eq(space.root, "/", "toggleRoot refused while scanning")
    eq(#runs, 1, "no second scan")
    assert(space.index ~= nil, "index kept")
end

-- ── long lists: 200 rows, then one muted line ───────────────────────────────
do
    local recs = { { id = "0", n = "/", s = 0, f = 0 } }
    for i = 1, 250 do
        recs[#recs + 1] = { id = "0/" .. (i - 1), n = string.format("d%03d", i), s = i, leaf = true }
        recs[1].s += i
    end
    local space = boot()
    putIndex("/", jsonl("/", recs), 60)
    space.onOpen(function() end)
    drain(space)
    local realTr = noctalia.tr
    noctalia.tr = function(k, v) return k == "space_more_rows" and k .. ":" .. v.count or k end
    local tree = space.render()
    assert(find(tree, "space-row-200") and not find(tree, "space-row-201"), "200 rows")
    assert(findText(find(tree, "space-row-200"), "d051"), "cap after the sort (size, biggest first)")
    eq(find(tree, "space-more").props.text, "space_more_rows:50", "the rest counted")
    space.setSort("name")
    assert(findText(find(space.render(), "space-row-200"), "d200"), "cap after the sort (name)")
    noctalia.tr = realTr
    space = ready()
    eq(find(space.render(), "space-more"), nil, "short list: no extra line")
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

-- ── deferred rescan redraws with scanning on, so the label and tick follow ──
do
    local space = boot()
    putIndex("/", fixture("/"), 2 * 86400)
    local last
    space.onOpen(function() last = { tick = space.needsTick(), scanning = space.scanning } end)
    while space.loading do space.step() end
    eq(#runs, 1, "stale index: deferred rescan started")
    assert(last and last.scanning and last.tick, "last redraw sees the rescan running")
end

-- ── Types mode ───────────────────────────────────────────────────────────────
local function typesFixture(root)
    return jsonl(root, {
        { id = "0", n = root, s = 1000, f = 40, c = { 400, 200, 100, 80, 60, 50, 40, 70 },
          t = { { n = "big.mkv", s = 300, k = 1 }, { n = "usr/clip.mp4", s = 100, k = 1 },
                { n = "usr/pic.png", s = 200, k = 2 }, { n = "gone.mkv", s = 5, k = 1 },
                { n = WEIRD .. ".mp3", s = 100, k = 3 } } },
        { id = "0/0", n = "usr", s = 600, f = 0, c = { 100, 200, 0, 0, 0, 0, 0, 300 },
          t = { { n = "clip.mp4", s = 100, k = 1 }, { n = "pic.png", s = 200, k = 2 } } },
        { id = "0/1", n = "home", s = 300, f = 0, c = { 300, 0, 0, 0, 0, 0, 0, 0 },
          t = { { n = "a.mkv", s = 300, k = 1 } } },
    })
end
local function typesReady()
    local space = boot()
    putIndex("/", typesFixture("/"), 60)
    space.onOpen(function() redraws += 1 end)
    drain(space)
    find(space.render(), "space-mode").children[2].props.onClick()
    return space
end
local function rowNames(tree)
    local out = {}
    for i = 1, 50 do
        local row = find(tree, "space-row-" .. i)
        if not row then break end
        table.insert(out, (find(row, "name-btn") or find(row, "name-plain")).props.text)
    end
    return out
end
do
    local space = typesReady()
    local tree = space.render()
    for i = 1, 8 do
        local row = find(tree, "space-legend-" .. i)
        assert(row, "category legend row " .. i)
    end
    assert(rowOf(tree, "space-legend-", "cat_video"), "category names from translations")
    assert(not find(tree, "space-legend-9"), "8 rows")
    -- legend sizes add up to the folder total (1000 B in the fixture)
    local realTr = noctalia.tr
    noctalia.tr = function(k, v) if k == "usage_amount" then return v.size end return k end
    local sum = 0
    for i = 1, 8 do
        local n = tonumber(find(find(space.render(), "space-legend-" .. i), "size").props.text:match("^(%d+) B$"))
        assert(n, "legend size is plain bytes")
        sum += n
    end
    noctalia.tr = realTr
    eq(sum, 1000, "legend sizes sum to the folder total")
    -- no filter: same list as Folders mode, every row has a type bar
    local names = rowNames(tree)
    eq(table.concat(names, "|"), "usr|home|space_loose", "unfiltered list = folders list")
    for i = 1, 3 do assert(find(find(tree, "space-row-" .. i), "typebar"), "type bar on row " .. i) end
    -- filter: files of the category below the folder, biggest first
    click(rowOf(tree, "space-legend-", "cat_video"), "video legend")
    names = rowNames(space.render())
    eq(table.concat(names, "|"), "big.mkv|usr/clip.mp4|gone.mkv", "video files below the folder")
    click(rowOf(space.render(), "space-legend-", "cat_video"), "video again")
    eq(#rowNames(space.render()), 3, "second click clears the filter")
    -- entering a folder keeps the mode and clears the filter
    click(rowOf(space.render(), "space-legend-", "cat_video"), "video")
    space.enter("usr")
    tree = space.render()
    assert(find(tree, "space-legend-1") and rowOf(tree, "space-legend-", "cat_images"), "still types mode")
    eq(space.typeFilter, nil, "filter cleared on enter")
    space.setTypeFilter(2)
    eq(rowNames(space.render())[1], "pic.png", "setTypeFilter(2)")
    space.setTypeFilter(nil)
end

-- ── file reveal (Types rows) ─────────────────────────────────────────────────
do
    local space = typesReady()
    files["/big.mkv"] = { text = "x", mtime = 1 }
    space.setTypeFilter(1)
    local tree = space.render()
    click(rowOf(tree, "space-row-", "big.mkv"), "big.mkv row")
    eq(#notes, 0, "existing file: no notice")
    eq(runs[#runs].argv[1], "gdbus", "reveal through gdbus")
    assert(runs[#runs].argv[10]:find("file:///big.mkv", 1, true), "uri of the file")
    local before = #runs
    click(rowOf(tree, "space-row-", "gone.mkv"), "missing row")
    eq(#runs, before, "missing file: no reveal")
    eq(#notes, 1, "missing file: one notice")
    -- hostile name: file exists, argv stays one element, no crash
    space.setTypeFilter(3)
    tree = space.render()
    files["/" .. WEIRD .. ".mp3"] = { text = "x", mtime = 1 }
    click(rowOf(tree, "space-row-", (WEIRD .. ".mp3"):gsub("%c", " ")), "hostile row")
    eq(runs[#runs].argv[1], "gdbus", "hostile name revealed")
    local lit = runs[#runs].argv[10]
    assert(lit:find("%0A", 1, true), "newline percent-encoded")
    assert(not lit:sub(3, -3):find('[\n"<&]'), "no raw newline, quote or markup in the literal")
end

-- ── slice colours: never shared, legend == svg == list ───────────────────────
do
    local recs = { { id = "0", n = "/", s = 0, f = 0 } }
    local total = 0
    for i = 1, 13 do
        recs[#recs + 1] = { id = "0/" .. (i - 1), n = "d" .. i, s = 100 + i, leaf = true }
        total += 100 + i
    end
    recs[1].s = total
    local space = boot()
    putIndex("/", jsonl("/", recs), 60)
    space.onOpen(function() redraws += 1 end)
    drain(space)
    local tree = space.render()
    local svg, seen, shown = svgText(), {}, 0
    for i = 1, 8 do
        local row = find(tree, "space-legend-" .. i)
        local name = findText(row, "d" .. (14 - i)) and "d" .. (14 - i)
        local fill = find(row, "swatch").props.fill
        if name then
            shown += 1
            eq(seen[fill], nil, "legend colours differ")
            seen[fill] = true
            assert(svg:find('stroke="' .. fill .. '"', 1, true), "svg uses the legend colour " .. fill)
            eq(find(rowOf(tree, "space-row-", name), "swatch").props.fill, fill, "list swatch == legend " .. name)
        end
    end
    eq(shown, 7, "7 folder slices")
    local grey = find(rowOf(tree, "space-row-", "d1"), "swatch").props.fill
    eq(seen[grey], nil, "folder outside the slices: neutral swatch")
end

print("space_ui_test OK")

-- ── toggleRoot clears the type filter ────────────────────────────────────────
do
    local space = typesReady()
    space.setTypeFilter(1)
    space.toggleRoot()
    eq(space.typeFilter, nil, "toggleRoot clears typeFilter")
end

-- ── search here: the button hands the current absolute path to the panel ────
do
    local space = ready()
    local got = {}
    space.onSearchHere = function(p) table.insert(got, p) end
    find(space.render(), "space-search-here").props.onClick()
    eq(got[1], "/", "root path")
    space.enter("usr")
    find(space.render(), "space-search-here").props.onClick()
    eq(got[2], "/usr", "current folder path")
end
