-- Sessions tab row actions of panel.luau, with the host and sessions.luau
-- stubbed: status icons, Moved/Orphan filters, resume and copy from the real
-- folder, repair of a misplaced transcript, rename, the
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
        status = "ok", projectDir = "-p-" .. id, cwd = "/p", cwdKnown = true, resolvedCwd = "", hasMemory = false }
    for k, v in pairs(fields or {}) do s[k] = v end
    s.runCwd = s.runCwd or s.cwd
    return s
end
local A = session("aaa1", { cwd = "/tmp/o'neil" })
local B = session("bbb2", { status = "misplaced" })
local C = session("ccc3", { status = "orphan", cwd = "/gone", hasMemory = true })
local D = session("ddd4", { status = "relocated", resolvedCwd = "/real", runCwd = "/real" })
local E = session("eee5", { status = "orphan", cwd = "/gone2" })
local LIVE = session("beef")
local GUESS = session("fff6", { cwdKnown = false })
local projects = {
    { cwd = "/p", lastActivity = 100, sessions = { A, B, C, D, E, LIVE, GUESS } },
}

local refreshes, renames, deletes = 0, {}, {}
local repairs, repairResult, repairCode = {}, true, nil
local lastInProject, memoryKept = true, true
local orphanResult, checkedIds, removed
local sessionsStub = {
    refresh = function(cb) refreshes += 1; cb(projects, nil) end,
    isLastInProject = function() return lastInProject end,
    memoryKept = function() return memoryKept end,
    deleteSession = function(s, done) table.insert(deletes, s.id); done(true) end,
    repairSession = function(s, done) table.insert(repairs, s.id); done(repairResult, repairCode) end,
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

-- Status rows: one glyph per status with the reason; resume only for ok/relocated.
local function glyphOf(key)
    local row = find(rendered, key)
    for _, c in ipairs(row.children) do if c.kind == "glyph" then return c.props end end
end
assert(find(rendered, "status-aaa1") == nil, "ok row has no status glyph")
eq(find(rendered, "status-ddd4").props.tooltip, "status_relocated(path=/real)", "relocated tooltip")
eq(glyphOf("status-ddd4").name, "folder-symlink", "relocated glyph")
eq(glyphOf("status-ddd4").color, "on_surface_variant", "relocated color")
eq(find(rendered, "status-ccc3").props.tooltip, "status_orphan_memory", "orphan tooltip with memory")
eq(find(rendered, "status-eee5").props.tooltip, "status_orphan", "orphan tooltip")
eq(glyphOf("status-ccc3").name, "folder-off", "orphan glyph"); eq(glyphOf("status-ccc3").color, "error", "orphan color")
eq(find(rendered, "status-bbb2").props.tooltip, "status_misplaced", "misplaced tooltip")
eq(glyphOf("status-bbb2").name, "alert-triangle", "misplaced glyph"); eq(glyphOf("status-bbb2").color, "tertiary", "misplaced color")
click("resume-bbb2")
eq(#launched, 0, "misplaced resume launches nothing")
eq(errors[1], "err_resume_refused(reason=resume_reason_misplaced)", "misplaced resume error")
click("resume-ccc3")
eq(#launched, 0, "orphan resume launches nothing")
eq(errors[2], "err_resume_refused(reason=resume_reason_orphan)", "orphan resume error")
click("resume-aaa1")
eq(#launched, 1, "ok row resumes")
eq(launched[1], "cd '/tmp/o'\\''neil' && exec claude --resume 'aaa1'", "ok resume cwd")
click("resume-ddd4")
eq(#launched, 2, "relocated row resumes")
eq(launched[2], "cd '/real' && exec claude --resume 'ddd4'", "relocated resumes from the real folder")

-- Moved / Orphan filters: one at a time, combined with Empty and search.
eq(find(rendered, "sort-moved").props.text, "1", "moved count")
eq(find(rendered, "sort-moved").props.glyph, "folder-symlink", "moved glyph")
eq(find(rendered, "sort-orphan").props.text, "3", "orphan count (orphan + misplaced)")
eq(find(rendered, "sort-orphan").props.glyph, "folder-off", "orphan filter glyph")
eq(find(rendered, "sort-moved").props.tooltip, "tip_filter_moved", "moved tooltip")
eq(find(rendered, "sort-orphan").props.tooltip, "tip_filter_orphan", "orphan tooltip")
click("sort-moved")
assert(find(rendered, "sort-moved").props.selected, "moved selected")
assert(find(rendered, "resume-ddd4") and find(rendered, "resume-aaa1") == nil and find(rendered, "resume-bbb2") == nil, "moved only")
click("sort-orphan")
assert(not find(rendered, "sort-moved").props.selected, "orphan replaces moved")
assert(find(rendered, "resume-bbb2") and find(rendered, "resume-ccc3") and find(rendered, "resume-eee5"), "orphan + misplaced shown")
assert(find(rendered, "resume-ddd4") == nil and find(rendered, "resume-aaa1") == nil, "others hidden")
click("sort-empty")
assert(find(rendered, "resume-bbb2") == nil, "combined with Empty")
click("sort-empty")
click("sort-orphan")
assert(find(rendered, "resume-aaa1") and find(rendered, "resume-ddd4"), "filter off shows all")

-- Copy resume command: from runCwd, never for an orphan.
click("copy-aaa1")
eq(clips[1][1], "cd '/tmp/o'\\''neil' && claude --resume aaa1", "copied text")
eq(clips[1][2], "text/plain", "copied mime")
eq(notes[#notes], "copied_resume", "copy notice")
click("copy-ddd4")
eq(clips[2][1], "cd '/real' && claude --resume ddd4", "relocated copy uses the real folder")
assert(find(rendered, "copy-bbb2"), "misplaced session with real cwd can copy")
assert(find(rendered, "copy-ccc3") == nil, "no copy for an orphan")
assert(find(rendered, "copy-fff6") == nil, "no copy for a guessed cwd")

-- Repair: only misplaced, never a live session; inline strip; confirm repairs then reloads.
assert(find(rendered, "repair-bbb2"), "repair button on misplaced")
eq(find(rendered, "repair-bbb2").props.glyph, "arrows-exchange", "repair glyph")
eq(find(rendered, "repair-bbb2").props.tooltip, "tip_repair_session", "repair tooltip")
for _, k in ipairs({ "repair-ccc3", "repair-ddd4", "repair-aaa1", "repair-eee5" }) do
    assert(find(rendered, k) == nil, "no repair: " .. k)
end
LIVE.status = "misplaced"
watchers.live({ groups = { count = 1, waiting = {}, idle = {}, busy = { { id = "beef" } } } })
assert(find(rendered, "repair-beef") == nil, "no repair for a live session")
LIVE.status = "ok"
click("repair-bbb2")
assert(find(rendered, "sess-wrap-bbb2-rep"), "wrapper key changes while the strip is open")
assert(has(find(rendered, "confirm-repair-bbb2"), function(n) return n.props.text == "repair_confirm(cwd=/p)" end), "strip text")
click("repair-no-bbb2")
assert(find(rendered, "confirm-repair-bbb2") == nil, "cancel closes")
click("repair-bbb2")
click("sess-refresh")
assert(find(rendered, "confirm-repair-bbb2") == nil, "refresh closes the strip")
click("repair-bbb2")
local r0 = refreshes
click("repair-ok-bbb2")
eq(repairs[1], "bbb2", "repairSession called"); assert(refreshes > r0, "repair reloads")
eq(notes[#notes], "repair_done", "done notice")
assert(find(rendered, "confirm-repair-bbb2") == nil, "strip closed after repair")
repairResult, repairCode = false, "exists"
click("repair-bbb2"); click("repair-ok-bbb2")
eq(errors[#errors], "err_repair_failed(reason=err_repair_exists)", "failure notice")
for code, key in pairs({ same_dir = "err_repair_same_dir", mkdir = "err_repair_mkdir", sidecar = "err_repair_sidecar",
    move = "err_repair_move", unsafe = "err_repair_unsafe", not_absolute = "err_repair_not_absolute",
    status = "err_repair_status", cwd_missing = "err_repair_cwd_missing" }) do
    repairCode = code
    click("repair-bbb2"); click("repair-ok-bbb2")
    eq(errors[#errors], "err_repair_failed(reason=" .. key .. ")", "notice for " .. code)
end
repairCode = "weird"
click("repair-bbb2"); click("repair-ok-bbb2")
eq(errors[#errors], "err_repair_generic", "unknown code falls back")
click("repair-bbb2")
eq(find(rendered, "repair-ok-bbb2").props.text, "repair_yes", "confirm label")
click("repair-no-bbb2")
repairResult, repairCode = true, nil

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

-- Orphan details list.
local function texts(n, out)
    out = out or {}
    if n.props and n.props.text then table.insert(out, n.props.text) end
    for _, c in ipairs(n.children or {}) do texts(c, out) end
    return out
end
local function orphRows()
    local list = find(rendered, "orph-list")
    local rows = {}
    if list then
        for _, c in ipairs(list.children or {}) do
            if c.props.key and c.props.key:find("^orph%-row%-") then table.insert(rows, c) end
        end
    end
    return rows
end
orphanResult = {
    { kind = "session-env", path = "/x/small", bytes = 10, mtime = 1, reason = "no_transcript" },
    { kind = "project", path = "/x/big", bytes = 5000, mtime = 1, reason = "weird_code" },
    { kind = "file-history", path = "/x/11111111-1111-1111-1111-111111111111", bytes = 900, mtime = 1, reason = "no_transcript" },
}
click("sess-orphans")
assert(find(rendered, "orph-list") == nil, "list hidden at first")
click("orphans-toggle")
local rows = orphRows()
eq(#rows, 3, "three rows")
eq(#find(rendered, "orph-list").children, 3, "no more button")
assert(find(rendered, "orph-more") == nil, "no button for a short list")
assert(has(rows[1], function(n) return n.props.text == "big" end), "bytes desc: big first")
assert(has(rows[2], function(n) return n.props.text == "11111111…" end), "uuid truncated")
assert(has(rows[2], function(n) return n.props.tooltip == "/x/11111111-1111-1111-1111-111111111111" end), "full path tooltip")
assert(has(rows[3], function(n) return n.props.text == "small" end), "small last")
assert(has(rows[2], function(n) return n.props.text == "orphan_reason_no_transcript" end), "known reason shown")
assert(has(rows[3], function(n) return n.props.text == "orphan_kind_session_env" end), "kind label")
for _, t in ipairs(texts(rows[1])) do assert(not t:find("^orphan_reason_"), "unknown reason shows no line") end
click("orphans-toggle")
assert(find(rendered, "orph-list") == nil, "toggle hides")
click("orphans-toggle")
assert(find(rendered, "orph-list"), "toggle shows again")
click("sess-refresh")
click("sess-orphans")
assert(find(rendered, "orph-list") == nil, "refresh then rescan hides the list")
click("orphans-toggle")
click("sess-refresh")
assert(find(rendered, "orph-list") == nil and find(rendered, "confirm-orphans") == nil, "refresh resets")

orphanResult = {}
for i = 1, 150 do
    table.insert(orphanResult, { kind = "project", path = "/x/p" .. i, bytes = i, mtime = 1, reason = "project_empty" })
end
click("sess-orphans")
click("orphans-toggle")
eq(#orphRows(), 20, "first page is 20 rows")
local lst = find(rendered, "orph-list")
eq(#lst.children, 21, "20 rows plus button")
local more = find(rendered, "orph-more")
eq(more.props.text, "show_more(n=20,total=130)", "button text")
assert(has(lst.children[1], function(n) return n.props.text == "p150" end), "largest first")
eq(#orphanResult, 150, "input list not reordered or cut")
more.props.onClick()
eq(#orphRows(), 40, "click adds 20")
find(rendered, "orph-more").props.onClick()
eq(#orphRows(), 60, "second click adds 20")
click("orphans-toggle")
click("orphans-toggle")
eq(#orphRows(), 20, "hide and show resets the page")
click("orph-more")
click("orph-more")
click("orphans-ok")
eq(#removed, 150, "all 150 removed, not only the shown ones")

-- Paging down to the end.
orphanResult = {}
for i = 1, 50 do
    table.insert(orphanResult, { kind = "project", path = "/x/q" .. i, bytes = i, mtime = 1 })
end
click("sess-refresh")
click("sess-orphans")
click("orphans-toggle")
eq(find(rendered, "orph-more").props.text, "show_more(n=20,total=30)", "20 of 30")
click("orph-more")
eq(#orphRows(), 40, "40 rows")
eq(find(rendered, "orph-more").props.text, "show_more(n=10,total=10)", "10 of 10")
click("orph-more")
eq(#orphRows(), 50, "all rows")
assert(find(rendered, "orph-more") == nil, "button gone when all shown")
click("sess-refresh")
click("sess-orphans")
click("orphans-toggle")
eq(#orphRows(), 20, "refresh resets the page")

-- Size units, stable order, no bogus age, same-UUID keys.
local function openOrphans(list)
    click("sess-refresh")
    orphanResult = list
    click("sess-orphans")
    click("orphans-toggle")
    return orphRows()
end
local function hasText(row, text) return has(row, function(n) return n.props.text == text end) end
local rs = openOrphans({
    { kind = "project", path = "/x/a", bytes = 3, mtime = 1 },
    { kind = "project", path = "/x/b", bytes = 1536, mtime = 1 },
    { kind = "project", path = "/x/c", bytes = 3 * 1048576, mtime = 1 },
})
assert(hasText(rs[1], "3.0 MB"), "MB range")
assert(hasText(rs[2], "1.5 KB"), "KB range")
assert(hasText(rs[3], "3 B"), "B range")

rs = openOrphans({
    { kind = "project", path = "/x/c", bytes = 5, mtime = 1 },
    { kind = "project", path = "/x/a", bytes = 5, mtime = 1 },
    { kind = "project", path = "/x/b", bytes = 5, mtime = 1 },
})
for i, name in ipairs({ "a", "b", "c" }) do assert(hasText(rs[i], name), "tiebreak on path: " .. name) end

rs = openOrphans({
    { kind = "project", path = "/x/nomtime", bytes = 1 },
    { kind = "project", path = "/x/zero", bytes = 1, mtime = 0 },
})
for _, r in ipairs(rs) do
    for _, t in ipairs(texts(r)) do assert(not t:find("^time_"), "no age without mtime") end
end

local U = "22222222-2222-2222-2222-222222222222"
rs = openOrphans({
    { kind = "session-env", path = "/h/session-env/" .. U, bytes = 1, mtime = 1 },
    { kind = "file-history", path = "/h/file-history/" .. U, bytes = 1, mtime = 1 },
})
eq(#rs, 2, "two rows")
assert(rs[1].props.key ~= rs[2].props.key, "distinct keys for the same UUID")

print("panel_sessions_test ok")
