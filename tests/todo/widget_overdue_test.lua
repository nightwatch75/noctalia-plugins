-- module: todo.luau dates.luau
-- Drives the bar widget under stubbed host globals: a task file is "read"
-- synchronously, and update() stands in for the tick.
local loaded = {}
function require(path)
    local name = path:match("([%w_]+%.luau)$")
    loaded[name] = loaded[name] or loadstring(MODULES[name])()
    return loaded[name]
end

local now = os.time()
local tasks = {}
local config = { glyph = "checklist", show_label = true, label = "To Do", count_mode = "total", sound_on_overdue = true }
local glyph, color, text, interval, played = nil, nil, nil, nil, 0
local store = {}
local nilRead = false -- reads fail, like a deleted or moved file

barWidget = {
    setGlyph = function(g) glyph = g end,
    setGlyphColor = function(c) color = c end,
    setText = function(t) text = t end,
    setTooltip = function() end,
}
noctalia = {
    getConfig = function(key) return config[key] end,
    expandPath = function(p) return p end,
    tr = function(key, args) return key .. (args and args.count and (":" .. args.count) or "") end,
    readFileAsync = function(_, cb)
        if nilRead then
            cb(nil, "missing")
        else
            cb("stub")
        end
        return true
    end,
    json = { decode = function() return { tasks = tasks } end },
    state = {
        watch = function() end,
        get = function(key) return store[key] end,
        set = function(key, value) store[key] = value end,
    },
    setUpdateInterval = function(ms) interval = ms end,
    sound = {
        load = function(_, _, cb) cb(true) end,
        play = function() played += 1 end,
    },
}
tasks = { { text = "a", done = false, due = now - 10 }, { text = "b", done = false } }
loadstring(MODULES["todo.luau"])() -- defines update() and runs the first read
assert(played == 0, "no sound for what was already overdue at load")

-- one overdue task: alarm, count in the label, 1 s tick
update()
assert(glyph == "alarm", "alarm glyph, got " .. tostring(glyph))
assert(text == "bar_overdue:1", "label, got " .. tostring(text))
assert(interval == 1000, "1 s tick while overdue")
local first = color
update()
assert(color ~= first, "color alternates each tick")

-- a second task expires: the count rises, the sound plays once
local before = played
tasks[2].due = now - 5
update()
assert(text == "bar_overdue:2")
assert(played == before + 1, "sound on rise")
update()
assert(played == before + 1, "no repeat while the count is unchanged")

-- several bar instances: one already chimed a moment ago (shared plugin state),
-- so this instance stays silent; once that chime is old, a new rise plays again
store.todo_overdue_chime = os.time()
tasks[3] = { text = "c", done = false, due = now - 1 }
update()
assert(played == before + 1, "a chime from another instance silences this one")
tasks[3] = nil
update()
store.todo_overdue_chime = os.time() - 60
tasks[3] = { text = "c", done = false, due = now - 1 }
update()
assert(played == before + 2, "a new rise plays once the last chime is old")

-- pointing todo_folder at another list is not a "rise"
tasks = { { text = "a", done = false, due = now - 10 } }
update()
config.todo_folder = "/other"
tasks = { { text = "a", done = false, due = now - 10 }, { text = "b", done = false, due = now - 10 } }
store.todo_overdue_chime = nil
update()
assert(played == before + 2, "a folder switch must not chime")
config.todo_folder = nil
update()

-- the file disappears: after a few failed reads the alarm stops
nilRead = true
update()
update()
update()
assert(glyph == "checklist", "alarm stops when the file is gone, got " .. tostring(glyph))
nilRead = false

-- done tasks are not overdue; un-doing one makes it overdue again
tasks = { { text = "a", done = true, due = now - 10 }, { text = "b", done = false, due = now + 3600 } }
update()
assert(glyph == "checklist", "normal glyph back, got " .. tostring(glyph))
assert(interval == 2000, "2 s tick when nothing is overdue")
tasks[1].done = false
update()
assert(glyph == "alarm", "un-done task is overdue again")

-- all-day: today is not overdue, yesterday is (local midnights)
local dates = require("./dates.luau")
local t = os.date("*t", now)
tasks = { { text = "a", done = false, allDay = true, due = dates.makeDue(t.year, t.month, t.day, 0, 0, true) } }
update()
assert(glyph == "checklist", "an all-day task due today is not overdue yet")
tasks = { { text = "a", done = false, allDay = true, due = dates.makeDue(t.year, t.month, t.day - 1, 0, 0, true) } }
update()
assert(glyph == "alarm", "an all-day task from yesterday is overdue")

-- a junk due in the file is ignored
tasks = { { text = "a", done = false, due = "soon" } }
update()
assert(glyph == "checklist")
print("widget overdue ok")
