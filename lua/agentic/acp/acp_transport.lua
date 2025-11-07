local logger = require("agentic.utils.logger")
local uv = vim.uv or vim.loop

---@alias agentic.acp.TransportType "stdio" | "tcp" | "websocket"

---@class agentic.acp.ACPTransportModule
local M = {}

---@class agentic.acp.TransportCallbacks
---@field on_state_change fun(state: agentic.acp.ClientConnectionState): nil
---@field on_message fun(message: table): nil
---@field on_reconnect fun(): nil

---@class agentic.acp.StdioTransportConfig
---@field command string Command to spawn agent
---@field args? string[] Arguments for agent command
---@field env? table<string, string> Environment variables
---@field enable_reconnect? boolean Enable auto-reconnect
---@field max_reconnect_attempts? number Maximum reconnection attempts

---Create stdio transport for ACP communication
---@param config agentic.acp.StdioTransportConfig
---@param callbacks agentic.acp.TransportCallbacks
---@return agentic.acp.ACPTransportInstance
function M.create_stdio_transport(config, callbacks)
    local reconnect_count = 0

    --- @class agentic.acp.ACPTransportInstance
    local transport = {
        --- @type uv.uv_pipe_t|nil
        stdin = nil,
        --- @type uv.uv_pipe_t|nil
        stdout = nil,
        --- @type uv.uv_process_t|nil
        process = nil,
    }

    --- @param data string
    function transport:send(data)
        if transport.stdin and not transport.stdin:is_closing() then
            transport.stdin:write(data .. "\n")
            return true
        end
        return false
    end

    function transport:start()
        callbacks.on_state_change("connecting")

        local stdin = uv.new_pipe(false)
        local stdout = uv.new_pipe(false)
        local stderr = uv.new_pipe(false)

        if not stdin or not stdout or not stderr then
            callbacks.on_state_change("error")
            error("Failed to create pipes for ACP agent")
        end

        local args = vim.deepcopy(config.args or {})
        local env = config.env

        local final_env = {}

        local path = vim.fn.getenv("PATH")
        if path then
            final_env[#final_env + 1] = "PATH=" .. path
        end

        if env then
            for k, v in pairs(env) do
                final_env[#final_env + 1] = k .. "=" .. v
            end
        end

        ---@diagnostic disable-next-line: missing-fields
        local handle, pid = uv.spawn(config.command, {
            args = args,
            env = final_env,
            stdio = { stdin, stdout, stderr },
            detached = false,
        }, function(code, signal)
            logger.debug(
                "ACP agent exited with code ",
                code,
                " and signal ",
                signal
            )
            callbacks.on_state_change("disconnected")

            if transport.process then
                transport.process:close()
                transport.process = nil
            end

            -- Handle reconnection if enabled
            if config.enable_reconnect then
                local max_attempts = config.max_reconnect_attempts or 3

                if reconnect_count < max_attempts then
                    reconnect_count = reconnect_count + 1

                    vim.defer_fn(function()
                        callbacks.on_reconnect()
                    end, 2000)
                end
            end
        end)

        logger.debug("Spawned ACP agent process with PID ", tostring(pid))

        if not handle then
            callbacks.on_state_change("error")
            error("Failed to spawn ACP agent process")
        end

        transport.process = handle
        transport.stdin = stdin
        transport.stdout = stdout

        callbacks.on_state_change("connected")

        local chunks = ""
        stdout:read_start(function(err, data)
            if err then
                vim.notify("ACP stdout error: " .. err, vim.log.levels.ERROR)
                callbacks.on_state_change("error")
                return
            end

            if data then
                chunks = chunks .. data

                -- Split on newlines and process complete JSON-RPC messages
                local lines = vim.split(chunks, "\n", { plain = true })
                chunks = lines[#lines]

                for i = 1, #lines - 1 do
                    local line = vim.trim(lines[i])
                    if line ~= "" then
                        local ok, message = pcall(vim.json.decode, line)
                        if ok then
                            callbacks.on_message(message)
                        else
                            vim.schedule(function()
                                vim.notify(
                                    "Failed to parse JSON-RPC message: " .. line,
                                    vim.log.levels.WARN
                                )
                            end)
                        end
                    end
                end
            end
        end)

        stderr:read_start(function(_, data)
            if data then
                if
                    not (
                        data:match("Session not found")
                        or data:match("session/prompt")
                        or data:match("Spawning Claude Code process")
                    )
                then
                    vim.schedule(function()
                        logger.debug("ACP stderr: ", data)
                    end)
                end
            end
        end)
    end

    function transport:stop()
        if transport.process and not transport.process:is_closing() then
            local process = transport.process
            transport.process = nil

            if not process then
                return
            end

            -- Try to terminate gracefully
            pcall(function()
                process:kill(15)
            end)
            -- then force kill, it'll fail harmlessly if already exited
            pcall(function()
                process:kill(9)
            end)

            process:close()
        end

        if transport.stdin then
            transport.stdin:close()
            transport.stdin = nil
        end
        if transport.stdout then
            transport.stdout:close()
            transport.stdout = nil
        end

        callbacks.on_state_change("disconnected")
    end

    return transport
end

return M
