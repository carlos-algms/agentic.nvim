local Logger = require("agentic.utils.logger")

--- Per-tab floating status surface for the agentic chat UI.
---
--- Owns a single floating window anchored to the bottom row of the bottom-most
--- agentic window. The float is driven by four public calls: `attach`,
--- `set_text`, `reposition`, and `destroy`. All mutable state lives on the
--- instance; no module-level mutable per-tab data.

--- @class agentic.ui.StatusLine
--- @field _tab_page_id integer Owning tabpage id
--- @field _win_nrs? table<string, integer> Reference to ChatWidget.win_nrs
--- @field _position? string Layout position: "left"|"right"|"bottom"
--- @field _text string Status text content (default "")
--- @field _float_winid? integer Float window id, nil when not open
--- @field _float_bufnr? integer Scratch buffer id for the float
--- @field _augroup? integer Autocmd group id for resize handlers
local StatusLine = {}
StatusLine.__index = StatusLine

--- @return agentic.ui.StatusLine
function StatusLine:new()
    local instance = setmetatable({
        _tab_page_id = 0,
        _win_nrs = nil,
        _position = nil,
        _text = "",
        _float_winid = nil,
        _float_bufnr = nil,
        _augroup = nil,
    }, StatusLine)

    return instance
end

--- Attach the status line to a tab layout.
--- Safe to call again on a live instance (re-attach): updates position/win_nrs
--- so the next reposition() re-points the existing float to the new anchor.
--- @param tab_page_id integer
--- @param win_nrs table<string, integer>
--- @param position string "left"|"right"|"bottom"
function StatusLine:attach(tab_page_id, win_nrs, position)
    self._tab_page_id = tab_page_id
    self._win_nrs = win_nrs
    self._position = position
    -- Autocmd group registration implemented in Task 4.
    Logger.debug(
        "StatusLine:attach tab="
            .. tostring(tab_page_id)
            .. " position="
            .. tostring(position)
    )
end

--- Store status text and refresh the float content when open.
--- Content refresh implemented in Task 3.
--- @param text string|nil
function StatusLine:set_text(text)
    self._text = text or ""
end

--- Recompute anchor window and update float position/size.
--- Float creation/move implemented in Task 3.
function StatusLine:reposition() end

--- Close the float window, delete the scratch buffer, and clear the autocmd
--- group. Idempotent: safe to call more than once.
--- Full implementation in Tasks 4/5.
function StatusLine:destroy() end

return StatusLine
