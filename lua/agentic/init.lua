local Config = require("agentic.config")
local ConfigDefault = require("agentic.config_default")

---@class agentic.state.Instances
---@field chat_widget agentic.ui.ChatWidget
---@field agent_client agentic.acp.ACPClient

--- A list of instances indexed by tab page ID
---@type table<integer, agentic.state.Instances>
local instances = {}

local M = {}

local function deep_merge_into(target, ...)
    for _, source in ipairs({ ... }) do
        for k, v in pairs(source) do
            if type(v) == "table" and type(target[k]) == "table" then
                deep_merge_into(target[k], v)
            else
                target[k] = v
            end
        end
    end
    return target
end

---@param opts agentic.UserConfig
function M.setup(opts)
    deep_merge_into(Config, opts or {})
    ---FIXIT: remove the debug override before release
    Config.debug = true
end

local function get_instance()
    local tab_page_id = vim.api.nvim_get_current_tabpage()
    local instance = instances[tab_page_id]

    if not instance then
        local ChatWidget = require("agentic.ui.chat_widget")
        local Client = require("agentic.acp.acp_client")

        instance = {
            chat_widget = ChatWidget:new(tab_page_id),
            agent_client = Client:new(),
        }

        instances[tab_page_id] = instance
    end

    return instance
end

function M.open()
    get_instance().chat_widget:open()
end

function M.close()
    get_instance().chat_widget:hide()
end

function M.toggle()
    get_instance().chat_widget:toggle()
end

return M
