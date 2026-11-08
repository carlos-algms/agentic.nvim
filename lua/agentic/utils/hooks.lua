local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.utils.Hooks
local Hooks = {}

--- @alias agentic.utils.Hooks.Name
--- | "on_create_session_response"
--- | "on_prompt_submit"
--- | "on_response_complete"
--- | "on_session_update"
--- | "on_file_edit"
--- | "on_request_permission"

--- Hooks whose value the caller uses. They run synchronously, not via `invoke`.
--- @alias agentic.utils.Hooks.SyncName
--- | "before_first_prompt"

--- @alias agentic.utils.Hooks.Data
--- | agentic.UserConfig.CreateSessionResponseData
--- | agentic.UserConfig.PromptSubmitData
--- | agentic.UserConfig.ResponseCompleteData
--- | agentic.UserConfig.SessionUpdateData
--- | agentic.UserConfig.FileEditData
--- | agentic.UserConfig.RequestPermissionData

--- @alias agentic.utils.Hooks.SyncData agentic.UserConfig.BeforeFirstPromptData

--- Safely invoke a notification hook. The return value is ignored; a hook that
--- supplies a value needs `invoke_sync`.
--- @param hook_name agentic.utils.Hooks.Name
--- @param data agentic.utils.Hooks.Data
function Hooks.invoke(hook_name, data)
    local hook = Config.hooks and Config.hooks[hook_name]

    if hook and type(hook) == "function" then
        vim.schedule(function()
            local ok, err = pcall(hook, data)
            if not ok then
                Logger.notify(
                    string.format("Hook '%s' error: %s", hook_name, err),
                    vim.log.levels.ERROR
                )
            end
        end)
    end
end

--- Invoke a hook that supplies a value. The caller waits for it, so a slow hook
--- delays the prompt; errors and wrong return types are reported, never raised.
--- @param hook_name agentic.utils.Hooks.SyncName
--- @param data agentic.utils.Hooks.SyncData
--- @return string|nil result
function Hooks.invoke_sync(hook_name, data)
    local hook = Config.hooks and Config.hooks[hook_name]

    if not hook or type(hook) ~= "function" then
        return nil
    end

    local ok, result = pcall(hook, data)
    if not ok then
        Logger.notify(
            string.format("Hook '%s' error: %s", hook_name, result),
            vim.log.levels.ERROR
        )
        return nil
    end

    if type(result) ~= "string" then
        if result ~= nil then
            Logger.notify(
                string.format(
                    "Hook '%s' must return a string or nil, got %s",
                    hook_name,
                    type(result)
                ),
                vim.log.levels.WARN
            )
        end
        return nil
    end

    return result
end

return Hooks
