--- Manages agent modes for ACP sessions
--- Provides mode selection via vim.ui.select

local BufHelpers = require("agentic.utils.buf_helpers")

--- @class agentic.acp.AgentModes
--- @field _modes agentic.acp.AgentMode[]
--- @field _current_mode_id string|nil
local AgentModes = {}
AgentModes.__index = AgentModes

--- @return agentic.acp.AgentModes
--- @param buffers agentic.ui.ChatWidget.BufNrs Same buffers as ChatWidget instance
function AgentModes:new(buffers)
    local instance = setmetatable({
        _modes = {},
        _current_mode_id = nil,
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
function AgentModes:setModes(modes_info)
    self._modes = modes_info.availableModes
    self._current_mode_id = modes_info.currentModeId
end

function AgentModes:show_mode_selector()
    vim.ui.select(self._modes, {
        prompt = "Select Agent Mode:",
        format_item = function(item)
            --- @cast item agentic.acp.AgentMode
            return string.format("%s: %s", item.name, item.description)
        end,
    }, function(selected_mode)
        if selected_mode then
            self._current_mode_id = selected_mode.id
        end
    end)
end

return AgentModes
