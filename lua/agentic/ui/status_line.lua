local Logger = require("agentic.utils.logger")
local BufHelpers = require("agentic.utils.buf_helpers")

-- 50 is Neovim's default float zindex. The status float anchors to a split
-- (no zindex), so 50 is sufficient; bump only if it must sit above other
-- agentic floats that use a higher zindex.
local FLOAT_ZINDEX = 50

--- Returns the bottom-most valid agentic winid for the given win_nrs + position.
--- Priority for position="bottom": todos > diagnostics > files > code > input > chat.
--- Priority for position="left"/"right": input > chat.
--- Returns nil when no valid winid is found.
--- @param win_nrs table<string, integer>
--- @param position string
--- @return integer|nil
local function bottom_anchor_winid(win_nrs, position)
    local function valid(key)
        local id = win_nrs[key]
        return id and vim.api.nvim_win_is_valid(id) and id or nil
    end

    if position == "bottom" then
        return valid("todos")
            or valid("diagnostics")
            or valid("files")
            or valid("code")
            or valid("input")
            or valid("chat")
    end

    return valid("input") or valid("chat")
end

--- Per-tab floating status surface for the agentic chat UI.
---
--- Owns a single floating window anchored to the bottom row of the bottom-most
--- agentic window. The float is driven by four public calls: `attach`,
--- `set_text`, `reposition`, and `destroy`. All mutable state lives on the
--- instance; no module-level mutable per-tab data.

--- @class agentic.ui.StatusLine
--- @field _tab_page_id? integer Owning tabpage id
--- @field _win_nrs? table<string, integer> Reference to ChatWidget.win_nrs
--- @field _position? "left"|"right"|"bottom" Layout position
--- @field _text string Status text content (default "")
--- @field _float_winid? integer Float window id, nil when not open
--- @field _float_bufnr? integer Scratch buffer id for the float
--- @field _augroup? integer Autocmd group id for resize handlers
local StatusLine = {}
StatusLine.__index = StatusLine

--- @return agentic.ui.StatusLine
function StatusLine:new()
    local instance = setmetatable({
        _tab_page_id = nil,
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
--- `clear = true` on the augroup makes re-attach idempotent — rotate_layout
--- calls hide→show→attach again and must not stack duplicate autocmds.
--- @param tab_page_id integer
--- @param win_nrs table<string, integer>
--- @param position "left"|"right"|"bottom"
function StatusLine:attach(tab_page_id, win_nrs, position)
    self._tab_page_id = tab_page_id
    self._win_nrs = win_nrs
    self._position = position

    local group_name = "AgenticStatusLine_" .. tab_page_id
    self._augroup = vim.api.nvim_create_augroup(group_name, { clear = true })

    -- Register resize handlers on the tab-scoped group.
    -- The callback is split into two parts for testability:
    --   1. Outer: fast-context guard (synchronous, safe in all contexts).
    --   2. Inner: _on_resize() — tabpage re-guard + reposition — callable
    --      directly from tests without vim.schedule.
    local function on_resize_callback()
        if not vim.api.nvim_tabpage_is_valid(self._tab_page_id) then
            return
        end
        vim.schedule(function()
            self:_on_resize()
        end)
    end

    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
        group = self._augroup,
        callback = on_resize_callback,
    })

    Logger.debug(
        "StatusLine:attach tab="
            .. tostring(tab_page_id)
            .. " position="
            .. tostring(position)
    )
end

--- Re-guard tabpage validity and reposition the float.
--- Called from the vim.schedule wrapper in the autocmd callback.
--- Also called directly from tests (synchronous) to avoid async traps.
function StatusLine:_on_resize()
    if not vim.api.nvim_tabpage_is_valid(self._tab_page_id) then
        return
    end
    self:reposition()
end

--- Store status text and refresh the float content when open.
--- @param text string|nil
function StatusLine:set_text(text)
    self._text = text or ""
    if self._float_bufnr and vim.api.nvim_buf_is_valid(self._float_bufnr) then
        BufHelpers.with_modifiable(self._float_bufnr, function(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { self._text })
        end)
    end
end

--- Returns the bottom-most valid agentic winid for the current layout.
--- Delegates to the module-level bottom_anchor_winid function.
--- @return integer|nil
function StatusLine:_anchor_winid()
    return bottom_anchor_winid(self._win_nrs or {}, self._position or "")
end

--- Recompute anchor window and update float position/size.
--- Creates the float if absent; moves it when the anchor changes.
--- Re-applies stored text after (re)creating so content survives re-anchor.
function StatusLine:reposition()
    local anchor = self:_anchor_winid()

    if not anchor then
        if
            self._float_winid and vim.api.nvim_win_is_valid(self._float_winid)
        then
            pcall(vim.api.nvim_win_close, self._float_winid, true)
        end
        self._float_winid = nil
        -- _float_bufnr is intentionally kept: the buffer is reused when the
        -- layout reopens and reposition() is called again. The asymmetry with
        -- _float_winid being nil'd is deliberate.
        return
    end

    local width = vim.api.nvim_win_get_width(anchor)
    local row = vim.api.nvim_win_get_height(anchor) - 1

    if self._float_winid and vim.api.nvim_win_is_valid(self._float_winid) then
        -- Move the existing float to the (possibly new) anchor.
        -- Guard against the anchor becoming invalid between _anchor_winid() and
        -- here (real race once Task 4 schedules reposition on resize events).
        local ok = pcall(vim.api.nvim_win_set_config, self._float_winid, {
            relative = "win",
            win = anchor,
            anchor = "NW",
            row = row,
            col = 0,
            width = width,
            height = 1,
        })
        if not ok then
            -- Anchor went away; nil out so the next reposition recreates cleanly.
            self._float_winid = nil
        end
    else
        -- Create scratch buffer once and make it non-modifiable by default.
        if
            not self._float_bufnr
            or not vim.api.nvim_buf_is_valid(self._float_bufnr)
        then
            self._float_bufnr = vim.api.nvim_create_buf(false, true)
            vim.bo[self._float_bufnr].modifiable = false
        end

        self._float_winid = vim.api.nvim_open_win(self._float_bufnr, false, {
            relative = "win",
            win = anchor,
            anchor = "NW",
            row = row,
            col = 0,
            width = width,
            height = 1,
            focusable = false,
            style = "minimal",
            zindex = FLOAT_ZINDEX,
            noautocmd = true,
        })

        vim.wo[self._float_winid][0].wrap = false
        vim.wo[self._float_winid][0].winhl = "Normal:NormalFloat"

        -- Re-apply stored text after creation so it survives re-anchor.
        -- Not needed on the move path: the buffer already holds the correct text.
        self:set_text(self._text)
    end
end

--- Close the float window, delete the scratch buffer, and clear the autocmd
--- group. Idempotent: safe to call more than once.
--- Full implementation in Task 5.
function StatusLine:destroy() end

return StatusLine
