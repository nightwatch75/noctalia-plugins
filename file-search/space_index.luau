--!nonstrict
--[[
  space_index.luau - pure logic of the Space tab: file categories, entry lists,
  sorting, donut slices and node navigation. No host globals: a plain module
  (ends with `return idx`), unit-tested by tests/space_index_test.lua.

  Decoded index node:  { n = name, s = bytes, f = loose file bytes,
                         c = { 8 bytes per category }, d = { child nodes },
                         t = { { n, s, k = category } } top files, leaf = true? }

  EXT below is the ONE extension table. The jq program that builds the index
  (Task 3) is generated from this same table, so the Luau side and the jq side
  cannot drift apart. Any extension not listed is category 8 (other).

  Slice colour index: in folders mode it is the position in the unsorted
  node.d (a folder keeps its colour when the sort changes); in types mode it
  is the category number.
]]

local idx = {}

idx.CATEGORIES = { "video", "images", "audio", "archives", "documents", "code", "packages", "other" }

-- Same fixed palettes as usage.luau, so a category keeps its colour.
idx.COLORS_DARK = {
    "#7aa2f7", "#9ece6a", "#e0af68", "#f7768e",
    "#bb9af7", "#2ac3de", "#ff9e64", "#73daca",
}
idx.COLORS_LIGHT = {
    "#3b5fc0", "#4f8a2b", "#b07708", "#c2405a",
    "#7c4dbd", "#0e7490", "#c25a12", "#2f8f7a",
}

-- category number -> lower-case extensions (no dot)
idx.EXT = {
    { "mkv", "mp4", "avi", "mov", "webm", "m4v", "wmv", "flv" },
    { "jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "raw" },
    { "mp3", "flac", "wav", "ogg", "opus", "m4a", "aac" },
    { "zip", "tar", "gz", "xz", "bz2", "zst", "7z", "rar", "tgz" },
    { "pdf", "doc", "docx", "odt", "xls", "xlsx", "ods", "ppt", "pptx", "txt", "md", "epub" },
    { "lua", "luau", "py", "js", "ts", "c", "h", "cpp", "hpp", "rs", "go", "java", "sh", "json", "toml", "yaml", "yml" },
    { "deb", "rpm", "pkg", "apk", "appimage", "iso", "img", "jar", "whl" },
}

local extMap = {}
for cat, list in ipairs(idx.EXT) do
    for _, e in ipairs(list) do extMap[e] = cat end
end

function idx.categoryOf(name)
    local ext = string.match(name, "^.+%.([^%.]+)$")
    if not ext then return 8 end
    return extMap[string.lower(ext)] or 8
end

function idx.child(node, name)
    for _, d in ipairs(node.d or {}) do
        if d.n == name then return d end
    end
    return nil
end

-- Folders view (also types view with no category selected): sub-folders plus
-- one "loose" row for files directly inside. With a category in types mode:
-- that category's top files only.
function idx.entries(node, mode, category)
    local out = {}
    if mode == "types" and category then
        for _, f in ipairs(node.t or {}) do
            if f.k == category then
                table.insert(out, { name = f.n, bytes = f.s, kind = "file", category = category })
            end
        end
    else
        for _, d in ipairs(node.d or {}) do
            table.insert(out, { name = d.n, bytes = d.s, kind = "dir", node = d })
        end
        if (node.f or 0) > 0 then
            table.insert(out, { name = "", bytes = node.f, kind = "loose" })
        end
    end
    return idx.sort(out, "size", true)
end

function idx.sort(entries, key, descending)
    local pos = {}
    for i, e in ipairs(entries) do pos[e] = i end
    local out = table.clone(entries)
    table.sort(out, function(a, b)
        local x, y = a.bytes, b.bytes
        if key == "name" then x, y = a.name, b.name end
        if x ~= y then
            if descending then return x > y end
            return x < y
        end
        if a.name ~= b.name then return a.name < b.name end
        return pos[a] < pos[b] -- table.sort is not stable: original order breaks full ties
    end)
    return out
end

-- Donut rows. folders: one per entry, colour index = position in the unsorted
-- node.d. types: one per non-empty category, colour index = category number.
local function sliceRows(node, mode)
    local rows = {}
    if mode == "types" then
        for i = 1, 8 do
            local b = (node.c or {})[i] or 0
            if b > 0 then
                table.insert(rows, { name = idx.CATEGORIES[i], bytes = b, kind = "category", index = i })
            end
        end
        return idx.sort(rows, "size", true)
    end
    for _, e in ipairs(idx.entries(node, "folders")) do
        if e.node then
            for j, d in ipairs(node.d) do
                if d == e.node then e.index = j break end
            end
        end
        table.insert(rows, e)
    end
    return rows
end

-- Top maxSlices-1 rows plus one "other" holding the rest, so the bytes sum to node.s.
function idx.slices(node, mode, maxSlices)
    local out = {}
    if (node.s or 0) <= 0 then return out end
    local list = sliceRows(node, mode)
    local kept = #list > maxSlices and maxSlices - 1 or #list
    local sum = 0
    for i = 1, kept do
        local e = list[i]
        sum += e.bytes
        table.insert(out, {
            label = e.name, bytes = e.bytes, kind = e.kind, index = e.index,
            color = e.index and idx.COLORS_DARK[(e.index - 1) % 8 + 1] or nil,
        })
    end
    if node.s > sum then
        table.insert(out, { label = "other", bytes = node.s - sum, kind = "other" })
    end
    return out
end

return idx
