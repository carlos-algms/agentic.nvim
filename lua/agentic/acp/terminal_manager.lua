local Logger = require("agentic.utils.logger")

--- Implements the client side of ACP terminal support
--- (https://agentclientprotocol.com/protocol/terminals.md).
---
--- Agents that delegate shell execution to the client (e.g. Kimi Code in ACP
--- mode) issue `terminal/create` and friends as reverse-RPC requests. Each
--- terminal is a background process spawned with `vim.system`; output is
--- accumulated as it streams so `terminal/output` can be answered at any time,
--- and `terminal/wait_for_exit` requests are parked until the process exits.

--- @class agentic.acp.TerminalExitStatus
--- @field exitCode number|vim.NIL
--- @field signal string|vim.NIL

--- @class agentic.acp.TerminalRecord
--- @field session_id? string Owning session, so it can be torn down on cancel
--- @field output_chunks string[] Streamed output, joined lazily in get_output
--- @field output_bytes number Retained byte count, capped to outputByteLimit
--- @field truncated boolean True once the byte limit dropped earlier output
--- @field exit_status? agentic.acp.TerminalExitStatus nil until the process exits
--- @field handle? vim.SystemObj
--- @field waiters fun(status: agentic.acp.TerminalExitStatus)[] wait_for_exit callbacks

--- @class agentic.acp.TerminalManager
--- @field terminals table<string, agentic.acp.TerminalRecord>
--- @field id_counter number
local TerminalManager = {}
TerminalManager.__index = TerminalManager

--- @return agentic.acp.TerminalManager
function TerminalManager:new()
    return setmetatable({
        terminals = {},
        id_counter = 0,
    }, self)
end

--- @param signal number|nil libuv signal number from vim.system on_exit
--- @return string|vim.NIL
local function normalize_signal(signal)
    if type(signal) == "number" and signal ~= 0 then
        return tostring(signal)
    end
    return vim.NIL
end

--- Signal a running process. The record is left intact so its output and exit
--- status stay readable until `terminal/release`.
--- @param terminal agentic.acp.TerminalRecord
local function kill_if_running(terminal)
    if terminal.handle and not terminal.exit_status then
        pcall(function()
            terminal.handle:kill(15)
        end)
    end
end

--- Answer and clear every parked wait_for_exit request. Snapshot-then-clear so
--- a callback that re-enters cannot see a half-drained list.
--- @param terminal agentic.acp.TerminalRecord
--- @param status agentic.acp.TerminalExitStatus
local function resolve_waiters(terminal, status)
    local waiters = terminal.waiters
    terminal.waiters = {}
    for _, waiter in ipairs(waiters) do
        pcall(waiter, status)
    end
end

--- Spawn a background process for a `terminal/create` request.
--- @param params { command?: string, args?: string[], env?: agentic.acp.EnvVariable[], cwd?: string, outputByteLimit?: number, sessionId?: string }
--- @return string|nil terminal_id nil when the command is missing or spawn fails
--- @return string|nil err
function TerminalManager:create(params)
    if type(params) ~= "table" or type(params.command) ~= "string" then
        return nil, "terminal/create requires a 'command' string"
    end

    self.id_counter = self.id_counter + 1
    local id = "term_" .. self.id_counter

    local cmd = { params.command }
    if type(params.args) == "table" then
        for _, arg in ipairs(params.args) do
            cmd[#cmd + 1] = arg
        end
    end

    --- @type table<string, string>|nil
    local env
    if type(params.env) == "table" then
        env = {}
        for _, entry in ipairs(params.env) do
            if type(entry) == "table" and type(entry.name) == "string" then
                env[entry.name] = entry.value
            end
        end
    end

    local limit = params.outputByteLimit

    --- @type agentic.acp.TerminalRecord
    local terminal = {
        session_id = params.sessionId,
        output_chunks = {},
        output_bytes = 0,
        truncated = false,
        waiters = {},
    }

    local function append(data)
        if type(data) ~= "string" or data == "" then
            return
        end

        terminal.output_chunks[#terminal.output_chunks + 1] = data
        terminal.output_bytes = terminal.output_bytes + #data

        -- Only pay the join+trim once the cap is exceeded; the uncapped case
        -- stays O(#data) per chunk instead of copying the whole buffer.
        if limit and terminal.output_bytes > limit then
            local joined = table.concat(terminal.output_chunks)
            joined = string.sub(joined, #joined - limit + 1)
            terminal.output_chunks = { joined }
            terminal.output_bytes = #joined
            terminal.truncated = true
        end
    end

    local ok, handle = pcall(vim.system, cmd, {
        cwd = params.cwd,
        env = env,
        text = true,
        stdout = function(_, data)
            append(data)
        end,
        stderr = function(_, data)
            append(data)
        end,
    }, function(out)
        --- on_exit runs in a libuv fast-event context; defer state changes and
        --- waiter callbacks (which write JSON-RPC results) onto the main loop.
        vim.schedule(function()
            terminal.exit_status = {
                exitCode = type(out.code) == "number" and out.code or vim.NIL,
                signal = normalize_signal(out.signal),
            }
            resolve_waiters(terminal, terminal.exit_status)
        end)
    end)

    if not ok or not handle then
        local err = ok and "failed to spawn process" or tostring(handle)
        Logger.debug(
            "terminal/create failed for '" .. params.command .. "': " .. err
        )
        return nil, err
    end

    terminal.handle = handle
    self.terminals[id] = terminal

    return id, nil
end

--- Answer a `terminal/output` request.
--- @param terminal_id string
--- @return { output: string, truncated: boolean, exitStatus?: agentic.acp.TerminalExitStatus }|nil
function TerminalManager:get_output(terminal_id)
    local terminal = self.terminals[terminal_id]
    if not terminal then
        return nil
    end

    local result = {
        output = table.concat(terminal.output_chunks),
        truncated = terminal.truncated,
    }

    if terminal.exit_status then
        result.exitStatus = terminal.exit_status
    end

    return result
end

--- Answer a `terminal/wait_for_exit` request, either immediately (already
--- exited) or once the process exits.
--- @param terminal_id string
--- @param callback fun(status: agentic.acp.TerminalExitStatus)
--- @return boolean known false when the terminal id is unknown
function TerminalManager:wait_for_exit(terminal_id, callback)
    local terminal = self.terminals[terminal_id]
    if not terminal then
        return false
    end

    if terminal.exit_status then
        callback(terminal.exit_status)
    else
        terminal.waiters[#terminal.waiters + 1] = callback
    end

    return true
end

--- Handle a `terminal/kill` request. The terminal stays alive so its output
--- and exit status remain readable until `terminal/release`.
--- @param terminal_id string
--- @return boolean known false when the terminal id is unknown
function TerminalManager:kill(terminal_id)
    local terminal = self.terminals[terminal_id]
    if not terminal then
        return false
    end

    kill_if_running(terminal)
    return true
end

--- Handle a `terminal/release` request: kill the process if still running,
--- resolve any pending waiters, and drop the terminal record.
--- @param terminal_id string
--- @return boolean known false when the terminal id is unknown
function TerminalManager:release(terminal_id)
    local terminal = self.terminals[terminal_id]
    if not terminal then
        return false
    end

    kill_if_running(terminal)
    self.terminals[terminal_id] = nil

    -- Never strand a parked wait_for_exit request on the shared subprocess.
    resolve_waiters(
        terminal,
        terminal.exit_status or { exitCode = vim.NIL, signal = vim.NIL }
    )

    return true
end

--- Release every terminal spawned for a session. Mirrors how subscribers are
--- dropped on `cancel_session`, so cancelling a prompt does not orphan its
--- running shell commands.
--- @param session_id string
function TerminalManager:release_session(session_id)
    for id, terminal in pairs(self.terminals) do
        if terminal.session_id == session_id then
            self:release(id)
        end
    end
end

--- Kill and drop every terminal. Called when the client disconnects.
function TerminalManager:release_all()
    for id in pairs(self.terminals) do
        self:release(id)
    end
end

return TerminalManager
