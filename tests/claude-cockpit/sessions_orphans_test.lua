-- module: sessions.luau
-- checkOrphans parsing and removeOrphans path validation / argv; delete and
-- rename id guard.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end

local calls, rcode, stdout = {}, 0, ""
noctalia = {
    expandPath = function(p) return (p:gsub("^~", "/h")) end,
    tr = function(k) return k end, pluginDir = function() return "/plug" end,
    fileExists = function() return false end,
    runAsync = function(argv, cb) table.insert(calls, argv); cb({ exitCode = rcode, stdout = stdout }); return true end,
    json = { encode = function() return "LINE" end, decode = function(s) if s == "bad" then return nil end return { orphans = { { kind = "project", path = "/h/.claude/projects/-a", bytes = 0, mtime = 123, reason = "project_empty" } } } end },
}
local sessions = loadstring(MODULE_SRC)()
local function join(a) return table.concat(a, " ") end

local U = "11111111-1111-1111-1111-111111111111"
local E, F, P = "/h/.claude/session-env/", "/h/.claude/file-history/", "/h/.claude/projects/"

-- checkOrphans: argv carries --exclude per live id; result decoded
stdout = "ok"
local got, err
sessions.checkOrphans({ "a1", "b2" }, function(o, e) got, err = o, e end)
eq(join(calls[1]), "bash /plug/list-claude-orphans --exclude a1 --exclude b2", "check argv")
eq(got[1].path, "/h/.claude/projects/-a", "orphans decoded")
eq(got[1].mtime, 123, "mtime carried"); eq(got[1].reason, "project_empty", "reason carried")
-- a live id that is not hex is dropped, never passed to the script
calls = {}
sessions.checkOrphans({ "a1; rm" }, function() end)
eq(join(calls[1]), "bash /plug/list-claude-orphans", "bad live id dropped")
stdout = "bad"
sessions.checkOrphans({}, function(o, e) got, err = o, e end)
eq(got, nil, "bad json"); eq(err, "err_sessions_data", "bad json err")
rcode = 1
sessions.checkOrphans({}, function(o, e) got, err = o, e end)
eq(got, nil, "exit err"); eq(err, "err_sessions_fetch", "exit err msg")
rcode = 0

-- removeOrphans: refusals run nothing
local function refuse(list, m)
    calls = {}
    local r
    sessions.removeOrphans(list, function(ok) r = ok end)
    eq(r, false, m); eq(#calls, 0, m .. " no exec")
end
refuse({ { kind = "session-env", path = "/etc/passwd" } }, "outside")
refuse({ { kind = "session-env", path = E .. "not-a-uuid" } }, "non uuid")
refuse({ { kind = "session-env", path = E .. ".." } }, "dotdot")
refuse({ { kind = "project", path = P .. "../x" } }, "dotdot project")
refuse({ { kind = "project", path = P .. "-a/sub" } }, "nested")
refuse({ { kind = "session-env", path = F .. U } }, "kind/parent mismatch")
refuse({ { kind = "project", path = P } }, "parent itself")
refuse({ { kind = "bogus", path = P .. "-a" } }, "bad kind")
refuse({ { kind = "session-env", path = E .. U }, { kind = "project", path = "/x/-a" } }, "one bad refuses all")

-- reason and mtime never decide: a bogus reason is judged by the path rules only
refuse({ { kind = "session-env", path = "/etc/passwd", reason = "project_empty", mtime = 1 } }, "bogus reason, bad path")
calls = {}
local okb
sessions.removeOrphans({ { kind = "project", path = P .. "-a", reason = "bogus", mtime = "x" } }, function(r) okb = r end)
eq(okb, true, "bogus reason, good path removed")

-- valid
calls = {}
local ok
sessions.removeOrphans({
    { kind = "session-env", path = E .. U }, { kind = "file-history", path = F .. U },
    { kind = "project", path = P .. "-a" }, { kind = "project", path = P .. "-b" },
}, function(r) ok = r end)
eq(ok, true, "valid ok")
eq(join(calls[1]), "rm -rf -- " .. E .. U .. " " .. F .. U, "rm argv")
eq(join(calls[2]), "rmdir -- " .. P .. "-a/memory " .. P .. "-b/memory", "memory rmdir")
eq(join(calls[3]), "rmdir -- " .. P .. "-a " .. P .. "-b", "project rmdir")
eq(#calls, 3, "three execs")
calls = {}
sessions.removeOrphans({}, function(r) ok = r end)
eq(ok, true, "empty ok"); eq(#calls, 0, "empty no exec")

-- id guard on delete/rename
local s = { id = "..", jsonlPath = "/j", sidecarDir = "/s", sessionEnvDir = "/e", fileHistoryDir = "/f", memoryDir = "/m", projectPath = "/p" }
for _, bad in ipairs({ "..", "", "a/b", "xyz" }) do
    s.id = bad
    calls = {}
    local r
    sessions.deleteSession(s, function(x) r = x end); eq(r, false, "delete refuses " .. bad)
    sessions.renameSession(s, "t", function(x) r = x end); eq(r, false, "rename refuses " .. bad)
    eq(#calls, 0, "no exec for id " .. bad)
end

-- failed rm skips rmdir
s.id = U
calls = {}; rcode = 1
local r
sessions.deleteSession(s, function(x) r = x end)
eq(r, false, "failed rm"); eq(#calls, 1, "rmdir skipped")
print("sessions_orphans_test ok")
