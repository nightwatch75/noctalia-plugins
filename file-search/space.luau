--!nonstrict
-- file-search — the Space tab of the panel: a disk-usage browser.
--
-- Role: a module required by panel.luau (never an entry of its own). The panel
-- calls onOpen()/onClose() with its own lifecycle and embeds whatever
-- render() returns under the tab bar. The treemap UI arrives in later steps;
-- this file owns the scan engine and its state. The panel calls space.step()
-- on its frame tick while space.needsTick() is true: scans and index loads
-- only advance there.
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
    space.scannedAt = at
    space.state = "ready"
    space.errText = nil
    if scanLoad then
        endScan(nil)
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
-- already in flight is never doubled.
function space.scan(root, force, done)
    space.setRoot(root)
    if space.scanning then
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
    return space.needsTick()
end

function space.needsTick()
    return space.scanning or space.loading
end

-- ── panel hooks ──────────────────────────────────────────────────────────────

function space.onOpen() end

function space.onClose() end

function space.render()
    return ui.label({
        key = "space",
        text = noctalia.tr("space_placeholder"),
        color = "on_surface_variant",
        flexGrow = 1,
    })
end

return space
