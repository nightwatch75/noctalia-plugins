--!nonstrict
-- kuma-status — UI builders shared by the panel tabs: a monitor row with its
-- 40-cell heartbeat bar and optional certificate line, and a collapsible group
-- header. Pure functions over the Row/Group tables of kuma.luau; callbacks are
-- closures (render-scoped, plugin_api >= 9). Keys: "row-<id>" (the column, also
-- the tooltip carrier: the check's URL), "dot-", "name-" (a ghost button: only
-- a button's onRightClick can raise the context menu), "ping-", "bar-",
-- "cert-<id>" with "cert-glyph-" / "cert-text-".

local R = {}

R.CELLS = 40
R.COLORS = { [0] = "#e06c75", [1] = "#98c379", [2] = "#e5c07b", [3] = "#61afef" }
R.EMPTY = "#4b5263"
-- Name button width: panel 640 - 2*14 padding - 14 scrollbar - dot 10 - ping 64
-- - bar (40*4 + 39) - 3 gaps of 8. Keep in sync with [[panel]] width.
local NAME_W = 300

-- Always exactly CELLS boxes, oldest left; missing history shows as neutral
-- cells on the left so every bar has the same width.
function R.beatBar(beats, key)
    local n = #beats
    local first = math.max(1, n - R.CELLS + 1)
    local used = n - first + 1
    local cells = {}
    for _ = 1, R.CELLS - used do
        cells[#cells + 1] = ui.box({ width = 4, height = 14, radius = 1, fill = R.EMPTY, opacity = 0.5 })
    end
    local up = 0
    for i = first, n do
        if beats[i] == 1 then up += 1 end
        cells[#cells + 1] = ui.box({ width = 4, height = 14, radius = 1, fill = R.COLORS[beats[i]] or R.EMPTY })
    end
    local tip = nil
    if used > 0 then tip = noctalia.tr("panel.tip_bar", { up = up, total = used }) end
    return ui.row({ key = key, gap = 1, tooltip = tip }, cells)
end

local function pingText(row)
    if row.paused or row.noPing then return "" end
    if row.ping == nil then return "—" end
    return string.format("%d ms", math.floor(row.ping + 0.5))
end

-- Days left to colors: more than 30 green, more than 7 yellow, else red.
local function certLine(row)
    local days = math.floor(row.certDays)
    local color = days > 30 and R.COLORS[1] or (days > 7 and R.COLORS[2] or R.COLORS[0])
    local text = days < 0 and noctalia.tr("panel.cert_expired") or noctalia.tr("panel.cert_days", { days = days })
    return ui.row({ key = "cert-" .. row.id, gap = 4, align = "center" }, {
        ui.box({ width = 18 }),
        ui.glyph({ key = "cert-glyph-" .. row.id, name = "certificate", size = 12, color = color }),
        ui.label({ key = "cert-text-" .. row.id, text = text, fontSize = 11, color = "on_surface_variant" }),
    })
end

-- onOpen(id): left click on the name. onMenu(row): right click, nil to disable.
function R.monitorRow(row, onOpen, onMenu)
    local id = row.id
    local main = ui.row({ gap = 8, align = "center", paddingV = 2 }, {
        ui.box({ key = "dot-" .. id, width = 10, height = 10, radius = 5, fill = row.paused and R.EMPTY or (R.COLORS[row.status] or R.EMPTY) }),
        ui.button({
            key = "name-" .. id, text = row.name, variant = "ghost", contentAlign = "start", width = NAME_W,
            onClick = function() onOpen(id) end,
            onRightClick = onMenu and function() onMenu(row) end or nil,
        }),
        ui.label({ key = "ping-" .. id, text = pingText(row), width = 64, textAlign = "end", color = "on_surface_variant" }),
        R.beatBar(row.beats, "bar-" .. id),
    })
    local children = { main }
    if row.certDays ~= nil and not row.paused then children[2] = certLine(row) end
    return ui.column({ key = "row-" .. id, gap = 0, opacity = row.paused and 0.55 or 1, tooltip = row.url }, children)
end

function R.groupKey(group)
    return group.name ~= "" and group.name or "_none"
end

function R.groupHeader(group, collapsed, onToggle)
    local key = R.groupKey(group)
    local label = group.name ~= "" and group.name or noctalia.tr("panel.group_none")
    local uptime = group.uptime1d and string.format("%.1f%%", group.uptime1d * 100) or ""
    return ui.row({ key = "gh-" .. key, gap = 8, align = "center", paddingV = 4, fill = "surface_variant", radius = 6, paddingH = 8, onClick = function() onToggle(key) end }, {
        ui.label({ text = collapsed and "▶" or "▼", width = 14 }),
        ui.label({ text = label, flexGrow = 1, maxLines = 1, fontWeight = "semibold" }),
        ui.label({ text = group.up .. "/" .. group.total, color = "on_surface_variant" }),
        ui.label({ text = uptime, width = 56, textAlign = "end", color = "on_surface_variant" }),
    })
end

return R
