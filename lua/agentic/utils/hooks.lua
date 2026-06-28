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

--- @alias agentic.utils.Hooks.Data
--- | agentic.UserConfig.CreateSessionResponseData
--- | agentic.UserConfig.PromptSubmitData
--- | agentic.UserConfig.ResponseCompleteData
--- | agentic.UserConfig.SessionUpdateData
--- | agentic.UserConfig.FileEditData
--- | agentic.UserConfig.RequestPermissionData

--- Safely invoke a user-configured hook
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

return Hooks
