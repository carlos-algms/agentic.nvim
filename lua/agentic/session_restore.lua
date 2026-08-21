local Logger = require("agentic.utils.logger")
local Config = require("agentic.config")
local AgentInstance = require("agentic.acp.agent_instance")
local SessionRegistry = require("agentic.session_registry")

--- @class agentic.SessionRestoreContext
--- @field agent agentic.acp.ACPClient
--- @field provider_name agentic.UserConfig.ProviderName
--- @field source? agentic.SessionManager

--- @class agentic.SessionRestore
local SessionRestore = {}

--- @return agentic.SessionRestoreContext|nil context
local function resolve_context()
    local source = SessionRegistry.current()
    if source then
        return {
            agent = source.agent,
            provider_name = source.provider_name,
            source = source,
        }
    end

    local agent = AgentInstance.get_instance(Config.provider)
    if not agent then
        return nil
    end

    return {
        agent = agent,
        provider_name = Config.provider,
    }
end

--- @param operation string
--- @return fun(err: agentic.acp.ACPError) callback
local function notify_readiness_failure(operation)
    return function(err)
        Logger.notify(
            "Failed to "
                .. operation
                .. ": "
                .. (err.message or "provider unavailable"),
            vim.log.levels.WARN
        )
    end
end

--- @param context agentic.SessionRestoreContext
--- @param session_id string
--- @param title string|nil
--- @param timestamp string|integer|nil
local function restore(context, session_id, title, timestamp)
    --- @type agentic.SessionStartSpec
    local start_spec = {
        kind = "load",
        session_id = session_id,
        title = title,
        timestamp = timestamp,
    }

    -- Only a fresh target issues `session/load`; an existing manager can be
    -- shown without the provider advertising load support.
    local existing =
        SessionRegistry.find_by_acp_session_id(session_id, context.agent)
    if not existing then
        local capabilities = context.agent.agent_capabilities
        if not capabilities or not capabilities.loadSession then
            Logger.notify(
                "Agent does not support loading sessions",
                vim.log.levels.WARN
            )
            return
        end
    end

    SessionRegistry.choose_session_lifecycle(
        context.source,
        "Restore session:",
        function(destroy_source)
            --- @type agentic.SessionReplacementOpts
            local opts = { agent = context.agent }
            if context.source and not destroy_source then
                opts.retain_source = true
            end

            SessionRegistry.replace(
                context.source,
                context.provider_name,
                start_spec,
                opts
            )
        end
    )
end

function SessionRestore.show_picker()
    local context = resolve_context()
    if not context then
        return
    end

    local cwd = vim.fn.getcwd()
    context.agent:when_ready(function()
        context.agent:list_sessions(cwd, function(result, err)
            if err or not result then
                Logger.notify(
                    "Failed to list sessions: "
                        .. (err and err.message or "unknown error"),
                    vim.log.levels.WARN
                )
                return
            end

            if #result.sessions == 0 then
                Logger.notify("No saved sessions found", vim.log.levels.INFO)
                return
            end

            local items = {}
            for _, session in ipairs(result.sessions) do
                local date = session.updatedAt
                        and session.updatedAt:sub(1, 16):gsub("T", " ")
                    or "unknown date"
                items[#items + 1] = {
                    display = string.format(
                        "%s - %s",
                        date,
                        session.title or "(no title)"
                    ),
                    session_id = session.sessionId,
                    title = session.title,
                    updated_at = session.updatedAt,
                }
            end

            vim.schedule(function()
                vim.ui.select(items, {
                    prompt = "Select session to restore:",
                    format_item = function(item)
                        return item.display
                    end,
                }, function(choice)
                    if choice then
                        restore(
                            context,
                            choice.session_id,
                            choice.title,
                            choice.updated_at
                        )
                    end
                end)
            end)
        end)
    end, notify_readiness_failure("list sessions"))
end

--- @param session_id string
function SessionRestore.restore_by_id(session_id)
    local context = resolve_context()
    if not context then
        return
    end

    context.agent:when_ready(function()
        restore(context, session_id, nil, nil)
    end, notify_readiness_failure("restore session"))
end

return SessionRestore
