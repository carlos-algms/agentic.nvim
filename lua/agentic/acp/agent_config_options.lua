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

--- @class agentic.acp.AgentConfigOptions.Callbacks
--- @field on_set_mode_success fun(mode_id: string)
--- @field on_config_options_applied fun()
--- @field get_agent_instance fun(): agentic.acp.ACPClient|nil
--- @field get_session_id fun(): string|nil

--- @class agentic.acp.AgentConfigOptions
--- @field options agentic.acp.AnyConfigOption[]
--- @field mode? agentic.acp.ConfigOption
--- @field model? agentic.acp.ConfigOption
--- @field thought_level? agentic.acp.ConfigOption
--- @field legacy_agent_modes agentic.acp.AgentModes
--- @field legacy_agent_models agentic.acp.AgentModels
--- @field callbacks agentic.acp.AgentConfigOptions.Callbacks
local AgentConfigOptions = {}
AgentConfigOptions.__index = AgentConfigOptions

--- @param buffers agentic.ui.ChatWidget.BufNrs Same buffers as ChatWidget instance
--- @param callbacks agentic.acp.AgentConfigOptions.Callbacks
--- @return agentic.acp.AgentConfigOptions
function AgentConfigOptions:new(buffers, callbacks)
    local AgentModes = require("agentic.acp.agent_modes")
    local AgentModels = require("agentic.acp.agent_models")

    self = setmetatable({
        options = {},
        mode = nil,
        model = nil,
        thought_level = nil,
        legacy_agent_modes = AgentModes:new(),
        legacy_agent_models = AgentModels:new(),
        callbacks = callbacks,
    }, self)

    for _, bufnr in pairs(buffers) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.change_mode,
            bufnr,
            function()
                self:_show_mode_selector()
            end,
            { desc = "Agentic: Select Agent Mode" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_model,
            bufnr,
            function()
                self:_show_model_selector()
            end,
            { desc = "Agentic: Select Model" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.change_thought_level,
            bufnr,
            function()
                self:_show_thought_level_selector()
            end,
            { desc = "Agentic: Select Thought Effort Level" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.open_options,
            bufnr,
            function()
                self:_show_options_modal()
            end,
            { desc = "Agentic: Open Options" }
        )
    end

    return self
end

function AgentConfigOptions:clear()
    self.options = {}
    self.mode = nil
    self.model = nil
    self.thought_level = nil
    self.legacy_agent_modes:clear()
    self.legacy_agent_models:clear()
end

--- @class agentic.acp.AgentConfigOptions.Snapshot
--- @field options agentic.acp.AnyConfigOption[]
--- @field mode? agentic.acp.ConfigOption
--- @field model? agentic.acp.ConfigOption
--- @field thought_level? agentic.acp.ConfigOption
--- @field legacy_modes { modes: agentic.acp.AgentMode[], current_mode_id: string|nil }
--- @field legacy_models { models: agentic.acp.Model[], current_model_id: string|nil }

--- Capture mode/model/thought_level and legacy modes/models so they survive a
--- destructive `clear()`. These belong to the agent instance, not the session,
--- and session load/restore does not re-send them.
--- @return agentic.acp.AgentConfigOptions.Snapshot snapshot
function AgentConfigOptions:snapshot()
    --- @type agentic.acp.AgentConfigOptions.Snapshot
    local snapshot = {
        options = self.options,
        mode = self.mode,
        model = self.model,
        thought_level = self.thought_level,
        legacy_modes = self.legacy_agent_modes:save(),
        legacy_models = self.legacy_agent_models:save(),
    }
    return snapshot
end

--- @param snapshot agentic.acp.AgentConfigOptions.Snapshot
function AgentConfigOptions:restore_snapshot(snapshot)
    self.options = snapshot.options
    self.mode = snapshot.mode
    self.model = snapshot.model
    self.thought_level = snapshot.thought_level
    self.legacy_agent_modes:restore(snapshot.legacy_modes)
    self.legacy_agent_models:restore(snapshot.legacy_models)
end

--- @param configOptions agentic.acp.AnyConfigOption[]|nil
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

        if cat:sub(1, 1) ~= "_" then
            local stored_option = vim.deepcopy(option)
            self.options[#self.options + 1] = stored_option

            if option.type ~= "boolean" and cat == "mode" then
                self.mode = stored_option
            elseif option.type ~= "boolean" and cat == "model" then
                self.model = stored_option
            elseif option.type ~= "boolean" and cat == "thought_level" then
                self.thought_level = stored_option
            elseif cat ~= "" and cat ~= "model_config" and cat ~= "other" then
                Logger.debug("Unknown config option", option)
            end
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
function AgentConfigOptions:set_initial_mode(target_mode)
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
        local current = self:get_mode_id() or "unknown"
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

    self:handle_mode_change(target_mode, is_legacy)
end

--- @param target_model string|nil
--- @param on_done fun()|nil
--- @return boolean handler_fired Whether a model change was triggered
function AgentConfigOptions:set_initial_model(target_model, on_done)
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
        local current = self:get_model_id() or "unknown"
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

    self:handle_model_change(target_model, is_legacy, on_done)
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

--- Current mode id, config option first, legacy state as fallback.
--- @return string|nil mode_id
function AgentConfigOptions:get_mode_id()
    return self.mode and self.mode.currentValue
        or self.legacy_agent_modes.current_mode_id
end

--- Current model id, config option first, legacy state as fallback.
--- @return string|nil model_id
function AgentConfigOptions:get_model_id()
    return self.model and self.model.currentValue
        or self.legacy_agent_models.current_model_id
end

function AgentConfigOptions:_show_options_modal()
    local session_id = self.callbacks.get_session_id()

    if #self.options == 0 or not session_id then
        Logger.notify(
            "No config options are available",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
        return
    end

    local ConfigOptionsModal = require("agentic.ui.config_options_modal")
    ConfigOptionsModal:new({
        get_options = function()
            return self.options
        end,
        is_session_active = function()
            return self.callbacks.get_session_id() == session_id
        end,
        handle_change = function(config_id, value, on_done)
            self:handle_change(config_id, value, on_done)
        end,
        show_selector = function(option, prompt, handle_change)
            return self:_show_selector(option, prompt, handle_change)
        end,
    }):open()
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

--- @return boolean shown
function AgentConfigOptions:_show_mode_selector()
    local shown = self:_show_selector(
        self.mode,
        "Select agent mode config:",
        function(mode)
            self:handle_mode_change(mode, false)
        end
    )

    if shown then
        return true
    end

    local legacy_shown = self.legacy_agent_modes:show_mode_selector(
        function(mode)
            self:handle_mode_change(mode, true)
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

--- @return boolean shown
function AgentConfigOptions:_show_thought_level_selector()
    local shown = self:_show_selector(
        self.thought_level,
        "Select thought effort level:",
        function(value)
            self:handle_thought_level_change(value)
        end
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

--- @return boolean shown
function AgentConfigOptions:_show_model_selector()
    local shown = self:_show_selector(
        self.model,
        "Select model to change:",
        function(model)
            self:handle_model_change(model, false)
        end
    )

    if shown then
        return true
    end

    local legacy_shown = self.legacy_agent_models:show_model_selector(
        function(model_id)
            self:handle_model_change(model_id, true)
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
function AgentConfigOptions:set_initial_thought_level(target_value)
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

    self:handle_thought_level_change(target_value)
end

--- @param target agentic.acp.ConfigOption|nil
--- @param prompt string
--- @param handle_change fun(value: string): any
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
            handle_change(selected_mode.value)
        end
    end)

    return true
end

--- @param session_id string
--- @param label string
--- @param value string
--- @param on_success fun(result: table|nil)
--- @return fun(result: table|nil, err: agentic.acp.ACPError|nil)
function AgentConfigOptions:_make_change_response(
    session_id,
    label,
    value,
    on_success
)
    return function(result, err)
        if self.callbacks.get_session_id() ~= session_id then
            Logger.debug("Stale config change response, ignoring")
            return
        end

        if err then
            Logger.notify(
                string.format(
                    "Failed to change %s to '%s': %s",
                    label,
                    value,
                    err.message
                ),
                vim.log.levels.ERROR
            )
            return
        end

        on_success(result)
    end
end

--- @param config_id string
--- @param value string|boolean
--- @param on_done fun()|nil
function AgentConfigOptions:handle_change(config_id, value, on_done)
    --- @type agentic.acp.AnyConfigOption|nil
    local target
    for _, option in ipairs(self.options) do
        if option.id == config_id then
            target = option
            break
        end
    end

    if not target then
        Logger.debug("Unknown config option", config_id)
        return
    end

    local session_id = self.callbacks.get_session_id()

    if not session_id then
        return
    end

    local agent = self.callbacks.get_agent_instance()

    if not agent then
        return
    end

    local response = self:_make_change_response(
        session_id,
        target.name,
        tostring(value),
        function(result)
            if target.type == "boolean" and type(value) == "boolean" then
                target.currentValue = value
            elseif target.type ~= "boolean" and type(value) == "string" then
                target.currentValue = value

                if target.category == "mode" then
                    self.legacy_agent_modes.current_mode_id = value
                    self.callbacks.on_set_mode_success(value)
                elseif target.category == "model" then
                    self.legacy_agent_models.current_model_id = value
                end
            end

            if result and type(result.configOptions) == "table" then
                self:set_options(result.configOptions)
            end

            self.callbacks.on_config_options_applied()
            Logger.notify(
                target.name .. " changed to: " .. tostring(value),
                vim.log.levels.INFO,
                { title = "Agentic Setting changed" }
            )

            if on_done then
                on_done()
            end
        end
    )

    if target.type == "boolean" and type(value) == "boolean" then
        agent:set_config_option({
            sessionId = session_id,
            configId = config_id,
            type = "boolean",
            value = value,
        }, response)
    elseif target.type ~= "boolean" and type(value) == "string" then
        agent:set_config_option({
            sessionId = session_id,
            configId = config_id,
            value = value,
        }, response)
    end
end

--- @param mode_id string
--- @param is_legacy boolean
function AgentConfigOptions:handle_mode_change(mode_id, is_legacy)
    if not is_legacy then
        self:handle_change(self.mode.id, mode_id)
        return
    end

    local session_id = self.callbacks.get_session_id()

    if not session_id then
        return
    end

    local agent = self.callbacks.get_agent_instance()

    if not agent then
        return
    end

    local response = self:_make_change_response(
        session_id,
        "mode",
        mode_id,
        function(result)
            -- keep legacy state in sync so legacy selectors reflect the change
            self.legacy_agent_modes.current_mode_id = mode_id

            if result and type(result.configOptions) == "table" then
                Logger.debug("received result after setting mode")
                self:set_options(result.configOptions)
            end

            local mode_name = self:get_mode_name(mode_id)
            Logger.notify(
                "Mode changed to: " .. mode_name,
                vim.log.levels.INFO,
                { title = "Agentic Mode changed" }
            )

            self.callbacks.on_set_mode_success(mode_id)
        end
    )

    agent:set_mode(session_id, mode_id, response)
end

--- @param model_id string
--- @param is_legacy boolean
--- @param on_done fun()|nil
function AgentConfigOptions:handle_model_change(model_id, is_legacy, on_done)
    if not is_legacy then
        self:handle_change(self.model.id, model_id, on_done)
        return
    end

    local session_id = self.callbacks.get_session_id()

    if not session_id then
        return
    end

    local agent = self.callbacks.get_agent_instance()

    if not agent then
        return
    end

    local response = self:_make_change_response(
        session_id,
        "model",
        model_id,
        function(result)
            -- keep legacy state in sync so legacy selectors reflect the change
            self.legacy_agent_models.current_model_id = model_id

            if result and type(result.configOptions) == "table" then
                Logger.debug("received result after setting model")
                self:set_options(result.configOptions)
            end
            self.callbacks.on_config_options_applied()

            Logger.notify(
                "Model changed to: " .. model_id,
                vim.log.levels.INFO,
                { title = "Agentic Model changed" }
            )

            if on_done then
                on_done()
            end
        end
    )

    agent:set_model(session_id, model_id, response)
end

--- @param value string
function AgentConfigOptions:handle_thought_level_change(value)
    if not self.thought_level then
        Logger.debug("no thought_level option available")
        return
    end

    self:handle_change(self.thought_level.id, value)
end

return AgentConfigOptions
