--!nonstrict
-- file-search — the Space tab of the panel: a disk-usage browser.
--
-- Role: a module required by panel.luau (never an entry of its own). The panel
-- calls onOpen()/onClose() with its own lifecycle and embeds whatever
-- render() returns under the tab bar. Stub for now; the scan engine and the
-- treemap arrive in later steps.

local space = {}

function space.onOpen() end

function space.onClose() end

function space.render()
    return ui.label({
        key = "space",
        text = noctalia.tr("space_placeholder"),
        color = "on_surface_variant",
        flexGrow = 1,
    })
end

return space
