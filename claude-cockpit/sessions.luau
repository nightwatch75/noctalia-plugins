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

local PROJECTS_DIR = noctalia.expandPath("~/.claude/projects")
M.GLOBAL_CLAUDE_MD = noctalia.expandPath("~/.claude/CLAUDE.md")

local scriptPath = `{noctalia.pluginDir()}/list-claude-sessions`

-- Best-effort decode of an encoded project dir name back to a path, used
-- ONLY when a session never states its own cwd (a "bridge-session"-only stub
-- with no real turn in it — list-claude-sessions still lists it). The
-- encoding (every "/" becomes "-") is not reversible in general — a project
-- whose real path contains a literal "-" cannot be told apart from an
-- encoded "/" — so this is a DISPLAY fallback only, never used to build a
-- path an action (resume, delete, open CLAUDE.md) runs against; those always
-- use the session's own recorded paths.
local function decodeProjectDir(encoded)
    if type(encoded) ~= "string" or encoded == "" or encoded:sub(1, 1) ~= "-" then
        return nil
    end
    return "/" .. encoded:sub(2):gsub("%-", "/")
end

-- One session record from the script, reshaped for the panel: a stable
-- label (the AI title, else the last prompt cut short, else the id) plus
-- the jsonl path and subagent sidecar dir a delete acts on.
local function shapeSession(raw, cwd)
    local id = raw.id
    local lastPrompt = (type(raw.lastPrompt) == "string") and raw.lastPrompt or ""
    local label = raw.title
    if type(label) ~= "string" or label == "" then
        if lastPrompt ~= "" then
            label = (#lastPrompt > 72) and (lastPrompt:sub(1, 72) .. "…") or lastPrompt
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
        label = label,
        lastPrompt = lastPrompt,
        jsonlPath = PROJECTS_DIR .. "/" .. dir .. "/" .. id .. ".jsonl",
        sidecarDir = PROJECTS_DIR .. "/" .. dir .. "/" .. id,
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

-- Deletes one session's transcript and its subagent sidecar dir (if any), as
-- a direct argv exec — no shell in the way, so no shellQuote is needed and
-- `rm` needs no commandExists guard (it ships on every Linux install).
function M.deleteSession(session, done)
    local ok = noctalia.runAsync({ "rm", "-rf", "--", session.jsonlPath, session.sidecarDir }, function(result)
        done(type(result) == "table" and result.exitCode == 0)
    end)
    if not ok then
        done(false)
    end
end

return M
