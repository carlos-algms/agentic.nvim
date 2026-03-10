--- Manages agent modes for ACP sessions
--- Provides mode selection via vim.ui.select

local Logger = require("agentic.utils.logger")

--- @class agentic.acp.AgentModes
--- @field _modes agentic.acp.AgentMode[]
--- @field current_mode_id? string
local AgentModes = {}
AgentModes.__index = AgentModes

--- @return agentic.acp.AgentModes
function AgentModes:new()
    local instance = setmetatable({
        _modes = {},
        current_mode_id = nil,
    }, self)

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

--- @param set_mode_callback fun(mode_id: string)
--- @return boolean shown
function AgentModes:show_mode_selector(set_mode_callback)
    if #self._modes == 0 then
        return false
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
            set_mode_callback(selected_mode.id)
        end
    end)

    return true
end

--- @param mode_id string|nil
--- @return boolean success true if mode was updated, false if invalid mode_id
function AgentModes:handle_agent_update_mode(mode_id)
    if #self._modes == 0 then
        -- Providers that support both, legacy modes and configOptions modes will send an update
        -- ignoring it to avoid double handling the event
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

--- Reset all modes and current selection
function AgentModes:clear()
    self._modes = {}
    self.current_mode_id = nil
end

return AgentModes
