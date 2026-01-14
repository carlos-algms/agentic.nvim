local M = {}

M.session_new = {
    id = 4,
    jsonrpc = "2.0",
    method = "session/new",
    params = {
        cwd = "/Users/abc/projects/agentic.nvim",
        mcpServers = {},
    },
}

return M
