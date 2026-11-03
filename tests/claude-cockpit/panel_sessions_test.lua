-- Sessions tab row actions of panel.luau, with the host and sessions.luau
-- stubbed: broken status, Broken filter, copy resume command, rename, the
-- kept-memory notice on delete and the orphan check.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end

local rendered
local function node(kind)
    return function(props, children)
        return { kind = kind, props = props or {}, children = children }
    end
end
ui = setmetatable({}, { __index = function(_, kind) return node(kind) end })
panel = {
    render = function(tree) rendered = tree end,
    setWantsSecondTicks = function() end,
    setNeedsFrameTick = function() end,
    close = function() end,
}

local notes, errors, clips, launched, watchers = {}, {}, {}, {}, {}
noctalia = {
    readFile = function() return 'version = "9.9.9"' end,
    tr = function(key, args)
        if args == nil then return key end
        local parts = {}
        for k, v in pairs(args) do table.insert(parts, k .. "=" .. tostring(v)) end
        table.sort(parts)
        return key .. "(" .. table.concat(parts, ",") .. ")"
    end,
    openSettings = function() end,
    notify = function(_, body) table.insert(notes, body) end,
    notifyError = function(_, body) table.insert(errors, body) end,
    copyToClipboard = function(text, mime) table.insert(clips, { text, mime }); return true end,
    expandPath = function(p) return p end,
    fileExists = function() return true end,
    state = {
        set = function() end,
        get = function() return nil end,
        watch = function(k, cb) watchers[k] = cb end,
    },
}

local function session(id, fields)
    local s = { id = id, label = id, mtime = 100, empty = false, firstPrompt = "", model = "", contextTokens = 0,
        status = "ok", projectDir = "-p-" .. id, cwd = "/p", cwdKnown = true }
    for k, v in pairs(fields or {}) do s[k] = v end
    return s
end
local A = session("aaa1", { cwd = "/tmp/o'neil" })
local B = session("bbb2", { status = "dir_mismatch" })
local C = session("ccc3", { status = "cwd_missing", cwd = "unknown project" })
local LIVE = session("beef")
local GUESS = session("fff6", { cwdKnown = false })
local projects = {
    { cwd = "/p", lastActivity = 100, sessions = { A, B, C, LIVE, GUESS } },
}

local refreshes, renames, deletes = 0, {}, {}
local lastInProject, memoryKept = true, true
local orphanResult, checkedIds, removed
local sessionsStub = {
    refresh = function(cb) refreshes += 1; cb(projects, nil) end,
    isLastInProject = function() return lastInProject end,
    memoryKept = function() return memoryKept end,
    deleteSession = function(s, done) table.insert(deletes, s.id); done(true) end,
    renameSession = function(s, title, done) table.insert(renames, { s.id, title }); done(true) end,
    checkOrphans = function(ids, done) checkedIds = ids; done(orphanResult, nil) end,
    removeOrphans = function(list, done) removed = list; done(true) end,
}
local shared = {
    trim = function(v) return v:match("^%s*(.-)%s*$") end,
    shellQuote = function(v) return "'" .. v:gsub("'", "'\\''") .. "'" end,
    launchTerminal = function(cmd) table.insert(launched, cmd); return true end,
}
require = function(path)
    if path == "./sessions.luau" then return sessionsStub end
    if path == "./shared.luau" then return shared end
    if path == "./live.luau" then return { GROUPS = { "waiting", "busy", "idle" } } end
    return { GROUPS = {} }
end
assert(loadstring(PANEL_SRC, "=panel.luau"))()

local function find(n, key)
    if n.props and n.props.key == key then return n end
    for _, child in ipairs(n.children or {}) do
        local hit = find(child, key)
        if hit then return hit end
    end
end
local function has(n, pred)
    if pred(n) then return true end
    for _, child in ipairs(n.children or {}) do
        if has(child, pred) then return true end
    end
    return false
end
local function click(key)
    local n = find(rendered, key)
    assert(n, "missing " .. key)
    n.props.onClick()
end

onOpen(nil)
click("tab-sessions")
-- Published after leaving the Live tab, which would render it as cards.
watchers.live({ groups = { count = 1, waiting = {}, idle = {}, busy = { { id = "beef" } } } })
click("grp-/p")

-- Broken rows: warning glyph with the reason; resume does not launch.
local warn = find(rendered, "broken-bbb2")
assert(warn, "broken glyph on dir_mismatch row")
eq(warn.props.tooltip, "status_dir_mismatch", "broken tooltip")
assert(has(warn, function(n) return n.kind == "glyph" and n.props.name == "alert-triangle" end), "alert-triangle glyph")
eq(find(rendered, "broken-ccc3").props.tooltip, "status_cwd_missing", "cwd_missing tooltip")
assert(find(rendered, "broken-aaa1") == nil, "ok row has no warning")
click("resume-bbb2")
eq(#launched, 0, "broken resume launches nothing")
eq(errors[1], "err_resume_broken(reason=status_dir_mismatch)", "broken resume error")
click("resume-aaa1")
eq(#launched, 1, "ok row resumes")

-- Broken filter.
eq(find(rendered, "sort-broken").props.text, "filter_broken(n=2)", "broken count")
click("sort-broken")
assert(find(rendered, "resume-aaa1") == nil and find(rendered, "resume-beef") == nil, "ok rows hidden")
assert(find(rendered, "resume-bbb2") and find(rendered, "resume-ccc3"), "broken rows shown")
click("sort-broken")
assert(find(rendered, "resume-aaa1"), "filter off shows all")

-- Copy resume command.
click("copy-aaa1")
eq(clips[1][1], "cd '/tmp/o'\\''neil' && claude --resume aaa1", "copied text")
eq(clips[1][2], "text/plain", "copied mime")
eq(notes[#notes], "copied_resume", "copy notice")
assert(find(rendered, "copy-bbb2"), "broken session with real cwd can copy")
assert(find(rendered, "copy-ccc3") == nil, "no copy without a real cwd")
assert(find(rendered, "copy-fff6") == nil, "no copy for a guessed cwd")

-- Rename.
assert(find(rendered, "ren-beef") == nil, "no pencil on a live session")
click("ren-aaa1")
assert(find(rendered, "sess-wrap-aaa1-ren"), "wrapper key changes while renaming")
local input = find(rendered, "ren-input-aaa1-1")
assert(input and input.kind == "input", "rename input")
eq(find(rendered, "ren-ok-aaa1").props.enabled, false, "empty draft disables confirm")
input.props.onChange("   ")
eq(find(rendered, "ren-ok-aaa1").props.enabled, false, "blank draft disables confirm")
find(rendered, "ren-input-aaa1-1").props.onChange("New name")
eq(find(rendered, "ren-ok-aaa1").props.enabled, true, "draft enables confirm")
local before = refreshes
click("ren-ok-aaa1")
eq(renames[1][1], "aaa1", "rename id"); eq(renames[1][2], "New name", "rename title")
assert(refreshes > before, "rename reloads")
assert(find(rendered, "ren-input-aaa1-1") == nil, "strip closed after rename")
click("ren-aaa1")
assert(find(rendered, "ren-input-aaa1-2"), "reopen reseeds the input")
click("ren-no-aaa1")
assert(find(rendered, "sess-wrap-aaa1"), "cancel closes the strip")

-- Return saves the rename (the host sends it to onKey, not the input).
click("ren-aaa1")
find(rendered, "ren-input-aaa1-3").props.onChange("Via return")
local nl, nr = #launched, #renames
onKey("Return", true)
eq(#renames, nr + 1, "Return renames"); eq(renames[nr + 1][1], "aaa1", "Return rename id")
eq(renames[nr + 1][2], "Via return", "Return rename title")
eq(#launched, nl, "Return while renaming launches nothing")
click("ren-aaa1")
onKey("KP_Enter", true)
eq(#renames, nr + 1, "blank draft renames nothing"); eq(#launched, nl, "blank draft launches nothing")
click("ren-no-aaa1")

-- Draft cap: 130 characters (multibyte) are stored as 120.
click("ren-aaa1")
find(rendered, "ren-input-aaa1-5").props.onChange(string.rep("é", 130))
local capped = find(rendered, "ren-input-aaa1-5").props.value
eq(utf8.len(capped), 120, "draft capped at 120 characters")
find(rendered, "ren-input-aaa1-5").props.onChange("\255\254bad")
click("ren-no-aaa1")

-- Delete: memory notice only for the last session of its project dir.
local n0 = #notes
lastInProject, memoryKept = false, true
click("del-aaa1"); click("del-ok-aaa1")
eq(#notes, n0, "no notice for a non-last session")
lastInProject = true
click("del-bbb2"); click("del-ok-bbb2")
eq(notes[#notes], "memory_kept(dir=-p-bbb2)", "memory notice")

-- Orphans.
orphanResult = {}
n0 = #notes
click("sess-orphans")
eq(checkedIds[1], "beef", "live ids passed"); eq(#checkedIds, 1, "only live ids")
eq(notes[#notes], "orphans_none", "none notice")
assert(find(rendered, "confirm-orphans") == nil, "no strip for zero orphans")
orphanResult = {
    { kind = "project", path = "/x/a", bytes = 1048576 },
    { kind = "session-env", path = "/x/b", bytes = 1048576 },
}
click("sess-orphans")
local strip = find(rendered, "confirm-orphans")
assert(strip, "orphan strip")
click("sess-refresh")
assert(find(rendered, "confirm-orphans") == nil, "refresh drops the orphan strip")
click("sess-orphans")
strip = find(rendered, "confirm-orphans")
assert(has(strip, function(n) return n.props.text == "orphans_confirm(mb=2.0,n=2)" end), "count and size")
before = refreshes
click("orphans-ok")
eq(removed, orphanResult, "removeOrphans gets the list")
assert(refreshes > before, "orphan removal reloads")
assert(find(rendered, "confirm-orphans") == nil, "strip closed")

print("panel_sessions_test ok")
