-- module: panel.luau dates.luau storage.luau
-- Drives panel.luau's date picker under stubbed host globals: renders are
-- captured as trees and "clicks" call the nodes' onClick/onChange closures.
local loaded = {}
function require(path)
    local name = path:match("([%w_]+%.luau)$")
    if loaded[name] == nil then
        loaded[name] = loadstring(MODULES[name])()
    end
    return loaded[name]
end

-- a clock the test can move forward (os.time with no argument only)
local realTime, clockOffset = os.time, 0
os.time = function(t)
    if t ~= nil then
        return realTime(t)
    end
    return realTime() + clockOffset
end

local lastTree, lastEncoded = nil, nil
local function node(props, children)
    return { props = props or {}, children = children or {} }
end
ui = {}
for _, kind in ipairs({ "column", "row", "scroll", "box", "label", "glyph", "button", "input", "select", "toggle", "separator", "spacer", "dragSource", "dropZone" }) do
    ui[kind] = function(props, children)
        local n = node(props, children)
        n.kind = kind
        return n
    end
end
panel = {
    render = function(tree)
        lastTree = tree
    end,
    setWantsSecondTicks = function() end,
    openContextMenu = function() return true end,
    close = function() end,
}
noctalia = {
    readFile = function(path)
        if path == "plugin.toml" then
            return 'version = "9.9.9"'
        end
        return "stub"
    end,
    writeFile = function() return true end,
    mkdirAll = function() return true end,
    expandPath = function(p) return p end,
    getConfig = function() return nil end,
    tr = function(key) return key end,
    notifyError = function(_, msg) error("notifyError: " .. tostring(msg)) end,
    formatTime = function(pattern, ts) return os.date(pattern, ts) end,
    string = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end },
    json = {
        decode = function()
            return { version = 2, sort = "manual", tasks = { { id = 1, text = "Call the client", priority = "medium", done = false } } }
        end,
        encode = function(tbl)
            lastEncoded = tbl
            return "{}"
        end,
    },
    state = { set = function() end, watch = function() end },
    sound = { load = function() end, play = function() end },
}
loadstring(MODULES["panel.luau"])() -- defines the global callbacks (onOpen, onRowMenu, ...)

local function find(tree, pred)
    if pred(tree) then
        return tree
    end
    for _, child in ipairs(tree.children) do
        local hit = find(child, pred)
        if hit then
            return hit
        end
    end
    return nil
end
local function byKey(key)
    return find(lastTree, function(n) return n.props.key == key end)
end
local function byTooltip(tip)
    return find(lastTree, function(n) return n.props.tooltip == tip end)
end
local function click(n)
    assert(n ~= nil, "node not found")
    n.props.onClick()
end
local function due()
    return lastEncoded.tasks[1].due
end

onOpen({})
assert(byKey("pick-save") == nil, "list view first")

-- the calendar glyph sits left of the task text, right after the done toggle
local row = find(lastTree, function(n) return type(n.props.key) == "string" and n.props.key:match("^row%-1%-") ~= nil end)
local order = {}
for _, child in ipairs(row.children) do
    local key = child.props.key
    if type(key) == "string" and (key:match("^due%-1") or key:match("^view%-1")) then
        order[#order + 1] = key:match("^due") and "due" or "text"
    end
end
assert(order[1] == "due" and order[2] == "text", "due button comes before the task text")

-- a new date seeds from now + 15 minutes, at minute precision
local function expectedSeed(offset)
    local t = os.date("*t", os.time() + offset)
    return t.hour, t.min
end
local h1, m1 = expectedSeed(900)
onRowMenu("due", "1")
local h2, m2 = expectedSeed(900)
local gotH, gotM = byKey("pick-hour").props.selectedIndex, byKey("pick-min").props.selectedIndex
assert((gotH == h1 and gotM == m1) or (gotH == h2 and gotM == m2), "seed is now + 15 min, got " .. gotH .. ":" .. gotM)
assert(#byKey("pick-min").props.options == 60, "minutes go 00..59")
click(byKey("pick-cancel"))

-- a past date is rejected, nothing is written
onRowMenu("due", "1")
assert(byKey("pick-save") ~= nil, "picker opens")
click(byTooltip("tip_picker_prev"))
click(byKey("day-1"))
lastEncoded = nil
click(byKey("pick-save"))
assert(lastEncoded == nil, "past date must not be saved")
assert(find(lastTree, function(n) return n.props.text == "picker_past" end) ~= nil, "error shown")
click(byKey("pick-cancel"))
assert(byKey("pick-save") == nil, "cancel returns to the list")

-- a date months ahead is saved
onRowMenu("due", "1")
click(byTooltip("tip_picker_next"))
click(byTooltip("tip_picker_next"))
click(byKey("day-15"))
click(byKey("pick-save"))
assert(due() ~= nil and due() > os.time() + 40 * 86400, "future date saved")
assert(byKey("pick-save") == nil, "save returns to the list")

-- remove date
onRowMenu("due", "1")
click(byKey("pick-clear"))
assert(due() == nil, "due removed")

-- all-day: today (or the seeded day) is accepted
onRowMenu("due", "1")
byKey("pick-allday").props.onChange("true")
click(byKey("pick-save"))
assert(due() ~= nil and lastEncoded.tasks[1].allDay == true, "all-day saved")


-- N and S do nothing behind the picker (no hidden blank task appears)
onRowMenu("due", "1")
onKey("n", true)
click(byKey("pick-cancel"))
assert(find(lastTree, function(n) return n.kind == "input" end) == nil, "N must not add a task behind the picker")

-- the list and the picker have distinct root keys
assert(lastTree.props.key == "view-list")
onRowMenu("due", "1")
assert(lastTree.props.key == "view-picker")
click(byKey("pick-cancel"))

-- a row flips to overdue while the panel stays open
onRowMenu("due", "1")
click(byTooltip("tip_picker_next"))
click(byKey("day-15"))
click(byKey("pick-save"))
assert(byKey("due-1-set") ~= nil, "saved date shows the calendar-event glyph")
clockOffset = 90 * 86400
update()
assert(byKey("due-1-overdue") ~= nil, "row turns overdue on the tick without any click")
-- the task vanishes while the picker is open: back to the list, no error
onRowMenu("due", "1")
assert(byKey("pick-save") ~= nil)
onRowMenu("delete", "1")
assert(byKey("pick-save") == nil, "picker closes when its task is gone")
print("panel picker ok")
