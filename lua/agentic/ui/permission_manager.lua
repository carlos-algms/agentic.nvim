local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

-- Priority order for permission option kinds based on ACP tool-calls documentation
-- Lower number = higher priority (appears first)
-- Order from https://agentclientprotocol.com/protocol/tool-calls.md:
-- 1. allow_once - Allow this operation only this time
-- 2. allow_always - Allow this operation and remember the choice
-- 3. reject_once - Reject this operation only this time
-- 4. reject_always - Reject this operation and remember the choice
local PERMISSION_KIND_PRIORITY = {
    allow_once = 1,
    allow_always = 2,
    reject_once = 3,
    reject_always = 4,
}

local MAX_DIGIT_KEYS = vim.tbl_count(PERMISSION_KIND_PRIORITY)

--- @class agentic.ui.PermissionManager.PermissionRequest
--- @field tool_call_id string
--- @field request agentic.acp.RequestPermission
--- @field callback fun(option_id: string|nil)
--- @field sorted_options agentic.acp.PermissionOption[]

--- @class agentic.ui.PermissionManager
--- @field message_writer agentic.ui.MessageWriter
--- @field pending table<string, agentic.ui.PermissionManager.PermissionRequest> Pending requests keyed by tool_call_id
--- @field _order string[] Insertion order of pending tool_call_ids
--- @field focused_id? string Currently focused tool_call_id
--- @field _cycle_keymaps_installed boolean
local PermissionManager = {}
PermissionManager.__index = PermissionManager

--- @param message_writer agentic.ui.MessageWriter
--- @return agentic.ui.PermissionManager
function PermissionManager:new(message_writer)
    self = setmetatable({
        message_writer = message_writer,
        pending = {},
        _order = {},
        focused_id = nil,
        _cycle_keymaps_installed = false,
    }, self)

    return self
end

function PermissionManager:_install_cycle_keymaps()
    if self._cycle_keymaps_installed then
        return
    end

    if not vim.api.nvim_buf_is_valid(self.message_writer.bufnr) then
        return
    end

    local cfg = (Config.keymaps and Config.keymaps.permission) or {}
    local bufnr = self.message_writer.bufnr

    BufHelpers.multi_keymap_set(cfg.cycle_next or "<C-n>", bufnr, function()
        self:_cycle_focus(1)
    end, { desc = "Permission: focus next pending tool call" })

    BufHelpers.multi_keymap_set(cfg.cycle_prev or "<C-p>", bufnr, function()
        self:_cycle_focus(-1)
    end, { desc = "Permission: focus previous pending tool call" })

    self._cycle_keymaps_installed = true
end

function PermissionManager:_remove_cycle_keymaps()
    if not self._cycle_keymaps_installed then
        return
    end

    if vim.api.nvim_buf_is_valid(self.message_writer.bufnr) then
        local cfg = (Config.keymaps and Config.keymaps.permission) or {}
        local bufnr = self.message_writer.bufnr

        BufHelpers.multi_keymap_del(cfg.cycle_next or "<C-n>", bufnr)
        BufHelpers.multi_keymap_del(cfg.cycle_prev or "<C-p>", bufnr)
    end

    self._cycle_keymaps_installed = false
end

--- @param options agentic.acp.PermissionOption[]
--- @return agentic.acp.PermissionOption[]
function PermissionManager._sort_permission_options(options)
    local sorted = vim.list_extend({}, options)

    table.sort(sorted, function(a, b)
        local priority_a = PERMISSION_KIND_PRIORITY[a.kind] or 999
        local priority_b = PERMISSION_KIND_PRIORITY[b.kind] or 999
        return priority_a < priority_b
    end)

    return sorted
end

--- @return boolean
function PermissionManager:has_pending()
    return next(self.pending) ~= nil
end

--- Register a new permission request. Multiple requests can be pending
--- simultaneously; out-of-order resolution is supported.
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
function PermissionManager:add_request(request, callback)
    if not request.toolCall or not request.toolCall.toolCallId then
        Logger.debug(
            "PermissionManager: Invalid request - missing toolCall.toolCallId"
        )
        pcall(callback, nil)
        return
    end

    local tool_call_id = request.toolCall.toolCallId

    if self.pending[tool_call_id] then
        Logger.debug(
            "PermissionManager: Duplicate request for " .. tool_call_id
        )
        pcall(callback, nil)
        return
    end

    local sorted_options = self._sort_permission_options(request.options)

    --- @type agentic.ui.PermissionManager.PermissionRequest
    local pending_req = {
        tool_call_id = tool_call_id,
        request = request,
        callback = callback,
        sorted_options = sorted_options,
    }

    self.pending[tool_call_id] = pending_req
    table.insert(self._order, tool_call_id)

    if #self._order == 1 then
        self:_install_cycle_keymaps()
    end

    if self.focused_id == nil then
        self:_set_focus(tool_call_id)
    else
        self.message_writer:set_permission_state(tool_call_id, {
            sorted_options = sorted_options,
            is_focused = false,
            focused_button_index = 1,
        })
        self.message_writer:repaint_status_row(tool_call_id)
    end
end

--- Move button focus within the currently focused block. Wraps. No-op when
--- no block is focused or it has zero options.
--- @param direction integer 1 = right (l), -1 = left (h)
--- @protected
function PermissionManager:_cycle_button(direction)
    if not self.focused_id then
        return
    end

    local pending = self.pending[self.focused_id]

    if not pending then
        return
    end

    local n = #pending.sorted_options

    if n == 0 then
        return
    end

    local current = self.message_writer:get_focused_button_index(
        self.focused_id
    ) or 1

    local new_idx = ((current - 1 + direction + n) % n) + 1

    self.message_writer:set_permission_state(self.focused_id, {
        sorted_options = pending.sorted_options,
        is_focused = true,
        focused_button_index = new_idx,
    })
    self.message_writer:repaint_status_row(self.focused_id)
    self:_jump_cursor_to_button(self.focused_id, new_idx)
end

--- @param tool_call_id string
--- @param button_index integer 1-indexed
--- @protected
function PermissionManager:_jump_cursor_to_button(tool_call_id, button_index)
    local row = self.message_writer:get_block_end_row(tool_call_id)
    if not row then
        return
    end

    local winid = self:_find_visible_chat_winid()
    if not winid then
        return
    end

    local col = self.message_writer:get_button_col(tool_call_id, button_index)
    if not col then
        return
    end

    pcall(vim.api.nvim_win_set_cursor, winid, { row + 1, col })
end

--- Resolve the focused block with its currently focused button's option.
function PermissionManager:_submit_focused_button()
    if not self.focused_id then
        return
    end

    local pending = self.pending[self.focused_id]
    if not pending then
        return
    end

    local idx = self.message_writer:get_focused_button_index(self.focused_id)
        or 1
    local opt = pending.sorted_options[idx]

    if not opt then
        return
    end

    self:resolve(self.focused_id, opt.optionId)
end

--- Fire the callback for tool_call_id with option_id and remove the request.
--- If the resolved request was focused, advances focus to next pending head.
--- @param tool_call_id string
--- @param option_id string|nil
function PermissionManager:resolve(tool_call_id, option_id)
    local request = self.pending[tool_call_id]

    if not request then
        return
    end

    local was_focused = self.focused_id == tool_call_id

    self.pending[tool_call_id] = nil

    for i, id in ipairs(self._order) do
        if id == tool_call_id then
            table.remove(self._order, i)
            break
        end
    end

    self.message_writer:set_permission_state(tool_call_id, nil)

    -- Repaint BEFORE the callback so the user sees the buttons gone
    -- immediately. The callback hits the ACP provider; any subsequent
    -- agent update arrives on a later tick (notifications cross
    -- `vim.schedule`), so no UI race. _set_focus below cannot do this
    -- repaint for us because it skips the old-id branch once the id has
    -- been removed from `pending`, and skips the new-id branch when there
    -- is no next head.
    self.message_writer:repaint_status_row(tool_call_id)

    pcall(request.callback, option_id)

    if was_focused then
        self:_set_focus(self._order[1])
    end
end

--- Clear all pending requests (e.g. on session stop or teardown). Fires every
--- pending callback with nil.
function PermissionManager:clear()
    --- @type string[]
    local ids = vim.list_extend({}, self._order)

    for _, tool_call_id in ipairs(ids) do
        local request = self.pending[tool_call_id]
        if request then
            self.pending[tool_call_id] = nil
            self.message_writer:set_permission_state(tool_call_id, nil)
            self.message_writer:repaint_status_row(tool_call_id)
            pcall(request.callback, nil)
        end
    end

    self._order = {}
    self:_remove_focus_keymaps()
    self:_remove_cycle_keymaps()
    self.focused_id = nil
end

--- Remove permission request for a specific tool call ID (e.g. when tool call
--- fails before user granted it). Equivalent to resolve with nil option_id.
--- @param tool_call_id string
function PermissionManager:remove_request_by_tool_call_id(tool_call_id)
    if self.pending[tool_call_id] then
        self:resolve(tool_call_id, nil)
    end
end

--- Set focus to new_id (may be nil to clear focus). Repaints the previously
--- focused block (if still pending) and the new focused block, rotates the
--- focus keymaps (digits + h/l/<CR>), and jumps the cursor to the new
--- focused row. Resets focused_button_index to 1 on every block-focus change.
--- @param new_id string|nil
--- @protected
function PermissionManager:_set_focus(new_id)
    local old_id = self.focused_id

    if new_id == old_id then
        return
    end

    self.focused_id = new_id

    if old_id and self.pending[old_id] then
        self.message_writer:set_permission_state(old_id, {
            sorted_options = self.pending[old_id].sorted_options,
            is_focused = false,
            focused_button_index = 1,
        })
        self.message_writer:repaint_status_row(old_id)
    end

    self:_remove_focus_keymaps()

    if new_id == nil then
        self:_remove_cycle_keymaps()
        return
    end

    local pending = self.pending[new_id]
    if not pending then
        self.focused_id = nil
        return
    end

    self:_install_focus_keymaps(pending)

    self.message_writer:set_permission_state(new_id, {
        sorted_options = pending.sorted_options,
        is_focused = true,
        focused_button_index = 1,
    })
    self.message_writer:repaint_status_row(new_id)
    self:_jump_cursor_to(new_id)
end

--- @param direction integer 1 for next, -1 for previous
function PermissionManager:_cycle_focus(direction)
    local n = #self._order
    if n == 0 then
        return
    end

    local current_idx = nil
    if self.focused_id then
        for i, id in ipairs(self._order) do
            if id == self.focused_id then
                current_idx = i
                break
            end
        end
    end

    if not current_idx then
        self:_set_focus(self._order[1])
        return
    end

    local new_idx = ((current_idx - 1 + direction + n) % n) + 1
    local target_id = self._order[new_idx]

    -- Single-pending case (or cycle landing on same id): focus is unchanged
    -- but the user still expects the cursor to jump back onto the focused row.
    if target_id == self.focused_id then
        self:_jump_cursor_to(target_id)
        return
    end

    self:_set_focus(target_id)
end

--- Install the per-block focus keymaps: digits 1..N for direct dispatch,
--- h / l / <Left> / <Right> for button-focus cycling, and <CR> for submit.
--- Digits fire from anywhere in the chat buffer (direct dispatch is the whole
--- point of inline permissions). Motion / submit keys are `expr = true` and
--- only fire on the focused block's row N; off-row they return the original
--- key so the user can navigate / count normally.
--- @param pending agentic.ui.PermissionManager.PermissionRequest
--- @protected
function PermissionManager:_install_focus_keymaps(pending)
    --- Build an expr-keymap callback that runs `action` only when the cursor
    --- is on the focused row. Off-row, returns `fallback_keys` (typed via
    --- noremap), giving the user normal cursor / count behavior.
    --- On-row, defers the action via `vim.schedule` because expr-keymaps run
    --- inside textlock and cannot call `nvim_buf_set_lines` directly. Without
    --- the defer, the row-N text rewrite in `repaint_status_row` silently
    --- fails and the button labels stay visible (only their highlights drop).
    --- @param fallback_keys string
    --- @param action fun()
    --- @return fun(): string
    local function gated(fallback_keys, action)
        return function()
            if self:_cursor_on_focused_row() then
                vim.schedule(action)
                return ""
            end
            return fallback_keys
        end
    end

    local bufnr = self.message_writer.bufnr

    for i, opt in ipairs(pending.sorted_options) do
        if i > MAX_DIGIT_KEYS then
            break
        end
        local digit = tostring(i)
        local option_id = opt.optionId
        BufHelpers.keymap_set(bufnr, "n", digit, function()
            self:resolve(pending.tool_call_id, option_id)
        end, {
            desc = "Permission: select option " .. digit,
        })
    end

    local function prev_button()
        self:_cycle_button(-1)
    end

    local function next_button()
        self:_cycle_button(1)
    end

    for _, lhs in ipairs({ "h", "<Left>" }) do
        BufHelpers.keymap_set(bufnr, "n", lhs, gated(lhs, prev_button), {
            desc = "Permission: focus previous button",
            expr = true,
        })
    end

    for _, lhs in ipairs({ "l", "<Right>" }) do
        BufHelpers.keymap_set(bufnr, "n", lhs, gated(lhs, next_button), {
            desc = "Permission: focus next button",
            expr = true,
        })
    end

    BufHelpers.keymap_set(
        bufnr,
        "n",
        "<CR>",
        gated("<CR>", function()
            self:_submit_focused_button()
        end),
        {
            desc = "Permission: submit focused button",
            expr = true,
        }
    )
end

--- Find the first focusable window showing the chat buffer. The chat buffer
--- may also live in a non-focusable float (`ChatWidget._hidden_chat_winid`)
--- while the widget is hidden; cursor moves there are invisible to the user,
--- so we skip those windows.
--- @return integer|nil winid
--- @protected
function PermissionManager:_find_visible_chat_winid()
    for _, winid in ipairs(vim.fn.win_findbuf(self.message_writer.bufnr)) do
        if vim.api.nvim_win_get_config(winid).focusable then
            return winid
        end
    end
    return nil
end

--- @return boolean
function PermissionManager:_cursor_on_focused_row()
    if not self.focused_id then
        return false
    end
    local row = self.message_writer:get_block_end_row(self.focused_id)
    if not row then
        return false
    end

    local winid = self:_find_visible_chat_winid()
    if not winid then
        return false
    end
    local cursor_row = vim.api.nvim_win_get_cursor(winid)[1]
    return cursor_row == row + 1
end

function PermissionManager:_remove_focus_keymaps()
    if not vim.api.nvim_buf_is_valid(self.message_writer.bufnr) then
        return
    end

    local bufnr = self.message_writer.bufnr
    for i = 1, MAX_DIGIT_KEYS do
        BufHelpers.keymap_del(bufnr, "n", tostring(i))
    end
    for _, lhs in ipairs({ "h", "l", "<Left>", "<Right>", "<CR>" }) do
        BufHelpers.keymap_del(bufnr, "n", lhs)
    end
end

--- @param tool_call_id string
function PermissionManager:_jump_cursor_to(tool_call_id)
    local row = self.message_writer:get_block_end_row(tool_call_id)
    if not row then
        return
    end

    local winid = self:_find_visible_chat_winid()
    if not winid then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(self.message_writer.bufnr)
    if row + 1 > line_count then
        return
    end

    --- @diagnostic disable-next-line: invisible
    local col = self.message_writer:get_button_col(tool_call_id, 1) or 0
    pcall(vim.api.nvim_win_set_cursor, winid, { row + 1, col })
    -- `zb` (not `zz`) matches the chat auto-scroll convention (`G0zb`),
    -- anchoring row N near the bottom of the window where the user expects
    -- new chat content to live.
    vim.api.nvim_win_call(winid, function()
        vim.cmd("noautocmd normal! zb")
    end)
end

return PermissionManager
