--!nonstrict
-- dns-switcher — provider panel. Pure renderer over the shared state: the
-- service entry (service.luau) publishes "dns_state" and executes the
-- "apply_request" entries this panel emits. Picking a provider applies it
-- immediately (one nmcli change, no reactivation).

local snapshot = nil -- last "dns_state" published by the service

local render

-- Per-row callbacks need distinct global names; the reconciler dispatches
-- callbacks by name only. getfenv() is the script environment lua_getglobal
-- reads from, so assigning into it defines the callback the host will find.
local env = getfenv()
local function rowCallback(prefix, index, fn)
    local name = prefix .. "_" .. index
    env[name] = fn
    return name
end

local function tr(key, args)
    return noctalia.tr(key, args)
end

-- The nonce is monotonic across writers (widget instances and the panel):
-- each seeds from the last request in the shared state.
local function requestApply(entry)
    if snapshot == nil or snapshot.changing == true then
        return
    end
    local prev = noctalia.state.get("apply_request")
    local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
    noctalia.state.set("apply_request", {
        nonce = nonce,
        id = entry.id,
        label = entry.label,
        ip = entry.ip,
    })
end

local function providerRow(entry, index)
    local active = snapshot.current ~= nil and snapshot.current.id == entry.id
    return ui.button({
        key = "dns-" .. entry.id .. (active and "-on" or ""),
        glyph = entry.glyph,
        text = entry.label,
        variant = active and "primary" or "ghost",
        contentAlign = "start",
        onClick = rowCallback("dnsPick", index, function()
            if not active then
                requestApply(entry)
            end
        end),
    })
end

local function statusFooter()
    if snapshot.changing == true then
        return ui.label({ text = tr("status_switching"), fontSize = 11, color = "secondary" })
    end
    local servers = snapshot.servers
    if servers == nil or servers == "" then
        servers = tr("status_auto")
    end
    local caption = servers
    if snapshot.conName ~= nil and snapshot.conName ~= "" then
        caption = snapshot.conName .. "  ·  " .. servers
    end
    return ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = caption, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
        ui.button({ glyph = "copy", variant = "ghost", onClick = "onCopyServers" }),
    })
end

render = function()
    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({
                text = tr("title"),
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
                flexGrow = 1,
            }),
            ui.button({ glyph = "close", variant = "ghost", onClick = "onClosePanel" }),
        }),
    }

    if snapshot == nil or snapshot.list == nil then
        table.insert(children, ui.label({ text = tr("status_checking"), color = "on_surface_variant" }))
    elseif snapshot.error ~= nil then
        table.insert(children, ui.label({ text = snapshot.error, color = "error" }))
    else
        local rows = {}
        for index, entry in ipairs(snapshot.list) do
            table.insert(rows, providerRow(entry, index))
        end
        table.insert(children, ui.scroll({ flexGrow = 1, gap = 4 }, rows))
        table.insert(children, statusFooter())
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

function onOpen(_context)
    snapshot = noctalia.state.get("dns_state")
    render()
end

noctalia.state.watch("dns_state", function(value)
    if type(value) == "table" then
        snapshot = value
        render()
    end
end)

function onCopyServers()
    if snapshot == nil then
        return
    end
    local text = snapshot.servers
    if (text == nil or text == "") and snapshot.current ~= nil then
        text = snapshot.current.ip
    end
    if text == nil or text == "" then
        return
    end
    noctalia.copyToClipboard(text, "text/plain")
    noctalia.notify(tr("title"), tr("copied", { ip = text }))
end

function onClosePanel()
    panel.close()
end
