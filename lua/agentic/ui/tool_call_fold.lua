local Config = require("agentic.config")

--- Manual-fold helper for tool call blocks. The chat window uses
--- `foldmethod=manual` and folds are created explicitly via
--- `:N,Nfold` once a block crosses the threshold. This sidesteps
--- foldexpr cache lag (see #210).
--- @class agentic.ui.ToolCallFold
local Fold = {}

--- Returns the configured fold threshold, or nil when folding is disabled.
--- Negative thresholds are clamped to 0.
--- @return integer|nil threshold
function Fold.threshold()
    local cfg = Config.folding and Config.folding.tool_calls
    if not cfg or not cfg.enabled then
        return nil
    end
    return math.max(0, cfg.threshold or 0)
end

--- Whether a block with the given interior line count should be folded.
--- @param interior integer Number of body lines (excludes header, pads, footer)
--- @param is_diff boolean Diff blocks are never folded
--- @return boolean
function Fold.should_fold(interior, is_diff)
    if is_diff then
        return false
    end
    local threshold = Fold.threshold()
    return threshold ~= nil and interior > threshold
end

--- Foldtext: renders collapsed fold text.
--- @return string
function Fold.foldtext()
    local hidden = vim.v.foldend - vim.v.foldstart + 1
    return string.format(
        "  %d lines hidden (Fold: `zo` open | `zc` close)",
        hidden
    )
end

local FOLDTEXT_EXPR = "v:lua.require'agentic.ui.tool_call_fold'.foldtext()"

--- Configure the chat window for manual tool-call folding. Idempotent.
--- @param winid integer
--- @param _bufnr integer
function Fold.setup_window(winid, _bufnr)
    if Fold.threshold() == nil then
        return
    end
    -- Idempotency marker: our `foldtext` is unique per call site, so a
    -- match means we have already configured this window. `foldmethod`
    -- defaults to "manual" globally, so we cannot use it as a marker.
    if vim.wo[winid].foldtext == FOLDTEXT_EXPR then
        return
    end
    vim.wo[winid].foldmethod = "manual"
    vim.wo[winid].foldlevel = 0
    vim.wo[winid].foldenable = true
    vim.wo[winid].foldtext = FOLDTEXT_EXPR
end

--- Create a closed manual fold over `[start_lnum..end_lnum]` (1-indexed,
--- inclusive) in any window currently displaying `bufnr`. No-op when
--- folding is disabled or the buffer is not displayed.
--- @param bufnr integer
--- @param start_lnum integer
--- @param end_lnum integer
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
