--!nonstrict
-- nnotes — panel: notes list on the left, editor on the right.
--
-- One .md/.txt file per note in `notes_folder`. Pins, manual order and sort
-- mode live in `.nnotes.json` next to them. The buffer is written on idle
-- (`autosave_seconds`), Save/Ctrl+Enter, note switch and close. A new note
-- (`current == nil`) is created on its first non-empty write.
-- Search matches file names at once and, with `grep`, file content (async,
-- nonce-stamped). The bar widget follows the "nnotes_open" state key.

local MAX_NOTES = 100

local notes = {} -- { name, mtime, rank, pinned }, in display order
local current = nil -- open note file name; nil = new, not yet written
local buffer = ""
local dirty = false
local idleTicks = 0
local editorRev = 0 -- bump to reseed the uncontrolled inputs
local query = ""
local contentHits = nil -- set of names matching the query by content
local searchNonce = 0
local confirmDelete = false
local nameDraft = nil -- name field text not yet applied
local meta = { order = {}, pinned = {}, sort = "manual" }
local SORTS = { "manual", "name_az", "name_za", "date" }
local DRAG_TYPE = "nnotes-note"

local render

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

local function pathOf(name)
    return notesFolder() .. "/" .. name
end

local function isNoteName(name)
    return name:sub(1, 1) ~= "." and (name:sub(-3) == ".md" or name:sub(-4) == ".txt")
end

local function stem(name)
    return (name:gsub("%.%w+$", ""))
end

local function metaPath()
    return notesFolder() .. "/.nnotes.json"
end

local function loadMeta()
    meta = { order = {}, pinned = {}, sort = "manual" }
    local raw = noctalia.readFile(metaPath())
    local data = raw and noctalia.json.decode(raw)
    if type(data) == "table" then
        if type(data.order) == "table" then
            for _, name in ipairs(data.order) do
                if type(name) == "string" then
                    table.insert(meta.order, name)
                end
            end
        end
        for _, mode in ipairs(SORTS) do
            if data.sort == mode then
                meta.sort = mode
            end
        end
        if type(data.pinned) == "table" then
            for _, name in ipairs(data.pinned) do
                if type(name) == "string" then
                    meta.pinned[name] = true
                end
            end
        end
    end
end

local function saveMeta()
    local pinned = {}
    for name in pairs(meta.pinned) do
        table.insert(pinned, name)
    end
    table.sort(pinned)
    local ok, err = noctalia.writeFile(metaPath(), noctalia.json.encode({ order = meta.order, pinned = pinned, sort = meta.sort }))
    if not ok then
        noctalia.notifyError(noctalia.tr("title"), err or noctalia.tr("save_failed"))
    end
end

local function refreshList()
    local names = noctalia.listDir(notesFolder()) or {}
    local rank = {}
    for i, name in ipairs(meta.order) do
        rank[name] = i
    end
    notes = {}
    for _, name in ipairs(names) do
        if isNoteName(name) and #notes < MAX_NOTES then
            local info = noctalia.fileInfo(pathOf(name))
            if info ~= nil and not info.isDir then
                table.insert(notes, { name = name, mtime = info.mtime, rank = rank[name] or 0, pinned = meta.pinned[name] == true })
            end
        end
    end
    -- Pinned first. Manual: rank 0 (not ordered yet) sorts on top, newest first.
    local sort = meta.sort
    table.sort(notes, function(a, b)
        if a.pinned ~= b.pinned then
            return a.pinned
        end
        if sort == "name_az" or sort == "name_za" then
            local x, y = a.name:lower(), b.name:lower()
            if x ~= y then
                return (sort == "name_az") == (x < y)
            end
        elseif sort == "manual" and a.rank ~= b.rank then
            return a.rank < b.rank
        end
        return a.mtime > b.mtime
    end)
end

local function freshName()
    local base = os.date("%Y%m%d-%H%M%S")
    local name = base .. ".md"
    local n = 2
    while noctalia.fileExists(pathOf(name)) do
        name = base .. "-" .. n .. ".md"
        n += 1
    end
    return name
end

local function flush()
    if not dirty then
        return
    end
    if current == nil then
        if buffer:match("%S") == nil then
            dirty = false
            return
        end
        current = freshName()
    end
    local ok, err = noctalia.writeFile(pathOf(current), buffer)
    if not ok then
        noctalia.notifyError(noctalia.tr("title"), err or noctalia.tr("save_failed"))
        return
    end
    dirty = false
    refreshList()
end

local function load(name)
    flush()
    current = name
    buffer = name and (noctalia.readFile(pathOf(name)) or "") or ""
    dirty = false
    idleTicks = 0
    confirmDelete = false
    nameDraft = nil
    editorRev += 1
end

local function visibleNotes()
    if query == "" then
        return notes
    end
    local needle = query:lower()
    local out = {}
    for _, note in ipairs(notes) do
        if note.name:lower():find(needle, 1, true) or (contentHits and contentHits[note.name]) then
            table.insert(out, note)
        end
    end
    return out
end

local function statusLine()
    local words = select(2, buffer:gsub("%S+", ""))
    local chars = utf8.len(buffer) or #buffer
    local status = dirty and noctalia.tr("editing") or noctalia.tr("saved")
    return status .. "  ·  " .. noctalia.tr("counts", { words = words, chars = chars })
end

local function insertionZone(index)
    return ui.dropZone({
        key = "gap-" .. index,
        accepts = { DRAG_TYPE },
        value = tostring(index),
        onDrop = "onNoteDrop",
        height = 3,
        radius = 6,
        expandOnDrag = true,
        hitSlop = 14,
    })
end

local function listColumn()
    local rows = {}
    local shown = visibleNotes()
    local reorder = query == "" and meta.sort == "manual"
    if reorder and #shown > 0 then
        table.insert(rows, insertionZone(0))
    end
    for i, note in ipairs(shown) do
        local name = note.name
        local cells = {}
        if reorder then
            table.insert(cells, ui.dragSource({
                key = "grip-" .. name,
                dragType = DRAG_TYPE,
                payload = name,
                previewAncestor = 1,
                liftFromLayout = true,
                width = 22,
                height = 28,
                align = "center",
                justify = "center",
                tooltip = noctalia.tr("tip_grip"),
            }, {
                ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
            }))
        end
        table.insert(cells, ui.button({
            key = "note-" .. name,
            text = stem(name),
            variant = "ghost",
            contentAlign = "start",
            flexGrow = 1,
            selected = name == current,
            onClick = function()
                load(name)
                render()
            end,
        }))
        table.insert(cells, ui.button({
            key = "pin-" .. name,
            glyph = "pin",
            variant = "ghost",
            controlSize = "sm",
            selected = note.pinned,
            tooltip = noctalia.tr(note.pinned and "tip_unpin" or "tip_pin"),
            onClick = function()
                onTogglePin(name)
            end,
        }))
        table.insert(rows, ui.row({ key = "row-" .. name, gap = 2, align = "center" }, cells))
        if reorder then
            table.insert(rows, insertionZone(i))
        end
    end
    if #rows == 0 then
        table.insert(rows, ui.label({ text = noctalia.tr("no_notes"), fontSize = 12, color = "on_surface_variant" }))
    end
    return ui.column({ width = 270, gap = 8, align = "stretch" }, {
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "search",
                value = query,
                placeholder = noctalia.tr("search_placeholder"),
                flexGrow = 1,
                controlSize = "sm",
                onChange = "onSearch",
            }),
            ui.button({ glyph = "plus", variant = "primary", controlSize = "sm", tooltip = noctalia.tr("tip_new"), onClick = "onNewNote" }),
        }),
        ui.button({
            glyph = "arrows-sort",
            text = noctalia.tr("sort_" .. meta.sort),
            variant = "ghost",
            controlSize = "sm",
            contentAlign = "start",
            tooltip = noctalia.tr("tip_sort"),
            onClick = "onCycleSort",
        }),
        ui.scroll({ flexGrow = 1, gap = 2, align = "stretch" }, rows),
    })
end

local function editorColumn()
    local pinned = current ~= nil and meta.pinned[current] == true
    local header = {
        ui.input({
            key = "name-" .. editorRev .. "-" .. (current or ""),
            value = current and stem(current) or "",
            placeholder = noctalia.tr("name_placeholder"),
            flexGrow = 1,
            controlSize = "sm",
            onChange = "onNameEdited",
            onSubmit = "onRename",
        }),
    }
    if confirmDelete then
        table.insert(header, ui.button({ text = noctalia.tr("delete_confirm"), variant = "destructive", controlSize = "sm", onClick = "onDeleteYes" }))
        table.insert(header, ui.button({ text = noctalia.tr("cancel"), variant = "ghost", controlSize = "sm", onClick = "onDeleteNo" }))
    else
        table.insert(header, ui.button({ glyph = "device-floppy", variant = "primary", controlSize = "sm", tooltip = noctalia.tr("tip_save"), onClick = "onSaveNow" }))
        table.insert(header, ui.button({
            glyph = "trash",
            variant = "ghost",
            controlSize = "sm",
            tooltip = noctalia.tr(pinned and "tip_delete_pinned" or "tip_delete"),
            enabled = current ~= nil and not pinned,
            onClick = "onDeleteAsk",
        }))
        table.insert(header, ui.button({ glyph = "folder", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("tip_folder"), onClick = "onOpenFolder" }))
        table.insert(header, ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("tip_settings"), onClick = "onOpenSettings" }))
        table.insert(header, ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("tip_close"), onClick = "onClosePanel" }))
    end
    return ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
        ui.row({ gap = 6, align = "center" }, header),
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
    })
end

render = function()
    panel.render(ui.row({ flexGrow = 1, gap = 12, align = "stretch" }, {
        listColumn(),
        editorColumn(),
    }))
end

function onOpen(_context)
    local ok, err = noctalia.mkdirAll(notesFolder())
    if not ok then
        noctalia.notifyError(noctalia.tr("title"), err or "")
    end
    loadMeta()
    refreshList()
    query = ""
    contentHits = nil
    load(notes[1] and notes[1].name or nil)
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
    -- the status line shows live counts
    render()
end

function onFlushNow(value)
    buffer = value
    dirty = true
    flush()
    render()
end

function onNewNote()
    load(nil)
    render()
end

function onSearch(value)
    query = value
    contentHits = nil
    searchNonce += 1
    local nonce = searchNonce
    if query ~= "" and noctalia.commandExists("grep") then
        noctalia.runAsync({ "grep", "-rliF", "--include=*.md", "--include=*.txt", "--", query, notesFolder() }, function(result)
            if nonce ~= searchNonce then
                return
            end
            contentHits = {}
            for line in result.stdout:gmatch("[^\n]+") do
                contentHits[line:match("[^/]+$")] = true
            end
            render()
        end, 3000)
    end
    render()
end

function onNameEdited(value)
    nameDraft = value
end

-- Keeps the extension; strips "/" and leading dots so the name stays inside the folder and visible.
local function applyName(value)
    if current == nil then
        return
    end
    local clean = value:gsub("[/\n\r]", ""):gsub("^[%.%s]+", ""):gsub("%s+$", "")
    if clean == "" then
        return
    end
    local newName = clean .. current:match("%.%w+$")
    if newName == current then
        return
    end
    flush()
    if noctalia.fileExists(pathOf(newName)) then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("name_taken"))
        return
    end
    local ok, err = noctalia.renameFile(pathOf(current), pathOf(newName))
    if not ok then
        noctalia.notifyError(noctalia.tr("title"), err or noctalia.tr("save_failed"))
        return
    end
    for i, name in ipairs(meta.order) do
        if name == current then
            meta.order[i] = newName
        end
    end
    if meta.pinned[current] then
        meta.pinned[current] = nil
        meta.pinned[newName] = true
    end
    saveMeta()
    current = newName
    nameDraft = nil
    refreshList()
end

function onRename(value)
    applyName(value)
    render()
end

function onSaveNow()
    flush()
    if nameDraft ~= nil then
        applyName(nameDraft)
    end
    render()
end

function onCycleSort()
    for i, mode in ipairs(SORTS) do
        if mode == meta.sort then
            meta.sort = SORTS[i % #SORTS + 1]
            break
        end
    end
    saveMeta()
    refreshList()
    render()
end

function onTogglePin(name)
    if meta.pinned[name] then
        meta.pinned[name] = nil
    else
        meta.pinned[name] = true
    end
    saveMeta()
    refreshList()
    render()
end

-- `value` = rows above the gap
function onNoteDrop(payload, value)
    local to = tonumber(value)
    local from = nil
    local names = {}
    for i, note in ipairs(notes) do
        names[i] = note.name
        if note.name == payload then
            from = i
        end
    end
    if from == nil or to == nil then
        return
    end
    table.remove(names, from)
    table.insert(names, (from <= to) and to or (to + 1), payload)
    meta.order = names
    saveMeta()
    refreshList()
    render()
end

function onDeleteAsk()
    confirmDelete = true
    render()
end

function onDeleteNo()
    confirmDelete = false
    render()
end

function onDeleteYes()
    if current == nil or meta.pinned[current] then
        return
    end
    local ok, err = noctalia.removeFile(pathOf(current))
    if not ok then
        noctalia.notifyError(noctalia.tr("title"), err or "")
    else
        for i = #meta.order, 1, -1 do
            if meta.order[i] == current then
                table.remove(meta.order, i)
            end
        end
        saveMeta()
    end
    dirty = false
    current = nil
    refreshList()
    load(notes[1] and notes[1].name or nil)
    render()
end

function onOpenFolder()
    noctalia.runAsync("xdg-open " .. shellQuote(notesFolder()) .. " >/dev/null 2>&1")
end

function onOpenSettings()
    noctalia.openSettings()
end

function onClosePanel()
    panel.close()
end
