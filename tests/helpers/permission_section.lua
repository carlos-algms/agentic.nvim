--- Shared test helpers for the permission section (button rows + status row).
--- @class agentic.tests.helpers.PermissionSection
local M = {}

--- Return the K button rows above the status row (empty when k = 0).
--- @param bufnr integer
--- @param end_row integer Status row (0-indexed)
--- @param k integer Rendered button-row count
--- @return string[]
function M.button_row_lines(bufnr, end_row, k)
    if k == 0 then
        return {}
    end
    local bottom_pad_row = end_row - k - 1
    return vim.api.nvim_buf_get_lines(
        bufnr,
        bottom_pad_row + 1,
        bottom_pad_row + 1 + k,
        false
    )
end

--- @param bufnr integer
--- @param end_row integer Status row (0-indexed)
--- @return string
function M.status_row_text(bufnr, end_row)
    return vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1]
        or ""
end

return M
