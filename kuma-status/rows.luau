--!nonstrict
-- kuma-status — UI builders shared by the panel tabs: a monitor row with its
-- 40-cell heartbeat bar, and a collapsible group header. Pure functions over
-- the Row/Group tables of kuma.luau; callbacks are closures (render-scoped,
-- plugin_api >= 9). Every row keeps its own stable keys ("row-<id>",
-- "dot-<id>", "name-<id>", "ping-<id>", "bar-<id>") so the reconciler diffs
-- rows by monitor, not by position.

local R = {}

R.CELLS = 40
R.COLORS = { [0] = "#e06c75", [1] = "#98c379", [2] = "#e5c07b", [3] = "#61afef" }
R.EMPTY = "#4b5263"

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
    if row.paused then return "" end
    if row.ping == nil then return "—" end
    return string.format("%d ms", math.floor(row.ping + 0.5))
end

function R.monitorRow(row, onOpen)
    local dim = row.paused
    return ui.row({ key = "row-" .. row.id, gap = 8, align = "center", paddingV = 2, onClick = function() onOpen(row.id) end }, {
        ui.box({ key = "dot-" .. row.id, width = 10, height = 10, radius = 5, fill = dim and R.EMPTY or (R.COLORS[row.status] or R.EMPTY) }),
        ui.label({ key = "name-" .. row.id, text = row.name, flexGrow = 1, maxLines = 1, color = dim and "on_surface_variant" or "on_surface" }),
        ui.label({ key = "ping-" .. row.id, text = pingText(row), width = 64, textAlign = "end", color = "on_surface_variant" }),
        R.beatBar(row.beats, "bar-" .. row.id),
    })
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
