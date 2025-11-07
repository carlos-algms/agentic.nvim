local Config = require("agentic.config")

--- A list of instances indexed by tab page ID
--- We are limited by one Agent instance per tab
---@type table<integer, agentic.state.Instance>
local instances = {}

---Cleanup all active instances and processes
---This is called automatically on VimLeavePre and signal handlers
---Can also be called manually if needed
local function cleanup_all()
    for _tab_id, instance in pairs(instances) do
        if instance.agent_client then
            pcall(function()
                instance.agent_client:stop()
            end)
        end
    end
    instances = {}
end

---@class agentic.Agentic
local Agentic = {}

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
function Agentic.setup(opts)
    deep_merge_into(Config, opts or {})
    ---FIXIT: remove the debug override before release
    Config.debug = true

    local cleanup_group =
        vim.api.nvim_create_augroup("AgenticCleanup", { clear = true })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = cleanup_group,
        callback = function()
            cleanup_all()
        end,
        desc = "Cleanup Agentic processes on exit",
    })

    -- Cleanup specific tab instance when tab is closed
    vim.api.nvim_create_autocmd("TabClosed", {
        group = cleanup_group,
        callback = function(ev)
            local tab_id = tonumber(ev.match)
            if tab_id and instances[tab_id] then
                if instances[tab_id].agent_client then
                    pcall(function()
                        instances[tab_id].agent_client:stop()
                    end)
                end
                instances[tab_id] = nil
            end
        end,
        desc = "Cleanup Agentic processes on tab close",
    })

    -- Setup signal handlers for graceful shutdown
    local sigterm_handler = vim.uv.new_signal()
    vim.uv.signal_start(sigterm_handler, "sigterm", function(signame)
        cleanup_all()
    end)

    -- SIGINT handler (Ctrl-C) - note: may not trigger in raw terminal mode
    local sigint_handler = vim.uv.new_signal()
    vim.uv.signal_start(sigint_handler, "sigint", function(signame)
        cleanup_all()
    end)
end

local function get_instance()
    local tab_page_id = vim.api.nvim_get_current_tabpage()
    local instance = instances[tab_page_id]

    if not instance then
        instance = require("agentic.agent_instance").make_instance(tab_page_id)
        instances[tab_page_id] = instance
    end

    return instance
end

function Agentic.open()
    get_instance().chat_widget:open()
end

function Agentic.close()
    get_instance().chat_widget:hide()
end

function Agentic.toggle()
    get_instance().chat_widget:toggle()
end

return Agentic
