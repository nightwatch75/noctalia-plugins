--!nonstrict
-- kuma-status — status pages added from the panel. One normalized URL per line
-- in <pluginDataDir>/status_pages.txt, next to (never replacing) the
-- `status_pages` setting: the host gives plugins no way to write settings.
-- The panel adds and removes lines; the service re-reads the file every cycle.
local S = {}

local function path()
    local dir = noctalia.pluginDataDir()
    return dir and (dir .. "/status_pages.txt") or nil
end

function S.load()
    local p = path()
    local text = p and noctalia.readFile(p) or nil
    local out, seen = {}, {}
    for line in (text or ""):gmatch("[^\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not seen[line] then
            seen[line] = true
            out[#out + 1] = line
        end
    end
    return out
end

function S.save(list)
    local p = path()
    if p == nil then return false end
    local body = #list > 0 and (table.concat(list, "\n") .. "\n") or ""
    return (noctalia.writeFile(p, body))
end

return S
