--!nonstrict
-- nnotes — bar widget that toggles the nnotes editor panel.
--
-- The panel (panel.luau) publishes its open state on the shared
-- "nnotes_open" state key; the glyph lights up while it is open.
--
-- Click mapping:
--   Left click   — open/close the note panel
--   Right click  — open the notes folder in the file manager
--   Middle click — copy the notes file path to the clipboard

local PANEL_ID = "nightwatch75/nnotes:panel"

local open = false

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function notesFolder()
    local dir = noctalia.getConfig("notes_folder")
    if dir == nil or dir == "" then
        dir = (noctalia.getenv("HOME") or "/tmp") .. "/Notes"
    else
        dir = noctalia.expandPath(dir)
    end
    return (dir:gsub("/+$", ""))
end

local function notesFile()
    local name = noctalia.getConfig("file_name")
    if name == nil or name == "" then
        name = "notes.txt"
    end
    return notesFolder() .. "/" .. name
end

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))
    local file = notesFile()
    if open then
        barWidget.setGlyphColor("primary")
        barWidget.setTooltip(noctalia.tr("tooltip_open", { path = file }))
    else
        barWidget.setGlyphColor("on_surface")
        barWidget.setTooltip(noctalia.tr("tooltip_closed", { path = file }))
    end
end

noctalia.state.watch("nnotes_open", function(value)
    open = value == true
    render()
end)

-- Periodic re-render keeps the glyph and tooltip in sync with settings changes.
function update()
    render()
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
    noctalia.runAsync("xdg-open " .. shellQuote(notesFolder()) .. " >/dev/null 2>&1")
end

function onMiddleClick()
    noctalia.copyToClipboard(notesFile(), "text/plain")
    noctalia.notify(noctalia.tr("title"), noctalia.tr("copied_path"))
end

noctalia.setUpdateInterval(1000)
render()
