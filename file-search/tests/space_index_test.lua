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
print("space_index_test OK")
