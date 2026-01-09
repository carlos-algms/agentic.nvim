local BufHelpers = require("agentic.utils.buf_helpers")

--- Floating message window utilities
--- @class agentic.ui.FloatingMessage
local M = {}

--- @class agentic.ui.FloatingMessage.ShowOpts
--- @field body string[] Lines to display in the window
--- @field title? string Window title (default: " Agentic.nvim ")
--- @field footer? string Window footer (default: " q or <Esc> to close ")
--- @field width_ratio? number Window width as ratio of screen width (default: 0.5)
--- @field filetype? string Buffer filetype (default: "markdown")

--- Show a floating window with markdown content
--- @param opts agentic.ui.FloatingMessage.ShowOpts
function M.show(opts)
    local width_ratio = opts.width_ratio or 0.5
    local width = math.floor(vim.o.columns * width_ratio)
    local height = #opts.body + 3
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local buf = vim.api.nvim_create_buf(false, true)

    local filetype = opts.filetype or "markdown"
    vim.bo[buf].filetype = filetype
    vim.bo[buf].syntax = filetype
    pcall(vim.treesitter.start, buf, filetype)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.body)

    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = opts.title or " Agentic.nvim ",
        title_pos = "center",
        footer = opts.footer or " q or <Esc> to close ",
        footer_pos = "right",
    })

    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true

    BufHelpers.keymap_set(buf, "n", "q", function()
        vim.cmd.close()
    end)
    BufHelpers.keymap_set(buf, "n", "<Esc>", function()
        vim.cmd.close()
    end)

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
            vim.schedule(function()
                if vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_close(win, true)
                end
            end)
        end,
    })
end

return M
