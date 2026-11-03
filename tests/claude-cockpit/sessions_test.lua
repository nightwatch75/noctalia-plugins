-- module: sessions.luau
-- Session shape, delete argv, rename validation. The real rename shell
-- snippet runs in rename_append_test.sh.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end

local calls = {}
local encoded
noctalia = {
    expandPath = function(p) return (p:gsub("^~", "/h")) end,
    tr = function(k, a) return k .. (a and a.id or "") end,
    fileExists = function(p) return p == "/h/.claude/projects/-p/memory" end,
    pluginDir = function() return "/plug" end,
    runAsync = function(argv, cb) table.insert(calls, argv); cb({ exitCode = 0 }); return true end,
    json = { encode = function(t) encoded = t; return "LINE" end },
}
local sessions = loadstring(MODULE_SRC)()

local function group(raw) return sessions.groupByProject({ raw })[1].sessions[1] end
local base = { id = "abcdef12-1", projectDir = "-p", cwd = "/w", mtime = 1 }
local function with(t) local r = {} for k, v in pairs(base) do r[k] = v end for k, v in pairs(t) do r[k] = v end return r end

eq(group(with({ customTitle = "C", title = "A", firstPrompt = "P" })).label, "C", "custom wins")
eq(group(with({ title = "A", firstPrompt = "P" })).label, "A", "ai second")
eq(group(with({ customTitle = "", title = "", firstPrompt = "P" })).label, "P", "prompt third")
eq(group(with({})).label, "session_untitledabcdef12", "id last")

local s = group(with({ status = "misplaced" }))
eq(s.projectDir, "-p", "projectDir")
eq(s.status, "misplaced", "status")
eq(group(base).status, "ok", "status default")
eq(group(base).resolvedCwd, "", "resolvedCwd default")
eq(group(base).hasMemory, false, "hasMemory default")
eq(group(base).runCwd, "/w", "runCwd is the recorded cwd")
local rel = group(with({ status = "relocated", resolvedCwd = "/real", hasMemory = true, cwd = "/old" }))
eq(rel.resolvedCwd, "/real", "resolvedCwd"); eq(rel.hasMemory, true, "hasMemory")
eq(rel.runCwd, "/real", "runCwd prefers resolvedCwd"); eq(rel.cwd, "/real", "row cwd is the real folder")
-- A relocated session joins the group of its real folder.
local gs = sessions.groupByProject({
    with({ id = "abcdef12-2", cwd = "/real", mtime = 2 }),
    with({ id = "abcdef12-3", cwd = "/old", resolvedCwd = "/real", status = "relocated", mtime = 1 }),
})
eq(#gs, 1, "one group"); eq(gs[1].cwd, "/real", "group cwd"); eq(gs[1].claudeMdPath, "/real/CLAUDE.md", "group CLAUDE.md")
eq(#gs[1].sessions, 2, "both sessions in it")
eq(s.sessionEnvDir, "/h/.claude/session-env/abcdef12-1", "env")
eq(s.fileHistoryDir, "/h/.claude/file-history/abcdef12-1", "history")
eq(s.memoryDir, "/h/.claude/projects/-p/memory", "memory")
eq(s.projectPath, "/h/.claude/projects/-p", "projectPath")
eq(sessions.memoryKept(s), true, "memoryKept")

local okv
sessions.deleteSession(s, function(ok) okv = ok end)
eq(okv, true, "delete done")
eq(#calls, 3, "three execs")
eq(table.concat(calls[1], " "), "rm -rf -- /h/.claude/projects/-p/abcdef12-1.jsonl /h/.claude/projects/-p/abcdef12-1", "rm argv")
eq(table.concat(calls[2], " "), "sh -c " .. sessions.CLEANUP_SH .. " sh /h/.claude/projects abcdef12-1 /h/.claude/session-env/abcdef12-1 /h/.claude/file-history/abcdef12-1", "cleanup argv")
eq(table.concat(calls[3], " "), "rmdir -- /h/.claude/projects/-p/memory /h/.claude/projects/-p", "rmdir argv")
eq(group(with({})).cwdKnown, true, "cwd known")
eq(group(with({ cwd = "" })).cwdKnown, false, "cwd not recorded")

-- done waits for rmdir; a failed rm skips rmdir
local saved = noctalia.runAsync
local pending, doneCalled = {}, false
noctalia.runAsync = function(argv, cb) table.insert(pending, { argv, cb }); return true end
sessions.deleteSession(s, function() doneCalled = true end)
pending[1][2]({ exitCode = 0 })
pending[2][2]({ exitCode = 0 })
eq(doneCalled, false, "done waits for rmdir")
pending[3][2]({ exitCode = 1 })
eq(doneCalled, true, "done after rmdir")
pending, doneCalled = {}, false
sessions.deleteSession(s, function(ok) doneCalled = ok == false end)
pending[1][2]({ exitCode = 1 })
eq(doneCalled, true, "failed rm: done(false) at once"); eq(#pending, 1, "failed rm: no rmdir")

-- deleteSessions: same per-session sequence, an invalid id counts as failed,
-- never more than 4 commands in flight (host limit is 8).
pending = {}
local inFlight, peak = 0, 0
noctalia.runAsync = function(argv, cb)
    inFlight += 1
    peak = math.max(peak, inFlight)
    table.insert(pending, { argv, function(r) inFlight -= 1; cb(r) end })
    return true
end
local list = {}
for i = 1, 9 do
    table.insert(list, group(with({ id = "abcdef12-" .. i })))
end
table.insert(list, 5, group(with({ id = "../x" })))
local failedN
sessions.deleteSessions(list, function(n) failedN = n end)
local ran = 0
while #pending > 0 do
    local p = table.remove(pending, 1)
    ran += 1
    -- rm of session 3 fails: its cleanup/rmdir must not run
    p[2]({ exitCode = (p[1][1] == "rm" and p[1][4]:find("abcdef12%-3%.jsonl")) and 1 or 0 })
end
eq(failedN, 2, "bad id + failed rm counted")
eq(ran, 8 * 3 + 1, "three execs per deleted session, one for the failed rm")
eq(peak <= 4, true, "at most 4 in flight")
failedN = nil
sessions.deleteSessions({}, function(n) failedN = n end)
eq(failedN, 0, "empty list")
noctalia.runAsync = saved

local projects = sessions.groupByProject({ with({}), with({ id = "b2" }), with({ id = "c3", projectDir = "-q", cwd = "/o" }) })
local function find(id) for _, g in ipairs(projects) do for _, x in ipairs(g.sessions) do if x.id == id then return x end end end end
eq(sessions.isLastInProject(projects, find("c3")), true, "last")
eq(sessions.isLastInProject(projects, find("b2")), false, "not last")

for _, bad in ipairs({ "", "  \n ", string.rep("x", 121) }) do
    calls = {}
    local r
    sessions.renameSession(s, bad, function(ok) r = ok end)
    eq(r, false, "reject")
    eq(#calls, 0, "no exec")
end
calls = {}
sessions.renameSession(s, " a\nb ", function() end)
eq(encoded.customTitle, "a b", "newline to space")
eq(encoded.type, "custom-title", "type")
eq(encoded.sessionId, "abcdef12-1", "sessionId")
eq(calls[1][1], "sh", "sh")
eq(calls[1][5], "/h/.claude/projects/-p/abcdef12-1.jsonl", "jsonl arg")
eq(calls[1][6], "LINE", "line arg")
calls = {}
sessions.renameSession(s, string.rep("x", 120), function() end)
eq(#calls, 1, "120 ok")
print("sessions_test ok")
