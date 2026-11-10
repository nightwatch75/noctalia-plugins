--!nonstrict
-- kuma-status — singleton engine: all network, parsing and buffering.
--
-- Runs once however many bars show the widget. The widget and the panel are
-- pure renderers wired through the plugin's shared state:
--   engine publishes  "kuma_status_data"    = { nonce, ts, summary, dashboard?,
--                       pages (each with .source = the URL as configured),
--                       pageUrls (setting + panel-added URLs, deduped),
--                       addedUrls (the panel-added ones), errors = { metrics?, monitors?, pages = {[url]=msg} },
--                       mode = "hierarchy"|"tags", baseUrl, plainHttp }
--                     summary.color is "offline" when /metrics is unusable.
--                     certs (Certificates tab: groups by expiry level).
--   UI entries send   "kuma_status_request" = { nonce, action = "refresh" }
--                     or { nonce, action = "tag_mode", value = "first"|"all" }
--                     (rebuilds the grouping from the last data, no network;
--                     a nonce already seen is ignored).
--
-- Sources per cycle (refresh_seconds, default 60):
--   /metrics            Basic, user "kuma", password = the API key (status, ping, tags)
--   /api/monitors       Bearer API key, only with kuma3_support (Kuma 3 hierarchy)
--   status pages        <origin>/api/status-page/<slug> and .../heartbeat/<slug>,
--                       Basic with the global proxy user/password when set
-- Secrets never live in the settings: api_key_file and proxy_password_file hold
-- the PATH of a file, read like noctalia's own credential_source = "file" (absolute
-- path, regular file, 1 byte to 64 KiB, no NUL, one trailing LF/CRLF ignored, never
-- written here) and re-read every cycle, so a secret manager can rotate it. A file
-- readable by group/other raises credWarn (checked with stat at start and on
-- settings changes). Values stay in locals: never in the shared state, logs or
-- notifications.
-- The API key goes to kuma_url only; the proxy pair goes to the hosts of the
-- listed status pages only. A 401/403 blocks that source until the settings
-- change; a 404 on /api/monitors switches Kuma 3 support off for the session;
-- any other failure is retried on the next cycle. A source that fails never
-- clears the others. Callbacks decode and parse inline: the host budget is
-- ~25 ms per callback (measured in the budget test, Task 7).
-- Monitors that no listed status page covers get their history from a
-- 40-sample buffer fed by /metrics; it lives in memory only.

local K = require("./kuma.luau")
local store = require("./pages_store.luau")

local MAX_CRED = 65536 -- noctalia rejects larger credential files
local STATE_KEY = "kuma_status_data"
local REQUEST_KEY = "kuma_status_request"
local BUFFER_CAP = 40

local gen = 0        -- bumps per cycle and on config change; stale callbacks drop themselves
local nonce = 0
local seenRequest = nil
local elapsed = 0
local inFlight = false -- a cycle is waiting for answers; the timer must not restart it
local v3Off = false  -- /api/monitors answered 404: stop asking this session
local blocked = { metrics = false, monitors = false, pages = {} }
local reasons = { pages = {} } -- text shown for blocked sources
local buffer = {}
local credWarn = false -- a credentials file is readable by group/other
local publish           -- defined below; checkPermissions republishes through it
-- "first": a monitor in its first tag only; "all": in every tag. The choice is
-- kept in the plugin data folder (tag_mode.txt) across restarts.
local function modeFile()
    local dir = noctalia.pluginDataDir()
    return dir and (dir .. "/tag_mode.txt") or nil
end
local function loadTagMode()
    local f = modeFile()
    local saved = f and noctalia.readFile(f) or nil
    return (saved ~= nil and saved:match("^%s*all")) and "all" or "first"
end
local tagMode = "first"
local last = nil         -- inputs of the last publish, to rebuild the view without network

local function tr(key, args)
    return noctalia.tr(key, args)
end

-- Ordered tag names from the group_tags setting (blank entries dropped).
local function groupTagList()
    local setting = noctalia.getConfig("group_tags")
    local out = {}
    for _, t in ipairs(type(setting) == "table" and setting or {}) do
        if type(t) == "string" then
            t = t:match("^%s*(.-)%s*$")
            if t ~= "" then out[#out + 1] = t end
        end
    end
    return out
end

local function readConfig()
    -- the setting first, then pages added from the panel; one entry per page
    local pages, seen = {}, {}
    local function add(url)
        if type(url) ~= "string" then return end
        local origin, slug = K.statusPageUrl(url)
        local key = origin and (origin .. "/status/" .. slug) or url
        if not seen[key] then
            seen[key] = true
            pages[#pages + 1] = url
        end
    end
    local setting = noctalia.getConfig("status_pages")
    for _, url in ipairs(type(setting) == "table" and setting or {}) do add(url) end
    local added = store.load()
    for _, url in ipairs(added) do add(url) end
    local interval = tonumber(noctalia.getConfig("refresh_seconds")) or 60
    return {
        base = K.baseUrl(noctalia.getConfig("kuma_url") or ""),
        keyFile = noctalia.getConfig("api_key_file") or "",
        proxyUser = noctalia.getConfig("proxy_user") or "",
        proxyFile = noctalia.getConfig("proxy_password_file") or "",
        pages = pages,
        added = added,
        groupTags = groupTagList(),
        v3 = noctalia.getConfig("kuma3_support") == true,
        interval = math.min(3600, math.max(20, interval))
    }
end

-- Reads a credential file: (value) or (nil, errorKey). "empty" means no path set.
local function readCredential(path)
    if path == "" then return nil, "empty" end
    if path:sub(1, 1) ~= "/" then return nil, "error.cred_path" end
    local info = noctalia.fileInfo(path)
    if info == nil or info.isDir then return nil, "error.cred_unreadable" end
    if info.size < 1 or info.size > MAX_CRED then return nil, "error.cred_invalid" end
    local text = noctalia.readFile(path)
    if text == nil then return nil, "error.cred_unreadable" end
    if text:find("\0", 1, true) then return nil, "error.cred_invalid" end
    text = (text:gsub("\r?\n$", ""))
    if text == "" then return nil, "error.cred_invalid" end
    return text, nil
end

-- Warn when a configured credentials file is readable by group or other.
local function checkPermissions(cfg)
    local warn, pending, started = false, 0, 0
    local function check(path)
        if path:sub(1, 1) ~= "/" then return end
        pending += 1
        started += 1
        noctalia.runAsync({ "stat", "-c", "%a", path }, function(r)
            local mode = r and r.exitCode == 0 and tostring(r.stdout or ""):match("%d+") or nil
            if mode ~= nil and #mode >= 2 and mode:sub(-2) ~= "00" then warn = true end
            pending -= 1
            if pending == 0 and warn ~= credWarn then
                credWarn = warn
                if last ~= nil then publish(table.unpack(last)) end
            end
        end)
    end
    check(cfg.keyFile)
    check(cfg.proxyFile)
    if started == 0 then credWarn = false end
end

-- Maps an http response to (body) or (nil, message, hard) where `hard` marks a
-- 401/403 that should block the source.
local function classify(r)
    if not r.ok then return nil, tr("error.offline"), false end
    if r.status == 401 or r.status == 403 then return nil, tr("error.unauthorized"), true end
    if r.status == 404 then return nil, tr("error.not_found"), false end
    if r.status ~= 200 then return nil, tr("error.http", { status = r.status }), false end
    return r.body, nil, false
end

function publish(cfg, metrics, structure, beatsById, pages, errors)
    nonce += 1
    local summary = K.summarize(metrics or {})
    if metrics == nil then summary.color = "offline" end
    last = { cfg, metrics, structure, beatsById, pages, errors }
    local dashboard = nil
    if metrics ~= nil then
        dashboard = K.buildDashboard(metrics, structure, beatsById, buffer, { firstTagOnly = tagMode == "first", groupTags = cfg.groupTags })
    end
    -- from the configured URLs, so a page that failed still flags clear text
    local plain = cfg.base ~= nil and cfg.base:sub(1, 7) == "http://"
    for _, url in ipairs(cfg.pages) do
        if type(url) == "string" and url:lower():sub(1, 7) == "http://" then plain = true end
    end
    noctalia.state.set(STATE_KEY, {
        nonce = nonce,
        ts = os.time(),
        summary = summary,
        dashboard = dashboard,
        pages = pages,
        pageUrls = cfg.pages,
        addedUrls = cfg.added,
        errors = errors,
        mode = structure ~= nil and "hierarchy" or "tags",
        tagMode = tagMode,
        credWarn = credWarn,
        certs = metrics ~= nil and K.buildCertificates(metrics) or nil,
        baseUrl = cfg.base or "",
        plainHttp = plain,
    })
end

local function refresh()
    gen += 1
    local mine = gen
    elapsed = 0
    local cfg = readConfig()
    local errors = { pages = {} }
    if cfg.base == nil then
        errors.metrics = tr("error.no_url")
        inFlight = false
        publish(cfg, nil, nil, {}, {}, errors)
        return
    end
    inFlight = true

    -- Credentials come from files, fresh every cycle. A source blocked by a 401
    -- stays blocked only while the secret that was refused is still the one in
    -- the file, so rotating the secret unblocks it without touching settings.
    local key, keyErr = readCredential(cfg.keyFile)
    local proxyPw, proxyErr = "", nil
    if cfg.proxyUser ~= "" and cfg.proxyFile ~= "" then
        proxyPw, proxyErr = readCredential(cfg.proxyFile)
    end

    local metrics, structure = nil, nil
    local pageResults = {} -- [index] = StatusPage
    local pending = 1      -- guard: held until every request is issued

    local function finish()
        pending -= 1
        if pending > 0 or mine ~= gen then return end
        inFlight = false
        local pages, beatsById = {}, {}
        for i = 1, #cfg.pages do
            local sp = pageResults[i]
            if sp ~= nil then
                pages[#pages + 1] = sp
                for _, g in ipairs(sp.groups) do
                    for _, m in ipairs(g.monitors) do
                        if beatsById[m.id] == nil and #m.beats > 0 then beatsById[m.id] = m.beats end
                    end
                end
            end
        end
        if metrics ~= nil then
            for id, m in pairs(metrics) do
                if m.type ~= "group" and beatsById[id] == nil then
                    K.pushSample(buffer, id, m.status, BUFFER_CAP)
                end
            end
        end
        publish(cfg, metrics, structure, beatsById, pages, errors)
    end

    local function request(req, cb)
        pending += 1
        local sent = noctalia.http(req, function(r)
            -- a throwing handler must not leave the cycle without its finish()
            if mine == gen then pcall(cb, r) end
            finish()
        end)
        if not sent then
            pending -= 1
            cb({ ok = false, status = 0, body = "" })
        end
    end

    -- /metrics
    if key == nil then
        errors.metrics = keyErr == "empty" and tr("error.no_key") or tr(keyErr)
    elseif blocked.metrics == key then
        errors.metrics = reasons.metrics
    else
        request({ url = cfg.base .. "/metrics", basic_username = "kuma", basic_password = key }, function(r)
            local body, msg, hard = classify(r)
            if body == nil then
                errors.metrics = msg
                if hard then
                    blocked.metrics = key
                    reasons.metrics = msg
                end
            elseif body:find("monitor_status", 1, true) == nil then
                -- an HTML login page or a wrong path also answers 200; even with
                -- every monitor paused Kuma still lists its monitor_* HELP lines
                errors.metrics = tr("error.bad_metrics")
            else
                metrics = K.parseMetrics(body)
            end
        end)
    end

    -- /api/monitors (Kuma 3)
    if cfg.v3 then
        if v3Off then
            errors.monitors = reasons.monitors
        elseif key ~= nil and blocked.monitors == key then
            errors.monitors = reasons.monitors
        elseif key ~= nil then
            request({ url = cfg.base .. "/api/monitors", headers = { "Authorization: Bearer " .. key } }, function(r)
                if r.ok and r.status == 404 then
                    v3Off = true
                    reasons.monitors = tr("error.v3_api_off")
                    errors.monitors = reasons.monitors
                    return
                end
                local body, msg, hard = classify(r)
                if body == nil then
                    errors.monitors = msg
                    if hard then
                        blocked.monitors = key
                        reasons.monitors = msg
                    end
                    return
                end
                local decoded = noctalia.json.decode(body)
                local parsed, res = pcall(K.parseMonitors, decoded)
                if type(decoded) == "table" and parsed then
                    structure = res
                else
                    errors.monitors = tr("error.bad_json")
                end
            end)
        end
    end

    -- status pages
    for i, url in ipairs(cfg.pages) do
        local origin, slug = K.statusPageUrl(url)
        if origin == nil then
            errors.pages[url] = tr("error.bad_url")
        elseif proxyErr ~= nil then
            errors.pages[url] = tr(proxyErr)
        elseif blocked.pages[url] ~= nil and blocked.pages[url] == proxyPw then
            errors.pages[url] = reasons.pages[url]
        else
            local got = { left = 2 }
            local function done()
                got.left -= 1
                if got.left > 0 then return end
                if got.err ~= nil then
                    errors.pages[url] = got.err
                    if got.hard then
                        blocked.pages[url] = proxyPw
                        reasons.pages[url] = got.err
                    end
                    return
                end
                local page = noctalia.json.decode(got.page)
                local hb = noctalia.json.decode(got.hb)
                local parsed, res = pcall(K.parseStatusPage, page, hb, origin, slug)
                if type(page) == "table" and type(hb) == "table" and parsed then
                    pageResults[i] = res
                    pageResults[i].source = url
                else
                    errors.pages[url] = tr("error.bad_json")
                end
            end
            local function pageRequest(path, field)
                local req = { url = origin .. path .. slug }
                if cfg.proxyUser ~= "" then
                    req.basic_username = cfg.proxyUser
                    req.basic_password = proxyPw
                end
                request(req, function(r)
                    local body, msg, hard = classify(r)
                    if body == nil then
                        got.err, got.hard = got.err or msg, got.hard or hard
                    else
                        got[field] = body
                    end
                    done()
                end)
            end
            pageRequest("/api/status-page/", "page")
            pageRequest("/api/status-page/heartbeat/", "hb")
        end
    end

    finish()
end

tagMode = loadTagMode()
local request0 = noctalia.state.get(REQUEST_KEY)
if type(request0) == "table" then seenRequest = request0.nonce end
noctalia.state.watch(REQUEST_KEY, function(req)
    if type(req) ~= "table" or req.nonce == seenRequest then return end
    seenRequest = req.nonce
    if req.action == "refresh" then
        refresh()
    elseif req.action == "tag_mode" and (req.value == "first" or req.value == "all") then
        tagMode = req.value
        local f = modeFile()
        if f then noctalia.writeFile(f, tagMode) end
        if last ~= nil then publish(table.unpack(last)) end
    end
end)

function update()
    elapsed += 1
    if not inFlight and elapsed >= readConfig().interval then refresh() end
end

-- Settings changed: forget every block and the 404 verdict, ask again now.
function onConfigChanged()
    blocked = { metrics = false, monitors = false, pages = {} }
    reasons = { pages = {} }
    v3Off = false
    checkPermissions(readConfig())
    refresh()
end

function onExit()
    gen += 1
end

noctalia.setUpdateInterval(1000)
checkPermissions(readConfig())
refresh()
