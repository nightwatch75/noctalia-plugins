-- module: space_index.luau
-- Pure logic of space_index.luau; run through tests/run.sh.
local idx = loadstring(MODULE_SRC)()
local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b)) end end

eq(idx.categoryOf("a.MKV"), 1, "mkv")
eq(idx.categoryOf("x.tar.gz"), 4, "tar.gz")
eq(idx.categoryOf("Makefile"), 8, "no ext")
eq(idx.categoryOf(".bashrc"), 8, "dotfile")

local es = {
    { name = "b", bytes = 5 }, { name = "a", bytes = 5 }, { name = "c", bytes = 9 },
}
local s = idx.sort(es, "size", true)
eq(s[1].name .. s[2].name .. s[3].name, "cab", "size desc, ties by name")
s = idx.sort(es, "name", false)
eq(s[1].name .. s[2].name .. s[3].name, "abc", "name asc")
eq(es[1].name, "b", "input untouched")

local kids, total = {}, 0
for i = 1, 12 do
    kids[i] = { n = "d" .. i, s = i * 10, f = 0, c = { 0, 0, 0, 0, 0, 0, 0, i * 10 }, d = {}, t = {} }
    total += i * 10
end
local root = { n = "/", s = total + 7, f = 7, c = { 100, 0, 0, 0, 0, 0, 0, 0 }, d = kids,
    t = { { n = "small.mp4", s = 10, k = 1 }, { n = "big.mkv", s = 90, k = 1 }, { n = "x.png", s = 3, k = 2 } } }

local e = idx.entries(root, "types", 1)
eq(#e, 2, "video files only")
eq(e[1].name, "big.mkv", "biggest first")
eq(idx.child(root, "d3").s, 30, "child")
eq(idx.child(root, "nope"), nil, "missing child")

local sl = idx.slices(root, "folders", 8)
eq(#sl, 8, "8 slices")
eq(sl[8].kind, "other", "last is other")
local sum = 0
for _, x in ipairs(sl) do sum += x.bytes end
eq(sum, root.s, "slices sum")
eq(#idx.slices({ n = "e", s = 0, f = 0, c = {}, d = {}, t = {} }, "folders", 8), 0, "zero node")

-- types with no category = same list as folders (dirs carry their node)
local ef, et = idx.entries(root, "folders"), idx.entries(root, "types")
eq(#et, #ef, "types nil == folders count")
eq(et[1].kind, "dir", "dir row")
eq(et[1].node ~= nil, true, "dir row has node")
eq(et[1].name, "d12", "biggest first")
eq(ef[#ef].kind, "loose", "loose row last (7 bytes)")
eq(ef[#ef].bytes, 7, "loose bytes")

-- types slices = categories
local ts = idx.slices(root, "types", 8)
eq(#ts, 2, "types slices: video + other(cat 8 empty at root -> remainder)")
eq(ts[1].kind, "category", "category kind")
eq(ts[1].label, "video", "category label")
eq(ts[1].index, 1, "category index")
eq(ts[1].color, idx.COLORS_DARK[1], "category colour")
eq(ts[2].kind, "other", "remainder")
local tsum = 0
for _, x in ipairs(ts) do tsum += x.bytes end
eq(tsum, root.s, "types slices sum")

-- full tie keeps input order
local tie = idx.sort({ { name = "x", bytes = 1, id = 1 }, { name = "x", bytes = 1, id = 2 } }, "size", true)
eq(tie[1].id, 1, "stable full tie")

-- hostile name stays plain data
local bad = 'a\nb"<&>.MP4'
eq(idx.categoryOf(bad), 1, "hostile categoryOf")
local hn = { n = "/", s = 5, f = 0, c = { 5, 0, 0, 0, 0, 0, 0, 0 }, d = { { n = bad, s = 5, f = 5, c = {}, d = {}, t = {}, leaf = true } }, t = {} }
eq(idx.entries(hn, "folders")[1].name, bad, "hostile entries")
eq(idx.sort(idx.entries(hn, "folders"), "name", false)[1].name, bad, "hostile sort")
eq(idx.slices(hn, "folders", 8)[1].label, bad, "hostile slices")
print("space_index_test OK")
