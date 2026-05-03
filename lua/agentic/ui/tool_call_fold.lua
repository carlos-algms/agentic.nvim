local Config = require("agentic.config")

--- @class agentic.ui.ToolCallFold
local Fold = {}

--- @return integer|nil threshold nil when folding is disabled
function Fold.threshold()
    local cfg = Config.folding and Config.folding.tool_calls
    if not cfg or not cfg.enabled then
        return nil
    end
    return math.max(0, cfg.threshold or 0)
end

--- @param bufnr integer
--- @param start_row integer 0-indexed inclusive
--- @param end_row integer 0-indexed inclusive
--- @param is_diff boolean
--- @return boolean
function Fold.should_fold(bufnr, start_row, end_row, is_diff)
    if is_diff then
        return false
    end
    local threshold = Fold.threshold()
    if threshold == nil then
        return false
    end
    if start_row > end_row then
        return false
    end

    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
        return false
    end

    local ok, result = pcall(vim.api.nvim_win_text_height, wins[1], {
        start_row = start_row,
        end_row = end_row,
    })
    if not ok or type(result) ~= "table" then
        return false
    end

    return result.all > threshold
end

--- @return string
function Fold.foldtext()
    local hidden = vim.v.foldend - vim.v.foldstart + 1
    return string.format(
        "  %d lines hidden (Fold: `zo` open | `zc` close)",
        hidden
    )
end

local FOLDTEXT_EXPR = "v:lua.require'agentic.ui.tool_call_fold'.foldtext()"

--- @param winid integer
--- @param _bufnr integer
function Fold.setup_window(winid, _bufnr)
    if Fold.threshold() == nil then
        return
    end
    if vim.wo[winid].foldmethod ~= "manual" then
        vim.wo[winid].foldmethod = "manual"
    end
    if vim.wo[winid].foldlevel ~= 0 then
        vim.wo[winid].foldlevel = 0
    end
    vim.wo[winid].foldenable = true
    vim.wo[winid].foldtext = FOLDTEXT_EXPR
end

--- @param bufnr integer
--- @param start_lnum integer 1-indexed inclusive
--- @param end_lnum integer 1-indexed inclusive
function Fold.close_range(bufnr, start_lnum, end_lnum)
    if Fold.threshold() == nil then
        return
    end
    if start_lnum > end_lnum then
        return
    end
    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
        return
    end
    vim.api.nvim_win_call(wins[1], function()
        vim.cmd(
            string.format("silent! noautocmd %d,%dfold", start_lnum, end_lnum)
        )
    end)
end

return Fold
