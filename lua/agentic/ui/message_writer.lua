local Logger = require("agentic.utils.logger")

---@class agentic.ui.MessageWriter
---@field bufnr integer
local MessageWriter = {}
MessageWriter.__index = MessageWriter

---@param bufnr integer
---@return agentic.ui.MessageWriter
function MessageWriter:new(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        error("Invalid buffer number: " .. tostring(bufnr))
    end

    local instance = setmetatable({
        bufnr = bufnr,
    }, self)

    -- Make buffer readonly for users, but we can still write programmatically
    vim.bo[bufnr].modifiable = false

    vim.bo[bufnr].syntax = "markdown"

    local ok, _ = pcall(vim.treesitter.start, bufnr, "markdown")
    if not ok then
        Logger.debug("MessageWriter: Treesitter markdown parser not available")
    end

    return instance
end

---@param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message(update)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        Logger.debug("MessageWriter: Buffer is no longer valid")
        return
    end

    local text = nil
    if
        update.content
        and update.content.type == "text"
        and update.content.text
    then
        text = update.content.text
    else
        -- For now, only handle text content
        Logger.debug(
            "MessageWriter: Skipping non-text content or missing content"
        )
        return
    end

    if not text or text == "" then
        return
    end

    local lines = vim.split(text, "\n", { plain = true })
    self:_append_lines(lines)
end

---@param lines string[]
---@return nil
function MessageWriter:_append_lines(lines)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    vim.bo[self.bufnr].modifiable = true

    vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)

    vim.bo[self.bufnr].modifiable = false
end

return MessageWriter
