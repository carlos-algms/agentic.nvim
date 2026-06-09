--- Shared test helpers for the permission section (button rows + status row).
--- @class agentic.tests.helpers.PermissionSection
local M = {}

--- Return the K button rows above the status row (empty when k = 0).
--- Errors on a degenerate `(end_row, k)` pair so callers cannot silently
--- read pre-section rows.
--- @param bufnr integer
--- @param end_row integer Status row (0-indexed)
--- @param k integer Rendered button-row count
--- @return string[]
function M.button_row_lines(bufnr, end_row, k)
    if k == 0 then
        return {}
    end
    if end_row < k + 1 then
        error(
            "PermissionSection.button_row_lines: bogus end_row "
                .. tostring(end_row)
                .. " for k="
                .. tostring(k)
        )
    end
    local bottom_pad_row = end_row - k - 1
    return vim.api.nvim_buf_get_lines(
        bufnr,
        bottom_pad_row + 1,
        bottom_pad_row + 1 + k,
        false
    )
end

--- Return the status-row text, or nil when the row does not exist.
--- @param bufnr integer
--- @param end_row integer Status row (0-indexed)
--- @return string|nil
function M.status_row_text(bufnr, end_row)
    return vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1]
end

--- All NS_STATUS extmarks on the K rendered rows (button + spacer rows)
--- above the status row. Empty when k = 0.
--- @param bufnr integer
--- @param end_row integer Status row (0-indexed)
--- @param k integer Rendered button-row count
--- @return vim.api.keyset.get_extmark_item[]
function M.button_row_extmarks(bufnr, end_row, k)
    if k == 0 then
        return {}
    end
    local bottom_pad_row = end_row - k - 1
    local ns = vim.api.nvim_create_namespace("agentic_status_footer")
    return vim.api.nvim_buf_get_extmarks(
        bufnr,
        ns,
        { bottom_pad_row + 1, 0 },
        { bottom_pad_row + k, -1 },
        { details = true }
    )
end

return M
