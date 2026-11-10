--!nonstrict
-- kuma-status — panel with two tabs: Dashboard and Status pages.
-- State key: "kuma_status_open" (published for the bar glyph).
-- Skeleton only: renders a placeholder.

local function render()
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
        ui.label({ text = noctalia.tr("panel.placeholder") }),
    }))
end

function onOpen(_context)
    noctalia.state.set("kuma_status_open", true)
    render()
end

function onClose()
    noctalia.state.set("kuma_status_open", false)
end
