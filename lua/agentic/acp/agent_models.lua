--- Manages agent models for ACP sessions
--- Provides model selection via vim.ui.select

local Logger = require("agentic.utils.logger")

--- @class agentic.acp.AgentModels
--- @field _models agentic.acp.Model[]
--- @field current_model_id? string
local AgentModels = {}
AgentModels.__index = AgentModels

--- @return agentic.acp.AgentModels
function AgentModels:new()
    local instance = setmetatable({
        _models = {},
        current_model_id = nil,
    }, self)

    return instance
end

--- Replace all models with new list
--- @param models_info agentic.acp.ModelsInfo
function AgentModels:set_models(models_info)
    self._models = models_info.availableModels
    self.current_model_id = models_info.currentModelId
end

--- @param model_id string
--- @return agentic.acp.Model|nil
function AgentModels:get_model(model_id)
    for _, model in ipairs(self._models) do
        if model.modelId == model_id then
            return model
        end
    end
    return nil
end

--- @param set_model_callback fun(model_id: string)
--- @return boolean shown
function AgentModels:show_model_selector(set_model_callback)
    if #self._models == 0 then
        return false
    end

    vim.ui.select(self._models, {
        prompt = "Select Model:",
        format_item = function(item)
            --- @cast item agentic.acp.Model
            local prefix = item.modelId == self.current_model_id and "● "
                or "  "
            if item.description and item.description ~= "" then
                return string.format(
                    "%s%s: %s",
                    prefix,
                    item.name,
                    item.description
                )
            end
            return prefix .. item.name
        end,
    }, function(selected_model)
        if
            selected_model
            and selected_model.modelId ~= self.current_model_id
        then
            set_model_callback(selected_model.modelId)
        end
    end)

    return true
end

--- @param model_id string|nil
--- @return boolean success
function AgentModels:handle_agent_update_model(model_id)
    if #self._models == 0 then
        return false
    end

    if not model_id or not self:get_model(model_id) then
        Logger.notify(
            string.format(
                "Agent sent invalid model '%s', keeping current model '%s'",
                model_id,
                self.current_model_id or "unknown"
            ),
            vim.log.levels.WARN,
            { title = "Agentic: Invalid model" }
        )
        return false
    end

    self.current_model_id = model_id

    Logger.notify(
        "Model changed to: " .. model_id,
        vim.log.levels.INFO,
        { title = "Agentic Model changed" }
    )

    return true
end

--- Reset all models and current selection
function AgentModels:clear()
    self._models = {}
    self.current_model_id = nil
end

return AgentModels
