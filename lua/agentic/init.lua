local Config = require("agentic.config")
local AgentInstance = require("agentic.acp.agent_instance")
local Theme = require("agentic.theme")
local SessionRegistry = require("agentic.session_registry")

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

--- Opens the chat widget for the current tab page
--- Safe to call multiple times
function Agentic.open()
    local session = SessionRegistry.get_session_for_tab_page()
    session:add_selection_or_file_to_session()
    session.widget:show()
end

--- Closes the chat widget for the current tab page
--- Safe to call multiple times
function Agentic.close()
    SessionRegistry.get_session_for_tab_page().widget:hide()
end

--- Toggles the chat widget for the current tab page
--- Safe to call multiple times
function Agentic.toggle()
    local session = SessionRegistry.get_session_for_tab_page()

    if session.widget:is_open() then
        session.widget:hide()
    else
        session:add_selection_or_file_to_session()
        session.widget:show()
    end
end

--- Add the current visual selection to the Chat context
function Agentic.add_selection()
    local session = SessionRegistry.get_session_for_tab_page()
    session:add_selection_to_session()

    session.widget:show()
end

--- Add the current file to the Chat context
function Agentic.add_file()
    local session = SessionRegistry.get_session_for_tab_page()
    session:add_file_to_session()
    session.widget:show()
end

--- Add either the current visual selection or the current file to the Chat context
function Agentic.add_selection_or_file_to_context()
    local session = SessionRegistry.get_session_for_tab_page()
    session:add_selection_or_file_to_session()
    session.widget:show()
end

--- Destroys the current Chat session and starts a new one
function Agentic.new_session()
    local session = SessionRegistry.new_session()
    session:add_selection_or_file_to_session()
    session.widget:show()
end

--- Used to make sure we don't set multiple signal handlers or autocmds, if the user calls setup multiple times
local traps_set = false
local cleanup_group = vim.api.nvim_create_augroup("AgenticCleanup", {
    clear = true,
})

--- Merges the current user configuration with the default configuration
--- This method should be safe to be called multiple times
---@param opts agentic.UserConfig
function Agentic.setup(opts)
    deep_merge_into(Config, opts or {})

    if traps_set then
        return
    end

    traps_set = true

    vim.treesitter.language.register("markdown", "AgenticChat")

    Theme.setup()

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = cleanup_group,
        callback = function()
            AgentInstance:cleanup_all()
        end,
        desc = "Cleanup Agentic processes on exit",
    })

    -- Cleanup specific tab instance when tab is closed
    vim.api.nvim_create_autocmd("TabClosed", {
        group = cleanup_group,
        callback = function(ev)
            local tab_id = tonumber(ev.match)
            SessionRegistry.destroy_session(tab_id)
        end,
        desc = "Cleanup Agentic processes on tab close",
    })

    -- Setup signal handlers for graceful shutdown
    local sigterm_handler = vim.uv.new_signal()
    if sigterm_handler then
        vim.uv.signal_start(sigterm_handler, "sigterm", function(_sigName)
            AgentInstance:cleanup_all()
        end)
    end

    -- SIGINT handler (Ctrl-C) - note: may not trigger in raw terminal mode
    local sigint_handler = vim.uv.new_signal()
    if sigint_handler then
        vim.uv.signal_start(sigint_handler, "sigint", function(_sigName)
            AgentInstance:cleanup_all()
        end)
    end
end

return Agentic
