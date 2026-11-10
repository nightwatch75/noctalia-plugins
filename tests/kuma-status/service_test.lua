-- module: service.luau kuma.luau pages_store.luau
-- service.luau against a fake noctalia host: recorded http calls, canned
-- responses, in-memory shared state. All data synthetic. Run through
-- tests/kuma-status/run.sh.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end

local function series(metric, id, name, value, extra)
    return metric .. '{monitor_id="' .. id .. '",monitor_name="' .. name .. '",monitor_type="http",monitor_url="https://x.example.test/",monitor_hostname="null",monitor_port="null"' .. (extra or "") .. "} " .. value
end
local METRICS = table.concat({
    series("monitor_status", 1, "svc-a", 1), series("monitor_status", 2, "svc-b", 0),
    series("monitor_response_time", 1, "svc-a", 12),
}, "\n")

local DECODED = {
    badmonitors = { monitors = { 1 } },
    badpage = { config = { title = "x" }, publicGroupList = { 1 } },
    monitors = { monitors = {
        { id = 10, name = "grp", type = "group", active = true, childrenIDs = { 1, 2 }, tags = {} },
        { id = 1, name = "svc-a", type = "http", active = true, parent = 10, childrenIDs = {}, tags = {} },
        { id = 2, name = "svc-b", type = "http", active = true, parent = 10, childrenIDs = {}, tags = {} },
    } },
    page = { config = { title = "Board" }, publicGroupList = { { name = "G", monitorList = { { id = 1, name = "svc-a" } } } } },
    beats = { heartbeatList = { ["1"] = { { status = 1 }, { status = 0 } } } },
}

-- Boots service.luau with fake globals. cfg overrides defaults; respond(req)
-- returns a response table or nil (= network failure).
local function boot(cfg, respond, files)
    local H = { calls = {}, state = {}, watchers = {}, cfg = cfg, files = files or {} }
    local defaults = {
        kuma_url = "https://kuma.example.test", api_key = "KEY-SECRET", proxy_user = "", proxy_password = "",
        status_pages = {}, kuma3_support = false, refresh_seconds = 60,
    }
    for k, v in pairs(cfg) do defaults[k] = v end
    H.cfg = defaults
    noctalia = {
        getConfig = function(k) return H.cfg[k] end,
        tr = function(k) return k end,
        pluginDataDir = function() return "/data" end,
        readFile = function(p) return H.files[p] end,
        writeFile = function(p, c) H.files[p] = c; return true end,
        setUpdateInterval = function() end,
        json = { decode = function(s) return DECODED[s], DECODED[s] == nil and "bad json" or nil end },
        http = function(req, cb)
            H.calls[#H.calls + 1] = req
            local r = respond(req)
            if r == "HOLD" then return true end -- never answers: a stalled server
            if r == nil then r = { ok = false, status = 0, body = "" } end
            cb(r)
            return true
        end,
        state = {
            set = function(k, v)
                H.state[k] = v
                for _, w in ipairs(H.watchers[k] or {}) do w(v) end
            end,
            get = function(k) return H.state[k] end,
            watch = function(k, w) H.watchers[k] = H.watchers[k] or {}; table.insert(H.watchers[k], w) end,
        },
    }
    local kuma = loadstring(MODULES["kuma.luau"])()
    local store = loadstring(MODULES["pages_store.luau"])()
    require = function(p) if p:find("pages_store") then return store end return kuma end
    onConfigChanged = nil
    update = nil
    loadstring(MODULE_SRC)()
    function H.refresh(n) noctalia.state.set("kuma_status_request", { nonce = n, action = "refresh" }) end
    function H.data() return H.state["kuma_status_data"] end
    function H.count(suffix)
        local n = 0
        for _, c in ipairs(H.calls) do if c.url:sub(-#suffix) == suffix then n += 1 end end
        return n
    end
    return H
end

local function ok(body) return { ok = true, status = 200, body = body } end
local function standard(req)
    if req.url:sub(-8) == "/metrics" then return ok(METRICS) end
    if req.url:sub(-13) == "/api/monitors" then return ok("monitors") end
    if req.url:find("/api/status%-page/heartbeat/") then return ok("beats") end
    if req.url:find("/api/status%-page/") then return ok("page") end
    return { ok = true, status = 404, body = "" }
end

-- test: no_calls_without_url
local h = boot({ kuma_url = "", status_pages = {} }, standard)
eq(#h.calls, 0, "no calls without a URL")
eq(h.data().summary.color, "offline", "unconfigured is offline")
eq(h.data().errors.metrics, "error.no_url", "reason shown")

-- test: metrics_uses_basic_with_key
h = boot({}, standard)
eq(h.calls[1].url, "https://kuma.example.test/metrics", "metrics url")
eq(h.calls[1].basic_username, "kuma", "basic user")
eq(h.calls[1].basic_password, "KEY-SECRET", "basic password is the key")
eq(h.data().summary.up, 1, "parsed up"); eq(h.data().summary.down, 1, "parsed down")
eq(h.data().mode, "tags", "tags mode without kuma 3")

-- test: api_monitors_skipped_when_kuma3_off
eq(h.count("/api/monitors"), 0, "no /api/monitors when the toggle is off")

-- test: api_monitors_bearer_when_on
h = boot({ kuma3_support = true }, standard)
local mon
for _, c in ipairs(h.calls) do if c.url:sub(-13) == "/api/monitors" then mon = c end end
eq(mon ~= nil, true, "called")
eq(mon.headers[1], "Authorization: Bearer KEY-SECRET", "bearer header")
eq(h.data().mode, "hierarchy", "hierarchy mode")
eq(h.data().dashboard.groups[1].name, "grp", "group from structure")

-- test: api_monitors_404_disables_for_session
h = boot({ kuma3_support = true }, function(req)
    if req.url:sub(-13) == "/api/monitors" then return { ok = true, status = 404, body = "" } end
    return standard(req)
end)
eq(h.data().errors.monitors, "error.v3_api_off", "reason shown")
eq(h.data().mode, "tags", "falls back to tags")
h.refresh(1)
eq(h.count("/api/monitors"), 1, "not called again this session")

-- test: status_page_gets_proxy_pair_only_for_listed_hosts
h = boot({ status_pages = { "https://status.example.test/status/dev" }, proxy_user = "pu", proxy_password = "pp" }, standard)
local pageCalls = 0
for _, c in ipairs(h.calls) do
    if c.url:find("^https://status.example.test/") then
        pageCalls += 1
        eq(c.basic_username, "pu", "proxy user on status page"); eq(c.basic_password, "pp", "proxy password on status page")
    else
        eq(c.basic_password, "KEY-SECRET", "kuma call carries the key, never the proxy pair")
    end
end
eq(pageCalls, 2, "page + heartbeat")
eq(h.data().pages[1].title, "Board", "page parsed")
eq(table.concat(h.data().dashboard.groups[1].rows[1].beats, ","), "1,0", "beats from the status page")

-- test: key_never_sent_to_status_page_host
for _, c in ipairs(h.calls) do
    if c.url:find("^https://status.example.test/") then
        eq(c.basic_password == "KEY-SECRET", false, "key on status page host")
        for _, line in ipairs(c.headers or {}) do eq(line:find("KEY-SECRET", 1, true), nil, "key in header") end
    end
end

-- test: 401_on_one_page_does_not_stop_others
local A, B = "https://a.example.test/status/dev", "https://b.example.test/status/dev"
h = boot({ status_pages = { A, B } }, function(req)
    if req.url:find("^https://a.example.test/") then return { ok = true, status = 401, body = "" } end
    return standard(req)
end)
eq(h.data().errors.pages[A], "error.unauthorized", "A reported")
eq(#h.data().pages, 1, "B still parsed")
eq(h.data().pages[1].url, "https://b.example.test/status/dev", "B")
local aBefore = h.count("/api/status-page/dev")
h.refresh(1)
eq(h.count("/api/status-page/dev"), aBefore + 1, "only B is requested again")

-- test: 401_on_metrics_stops_calls_until_config_changes
h = boot({}, function(req)
    if req.url:sub(-8) == "/metrics" then return { ok = true, status = 401, body = "" } end
    return standard(req)
end)
eq(h.data().errors.metrics, "error.unauthorized", "reason shown"); eq(h.data().summary.color, "offline", "offline")
h.refresh(1)
eq(h.count("/metrics"), 1, "blocked: no second call")
onConfigChanged()
eq(h.count("/metrics"), 2, "config change retries")

-- test: refresh_request_nonce_ignored_twice
h = boot({}, standard)
h.refresh(5); h.refresh(5)
eq(h.count("/metrics"), 2, "initial + one refresh, second nonce ignored")

-- test: state_lists_page_urls_and_sources
local U = "https://status.example.test/status/Dev"
h = boot({ status_pages = { U } }, standard)
eq(h.data().pageUrls[1], U, "configured URL kept as typed")
eq(h.data().pages[1].source, U, "page remembers the URL it came from")

-- test: metrics_200_that_is_not_prometheus_is_an_error
h = boot({}, function(req)
    if req.url:sub(-8) == "/metrics" then return ok("<html>login</html>") end
    return standard(req)
end)
eq(h.data().errors.metrics, "error.bad_metrics", "html answer is reported")
eq(h.data().summary.color, "offline", "offline, not idle")

-- test: metrics_help_lines_only_is_idle_not_an_error
h = boot({}, function(req)
    if req.url:sub(-8) == "/metrics" then return ok("# HELP monitor_status Monitor Status\n# TYPE monitor_status gauge") end
    return standard(req)
end)
eq(h.data().errors.metrics, nil, "all paused is not an error")
eq(h.data().summary.color, "idle", "idle")

-- test: timer_does_not_restart_a_cycle_in_flight
h = boot({ refresh_seconds = 20 }, function(req)
    if req.url:sub(-8) == "/metrics" then return "HOLD" end
    return standard(req)
end)
for _ = 1, 45 do update() end
eq(h.count("/metrics"), 1, "stalled cycle is not restarted by the timer")

-- test: wrong_shape_json_is_reported_and_cycle_still_publishes
h = boot({ kuma3_support = true, status_pages = { "https://status.example.test/status/dev" } }, function(req)
    if req.url:sub(-13) == "/api/monitors" then return ok("badmonitors") end
    if req.url:find("/api/status%-page/heartbeat/") then return ok("beats") end
    if req.url:find("/api/status%-page/") then return ok("badpage") end
    return standard(req)
end)
eq(h.data() ~= nil, true, "published despite wrong shapes")
eq(h.data().errors.monitors, "error.bad_json", "monitors shape")
eq(h.data().errors.pages["https://status.example.test/status/dev"], "error.bad_json", "page shape")
eq(h.data().summary.up, 1, "metrics still shown")

-- test: plain_http_flag_counts_failed_pages
h = boot({ status_pages = { "http://status.example.test/status/dev" } }, function(req)
    if req.url:find("^http://status.example.test/") then return { ok = true, status = 401, body = "" } end
    return standard(req)
end)
eq(h.data().plainHttp, true, "a failed http page still sent the proxy password in clear")

-- test: added_pages_are_merged_with_settings_without_duplicates
local SET, ADD = "https://a.example.test/status/dev", "https://b.example.test/status/dev"
h = boot({ status_pages = { SET } }, function(req) return standard(req) end)
eq(h.count("/api/status-page/dev"), 1, "settings page only")
h.files["/data/status_pages.txt"] = ADD .. "\n" .. SET .. "\n"
h.refresh(1)
eq(h.data().pageUrls[1], SET, "settings first"); eq(h.data().pageUrls[2], ADD, "then added"); eq(#h.data().pageUrls, 2, "duplicate dropped")
eq(h.data().addedUrls[1], ADD, "added list published for the panel")

-- test: tag_view_defaults_to_first_tag_and_switches_without_network
local function multiTag(req)
    if req.url:sub(-8) == "/metrics" then
        return ok(table.concat({
            series("monitor_status", 1, "svc-a", 1, ',x="",y=""'),
            series("monitor_status", 2, "svc-b", 1, ',y=""'),
        }, "\n"))
    end
    return standard(req)
end
h = boot({}, multiTag)
eq(h.data().tagMode, "first", "default view")
eq(#h.data().dashboard.groups[1].rows + #h.data().dashboard.groups[2].rows, 2, "each monitor once")
local calls = #h.calls
noctalia.state.set("kuma_status_request", { nonce = 9, action = "tag_mode", value = "all" })
eq(h.data().tagMode, "all", "switched")
eq(#h.data().dashboard.groups[2].rows, 2, "duplicates back: y holds both")
eq(#h.calls, calls, "no new network call")

-- test: tag_view_choice_is_remembered
h = boot({}, multiTag)
noctalia.state.set("kuma_status_request", { nonce = 3, action = "tag_mode", value = "all" })
eq(h.files["/data/tag_mode.txt"], "all", "choice saved")
h = boot({}, multiTag, { ["/data/tag_mode.txt"] = "all" })
eq(h.data().tagMode, "all", "restored at start")
h = boot({}, multiTag, { ["/data/tag_mode.txt"] = "junk" })
eq(h.data().tagMode, "first", "unknown content falls back to the default")

print("service_test OK")
