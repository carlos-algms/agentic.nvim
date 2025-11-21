---@class agentic.theme
local Theme = {}

Theme.HL_GROUPS = {
    DIFF_DELETE = "AgenticDiffDelete",
    DIFF_ADD = "AgenticDiffAdd",
    DIFF_DELETE_WORD = "AgenticDiffDeleteWord",
    DIFF_ADD_WORD = "AgenticDiffAddWord",
    STATUS_PENDING = "AgenticStatusPending",
    STATUS_COMPLETED = "AgenticStatusCompleted",
    STATUS_FAILED = "AgenticStatusFailed",
}

local COLORS = {
    diff_delete_word_bg = "#9a3c3c",
    diff_add_word_bg = "#155729",
    status_pending_bg = "#5f4d8f",
    status_completed_bg = "#2d5a3d",
    status_failed_bg = "#7a2d2d",
}

function Theme.setup()
    -- Diff highlights
    Theme._create_hl_if_not_exists(
        Theme.HL_GROUPS.DIFF_DELETE,
        { link = "DiffDelete" }
    )
    Theme._create_hl_if_not_exists(
        Theme.HL_GROUPS.DIFF_ADD,
        { link = "DiffAdd" }
    )
    Theme._create_hl_if_not_exists(
        Theme.HL_GROUPS.DIFF_DELETE_WORD,
        { bg = COLORS.diff_delete_word_bg, bold = true }
    )
    Theme._create_hl_if_not_exists(
        Theme.HL_GROUPS.DIFF_ADD_WORD,
        { bg = COLORS.diff_add_word_bg, bold = true }
    )

    -- Status highlights
    Theme._create_hl_if_not_exists(
        Theme.HL_GROUPS.STATUS_PENDING,
        { bg = COLORS.status_pending_bg }
    )
    Theme._create_hl_if_not_exists(
        Theme.HL_GROUPS.STATUS_COMPLETED,
        { bg = COLORS.status_completed_bg }
    )
    Theme._create_hl_if_not_exists(
        Theme.HL_GROUPS.STATUS_FAILED,
        { bg = COLORS.status_failed_bg }
    )
end

---@private
---@param group string
---@param opts table
function Theme._create_hl_if_not_exists(group, opts)
    local hl = vim.api.nvim_get_hl(0, { name = group })
    -- Check if highlight actually exists by checking for specific keys or count
    -- An empty table {} would have next() == nil, but we want to check if it's truly defined
    if vim.tbl_count(hl) > 0 then
        return
    end
    vim.api.nvim_set_hl(0, group, opts)
end

return Theme