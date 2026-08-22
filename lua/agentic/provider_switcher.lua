local BufHelpers = require("agentic.utils.buf_helpers")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")

local ProviderSwitcher = {}

--- @class agentic.ui.SwitchProviderOpts
--- @field provider? agentic.UserConfig.ProviderName

--- @param provider_name agentic.UserConfig.ProviderName
local function notify_creation_failure(provider_name)
    Logger.notify(
        "Failed to create session for provider '" .. provider_name .. "'.",
        vim.log.levels.ERROR
    )
end

--- @param source agentic.SessionManager
--- @return string[]|nil lines
local function get_nonblank_input(source)
    local input_bufnr = source.widget.buf_nrs.input
    if not input_bufnr or not vim.api.nvim_buf_is_valid(input_bufnr) then
        return nil
    end

    local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false)
    for _, line in ipairs(lines) do
        if line:match("%S") then
            return lines
        end
    end

    return nil
end

--- @param messages agentic.ui.ChatHistory.Message[]
--- @return agentic.ui.ChatHistory.Message[] transcript
local function copy_transcript(messages)
    local transcript = vim.deepcopy(messages)

    for _, message in ipairs(transcript) do
        if message.type == "tool_call" then
            message.extmark_id = nil
            message.has_fold = nil
            message.permission = nil
            message.rendered_button_count = nil
        end
    end

    return transcript
end

--- @param source agentic.SessionManager
--- @param target agentic.SessionManager
local function copy_continuity(source, target)
    local messages = copy_transcript(source.chat_history.messages)
    target.chat_history.messages = messages
    target.chat_history.title = source.chat_history.title
    target.history_to_send = vim.deepcopy(messages)
    target.message_writer:replay_history_messages(vim.deepcopy(messages))

    for _, file_path in ipairs(source.file_list:get_files()) do
        target.file_list:add(file_path)
    end

    for _, selection in ipairs(source.code_selection:get_selections()) do
        target.code_selection:add(selection)
    end

    target.diagnostics_list:add_many(source.diagnostics_list:get_diagnostics())

    local input_lines = get_nonblank_input(source)
    if input_lines then
        BufHelpers.with_modifiable(target.widget.buf_nrs.input, function(bufnr)
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                vim.deepcopy(input_lines)
            )
        end)
    end
end

--- @param provider_name agentic.UserConfig.ProviderName
local function apply_provider_switch(provider_name)
    Logger.debug(
        "apply_provider_switch: starting for provider " .. provider_name
    )

    local source = SessionRegistry.current()
    local source_session_id = source and source.session_id or nil

    if source and not source_session_id then
        Logger.notify(
            "Cannot switch provider: session is initializing. Please wait.",
            vim.log.levels.WARN
        )
        return
    end

    if source and source.is_generating then
        Logger.notify(
            "Cannot switch provider while generating. Stop generation first.",
            vim.log.levels.WARN
        )
        return
    end

    --- @type agentic.SessionReplacementOpts
    local replacement_opts = {}

    if source then
        replacement_opts.prepare = function(live_source, target)
            if
                not source_session_id
                or not live_source:owns_ready_acp_session(source_session_id)
            then
                Logger.notify(
                    "Cannot switch provider: the source session changed. Try again."
                )
                return false
            end

            if live_source.is_generating then
                Logger.notify(
                    "Cannot switch provider while generating. Stop generation first."
                )
                return false
            end

            copy_continuity(live_source, target)
        end
    end

    local target = SessionRegistry.replace(
        source,
        provider_name,
        { kind = "new" },
        replacement_opts
    )
    if not target then
        notify_creation_failure(provider_name)
        return
    end

    target:on_session_ready(function() end, function()
        notify_creation_failure(provider_name)
    end)
end

--- Switch provider while preserving chat UI and history. No `opts.provider` shows a picker.
--- @param opts agentic.ui.SwitchProviderOpts|nil
function ProviderSwitcher.switch(opts)
    if opts and opts.provider then
        apply_provider_switch(opts.provider)
        return
    end

    SessionRegistry.select_provider(function(provider_name)
        if provider_name then
            apply_provider_switch(provider_name)
        end
    end)
end

return ProviderSwitcher
