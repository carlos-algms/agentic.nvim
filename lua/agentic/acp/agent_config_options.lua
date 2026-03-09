local Logger = require("agentic.utils.logger")

--- @class agentic.acp.AgentConfigOptions
--- @field mode? agentic.acp.ConfigOption
--- @field model? agentic.acp.ConfigOption
--- @field thought_level? agentic.acp.ConfigOption
local AgentConfigOptions = {}
AgentConfigOptions.__index = AgentConfigOptions

--- @return agentic.acp.AgentConfigOptions
function AgentConfigOptions:new()
    self = setmetatable({
        mode = nil,
        model = nil,
        thought_level = nil,
    }, self)

    return self
end

--- @param configOptions agentic.acp.ConfigOption[]|nil
function AgentConfigOptions:set_options(configOptions)
    if not configOptions then
        return
    end

    for _i, option in ipairs(configOptions) do
        if option.category == "mode" then
            self.mode = option
        elseif option.category == "model" then
            self.model = option
        elseif option.category == "thought_level" then
            self.thought_level = option
        else
            Logger.debug("Unknown config option", option)
        end
    end
end

--- @param default_mode string|nil
--- @param handle_mode_change fun(mode: string): any
function AgentConfigOptions:set_initial_mode(default_mode, handle_mode_change)
    if not default_mode or default_mode == "" then
        return
    end

    local can_use_default = default_mode ~= self.mode.currentValue
        and self:get_mode(default_mode)

    if can_use_default then
        handle_mode_change(default_mode)
    else
        Logger.notify(
            string.format(
                "Configured default_mode '%s' not available. Using provider default '%s'",
                default_mode,
                self.mode.currentValue
            ),
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end
end

--- @param target agentic.acp.ConfigOption|nil
--- @param value string
--- @return agentic.acp.ConfigOption.Option|nil
local function getter(target, value)
    if not target or not target.options or #target.options == 0 then
        return nil
    end

    for _, option in ipairs(target.options) do
        if option.value == value then
            return option
        end
    end

    return nil
end

--- @param mode_value string
--- @return agentic.acp.ConfigOption.Option|nil
function AgentConfigOptions:get_mode(mode_value)
    return getter(self.mode, mode_value)
end

--- @param model_value string
--- @return agentic.acp.ConfigOption.Option|nil
function AgentConfigOptions:get_model(model_value)
    return getter(self.model, model_value)
end

--- @param handle_mode_change fun(mode: string, is_config_option: boolean): any
--- @return boolean shown
function AgentConfigOptions:show_mode_selector(handle_mode_change)
    return self:_show_selector(
        self.mode,
        "Select agent mode config:",
        handle_mode_change
    )
end

--- @param target agentic.acp.ConfigOption|nil
--- @param prompt string
--- @param handle_change fun(mode: string, is_config_option: boolean): any
--- @return boolean shown
function AgentConfigOptions:_show_selector(target, prompt, handle_change)
    if not target or not target.options or #target.options == 0 then
        return false
    end

    vim.ui.select(target.options, {
        prompt = prompt,
        format_item = function(item)
            --- @cast item agentic.acp.ConfigOption.Option -- need to cast because `select` has a Generic, but not for `format_item`
            local prefix = item.value == target.currentValue and "● " or "  "

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
    }, function(selected_mode)
        if selected_mode and selected_mode.value ~= target.currentValue then
            handle_change(selected_mode.value, true)
        end
    end)

    return true
end

return AgentConfigOptions
