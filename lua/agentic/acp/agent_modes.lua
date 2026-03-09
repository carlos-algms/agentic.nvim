--- Manages agent modes for ACP sessions
--- Provides mode selection via vim.ui.select

local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.acp.AgentModes
--- @field _modes agentic.acp.AgentMode[]
--- @field _set_mode_callback fun(mode_id: string, is_config_option: boolean) called when the user selects a new mode from the selector
--- @field current_mode_id? string
--- @field agent_config_options? agentic.acp.AgentConfigOptions
local AgentModes = {}
AgentModes.__index = AgentModes

--- @return agentic.acp.AgentModes
--- @param buffers agentic.ui.ChatWidget.BufNrs Same buffers as ChatWidget instance
--- @param set_mode_callback fun(mode_id: string, is_config_option: boolean) Callback to change mode via SessionManager
--- @param agent_config_options agentic.acp.AgentConfigOptions|nil
function AgentModes:new(buffers, set_mode_callback, agent_config_options)
    local instance = setmetatable({
        _modes = {},
        _set_mode_callback = set_mode_callback,
        current_mode_id = nil,
        agent_config_options = agent_config_options,
    }, self)

    for _, bufnr in pairs(buffers) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.change_mode,
            bufnr,
            function()
                instance:show_mode_selector()
            end,
            { desc = "Agentic: Select Agent Mode" }
        )
    end

    return instance
end

--- Replace all modes with new list
--- @param modes_info agentic.acp.ModesInfo
function AgentModes:set_modes(modes_info)
    self._modes = modes_info.availableModes
    self.current_mode_id = modes_info.currentModeId
end

--- @param mode_id string
--- @return agentic.acp.AgentMode|nil
function AgentModes:get_mode(mode_id)
    for _, mode in ipairs(self._modes) do
        if mode.id == mode_id then
            return mode
        end
    end
    return nil
end

function AgentModes:show_mode_selector()
    if
        self.agent_config_options
        and self.agent_config_options:show_mode_selector(
            self._set_mode_callback
        )
    then
        return
    end

    if #self._modes == 0 then
        return
    end

    vim.ui.select(self._modes, {
        prompt = "Select Agent Mode:",
        format_item = function(item)
            --- @cast item agentic.acp.AgentMode -- need to cast because `select` has a Generic, but not for `format_item`
            local prefix = item.id == self.current_mode_id and "● " or "  "
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
        if selected_mode and selected_mode.id ~= self.current_mode_id then
            self._set_mode_callback(selected_mode.id, false)
        end
    end)
end

--- @param mode_id string|nil
--- @return boolean success true if mode was updated, false if invalid mode_id
function AgentModes:handle_agent_update_mode(mode_id)
    if #self._modes == 0 then
        -- Providers that support both, legacy modes and configOptions modes will send an update
        -- ignoring it to avoid double calling header renders
        return false
    end

    if not mode_id or not self:get_mode(mode_id) then
        Logger.notify(
            string.format(
                "Agent sent invalid mode '%s', keeping current mode '%s'",
                mode_id,
                self.current_mode_id or "unknown"
            ),
            vim.log.levels.WARN,
            { title = "Agentic: Invalid mode" }
        )
        return false
    end

    self.current_mode_id = mode_id

    Logger.notify(
        "Mode changed to: " .. mode_id,
        vim.log.levels.INFO,
        { title = "Agentic Mode changed" }
    )

    return true
end

function AgentModes:clear()
    self.agent_config_options = nil
    self.modes = {}
end

return AgentModes
