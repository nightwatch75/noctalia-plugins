--!nonstrict
-- sessions — pure data module: runs list-claude-sessions and shapes its flat
-- output into project groups the panel renders. No UI state, no closures
-- over caller state (same rule todo/storage.luau follows) — the panel alone
-- owns what is expanded, searched or being confirmed.
--
-- Never polled: M.refresh is called from the panel's onOpen and its refresh
-- button only. A "project" here is a distinct cwd a session was run from —
-- NOT literally a `~/.claude/projects/<encoded>/` directory, though most of
-- the time they line up 1:1; see decodeProjectDir for the one case they
-- don't (a session that states no cwd at all).

local M = {}

local HOME = noctalia.expandPath("~")
local PROJECTS_DIR = noctalia.expandPath("~/.claude/projects")
local SESSION_ENV_DIR = noctalia.expandPath("~/.claude/session-env")
local FILE_HISTORY_DIR = noctalia.expandPath("~/.claude/file-history")
M.GLOBAL_CLAUDE_MD = noctalia.expandPath("~/.claude/CLAUDE.md")

local scriptPath = `{noctalia.pluginDir()}/list-claude-sessions`
local findClaudeMdPath = `{noctalia.pluginDir()}/find-claude-md`

-- Best-effort decode of an encoded project dir name, used ONLY when a
-- session never states its own cwd. Not reversible in general (a literal
-- "-" in a path is indistinguishable from an encoded "/"), so this is a
-- display fallback only — actions always use the session's recorded paths.
local function decodeProjectDir(encoded)
    if type(encoded) ~= "string" or encoded == "" or encoded:sub(1, 1) ~= "-" then
        return nil
    end
    return "/" .. encoded:sub(2):gsub("%-", "/")
end

-- One session record from the script, reshaped for the panel: a stable
-- label (AI title, else opening prompt cut short, else the id) plus the
-- jsonl path and subagent sidecar dir a delete acts on. `firstPrompt` stays
-- its own field, untruncated, for the panel's preview.
local function shapeSession(raw, cwd)
    local id = raw.id
    local aiTitle = (type(raw.title) == "string") and raw.title or ""
    local customTitle = (type(raw.customTitle) == "string") and raw.customTitle or ""
    local firstPrompt = (type(raw.firstPrompt) == "string") and raw.firstPrompt or ""
    local label = (customTitle ~= "") and customTitle or aiTitle
    if label == "" then
        if firstPrompt ~= "" then
            label = (#firstPrompt > 72) and (firstPrompt:sub(1, 72) .. "…") or firstPrompt
        else
            label = noctalia.tr("session_untitled", { id = id:sub(1, 8) })
        end
    end
    local dir = tostring(raw.projectDir or "")
    return {
        id = id,
        cwd = cwd,
        gitBranch = (type(raw.gitBranch) == "string" and raw.gitBranch ~= "") and raw.gitBranch or nil,
        mtime = tonumber(raw.mtime) or 0,
        size = tonumber(raw.size) or 0,
        empty = raw.empty == true, -- no user turn: opened and closed without a prompt
        label = label,
        firstPrompt = firstPrompt,
        -- Model + context size from the session's last assistant turn; 0/""
        -- for a session with no assistant turn yet.
        model = (type(raw.model) == "string") and raw.model or "",
        contextTokens = tonumber(raw.contextTokens) or 0,
        projectDir = dir,
        status = (type(raw.status) == "string" and raw.status ~= "") and raw.status or "ok",
        jsonlPath = PROJECTS_DIR .. "/" .. dir .. "/" .. id .. ".jsonl",
        sidecarDir = PROJECTS_DIR .. "/" .. dir .. "/" .. id,
        sessionEnvDir = SESSION_ENV_DIR .. "/" .. id,
        fileHistoryDir = FILE_HISTORY_DIR .. "/" .. id,
        memoryDir = PROJECTS_DIR .. "/" .. dir .. "/memory",
        projectPath = PROJECTS_DIR .. "/" .. dir,
    }
end

-- Groups the flat session list by resolved cwd, sorted most-recent-first
-- both within a project and across projects.
function M.groupByProject(rawSessions)
    local byCwd = {}
    local order = {}
    for _, raw in ipairs(rawSessions) do
        local cwd = raw.cwd
        if type(cwd) ~= "string" or cwd == "" then
            cwd = decodeProjectDir(raw.projectDir) or noctalia.tr("unknown_project")
        end
        local group = byCwd[cwd]
        if group == nil then
            group = { cwd = cwd, claudeMdPath = cwd .. "/CLAUDE.md", sessions = {}, lastActivity = 0 }
            byCwd[cwd] = group
            table.insert(order, group)
        end
        local session = shapeSession(raw, cwd)
        table.insert(group.sessions, session)
        if session.mtime > group.lastActivity then
            group.lastActivity = session.mtime
        end
    end
    for _, group in ipairs(order) do
        table.sort(group.sessions, function(a, b)
            return a.mtime > b.mtime
        end)
    end
    table.sort(order, function(a, b)
        return a.lastActivity > b.lastActivity
    end)
    return order
end

-- Runs list-claude-sessions and hands the grouped project list to
-- done(projects, err) — err is nil on success.
function M.refresh(done)
    local ok = noctalia.runAsync(`bash '{scriptPath}'`, function(result)
        if type(result) ~= "table" or result.success == false or result.exitCode ~= 0 then
            done(nil, noctalia.tr("err_sessions_fetch"))
            return
        end
        local data = noctalia.json.decode(result.stdout or "")
        if type(data) ~= "table" or type(data.sessions) ~= "table" then
            done(nil, noctalia.tr("err_sessions_data"))
            return
        end
        done(M.groupByProject(data.sessions), nil)
    end)
    if not ok then
        done(nil, noctalia.tr("err_sessions_launch"))
    end
end

-- True when no other session shares this session's ~/.claude/projects dir,
-- i.e. deleting it leaves the project dir empty apart from memory/.
function M.isLastInProject(projects, session)
    for _, group in ipairs(projects) do
        for _, other in ipairs(group.sessions) do
            if other.id ~= session.id and other.projectDir == session.projectDir then
                return false
            end
        end
    end
    return true
end

function M.memoryKept(session)
    return noctalia.fileExists(session.memoryDir) == true
end

-- Ids become path parts under rm -rf: only hex and dashes, never "." or "/".
local function validId(id)
    return type(id) == "string" and id:match("^[%x-]+$") ~= nil
end

-- Deletes one session's transcript, subagent sidecar, session-env and
-- file-history, as a direct argv exec — no shell in the way, so no
-- shellQuote is needed. The follow-up rmdir only removes the (now empty)
-- memory and project dirs and fails harmlessly when they hold anything, so
-- its result is ignored and `done` reports the rm alone.
function M.deleteSession(session, done)
    if not validId(session.id) then
        done(false)
        return
    end
    local ok = noctalia.runAsync({
        "rm", "-rf", "--", session.jsonlPath, session.sidecarDir, session.sessionEnvDir, session.fileHistoryDir,
    }, function(result)
        local success = type(result) == "table" and result.exitCode == 0
        if success then
            noctalia.runAsync({ "rmdir", "--", session.memoryDir, session.projectPath }, function() end)
        end
        done(success)
    end)
    if not ok then
        done(false)
    end
end

-- Appends a custom-title record, the same line /rename writes, so Claude
-- Code and list-claude-sessions both pick it up. The snippet first adds a
-- newline if the transcript lacks a final one, so the record never glues
-- onto the last line.
M.RENAME_SH = 'f="$1"; [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && printf "\\n" >> "$f"; printf "%s\\n" "$2" >> "$f"'

function M.renameSession(session, title, done)
    if not validId(session.id) then
        done(false)
        return
    end
    title = title:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
    if title == "" or utf8.len(title) == nil or utf8.len(title) > 120 then
        done(false)
        return
    end
    local line = noctalia.json.encode({ type = "custom-title", customTitle = title, sessionId = session.id })
    local ok = noctalia.runAsync({ "sh", "-c", M.RENAME_SH, "sh", session.jsonlPath, line }, function(result)
        done(type(result) == "table" and result.exitCode == 0)
    end)
    if not ok then
        done(false)
    end
end

-- ── Orphan leftovers ─────────────────────────────────────────────────────
-- list-claude-orphans is read-only; removal happens here, after every path
-- is re-validated in Lua, as direct argv execs (no shell).

local orphansPath = `{noctalia.pluginDir()}/list-claude-orphans`
local UUID_PAT = ("%x"):rep(8) .. ("%-" .. ("%x"):rep(4)):rep(3) .. "%-" .. ("%x"):rep(12)

-- Scans for orphans, keeping every id in liveIds. done(orphans, err).
function M.checkOrphans(liveIds, done)
    local argv = { "bash", orphansPath }
    for _, id in ipairs(liveIds) do
        if validId(id) then
            table.insert(argv, "--exclude")
            table.insert(argv, id)
        end
    end
    local ok = noctalia.runAsync(argv, function(result)
        if type(result) ~= "table" or result.success == false or result.exitCode ~= 0 then
            done(nil, noctalia.tr("err_sessions_fetch"))
            return
        end
        local data = noctalia.json.decode(result.stdout or "")
        if type(data) ~= "table" or type(data.orphans) ~= "table" then
            done(nil, noctalia.tr("err_sessions_data"))
            return
        end
        done(data.orphans, nil)
    end)
    if not ok then
        done(nil, noctalia.tr("err_sessions_launch"))
    end
end

-- The orphan's own name when its path is exactly <parent>/<name> with a
-- clean name, else nil.
local function childName(path, parent)
    if type(path) ~= "string" or path:sub(1, #parent + 1) ~= parent .. "/" then
        return nil
    end
    local name = path:sub(#parent + 2)
    if name == "" or name == "." or name == ".." or name:find("/", 1, true) or name:find("%c") then
        return nil
    end
    return name
end

-- Removes the orphans checkOrphans returned. All-or-nothing validation first:
-- one bad entry refuses the whole batch and nothing runs.
function M.removeOrphans(orphans, done)
    local idPaths, projects = {}, {}
    for _, o in ipairs(orphans) do
        local kind = type(o) == "table" and o.kind
        if kind == "session-env" or kind == "file-history" then
            local name = childName(o.path, kind == "session-env" and SESSION_ENV_DIR or FILE_HISTORY_DIR)
            if not name or not name:match("^" .. UUID_PAT .. "$") then
                done(false)
                return
            end
            table.insert(idPaths, o.path)
        elseif kind == "project" then
            if not childName(o.path, PROJECTS_DIR) then
                done(false)
                return
            end
            table.insert(projects, o.path)
        else
            done(false)
            return
        end
    end
    -- Sequential: id folders, then each project's (empty) memory dir, then the project dir.
    local function removeProjects()
        if #projects == 0 then
            done(true)
            return
        end
        local memories = {}
        for _, p in ipairs(projects) do
            table.insert(memories, p .. "/memory")
        end
        table.insert(memories, 1, "--")
        table.insert(memories, 1, "rmdir")
        -- A project without memory/ makes this rmdir fail harmlessly: ignored.
        local started = noctalia.runAsync(memories, function()
            local argv = { "rmdir", "--" }
            for _, p in ipairs(projects) do
                table.insert(argv, p)
            end
            if not noctalia.runAsync(argv, function(result)
                done(type(result) == "table" and result.exitCode == 0)
            end) then
                done(false)
            end
        end)
        if not started then
            done(false)
        end
    end
    if #idPaths == 0 then
        removeProjects()
        return
    end
    local argv = { "rm", "-rf", "--" }
    for _, p in ipairs(idPaths) do
        table.insert(argv, p)
    end
    local ok = noctalia.runAsync(argv, function(result)
        if type(result) == "table" and result.exitCode == 0 then
            removeProjects()
        else
            done(false)
        end
    end)
    if not ok then
        done(false)
    end
end

-- ── CLAUDE.md discovery ──────────────────────────────────────────────────
-- The Sessions/CLAUDE.md tabs otherwise only know about projects that have
-- run a Claude Code session — a real CLAUDE.md nested deeper, or sitting in
-- a directory nobody has run `claude` from yet, would never show up. This
-- scans $HOME for every one instead.

-- Filesystem types find-claude-md must never walk into: a stalled NFS/SMB/
-- sshfs share would otherwise stall (or badly slow down) a scan that is
-- meant to be a quick $HOME walk.
local REMOTE_FSTYPES = {
    nfs = true, nfs4 = true, cifs = true, smb = true, smbfs = true, smb3 = true,
    sshfs = true, ["fuse.sshfs"] = true, davfs = true, davfs2 = true, ["fuse.davfs"] = true,
    ftpfs = true, ["fuse.ftpfs"] = true, afpfs = true, ceph = true, glusterfs = true,
    ["9p"] = true, ["fuse.rclone"] = true,
}

-- Mount points of remote filesystems under `root`. /proc/mounts fields are
-- space-separated with a "\NNN" octal escape for space/tab in a path — same
-- convention file-search's fallbackMounts already decodes.
local function remoteMountsUnder(root)
    local text = noctalia.readFile("/proc/mounts")
    if type(text) ~= "string" then
        return {}
    end
    local prefix = root:gsub("/+$", "") .. "/"
    local found = {}
    for line in text:gmatch("[^\n]+") do
        local mountPoint, fstype = line:match("^%S+%s+(%S+)%s+(%S+)")
        if mountPoint ~= nil and REMOTE_FSTYPES[fstype] then
            local decoded = mountPoint:gsub("\\(%d%d%d)", function(octal)
                local code = tonumber(octal, 8)
                return (code ~= nil) and string.char(code) or ""
            end)
            if decoded == root or decoded:sub(1, #prefix) == prefix then
                table.insert(found, decoded)
            end
        end
    end
    return found
end

-- Every real CLAUDE.md under $HOME, skipping .git/node_modules/.cache/.venv
-- and any remote mount. done(paths, err) — err is nil on success.
function M.findClaudeMdFiles(done)
    local argv = { "bash", findClaudeMdPath, HOME }
    for _, mount in ipairs(remoteMountsUnder(HOME)) do
        table.insert(argv, mount)
    end
    local ok = noctalia.runAsync(argv, function(result)
        if type(result) ~= "table" or result.exitCode ~= 0 then
            done(nil, noctalia.tr("err_claudemd_scan"))
            return
        end
        local paths = {}
        for line in (result.stdout or ""):gmatch("[^\n]+") do
            table.insert(paths, line)
        end
        done(paths, nil)
    end, 60000)
    if not ok then
        done(nil, noctalia.tr("err_claudemd_scan"))
    end
end

return M
