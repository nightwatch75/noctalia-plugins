-- module: shared.luau
-- Mount classification of shared.prunePaths, with a stubbed /proc/mounts.
-- Fixed paths and pseudo filesystems are always pruned; remote (network and
-- any FUSE type) only with opts.network; removable disks (shared.mounts) only
-- with opts.external; fuseblk is local and never pruned. Run through
-- tests/file-search/run.sh, which splices shared.luau as MODULE_SRC.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end

local MOUNTS = table.concat({
    "/dev/sda2 / btrfs rw 0 0",
    "proc /proc proc rw 0 0",
    "overlay /var/lib/docker/overlay2/x/merged overlay rw 0 0",
    "/dev/loop0 /snap/core/1 squashfs ro 0 0",
    "server:/share /mnt/nas nfs4 rw 0 0",
    "//box/music /mnt/music cifs rw 0 0",
    "remote: /home/u/cloud fuse.rclone rw 0 0",
    "sshfs#me@h: /home/u/ssh fuse rw 0 0",
    "/dev/sdb1 /mnt/win fuseblk rw 0 0",
    "/dev/sdc1 /mnt/with\\040space nfs rw 0 0",
    "/dev/sdc2 /mnt/bad\\012name nfs rw 0 0",
}, "\n")

noctalia = { readFile = function(p) return p == "/proc/mounts" and MOUNTS or nil end }
local shared = loadstring(MODULE_SRC)()
shared.mounts = { "/run/media/u/USB/", "/mnt/usb" }

local function set(list)
    local out = {}
    for _, p in ipairs(list) do out[p] = true end
    return out
end

local ALWAYS = { "/proc", "/sys", "/dev", "/run", "/var/lib/docker/overlay2/x/merged", "/snap/core/1" }
local REMOTE = { "/mnt/nas", "/mnt/music", "/home/u/cloud", "/home/u/ssh", "/mnt/with space" }

for _, case in ipairs({
    { net = false, ext = false }, { net = true, ext = false },
    { net = false, ext = true }, { net = true, ext = true },
}) do
    local name = "net=" .. tostring(case.net) .. " ext=" .. tostring(case.ext)
    local got = set(shared.prunePaths({ network = case.net, external = case.ext }))
    for _, p in ipairs(ALWAYS) do assert(got[p], name .. ": always pruned " .. p) end
    for _, p in ipairs(REMOTE) do eq(got[p] == true, case.net, name .. ": remote " .. p) end
    eq(got["/mnt/usb"] == true, case.ext, name .. ": removable /mnt/usb")
    eq(got["/run/media/u/USB"], nil, name .. ": removable inside /run deduped")
    eq(got["/mnt/win"], nil, name .. ": fuseblk is local")
    eq(got["/"], nil, name .. ": never /")
    eq(got["/home"], nil, name .. ": local btrfs kept")
    for p in pairs(got) do assert(not p:find("\n", 1, true) and not p:find("bad"), name .. ": control char rejected") end
end

-- The Search tab keeps its behaviour: wholePrunePaths = network + external.
eq(table.concat(shared.wholePrunePaths(), "|"),
    table.concat(shared.prunePaths({ network = true, external = true }), "|"), "wholePrunePaths unchanged")
assert(shared.REMOTE_FS.nfs and shared.REMOTE_FS["9p"] and not shared.REMOTE_FS.fuseblk, "REMOTE_FS table")

print("shared_prune_test OK")
