--!nonstrict
-- Claude Cockpit — bar widget that toggles the panel.
--
-- Deliberately minimal: just a glyph that lights up while the panel is open
-- (shared "claude_cockpit_open" state, published by panel.luau). No pill, no
-- ring — that would mean porting jrohland/claudecode's ring.luau (which
-- needs plugin_api 26 for noctalia.getSetting) for a number the panel's
-- Usage tab already shows one click away.
--
-- Left click is NOT wired here: plugin.toml declares it as a
-- [widget.actions] default (`left = "panel-toggle nightwatch75/claude-cockpit:panel"`),
-- so the user can remap the gesture from the bar's own settings.

local open = false

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))
    barWidget.setGlyphColor(open and "primary" or "on_surface")
    barWidget.setTooltip(noctalia.tr("title"))
end

noctalia.state.watch("claude_cockpit_open", function(value)
    open = value == true
    render()
end)

render()
