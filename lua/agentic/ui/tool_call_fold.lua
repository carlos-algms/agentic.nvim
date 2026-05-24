local Config = require("agentic.config")

--- @class agentic.ui.ToolCallFold
local Fold = {}

--- @class agentic.ui.ToolCallFold.ShouldFoldOpts
--- @field bufnr integer
--- @field start_row integer 0-indexed inclusive
--- @field end_row integer 0-indexed inclusive
--- @field status? agentic.acp.ToolCallStatus
--- @field is_diff boolean

--- @return integer|nil threshold nil when folding is disabled
function Fold.threshold()
    local cfg = Config.folding and Config.folding.tool_calls
    if not cfg or not cfg.enabled then
        return nil
    end
    return math.max(0, cfg.threshold or 0)
end

--- @param status agentic.acp.ToolCallStatus|nil
--- @return boolean should_fold
function Fold.should_auto_fold(status)
    if status == "completed" then
        return true
    end

    if status == "failed" then
        local cfg = Config.folding and Config.folding.tool_calls
        return cfg ~= nil and cfg.fold_on_error == true
    end

    return false
end

--- @param opts agentic.ui.ToolCallFold.ShouldFoldOpts
--- @return boolean should_fold
function Fold.should_fold(opts)
    if opts.is_diff then
        return false
    end

    if not Fold.should_auto_fold(opts.status) then
        return false
    end

    local threshold = Fold.threshold()
    if threshold == nil then
        return false
    end

    if opts.start_row > opts.end_row then
        return false
    end

    local wins = vim.fn.win_findbuf(opts.bufnr)

    if #wins == 0 then
        return false
    end

    local ok, result = pcall(vim.api.nvim_win_text_height, wins[1], {
        start_row = opts.start_row,
        end_row = opts.end_row,
    })

    if not ok or type(result) ~= "table" then
        return false
    end

    return result.all > threshold
end

--- @return string
function Fold.foldtext()
    local folded = vim.v.foldend - vim.v.foldstart + 1
    return string.format("  %d lines folded - `zo` open | `zc` close", folded)
end

local FOLDTEXT_EXPR = "v:lua.require'agentic.ui.tool_call_fold'.foldtext()"

--- @param winid integer
--- @param _bufnr integer
function Fold.setup_window(winid, _bufnr)
    if Fold.threshold() == nil then
        return
    end
    if vim.wo[winid].foldmethod ~= "manual" then
        vim.wo[winid][0].foldmethod = "manual"
    end
    if vim.wo[winid].foldlevel ~= 0 then
        vim.wo[winid][0].foldlevel = 0
    end
    vim.wo[winid][0].foldenable = true
    vim.wo[winid][0].foldtext = FOLDTEXT_EXPR
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
