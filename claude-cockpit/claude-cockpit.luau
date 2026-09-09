--!nonstrict
-- Claude Cockpit — bar widget that toggles the panel.
--
-- Just a glyph that lights up while the panel is open (shared
-- "claude_cockpit_open" state, published by panel.luau), plus an optional
-- text badge mirroring service.luau's published "usage" state: "sNN% wMM%"
-- — s for the 5-hour session window, w for the 7-day weekly one, the two
-- windows every plan reports. No ring — that would mean porting
-- jrohland/claudecode's ring.luau (which needs plugin_api 26 for
-- noctalia.getSetting) for numbers the panel's Usage tab already shows one
-- click away; a plain text badge needs neither.
--
-- Left click is NOT wired here: plugin.toml declares it as a
-- [widget.actions] default (`left = "panel-toggle nightwatch75/claude-cockpit:panel"`),
-- so the user can remap the gesture from the bar's own settings.

local shared = require("./shared.luau")

local open = false
local usage = noctalia.state.get("usage")
local status = noctalia.state.get("status")

-- "" when the setting is off, the service has no data yet, or it reported
-- itself unavailable (missing jq/curl) — never a stale or half-built badge.
local function usageText()
    if noctalia.getConfig("show_usage_percent") ~= true then
        return ""
    end
    if type(status) == "table" and status.available == false then
        return ""
    end
    if type(usage) ~= "table" then
        return ""
    end
    local session = shared.round(tonumber(usage.five_hour_util) or 0)
    local weekly = shared.round(tonumber(usage.seven_day_util) or 0)
    return `s{session}% w{weekly}%`
end

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))
    barWidget.setGlyphColor(open and "primary" or "on_surface")
    barWidget.setText(usageText())
    barWidget.setTooltip(noctalia.tr("title"))
end

noctalia.state.watch("claude_cockpit_open", function(value)
    open = value == true
    render()
end)

noctalia.state.watch("usage", function(value)
    usage = value
    render()
end)

noctalia.state.watch("status", function(value)
    status = value
    render()
end)

render()
