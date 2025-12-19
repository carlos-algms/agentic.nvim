--- Manages agent modes for ACP sessions
--- Provides mode selection via vim.ui.select

local BufHelpers = require("agentic.utils.buf_helpers")

--- @class agentic.acp.AgentModes
--- @field _modes agentic.acp.AgentMode[]
--- @field _set_mode_callback fun(mode_id: string) called when the user selects a new mode from the selector
--- @field current_mode_id? string
local AgentModes = {}
AgentModes.__index = AgentModes

--- @return agentic.acp.AgentModes
--- @param buffers agentic.ui.ChatWidget.BufNrs Same buffers as ChatWidget instance
--- @param set_mode_callback fun(mode_id: string) Callback to change mode via SessionManager
function AgentModes:new(buffers, set_mode_callback)
    local instance = setmetatable({
        _modes = {},
        _set_mode_callback = set_mode_callback,
        current_mode_id = nil,
    }, self)

    for _, bufnr in pairs(buffers) do
        BufHelpers.keymap_set(bufnr, { "n", "v", "i" }, "<S-Tab>", function()
            instance:show_mode_selector()
        end, { desc = "Agentic: Select Agent Mode" })
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
function AgentModes:get_mode(mode_id)
    for _, mode in ipairs(self._modes) do
        if mode.id == mode_id then
            return mode
        end
    end
    return nil
end

function AgentModes:show_mode_selector()
    if #self._modes == 0 then
        return
    end

    vim.ui.select(self._modes, {
        prompt = "Select Agent Mode:",
        format_item = function(item)
            --- @cast item agentic.acp.AgentMode -- need to cast because `select` has a Generic, but not for `format_item`
            local prefix = item.id == self.current_mode_id and "● " or "  "
            return string.format(
                "%s%s: %s",
                prefix,
                item.name,
                item.description
            )
        end,
    }, function(selected_mode)
        if selected_mode and selected_mode.id ~= self.current_mode_id then
            self._set_mode_callback(selected_mode.id)
        end
    end)
end

return AgentModes
