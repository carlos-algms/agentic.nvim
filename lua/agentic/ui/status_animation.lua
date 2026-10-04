local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Theme = require("agentic.theme")

local NS_ANIMATION = vim.api.nvim_create_namespace("agentic_animation")

--- @type table<agentic.Theme.SpinnerState, number>
local TIMING = {
    generating = 200,
    thinking = 600,
    searching = 600,
    busy = 100,
}

--- @class agentic.ui.StatusAnimation
--- @field _bufnr number
--- @field _state? agentic.Theme.SpinnerState
--- @field _next_frame_handle? uv.uv_timer_t
--- @field _spinner_idx number
--- @field _extmark_id? number
--- @field _epoch number Bumped by every `start`; a stale frame reschedules nothing
local StatusAnimation = {}
StatusAnimation.__index = StatusAnimation

--- @param bufnr number
--- @return agentic.ui.StatusAnimation
function StatusAnimation:new(bufnr)
    local instance = setmetatable({
        _bufnr = bufnr,
        _state = nil,
        _next_frame_handle = nil,
        _spinner_idx = 1,
        _extmark_id = nil,
        _epoch = 0,
    }, StatusAnimation)

    return instance
end

--- @param state agentic.Theme.SpinnerState
function StatusAnimation:start(state)
    self:stop()

    -- `stop` cannot un-queue an already-fired `vim.defer_fn` callback.
    -- Regression: status_animation.test.lua::"drops a stale frame instead of scheduling a successor"
    self._epoch = self._epoch + 1

    self._state = state
    self._spinner_idx = 1
    self:_render_frame(self._epoch)
end

function StatusAnimation:stop()
    self._state = nil

    if self._next_frame_handle then
        pcall(function()
            self._next_frame_handle:stop()
        end)
        pcall(function()
            self._next_frame_handle:close()
        end)
        self._next_frame_handle = nil
    end

    if self._extmark_id then
        pcall(
            vim.api.nvim_buf_del_extmark,
            self._bufnr,
            NS_ANIMATION,
            self._extmark_id
        )
    end

    self._extmark_id = nil
end

--- @param epoch number Epoch this frame was scheduled with
function StatusAnimation:_render_frame(epoch)
    if epoch ~= self._epoch then
        return
    end

    if not self._state or not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end

    local spinner_chars = Config.spinner_chars[self._state]
        or Config.spinner_chars.generating

    local char = spinner_chars[self._spinner_idx] or spinner_chars[1]

    self._spinner_idx = (self._spinner_idx % #spinner_chars) + 1

    local display_text = string.format(" %s %s ", char, self._state)

    local hl_group = Theme.get_spinner_hl_group(self._state)
    local lines = vim.api.nvim_buf_get_lines(self._bufnr, 0, -1, false)
    local line_num = math.max(0, #lines - 1)

    local virt_text = { { display_text, hl_group } }

    -- A background session animates in its own tab, so the centring padding must measure that window.
    local winid = BufHelpers.find_visible_win(self._bufnr)
    if winid then
        local win_width = vim.api.nvim_win_get_width(winid)
        local text_width = vim.fn.strdisplaywidth(display_text)
        if win_width > text_width then
            local padding = math.floor((win_width - text_width) / 2)
            table.insert(virt_text, 1, { string.rep(" ", padding), "Normal" })
        end
    end

    local delay = TIMING[self._state] or TIMING.generating

    local virt_lines = {
        { { "" } },
        virt_text,
        { { "" } },
    }

    self._extmark_id =
        vim.api.nvim_buf_set_extmark(self._bufnr, NS_ANIMATION, line_num, 0, {
            id = self._extmark_id,
            virt_lines = virt_lines,
            virt_lines_above = false,
        })

    self._next_frame_handle = vim.defer_fn(function()
        self:_render_frame(epoch)
    end, delay)
end

return StatusAnimation
