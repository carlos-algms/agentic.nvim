--- Mock implementation of agentic.acp.ACPHealth for testing
--- @class agentic.acp.ACPHealthMock
local M = {}

--- Mock: Always return true for configured provider availability
--- This bypasses the real check that would fail in test environment
--- @return boolean
function M.check_configured_provider()
    return true
end

return M
