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
-- click away; a plain text badge needs neither. The tooltip mirrors that
-- plugin's own pill tooltip content (plan, rate windows, today/week tokens).
--
-- Left click is NOT wired here: plugin.toml declares it as a
-- [widget.actions] default (`left = "panel-toggle nightwatch75/claude-cockpit:panel"`),
-- so the user can remap the gesture from the bar's own settings.

local shared = require("./shared.luau")

local open = false
local usage = noctalia.state.get("usage")
local status = noctalia.state.get("status")

-- "" when the setting is "none", the service has no data yet, or it
-- reported itself unavailable (missing jq/curl) — never a stale or
-- half-built badge.
local function usageText()
    local mode = noctalia.getConfig("usage_percent_display") or "both"
    if mode == "none" then
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
    if mode == "session" then
        return `s{session}%`
    end
    if mode == "weekly" then
        return `w{weekly}%`
    end
    return `s{session}% w{weekly}%`
end

-- Same tooltip content as jrohland/claudecode's pill (see its widget.luau):
-- key/value rows so the shell lays them out as a two-column grid instead of
-- a wall of text. A row per rate window (percent, countdown, reset clock),
-- then today's and this week's tokens with their cost.
local function usageTooltip()
    if type(status) == "table" and status.available == false then
        return status.message ~= "" and status.message or noctalia.tr("unavailable")
    end
    if type(usage) ~= "table" then
        return noctalia.tr("loading")
    end

    local rows = {}
    local function row(key, value)
        table.insert(rows, { key = key, value = value })
    end

    row(noctalia.tr("plan"), shared.planName(usage.subscription_type, usage.rate_limit_tier))

    for _, w in shared.windows(usage) do
        local value = `{shared.round(w.percent)}%`
        local countdown = shared.formatCountdownShort(w.resetIso)
        if countdown then
            local clock = shared.formatResetClock(w.resetIso)
            value = clock and `{value}  ·  {countdown} ({clock})` or `{value}  ·  {countdown}`
        end
        row(w.label, value)
    end

    local todayTokens = (type(usage.daily) == "table" and usage.daily[shared.todayIndex()]) or 0
    row(noctalia.tr("today"), `{shared.formatTokens(todayTokens)}  ({shared.formatCost(usage.today_cost)})`)
    row(noctalia.tr("week"), `{shared.formatTokens(usage.week_tokens)}  ({shared.formatCost(usage.week_cost)})`)

    return rows
end

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))
    barWidget.setGlyphColor(open and "primary" or "on_surface")
    barWidget.setText(usageText())
    barWidget.setTooltip(usageTooltip())
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
