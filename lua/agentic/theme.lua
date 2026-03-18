local FileSystem = require("agentic.utils.file_system")

--- @alias agentic.Theme.SpinnerState "generating" | "thinking" | "searching" | "busy"

--- @class agentic.Theme
local Theme = {}

Theme.HL_GROUPS = {
    DIFF_DELETE = "AgenticDiffDelete",
    DIFF_ADD = "AgenticDiffAdd",
    DIFF_DELETE_WORD = "AgenticDiffDeleteWord",
    DIFF_ADD_WORD = "AgenticDiffAddWord",
    STATUS_PENDING = "AgenticStatusPending",
    STATUS_COMPLETED = "AgenticStatusCompleted",
    STATUS_FAILED = "AgenticStatusFailed",
    CODE_BLOCK_FENCE = "AgenticCodeBlockFence",
    WIN_BAR_TITLE = "AgenticTitle",

    SPINNER_GENERATING = "AgenticSpinnerGenerating",
    SPINNER_THINKING = "AgenticSpinnerThinking",
    SPINNER_SEARCHING = "AgenticSpinnerSearching",
    SPINNER_BUSY = "AgenticSpinnerBusy",
}

--- A lang map of extension to language identifier for markdown code fences
--- Keep only possible unknown mappings
local lang_map = {
    py = "python",
    rb = "ruby",
    rs = "rust",
    kt = "kotlin",
    htm = "html",
    yml = "yaml",
    sh = "bash",
    typescriptreact = "tsx",
    javascriptreact = "jsx",
    markdown = "md",
}

local status_hl = {
    pending = Theme.HL_GROUPS.STATUS_PENDING,
    in_progress = Theme.HL_GROUPS.STATUS_PENDING, -- pending and in_progress should look the same, to avoid too many colors, added initially because of Codex, but not limited to it
    completed = Theme.HL_GROUPS.STATUS_COMPLETED,
    failed = Theme.HL_GROUPS.STATUS_FAILED,
}

local spinner_hl = {
    generating = Theme.HL_GROUPS.SPINNER_GENERATING,
    thinking = Theme.HL_GROUPS.SPINNER_THINKING,
    searching = Theme.HL_GROUPS.SPINNER_SEARCHING,
    busy = Theme.HL_GROUPS.SPINNER_BUSY,
}

function Theme.setup()
    -- stylua: ignore start
    local highlights = {
        -- Diff highlights
        { Theme.HL_GROUPS.DIFF_DELETE, { link = "DiffDelete" } },
        { Theme.HL_GROUPS.DIFF_ADD, { link = "DiffAdd" } },
        -- TODO: Add better link for these two groups
        { Theme.HL_GROUPS.DIFF_DELETE_WORD, { link = "DiffDelete", bold = true } },
        { Theme.HL_GROUPS.DIFF_ADD_WORD, { link = "DiffAdd", bold = true } },

        -- Status highlights
        { Theme.HL_GROUPS.STATUS_PENDING, { link = "InfoFloat" } },
        { Theme.HL_GROUPS.STATUS_COMPLETED, { link = "OkFloat" } },
        { Theme.HL_GROUPS.STATUS_FAILED, { link = "ErrorFloat" } },
        { Theme.HL_GROUPS.CODE_BLOCK_FENCE, { link = "Directory" } },

        -- Title highlight
        { Theme.HL_GROUPS.WIN_BAR_TITLE, { link = "Title", bold = true } },

        -- Spinner highlights
        { Theme.HL_GROUPS.SPINNER_GENERATING, { link = "Constant", bold = true } },
        { Theme.HL_GROUPS.SPINNER_THINKING, { link = "Float", bold = true } },
        { Theme.HL_GROUPS.SPINNER_SEARCHING, { link = "Structure", bold = true } },
        { Theme.HL_GROUPS.SPINNER_BUSY, { link = "Comment" } },
    }
    -- stylua: ignore end

    for _, hl in ipairs(highlights) do
        Theme._create_hl_if_not_exists(hl[1], hl[2])
    end
end

---Get language identifier from file path for markdown code fences
--- @param file_path string
--- @return string language
function Theme.get_language_from_path(file_path)
    local ext = FileSystem.get_file_extension(file_path)
    if not ext or ext == "" then
        return ""
    end

    return lang_map[ext] or ext
end

--- @param status string
--- @return string hl_group
function Theme.get_status_hl_group(status)
    return status_hl[status] or "Comment"
end

--- @param state agentic.Theme.SpinnerState
--- @return string hl_group
function Theme.get_spinner_hl_group(state)
    return spinner_hl[state] or Theme.HL_GROUPS.SPINNER_GENERATING
end

--- @private
--- @param group string
--- @param opts table
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
