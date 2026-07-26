--!nonstrict
-- To Do — a prioritised task list in an attached panel.
--
-- A task is { id, text, priority, done, uid? }. It is persisted in one of two
-- formats under <todo_folder>, chosen by the `storage` setting (see the storage
-- backends section below): the default single todo.json, or one iCalendar VTODO
-- file per task for CalDAV-compatible sync. In both, tasks are held in manual
-- order and `sort` records the display mode. Empty (blank-text) tasks are never
-- written: they only exist transiently while being entered.
--
-- Ordering has two modes, switched from a header toggle. `items` (and the disk
-- array) hold the manual order in both; priority mode is a VIEW — a stable sort
-- applied at render time only — so switching modes never rewrites the user's
-- manual order:
--   * "priority" — rows display sorted important → medium → low; equal-priority
--     rows keep their manual relative order. No drag handles are shown.
--   * "manual" — the stored order is shown verbatim. A ☰ grip on each row
--     drags it to a new position (declarative drag-and-drop, plugin_api >= 5):
--     grab the grip and drop onto one of the thin insertion zones between rows.
--     Changing a priority only recolours the chip and never moves the row.
--
-- Interaction: a row is a static line by default. Click its text or the pencil
-- button to edit; press Enter or the ✓ button to commit back to the static
-- line. The coloured chip cycles the priority (a legend at the foot of the
-- panel maps each colour to its category). The ☐/☑ button toggles done, which
-- strikes the text through. A header trash button deletes every done row after
-- an inline confirmation strip (confirm/cancel) — the plugin UI has no dialog
-- primitive. No external commands are run.
--
-- The bar widget (todo.luau) lights its glyph while the panel is open via the
-- shared "todo_open" state; it reads todo.json itself for the pending count.

local PRIORITIES = { "important", "medium", "low" }
local RANK = { important = 1, medium = 2, low = 3 }
local COLORS = { important = "#e06c75", medium = "#e5c07b", low = "#98c379" }
local FILE_NAME = "todo.json"
local AUTOSAVE_IDLE_TICKS = 2 -- 1s panel ticks with no edits before a flush
local DRAG_TYPE = "todo-row" -- drag identifier matched by the row drop zones

local items = {} -- array, ALWAYS in manual order (priority mode sorts a copy for display)
local nextId = 1 -- monotonic id source (identity only, not a sort key)
local folder = ""
local filePath = ""
local dirty = false -- unsaved inline text edits
local idleTicks = 0
local editingId = nil -- id of the row currently in edit mode (at most one)
local loaded = false -- guard so an early save() can never truncate the file
local sortMode = "priority" -- "priority" (auto sort) or "manual" (drag reorder)
local confirmingClear = false -- header trash pressed, awaiting confirm/cancel

local render

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
-- utf8.codes THROWS on invalid UTF-8, and render() would re-raise it on every
-- frame until the host disables the plugin; utf8.len returns nil instead, so
-- gate on it and fall back to the plain text (the ☑ still marks it done).
local function strike(text)
    if text == "" or utf8.len(text) == nil then
        return text
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

-- The rows to render, in display order. `items` itself is never reordered by
-- priority mode: it sorts a COPY (stable by priority via decorate-by-index, so
-- equal-priority rows keep their manual relative order). Keeping the sort out
-- of the model is what preserves the manual order across mode switches.
local function displayItems()
    if sortMode ~= "priority" then
        return items
    end
    local decorated = {}
    for index, item in ipairs(items) do
        decorated[index] = { item = item, index = index }
    end
    table.sort(decorated, function(a, b)
        local ra, rb = RANK[a.item.priority], RANK[b.item.priority]
        if ra ~= rb then
            return ra < rb
        end
        return a.index < b.index -- stable: keep the manual within-priority order
    end)
    local sorted = {}
    for index, entry in ipairs(decorated) do
        sorted[index] = entry.item
    end
    return sorted
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

-- ── Storage backends ─────────────────────────────────────────────────────────
-- Two on-disk formats, chosen by the `storage` setting:
--   * "json"  — the whole list in one todo.json (default; legacy plain array
--     still read). filePath points at it.
--   * "ical"  — one RFC 5545 VTODO per task at <folder>/<uid>.ics (a "vdir",
--     the layout Radicale/vdirsyncer use). Manual order + sort mode live in a
--     .order.json sidecar (VTODO has no ordering property). Sync-friendly:
--     file-sync tools (Syncthing) replicate per file, and a CalDAV server
--     (Radicale) can serve the folder to tasks.org/DAVx5.

local function storageMode()
    return noctalia.getConfig("storage") == "ical" and "ical" or "json"
end

-- JSON backend (todo.json) ----------------------------------------------------

local function loadJson()
    items = {}
    nextId = 1
    sortMode = "priority"
    local raw = noctalia.readFile(filePath)
    if raw ~= nil and raw ~= "" then
        local decoded = noctalia.json.decode(raw)
        local list = nil
        if type(decoded) == "table" then
            -- Object form { version, sort, tasks }; a legacy plain array has no
            -- `tasks` key and is read as-is (manual order, priority sort).
            if decoded.tasks ~= nil then
                if decoded.sort == "manual" or decoded.sort == "priority" then
                    sortMode = decoded.sort
                end
                list = decoded.tasks
            else
                list = decoded
            end
        end
        if type(list) == "table" then
            for _, entry in ipairs(list) do
                if type(entry) == "table" then
                    local id = tonumber(entry.id) or nextId
                    table.insert(items, {
                        id = id,
                        text = type(entry.text) == "string" and entry.text or "",
                        priority = normalizePriority(entry.priority),
                        done = entry.done == true,
                        uid = type(entry.uid) == "string" and entry.uid or nil,
                    })
                    if id >= nextId then
                        nextId = id + 1
                    end
                end
            end
        end
    end
    -- The on-disk order IS the manual order; priority mode sorts at render time.
    loaded = true
end

local function saveJson()
    -- Blank tasks are in-progress placeholders; they never reach disk.
    local toStore = {}
    for _, item in ipairs(items) do
        if not isBlank(item.text) then
            table.insert(toStore, item)
        end
    end
    local encoded = noctalia.json.encode({ version = 2, sort = sortMode, tasks = toStore }, true)
    if encoded == nil then
        return
    end
    local ok, err = noctalia.writeFile(filePath, encoded)
    if not ok then
        noctalia.notifyError(tr("title"), err or tr("save_failed"))
    end
end

-- iCalendar (VTODO vdir) backend ----------------------------------------------

-- iCalendar PRIORITY is 1 (highest)..9 (lowest); 0/absent = undefined.
local ICAL_PRIO = { important = 1, medium = 5, low = 9 }
local function priorityFromIcal(n)
    n = tonumber(n)
    if n == nil or n == 0 then return "medium" end
    if n <= 4 then return "important" end
    if n == 5 then return "medium" end
    return "low"
end

local function icalEscape(s)
    return (s:gsub("\\", "\\\\"):gsub(";", "\\;"):gsub(",", "\\,"):gsub("\r?\n", "\\n"))
end

-- Single pass so an escaped backslash is never re-interpreted.
local function icalUnescape(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "\\" and i < n then
            local d = s:sub(i + 1, i + 1)
            if d == "n" or d == "N" then
                table.insert(out, "\n")
            else
                table.insert(out, d) -- \\, \;, \, and any other escaped char
            end
            i += 2
        else
            table.insert(out, c)
            i += 1
        end
    end
    return table.concat(out)
end

-- Fold a content line to <=75 octets, continuation with CRLF + space (RFC 5545
-- §3.1). Byte boundaries are spec-correct: unfolding rejoins the exact bytes.
local function fold(line)
    if #line <= 75 then return line end
    local parts, i = {}, 1
    while i <= #line do
        local n = (i == 1) and 75 or 74
        table.insert(parts, line:sub(i, i + n - 1))
        i += n
    end
    return table.concat(parts, "\r\n ")
end

-- Unfold: continuation lines (leading space/tab) join onto the previous one.
local function unfold(raw)
    local logical = {}
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        line = (line:gsub("\r$", ""))
        if (line:sub(1, 1) == " " or line:sub(1, 1) == "\t") and #logical > 0 then
            logical[#logical] = logical[#logical] .. line:sub(2)
        else
            table.insert(logical, line)
        end
    end
    return logical
end

-- Floating local timestamp (no Z): no UTC conversion is available in-sandbox,
-- and CalDAV servers/task apps accept floating DATE-TIME for these fields.
local function nowStamp()
    return noctalia.formatTime("%Y%m%dT%H%M%S")
end

-- UID = <time>-<rand>-<counter>@noctalia-todo. Time + counter keep it unique on
-- this device across sessions; the random part separates tasks made in the same
-- second; callers also collision-check against the existing set.
local uidCounter = 0
local rngSeeded = false
local function newUid(existing)
    if not rngSeeded then
        math.randomseed((tonumber(noctalia.formatTime("%H%M%S")) or 1) + #items)
        rngSeeded = true
    end
    while true do
        uidCounter += 1
        local uid = string.format("%s-%04x-%d@noctalia-todo",
            noctalia.formatTime("%Y%m%d%H%M%S"), math.random(0, 0xffff), uidCounter)
        if existing == nil or existing[uid] == nil then
            return uid
        end
    end
end

local function serializeVtodo(item)
    local lines = {
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//nightwatch75//todo//EN",
        "BEGIN:VTODO",
        "UID:" .. item.uid,
        "DTSTAMP:" .. nowStamp(),
        "SUMMARY:" .. icalEscape(item.text),
        "PRIORITY:" .. tostring(ICAL_PRIO[item.priority] or 5),
    }
    if item.done then
        table.insert(lines, "STATUS:COMPLETED")
        table.insert(lines, "PERCENT-COMPLETE:100")
        table.insert(lines, "COMPLETED:" .. nowStamp())
    else
        table.insert(lines, "STATUS:NEEDS-ACTION")
    end
    table.insert(lines, "END:VTODO")
    table.insert(lines, "END:VCALENDAR")
    local folded = {}
    for _, l in ipairs(lines) do
        table.insert(folded, fold(l))
    end
    return table.concat(folded, "\r\n") .. "\r\n"
end

-- Parse a single-VTODO .ics into a task, or nil if it carries no VTODO summary.
local function parseVtodo(raw)
    if raw == nil or not raw:find("BEGIN:VTODO", 1, true) then
        return nil
    end
    local uid, summary, prio, status, percent
    for _, line in ipairs(unfold(raw)) do
        local head, value = line:match("^([^:]+):(.*)$")
        if head ~= nil then
            local name = head:match("^([^;]+)"):upper() -- drop any ;params
            if name == "UID" then
                uid = value
            elseif name == "SUMMARY" then
                summary = icalUnescape(value)
            elseif name == "PRIORITY" then
                prio = value
            elseif name == "STATUS" then
                status = value:upper()
            elseif name == "PERCENT-COMPLETE" then
                percent = tonumber(value)
            end
        end
    end
    if summary == nil then
        return nil
    end
    return {
        uid = uid,
        text = summary,
        priority = priorityFromIcal(prio),
        done = status == "COMPLETED" or percent == 100,
    }
end

-- Sync tools drop conflicting copies (e.g. foo.sync-conflict-….ics) beside the
-- file; never read them as tasks nor delete them. Dotfiles (.order.json) skipped.
local function isTaskFile(name)
    return name:sub(-4) == ".ics" and name:sub(1, 1) ~= "." and not name:find("sync%-conflict")
end

-- uid -> last on-disk content for the files this plugin manages, so save()
-- rewrites only what changed and deletes only its own files.
local written = {}

local function loadIcal()
    items = {}
    nextId = 1
    sortMode = "priority"
    written = {}
    local byUid = {}
    for _, name in ipairs(noctalia.listDir(folder) or {}) do
        if isTaskFile(name) then
            local raw = noctalia.readFile(folder .. "/" .. name)
            local task = parseVtodo(raw)
            if task ~= nil and task.uid ~= nil and task.uid ~= "" then
                task.id = nextId
                nextId += 1
                byUid[task.uid] = task
                written[task.uid] = raw
            end
        end
    end
    -- Manual order + sort mode from the sidecar; unknown uids appended (sorted).
    local sidecar = noctalia.readFile(folder .. "/.order.json")
    if sidecar ~= nil and sidecar ~= "" then
        local decoded = noctalia.json.decode(sidecar)
        if type(decoded) == "table" then
            if decoded.sort == "manual" or decoded.sort == "priority" then
                sortMode = decoded.sort
            end
            if type(decoded.order) == "table" then
                for _, uid in ipairs(decoded.order) do
                    if byUid[uid] ~= nil then
                        table.insert(items, byUid[uid])
                        byUid[uid] = nil
                    end
                end
            end
        end
    end
    local rest = {}
    for uid in pairs(byUid) do
        table.insert(rest, uid)
    end
    table.sort(rest)
    for _, uid in ipairs(rest) do
        table.insert(items, byUid[uid])
    end
    loaded = true
end

local function saveIcal()
    noctalia.mkdirAll(folder)
    local existing = {}
    for _, it in ipairs(items) do
        if it.uid ~= nil then existing[it.uid] = true end
    end
    local desired, order = {}, {}
    for _, it in ipairs(items) do
        if not isBlank(it.text) then
            if it.uid == nil or it.uid == "" then
                it.uid = newUid(existing)
                existing[it.uid] = true
            end
            desired[it.uid] = serializeVtodo(it)
            table.insert(order, it.uid)
        end
    end
    -- Write changed files atomically (temp + rename, so a half-written file is
    -- never synced); skip unchanged ones to avoid needless mtime churn.
    for uid, content in pairs(desired) do
        if written[uid] ~= content then
            local path = folder .. "/" .. uid .. ".ics"
            local tmp = folder .. "/." .. uid .. ".ics.tmp"
            if noctalia.writeFile(tmp, content) then
                if noctalia.renameFile(tmp, path) then
                    written[uid] = content
                else
                    noctalia.removeFile(tmp)
                end
            end
        end
    end
    -- Delete files for tasks we managed that are gone now (never touch external
    -- or conflict files, which were never in `written`).
    for uid in pairs(written) do
        if desired[uid] == nil then
            noctalia.removeFile(folder .. "/" .. uid .. ".ics")
            written[uid] = nil
        end
    end
    noctalia.writeFile(folder .. "/.order.json",
        noctalia.json.encode({ sort = sortMode, order = order }, true) or "{}")
end

-- Dispatchers -----------------------------------------------------------------

local function load()
    if storageMode() == "ical" then
        loadIcal()
    else
        loadJson()
    end
end

local function save()
    if not loaded then
        return -- never write before the first load reads what is on disk
    end
    if storageMode() == "ical" then
        saveIcal()
    else
        saveJson()
    end
    dirty = false
end

local function addItem()
    local item = { id = nextId, text = "", priority = "medium", done = false }
    nextId += 1
    -- Appended at the foot of the manual order; the priority view shows it at
    -- the foot of its group.
    table.insert(items, item)
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
        -- important → medium → low → important. The manual position is
        -- untouched; the priority view re-sorts on render.
        item.priority = PRIORITIES[(RANK[item.priority] % #PRIORITIES) + 1]
        save()
        render()
    end
end

-- Switch ordering mode. Only the `sort` choice is persisted — the task array
-- is never rewritten, so the manual order survives any number of round trips
-- through priority mode.
local function setSortMode(mode)
    if mode ~= "manual" and mode ~= "priority" then
        return
    end
    sortMode = mode
    save()
    render()
end

-- Move task `id` to sit at manual position `insertAt` (1-based, in `items`).
-- The insertion zones number the gaps 1..#items+1, so `insertAt` is where the
-- row lands before removing itself; drop onto its own gap is a no-op. Only
-- reachable in manual mode, where the render order IS the `items` order.
local function moveItemTo(id, insertAt)
    local fromIndex = nil
    for i, item in ipairs(items) do
        if item.id == id then
            fromIndex = i
            break
        end
    end
    if fromIndex == nil or type(insertAt) ~= "number" then
        return
    end
    local moved = table.remove(items, fromIndex)
    -- Removing the row shifts every later gap down by one.
    if fromIndex < insertAt then
        insertAt -= 1
    end
    insertAt = math.max(1, math.min(insertAt, #items + 1))
    table.insert(items, insertAt, moved)
    save()
    render()
end

local function doneCount()
    local n = 0
    for _, item in ipairs(items) do
        if item.done then
            n += 1
        end
    end
    return n
end

-- Remove every done row (the header trash, after confirmation). Editing state
-- pointing at a removed row is dropped with it.
local function clearDone()
    local kept = {}
    for _, item in ipairs(items) do
        if not item.done then
            table.insert(kept, item)
        end
    end
    if #kept ~= #items then
        items = kept
        if editingId ~= nil and findItem(editingId) == nil then
            editingId = nil
        end
        save()
    end
    confirmingClear = false
    render()
end

local function taskRow(item)
    local id = item.id
    local editing = editingId == id

    -- Manual mode only: a ☰ grip that drags the whole row to a new position.
    -- The grip is a drag source holding the glyph, but previewAncestor = 1
    -- makes the drag ghost the whole row and liftFromLayout pulls the row out
    -- of the list while it moves; the thin insertion zones between rows are the
    -- drop targets. Same glyph noctalia's own bar reorder uses ("menu-2").
    local grip = nil
    if sortMode == "manual" then
        grip = ui.dragSource({
            key = "grip-" .. id,
            dragType = DRAG_TYPE,
            payload = tostring(id),
            previewAncestor = 1,
            liftFromLayout = true,
            width = 24,
            height = 24,
            align = "center",
            justify = "center",
            tooltip = tr("tip_grip"),
        }, {
            ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
        })
    end

    local chip = ui.box({
        -- priority in the key so the retained box picks up the new fill colour
        key = "chip-" .. id .. "-" .. item.priority,
        width = 16,
        height = 16,
        radius = 4,
        fill = COLORS[item.priority],
        onClick = function()
            cyclePriority(id)
        end,
    })
    local children = {}
    if grip ~= nil then
        table.insert(children, grip)
    end
    table.insert(children, chip)

    if editing then
        table.insert(children, ui.input({
            key = "text-" .. id,
            value = item.text,
            placeholder = tr("placeholder"),
            focus = true,
            flexGrow = 1,
            onChange = function(value)
                item.text = value
                dirty = true
                idleTicks = 0
            end,
            onSubmit = function(value)
                commitEdit(id, value)
            end,
        }))
        -- ✓ commits the edit, mirroring Enter.
        table.insert(children, ui.button({
            glyph = "check",
            variant = "primary",
            tooltip = tr("tip_commit"),
            onClick = function()
                commitEdit(id, item.text)
            end,
        }))
    else
        -- Static text; clicking it re-opens the editor ("press on the text").
        table.insert(children, ui.button({
            key = "view-" .. id,
            text = item.done and strike(item.text) or item.text,
            variant = "ghost",
            contentAlign = "start",
            flexGrow = 1,
            onClick = function()
                enterEdit(id)
            end,
        }))
        -- Done toggle: strikes the text through.
        table.insert(children, ui.button({
            glyph = item.done and "square-check" or "square",
            variant = "ghost",
            tooltip = tr(item.done and "tip_undone" or "tip_done"),
            onClick = function()
                toggleDone(id)
            end,
        }))
        -- Explicit edit affordance next to the row.
        table.insert(children, ui.button({
            glyph = "pencil",
            variant = "ghost",
            tooltip = tr("tip_edit"),
            onClick = function()
                enterEdit(id)
            end,
        }))
    end

    table.insert(children, ui.button({
        glyph = "trash",
        variant = "ghost",
        tooltip = tr("tip_delete"),
        onClick = function()
            deleteItem(id)
        end,
    }))

    return ui.row({
        -- edit/done/mode state flips the row's controls; key it to recreate cleanly
        key = "row-"
            .. id
            .. (editing and "-edit" or "-view")
            .. (item.done and "-done" or "")
            .. (sortMode == "manual" and "-m" or ""),
        gap = 8,
        align = "center",
    }, children)
end

-- A footer legend mapping each chip colour to its category.
local function legendEntry(priority)
    return ui.row({ gap = 6, align = "center" }, {
        ui.box({ width = 12, height = 12, radius = 3, fill = COLORS[priority] }),
        ui.label({ text = tr("prio_" .. priority), fontSize = 11, color = "on_surface_variant" }),
    })
end

-- A thin drop target in the gap before manual-order row `index` (and one past
-- the end, at #items+1). expandOnDrag opens a row-height gap where the dragged
-- row will land; hitSlop makes the 3px line reachable from the rows around it.
local function insertionZone(index)
    return ui.dropZone({
        key = "gap-" .. index,
        accepts = { DRAG_TYPE },
        value = tostring(index),
        onDrop = "onTodoDrop",
        height = 3,
        radius = 6,
        expandOnDrag = true,
        hitSlop = 28,
    })
end

render = function()
    -- Ordering toggle: shows the current mode and flips it. "menu-2" (the grip
    -- glyph) for manual, "palette" for the colour/priority sort.
    local sortToggle = ui.button({
        key = "header-sort-" .. sortMode,
        glyph = sortMode == "manual" and "menu-2" or "palette",
        text = sortMode == "manual" and tr("sort_manual") or tr("sort_priority"),
        variant = "ghost",
        tooltip = tr("tip_sort"),
        onClick = "onSortToggle",
    })

    -- With nothing done the trash has nothing to clear; keep it visible but
    -- disabled, and fold away a confirmation left open while the last done
    -- row was toggled back.
    local done = doneCount()
    if done == 0 then
        confirmingClear = false
    end

    local header = ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
        sortToggle,
        ui.button({ key = "header-refresh", glyph = "refresh", variant = "ghost", tooltip = tr("tip_refresh"), onClick = "onRefresh" }),
        ui.button({
            key = "header-clear-done" .. (done == 0 and "-off" or ""),
            glyph = "trash",
            variant = "ghost",
            enabled = done > 0,
            tooltip = tr("tip_clear_done"),
            onClick = "onClearDone",
        }),
        ui.button({ key = "header-add", glyph = "plus", variant = "primary", tooltip = tr("tip_add"), onClick = "onAdd" }),
        ui.button({ key = "header-close", glyph = "close", variant = "ghost", tooltip = tr("tip_close"), onClick = "onClosePanel" }),
    })

    -- Confirmation strip for the header trash: the question plus an explicit
    -- destructive confirm and a cancel, in place of a modal (the plugin UI has
    -- no dialog primitive).
    local confirmStrip = nil
    if confirmingClear then
        confirmStrip = ui.row({ key = "confirm-clear", gap = 8, align = "center" }, {
            ui.label({ text = tr("clear_done_confirm"), color = "on_surface", flexGrow = 1 }),
            ui.button({ text = tr("clear_done_yes"), variant = "destructive", onClick = "onClearDoneConfirm" }),
            ui.button({ text = tr("clear_done_no"), variant = "ghost", onClick = "onClearDoneCancel" }),
        })
    end

    local legend = ui.column({ gap = 8 }, {
        ui.separator({}),
        ui.row({ gap = 16, align = "center", justify = "center" }, {
            legendEntry("important"),
            legendEntry("medium"),
            legendEntry("low"),
        }),
        -- Footer note: which storage backend is active (JSON file vs iCal vdir).
        ui.row({ justify = "center" }, {
            ui.label({
                text = tr(storageMode() == "ical" and "mode_ical" or "mode_json"),
                fontSize = 11,
                color = "on_surface_variant",
            }),
        }),
    })

    local body
    if #items == 0 then
        body = ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
            ui.label({ text = tr("empty"), color = "on_surface_variant" }),
        })
    else
        local rows = {}
        -- Manual mode interleaves an insertion zone before each row (and one
        -- after the last) so a drag can land in any gap. In manual mode the
        -- render order IS the items order, so gap N targets items index N.
        local manual = sortMode == "manual"
        for index, item in ipairs(displayItems()) do
            if manual then
                table.insert(rows, insertionZone(index))
            end
            table.insert(rows, taskRow(item))
        end
        if manual then
            table.insert(rows, insertionZone(#items + 1))
        end
        body = ui.scroll({ flexGrow = 1, gap = 6 }, rows)
    end

    local parts = { header }
    if confirmStrip ~= nil then
        table.insert(parts, confirmStrip)
    end
    table.insert(parts, body)
    table.insert(parts, legend)
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, parts))
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
    confirmingClear = false
    dirty = false
    idleTicks = 0
    panel.setWantsSecondTicks(true)
    noctalia.state.set("todo_open", true)
    render()
end

function onClose()
    editingId = nil
    confirmingClear = false
    if dirty then
        save()
    end
    noctalia.state.set("todo_open", false)
end

-- Fires on every teardown (shutdown and reload), even paths that skip onClose;
-- flush a pending inline edit so it is never lost.
function onExit()
    if dirty then
        save()
    end
end

function onConfigChanged()
    if dirty then
        save()
    end
    folder = todoFolder()
    filePath = folder .. "/" .. FILE_NAME
    noctalia.mkdirAll(folder)
    editingId = nil
    confirmingClear = false
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

function onSortToggle()
    setSortMode(sortMode == "manual" and "priority" or "manual")
end

-- Reload from storage: flush a pending edit, then re-read the folder/file so
-- tasks that arrived externally (via a CalDAV server or file sync) show up.
-- The plugin writes locally; it cannot push to the phone — that is the CalDAV
-- client's job — so this is a pull/refresh, not a two-way "sync now".
function onRefresh()
    if dirty then
        save()
    end
    editingId = nil
    confirmingClear = false
    load()
    render()
end

-- Drop callback for the insertion zones (declarative drag-and-drop). payload is
-- the dragged row's id as text, value the target gap index as text.
function onTodoDrop(payload, value)
    moveItemTo(tonumber(payload), tonumber(value))
end

function onClearDone()
    confirmingClear = true
    render()
end

function onClearDoneConfirm()
    clearDone()
end

function onClearDoneCancel()
    confirmingClear = false
    render()
end

function onClosePanel()
    panel.close()
end
