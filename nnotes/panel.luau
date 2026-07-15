--!nonstrict
-- nnotes — floating panel editing a single notes file, with idle autosave.
--
-- The buffer flushes after `autosave_seconds` of idle time (0 disables the
-- timer), on Ctrl+Enter, and when the panel closes. The file is re-read on
-- every open, so external edits are picked up. The bar widget mirrors the
-- panel's open state through the shared "nnotes_open" state key.

local buffer = ""
local loadedContent = "" -- what the file held when we last read/wrote it
local dirty = false
local idleTicks = 0
local editorRev = 0 -- bumped to reseed the (uncontrolled) editor input
local filePath = ""

local render

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

local function flush()
    if not dirty or filePath == "" then
        return
    end
    local ok, err = noctalia.writeFile(filePath, buffer)
    if not ok then
        noctalia.notifyError(noctalia.tr("title"), err or noctalia.tr("save_failed"))
        return
    end
    loadedContent = buffer
    dirty = false
end

local function statusLine()
    local words = select(2, buffer:gsub("%S+", ""))
    local chars = utf8.len(buffer) or #buffer
    local status = dirty and noctalia.tr("editing") or noctalia.tr("saved")
    return status .. "  ·  " .. noctalia.tr("counts", { words = words, chars = chars })
end

render = function()
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
        ui.row({ gap = 6, align = "center" }, {
            ui.label({
                text = noctalia.tr("title"),
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
                flexGrow = 1,
            }),
            ui.button({ glyph = "folder", variant = "ghost", tooltip = noctalia.tr("tip_folder"), onClick = "onOpenFolder" }),
            ui.button({ glyph = "copy", variant = "ghost", tooltip = noctalia.tr("tip_copy"), onClick = "onCopyPath" }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("tip_close"), onClick = "onClosePanel" }),
        }),
        ui.input({
            key = "editor-" .. editorRev,
            value = buffer,
            multiline = true,
            focus = true,
            flexGrow = 1,
            placeholder = noctalia.tr("editor_placeholder"),
            onChange = "onEdited",
            onSubmit = "onFlushNow",
        }),
        ui.label({ text = statusLine(), fontSize = 11, color = "on_surface_variant" }),
    }))
end

function onOpen(_context)
    filePath = notesFile()
    local ok, err = noctalia.mkdirAll(notesFolder())
    if not ok then
        noctalia.notifyError(noctalia.tr("title"), err or "")
    end
    -- onClose flushed any edits, so reloading cannot drop anything of ours;
    -- it folds in changes made outside the panel while it was closed.
    buffer = noctalia.readFile(filePath) or ""
    loadedContent = buffer
    dirty = false
    idleTicks = 0
    editorRev += 1
    panel.setWantsSecondTicks(true)
    noctalia.state.set("nnotes_open", true)
    render()
end

function onClose()
    flush()
    noctalia.state.set("nnotes_open", false)
end

function update()
    if not dirty then
        return
    end
    local limit = tonumber(noctalia.getConfig("autosave_seconds")) or 5
    if limit <= 0 then
        return
    end
    idleTicks += 1
    if idleTicks >= limit then
        flush()
        render()
    end
end

function onEdited(value)
    buffer = value
    dirty = true
    idleTicks = 0
    -- Re-render on every edit: the status line carries the live word/char count.
    render()
end

function onFlushNow(value)
    buffer = value
    dirty = true
    flush()
    render()
end

function onOpenFolder()
    noctalia.runAsync("xdg-open " .. shellQuote(notesFolder()) .. " >/dev/null 2>&1")
end

function onCopyPath()
    noctalia.copyToClipboard(notesFile(), "text/plain")
    noctalia.notify(noctalia.tr("title"), noctalia.tr("copied_path"))
end

function onClosePanel()
    panel.close()
end
