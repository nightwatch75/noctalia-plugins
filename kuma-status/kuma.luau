--!nonstrict
-- kuma-status — pure data functions (no noctalia.* access, testable without
-- the host). Parsing of Kuma's /metrics text, /api/monitors (Kuma 3) and the
-- public status-page JSON, plus URL validation. Everything that reaches the UI
-- passes through safeText: monitor names are untrusted text.
--
-- Types (informal):
--   Metric     = { id, name, type, url?, status, ping?, uptime1d?, certDays?, tags }
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

-- Hot path (a production /metrics is ~250 KB and the host gives a callback
-- ~25 ms): lines of series we do not use are skipped on a cheap prefix test,
-- and labels are parsed only on the first line of each monitor (the label set
-- is the same on all its series). Lines holding a backslash (escaped quote or
-- newline in a value) take the slow character scanner above.
local USED = {
    monitor_status = true, monitor_response_time = true,
    monitor_uptime_ratio = true, monitor_cert_days_remaining = true,
}

local function labelsOf(l)
    if l:find("\\", 1, true) == nil then
        local labels = {}
        for k, v in l:gmatch('([%w_]+)="([^"]*)"') do labels[k] = v end
        return labels
    end
    local _, labels = parseSeries(l)
    return labels
end

function K.parseMetrics(text: string)
    local byId = {}
    for l in (text or ""):gmatch("[^\n]+") do
        local metric = l:match("^([%w_]+){")
        if metric ~= nil and USED[metric] and (metric ~= "monitor_uptime_ratio" or l:find('window="1d"', 1, true)) then
            local id = tonumber(l:match('monitor_id="(%d+)"'))
            local value = tonumber(l:match("}%s+(%S+)%s*$"))
            if id ~= nil and value ~= nil and value == value then
                local m = byId[id]
                if m == nil then
                    local labels = labelsOf(l)
                    if labels ~= nil then
                        local tags = {}
                        for key in pairs(labels) do
                            if not RESERVED[key] then tags[#tags + 1] = K.safeText(key, MAX_NAME) end
                        end
                        table.sort(tags)
                        -- what the check hits: the URL, else host[:port]
                        local url = labels.monitor_url
                        if url == nil or url == "" or url == "null" then
                            url = nil
                            local host = labels.monitor_hostname
                            if host ~= nil and host ~= "" and host ~= "null" then
                                url = host
                                local port = labels.monitor_port
                                if port ~= nil and port ~= "" and port ~= "null" then url = host .. ":" .. port end
                            end
                        end
                        m = {
                            id = id,
                            name = K.safeText(labels.monitor_name or "", MAX_NAME),
                            type = K.safeText(labels.monitor_type or "", 40),
                            url = url and K.safeText(url, 200) or nil,
                            tags = tags,
                        }
                        byId[id] = m
                    end
                end
                if m ~= nil then
                    if metric == "monitor_status" then
                        m.status = value
                    elseif metric == "monitor_response_time" then
                        if value >= 0 then m.ping = value end
                    elseif metric == "monitor_uptime_ratio" then
                        m.uptime1d = value
                    else
                        m.certDays = value
                    end
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
    host = host:lower()
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

-- Samples kept for monitors that no status page covers: the last `cap`
-- statuses, oldest first.
function K.pushSample(buffer, id: number, status: number, cap: number)
    local b = buffer[id]
    if b == nil then
        b = {}
        buffer[id] = b
    end
    b[#b + 1] = status
    while #b > cap do table.remove(b, 1) end
end

-- Overall state for the bar. Groups are containers, not checks, so they are
-- not counted. Maintenance (3) is neither up nor down: it keeps the color
-- green but adds to no counter. No series at all is "idle", never green.
function K.summarize(metrics)
    local s = { up = 0, down = 0, pending = 0, color = "idle", downNames = {} }
    local seen = 0
    for _, m in pairs(metrics) do
        if m.type ~= "group" then
            seen += 1
            if m.status == 1 then
                s.up += 1
            elseif m.status == 0 then
                s.down += 1
                s.downNames[#s.downNames + 1] = m.name
            elseif m.status == 2 then
                s.pending += 1
            end
        end
    end
    table.sort(s.downNames)
    if s.down > 0 then
        s.color = "down"
    elseif s.pending > 0 then
        s.color = "pending"
    elseif seen > 0 then
        s.color = "up"
    end
    return s
end

local function byName(a, b)
    local x, y = a.name:lower(), b.name:lower()
    if x ~= y then return x < y end
    return a.id < b.id
end

-- Rows come from /metrics; a monitor known only from the structure (Kuma 3)
-- is paused: Kuma exports no series for a paused monitor.
local function makeRow(id, m, struct, beats, buffer)
    local b = beats[id]
    if b == nil or #b == 0 then b = buffer[id] or {} end
    if m ~= nil then
        return { id = id, name = m.name, status = m.status, ping = m.ping, beats = b, paused = false, url = m.url, certDays = m.certDays }
    end
    return { id = id, name = struct.name, status = -1, beats = b, paused = true }
end

local function makeGroup(id, name, rows, metrics)
    table.sort(rows, byName)
    local g = { id = id, name = name, up = 0, total = 0, rows = rows }
    local sum, n = 0, 0
    for _, r in ipairs(rows) do
        if not r.paused then
            g.total += 1
            if r.status == 1 or r.status == 3 then g.up += 1 end
            local u = metrics[r.id] and metrics[r.id].uptime1d
            if u ~= nil then
                sum += u
                n += 1
            end
        end
    end
    if n > 0 then g.uptime1d = sum / n end
    return g
end

-- Groups for the Dashboard tab. With a Kuma 3 structure the groups are the
-- real group monitors (nested ones named "Parent / Child"); without it, one
-- group per tag (a multi-tag monitor appears in several) and an unnamed group
-- last for what has no group or tag; opts.firstTagOnly puts a monitor only in
-- its first tag (tags are sorted, so alphabetical). Counts here are per group; the bar uses
-- summarize, which counts every monitor once.
function K.buildDashboard(metrics, structure, beats, buffer, opts)
    local groups = {}
    if structure ~= nil then
        local function fullName(id)
            local st, parts, guard = structure[id], {}, 0
            while st ~= nil and guard < 20 do
                table.insert(parts, 1, st.name)
                st = st.parent and structure[st.parent] or nil
                guard += 1
            end
            return table.concat(parts, " / ")
        end
        local placed, loose = {}, {}
        local ids = {}
        for id, st in pairs(structure) do
            if st.type == "group" then ids[#ids + 1] = id end
        end
        local named = {}
        for _, id in ipairs(ids) do
            local rows = {}
            for _, c in ipairs(structure[id].children) do
                local cs = structure[c]
                if cs ~= nil and cs.type ~= "group" then
                    rows[#rows + 1] = makeRow(c, metrics[c], cs, beats, buffer)
                    placed[c] = true
                end
            end
            named[#named + 1] = { name = fullName(id), id = id, rows = rows }
        end
        table.sort(named, function(a, b) return a.name:lower() < b.name:lower() end)
        for _, g in ipairs(named) do groups[#groups + 1] = makeGroup(g.id, g.name, g.rows, metrics) end
        for id, st in pairs(structure) do
            if st.type ~= "group" and not placed[id] then
                loose[#loose + 1] = makeRow(id, metrics[id], st, beats, buffer)
            end
        end
        for id, m in pairs(metrics) do
            if m.type ~= "group" and structure[id] == nil then
                loose[#loose + 1] = makeRow(id, m, nil, beats, buffer)
            end
        end
        if #loose > 0 then groups[#groups + 1] = makeGroup(nil, "", loose, metrics) end
        return { mode = "hierarchy", groups = groups }
    end
    local byTag, untagged, names = {}, {}, {}
    local firstOnly = opts ~= nil and opts.firstTagOnly == true
    for id, m in pairs(metrics) do
        if m.type ~= "group" then
            local r = makeRow(id, m, nil, beats, buffer)
            if #m.tags == 0 then
                untagged[#untagged + 1] = r
            end
            for i, t in ipairs(m.tags) do
                if i == 1 or not firstOnly then
                    if byTag[t] == nil then
                        byTag[t] = {}
                        names[#names + 1] = t
                    end
                    table.insert(byTag[t], r)
                end
            end
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    for _, t in ipairs(names) do groups[#groups + 1] = makeGroup(nil, t, byTag[t], metrics) end
    if #untagged > 0 then groups[#groups + 1] = makeGroup(nil, "", untagged, metrics) end
    return { mode = "tags", groups = groups }
end

return K
