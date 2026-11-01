-- module: space.luau shared.luau usage.luau space_index.luau
-- Scan pipeline of space.luau, with the host stubbed. The scan is one detached
-- `sh -c` run (runAsync without callback); the test plays the script by
-- writing its marker and index files, then drives space.step() with a fake
-- clock. Files live in an in-memory table; json.decode maps known line texts
-- to tables and returns nil, err for anything else, like the host. Run
-- through tests/file-search/run.sh, which splices the real modules.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end

local MOUNTS = table.concat({
    "/dev/sda2 / btrfs rw 0 0",
    "proc /proc proc rw 0 0",
    "/dev/sda2 /home btrfs rw 0 0",
    "server:/share /mnt/nas nfs4 rw 0 0",
    "gvfsd-fuse /run/user/1000/gvfs fuse.gvfsd-fuse rw 0 0",
}, "\n")

local files, decoded, runs, config, tools, ms, decodeCost, spawnOk
local heapKiB, decodes, reads -- gcinfo() stub value; json.decode calls; readFile calls per path
local DIR = "/data"
local HOME = "/home/u"
local DAY = 86400

-- A fresh VM: new module instances (the ncdu version is cached per load).
local function boot(home)
    files = { ["/proc/mounts"] = { text = MOUNTS, mtime = 0 } }
    -- no lsblk: the mount probe falls back to /proc/mounts and answers at once
    decoded, runs, config, tools = {}, {}, {}, { lsblk = false }
    ms, decodeCost, spawnOk = 1e9, 0, true
    heapKiB, decodes, reads = 0, 0, {}
    gcinfo = function() return heapKiB end
    noctalia = {
        readFile = function(p) reads[p] = (reads[p] or 0) + 1; local f = files[p]; return f and f.text end,
        writeFile = function(p, t) files[p] = { text = t, mtime = ms // 1000 }; return true end,
        removeFile = function(p) files[p] = nil; return true end,
        fileInfo = function(p) local f = files[p]; return f and { size = #f.text, mtime = f.mtime, isDir = false } end,
        fileExists = function(p)
            local name = p:match("^/usr/bin/([^/]+)$")
            if name then return tools[name] ~= false end
            return files[p] ~= nil
        end,
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
        expandPath = function(p) return (p:gsub("^~", HOME)) end,
        nowMs = function() return ms end,
        pluginDataDir = function() return DIR end,
        log = function() end,
        tr = function(k, v) return v and (k .. ":" .. tostring(v.percent or v.time)) or k end,
        json = { decode = function(t)
            ms += decodeCost
            decodes += 1
            local v = decoded[t]
            if v == nil then return nil, "bad json" end
            return v
        end },
        runAsync = function(argv, cb, timeout)
            table.insert(runs, { argv = argv, cb = cb, timeout = timeout })
            return spawnOk
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
    local space = require("./space.luau")
    -- The fixtures are rooted at "/"; `home` keeps the start on the home folder.
    if not home then space.setRoot("/") end
    return space
end

local function has(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
end
local function count(list, value)
    local n = 0
    for _, v in ipairs(list) do if v == value then n += 1 end end
    return n
end

-- JSON Lines index: header, then records in pre-order. Each line is a unique
-- token that the json stub maps to its table.
local serial = 0
local function jsonl(root, v, records)
    serial += 1
    local head = "H" .. serial
    decoded[head] = { v = v, root = root }
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
local function smallIndex(root, v)
    return jsonl(root, v or 4, {
        { id = "0", n = root, s = 10 },
        { id = "0/0", n = "a", s = 6 },
        { id = "0/0/0", n = "x", s = 6, leaf = true },
        { id = "0/1", n = "b", s = 4 },
    })
end
-- Index file of `root` for the current settings (space-<root>-<tag>.json).
local function indexFile(root)
    return DIR .. "/space-" .. (root == "/" and "root" or "home") .. "-" .. require("./space.luau").settingsTag() .. ".json"
end
local function putIndex(root, text, age)
    files[indexFile(root)] = { text = text, mtime = ms // 1000 - (age or 0) }
end

local function drain(space)
    for _ = 1, 10000 do
        if not space.step() then return end
        ms += 1000
    end
    error("step() never settles")
end

-- Answers the version probe; returns the detached run.
local function passVersion(version)
    local probe = runs[#runs]
    eq(probe.argv[1], "/usr/bin/ncdu", "probe uses the absolute ncdu")
    eq(probe.argv[2], "--version", "probe arg")
    assert(probe.cb ~= nil, "probe has a callback")
    probe.cb({ exitCode = 0, stdout = (version or "ncdu 2.9.2") .. "\n", stderr = "", timedOut = false })
    return runs[#runs]
end

-- Positional arguments of the detached script (see space.luau).
local function scriptArgs(run)
    local a = run.argv
    return {
        script = a[3], ncdu = a[5], jq = a[6], program = a[7], scan = a[8],
        tmp = a[9], index = a[10], marker = a[11], nice = a[12],
    }
end

-- Plays the script's end: the index lands and the marker says how it went.
local function playScript(run, code, indexText)
    local s = scriptArgs(run)
    if indexText then files[s.index] = { text = indexText, mtime = ms // 1000 } end
    files[s.marker] = { text = code .. "\n", mtime = ms // 1000 }
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
    config.space_skip_network = false
    args = space.excludeArgs()
    assert(not has(args, "/mnt/nas"), "network mount scanned when space_skip_network is off")
    assert(has(args, "/proc") and has(args, "/run"), "pseudo and fixed paths always excluded")
    eq(count(args, "--exclude"), 4, "only /dev /proc /run /sys")
    eq(args[1], "--exclude-kernfs", "kernfs kept")
    config.space_skip_network = nil
end

-- ── settings tag: one per setting combination, in the index file name ───────
do
    local space = boot()
    local seen = {}
    local function tag()
        local t = space.settingsTag()
        assert(t:match("^%x%x%x%x%x%x%x%x$"), "8 hex chars: " .. t)
        return t
    end
    for _, c in ipairs({
        {}, { space_skip_network = false }, { space_skip_external = false },
        { space_skip_network = false, space_skip_external = false }, { usage_exclude_dirs = "/mnt/data" },
        { usage_exclude_dirs = "/mnt/data2" },
    }) do
        config = c
        local t = tag()
        eq(seen[t], nil, "tag differs per setting combination")
        seen[t] = true
    end
    config = { space_skip_network = true, space_skip_external = true }
    eq(space.settingsTag(), (function() config = {}; return space.settingsTag() end)(), "nil reads as true")
end

-- ── checkTools ───────────────────────────────────────────────────────────────
do
    local space = boot()
    eq(space.checkTools(), nil, "all present")
    tools.ncdu = false
    eq(space.checkTools(), "ncdu", "ncdu missing")
    tools.ncdu, tools.jq = nil, false
    eq(space.checkTools(), "jq", "jq missing")
    -- found outside /usr/bin, through the candidate list
    tools.jq = false
    files[HOME .. "/.local/bin/jq"] = { text = "x", mtime = 0 }
    eq(space.checkTools(), nil, "jq in ~/.local/bin")
end

-- ── old ncdu: remembered, no scan ────────────────────────────────────────────
do
    local space = boot()
    local doneCalls = 0
    space.scan("/", false, function() doneCalls += 1 end)
    passVersion("ncdu 1.19")
    eq(#runs, 1, "no scan with ncdu 1.x")
    eq(space.state, "error", "old ncdu is an error")
    eq(space.errText, "ncdu_old", "old ncdu code")
    eq(space.checkTools(), "ncdu_old", "checkTools remembers the old version")
    eq(space.scanning, false, "not stuck scanning")
    eq(doneCalls, 1, "done called")
end

-- ── version probe timeout: not remembered, retried on the next scan ──────────
do
    local space = boot()
    space.scan("/", false, function() end)
    runs[1].cb({ exitCode = -1, stdout = "", stderr = "", timedOut = true })
    eq(space.errText, "timeout", "probe timeout"); eq(space.scanning, false, "not stuck")
    eq(space.checkTools(), nil, "a timeout does not mark ncdu old")
    space.scan("/", true, function() end)
    eq(runs[2].argv[2], "--version", "probed again")
end

-- ── the tab starts on the home folder; no usable home falls back to "/" ─────
do
    local space = boot(true)
    eq(space.root, HOME, "initial root is home")
    space.onOpen(function() end) -- no index: the first scan starts by itself
    local a = passVersion().argv
    eq(a[#a - 1], "--", "root after --"); eq(a[#a], HOME, "first scan of the home folder")
    assert(scriptArgs(runs[#runs]).index:find("/space-home-", 1, true), "home index file")
    space.toggleRoot() -- refused while scanning
    eq(space.root, HOME, "still home")

    local realHome = HOME
    HOME = ""
    eq(boot(true).root, "/", "empty home: /")
    HOME = realHome
end

-- ── progress estimate: the last complete scan's duration ─────────────────────
local function timeFile(root)
    return (indexFile(root):gsub("%.json$", ".time"))
end
do
    eq(boot().formatElapsed(0), "0:00", "m:ss zero")
    eq(boot().formatElapsed(45999), "0:45", "m:ss seconds")
    eq(boot().formatElapsed(125000), "2:05", "m:ss minutes")

    -- no history: elapsed time only; the duration is stored on "ok"
    local space = boot()
    space.scan("/", false, function() end)
    local run = passVersion()
    eq(space.phase, "scan", "scan phase"); eq(space.progress, nil, "no history: no estimate")
    eq(space.elapsedMs, 0, "elapsed from the launch")
    ms += 20000
    space.step()
    eq(space.elapsedMs, 20000, "elapsed counts"); eq(space.progress, nil, "still no estimate")
    files[scriptArgs(run).marker .. ".phase"] = { text = "reduce\n", mtime = 0 }
    ms += 1000
    space.step()
    eq(space.phase, "reduce", "phase file read")
    ms += 1000
    playScript(run, "ok", smallIndex("/"))
    space.step()
    eq(files[timeFile("/")].text, "22000", "duration stored on ok")
    drain(space)
    eq(space.progress, nil, "no progress after the scan"); eq(space.phase, nil, "no phase after the scan")
    eq(space.elapsedMs, nil, "no elapsed after the scan")

    -- with history: fraction of the last duration, capped at 0.95
    space = boot()
    files[timeFile("/")] = { text = "30000", mtime = 0 }
    space.scan("/", false, function() end)
    passVersion()
    eq(space.progress, 0, "estimate starts at 0")
    ms += 15000
    space.step()
    eq(space.progress, 0.5, "15 s of 30 s")
    ms += 60000
    space.step()
    eq(space.progress, 0.95, "capped")

    -- invalid history, or another settings tag: no estimate
    space = boot()
    files[timeFile("/")] = { text = "soon", mtime = 0 }
    space.scan("/", false, function() end)
    passVersion()
    eq(space.progress, nil, "invalid time file ignored")
    space = boot()
    files[timeFile("/")] = { text = "30000", mtime = 0 }
    config.space_skip_network = false
    space.scan("/", false, function() end)
    passVersion()
    eq(space.progress, nil, "another settings tag ignores the old duration")
    config.space_skip_network = nil

    -- not stored on a failure or a timeout
    for _, code in ipairs({ "empty", "reduce" }) do
        space = boot()
        space.scan("/", false, function() end)
        playScript(passVersion(), code, nil)
        drain(space)
        eq(files[timeFile("/")], nil, code .. ": no duration stored")
        eq(space.progress, nil, code .. ": no progress"); eq(space.phase, nil, code .. ": no phase")
    end
    space = boot()
    space.scan("/", false, function() end)
    passVersion()
    ms += space.SCAN_DEADLINE_MS + 2000
    space.step()
    eq(files[timeFile("/")], nil, "timeout: no duration stored")

    -- redraws follow the visible text: a slow estimate moves 0.1 % a second
    space = boot()
    files[timeFile("/")] = { text = "1000000", mtime = 0 }
    local redraws = 0
    space.onOpen(function() redraws += 1 end)
    space.refresh()
    passVersion()
    redraws = 0
    for _ = 1, 5 do ms += 1000; space.step() end
    eq(redraws, 0, "under 1 %: no redraw")
    for _ = 1, 6 do ms += 1000; space.step() end
    eq(redraws, 1, "one redraw per whole percent")
end

-- ── full pipeline: one detached run, polled marker, sliced load ──────────────
do
    local space = boot()
    local doneCalls = 0
    eq(space.step(), false, "nothing to do when idle")
    space.scan("/", false, function() doneCalls += 1 end)
    eq(space.state, "scanning", "scanning with no index")
    eq(space.needsTick(), true, "ticks while probing")
    local run = passVersion()
    eq(#runs, 2, "detached run started")
    eq(run.cb, nil, "detached: no callback, so no host timeout")
    local a, s = run.argv, scriptArgs(run)
    eq(a[1], "/bin/sh", "absolute sh"); eq(a[2], "-c", "sh -c"); eq(a[4], "sh", "$0")
    eq(s.ncdu, "/usr/bin/ncdu", "absolute ncdu"); eq(s.jq, "/usr/bin/jq", "absolute jq")
    eq(s.nice, "/usr/bin/nice", "absolute nice")
    assert(s.program:find("flat(", 1, true), "jq program as an argument")
    eq(s.index, indexFile("/"), "index path per root and settings tag")
    for _, key in ipairs({ "scan", "tmp", "marker" }) do
        eq(s[key]:sub(1, #DIR + 1), DIR .. "/", key .. " in the data dir")
    end
    assert(s.tmp ~= s.index and s.scan ~= s.index, "temp and scan are not the index")
    assert(has(a, "--exclude-kernfs") and has(a, "/mnt/nas"), "excludes passed")
    assert(not has(a, "-x"), "never -x")
    eq(a[#a - 1], "--", "root after --"); eq(a[#a], "/", "root last")
    -- the script is a constant: no path, no value of this scan in its text
    assert(not s.script:find(DIR, 1, true) and not s.script:find("usr", 1, true), "no path in the script")
    assert(s.script:find('mv -f "$t" "$i"', 1, true), "temp moved onto the index")
    assert(s.script:find("-n 19", 1, true), "nice level")
    eq(s.script:match("^[^\n]*"), "echo 1000 2>/dev/null > /proc/self/oom_score_adj", "oom score first")

    -- marker not there yet: still scanning
    ms += 1000
    eq(space.step(), true, "waiting on the marker")
    playScript(run, "ok", smallIndex("/"))
    eq(space.step(), true, "polls at most once a second")
    eq(space.loading, false, "not polled within the second")
    ms += 1000
    space.step()
    eq(files[s.marker], nil, "marker consumed")
    drain(space)
    eq(space.state, "ready", "ready")
    eq(space.index.n, "/", "index root"); eq(space.index.d[1].n, "a", "child order")
    eq(space.index.d[1].d[1].leaf, true, "leaf"); eq(#space.index.d[2].d, 0, "d always a table")
    eq(space.scanning, false, "not scanning"); eq(space.loading, false, "not loading")
    eq(space.needsTick(), false, "no tick needed")
    eq(doneCalls, 1, "done once")

    space.scan("/", false, function() doneCalls += 1 end)
    eq(#runs, 2, "fresh index: no scan"); eq(doneCalls, 2, "done on fresh")
    space.scan("/", true, function() end)
    eq(runs[3].cb, nil, "force rescans, version probed once")
    local s3 = scriptArgs(runs[3])
    assert(s3.marker ~= s.marker and s3.scan ~= s.scan, "each scan its own files")
    eq(s3.script, s.script, "same constant script")
end

-- ── script reports failures: empty scan (ncdu wrote nothing), failed reduce ──
for _, code in ipairs({ "empty", "reduce" }) do
    local space = boot()
    space.scan("/", false, function() end)
    playScript(passVersion(), code, nil)
    drain(space)
    eq(space.state, "error", code .. " is an error"); eq(space.errText, code, "code")
    eq(space.scanning, false, code .. ": not stuck"); eq(space.index, nil, "no index")
end

-- ── spawn failure and deadline ───────────────────────────────────────────────
do
    local space = boot()
    spawnOk = false
    space.scan("/", false, function() end)
    runs[1].cb({ exitCode = 0, stdout = "ncdu 2.9.2", stderr = "", timedOut = false })
    eq(space.errText, "spawn", "detached spawn failure"); eq(space.scanning, false, "not stuck")

    space = boot()
    space.scan("/", false, function() end)
    passVersion()
    ms += space.SCAN_DEADLINE_MS + 2000
    space.step()
    eq(space.errText, "timeout", "no marker past the deadline"); eq(space.scanning, false, "not stuck")
end

-- ── stale marker is ignored (Review Focus 3) ─────────────────────────────────
do
    local space = boot()
    local doneCalls = 0
    space.scan("/", false, function() doneCalls += 1 end)
    local old = passVersion()
    space.setRoot(HOME)
    eq(space.root, HOME, "root switched"); eq(space.state, "idle", "new root idle")
    eq(space.scanning, false, "new root not scanning")
    playScript(old, "ok", smallIndex("/"))
    ms += 1000
    eq(space.step(), false, "old marker never polled")
    eq(space.index, nil, "old result not loaded"); eq(doneCalls, 0, "no done for a dropped scan")

    -- a newer scan of the same root: the older marker is not the one polled
    local stale = boot()
    stale.scan("/", false, function() end)
    local first = passVersion()
    stale.setRoot(HOME); stale.setRoot("/")
    stale.scan("/", true, function() end)
    local second = runs[#runs]
    assert(scriptArgs(second).marker ~= scriptArgs(first).marker, "markers carry the scan id")
    playScript(first, "ok", smallIndex("/"))
    ms += 1000
    stale.step()
    eq(stale.loading, false, "older marker does not start a load")
    eq(stale.scanning, true, "the newer scan still runs")
    -- a probe answer for a dropped scan starts nothing
    local s4 = boot()
    s4.scan("/", false, function() end)
    s4.setRoot(HOME)
    runs[1].cb({ exitCode = 0, stdout = "ncdu 2.9.2", stderr = "", timedOut = false })
    eq(#runs, 1, "dropped scan: probe answer starts no run")
end

-- ── stale index stays shown while the rescan runs ────────────────────────────
do
    local space = boot()
    putIndex("/", smallIndex("/"), 2 * DAY)
    assert(space.startLoad(DIR), "index starts loading")
    drain(space)
    eq(space.state, "ready", "ready after load")
    space.scan("/", false, function() end)
    eq(#runs, 1, "stale index: rescan starts")
    eq(space.state, "ready", "stays ready"); eq(space.scanning, true, "scanning")
    assert(space.index ~= nil, "old index kept")

    local fresh = boot()
    putIndex("/", smallIndex("/"), 60)
    fresh.startLoad(DIR)
    drain(fresh)
    fresh.scan("/", false, function() end)
    eq(#runs, 0, "fresh index: no scan")
end

-- ── sliced load: bounded work per step, old index until complete ─────────────
do
    local space = boot()
    putIndex("/", smallIndex("/"), 0)
    space.startLoad(DIR)
    drain(space)
    local old = space.index
    local records = { { id = "0", n = "/", s = 1000 } }
    for i = 0, 199 do table.insert(records, { id = "0/" .. i, n = "d" .. i, s = 5 }) end
    putIndex("/", jsonl("/", 4, records), 0)
    decodeCost = 3
    assert(space.startLoad(DIR), "big index starts")
    local steps = 0
    while space.loading do
        local before = ms
        space.step()
        steps += 1
        assert(ms - before <= space.SLICE_MS + decodeCost, "step over budget: " .. (ms - before) .. " ms")
        if space.loading then eq(space.index, old, "old index until the new one is complete") end
        assert(steps < 1000, "load never ends")
    end
    assert(steps > 10, "load spread over many steps (" .. steps .. ")")
    eq(#space.index.d, 200, "all records attached")
    eq(space.index.d[200].n, "d199", "order kept")
end

-- ── u (unreadable folders) is loaded; an older index without it reads as 0 ──
do
    local space = boot()
    putIndex("/", jsonl("/", 4, { { id = "0", n = "/", s = 10, u = 3 }, { id = "0/0", n = "a", s = 6, u = 2 },
        { id = "0/1", n = "b", s = 4 } }), 0)
    space.startLoad(DIR)
    drain(space)
    eq(space.index.u, 3, "root u"); eq(space.index.d[1].u, 2, "child u")
    eq(space.index.d[2].u, 0, "absent u defaults to 0")
end

-- ── a bad line discards the index; nothing stuck ─────────────────────────────
do
    local space = boot()
    local text = smallIndex("/") .. "{not json\n"
    putIndex("/", text, 0)
    assert(space.startLoad(DIR), "header fine")
    drain(space)
    eq(space.loading, false, "not stuck loading"); eq(space.index, nil, "discarded")
    eq(space.state, "idle", "no error without a scan: the caller rescans")

    -- a record whose parent is missing is as bad as invalid JSON
    putIndex("/", jsonl("/", 4, { { id = "0", n = "/", s = 1 }, { id = "0/4/2", n = "x", s = 1 } }), 0)
    space.startLoad(DIR)
    drain(space)
    eq(space.index, nil, "orphan record discards the index")

    -- during a scan, a bad index ends the scan with "index"
    space.scan("/", false, function() end)
    playScript(passVersion(), "ok", "H0\n{bad\n")
    decoded.H0 = { v = 4, root = "/" }
    drain(space)
    eq(space.errText, "index", "bad new index"); eq(space.scanning, false, "scan not stuck")
end

-- ── header checks (Review Focus 5) and per-root files ────────────────────────
do
    local space = boot()
    putIndex("/", "{garbage\n", 0)
    eq(space.startLoad(DIR), false, "corrupted header discarded")
    putIndex("/", smallIndex("/", 1), 0)
    eq(space.startLoad(DIR), false, "an index of format 1 (5 files per type) is discarded")
    putIndex("/", smallIndex("/", 2), 0)
    eq(space.startLoad(DIR), false, "an index of format 2 (no fold relative to the parent) is discarded")
    putIndex("/", smallIndex("/", 3), 0)
    eq(space.startLoad(DIR), false, "an index of format 3 (no file counts) is discarded")
    putIndex("/", "", 0)
    eq(space.startLoad(DIR), false, "empty file discarded")
    eq(space.startLoad(nil), false, "no data dir")
    eq(space.loading, false, "not loading"); eq(space.state, "idle", "still idle")

    -- home is a symlink: ncdu writes the resolved name, the index still loads
    space.setRoot(HOME)
    putIndex(HOME, smallIndex("/real" .. HOME), 0)
    assert(space.startLoad(DIR), "home index from its own file")
    drain(space)
    eq(space.state, "ready", "symlinked home loads")
end

-- ── mount probe before the run (removable disks excluded on a first use) ────
do
    local space = boot()
    local shared = require("./shared.luau")
    local pending, any
    shared.probeMounts = function(_, done, all) pending, any = done, all end
    space.scan("/", false, function() end)
    passVersion()
    eq(#runs, 1, "no run while the mount probe runs")
    assert(pending ~= nil and any == true, "probe asked for every scope")
    eq(space.scanning, true, "still scanning"); eq(space.needsTick(), true, "ticks while probing")
    ms += 1000
    eq(space.step(), true, "step keeps waiting")
    space.scan("/", true, function() end)
    eq(#runs, 1, "no second scan while probing")
    shared.mounts = { "/mnt/usb*key" }
    pending()
    eq(#runs, 2, "run starts in the probe callback")
    local a = runs[2].argv
    local at = has(a, "/mnt/usb\\*key")
    assert(at and a[at - 1] == "--exclude", "removable mount excluded, glob escaped")
    pending()
    eq(#runs, 2, "a second callback starts nothing")

    -- the setting off: no probe, no removable exclude
    space = boot()
    shared = require("./shared.luau")
    config.space_skip_external = false
    local probed = false
    shared.mounts = { "/mnt/usb" }
    shared.probeMounts = function(_, done) probed = true; done() end
    space.scan("/", false, function() end)
    passVersion()
    eq(probed, false, "space_skip_external off: no mount probe")
    eq(#runs, 2, "run starts at once")
    assert(not has(runs[2].argv, "/mnt/usb"), "setting off: mount scanned")
    assert(has(runs[2].argv, "/mnt/nas"), "network still skipped")

    -- a late callback after a root switch starts nothing
    space = boot()
    shared = require("./shared.luau")
    shared.probeMounts = function(_, done) pending = done end
    space.scan("/", false, function() end)
    passVersion()
    space.setRoot(HOME)
    pending()
    eq(#runs, 1, "stale probe callback ignored")

    -- a probe that never answers: the run starts anyway after PROBE_WAIT_MS
    space = boot()
    shared = require("./shared.luau")
    shared.probeMounts = function() end
    space.scan("/", false, function() end)
    passVersion()
    ms += space.PROBE_WAIT_MS + 1
    space.step()
    eq(#runs, 2, "lost probe: launched with what is known")
    eq(runs[2].cb, nil, "the detached run")
end

-- ── onOpen sweeps leftovers of a killed scan, never those of a live one ─────
do
    local space = boot()
    putIndex("/", smallIndex("/"), 60)
    local timeFile = indexFile("/"):gsub("%.json$", ".time")
    files[timeFile] = { text = "30000", mtime = 0 }
    for _, ext in ipairs({ "scan", "tmp", "done", "done.phase" }) do
        files[DIR .. "/space-root-1-1." .. ext] = { text = "x", mtime = 0 }
    end
    space.onOpen(function() end)
    assert(files[timeFile], "duration of the last scan kept")
    for _, ext in ipairs({ "scan", "tmp", "done", "done.phase" }) do
        eq(files[DIR .. "/space-root-1-1." .. ext], nil, "leftover ." .. ext .. " swept")
    end
    assert(files[indexFile("/")], "index kept")

    space = boot()
    space.scan("/", false, function() end)
    local live = scriptArgs(passVersion()).scan
    files[live] = { text = "x", mtime = 0 }
    space.onOpen(function() end)
    assert(files[live], "a running scan keeps its file")
end

-- ── changed settings: never the stale index ─────────────────────────────────
do
    local space = boot()
    putIndex("/", smallIndex("/"), 60)
    space.onOpen(function() end)
    drain(space)
    eq(space.state, "ready", "index of the default settings")
    eq(#runs, 0, "fresh: no scan")
    local redraws = 0
    space.onOpen(function() redraws += 1 end)
    space.onClose()
    -- unchanged config: nothing happens
    space.onConfigChanged()
    assert(space.index ~= nil, "unchanged config keeps the index")
    eq(space.state, "ready", "still ready"); eq(#runs, 0, "no scan")
    -- a changed setting drops the index; the next open scans for the new tag
    config.space_skip_network = false
    space.onConfigChanged()
    eq(space.index, nil, "index dropped"); eq(space.state, "idle", "idle")
    space.onOpen(function() end)
    eq(#runs, 1, "no index for the new tag: scan")
    local run = passVersion()
    eq(scriptArgs(run).index, indexFile("/"), "scan writes the new tag's file")
    assert(not has(run.argv, "/mnt/nas"), "new argv: nfs mount scanned")
    -- the scan completes: the older tag's file (and an untagged legacy one) go
    local oldFile = DIR .. "/space-root-" .. (function()
        config.space_skip_network = nil
        local t = space.settingsTag()
        config.space_skip_network = false
        return t
    end)() .. ".json"
    assert(files[oldFile], "old tag file still there before the scan ends")
    files[DIR .. "/space-root.json"] = { text = "x", mtime = 0 }
    files[DIR .. "/space-home-0badc0de.json"] = { text = "x", mtime = 0 }
    local oldTime = oldFile:gsub("%.json$", ".time")
    files[oldTime] = { text = "30000", mtime = 0 }
    files[DIR .. "/space-home-0badc0de.time"] = { text = "30000", mtime = 0 }
    playScript(run, "ok", smallIndex("/"))
    ms += 1000
    drain(space)
    eq(space.state, "ready", "new index loaded")
    eq(files[oldFile], nil, "old tag file removed")
    eq(files[DIR .. "/space-root.json"], nil, "legacy untagged file removed")
    eq(files[oldTime], nil, "old tag duration removed")
    assert(files[DIR .. "/space-home-0badc0de.time"], "other root duration kept")
    assert(files[DIR .. "/space-home-0badc0de.json"], "other root kept")
    assert(files[indexFile("/")], "new index kept")

    -- back to the old setting while open: reset and reload at once
    space = boot()
    putIndex("/", smallIndex("/"), 60)
    space.onOpen(function() end)
    drain(space)
    local n = 0
    space.onOpen(function() n += 1 end)
    config.space_skip_external = false
    space.onConfigChanged()
    assert(n > 0, "redraw on reset")
    eq(#runs, 1, "open tab: the new tag is scanned at once")
    -- first launch argv with skipNet on: --exclude for the nfs mount
    config = { space_skip_external = false }
    local fresh = boot()
    fresh.scan("/", false, function() end)
    local a = passVersion().argv
    local at = has(a, "/mnt/nas")
    assert(at and a[at - 1] == "--exclude", "skipNet on: nfs mount excluded")
end

-- ── index guards: file size and Lua heap ─────────────────────────────────────
-- A file over INDEX_MAX_BYTES is refused before it is read (fileInfo size).
do
    local space = boot()
    local max = space.INDEX_MAX_BYTES
    assert(max and max > 4e6 and max < 128 * 1048576, "INDEX_MAX_BYTES set")
    local text = smallIndex("/") .. string.rep("x", max)
    putIndex("/", text, 0)
    local before, read0 = decodes, reads[indexFile("/")] or 0
    eq(space.startLoad(DIR), false, "too big: not loaded")
    eq(decodes, before, "too big: no decode")
    eq(reads[indexFile("/")] or 0, read0, "too big: not even read")
    eq(space.errText, "index_big", "index_big code"); eq(space.state, "error", "no index to show: error")
    eq(space.loading, false, "not loading")
    space.scan("/", false, function() end)
    eq(#runs, 0, "a too big index is not rescanned by itself")
    -- the string check after the read: fileInfo lies (file grew after the stat)
    space = boot()
    putIndex("/", text, 0)
    noctalia.fileInfo = function() return { size = 10, mtime = 0, isDir = false } end
    eq(space.startLoad(DIR), false, "too big after the read")
    eq(decodes, 0, "no decode after a read over the limit")
    eq(space.errText, "index_big", "index_big code after the read")
    -- the same file is not read again
    local n = reads[indexFile("/")]
    eq(space.startLoad(DIR), false, "tripped file refused again")
    eq(reads[indexFile("/")], n, "tripped file not read again")
    -- a normal index still loads
    space = boot()
    putIndex("/", smallIndex("/"), 0)
    assert(space.startLoad(DIR), "normal index loads")
    drain(space)
    eq(space.state, "ready", "normal index ready"); eq(space.errText, nil, "no error")
end

-- Heap over HEAP_SOFT_BYTES mid-load: the load stops, the old index stays.
do
    local space = boot()
    putIndex("/", smallIndex("/"), 60)
    space.startLoad(DIR)
    drain(space)
    local old = space.index
    local records = { { id = "0", n = "/", s = 1000 } }
    for i = 0, 199 do table.insert(records, { id = "0/" .. i, n = "d" .. i, s = 5 }) end
    local big = jsonl("/", 4, records)
    space.scan("/", true, function() end)
    playScript(passVersion(), "ok", big)
    decodeCost = 3
    local guard = 0
    while not space.loading do space.step(); ms += 1000; guard += 1; assert(guard < 100, "load never starts") end
    space.step() -- one slice under the limit
    assert(space.loading, "load spans several slices")
    heapKiB = space.HEAP_SOFT_BYTES // 1024 + 1
    local before = decodes
    drain(space)
    eq(decodes, before, "no decode after the heap trip")
    eq(space.index, old, "old index stays shown")
    eq(space.state, "ready", "ready: an index is shown"); eq(space.errText, "index_big", "notice")
    eq(space.scanning, false, "scan not stuck"); eq(space.loading, false, "load not stuck")
    -- the same file is not read again, a new scan resets the guard
    heapKiB = 0
    local n = reads[indexFile("/")]
    space.setRoot(HOME); space.setRoot("/")
    eq(reads[indexFile("/")], n, "tripped file not read again")
    eq(space.errText, "index_big", "refused again: notice"); eq(space.state, "error", "nothing to show")
    space.scan("/", true, function() end)
    playScript(runs[#runs], "ok", big) -- ncdu version already known: no probe
    drain(space)
    eq(#space.index.d, 200, "a new scan reads the file again")
    eq(space.errText, nil, "no notice")
end

-- A rescan whose new index is over INDEX_MAX_BYTES: old index stays, notice.
do
    local space = boot()
    putIndex("/", smallIndex("/"), 60)
    space.startLoad(DIR)
    drain(space)
    local old = space.index
    space.scan("/", true, function() end)
    playScript(passVersion(), "ok", smallIndex("/") .. string.rep("x", space.INDEX_MAX_BYTES))
    drain(space)
    eq(space.index, old, "old index stays shown")
    eq(space.state, "ready", "still ready"); eq(space.errText, "index_big", "index_big notice")
    eq(space.scanning, false, "scan ended")
end

-- ── onDisabled: a running scan is dropped, nothing new starts ───────────────
do
    local space = boot()
    space.onDisabled() -- nothing running: no-op, starts nothing
    eq(#runs, 0, "idle onDisabled starts nothing")
    local doneCalls = 0
    space.scan("/", false, function() doneCalls += 1 end)
    local run = passVersion()
    eq(space.scanning, true, "scan running")
    space.onDisabled()
    eq(space.scanning, false, "scan dropped"); eq(space.loading, false, "no load")
    eq(space.state, "idle", "idle")
    eq(space.needsTick(), false, "no tick")
    local before = #runs
    playScript(run, "ok", smallIndex("/"))
    ms += 1000
    space.step()
    eq(space.index, nil, "late marker ignored"); eq(space.loading, false, "late marker starts no load")
    eq(doneCalls, 0, "no done for a dropped scan")
    space.onOpen(function() end) -- re-enable: the dropped run is not resurrected
    eq(space.index, nil, "old result not loaded after re-enable")
    eq(space.scanning and #runs > before or false, false, "no stale marker polled")
end

print("space_scan_test OK")
