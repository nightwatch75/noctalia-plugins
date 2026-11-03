-- module: sessions.luau
-- repairTarget refusals and encoding, repairSession argv order, collision and
-- failure handling. The real moves run in repair_test.sh.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end

local calls, exists, failAt = {}, {}, nil
noctalia = {
    expandPath = function(p) return (p:gsub("^~", "/h")) end,
    tr = function(k) return k end,
    fileExists = function(p) return exists[p] == true end,
    pluginDir = function() return "/plug" end,
    runAsync = function(argv, cb)
        table.insert(calls, argv)
        cb({ exitCode = (failAt == #calls) and 1 or 0 })
        return true
    end,
}
local sessions = loadstring(MODULE_SRC)()

local ID = "abcdef12-1"
local function mk(fields)
    local raw = { id = ID, projectDir = "-old", cwd = "/w/x", mtime = 1, status = "dir_mismatch" }
    for k, v in pairs(fields or {}) do raw[k] = v end
    return sessions.groupByProject({ raw })[1].sessions[1]
end

-- repairTarget
local t, e = sessions.repairTarget(mk())
eq(t, "/w/x", "target is the recorded cwd"); eq(e, nil, "no error")
t, e = sessions.repairTarget(mk({ status = "ok" })); eq(t, nil, "ok refused"); assert(e, "ok code")
t, e = sessions.repairTarget(mk({ status = "cwd_missing" })); eq(t, nil, "cwd_missing refused")
t, e = sessions.repairTarget(mk({ id = "../x" })); eq(t, nil, "bad id refused")
t, e = sessions.repairTarget(mk({ cwd = "rel/dir" })); eq(t, nil, "relative"); eq(e, "not_absolute", "relative code")
t, e = sessions.repairTarget(mk({ cwd = "/a/../b" })); eq(t, nil, "dotdot"); eq(e, "unsafe", "dotdot code")
t, e = sessions.repairTarget(mk({ cwd = "/a/..", projectDir = "-x" })); eq(t, nil, "trailing dotdot")
t, e = sessions.repairTarget(mk({ cwd = "/a\nb" })); eq(t, nil, "control char"); eq(e, "unsafe", "control code")
t, e = sessions.repairTarget(mk({ cwd = "/" .. string.rep("a", 200) })); eq(t, nil, "long name"); eq(e, "unsafe", "long code")
t, e = sessions.repairTarget(mk({ cwd = "/w/x", projectDir = "-w-x" })); eq(t, nil, "same dir"); assert(e, "same dir code")
t, e = sessions.repairTarget(mk({ cwd = "/w/..foo" })); eq(t, "/w/..foo", "dots inside a name are fine")

-- repairSession: no existing cwd, with sidecar
local P = "/h/.claude/projects"
exists[P .. "/-old/" .. ID] = true
local ok, err
sessions.repairSession(mk(), function(o, r) ok, err = o, r end)
eq(ok, true, "done ok"); eq(err, nil, "no err")
local function flat(a) return table.concat(a, " ") end
eq(#calls, 4, "four steps")
eq(flat(calls[1]), "mkdir -p -- /w/x", "mkdir cwd")
eq(flat(calls[2]), "mkdir -p -- " .. P .. "/-w-x", "mkdir project")
eq(flat(calls[3]), "mv -n -- " .. P .. "/-old/" .. ID .. ".jsonl " .. P .. "/-w-x/", "mv jsonl")
eq(flat(calls[4]), "mv -n -- " .. P .. "/-old/" .. ID .. " " .. P .. "/-w-x/", "mv sidecar")

-- existing cwd, no sidecar
calls, exists = {}, { ["/w/x"] = true }
sessions.repairSession(mk(), function(o) ok = o end)
eq(ok, true, "ok 2"); eq(#calls, 2, "two steps")
eq(calls[1][2], "-p", "first is project mkdir"); eq(calls[1][4], P .. "/-w-x", "project mkdir path")
eq(calls[2][1], "mv", "then mv")

-- encoding: one dash per Unicode character
calls, exists = {}, { ["/w/è x"] = true }
sessions.repairSession(mk({ cwd = "/w/è x" }), function() end)
eq(calls[1][4], P .. "/-w---x", "è is one dash")

-- collision runs nothing
calls, exists = {}, { [P .. "/-w-x/" .. ID .. ".jsonl"] = true }
sessions.repairSession(mk(), function(o, r) ok, err = o, r end)
eq(ok, false, "collision refused"); eq(err, "exists", "collision code"); eq(#calls, 0, "nothing ran")

-- refusal runs nothing
calls, exists = {}, {}
sessions.repairSession(mk({ cwd = "rel" }), function(o, r) ok, err = o, r end)
eq(ok, false, "refused"); eq(err, "not_absolute", "refusal code"); eq(#calls, 0, "no exec")

-- failures stop the chain
for step, code in pairs({ [1] = "mkdir", [2] = "mkdir", [3] = "move", [4] = "move" }) do
    calls, exists, failAt = {}, { [P .. "/-old/" .. ID] = true }, step
    sessions.repairSession(mk(), function(o, r) ok, err = o, r end)
    eq(ok, false, "failed at " .. step); eq(err, code, "code at " .. step); eq(#calls, step, "stopped at " .. step)
end
failAt = nil
print("sessions_repair_test ok")
