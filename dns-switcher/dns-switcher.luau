--!nonstrict
-- dns-switcher — bar widget: renders the state published by the service
-- entry (service.luau) and forwards user actions to it via "apply_request".
--
-- Click mapping:
--   Left click   — open/close the provider panel
--   Right click  — reset to the connection default (ISP)
--
-- No middle-click handler: every bar widget carries a built-in `middle` binding
-- that opens its own settings, and a user binding wins over a script callback,
-- so one here would never fire. The panel's copy button does the same job.

local PANEL_ID = "nightwatch75/dns-switcher:panel"
local GLYPH_UNKNOWN = "globe"

local snapshot = nil -- last "dns_state" published by the service

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function setLabel(text)
    if noctalia.getConfig("show_label") == false then
        barWidget.setText("")
    else
        barWidget.setText(text)
    end
end

local function paint(glyph, role, label)
    barWidget.setGlyph(glyph)
    barWidget.setGlyphColor(role)
    barWidget.setColor(role)
    setLabel(label)
end

local function render()
    local s = snapshot
    if s == nil or (s.current == nil and s.error == nil) then
        paint(GLYPH_UNKNOWN, "on_surface", tr("status_checking"))
        barWidget.clearTooltip()
        return
    end
    if s.changing == true then
        paint("refresh", "secondary", tr("status_switching"))
        barWidget.setTooltip(tr("tooltip_switching"))
        return
    end
    if s.error ~= nil then
        paint(GLYPH_UNKNOWN, "error", s.error)
        barWidget.clearTooltip()
        return
    end
    local role = s.current.id ~= "default" and "primary" or "on_surface"
    paint(s.current.glyph, role, s.current.label)
    local servers = s.current.ip
    if servers == "" then
        servers = s.servers ~= "" and s.servers or tr("status_auto")
    end
    barWidget.setTooltip({
        { key = tr("tooltip_provider"), value = s.current.label },
        { key = tr("tooltip_servers"), value = servers },
        { key = tr("tooltip_actions"), value = tr("tooltip_hints") },
    })
end

noctalia.state.watch("dns_state", function(value)
    if type(value) == "table" then
        snapshot = value
        render()
    end
end)

-- The nonce is monotonic across writers (widget instances and the panel):
-- each seeds from the last request in the shared state.
local function requestApply(id, label, ip)
    local prev = noctalia.state.get("apply_request")
    local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
    noctalia.state.set("apply_request", { nonce = nonce, id = id, label = label, ip = ip })
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
    if snapshot == nil or snapshot.changing == true then
        return
    end
    if snapshot.current ~= nil and snapshot.current.id == "default" then
        return
    end
    requestApply("default", tr("status_default"), "")
end

snapshot = noctalia.state.get("dns_state")
render()
