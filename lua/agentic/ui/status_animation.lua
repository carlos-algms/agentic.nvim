--- StatusAnimation module for displaying animated spinners in windows
---
--- This module provides utilities to render animated state indicators (spinners)
--- in buffers using extmarks and timers.
---
--- ## Usage
--- ```lua
--- local StatusAnimation = require("agentic.ui.status_animation")
--- local animator = StatusAnimation:new(bufnr)
--- animator:start("generating")
--- -- later...
--- animator:stop()
--- ```
---

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
--- @field bufnr number Buffer number where animation is rendered
--- @field state agentic.Theme.SpinnerState|nil Current animation state
--- @field timer uv.uv_timer_t|nil uv timer object
--- @field spinner_idx number Current spinner frame index
--- @field extmark_id number|nil Current extmark ID
local StatusAnimation = {}
StatusAnimation.__index = StatusAnimation

--- @param bufnr number
--- @return agentic.ui.StatusAnimation
function StatusAnimation:new(bufnr)
    local instance = setmetatable({
        bufnr = bufnr,
        state = nil,
        timer = nil,
        spinner_idx = 1,
        extmark_id = nil,
    }, StatusAnimation)

    return instance
end

--- Start the animation with the given state
--- Always stops and restarts to avoid overlapping with new content
--- @param state agentic.Theme.SpinnerState
function StatusAnimation:start(state)
    self:stop()

    self.state = state
    self.spinner_idx = 1
    self:_render_frame()
end

function StatusAnimation:stop()
    if self.timer then
        pcall(function()
            self.timer:stop()
        end)
        pcall(function()
            self.timer:close()
        end)
        self.timer = nil
    end

    if self.extmark_id then
        pcall(
            vim.api.nvim_buf_del_extmark,
            self.bufnr,
            NS_ANIMATION,
            self.extmark_id
        )
    end

    self.extmark_id = nil
    self.state = nil
end

function StatusAnimation:_render_frame()
    if not self.state or not vim.api.nvim_buf_is_valid(self.bufnr) then
        self:stop()
        return
    end

    local spinner_chars = Config.spinner_chars[self.state]
        or Config.spinner_chars.generating

    local char = spinner_chars[self.spinner_idx] or spinner_chars[1]

    self.spinner_idx = (self.spinner_idx % #spinner_chars) + 1

    local display_text = string.format(" %s %s ", char, self.state)

    local hl_group = Theme.get_spinner_hl_group(self.state)
    local lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
    local line_num = math.max(0, #lines - 1)

    local virt_text = { { display_text, hl_group } }

    local winid = vim.fn.bufwinid(self.bufnr)
    if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
        local win_width = vim.api.nvim_win_get_width(winid)
        local padding =
            math.floor((win_width - vim.fn.strdisplaywidth(display_text)) / 2)
        table.insert(
            virt_text,
            1,
            { string.rep(" ", math.max(0, padding)), "Normal" }
        )
    end

    local delay = TIMING[self.state] or TIMING.generating

    local virt_lines = {
        { { "" } }, -- Empty line above
        virt_text, -- Animation in middle
        { { "" } }, -- Empty line below
    }

    self.extmark_id =
        vim.api.nvim_buf_set_extmark(self.bufnr, NS_ANIMATION, line_num, 0, {
            id = self.extmark_id, -- Reuse existing extmark ID to update in-place
            virt_lines = virt_lines,
            virt_lines_above = false,
        })

    self.timer = vim.defer_fn(function()
        self:_render_frame()
    end, delay)
end

return StatusAnimation
