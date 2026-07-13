--!nonstrict
-- To Do — a prioritised task list in an attached panel.
--
-- A task is { id, text, priority, done }. The whole list is persisted as one
-- JSON array in <todo_folder>/todo.json (noctalia.json). Empty (blank-text)
-- tasks are never written: they only exist transiently while being entered.
--
-- Display order: a stable sort by priority (important → medium → low). "Stable"
-- means equal-priority rows keep their current relative order, and `items` is
-- always kept in that display order — so changing a task's priority moves it
-- the minimum needed to satisfy the grouping and never reshuffles its peers by
-- id/name.
--
-- Interaction: a row is a static line by default. Click its text or the pencil
-- button to edit; press Enter or the ✓ button to commit back to the static
-- line. The coloured chip (with its priority word) cycles the priority. The
-- ☐/☑ button toggles done, which strikes the text through. No external
-- commands are run.
--
-- The bar widget (todo.luau) lights its glyph while the panel is open via the
-- shared "todo_open" state; it reads todo.json itself for the pending count.

local PRIORITIES = { "important", "medium", "low" }
local RANK = { important = 1, medium = 2, low = 3 }
local COLORS = { important = "#e06c75", medium = "#e5c07b", low = "#98c379" }
local FILE_NAME = "todo.json"
local AUTOSAVE_IDLE_TICKS = 2 -- 1s panel ticks with no edits before a flush

local items = {} -- array, kept in display order (stable sort by priority)
local nextId = 1 -- monotonic id source (identity only, not a sort key)
local folder = ""
local filePath = ""
local dirty = false -- unsaved inline text edits
local idleTicks = 0
local editingId = nil -- id of the row currently in edit mode (at most one)
local loaded = false -- guard so an early save() can never truncate the file

local render

-- Per-row callbacks need distinct global names; the reconciler dispatches
-- callbacks by name only. getfenv() is the script environment lua_getglobal
-- reads from, so assigning into it defines the callback the host will find.
-- Keyed by the stable id, so a callback stays valid as rows reorder.
local env = getfenv()
local function rowCallback(prefix, id, fn)
    local name = prefix .. "_" .. id
    env[name] = fn
    return name
end

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function isBlank(text)
    return noctalia.string.trim(text or "") == ""
end

local function todoFolder()
    local dir = noctalia.getConfig("todo_folder")
    if dir == nil or dir == "" then
        dir = noctalia.expandPath("~/Documents/Todo")
    else
        dir = noctalia.expandPath(dir)
    end
    return (dir:gsub("/+$", ""))
end

-- Overlay every character with U+0336 (combining long stroke) so a plain label
-- renders struck through — labels/buttons have no line-through prop.
local function strike(text)
    if text == "" then
        return ""
    end
    local out = {}
    for _, code in utf8.codes(text) do
        table.insert(out, utf8.char(code))
        table.insert(out, "\u{0336}")
    end
    return table.concat(out)
end

local function normalizePriority(value)
    return RANK[value] ~= nil and value or "medium"
end

-- Stable sort by priority: equal-priority rows keep their current relative
-- order (decorate-by-index makes table.sort stable), and the result becomes the
-- new `items` order. Called after every mutation, so `items` is always the
-- display order and re-prioritising a row only nudges it into its group.
local function sortItems()
    local decorated = {}
    for index, item in ipairs(items) do
        decorated[index] = { item = item, index = index }
    end
    table.sort(decorated, function(a, b)
        local ra, rb = RANK[a.item.priority], RANK[b.item.priority]
        if ra ~= rb then
            return ra < rb
        end
        return a.index < b.index -- stable: keep the current within-priority order
    end)
    local sorted = {}
    for index, entry in ipairs(decorated) do
        sorted[index] = entry.item
    end
    items = sorted
end

local function findItem(id)
    for _, item in ipairs(items) do
        if item.id == id then
            return item
        end
    end
    return nil
end

local function removeItem(id)
    for i, item in ipairs(items) do
        if item.id == id then
            table.remove(items, i)
            return true
        end
    end
    return false
end

local function load()
    items = {}
    nextId = 1
    local raw = noctalia.readFile(filePath)
    if raw ~= nil and raw ~= "" then
        local decoded = noctalia.json.decode(raw)
        if type(decoded) == "table" then
            for _, entry in ipairs(decoded) do
                if type(entry) == "table" then
                    local id = tonumber(entry.id) or nextId
                    table.insert(items, {
                        id = id,
                        text = type(entry.text) == "string" and entry.text or "",
                        priority = normalizePriority(entry.priority),
                        done = entry.done == true,
                    })
                    if id >= nextId then
                        nextId = id + 1
                    end
                end
            end
        end
    end
    sortItems()
    loaded = true
end

local function save()
    if not loaded then
        return -- never write before the first load reads what is on disk
    end
    -- Blank tasks are in-progress placeholders; they never reach disk.
    local toStore = {}
    for _, item in ipairs(items) do
        if not isBlank(item.text) then
            table.insert(toStore, item)
        end
    end
    local encoded = noctalia.json.encode(toStore, true)
    if encoded == nil then
        return
    end
    local ok, err = noctalia.writeFile(filePath, encoded)
    if not ok then
        noctalia.notifyError(tr("title"), err or tr("save_failed"))
        return
    end
    dirty = false
end

local function addItem()
    local item = { id = nextId, text = "", priority = "medium", done = false }
    nextId += 1
    table.insert(items, item)
    sortItems()
    editingId = item.id -- new task opens straight into edit mode
    render()
end

local function deleteItem(id)
    removeItem(id)
    if editingId == id then
        editingId = nil
    end
    save()
    render()
end

local function enterEdit(id)
    -- Leaving a still-blank row behind (e.g. a just-added task) would strand an
    -- empty line; drop it as we move focus elsewhere.
    if editingId ~= nil and editingId ~= id then
        local prev = findItem(editingId)
        if prev ~= nil and isBlank(prev.text) then
            removeItem(editingId)
        end
    end
    editingId = id
    render()
end

local function commitEdit(id, value)
    local item = findItem(id)
    if item == nil then
        return
    end
    item.text = value
    editingId = nil
    if isBlank(item.text) then
        removeItem(id) -- committing a blank task discards it
    end
    save()
    render()
end

local function toggleDone(id)
    local item = findItem(id)
    if item ~= nil then
        item.done = not item.done
        save()
        render()
    end
end

local function cyclePriority(id)
    local item = findItem(id)
    if item ~= nil then
        -- important → medium → low → important
        item.priority = PRIORITIES[(RANK[item.priority] % #PRIORITIES) + 1]
        sortItems()
        save()
        render()
    end
end

local function taskRow(item)
    local id = item.id
    local editing = editingId == id

    local chip = ui.box({
        -- priority in the key so the retained box picks up the new fill colour
        key = "chip-" .. id .. "-" .. item.priority,
        width = 16,
        height = 16,
        radius = 4,
        fill = COLORS[item.priority],
        onClick = rowCallback("todoPrio", id, function()
            cyclePriority(id)
        end),
    })
    local prioWord = ui.label({
        text = tr("prio_" .. item.priority),
        color = COLORS[item.priority],
        fontSize = 11,
        width = 76,
    })

    local children = { chip, prioWord }

    if editing then
        table.insert(children, ui.input({
            key = "text-" .. id,
            value = item.text,
            placeholder = tr("placeholder"),
            focus = true,
            flexGrow = 1,
            onChange = rowCallback("todoText", id, function(value)
                item.text = value
                dirty = true
                idleTicks = 0
            end),
            onSubmit = rowCallback("todoSubmit", id, function(value)
                commitEdit(id, value)
            end),
        }))
        -- ✓ commits the edit, mirroring Enter.
        table.insert(children, ui.button({
            glyph = "check",
            variant = "primary",
            onClick = rowCallback("todoOk", id, function()
                commitEdit(id, item.text)
            end),
        }))
    else
        -- Static text; clicking it re-opens the editor ("press on the text").
        table.insert(children, ui.button({
            key = "view-" .. id,
            text = item.done and strike(item.text) or item.text,
            variant = "ghost",
            contentAlign = "start",
            flexGrow = 1,
            onClick = rowCallback("todoEdit", id, function()
                enterEdit(id)
            end),
        }))
        -- Done toggle: strikes the text through.
        table.insert(children, ui.button({
            glyph = item.done and "square-check" or "square",
            variant = "ghost",
            onClick = rowCallback("todoDone", id, function()
                toggleDone(id)
            end),
        }))
        -- Explicit edit affordance next to the row.
        table.insert(children, ui.button({
            glyph = "pencil",
            variant = "ghost",
            onClick = rowCallback("todoPencil", id, function()
                enterEdit(id)
            end),
        }))
    end

    table.insert(children, ui.button({
        glyph = "trash",
        variant = "ghost",
        onClick = rowCallback("todoDel", id, function()
            deleteItem(id)
        end),
    }))

    return ui.row({
        -- edit/done state flips the row's controls; key it so it recreates cleanly
        key = "row-" .. id .. (editing and "-edit" or "-view") .. (item.done and "-done" or ""),
        gap = 8,
        align = "center",
    }, children)
end

render = function()
    local header = ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
        ui.button({ key = "header-add", glyph = "plus", variant = "primary", onClick = "onAdd" }),
        ui.button({ key = "header-close", glyph = "close", variant = "ghost", onClick = "onClosePanel" }),
    })

    local body
    if #items == 0 then
        body = ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
            ui.label({ text = tr("empty"), color = "on_surface_variant" }),
        })
    else
        local rows = {}
        for _, item in ipairs(items) do
            table.insert(rows, taskRow(item))
        end
        body = ui.scroll({ flexGrow = 1, gap = 6 }, rows)
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, { header, body }))
end

function onOpen(_context)
    folder = todoFolder()
    filePath = folder .. "/" .. FILE_NAME
    local ok, err = noctalia.mkdirAll(folder)
    if not ok then
        noctalia.notifyError(tr("title"), err or "")
    end
    load()
    editingId = nil
    dirty = false
    idleTicks = 0
    panel.setWantsSecondTicks(true)
    noctalia.state.set("todo_open", true)
    render()
end

function onClose()
    editingId = nil
    if dirty then
        save()
    end
    noctalia.state.set("todo_open", false)
end

function onConfigChanged()
    if dirty then
        save()
    end
    folder = todoFolder()
    filePath = folder .. "/" .. FILE_NAME
    noctalia.mkdirAll(folder)
    editingId = nil
    load()
    render()
end

function update()
    if dirty then
        idleTicks += 1
        if idleTicks >= AUTOSAVE_IDLE_TICKS then
            save()
        end
    end
end

function onAdd()
    addItem()
end

function onClosePanel()
    panel.close()
end
