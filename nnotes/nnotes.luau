--!nonstrict
-- nnotes — bar widget. Left: toggle the panel; right: open the notes folder;
-- middle: copy the folder path. The glyph lights up while the panel's
-- "nnotes_open" state is true.

local PANEL_ID = "nightwatch75/nnotes:panel"

local open = false

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function notesFolder()
    local dir = noctalia.getConfig("notes_folder")
    if dir == nil or dir == "" then
        dir = (noctalia.getenv("HOME") or "/tmp") .. "/Documents/Nnotes"
    else
        dir = noctalia.expandPath(dir)
    end
    return (dir:gsub("/+$", ""))
end

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))
    local folder = notesFolder()
    if open then
        barWidget.setGlyphColor("#38bdf8")
        barWidget.setTooltip(noctalia.tr("tooltip_open", { path = folder }))
    else
        barWidget.setGlyphColor("on_surface")
        barWidget.setTooltip(noctalia.tr("tooltip_closed", { path = folder }))
    end
end

noctalia.state.watch("nnotes_open", function(value)
    open = value == true
    render()
end)

-- picks up settings changes
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
    noctalia.copyToClipboard(notesFolder(), "text/plain")
    noctalia.notify(noctalia.tr("title"), noctalia.tr("copied_path"))
end

noctalia.setUpdateInterval(1000)
render()
