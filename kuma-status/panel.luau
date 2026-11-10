--!nonstrict
-- kuma-status — panel with two tabs: Dashboard and Status pages.
--
-- Pure renderer over the "kuma_status_data" state published by service.luau.
-- Both tabs stay mounted and the inactive one is hidden with `visible =
-- false` (recreating a tab would replay its creation animations). Opening the
-- panel and the refresh button publish "kuma_status_request" (nonce from a
-- clock-seeded counter, so the service never mistakes a new panel session
-- for a nonce it already saw). Clicking a monitor opens its Kuma page with
-- xdg-open; the URL is built here from the service's baseUrl and the numeric
-- monitor id, never from monitor text.
-- Dashboard groups collapse by dropping their rows (cheaper than hiding).

local R = require("./rows.luau")

local DATA_KEY = "kuma_status_data"
local REQUEST_KEY = "kuma_status_request"

local data = nil
local tab = "dashboard"
local collapsed = {}
local isOpen = false
local requestNonce = math.floor(noctalia.nowMs())

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function requestRefresh()
    requestNonce += 1
    noctalia.state.set(REQUEST_KEY, { nonce = requestNonce, action = "refresh" })
end

-- Only http(s) URLs built by this plugin reach xdg-open.
local function openUrl(url)
    if not url:match("^https?://") then return end
    if not noctalia.commandExists("xdg-open") then
        noctalia.notifyError(tr("tooltip"), tr("panel.no_xdg_open"))
        return
    end
    noctalia.runAsync({ "xdg-open", url })
end

local function openMonitor(id)
    local base = data and data.baseUrl or ""
    if base == "" or tonumber(id) == nil then return end
    openUrl(base .. "/dashboard/" .. math.floor(tonumber(id)))
end

local render

local function toggleGroup(key)
    collapsed[key] = not collapsed[key]
    render()
end

local function dashboardView()
    local children = {}
    local dash = data and data.dashboard
    if dash == nil then
        children[1] = ui.label({ key = "empty", text = tr("panel.empty"), color = "on_surface_variant" })
    elseif #dash.groups == 0 then
        children[1] = ui.label({ key = "dash-empty", text = tr("panel.empty_groups"), color = "on_surface_variant" })
    else
        for _, g in ipairs(dash.groups) do
            local key = R.groupKey(g)
            children[#children + 1] = R.groupHeader(g, collapsed[key] == true, toggleGroup)
            if not collapsed[key] then
                for _, row in ipairs(g.rows) do
                    children[#children + 1] = R.monitorRow(row, openMonitor)
                end
            end
        end
    end
    return children
end

-- A status page row is the newest heartbeat plus the bar; ping is not in the
-- public heartbeat list, so the ping column stays empty.
local function pageRow(m, open)
    local status = m.beats[#m.beats]
    return R.monitorRow({ id = m.id, name = m.name, status = status or -1, beats = m.beats, paused = false, noPing = true }, open)
end

local function pagesView()
    local out = {}
    local urls = data and data.pageUrls or {}
    if #urls == 0 then
        out[1] = ui.label({ key = "pages-empty", text = tr("panel.pages_empty"), color = "on_surface_variant" })
        return out
    end
    local bySource = {}
    for _, sp in ipairs(data.pages or {}) do bySource[sp.source] = sp end
    local pageErrors = data.errors and data.errors.pages or {}
    for i, url in ipairs(urls) do
        local sp = bySource[url]
        if sp == nil then
            out[#out + 1] = ui.column({ key = "page-" .. i, gap = 2 }, {
                ui.label({ key = "page-url-" .. i, text = url, fontWeight = "semibold", maxLines = 1 }),
                ui.label({ key = "page-err-" .. i, text = pageErrors[url] or tr("panel.page_no_data"), color = "error" }),
            })
        else
            local function open() openUrl(sp.url) end
            local children = {
                ui.row({ key = "page-head-" .. i, gap = 6, align = "center" }, {
                    ui.label({ key = "page-title-" .. i, text = sp.title, flexGrow = 1, maxLines = 1, fontWeight = "bold" }),
                    ui.button({ key = "btn-open-page-" .. i, glyph = "external-link", variant = "ghost", tooltip = tr("panel.tip_open_page"), onClick = open }),
                }),
            }
            for j, g in ipairs(sp.groups) do
                children[#children + 1] = ui.label({ key = "page-group-" .. i .. "-" .. j, text = g.name, fontWeight = "semibold", color = "on_surface_variant" })
                for _, m in ipairs(g.monitors) do
                    children[#children + 1] = pageRow(m, open)
                end
            end
            out[#out + 1] = ui.column({ key = "page-" .. i, gap = 4 }, children)
        end
    end
    return out
end

local function notices()
    local out = {}
    local errors = data and data.errors or {}
    if errors.metrics then out[#out + 1] = ui.label({ key = "err-metrics", text = errors.metrics, color = "error" }) end
    if errors.monitors then out[#out + 1] = ui.label({ key = "err-monitors", text = errors.monitors, color = "error" }) end
    if data and data.plainHttp then
        out[#out + 1] = ui.label({ key = "warn-http", text = tr("panel.warn_http"), color = "tertiary" })
    end
    return out
end

function render()
    local mode = data and (data.dashboard and data.dashboard.mode or data.mode)
    local stamp = data and data.ts and tr("panel.updated", { time = noctalia.formatTime("%H:%M", data.ts) }) or ""
    local dashChildren = {}
    if mode then
        dashChildren[1] = ui.label({ key = "mode-line", text = mode == "hierarchy" and tr("panel.mode_hierarchy") or tr("panel.mode_tags"), color = "on_surface_variant" })
    end
    dashChildren[#dashChildren + 1] = ui.scroll({ key = "scroll-dash", flexGrow = 1, gap = 4 }, dashboardView())
    panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
        ui.row({ key = "header", gap = 6, align = "center" }, {
            ui.button({ key = "btn-tab-dashboard", text = tr("panel.tab_dashboard"), variant = tab == "dashboard" and "primary" or "ghost", onClick = function() tab = "dashboard"; render() end }),
            ui.button({ key = "btn-tab-pages", text = tr("panel.tab_pages"), variant = tab == "pages" and "primary" or "ghost", onClick = function() tab = "pages"; render() end }),
            ui.label({ key = "stamp", text = stamp, flexGrow = 1, textAlign = "end", color = "on_surface_variant" }),
            ui.button({ key = "btn-refresh", glyph = "refresh", variant = "ghost", tooltip = tr("panel.tip_refresh"), onClick = requestRefresh }),
        }),
        ui.column({ key = "notices", gap = 2 }, notices()),
        ui.column({ key = "tab-dashboard", visible = tab == "dashboard", flexGrow = 1, gap = 6 }, dashChildren),
        ui.column({ key = "tab-pages", visible = tab == "pages", flexGrow = 1, gap = 6 }, {
            ui.scroll({ key = "scroll-pages", flexGrow = 1, gap = 8 }, pagesView()),
        }),
    }))
end

noctalia.state.watch(DATA_KEY, function(value)
    data = value
    if isOpen then render() end
end)

function onOpen(_context)
    isOpen = true
    data = noctalia.state.get(DATA_KEY)
    requestRefresh()
    render()
end

function onClose()
    isOpen = false
end
