local M = {}

M.new_session_response = {
    id = 4,
    jsonrpc = "2.0",
    result = {
        models = {
            availableModels = {
                {
                    description = "Use the default model (currently Sonnet 4.5) · $3/$15 per Mtok",
                    modelId = "default",
                    name = "Default (recommended)",
                },
                {
                    description = "Opus 4.5 · Most capable for complex work · $5/$25 per Mtok",
                    modelId = "opus",
                    name = "Opus",
                },
            },
            currentModelId = "default",
        },
        modes = {
            availableModes = {
                {
                    description = "Standard behavior, prompts for dangerous operations",
                    id = "default",
                    name = "Default",
                },
                {
                    description = "Auto-accept file edit operations",
                    id = "acceptEdits",
                    name = "Accept Edits",
                },
            },
            currentModeId = "default",
        },
        sessionId = "355f40b2-bb6c-4d8f-93ed-5128907803cd",
    },
}

M.available_commands_update = {
    jsonrpc = "2.0",
    method = "session/update",
    params = {
        sessionId = "355f40b2-bb6c-4d8f-93ed-5128907803cd",
        sessionUpdate = "available_commands_update",
        update = {
            availableCommands = {
                {
                    description = "Create a conventional message but don't commit (user)",
                    input = vim.NIL,
                    name = "conventional_message",
                },
            },
        },
    },
}

return M
