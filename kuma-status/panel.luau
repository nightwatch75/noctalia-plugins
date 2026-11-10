--!nonstrict
-- kuma-status — panel with two tabs: Dashboard and Status pages.
--
-- Pure renderer over the "kuma_status_data" state published by service.luau,
-- plus two small writes: the refresh request ("kuma_status_request", nonce from
-- a clock-seeded counter so a new panel session is never mistaken for a nonce
-- the service already saw) and the status pages added here (pages_store.luau;
-- the service merges them with the `status_pages` setting).
-- Header: title, settings (noctalia.openSettings) and close buttons like the
-- other plugins; under it the tabs, the configured Kuma URL and refresh.
-- Both tabs stay mounted and the inactive one is hidden with `visible =
-- false` (recreating a tab would replay its creation animations). Dashboard
-- groups collapse by dropping their rows (cheaper than hiding).
-- Clicks: a monitor name opens its Kuma page; right click raises a native menu
-- (Open browser / Copy URL, both about the URL the check hits) — onActivate
-- must name a global, so the menu target is kept in file-locals. Only http(s)
-- URLs built or validated by this plugin reach xdg-open.

local R = require("./rows.luau")
local K = require("./kuma.luau")
local store = require("./pages_store.luau")

local DATA_KEY = "kuma_status_data"
local REQUEST_KEY = "kuma_status_request"

local data = nil
local tab = "dashboard"
local collapsed = {}
local isOpen = false
local requestNonce = math.floor(noctalia.nowMs())
local addText, addRev, addError = "", 0, false
local menuUrl = nil

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function requestRefresh()
    requestNonce += 1
    noctalia.state.set(REQUEST_KEY, { nonce = requestNonce, action = "refresh" })
end

local function openUrl(url)
    if url == nil or not url:match("^https?://") then return end
    if not noctalia.commandExists("xdg-open") then
        noctalia.notifyError(tr("title"), tr("panel.no_xdg_open"))
        return
    end
    noctalia.runAsync({ "xdg-open", url })
end

local function openMonitor(id)
    local base = data and data.baseUrl or ""
    if base == "" or tonumber(id) == nil then return end
    openUrl(base .. "/dashboard/" .. math.floor(tonumber(id)))
end

-- Right click on a check: only worth a menu when the check has a URL.
local function openRowMenu(row)
    if row.url == nil then return end
    menuUrl = row.url
    panel.openContextMenu({
        onActivate = "onRowMenu",
        context = tostring(row.id),
        items = {
            { id = "open", label = tr("panel.menu_open"), enabled = row.url:match("^https?://") ~= nil },
            { id = "copy", label = tr("panel.menu_copy") },
        },
    })
end

function onRowMenu(actionId, _context)
    if menuUrl == nil then return end
    if actionId == "open" then
        openUrl(menuUrl)
    elseif actionId == "copy" then
        noctalia.copyToClipboard(menuUrl, "text/plain")
    end
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
                    children[#children + 1] = R.monitorRow(row, openMonitor, openRowMenu)
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
    return R.monitorRow({ id = m.id, name = m.name, status = status or -1, beats = m.beats, paused = false, noPing = true }, open, nil)
end

local function addPage()
    local text = (addText or ""):match("^%s*(.-)%s*$")
    local origin, slug = K.statusPageUrl(text)
    if origin == nil then
        addError = true
        render()
        return
    end
    local url = origin .. "/status/" .. slug
    local list = store.load()
    local present = false
    for _, u in ipairs(list) do
        if u == url then present = true end
    end
    if not present then
        list[#list + 1] = url
        store.save(list)
    end
    addText, addError = "", false
    addRev += 1
    requestRefresh()
    render()
end

local function removePage(url)
    local kept = {}
    for _, u in ipairs(store.load()) do
        if u ~= url then kept[#kept + 1] = u end
    end
    store.save(kept)
    requestRefresh()
    render()
end

local function addView()
    local out = {
        ui.row({ key = "add-row", gap = 6, align = "center" }, {
            ui.column({ key = "add-wrap-" .. addRev, flexGrow = 1 }, {
                ui.input({
                    key = "add-input", placeholder = tr("panel.add_placeholder"), submitOnEnter = true,
                    onChange = function(v) addText = v end,
                    onSubmit = function(v) addText = v; addPage() end,
                }),
            }),
            ui.button({ key = "btn-add-page", glyph = "plus", variant = "ghost", tooltip = tr("panel.tip_add"), onClick = addPage }),
        }),
    }
    if addError then
        out[#out + 1] = ui.label({ key = "add-err", text = tr("panel.add_bad_url"), color = "error" })
    end
    return out
end

local function pagesView()
    local out = {}
    local urls = data and data.pageUrls or {}
    if #urls == 0 then
        out[1] = ui.label({ key = "pages-empty", text = tr("panel.pages_empty"), color = "on_surface_variant" })
        return out
    end
    local bySource, added = {}, {}
    for _, sp in ipairs(data.pages or {}) do bySource[sp.source] = sp end
    for _, u in ipairs(data.addedUrls or {}) do added[u] = true end
    local pageErrors = data.errors and data.errors.pages or {}
    for i, url in ipairs(urls) do
        local sp = bySource[url]
        local removeBtn = added[url] and ui.button({ key = "btn-del-page-" .. i, glyph = "trash", variant = "ghost", tooltip = tr("panel.tip_remove_page"), onClick = function() removePage(url) end }) or nil
        if sp == nil then
            out[#out + 1] = ui.column({ key = "page-" .. i, gap = 2 }, {
                ui.row({ key = "page-head-" .. i, gap = 6, align = "center" }, {
                    ui.label({ key = "page-url-" .. i, text = url, flexGrow = 1, fontWeight = "semibold", maxLines = 1 }),
                    removeBtn,
                }),
                ui.label({ key = "page-err-" .. i, text = pageErrors[url] or tr("panel.page_no_data"), color = "error" }),
            })
        else
            local function open() openUrl(sp.url) end
            local children = {
                ui.row({ key = "page-head-" .. i, gap = 6, align = "center" }, {
                    ui.label({ key = "page-title-" .. i, text = sp.title, flexGrow = 1, maxLines = 1, fontWeight = "bold" }),
                    ui.button({ key = "btn-open-page-" .. i, glyph = "external-link", variant = "ghost", tooltip = tr("panel.tip_open_page"), onClick = open }),
                    removeBtn,
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
    local stamp = data and data.ts and tr("panel.updated", { time = noctalia.formatTime("%H:%M", data.ts) }) or nil
    local dashChildren = {}
    if mode then
        dashChildren[1] = ui.label({ key = "mode-line", text = mode == "hierarchy" and tr("panel.mode_hierarchy") or tr("panel.mode_tags"), color = "on_surface_variant" })
    end
    dashChildren[#dashChildren + 1] = ui.scroll({ key = "scroll-dash", flexGrow = 1, gap = 4 }, dashboardView())
    local pagesChildren = addView()
    pagesChildren[#pagesChildren + 1] = ui.scroll({ key = "scroll-pages", flexGrow = 1, gap = 8 }, pagesView())
    panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
        ui.row({ key = "header", gap = 6, align = "center" }, {
            ui.label({ key = "title", text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
            ui.button({ key = "btn-settings", glyph = "settings", variant = "ghost", tooltip = tr("panel.tip_settings"), onClick = function() noctalia.openSettings() end }),
            ui.button({ key = "btn-close", glyph = "close", variant = "ghost", tooltip = tr("panel.tip_close"), onClick = function() panel.close() end }),
        }),
        ui.row({ key = "tabs", gap = 6, align = "center" }, {
            ui.button({ key = "btn-tab-dashboard", glyph = "layout-dashboard", text = tr("panel.tab_dashboard"), variant = tab == "dashboard" and "primary" or "ghost", onClick = function() tab = "dashboard"; render() end }),
            ui.button({ key = "btn-tab-pages", glyph = "world-www", text = tr("panel.tab_pages"), variant = tab == "pages" and "primary" or "ghost", onClick = function() tab = "pages"; render() end }),
            ui.label({ key = "kuma-url", text = data and data.baseUrl or "", flexGrow = 1, textAlign = "end", maxLines = 1, fontSize = 12, color = "on_surface_variant" }),
            ui.button({ key = "btn-refresh", glyph = "refresh", variant = "ghost", tooltip = tr("panel.tip_refresh") .. (stamp and (" · " .. stamp) or ""), onClick = requestRefresh }),
        }),
        ui.column({ key = "notices", gap = 2 }, notices()),
        ui.column({ key = "tab-dashboard", visible = tab == "dashboard", flexGrow = 1, gap = 6 }, dashChildren),
        ui.column({ key = "tab-pages", visible = tab == "pages", flexGrow = 1, gap = 6 }, pagesChildren),
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
