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
        kuma_url = "https://kuma.example.test", api_key_file = "/secrets/api-key", proxy_user = "", proxy_password_file = "",
        status_pages = {}, kuma3_support = false, refresh_seconds = 60,
    }
    for k, v in pairs(cfg) do defaults[k] = v end
    H.cfg = defaults
    if #defaults.status_pages > 0 and files == nil then
        H.files["/data/status_pages.txt"] = table.concat(defaults.status_pages, "\n") .. "\n"
    end
    H.files["/secrets/api-key"] = H.files["/secrets/api-key"] or "KEY-SECRET\n"
    H.files["/secrets/proxy"] = H.files["/secrets/proxy"] or "pp\n"
    H.runs = {}
    H.toasts = {}
    H.stat = "600\n"
    noctalia = {
        getConfig = function(k) return H.cfg[k] end,
        tr = function(k) return k end,
        pluginDataDir = function() return "/data" end,
        readFile = function(p) return H.files[p] end,
        writeFile = function(p, c) H.files[p] = c; return true end,
        fileInfo = function(p)
            local c = H.files[p]
            if c == nil then return nil, "missing" end
            return { size = #c, mtime = 0, isDir = false }
        end,
        runAsync = function(argv, cb)
            H.runs[#H.runs + 1] = argv
            if cb then cb({ exitCode = 0, stdout = H.stat }) end
            return true
        end,
        setUpdateInterval = function() end,
        notify = function(t, b) H.toasts[#H.toasts + 1] = { t, b } end,
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
h = boot({ status_pages = { "https://status.example.test/status/dev" }, proxy_user = "pu", proxy_password_file = "/secrets/proxy", proxy_hosts = { "Status.Example.Test" } }, standard)
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

-- test: proxy_pair_not_sent_to_unlisted_hosts
local OTHER = "https://other.example.test/status/x"
h = boot({ status_pages = { OTHER }, proxy_user = "pu", proxy_password_file = "/secrets/proxy" }, standard)
for _, c in ipairs(h.calls) do
    if c.url:find("^https://other.example.test/") then
        eq(c.basic_username, nil, "no proxy user to an unlisted host"); eq(c.basic_password, nil, "no proxy password to an unlisted host")
    end
end
h = boot({ status_pages = { "https://kuma.example.test/status/x" }, proxy_user = "pu", proxy_password_file = "/secrets/proxy" }, standard)
eq(h.calls[2].basic_password, "pp", "the Kuma host itself gets the pair")

-- test: unlisted_host_401_names_the_cause
h = boot({ status_pages = { OTHER }, proxy_user = "pu", proxy_password_file = "/secrets/proxy" }, function(req)
    if req.url:find("^https://other.example.test/") then return { ok = true, status = 401, body = "" } end
    return standard(req)
end)
eq(h.data().errors.pages[OTHER], "error.unauthorized_host", "401 without the pair says why")

-- test: oversized_body_is_refused
h = boot({}, function(req)
    if req.url:sub(-8) == "/metrics" then return ok(string.rep("x", 1048577)) end
    return standard(req)
end)
eq(h.data().errors.metrics, "error.too_large", "metrics over 1 MiB refused")
eq(h.data().summary.color, "offline", "nothing parsed")

-- test: insecure_tls_only_when_enabled
h = boot({ status_pages = { "https://status.example.test/status/dev" } }, standard)
for _, c in ipairs(h.calls) do eq(c.allow_insecure_tls, nil, "verification on by default") end
eq(h.data().insecureTls, false, "not flagged")
h = boot({ insecure_tls = true, status_pages = { "https://status.example.test/status/dev" } }, standard)
for _, c in ipairs(h.calls) do eq(c.allow_insecure_tls, true, "toggle reaches every request") end
eq(h.data().insecureTls, true, "flagged for the panel")

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

-- test: pages_come_from_the_store_without_duplicates
local ADD = "https://b.example.test/status/dev"
h = boot({}, function(req) return standard(req) end)
eq(#h.data().pageUrls, 0, "no pages by default")
h.files["/data/status_pages.txt"] = ADD .. "\n" .. ADD .. "\n"
h.refresh(1)
eq(#h.data().pageUrls, 1, "duplicate dropped"); eq(h.data().pageUrls[1], ADD, "page listed")

-- test: state_changes_raise_toasts_and_alert
local down1 = false
local function flip(req)
    if req.url:sub(-8) == "/metrics" then
        return ok(table.concat({ series("monitor_status", 1, "svc-a", down1 and 0 or 1), series("monitor_status", 2, "svc-b", 0) }, "\n"))
    end
    return standard(req)
end
h = boot({ notify_changes = "toast_blink" }, flip)
eq(#h.toasts, 0, "svc-b was down at start: silent")
down1 = true
h.refresh(1); eq(#h.toasts, 0, "first down cycle: silent")
h.refresh(2)
eq(#h.toasts, 1, "second down cycle: one toast"); eq(h.toasts[1][1], "notify.down", "title"); eq(h.toasts[1][2], "svc-a", "body names the monitor")
eq(h.data().alertTs ~= nil, true, "alert time published for the bar")
down1 = false
h.refresh(3)
eq(#h.toasts, 2, "recovery toast"); eq(h.toasts[2][1], "notify.restored", "restored title")

-- test: notify_modes
down1 = false
h = boot({ notify_changes = "toast" }, flip)
down1 = true
h.refresh(1); h.refresh(2)
eq(#h.toasts, 1, "toast mode notifies"); eq(h.data().alertTs, nil, "but no blink")
down1 = false
h = boot({ notify_changes = "off" }, flip)
down1 = true
h.refresh(1); h.refresh(2)
eq(#h.toasts, 0, "off: no toast"); eq(h.data().alertTs, nil, "off: no blink")

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

-- test: credential_file_one_trailing_newline_stripped
for _, content in ipairs({ "K1\n", "K1\r\n", "K1" }) do
    h = boot({}, standard, { ["/secrets/api-key"] = content })
    eq(h.calls[1].basic_password, "K1", "key read from " .. string.format("%q", content))
end

-- test: credential_file_must_be_absolute_regular_and_sane
local function metricsError(path, files)
    local hh = boot({ api_key_file = path }, standard, files)
    eq(hh.count("/metrics"), 0, "no call with a bad key file: " .. path)
    return hh.data().errors.metrics
end
eq(metricsError("rel/key", {}), "error.cred_path", "relative path")
eq(metricsError("/secrets/none", { ["/secrets/api-key"] = "x" }), "error.cred_unreadable", "missing file")
eq(metricsError("/secrets/e", { ["/secrets/e"] = "\n" }), "error.cred_invalid", "empty after the newline")
eq(metricsError("/secrets/n", { ["/secrets/n"] = "a\0b" }), "error.cred_invalid", "NUL byte")
eq(metricsError("/secrets/big", { ["/secrets/big"] = string.rep("x", 65537) }), "error.cred_invalid", "over 64 KiB")
eq(metricsError("", {}), "error.no_key", "no file configured")

-- test: secrets_never_reach_the_published_state
h = boot({ status_pages = { "https://status.example.test/status/dev" }, proxy_user = "pu", proxy_password_file = "/secrets/proxy", kuma3_support = true }, standard)
local function leaks(v, depth)
    if depth > 8 then return false end
    if type(v) == "string" then return v:find("KEY-SECRET", 1, true) ~= nil or v == "pp" end
    if type(v) == "table" then
        for k, x in pairs(v) do
            if leaks(k, depth + 1) or leaks(x, depth + 1) then return true end
        end
    end
    return false
end
eq(leaks(h.data(), 0), false, "no secret in the shared state")

-- test: credential_file_is_reread_every_cycle
h = boot({}, standard)
h.files["/secrets/api-key"] = "ROTATED\n"
h.refresh(1)
eq(h.calls[#h.calls].basic_password, "ROTATED", "rotated key used on the next cycle")

-- test: bad_proxy_password_file_blocks_pages_not_metrics
local PU = "https://status.example.test/status/dev"
h = boot({ status_pages = { PU }, proxy_user = "pu", proxy_password_file = "/secrets/none", proxy_hosts = { "status.example.test" } }, standard)
eq(h.count("/api/status-page/dev"), 0, "no page request without the password")
eq(h.data().errors.pages[PU], "error.cred_unreadable", "reason on the page")
eq(h.data().summary.up, 1, "metrics unaffected")

-- test: permission_warning_for_files_readable_by_others
h = boot({}, standard)
eq(h.data().credWarn, false, "600 is fine")
eq(table.concat(h.runs[1], " "), "stat -c %a /secrets/api-key", "mode read with stat")
h.stat = "644\n"
onConfigChanged()
eq(h.data().credWarn, true, "644 warns")

-- test: rotating_the_secret_unblocks_a_401_source
h = boot({}, function(req)
    if req.url:sub(-8) == "/metrics" and req.basic_password == "KEY-SECRET" then return { ok = true, status = 401, body = "" } end
    return standard(req)
end)
eq(h.data().errors.metrics, "error.unauthorized", "refused")
h.refresh(1)
eq(h.count("/metrics"), 1, "same secret stays blocked")
h.files["/secrets/api-key"] = "NEW\n"
h.refresh(2)
eq(h.count("/metrics"), 2, "a new secret is tried")
eq(h.data().errors.metrics, nil, "and accepted")

-- test: certificates_published_with_fixed_limits
local function certMetrics(req)
    if req.url:sub(-8) == "/metrics" then
        return ok(table.concat({
            series("monitor_status", 1, "svc-a", 1), series("monitor_status", 2, "svc-b", 1), series("monitor_status", 3, "svc-c", 1),
            series("monitor_cert_days_remaining", 1, "svc-a", 7), series("monitor_cert_days_remaining", 2, "svc-b", 8),
            series("monitor_cert_days_remaining", 3, "svc-c", 60),
        }, "\n"))
    end
    return standard(req)
end
h = boot({}, certMetrics)
eq(h.data().certs.groups[1].level, "red", "7 days is red"); eq(h.data().certs.groups[2].level, "yellow", "8 days is yellow")
eq(h.data().certs.groups[3].level, "green", "60 days is green")
eq(h.data().certLimits.red, 7, "default limits published"); eq(h.data().certLimits.yellow, 30, "default yellow")
h = boot({ cert_red_days = 8, cert_yellow_days = 59 }, certMetrics)
eq(h.data().certs.groups[1].level, "red", "8 days is red with red 8"); eq(#h.data().certs.groups[1].rows, 2, "7 and 8 days")
eq(h.data().certs.groups[2].level, "green", "60 days is green with yellow 59")
eq(h.data().certLimits.yellow, 59, "custom limits published")
eq(h.data().dashboard.groups[1].rows[1].certLevel ~= nil, true, "dashboard rows have a level")

-- test: group_tags_setting_drives_the_tag_groups
h = boot({ group_tags = { "x" } }, multiTag)
eq(h.data().dashboard.groups[1].name, "x", "listed tag first"); eq(#h.data().dashboard.groups[1].rows, 1, "svc-a only")
eq(h.data().dashboard.groups[2].name, "", "svc-b has no listed tag"); eq(h.data().dashboard.groups[2].rows[1].name, "svc-b", "svc-b")

print("service_test OK")
