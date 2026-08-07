--!nonstrict
-- shared — constants and helpers common to all three entries (bar widget,
-- service, panel), pulled in via require() (relative same-plugin import,
-- plugin_api >= 22). Centralizing the state-channel names removes the risk of
-- a typo'd literal in one file silently going unnoticed by state.watch in
-- another (there is no compile-time check tying "dns_state" strings together
-- across separate scripts).

local shared = {}

-- engine (service.luau) publishes  STATE_KEY   = { nonce, current?, servers,
--                                                   conName, changing, error?,
--                                                   list }
-- UI entries send                  REQUEST_KEY = { nonce, id, label?, ip? }
shared.STATE_KEY = "dns_state"
shared.REQUEST_KEY = "apply_request"

function shared.tr(key, args)
    return noctalia.tr(key, args)
end

-- The nonce is monotonic across writers (widget instances and the panel):
-- each seeds from the last request already in the shared state.
function shared.requestApply(id, label, ip)
    local prev = noctalia.state.get(shared.REQUEST_KEY)
    local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
    noctalia.state.set(shared.REQUEST_KEY, { nonce = nonce, id = id, label = label, ip = ip })
end

return shared
