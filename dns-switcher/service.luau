--!nonstrict
-- dns-switcher — singleton DNS engine (detection + apply).
--
-- Runs once regardless of how many bars show the widget. The widget and the
-- panel are pure renderers wired through the plugin's shared state:
--   engine publishes  "dns_state"     = { nonce, current?, servers, conName,
--                                         changing, error?, list }
--   UI entries send   "apply_request" = { nonce, id, label?, ip? }
--
-- Detection reads the active connection's ipv4.dns / ipv4.ignore-auto-dns
-- profile settings (manual DNS is matched against the providers, otherwise
-- shown as "Custom"); without a manual DNS the state is the ISP default.
-- Applying runs `nmcli con mod <uuid> … && nmcli device reapply <dev>` —
-- reapply pushes the change onto the live connection without reactivating
-- it, so the network never drops. The privilege command is empty by default:
-- NetworkManager's polkit policy lets active local sessions modify system
-- connections on most desktop distros.

local BUILTIN = {
    { id = "google",     label = "Google",     ip = "8.8.8.8 8.8.4.4",               glyph = "brand-google" },
    { id = "cloudflare", label = "Cloudflare", ip = "1.1.1.1 1.0.0.1",               glyph = "cloud" },
    { id = "opendns",    label = "OpenDNS",    ip = "208.67.222.222 208.67.220.220", glyph = "world" },
    { id = "adguard",    label = "AdGuard",    ip = "94.140.14.14 94.140.15.15",     glyph = "shield-check" },
    { id = "quad9",      label = "Quad9",      ip = "9.9.9.9 149.112.112.112",       glyph = "lock" },
}
local GLYPH_DEFAULT = "router" -- ISP / connection default
local GLYPH_UNKNOWN = "globe"  -- unrecognized manual DNS
local GLYPH_CUSTOM = "server"  -- user-defined servers

local current = nil -- provider entry detected as active; nil = still checking
local lastSeen = "" -- runtime resolver IPs from the last successful poll
local conName = ""  -- active connection name, shown in the panel footer
local errMsg = nil  -- sticky error label (no nmcli / no connection)
local pollTicks = 0
local changing = false
local checkInFlight = false
local nmcliMissing = false
local stateNonce = 0

local function cfg(key)
    return noctalia.getConfig(key)
end

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function pollSeconds()
    return math.max(2, tonumber(cfg("poll_seconds")) or 10)
end

local function isValidIp(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if a == nil then
        return false
    end
    for _, part in ipairs({ a, b, c, d }) do
        if #part > 3 or tonumber(part) > 255 then
            return false
        end
    end
    return true
end

-- One or two space-separated IPv4 addresses, same shape nmcli accepts.
local function validDnsSpec(spec)
    local count = 0
    for token in spec:gmatch("%S+") do
        count += 1
        if count > 2 or not isValidIp(token) then
            return false
        end
    end
    return count > 0
end

-- Custom servers setting: "Name = 1.2.3.4 5.6.7.8; Other = 9.9.9.10".
-- Entries split on ';' or ','. Parsed lazily and cached on the raw string,
-- so invalid entries are only logged when the setting actually changes.
local customCacheRaw = nil
local customCacheList = {}
local function customProviders()
    local raw = cfg("custom_servers")
    if type(raw) ~= "string" then
        raw = ""
    end
    if raw == customCacheRaw then
        return customCacheList
    end
    customCacheRaw = raw
    customCacheList = {}
    for entry in raw:gmatch("[^;,]+") do
        local name, spec = entry:match("^(.-)=(.*)$")
        name = name ~= nil and trim(name) or ""
        spec = spec ~= nil and trim(spec) or ""
        if name ~= "" and validDnsSpec(spec) then
            table.insert(customCacheList, { id = "custom:" .. name, label = name, ip = spec, glyph = GLYPH_CUSTOM })
        elseif trim(entry) ~= "" then
            noctalia.log("dns-switcher: ignoring invalid custom server entry '" .. trim(entry) .. "'")
        end
    end
    return customCacheList
end

local function enabledBuiltins()
    local raw = cfg("providers")
    if type(raw) ~= "string" then
        return BUILTIN
    end
    -- Cleared setting = no built-ins: only custom servers and the ISP default.
    if trim(raw) == "" then
        return {}
    end
    local wanted = {}
    for id in raw:gmatch("[^,%s]+") do
        wanted[id:lower()] = true
    end
    local list = {}
    for _, provider in ipairs(BUILTIN) do
        if wanted[provider.id] then
            table.insert(list, provider)
        end
    end
    return list
end

local function defaultEntry()
    return { id = "default", label = tr("status_default"), ip = "", glyph = GLYPH_DEFAULT }
end

-- Panel order: enabled built-ins, then custom servers, then the ISP default.
local function providerList()
    local list = {}
    for _, provider in ipairs(enabledBuiltins()) do
        table.insert(list, provider)
    end
    for _, provider in ipairs(customProviders()) do
        table.insert(list, provider)
    end
    table.insert(list, defaultEntry())
    return list
end

local function publish()
    stateNonce += 1
    noctalia.state.set("dns_state", {
        nonce = stateNonce,
        current = current,
        servers = lastSeen,
        conName = conName,
        changing = changing,
        error = errMsg,
        list = providerList(),
    })
end

-- Picks the active connection: prefer wifi/ethernet, else the first
-- non-loopback entry. Emits KEY=value lines parsed by the poll callback;
-- UUID (colon-free) identifies the connection, DEV drives the reapply.
local DETECT_CMD = [[
ACT=$(LC_ALL=C nmcli -t -f TYPE,DEVICE,UUID,NAME connection show --active 2>/dev/null)
LINE=$(printf '%s\n' "$ACT" | grep -E '^(802-11-wireless|802-3-ethernet):' | head -n 1)
[ -n "$LINE" ] || LINE=$(printf '%s\n' "$ACT" | grep -v '^loopback:' | head -n 1)
[ -n "$LINE" ] || { echo 'ERR=noconn'; exit 0; }
DEV=$(printf '%s' "$LINE" | cut -d: -f2)
UUID=$(printf '%s' "$LINE" | cut -d: -f3)
echo "NAME=$(printf '%s' "$LINE" | cut -d: -f4-)"
echo "CFG=$(LC_ALL=C nmcli -g ipv4.dns connection show uuid "$UUID" 2>/dev/null)"
echo "AUTO=$(LC_ALL=C nmcli -g ipv4.ignore-auto-dns connection show uuid "$UUID" 2>/dev/null)"
echo "RUN=$(nmcli -g IP4.DNS device show "$DEV" 2>/dev/null | tr '\n' ' ')"
]]

local function updateDnsState(stdout)
    local fields = {}
    for line in stdout:gmatch("[^\n]+") do
        local key, value = line:match("^(%u+)=(.*)$")
        if key ~= nil then
            fields[key] = value
        end
    end

    if fields.ERR == "noconn" then
        current = nil
        errMsg = tr("err_no_connection")
        return
    end
    errMsg = nil
    conName = fields.NAME or ""

    local runtime = {}
    for token in (fields.RUN or ""):gmatch("%d+%.%d+%.%d+%.%d+") do
        if isValidIp(token) then
            table.insert(runtime, token)
        end
    end
    lastSeen = table.concat(runtime, " ")

    -- Manual DNS lives in the profile (ipv4.dns + ignore-auto-dns yes);
    -- anything else is the connection default, whatever the LAN hands out.
    local manual = (fields.AUTO == "yes")
    local cfgIps = {}
    for token in (fields.CFG or ""):gmatch("%d+%.%d+%.%d+%.%d+") do
        if isValidIp(token) then
            table.insert(cfgIps, token)
        end
    end
    if not manual or #cfgIps == 0 then
        current = defaultEntry()
        return
    end

    -- Customs take precedence over built-ins, so a custom entry that reuses
    -- a public IP (e.g. a forwarder) keeps its own label.
    local lookup = {}
    for _, provider in ipairs(BUILTIN) do
        for ip in provider.ip:gmatch("%S+") do
            lookup[ip] = provider
        end
    end
    for _, provider in ipairs(customProviders()) do
        for ip in provider.ip:gmatch("%S+") do
            lookup[ip] = provider
        end
    end
    for _, ip in ipairs(cfgIps) do
        if lookup[ip] ~= nil then
            current = lookup[ip]
            return
        end
    end
    current = {
        id = "unknown",
        label = tr("status_custom", { ip = cfgIps[1] }),
        ip = table.concat(cfgIps, " "),
        glyph = GLYPH_UNKNOWN,
    }
end

local function pollNow()
    if checkInFlight or changing or nmcliMissing then
        return
    end
    checkInFlight = true
    local ok = noctalia.runAsync(DETECT_CMD, function(result)
        checkInFlight = false
        if result.exitCode == 0 and not result.timedOut then
            updateDnsState(result.stdout)
        elseif current == nil then
            errMsg = tr("status_no_nmcli")
        end
        publish()
    end, 4000)
    if not ok then
        checkInFlight = false
    end
end

local function apply(provider)
    if changing then
        return
    end
    if provider.ip ~= "" and not validDnsSpec(provider.ip) then
        noctalia.notifyError(tr("title"), tr("err_invalid_ip", { ip = provider.ip }))
        return
    end

    -- Safety net mirroring the v4 plugin: the spec is already validated, the
    -- gsub guarantees nothing shell-relevant ever reaches the command line.
    local safeIp = provider.ip:gsub("[^%d%. ]", "")
    local mods
    if safeIp == "" then
        mods = 'ipv4.dns "" ipv4.ignore-auto-dns no'
    else
        mods = 'ipv4.dns "' .. safeIp .. '" ipv4.ignore-auto-dns yes'
    end
    local inner = 'ACT=$(LC_ALL=C nmcli -t -f TYPE,DEVICE,UUID connection show --active 2>/dev/null); '
        .. [[LINE=$(printf '%s\n' "$ACT" | grep -E '^(802-11-wireless|802-3-ethernet):' | head -n 1); ]]
        .. [=[[ -n "$LINE" ] || LINE=$(printf '%s\n' "$ACT" | grep -v '^loopback:' | head -n 1); ]=]
        .. [=[[ -n "$LINE" ] || exit 9; ]=]
        .. 'DEV=$(printf \'%s\' "$LINE" | cut -d: -f2); '
        .. 'UUID=$(printf \'%s\' "$LINE" | cut -d: -f3); '
        .. 'nmcli con mod "$UUID" ' .. mods .. ' && nmcli device reapply "$DEV"'

    local priv = cfg("privilege_command")
    if type(priv) ~= "string" then
        priv = ""
    end
    priv = trim(priv)
    local cmd = inner
    if priv ~= "" then
        cmd = priv .. " sh -c " .. shellQuote(inner)
    end

    changing = true
    publish()
    -- 60s budget so an eventual polkit password prompt can be answered.
    local ok = noctalia.runAsync(cmd, function(result)
        changing = false
        if result.exitCode == 0 and not result.timedOut then
            noctalia.notify(tr("title"), tr("applied", { name = provider.label }))
        elseif result.timedOut then
            noctalia.notifyError(tr("title"), tr("err_timeout"))
        elseif result.exitCode == 9 then
            noctalia.notifyError(tr("title"), tr("err_no_connection"))
        elseif result.exitCode == 126 then
            noctalia.notifyError(tr("title"), tr("err_auth_dismissed"))
        else
            local detail = trim(result.stderr or "")
            if #detail > 200 then
                detail = detail:sub(1, 200) .. "…"
            end
            local body = tr("err_apply_failed")
            if detail:lower():find("not authorized") or detail:lower():find("insufficient") then
                body = tr("err_not_authorized")
            elseif detail ~= "" then
                body = body .. "\n" .. detail
            end
            noctalia.notifyError(tr("title"), body)
        end
        publish()
        pollNow()
    end, 60000)
    if not ok then
        changing = false
        noctalia.notifyError(tr("title"), tr("err_spawn"))
        publish()
    end
end

-- Resolves an apply request against the current provider list (so config
-- edits win over stale request payloads), falling back to the request's own
-- label/ip for entries that just left the list.
local function applyById(id, label, ip)
    for _, entry in ipairs(providerList()) do
        if entry.id == id then
            apply(entry)
            return true
        end
    end
    if id == "default" or (type(ip) == "string" and validDnsSpec(ip)) then
        apply({ id = id, label = label or id, ip = id == "default" and "" or ip })
        return true
    end
    return false
end

-- Apply requests from the widget/panel. The nonce is monotonic across
-- writers (each seeds from the last request) and guards against replaying a
-- stale request after a hot reload of this script.
local handledNonce = 0
do
    local pendingReq = noctalia.state.get("apply_request")
    if type(pendingReq) == "table" and type(pendingReq.nonce) == "number" then
        handledNonce = pendingReq.nonce
    end
end
noctalia.state.watch("apply_request", function(req)
    if type(req) ~= "table" or type(req.nonce) ~= "number" or req.nonce <= handledNonce then
        return
    end
    handledNonce = req.nonce
    if nmcliMissing then
        return
    end
    applyById(req.id, req.label, req.ip)
end)

-- Scriptable switching:
--   noctalia msg plugin nightwatch75/dns-switcher:service all apply <id>
-- where <id> is a provider id ("google", "default", "custom:<name>"…);
-- "poll" forces an immediate re-detection.
function onIpc(event, payload)
    if nmcliMissing then
        return
    end
    if event == "poll" then
        pollNow()
    elseif event == "apply" then
        local id = type(payload) == "string" and trim(payload) or ""
        if not applyById(id) then
            noctalia.notifyError(tr("title"), tr("err_unknown_provider", { id = id }))
        end
    end
end

function onConfigChanged()
    -- Settings edits reshape the provider list and may relabel the current
    -- entry; re-publish and re-check right away.
    publish()
    pollNow()
end

function update()
    if nmcliMissing then
        return
    end
    pollTicks += 1
    if pollTicks >= pollSeconds() then
        pollTicks = 0
        pollNow()
    end
end

noctalia.setUpdateInterval(1000)
if not noctalia.commandExists("nmcli") then
    nmcliMissing = true
    errMsg = tr("status_no_nmcli")
    current = nil
    publish()
    noctalia.notifyError(tr("title"), tr("err_no_nmcli"))
else
    publish()
    pollNow()
end
