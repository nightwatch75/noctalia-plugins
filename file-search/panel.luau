--!nonstrict
-- file-search — fuzzy search panel, fzf as the matching subsystem.
--
-- On open the search folder is walked once with `find` into a cache file
-- (excluded directory names are pruned, hidden entries too unless enabled);
-- after that every keystroke runs `fzf --filter=<query>` over the cache, so
-- typing stays responsive even on large trees. Results update live; picking
-- one opens it with the system MIME association (xdg-open) — directories
-- open in the file manager.
--
-- Keyboard: the query input holds focus, so typing always reaches it. Up/Down
-- (declared as the panel's capture_keys, plugin_api >= 13) move the highlighted
-- result and Enter opens it — the query input's onSubmit, which is why Return is
-- not captured.
--
-- The results list is WINDOWED rather than scrolled. ui.scroll gives plugins no
-- way to scroll to a given child (the reconciler accepts no offset prop, and the
-- host's scroll-into-view is wired to native controls only), so a highlight
-- moving past the fold could never be brought back into view. Instead only the
-- rows that fit are rendered and the window follows the selection: pressing Down
-- on the last visible row advances the window by one, which reads as the list
-- scrolling. The trade is that the wheel cannot reach past the window — narrow
-- the query, or hold Down. The launcher entry keeps the natively scrolled list.
--
-- The index is rebuilt when the panel opens with changed settings, or on
-- demand via the refresh button. The bar widget mirrors the panel's open
-- state through the shared "file_search_open" state key.

-- Result-list geometry. Every row is pinned to ROW_H so the row count is fixed
-- arithmetic instead of whatever control-height tier the host picks (a Button
-- with text would default to Style::controlHeight, 38). The budget, from the
-- panel's 480 height in plugin.toml: 480 − 2 × Style::panelPadding (14) = 452
-- content, less the column's three 12px gaps, the header row (32, its glyph
-- buttons), the query input (Style::controlHeight, 38) and the footer label
-- (~15) → 331 for the list. 10 × 30 + 9 × 2 = 318 fits; 11 rows would not.
local ROW_H = 30
local ROW_GAP = 2
local VISIBLE_ROWS = 10

local query = ""
local results = {}      -- relative paths; directories keep a trailing "/"
local selected = 1      -- 1-based index into `results`; Enter opens this row
local windowStart = 1   -- index of the first rendered row; follows `selected`
local total = nil       -- entries in the index, shown in the footer
local indexing = false
local searching = false
local errMsg = nil
local fzfMissing = false
local inputRev = 0      -- bumped to reseed the query input on open
local haveIndex = false -- the cache on disk matches the current settings

local render
local runSearch
local buildIndex

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- Private per-plugin storage (XDG state); the host creates the directory on
-- every call. nil (with a log line) when no state directory resolves.
local function dataDir()
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then
        noctalia.log("file-search: pluginDataDir failed: " .. tostring(err))
        return nil
    end
    return dir
end

-- Shell header shared by every cache command. The .meta sidecar holds the
-- settings fingerprint the cache was built with, so the panel and the
-- launcher can both tell a stale index apart.
local function cacheSh(dir)
    return "CACHE_DIR=" .. shellQuote(dir)
        .. '\nCACHE="$CACHE_DIR/index.list"\nMETA="$CACHE_DIR/index.meta"'
end

local function searchRoot()
    local dir = noctalia.getConfig("search_folder")
    if dir == nil or dir == "" then
        dir = noctalia.getenv("HOME") or "/tmp"
    else
        dir = noctalia.expandPath(dir)
    end
    dir = dir:gsub("/+$", "")
    if dir == "" then
        dir = "/"
    end
    return dir
end

local function maxResults()
    return math.max(10, math.min(200, tonumber(noctalia.getConfig("max_results")) or 50))
end

-- Excluded directory names from the setting, split on ',' or ';'. Matching
-- is by basename (find -name), so entries containing '/' are skipped and
-- logged. Hidden entries are folded in as an extra '.*' pattern.
local function excludeNames()
    local raw = noctalia.getConfig("exclude_dirs")
    if type(raw) ~= "string" then
        raw = ""
    end
    local names = {}
    for entry in raw:gmatch("[^,;]+") do
        local name = trim(entry)
        if name:find("/") then
            noctalia.log("file-search: ignoring exclude entry with '/': '" .. name .. "'")
        elseif name ~= "" then
            table.insert(names, name)
        end
    end
    if noctalia.getConfig("show_hidden") ~= true then
        table.insert(names, ".*")
    end
    return names
end

local function indexKey()
    return searchRoot() .. "\n" .. table.concat(excludeNames(), "\n")
end

-- The cache on disk is current when its fingerprint matches the settings,
-- whether the panel or the launcher built it.
local function cacheFresh(dir)
    return noctalia.readFile(dir .. "/index.meta") == indexKey()
end

-- One cache record, about to be joined to the search root. The cache is a
-- plain user-editable file, so records are untrusted: reject anything that
-- could resolve outside the root.
local function safeRel(rel)
    if rel == "" or rel:sub(1, 1) == "/" or rel:find("\n", 1, true) then
        return false
    end
    for part in rel:gmatch("[^/]+") do
        if part == ".." then
            return false
        end
    end
    return true
end

buildIndex = function()
    if fzfMissing or indexing then
        return
    end
    local dir = dataDir()
    if dir == nil then
        errMsg = tr("err_index")
        render()
        return
    end
    indexing = true
    errMsg = nil
    local key = indexKey()

    -- Names containing a newline would each forge extra one-per-fragment
    -- records (a crafted name can smuggle '..' lines into the index), so
    -- they are pruned unconditionally, before the user's exclusions.
    local names = { "-name " .. shellQuote("*\n*") }
    for _, name in ipairs(excludeNames()) do
        table.insert(names, "-name " .. shellQuote(name))
    end
    local prune = "\\( " .. table.concat(names, " -o ") .. " \\) -prune -o "
    -- %P prints paths relative to the root; the trailing '/' marks
    -- directories so rows get the right glyph. find's own exit status is
    -- ignored, so permission errors inside the tree don't fail the build.
    -- Cache and fingerprint are written to mktemp-created private files and
    -- renamed into place: rename replaces a planted symlink at the
    -- destination instead of following it. The host guarantees $CACHE_DIR
    -- exists (created by pluginDataDir above).
    local cmd = cacheSh(dir)
        .. '\nTMP=$(mktemp "$CACHE_DIR/index.list.XXXXXX") || exit 1\n'
        .. "find " .. shellQuote(searchRoot()) .. " -mindepth 1 " .. prune
        .. "-type d -printf '%P/\\n' -o -printf '%P\\n' > \"$TMP\" 2>/dev/null\n"
        .. 'mv -f "$TMP" "$CACHE" || exit 1\n'
        .. 'TMPM=$(mktemp "$CACHE_DIR/index.meta.XXXXXX") || exit 1\n'
        .. "printf '%s' " .. shellQuote(key) .. ' > "$TMPM"\n'
        .. 'mv -f "$TMPM" "$META" || exit 1\n'
        .. 'wc -l < "$CACHE"'

    render()
    local ok = noctalia.runAsync(cmd, function(result)
        indexing = false
        if result.exitCode == 0 and not result.timedOut then
            haveIndex = true
            total = tonumber(trim(result.stdout or "")) or 0
            if indexKey() ~= key then
                buildIndex() -- settings changed while the walk was running
            else
                runSearch()
            end
        else
            haveIndex = false
            errMsg = tr("err_index")
        end
        render()
    end, 180000)
    if not ok then
        indexing = false
        errMsg = tr("err_spawn")
        render()
    end
end

runSearch = function()
    if fzfMissing or indexing or searching or not haveIndex then
        return
    end
    local dir = dataDir()
    if dir == nil then
        return
    end
    searching = true
    local q = query
    local limit = maxResults()
    local cmd
    if trim(q) == "" then
        cmd = cacheSh(dir) .. '\nhead -n ' .. limit .. ' "$CACHE" 2>/dev/null'
    else
        -- head closes the pipe early; the pipeline status stays head's (0).
        cmd = cacheSh(dir) .. "\nfzf --filter=" .. shellQuote(q)
            .. ' < "$CACHE" 2>/dev/null | head -n ' .. limit
    end
    local ok = noctalia.runAsync(cmd, function(result)
        searching = false
        if not result.timedOut then
            results = {}
            for line in (result.stdout or ""):gmatch("[^\n]+") do
                table.insert(results, line)
            end
            -- A new result set invalidates the old position: the top match is
            -- what a fresh query means to select, and the window follows it.
            selected = 1
            windowStart = 1
        end
        -- The query moved on while this search ran: chase it. The stale
        -- rows rendered below are overwritten as soon as it completes.
        if query ~= q then
            runSearch()
        end
        render()
    end, 15000)
    if not ok then
        searching = false
    end
end

local function openEntry(rel)
    if not safeRel(rel) then
        noctalia.log("file-search: refusing unsafe index record: " .. rel)
        noctalia.notify(tr("title"), tr("err_bad_record"))
        return
    end
    local path = searchRoot()
    if path ~= "/" then
        path = path .. "/"
    end
    path = path .. rel:gsub("/+$", "")
    noctalia.runAsync("xdg-open " .. shellQuote(path) .. " >/dev/null 2>&1")
    panel.close()
end

-- Slide the window so `selected` is inside it, then keep it in range: a shorter
-- result set must not leave the window pointing past the end.
local function syncWindow()
    if selected < windowStart then
        windowStart = selected
    elseif selected > windowStart + VISIBLE_ROWS - 1 then
        windowStart = selected - VISIBLE_ROWS + 1
    end
    local maxStart = math.max(1, #results - VISIBLE_ROWS + 1)
    windowStart = math.max(1, math.min(maxStart, windowStart))
end

-- The selected row is the one Enter opens, so it is drawn as the primary
-- action. The key carries the selection: the reconciler diffs by key, and the
-- same convention marks the active row in the other panels.
local function resultRow(rel, index)
    local isDir = rel:sub(-1) == "/"
    local isSelected = index == selected
    return ui.button({
        key = "hit-" .. index .. (isSelected and "-sel" or ""),
        glyph = isDir and "folder" or "file",
        text = rel,
        variant = isSelected and "primary" or "ghost",
        contentAlign = "start",
        height = ROW_H,
        onClick = function()
            openEntry(rel)
        end,
    })
end

local function statusFooter()
    if indexing then
        return ui.label({ text = tr("status_indexing", { path = searchRoot() }), fontSize = 11, color = "secondary" })
    end
    local shown = #results
    -- With more matches than the window can hold, the plain count would look
    -- like the list was truncated; name the visible range instead so the rows
    -- off-window are visibly reachable rather than missing.
    local text
    if shown > VISIBLE_ROWS then
        text = tr("counts_window", {
            from = windowStart,
            to = math.min(shown, windowStart + VISIBLE_ROWS - 1),
            shown = shown,
            total = total or 0,
        })
    else
        text = tr("counts", { shown = shown, total = total or 0 })
    end
    return ui.label({ text = text, fontSize = 11, color = "on_surface_variant" })
end

render = function()
    local children = {
        ui.row({ gap = 6, align = "center" }, {
            ui.label({
                text = tr("title"),
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
                flexGrow = 1,
            }),
            ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("tip_refresh"), onClick = "onRefreshIndex" }),
            ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("tip_settings"), onClick = "onOpenSettings" }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = tr("tip_close"), onClick = "onClosePanel" }),
        }),
        ui.input({
            key = "query-" .. inputRev,
            value = query,
            focus = true,
            placeholder = tr("search_placeholder"),
            onChange = "onQueryChanged",
            onSubmit = "onOpenSelected",
        }),
    }

    if fzfMissing then
        table.insert(children, ui.label({ text = tr("err_no_fzf"), color = "error" }))
    elseif errMsg ~= nil then
        table.insert(children, ui.label({ text = errMsg, color = "error" }))
    else
        if #results == 0 and not indexing and trim(query) ~= "" then
            table.insert(children, ui.label({
                text = tr("no_results", { query = query }),
                color = "on_surface_variant",
                flexGrow = 1,
            }))
        else
            -- Only the windowed slice is built. ui.scroll is kept around it as
            -- a safety net: if a theme ever makes a row taller than ROW_H the
            -- last one stays reachable with the wheel instead of being clipped.
            local rows = {}
            local last = math.min(#results, windowStart + VISIBLE_ROWS - 1)
            for index = windowStart, last do
                table.insert(rows, resultRow(results[index], index))
            end
            table.insert(children, ui.scroll({ flexGrow = 1, gap = ROW_GAP }, rows))
        end
        table.insert(children, statusFooter())
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

function onOpen(_context)
    fzfMissing = not noctalia.commandExists("fzf")
    query = ""
    results = {}
    selected = 1
    windowStart = 1
    inputRev += 1
    noctalia.state.set("file_search_open", true)
    if not fzfMissing then
        local dir = dataDir()
        if dir == nil then
            errMsg = tr("err_index")
        else
            haveIndex = cacheFresh(dir)
            if not haveIndex then
                buildIndex()
            else
                runSearch()
            end
        end
    end
    render()
end

function onClose()
    noctalia.state.set("file_search_open", false)
end

function onConfigChanged()
    if fzfMissing or indexing then
        return
    end
    local dir = dataDir()
    if dir == nil then
        return
    end
    haveIndex = cacheFresh(dir)
    if not haveIndex then
        buildIndex()
    else
        runSearch()
    end
end

function onQueryChanged(value)
    query = value
    runSearch()
end

-- Enter in the query input: open whatever Up/Down last highlighted, which is
-- the top match until the arrows move it.
function onOpenSelected(value)
    query = value
    local rel = results[selected]
    if rel ~= nil then
        openEntry(rel)
    end
end

-- Declared capture_keys arrive here as the verbatim manifest spec. The host
-- sends one call per physical press plus one on release; only the press moves
-- the selection. Movement clamps at both ends rather than wrapping, so holding
-- an arrow settles on the first or last row instead of cycling past it.
function onKey(chord, pressed)
    if not pressed or #results == 0 then
        return
    end
    local step = chord == "Down" and 1 or -1
    local target = math.max(1, math.min(#results, selected + step))
    if target ~= selected then
        selected = target
        syncWindow()
        render()
    end
end

function onRefreshIndex()
    haveIndex = false
    buildIndex()
end

-- Opens the settings window on this plugin's own page (the host supplies the
-- plugin id, so a plugin can only ever open its own). The panel closes on the
-- way; the index survives it, since it lives in the plugin data directory.
function onOpenSettings()
    noctalia.openSettings()
end

function onClosePanel()
    panel.close()
end
