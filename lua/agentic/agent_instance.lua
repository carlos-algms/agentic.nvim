local Logger = require("agentic.utils.logger")

---@class agentic.state.Instance
---@field chat_widget agentic.ui.ChatWidget
---@field agent_client agentic.acp.ACPClient

---@class agentic.AgentInstance
local AgentInstance = {}

--- Read the file content from a buffer if loaded, to get unsaved changes or from disk otherwise
---@param abs_path string
---@return string[]|nil lines
---@return string|nil error
local function read_file_from_buf_or_disk(abs_path)
    local ok, bufnr = pcall(vim.fn.bufnr, abs_path)
    if ok then
        if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            return lines, nil
        end
    end

    local stat = vim.uv.fs_stat(abs_path)
    if stat and stat.type == "directory" then
        return {}, "Cannot read a directory as file: " .. abs_path
    end

    local file, open_err = io.open(abs_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        content = content:gsub("\r\n", "\n")
        return vim.split(content, "\n"), nil
    else
        return {}, open_err
    end
end

---@param tab_page_id integer
function AgentInstance.make_instance(tab_page_id)
    local ChatWidget = require("agentic.ui.chat_widget")
    local Client = require("agentic.acp.acp_client")

    local agent_client = Client:new({
        handlers = {
            on_error = function(err)
                Logger.debug("Agent error: ", err)
                vim.notify(
                    "Agent error: " .. err,
                    vim.log.levels.ERROR,
                    { title = "🐞 Agent Error" }
                )
            end,

            on_read_file = function(abs_path, line, limit, callback)
                local lines, err = read_file_from_buf_or_disk(abs_path)
                lines = lines or {}

                if err ~= nil then
                    vim.notify(
                        "Agent file read error: " .. err,
                        vim.log.levels.ERROR,
                        { title = " Read file error" }
                    )
                    callback(nil)
                    return
                end

                if line ~= nil and limit ~= nil then
                    lines = vim.list_slice(lines, line, line + limit)
                end

                local content = table.concat(lines, "\n")
                callback(content)
            end,

            on_write_file = function(abs_path, content, callback)
                local file = io.open(abs_path, "w")
                if file then
                    file:write(content)
                    file:close()

                    local buffers = vim.tbl_filter(function(bufnr)
                        return vim.api.nvim_buf_is_valid(bufnr)
                            and vim.fn.fnamemodify(
                                    vim.api.nvim_buf_get_name(bufnr),
                                    ":p"
                                )
                                == abs_path
                    end, vim.api.nvim_list_bufs())

                    local bufnr = next(buffers)

                    if bufnr then
                        vim.api.nvim_buf_call(bufnr, function()
                            local view = vim.fn.winsaveview()
                            vim.cmd("checktime")
                            vim.fn.winrestview(view)
                        end)
                    end

                    callback(nil)
                    return
                end
                callback("Failed to write file: " .. abs_path)
            end,

            on_session_update = function(update)
                -- Handle state changes of the agent connection
            end,

            on_request_permission = function(request)
                -- Handle permission requests from the agent
            end,
        },
    })

    local chat_widget = ChatWidget:new(tab_page_id, function(prompt)
        agent_client:send_prompt(agent_client.state)
    end)

    --- @type agentic.state.Instance
    local instance = {
        chat_widget = chat_widget,
        agent_client = agent_client,
    }

    return instance
end

return AgentInstance
