--!nonstrict
-- file-search — the Space tab of the panel: a disk-usage browser.
--
-- Role: a module required by panel.luau (never an entry of its own). The panel
-- calls onOpen(redraw) when the Space tab is shown, onClose() with the panel,
-- and embeds whatever render() returns under the tab bar. This file owns the
-- scan engine, its state and the tab UI (path line, donut, legend, sorted
-- list). The panel calls space.step() on its frame tick while
-- space.needsTick() is true: scans and index loads only advance there. Any
-- visible change calls redraw, never while the panel is closed.
--
-- UI state (file-locals): path (node stack from space.index down to the
-- current folder; re-walked by name when a new index lands), sortKey
-- ("size" | "name"), sortDesc, mode ("folders" | "types"), typeFilter (a
-- category number in Types mode, nil = none; cleared by entering a folder, going
-- up or switching mode).
--
-- State (module fields, read by the panel):
--   space.state     "idle" | "scanning" | "ready" | "error". A stale index
--                   stays "ready" while its rescan runs (see space.scanning).
--   space.scanning  a scan of space.root is in flight (probe, run or load)
--   space.loading   an index is being decoded, a slice per step()
--   space.errText   last failure, one of:
--                     "ncdu"      ncdu not found, or its --version unreadable
--                     "ncdu_old"  ncdu older than 2.0
--                     "jq"        jq not found
--                     "datadir"   no plugin data directory
--                     "spawn"     the host refused to start a process
--                     "timeout"   version probe timed out, or no result
--                                 within SCAN_DEADLINE_MS
--                     "empty"     ncdu wrote no scan file
--                     "reduce"    jq or the final mv failed
--                     "index"     the new index file does not decode
--   space.root      "/" or the home path
--   space.index     decoded index tree (see space_index.luau), nil = none
--   space.scannedAt unix seconds of the index file (its mtime)
--
-- Pipeline:
--   1. `ncdu --version` with a callback, once per load (ncdu >= 2.0). Only a
--      parsed version is remembered; a timeout is retried on the next scan.
--   2. One DETACHED `/bin/sh -c SCAN_SCRIPT` (runAsync without callback): the
--      host kills a captured run after 60 s and keeps only 1 MiB of its
--      stdout, and ncdu + jq take ~45 s on "/" here, so neither limit can
--      apply. The script runs ncdu (never -x: on "/" it skips /home and
--      /var/log when they are separate mounts), then jq into a temp file and
--      `mv -f` onto the index (atomic), removes the 100+ MB scan file and
--      writes a one-word marker file. ncdu exits 1 after unreadable folders;
--      a non-empty scan file decides, not the status. The script text is a
--      constant; every path, exclude and the jq program are positional
--      parameters. A detached run has no login PATH, so binaries are absolute
--      (TOOL_DIRS).
--   3. step() polls the marker about once a second, then loads the index.
--   jq writes the index file itself; there is no Lua-side save.
--
-- The index is JSON Lines (see idx.jqProgram) and decoded a few lines per
-- step(), within SLICE_MS, because a host callback has a 25 ms CPU budget and
-- the whole file is ~2.5 MB. space.index keeps the previous tree until the
-- new one is complete.
--
-- A scan is a job table; setRoot() or a newer scan replaces it, and anything
-- belonging to an older job (probe answer, marker) is ignored. Each run has
-- its own scan/temp/marker names; leftovers of dropped or orphaned runs are
-- swept when the next run starts.

local shared = require("./shared.luau")
local usage = require("./usage.luau")
local idx = require("./space_index.luau")

local space = {}

space.VERSION_TIMEOUT_MS = 5000
space.POLL_MS = 1000
space.SLICE_MS = 8
-- No host timeout applies to a detached run; ~45 s on "/" here.
space.SCAN_DEADLINE_MS = 1800000

-- Values recorded with their measurements in the header of space_index.luau.
local DEPTH, TOP_N, MIN_BYTES = 6, 5, 1048576

local TOOL_DIRS = { "/usr/bin", "/usr/local/bin", "/bin", "~/.local/bin" }

-- $1 ncdu  $2 jq  $3 jq program  $4 scan file  $5 temp  $6 index  $7 marker
-- $8 nice ("" = none), then the ncdu arguments.
local SCAN_SCRIPT = table.concat({
    'n=$1 j=$2 p=$3 s=$4 t=$5 i=$6 d=$7 c=$8',
    'shift 8',
    'run() { if [ -n "$c" ]; then "$c" -n 19 "$@"; else "$@"; fi; }',
    'run "$n" -0 -o "$s" "$@" >/dev/null 2>&1',
    'if [ ! -s "$s" ]; then r=empty',
    'elif run "$j" -c "$p" "$s" > "$t" 2>/dev/null && mv -f "$t" "$i"; then r=ok',
    'else r=reduce; fi',
    'rm -f "$s" "$t"',
    'echo "$r" > "$d"',
}, "\n")

space.state = "idle"
space.scanning = false
space.loading = false
space.errText = nil
space.root = "/"
space.index = nil
space.scannedAt = 0

local scanCount = 0
local ncduOld = nil -- nil = not probed yet
local job = nil     -- { dir, done, marker?, deadline, nextPoll, loading? }
local loader = nil  -- { text, pos, nodes, tree, at }
local deferred = nil -- done() of a scan waiting for the current load to end
local generation = 0 -- bumped per loaded index, keys the chart cache

-- Panel side (see the panel hooks below).
local isOpen = false
local redraw = nil

local function changed()
    if isOpen and redraw ~= nil then
        redraw()
    end
end

-- ── files and tools ──────────────────────────────────────────────────────────

local function rootTag(root)
    return root == "/" and "root" or "home"
end

local function indexPath(dir, root)
    return dir .. "/space-" .. rootTag(root) .. ".json"
end

-- Unlinking a file an older run still writes is harmless: it keeps its inode,
-- and that run's result is ignored anyway.
local function sweep(dir)
    for _, name in ipairs(noctalia.listDir(dir) or {}) do
        if name:match("^space%-.+%.scan$") or name:match("^space%-.+%.tmp$") or name:match("^space%-.+%.done$") then
            noctalia.removeFile(dir .. "/" .. name)
        end
    end
end

local function findTool(name)
    for _, dir in ipairs(TOOL_DIRS) do
        local path = noctalia.expandPath(dir) .. "/" .. name
        if noctalia.fileExists(path) then
            return path
        end
    end
    return nil
end

-- ── settings ─────────────────────────────────────────────────────────────────

function space.excludeArgs()
    local args = { "--exclude-kernfs" }
    -- Declared in plugin.toml by a later step; until then nil reads as true.
    if noctalia.getConfig("space_exclude_external") ~= false then
        for _, path in ipairs(shared.wholePrunePaths()) do
            table.insert(args, "--exclude")
            table.insert(args, path)
        end
    end
    for _, pattern in ipairs(usage.excludes()) do
        table.insert(args, "--exclude")
        table.insert(args, pattern)
    end
    return args
end

function space.checkTools()
    if findTool("ncdu") == nil then
        return "ncdu"
    end
    if ncduOld then
        return "ncdu_old"
    end
    if findTool("jq") == nil then
        return "jq"
    end
    return nil
end

-- ── scan end ─────────────────────────────────────────────────────────────────

-- State is settled before done() runs, so a throwing caller leaves nothing
-- stuck. A failure keeps an index already on screen ("ready" + errText).
local function endScan(errText)
    local done = job and job.done
    job = nil
    space.scanning = false
    if errText ~= nil then
        space.errText = errText
        if space.index == nil then
            space.state = "error"
        end
    end
    if done then
        done()
    end
    changed()
end

-- ── index load ───────────────────────────────────────────────────────────────

-- Reads the index of space.root and checks its header; the records are
-- decoded by step(). False (nothing loading) for a missing, corrupted or
-- other-version file: it is a cache, the caller rescans. The header's root is
-- not compared: ncdu writes the resolved path (a symlinked home differs), and
-- the file name is already per root.
function space.startLoad(dir)
    loader = nil
    space.loading = false
    if dir == nil then
        return false
    end
    local path = indexPath(dir, space.root)
    local text = noctalia.readFile(path)
    local nl = type(text) == "string" and text:find("\n", 1, true)
    if not nl then
        return false
    end
    local ok, head = pcall(noctalia.json.decode, text:sub(1, nl - 1))
    if not ok or type(head) ~= "table" or head.v ~= 1 then
        return false
    end
    local info = noctalia.fileInfo(path)
    loader = { text = text, pos = nl + 1, nodes = {}, tree = nil, at = info and info.mtime or 0 }
    space.loading = true
    return true
end

-- One record into the tree being built; false = the index is unusable.
local function addRecord(l, line)
    local ok, r = pcall(noctalia.json.decode, line)
    if not ok or type(r) ~= "table" or type(r.id) ~= "string" or l.nodes[r.id] ~= nil
        or type(r.n) ~= "string" or type(r.s) ~= "number" or type(r.c) ~= "table" or type(r.t) ~= "table" then
        return false
    end
    local node = { n = r.n, s = r.s, f = r.f or 0, c = r.c, t = r.t, d = {}, leaf = r.leaf }
    local parentId = r.id:match("^(.+)/%d+$")
    if parentId ~= nil then
        local parent = l.nodes[parentId]
        if parent == nil then
            return false
        end
        table.insert(parent.d, node)
    elseif r.id == "0" then
        l.tree = node
    else
        return false
    end
    l.nodes[r.id] = node
    return true
end

local function endLoad(tree, at)
    loader = nil
    space.loading = false
    local scanLoad = job ~= nil and job.loading
    if tree == nil then
        if scanLoad then
            endScan("index")
        end
        return
    end
    space.index = tree
    generation += 1
    space.scannedAt = at
    space.state = "ready"
    space.errText = nil
    if scanLoad then
        endScan(nil)
    else
        changed()
    end
end

-- At least one line per call, then lines until SLICE_MS is spent. Lines are
-- cut with find from a moving cursor: one gmatch pass over 2.5 MB would be a
-- slice of its own.
local function sliceLoad(started)
    local l = loader
    repeat
        local text = l.text
        local nl = text:find("\n", l.pos, true)
        local stop = nl and nl - 1 or #text
        local line = text:sub(l.pos, stop)
        l.pos = stop + 2
        if line ~= "" and not addRecord(l, line) then
            endLoad(nil)
            return
        end
        if l.pos > #text then
            endLoad(l.tree, l.at)
            return
        end
    until noctalia.nowMs() - started >= space.SLICE_MS
end

-- ── scan ─────────────────────────────────────────────────────────────────────

function space.fresh()
    return space.state == "ready" and space.index ~= nil
        and (shared.now() - space.scannedAt) < usage.TTL_SECONDS
end

-- Drops the current index, any scan or load in progress, and starts loading
-- the new root's index.
function space.setRoot(root)
    if root == space.root then
        return
    end
    job = nil
    loader = nil
    deferred = nil
    space.root = root
    space.index = nil
    space.scannedAt = 0
    space.scanning = false
    space.loading = false
    space.state = "idle"
    space.errText = nil
    space.startLoad(shared.dataDir())
end

local function launch(current)
    -- Again after the async probe: a nil in argv would shift every $N.
    local missing = space.checkTools()
    if missing ~= nil then
        endScan(missing)
        return
    end
    local root = space.root
    local dir = current.dir
    scanCount += 1
    -- The clock keeps names unique across reloads, where the counter restarts.
    local stem = string.format("%s/space-%s-%d-%d", dir, rootTag(root), noctalia.nowMs(), scanCount)
    sweep(dir)
    local argv = {
        "/bin/sh", "-c", SCAN_SCRIPT, "sh",
        findTool("ncdu"), findTool("jq"), idx.jqProgram(DEPTH, TOP_N, MIN_BYTES),
        stem .. ".scan", stem .. ".tmp", indexPath(dir, root), stem .. ".done",
        findTool("nice") or "",
    }
    for _, arg in ipairs(space.excludeArgs()) do
        table.insert(argv, arg)
    end
    table.insert(argv, "--")
    table.insert(argv, root)
    if not noctalia.runAsync(argv) then
        endScan("spawn")
        return
    end
    local now = noctalia.nowMs()
    current.marker = stem .. ".done"
    current.deadline = now + space.SCAN_DEADLINE_MS
    current.nextPoll = now + space.POLL_MS
end

local function poll(now)
    if now < job.nextPoll then
        return
    end
    job.nextPoll = now + space.POLL_MS
    local text = noctalia.readFile(job.marker)
    local code = type(text) == "string" and text:match("^(%a+)") or nil
    if code == nil then
        -- An empty marker is the script mid-write: wait for the next poll.
        if now > job.deadline then
            endScan("timeout")
        end
        return
    end
    noctalia.removeFile(job.marker)
    job.marker = nil
    if code ~= "ok" then
        endScan(code == "empty" and "empty" or "reduce")
        return
    end
    job.loading = true
    if not space.startLoad(job.dir) then
        endScan("index")
    end
end

-- Scan `root` (switching to it first), then call done() unless the scan was
-- dropped by setRoot. `force` skips the TTL; a scan of the current root
-- already in flight is never doubled. While an index loads (setRoot starts
-- one) the TTL check waits for it, so a fresh cached index is not rescanned.
function space.scan(root, force, done)
    space.setRoot(root)
    if space.scanning then
        return
    end
    if space.loading and not force then
        deferred = done
        return
    end
    if not force and space.fresh() then
        done()
        return
    end
    job = { done = done }
    space.scanning = true
    if space.index == nil then
        space.state = "scanning"
    end
    local missing = space.checkTools()
    if missing ~= nil then
        endScan(missing)
        return
    end
    job.dir = shared.dataDir()
    if job.dir == nil then
        endScan("datadir")
        return
    end
    if ncduOld ~= nil then
        launch(job)
        return
    end
    local current = job
    local started = noctalia.runAsync({ findTool("ncdu"), "--version" }, function(result)
        local major = tonumber((result.stdout or ""):match("ncdu (%d+)%."))
        if major ~= nil then
            ncduOld = major < 2
        end
        if job ~= current then
            return
        end
        if result.timedOut then
            endScan("timeout")
        elseif major == nil then
            endScan("ncdu")
        elseif ncduOld then
            endScan("ncdu_old")
        else
            launch(current)
        end
    end, space.VERSION_TIMEOUT_MS)
    if not started then
        endScan("spawn")
    end
end

-- Advances a running scan (marker poll) and an index load (one slice).
-- True while anything is left to wait for.
function space.step()
    local now = noctalia.nowMs()
    if job ~= nil and job.marker ~= nil then
        poll(now)
    end
    if loader ~= nil then
        sliceLoad(now)
    end
    if deferred ~= nil and not space.loading and job == nil then
        local done = deferred
        deferred = nil
        space.scan(space.root, false, done)
        changed() -- the "scanning again" label
    end
    return space.needsTick()
end

function space.needsTick()
    return space.scanning or space.loading
end


-- ── navigation ───────────────────────────────────────────────────────────────

local LEFT_WIDTH = 340
local DONUT_SIZE = 200
local DONUT_THICKNESS = 28
local LABEL_MAX = 34
local ROW_HEIGHT = 22
local SVG_NAMES = { "space-a.svg", "space-b.svg" }
local GREY = { dark = { other = "#5b6180", loose = "#3d4256" }, light = { other = "#9aa2b8", loose = "#c3c8d6" } }

local path = {}       -- nodes from space.index down to the current folder
local sortKey = "size"
local sortDesc = true
local mode = "folders"
local typeFilter = nil -- category number, Types mode only
local svg = { slot = 0, path = nil, key = nil } -- written image and what it shows

-- The current folder. A new index (rescan, root switch) is walked again by
-- name, so the view stays where it was as far as the folders still exist.
local function current()
    local tree = space.index
    if tree == nil then
        path = {}
        return nil
    end
    if path[1] ~= tree then
        local fresh = { tree }
        for i = 2, #path do
            local child = idx.child(fresh[#fresh], path[i].n)
            if child == nil then
                break
            end
            table.insert(fresh, child)
        end
        path = fresh
    end
    return path[#path]
end

-- Absolute path of the current folder (+ `rel`). Built from space.root, not
-- the index's root name: ncdu writes a symlinked home resolved.
local function absolute(rel)
    local parts = { space.root == "/" and "" or space.root }
    for i = 2, #path do
        table.insert(parts, path[i].n)
    end
    if rel ~= nil then
        table.insert(parts, rel)
    end
    local out = table.concat(parts, "/")
    return out == "" and "/" or out
end

-- Names come from the disk: control characters (a newline would break the
-- row) become spaces, and long ones are cut, unless the UTF-8 is invalid.
local function display(name, max)
    local text = name:gsub("%c", " ")
    local len = utf8.len(text)
    if len ~= nil and len > max then
        text = text:sub(1, utf8.offset(text, max)) .. "…"
    end
    return text
end

function space.up()
    if #path > 1 then
        table.remove(path)
        typeFilter, space.typeFilter = nil, nil
        changed()
    end
end

function space.enter(name)
    local node = current()
    local child = node and idx.child(node, name)
    if child ~= nil and not child.leaf then
        table.insert(path, child)
        typeFilter, space.typeFilter = nil, nil
        changed()
    end
end

function space.setSort(key)
    if key == sortKey then
        sortDesc = not sortDesc
    else
        sortKey = key
        sortDesc = key == "size"
    end
    changed()
end

function space.setMode(value)
    mode = value
    typeFilter, space.typeFilter = nil, nil
    changed()
end

function space.setTypeFilter(category)
    typeFilter = category
    space.typeFilter = category -- read-only mirror for tests
    changed()
end

local function noop() end

function space.toggleRoot()
    path = {}
    space.scan(space.root == "/" and noctalia.expandPath("~") or "/", false, noop)
    changed()
end

function space.refresh()
    space.scan(space.root, true, noop)
    changed()
end

-- A top file of the current folder (Types mode). The index may be a day
-- old, so a missing file is a notice, not an error.
local function revealFile(rel)
    local full = absolute(rel)
    if not noctalia.fileExists(full) then
        noctalia.notify(shared.tr("title"), shared.tr("space_gone", { path = full }))
        return
    end
    shared.revealPath(full)
end

-- ── donut ────────────────────────────────────────────────────────────────────

local function paint(slices)
    local dark = noctalia.isDarkMode()
    local palette = dark and idx.COLORS_DARK or idx.COLORS_LIGHT
    local grey = dark and GREY.dark or GREY.light
    for _, slice in ipairs(slices) do
        slice.color = slice.index and palette[(slice.index - 1) % #palette + 1] or grey[slice.kind] or grey.other
    end
    return slices
end

-- Rewritten only when what it shows changes; two alternating names, since the
-- host caches an image by path (same pattern as usage.writeSvg).
local function writeSvg(node, slices)
    local dir = shared.dataDir()
    if dir == nil then
        return nil
    end
    local key = generation .. "/" .. #path .. "/" .. tostring(node) .. mode .. tostring(noctalia.isDarkMode())
    if key == svg.key and svg.path ~= nil then
        return svg.path
    end
    local name = #path > 1 and node.n or space.root
    local text = usage.svg(slices, node.s, DONUT_SIZE, DONUT_THICKNESS,
        shared.formatBytes(node.s), display(name, 14))
    svg.slot = svg.slot % #SVG_NAMES + 1
    local previous = svg.path or (dir .. "/" .. SVG_NAMES[svg.slot % #SVG_NAMES + 1])
    local file = dir .. "/" .. SVG_NAMES[svg.slot]
    local ok, err = noctalia.writeFile(file, text)
    if not ok then
        noctalia.log("file-search: could not write the space chart: " .. tostring(err))
        return svg.path
    end
    if previous ~= file then
        noctalia.removeFile(previous)
    end
    svg.path, svg.key = file, key
    return file
end

-- ── panel hooks ──────────────────────────────────────────────────────────────

-- `onChange` re-renders the panel. Loads the current root's index first; the
-- scan's TTL check waits for that load (see space.scan), then rescans a
-- missing or stale index by itself. Safe to call again on every tab switch.
function space.onOpen(onChange)
    isOpen = true
    redraw = onChange
    if space.index == nil and not space.loading and not space.scanning then
        space.startLoad(shared.dataDir())
    end
    space.scan(space.root, false, noop)
end

-- Scans and loads keep going; their late results only stop redrawing.
function space.onClose()
    isOpen = false
end

local function label(key, text, color)
    return ui.label({ key = key, text = text, fontSize = 12, color = color or "on_surface_variant" })
end

local function entryLabel(entry)
    if entry.kind == "loose" then
        return shared.tr("space_loose")
    end
    return display(entry.name, LABEL_MAX)
end

-- The category with most bytes in a folder; nil for an empty one.
local function categoryOfNode(node)
    local best, cat = 0, nil
    for k, b in ipairs(node and node.c or {}) do
        if b > best then best, cat = b, k end
    end
    return cat
end

-- One list row: swatch, name (a button only when a click does something),
-- size and share of the current folder.
local function listRow(entry, i, node, colors, palette)
    local onClick = nil
    if entry.kind == "dir" and not entry.node.leaf then
        onClick = function() space.enter(entry.name) end
    elseif entry.kind == "file" then
        onClick = function() revealFile(entry.name) end
    end
    local text = entryLabel(entry)
    local name = onClick
        and ui.button({ key = "name-btn", text = text, fontSize = 12, variant = "ghost", contentAlign = "start",
            flexGrow = 1, height = ROW_HEIGHT, onClick = onClick })
        or ui.label({ key = "name-plain", text = text, fontSize = 12, color = "on_surface", flexGrow = 1 })
    local share = node.s > 0 and entry.bytes / node.s * 100 or 0
    local bar
    if palette then -- Types mode: a bar in the colour of the row's category (a folder: its biggest)
        local cat = entry.category or categoryOfNode(entry.node)
        bar = ui.box({ key = "typebar", fill = cat and palette[cat] or colors.loose, radius = 2, width = 4, height = 14 })
    else
        bar = ui.box({ key = "swatch", fill = colors[entry.node or entry.kind] or colors.other, radius = 2, width = 9, height = 9 })
    end
    return ui.row({ key = "space-row-" .. i, gap = 6, align = "center", height = ROW_HEIGHT }, {
        bar,
        name,
        label("size", shared.tr("usage_amount", {
            size = shared.formatBytes(entry.bytes), share = string.format("%.0f", share),
        })),
    })
end

local function legendRow(slice, i, node)
    local text = slice.kind == "loose" and shared.tr("space_loose")
        or slice.kind == "other" and shared.tr("usage_other")
        or display(slice.label, LABEL_MAX)
    local child = slice.kind == "dir" and idx.child(node, slice.label)
    local name
    if slice.kind == "category" then
        local cat = slice.index
        name = ui.button({ key = "name-btn", text = shared.tr("cat_" .. slice.label), fontSize = 11, variant = "ghost",
            contentAlign = "start", selected = typeFilter == cat, flexGrow = 1, height = 20,
            onClick = function() space.setTypeFilter(typeFilter ~= cat and cat or nil) end })
    elseif child and not child.leaf then
        name = ui.button({ key = "name-btn", text = text, fontSize = 11, variant = "ghost", contentAlign = "start",
            flexGrow = 1, height = 20, onClick = function() space.enter(slice.label) end })
    else
        name = ui.label({ key = "name-plain", text = text, fontSize = 11, color = "on_surface_variant", flexGrow = 1 })
    end
    local share = node.s > 0 and slice.bytes / node.s * 100 or 0
    return ui.row({ key = "space-legend-" .. i, gap = 6, align = "center", height = 20 }, {
        ui.box({ key = "swatch", fill = slice.color, radius = 2, width = 9, height = 9 }),
        name,
        ui.label({ key = "size", fontSize = 11, color = "on_surface_variant", text = shared.tr("usage_amount", {
            size = shared.formatBytes(slice.bytes), share = string.format("%.0f", share),
        }) }),
    })
end

local function sortButton(key)
    local active = sortKey == key
    return ui.button({
        key = "space-sort-" .. key,
        text = shared.tr("space_sort_" .. key),
        glyph = active and (sortDesc and "arrow-down" or "arrow-up") or nil,
        variant = "ghost", controlSize = "sm", selected = active,
        onClick = function() space.setSort(key) end,
    })
end

-- The text in place of the chart and list, or nil when an index is shown.
local function statusText()
    if space.index ~= nil then
        return nil
    end
    if space.state == "error" then
        return shared.tr("space_err." .. (space.errText or "spawn")), "error"
    end
    if space.state == "scanning" then
        return shared.tr("space_scanning")
    end
    return shared.tr("space_loading")
end

function space.render()
    local node = current()
    local atHome = space.root ~= "/"
    local controls = ui.row({ key = "space-buttons", gap = 4, align = "center" }, {
        ui.button({ key = "space-up", glyph = "arrow-up", variant = "ghost", enabled = #path > 1,
            tooltip = shared.tr("space_tip_up"), onClick = space.up }),
        ui.button({ key = "space-root", glyph = atHome and "device-desktop" or "home", variant = "ghost",
            text = atHome and "/" or "~", tooltip = shared.tr(atHome and "space_tip_root" or "space_tip_home"),
            onClick = space.toggleRoot }),
        ui.row({ key = "space-mode", gap = 2 }, {
            ui.button({ key = "folders", text = shared.tr("space_mode_folders"), variant = "ghost",
                controlSize = "sm", selected = mode == "folders", onClick = function() space.setMode("folders") end }),
            ui.button({ key = "types", text = shared.tr("space_mode_types"), variant = "ghost",
                controlSize = "sm", selected = mode == "types", onClick = function() space.setMode("types") end }),
        }),
        ui.spacer({ key = "gap", flexGrow = 1 }),
        ui.button({ key = "space-refresh", glyph = "refresh", variant = "ghost", enabled = not space.scanning,
            tooltip = shared.tr("space_tip_refresh"), onClick = space.refresh }),
    })
    -- The end of a long path is the part that says where you are.
    local where = absolute():gsub("%c", " ")
    local len = utf8.len(where)
    if len ~= nil and len > LABEL_MAX + 6 then
        where = "…" .. where:sub(utf8.offset(where, len - LABEL_MAX - 4))
    end
    local left = {
        ui.label({ key = "space-path", text = where, fontSize = 13,
            fontWeight = "bold", color = "on_surface" }),
        controls,
    }
    local text, color = statusText()
    if text == nil and space.scanning then
        text = shared.tr("space_rescanning")
    elseif text == nil and space.errText ~= nil then
        text, color = shared.tr("space_err." .. space.errText), "error"
    end
    if text ~= nil then
        table.insert(left, label("space-msg", text, color))
    end
    local right = {}
    if node ~= nil then
        local slices = paint(idx.slices(node, mode, usage.MAX_SLICES))
        local image = writeSvg(node, slices)
        if image ~= nil then
            table.insert(left, ui.image({ key = "space-img", path = image, width = DONUT_SIZE, height = DONUT_SIZE }))
        end
        local legend = {}
        for i, slice in ipairs(slices) do
            table.insert(legend, legendRow(slice, i, node))
        end
        table.insert(left, ui.column({ key = "space-legend", gap = 1 }, legend))

        -- Swatch colours: a shown folder takes its slice's colour; the rest stay grey.
        local dark = noctalia.isDarkMode()
        local colors = table.clone(dark and GREY.dark or GREY.light)
        for _, slice in ipairs(slices) do
            if slice.node then
                colors[slice.node] = slice.color
            end
        end
        local rows = {}
        for i, entry in ipairs(idx.sort(idx.entries(node, mode, typeFilter), sortKey, sortDesc)) do
            table.insert(rows, listRow(entry, i, node, colors, mode == "types" and (dark and idx.COLORS_DARK or idx.COLORS_LIGHT) or nil))
        end
        table.insert(right, ui.row({ key = "space-sort", gap = 4, align = "center" }, {
            sortButton("size"), sortButton("name"),
        }))
        table.insert(right, ui.scroll({ key = "space-list", flexGrow = 1, gap = 2 }, rows))
    end
    return ui.row({ key = "space", flexGrow = 1, gap = 16 }, {
        ui.column({ key = "space-left", width = LEFT_WIDTH, gap = 8 }, left),
        ui.column({ key = "space-right", flexGrow = 1, gap = 4 }, right),
    })
end

return space
