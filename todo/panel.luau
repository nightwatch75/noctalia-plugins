--!nonstrict
-- To Do — a prioritised task list in an attached panel.
--
-- A task is { id, text, priority, done }. The whole list is persisted as one
-- JSON array in <todo_folder>/todo.json (noctalia.json). Rows are kept sorted
-- by priority (important → medium → low), stable within a priority by creation
-- order (the monotonic id). An active task is an editable input; a completed
-- task becomes a struck-through, dimmed label until it is un-done. Clicking a
-- row's colour chip cycles its priority. No external commands are run.
--
-- The bar widget (todo.luau) lights its glyph while the panel is open via the
-- shared "todo_open" state; it reads todo.json itself for the pending count.

local PRIORITIES = { "important", "medium", "low" }
local RANK = { important = 1, medium = 2, low = 3 }
local COLORS = { important = "#e06c75", medium = "#e5c07b", low = "#98c379" }
local FILE_NAME = "todo.json"
local AUTOSAVE_IDLE_TICKS = 2 -- 1s panel ticks with no edits before a flush

local items = {} -- array of { id, text, priority, done }
local nextId = 1 -- monotonic; also the stable within-priority sort key
local folder = ""
local filePath = ""
local dirty = false -- unsaved inline text edits
local idleTicks = 0
local focusId = nil -- id of a freshly added row to focus once
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
-- renders struck through — ui.label has no line-through prop.
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

local function sortItems()
    table.sort(items, function(a, b)
        local ra, rb = RANK[a.priority], RANK[b.priority]
        if ra ~= rb then
            return ra < rb
        end
        return a.id < b.id -- stable: creation order within a priority
    end)
end

local function findItem(id)
    for _, item in ipairs(items) do
        if item.id == id then
            return item
        end
    end
    return nil
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
    local encoded = noctalia.json.encode(items, true)
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
    focusId = item.id
    sortItems()
    save()
    render()
end

local function deleteItem(id)
    for i, item in ipairs(items) do
        if item.id == id then
            table.remove(items, i)
            break
        end
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

    local middle
    if item.done then
        middle = ui.label({
            text = item.text ~= "" and strike(item.text) or tr("placeholder"),
            color = "on_surface_variant",
            flexGrow = 1,
        })
    else
        middle = ui.input({
            key = "text-" .. id,
            value = item.text,
            placeholder = tr("placeholder"),
            focus = focusId == id,
            flexGrow = 1,
            onChange = rowCallback("todoText", id, function(value)
                item.text = value
                dirty = true
                idleTicks = 0
            end),
            onSubmit = rowCallback("todoSubmit", id, function(value)
                item.text = value
                save()
            end),
        })
    end

    return ui.row({
        -- done state flips input<->label; key it so the row is recreated cleanly
        key = "row-" .. id .. (item.done and "-done" or "-todo"),
        gap = 8,
        align = "center",
    }, {
        chip,
        middle,
        ui.button({
            glyph = item.done and "square-check" or "square",
            variant = "ghost",
            onClick = rowCallback("todoDone", id, function()
                toggleDone(id)
            end),
        }),
        ui.button({
            glyph = "trash",
            variant = "ghost",
            onClick = rowCallback("todoDel", id, function()
                deleteItem(id)
            end),
        }),
    })
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
    focusId = nil
    dirty = false
    idleTicks = 0
    panel.setWantsSecondTicks(true)
    noctalia.state.set("todo_open", true)
    render()
end

function onClose()
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
