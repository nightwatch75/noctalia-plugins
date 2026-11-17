-- module: dates.luau
local dates = loadstring(MODULE_SRC)()

assert(dates.daysInMonth(2028, 2) == 29)
assert(dates.daysInMonth(2100, 2) == 28)
assert(dates.daysInMonth(2026, 11) == 30)

assert(dates.firstWeekday(2026, 11) == 7) -- 1 Nov 2026 is a Sunday
assert(dates.firstWeekday(2026, 6) == 1) -- 1 Jun 2026 is a Monday

local grid = dates.monthGrid(2026, 11)
assert(#grid == 6)
local row1 = grid[1]
for i, want in ipairs({ 0, 0, 0, 0, 0, 0, 1 }) do
    assert(row1[i] == want, "row 1 cell " .. i)
end
local nonzero, thirties = 0, 0
for _, row in ipairs(grid) do
    assert(#row == 7)
    for _, cell in ipairs(row) do
        if cell ~= 0 then
            nonzero += 1
        end
        if cell == 30 then
            thirties += 1
        end
    end
end
assert(nonzero == 30 and thirties == 1)

local y, m = dates.shiftMonth(2026, 12, 1)
assert(y == 2027 and m == 1)
y, m = dates.shiftMonth(2026, 1, -1)
assert(y == 2025 and m == 12)

for _, bad in ipairs({ { due = "x" }, { due = -5 }, { due = 0 / 0 }, { due = math.huge }, { due = 1e15 }, {} }) do
    local due, allDay = dates.normalizeDue(bad)
    assert(due == nil and allDay == false)
end
local due, allDay = dates.normalizeDue({ due = 1700000000.7, allDay = true })
assert(due == 1700000000 and allDay == true)
due, allDay = dates.normalizeDue({ due = 1700000000, allDay = "yes" })
assert(due == 1700000000 and allDay == false)

local now = os.time()
assert(dates.isOverdue({ due = now - 60 }, now) == true)
assert(dates.isOverdue({ due = now + 60 }, now) == false)
assert(dates.isOverdue({ due = now - 60, done = true }, now) == false)
assert(dates.isOverdue({}, now) == false)

local t = os.date("*t", now)
local noon = dates.makeDue(t.year, t.month, t.day, 12, 0, false)
local today = dates.makeDue(t.year, t.month, t.day, 0, 0, true)
local yesterday = dates.makeDue(t.year, t.month, t.day - 1, 0, 0, true)
assert(dates.isOverdue({ due = today, allDay = true }, noon) == false)
assert(dates.isOverdue({ due = yesterday, allDay = true }, noon) == true)

-- makeDue takes LOCAL fields: reading them back with os.date must round-trip
local back = os.date("*t", dates.makeDue(2026, 11, 20, 18, 30, false))
assert(back.year == 2026 and back.month == 11 and back.day == 20, "local date round-trips")
assert(back.hour == 18 and back.min == 30, "local time round-trips, got " .. back.hour .. ":" .. back.min)
back = os.date("*t", dates.makeDue(2026, 7, 1, 9, 0, false)) -- other side of DST
assert(back.hour == 9 and back.day == 1, "summer time round-trips")
back = os.date("*t", dates.makeDue(2026, 11, 20, 18, 30, true))
assert(back.hour == 0 and back.min == 0 and back.day == 20, "all-day is local midnight")

assert(dates.makeDue(2026, 11, 20, 18, 30, true) == dates.makeDue(2026, 11, 20, 0, 0, false))
print("dates ok")
