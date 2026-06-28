local Logger = require("agentic.utils.logger")

--- Dispatches a config-option change request to the agent and reacts to the
--- response against the LIVE session: stale responses are dropped, errors are
--- notified, and success is forwarded to the caller. It owns the request
--- lifecycle, NOT the config-option state (that lives in AgentConfigOptions).
--- @class agentic.acp.ConfigChangeDispatcher
local ConfigChangeDispatcher = {}

--- @class agentic.acp.ConfigChangeDispatcher.Request
--- @field get_session_id fun(): string|nil Resolves the live session id at response time
--- @field value string The new value, used only for error messages
--- @field label string Human-readable change name for notifications
--- @field send fun(callback: fun(result: table|nil, err: agentic.acp.ACPError|nil)) Issues the ACP request, binding session id + method
--- @field on_success fun(result: table|nil) Runs on a fresh, error-free response

--- @param request agentic.acp.ConfigChangeDispatcher.Request
function ConfigChangeDispatcher.dispatch(request)
    local request_session_id = request.get_session_id()

    request.send(function(result, err)
        if request.get_session_id() ~= request_session_id then
            Logger.debug("Stale config change response, ignoring")
            return
        end

        if err then
            Logger.notify(
                string.format(
                    "Failed to change %s to '%s': %s",
                    request.label,
                    request.value,
                    err.message
                ),
                vim.log.levels.ERROR
            )
            return
        end

        request.on_success(result)
    end)
end

return ConfigChangeDispatcher
