local Logger = require("agentic.utils.logger")

--- @class agentic.acp.AgentConfigOptions
--- @field mode agentic.acp.ConfigOption
--- @field model agentic.acp.ConfigOption
--- @field thought_level agentic.acp.ConfigOption
local AgentConfigOptions = {}
AgentConfigOptions.__index = AgentConfigOptions

function AgentConfigOptions:new()
    self = setmetatable({
        mode = nil,
        model = nil,
        thought_level = nil,
    }, self)

    return self
end

--- @param configOptions? agentic.acp.ConfigOption[]
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

--- @param mode_value string
--- @return agentic.acp.ConfigOption.Option|nil
function AgentConfigOptions:get_mode(mode_value)
    for _, mode in ipairs(self.mode.options) do
        if mode.value == mode_value then
            return mode
        end
    end

    return nil
end

function AgentConfigOptions:show_mode_selector()
    if not self.mode or #self.mode.options == 0 then
        return
    end

    vim.ui.select(self.mode.options, {
        prompt = "Select Agent Mode:",
        format_item = function(item)
            --- @cast item agentic.acp.ConfigOption.Option -- need to cast because `select` has a Generic, but not for `format_item`
            local prefix = item.value == self.mode.currentValue and "● "
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
    }, function(selected_mode)
        if selected_mode and selected_mode.value ~= self.mode.currentValue then
            self._set_mode_callback(selected_mode.value)
        end
    end)
end

return AgentConfigOptions
