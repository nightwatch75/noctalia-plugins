--!nonstrict
-- kuma-status — pure data functions (no noctalia.* access, testable without
-- the host). Parsing of Kuma's /metrics text, /api/monitors (Kuma 3) and the
-- public status-page JSON, plus URL validation. Everything that reaches the UI
-- passes through safeText: monitor names are untrusted text.
--
-- Types (informal):
--   Metric     = { id, name, type, status, ping?, uptime1d?, certDays?, tags }
--   Structure  = { id, name, type, parent?, children, tags, active }
--   StatusPage = { slug, title, url, groups = { { name, monitors = { { id, name, beats } } } } }
-- Status codes everywhere: 0 down, 1 up, 2 pending, 3 maintenance.

local K = {}

local MAX_NAME = 80
local BEATS = 40

-- Labels that describe the monitor itself; every other label of a /metrics
-- series is a Kuma tag (tag name as label name, value empty or free).
local RESERVED = {
    monitor_id = true, monitor_name = true, monitor_type = true, monitor_url = true,
    monitor_hostname = true, monitor_port = true, window = true,
}

-- Controls become spaces, invalid UTF-8 bytes become "?", then the text is cut
-- to `max` characters on a character boundary (utf8.codes would throw on
-- invalid input, so validity is checked first).
function K.safeText(s: string, max: number): string
    s = tostring(s or ""):gsub("[\0-\31\127]", " ")
    if utf8.len(s) == nil then
        s = s:gsub("[\128-\255]", "?")
    end
    if utf8.len(s) > max then
        s = s:sub(1, utf8.offset(s, max + 1) - 1)
    end
    return s
end

-- One Prometheus series line: name{k="v",...} value. Label values may hold
-- escaped quotes, backslashes and newlines, so the label block is scanned
-- character by character instead of with a pattern.
local function parseSeries(l: string)
    local brace = l:find("{", 1, true)
    if brace == nil then return nil end
    local metric = l:sub(1, brace - 1)
    local labels = {}
    local i, n = brace + 1, #l
    while i <= n do
        local c = l:sub(i, i)
        if c == "}" then break end
        if c == "," or c == " " then
            i += 1
        else
            local eq = l:find("=", i, true)
            if eq == nil or l:sub(eq + 1, eq + 1) ~= '"' then return nil end
            local key = l:sub(i, eq - 1)
            local buf = {}
            i = eq + 2
            while i <= n and l:sub(i, i) ~= '"' do
                local ch = l:sub(i, i)
                if ch == "\\" then
                    i += 1
                    ch = l:sub(i, i)
                    if ch == "n" then ch = "\n" end
                end
                buf[#buf + 1] = ch
                i += 1
            end
            if i > n then return nil end
            labels[key] = table.concat(buf)
            i += 1
        end
    end
    local value = tonumber(l:sub(i + 1):match("^%s*(%S+)"))
    if value == nil or value ~= value then return nil end
    return metric, labels, value
end

function K.parseMetrics(text: string)
    local byId = {}
    for l in (text or ""):gmatch("[^\n]+") do
        if l:sub(1, 1) ~= "#" then
            local metric, labels, value = parseSeries(l)
            local id = labels and tonumber(labels.monitor_id)
            if id ~= nil and metric:sub(1, 8) == "monitor_" then
                local m = byId[id]
                if m == nil then
                    local tags = {}
                    for key in pairs(labels) do
                        if not RESERVED[key] then tags[#tags + 1] = K.safeText(key, MAX_NAME) end
                    end
                    table.sort(tags)
                    m = {
                        id = id,
                        name = K.safeText(labels.monitor_name or "", MAX_NAME),
                        type = K.safeText(labels.monitor_type or "", 40),
                        tags = tags,
                    }
                    byId[id] = m
                end
                if metric == "monitor_status" then
                    m.status = value
                elseif metric == "monitor_response_time" then
                    if value >= 0 then m.ping = value end
                elseif metric == "monitor_uptime_ratio" then
                    if labels.window == "1d" then m.uptime1d = value end
                elseif metric == "monitor_cert_days_remaining" then
                    m.certDays = value
                end
            end
        end
    end
    -- Series order in the text puts status last; a monitor without it is noise.
    for id, m in pairs(byId) do
        if m.status == nil then byId[id] = nil end
    end
    return byId
end

-- Input is the decoded body of GET /api/monitors: { monitors = { ... } }.
function K.parseMonitors(decoded: any)
    local out = {}
    local list = type(decoded) == "table" and decoded.monitors or {}
    for _, x in ipairs(list) do
        local id = tonumber(x.id)
        if id ~= nil then
            local children, tags = {}, {}
            for _, c in ipairs(x.childrenIDs or {}) do
                if tonumber(c) ~= nil then children[#children + 1] = tonumber(c) end
            end
            for _, t in ipairs(x.tags or {}) do
                if type(t) == "table" and t.name ~= nil then tags[#tags + 1] = K.safeText(t.name, MAX_NAME) end
            end
            out[id] = {
                id = id,
                name = K.safeText(x.name or "", MAX_NAME),
                type = K.safeText(x.type or "", 40),
                parent = tonumber(x.parent),
                children = children,
                tags = tags,
                active = x.active == true,
            }
        end
    end
    return out
end

-- scheme://host[:port] plus the rest of the URL, or nil. Only http and https;
-- no credentials, spaces, query or fragment in the host part.
local function splitUrl(url)
    if type(url) ~= "string" or url:find("%s") then return nil end
    local scheme, rest = url:match("^(%a+)://(.*)$")
    if scheme == nil then return nil end
    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then return nil end
    local host, path = rest:match("^([^/]*)(.*)$")
    if host == "" or not host:match("^[%w%.%-%[%]:]+$") then return nil end
    return scheme, host, (path:gsub("/+$", ""))
end

function K.baseUrl(url: string): string?
    local scheme, host, path = splitUrl(url)
    if scheme == nil or path:find("[?#]") then return nil end
    return scheme .. "://" .. host .. path
end

function K.statusPageUrl(url: string)
    local scheme, host, path = splitUrl(url)
    if scheme == nil then return nil, nil, "not an http(s) URL" end
    local slug = path:match("^/status/([%w_%-]+)$")
    if slug == nil then return nil, nil, "expected https://host/status/<slug>" end
    return scheme .. "://" .. host, slug:lower(), nil
end

function K.parseStatusPage(page: any, heartbeats: any, origin: string, slug: string)
    local cfg = type(page) == "table" and page.config or {}
    local lists = type(heartbeats) == "table" and heartbeats.heartbeatList or {}
    local sp = {
        slug = slug,
        title = K.safeText(cfg.title or slug, MAX_NAME),
        url = origin .. "/status/" .. slug,
        groups = {},
    }
    for _, g in ipairs(type(page) == "table" and page.publicGroupList or {}) do
        local group = { name = K.safeText(g.name or "", MAX_NAME), monitors = {} }
        for _, mon in ipairs(g.monitorList or {}) do
            local id = tonumber(mon.id)
            if id ~= nil then
                local src = lists[tostring(id)] or lists[id] or {}
                local beats = {}
                for i = math.max(1, #src - BEATS + 1), #src do
                    local st = tonumber(type(src[i]) == "table" and src[i].status)
                    if st ~= nil then beats[#beats + 1] = st end
                end
                group.monitors[#group.monitors + 1] = {
                    id = id, name = K.safeText(mon.name or "", MAX_NAME), beats = beats,
                }
            end
        end
        sp.groups[#sp.groups + 1] = group
    end
    return sp
end

return K
