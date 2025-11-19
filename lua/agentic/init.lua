local Config = require("agentic.config")
local AgentInstance = require("agentic.acp.agent_instance")

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

---@type table<integer, agentic.SessionManager|nil>
local chat_widgets_by_tab = {}

local function get_session_for_tab_page()
    local tab_page_id = vim.api.nvim_get_current_tabpage()
    local instance = chat_widgets_by_tab[tab_page_id]

    if not instance then
        instance = require("agentic.session_manager"):new(tab_page_id)
        chat_widgets_by_tab[tab_page_id] = instance
    end

    return instance --[[@as agentic.SessionManager]]
end

--- Opens the chat widget for the current tab page
--- Safe to call multiple times
function Agentic.open()
    local session = get_session_for_tab_page()
    session:add_selection_or_file_to_session()
    session.widget:show()
end

--- Closes the chat widget for the current tab page
--- Safe to call multiple times
function Agentic.close()
    get_session_for_tab_page().widget:hide()
end

--- Toggles the chat widget for the current tab page
--- Safe to call multiple times
function Agentic.toggle()
    local session = get_session_for_tab_page()

    if session.widget:is_open() then
        session.widget:hide()
    else
        session:add_selection_or_file_to_session()
        session.widget:show()
    end
end

--- Add the current visual selection to the Chat context
function Agentic.add_selection()
    local session = get_session_for_tab_page()
    session:add_selection_to_session()

    session.widget:show()
end

--- Add the current file to the Chat context
function Agentic.add_file()
    local session = get_session_for_tab_page()
    session:add_file_to_session()
    session.widget:show()
end

--- Add either the current visual selection or the current file to the Chat context
function Agentic.add_selection_or_file_to_context()
    local session = get_session_for_tab_page()
    session:add_selection_or_file_to_session()
    session.widget:show()
end

--- Clears the current chat session and starts a new one
function Agentic.new_session()
    local tab_page_id = vim.api.nvim_get_current_tabpage()
    local session = chat_widgets_by_tab[tab_page_id]

    if session then
        pcall(function()
            session:destroy()
        end)
        chat_widgets_by_tab[tab_page_id] = nil
    end

    local new_session = get_session_for_tab_page()
    new_session:add_selection_or_file_to_session()
    new_session.widget:show()
end

local traps_set = false
local cleanup_group = vim.api.nvim_create_augroup("AgenticCleanup", {
    clear = true,
})

--- Merges the current user configuration with the default configuration
--- This method should be safe to be called multiple times
---@param opts agentic.UserConfig
function Agentic.setup(opts)
    deep_merge_into(Config, opts or {})
    ---FIXIT: remove the debug override before release
    Config.debug = true

    if traps_set then
        return
    end

    traps_set = true

    vim.treesitter.language.register("markdown", "AgenticChat")

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
            if tab_id and chat_widgets_by_tab[tab_id] then
                pcall(function()
                    chat_widgets_by_tab[tab_id]:destroy()
                end)
                chat_widgets_by_tab[tab_id] = nil
            end
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
