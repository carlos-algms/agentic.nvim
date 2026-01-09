local Logger = require("agentic.utils.logger")

--- @class agentic.Clipboard
local M = {}

--- @class agentic.Clipboard.SetupOpts
--- @field is_widget_open fun(): boolean Callback to check if the Chat widget is visible
--- @field on_paste fun(file_path: string): boolean Callback when file is pasted, returns success

--- Setup image paste/drag-and-drop support via vim.paste override
--- @param opts agentic.Clipboard.SetupOpts
function M.setup(opts)
    -- luacheck: ignore 122 (setting read-only field paste of global vim)
    vim.paste = (function(original_paste)
        --- @param lines string[]
        --- @param phase -1|1|2|3
        return function(lines, phase)
            if not opts.is_widget_open() then
                return original_paste(lines, phase)
            end

            local line = lines[1]

            -- Only handle single-line pastes that look like file paths
            if not line or line == "" or #lines > 1 then
                return original_paste(lines, phase)
            end

            -- Verify file exists
            local stat = vim.uv.fs_stat(line)
            if not stat or stat.type ~= "file" then
                Logger.debug("clipboard: file does not exist", line)
                return original_paste(lines, phase)
            end

            if opts.on_paste(line) then
                return true
            end

            Logger.debug("clipboard: on_paste returned false", line)
            return original_paste(lines, phase)
        end
    end)(vim.paste)
end

return M
