-- module: space.luau shared.luau usage.luau space_index.luau
-- Scan pipeline of space.luau (ncdu -> jq -> index), with the host stubbed:
-- runAsync only records argv + callback, and the test drives each callback by
-- hand. Files live in an in-memory table; json.decode maps known texts to
-- tables. Run through tests/run.sh, which splices the real modules.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end

local MOUNTS = table.concat({
    "/dev/sda2 / btrfs rw 0 0",
    "proc /proc proc rw 0 0",
    "/dev/sda2 /home btrfs rw 0 0",
    "server:/share /mnt/nas nfs4 rw 0 0",
    "gvfsd-fuse /run/user/1000/gvfs fuse.gvfsd-fuse rw 0 0",
}, "\n")

local files, decoded, runs, config, tools, clock
local DIR = "/data"
local HOME = "/home/u"

-- A fresh VM: new module instances (the ncdu version probe is cached per load).
local function boot()
    files = { ["/proc/mounts"] = { text = MOUNTS, mtime = 0 } }
    decoded, runs, config, tools, clock = {}, {}, {}, {}, 1000000
    noctalia = {
        readFile = function(p) local f = files[p]; return f and f.text end,
        writeFile = function(p, t) files[p] = { text = t, mtime = clock }; return true end,
        removeFile = function(p) files[p] = nil; return true end,
        fileInfo = function(p) local f = files[p]; return f and { size = #f.text, mtime = f.mtime, isDir = false } end,
        listDir = function(dir)
            local out = {}
            for p in pairs(files) do
                local name = p:match("^" .. dir .. "/([^/]+)$")
                if name then table.insert(out, name) end
            end
            return out
        end,
        commandExists = function(n) return tools[n] ~= false end,
        getConfig = function(k) return config[k] end,
        expandPath = function(p) return p end,
        nowMs = function() return clock * 1000 end,
        pluginDataDir = function() return DIR end,
        log = function() end,
        json = { decode = function(t)
            local v = decoded[t]
            if v == nil then error("bad json") end
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

local function has(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
end
local function count(list, value)
    local n = 0
    for _, v in ipairs(list) do if v == value then n += 1 end end
    return n
end
local function argAfter(argv, flag) return argv[has(argv, flag) + 1] end

local function indexFor(root, v)
    local text = "IDX:" .. root .. ":" .. tostring(v)
    decoded[text] = { v = v, root = root, tree = { n = root, s = 10, f = 10, c = {}, d = {}, t = {} } }
    return text
end

-- Drives the version probe, returns the ncdu run.
local function passVersion(space)
    eq(runs[#runs].argv[1], "ncdu", "probe first")
    eq(runs[#runs].argv[2], "--version", "probe arg")
    runs[#runs].cb({ exitCode = 0, stdout = "ncdu 2.9.2\n", stderr = "" })
    return runs[#runs]
end

-- Plays jq: the shell script's $4 receives the index, $3 (temp) is gone.
local function playJq(run, text)
    local sh = has(run.argv, "sh")
    local tmp, final = run.argv[sh + 6], run.argv[sh + 7]
    files[final] = { text = text, mtime = clock }
    files[tmp] = nil
end

-- ── excludeArgs ──────────────────────────────────────────────────────────────
do
    local space = boot()
    local args = space.excludeArgs()
    eq(args[1], "--exclude-kernfs", "kernfs first")
    -- /dev /mnt/nas /proc /run /sys (gvfs is nested in /run, the btrfs mounts are local)
    eq(count(args, "--exclude"), 5, "one --exclude per pruned mount")
    assert(has(args, "/mnt/nas") and has(args, "/proc"), "nfs mount excluded")
    assert(not has(args, "/home"), "local mount scanned")
    assert(not has(args, "-x"), "never -x")
    config.usage_exclude_dirs = "node_modules"
    args = space.excludeArgs()
    eq(count(args, "--exclude"), 6, "usage excludes feed ncdu")
    eq(args[#args], "node_modules", "usage exclude last")
    config.usage_exclude_dirs = nil
    config.space_exclude_external = false
    args = space.excludeArgs()
    eq(#args, 1, "external mounts kept when the setting is off")
    eq(args[1], "--exclude-kernfs", "only kernfs")
end

-- ── checkTools ───────────────────────────────────────────────────────────────
do
    local space = boot()
    eq(space.checkTools(), nil, "all present")
    tools.ncdu = false
    eq(space.checkTools(), "ncdu", "ncdu missing")
    tools.ncdu, tools.jq = nil, false
    eq(space.checkTools(), "jq", "jq missing")
end

-- ── old ncdu: error, no scan ─────────────────────────────────────────────────
do
    local space = boot()
    local doneCalls = 0
    space.scan("/", false, function() doneCalls += 1 end)
    runs[1].cb({ exitCode = 0, stdout = "ncdu 1.19\n", stderr = "" })
    eq(#runs, 1, "no ncdu walk with ncdu 1.x")
    eq(space.state, "error", "old ncdu is an error")
    eq(space.errText, "ncdu", "names the tool")
    eq(space.checkTools(), "ncdu", "checkTools remembers the old version")
    eq(doneCalls, 1, "done called")
end

-- ── full pipeline; ncdu exit 1 with a scan file is fine (Review Focus 4) ─────
do
    local space = boot()
    local doneCalls = 0
    space.scan("/", false, function() doneCalls += 1 end)
    eq(space.state, "scanning", "scanning with no index")
    local ncdu = passVersion(space)
    local a = ncdu.argv
    eq(a[1], "nice", "ncdu under nice"); eq(a[3], "19", "nice level")
    assert(has(a, "ncdu") and has(a, "-0"), "ncdu -0")
    local scanFile = argAfter(a, "-o")
    eq(scanFile:sub(1, #DIR + 1), DIR .. "/", "scan file in the data dir")
    assert(has(a, "--exclude-kernfs") and has(a, "/mnt/nas"), "excludes passed")
    assert(not has(a, "-x"), "never -x")
    eq(a[#a - 1], "--", "root after --"); eq(a[#a], "/", "root last")
    eq(ncdu.timeout, 600000, "ncdu timeout")

    files[scanFile] = { text = "[1,2,{},[{\"name\":\"/\"}]]", mtime = clock }
    ncdu.cb({ exitCode = 1, stdout = "", stderr = "permission denied" })
    eq(#runs, 3, "jq started after ncdu exit 1")
    local jq = runs[3]
    eq(jq.timeout, 300000, "jq timeout")
    eq(jq.argv[1], "nice", "jq under nice")
    local sh = has(jq.argv, "sh")
    eq(jq.argv[sh + 1], "-c", "sh -c")
    local script = jq.argv[sh + 2]
    assert(script:find('> "$3"', 1, true), "jq writes to the temp path")
    assert(script:find('mv -f "$3" "$4"', 1, true), "temp moved onto the index")
    assert(script:find("jq ", 1, true), "script runs jq")
    eq(jq.argv[sh + 5], scanFile, "$2 is the scan file")
    local tmp, final = jq.argv[sh + 6], jq.argv[sh + 7]
    eq(final, DIR .. "/space-root.json", "index path per root")
    assert(tmp ~= final and tmp:sub(1, #DIR + 1) == DIR .. "/", "temp next to the index")
    assert(jq.argv[sh + 4]:find("node(0)", 1, true), "$1 is the jq program")
    eq(space.state, "scanning", "still scanning during jq")

    playJq(jq, indexFor("/", 1))
    jq.cb({ exitCode = 0, stdout = "", stderr = "" })
    eq(space.state, "ready", "ready after jq")
    eq(space.index.n, "/", "index loaded")
    eq(space.scanning, false, "not scanning")
    eq(files[scanFile], nil, "big scan file removed")
    eq(doneCalls, 1, "done once")

    -- Fresh now: no new process; the version probe is not repeated on force.
    space.scan("/", false, function() doneCalls += 1 end)
    eq(#runs, 3, "fresh index: no scan"); eq(doneCalls, 2, "done on fresh")
    space.scan("/", true, function() end)
    eq(runs[4].argv[has(runs[4].argv, "ncdu")], "ncdu", "force rescans")
    eq(has(runs[4].argv, "--version"), nil, "version probed once")
end

-- ── ncdu leaves no scan file: error, jq never runs ───────────────────────────
do
    local space = boot()
    space.scan("/", false, function() end)
    local ncdu = passVersion(space)
    ncdu.cb({ exitCode = 1, stdout = "", stderr = "" })
    eq(#runs, 2, "no jq without a scan file")
    eq(space.state, "error", "error"); eq(space.errText, "empty", "empty scan")
end

-- ── jq fails: scan and temp files removed, error ─────────────────────────────
do
    local space = boot()
    space.scan("/", false, function() end)
    local ncdu = passVersion(space)
    local scanFile = argAfter(ncdu.argv, "-o")
    files[scanFile] = { text = "[1,2,{},[", mtime = clock }
    ncdu.cb({ exitCode = 0, stdout = "", stderr = "" })
    local jq = runs[3]
    local tmp = jq.argv[has(jq.argv, "sh") + 6]
    files[tmp] = { text = "{\"v\":1,", mtime = clock } -- half-written
    jq.cb({ exitCode = 5, stdout = "", stderr = "parse error" })
    eq(space.state, "error", "jq failure is an error")
    eq(files[scanFile], nil, "scan file removed after a failed reduce")
    eq(files[tmp], nil, "temp removed")
    eq(files[DIR .. "/space-root.json"], nil, "no index")
end

-- ── late callback after setRoot is ignored (Review Focus 3) ──────────────────
do
    local space = boot()
    local doneCalls = 0
    space.scan("/", false, function() doneCalls += 1 end)
    local ncdu = passVersion(space)
    local scanFile = argAfter(ncdu.argv, "-o")
    space.setRoot(HOME)
    eq(space.root, HOME, "root switched"); eq(space.state, "idle", "new root idle")
    eq(space.scanning, false, "new root not scanning")
    files[scanFile] = { text = "[1]", mtime = clock }
    ncdu.cb({ exitCode = 0, stdout = "", stderr = "" })
    eq(#runs, 2, "late ncdu result starts no jq")
    eq(files[scanFile], nil, "late scan file removed")
    eq(space.state, "idle", "late result ignored"); eq(doneCalls, 0, "no done for a dropped scan")

    -- A newer scan of the same root makes the older jq result stale too.
    space.setRoot("/")
    space.scan("/", true, function() end)
    local ncdu2 = runs[#runs]
    files[argAfter(ncdu2.argv, "-o")] = { text = "[1]", mtime = clock }
    ncdu2.cb({ exitCode = 0, stdout = "", stderr = "" })
    local jqOld = runs[#runs]
    space.setRoot(HOME)
    space.setRoot("/")
    space.scan("/", true, function() end)
    local ncdu3 = runs[#runs]
    assert(has(ncdu3.argv, "-o") and argAfter(ncdu3.argv, "-o") ~= argAfter(ncdu2.argv, "-o"), "each scan its own file")
    playJq(jqOld, indexFor("/", 1))
    jqOld.cb({ exitCode = 0, stdout = "", stderr = "" })
    eq(space.scanning, true, "the newer scan is still running")
    eq(space.state, "scanning", "older jq result does not finish the newer scan")
    eq(space.index, nil, "older jq result not loaded")
end

-- ── stale index stays shown while the rescan runs ────────────────────────────
do
    local space = boot()
    files[DIR .. "/space-root.json"] = { text = indexFor("/", 1), mtime = clock - 2 * 86400 }
    assert(space.load(DIR), "index loads")
    eq(space.state, "ready", "ready after load")
    space.scan("/", false, function() end)
    eq(#runs, 1, "stale index: rescan starts")
    eq(space.state, "ready", "stays ready"); eq(space.scanning, true, "scanning")
    assert(space.index ~= nil, "old index kept")

    local fresh = boot()
    files[DIR .. "/space-root.json"] = { text = indexFor("/", 1), mtime = clock - 60 }
    assert(fresh.load(DIR), "fresh index loads")
    fresh.scan("/", false, function() end)
    eq(#runs, 0, "fresh index: no scan")
end

-- ── corrupted / other-version index is discarded (Review Focus 5) ────────────
do
    local space = boot()
    local path = DIR .. "/space-root.json"
    files[path] = { text = "{garbage", mtime = clock }
    eq(space.load(DIR), false, "corrupted index discarded")
    eq(space.index, nil, "no index")
    files[path] = { text = indexFor("/", 2), mtime = clock }
    eq(space.load(DIR), false, "other version discarded")
    files[path] = { text = indexFor(HOME, 1), mtime = clock }
    eq(space.load(DIR), false, "index of another root discarded")
    files[path] = { text = "", mtime = clock }
    eq(space.load(DIR), false, "empty file discarded")
    eq(space.load(nil), false, "no data dir")
    eq(space.state, "idle", "still idle")
    -- each root has its own index file
    space.setRoot(HOME)
    files[DIR .. "/space-home.json"] = { text = indexFor(HOME, 1), mtime = clock }
    assert(space.load(DIR), "home index from its own file")
end

print("space_scan_test OK")
