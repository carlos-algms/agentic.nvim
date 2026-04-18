local Config = require("agentic.config")

--- @class agentic.ui.ToolCallFold.Block
--- @field start_row integer 0-indexed header row of the block
--- @field end_row integer 0-indexed footer row of the block (inclusive)
--- @field foldable boolean Whether this block should be folded

--- @alias agentic.ui.ToolCallFold.Getter fun(): agentic.ui.ToolCallFold.Block[]

--- @class agentic.ui.ToolCallFold
local Fold = {}

--- Strong table: bufnr -> { getter = agentic.ui.ToolCallFold.Getter }
--- Strong because the getter closure has no other referent.
--- Must be cleaned up via unregister().
--- @type table<integer, { getter: agentic.ui.ToolCallFold.Getter }>
local instances_by_buffer = {}

--- Register a getter for a buffer. Called once per MessageWriter instance.
--- @param bufnr integer
--- @param getter agentic.ui.ToolCallFold.Getter
function Fold.register(bufnr, getter)
    instances_by_buffer[bufnr] = { getter = getter }
end

--- Remove a buffer's getter. Safe to call on an already-unregistered bufnr.
--- @param bufnr integer
function Fold.unregister(bufnr)
    instances_by_buffer[bufnr] = nil
end

--- Foldexpr: called by Neovim for each line. Returns 0 (not foldable) or 1 (foldable).
--- Not a method - dispatched via v:lua, which cannot invoke instance methods.
--- @param bufnr integer
--- @param lnum integer 1-indexed line number
--- @return integer fold_level 0 or 1
function Fold.foldexpr(bufnr, lnum)
    local state = instances_by_buffer[bufnr]
    if not state then
        return 0
    end
    local blocks = state.getter()
    for _, block in ipairs(blocks) do
        if
            block.foldable
            and lnum >= block.start_row + 2
            and lnum <= block.end_row
        then
            return 1
        end
    end
    return 0
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

--- Apply fold-related window options to the chat window.
--- @param winid integer
--- @param bufnr integer
function Fold.setup_window(winid, bufnr)
    local cfg = Config.folding and Config.folding.tool_calls
    if not cfg or not cfg.enabled then
        return
    end

    local desired_expr = string.format(
        "v:lua.require'agentic.ui.tool_call_fold'.foldexpr(%d, v:lnum)",
        bufnr
    )

    -- Idempotent: if this window has already been configured by us, skip.
    -- Reapplying would reset foldlevel=0, re-closing folds the user opened.
    if vim.wo[winid].foldexpr == desired_expr then
        return
    end

    vim.wo[winid].foldmethod = "expr"
    vim.wo[winid].foldexpr = desired_expr
    vim.wo[winid].foldlevel = 0
    vim.wo[winid].foldenable = true
    vim.wo[winid].foldtext =
        "v:lua.require'agentic.ui.tool_call_fold'.foldtext()"
end

return Fold
