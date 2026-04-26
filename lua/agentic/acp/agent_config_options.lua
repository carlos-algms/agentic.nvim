local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local List = require("agentic.utils.list")

--- Map non-spec category names to their canonical spec category.
--- `effort` is sent by Claude ACP (PR #464, merged 2026-04-20) instead of
--- the spec's `thought_level`. We normalize so a single code path handles
--- both providers (Codex sends `thought_level`, Claude sends `effort`).
local CATEGORY_ALIASES = {
    effort = "thought_level",
}

--- @class agentic.acp.AgentConfigOptions
--- @field mode? agentic.acp.ConfigOption
--- @field model? agentic.acp.ConfigOption
--- @field thought_level? agentic.acp.ConfigOption
--- @field legacy_agent_modes agentic.acp.AgentModes
--- @field legacy_agent_models agentic.acp.AgentModels
local AgentConfigOptions = {}
AgentConfigOptions.__index = AgentConfigOptions

--- @class agentic.acp.AgentConfigOptions.Callbacks
--- @field set_mode fun(mode_id: string, is_legacy: boolean)
--- @field set_model fun(model_id: string, is_legacy: boolean)
--- @field set_thought_level fun(value: string)

--- @param buffers agentic.ui.ChatWidget.BufNrs Same buffers as ChatWidget instance
--- @param callbacks agentic.acp.AgentConfigOptions.Callbacks
--- @return agentic.acp.AgentConfigOptions
function AgentConfigOptions:new(buffers, callbacks)
    local AgentModes = require("agentic.acp.agent_modes")
    local AgentModels = require("agentic.acp.agent_models")

    self = setmetatable({
        mode = nil,
        model = nil,
        thought_level = nil,
        legacy_agent_modes = AgentModes:new(),
        legacy_agent_models = AgentModels:new(),
    }, self)

    for _, bufnr in pairs(buffers) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.change_mode,
            bufnr,
            function()
                self:show_mode_selector(callbacks.set_mode)
            end,
            { desc = "Agentic: Select Agent Mode" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_model,
            bufnr,
            function()
                self:show_model_selector(callbacks.set_model)
            end,
            { desc = "Agentic: Select Model" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.change_thought_level,
            bufnr,
            function()
                self:show_thought_level_selector(callbacks.set_thought_level)
            end,
            { desc = "Agentic: Select Thought Effort Level" }
        )
    end

    return self
end

function AgentConfigOptions:clear()
    self.mode = nil
    self.model = nil
    self.thought_level = nil
    self.legacy_agent_modes:clear()
    self.legacy_agent_models:clear()
end

--- @param configOptions agentic.acp.ConfigOption[]|nil
function AgentConfigOptions:set_options(configOptions)
    self:clear()

    if not configOptions then
        return
    end

    for _, option in ipairs(configOptions) do
        -- Guard against malformed input (nil/non-string category): treat as
        -- empty string so the dispatch falls through to the unknown branch
        -- without crashing on `nil:sub(1, 1)`.
        local raw = type(option.category) == "string" and option.category or ""
        local cat = CATEGORY_ALIASES[raw] or raw

        if cat == "mode" then
            self.mode = option
        elseif cat == "model" then
            self.model = option
        elseif cat == "thought_level" then
            self.thought_level = option
        elseif cat:sub(1, 1) ~= "_" then
            Logger.debug("Unknown config option", option)
        end
    end
end

--- Modes from providers that don't support the new Config Options
--- @param modes_info agentic.acp.ModesInfo
function AgentConfigOptions:set_legacy_modes(modes_info)
    self.legacy_agent_modes:set_modes(modes_info)
end

--- Models from providers that don't support the new Config Options
--- @param models_info agentic.acp.ModelsInfo
function AgentConfigOptions:set_legacy_models(models_info)
    self.legacy_agent_models:set_models(models_info)
end

--- @param target_mode string|nil
--- @param handle_mode_change fun(mode: string, is_legacy: boolean|nil): any
function AgentConfigOptions:set_initial_mode(target_mode, handle_mode_change)
    if not target_mode or target_mode == "" then
        Logger.debug("not setting initial mode", target_mode)
        return
    end

    local is_legacy = false
    local found = false

    if self:get_mode(target_mode) ~= nil then
        found = true
        Logger.debug("Going to set initial config mode", target_mode)
    elseif self.legacy_agent_modes:get_mode(target_mode) ~= nil then
        found = true
        is_legacy = true
        Logger.debug("Going to set initial legacy mode", target_mode)
    end

    if not found then
        local current = self.mode and self.mode.currentValue
            or self.legacy_agent_modes.current_mode_id
            or "unknown"
        Logger.notify(
            string.format(
                "Configured default_mode ‘%s’ not available."
                    .. " Using provider’s default ‘%s’",
                target_mode,
                current
            ),
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
        return
    end

    local current_value = is_legacy and self.legacy_agent_modes.current_mode_id
        or self.mode.currentValue

    if target_mode == current_value then
        Logger.debug("initial mode already matches current", target_mode)
        return
    end

    handle_mode_change(target_mode, is_legacy)
end

--- @param target_model string|nil
--- @param handle_model_change fun(model: string, is_legacy: boolean|nil): any
--- @return boolean handler_fired Whether `handle_model_change` was invoked
function AgentConfigOptions:set_initial_model(target_model, handle_model_change)
    if not target_model or target_model == "" then
        Logger.debug("not setting initial model", target_model)
        return false
    end

    local is_legacy = false
    local found = false

    if self:get_model(target_model) ~= nil then
        found = true
        Logger.debug("Setting initial config model", target_model)
    elseif self.legacy_agent_models:get_model(target_model) ~= nil then
        found = true
        is_legacy = true
        Logger.debug("Setting initial legacy model", target_model)
    end

    if not found then
        local current = self.model and self.model.currentValue
            or self.legacy_agent_models.current_model_id
            or "unknown"
        Logger.notify(
            string.format(
                "Configured initial_model '%s' not available."
                    .. " Using provider's default '%s'",
                target_model,
                current
            ),
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
        return false
    end

    local current_value = is_legacy
            and self.legacy_agent_models.current_model_id
        or self.model.currentValue

    if target_model == current_value then
        Logger.debug("initial model already matches current", target_model)
        return false
    end

    handle_model_change(target_model, is_legacy)
    return true
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

--- @param mode_value string
--- @return string|nil mode_name
function AgentConfigOptions:get_mode_name(mode_value)
    local mode = self:get_mode(mode_value)

    if mode then
        return mode.name
    end

    local legacy_mode = self.legacy_agent_modes:get_mode(mode_value)

    if legacy_mode then
        return legacy_mode.name
    end

    return nil
end

--- @param model_value string
--- @return agentic.acp.ConfigOption.Option|nil
function AgentConfigOptions:get_model(model_value)
    return getter(self.model, model_value)
end

--- @param value string
--- @return agentic.acp.ConfigOption.Option|nil
function AgentConfigOptions:get_thought_level(value)
    return getter(self.thought_level, value)
end

--- @param handle_mode_change fun(mode: string, is_legacy: boolean): any
--- @return boolean shown
function AgentConfigOptions:show_mode_selector(handle_mode_change)
    local shown = self:_show_selector(
        self.mode,
        "Select agent mode config:",
        handle_mode_change
    )

    if shown then
        return true
    end

    local legacy_shown = self.legacy_agent_modes:show_mode_selector(
        function(mode)
            handle_mode_change(mode, true)
        end
    )

    if not legacy_shown then
        Logger.notify(
            "This provider does not support mode switching",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end

    return legacy_shown
end

--- @param handle_change fun(value: string): any
--- @return boolean shown
function AgentConfigOptions:show_thought_level_selector(handle_change)
    local shown = self:_show_selector(
        self.thought_level,
        "Select thought effort level:",
        handle_change
    )

    if shown then
        return true
    end

    Logger.notify(
        "This provider does not support thought effort level switching",
        vim.log.levels.WARN,
        { title = "Agentic" }
    )

    return false
end

--- @param handle_model_change fun(model_id: string, is_legacy: boolean): any
--- @return boolean shown
function AgentConfigOptions:show_model_selector(handle_model_change)
    local shown = self:_show_selector(
        self.model,
        "Select model to change:",
        handle_model_change
    )

    if shown then
        return true
    end

    local legacy_shown = self.legacy_agent_models:show_model_selector(
        function(model_id)
            handle_model_change(model_id, true)
        end
    )

    if not legacy_shown then
        Logger.notify(
            "This provider does not support model switching",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end

    return legacy_shown
end

--- @param target_value string|nil
--- @param handle_change fun(value: string): any
function AgentConfigOptions:set_initial_thought_level(
    target_value,
    handle_change
)
    if not target_value or target_value == "" then
        Logger.debug("not setting initial thought level", target_value)
        return
    end

    if not self.thought_level then
        Logger.debug(
            "Provider does not support thought effort level;"
                .. " ignoring default_thought_level",
            target_value
        )
        return
    end

    if self:get_thought_level(target_value) == nil then
        Logger.notify(
            string.format(
                "Configured default_thought_level '%s' not available."
                    .. " Using provider's default '%s'",
                target_value,
                self.thought_level.currentValue or "unknown"
            ),
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
        return
    end

    local current_value = self.thought_level and self.thought_level.currentValue

    if target_value == current_value then
        Logger.debug(
            "initial thought level already matches current",
            target_value
        )
        return
    end

    handle_change(target_value)
end

--- @param target agentic.acp.ConfigOption|nil
--- @param prompt string
--- @param handle_change fun(mode: string, is_legacy: boolean): any
--- @return boolean shown
function AgentConfigOptions:_show_selector(target, prompt, handle_change)
    if not target or not target.options or #target.options == 0 then
        return false
    end

    local ordered_options =
        List.move_to_head(target.options, "value", target.currentValue)

    vim.ui.select(ordered_options, {
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
            handle_change(selected_mode.value, false)
        end
    end)

    return true
end

return AgentConfigOptions
