--!nonstrict
-- file-search — the Space tab of the panel: a disk-usage browser.
--
-- Role: a module required by panel.luau (never an entry of its own). The panel
-- calls onOpen()/onClose() with its own lifecycle and embeds whatever
-- render() returns under the tab bar. The treemap UI arrives in later steps;
-- this file owns the scan engine and its state.
--
-- State (module fields, read by the panel):
--   space.state     "idle" | "scanning" | "ready" | "error". A stale index
--                   stays "ready" while its rescan runs (see space.scanning).
--   space.scanning  a scan of space.root is in flight
--   space.errText   last failure: "ncdu" | "jq" (tool missing or too old),
--                   "datadir", "spawn", "timeout", "empty", "reduce", "index"
--   space.root      "/" or the home path
--   space.index     decoded index tree (see space_index.luau), nil = none
--   space.scannedAt unix seconds of the index file (its mtime)
--
-- Pipeline, all argv through runAsync, never blocking the panel:
--   1. `ncdu --version`, once per load (ncdu >= 2.0 required).
--   2. `nice -n 19 ncdu -0 -o <scan> --exclude-kernfs --exclude <path>... -- root`.
--      Never -x: on "/" it skips /home and /var/log when they are separate
--      mounts. ncdu exits 1 after unreadable folders; the scan file decides.
--   3. `nice -n 19 sh -c 'jq ... > tmp && mv -f tmp index'`. The only shell in
--      the plugin's Space path: the host captures at most 1 MiB of stdout and
--      the index is ~2.5 MB, so jq must redirect into a file itself. The script
--      is a constant; every value reaches it as a positional parameter.
--   The scan file (100+ MB) is removed after the reduce, success or not.
--
-- Each scan is stamped with a nonce; setRoot() or a newer scan bumps it, and a
-- callback carrying an older nonce only removes its own files. Each scan has
-- its own scan/temp file names, so an old and a new run never share a file;
-- the index file itself only ever changes by the atomic mv.

local shared = require("./shared.luau")
local usage = require("./usage.luau")
local idx = require("./space_index.luau")

local space = {}

-- The host clamps runAsync timeouts to its own ceiling (60 s in current
-- builds); these are the intended values. Measured on "/": ncdu ~15 s, jq ~29 s.
space.NCDU_TIMEOUT_MS = 600000
space.JQ_TIMEOUT_MS = 300000
space.VERSION_TIMEOUT_MS = 5000

-- Values recorded with their measurements in the header of space_index.luau.
local DEPTH, TOP_N, MIN_BYTES = 6, 5, 1048576

local JQ_SCRIPT = 'jq -c "$1" "$2" > "$3" && mv -f "$3" "$4"'

space.state = "idle"
space.scanning = false
space.errText = nil
space.root = "/"
space.index = nil
space.scannedAt = 0

local scanNonce = 0
local inFlight = 0     -- pipelines of this VM still running, current or stale
local ncduOld = nil    -- nil = not probed yet

-- ── files ────────────────────────────────────────────────────────────────────

local function rootTag(root)
    return root == "/" and "root" or "home"
end

local function indexPath(dir, root)
    return dir .. "/space-" .. rootTag(root) .. ".json"
end

-- Scan/temp files left by a VM that was reloaded mid-scan. Unlinking one an
-- orphan process still writes is harmless: it keeps its own inode.
local function sweep(dir)
    for _, name in ipairs(noctalia.listDir(dir) or {}) do
        if name:match("^space%-.+%.scan$") or name:match("^space%-.+%.tmp$") then
            noctalia.removeFile(dir .. "/" .. name)
        end
    end
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
    if ncduOld or not noctalia.commandExists("ncdu") then
        return "ncdu"
    end
    if not noctalia.commandExists("jq") then
        return "jq"
    end
    return nil
end

-- ── index ────────────────────────────────────────────────────────────────────

-- A cache: anything unreadable, of another version or of another root is
-- discarded (false), and the caller rescans.
function space.load(dir)
    if dir == nil then
        return false
    end
    local path = indexPath(dir, space.root)
    local text = noctalia.readFile(path)
    if type(text) ~= "string" or text == "" then
        return false
    end
    local ok, data = pcall(noctalia.json.decode, text)
    if not ok or type(data) ~= "table" or data.v ~= 1 or data.root ~= space.root
        or type(data.tree) ~= "table" then
        return false
    end
    local info = noctalia.fileInfo(path)
    space.index = data.tree
    space.scannedAt = info and info.mtime or 0
    space.state = "ready"
    space.errText = nil
    return true
end

function space.fresh()
    return space.state == "ready" and space.index ~= nil
        and (shared.now() - space.scannedAt) < usage.TTL_SECONDS
end

-- Drops the current index and ignores any scan still running for the old root.
function space.setRoot(root)
    if root == space.root then
        return
    end
    scanNonce += 1
    space.root = root
    space.index = nil
    space.scannedAt = 0
    space.scanning = false
    space.state = "idle"
    space.errText = nil
    space.load(shared.dataDir())
end

-- ── scan ─────────────────────────────────────────────────────────────────────

-- A failure keeps an index already on screen ("ready" + errText).
local function fail(text)
    space.scanning = false
    space.errText = text
    if space.index == nil then
        space.state = "error"
    end
end

local function niced(argv)
    if not noctalia.commandExists("nice") then
        return argv
    end
    local out = { "nice", "-n", "19" }
    for _, arg in ipairs(argv) do
        table.insert(out, arg)
    end
    return out
end

-- Scan `root` (switching to it first), then call done() unless the scan was
-- dropped by setRoot or a newer scan. `force` skips the TTL; a scan of the
-- current root already in flight is never doubled.
function space.scan(root, force, done)
    space.setRoot(root)
    if space.scanning then
        return
    end
    if not force and space.fresh() then
        done()
        return
    end
    local missing = space.checkTools()
    if missing ~= nil then
        fail(missing)
        done()
        return
    end
    local dir = shared.dataDir()
    if dir == nil then
        fail("datadir")
        done()
        return
    end
    if inFlight == 0 then
        sweep(dir)
    end

    scanNonce += 1
    local nonce = scanNonce
    -- The clock keeps names unique across reloads, where the nonce restarts.
    local stem = string.format("%s/space-%s-%d-%d", dir, rootTag(root), noctalia.nowMs(), nonce)
    local scanFile, tmpFile = stem .. ".scan", stem .. ".tmp"
    space.scanning = true
    if space.index == nil then
        space.state = "scanning"
    end
    inFlight += 1

    local function current()
        return nonce == scanNonce
    end
    -- Every pipeline ends here exactly once.
    local function finish(errText)
        inFlight -= 1
        noctalia.removeFile(scanFile)
        noctalia.removeFile(tmpFile)
        if not current() then
            return
        end
        if errText ~= nil then
            fail(errText)
        elseif not space.load(dir) then
            fail("index")
        else
            space.scanning = false
        end
        done()
    end
    local function start(argv, callback, timeoutMs)
        if not noctalia.runAsync(argv, callback, timeoutMs) then
            finish("spawn")
        end
    end

    local function reduce()
        start(niced({
            "sh", "-c", JQ_SCRIPT, "sh",
            idx.jqProgram(DEPTH, TOP_N, MIN_BYTES), scanFile, tmpFile, indexPath(dir, root),
        }), function(result)
            if result.timedOut then
                finish("timeout")
            elseif result.exitCode ~= 0 then
                noctalia.log("file-search: space index reduce failed: " .. tostring(result.stderr))
                finish("reduce")
            else
                finish(nil)
            end
        end, space.JQ_TIMEOUT_MS)
    end

    local function walk()
        local argv = { "ncdu", "-0", "-o", scanFile }
        for _, arg in ipairs(space.excludeArgs()) do
            table.insert(argv, arg)
        end
        table.insert(argv, "--")
        table.insert(argv, root)
        start(niced(argv), function(result)
            if not current() then
                finish(nil)
                return
            end
            -- The exit status is ignored: one unreadable folder makes it 1.
            local info = noctalia.fileInfo(scanFile)
            if result.timedOut then
                finish("timeout")
            elseif info == nil or info.size == 0 then
                finish("empty")
            else
                reduce()
            end
        end, space.NCDU_TIMEOUT_MS)
    end

    if ncduOld ~= nil then
        walk()
        return
    end
    start({ "ncdu", "--version" }, function(result)
        local major = tonumber((result.stdout or ""):match("ncdu (%d+)%."))
        ncduOld = major == nil or major < 2
        if ncduOld then
            finish("ncdu")
        elseif not current() then
            finish(nil)
        else
            walk()
        end
    end, space.VERSION_TIMEOUT_MS)
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
