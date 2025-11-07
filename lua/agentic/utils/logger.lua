local Config = require("agentic.config")

---@class agentic.utils.Logger
local M = {}

function M.get_timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function format_debug_message(...)
    if not Config.debug then
        return nil
    end

    local args = { ... }

    if #args == 0 then
        return nil
    end

    local info = debug.getinfo(3, "Sl")
    local caller_source = info.source:match("@(.+)$") or "unknown"
    local caller_module =
        caller_source:gsub("^.*/lua/", ""):gsub("%.lua$", ""):gsub("/", ".")

    local timestamp = M.get_timestamp()
    local log_parts = {
        string.format(
            "[%s] [%s:%d]",
            timestamp,
            caller_module,
            info.currentline
        ),
    }

    for _, arg in ipairs(args) do
        if type(arg) == "string" then
            table.insert(log_parts, arg)
        else
            table.insert(log_parts, vim.inspect(arg))
        end
    end

    return log_parts
end

function M.debug(...)
    local formatted_message = format_debug_message(...)

    if formatted_message then
        print(unpack(formatted_message))
    end
end

function M.debug_to_file(...)
    local log_parts = format_debug_message(...)
    if not log_parts then
        return
    end

    local log_message = table.concat(log_parts, " ")
        .. "\n"
        .. string.rep("=", 100)
        .. "\n\n"

    local cache_dir = vim.fn.stdpath("cache")
    local log_file_path = cache_dir .. "/agentic_debug.log"

    local file = io.open(log_file_path, "a")
    if file then
        file:write(log_message)
        file:close()
    else
        vim.notify(
            "Failed to write to log file: " .. log_file_path,
            vim.log.levels.WARN
        )
    end
end

return M
